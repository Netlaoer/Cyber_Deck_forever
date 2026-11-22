# -*- coding: utf-8 -*-
"""法师决策（魔兽世界无限服 1.60.1，60 级经典技能组 + 天赋树）。

专精：1 奥术 / 2 火焰 / 3 冰霜
资源：法力（能量值像素）
"""

import time

from utils import get_hotkey

# 法师经典没有驱散技能（解除次级诅咒只驱法师自己身上的）
# 法师驱散能力：2 诅咒（解除次级诅咒 475）
# 法师没有驱散魔法/疾病/中毒的技能 —— 别往里加不存在的类型
DISPEL_TYPES = ("诅咒",)

AOE_3 = 3
AOE_5 = 5

# ============================================================
# 内部小工具（本职业自用，不与其他职业共用）
# ============================================================


CD_UNAVAILABLE = 255

# 驱散类型：1=魔法 2=诅咒 3=疾病 4=中毒
DISPEL_MAGIC = 1
DISPEL_CURSE = 2
DISPEL_DISEASE = 3
DISPEL_POISON = 4


def _cd(spells, name):
    """取冷却值；技能不存在或读不到返回 255（不可用）。"""
    v = (spells or {}).get(name)
    if v is None:
        return CD_UNAVAILABLE
    try:
        return int(v)
    except (TypeError, ValueError):
        return CD_UNAVAILABLE


def _ready(spells, name):
    """技能是否就绪（CD == 0）。"""
    return _cd(spells, name) == 0


def _int(state, key, default=0):
    """取整型状态字段；字段缺失或不是数字时回默认值。"""
    v = (state or {}).get(key, default)
    try:
        return int(v)
    except (TypeError, ValueError):
        return default


def _is_enemy(目标类型):
    """敌对判定：1~10 是敌对区间（含可驱散减益的细分位）。"""
    return 1 <= 目标类型 <= 10


def _in_melee(距离, yards=10):
    """距离码 → 码数比较。"""
    try:
        d = int(距离)
    except (TypeError, ValueError):
        return False
    return 0 < d <= yards


class Ctx(object):
    """一次决策的读数打包（decision 开头 new 一个出来用）。"""

    def __init__(self, state_dict, spec_name):
        self.sd = state_dict or {}
        self.spells = self.sd.get("spells") or {}
        self.spec = spec_name or ""
        self.group = self.sd.get("group") or {}

        self.combat = _int(self.sd, "战斗")
        self.hp = _int(self.sd, "生命值")
        self.mp = _int(self.sd, "能量值")
        self.valid = _int(self.sd, "有效性")

        self.target_type = _int(self.sd, "目标类型")
        self.target_hp = _int(self.sd, "目标生命值")
        self.target_dist = _int(self.sd, "目标距离")
        self.target_casting = _int(self.sd, "目标施法")

        self.enemy_count = _int(self.sd, "敌人人数")
        self.enemy5 = _int(self.sd, "5码敌人")
        self.auto_attack = _int(self.sd, "自动攻击")

        self.dispel_switch = _int(self.sd, "驱散开关")
        self.delay = _int(self.sd, "延迟")

    # -- 常用判断 ----------------------------------------------------
    @property
    def has_target(self):
        """有活着的目标。"""
        return self.target_type > 0

    @property
    def in_combat(self):
        return bool(self.combat)

    @property
    def melee(self):
        """目标在近战距离内。"""
        return self.has_target and _in_melee(self.target_dist, 5)

    def cd(self, name):
        return _cd(self.spells, name)

    def ready(self, name):
        return _ready(self.spells, name)


# -- 节流器 --------------------------------------------------------
# 补 buff / 换武器这类维持类操作用，防止每 0.2 秒重复按
_upkeep_state = {}


def _upkeep_ok(key, interval=3.0):
    """节流：同名操作在 interval 秒内只放行一次。

    只用在「补 buff / 换武器 / 开爆发」这类维持性操作上，
    **别用在主力技能上**（主力技能靠 CD 本身约束）。
    """
    now = time.time()
    last = _upkeep_state.get(key)
    if last is not None and (now - last) < interval:
        return False
    _upkeep_state[key] = now
    return True


def _reset_upkeep():
    """测试用：清空节流状态。"""
    _upkeep_state.clear()


def _pick_dispel_unit(state_dict, 驱散开关, types):
    """挑一个需要驱散（且自己会驱）的队友。

    types 是本职业能驱的**像素字段名**元组（如 ("魔法", "疾病")），
    对应 group 里每人一格剩余秒数：> 0 表示身上有这类可驱减益
    （1 = 不足一秒，255 = 永久/超 255 秒）。
    返回 (slot_key, unit_data) 或 (None, None)。
    """
    from utils import get_unit_with_dispel_seconds
    if not 驱散开关:
        return None, None
    for field in types:
        slot, data = get_unit_with_dispel_seconds(state_dict, field)
        if slot:
            return slot, data
    return None, None

def _skill(ctx, name, unit=None):
    if not ctx.ready(name):
        return None
    return get_hotkey(unit if unit is not None else 0, name)


def run_mage_logic(state_dict, spec_name):
    """返回 (action_hotkey, current_step, unit_info)"""
    ctx = Ctx(state_dict, spec_name)
    spec = ctx.spec

    # -- 驱散（法师能解诅咒）--
    # 战斗和脱战都驱：脱战时驱散是战前清理（队友身上的减益还没过期）
    slot, _ = _pick_dispel_unit(state_dict, ctx.dispel_switch, DISPEL_TYPES)
    if slot:
        hk = _skill(ctx, "解除次级诅咒", int(slot))
        if hk:
            return hk, "解除次级诅咒 on %s" % slot, {"unit": slot}

    if not ctx.in_combat:
        return None, "脱战", {}

    # -- 打断/控制 --
    if ctx.target_casting:
        if spec == "冰霜":
            for sk in ("冰锥术", "冰枪术"):
                hk = _skill(ctx, sk)
                if hk:
                    return hk, "%s（打断）" % sk, {}
        elif spec == "火焰":
            hk = _skill(ctx, "炎爆术")
            if hk:
                return hk, "炎爆术（打断）", {}
        hk = _skill(ctx, "法术反制")
        if hk:
            return hk, "法术反制（打断）", {}

    # -- AOE --
    if ctx.enemy_count >= AOE_5:
        if spec == "冰霜":
            hk = _skill(ctx, "暴风雪")
            if hk:
                return hk, "暴风雪", {"enemies": ctx.enemy_count}
        elif spec == "火焰":
            hk = _skill(ctx, "烈焰风暴")
            if hk:
                return hk, "烈焰风暴", {"enemies": ctx.enemy_count}
    if ctx.enemy_count >= AOE_3:
        if spec == "火焰":
            hk = _skill(ctx, "烈焰风暴")
            if hk:
                return hk, "烈焰风暴", {"enemies": ctx.enemy_count}
        elif spec == "冰霜":
            hk = _skill(ctx, "暴风雪")
            if hk:
                return hk, "暴风雪", {"enemies": ctx.enemy_count}

    # -- 单体 --
    if spec == "奥术":
        hk = _skill(ctx, "奥术飞弹")
        if hk:
            return hk, "奥术飞弹", {}
        hk = _skill(ctx, "魔爆术")
        if hk:
            return hk, "魔爆术", {}
        hk = _skill(ctx, "火球术")
        if hk:
            return hk, "火球术", {}
    elif spec == "火焰":
        hk = _skill(ctx, "灼烧")
        if hk:
            return hk, "灼烧", {}
        hk = _skill(ctx, "炎爆术")
        if hk:
            return hk, "炎爆术", {}
        hk = _skill(ctx, "火球术")
        if hk:
            return hk, "火球术", {}
    else:  # 冰霜
        hk = _skill(ctx, "寒冰箭")
        if hk:
            return hk, "寒冰箭", {}
        hk = _skill(ctx, "冰枪术")
        if hk:
            return hk, "冰枪术", {}
        hk = _skill(ctx, "冰锥术")
        if hk:
            return hk, "冰锥术", {}

    # -- 贴脸应急 --
    hk = _skill(ctx, "冰霜新星")
    if hk and ctx.melee:
        return hk, "寒冰新星（贴脸）", {}

    # -- 工具 --
    hk = _skill(ctx, "闪现术")
    if hk and ctx.melee and _upkeep_ok("闪现术", 5.0):
        return hk, "闪现术（拉开距离）", {}

    return None, "无操作", {}

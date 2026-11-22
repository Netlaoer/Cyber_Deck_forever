# -*- coding: utf-8 -*-
"""牧师决策（魔兽世界无限服 1.60.1，60 级经典技能组 + 天赋树）。

专精：1 戒律（治疗） / 2 圣言（治疗） / 3 暗影（输出）
资源：法力（能量值像素）
"""

import time

from utils import get_hotkey

# 牧师驱散能力：1 魔法（驱散魔法 527）/ 3 疾病（祛病术 988、驱除疾病 552）
# 经典牧师没有解诅咒技能（解除次级诅咒 475 是法师系的）
DISPEL_TYPES = ("魔法", "疾病")

# 治疗阈值
HEAL_PANIC = 35      # 危急血量
HEAL_LOW = 60        # 偏低血量
HEAL_MID = 85        # 中等血量

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


def _lowest_hp_teammate(state_dict):
    """血量最低的队友 (slot, pct)，没有返回 (None, None)"""
    from utils import get_lowest_health_unit
    return get_lowest_health_unit(state_dict, 100)


def run_priest_logic(state_dict, spec_name):
    """返回 (action_hotkey, current_step, unit_info)"""
    ctx = Ctx(state_dict, spec_name)
    spec = ctx.spec

    # -- 驱散（牧师是驱散主力）--
    # 战斗和脱战都驱：脱战时驱散是战前清理（队友身上的减益还没过期）
    slot, _ = _pick_dispel_unit(state_dict, ctx.dispel_switch, DISPEL_TYPES)
    if slot:
        for sk in ("驱散魔法", "祛病术"):
            hk = _skill(ctx, sk, int(slot))
            if hk:
                return hk, "%s on %s" % (sk, slot), {"unit": slot}

    if not ctx.in_combat:
        return None, "脱战", {}

    # -- 暗影专精：输出 --
    if spec == "暗影":
        if ctx.enemy_count >= AOE_3:
            hk = _skill(ctx, "精神鞭笞")
            if hk:
                return hk, "精神鞭笞", {"enemies": ctx.enemy_count}
        hk = _skill(ctx, "暗言术：灭")
        if hk:
            return hk, "暗言术：灭", {}
        hk = _skill(ctx, "暗言术：痛")
        if hk:
            return hk, "暗言术：痛", {}
        hk = _skill(ctx, "惩击")
        if hk:
            return hk, "惩击", {}
        hk = _skill(ctx, "心灵震爆")
        if hk:
            return hk, "心灵震爆", {}
        hk = _skill(ctx, "噬灵瘟疫")
        if hk:
            return hk, "噬灵瘟疫", {}
        return None, "无操作", {}

    # -- 治疗专精：戒律 / 圣言 --
    target_slot, target_pct = _lowest_hp_teammate(state_dict)
    if target_slot is None:
        # 没有队友需要治疗，转输出
        hk = _skill(ctx, "惩击")
        if hk:
            return hk, "惩击", {}
        return None, "无队友", {}

    hp = target_pct if target_pct is not None else 100
    unit = int(target_slot)

    # 危急：瞬间治疗
    if hp <= HEAL_PANIC:
        for sk in ("强效治疗术", "快速治疗", "治疗术"):
            hk = _skill(ctx, sk, unit)
            if hk:
                return hk, "%s on %s (%d%%)" % (sk, target_slot, hp), {"unit": target_slot, "hp": hp}

    # 偏低：常规治疗
    if hp <= HEAL_LOW:
        for sk in ("治疗术", "快速治疗", "次级治疗术"):
            hk = _skill(ctx, sk, unit)
            if hk:
                return hk, "%s on %s (%d%%)" % (sk, target_slot, hp), {"unit": target_slot, "hp": hp}

    # 中等：低消耗
    if hp <= HEAL_MID:
        hk = _skill(ctx, "次级治疗术", unit)
        if hk:
            return hk, "次级治疗术 on %s (%d%%)" % (target_slot, hp), {"unit": target_slot, "hp": hp}

    # 群疗
    hk = _skill(ctx, "愈合祷言")
    if hk and ctx.enemy_count >= AOE_5:
        return hk, "愈合祷言", {"enemies": ctx.enemy_count}
    hk = _skill(ctx, "安抚心灵")
    if hk and _upkeep_ok("安抚心灵", 3.0):
        return hk, "安抚心灵", {}

    # AOE 神圣新星（贴脸时）
    hk = _skill(ctx, "神圣新星")
    if hk and ctx.melee and ctx.enemy_count >= AOE_3:
        return hk, "神圣新星", {"enemies": ctx.enemy_count}

    return None, "无操作", {}

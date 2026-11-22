# -*- coding: utf-8 -*-
"""萨满决策（魔兽世界无限服 1.60.1，60 级经典技能组 + 天赋树）。

专精：1 元素 / 2 增强 / 3 恢复
资源：法力（元素/恢复）；增强用怒气（但本作按法力像素读，经典增强也用法力值）
"""

import time

from utils import get_hotkey

# 萨满驱散能力：净化术(526) 驱诅咒；祛病术(2870) 驱疾病
# 注意：无限服萨满没有「清毒术」（只有「清毒图腾」）
DISPEL_TYPES = ("诅咒", "疾病")

HEAL_LOW = 60
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


def run_shaman_logic(state_dict, spec_name):
    """返回 (action_hotkey, current_step, unit_info)"""
    ctx = Ctx(state_dict, spec_name)
    spec = ctx.spec

    # -- 驱散 --
    # 战斗和脱战都驱：脱战时驱散是战前清理（队友身上的减益还没过期）
    slot, _ = _pick_dispel_unit(state_dict, ctx.dispel_switch, DISPEL_TYPES)
    if slot:
        for sk in ("净化术", "祛病术"):
            hk = _skill(ctx, sk, int(slot))
            if hk:
                return hk, "%s on %s" % (sk, slot), {"unit": slot}

    if not ctx.in_combat:
        return None, "脱战", {}

    # -- 打断 --
    if ctx.target_casting:
        for sk in ("地震术", "烈焰震击", "冰霜震击"):
            hk = _skill(ctx, sk)
            if hk:
                return hk, "%s（打断）" % sk, {}

    # -- 恢复专精：治疗 --
    if spec == "恢复":
        from utils import get_lowest_health_unit
        tslot, tpct = get_lowest_health_unit(state_dict, 100)
        if tslot is not None and tpct is not None and tpct <= HEAL_LOW:
            unit = int(tslot)
            if ctx.enemy_count >= AOE_3:
                hk = _skill(ctx, "治疗链", unit)
                if hk:
                    return hk, "治疗链 on %s" % tslot, {"unit": tslot, "hp": tpct}
            for sk in ("治疗波", "次级治疗波"):
                hk = _skill(ctx, sk, unit)
                if hk:
                    return hk, "%s on %s (%d%%)" % (sk, tslot, tpct), {"unit": tslot, "hp": tpct}
        # 没队友要治：给自己挂治疗波（回蓝回血）
        if ctx.hp <= HEAL_LOW or ctx.mp <= 40:
            hk = _skill(ctx, "治疗波")
            if hk:
                return hk, "治疗波（自保 %d%%)" % ctx.hp, {"hp": ctx.hp, "mp": ctx.mp}
        hk = _skill(ctx, "火焰新星")
        if hk and ctx.melee and ctx.enemy_count >= AOE_3:
            return hk, "火焰新星", {"enemies": ctx.enemy_count}
        return None, "无操作", {}

    # -- 元素：AOE 法术 --
    if spec == "元素":
        if ctx.enemy_count >= AOE_3:
            hk = _skill(ctx, "闪电链")
            if hk:
                return hk, "闪电链", {"enemies": ctx.enemy_count}
        hk = _skill(ctx, "闪电箭")
        if hk:
            return hk, "闪电箭", {}
        hk = _skill(ctx, "火焰新星")
        if hk and ctx.melee and ctx.enemy_count >= AOE_3:
            return hk, "火焰新星", {"enemies": ctx.enemy_count}
        return None, "无操作", {}

    # -- 增强：近战武器 + 风怒 --
    if ctx.enemy5 >= AOE_3:
        hk = _skill(ctx, "风怒武器")
        if hk and _upkeep_ok("风怒武器", 20.0):
            return hk, "风怒武器", {"enemies": ctx.enemy5}
    for sk in ("火舌武器", "石化武器", "冰封武器"):
        hk = _skill(ctx, sk)
        if hk and _upkeep_ok(sk, 20.0):
            return hk, sk, {}
    hk = _skill(ctx, "火焰新星")
    if hk and ctx.melee and ctx.enemy_count >= AOE_3:
        return hk, "火焰新星", {"enemies": ctx.enemy_count}

    return None, "无操作", {}

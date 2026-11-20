# -*- coding: utf-8 -*-
"""德鲁伊决策（魔兽世界无限服 1.60.1，60 级经典技能组 + 天赋树）。

专精：1 平衡（法术） / 2 野性（近战输出） / 3 守护（坦克）
资源：法力（平衡/守护）；野性用怒气（能量值像素）
"""

import time

from utils import get_hotkey

# 德鲁伊驱散能力：解除诅咒(2782) 驱诅咒；驱毒术(8946) 驱中毒
DISPEL_TYPES = (2, 4)

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

    types 是本职业能驱的类型元组（如 (1, 3, 4)）。
    返回 (slot_key, unit_data) 或 (None, None)。
    """
    from utils import get_unit_with_dispel_type
    if not 驱散开关:
        return None, None
    for t in types:
        slot, data = get_unit_with_dispel_type(state_dict, t)
        if slot:
            return slot, data
    return None, None



def _skill(ctx, name, unit=None):
    if not ctx.ready(name):
        return None
    return get_hotkey(unit if unit is not None else 0, name)


def run_druid_logic(state_dict, spec_name):
    """返回 (action_hotkey, current_step, unit_info)"""
    ctx = Ctx(state_dict, spec_name)
    spec = ctx.spec

    if not ctx.in_combat:
        return None, "脱战", {}

    # -- 驱散 --
    slot, _ = _pick_dispel_unit(state_dict, ctx.dispel_switch, DISPEL_TYPES)
    if slot:
        for sk in ("驱毒术", "解除诅咒"):
            hk = _skill(ctx, sk, int(slot))
            if hk:
                return hk, "%s on %s" % (sk, slot), {"unit": slot}

    # -- 打断/控制 --
    if ctx.target_casting:
        hk = _skill(ctx, "纠缠根须")
        if hk:
            return hk, "纠缠根须（打断）", {}

    # -- 守护：坦克 --
    if spec == "守护":
        hk = _skill(ctx, "挑战咆哮")
        if hk:
            return hk, "挑战咆哮", {}
        if ctx.enemy5 >= AOE_3:
            hk = _skill(ctx, "扫击")
            if hk:
                return hk, "扫击", {"enemies": ctx.enemy5}
        hk = _skill(ctx, "槌击")
        if hk:
            return hk, "槌击", {}
        # 残血自保
        if ctx.hp <= HEAL_LOW:
            hk = _skill(ctx, "治疗之触")
            if hk:
                return hk, "治疗之触（自保 %d%%)" % ctx.hp, {"hp": ctx.hp}
        hk = _skill(ctx, "低吼")
        if hk and _upkeep_ok("低吼", 10.0):
            return hk, "低吼", {}
        hk = _skill(ctx, "自然之握")
        if hk and _upkeep_ok("自然之握", 10.0):
            return hk, "自然之握", {}
        return None, "无操作", {}

    # -- 野性：近战输出 --
    if spec == "野性":
        if ctx.enemy5 >= AOE_3:
            hk = _skill(ctx, "扫击")
            if hk:
                return hk, "扫击", {"enemies": ctx.enemy5}
        hk = _skill(ctx, "撕碎")
        if hk:
            return hk, "撕碎", {}
        hk = _skill(ctx, "撕扯")
        if hk:
            return hk, "撕扯", {}
        hk = _skill(ctx, "爪击")
        if hk:
            return hk, "爪击", {}
        hk = _skill(ctx, "凶猛撕咬")
        if hk:
            return hk, "凶猛撕咬", {}
        hk = _skill(ctx, "野性印记")
        if hk and _upkeep_ok("野性印记", 10.0):
            return hk, "野性印记", {}
        return None, "无操作", {}

    # -- 平衡：法术输出 --
    if ctx.enemy_count >= AOE_3:
        hk = _skill(ctx, "月火术")
        if hk:
            return hk, "月火术", {"enemies": ctx.enemy_count}
    hk = _skill(ctx, "星火术")
    if hk:
        return hk, "星火术", {}
    hk = _skill(ctx, "愤怒")
    if hk:
        return hk, "愤怒", {}
    hk = _skill(ctx, "荆棘术")
    if hk:
        return hk, "荆棘术", {}

    return None, "无操作", {}

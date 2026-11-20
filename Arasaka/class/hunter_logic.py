# -*- coding: utf-8 -*-
"""猎人决策（魔兽世界无限服 1.60.1，60 级经典技能组 + 天赋树）。

专精：1 野兽控制 / 2 射击 / 3 生存
资源：法力（能量值像素）
注意：猎人是远程，「自动射击」会自动触发，不需要按键。
"""

import time

from utils import get_hotkey

# 猎人经典没有驱散技能（净化属牧师系）
DISPEL_TYPES = ()

# 射速技能（需要 5 码外）
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



def _skill(ctx, name, unit=None):
    if not ctx.ready(name):
        return None
    return get_hotkey(unit if unit is not None else 0, name)


def run_hunter_logic(state_dict, spec_name):
    """返回 (action_hotkey, current_step, unit_info)"""
    ctx = Ctx(state_dict, spec_name)
    spec = ctx.spec

    if not ctx.in_combat:
        return None, "脱战", {}

    # -- 打断 --
    if ctx.target_casting:
        hk = _skill(ctx, "狙击")
        if hk:
            return hk, "狙击（打断）", {}
        hk = _skill(ctx, "震荡射击")
        if hk:
            return hk, "震荡射击（打断）", {}

    # -- 生存：优先保命 --
    if spec == "生存":
        hk = _skill(ctx, "逃脱")
        if hk and ctx.hp <= 35 and _upkeep_ok("逃脱", 5.0):
            return hk, "逃脱（保命）", {"hp": ctx.hp}
        hk = _skill(ctx, "假死")
        if hk and ctx.hp <= 25 and _upkeep_ok("假死", 5.0):
            return hk, "假死（保命）", {"hp": ctx.hp}

    # -- AOE --
    if ctx.enemy_count >= AOE_5:
        hk = _skill(ctx, "多重射击")
        if hk:
            return hk, "多重射击", {"enemies": ctx.enemy_count}
    if ctx.enemy_count >= AOE_3:
        hk = _skill(ctx, "瞄准射击")
        if hk:
            return hk, "瞄准射击", {"enemies": ctx.enemy_count}
        hk = _skill(ctx, "急速射击")
        if hk and _upkeep_ok("急速射击", 5.0):
            return hk, "急速射击", {"enemies": ctx.enemy_count}
        hk = _skill(ctx, "乱射")
        if hk and ctx.melee:
            return hk, "乱射", {"enemies": ctx.enemy_count}

    # -- 单体 --
    hk = _skill(ctx, "猛禽一击")
    if hk:
        return hk, "猛禽一击", {}
    hk = _skill(ctx, "自动射击")
    if hk:
        return hk, "自动射击", {}
    hk = _skill(ctx, "毒蛇钉刺")
    if hk:
        return hk, "毒蛇钉刺", {}
    hk = _skill(ctx, "奥术射击")
    if hk:
        return hk, "奥术射击", {}

    # -- 增益/工具 --
    hk = _skill(ctx, "猎人印记")
    if hk and _upkeep_ok("猎人印记", 10.0):
        return hk, "猎人印记", {}
    hk = _skill(ctx, "强击光环")
    if hk and _upkeep_ok("强击光环", 10.0):
        return hk, "强击光环", {}

    return None, "无操作", {}

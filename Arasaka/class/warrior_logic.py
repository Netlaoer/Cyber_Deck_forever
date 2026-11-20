# -*- coding: utf-8 -*-
"""战士决策（魔兽世界无限服 1.60.1，60 级经典技能组 + 天赋树）。

专精：1 武器 / 2 狂怒 / 3 防护
资源：怒气（能量值像素是怒气百分比，满 100）
"""

import time

from utils import get_hotkey

# 战士能驱的类型：经典旧世战士只有「驱散魔法」（净化 1152 是牧师系，战士没有）。
# 无限服战士没有驱散技能 —— 保留空元组，需要时再按实测填。
DISPEL_TYPES = ()

# 斩杀阈值（目标血量低于此值才放斩杀）
EXECUTE_HP = 20

# AOE 阈值（5 码内敌人数）
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
    """技能就绪就返回 hotkey，否则 None。"""
    if not ctx.ready(name):
        return None
    return get_hotkey(unit if unit is not None else 0, name)


def run_warrior_logic(state_dict, spec_name):
    """返回 (action_hotkey, current_step, unit_info)"""
    ctx = Ctx(state_dict, spec_name)
    spec = ctx.spec

    if not ctx.in_combat:
        return None, "脱战", {}

    # -- 通用：斩杀（目标残血）--
    if ctx.has_target and ctx.target_hp > 0 and ctx.target_hp <= EXECUTE_HP:
        hk = _skill(ctx, "斩杀")
        if hk:
            return hk, "斩杀", {"target_hp": ctx.target_hp}

    # -- 防护专精：坦克工具优先 --
    if spec == "防护":
        hk = _skill(ctx, "盾牌猛击")
        if hk:
            return hk, "盾牌猛击", {}
        if ctx.enemy5 >= 2:
            hk = _skill(ctx, "盾击")
            if hk:
                return hk, "盾击", {}
        hk = _skill(ctx, "盾牌格挡")
        if hk:
            return hk, "盾牌格挡", {}
        hk = _skill(ctx, "致死打击")
        if hk:
            return hk, "致死打击", {}
        hk = _skill(ctx, "挑战怒吼")
        if hk:
            return hk, "挑战怒吼", {}

    # -- 武器 / 狂怒：AOE 与爆发 --
    if ctx.enemy5 >= AOE_5:
        hk = _skill(ctx, "反击风暴")
        if hk:
            return hk, "反击风暴", {"enemies": ctx.enemy5}
    if ctx.enemy5 >= AOE_3:
        hk = _skill(ctx, "猛击")
        if hk:
            return hk, "猛击", {"enemies": ctx.enemy5}
        hk = _skill(ctx, "破胆怒吼")
        if hk:
            return hk, "破胆怒吼", {"enemies": ctx.enemy5}
        hk = _skill(ctx, "乘胜追击")
        if hk:
            return hk, "乘胜追击", {"enemies": ctx.enemy5}
        hk = _skill(ctx, "顺劈斩")
        if hk:
            return hk, "顺劈斩", {"enemies": ctx.enemy5}
        hk = _skill(ctx, "狂暴之怒")
        if hk and _upkeep_ok("狂暴之怒", 5.0):
            return hk, "狂暴之怒", {"enemies": ctx.enemy5}
        if spec == "狂怒":
            hk = _skill(ctx, "嗜血")
            if hk and _upkeep_ok("嗜血", 5.0):
                return hk, "嗜血", {"enemies": ctx.enemy5}

    # -- 通用：控制与打断 --
    if ctx.target_casting:
        hk = _skill(ctx, "拦截")
        if hk:
            return hk, "拦截（打断）", {}
        hk = _skill(ctx, "缴械")
        if hk:
            return hk, "缴械（打断）", {}
        hk = _skill(ctx, "挑战怒吼")
        if hk:
            return hk, "挑战怒吼（打断）", {}

    # -- 单体：撕裂 --
    hk = _skill(ctx, "撕裂")
    if hk:
        return hk, "撕裂", {}

    # -- 爆发 --
    if ctx.enemy5 >= AOE_3:
        hk = _skill(ctx, "鲁莽")
        if hk and _upkeep_ok("鲁莽", 5.0):
            return hk, "鲁莽", {}

    # -- 平砍 --
    hk = _skill(ctx, "英勇打击")
    if hk:
        return hk, "英勇打击", {}

    # -- 兜底：起手（必须放最后，否则会挡死上面的分支）--
    if ctx.auto_attack == 0 and _upkeep_ok("开始攻击", 2.0):
        hk = _skill(ctx, "开始攻击")
        if hk:
            return hk, "开始攻击", {}

    return None, "无操作", {}

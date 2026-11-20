# -*- coding: utf-8 -*-
"""盗贼决策（魔兽世界无限服 1.60.1，60 级经典技能组 + 天赋树）。

专精：1 狂徒 / 2 敏锐 / 3 刺杀
资源：能量（能量值像素）；能量不足时技能放不出来，靠 CD 像素自然约束
"""

import time

from utils import get_hotkey

# 盗贼经典没有驱散技能（净化属牧师系）
DISPEL_TYPES = ()

AOE_3 = 3
AOE_5 = 5

# 能量下限：低于这个值不放高消耗技能（等能量回来）
ENERGY_MIN = 20

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


def run_rogue_logic(state_dict, spec_name):
    """返回 (action_hotkey, current_step, unit_info)"""
    ctx = Ctx(state_dict, spec_name)
    spec = ctx.spec

    if not ctx.in_combat:
        # 脱战：消失回能量（能量低时才用）
        if ctx.mp < 30:
            hk = _skill(ctx, "消失")
            if hk and _upkeep_ok("消失", 10.0):
                return hk, "消失（回能量）", {"mp": ctx.mp}
        return None, "脱战", {}

    # -- 打断/控制 --
    if ctx.target_casting:
        hk = _skill(ctx, "闷棍")
        if hk:
            return hk, "闷棍（打断）", {}
        hk = _skill(ctx, "肾击")
        if hk:
            return hk, "肾击（打断）", {}
        hk = _skill(ctx, "致盲")
        if hk:
            return hk, "致盲（打断）", {}

    # -- 能量不够就不放主力技能 --
    if ctx.mp < ENERGY_MIN:
        return None, "能量不足", {"mp": ctx.mp}

    # -- 刺杀：背击后的斩杀 --
    if spec == "刺杀":
        hk = _skill(ctx, "割裂")
        if hk:
            return hk, "割裂", {}
        hk = _skill(ctx, "毁伤")
        if hk:
            return hk, "毁伤", {}

    # -- AOE --
    if ctx.enemy5 >= AOE_3:
        hk = _skill(ctx, "割裂")
        if hk:
            return hk, "割裂（AOE）", {"enemies": ctx.enemy5}

    # -- 单体 --
    hk = _skill(ctx, "刺击")
    if hk:
        return hk, "刺击", {}
    hk = _skill(ctx, "毁伤")
    if hk:
        return hk, "毁伤", {}
    hk = _skill(ctx, "刺骨")
    if hk:
        return hk, "刺骨", {}

    # -- 伏击（背刺后接）--
    hk = _skill(ctx, "伏击")
    if hk:
        return hk, "伏击", {}

    # -- 增益 --
    hk = _skill(ctx, "疾跑")
    if hk and _upkeep_ok("疾跑", 10.0):
        return hk, "疾跑", {}
    hk = _skill(ctx, "闪避")
    if hk and _upkeep_ok("闪避", 10.0):
        return hk, "闪避", {}

    # -- 兜底：起手 --
    if ctx.auto_attack == 0 and _upkeep_ok("开始攻击", 2.0):
        hk = _skill(ctx, "开始攻击")
        if hk:
            return hk, "开始攻击", {}

    return None, "无操作", {}

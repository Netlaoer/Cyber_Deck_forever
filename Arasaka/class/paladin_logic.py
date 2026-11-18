# -*- coding: utf-8 -*-
"""圣骑士决策（魔兽世界无限服 1.60.1，60 级经典技能组 + 天赋树）。

与正式服版的差别（对应 class/Paladin.lua 的像素索引）：
- 没有神圣能量 / 圣洁鸣钟 / 圣洁武器 / 英雄天赋 / 一键辅助，相关分支全部删掉；
- 资源是法力（能量值 = 法力百分比），核心是「圣印 + 审判 + 省蓝」；
- 圣印用 20 号像素编码：1 正义 2 命令 3 十字军 4 光明 5 智慧 6 愤怒 7 公正；
- 神恩术(25) / 圣光灌注(26) / 正义之怒(65) / 目标施法(66) 由 core/forever.lua 扫描写入；
  神圣之盾只看 神圣之盾CD(67)（卡 CD 补，与审判一致）——buff 是 secret 值，不再采集；
- 技能冷却来自 spells：0 = 就绪，1~254 = 剩余秒，255 = 不可用（没学会或未解析到）。

冷却值一律用 255 作为缺省：宁可不动，也不对没学会的技能瞎按键。
"""

import time

from utils import (
    count_units_below_health,
    get_hotkey,
    get_lowest_health_unit,
    get_unit_with_dispel_type,
)

# 圣印编号（20 号像素）
SEAL_JUSTICE = 1       # 正义圣印
SEAL_COMMAND = 2       # 命令圣印
SEAL_CRUSADER = 3      # 十字军圣印
SEAL_LIGHT = 4         # 光明圣印
SEAL_WISDOM = 5        # 智慧圣印
SEAL_FURY = 6          # 愤怒圣印
SEAL_JUSTICE_2 = 7     # 公正圣印

# 防护圣印：法力低于 50% 立即换智慧回蓝；
# 回到阈值以上时不立即取消——等这颗智慧的 buff 自己到期，下次才换回愤怒。
SEAL_WISDOM_LOW = 50

CD_UNAVAILABLE = 255

# 清洁术能驱散的类型：1 魔法 / 3 疾病 / 4 中毒（经典旧世圣骑士不能驱诅咒）
CLEANSE_TYPES = (1, 3, 4)

# UnitCreatureType 编号：驱邪术/神圣愤怒 只对亡灵和恶魔
CREATURE_DEMON = 3
CREATURE_UNDEAD = 6
UNDEAD_DEMON = (CREATURE_DEMON, CREATURE_UNDEAD)

# 20 号像素的圣印编号 -> 技能名（69-75 号像素用来判断“学会没学会”）
SEAL_SPELLS = {
    1: "正义圣印", 2: "命令圣印", 3: "十字军圣印", 4: "光明圣印",
    5: "智慧圣印", 6: "愤怒圣印", 7: "公正圣印",
}


def _cd(spells, name):
    v = spells.get(name)
    if v is None:
        return CD_UNAVAILABLE
    try:
        return int(v)
    except (TypeError, ValueError):
        return CD_UNAVAILABLE


def _ready(spells, name):
    return _cd(spells, name) == 0


def _int(state, key, default=0):
    v = state.get(key, default)
    try:
        return int(v)
    except (TypeError, ValueError):
        return default


def _seal_known(spells, seal):
    """69-75 号探测块：255 = 没学会。"""
    return _cd(spells, SEAL_SPELLS[seal]) != CD_UNAVAILABLE


def _first_known_seal(spells, order):
    """按顺序取第一个已学会的圣印。

    69-75 号探测块有任何一项没被客户端写上（停在 255）就会让整条链返回 None，
    此时圣印永远不换、身上一直残留旧的那个（典型现象：防护骑一直挂光明圣印）。
    所以探测全部落空时退回顺序里的第一个候选，宁可空按一次也别让圣印卡死。
    """
    for seal in order:
        if _seal_known(spells, seal):
            return seal
    return order[0] if order else None


def _holy_seal(spells, mana):
    if mana < 35:
        return _first_known_seal(spells, (SEAL_WISDOM, SEAL_LIGHT, SEAL_JUSTICE))
    return _first_known_seal(spells, (SEAL_LIGHT, SEAL_JUSTICE))


# 圣印持续时间（和 core/auras.lua 的 duration 一致），用于本地兜底
SEAL_DURATION = 30.0
# 最近一次"下达换智慧指令"的时刻。战斗中施放的 spellID 是 secret，
# auras 的计时建不起来 → 198 号剩余恒 0；此时用这个时刻推算还剩多久。
_wisdom_cast_at = {"t": time.time()}   # 以模块加载时刻为起点：重载后正挂着智慧也不会被误判到期
def _prot_seal(spells, mana, current_seal=None, seal_remaining=0):
    """防护圣印：

    - 法力 < 50%：**立即**换智慧回蓝，不管当前圣印还剩多久。
    - 法力 ≥ 50% 且正挂着智慧、buff 还没到期：**保持不动**，让它把剩余时间跑完，
      下次到期再换回愤怒——中途取消等于白丢一个 GCD + 一份回蓝。
    - 其余情况：换回愤怒（→ 正义 → 智慧）。

    剩余时间优先用 198 号像素（auras 计时）；读不到（0）时退回本地估算，
    否则战斗中刚换的智慧会被误判"已到期"立刻换回去。
    """
    now = time.time()
    if mana < SEAL_WISDOM_LOW:
        _wisdom_cast_at["t"] = now
        return _first_known_seal(spells, (SEAL_WISDOM, SEAL_FURY, SEAL_JUSTICE))
    if current_seal == SEAL_WISDOM:
        remain = seal_remaining
        if remain <= 0:
            remain = SEAL_DURATION - (now - _wisdom_cast_at["t"])
        if remain > 0:
            return SEAL_WISDOM
    return _first_known_seal(spells, (SEAL_FURY, SEAL_JUSTICE, SEAL_WISDOM))


def _ret_seal(spells, mana):
    if mana >= 25:
        return _first_known_seal(spells, (SEAL_COMMAND, SEAL_JUSTICE))
    return _first_known_seal(spells, (SEAL_WISDOM, SEAL_JUSTICE))


# 维持类技能节流：buff 名称万一和客户端不一致，也不会每个 tick 重按
# 圣印不节流：它只受 GCD 限制，换完由 20 号像素确认，不必再叠一层计时
_UPKEEP_INTERVAL = {"正义之怒": 2.0, "虔诚光环": 2.0}
_last_upkeep = {}


def _upkeep_ok(key, interval=None):
    now = time.time()
    limit = interval if interval is not None else _UPKEEP_INTERVAL.get(key, 3.0)
    if now - _last_upkeep.get(key, 0.0) < limit:
        return False
    _last_upkeep[key] = now
    return True



def _is_enemy(目标类型):
    """main.lua:623 getTargetDispelType 的编码不是 0/1/2/3，而是一段区间：

        0      = 无目标 / 超出射程 / 目标已死
        1~10   = 敌对（1 = 身上没有可驱散光环；2~10 = 有，颜色曲线细分）
        11~20  = 友善（11 为基线，12~20 = 有可驱散光环）

    早期写成 `== 1`，导致「身上带可驱散 buff 的敌人」被判成非敌人，
    防护/惩戒整条战斗链都不走（表现为某些怪一个技能都不放）。
    """
    return 1 <= 目标类型 <= 10


def _in_melee(距离, yards=10):
    return 距离 is not None and 0 < 距离 <= yards


def _pick_dispel_unit(state_dict, 驱散开关):
    """按 魔法 > 疾病 > 中毒 的顺序找一个需要驱散的队友。"""
    if not 驱散开关:
        return None
    for dispel_type in CLEANSE_TYPES:
        unit, _ = get_unit_with_dispel_type(state_dict, dispel_type)
        if unit is not None:
            return unit
    return None


def run_paladin_logic(state_dict, spec_name):
    spells = state_dict.get("spells") or {}

    # 注意：4 号「有效性」（死亡 / 坐骑 / 打字 / 吃喝）由调度层统一判断——
    # logic_gui_Tools.py:_run_logic_loop 在调用本函数**之前**已经 `if not sd.get("有效性"): continue`，
    # 对全部 13 个职业生效。这里不再重复判断，避免两处逻辑漂移。

    # ==================== 公共状态 ====================
    战斗 = bool(state_dict.get("战斗", False))
    移动 = bool(state_dict.get("移动", False))
    施法 = _int(state_dict, "施法")
    引导 = _int(state_dict, "引导")
    生命值 = _int(state_dict, "生命值")
    能量值 = _int(state_dict, "能量值")   # 法力百分比
    目标类型 = _int(state_dict, "目标类型")
    目标距离 = state_dict.get("目标距离")
    目标生命值 = _int(state_dict, "目标生命值")
    目标施法 = _int(state_dict, "目标施法")
    敌人人数 = _int(state_dict, "敌人人数")
    # 48 号：姓名版里距离 ≤5 码且处于战斗的敌人数量。
    # 奉献是地面 AoE（半径 8 码左右），判断该不该放要看身边有几个，不是全场有几个。
    五码敌人 = _int(state_dict, "5码敌人")
    爆发 = _int(state_dict, "爆发开关")
    延迟 = _int(state_dict, "延迟")
    驱散开关 = _int(state_dict, "驱散开关", 1)
    当前圣印 = _int(state_dict, "圣印")
    # 198 号：当前圣印剩余秒（auras 施放计时）；0 = 没挂 / 已到期 / 读不到
    圣印剩余 = _int(state_dict, "圣印剩余")

    神恩术 = _int(state_dict, "神恩术")
    圣光灌注 = _int(state_dict, "圣光灌注")
    正义之怒 = _int(state_dict, "正义之怒")
    生物类型 = _int(state_dict, "生物类型")
    虔诚光环 = _int(state_dict, "虔诚光环")

    圣疗术CD = _cd(spells, "圣疗术")
    清洁术CD = _cd(spells, "清洁术")

    圣光术CD = _cd(spells, "圣光术")
    圣光闪现CD = _cd(spells, "圣光闪现")
    神圣震击CD = _cd(spells, "神圣震击")
    审判CD = _cd(spells, "审判")
    奉献CD = _cd(spells, "奉献")
    神圣打击CD = _cd(spells, "神圣打击")
    愤怒之锤CD = _cd(spells, "愤怒之锤")
    制裁之锤CD = _cd(spells, "制裁之锤")
    神恩术CD = _cd(spells, "神恩术CD")
    神圣之盾CD = _cd(spells, "神圣之盾CD")
    # 24 号像素：1 = 正在近战平砍，0 = 没有（PLAYER_ENTER_COMBAT / LEAVE_COMBAT）
    自动攻击 = _int(state_dict, "自动攻击")
    正义之怒CD = _cd(spells, "正义之怒CD")
    驱邪术CD = _cd(spells, "驱邪术")
    神圣愤怒CD = _cd(spells, "神圣愤怒")

    正在读条 = 施法 > 0 or 引导 > 0

    action_hotkey = None
    current_step = "无匹配技能"
    unit_info = {}

    最低单位, 最低生命值 = get_lowest_health_unit(state_dict, 100)
    最低单位 = 最低单位 or "0"
    最低生命值 = 最低生命值 if 最低生命值 is not None else 100

    if 延迟 > 0 or 引导 > 0:
        current_step = "延迟/引导中，不操作"
        return None, current_step, unit_info

    # ==================== 神圣 ====================
    if spec_name == "神圣":
        驱散单位 = _pick_dispel_unit(state_dict, 驱散开关)
        HP90 = count_units_below_health(state_dict, 90)
        HP75 = count_units_below_health(state_dict, 75)
        HP60 = count_units_below_health(state_dict, 60)
        unit_info = {
            "最低单位": 最低单位 if 最低单位 != "0" else None,
            "最低生命值": 最低生命值,
            "HP<90%人数": HP90,
            "HP<75%人数": HP75,
            "HP<60%人数": HP60,
            "法力": 能量值,
            "圣印": 当前圣印,
        }

        # 圣印维持：缺蓝用智慧，否则光明；没学就退回正义
        想要圣印 = _holy_seal(spells, 能量值)
        圣印就绪 = 想要圣印 is not None and 当前圣印 != 想要圣印 and not 正在读条

        if 清洁术CD == 0 and 驱散单位 is not None:
            current_step = f"清洁术 驱散 {驱散单位}"
            action_hotkey = get_hotkey(int(驱散单位), "清洁术")

        # 神恩术：爆发开时给大治疗铺暴击
        elif 爆发 == 1 and 神恩术CD == 0 and 神恩术 == 0 and not 正在读条 and 最低生命值 < 55:
            current_step = "神恩术"
            action_hotkey = get_hotkey(0, "神恩术")

        # 治疗：圣光术吃大缺口，圣光闪现平刷
        elif not 正在读条 and not 移动 and 最低生命值 < 40 and 能量值 >= 25 and 圣光术CD == 0:
            current_step = f"圣光术 -> {最低单位} ({最低生命值}%)"
            action_hotkey = get_hotkey(int(最低单位), "圣光术")
        elif not 正在读条 and not 移动 and 最低生命值 < 65 and 能量值 >= 12 and 圣光闪现CD == 0:
            current_step = f"圣光闪现 -> {最低单位} ({最低生命值}%)"
            action_hotkey = get_hotkey(int(最低单位), "圣光闪现")
        elif not 正在读条 and not 移动 and 最低生命值 < 88 and 能量值 >= 45 and 圣光闪现CD == 0:
            current_step = f"平刷 圣光闪现 -> {最低单位} ({最低生命值}%)"
            action_hotkey = get_hotkey(int(最低单位), "圣光闪现")

        # 神圣震击：瞬发，补缺口
        elif 神圣震击CD == 0 and not 正在读条 and 最低生命值 < 90 and 能量值 >= 15:
            current_step = f"神圣震击 -> {最低单位} ({最低生命值}%)"
            action_hotkey = get_hotkey(int(最低单位), "神圣震击")

        # 圣印：只在战斗中补，脱战不主动换
        elif 战斗 and 圣印就绪:
            seal_name = SEAL_SPELLS[想要圣印]
            current_step = f"换 {seal_name}"
            action_hotkey = get_hotkey(0, seal_name)

        # 空闲输出：近战位审判
        elif 战斗 and _is_enemy(目标类型) and _in_melee(目标距离) and 审判CD == 0:
            current_step = "审判"
            action_hotkey = get_hotkey(0, "审判")
        elif 战斗 and _is_enemy(目标类型) and _in_melee(目标距离, 20) and 神圣震击CD == 0 and 能量值 >= 60:
            current_step = "进攻 神圣震击"
            action_hotkey = get_hotkey(0, "神圣震击")

    # ==================== 防护 ====================
    elif spec_name == "防护":
        unit_info = {
            "最低单位": 最低单位 if 最低单位 != "0" else None,
            "最低生命值": 最低生命值,
            "法力": 能量值,
            "圣印": 当前圣印,
            "目标距离": 目标距离,
        }

        # 圣印是常驻 buff（30 秒），战斗内外都要维持，提前算好给两条分支共用
        想要圣印 = _prot_seal(spells, 能量值, 当前圣印, 圣印剩余)

        # 自疗：极端低血才丢圣疗（瞬发大治疗）
        if not 正在读条 and 0 < 生命值 < 10 and 圣疗术CD == 0:
            current_step = f"圣疗术 自救 ({生命值}%)"
            action_hotkey = get_hotkey(0, "圣疗术")
        # 正义之怒：常驻仇恨
        elif 正义之怒 == 0 and 正义之怒CD == 0 and _upkeep_ok("正义之怒"):
            current_step = "补 正义之怒"
            action_hotkey = get_hotkey(0, "正义之怒")
        # 虔诚光环：常驻，断了就补
        elif 虔诚光环 == 0 and _upkeep_ok("虔诚光环"):
            current_step = "补 虔诚光环"
            action_hotkey = get_hotkey(0, "虔诚光环")
        # 战斗循环
        elif 战斗 and _is_enemy(目标类型):
            # 圣印：常驻 30 秒。施放成功由插件记 30 秒（core/auras.lua），
            # 到期后 UpdateForeverAuras 会把 20 号编号归 0，所以这里只看"编号对不对"。
            # 2 秒防抖只是盖住像素刷新的那一两个 tick，不是额外的时间闸。
            if (想要圣印 is not None and 当前圣印 != 想要圣印 and not 正在读条
                    and _upkeep_ok("圣印", 2.0)):
                seal_name = SEAL_SPELLS[想要圣印]
                current_step = f"换 {seal_name}"
                action_hotkey = get_hotkey(0, seal_name)
            # 神圣之盾：CD 10 秒 / 持续 10 秒，卡 CD 补——和审判一样，只看 CD，不看 buff。
            # 持续与 CD 等长：buff 被提前打掉时 CD 还在转，CD 一好就补才能无缝覆盖；
            # 若 buff 因天赋/装备被延长，CD 好了也照补（刷新格挡次数）。
            # 没学会时 CD 像素是 255，条件不成立，不会空按。
            elif 神圣之盾CD == 0:
                current_step = "补 神圣之盾"
                action_hotkey = get_hotkey(0, "神圣之盾")
            elif 审判CD == 0 and _in_melee(目标距离):
                current_step = "审判"
                action_hotkey = get_hotkey(0, "审判")
            # 奉献：身边 ≥2 个才放（5 码内敌人数，不是全场人数）
            elif 奉献CD == 0 and 五码敌人 >= 2 and 能量值 >= 70 and not 移动:
                current_step = "奉献"
                action_hotkey = get_hotkey(0, "奉献")
            elif 神圣打击CD == 0 and _in_melee(目标距离, 5):
                current_step = "神圣打击"
                action_hotkey = get_hotkey(0, "神圣打击")
            elif 生物类型 in UNDEAD_DEMON and 敌人人数 >= 2 and 神圣愤怒CD == 0:
                current_step = "神圣愤怒（亡灵/恶魔）"
                action_hotkey = get_hotkey(0, "神圣愤怒")
            # 兜底起手：必须最后。放最前面会让后面全部 elif 被挡死——
            # /reload 后自动攻击像素是 0，整条链就再也出不来（表现为一个技能都不放）。
            # 「战斗且有敌人」为前提：脱战时按它没意义，还会挤掉维持类技能。
            elif 战斗 and _is_enemy(目标类型) and 自动攻击 == 0 and _upkeep_ok("开始攻击", 2):
                current_step = "开始攻击"
                action_hotkey = get_hotkey(0, "开始攻击")
        # 战斗中但当前没敌人（目标刚死、战斗未结束）：仍维持圣印，别等下一个目标现挂。
        # 脱战一律不补——非战斗时按键只会干扰操作（打字、坐骑、看背包）。
        elif (战斗 and 想要圣印 is not None and 当前圣印 != 想要圣印
                and not 正在读条 and _upkeep_ok("圣印", 2.0)):
            seal_name = SEAL_SPELLS[想要圣印]
            current_step = f"换 {seal_name}"
            action_hotkey = get_hotkey(0, seal_name)

    # ==================== 惩戒 ====================
    elif spec_name == "惩戒":
        unit_info = {
            "最低单位": 最低单位 if 最低单位 != "0" else None,
            "最低生命值": 最低生命值,
            "法力": 能量值,
            "圣印": 当前圣印,
            "目标距离": 目标距离,
            "目标生命值": 目标生命值,
        }

        # 圣印是常驻 buff（30 秒），战斗内外都要维持
        想要圣印 = _ret_seal(spells, 能量值)

        if not 正在读条 and not 移动 and 0 < 生命值 < 45 and 能量值 >= 35 and 圣光闪现CD == 0:
            current_step = f"自疗 圣光闪现 ({生命值}%)"
            action_hotkey = get_hotkey(0, "圣光闪现")
        elif 目标施法 > 0 and 制裁之锤CD == 0:
            current_step = "制裁之锤 打断"
            action_hotkey = get_hotkey(0, "制裁之锤")
        elif 战斗 and _is_enemy(目标类型):
            # 斩杀
            if 目标生命值 <= 20 and 愤怒之锤CD == 0 and _in_melee(目标距离, 30):
                current_step = "愤怒之锤"
                action_hotkey = get_hotkey(0, "愤怒之锤")
            # 圣印：常驻，掉了先补
            elif 想要圣印 is not None and 当前圣印 != 想要圣印 and not 正在读条:
                seal_name = SEAL_SPELLS[想要圣印]
                current_step = f"换 {seal_name}"
                action_hotkey = get_hotkey(0, seal_name)
            elif 审判CD == 0 and _in_melee(目标距离):
                current_step = "审判"
                action_hotkey = get_hotkey(0, "审判")
            elif 神圣打击CD == 0 and _in_melee(目标距离, 5):
                current_step = "神圣打击"
                action_hotkey = get_hotkey(0, "神圣打击")
            elif 生物类型 in UNDEAD_DEMON and 驱邪术CD == 0 and _in_melee(目标距离, 30):
                current_step = "驱邪术（亡灵/恶魔）"
                action_hotkey = get_hotkey(0, "驱邪术")
            # 奉献：身边 ≥2 个才放（5 码内敌人数，不是全场人数）
            elif 奉献CD == 0 and 五码敌人 >= 2 and 能量值 >= 30:
                current_step = "奉献 (AoE)"
                action_hotkey = get_hotkey(0, "奉献")
            # 兜底起手（同防护：只在所有技能都没命中时才按）
            elif 战斗 and _is_enemy(目标类型) and 自动攻击 == 0 and _upkeep_ok("开始攻击", 2):
                current_step = "开始攻击"
                action_hotkey = get_hotkey(0, "开始攻击")
        # 战斗中但当前没敌人：仍维持圣印（脱战不补，同防护）
        elif 战斗 and 想要圣印 is not None and 当前圣印 != 想要圣印 and not 正在读条:
            seal_name = SEAL_SPELLS[想要圣印]
            current_step = f"换 {seal_name}"
            action_hotkey = get_hotkey(0, seal_name)

    return action_hotkey, current_step, unit_info

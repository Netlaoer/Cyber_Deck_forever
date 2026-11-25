# -*- coding: utf-8 -*-
"""圣骑士决策（魔兽世界无限服 1.60.1，60 级经典技能组 + 天赋树）。
"""

import time

from utils import (
    count_units_below_health,
    get_hotkey,
    get_lowest_health_unit,
    get_unit_with_aura,
    get_unit_with_role_and_without_aura_name,
    get_unit_with_dispel_seconds,
)

# 圣印编号（20 号像素）
SEAL_JUSTICE = 1       # 正义圣印
SEAL_COMMAND = 2       # 命令圣印
SEAL_WISDOM = 5        # 智慧圣印
SEAL_FURY = 6          # 愤怒圣印

# 防护：法力低于 50% 换智慧回蓝；回到阈值以上等这颗智慧到期再换回
SEAL_WISDOM_LOW = 50

CD_UNAVAILABLE = 255

# 清洁术可驱：魔法 > 疾病 > 中毒（字段名与 config.yml 的 group 一致）
CLEANSE_FIELDS = ("魔法", "疾病", "中毒")

# 不读目标生物类型（secret，无法比较 ==3/==6）：驱邪术/神圣愤怒已从循环撤掉。
# 要加回来需 Lua 侧新增一个类型像素 + config.yml 加字段。

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




def _int(state, key, default=0):
    v = state.get(key, default)
    try:
        return int(v)
    except (TypeError, ValueError):
        return default


def _seal_known(spells, seal):
    return _cd(spells, SEAL_SPELLS[seal]) != CD_UNAVAILABLE


def _first_known_seal(spells, order):
    for seal in order:
        if _seal_known(spells, seal):
            return seal
    return order[0] if order else None




# 圣印持续时间（和 core/auras.lua 的 duration 一致），用于本地兜底
SEAL_DURATION = 30.0
# 最近一次换智慧的时刻：战斗中 spellID 是 secret，auras 计时建不起来，用它推算剩余
_wisdom_cast_at = {"t": time.time()}   # 以模块加载时刻为起点：重载后正挂着智慧也不会被误判到期
def _prot_seal(spells, mana, current_seal=None, seal_remaining=0):
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


# 审判门控（仅防护，审判不消耗圣印）：愤怒印 CD 好就放；
# 智慧印目标已有智慧审判就不放。像素：0 没有，1 不足 1 秒，>=2 有（数值即剩余秒数）
JUDGE_DEBUFF_MIN = 2


def _judge_gate(seal, target_judge_remaining):
    if seal == SEAL_FURY:
        return True
    if seal == SEAL_WISDOM:
        return target_judge_remaining < JUDGE_DEBUFF_MIN
    return True


# 施法失败像素 -> 技能名（27 制裁之锤 / 28 圣盾术）；自由祝福没有块，不重试
failed_spell_map = {
    27: "制裁之锤",
    28: "圣盾术",
}


def _get_failed_spell(state_dict):
    spell_name = failed_spell_map.get(state_dict.get("法术失败", 0))
    if not spell_name:
        return None
    spells = state_dict.get("spells") or {}
    return spell_name if spells.get(spell_name, 0) == 0 else None


_UPKEEP_INTERVAL = {"正义之怒": 2.0}
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
    """
    return 1 <= 目标类型 <= 10


def _in_melee(距离, yards=10):
    return 距离 is not None and 0 < 距离 <= yards


def _pick_dispel_unit(state_dict, 驱散开关):
    """按 魔法 > 疾病 > 中毒 的顺序找一个需要驱散的队友。

    每种类型在 group 里是一格剩余秒数：> 0 就表示身上有这类可驱减益
    （1 = 不足一秒，255 = 永久/超 255 秒）。
    """
    if not 驱散开关:
        return None
    for field in CLEANSE_FIELDS:
        unit, _ = get_unit_with_dispel_seconds(state_dict, field)
        if unit is not None:
            return unit
    return None


def run_paladin_logic(state_dict, spec_name):
    spells = state_dict.get("spells") or {}

    # 有效性（死亡/坐骑/打字/吃喝）由调度层统一判断

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
    五码敌人 = _int(state_dict, "5码敌人")
    延迟 = _int(state_dict, "延迟")
    驱散开关 = _int(state_dict, "驱散开关", 1)
    鼠标可驱 = _int(state_dict, "鼠标可驱")
    当前圣印 = _int(state_dict, "圣印")
    圣印剩余 = _int(state_dict, "圣印剩余")
    # 目标智慧审判（20354）剩余秒数：引擎 AuraContainer 写 340 格，0 = 没有
    目标智慧审判 = _int(state_dict, "目标智慧审判")

    正义之怒 = _int(state_dict, "正义之怒")

    圣疗术CD = _cd(spells, "圣疗术")
    圣盾术CD = _cd(spells, "圣盾术")
    # ---- 正式服专有上下文（无限服没有对应数据源）----
    orig_目标类型 = _int(state_dict, "目标类型")   # 正式服分支会临时改写 目标类型，需要留原值
    法术失败 = _int(state_dict, "法术失败")   # 12 号像素，0 = 没失败
    失败法术 = _get_failed_spell(state_dict)
    清洁术CD = _cd(spells, "清洁术")

    神圣震击CD = _cd(spells, "神圣震击")
    审判CD = _cd(spells, "审判")
    奉献CD = _cd(spells, "奉献")
    神圣打击CD = _cd(spells, "神圣打击")
    愤怒之锤CD = _cd(spells, "愤怒之锤")
    制裁之锤CD = _cd(spells, "制裁之锤")
    神圣之盾CD = _cd(spells, "神圣之盾CD")
    自动攻击 = _int(state_dict, "自动攻击")
    正义之怒CD = _cd(spells, "正义之怒CD")

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
        # 选中友方时临时当敌对，让进攻块照常执行；无目标不伪造（纯 /cast 会空按）
        if 11 <= orig_目标类型 <= 20:
            state_dict["目标类型"] = 2
            目标类型 = 2

        最低单位_orig, 最低生命值_orig = get_lowest_health_unit(state_dict, 100)
        最低单位 = 最低单位_orig or "0"
        最低生命值 = 最低生命值_orig or 100
        HP90 = count_units_below_health(state_dict, 90)
        HP80 = count_units_below_health(state_dict, 80)
        HP75 = count_units_below_health(state_dict, 75)
        HP60 = count_units_below_health(state_dict, 60)

        unit_info = {
            "最低单位": 最低单位_orig,
            "最低生命值": 最低生命值_orig,
            "HP<90%人数": HP90,
            "HP<80%人数": HP80,
            "HP<75%人数": HP75,
            "HP<60%人数": HP60,
        }

        # 驱散优先级 魔法 > 疾病 > 中毒，受 /cy dispel 开关控制
        驱散单位 = _pick_dispel_unit(state_dict, 驱散开关)

        if 引导 > 0 or 延迟 > 0:
            current_step = "在引导,不执行任何操作"

        elif 法术失败 != 0 and 失败法术 is not None:
            current_step = f"施放 {失败法术}"
            action_hotkey = get_hotkey(0, 失败法术)

        # 只走动态宏（@raidN）；单人时宏体第三段是 [@player]，等于给自己驱散
        elif 清洁术CD == 0 and 驱散单位 is not None:
            current_step = f"施放 清洁术 on {驱散单位}"
            action_hotkey = get_hotkey(int(驱散单位), "清洁术")
        # 开关关 -> 鼠标指向（判断和施法都看 mouseover：unit 0 的 [@mouseover] 宏）
        elif 清洁术CD == 0 and not 驱散开关 and 鼠标可驱 > 0:
            current_step = "施放 清洁术 on 鼠标指向"
            action_hotkey = get_hotkey(0, "清洁术")

        # ==================== 团队/队伍/单人逻辑 ====================
        else:
            if 圣盾术CD == 0 and 生命值 < 15:
                current_step = "施放 圣盾术"
                # 圣盾术是静态宏（staticSpells[7]），没有按单位分的宏位；写 unit 1 会取到 None
                action_hotkey = get_hotkey(0, "圣盾术")
            elif 圣疗术CD == 0 and 圣盾术CD > 0 and 生命值 < 15:
                current_step = "施法 圣疗术"
                # 自救走 [@player] 静态宏（staticSpells[9]），不要用 unit 1（团队里是 raid1）
                action_hotkey = get_hotkey(0, "圣疗术")
            elif 战斗 :
                守望单位, _ = get_unit_with_aura(state_dict, "圣光守望")
                # 圣光誓约：坦克身上没有就补（5 分钟长 buff，只挂一个）
                誓约单位, _ = get_unit_with_role_and_without_aura_name(state_dict, 1, "圣光誓约")
                if 守望单位 is not None and 神圣震击CD == 0 and not 施法:
                    current_step = f"圣光守望 震击 -> {守望单位}"
                    action_hotkey = get_hotkey(int(守望单位), "神圣震击")
                elif 誓约单位 is not None and not 施法:
                    current_step = f"圣光誓约 -> {誓约单位}"
                    action_hotkey = get_hotkey(int(誓约单位), "圣光誓约")
                elif not 施法 and not 移动 and 最低生命值 < 60:
                    current_step = "站桩 圣光术"
                    action_hotkey = get_hotkey(int(最低单位), "圣光术")
                # 群抬：圣光守望没有冷却，只看震击剩余和低血人数
                elif 神圣震击CD <= 2 and not 移动 and HP75 >= 3:
                    current_step = "群奶 圣光守望"
                    action_hotkey = get_hotkey(int(最低单位), "圣光守望")
                elif not 施法 and not 移动 and 最低生命值 <= 90:
                    current_step = "圣光闪现"
                    action_hotkey = get_hotkey(int(最低单位), "圣光闪现")
                elif 神圣震击CD == 0 and not 施法 and 最低生命值 < 95:
                    current_step = "施放 神圣震击"
                    action_hotkey = get_hotkey(int(最低单位), "神圣震击")
 
            if current_step == "无匹配技能" and 战斗 and not 施法 and 1 <= 目标类型 <= 3:
                # 智慧圣印优先：奶骑靠它回蓝，进攻前先确保挂着
                if 当前圣印 != SEAL_WISDOM and not 施法:
                    current_step = "施放 智慧圣印"
                    action_hotkey = get_hotkey(0, "智慧圣印")
                # 审判：目标已有智慧审判(20354)就不放（奶骑审判只为维持 debuff，省 GCD/省蓝）
                elif 审判CD == 0 and _judge_gate(SEAL_WISDOM, 目标智慧审判):
                    current_step = "进攻 审判"
                    action_hotkey = get_hotkey(0, "审判")
                elif 神圣打击CD == 0:
                    current_step = "进攻 神圣打击"
                    action_hotkey = get_hotkey(0, "神圣打击")


    # ==================== 防护 ====================
    elif spec_name == "防护":
        unit_info = {
            "最低单位": 最低单位 if 最低单位 != "0" else None,
            "最低生命值": 最低生命值,
            "法力": 能量值,
            "圣印": 当前圣印,
            "目标距离": 目标距离,
        }

        驱散单位 = _pick_dispel_unit(state_dict, 驱散开关)

        # 圣印是常驻 buff（30 秒），战斗内外都要维持，提前算好给两条分支共用
        想要圣印 = _prot_seal(spells, 能量值, 当前圣印, 圣印剩余)

        if 法术失败 != 0 and 失败法术 is not None:
            current_step = f"施放 {失败法术}"
            action_hotkey = get_hotkey(0, 失败法术)
        # 驱散：开关开 -> 自动驱队友；开关关 -> 鼠标指向（unit 0 的 [@mouseover]）
        elif 清洁术CD == 0 and 驱散开关 and 驱散单位 is not None:
            current_step = f"施放 清洁术 on {驱散单位}"
            action_hotkey = get_hotkey(int(驱散单位), "清洁术")
        # 「鼠标可驱」> 0 就按；引擎算剩余，战斗中同样有效
        elif 清洁术CD == 0 and not 驱散开关 and 鼠标可驱 > 0:
            current_step = "施放 清洁术 on 鼠标指向"
            action_hotkey = get_hotkey(0, "清洁术")
        # 自疗：极端低血才丢圣疗（瞬发大治疗）
        elif not 正在读条 and 0 < 生命值 < 10 and 圣疗术CD == 0:
            current_step = f"圣疗术 自救 ({生命值}%)"
            action_hotkey = get_hotkey(0, "圣疗术")
        elif 正义之怒 == 0 and 正义之怒CD == 0 and _upkeep_ok("正义之怒"):
            current_step = "补 正义之怒"
            action_hotkey = get_hotkey(0, "正义之怒")
        elif 战斗 and _is_enemy(目标类型):
            # 圣印常驻 30 秒，施放成功时 spellID 可读，所以 20 号编号与 198 号剩余是准的；
            # 不设防抖：编号一更新条件就不成立，多按一次也有 GCD 挡
            if 想要圣印 is not None and 当前圣印 != 想要圣印 and not 正在读条:
                seal_name = SEAL_SPELLS[想要圣印]
                current_step = f"换 {seal_name}"
                action_hotkey = get_hotkey(0, seal_name)
            # 神圣之盾：CD 10 秒 = 持续 10 秒，卡 CD 补（buff 被提前打掉也能无缝覆盖）；
            # 未学会时 CD 像素 255，条件不成立
            elif 神圣之盾CD == 0 and 五码敌人 >= 1:
                current_step = "补 神圣之盾"
                action_hotkey = get_hotkey(0, "神圣之盾")
            # 审判看圣印分支（审判不消耗圣印），智慧印已有 debuff 就不放
            elif (审判CD == 0 and _in_melee(目标距离)
                  and _judge_gate(当前圣印, 目标智慧审判)):
                current_step = "审判"
                action_hotkey = get_hotkey(0, "审判")
            # 奉献：身边 ≥2 个才放（5 码内敌人数，不是全场人数）
            elif 奉献CD == 0 and 五码敌人 >= 2 and 能量值 >= 40 and not 移动:
                current_step = "奉献"
                action_hotkey = get_hotkey(0, "奉献")
            elif 神圣打击CD == 0 and _in_melee(目标距离, 5):
                current_step = "神圣打击"
                action_hotkey = get_hotkey(0, "神圣打击")
            # 驱邪/神圣愤怒不做了：读不到生物类型，盲放只会红字报错。
            # 兜底起手必须放最后：放前面会挡死后面所有 elif，/reload 后一个技能都不出；
            # 「战斗且有敌人」为前提，脱战时按它只会挤掉维持类技能。
            elif 战斗 and _is_enemy(目标类型) and 自动攻击 == 0 and _upkeep_ok("开始攻击", 2):
                current_step = "开始攻击"
                action_hotkey = get_hotkey(0, "开始攻击")
        # 战斗中没敌人（目标刚死）仍维持圣印；脱战不补，免得干扰打字/坐骑
        elif (战斗 and 想要圣印 is not None and 当前圣印 != 想要圣印
                and not 正在读条):
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

        if 法术失败 != 0 and 失败法术 is not None:
            current_step = f"施放 {失败法术}"
            action_hotkey = get_hotkey(0, 失败法术)
        # 开关关 -> 鼠标指向驱散（判断和施法都看 mouseover：unit 0 的 [@mouseover] 宏）
        elif 清洁术CD == 0 and not 驱散开关 and 鼠标可驱 > 0:
            current_step = "施放 清洁术 on 鼠标指向"
            action_hotkey = get_hotkey(0, "清洁术")
        elif not 正在读条 and not 移动 and 0 < 生命值 < 45 and 能量值 >= 35:
            current_step = f"自疗 圣光闪现 ({生命值}%)"
            # 自疗走 staticSpells[35] 的 [@player]（unit 0）：动态宏在团队里会打给 raidN
            action_hotkey = get_hotkey(0, "圣光闪现")
        elif 目标施法 > 0 and 制裁之锤CD == 0:
            current_step = "制裁之锤 打断"
            action_hotkey = get_hotkey(0, "制裁之锤")
        elif 战斗 and _is_enemy(目标类型):
            if 目标生命值 <= 20 and 愤怒之锤CD == 0 and _in_melee(目标距离, 30):
                current_step = "愤怒之锤"
                action_hotkey = get_hotkey(0, "愤怒之锤")
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
            # 驱邪术同上不做；奉献：5 码内 ≥2 个才放
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

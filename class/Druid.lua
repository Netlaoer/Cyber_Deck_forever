if UnitClassBase("player") ~= "DRUID" then return end
local addon, ns = ...

--[[
    class/Druid.lua — 无限服(1.60.1 / Interface 16001)版 · 像素块布局
    ------------------------------------------------------------------
    像素块布局已按无限服规范排好，**决策逻辑在 Arasaka/class/druid_logic.py**
    （run_druid_logic），config.yml 的专精段与 keymap/druid.yml 都已配好。
    本文件只负责「块名 -> 索引」与宏表，不承担决策。

    技能用 name 而非 spellId（main.lua 解析到已学会的 rank，未学会写 255）；
    无蓄力/一键辅助/英雄天赋/首领战/难度；通用块 1~15 与 config.yml 顶层 state 一致。

    索引表：
      1-15    通用（与全局 state 一致）
      16-17   留空
      18-28   职业状态（施法技能/施法目标/目标距离/自动攻击/敌人人数/
              爆发开关/大红冷却/延迟/驱散开关/5码敌人/目标施法）
      29-84  技能（按学习等级排序，共 56 个）
      85    队伍块起点（每人 生命值 / 职责 / 诅咒 / 中毒）
      85+1 起  预留给该职业特有的光环块

    改布局时三处必须同步：下面的索引表 / Arasaka/config.yml 对应专精段的 step /
    重跑 _work/test_layouts_all.py（查 start/num/字段/块尾/区间重叠）。
    决策逻辑在 Arasaka/class/druid_logic.py，不在本文件。
]]

local function buildBlocks()
    return {
        powerType = "MANA",
        [1] = { type = "block", name = "锚点" },
        [2] = { type = "block", name = "职业" },
        [3] = { type = "block", name = "专精" },
        [4] = { type = "block", name = "有效性" },
        [5] = { type = "block", name = "战斗" },
        [6] = { type = "block", name = "移动" },
        [7] = { type = "block", name = "施法" },
        [8] = { type = "block", name = "引导" },
        [9] = { type = "block", name = "生命值" },
        [10] = { type = "block", name = "能量值" },
        [11] = { type = "block", name = "目标生命值" },
        [12] = { type = "block", name = "法术失败" },
        [13] = { type = "block", name = "目标类型" },
        [14] = { type = "block", name = "队伍类型" },
        [15] = { type = "block", name = "队伍人数" },
        [18] = { type = "block", name = "施法技能" },
        [19] = { type = "block", name = "施法目标" },
        [20] = { type = "block", name = "目标距离" },
        [21] = { type = "block", name = "自动攻击" },
        [22] = { type = "block", name = "敌人人数" },
        [23] = { type = "block", name = "爆发开关" },
        [24] = { type = "block", name = "大红冷却" },
        [25] = { type = "block", name = "延迟" },
        [26] = { type = "block", name = "驱散开关" },
        [27] = { type = "block", name = "5码敌人" },
        [28] = { type = "block", name = "目标施法" },
        [29] = { type = "spell", name = "愤怒" },  -- 天赋解锁（未点天赋时写 255）
        [30] = { type = "spell", name = "治疗之触" },  -- 天赋解锁（未点天赋时写 255）
        [31] = { type = "spell", name = "野性印记" },
        [32] = { type = "spell", name = "回春术" },
        [33] = { type = "spell", name = "月火术" },
        [34] = { type = "spell", name = "荆棘术" },
        [35] = { type = "spell", name = "纠缠根须" },
        [36] = { type = "spell", name = "传送：月光林地" },
        [37] = { type = "spell", name = "低吼" },
        [38] = { type = "spell", name = "挫志咆哮" },
        [39] = { type = "spell", name = "槌击" },
        [40] = { type = "spell", name = "熊形态" },
        [41] = { type = "spell", name = "自然之握" },
        [42] = { type = "spell", name = "愈合" },
        [43] = { type = "spell", name = "狂怒" },
        [44] = { type = "spell", name = "起死回生" },
        [45] = { type = "spell", name = "消毒术" },
        [46] = { type = "spell", name = "重击" },
        [47] = { type = "spell", name = "挥击" },
        [48] = { type = "spell", name = "水栖形态" },
        [49] = { type = "spell", name = "水栖形态（被动）" },
        [50] = { type = "spell", name = "休眠" },
        [51] = { type = "spell", name = "精灵之火" },
        [52] = { type = "spell", name = "复生" },
        [53] = { type = "spell", name = "撕扯" },
        [54] = { type = "spell", name = "撕碎" },
        [55] = { type = "spell", name = "星火术" },
        [56] = { type = "spell", name = "清晰预兆" },
        [57] = { type = "spell", name = "潜行" },
        [58] = { type = "spell", name = "爪击" },
        [59] = { type = "spell", name = "猎豹形态" },
        [60] = { type = "spell", name = "安抚动物" },
        [61] = { type = "spell", name = "凶猛撕咬" },
        [62] = { type = "spell", name = "扫击" },
        [63] = { type = "spell", name = "解除诅咒" },
        [64] = { type = "spell", name = "急奔" },
        [65] = { type = "spell", name = "驱毒术" },
        [66] = { type = "spell", name = "挑战咆哮" },
        [67] = { type = "spell", name = "畏缩" },
        [68] = { type = "spell", name = "宁静" },
        [69] = { type = "spell", name = "旅行形态" },
        [70] = { type = "spell", name = "虫群" },
        [71] = { type = "spell", name = "毁灭" },
        [72] = { type = "spell", name = "蓄势待发" },
        [73] = { type = "spell", name = "追踪人型生物" },
        [74] = { type = "spell", name = "割伤" },
        [75] = { type = "spell", name = "狂暴回复" },
        [76] = { type = "spell", name = "突袭" },
        [77] = { type = "spell", name = "巨熊形态" },  -- 天赋解锁（未点天赋时写 255）
        [78] = { type = "spell", name = "激活" },  -- 天赋解锁（未点天赋时写 255）
        [79] = { type = "spell", name = "豹之优雅" },  -- 天赋解锁（未点天赋时写 255）
        [80] = { type = "spell", name = "飓风" },  -- 天赋解锁（未点天赋时写 255）
        [81] = { type = "spell", name = "树皮术" },  -- 天赋解锁（未点天赋时写 255）
        [82] = { type = "spell", name = "原始撕咬" },  -- 天赋解锁（未点天赋时写 255）
        [83] = { type = "spell", name = "野性成长" },  -- 天赋解锁（未点天赋时写 255）
        [84] = { type = "spell", name = "野性赐福" },  -- 天赋解锁（未点天赋时写 255）

        -- 队伍块：每人 生命值 / 职责 / 诅咒 / 中毒
        -- 队伍块必须排在技能块之外，config.yml 的 group.start 与这里要一致
        [85] = {
            type = "group",
            num = 4,
            healthPercent = 1,
            role = 2,
            dispelCurse = 3,
            dispelPoison = 4,
            auras = {},
        },
    }
end

CyberDeck.ClassBlocks = {
    [1] = buildBlocks(), -- 平衡
    [2] = buildBlocks(), -- 野性
    [3] = buildBlocks(), -- 守护
}

-- 宏表：dynamicSpells 每技能占 30 个宏位（@raid1/@partyN），staticSpells 单键宏，
-- 以 / 开头放 specialSpells；动态数 x30 + 静态数 ≤ 7 组修饰 x 39 键 = 273。
CyberDeck.MacrosList = {
    dynamicSpells = { "解除诅咒", "驱毒术" },
    specialSpells = {
    },
    staticSpells = {
        [3] = "纠缠根须",
        [4] = "挑战咆哮",
        [5] = "扫击",
        [6] = "槌击",
        [7] = "治疗之触",
        [8] = "低吼",
        [9] = "自然之握",
        [10] = "撕碎",
        [11] = "撕扯",
        [12] = "爪击",
        [13] = "凶猛撕咬",
        [14] = "野性印记",
        [15] = "月火术",
        [16] = "星火术",
        [17] = "愤怒",
        [18] = "荆棘术",
    },
}








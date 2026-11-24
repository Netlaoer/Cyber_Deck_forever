if UnitClassBase("player") ~= "SHAMAN" then return end
local addon, ns = ...

--[[
    class/Shaman.lua — 无限服(1.60.1 / Interface 16001)版 · 像素块布局
    ------------------------------------------------------------------
    像素块布局已按无限服规范排好，**决策逻辑在 Arasaka/class/shaman_logic.py**
    （run_shaman_logic），config.yml 的专精段与 keymap/shaman.yml 都已配好。
    本文件只负责「块名 -> 索引」与宏表，不承担决策。

    与正式服版的区别：
    1. 技能用 name 而不是 spellId；main.lua 按名称解析到"已学会的 rank"，
       没学会的技能自动写 255（不可用）。
    2. 没有蓄力 / 一键辅助 / 英雄天赋 / 首领战 / 难度这些零售机制。
    3. 通用块 1~15 与 config.yml 顶层 state 一致；16~17 留空。

    索引表：
      1-15    通用（与全局 state 一致）
      16-17   留空
      18-28   职业状态（施法技能/施法目标/目标距离/自动攻击/敌人人数/
              爆发开关/大红冷却/延迟/驱散开关/5码敌人/目标施法）
      29-79  技能（按学习等级排序，共 51 个）
      80    队伍块起点（每人 生命值 / 职责 / 诅咒 / 疾病）
      80+1 起  预留给该职业特有的光环块

    技能名来自 endgametools 的无限服职业法术页（经典 60 级技能组 + 天赋）。
    改布局时三处必须同步：
      1. 改下面的索引表
      2. 改 Arasaka/config.yml 对应专精段的 step
      3. 重跑 _work/test_layouts_all.py（查 start/num/字段/块尾/区间重叠）
    决策逻辑在 Arasaka/class/shaman_logic.py，不在本文件。
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
        [29] = { type = "spell", name = "治疗波" },  -- 天赋解锁（未点天赋时写 255）
        [30] = { type = "spell", name = "石化武器" },
        [31] = { type = "spell", name = "闪电箭" },  -- 天赋解锁（未点天赋时写 255）
        [32] = { type = "spell", name = "地震术" },
        [33] = { type = "spell", name = "石肤图腾" },
        [34] = { type = "spell", name = "地缚图腾" },
        [35] = { type = "spell", name = "石爪图腾" },
        [36] = { type = "spell", name = "闪电之盾" },
        [37] = { type = "spell", name = "大地之力图腾" },
        [38] = { type = "spell", name = "火舌武器" },
        [39] = { type = "spell", name = "灼热图腾" },
        [40] = { type = "spell", name = "烈焰震击" },
        [41] = { type = "spell", name = "先祖之魂" },
        [42] = { type = "spell", name = "净化术" },
        [43] = { type = "spell", name = "火焰新星" },
        [44] = { type = "spell", name = "消毒术" },
        [45] = { type = "spell", name = "战栗图腾" },
        [46] = { type = "spell", name = "元素的召唤" },
        [47] = { type = "spell", name = "冰封武器" },
        [48] = { type = "spell", name = "冰霜震击" },
        [49] = { type = "spell", name = "幽魂之狼" },
        [50] = { type = "spell", name = "收回图腾" },
        [51] = { type = "spell", name = "次级治疗波" },
        [52] = { type = "spell", name = "治疗之泉图腾" },
        [53] = { type = "spell", name = "图腾呼唤" },
        [54] = { type = "spell", name = "水下呼吸" },
        [55] = { type = "spell", name = "清毒图腾" },
        [56] = { type = "spell", name = "祛病术" },
        [57] = { type = "spell", name = "抗寒图腾" },
        [58] = { type = "spell", name = "法力之泉图腾" },
        [59] = { type = "spell", name = "熔岩图腾" },
        [60] = { type = "spell", name = "视界术" },
        [61] = { type = "spell", name = "抗火图腾" },
        [62] = { type = "spell", name = "水上行走" },
        [63] = { type = "spell", name = "火舌图腾" },
        [64] = { type = "spell", name = "先祖的召唤" },
        [65] = { type = "spell", name = "复生" },
        [66] = { type = "spell", name = "星界传送" },
        [67] = { type = "spell", name = "根基图腾" },
        [68] = { type = "spell", name = "自然抗性图腾" },
        [69] = { type = "spell", name = "风怒武器" },
        [70] = { type = "spell", name = "闪电链" },
        [71] = { type = "spell", name = "风怒图腾" },
        [72] = { type = "spell", name = "岗哨图腾" },
        [73] = { type = "spell", name = "风墙图腾" },
        [74] = { type = "spell", name = "法力之潮图腾" },
        [75] = { type = "spell", name = "祛病图腾" },
        [76] = { type = "spell", name = "治疗链" },  -- 天赋解锁（未点天赋时写 255）
        [77] = { type = "spell", name = "灵魂的召唤" },  -- 天赋解锁（未点天赋时写 255）
        [78] = { type = "spell", name = "风之优雅图腾" },  -- 天赋解锁（未点天赋时写 255）
        [79] = { type = "spell", name = "激流" },  -- 天赋解锁（未点天赋时写 255）

        -- 队伍块：每人 生命值 / 职责 / 诅咒 / 疾病
        -- 队伍块必须排在技能块之外，config.yml 的 group.start 与这里要一致
        [80] = {
            type = "group",
            num = 4,
            healthPercent = 1,
            role = 2,
            dispelCurse = 3,
            dispelDisease = 4,
            auras = {},
        },
    }
end

CyberDeck.ClassBlocks = {
    [1] = buildBlocks(), -- 元素
    [2] = buildBlocks(), -- 增强
    [3] = buildBlocks(), -- 恢复
}

-- 宏表：dynamicSpells 每个技能占 30 个宏位（@raid1 / @partyN），
-- staticSpells 是单键宏；特殊宏体（以 / 开头）放 specialSpells。
-- 宏位总数上限 = 7 组修饰键 x 39 键 = 273，
-- 动态技能数 x 30 + 静态数 不能超过 273。
CyberDeck.MacrosList = {
    dynamicSpells = { "净化术", "祛病术" },
    specialSpells = {
    },
    staticSpells = {
        [3] = "冰霜震击",
        [4] = "地震术",
        [5] = "烈焰震击",
        [6] = "治疗链",
        [7] = "次级治疗波",
        [8] = "治疗波",
        [9] = "火焰新星",
        [10] = "闪电链",
        [11] = "闪电箭",
        [12] = "风怒武器",
        [13] = "冰封武器",
        [14] = "火舌武器",
        [15] = "石化武器",
    },
}








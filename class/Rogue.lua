if UnitClassBase("player") ~= "ROGUE" then return end
local addon, ns = ...

--[[
    class/Rogue.lua — 无限服(1.60.1 / Interface 16001)版 · 像素块布局
    ------------------------------------------------------------------
    像素块布局已按无限服规范排好，**决策逻辑在 Arasaka/class/rogue_logic.py**
    （run_rogue_logic），config.yml 的专精段与 keymap/rogue.yml 都已配好。
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
      29-57  技能（按学习等级排序，共 29 个）
      58    队伍块起点（每人 生命值 / 职责（无驱散））
      58+1 起  预留给该职业特有的光环块

    技能名来自 endgametools 的无限服职业法术页（经典 60 级技能组 + 天赋）。
    改布局时三处必须同步：
      1. 改下面的索引表
      2. 改 Arasaka/config.yml 对应专精段的 step
      3. 重跑 _work/test_layouts_all.py（查 start/num/字段/块尾/区间重叠）
    决策逻辑在 Arasaka/class/rogue_logic.py，不在本文件。
]]

local function buildBlocks()
    return {
        powerType = "ENERGY",
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
        [29] = { type = "spell", name = "刺骨" },  -- 天赋解锁（未点天赋时写 255）
        [30] = { type = "spell", name = "潜行" },
        [31] = { type = "spell", name = "转嫁" },
        [32] = { type = "spell", name = "邪恶攻击" },  -- 天赋解锁（未点天赋时写 255）
        [33] = { type = "spell", name = "搜索" },
        [34] = { type = "spell", name = "背刺" },
        [35] = { type = "spell", name = "凿击" },
        [36] = { type = "spell", name = "闪避" },
        [37] = { type = "spell", name = "切割" },
        [38] = { type = "spell", name = "疾跑" },
        [39] = { type = "spell", name = "闷棍" },
        [40] = { type = "spell", name = "脚踢" },
        [41] = { type = "spell", name = "破甲" },
        [42] = { type = "spell", name = "绞喉" },
        [43] = { type = "spell", name = "佯攻" },
        [44] = { type = "spell", name = "伏击" },
        [45] = { type = "spell", name = "蓄势待发" },
        [46] = { type = "spell", name = "割裂" },
        [47] = { type = "spell", name = "扰乱" },
        [48] = { type = "spell", name = "消失" },
        [49] = { type = "spell", name = "侦测陷阱" },
        [50] = { type = "spell", name = "刺击" },
        [51] = { type = "spell", name = "偷袭" },
        [52] = { type = "spell", name = "肾击" },
        [53] = { type = "spell", name = "解除陷阱" },
        [54] = { type = "spell", name = "致盲" },
        [55] = { type = "spell", name = "安全降落" },  -- 天赋解锁（未点天赋时写 255）
        [56] = { type = "spell", name = "死亡印记" },  -- 天赋解锁（未点天赋时写 255）
        [57] = { type = "spell", name = "毁伤" },  -- 天赋解锁（未点天赋时写 255）

        -- 队伍块：每人 生命值 / 职责（无驱散）
        -- 队伍块必须排在技能块之外，config.yml 的 group.start 与这里要一致
        [58] = {
            type = "group",
            num = 2,
            healthPercent = 1,
            role = 2,
            auras = {},
        },
    }
end

CyberDeck.ClassBlocks = {
    [1] = buildBlocks(), -- 狂徒
    [2] = buildBlocks(), -- 敏锐
    [3] = buildBlocks(), -- 刺杀
}

-- 宏表：dynamicSpells 每个技能占 30 个宏位（@raid1 / @partyN），
-- staticSpells 是单键宏；特殊宏体（以 / 开头）放 specialSpells。
-- 宏位总数上限 = 7 组修饰键 x 39 键 = 273，
-- 动态技能数 x 30 + 静态数 不能超过 273。
CyberDeck.MacrosList = {
    dynamicSpells = {},
    specialSpells = {
        [12] = "/startattack [harm,nodead]",
    },
    staticSpells = {
        [1] = "消失",
        [2] = "闷棍",
        [3] = "肾击",
        [4] = "致盲",
        [5] = "割裂",
        [6] = "毁伤",
        [7] = "刺击",
        [8] = "刺骨",
        [9] = "伏击",
        [10] = "疾跑",
        [11] = "闪避",
    },
}








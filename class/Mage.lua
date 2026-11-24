if UnitClassBase("player") ~= "MAGE" then return end
local addon, ns = ...

--[[
    class/Mage.lua — 无限服(1.60.1 / Interface 16001)版 · 像素块布局
    ------------------------------------------------------------------
    像素块布局已按无限服规范排好，**决策逻辑在 Arasaka/class/mage_logic.py**
    （run_mage_logic），config.yml 的专精段与 keymap/mage.yml 都已配好。
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
      29-82  技能（按学习等级排序，共 54 个）
      83    队伍块起点（每人 生命值 / 职责 / 诅咒）
      83+1 起  预留给该职业特有的光环块

    技能名来自 endgametools 的无限服职业法术页（经典 60 级技能组 + 天赋）。
    改布局时三处必须同步：
      1. 改下面的索引表
      2. 改 Arasaka/config.yml 对应专精段的 step
      3. 重跑 _work/test_layouts_all.py（查 start/num/字段/块尾/区间重叠）
    决策逻辑在 Arasaka/class/mage_logic.py，不在本文件。
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
        [29] = { type = "spell", name = "奥术智慧" },
        [30] = { type = "spell", name = "火球术" },  -- 天赋解锁（未点天赋时写 255）
        [31] = { type = "spell", name = "霜甲术" },  -- 天赋解锁（未点天赋时写 255）
        [32] = { type = "spell", name = "寒冰箭" },
        [33] = { type = "spell", name = "造水术" },
        [34] = { type = "spell", name = "火焰冲击" },
        [35] = { type = "spell", name = "造食术" },
        [36] = { type = "spell", name = "变形术" },
        [37] = { type = "spell", name = "奥术飞弹" },
        [38] = { type = "spell", name = "冰霜新星" },
        [39] = { type = "spell", name = "缓落术" },
        [40] = { type = "spell", name = "魔法抑制" },
        [41] = { type = "spell", name = "魔爆术" },
        [42] = { type = "spell", name = "烈焰风暴" },
        [43] = { type = "spell", name = "解除次级诅咒" },
        [44] = { type = "spell", name = "魔法增效" },
        [45] = { type = "spell", name = "传送：奥格瑞玛" },
        [46] = { type = "spell", name = "传送：幽暗城" },
        [47] = { type = "spell", name = "传送：暴风城" },
        [48] = { type = "spell", name = "传送：铁炉堡" },
        [49] = { type = "spell", name = "唤醒" },
        [50] = { type = "spell", name = "暴风雪" },
        [51] = { type = "spell", name = "法力护盾" },
        [52] = { type = "spell", name = "闪现术" },
        [53] = { type = "spell", name = "防护火焰结界" },
        [54] = { type = "spell", name = "灼烧" },
        [55] = { type = "spell", name = "防护冰霜结界" },
        [56] = { type = "spell", name = "法术反制" },
        [57] = { type = "spell", name = "炎爆术" },
        [58] = { type = "spell", name = "冰锥术" },
        [59] = { type = "spell", name = "冰枪术" },
        [60] = { type = "spell", name = "制造魔法玛瑙" },
        [61] = { type = "spell", name = "传送：达纳苏斯" },
        [62] = { type = "spell", name = "传送：雷霆崖" },
        [63] = { type = "spell", name = "冰甲术" },
        [64] = { type = "spell", name = "奥术冲击" },
        [65] = { type = "spell", name = "魔甲术" },
        [66] = { type = "spell", name = "冲击波" },
        [67] = { type = "spell", name = "奥术愤怒" },
        [68] = { type = "spell", name = "制造魔法翡翠" },
        [69] = { type = "spell", name = "传送门：奥格瑞玛" },  -- 天赋解锁（未点天赋时写 255）
        [70] = { type = "spell", name = "传送门：幽暗城" },  -- 天赋解锁（未点天赋时写 255）
        [71] = { type = "spell", name = "传送门：暴风城" },  -- 天赋解锁（未点天赋时写 255）
        [72] = { type = "spell", name = "传送门：铁炉堡" },  -- 天赋解锁（未点天赋时写 255）
        [73] = { type = "spell", name = "霜火之箭" },  -- 天赋解锁（未点天赋时写 255）
        [74] = { type = "spell", name = "寒冰护体" },  -- 天赋解锁（未点天赋时写 255）
        [75] = { type = "spell", name = "制造魔法黄水晶" },  -- 天赋解锁（未点天赋时写 255）
        [76] = { type = "spell", name = "传送门：达纳苏斯" },  -- 天赋解锁（未点天赋时写 255）
        [77] = { type = "spell", name = "传送门：雷霆崖" },  -- 天赋解锁（未点天赋时写 255）
        [78] = { type = "spell", name = "传送：达拉然" },  -- 天赋解锁（未点天赋时写 255）
        [79] = { type = "spell", name = "奥术光辉" },  -- 天赋解锁（未点天赋时写 255）
        [80] = { type = "spell", name = "制造魔法红宝石" },  -- 天赋解锁（未点天赋时写 255）
        [81] = { type = "spell", name = "变形术：奶牛" },  -- 天赋解锁（未点天赋时写 255）
        [82] = { type = "spell", name = "魔火" },  -- 天赋解锁（未点天赋时写 255）

        -- 队伍块：每人 生命值 / 职责 / 诅咒
        -- 队伍块必须排在技能块之外，config.yml 的 group.start 与这里要一致
        [83] = {
            type = "group",
            num = 3,
            healthPercent = 1,
            role = 2,
            dispelCurse = 3,
            auras = {},
        },
    }
end

CyberDeck.ClassBlocks = {
    [1] = buildBlocks(), -- 奥术
    [2] = buildBlocks(), -- 火焰
    [3] = buildBlocks(), -- 冰霜
}

-- 宏表：dynamicSpells 每个技能占 30 个宏位（@raid1 / @partyN），
-- staticSpells 是单键宏；特殊宏体（以 / 开头）放 specialSpells。
-- 宏位总数上限 = 7 组修饰键 x 39 键 = 273，
-- 动态技能数 x 30 + 静态数 不能超过 273。
CyberDeck.MacrosList = {
    dynamicSpells = { "解除次级诅咒" },
    specialSpells = {
    },
    staticSpells = {
        [1] = "冰枪术",
        [2] = "冰锥术",
        [3] = "炎爆术",
        [4] = "法术反制",
        [5] = "暴风雪",
        [6] = "烈焰风暴",
        [7] = "奥术飞弹",
        [8] = "魔爆术",
        [9] = "火球术",
        [10] = "灼烧",
        [11] = "寒冰箭",
        [12] = "冰霜新星",
        [13] = "闪现术",
    },
}








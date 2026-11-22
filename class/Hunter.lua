if UnitClassBase("player") ~= "HUNTER" then return end
local addon, ns = ...

--[[
    class/Hunter.lua — 无限服(1.60.1 / Interface 16001)版 · 骨架
    ------------------------------------------------------------------
    ⚠️ 本文件是**骨架**：像素块布局已按无限服规范排好，但**决策逻辑还没写**。
       对应的 Arasaka/class/hunter_logic.py 尚未实现，因此装了插件也不会有动作。

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
      29-85  技能（按学习等级排序，共 57 个）
      86    队伍块起点（每人 生命值 / 职责（无驱散））
      86+1 起  预留给该职业特有的光环块

    技能名来自 endgametools 的无限服职业法术页（经典 60 级技能组 + 天赋）。
    要接决策层时：
      1. 在 Arasaka/class/hunter_logic.py 实现 run_hunter_logic(state_dict, spec_name)
      2. 在 Arasaka/config.yml 加 <职业ID>/<专精ID> 段（spells 的键名 = 下面的中文名）
      3. 在 Arasaka/keymap/hunter.yml 建热键表
      4. 写 Progress/hunter.md 记录该职业的像素索引与决策优先级
]]

local function buildBlocks()
    return {
        powerType = "FOCUS",
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
        [29] = { type = "spell", name = "猛禽一击" },  -- 天赋解锁（未点天赋时写 255）
        [30] = { type = "spell", name = "自动射击" },  -- 天赋解锁（未点天赋时写 255）
        [31] = { type = "spell", name = "蝰蛇守护" },
        [32] = { type = "spell", name = "追踪野兽" },
        [33] = { type = "spell", name = "雄狮之心" },
        [34] = { type = "spell", name = "毒蛇钉刺" },
        [35] = { type = "spell", name = "灵猴守护" },
        [36] = { type = "spell", name = "奥术射击" },
        [37] = { type = "spell", name = "猎人印记" },
        [38] = { type = "spell", name = "震荡射击" },
        [39] = { type = "spell", name = "召唤宠物" },
        [40] = { type = "spell", name = "喂养宠物" },
        [41] = { type = "spell", name = "复活宠物" },
        [42] = { type = "spell", name = "解散野兽" },
        [43] = { type = "spell", name = "追踪人型生物" },
        [44] = { type = "spell", name = "雄鹰守护" },
        [45] = { type = "spell", name = "驯服野兽" },
        [46] = { type = "spell", name = "扰乱射击" },
        [47] = { type = "spell", name = "摔绊" },
        [48] = { type = "spell", name = "治疗宠物" },
        [49] = { type = "spell", name = "恐吓野兽" },
        [50] = { type = "spell", name = "野兽之眼" },
        [51] = { type = "spell", name = "鹰眼术" },
        [52] = { type = "spell", name = "猫鼬撕咬" },
        [53] = { type = "spell", name = "献祭陷阱" },
        [54] = { type = "spell", name = "多重射击" },
        [55] = { type = "spell", name = "追踪亡灵" },
        [56] = { type = "spell", name = "冰冻陷阱" },
        [57] = { type = "spell", name = "猎豹守护" },
        [58] = { type = "spell", name = "瞄准射击" },
        [59] = { type = "spell", name = "逃脱" },
        [60] = { type = "spell", name = "毒蝎钉刺" },
        [61] = { type = "spell", name = "追踪隐藏生物" },
        [62] = { type = "spell", name = "野兽知识" },
        [63] = { type = "spell", name = "急速射击" },
        [64] = { type = "spell", name = "追踪元素生物" },
        [65] = { type = "spell", name = "冰霜陷阱" },
        [66] = { type = "spell", name = "假死" },
        [67] = { type = "spell", name = "割伤" },
        [68] = { type = "spell", name = "反击" },
        [69] = { type = "spell", name = "野兽守护" },
        [70] = { type = "spell", name = "强击光环" },
        [71] = { type = "spell", name = "照明弹" },
        [72] = { type = "spell", name = "追踪恶魔" },
        [73] = { type = "spell", name = "魔化照明弹" },
        [74] = { type = "spell", name = "爆炸陷阱" },
        [75] = { type = "spell", name = "召唤雄鹰" },
        [76] = { type = "spell", name = "蝰蛇钉刺" },
        [77] = { type = "spell", name = "乱射" },  -- 天赋解锁（未点天赋时写 255）
        [78] = { type = "spell", name = "豹群守护" },  -- 天赋解锁（未点天赋时写 255）
        [79] = { type = "spell", name = "追踪巨人" },  -- 天赋解锁（未点天赋时写 255）
        [80] = { type = "spell", name = "野性守护" },  -- 天赋解锁（未点天赋时写 255）
        [81] = { type = "spell", name = "狙击" },  -- 天赋解锁（未点天赋时写 255）
        [82] = { type = "spell", name = "追踪龙类" },  -- 天赋解锁（未点天赋时写 255）
        [83] = { type = "spell", name = "黑箭" },  -- 天赋解锁（未点天赋时写 255）
        [84] = { type = "spell", name = "宁神射击" },  -- 天赋解锁（未点天赋时写 255）
        [85] = { type = "spell", name = "猎鹰守护" },  -- 天赋解锁（未点天赋时写 255）

        -- 队伍块：每人 生命值 / 职责（无驱散）
        -- 队伍块必须排在技能块之外，config.yml 的 group.start 与这里要一致
        [86] = {
            type = "group",
            num = 2,
            healthPercent = 1,
            role = 2,
            auras = {},
        },
    }
end

CyberDeck.ClassBlocks = {
    [1] = buildBlocks(), -- 野兽控制
    [2] = buildBlocks(), -- 射击
    [3] = buildBlocks(), -- 生存
}

-- 宏表：dynamicSpells 每个技能占 30 个宏位（@raid1 / @partyN），
-- staticSpells 是单键宏；特殊宏体（以 / 开头）放 specialSpells。
-- 宏位总数上限 = 7 组修饰键 x 39 键 = 273，
-- 动态技能数 x 30 + 静态数 不能超过 273。
CyberDeck.MacrosList = {
    dynamicSpells = {},
    specialSpells = {
    },
    staticSpells = {
        [1] = "狙击",
        [2] = "震荡射击",
        [3] = "逃脱",
        [4] = "假死",
        [5] = "多重射击",
        [6] = "瞄准射击",
        [7] = "急速射击",
        [8] = "乱射",
        [9] = "猛禽一击",
        [10] = "自动射击",
        [11] = "毒蛇钉刺",
        [12] = "奥术射击",
        [13] = "猎人印记",
        [14] = "强击光环",
    },
}








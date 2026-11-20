if UnitClassBase("player") ~= "WARLOCK" then return end
local addon, ns = ...

--[[
    class/Warlock.lua — 无限服(1.60.1 / Interface 16001)版 · 骨架
    ------------------------------------------------------------------
    ⚠️ 本文件是**骨架**：像素块布局已按无限服规范排好，但**决策逻辑还没写**。
       对应的 Arasaka/class/warlock_logic.py 尚未实现，因此装了插件也不会有动作。

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
      29-75  技能（按学习等级排序，共 47 个）
      76    队伍块起点（每人 num 格：生命值/职责/驱散）
      76+1 起  预留给该职业特有的光环块

    技能名来自 endgametools 的无限服职业法术页（经典 60 级技能组 + 天赋）。
    要接决策层时：
      1. 在 Arasaka/class/warlock_logic.py 实现 run_warlock_logic(state_dict, spec_name)
      2. 在 Arasaka/config.yml 加 <职业ID>/<专精ID> 段（spells 的键名 = 下面的中文名）
      3. 在 Arasaka/keymap/warlock.yml 建热键表
      4. 写 Progress/warlock.md 记录该职业的像素索引与决策优先级
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
        [29] = { type = "spell", name = "召唤小鬼" },
        [30] = { type = "spell", name = "恶魔皮肤" },  -- 天赋解锁（未点天赋时写 255）
        [31] = { type = "spell", name = "暗影箭" },  -- 天赋解锁（未点天赋时写 255）
        [32] = { type = "spell", name = "献祭" },
        [33] = { type = "spell", name = "腐蚀术" },
        [34] = { type = "spell", name = "虚弱诅咒" },
        [35] = { type = "spell", name = "生命分流" },
        [36] = { type = "spell", name = "恐惧术" },
        [37] = { type = "spell", name = "痛苦灾祸" },
        [38] = { type = "spell", name = "制造治疗石" },
        [39] = { type = "spell", name = "召唤虚空行者" },
        [40] = { type = "spell", name = "吸取灵魂" },
        [41] = { type = "spell", name = "生命通道" },
        [42] = { type = "spell", name = "吸取生命" },
        [43] = { type = "spell", name = "鲁莽诅咒" },
        [44] = { type = "spell", name = "魔息术" },
        [45] = { type = "spell", name = "制造灵魂石" },
        [46] = { type = "spell", name = "灼热之痛" },
        [47] = { type = "spell", name = "元素诅咒" },
        [48] = { type = "spell", name = "召唤仪式" },
        [49] = { type = "spell", name = "召唤夜魔" },
        [50] = { type = "spell", name = "召唤魅魔" },
        [51] = { type = "spell", name = "火焰之雨" },
        [52] = { type = "spell", name = "魔甲术" },
        [53] = { type = "spell", name = "基尔罗格之眼" },
        [54] = { type = "spell", name = "吸取法力" },
        [55] = { type = "spell", name = "感知恶魔" },
        [56] = { type = "spell", name = "暗影灼烧" },
        [57] = { type = "spell", name = "侦测隐形" },
        [58] = { type = "spell", name = "语言诅咒" },
        [59] = { type = "spell", name = "制造火焰石" },
        [60] = { type = "spell", name = "放逐术" },
        [61] = { type = "spell", name = "召唤地狱猎犬" },
        [62] = { type = "spell", name = "地狱烈焰" },
        [63] = { type = "spell", name = "征服恶魔" },
        [64] = { type = "spell", name = "燃烧" },
        [65] = { type = "spell", name = "防护暗影结界" },
        [66] = { type = "spell", name = "制造法术石" },
        [67] = { type = "spell", name = "生命虹吸" },
        [68] = { type = "spell", name = "恐惧嚎叫" },  -- 天赋解锁（未点天赋时写 255）
        [69] = { type = "spell", name = "死亡缠绕" },  -- 天赋解锁（未点天赋时写 255）
        [70] = { type = "spell", name = "灵魂之火" },  -- 天赋解锁（未点天赋时写 255）
        [71] = { type = "spell", name = "地狱火" },  -- 天赋解锁（未点天赋时写 255）
        [72] = { type = "spell", name = "烧尽" },  -- 天赋解锁（未点天赋时写 255）
        [73] = { type = "spell", name = "召唤传送门" },  -- 天赋解锁（未点天赋时写 255）
        [74] = { type = "spell", name = "末日仪式" },  -- 天赋解锁（未点天赋时写 255）
        [75] = { type = "spell", name = "末日灾祸" },  -- 天赋解锁（未点天赋时写 255）

        -- 队伍块：每人 num 格（生命值 / 职责 / 驱散）
        -- 队伍块必须排在技能块之外，config.yml 的 group.start 与这里要一致
        [76] = {
            type = "group",
            num = 3,
            healthPercent = 1,
            role = 2,
            dispel = 3,
            auras = {},
        },
    }
end

CyberDeck.ClassBlocks = {
    [1] = buildBlocks(), -- 痛苦
    [2] = buildBlocks(), -- 恶魔学识
    [3] = buildBlocks(), -- 毁灭
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
        [1] = "恐惧术",
        [2] = "末日灾祸",
        [3] = "灵魂之火",
        [4] = "烧尽",
        [5] = "暗影箭",
        [6] = "献祭",
        [7] = "腐蚀术",
        [8] = "灼热之痛",
    },
}








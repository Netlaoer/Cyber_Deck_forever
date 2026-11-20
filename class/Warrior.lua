if UnitClassBase("player") ~= "WARRIOR" then return end
local addon, ns = ...

--[[
    class/Warrior.lua — 无限服(1.60.1 / Interface 16001)版 · 骨架
    ------------------------------------------------------------------
    ⚠️ 本文件是**骨架**：像素块布局已按无限服规范排好，但**决策逻辑还没写**。
       对应的 Arasaka/class/warrior_logic.py 尚未实现，因此装了插件也不会有动作。

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
      29-64  技能（按学习等级排序，共 36 个）
      65    队伍块起点（每人 num 格：生命值/职责/驱散）
      65+1 起  预留给该职业特有的光环块

    技能名来自 endgametools 的无限服职业法术页（经典 60 级技能组 + 天赋）。
    要接决策层时：
      1. 在 Arasaka/class/warrior_logic.py 实现 run_warrior_logic(state_dict, spec_name)
      2. 在 Arasaka/config.yml 加 <职业ID>/<专精ID> 段（spells 的键名 = 下面的中文名）
      3. 在 Arasaka/keymap/warrior.yml 建热键表
      4. 写 Progress/warrior.md 记录该职业的像素索引与决策优先级
]]

local function buildBlocks()
    return {
        powerType = "RAGE",
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
        [29] = { type = "spell", name = "战斗姿态" },  -- 天赋解锁（未点天赋时写 255）
        [30] = { type = "spell", name = "战斗怒吼" },
        [31] = { type = "spell", name = "英勇打击" },  -- 天赋解锁（未点天赋时写 255）
        [32] = { type = "spell", name = "冲锋" },
        [33] = { type = "spell", name = "撕裂" },
        [34] = { type = "spell", name = "雷霆一击" },
        [35] = { type = "spell", name = "断筋" },
        [36] = { type = "spell", name = "嘲讽" },
        [37] = { type = "spell", name = "破甲攻击" },
        [38] = { type = "spell", name = "血性狂暴" },
        [39] = { type = "spell", name = "防御姿态" },
        [40] = { type = "spell", name = "压制" },
        [41] = { type = "spell", name = "盾击" },
        [42] = { type = "spell", name = "复仇" },
        [43] = { type = "spell", name = "战术掌握" },
        [44] = { type = "spell", name = "挫志怒吼" },
        [45] = { type = "spell", name = "惩戒痛击" },
        [46] = { type = "spell", name = "盾牌格挡" },
        [47] = { type = "spell", name = "缴械" },
        [48] = { type = "spell", name = "乘胜追击" },
        [49] = { type = "spell", name = "反击风暴" },
        [50] = { type = "spell", name = "猛击" },
        [51] = { type = "spell", name = "顺劈斩" },
        [52] = { type = "spell", name = "破胆怒吼" },
        [53] = { type = "spell", name = "斩杀" },
        [54] = { type = "spell", name = "挑战怒吼" },
        [55] = { type = "spell", name = "盾墙" },
        [56] = { type = "spell", name = "拦截" },
        [57] = { type = "spell", name = "狂暴之怒" },
        [58] = { type = "spell", name = "狂暴姿态" },
        [59] = { type = "spell", name = "旋风斩" },
        [60] = { type = "spell", name = "拳击" },
        [61] = { type = "spell", name = "嗜血" },  -- 天赋解锁（未点天赋时写 255）
        [62] = { type = "spell", name = "盾牌猛击" },  -- 天赋解锁（未点天赋时写 255）
        [63] = { type = "spell", name = "致死打击" },  -- 天赋解锁（未点天赋时写 255）
        [64] = { type = "spell", name = "鲁莽" },  -- 天赋解锁（未点天赋时写 255）

        -- 队伍块：每人 num 格（生命值 / 职责 / 驱散）
        -- 队伍块必须排在技能块之外，config.yml 的 group.start 与这里要一致
        [65] = {
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
    [1] = buildBlocks(), -- 武器
    [2] = buildBlocks(), -- 狂怒
    [3] = buildBlocks(), -- 防护
}

-- 宏表：dynamicSpells 每个技能占 30 个宏位（@raid1 / @partyN），
-- staticSpells 是单键宏；特殊宏体（以 / 开头）放 specialSpells。
-- 宏位总数上限 = 7 组修饰键 x 39 键 = 273，
-- 动态技能数 x 30 + 静态数 不能超过 273。
CyberDeck.MacrosList = {
    dynamicSpells = {},
    specialSpells = {
        [19] = "/startattack [harm,nodead]",
    },
    staticSpells = {
        [1] = "斩杀",
        [2] = "盾牌猛击",
        [3] = "盾击",
        [4] = "盾牌格挡",
        [5] = "致死打击",
        [6] = "挑战怒吼",
        [7] = "反击风暴",
        [8] = "猛击",
        [9] = "破胆怒吼",
        [10] = "乘胜追击",
        [11] = "顺劈斩",
        [12] = "狂暴之怒",
        [13] = "嗜血",
        [14] = "拦截",
        [15] = "缴械",
        [16] = "撕裂",
        [17] = "鲁莽",
        [18] = "英勇打击",
    },
}








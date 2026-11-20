if UnitClassBase("player") ~= "PRIEST" then return end
local addon, ns = ...

--[[
    class/Priest.lua — 无限服(1.60.1 / Interface 16001)版 · 骨架
    ------------------------------------------------------------------
    ⚠️ 本文件是**骨架**：像素块布局已按无限服规范排好，但**决策逻辑还没写**。
       对应的 Arasaka/class/priest_logic.py 尚未实现，因此装了插件也不会有动作。

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
      29-78  技能（按学习等级排序，共 50 个）
      79    队伍块起点（每人 num 格：生命值/职责/驱散）
      79+1 起  预留给该职业特有的光环块

    技能名来自 endgametools 的无限服职业法术页（经典 60 级技能组 + 天赋）。
    要接决策层时：
      1. 在 Arasaka/class/priest_logic.py 实现 run_priest_logic(state_dict, spec_name)
      2. 在 Arasaka/config.yml 加 <职业ID>/<专精ID> 段（spells 的键名 = 下面的中文名）
      3. 在 Arasaka/keymap/priest.yml 建热键表
      4. 写 Progress/priest.md 记录该职业的像素索引与决策优先级
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
        [29] = { type = "spell", name = "惩击" },  -- 天赋解锁（未点天赋时写 255）
        [30] = { type = "spell", name = "暗影魔" },
        [31] = { type = "spell", name = "次级治疗术" },  -- 天赋解锁（未点天赋时写 255）
        [32] = { type = "spell", name = "真言术：韧" },
        [33] = { type = "spell", name = "暗言术：痛" },
        [34] = { type = "spell", name = "真言术：盾" },
        [35] = { type = "spell", name = "恢复" },
        [36] = { type = "spell", name = "渐隐术" },
        [37] = { type = "spell", name = "复活术" },
        [38] = { type = "spell", name = "心灵震爆" },
        [39] = { type = "spell", name = "星辰碎片" },
        [40] = { type = "spell", name = "神圣恩典" },
        [41] = { type = "spell", name = "绝望祷言" },
        [42] = { type = "spell", name = "虚弱之触" },
        [43] = { type = "spell", name = "虚弱妖术" },
        [44] = { type = "spell", name = "迷惑闪光" },
        [45] = { type = "spell", name = "心灵之火" },
        [46] = { type = "spell", name = "心灵尖啸" },
        [47] = { type = "spell", name = "祛病术" },
        [48] = { type = "spell", name = "治疗术" },
        [49] = { type = "spell", name = "驱散魔法" },
        [50] = { type = "spell", name = "噬灵瘟疫" },
        [51] = { type = "spell", name = "回馈" },
        [52] = { type = "spell", name = "安抚心灵" },
        [53] = { type = "spell", name = "应急方案" },
        [54] = { type = "spell", name = "快速治疗" },
        [55] = { type = "spell", name = "暗影守卫" },
        [56] = { type = "spell", name = "束缚亡灵" },
        [57] = { type = "spell", name = "神圣之火" },
        [58] = { type = "spell", name = "艾露恩的赐福" },
        [59] = { type = "spell", name = "防护恐惧结界" },
        [60] = { type = "spell", name = "黑暗献祭" },
        [61] = { type = "spell", name = "心灵视界" },
        [62] = { type = "spell", name = "法力燃烧" },
        [63] = { type = "spell", name = "神圣新星" },
        [64] = { type = "spell", name = "精神鞭笞" },
        [65] = { type = "spell", name = "治疗祷言" },
        [66] = { type = "spell", name = "神圣之灵" },
        [67] = { type = "spell", name = "精神控制" },
        [68] = { type = "spell", name = "防护暗影" },
        [69] = { type = "spell", name = "暗言术：灭" },
        [70] = { type = "spell", name = "驱除疾病" },
        [71] = { type = "spell", name = "漂浮术" },
        [72] = { type = "spell", name = "光明之泉" },  -- 天赋解锁（未点天赋时写 255）
        [73] = { type = "spell", name = "强效治疗术" },  -- 天赋解锁（未点天赋时写 255）
        [74] = { type = "spell", name = "苦修" },  -- 天赋解锁（未点天赋时写 255）
        [75] = { type = "spell", name = "坚韧祷言" },  -- 天赋解锁（未点天赋时写 255）
        [76] = { type = "spell", name = "愈合祷言" },  -- 天赋解锁（未点天赋时写 255）
        [77] = { type = "spell", name = "暗影防护祷言" },  -- 天赋解锁（未点天赋时写 255）
        [78] = { type = "spell", name = "精神祷言" },  -- 天赋解锁（未点天赋时写 255）

        -- 队伍块：每人 num 格（生命值 / 职责 / 驱散）
        -- 队伍块必须排在技能块之外，config.yml 的 group.start 与这里要一致
        [79] = {
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
    [1] = buildBlocks(), -- 戒律
    [2] = buildBlocks(), -- 圣言
    [3] = buildBlocks(), -- 暗影
}

-- 宏表：dynamicSpells 每个技能占 30 个宏位（@raid1 / @partyN），
-- staticSpells 是单键宏；特殊宏体（以 / 开头）放 specialSpells。
-- 宏位总数上限 = 7 组修饰键 x 39 键 = 273，
-- 动态技能数 x 30 + 静态数 不能超过 273。
CyberDeck.MacrosList = {
    dynamicSpells = { "驱散魔法", "祛病术" },
    specialSpells = {
    },
    staticSpells = {
        [4] = "精神鞭笞",
        [5] = "暗言术：灭",
        [6] = "暗言术：痛",
        [7] = "惩击",
        [8] = "心灵震爆",
        [9] = "噬灵瘟疫",
        [10] = "强效治疗术",
        [11] = "快速治疗",
        [12] = "治疗术",
        [13] = "次级治疗术",
        [14] = "愈合祷言",
        [15] = "安抚心灵",
        [16] = "神圣新星",
    },
}








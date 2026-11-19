if UnitClassBase("player") ~= "PALADIN" then return end
local addon, ns = ...

--[[
    class/Paladin.lua — 无限服(1.60.1 / Interface 16001)版
    ------------------------------------------------------------------
    与正式服版的区别：
    1. 技能用 name 而不是 spellId；main.lua 会在无限服按名称解析到“已学会的 rank”，
       未学会的技能自动写 255（不可用）。
    2. 没有神圣能量、圣洁鸣钟、神圣棱镜、美德道标、光环掌握、盲目之光等正式服技能；
       圣印 / 神恩术 / 圣光灌注 由 core/forever.lua 直接扫描光环写入。
    3. 三系共用同一套像素索引，队伍框都是 3 格（生命值/职责/驱散）。
    4. 索引 1-19 通用；20-29 状态；30-44 技能；45-48 开关/物品；49-64 技能；
       65-68 状态；69-75 圣印探测；76-196 队伍块；200-211 符文技能。

    索引表（1-19 与全局 state 一致，20 起为圣骑士专属；43/61/64 留空）：
      20 圣印(1正义 2命令 3十字军 4光明 5智慧 6愤怒 7公正)
      21 施法技能  22 施法目标  23 目标距离
      24 自动攻击（PLAYER_ENTER_COMBAT / PLAYER_LEAVE_COMBAT，1=平砍中）
      25 神恩术  26 圣光灌注层数  27 空（原目标审判，无限服无用已删）
      28 敌人人数  29 爆发开关
      45 大红冷却  46 延迟  47 驱散开关  48 5码敌人
      65 正义之怒  66 目标施法  67 神圣之盾CD  68 神恩术CD
      69-75 七种圣印的“是否学会”探测（69 正义 70 命令 71 十字军 72 光明 73 智慧 74 愤怒 75 公正）
      76 队伍块起点（group start，每名队友占 3 格；40 人 raid 到 196）
      198 圣印剩余秒（auras 施放计时 remaining，0 = 没挂/已到期）
          —— 不能放 77：队伍块 76 起每人 3 格，77 是 1 号队友生命值
      200-211 已删除：复仇之怒/圣洁护盾/正义盾击/神圣风暴/责难/神圣牺牲/
              殉道圣印/殉道审判/洛丹伦号角/激励典范/神圣之光/真理之音
              都是 WLK/TBC/11.x 技能，无限服 60 级经典组不提供
    9/10 蓄力：无限服没有这些机制，不建块（像素保持 0）；
    20 位原全局“英雄天赋”由圣骑士改作“圣印”，决策层不读英雄天赋
    注：全局 state 的 step 20 名为“英雄天赋”，圣骑士在该位置写“圣印”，逻辑不读英雄天赋
]]

local function buildBlocks(groupNum, groupAuras)
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
        [12] = { type = "block", name = "法术失败" },
        [13] = { type = "block", name = "目标类型" },
        [14] = { type = "block", name = "队伍类型" },
        [15] = { type = "block", name = "队伍人数" },
        [16] = { type = "block", name = "首领战" },
        [17] = { type = "block", name = "难度" },

        [18] = { type = "block", name = "圣印" },
        [19] = { type = "block", name = "施法技能" },
        [20] = { type = "block", name = "施法目标" },
        [21] = { type = "block", name = "目标距离" },
        [22] = { type = "block", name = "自动攻击" },  -- 1 = 正在近战平砍，0 = 没有
        [23] = { type = "block", name = "神恩术" },
        [24] = { type = "block", name = "圣光灌注" },
        [25] = { type = "block", name = "敌人人数" },
        [26] = { type = "block", name = "爆发开关" },

        [27] = { type = "spell", name = "制裁之锤" },
        [28] = { type = "spell", name = "圣盾术" },
        [29] = { type = "spell", name = "圣佑术" },
        [30] = { type = "spell", name = "圣疗术" },
        [31] = { type = "spell", name = "神圣震击" },
        [32] = { type = "spell", name = "审判" },
        [33] = { type = "spell", name = "奉献" },
        [34] = { type = "spell", name = "驱邪术" },
        [35] = { type = "spell", name = "愤怒之锤" },
        [36] = { type = "spell", name = "神圣打击" },
        -- [43] 正义之锤：WLK 才有的技能，无限服（60 级经典组）不存在
        [37] = { type = "spell", name = "神圣愤怒" },
        [38] = { type = "block", name = "大红冷却" },
        [39] = { type = "block", name = "延迟" },
        [40] = { type = "block", name = "驱散开关" },
        [41] = { type = "block", name = "5码敌人" },

        [42] = { type = "spell", name = "清洁术" },
        [43] = { type = "spell", name = "正义之怒" },
        [44] = { type = "spell", name = "圣光术" },
        [45] = { type = "spell", name = "圣光闪现" },

        [46] = { type = "block", name = "正义之怒" },
        [47] = { type = "block", name = "目标施法" },
        [48] = { type = "spell", name = "神圣之盾" },
        [49] = { type = "spell", name = "神恩术" },

        -- 圣印探测：只用来判断“学会没学会”（未学会写 255），不用于冷却
        [50] = { type = "spell", name = "正义圣印" },
        [51] = { type = "spell", name = "命令圣印" },
        [52] = { type = "spell", name = "十字军圣印" },
        [53] = { type = "spell", name = "光明圣印" },
        [54] = { type = "spell", name = "智慧圣印" },
        [55] = { type = "spell", name = "愤怒圣印" },
        [56] = { type = "spell", name = "公正圣印" },


        -- [200]-[211] 原为正式服（WLK/TBC/11.x）技能：复仇之怒、圣洁护盾、正义盾击、
        -- 神圣风暴、责难、神圣牺牲、殉道圣印、殉道审判、洛丹伦号角、激励典范、
        -- 神圣之光、真理之音。无限服（60 级经典组）都不存在，已删除。

        -- 圣印剩余秒：type = "aura" 会被 loadPlayerBlocks 收进 blocks.auras，
        -- 由 CyberDeck:updateAuraBlocks() 把 Auras["圣印"].remaining 写进 77 号
        -- 编号必须在队伍块范围之外：队伍块从 76 起、每人 3 格，77~196 全被占用
        -- （曾经放在 77 号，和「1 号队友生命值」抢同一像素，面板显示成 100s = 队友血量）
        [208] = { type = "aura", name = "圣印剩余", auraName = "圣印", showKey = "remaining" },

        [57] = {
            type = "group",
            num = groupNum,
            healthPercent = 1,
            role = 2,
            dispel = 3,
            auras = groupAuras,
        },
    }
end

CyberDeck.ClassBlocks = {
    -- 神圣多两个 buff 位：4 = 圣光守望(1310909)、5 = 圣光誓约(1328548)
    [1] = buildBlocks(5, { [4] = { 1310909 }, [5] = { 1328548 } }),
    [2] = buildBlocks(3), -- 防护
    [3] = buildBlocks(3), -- 惩戒
}

-- 创建圣骑士宏
-- dynamicSpells：按队伍位施放的技能，每个技能占 30 个宏位（@raid1 / @partyN）
-- staticSpells：单键宏，[@mouseover] 前缀表示鼠标指向施放；以 / 开头的值按完整宏体处理
-- 注意：宏位总数 = 7 组修饰键 x 39 键 = 273，动态技能数 x 30 + 静态数 不能超过 273
CyberDeck.MacrosList = {
    -- 圣光誓约必须能挂队友，只能走动态宏（@raidN）。这会把动态位从 150 涨到 180，
    -- 静态技能整体后移 30 格，动作条需要重摆一次。
    dynamicSpells = { "圣光术", "圣光闪现", "神圣震击", "清洁术", "圣疗术", "圣光誓约", "圣光守望" },
    -- specialSpells 里是**完整宏体**（不拼 /cast），与 staticSpells 同位置时优先。
    -- /startattack 不占 GCD，[harm,nodead] 保证对无效目标不产生红字报错。
    specialSpells = {
        -- special 与 static 同槽位时 special 优先
        [33] = "/startattack [harm,nodead]",
    },
    staticSpells = {
        [1] = "审判",
        [2] = "奉献",
        [3] = "神圣打击",
        [4] = "驱邪术",
        [5] = "愤怒之锤",
        [6] = "制裁之锤",
        [7] = "圣盾术",
        [8] = "圣佑术",
        [9] = "[@player]圣疗术",
        [10] = "神恩术",
        [11] = "正义之怒",
        [12] = "神圣之盾",
        [13] = "圣殿骑士壁垒",
        [14] = "迅捷审判",
        [15] = "正义圣印",
        [16] = "命令圣印",
        [17] = "十字军圣印",
        [18] = "光明圣印",
        [19] = "智慧圣印",
        [20] = "愤怒圣印",
        [21] = "公正圣印",
        [22] = "[@mouseover]保护祝福",
        [23] = "[@mouseover]自由祝福",
        [24] = "[@mouseover]牺牲祝福",
        [25] = "超度亡灵",
        [26] = "神圣愤怒",
        [27] = "忏悔",
        [28] = "救赎",
        [29] = "神圣干涉",
        [30] = "王者祝福",
        [31] = "智慧祝福",
        [32] = "力量祝福",
        -- 清洁术的"对目标/鼠标指向"版本（动态宏只覆盖 @raid1~30）
        [34] = "[@mouseover]清洁术",
    },
}

if UnitClassBase("player") ~= "PALADIN" then return end
local addon, ns = ...

--[[
    class/Paladin.lua — 无限服(1.60.1 / Interface 16001)版
    ------------------------------------------------------------------
    与正式服版的区别：
    1. 技能用 name 而不是 spellId；main.lua 按名称解析到“已学会的 rank”，
       未学会的技能自动写 255（不可用）。
    2. 没有神圣能量、圣洁鸣钟、神圣棱镜、美德道标、光环掌握、盲目之光等正式服技能；
       圣印 / 神恩术 / 圣光灌注 由 core/forever.lua 直接扫描光环写入。
    3. 三系共用同一套像素索引，只有队伍块长度不同（神圣 7 格 / 防护、惩戒 5 格）。

    索引表：
      1-15   通用（与全局 state 一致，11 = 目标生命值）
      18-26  圣骑士状态（圣印/施法技能/施法目标/目标距离/自动攻击/神恩术/
             圣光灌注/敌人人数/爆发开关）
      27-36  技能；38-41 状态（大红冷却/延迟/驱散开关/5码敌人）
      42-45  技能；46-47 状态（正义之怒/目标施法）；48-49 技能
      50-56  七种圣印的“是否学会”探测（未学会写 255，不用于冷却）
      57     队伍块起点：每人 num 格
               1 生命值 / 2 职责 / 3 魔法 / 4 疾病 / 5 中毒
               神圣额外 6 圣光守望、7 圣光誓约
             40 人 × 7 格占 58~337（updateGroup 不封顶，按 GetNumGroupMembers 走）
      338    圣印剩余秒（auras 施放计时 remaining）
             —— 必须排在队伍块之外
]]

local DISPEL_FIELD_BY_TYPE = {
    Magic = "dispelMagic",
    Curse = "dispelCurse",
    Disease = "dispelDisease",
    Poison = "dispelPoison",
    Bleed = "dispelBleed",
}

local function buildBlocks(dispelTypes, groupAuras)
    -- 队伍块：每人 num 格（生命值 / 职责 / 各驱散类型 / 光环）
    -- 驱散格与 Shingen 同款：**每个能驱的类型各占一格**，蓝通道写「同类最长剩余秒数」
    -- （0 = 没有，1 = 不足一秒，255 = 超过 255 秒或永久）。
    -- 圣骑士只能驱 魔法/疾病/中毒，所以只建这三格；诅咒/流血不建，省 2 格/人。
    local group = {
        type = "group",
        healthPercent = 1,
        role = 2,
    }
    local num = 2
    for _, typeName in ipairs(dispelTypes) do
        num = num + 1
        group[DISPEL_FIELD_BY_TYPE[typeName]] = num
    end
    for offset in pairs(groupAuras or {}) do
        if offset > num then num = offset end
    end
    group.num = num
    group.auras = groupAuras

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
        -- 11 号原来放正式服的「一键辅助」，删掉后空出来给「目标生命值」。
        [11] = { type = "block", name = "目标生命值" },
        [12] = { type = "block", name = "法术失败" },
        [13] = { type = "block", name = "目标类型" },
        [14] = { type = "block", name = "队伍类型" },
        [15] = { type = "block", name = "队伍人数" },

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


        -- 圣印剩余秒：type = "aura" 会被 loadPlayerBlocks 收进 blocks.auras，
        -- 由 CyberDeck:updateAuraBlocks() 把 Auras["圣印"].remaining 写进来。
        -- 编号必须排在队伍块之外：40 人 × 7 格占到 337。
        [338] = { type = "aura", name = "圣印剩余", auraName = "圣印", showKey = "remaining" },

        -- 鼠标可驱：引擎写（绑 mouseover 的 AuraContainer，本职业能驱的几类取剩余最长），
        -- > 0 = 鼠标指向的人身上有本职业能驱的减益。战斗中同样有效（引擎算，不读光环）。
        [339] = { type = "block", name = "鼠标可驱" },

        [57] = group,
    }
end

CyberDeck.ClassBlocks = {
    -- 驱散格：只列本职业真能驱的类型（圣骑士 = 清洁术 4987：魔法/疾病/中毒）。
    -- 神圣多两个 buff 位：6 = 圣光守望(1310909)、7 = 圣光誓约(1328548)
    [1] = buildBlocks({ "Magic", "Disease", "Poison" },
        { [6] = { 1310909 }, [7] = { 1328548 } }),
    [2] = buildBlocks({ "Magic", "Disease", "Poison" }), -- 防护
    [3] = buildBlocks({ "Magic", "Disease", "Poison" }), -- 惩戒
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
        -- 防护的"鼠标指向驱散"（关闭 /cy dispel 时使用）
        [34] = "[@mouseover]清洁术",
    },
}

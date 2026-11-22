local addon, ns = ...
local isSec = issecretvalue

-- UNIT_AURA 的 info 字段（isFullUpdate / addedAuras / updated... / removed...）
-- 在战斗中全是 secret。直接 `if info.x then` 会抛
-- "attempt to perform boolean test on field 'isFullUpdate' (a secret boolean value)"。
-- 统一取真值：读不到就返回 false，等价于"这次事件没有这一项"。
local function safeTruthy(v)
    if type(isSec) == "function" and isSec(v) then return false end
    return v and true or false
end
local GetSpellCooldownDuration = C_Spell.GetSpellCooldownDuration
local GetSpellChargeDuration = C_Spell.GetSpellChargeDuration
local GetSpellCooldown = C_Spell.GetSpellCooldown
local GetSpellName = C_Spell.GetSpellName
local IsSpellKnown = C_SpellBook.IsSpellKnown
local EvaluateColorFromBoolean = C_CurveUtil.EvaluateColorFromBoolean or function(cond, trueColor, falseColor)
    return cond and trueColor or falseColor
end
local rc = LibStub("LibRangeCheck-3.0")

local state = CyberDeck.state
local blocks = CyberDeck.blocks
local target = CyberDeck.target
local focus = CyberDeck.focus
local nameplate = CyberDeck.nameplate
local group = CyberDeck.group
local groupList = CyberDeck.groupList
local spells = {}
local failedSpell, failedSpellId, failedSpellTimer, updateIndex = nil, nil, nil, 1
local roleMap, EnumPowerType = CyberDeck.roleMap, CyberDeck.EnumPowerType
-- 施法失败要重试的技能（按名字判定：无限服法术 ID 随 rank 变，ID 表用不了）
local FAILED_RETRY = {
    ["自由祝福"] = true,
    ["制裁之锤"] = true,
    ["圣盾术"] = true,
}
local fallbackColor, falseValueBlack, falseValueWhite = CreateColor(0, 0, 1, 1), CreateColor(0, 0, 0, 1),
    CreateColor(0, 0, 1, 1)

-- ================================================================
--                          创建颜色曲线
-- ================================================================
local curveCache = {}

local function creatColorCurveScaling(b)
    if curveCache[b] then
        return curveCache[b]
    end
    local curve = C_CurveUtil.CreateColorCurve()
    curve:SetType(Enum.LuaCurveType.Linear)
    if b > 100 then
        curve:AddPoint(0, CreateColor(0, 0, (b - 100) / 255, 1))
        curve:AddPoint(1, CreateColor(0, 0, b / 255, 1))
    else
        local z = (100 - b) / 100
        curve:AddPoint(0, CreateColor(0, 0, 0, 1))
        curve:AddPoint(z, CreateColor(0, 0, 1 / 255, 1))
        curve:AddPoint(1, CreateColor(0, 0, b / 255, 1))
    end
    curveCache[b] = curve
    return curve
end

local curve100 = creatColorCurveScaling(100)
local curve255 = CyberDeck:creatColorCurve(255, 255)
local castCurve = CyberDeck:creatColorCurve(2.55, 255)

local powerCurve = {}
function CyberDeck:CreatPowerCurve(powerType)
    if powerCurve[powerType] then return end
    local powerMax = UnitPowerMax("player", EnumPowerType[powerType])
    if powerMax >= 250 then
        powerCurve[powerType] = self:creatColorCurve(1, 100)
    else
        powerCurve[powerType] = self:creatColorCurve(1, powerMax)
    end
end

-- 单体读条治疗法术
-- 施法目标的生命值增加值,防止对同一个目标重复施法,导致过量治疗
local helpfulSpells = {
    [2061] = 15,    -- 快速治疗
    [1262763] = 15, -- 祈福
    [82326] = 40,   -- 圣光术
    [19750] = 15,   -- 圣光闪现
    [8936] = 15,    -- 愈合
    [186263] = 50,  -- 暗影愈合
    [77472] = 15,   -- 治疗波
}

target.enemyCurve = C_CurveUtil.CreateColorCurve()
target.friendCurve = C_CurveUtil.CreateColorCurve()

target.enemyCurve:SetType(Enum.LuaCurveType.Step)
target.friendCurve:SetType(Enum.LuaCurveType.Step)

-- ================================================================
--                          通用函数
-- ================================================================

-- 统计单位身上的负面光环数量（牧师「目标光环数量」块用）
--
-- ⚠️ 受限（战斗中）时 GetAuraInstanceIDs 返回 nil（读不到），
--    这里统一当 0 处理 —— 像素写 0，决策层就不驱散（宁可漏驱也不空放）。
function CyberDeck:updateUnitAuraCount(unit)
    local auraInstanceIDs = self:GetAuraInstanceIDs(unit, "HARMFUL|PLAYER", 40)
    if auraInstanceIDs then
        return #auraInstanceIDs
    end
    return 0
end

local function updateUnitRange(unit)
    local minRange, maxRange = rc:GetRange(unit)
    return minRange, maxRange
end

-- 打印成功施放的技能id和名称, 不重复打印已经施放的技能
-- 打印格式为  [spellID] = { index = i, }, -- 技能名称
local succSpells = {}
local succIndex = 1
local function printSuccSpell(spellID)
    if not blocks or not blocks.spells then return end
    if succSpells[spellID] or blocks.spells[spellID] then return end
    succSpells[spellID] = true
    print("[" .. spellID .. "]" .. " = { index = " .. succIndex .. ", }, -- " .. GetSpellName(spellID))
    succIndex = succIndex + 1
end

local function getSpellChargesInfo()
    local charges = C_Spell.GetSpellCharges(1247378)
    for k, v in pairs(charges) do
        print(k, v, issecretvalue(v))
    end
end

function CyberDeck:SPELL_UPDATE_CHARGES(_)
    -- getSpellChargesInfo()
end

-- 驱散能力映射
-- 无限服是经典（1.60.1）法术 ID：圣骑士只学到 纯净术(1152，驱疾病+中毒) 和 清洁术(4987，驱魔法+疾病+中毒)。
-- 正式服那套 ID 在无限服一个都对不上 -> hasLearnedAnySpell 全 false -> 曲线 3/4 号点位写成 0
-- -> 队友的“驱散”像素恒为 0 -> 决策层永远找不到要驱散的人（只有魔法那档侥幸命中 4987）。
-- [2] 诅咒保持全 false：经典圣骑士没有驱诅咒的法术（清洁术只驱魔法/疾病/中毒）。
local dispelAbilities = {
    [1] = { 527, 360823, 4987, 115450, 88423, 77130 },                      -- 魔法驱散
    [2] = { 383016, 51886, 392378, 2782, 475 },                             -- 诅咒驱散
    [3] = { 1152, 4987, 390632, 213634, 393024, 213644, 388874, 218164 },   -- 疾病驱散
    [4] = { 1152, 4987, 392378, 2782, 393024, 213644, 388874, 218164, 365585 }, -- 中毒驱散
    [11] = {}                                                               -- 流血驱散
}

-- 进攻驱散能力映射
local offensiveDispelAbilities = {
    [1] = { 528 },  -- 魔法
    [9] = { 2908 }, -- 激怒
}

local function hasLearnedAnySpell(spellIDs)
    for _, spellID in ipairs(spellIDs) do
        if IsSpellKnown(spellID) then
            return true
        end
    end
    return false
end

-- ================================================================
-- 光环受限（secret）适配 —— 只影响**目标侧**
--
-- 战斗中 / 首领战中 C_UnitAuras 返回 secret 值，读不到减益类型，
-- 所以「目标类型」像素会退回基线（友善 11 / 敌对 1）。
-- 这只会影响「按敌人减益类型选技能」这类判断（驱邪术/神圣愤怒已撤掉）。
--
-- ★ 队友侧不受此限：那几格由 AuraContainer 的引擎计时驱动，
--   插件侧不读光环，见 UpdateDispelProbeUnit。
-- ================================================================

-- 遍历光环列表，找第一个「玩家能驱散」的（曲线求值非零）
-- 只看 ids[1] 是不够的：第一个减益可能正好是自己驱不掉的那种
--
-- ★ 只用于**目标侧**（getTargetDispelType：读目标身上的减益类型，
--   编码成 11~15 写进「目标类型」像素）。
--   队友侧已改成引擎计时（每个可驱类型一格），不走这里。
local function pickTypeByCurve(unit, ids, curve)
    if not ids then return nil end
    for i = 1, #ids do
        local color = CyberDeck:GetAuraDispelTypeColor(unit, ids[i], curve)
        if color and color.b and color.b > 0 then
            return color.b
        end
    end
    return nil
end

-- ================================================================


local function updateCooldownSpellKnown()
    spells = {}
    if not blocks or not blocks.spells then return end
    C_Timer.After(1, function()
        for spellID, info in pairs(blocks.spells) do
            -- key 已经是 ResolveSpellID 用 C_SpellBook.IsSpellKnown 过滤过的 rank ID，
            -- 直接信任解析结果。正式服那套全局 IsSpellKnown / IsSpellInSpellBook 复核在这里
            -- 不适用：无限服是经典技能组，两套 API 对 rank 的语义不一致，
            -- 会把已学会的技能整体误标成 255，整条决策链失效。
            local isKnown = true
            local index = info.index
            if isKnown or info.forcedKnown then
                spells[spellID] = info
            elseif index then
                CyberDeck:CreatTexture(index, 1)
            end
        end
    end)
end

function CyberDeck:updateSpellKnown()
    updateCooldownSpellKnown()

    local dispelCapabilities = {
        [1] = false,  -- 魔法驱散
        [2] = false,  -- 疾病驱散
        [3] = false,  -- 诅咒驱散
        [4] = false,  -- 中毒驱散
        [11] = false, -- 流血
    }
    local offensiveDispelCapabilities = {
        [1] = false, -- 魔法
        [9] = false, -- 激怒
    }

    for debuffType, spellIDs in pairs(dispelAbilities) do
        dispelCapabilities[debuffType] = hasLearnedAnySpell(spellIDs)
    end

    for debuffType, spellIDs in pairs(offensiveDispelAbilities) do
        offensiveDispelCapabilities[debuffType] = hasLearnedAnySpell(spellIDs)
    end

    -- 只服务**目标侧**（队友侧由引擎计时驱动，不看能力表）
    target.enemyCurve:ClearPoints()
    target.friendCurve:ClearPoints()

    for i, v in pairs(dispelCapabilities) do
        if v then
            target.friendCurve:AddPoint(i, CreateColor(0, 1, (i + 11) / 255, 1))
        else
            target.friendCurve:AddPoint(i, CreateColor(0, 0, 11 / 255, 1))
        end
    end

    for i, v in pairs(offensiveDispelCapabilities) do
        if v then
            if i == 9 then
                target.enemyCurve:AddPoint(9, CreateColor(0, 1, 3 / 255, 1))
            else
                target.enemyCurve:AddPoint(i, CreateColor(0, 1, (i + 1) / 255, 1))
            end
        else
            target.enemyCurve:AddPoint(i, CreateColor(0, 0, 1 / 255, 1))
        end
    end
end

-- secret 上下文探测：/cy secrets
-- 无限服 1.60.1 带零售同款的 Secret Values 机制：C_Secrets 的谓词能直接问
-- 「当前上下文里这一类数据会不会变成 secret 值」，比逐字段试读准得多
-- （逐字段试读只能告诉你「这一次读到了什么」，不能告诉你「什么时候会变」）。
-- 用法：/cy secrets      —— 脱战时跑一次
--       /cy secrets 战斗 —— 战斗中再跑一次，对比两组的差异
function CyberDeck:PrintSecretContext()
    print("|cff00ff00[Cyber Deck]|r secret 上下文探测")

    if not C_Secrets then
        print("  |cffff0000当前客户端没有 C_Secrets|r（该客户端未启用 secret 机制，所有值都可读）")
        return
    end

    local inCombat = UnitAffectingCombat("player")
    print(("  上下文：%s   地图限制：%s"):format(
        inCombat and "|cffff0000战斗中|r" or "脱战",
        (C_Secrets.IsAddOnRestrictionActive and C_Secrets.IsAddOnRestrictionActive() or false)
            and "|cffff0000受限|r" or "普通"))

    -- 谓词清单：名称 -> 调用方式
    local checks = {
        { "光环",       function() return C_Secrets.ShouldAurasBeSecret() end },
        { "冷却",       function() return C_Secrets.ShouldCooldownsBeSecret() end },
        { "单位身份",   function() return C_Secrets.ShouldUnitIdentityBeSecret("target") end },
        { "单位属性",   function() return C_Secrets.ShouldUnitStatsBeSecret() end },
        { "威胁值",     function() return C_Secrets.ShouldUnitThreatValuesBeSecret("target", "target") end },
    }

    print("  |cff888888全局谓词（对所有单位一致）|r")
    for _, c in ipairs(checks) do
        local ok, v = pcall(c[2])
        if not ok then
            print(("    %-10s |cffff0000调用失败|r"):format(c[1]))
        else
            print(("    %-10s %s"):format(c[1],
                v and "|cffff0000会变 secret|r" or "|cff00ff00可读|r"))
        end
    end

    print("  |cff888888逐单位谓词（每个单位单独问）|r")
    local units = { "player", "target", "focus" }
    for i = 1, 5 do
        if UnitExists("party" .. i) then units[#units + 1] = "party" .. i end
    end
    for _, unit in ipairs(units) do
        if UnitExists(unit) then
            local parts = {}
            local fns = {
                { "身份", "ShouldUnitIdentityBeSecret", function() return C_Secrets.ShouldUnitIdentityBeSecret(unit) end },
                { "威胁", "ShouldUnitThreatValuesBeSecret", function() return C_Secrets.ShouldUnitThreatValuesBeSecret(unit, "target") end },
                { "施法", "ShouldUnitSpellCastingBeSecret", function() return C_Secrets.ShouldUnitSpellCastingBeSecret(unit) end },
                { "血上限", "ShouldUnitHealthMaxBeSecret", function() return C_Secrets.ShouldUnitHealthMaxBeSecret(unit) end },
                { "能量", "ShouldUnitPowerBeSecret", function() return C_Secrets.ShouldUnitPowerBeSecret(unit, 0) end },
            }
            for _, f in ipairs(fns) do
                if type(C_Secrets[f[2]]) ~= "function" then
                    parts[#parts + 1] = ("%s=—"):format(f[1])
                else
                    local ok, v = pcall(f[3])
                    if not ok then
                        parts[#parts + 1] = ("%s=!err"):format(f[1])
                    else
                        parts[#parts + 1] = ("%s=%s"):format(f[1], v and "S" or "ok")
                    end
                end
            end
            print(("    %-10s %s"):format(unit, table.concat(parts, "  ")))
        end
    end

    -- 单位比较（UnitIsUnit 在受限上下文会返回 nil 而不是 secret）
    if C_Secrets.CanCompareUnitTokens then
        local cmp = C_Secrets.CanCompareUnitTokens("player", "target")
        print(("  |cff888888UnitIsUnit 可用|r：%s"):format(cmp and "是" or "否（返回 nil）"))
    end

    -- 单个法术的光环保密等级（比全局谓词更精确：只有个别法术被标记 secret）
    -- GetSpellAuraSecrecy 返回 Enum.SecrecyLevel 枚举，不是布尔
    if C_Secrets.GetSpellAuraSecrecy and Enum and Enum.SecrecyLevel then
        print("  |cff888888单个法术的光环保密等级（NeverSecret = 任何时候都可读）|r")
        local probes = { 4987, 1152, 20927, 20473, 25780, 20271 }
        for _, spellID in ipairs(probes) do
            local ok, level = pcall(C_Secrets.GetSpellAuraSecrecy, spellID)
            if not ok then
                print(("    %-8d |cffff0000查询失败|r"):format(spellID))
            else
                local name
                if level == Enum.SecrecyLevel.NeverSecret then
                    name = "|cff00ff00NeverSecret|r 永远可读"
                elseif level == Enum.SecrecyLevel.AlwaysSecret then
                    name = "|cffff0000AlwaysSecret|r 永远是 secret"
                elseif level == Enum.SecrecyLevel.ContextuallySecret then
                    name = "|cffff0000ContextuallySecret|r 视上下文而定"
                else
                    name = "其它（值=" .. tostring(level) .. "）"
                end
                print(("    %-8d %s"):format(spellID, name))
            end
        end
    end

    print("  |cff888888提示|r：S = 该项在当前上下文会变成 secret 值（不能比较/算术）")
end

-- ================================================================
--                          玩家信息
-- ================================================================

function CyberDeck:updatePlayerBlocks()
    self.Initialize = false
    self.state.isDead = UnitIsDeadOrGhost("player") -- 4.有效性(死亡)
    self.state.isChatOpen = false                   -- 4.有效性(聊天框)
    self.state.drinkStatus = false                  -- 4.有效性(喝水)
    self:updatePlayerMounted()                      -- 4.有效性(坐骑, 变形)
    self:updatePlayerCombat()                       -- 5.战斗
    self:updatePlayerMoving(IsPlayerMoving())       -- 6.移动
    self:updatePlayerCastingInfo()                  -- 7.施法
    self:updatePlayerChannelingInfo()               -- 8.引导
    self:updatePlayerHealth()                       -- 11.生命值
    self:updatePlayerPowerType()                    -- 12.能量值
    self:updateTargetValid()                        -- 15.目标类型
    self:updateGroupType()                          -- 16.队伍类型
    self:updateGroupCount()                         -- 17.队伍人数

    self:updatePlayerBarInfo()                      -- 创建玩家bar信息
    self:updateShapeshiftForm()                     -- 姿态
    self:updateTargetRangeBlock()                   -- 目标距离
    self:updateTargetHealth()                       -- 目标生命值
    self:updateEnemyCount()                         -- 敌人数量
    self:updateGroup()                              -- 更新队伍
    self:GetItemCount()                             -- 获取物品数量
    C_Timer.After(1, function()
        self:updatePlayerConfig()
        self.Initialize = true
    end)
end

-- 队伍块里的驱散字段（class/*.lua 的 group 表） -> 引擎的类型名
-- 与 Shingen block.lua:1140-1146 的 DISPEL_DURATION_FIELDS 同名同序
local DISPEL_GROUP_FIELDS = {
    Magic = "dispelMagic",
    Curse = "dispelCurse",
    Disease = "dispelDisease",
    Poison = "dispelPoison",
    Bleed = "dispelBleed",
}

function CyberDeck:loadPlayerBlocks(specIndex)
    if not specIndex or not self.ClassBlocks then
        return
    end
    local t = self.ClassBlocks[specIndex]
    if not t then return end
    blocks = {
        state = {},
        auras = {},
        spells = {},
        countBars = {},
    }
    for k, v in pairs(t) do
        if k == "countBars" and type(v) == "table" then
            for key, value in pairs(v) do
                blocks.countBars[key] = value
            end
        end

        if type(v) ~= "table" or not v.type then
            -- 跳过 powerType 等非条目字段
        elseif v.type == "block" then
            if not v.name then
                self:Print(("loadPlayerBlocks: 索引 %s 的 block 缺少 name，已跳过"):format(tostring(k)))
            else
                blocks.state[v.name] = k
            end
        elseif v.type == "aura" then
            blocks.auras[k] = v
        elseif v.type == "spell" then
            -- 无限服按技能名解析到已学会的 rank ID（技能带等级，正式服 ID 不适用）
            local spellID = v.spellId
            if not spellID and v.name then
                spellID = self:ResolveSpellID(v.name)
            end
            if not spellID then
                self:CreatTexture(k, 1) -- 255 = 不可用
            else
                if not blocks.spells[spellID] then
                    blocks.spells[spellID] = {}
                end
                blocks.spells[spellID].name = v.name
                if v.charge then
                    blocks.spells[spellID].charge = k
                else
                    blocks.spells[spellID].index = k
                end
                if v.forcedKnown then
                    blocks.spells[spellID].forcedKnown = v.forcedKnown
                end
                if v.inSpellBook then
                    blocks.spells[spellID].inSpellBook = v.inSpellBook
                end
            end
        elseif v.type == "group" then
            blocks.groups = {}
            blocks.groups.start = k
            blocks.groups.num = v.num
            blocks.groups.healthPercent = v.healthPercent
            blocks.groups.role = v.role
            blocks.groups.auras = v.auras
            -- 驱散格：每个「能驱的类型」一个相对格号（Shingen 同款）
            --   类型名 -> 相对偏移；没有就表示本职业不建这一格
            --   旧字段 dispel（单格类型号）不再使用，属于已废弃协议
            blocks.groups.dispelCells = nil
            for typeName, field in pairs(DISPEL_GROUP_FIELDS) do
                if v[field] then
                    blocks.groups.dispelCells = blocks.groups.dispelCells or {}
                    blocks.groups.dispelCells[typeName] = v[field]
                end
            end
            if v.rejuv then
                blocks.groups.rejuv = v.rejuv
            end
        end
    end
    self.blocks = blocks
    -- ★ 换专精/重载 blocks 后队伍块的 start/num 都可能变（神圣 7 格 ↔ 防护 5 格），
    --   探针的 slot 还绑在旧格号上，必须整体重建，否则 2 号以后的队友会写进别人的格。
    --   （AuraContainer 的 slot 不能删，只能释放容器重来）
    if self.ResetDispelProbes then
        self:ResetDispelProbes()
    end
end

function CyberDeck:loadPlayerMacros()
    if not self.MacrosList then
        return
    end
    local m = self.MacrosList
    self:CreateMacro(m.dynamicSpells, m.staticSpells, m.specialSpells)
end

function CyberDeck:GetCharacterInfo()
    self.db.char.level = UnitLevel("player")
    self.state.name = UnitName("player")
    self.state.GUID = UnitGUID("player")
    self.state.classColor = RAID_CLASS_COLORS[self.state.classFilename].colorStr
end

function CyberDeck:GetCharacterSpecInfo()
    -- 无限服没有专精系统：专精索引按天赋树判定（GetActiveSpecIndex），名称/职责/射程取无限服表
    self.state.specIndex = self:GetActiveSpecIndex()
    local info = self:GetForeverSpecInfo(self.state.specIndex)
    self.state.specID = info.id
    self.state.specName = info.name
    self.state.specRole = info.role
    self.state.specRange = info.range
    self.state.isDead = UnitIsDeadOrGhost("player")
    self.state.isChatOpen = false
    self.state.casting = false
    self.state.channeling = false
    self:loadPlayerBlocks(self.state.specIndex)
    self:updateSpellKnown()
    self:updatePlayerMounted()
    self:updateGroup()
    self:loadPlayerMacros() -- 载入玩家宏
    self:updateAuraIconByEnteringWorld()
    self:GetItemCount()     -- 获取物品数量
    self:CreatTexture(blocks.state["职业"], self.state.classId / 255)
    self:CreatTexture(blocks.state["专精"], self.state.specIndex / 255)
end

function CyberDeck:updatePlayerSpecInfo()
    self:clearAllTextures()
    local newSpecIndex = self:GetActiveSpecIndex()
    -- 换专精：把上一套专精建的计数条清掉重建。
    -- 正式服在施法 384255 / 200749（切天赋/切专精）时做同一件事，
    -- 无限服没有那两个法术，改天赋走 PLAYER_TALENT_UPDATE，所以在这里补。
    -- 必须在 loadPlayerBlocks 之前清：CreateAutoLayoutBar 开头有
    -- 「spellIdToBar 已有就复用」的复检，不先清会命中旧映射，条不会重建。
    if self.state.specIndex and self.state.specIndex ~= newSpecIndex then
        self:ClearAllCyberDeckBars()
    end
    self.state.specIndex = newSpecIndex
    local info = self:GetForeverSpecInfo(self.state.specIndex)
    self.state.specID = info.id
    self.state.specName = info.name
    self.state.specRole = info.role
    self.state.specRange = info.range
    self:loadPlayerBlocks(self.state.specIndex) -- 载入玩家blocks配置

    self:updateSpellKnown()                     -- 更新法术已知状态
    self:updatePlayerBlocks()                   -- 更新玩家blocks信息
    self:CreatTexture(blocks.state["职业"], self.state.classId / 255)
    self:CreatTexture(blocks.state["专精"], self.state.specIndex / 255)
end

function CyberDeck:updatePlayerValid()
    local valid = not state.isDead and not state.mounted and not state.isChatOpen and not state.drinkStatus
    state.valid = valid and 1 / 255 or 0
    self:CreatTexture(blocks.state["有效性"], state.valid)
end

function CyberDeck:updatePlayerCombat()
    local combat = UnitAffectingCombat("player")
    state.combat = combat and 1 / 255 or 0
    self:CreatTexture(blocks.state["战斗"], state.combat)
end

function CyberDeck:updatePlayerMoving(boolean)
    state.drinkStatus = false
    self:updatePlayerValid()
    state.moving = boolean and 1 / 255 or 0
    self:CreatTexture(blocks.state["移动"], state.moving)
end

function CyberDeck:updatePlayerCastingInfo()
    if state.casting then
        local cast = UnitCastingDuration("player")
        if cast and cast.EvaluateElapsedDuration then
            local castingDurationColor = cast:EvaluateElapsedDuration(castCurve)
            ---@diagnostic disable-next-line: param-type-mismatch
            local _, _, b = castingDurationColor:GetRGB()
            state.castingDuration = b
            self:CreatTexture(blocks.state["施法"], state.castingDuration)
        else
            state.castingDuration = 0
            self:CreatTexture(blocks.state["施法"], 0)
        end
    else
        state.castingDuration = 0
        self:CreatTexture(blocks.state["施法"], 0)
    end
end

function CyberDeck:updatePlayerChannelingInfo()
    if state.channeling then
        local channel = UnitChannelDuration("player")
        if channel then
            local channelDurationColor = channel:EvaluateRemainingDuration(castCurve)
            ---@diagnostic disable-next-line: param-type-mismatch
            local _, _, b = channelDurationColor:GetRGB()
            state.channelingDuration = b
            self:CreatTexture(blocks.state["引导"], b)
        else
            state.channelingDuration = 0
            self:CreatTexture(blocks.state["引导"], 0)
        end
    else
        state.channelingDuration = 0
        self:CreatTexture(blocks.state["引导"], 0)
    end
end

function CyberDeck:updatePlayerHealth()
    local healthPercent = UnitHealthPercent("player", false, curve100)
    ---@diagnostic disable-next-line: param-type-mismatch
    local _, _, b = healthPercent:GetRGB()
    state.healthPercent = b
    self:CreatTexture(blocks.state["生命值"], state.healthPercent)
end

local specialPowerMap = {
    ["COMBO_POINTS"] = "连击点",
    ["HOLY_POWER"] = "神圣能量",
    ["ESSENCE"] = "精华能量",
    ["SOUL_SHARDS"] = "灵魂碎片",
    ["CHI"] = "真气",
}
function CyberDeck:updatePlayerPower(powerType)
    if blocks then
        local power = UnitPower("player", EnumPowerType[powerType])
        local specialPower = specialPowerMap[powerType]
        if isSec(power) then
            if not powerCurve[powerType] then self:CreatPowerCurve(powerType) end
            local powerPercent = UnitPowerPercent("player", EnumPowerType[powerType], nil, powerCurve[powerType])
            ---@diagnostic disable-next-line: param-type-mismatch
            local _, _, b = powerPercent:GetRGB()
            state.powerPercent = b
            self:CreatTexture(blocks.state["能量值"], state.powerPercent)
        elseif specialPower then
            local blockIndex = blocks.state[specialPower]
            if blockIndex then
                self:CreatTexture(blockIndex, (power or 0) / 255)
            end
        else
            -- 无限服没有秘密值系统：法力/怒气等直接按百分比写入 12.能量值
            local maxPower = UnitPowerMax("player", EnumPowerType[powerType])
            local blockIndex = blocks.state["能量值"]
            if blockIndex and maxPower and maxPower > 0 then
                self:CreatTexture(blockIndex, math.min(1, (power or 0) / maxPower))
            end
        end
    end
end

function CyberDeck:updatePlayerPowerType()
    local powerType = UnitPowerType("player")
    self:CreatPowerCurve(powerType)
    self:updatePlayerPower(powerType)
end

function CyberDeck:updateSpellFailed(spellID)
    local isUsable = C_Spell.IsSpellUsable(spellID)

    local info = blocks.spells and blocks.spells[spellID]
    if info and FAILED_RETRY[info.name] then
        failedSpell = info.index
        state.failedSpell = (failedSpell or 0) / 255
    else
        failedSpell = nil
        state.failedSpell = 0
    end

    if not isUsable or not failedSpell then return end

    failedSpellId = spellID

    if failedSpellTimer then
        failedSpellTimer:Cancel()
        failedSpellTimer = nil
    end

    failedSpellTimer = C_Timer.NewTimer(1.5, function()
        self:CreatTexture(blocks.state["法术失败"], 0)
        failedSpellTimer = nil
        failedSpell = nil
        failedSpellId = nil
    end)
    self:CreatTexture(blocks.state["法术失败"], state.failedSpell)
end

function CyberDeck:updateFailedSpellBySuccess(spellID)
    if spellID ~= failedSpellId then return end
    failedSpell = nil
    failedSpellId = nil
    print("|cff00ff00插入技能: |r", GetSpellName(spellID))
    self:CreatTexture(blocks.state["法术失败"], 0)
end

local function getTargetDispelType()
    local unit = "target"
    if not UnitExists(unit) then return 0 end
    local filter, curve, b = nil, nil, 0

    if target.canAttack then
        b = 1 / 255
        curve = target.enemyCurve
        filter = "HELPFUL|RAID_PLAYER_DISPELLABLE"
    elseif target.canAssist then
        b = 11 / 255
        curve = target.friendCurve
        filter = "HARMFUL|RAID_PLAYER_DISPELLABLE"
    else
        return 0
    end

    -- ⚠️ 受限时**照样尝试读**（pcall 保护）：
    --   客户端自带的 EUI 就是用 pcall 试读判断受限的，调用本身不污染 taint。
    --   读不到时 pickTypeByCurve(nil) 返回 nil -> 自然回落到基准值 b。
    local auraInstanceIDs = CyberDeck:GetAuraInstanceIDs(unit, filter, 40)

    -- 逐个试，别只看第一个：第一个光环可能不是自己能驱散的那种
    local cb = pickTypeByCurve(unit, auraInstanceIDs, curve)
    if cb then return cb end
    return b
end

function CyberDeck:updateTargetValid()
    local targetType = 0

    if target.inRange and not target.isDead then
        targetType = getTargetDispelType()
    end
    target.type = targetType
    self:CreatTexture(blocks.state["目标类型"], target.type)
end


-- 更新目标光环数量（牧师「苦修」决策用：目标身上有负面光环才值得驱）
function CyberDeck:updateTargetAuraCount()
    if not UnitExists("target") then return end
    if blocks and blocks.state["目标光环数量"] then
        local auraCount = self:updateUnitAuraCount("target")
        state.targetAuraCount = (auraCount or 0) / 255
        self:CreatTexture(blocks.state["目标光环数量"], state.targetAuraCount)
    end
end

function CyberDeck:updateGroupType()
    local index = 0
    if UnitInRaid("player") then
        index = UnitInRaid("player") or 0
    elseif UnitInParty("player") then
        index = 46
    end
    state.groupType = index / 255 or 0
    self:CreatTexture(blocks.state["队伍类型"], state.groupType)
end

function CyberDeck:updateGroupCount()
    local count = GetNumGroupMembers()
    state.groupCount = count / 255 or 0
    self:CreatTexture(blocks.state["队伍人数"], state.groupCount)
end

function CyberDeck:updatePlayerBarInfo()
    if blocks.countBars then
        for k, v in pairs(blocks.countBars) do
            self:CreateAutoLayoutBar(v.valueType, v.minValue, v.maxValue, v.spellId)
        end
    end
end

function CyberDeck:updatePlayerMounted()
    state.mounted = IsMounted() or state.shapeshiftFormID == 27 or state.shapeshiftFormID == 3 or
        state.shapeshiftFormID == 29
    self:updatePlayerValid()
end

function CyberDeck:updatePlayerCasting(spellId)
    if not blocks then return end
    if blocks.state["施法目标"] then
        if state.castTargetIndex then
            self:CreatTexture(blocks.state["施法目标"], state.castTargetIndex)
        else
            self:CreatTexture(blocks.state["施法目标"], 0)
        end
    end
    if blocks.state["施法技能"] then
        local spellInfo = blocks.spells and blocks.spells[spellId]
        local castingSpell = (spellInfo and (spellInfo.index or spellInfo.charge)) or 0
        state.castingSpell = castingSpell / 255 or 0
        if castingSpell then
            self:CreatTexture(blocks.state["施法技能"], state.castingSpell)
        else
            self:CreatTexture(blocks.state["施法技能"], 0)
        end
    end
end

function CyberDeck:updatePlayerConfig()
    local c = self.db and self.db.char
    if not c or not blocks then return end
    if blocks.state["爆发开关"] then
        self:CreatTexture(blocks.state["爆发开关"], (c.cooldowns or 0) / 255)
    end
    if blocks.state["驱散开关"] then
        self:CreatTexture(blocks.state["驱散开关"], (c.dispel or 1) / 255)
    end
end



function CyberDeck:updateShapeshiftForm()
    local shapeshiftFormID = GetShapeshiftFormID() or 0
    state.shapeshiftFormID = shapeshiftFormID / 255
    if blocks and blocks.state["姿态"] then
        self:CreatTexture(blocks.state["姿态"], state.shapeshiftFormID)
    end
end



function CyberDeck:updateSpellCooldown()
    if not spells then return end
    for spellID, info in pairs(spells) do
        local index = info.index
        local cdDurationObj = GetSpellCooldownDuration(spellID)
        local cdInfo = GetSpellCooldown(spellID)
        if cdDurationObj and cdInfo then
            local result = cdDurationObj:EvaluateRemainingDuration(curve255, 1)
            fallbackColor:SetRGBA(0, index, 254 / 255)
            ---@diagnostic disable-next-line: param-type-mismatch
            local value = EvaluateColorFromBoolean(cdInfo.isEnabled, result, fallbackColor)
            local _, _, b = value:GetRGB()
            ---@diagnostic disable-next-line: undefined-field
            if cdInfo.isOnGCD then b = 0 end
            self:CreatTexture(index, b)
        else
            self:CreatTexture(index, 1)
        end
        local chargeIndex = info.charge
        if chargeIndex then
            local chDurationObj = GetSpellChargeDuration(spellID)
            if chDurationObj then
                local result = chDurationObj:EvaluateRemainingDuration(curve255)
                ---@diagnostic disable-next-line: param-type-mismatch
                local _, _, b = result:GetRGB()
                self:CreatTexture(chargeIndex, b)
            else
                self:CreatTexture(chargeIndex, 1)
            end
        end
    end
end

local function countItemGroup(ids)
    local n = 0
    for _, id in ipairs(ids or {}) do
        n = n + (C_Item.GetItemCount(id) or 0)
    end
    return n
end

function CyberDeck:GetItemCount()
    self.state.itemCounts = {}
    for key, ids in pairs(self.itemGroups or {}) do
        self.state.itemCounts[key] = countItemGroup(ids)
    end
    -- 兼容旧字段
    self.state.HealthPotionCount = self.state.itemCounts.HealthPotion or 0
    self.state.ManaPotionCount = self.state.itemCounts.ManaPotion or 0
    self.state.HealthstoneCount = self.state.itemCounts.Healthstone or 0
    self.state.RecklessnessCount = self.state.itemCounts.Recklessness or 0
    self.state.LightsPotentialCount = self.state.itemCounts.LightsPotential or 0
end

function CyberDeck:GetItemRemainingTime(itemID)
    local startTimeSeconds, durationSeconds, enableCooldownTimer = C_Item.GetItemCooldown(itemID)
    if not enableCooldownTimer then return 255 end
    if startTimeSeconds > 0 then
        return durationSeconds - (GetTime() - startTimeSeconds)
    else
        return 0
    end
end

function CyberDeck:updateItemCoolDown()
    if not blocks or not blocks.state then return end
    if not self.state.itemCounts then
        self:GetItemCount()
    end
    for blockName, groupKey in pairs(self.itemBlocks or {}) do
        local index = blocks.state[blockName]
        if index then
            local ids = self.itemGroups and self.itemGroups[groupKey]
            local count = (self.state.itemCounts and self.state.itemCounts[groupKey]) or 0
            if ids and #ids > 0 and count > 0 then
                local remainingTime = 0
                for _, id in ipairs(ids) do
                    local t = self:GetItemRemainingTime(id)
                    if t and t ~= 255 and t > remainingTime then
                        remainingTime = t
                    end
                end
                self:CreatTexture(index, math.min(1, remainingTime / 255))
            else
                self:CreatTexture(index, 1) -- 255 = 没有可用物品
            end
        end
    end
end

-- ================================================================
--                          目标信息
-- ================================================================
--[[
    0 = "没有目标"

    1 = "敌方",
    2 = "敌方 有魔法 增益 "
    3 = "敌方 有激怒 增益",

    11 = "友方"
    12 = "友方 有魔法 减益"
    13 = "友方 有疾病 减益"
    14 = "友方 有诅咒 减益"
    15 = "友方 有中毒 减益"

]]

function CyberDeck:updateTargetType()
    target.canAttack = UnitCanAttack("player", "target")
    target.canAssist = UnitCanAssist("player", "target")
    self:updateTargetValid()
end

function CyberDeck:updateTargetRangeBlock()
    local minRange, maxRange = updateUnitRange("target")
    target.minRange = minRange
    target.maxRange = maxRange
    if target.canAttack then
        if target.maxRange and self.state.specRange then
            target.inRange = target.maxRange <= self.state.specRange
            self:updateTargetValid()
        end
    elseif target.canAssist then
        if target.maxRange then
            target.inRange = target.maxRange <= 40
            self:updateTargetValid()
        end
    end
    if blocks and blocks.state["目标距离"] then
        -- 没有目标/拿不到距离时必须写 0，否则像素会保留上一次的值（例如一直显示 20 码），
        -- 决策层会误判为“目标在近战范围内”
        if target.maxRange then
            self:CreatTexture(blocks.state["目标距离"], target.maxRange / 255)
        else
            self:CreatTexture(blocks.state["目标距离"], 0)
        end
    end
end

function CyberDeck:updateUnitCastingOrChannelingInfo(unit)
    if not UnitExists(unit) then return end
    local obj, castingDuration, channelingDuration
    if unit == "target" then
        obj = "目标"
        castingDuration = target.castingDuration
        channelingDuration = target.channelingDuration
    elseif unit == "focus" then
        obj = "焦点"
        castingDuration = focus.castingDuration
        channelingDuration = focus.channelingDuration
    end
    local cast = UnitCastingDuration(unit)
    local channel = UnitChannelDuration(unit)
    if cast then
        if unit == "target" and blocks and blocks.state["目标施法"] then
            -- 由 updateTargetCastingInfo 处理
        else
            local _, _, _, _, _, _, _, notInterruptible = UnitCastingInfo(unit)
            local castingDurationColor = cast:EvaluateRemainingDuration(castCurve)
            local booleanValue = EvaluateColorFromBoolean(notInterruptible, falseValueWhite, castingDurationColor)
            ---@diagnostic disable-next-line: param-type-mismatch
            local _, _, b = booleanValue:GetRGB()
            castingDuration = b
            if blocks and blocks.state[obj .. "施法"] then
                self:CreatTexture(blocks.state[obj .. "施法"], b)
            end
        end
    elseif channel then
        local _, _, _, _, _, _, notInterruptible = UnitChannelInfo("target")
        local channelDurationColor = channel:EvaluateRemainingDuration(castCurve)
        local booleanValue = EvaluateColorFromBoolean(notInterruptible, falseValueWhite, channelDurationColor)
        ---@diagnostic disable-next-line: param-type-mismatch
        local _, _, b = booleanValue:GetRGB()
        channelingDuration = b
        if blocks and blocks.state[obj .. "引导"] then
            self:CreatTexture(blocks.state[obj .. "引导"], b)
        end
    else
        castingDuration = 0
        channelingDuration = 0
        if blocks then
            if blocks.state[obj .. "施法"] and not (unit == "target" and blocks.state["目标施法"]) then
                self:CreatTexture(blocks.state[obj .. "施法"], 0)
            end
            if blocks.state[obj .. "引导"] then
                self:CreatTexture(blocks.state[obj .. "引导"], 0)
            end
        end
    end
end

function CyberDeck:updateTargetCastingInfo()
    if not blocks or not blocks.state["目标施法"] then return end
    if not UnitExists("target") then return end
    local cast = UnitCastingDuration("target")
    if cast then
        local _, _, _, _, _, _, _, notInterruptible = UnitCastingInfo("target")
        local castingDurationColor = cast:EvaluateRemainingDuration(castCurve)
        local booleanValue = EvaluateColorFromBoolean(notInterruptible, falseValueWhite, castingDurationColor)
        ---@diagnostic disable-next-line: param-type-mismatch
        local _, _, b = booleanValue:GetRGB()
        target.castingDuration = b
        self:CreatTexture(blocks.state["目标施法"], b)
    else
        target.castingDuration = 0
        self:CreatTexture(blocks.state["目标施法"], 0)
    end
end

function CyberDeck:updateTargetDeath()
    target.isDead = UnitIsDeadOrGhost("target")
    self:updateTargetValid()
end

function CyberDeck:updateTargetHealth()
    local healthPercent = UnitHealthPercent("target", false, curve100)
    ---@diagnostic disable-next-line: param-type-mismatch
    local _, _, b = healthPercent:GetRGB()
    target.healthPercent = b or 0
    if blocks and blocks.state["目标生命值"] then
        self:CreatTexture(blocks.state["目标生命值"], b)
    end
end

function CyberDeck:updateTargetFullInfo()
    self:updateTargetType()
    self:updateTargetDeath()
    self:updateTargetHealth()
end

-- ================================================================
--                          姓名版信息
-- ================================================================

local function addNameplate(unit)
    local minRange, maxRange = updateUnitRange(unit)
    nameplate[unit] = {
        name = GetUnitName(unit, true),
        GUID = UnitGUID(unit),
        canAttack = UnitCanAttack("player", unit),
        canAssist = UnitCanAssist("player", unit),
        minRange = minRange,
        maxRange = maxRange,
        affectingCombat = UnitAffectingCombat(unit),
    }
end
local testMap = {
    [2393] = true, -- 银月城
}
local testEncounter = {
    [2563] = true, -- 茂林古树
}
function CyberDeck:updateEnemyCount()
    local count = 0
    local hasAuraCount = 0
    local count5y = 0
    local inTestMap = state.mapID and testMap[state.mapID]
    local inTestEncounter = state.encounterID and testEncounter[state.encounterID]
    for unit, data in pairs(nameplate) do
        local minRange, maxRange = updateUnitRange(unit)
        data.minRange = minRange
        data.maxRange = maxRange
        data.affectingCombat = UnitAffectingCombat(unit)
        if data.canAttack and data.maxRange and data.maxRange <= self.state.specRange
            and (data.affectingCombat or inTestMap or inTestEncounter) then
            count = count + 1
            local hasAura = self:updateUnitAuraCount(unit)
            if hasAura > 0 then
                hasAuraCount = hasAuraCount + 1
            end
        end
        if data.canAttack and data.maxRange and data.maxRange <= 5 and (data.affectingCombat or inTestMap) then
            count5y = count5y + 1
        end
    end
    state.enemyCount = (count or 0) / 255
    state.hasAuraEnemyCount = (hasAuraCount or 0) / 255
    state.enemyCount5y = (count5y or 0) / 255
    if blocks then
        if blocks.state["敌人人数"] then
            self:CreatTexture(blocks.state["敌人人数"], state.enemyCount)
        end
        if blocks.state["有光环敌人数量"] then
            self:CreatTexture(blocks.state["有光环敌人数量"], state.hasAuraEnemyCount)
        end
        if blocks.state["5码敌人"] then
            self:CreatTexture(blocks.state["5码敌人"], state.enemyCount5y)
        end
    end
end

local drinkStatusTimer = nil
function CyberDeck:updateDrinkStatus(spellID)
    local name = C_Spell.GetSpellName(spellID)
    if name == "饮水" or name == "进食饮水" then
        state.drinkStatus = true
        self:updatePlayerValid()
        if drinkStatusTimer then
            drinkStatusTimer:Cancel()
            drinkStatusTimer = nil
        end
        drinkStatusTimer = C_Timer.NewTimer(20, function()
            state.drinkStatus = false
            self:updatePlayerValid()
            drinkStatusTimer = nil
        end)
    else
        if drinkStatusTimer then
            drinkStatusTimer:Cancel()
            drinkStatusTimer = nil
        end
        state.drinkStatus = false
        self:updatePlayerValid()
    end
end

-- ================================================================
--                          队伍信息
-- ================================================================

function CyberDeck:updateUnitHealthInfo(unit)
    local obj = group[unit]
    if not blocks or not blocks.groups or not obj then return end
    local index = blocks.groups.start + (obj.index - 1) * blocks.groups.num + blocks.groups.healthPercent
    obj.curve = creatColorCurveScaling(100 + obj.inComingHeals - obj.healAbsorb)
    local healthPercent = UnitHealthPercent(unit, false, obj.curve)
    ---@diagnostic disable-next-line: param-type-mismatch
    local _, _, b = healthPercent:GetRGB()
    obj.healthPercent = b
    self:CreatTexture(index, obj.healthPercent)
end

function CyberDeck:updateUnitValid(unit)
    local obj = group[unit]
    if not obj then return end
    obj.valid = not obj.isDead and obj.canAssist and obj.inSight
end

function CyberDeck:updateGroupInRangeAndHealth()
    if not blocks or not blocks.groups then return end
    local numUnits = #groupList
    if numUnits >= 1 then
        local unit = groupList[updateIndex]
        local obj = group[unit]
        if not obj then return end
        self:updateUnitHealthInfo(unit)
        local index = blocks.groups.start + (obj.index - 1) * blocks.groups.num + blocks.groups.role
        obj.isDead = UnitIsDeadOrGhost(unit)
        obj.canAssist = UnitCanAssist("player", unit)
        obj.valid = not obj.isDead and obj.canAssist and obj.inSight
        if obj.valid then
            local inRange = UnitIsUnit(unit, "player") and true or UnitInRange(unit)
            local roleValue = roleMap[obj.role] and roleMap[obj.role] / 255 or 5 / 255
            local trueValue = CreateColor(0, 0, roleValue, 1)
            local booleanValue = EvaluateColorFromBoolean(inRange, trueValue, falseValueBlack)
            local _, _, b = booleanValue:GetRGB()
            self:CreatTexture(index, b)
        else
            self:CreatTexture(index, 0)
        end
        updateIndex = updateIndex + 1
        if updateIndex > numUnits then
            updateIndex = 1
        end
    end
end

local function updateUnitDeath(unitGUID)
    for unit, data in pairs(group) do
        if data.GUID == unitGUID then
            data.isDead = true
            CyberDeck:updateUnitValid(unit)
        end
    end
end

local function updateUnitDeathByHealthInfo(unit)
    local obj = group[unit]
    if not obj then return end
    obj.isDead = UnitIsDeadOrGhost(unit)
    CyberDeck:updateUnitValid(unit)
end

local function updateUnitInSight(unit)
    local obj = group[unit]
    if not obj then return end
    obj.inSight = false
    if obj.inSightTimer then
        obj.inSightTimer:Cancel()
        obj.inSightTimer = nil
    end
    obj.inSightTimer = C_Timer.NewTimer(1.5, function()
        obj.inSight = true
        obj.inSightTimer = nil
        CyberDeck:updateUnitValid(unit)
    end)
    CyberDeck:updateUnitValid(unit)
end

local function updateUnitHealAbsorbCurve(unit)
    local obj = group[unit]
    if not obj then return end
    obj.healAbsorb = 15
    if obj.curveTimer then
        obj.curveTimer:Cancel()
    end
    obj.curveTimer = C_Timer.NewTimer(1, function()
        if group[unit] and group[unit] == obj then
            obj.healAbsorb = 0
            obj.curveTimer = nil
        end
    end)
end

local function updateUnitIncomingHealsCurve(spellID)
    local unit = state.castTargetUnit
    if not unit then return end
    local obj = group[unit]
    if not obj then return end
    local isHelpfulSpell = helpfulSpells[spellID]
    if isHelpfulSpell then
        obj.inComingHeals = isHelpfulSpell
    end
end

local function updateUnitIncomingHealsCurve2()
    for unit, data in pairs(group) do
        data.inComingHeals = 0
    end
end

function CyberDeck:updateUnitFullAura(unit)
    local obj = group[unit]
    if not obj then return end
    for i = 1, 5 do
        local okb, buff = pcall(C_UnitAuras.GetBuffDataByIndex, unit, i, "PLAYER|HELPFUL|RAID_IN_COMBAT")
        if okb and buff then
            obj.aura[buff.auraInstanceID] = buff
        end
    end
end

local function getMaxAuraByTable(unit, spellIds)
    local obj = group[unit]
    if not obj or not obj.aura then return end
    local maxAura = nil
    for i, spellId in pairs(spellIds) do
        for auraInstanceID, aura in pairs(obj.aura) do
            if isSec(aura.spellId) then
                obj.aura[auraInstanceID] = nil
            else
                if aura.spellId == spellId and aura.expirationTime and (not maxAura or aura.expirationTime > maxAura.expirationTime) then
                    maxAura = aura
                end
            end
        end
    end
    return maxAura
end

local function getRejuvCount(unit)
    local obj = group[unit]
    if not obj or not obj.aura then return end
    local rejuvCount = 0
    for auraInstanceID, aura in pairs(obj.aura) do
        if aura.spellId == 774 or aura.spellId == 155777 then
            rejuvCount = rejuvCount + 1
        end
    end
    return rejuvCount
end

function CyberDeck:OnUpdateUnitAura()
    if not blocks or not blocks.groups or not blocks.groups.auras then return end
    for unit, data in pairs(group) do
        for i, spellIds in pairs(blocks.groups.auras) do
            local index = blocks.groups.start + (data.index - 1) * blocks.groups.num + i
            local maxAura = getMaxAuraByTable(unit, spellIds)
            if maxAura and maxAura.auraInstanceID then
                local okd, duration = pcall(C_UnitAuras.GetAuraDuration, unit, maxAura.auraInstanceID)
                if maxAura.expirationTime == 0 then
                    self:CreatTexture(index, 1)
                elseif duration then
                    local auraduration = duration:EvaluateRemainingDuration(curve255)
                    ---@diagnostic disable-next-line: param-type-mismatch
                    local _, _, b = auraduration:GetRGB()
                    self:CreatTexture(index, b)
                else
                    self:CreatTexture(index, 0)
                end
            else
                self:CreatTexture(index, 0)
            end
        end
        if blocks.groups.rejuv then
            local index = blocks.groups.start + (data.index - 1) * blocks.groups.num + blocks.groups.rejuv
            local rejuvCount = getRejuvCount(unit)
            self:CreatTexture(index, rejuvCount / 255)
        end
    end
end

function CyberDeck:updateGroup()
    -- ⚠️ 必须用 wipe 而不是 `self.group = {}`：
    --    group / groupList 在文件顶部被 local 捕获过（local group = CyberDeck.group），
    --    重建 self.group 会让 local 继续指向旧表 —— 数据写进旧表、self.group 永远为空。
    wipe(self.group)
    wipe(self.groupList)
    local i = 1
    for unit in self:IterateGroupMembers() do
        table.insert(groupList, unit)
        local role = UnitGroupRolesAssigned(unit)
        if unit == "player" then
            role = self.state.specRole
        end
        group[unit] = {
            index = i,
            name = GetUnitName(unit, true),
            GUID = UnitGUID(unit),
            role = role,
            isDead = UnitIsDeadOrGhost(unit),
            inRange = UnitInRange(unit),
            canAttack = UnitCanAttack("player", unit),
            canAssist = UnitCanAssist("player", unit),
            inSight = true,
            inSightTimer = nil,
            curve = curve100,
            healAbsorb = 0,
            inComingHeals = 0,
            curveTimer = nil,
            aura = {}
        }
        self:updateUnitValid(unit)
        self:updateUnitHealthInfo(unit)
        self:updateUnitFullAura(unit)
        i = i + 1
    end

    -- 宏位上限告警：31 号以后没有可用的施法宏，决策层也不会去选（Python 只读 30 槽）
    local limit = CyberDeck.GROUP_TARGET_LIMIT or 30
    local total = #groupList
    if total > limit then
        if not self.groupLimitWarned then
            self.groupLimitWarned = true
            local slots = CyberDeck.GROUP_KEY_SLOTS
            self:Print(("|cffff0000队伍 %d 人：|r本插件只能对 1~%d 号队友施法%s，"
                .. "%d 号以后不会被治疗/驱散。")
                :format(total, limit,
                    slots and ("（宏位 " .. slots .. " 个已经排满）") or "",
                    limit + 1))
        end
    else
        self.groupLimitWarned = nil
    end
end

-- ================================================================
--                          事件
-- ================================================================

function CyberDeck:ZONE_CHANGED()
    state.mapID = C_Map.GetBestMapForUnit("player") or 0
    state.mapInfo = C_Map.GetMapInfo(state.mapID)
    state.subzone = GetSubZoneText()
    if GetBindLocation() == state.subzone then
        self:Print("欢迎回家!")
    end
end

function CyberDeck:ZONE_CHANGED_INDOORS()
    state.mapID = C_Map.GetBestMapForUnit("player") or 0
    state.mapInfo = C_Map.GetMapInfo(state.mapID)
    state.subzone = GetSubZoneText()
    if GetBindLocation() == state.subzone then
        self:Print("欢迎回家!")
    end
end

function CyberDeck:PLAYER_ENTERING_WORLD()
    -- 过场后光环缓存可能失效 -> 强制重绑探针的候选过滤
    if self.MarkDispelProbesRebind then self:MarkDispelProbesRebind() end
    state.mapID = C_Map.GetBestMapForUnit("player") or 0
end

function CyberDeck:PLAYER_TALENT_UPDATE()
    self:updatePlayerSpecInfo()
    self:updateGroup()
    -- 事件触发时天赋点数可能还是旧值（服务器未同步），再延迟刷两次兜底。
    -- 无限服切天赋的 spellID 不是正式服的 384255 / 200749，那条延迟路径走不到，
    -- 所以必须在这里补，否则 GUI 会一直显示切换前的专精。
    for _, delay in ipairs({ 0.5, 2.0 }) do
        C_Timer.After(delay, function()
            if InCombatLockdown() then return end
            self:updatePlayerSpecInfo()
        end)
    end
end

function CyberDeck:PLAYER_DEAD()
    self.state.isDead = UnitIsDeadOrGhost("player")
    self:updatePlayerValid()
    -- 死亡后圣印会消失，但 auras 的施放计时不知道，不清的话复活后会误判 30 秒
    local sealAura = CyberDeck.Auras and CyberDeck.Auras["圣印"]
    if sealAura then
        sealAura.expirationTime = nil
        sealAura.sealValue = 0
        sealAura.remaining = 0
    end
end

function CyberDeck:PLAYER_ALIVE()
    state.isDead = UnitIsDeadOrGhost("player")
    self:updatePlayerValid()
end

function CyberDeck:PLAYER_UNGHOST()
    state.isDead = UnitIsDeadOrGhost("player")
    self:updatePlayerValid()
end

function CyberDeck:PLAYER_MOUNT_DISPLAY_CHANGED()
    self:updatePlayerMounted()
end

function CyberDeck:PLAYER_REGEN_DISABLED()
    self:updateTargetType()
    self:updatePlayerCombat()
end

function CyberDeck:PLAYER_REGEN_ENABLED()
    self:updateTargetType()
    self:updatePlayerCombat()
end

function CyberDeck:PLAYER_STARTED_MOVING()
    self:updatePlayerMoving(true)
end

function CyberDeck:PLAYER_STOPPED_MOVING()
    self:updatePlayerMoving(false)
end

function CyberDeck:UNIT_SPELLCAST_SENT(_, unitTarget, targetName, castGUID, spellID)
    if unitTarget ~= "player" then return end
    if not isSec(targetName) then
        for unit, data in pairs(group) do
            if data.name == targetName then
                state.castTargetUnit = unit
                state.castTargetName = targetName
                state.castTargetIndex = data.index / 255
                break
            end
        end
    end
end

function CyberDeck:UNIT_SPELLCAST_START(_, unitTarget, castGUID, spellID, castBarID)
    if unitTarget == "player" then
        state.casting = true
        updateUnitIncomingHealsCurve(spellID)
        self:updatePlayerCasting(spellID)
    end
    if unitTarget == "target" then
        target.casting = true
    end
end

function CyberDeck:UNIT_SPELLCAST_STOP(_, unitTarget, castGUID, spellID, castBarID)
    if unitTarget == "player" then
        updateUnitIncomingHealsCurve2()
        state.casting = false
        state.castTargetUnit = nil
        state.castTargetName = nil
        state.castTargetIndex = 0
        self:updatePlayerCasting(0)
    elseif unitTarget == "target" then
        target.casting = false
    end
end

function CyberDeck:UNIT_SPELLCAST_CHANNEL_START(_, unitTarget, castGUID, spellID, castBarID)
    if unitTarget == "player" then
        state.channeling = true
        state.channelingSpellID = spellID
        self:updatePlayerCasting(spellID)
    elseif unitTarget == "target" then
        target.channeling = true
    end
end

function CyberDeck:UNIT_SPELLCAST_CHANNEL_STOP(_, unitTarget, castGUID, spellID, castBarID)
    if unitTarget == "player" then
        state.channeling = false
        state.castTargetUnit = nil
        state.castTargetName = nil
        state.castTargetIndex = 0
        self:updatePlayerCasting(0)
    elseif unitTarget == "target" then
        target.channeling = false
    end
end

function CyberDeck:UNIT_SPELLCAST_SUCCEEDED(_, unitTarget, castGUID, spellID, castBarID)
    if unitTarget ~= "player" then return end
    -- 必须在 isSec 过滤之前：战斗中 spellID 可能被保护，
    -- 放到后面会让常驻 buff 的有效期锁根本建不起来（像素恒 0 → 反复重开）
    if self.MarkForeverAuraCast then
        pcall(self.MarkForeverAuraCast, self, spellID)
    end
    if isSec(spellID) then return end
    self:updateDrinkStatus(spellID)
    self:updateFailedSpellBySuccess(spellID)
    self:updateAuraBySuccess(spellID, castBarID)
    -- 无限服没有正式服那套"切天赋/切专精"法术（384255 / 200749），改天赋走 PLAYER_TALENT_UPDATE
end

function CyberDeck:UNIT_SPELLCAST_FAILED(_, unitTarget, castGUID, spellID, castBarID)
    if unitTarget ~= "player" then return end
    if not isSec(spellID) then
        self:updateSpellFailed(spellID)
    end
end

function CyberDeck:SPELL_UPDATE_COOLDOWN(_, spellID)
    if issecretvalue(spellID) then return end
    self:updateAuraBySpellCooldown(spellID)
end

function CyberDeck:SPELL_UPDATE_ICON(_, spellID)
    if issecretvalue(spellID) then return end
    self:updateAuraByIcon(spellID)
end

function CyberDeck:COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED(_, baseSpellID, overrideSpellID)
    self:updateAuraBySpellOverride(baseSpellID, overrideSpellID)
end

function CyberDeck:SPELL_ACTIVATION_OVERLAY_GLOW_SHOW(_, spellId)
    self:updateAuraByOverlayGlow(spellId)
end

function CyberDeck:SPELL_ACTIVATION_OVERLAY_GLOW_HIDE(_, spellId)
    self:updateAuraByOverlayGlow(spellId)
end

function CyberDeck:SPELL_ACTIVATION_OVERLAY_SHOW(_, spellId)
    self:updateAuraByActivationOverlayShow(spellId)
end

function CyberDeck:SPELL_ACTIVATION_OVERLAY_HIDE(_, spellId)
    self:updateAuraByActivationOverlayHide(spellId)
end

-- 关注的物品 ID 集合（取无限服物品组 core/forever.lua 的 F.itemGroups）
-- 原来这里写的是正式服物品 ID（241304 银月城生命药水 / 224464 恶魔治疗石 等），
-- 无限服一个都对不上 -> ITEM_COUNT_CHANGED 永远不触发 -> 物品数量不刷新。
local trackedItems = {}
for _, ids in pairs(CyberDeck.itemGroups or {}) do
    for _, id in ipairs(ids) do
        trackedItems[id] = true
    end
end

function CyberDeck:ITEM_COUNT_CHANGED(_, itemID)
    if trackedItems[itemID] then
        self:GetItemCount()
    end
end

function CyberDeck:UNIT_HEALTH(_, unit)
    if unit == "player" then
        self:updatePlayerHealth()
    end
    if unit == "target" then
        self:updateTargetHealth()
    end
    if group[unit] then
        updateUnitDeathByHealthInfo(unit)
    end
end

function CyberDeck:UNIT_MAXHEALTH(_, unit)
    if unit == "player" then
        self:updatePlayerHealth()
    end
    if group[unit] then
        updateUnitDeathByHealthInfo(unit)
    end
end

function CyberDeck:UNIT_HEAL_ABSORB_AMOUNT_CHANGED(_, unit)
    if unit == "player" then
        self:updatePlayerHealth()
    end
    if group[unit] then
        updateUnitHealAbsorbCurve(unit)
        updateUnitDeathByHealthInfo(unit)
    end
end

function CyberDeck:UNIT_HEAL_PREDICTION(_, unit)
    if unit == "player" then
        self:updatePlayerHealth()
    end
    if group[unit] then
        updateUnitDeathByHealthInfo(unit)
    end
end

function CyberDeck:UNIT_POWER_UPDATE(_, unit, powerType)
    if unit ~= "player" then return end
    self:updatePlayerPower(powerType)
end

function CyberDeck:hookChatFrameEditBox()
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        local editBox = _G["ChatFrame" .. i .. "EditBox"]
        if editBox then
            editBox:HookScript("OnEditFocusGained", function()
                state.isChatOpen = true
                self:updatePlayerValid()
            end)
            editBox:HookScript("OnEditFocusLost", function()
                state.isChatOpen = false
                self:updatePlayerValid()
            end)
        end
    end
end

function CyberDeck:SPELL_UPDATE_USES(_, spellID, baseSpellID)

end

local rosterTimer
function CyberDeck:GROUP_ROSTER_UPDATE()
    state.castTargetName, state.castTargetUnit = nil, nil
    if rosterTimer then
        rosterTimer:Cancel()
    end
    rosterTimer = C_Timer.NewTimer(1, function()
        self:updateGroup()
        self:updateGroupCount()
        self:updateGroupType()
        rosterTimer = nil
    end)
end

function CyberDeck:UNIT_DIED(_, unitGUID)
    if not isSec(unitGUID) then
        updateUnitDeath(unitGUID)
    end
end

function CyberDeck:SPELL_RANGE_CHECK_UPDATE()
end

function CyberDeck:ACTION_RANGE_CHECK_UPDATE(_, slot, isInRange, checksRange)
end

function CyberDeck:UI_ERROR_MESSAGE(_, errorType, message)
    if message == "目标不在视野中" then
        updateUnitInSight(state.castTargetUnit)
    elseif message == "射程范围内无有效目标。" then
    end
end

function CyberDeck:UPDATE_BINDINGS()
    self:readKeybindings()
end

function CyberDeck:SPELLS_CHANGED()
    self:readKeybindings()
    -- 学会新技能/新 rank 后重建名称索引，并重新解析像素块里的技能
    self:InvalidateSpellBookIndex()
    if not InCombatLockdown() and self.state and self.state.specIndex then
        self:loadPlayerBlocks(self.state.specIndex)
        self:updateSpellKnown()
    end
end

function CyberDeck:ACTIONBAR_SHOWGRID()
    self:readKeybindings()
end

function CyberDeck:ACTIONBAR_HIDEGRID()
    self:readKeybindings()
end

function CyberDeck:PLAYER_TARGET_CHANGED()
    self:updateTargetFullInfo()
end

function CyberDeck:NAME_PLATE_UNIT_ADDED(_, unit)
    addNameplate(unit)
    self:updateTargetType()
end

function CyberDeck:NAME_PLATE_UNIT_REMOVED(_, unit)
    nameplate[unit] = nil
    self:updateTargetType()
end

function CyberDeck:UPDATE_SHAPESHIFT_FORM()
    self:updateShapeshiftForm()
    self:updatePlayerMounted()
end

function CyberDeck:UPDATE_SHAPESHIFT_FORMS()
    self:updateShapeshiftForm()
    self:updatePlayerMounted()
end

function CyberDeck:TestFiltered(unit, auraInstanceID)
    local AuraFilters = {
        "HELPFUL",
        "HELPFUL HARMFUL",
        "HELPFUL PLAYER",
        "HELPFUL RAID",
        "HELPFUL CANCELABLE",
        "HELPFUL NOT_CANCELABLE",
        "HELPFUL INCLUDE_NAME_PLATE_ONLY",
        "HELPFUL MAW",
        "HELPFUL EXTERNAL_DEFENSIVE",
        "HELPFUL CROWD_CONTROL",
        "HELPFUL RAID_IN_COMBAT",
        "HELPFUL RAID_PLAYER_DISPELLABLE",
        "HELPFUL BIG_DEFENSIVE",
        "HELPFUL IMPORTANT",
    }
    local okaura, aura = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, unit, auraInstanceID)
    if okaura and aura then
        for _, filter in pairs(AuraFilters) do
            local isFiltered = C_UnitAuras.IsAuraFilteredOutByInstanceID(unit, auraInstanceID, filter)
            local boolColored
            if isFiltered then
                boolColored = "|cffff0000" .. tostring(false) .. "|r"
            else
                boolColored = "|cff00ff00" .. tostring(true) .. "|r"
            end
            print(auraInstanceID, aura.name, filter, boolColored)
        end
    end
end

-- ================================================================
-- 队伍驱散像素（照抄 Shingen Forever 版 block.lua:1148-1386）
--
-- 编码（与 Shingen 一致，**不再是类型号**）：
--   每个能驱的类型各占一格，蓝通道 = 该类型在队友身上「最长的剩余秒数」
--     0        = 没有这类减益
--     1        = 有，但不足 1 秒
--     2..254   = 剩余秒数
--     255      = 超过 255 秒 / 永久
--
-- 为什么不再用「一格 + 类型号」：
--   那种写法必须让引擎按 debuff 类型给纹理染色（AddDispelTypeTexture），
--   战斗中类型是 secret，染色链路一断整格就是 0。
--   Shingen 的做法是让引擎用**原生计时文字**驱动颜色：剩余时间是引擎自己算的，
--   插件侧完全不碰光环数据，所以脱战/战斗同一套，不需要两条通道。
--
-- 三条硬约束（缺一不可）：
--   1) 每个类型一条 slot，candidateFilters.includeDispelTypes 只放这一个类型
--   2) SetUnit 会冲掉候选过滤 -> 换单位后必须重绑再 UpdateAllAuras
--   3) 按钮锚 UIParent 的那一格 + SetClipsChildren(true)，cell 子框负责可见范围
-- ================================================================

local dispelProbeUnits = {}     -- [groupIndex] = { container =, slots = {}, unit = }

-- 排序用引擎全局枚举表（Shingen block.lua:1186-1187 队伍驱散槽同款）：
--   ExpirationOnly + Reverse = 同类多个减益时取剩余时间最长的那个
local DISPEL_SORT_METHOD = (AuraContainerSortMethod and AuraContainerSortMethod.ExpirationOnly) or 0
local DISPEL_SORT_DIRECTION = (AuraContainerSortDirection and AuraContainerSortDirection.Reverse) or 0

-- 剩余秒数曲线：x = 剩余秒（0..255），值 = (方案号, 序号, 秒/255)
-- 与 Shingen MakeDurationColorCurve（block.lua:822-830）等价，
-- 只是把格号换成我们自己的总线编码（红=方案号 / 绿=序号）。
local function MakeDispelDurationCurve(cellIndex)
    local r, g = CyberDeck:EncodeBlockChannels(cellIndex)
    local curve = C_CurveUtil.CreateColorCurve()
    curve:SetType(Enum.LuaCurveType.Linear)
    curve:AddPoint(0, CreateColor(r, g, 1 / 255, 1))
    curve:AddPoint(1, CreateColor(r, g, 1 / 255, 1))
    curve:AddPoint(255, CreateColor(r, g, 1, 1))
    return curve
end

-- 加载 Blizzard_AuraContainer（Shingen block.lua:1163-1167 同款）
-- 不加载的话 CreateFrame 拿不到 CustomAuraContainerTemplate 的完整行为
local function EnsureAuraContainerLoaded()
    if C_AddOns and not C_AddOns.IsAddOnLoaded("Blizzard_AuraContainer") then
        pcall(C_AddOns.LoadAddOn, "Blizzard_AuraContainer")
    end
end

-- 某个队友某一类驱散对应的色条格号
local function getDispelCell(typeName, index)
    local groups = blocks and blocks.groups
    local offset = groups and groups.dispelCells and groups.dispelCells[typeName]
    if not offset then return nil end
    return groups.start + (index - 1) * groups.num + offset
end

-- 释放探针容器（Shingen ReleaseFrame 同款：停用 + 隐藏 + 脱离父级）
-- ★ 不用 Destroy()：AuraContainer 上不保证有这个方法，pcall 吞掉后容器会留在屏幕上
--   继续按旧单位染色，那一格就永远停在上一个队友的值。
local function ReleaseProbeContainer(probe)
    if not probe or not probe.container then return end
    pcall(function() probe.container:SetEnabled(false) end)
    pcall(function() probe.container:Hide() end)
    pcall(function() probe.container:SetParent(nil) end)
end

-- 建/更新某个队友的探针：一个容器 + 每个可驱类型一条 slot
function CyberDeck:UpdateDispelProbeUnit(index, unit)
    if not blocks or not blocks.groups or not blocks.groups.dispelCells then return end
    if not _G.CyberDeckColorBars then return end

    local probe = dispelProbeUnits[index]
    if not probe then
        EnsureAuraContainerLoaded()
        local container = CreateFrame("AuraContainer",
            "CyberDeckGroupDispelSlots_" .. index, UIParent, "CustomAuraContainerTemplate")
        container:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
        container:SetFrameStrata("TOOLTIP")
        container:SetFrameLevel(10001)     -- 必须高于色条（10000）
        pcall(function() container:EnableMouse(false) end)
        probe = { container = container, slots = {}, unit = nil }
        dispelProbeUnits[index] = probe
    end

    local unitChanged = (probe.unit ~= unit)
    -- ★ 0.12 秒一档的轮询：槽位齐了、单位没变、不需要重绑就直接返回，
    --   否则每 tick 会对 30 个成员各做一次 SetShown/SetEnabled/pairs，纯浪费。
    if not unitChanged and probe.ready and not probe.needRebind then return end
    if unitChanged then
        probe.unit = unit
        pcall(function() probe.container:SetUnit(unit) end)
    end

    local missing = 0
    for typeName in pairs(blocks.groups.dispelCells) do
        local cell = getDispelCell(typeName, index)
        local rect = cell and CyberDeck:GetColorBarCellRect(cell)
        if rect then
            local slotKey = ("CD_DISPEL_%d_%s"):format(index, typeName)
            if not probe.slots[slotKey] then
                missing = missing + 1
                -- 只有 AddAuraSlot 真成功才记账，失败下个 tick 重试（0.12 秒一档）
                local curve = MakeDispelDurationCurve(cell)
                local okSlot, errSlot = pcall(function()
                    probe.container:AddAuraSlot(slotKey, "HARMFUL", {
                        candidateFilters = { includeDispelTypes = { [typeName] = true } },
                        sortMethod = DISPEL_SORT_METHOD,
                        sortDirection = DISPEL_SORT_DIRECTION,
                        initializeFrame = function(button)
                          local okInit, errInit = pcall(function()
                              -- 1) 按钮精确到一格 + 裁剪子级（引擎会把按钮撑大）
                              pcall(function() button:EnableMouse(false) end)
                              pcall(function() button:SetMouseMotionEnabled(false) end)
                              button:SetSize(rect.w, rect.h)
                              button:SetClipsChildren(true)
                              -- 2) 锚 UIParent（container 的父级），坐标与色条同值
                              button:ClearAllPoints()
                              button:SetPoint("TOPLEFT", UIParent, "TOPLEFT", rect.x, 0)
                              button:SetFrameLevel(probe.container:GetFrameLevel() + 1)

                              -- 3) cell 子框：可见范围只有一格
                              local cellFrame = CreateFrame("Frame", nil, button)
                              cellFrame:SetSize(rect.w, rect.h)
                              cellFrame:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
                              cellFrame:SetClipsChildren(true)
                              pcall(function() cellFrame:EnableMouse(false) end)

                              -- 底色整格 b=1：永久/无计时兜底（Shingen 注释「保留 255 底色」）
                              local r, g = CyberDeck:EncodeBlockChannels(cell)
                              local bg = cellFrame:CreateTexture(nil, "BACKGROUND")
                              bg:SetAllPoints(cellFrame)
                              bg:SetColorTexture(r, g, 1, 1)

                              -- 计时文字：█ 字形盖满整格，颜色由引擎按剩余秒数算
                              local text = cellFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
                              text:SetPoint("CENTER", cellFrame, "CENTER", 0, 0)
                              text:SetJustifyH("CENTER")
                              text:SetJustifyV("MIDDLE")
                              button:SetDurationText(text, {
                                  textFormat = { formatString = "█", components = {} },
                                  textColor = {
                                      curve = curve,
                                      property = Enum.DurationTextBindingProperty.RemainingDuration,
                                  },
                              })
                          end)
                          if not okInit and not CyberDeck.dispelProbeInitWarned then
                              CyberDeck.dispelProbeInitWarned = true
                              CyberDeck:Print(("|cffff0000驱散像素初始化失败|r（%s）: %s")
                                  :format(tostring(typeName), tostring(errInit)))
                          end
                        end,
                    })
                end)
                if okSlot then
                    probe.slots[slotKey] = true
                elseif not CyberDeck.dispelProbeWarned then
                    CyberDeck.dispelProbeWarned = true
                    self:Print(("|cffff0000驱散槽注册失败|r（%s）: %s")
                        :format(tostring(typeName), tostring(errSlot)))
                end
            end
        end
    end

    if missing == 0 then
        probe.ready = true
    end

    -- 顺序照抄 Shingen / Decursive：AddAuraSlot 之后再 SetShown/SetEnabled
    pcall(function() probe.container:SetShown(true) end)
    pcall(function() probe.container:SetEnabled(true) end)

    -- ★ SetUnit 会冲掉候选过滤 -> 换单位/过场后必须重绑再刷新
    --   顺序固定：SetUnit -> SetAuraSlotCandidateFilters -> UpdateAllAuras
    if unitChanged or probe.needRebind then
        probe.needRebind = false
        for typeName in pairs(blocks.groups.dispelCells) do
            local slotKey = ("CD_DISPEL_%d_%s"):format(index, typeName)
            pcall(function()
                probe.container:SetAuraSlotCandidateFilters(slotKey, {
                    includeDispelTypes = { [typeName] = true },
                })
            end)
        end
        pcall(function() probe.container:UpdateAllAuras() end)
    end
end

-- 队友集合变化时重建探针（换人/退队要把旧探针清掉）
-- 队伍签名：成员或顺序变了就变了
local function groupSignature()
    local parts = {}
    for unit, data in pairs(group or {}) do
        if data and data.index then
            parts[#parts + 1] = tostring(unit) .. ":" .. tostring(data.index)
        end
    end
    table.sort(parts)
    return table.concat(parts, ",")
end

function CyberDeck:SyncDispelProbes()
    if not group or not blocks or not blocks.groups then return end
    -- 未移植职业（旧单格协议）没有 dispelCells，直接跳过
    if not blocks.groups.dispelCells then return end
    -- 队伍构成/顺序变了 -> 所有探针都要重绑候选过滤
    -- （SetUnit 会冲掉过滤，且引擎会改写 candidateFilters 原表）
    local sig = groupSignature()
    if sig ~= self.dispelProbeSig then
        self.dispelProbeSig = sig
        for _, probe in pairs(dispelProbeUnits) do
            probe.needRebind = true
        end
    end
    for index, probe in pairs(dispelProbeUnits) do
        local data = group and group[probe.unit]
        if probe.dead and not InCombatLockdown() then
            -- 脱战后把战斗中停用的探针释放掉，下一轮重建
            ReleaseProbeContainer(probe)
            dispelProbeUnits[index] = nil
        elseif not data or data.index ~= index then
            if InCombatLockdown() then
                -- ★ 战斗中不拆容器（Shingen 从不 Destroy，只 SetEnabled/Show 复用）：
                --   AuraButton 子树在 auras secret 期间重建不可靠，换人/换位时
                --   先停用（不会再染色），脱战后的下一轮 Sync 再释放重建。
                probe.dead = true
                pcall(function() probe.container:SetEnabled(false) end)
                pcall(function() probe.container:Hide() end)
            else
                ReleaseProbeContainer(probe)
                dispelProbeUnits[index] = nil
            end
        end
    end
    for unit, data in pairs(group or {}) do
        if data and data.index then
            local stale = dispelProbeUnits[data.index]
            if not (stale and stale.dead) then
                self:UpdateDispelProbeUnit(data.index, unit)
            end
        end
    end
end

-- 过场后光环缓存可能失效，强制重绑一次（Shingen 注释：过场后要重绑全部过滤）
function CyberDeck:MarkDispelProbesRebind()
    for _, probe in pairs(dispelProbeUnits) do
        probe.needRebind = true
    end
end

-- 释放全部探针（换专精 / blocks 重载时用）
-- 战斗中不释放，只停用并标 dead，脱战后由 SyncDispelProbes 收尸重建。
function CyberDeck:ResetDispelProbes()
    for index, probe in pairs(dispelProbeUnits) do
        if InCombatLockdown() then
            probe.dead = true
            pcall(function() probe.container:SetEnabled(false) end)
            pcall(function() probe.container:Hide() end)
        else
            ReleaseProbeContainer(probe)
            dispelProbeUnits[index] = nil
        end
    end
    self.dispelProbeSig = nil
end

-- 队伍驱散格**只有引擎一个写入方**（Shingen 同款）：
-- 计时文字的颜色由引擎按剩余秒数算，Lua 侧不读光环、也不写那一格。
-- 脱战/战斗是同一套，不存在两条通道抢同一格的问题。

function CyberDeck:UNIT_AURA(_, unit, info)
    local obj = group[unit]
    if not obj then return end
    if safeTruthy(info.isFullUpdate) then
        self:updateUnitFullAura(unit)
        return
    end
    if safeTruthy(info.addedAuras) then
        for k, v in pairs(info.addedAuras) do
            if not isSec(v.spellId) and v.sourceUnit == "player" then
                obj.aura[v.auraInstanceID] = v
            end
        end
    end
    if safeTruthy(info.updatedAuraInstanceIDs) then
        for _, v in pairs(info.updatedAuraInstanceIDs) do
            -- 战斗中 instanceID / spellId / sourceUnit 都可能是 secret，整体包一层
            pcall(function()
                local aura = C_UnitAuras.GetAuraDataByAuraInstanceID(unit, v)
                if aura and not isSec(aura.spellId) and aura.sourceUnit == "player" then
                    obj.aura[aura.auraInstanceID] = aura
                end
            end)
        end
    end
    if safeTruthy(info.removedAuraInstanceIDs) then
        for _, v in pairs(info.removedAuraInstanceIDs) do
            obj.aura[v] = nil
        end
    end
end

function CyberDeck:StartFrameUpdates()
    if not self.updateFrame then
        self.updateFrame = CreateFrame("Frame")
    end
    local parent = self
    self.updateFrame:SetScript("OnUpdate", function(frame, elapsed)
        parent:OnUpdate(elapsed)
    end)
end

CyberDeck.timeElapsed = 0
function CyberDeck:OnUpdate(elapsed)
    -- 1. 高频逻辑（每帧执行）
    -- 这里的函数必须确保能被访问到，如果是成员函数请加 self:
    self:updatePlayerCastingInfo()
    self:updatePlayerChannelingInfo()
    self:updateUnitCastingOrChannelingInfo("target")
    pcall(self.updateUnitCastingOrChannelingInfo, self, "focus")
    self:updateGroupInRangeAndHealth()
    self:updateAura()
    self:updateTargetAuraCount()
    -- 2. 低频逻辑（每 0.12 秒执行）
    -- 技能 CD 走这一档，0.2 秒会让「CD 好了但还没放」多等最多 200ms；
    -- 降到 0.12 与 Python 侧的 0.1 错开，避免两边同频导致一顿一顿。
    self.timeElapsed = self.timeElapsed + elapsed
    if self.timeElapsed > 0.12 then
        self:updateSpellCooldown()
        self:OnUpdateUnitAura()
        self:updateAura()
        self:updateTargetRangeBlock()
        self:updateEnemyCount()
        self:updateItemCoolDown()
        self:UpdateForeverAuras()
        self:UpdateForeverAutoAttack()
        -- 队伍驱散探针：每个队友一个容器，每个可驱类型一条 slot，
        -- 颜色/计时全部由引擎驱动（Lua 不写那一格）
        if self.SyncDispelProbes then self:SyncDispelProbes() end
        self.timeElapsed = 0
    end
end

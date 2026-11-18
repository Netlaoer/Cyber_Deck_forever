local addon, ns = ...
local isSec = issecretvalue
local GetSpellCooldownDuration = C_Spell.GetSpellCooldownDuration
local GetSpellChargeDuration = C_Spell.GetSpellChargeDuration
local GetSpellCooldown = C_Spell.GetSpellCooldown
local GetSpellName = C_Spell.GetSpellName
local IsSpellKnown = C_SpellBook.IsSpellKnown
local IsSpellInSpellBook = C_SpellBook.IsSpellInSpellBook
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
local roleMap, spellsList, EnumPowerType = CyberDeck.roleMap, CyberDeck.spellsList, CyberDeck.EnumPowerType
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

local dispelCurve = C_CurveUtil.CreateColorCurve()
target.enemyCurve = C_CurveUtil.CreateColorCurve()
target.friendCurve = C_CurveUtil.CreateColorCurve()

dispelCurve:SetType(Enum.LuaCurveType.Step)
target.enemyCurve:SetType(Enum.LuaCurveType.Step)
target.friendCurve:SetType(Enum.LuaCurveType.Step)

-- ================================================================
--                          通用函数
-- ================================================================

-- 更新单位拥有玩家光环的数量
function CyberDeck:updateUnitAuraCount(unit)
    local auraInstanceIDs = self:GetAuraInstanceIDs(unit, "HARMFUL|PLAYER", 1, 4)
    if auraInstanceIDs then
        return #auraInstanceIDs
    end
    return 0
end

-- 更新单位距离
local function updateUnitRange(unit)
    local minRange, maxRange = rc:GetRange(unit)
    return minRange, maxRange
end

-- 打印成功施放的技能id和名称, 不重复打印已经施放的技能
-- 打印格式为  [spellID] = { index = i, }, -- 技能名称
local succSpells = {}
local succIndex = 1
local function printSuccSpell(spellID)
    if succSpells[spellID] or CyberDeck.spellsList[spellID] then return end
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
local dispelAbilities = {
    [1] = { 527, 360823, 4987, 115450, 88423, 77130 },              -- 魔法驱散
    [2] = { 383016, 51886, 392378, 2782, 475 },                     -- 诅咒驱散
    [3] = { 390632, 213634, 393024, 213644, 388874, 218164 },       -- 疾病驱散
    [4] = { 392378, 2782, 393024, 213644, 388874, 218164, 365585 }, -- 中毒驱散
    [11] = {}                                                       -- 流血驱散
}

-- 进攻驱散能力映射
local offensiveDispelAbilities = {
    [1] = { 528 },  -- 魔法
    [9] = { 2908 }, -- 激怒
}

-- 检查玩家是否学习了多个法术中的任意一个
local function hasLearnedAnySpell(spellIDs)
    for _, spellID in ipairs(spellIDs) do
        if IsSpellKnown(spellID) then
            return true
        end
    end
    return false
end

local function updateCooldownSpellKnown()
    spells = {}
    if not blocks.spells then return end
    C_Timer.After(1, function()
        for spellID, info in pairs(blocks.spells) do
            -- 无限服：key 已经是 ResolveSpellID 用 C_SpellBook.IsSpellKnown 过滤过的 rank ID，
            -- 这里再用全局 IsSpellKnown 复核一遍，一旦两套 API 对 rank 的语义不一致，
            -- 会把已学会的技能整体误标成 255，整条决策链失效。所以无限服直接信任解析结果。
            local isKnown = CyberDeck.isForever and true or IsSpellKnown(spellID)
            if not CyberDeck.isForever and info.inSpellBook then
                isKnown = IsSpellInSpellBook(spellID)
            end
            local index = info.index
            if isKnown or info.forcedKnown then
                spells[spellID] = info
            elseif index then
                CyberDeck:CreatTexture(index, 1)
            end
        end
    end)
end

-- 更新法术已知状态
function CyberDeck:updateSpellKnown()
    updateCooldownSpellKnown()

    -- 动态生成防御驱散能力
    local dispelCapabilities = {
        [1] = false,  -- 魔法驱散
        [2] = false,  -- 疾病驱散
        [3] = false,  -- 诅咒驱散
        [4] = false,  -- 中毒驱散
        [11] = false, -- 流血
    }
    -- 动态生成进攻驱散能力
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

    dispelCurve:ClearPoints()
    target.enemyCurve:ClearPoints()
    target.friendCurve:ClearPoints()

    for i, v in pairs(dispelCapabilities) do
        if v then
            dispelCurve:AddPoint(i, CreateColor(0, 1, i / 255, 1))
            target.friendCurve:AddPoint(i, CreateColor(0, 1, (i + 11) / 255, 1))
        else
            dispelCurve:AddPoint(i, CreateColor(0, 0, 0, 1))
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
    self:updatePlayerEmpowerInfo()                  -- 9.蓄力  10.蓄力层数
    self:updatePlayerHealth()                       -- 11.生命值
    self:updatePlayerPowerType()                    -- 12.能量值
    self:updatePlayerAssistant()                    -- 13.一键辅助
    -- 14. 法术失败
    self:updateTargetValid()                        -- 15.目标类型
    self:updateGroupType()                          -- 16.队伍类型
    self:updateGroupCount()                         -- 17.队伍人数
    -- 18. 19. 更新boss战ID和难度
    self:updateHeroTalent()                         -- 20.英雄天赋

    self:updatePlayerBarInfo()                      -- 创建玩家bar信息
    self:updateShapeshiftForm()                     -- 姿态
    self:updatePlayerStagger()                      -- 酒池
    self:updateRune()                               -- 符文
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

-- 载入玩家blocks配置
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
            if not spellID and v.name and self.isForever then
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
            blocks.groups.dispel = v.dispel
            blocks.groups.auras = v.auras
            if v.rejuv then
                blocks.groups.rejuv = v.rejuv
            end
        end
    end
    self.blocks = blocks
end

-- 载入玩家宏
function CyberDeck:loadPlayerMacros()
    if not self.MacrosList then
        return
    end
    local m = self.MacrosList
    self:CreateMacro(m.dynamicSpells, m.staticSpells, m.specialSpells)
end

-- 1. 首次登录获取角色信息
function CyberDeck:GetCharacterInfo()
    self.db.char.level = UnitLevel("player")
    self.state.name = UnitName("player")
    self.state.GUID = UnitGUID("player")
    self.state.classColor = RAID_CLASS_COLORS[self.state.classFilename].colorStr
end

-- 2. 首次登录获取玩家专精信息
function CyberDeck:GetCharacterSpecInfo()
    if self.isForever then
        self.state.specIndex = self:GetActiveSpecIndex()
        local info = self:GetForeverSpecInfo(self.state.specIndex)
        self.state.specID = info.id
        self.state.specName = info.name
        self.state.specRole = info.role
        self.state.specRange = info.range
    else
        self.state.specIndex = C_SpecializationInfo.GetSpecialization()
        local specID, specName, _, _, role = C_SpecializationInfo.GetSpecializationInfo(self.state.specIndex)
        self.state.specID = specID
        self.state.specName = specName
        self.state.specRole = role
        self.state.specRange = self.rangeSpecID[specID]
    end
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

-- 2. 更新玩家专精信息
function CyberDeck:updatePlayerSpecInfo()
    self:clearAllTextures()
    if self.isForever then
        self.state.specIndex = self:GetActiveSpecIndex()
        local info = self:GetForeverSpecInfo(self.state.specIndex)
        self.state.specID = info.id
        self.state.specName = info.name
        self.state.specRole = info.role
        self.state.specRange = info.range
    else
        self.state.specIndex = C_SpecializationInfo.GetSpecialization()
        local specID, specName, _, _, role = C_SpecializationInfo.GetSpecializationInfo(self.state.specIndex)
        self.state.specID = specID
        self.state.specName = specName
        self.state.specRole = role
        self.state.specRange = self.rangeSpecID[specID]
    end
    self:loadPlayerBlocks(self.state.specIndex) -- 载入玩家blocks配置

    self:updateSpellKnown()                     -- 更新法术已知状态
    self:updatePlayerBlocks()                   -- 更新玩家blocks信息
    self:CreatTexture(blocks.state["职业"], self.state.classId / 255)
    self:CreatTexture(blocks.state["专精"], self.state.specIndex / 255)
end

-- 4. 更新玩家有效性
function CyberDeck:updatePlayerValid()
    local valid = not state.isDead and not state.mounted and not state.isChatOpen and not state.drinkStatus
    state.valid = valid and 1 / 255 or 0
    self:CreatTexture(blocks.state["有效性"], state.valid)
end

-- 5. 更新玩家战斗状态
function CyberDeck:updatePlayerCombat()
    local combat = UnitAffectingCombat("player")
    state.combat = combat and 1 / 255 or 0
    self:CreatTexture(blocks.state["战斗"], state.combat)
end

-- 6. 更新玩家移动状态
function CyberDeck:updatePlayerMoving(boolean)
    state.drinkStatus = false
    self:updatePlayerValid()
    state.moving = boolean and 1 / 255 or 0
    self:CreatTexture(blocks.state["移动"], state.moving)
end

-- 7. 更新玩家施法状态
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

-- 8. 更新玩家引导状态
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

-- 9. 10. 更新玩家蓄力状态（仅唤魔师；圣骑士等没有这两个像素块时直接跳过）
function CyberDeck:updatePlayerEmpowerInfo()
    local empowerIndex = blocks and blocks.state and blocks.state["蓄力"]
    local stageIndex = blocks and blocks.state and blocks.state["蓄力层数"]
    if not empowerIndex and not stageIndex then
        state.empowerDuration = 0
        state.empowerStage = 0
        return
    end
    if state.empowering then
        local empowerStages = UnitEmpoweredStageDurations("player")
        local empowerDuration = UnitEmpoweredChannelDuration("player")
        if empowerDuration and empowerIndex then
            local empowerDurationColor = empowerDuration:EvaluateRemainingDuration(castCurve)
            ---@diagnostic disable-next-line: param-type-mismatch
            local _, _, b = empowerDurationColor:GetRGB()
            state.empowerDuration = b
            self:CreatTexture(empowerIndex, state.empowerDuration)
        end
        if empowerStages and stageIndex then
            for k, v in pairs(empowerStages) do
                local empower = v:EvaluateRemainingDuration(castCurve)
                ---@diagnostic disable-next-line: param-type-mismatch
                local _, _, b = empower:GetRGB()
                state.empowerStage = (k - 1) / 255
                self:CreatTexture(stageIndex, state.empowerStage)
                if b > 0 then
                    break
                end
            end
        end
    else
        state.empowerDuration = 0
        state.empowerStage = 0
        if empowerIndex then self:CreatTexture(empowerIndex, 0) end
        if stageIndex then self:CreatTexture(stageIndex, 0) end
    end
end

-- 11. 更新玩家血量信息
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
-- 12. 更新玩家能量值
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
        elseif self.isForever then
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

-- 13. 更新玩家[一键辅助]
function CyberDeck:updatePlayerAssistant()
    local index = blocks and blocks.state and blocks.state["一键辅助"]
    if not index then
        -- 无限服没有一键辅助，且圣骑士块表里不建这个块
        state.assistantSpell = 0
        return
    end
    local spellIndex = 0
    if C_AssistedCombat and C_AssistedCombat.GetNextCastSpell then
        local ok, spellId = pcall(C_AssistedCombat.GetNextCastSpell)
        if ok and type(spellId) == "number" and spellsList[spellId] then
            spellIndex = spellsList[spellId].index or 0
        end
    end
    state.assistantSpell = spellIndex / 255
    self:CreatTexture(index, state.assistantSpell)
end

-- 14. 更新玩家法术失败
function CyberDeck:updateSpellFailed(spellID)
    local isUsable = C_Spell.IsSpellUsable(spellID)

    if spellsList[spellID] and spellsList[spellID].failed then
        failedSpell = spellsList[spellID].index
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

-- 14. 通过施法成功更新玩家法术失败
function CyberDeck:updateFailedSpellBySuccess(spellID)
    if spellID ~= failedSpellId then return end
    failedSpell = nil
    failedSpellId = nil
    print("|cff00ff00插入技能: |r", GetSpellName(spellID))
    self:CreatTexture(blocks.state["法术失败"], 0)
end

-- 15. 更新目标类型
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

    local auraInstanceIDs = CyberDeck:GetAuraInstanceIDs(unit, filter, 1, 4)

    if auraInstanceIDs and #auraInstanceIDs > 0 then
        local color = CyberDeck:GetAuraDispelTypeColor(unit, auraInstanceIDs[1], curve)
        if color then return color.b end
    end
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

function CyberDeck:updateTargetAuraCount()
    if not UnitExists("target") then return end
    if blocks and blocks.state["目标光环数量"] then
        local auraCount = self:updateUnitAuraCount("target")
        state.targetAuraCount = (auraCount or 0) / 255
        self:CreatTexture(blocks.state["目标光环数量"], state.targetAuraCount)
    end
end

-- 16. 更新玩家队伍类型
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

-- 17. 更新玩家队伍人数
function CyberDeck:updateGroupCount()
    local count = GetNumGroupMembers()
    state.groupCount = count / 255 or 0
    self:CreatTexture(blocks.state["队伍人数"], state.groupCount)
end

-- 18. 19. 更新boss战ID和难度
function CyberDeck:updateEncounterID(encounterID, difficultyID)
    state.encounterID = encounterID
    --[[更新难度ID
            1 = "5人本普通", -- Normal (Dungeon)
            2 = "5人本英雄", -- Heroic (Dungeon)
            14 = "团本普通", -- Normal (Raid)
            15 = "团本英雄", -- Heroic (Raid)
            16 = "团本史诗", -- Mythic (Raid)
            17 = "团本随机", -- Looking (Raid)
            23 = "5人本史诗", -- Mythic (Dungeon)
        ]]
    local id = self.bossID and self.bossID[encounterID] or 0
    if id then
        state.bossID = id / 255 or 0
        self:CreatTexture(blocks.state["首领战"], state.bossID)
    else
        state.bossID = 0
        self:CreatTexture(blocks.state["首领战"], state.bossID)
    end
    state.difficultyID = difficultyID
    self:CreatTexture(blocks.state["难度"], (state.difficultyID or 0) / 255)
end

-- 20. 更新玩家英雄天赋
function CyberDeck:updateHeroTalent()
    if self.isForever then
        -- 无限服没有英雄天赋
        self.state.heroTalent = 0
        if blocks.state["英雄天赋"] then
            self:CreatTexture(blocks.state["英雄天赋"], 0)
        end
        return
    end
    if self.heroTalents and blocks.state["英雄天赋"] then
        C_Timer.After(1, function()
            self.state.heroTalent = 0
            for spellID, index in pairs(self.heroTalents) do
                if IsSpellKnown(spellID) or IsSpellInSpellBook(spellID) then
                    self.state.heroTalent = index
                    break
                end
            end
            self:CreatTexture(blocks.state["英雄天赋"], self.state.heroTalent / 255)
        end)
    end
end

-- 创建玩家bar信息
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
        local castingSpell = spellsList[spellId] and spellsList[spellId].index or 0
        state.castingSpell = castingSpell / 255 or 0
        if castingSpell then
            self:CreatTexture(blocks.state["施法技能"], state.castingSpell)
        else
            self:CreatTexture(blocks.state["施法技能"], 0)
        end
    end
end

-- 更新玩家配置
function CyberDeck:updatePlayerConfig()
    local c = self.db and self.db.char
    if not c or not blocks then return end
    if blocks.state["爆发开关"] then
        self:CreatTexture(blocks.state["爆发开关"], (c.cooldowns or 0) / 255)
    end
    if blocks.state["AOE开关"] then
        self:CreatTexture(blocks.state["AOE开关"], (c.aoeMode or 0) / 255)
    end
    if blocks.state["输出模式"] then
        self:CreatTexture(blocks.state["输出模式"], (c.dpsMode or 0) / 255)
    end
    if blocks.state["爆发药水开关"] then
        self:CreatTexture(blocks.state["爆发药水开关"], (c.potion or 0) / 255)
    end
    if blocks.state["驱散开关"] then
        self:CreatTexture(blocks.state["驱散开关"], (c.dispel or 1) / 255)
    end
end

-- 更新玩家酒池百分比
function CyberDeck:updatePlayerStagger()
    if blocks and blocks.state["酒池"] then
        local unit = "player"
        local damage = UnitStagger(unit)
        local maxHealth = UnitHealthMax(unit)
        local staggerPercent = damage / maxHealth * 100
        state.staggerPercent = (staggerPercent or 0) / 255
        self:CreatTexture(blocks.state["酒池"], state.staggerPercent)
    end
end

-- 更新玩家符文
function CyberDeck:updateRune()
    if blocks and blocks.state["符文"] then
        local total = 0
        for i = 1, 6 do
            local runeCount = GetRuneCount(i)
            if runeCount then
                total = total + runeCount
            end
        end
        state.runeCount = total / 255 or 0
        self:CreatTexture(blocks.state["符文"], state.runeCount)
    end
end

-- 获取玩家形态
function CyberDeck:updateShapeshiftForm()
    local shapeshiftFormID = GetShapeshiftFormID() or 0
    state.shapeshiftFormID = shapeshiftFormID / 255
    if blocks and blocks.state["姿态"] then
        self:CreatTexture(blocks.state["姿态"], state.shapeshiftFormID)
    end
end

local diseaseJudgeTimer = nil
function CyberDeck:updateDiseaseJudge()
    if blocks and blocks.state["疾病判断"] then
        state.diseaseJudge = 1 / 255 or 0
        self:CreatTexture(blocks.state["疾病判断"], state.diseaseJudge)
        if diseaseJudgeTimer then
            diseaseJudgeTimer:Cancel()
            diseaseJudgeTimer = nil
        end
        diseaseJudgeTimer = C_Timer.NewTimer(1, function()
            state.diseaseJudge = 0
            self:CreatTexture(blocks.state["疾病判断"], state.diseaseJudge)
            diseaseJudgeTimer = nil
        end)
    end
end

-- 更新防御光环
function CyberDeck:GetDefensiveAuraInstanceID(unit, info)
    if unit ~= "player" then return end
    if info.addedAuras then
        for i = 1, 2 do
            local aura = C_UnitAuras.GetBuffDataByIndex(unit, i, "HELPFUL|BIG_DEFENSIVE")
            if not issecretvalue(aura) and aura then
                state.DefensiveAuraInstanceID = aura.auraInstanceID
            end
        end
    end
    if info.removedAuraInstanceIDs then
        for _, v in pairs(info.removedAuraInstanceIDs) do
            if v == state.DefensiveAuraInstanceID then
                state.DefensiveAuraInstanceID = nil
            end
        end
    end
end

function CyberDeck:GetDefensiveAuraDuration()
    if blocks and blocks.state["防御光环"] then
        if state.DefensiveAuraInstanceID then
            local duration = C_UnitAuras.GetAuraDuration("player", state.DefensiveAuraInstanceID)
            if duration then
                local auraduration = duration:EvaluateRemainingDuration(curve255)
                ---@diagnostic disable-next-line: param-type-mismatch
                local _, _, b = auraduration:GetRGB()
                self:CreatTexture(blocks.state["防御光环"], b)
            else
                self:CreatTexture(blocks.state["防御光环"], 0)
            end
        else
            self:CreatTexture(blocks.state["防御光环"], 0)
        end
    end
end

-- 更新法术冷却信息
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

-- 更新目标是否可以攻击
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

-- 更新目标是否死亡
function CyberDeck:updateTargetDeath()
    target.isDead = UnitIsDeadOrGhost("target")
    self:updateTargetValid()
end

-- 更新目标生命值
function CyberDeck:updateTargetHealth()
    local healthPercent = UnitHealthPercent("target", false, curve100)
    ---@diagnostic disable-next-line: param-type-mismatch
    local _, _, b = healthPercent:GetRGB()
    target.healthPercent = b or 0
    if blocks and blocks.state["目标生命值"] then
        self:CreatTexture(blocks.state["目标生命值"], b)
    end
end

-- 更新目标完整信息
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
-- 更新范围内敌方姓名版数量
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

-- 通过施放成功获取喝水状态
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
    -- print("目标不在视野中", obj.name)
    if obj.inSightTimer then
        obj.inSightTimer:Cancel()
        obj.inSightTimer = nil
    end
    obj.inSightTimer = C_Timer.NewTimer(1.5, function()
        obj.inSight = true
        obj.inSightTimer = nil
        -- print("目标在视野中", obj.name)
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
        local buff = C_UnitAuras.GetBuffDataByIndex(unit, i, "PLAYER|HELPFUL|RAID_IN_COMBAT")
        if buff then
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
                local duration = C_UnitAuras.GetAuraDuration(unit, maxAura.auraInstanceID)
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

local function getAuraDispelTypeColor(unit)
    local obj = group[unit]
    if not blocks.groups or not obj then return end
    local index = blocks.groups.start + (obj.index - 1) * blocks.groups.num + blocks.groups.dispel
    local auraInstanceIDs = CyberDeck:GetAuraInstanceIDs(unit, "HARMFUL|RAID_PLAYER_DISPELLABLE", 1, 4)
    if auraInstanceIDs and #auraInstanceIDs > 0 then
        local color = CyberDeck:GetAuraDispelTypeColor(unit, auraInstanceIDs[1], dispelCurve)
        if color then
            CyberDeck:CreatTexture(index, color.b)
        end
    else
        CyberDeck:CreatTexture(index, 0)
    end
end

function CyberDeck:clearGroupBlocks()
    if blocks.groups and blocks.groups.start then
        local startIndex = blocks.groups.start
        for index = startIndex, 255 do
            self:CreatTexture(index, 0)
        end
    end
end

function CyberDeck:updateGroup()
    self.group = {}
    self.groupList = {}
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
end

-- ================================================================
--                          事件
-- ================================================================

function CyberDeck:ZONE_CHANGED()
    state.mapID = C_Map.GetBestMapForUnit("player") or 0
    state.mapInfo = C_Map.GetMapInfo(state.mapID)
    state.subzone = GetSubZoneText()
    -- print("ZONE_CHANGED", state.mapID, state.mapInfo, state.subzone)
    if GetBindLocation() == state.subzone then
        self:Print("欢迎回家!")
    end
end

function CyberDeck:ZONE_CHANGED_INDOORS()
    state.mapID = C_Map.GetBestMapForUnit("player") or 0
    state.mapInfo = C_Map.GetMapInfo(state.mapID)
    state.subzone = GetSubZoneText()
    -- print("ZONE_CHANGED_INDOORS", state.mapID, state.mapInfo, state.subzone)
    if GetBindLocation() == state.subzone then
        self:Print("欢迎回家!")
    end
end

function CyberDeck:PLAYER_ENTERING_WORLD()
    state.mapID = C_Map.GetBestMapForUnit("player") or 0
    self:updateHeroTalent()
end

function CyberDeck:PLAYER_TALENT_UPDATE()
    self:updatePlayerSpecInfo()
    self:updateGroup()
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

-- 战斗状态更新
function CyberDeck:PLAYER_REGEN_DISABLED()
    self:updateTargetType()
    self:updatePlayerCombat()
end

function CyberDeck:PLAYER_REGEN_ENABLED()
    self:updateTargetType()
    self:updatePlayerCombat()
end

-- 移动状态更新
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
        -- print(state.castTargetUnit, state.castTargetName, state.castTargetIndex)
    end
end

-- 施法状态
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
        -- print("结束施法时间:", GetTime())
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

-- 引导状态
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

-- 蓄力状态
function CyberDeck:UNIT_SPELLCAST_EMPOWER_START(_, unitTarget, castGUID, spellID, castBarID)
    if unitTarget == "player" then
        state.empowering = true
        state.empoweringSpellID = spellID
        self:updatePlayerCasting(spellID)
    elseif unitTarget == "target" then
        target.empowering = true
    end
end

function CyberDeck:UNIT_SPELLCAST_EMPOWER_STOP(_, unitTarget, castGUID, spellID, complete, interruptedBy, castBarID)
    if unitTarget ~= "player" then
        state.empowering = false
        state.castTargetUnit = nil
        state.castTargetName = nil
        state.castTargetIndex = 0
        self:updatePlayerCasting(0)
    elseif unitTarget == "target" then
        target.empowering = false
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
    -- printSuccSpell(spellID)
    self:updateFailedSpellBySuccess(spellID)
    self:updateAuraBySuccess(spellID, castBarID)
    if spellID == 384255 then
        self:ClearAllCyberDeckBars()
        print("切换天赋")
        C_Timer.After(1, function()
            self:updatePlayerSpecInfo()
        end)
    elseif spellID == 200749 then
        self:ClearAllCyberDeckBars()
        print("切换专精")
        C_Timer.After(1, function()
            self:updatePlayerSpecInfo()
        end)
    end
end

function CyberDeck:UNIT_SPELLCAST_FAILED(_, unitTarget, castGUID, spellID, castBarID)
    if unitTarget ~= "player" then return end
    if not isSec(spellID) then
        self:updateSpellFailed(spellID)
    end
end

function CyberDeck:SPELL_UPDATE_COOLDOWN(_, spellID)
    -- self:Print(spellID, C_Spell.GetSpellName(spellID))
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

local potions = {
    [241304] = "银月城生命药水",
    [241305] = "银月城生命药水",
    [241301] = "光注法力药水",
    [241300] = "光注法力药水",
    [5512] = "治疗石",
    [224464] = "恶魔治疗石",
    [241288] = "鲁莽药水",
    [241289] = "鲁莽药水",
    [241308] = "圣光潜力",
    [241309] = "圣光潜力",
}

function CyberDeck:ITEM_COUNT_CHANGED(_, itemID)
    if potions[itemID] then
        self:GetItemCount()
    end
end

function CyberDeck:UNIT_HEALTH(_, unit)
    if unit == "player" then
        self:updatePlayerHealth()
        self:updatePlayerStagger()
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

-- 能量更新
function CyberDeck:UNIT_POWER_UPDATE(_, unit, powerType)
    if unit ~= "player" then return end
    self:updatePlayerPower(powerType)
end

-- Hook 所有默认聊天框
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
    -- updateNameplateCount()
end

function CyberDeck:ACTION_RANGE_CHECK_UPDATE(_, slot, isInRange, checksRange)
    -- updateNameplateCount()
end

function CyberDeck:UI_ERROR_MESSAGE(_, errorType, message)
    -- print(errorType, message)
    if message == "目标不在视野中" then
        updateUnitInSight(state.castTargetUnit)
    elseif message == "射程范围内无有效目标。" then
        self:updateDiseaseJudge()
    end
end

function CyberDeck:UPDATE_BINDINGS()
    self:readKeybindings()
end

function CyberDeck:SPELLS_CHANGED()
    self:readKeybindings()
    if self.isForever then
        -- 学会新技能/新 rank 后重建名称索引，并重新解析像素块里的技能
        self:InvalidateSpellBookIndex()
        if not InCombatLockdown() and self.state and self.state.specIndex then
            self:loadPlayerBlocks(self.state.specIndex)
            self:updateSpellKnown()
        end
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

function CyberDeck:ENCOUNTER_START(_, encounterID, encounterName, difficultyID, groupSize)
    self:updateEncounterID(encounterID, difficultyID)
end

function CyberDeck:ENCOUNTER_END(_, encounterID, encounterName, difficultyID, groupSize, success)
    self:updateEncounterID(0, 0)
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
    local aura = C_UnitAuras.GetAuraDataByAuraInstanceID(unit, auraInstanceID)
    if aura then
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

function CyberDeck:UNIT_AURA(_, unit, info)
    self:GetDefensiveAuraInstanceID(unit, info)
    local obj = group[unit]
    if not obj then return end
    getAuraDispelTypeColor(unit)
    if info.isFullUpdate then
        self:updateUnitFullAura(unit)
        return
    end
    if info.addedAuras then
        for k, v in pairs(info.addedAuras) do
            -- print("|cnGREEN_FONT_COLOR:新增光环: |r", v.auraInstanceID, v.spellId, v.name, v.duration)
            if not isSec(v.spellId) and v.sourceUnit == "player" then
                obj.aura[v.auraInstanceID] = v
            end
        end
    end
    if info.updatedAuraInstanceIDs then
        for _, v in pairs(info.updatedAuraInstanceIDs) do
            local aura = C_UnitAuras.GetAuraDataByAuraInstanceID(unit, v)
            if aura and not isSec(aura.spellId) and aura.sourceUnit == "player" then
                -- print("|cnYELLOW_FONT_COLOR:更新光环: |r", aura.auraInstanceID, aura.spellId, aura.name)
                obj.aura[aura.auraInstanceID] = aura
            end
        end
    end
    if info.removedAuraInstanceIDs then
        for _, v in pairs(info.removedAuraInstanceIDs) do
            -- print("|cnRED_FONT_COLOR:移除光环: |r", v)
            obj.aura[v] = nil
        end
    end
end

function CyberDeck:ENCOUNTER_TIMELINE_EVENT_ADDED(_, eventInfo)

end

function CyberDeck:ENCOUNTER_TIMELINE_EVENT_REMOVED(_, eventID)
end

function CyberDeck:ENCOUNTER_TIMELINE_EVENT_STATE_CHANGED(_, eventID)
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
    self:updatePlayerEmpowerInfo()
    self:updateTargetCastingInfo()
    self:updateUnitCastingOrChannelingInfo("target")
    pcall(self.updateUnitCastingOrChannelingInfo, self, "focus")
    self:updateGroupInRangeAndHealth()
    self:updateAura()
    self:updateTargetAuraCount()
    -- 2. 低频逻辑（每 0.2 秒执行）
    self.timeElapsed = self.timeElapsed + elapsed
    if self.timeElapsed > 0.2 then
        self:GetDefensiveAuraDuration()
        self:updateSpellCooldown()
        self:OnUpdateUnitAura()
        self:updateAuraBlocks()
        self:updatePlayerAssistant()
        self:updateRune()
        self:updateTargetRangeBlock()
        self:updateEnemyCount()
        self:updateItemCoolDown()
        self:UpdateForeverAuras()
        self:UpdateForeverCreatureType()
        self:UpdateForeverAutoAttack()
        self.timeElapsed = 0
    end
end

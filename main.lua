local addon, ns = ...
local isSec = issecretvalue

-- UNIT_AURA 的 info 字段在战斗中全是 secret，直接做布尔判断会抛错；读不到按 false 处理
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

-- 队伍生命曲线必须脱战预建（战斗中不允许首次 CreateColorCurve）。
-- b = 100 + inComingHeals - healAbsorb：inComingHeals 取自下方 helpfulSpells（15/20/50），
-- healAbsorb 只有 0/15，全组合 = 85/105/115/120/135/150（125/140 是 40% 治疗预留）
for _, b in ipairs({ 85, 105, 115, 120, 125, 135, 140, 150 }) do
    creatColorCurveScaling(b)
end

local curve255 = CyberDeck:creatColorCurve(255, 255)
local castCurve = CyberDeck:creatColorCurve(2.55, 255)

-- UnitPowerType() 返回数值、EnumPowerType 键是字符串，读连击点/神圣能量这类特殊资源前必须换算
local function toPowerEnum(powerType)
    if type(powerType) == "string" then
        return EnumPowerType[powerType]
    end
    return powerType
end

local powerTypeName = {}
for name, id in pairs(EnumPowerType) do
    if powerTypeName[id] == nil then powerTypeName[id] = name end
end

local powerCurve = {}
function CyberDeck:CreatPowerCurve(powerType)
    if powerCurve[powerType] then return end
    local powerMax = UnitPowerMax("player", toPowerEnum(powerType))
    if powerMax >= 250 then
        powerCurve[powerType] = self:creatColorCurve(1, 100)
    else
        powerCurve[powerType] = self:creatColorCurve(1, powerMax)
    end
end

-- 单体读条治疗：法术ID -> 预估治疗量，避免对同一目标重复施法过量治疗
local helpfulSpells = {
    [2061] = 15,    -- 快速治疗
    [1262763] = 15, -- 祈福
    [10328] = 50,   -- 圣光术
    [19942] = 20,   -- 圣光闪现
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

-- 单位身上的负面光环数量（战斗中读不到按 0 处理，决策层不会因此去驱散）
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

-- 打印成功施放的技能ID与名称（不重复），格式：[spellID] = { index = i }, -- 名称
local succSpells = {}
local succIndex = 1
local function printSuccSpell(spellID)
    if not blocks or not blocks.spells then return end
    if succSpells[spellID] or blocks.spells[spellID] then return end
    succSpells[spellID] = true
    print("[" .. spellID .. "]" .. " = { index = " .. succIndex .. ", }, -- " .. GetSpellName(spellID))
    succIndex = succIndex + 1
end

-- 调试：打印技能充能字段。用法 /run CyberDeck:getSpellChargesInfo() 或传 spellID
function CyberDeck:getSpellChargesInfo(spellID)
    local charges = C_Spell.GetSpellCharges(spellID or 1247378)
    for k, v in pairs(charges or {}) do
        print(k, v, issecretvalue(v))
    end
end

-- 驱散能力映射：无限服是经典法术ID（圣骑士只有 纯净术1152 / 清洁术4987，正式服ID对不上）；
-- 经典圣骑士无驱诅咒法术，[2] 保持空
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
-- 光环受限（secret）适配：只影响目标侧
-- 战斗中 C_UnitAuras 读不到减益类型，「目标类型」退回基线（友 11 / 敌 1）；
-- 队友侧由 core/group_aura.lua 的引擎计时驱动，不读光环。
-- ================================================================

-- 遍历光环列表找第一个玩家能驱散的类型（只看 ids[1] 会漏），仅用于目标侧
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

local function updateCooldownSpellKnown()
    spells = {}
    if not blocks or not blocks.spells then return end
    C_Timer.After(1, function()
        for spellID, info in pairs(blocks.spells) do
            -- key 已是 ResolveSpellID 用 IsSpellKnown 过滤过的 rank ID，直接信任；
            -- 无限服的 IsSpellKnown 语义与正式服不同，再复核会把已学技能整体误标成 255
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

-- secret 上下文探测（/cy secrets）：用 C_Secrets 谓词判断当前上下文哪类数据会变 secret
-- 脱战 / 战斗中各跑一次可对比差异
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

    -- 单个法术的光环保密等级（返回 Enum.SecrecyLevel 枚举，不是布尔）
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
    -- 目标类型：必须先算 canAttack/canAssist，否则登录/重载时带着目标也会被写成 0
    self:updateTargetType()
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

-- class/*.lua 的 group 驱散字段 -> 引擎的类型名
local DISPEL_GROUP_FIELDS = {
    Magic = "dispelMagic",
    Curse = "dispelCurse",
    Disease = "dispelDisease",
    Poison = "dispelPoison",
    Bleed = "dispelBleed",
}

function CyberDeck:loadPlayerBlocks(specIndex)
    local t = specIndex and self.ClassBlocks and self.ClassBlocks[specIndex]
    if not t then
        -- 该职业/专精没配块：给空表，CreatTexture 遇 nil 索引会跳过，插件空转不报错
        blocks = { state = {}, auras = {}, spells = {} }
        self.blocks = blocks
        if not self.ClassBlocks and not self.noBlocksWarned then
            self.noBlocksWarned = true
            self:Print(("本职业（%s）没有像素块配置，插件不参与（不影响游戏）")
                :format(tostring(self.state and self.state.classFilename)))
        end
        return
    end
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
            -- 驱散格：每个可驱类型一个相对格号；旧字段 dispel（单格类型号）已废弃
            blocks.groups.dispelCells = nil
            for typeName, field in pairs(DISPEL_GROUP_FIELDS) do
                if v[field] then
                    -- 必须同时平铺到 groups 上：group_aura 的 CollectGroupDispelDefs
                    -- 读的是 groups.dispelMagic / dispelCurse / ...，只放进 dispelCells 它看不到
                    blocks.groups[field] = v[field]
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
    -- 换专精后队伍块 start/num 会变（神圣 7 格 ↔ 防护 5 格），容器 slot 还绑在旧格号上，
    -- 只能整体释放，由下一轮 Refresh 按新布局重建
    if self.ReleaseGroupAuraContainers then
        self:ReleaseGroupAuraContainers()
    end
    -- 鼠标探针容器同理：格号可能变（339），整体释放由下一次 RefreshMouseover 重建
    if self.ReleaseMouseoverDispelContainer then
        self:ReleaseMouseoverDispelContainer()
    end
    -- 目标审判探针同理：格号可能变（340）
    if self.ReleaseTargetJudgeContainer then
        self:ReleaseTargetJudgeContainer()
    end
end

--- loadPlayerBlocks 会释放三类引擎容器（slot 绑在旧格号上、删不掉只能重建），
--- 调用过它的地方换完 blocks 必须调本函数，否则对应像素停更到下次进战斗/花名册变化
function CyberDeck:RefreshEngineContainers()
    if self.RefreshGroupAuraContainers then self:RefreshGroupAuraContainers() end
    if self.RefreshMouseoverDispelContainer then self:RefreshMouseoverDispelContainer() end
    if self.RefreshTargetJudgeContainer then self:RefreshTargetJudgeContainer() end
    if self.RefreshGroupRoleOverlayContainers then self:RefreshGroupRoleOverlayContainers() end
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
    -- 换专精：先清计数条再 loadPlayerBlocks（CreateAutoLayoutBar 有 spellIdToBar 复用检查，
    -- 不先清会命中旧映射，条不会重建）
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
    -- updateGroup 不重建鼠标探针，而 loadPlayerBlocks 已释放它，这里补一次
    if self.RefreshMouseoverDispelContainer then
        self:RefreshMouseoverDispelContainer()
    end
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
        local powerEnum = toPowerEnum(powerType)
        local powerName = type(powerType) == "number" and powerTypeName[powerType] or powerType
        local power = UnitPower("player", powerEnum)
        local specialPower = specialPowerMap[powerName]
        if isSec(power) then
            if not powerCurve[powerType] then self:CreatPowerCurve(powerType) end
            local powerPercent = UnitPowerPercent("player", powerEnum, nil, powerCurve[powerType])
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
            -- 非 secret：法力/怒气按百分比写入 12.能量值
            local maxPower = UnitPowerMax("player", powerEnum)
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

    -- 受限时照样 pcall 试读：读不到时 pickTypeByCurve 返回 nil，自然回落到基准值 b
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
    目标类型取值：
      0        没有目标
      1        敌方
      2 / 3    敌方带魔法 / 激怒增益
      11       友方
      12..15   友方带魔法/诅咒/疾病/中毒减益（= debuffType + 11）
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
        -- 无目标/读不到距离时必须写 0，否则像素保留上次值，决策层会误判为在近战范围
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
        local _, _, _, _, _, _, notInterruptible = UnitChannelInfo(unit)
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

-- 目标读条 -> 「目标施法」格（惩戒制裁之锤打断用）：只写可打断的剩余秒数，
-- 不可打断写 0，避免白交一次 1 分钟 CD；引导同样可打断
function CyberDeck:updateTargetCastingInfo()
    if not blocks or not blocks.state["目标施法"] then return end
    local index = blocks.state["目标施法"]
    if not UnitExists("target") then
        target.castingDuration = 0
        self:CreatTexture(index, 0)
        return
    end

    local duration = UnitCastingDuration("target")
    local notInterruptible
    if duration then
        _, _, _, _, _, _, _, notInterruptible = UnitCastingInfo("target")
    else
        duration = UnitChannelDuration("target")
        if duration then
            _, _, _, _, _, _, notInterruptible = UnitChannelInfo("target")
        end
    end

    if not duration then
        target.castingDuration = 0
        self:CreatTexture(index, 0)
        return
    end

    -- notInterruptible 在本服是 secret boolean，不能做布尔判断，只能交给
    -- EvaluateColorFromBoolean 选色：可打断 -> 剩余秒数曲线，不可打断 -> 0
    local durationColor = duration:EvaluateRemainingDuration(castCurve)
    local booleanValue = EvaluateColorFromBoolean(notInterruptible, falseValueBlack, durationColor)
    ---@diagnostic disable-next-line: param-type-mismatch
    local _, _, b = booleanValue:GetRGB()
    target.castingDuration = b
    self:CreatTexture(index, b)
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
            -- 吸收窗口结束要重算这一格，否则会停在「减 15」的旧值直到下次事件
            CyberDeck:updateUnitHealthInfo(unit)
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

-- 队伍 buff 格的 Lua 兜底读取：只在引擎容器没建起来时才会用到
-- 过滤器只用 PLAYER|HELPFUL，多挂 RAID_IN_COMBAT 可能把长 buff 过滤掉
function CyberDeck:updateUnitFullAura(unit)
    local obj = group[unit]
    if not obj then return end
    -- 扫 10 条：坦身上 buff 多，只扫前 5 条会漏掉排在后面的圣光守望/圣光誓约
    for i = 1, 10 do
        local okb, buff = pcall(C_UnitAuras.GetBuffDataByIndex, unit, i, "PLAYER|HELPFUL")
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
    -- 引擎接管后 Lua 侧必须停写：战斗中读不到会写 0，盖掉引擎算好的剩余秒数
    local writeAuraPixels = not self.groupAuraBuffEngineReady
    for unit, data in pairs(group) do
        if writeAuraPixels then
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
        end
        if blocks.groups.rejuv then
            local index = blocks.groups.start + (data.index - 1) * blocks.groups.num + blocks.groups.rejuv
            local rejuvCount = getRejuvCount(unit)
            self:CreatTexture(index, rejuvCount / 255)
        end
    end
end

function CyberDeck:updateGroup()
    -- 必须用 wipe 而不是 self.group = {}：group/groupList 在文件顶部被 local 捕获过，
    -- 重建 self.group 会让 local 继续指向旧表
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

    -- 空槽位清零：人数减少后旧槽位残留会被决策层选中，宏落到 [@player] 变成给自己驱散
    -- 驱散格不用清：容器 Hide 后露出色条底色 0
    if blocks and blocks.groups then
        local g = blocks.groups
        local aliveCount = #groupList
        local maxSlot = CyberDeck.GROUP_TARGET_LIMIT or 40
        if g.healthPercent and g.role and aliveCount < maxSlot then
            for i = aliveCount + 1, maxSlot do
                local base = g.start + (i - 1) * g.num
                self:CreatTexture(base + g.healthPercent, 0)
                self:CreatTexture(base + g.role, 0)
            end
        end
    end

    -- 花名册变化后重建/重绑队伍驱散容器（Shingen unit/group.lua:208 同款）
    if self.RefreshGroupAuraContainers then
        self:RefreshGroupAuraContainers()
    elseif not self.groupAuraMissingWarned then
        self.groupAuraMissingWarned = true
        self:Print("|cffff0000core/group_aura.lua 没生效|r：队伍驱散像素不会被创建（"
            .. tostring(self.groupAuraLoadError or "文件加载报错") .. "）。"
            .. "敲 /console scriptErrors 1 再 /reload 看具体错误。")
    end
    -- 目标审判探针（340）跟着 blocks 走
    if self.RefreshTargetJudgeContainer then
        self:RefreshTargetJudgeContainer()
    end
    -- 救赎之魂覆盖：花名册变了要跟着重建
    if self.RefreshGroupRoleOverlayContainers then
        self:RefreshGroupRoleOverlayContainers()
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
    -- 过场后光环缓存可能失效 -> 强制重建队伍驱散容器（重绑候选过滤）
    if self.RefreshGroupAuraContainers then self:RefreshGroupAuraContainers() end
    if self.RefreshTargetJudgeContainer then self:RefreshTargetJudgeContainer() end
    if self.RefreshGroupRoleOverlayContainers then self:RefreshGroupRoleOverlayContainers() end
    state.mapID = C_Map.GetBestMapForUnit("player") or 0
end

function CyberDeck:PLAYER_TALENT_UPDATE()
    self:updatePlayerSpecInfo()
    self:updateGroup()
    -- 天赋点数可能还是旧值，延迟刷两次兜底（无限服没有切专精法术事件）
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
    -- 进战斗也重刷：引擎会在战斗开始时重置 SetUnit 绑定，不重绑会导致容器染色失效
    -- 用 Refresh 而不是 RebindAll：Refresh 会补建缺失的容器
    if self.RefreshGroupAuraContainers then
        self:RefreshGroupAuraContainers()
    end
    -- 鼠标探针同样在进战斗时重绑（引擎会重置 SetUnit 绑定）
    if self.RefreshMouseoverDispelContainer then
        self:RefreshMouseoverDispelContainer()
    end
    -- 目标审判探针同样重绑
    if self.RefreshTargetJudgeContainer then
        self:RefreshTargetJudgeContainer()
    end
    -- 救赎之魂覆盖容器同样重绑（引擎会重置 SetUnit 绑定）
    if self.RefreshGroupRoleOverlayContainers then
        self:RefreshGroupRoleOverlayContainers()
    end
end

function CyberDeck:PLAYER_REGEN_ENABLED()
    self:updateTargetType()
    self:updatePlayerCombat()
    -- 脱战立刻重绑一次（战斗内引擎可能重置过绑定）
    if self.RebindAllGroupAuraContainers then
        self:RebindAllGroupAuraContainers()
    end
    -- 鼠标探针同步重绑
    if self.RefreshMouseoverDispelContainer then
        self:RefreshMouseoverDispelContainer()
    end
    -- 目标审判探针同步重绑
    if self.RefreshTargetJudgeContainer then
        self:RefreshTargetJudgeContainer()
    end
    -- 救赎之魂覆盖容器同步重绑
    if self.RefreshGroupRoleOverlayContainers then
        self:RefreshGroupRoleOverlayContainers()
    end
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

function CyberDeck:UNIT_SPELLCAST_INTERRUPTED(_, unitTarget, castGUID, spellID, castBarID)
    -- 打断的清理与 STOP 完全一致：不清的话在途治疗的 +15/+50 会一直挂在目标血格上，
    -- 坦克半血会被读成满血（Shingen 也是 STOP + INTERRUPTED 两处都清）
    self:UNIT_SPELLCAST_STOP(_, unitTarget, castGUID, spellID, castBarID)
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
    -- 必须在 isSec 过滤之前：战斗中 spellID 可能被保护，放后面常驻 buff 的锁就建不起来
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

-- 关注的物品 ID（core/forever.lua 的 itemGroups；正式服 ID 在无限服对不上）
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
        -- 血量变化即时写格：OnUpdate 的队伍轮询每帧只处理 1 人，
        -- 40 人一轮要 40 帧（60fps 约 0.67s），光靠轮询会比血条慢好几拍
        self:updateUnitHealthInfo(unit)
        updateUnitDeathByHealthInfo(unit)
    end
end

function CyberDeck:UNIT_MAXHEALTH(_, unit)
    if unit == "player" then
        self:updatePlayerHealth()
    end
    if group[unit] then
        -- 最大血量变了，百分比跟着变，立即重算
        self:updateUnitHealthInfo(unit)
        updateUnitDeathByHealthInfo(unit)
    end
end

function CyberDeck:UNIT_HEAL_ABSORB_AMOUNT_CHANGED(_, unit)
    if unit == "player" then
        self:updatePlayerHealth()
    end
    if group[unit] then
        updateUnitHealAbsorbCurve(unit)
        -- healAbsorb 改了 -> 曲线 b 变了，必须按新曲线重算这一格
        self:updateUnitHealthInfo(unit)
        updateUnitDeathByHealthInfo(unit)
    end
end

function CyberDeck:UNIT_HEAL_PREDICTION(_, unit)
    if unit == "player" then
        self:updatePlayerHealth()
    end
    if group[unit] then
        -- 治疗预测变化也意味着血量会变，顺手刷一次（Shingen 同样在这条事件里刷血量）
        self:updateUnitHealthInfo(unit)
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
        -- loadPlayerBlocks 已释放引擎容器，这里必须按新 blocks 重建
        self:RefreshEngineContainers()
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
    -- 换了目标要重绑目标审判探针（SetUnit + 重设候选过滤）
    if self.RefreshTargetJudgeContainer then
        self:RefreshTargetJudgeContainer()
    end
end

function CyberDeck:UPDATE_MOUSEOVER_UNIT()
    -- 驱动 mouseover 引擎探针；Refresh 内部只在 UnitGUID 变化时重绑，高频调用无妨
    if self.RefreshMouseoverDispelContainer then
        self:RefreshMouseoverDispelContainer()
    end
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

-- 调试：逐个过滤器打印光环是否被过滤（/run CyberDeck:TestFiltered("player", <auraInstanceID>)）
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
-- 队伍驱散像素（引擎 AuraContainer，照搬 Shingen）
-- 编码：每个可驱类型每人一格，蓝通道 = 该类型最长剩余秒数
--   0 = 无   1 = 不足 1 秒   2..254 = 剩余秒数   255 = 超过 255 秒 / 永久
-- 三条约束：1) 每类型一条 slot，候选过滤只放该类型
--           2) SetUnit 会冲掉候选过滤 -> 换单位后必须重设再 UpdateAllAuras
--           3) 按钮锚 UIParent 那一格 + SetClipsChildren(true)
-- 诊断 /cy dispelprobe：按钮=无 / slots=0 -> slot 没建；文字 b=0 且有减益 -> 引擎没染色；
--   文字 b>0 但 Python 读 0 -> 解码几何错位；战斗中读不到属正常
-- ================================================================

--- 读某单位身上「玩家可驱」的减益：返回 条数, "Magic,Disease"；战斗中返回 nil
local function DescribeAuraDebuffs(unit)
    local ok, ids = pcall(C_UnitAuras.GetUnitAuraInstanceIDs,
        unit, "HARMFUL|RAID_PLAYER_DISPELLABLE")
    if not ok or type(ids) ~= "table" then
        return nil, tostring(ids)
    end
    local names = {}
    for i = 1, #ids do
        local okD, d = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, unit, ids[i])
        names[#names + 1] = (okD and type(d) == "table" and d.dispelName) or "?"
    end
    return #ids, table.concat(names, ",")
end

--- 按格号找该槽的 AuraButton（initializeFrame 里打了 cdPixelIndex 标记）
local function FindSlotButton(container, pixelIndex)
    -- 优先用 initializeFrame 里存下的引用（GetChildren 不保证包含引擎建的 AuraButton）
    local cached = container.cdButtons and container.cdButtons[pixelIndex]
    if cached then
        return cached
    end
    for _, child in ipairs({ container:GetChildren() }) do
        if child.cdPixelIndex == pixelIndex then
            return child
        end
    end
    return nil
end

function CyberDeck:PrintDispelProbeDebug()
    local groups = self.blocks and self.blocks.groups
    if not groups then
        self:Print("|cffff0000blocks.groups 不存在|r（还没 loadPlayerBlocks）")
        return
    end

    local offsets = {}
    for _, def in ipairs({ { "Magic", "dispelMagic" }, { "Curse", "dispelCurse" },
                           { "Disease", "dispelDisease" }, { "Poison", "dispelPoison" },
                           { "Bleed", "dispelBleed" } }) do
        if groups[def[2]] then
            offsets[#offsets + 1] = ("%s=%d"):format(def[1], groups[def[2]])
        end
    end
    local moduleReady = (self.RefreshGroupAuraContainers ~= nil)
    local containers = (self.GetGroupAuraContainers and self:GetGroupAuraContainers()) or {}
    local containerCount = 0
    for _ in pairs(containers) do containerCount = containerCount + 1 end
    self:Print(("[驱散探针] start=%s num=%s 格=%s | 容器 %d 个 | 模块=%s | 色条=%s")
        :format(tostring(groups.start), tostring(groups.num),
            #offsets > 0 and table.concat(offsets, " ") or "|cffff0000空|r",
            containerCount,
            moduleReady and "有" or "|cffff0000未加载|r",
            _G.CyberDeckColorBars and "有" or "|cffff0000无|r"))
    if not moduleReady then
        self:Print(("  ！core/group_aura.lua 没生效：%s")
            :format(tostring(self.groupAuraLoadError or "文件加载报错，用 /console scriptErrors 1 后 /reload 看")))
        return
    end
    if containerCount == 0 then
        self:Print(("  groupList=%d 个成员 | blocks.groups=%s")
            :format(#(self.groupList or {}),
                (self.blocks and self.blocks.groups and "有") or "|cffff0000无|r"))
        -- 现场重试一次：把「建容器失败」的原因直接暴露出来
        local ok, err = pcall(self.RefreshGroupAuraContainers, self)
        self:Print(("  容器为 0，现场重试 Refresh：%s%s")
            :format(ok and "已调用" or "|cffff0000抛错|r",
                ok and "" or ("（" .. tostring(err) .. "）")))
        if self.dispelContainerError then
            self:Print(("  上次建容器失败：%s"):format(tostring(self.dispelContainerError)))
        end
        containers = (self.GetGroupAuraContainers and self:GetGroupAuraContainers()) or {}
        containerCount = 0
        for _ in pairs(containers) do containerCount = containerCount + 1 end
        self:Print(("  重试后容器 %d 个"):format(containerCount))
    end

    local indices = {}
    for i in pairs(containers) do indices[#indices + 1] = i end
    table.sort(indices)
    for _, memberIndex in ipairs(indices) do
        local container = containers[memberIndex]
        local okS, shown = pcall(function() return container:IsShown() end)
        local slots = container.cdDispelSlots or {}
        self:Print(("  成员%-2d %-8s shown=%s slots=%d")
            :format(memberIndex, tostring(container.cdUnit),
                tostring(okS and shown or "?"), #slots))
        for _, slot in ipairs(slots) do
            local btn = FindSlotButton(container, slot.index)
            local bStr, sizeStr, shownStr = "?", "?", "?"
            if btn then
                local okZ, w, h = pcall(function() return btn:GetSize() end)
                if okZ and w then sizeStr = ("%.1fx%.1f"):format(w, h or 0) end
                local okSh, sh = pcall(function() return btn:IsShown() end)
                if okSh then shownStr = tostring(sh) end
                local text = btn.cdDurationText
                if text and text.GetTextColor then
                    local okC, r, g, b = pcall(text.GetTextColor, text)
                    if okC and b then bStr = ("%.3f"):format(b) end
                end
            end
            self:Print(("    %s 格=%d 按钮=%s 显示=%s 尺寸=%s 文字b=%s")
                :format(tostring(slot.key), slot.index, btn and "有" or "|cffff0000无|r",
                    shownStr, sizeStr, bStr))
        end
        local cnt, detail = DescribeAuraDebuffs(container.cdUnit)
        if cnt then
            self:Print(("    实际可驱减益 %d 条%s")
                :format(cnt, cnt > 0 and ("（" .. detail .. "）") or ""))
        else
            self:Print(("    实际可驱减益 读不到（%s）"):format(tostring(detail)))
        end
    end
end

-- 队伍驱散格只有引擎一个写入方：计时文字颜色由引擎按剩余秒数算，
-- Lua 侧不读光环、也不写那一格，脱战/战斗同一套

function CyberDeck:UNIT_AURA(_, unit, info)
    -- 鼠标指向的减益被驱掉后，让引擎立即重新评估按钮显示，把「鼠标可驱」格清零
    -- （残留旧值 > 0 会让决策层重复驱散）。unit 可能是 mouseover 或实际 token，不精确匹配
    if self.RefreshMouseoverDispelAuras then
        self:RefreshMouseoverDispelAuras()
    end
    -- 目标身上的减益变化：让目标审判探针立即重新评估（审判 debuff 上/掉都要及时）
    if unit == "target" and self.RefreshTargetJudgeAuras then
        self:RefreshTargetJudgeAuras()
    end
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
CyberDeck.enemyElapsed = 0
function CyberDeck:OnUpdate(elapsed)
    -- 1. 高频逻辑（每帧）；成员函数用 self: 调用
    self:updatePlayerCastingInfo()
    self:updatePlayerChannelingInfo()
    self:updateUnitCastingOrChannelingInfo("target")
    self:updateTargetCastingInfo()
    pcall(self.updateUnitCastingOrChannelingInfo, self, "focus")
    self:updateGroupInRangeAndHealth()
    self:updateAura()
    self:updateTargetAuraCount()
    -- 2. 低频逻辑（0.12 秒）：与 Python 侧 0.1 秒错开，避免同频卡顿
    self.timeElapsed = self.timeElapsed + elapsed
    if self.timeElapsed > 0.12 then
        self:updateSpellCooldown()
        self:OnUpdateUnitAura()
        self:updateAura()
        self:updateTargetRangeBlock()
        self:updateItemCoolDown()
        self:UpdateForeverAuras()
        self:updateAuraBlocks()      -- 338 圣印剩余等「光环型」像素
        self:UpdateForeverAutoAttack()
        -- 队伍驱散容器由 updateGroup（花名册变化）和进/脱战重刷驱动，不在 OnUpdate 轮询
        self.timeElapsed = 0
    end

    -- 3. 姓名板档（0.2 秒）：LibRangeCheck:GetRange 是整个 OnUpdate 里最重的调用，
    --    只写「敌人人数/5码敌人」这类姓名板像素，与队伍血量（事件驱动）、
    --    队伍光环/圣印（上面 0.12s 档）完全解耦，降频不影响它们。
    --    ★ 不能设 0.1：LibRangeCheck 默认缓存寿命就是 0.1s（GetRange 第 4 参不传时），
    --      间隔 >=0.1 每次都是 cache miss、全量扫描，等于白花双倍开销。
    self.enemyElapsed = self.enemyElapsed + elapsed
    if self.enemyElapsed > 0.2 then
        self:updateEnemyCount()
        self.enemyElapsed = 0
    end
end

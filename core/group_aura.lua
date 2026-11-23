local addon, ns = ...

--[[============================================================================
    队伍成员驱散像素 —— 严格照搬 Shingen Forever 版 core/block.lua:1140-1470

    与 Shingen 的差异只有命名：
      Shingen            -> CyberDeck
      shingenUnit        -> cdUnit
      shingenDispelDurationSlots -> cdDispelSlots

    行为完全一致：
      · 每个可驱类型一条 slot，candidateFilters.includeDispelTypes 只放该类型
      · sortMethod = ExpirationOnly / sortDirection = Reverse（同类取剩余最长）
      · initializeFrame：按钮锚 UIParent 那一格 + SetClipsChildren + 底色 b=1 + █ 计时文字
      · 每次 RefreshGroupAuraContainers 都 SetUnit -> 重绑候选过滤 -> UpdateAllAuras
        （SetUnit 会冲掉过滤；只在换单位时绑一次会永久失效）
      · 容器常驻复用，只 SetEnabled/Show/Hide，不 Destroy
============================================================================]]

local AURA_DURATION_CHAR = "█"
local AURA_ENABLE_MOUSE = false
local AURA_DURATION_STRATA = "TOOLTIP"
local AURA_DURATION_LEVEL = 9003

local BLOCK = CyberDeck.BLOCK_FIX_CONFIG
local AURA_BLOCK_W = BLOCK.blockWidth
local AURA_BLOCK_H = BLOCK.blockHeight

-- 驱散字段 -> 引擎的 dispelType 名（Magic/Curse/Disease/Poison/Bleed）
-- 顺序与 Shingen DISPEL_DURATION_FIELDS 一致
local DISPEL_DURATION_FIELDS = {
    { field = "dispelMagic", auraType = "Magic" },
    { field = "dispelCurse", auraType = "Curse" },
    { field = "dispelDisease", auraType = "Disease" },
    { field = "dispelPoison", auraType = "Poison" },
    { field = "dispelBleed", auraType = "Bleed" },
}

local groupAuraContainers = {} -- [memberIndex] = AuraContainer

local function EnsureAuraContainerLoaded()
    if C_AddOns and not C_AddOns.IsAddOnLoaded("Blizzard_AuraContainer") then
        pcall(C_AddOns.LoadAddOn, "Blizzard_AuraContainer")
    end
end

local function EncodeBlockChannels(index)
    return CyberDeck:EncodeBlockChannels(index)
end

local function AuraBlockXOffset(index)
    return (index - 1) * BLOCK.blockWidth
end

local function ConfigureAuraButtonMouse(button)
    button:SetMouseMotionEnabled(AURA_ENABLE_MOUSE)
    if AURA_ENABLE_MOUSE then
        button:SetHideTooltipInCombat(true)
    end
end

local function AnchorAuraPixelButton(button, index)
    button:SetSize(AURA_BLOCK_W, AURA_BLOCK_H)
    button:SetClipsChildren(true)
    ConfigureAuraButtonMouse(button)
    button:SetPoint("TOPLEFT", UIParent, "TOPLEFT", AuraBlockXOffset(index), 0)
end

local function CreateAuraPixelCell(button, index, offset, blue)
    local cell = CreateFrame("Frame", nil, button)
    cell:SetSize(AURA_BLOCK_W, AURA_BLOCK_H)
    cell:SetPoint("TOPLEFT", button, "TOPLEFT", offset * AURA_BLOCK_W, 0)
    cell:SetClipsChildren(true)
    cell:EnableMouse(false)

    local bg = cell:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(cell)
    local r, g = EncodeBlockChannels(index)
    bg:SetColorTexture(r, g, blue, 1)
    return cell
end

local function MakeDurationColorCurve(index)
    local curve = C_CurveUtil.CreateColorCurve()
    curve:SetType(Enum.LuaCurveType.Linear)
    local r, g = EncodeBlockChannels(index)
    curve:AddPoint(0, CreateColor(r, g, 1 / 255, 1))
    curve:AddPoint(1, CreateColor(r, g, 1 / 255, 1))
    curve:AddPoint(255, CreateColor(r, g, 1, 1))
    return curve
end

local function MakeDispelDurationSlotInitializer(index)
    return function(button)
        AnchorAuraPixelButton(button, index)
        -- 原生计时文字在永久光环上停用；保留 255 底色。无候选时整个按钮隐藏，露出 0。
        local cell = CreateAuraPixelCell(button, index, 0, 1)
        local duration = cell:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        duration:SetPoint("CENTER", cell, "CENTER", 0, 0)
        duration:SetJustifyH("CENTER")
        duration:SetJustifyV("MIDDLE")
        button:SetDurationText(duration, {
            textFormat = { formatString = AURA_DURATION_CHAR, components = {} },
            textColor = {
                curve = MakeDurationColorCurve(index),
                property = Enum.DurationTextBindingProperty.RemainingDuration,
            },
        })
        -- 只给 /cy dispelprobe 用；不影响渲染
        button.cdPixelIndex = index
        button.cdDurationText = duration
    end
end

local function CollectGroupDispelDefs(groups)
    local defs = {}
    for _, def in ipairs(DISPEL_DURATION_FIELDS) do
        if groups[def.field] then
            table.insert(defs, { offset = groups[def.field], auraType = def.auraType })
        end
    end
    return defs
end

local function GroupAuraPixelIndex(groups, memberIndex, offset)
    return groups.start + (memberIndex - 1) * groups.num + offset
end

local function CreateGroupMemberAuraContainer(memberIndex, groups, dispelDefs)
    EnsureAuraContainerLoaded()

    local container = CreateFrame("AuraContainer", "CyberDeckGroupAuraSlots_" .. memberIndex, UIParent,
                                  "CustomAuraContainerTemplate")
    container:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
    container:SetEnabled(true)
    container:SetFrameStrata(AURA_DURATION_STRATA)
    container:SetFrameLevel(AURA_DURATION_LEVEL)

    container.cdDispelSlots = {}
    for _, def in ipairs(dispelDefs) do
        local pixelIndex = GroupAuraPixelIndex(groups, memberIndex, def.offset)
        if pixelIndex > 0 and pixelIndex <= BLOCK.capacity then
            local key = "group_" .. memberIndex .. "_dispel_" .. def.auraType
            container:AddAuraSlot(key, "HARMFUL", {
                candidateFilters = { includeDispelTypes = { [def.auraType] = true } },
                sortMethod = AuraContainerSortMethod.ExpirationOnly,
                sortDirection = AuraContainerSortDirection.Reverse,
                initializeFrame = MakeDispelDurationSlotInitializer(pixelIndex),
            })
            table.insert(container.cdDispelSlots, {
                key = key,
                auraType = def.auraType,
                index = pixelIndex,
            })
        end
    end

    return container
end

local function KickAuraContainer(container, unit)
    if not container then
        return
    end
    if unit then
        container.cdUnit = unit
        container:SetUnit(unit)
    end
end

-- 重绑全部驱散槽的候选过滤，并强制容器重新分配光环
-- 顺序：SetUnit → SetAuraSlotCandidateFilters → UpdateAllAuras（避免 SetUnit 冲掉过滤）
local function RebindContainerDispelFilters(container, unit)
    if not container then
        return
    end
    local bindUnit = unit or container.cdUnit
    KickAuraContainer(container, bindUnit)

    if container.cdDispelSlots then
        for _, slot in ipairs(container.cdDispelSlots) do
            -- 每次重建过滤表，保持各类独立
            container:SetAuraSlotCandidateFilters(slot.key, {
                includeDispelTypes = { [slot.auraType] = true },
            })
        end
    end

    if container.UpdateAllAuras then
        container:UpdateAllAuras()
    end
end

local function ReleaseFrame(frame)
    if not frame then
        return
    end
    frame:SetEnabled(false)
    frame:Hide()
    frame:SetParent(nil)
end

function CyberDeck:ReleaseGroupAuraContainers()
    for memberIndex, container in pairs(groupAuraContainers) do
        ReleaseFrame(container)
        groupAuraContainers[memberIndex] = nil
    end
end

--- 按当前 groupList 为每个成员创建/绑定单位光环槽（花名册变化时调，见 updateGroup）
function CyberDeck:RefreshGroupAuraContainers()
    local groups = self.blocks and self.blocks.groups
    if not groups or not groups.start or not groups.num then
        self:ReleaseGroupAuraContainers()
        return
    end

    local dispelDefs = CollectGroupDispelDefs(groups)
    if #dispelDefs == 0 then
        self:ReleaseGroupAuraContainers()
        return
    end

    local groupList = self.groupList or {}
    local group = self.group or {}
    local usedContainers = {}

    for _, unit in ipairs(groupList) do
        local obj = group[unit]
        if obj and obj.index then
            local memberIndex = obj.index
            usedContainers[memberIndex] = true
            local container = groupAuraContainers[memberIndex]
            if not container then
                container = CreateGroupMemberAuraContainer(memberIndex, groups, dispelDefs)
                groupAuraContainers[memberIndex] = container
            end
            container.cdUnit = unit
            RebindContainerDispelFilters(container, unit)
            container:SetEnabled(true)
            container:Show()
        end
    end

    for memberIndex, container in pairs(groupAuraContainers) do
        if not usedContainers[memberIndex] then
            container:SetEnabled(false)
            container:Hide()
        end
    end
end

--- 过场/脱战后重绑全部容器（只重绑，不动布局）
function CyberDeck:RebindAllGroupAuraContainers()
    for _, container in pairs(groupAuraContainers) do
        RebindContainerDispelFilters(container, container.cdUnit)
    end
end

--- 诊断用：拿到当前容器表
function CyberDeck:GetGroupAuraContainers()
    return groupAuraContainers
end

--- 诊断用：按成员序号取容器
function CyberDeck:GetGroupAuraContainer(memberIndex)
    return groupAuraContainers[memberIndex]
end

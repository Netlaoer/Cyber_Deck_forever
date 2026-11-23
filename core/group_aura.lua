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
if not BLOCK then
    -- 不能让整个文件崩掉：崩了 RefreshGroupAuraContainers 就不存在，
    -- main.lua 的 `if self.RefreshGroupAuraContainers then` 会静默跳过 -> 0 个容器且无报错。
    CyberDeck.groupAuraLoadError = "CyberDeck.BLOCK_FIX_CONFIG 缺失（core/block.lua 没加载？）"
    return
end

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

local function MakeDispelDurationSlotInitializer(index, container)
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
        if container then
            container.cdButtons = container.cdButtons or {}
            container.cdButtons[index] = button
        end
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
                initializeFrame = MakeDispelDurationSlotInitializer(pixelIndex, container),
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
                -- 战斗中/引擎未就绪时 CreateFrame/AddAuraSlot 可能抛错，
                -- 不能让它冒泡到 updateGroup（后面的逻辑会被整段跳过）。
                local ok, created = pcall(CreateGroupMemberAuraContainer, memberIndex, groups, dispelDefs)
                if ok and created then
                    container = created
                    groupAuraContainers[memberIndex] = container
                else
                    self.dispelContainerError = (ok and "返回 nil" or tostring(created))
                end
                if (not ok or not created) and not self.dispelContainerWarned then
                    self.dispelContainerWarned = true
                    if self.Print then
                        self:Print(("|cffff0000驱散容器创建失败|r（成员 %d）: %s")
                            :format(memberIndex, tostring(created)))
                    end
                end
            end
            if container then
                container.cdUnit = unit
                RebindContainerDispelFilters(container, unit)
                container:SetEnabled(true)
                container:Show()
            end
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

-- ================================================================
-- 鼠标指向驱散探针：给 mouseover 建一条引擎容器，
-- 一条 slot 过滤「本职业所有能驱的类型」，引擎取其中剩余最长的写进
-- 「鼠标可驱」格（> 0 = 鼠标指向的人身上有可驱减益）。
--
-- 与队友容器同源（都走 AuraContainer 引擎，引擎自己算剩余秒数），
-- 所以**战斗中同样有效**（不读光环，不受 secret 限制）。
--
-- 关键点：只在 UnitGUID("mouseover") 变化时重绑 SetUnit；
-- 同一单位身上的减益变化由引擎自己刷新，不需要每帧重绑
-- （每帧 SetUnit + UpdateAllAuras 会拖慢主循环，之前踩过这个坑）。
-- ================================================================
local mouseoverContainer = nil
local lastMouseoverGUID = nil

function CyberDeck:ReleaseMouseoverDispelContainer()
    if mouseoverContainer then
        ReleaseFrame(mouseoverContainer)
        mouseoverContainer = nil
    end
    lastMouseoverGUID = nil
end

function CyberDeck:RefreshMouseoverDispelContainer()
    local groups = self.blocks and self.blocks.groups
    local pixelIndex = self.blocks and self.blocks.state and self.blocks.state["鼠标可驱"]
    if not groups or not pixelIndex then
        self:ReleaseMouseoverDispelContainer()
        return
    end

    -- 本职业能驱的类型（blocks.groups.dispelCells 的 key，如 Magic/Disease/Poison）
    local includeDispelTypes = {}
    local hasType = false
    for typeName in pairs(groups.dispelCells or {}) do
        includeDispelTypes[typeName] = true
        hasType = true
    end
    if not hasType then
        self:ReleaseMouseoverDispelContainer()
        return
    end

    -- 只在鼠标指向的单位变化时重绑（同一单位由引擎自己跟）
    local guid = UnitGUID("mouseover")
    if guid and guid == lastMouseoverGUID then
        return
    end
    lastMouseoverGUID = guid

    if not guid then
        if mouseoverContainer then
            mouseoverContainer:Hide()
        end
        return
    end

    -- ★ 只驱散友方：鼠标指向敌对/中立单位时，敌方身上的减益会被 HARMFUL 过滤
    --   当成「可驱减益」，导致对着敌人也按清洁术。这里 Hide 容器，让 339 露出 0。
    if not UnitCanAssist("player", "mouseover") then
        if mouseoverContainer then
            mouseoverContainer:Hide()
        end
        return
    end

    EnsureAuraContainerLoaded()

    if not mouseoverContainer then
        local ok, created = pcall(function()
            local c = CreateFrame("AuraContainer", "CyberDeckMouseoverDispelSlots",
                UIParent, "CustomAuraContainerTemplate")
            c:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
            c:SetEnabled(true)
            c:SetFrameStrata(AURA_DURATION_STRATA)
            c:SetFrameLevel(AURA_DURATION_LEVEL)
            c:AddAuraSlot("mouseover_dispel", "HARMFUL", {
                candidateFilters = { includeDispelTypes = includeDispelTypes },
                sortMethod = AuraContainerSortMethod.ExpirationOnly,
                sortDirection = AuraContainerSortDirection.Reverse,
                initializeFrame = MakeDispelDurationSlotInitializer(pixelIndex, c),
            })
            return c
        end)
        if ok and created then
            mouseoverContainer = created
        else
            self.mouseoverDispelError = (ok and "返回 nil" or tostring(created))
            return
        end
    end

    mouseoverContainer.cdUnit = "mouseover"
    mouseoverContainer:SetUnit("mouseover")
    mouseoverContainer:SetAuraSlotCandidateFilters("mouseover_dispel", {
        includeDispelTypes = includeDispelTypes,
    })
    if mouseoverContainer.UpdateAllAuras then
        mouseoverContainer:UpdateAllAuras()
    end
    mouseoverContainer:SetEnabled(true)
    mouseoverContainer:Show()
end

--- 诊断用：拿到鼠标探针容器（供 /cy dispelprobe 扩展）
function CyberDeck:GetMouseoverDispelContainer()
    return mouseoverContainer
end

--- 只刷新鼠标探针容器当前绑定的光环（不重绑 SetUnit）：
--   mouseover 单位身上的减益被驱掉后，UNIT_AURA 会触发，这里立即 UpdateAllAuras
--   让引擎重新评估按钮显示，把「已驱减益」的按钮隐藏 -> 「鼠标可驱」格及时清零。
--   不刷新的话引擎可能滞后几帧，残留旧值 > 0，决策层就会重复驱散。
--   只在容器可见（鼠标正指着一个友方）时刷新，Hide 状态（鼠标已移开）跳过。
function CyberDeck:RefreshMouseoverDispelAuras()
    if mouseoverContainer and mouseoverContainer.cdUnit == "mouseover"
        and mouseoverContainer:IsShown() then
        if mouseoverContainer.UpdateAllAuras then
            mouseoverContainer:UpdateAllAuras()
        end
    end
end

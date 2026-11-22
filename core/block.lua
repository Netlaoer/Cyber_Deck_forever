local addon, ns = ...
local screenWidth = GetScreenWidth()

local BLOCK_FIX_CONFIG = {
    blockCount = 255,               -- 总色块数量
    blockWidth = screenWidth / 255, -- 色块宽度
    blockHeight = 2,                -- 色块高度
    blockSpacing = 0,               -- 色块间距
}

-- 计算 X 偏移
local function GetXOffset(index, Width, spacing)
    return index * (Width + spacing)
end

-- 创建"色条"的容器
local colorBars = CreateFrame("Frame", "CyberDeckColorBars", UIParent)
colorBars:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
colorBars:SetSize(screenWidth, BLOCK_FIX_CONFIG.blockHeight)
colorBars:SetFrameStrata("TOOLTIP") -- 确保在最上层
colorBars:SetFrameLevel(10000)
-- colorBars:Raise()   -- Increases the frame's frame level above all other frames in its strata

-- 存储纹理的数组 (1 到 255)
local pixelTextures = {}

-- 获取特定索引的纹理（如果不存在则创建）
local function creatTextureByIndex(i)
    if i <= 0 or i > BLOCK_FIX_CONFIG.blockCount then return nil end
    if pixelTextures[i] == nil then
        local tex = colorBars:CreateTexture(nil, "OVERLAY")
        tex:SetSize(BLOCK_FIX_CONFIG.blockWidth, BLOCK_FIX_CONFIG.blockHeight)
        tex:SetPoint("TOPLEFT", colorBars, "TOPLEFT",
            GetXOffset(i - 1, BLOCK_FIX_CONFIG.blockWidth, BLOCK_FIX_CONFIG.blockSpacing), 0)
        pixelTextures[i] = tex
    end
    return pixelTextures[i]
end

-- 更新或创建静态色块 (按索引)
function CyberDeck:CreatTexture(i, b)
    local tex = creatTextureByIndex(i)
    if tex then
        tex:SetColorTexture(0, i / 255, b, 1)
    end
end

-- 取色条第 i 格的位置与尺寸（**色条内部坐标系**）
--
-- ★ 必须用 BLOCK_FIX_CONFIG.blockWidth（= screenWidth/255 = 7.823），
--   并且调用方把宿主 frame 锚在 **UIParent** 上（不是 bars）。
--
--   推导（实测）：
--     colorBars 锚在 UIParent 的 (0,0)、无额外 scale，
--     所以 bars 内部坐标与 UIParent 坐标**数值相同**，
--     两者算出的物理位置一致。
--     UIParent 的实际渲染 scale = 色条物理宽 / screenWidth
--                              = 1819 / 1994.8 = 0.9118
--     格 249 -> rect.x = 248 * 7.823 = 1940.1 -> 物理 1940.1 * 0.9118 = 1769
--     （实测探针中心落在 1770，与格 249 的物理位置 1769 吻合 ✓）
--
--   ★ 为什么锚 UIParent 而不是 bars：
--     引擎接管的 AuraContainer，其 slot 按钮如果锚在 container 父链之外
--     （bars 是 container 的兄弟），布局时会被拉回 container 自己的坐标系，
--     我们设的位置直接失效。Shingen 用的就是 UIParent。
function CyberDeck:GetColorBarCellRect(i)
    if not i or i <= 0 or i > BLOCK_FIX_CONFIG.blockCount then return nil end
    return {
        x = GetXOffset(i - 1, BLOCK_FIX_CONFIG.blockWidth, BLOCK_FIX_CONFIG.blockSpacing),
        y = 0,
        w = BLOCK_FIX_CONFIG.blockWidth,
        h = BLOCK_FIX_CONFIG.blockHeight,
    }
end

function CyberDeck:clearAllTextures()
    for i = 1, BLOCK_FIX_CONFIG.blockCount do
        self:CreatTexture(i, 0)
    end
end

for i = 1, BLOCK_FIX_CONFIG.blockCount do
    CyberDeck:CreatTexture(i, 0)
end

local c = 255
local BAR_CONFIG = {
    count = c,
    width = screenWidth / c,
    height = 2,
    point = "TOPLEFT",
}

-- 创建"色条"的容器
local countBars = CreateFrame("Frame", "CyberDeckCountBars", UIParent)
countBars:SetSize(screenWidth, 20)
countBars:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, -2)
countBars:SetFrameStrata("TOOLTIP") -- 确保在最上层
countBars:SetFrameLevel(1)
local createdBars = {}
local spellIdToBar = {} -- 新增：用于根据 spellId 查找已存在的条
local nextAvailableIndex = 2
-- 多条 bar 共用一个终点色块，始终画在当前序列里最后创建的那条末尾
local countBarEndTexture = nil

local events = { "SPELL_UPDATE_USES", "PLAYER_ENTERING_WORLD", "SPELL_UPDATE_CHARGES" }
---@param minValue number 最小值
---@param maxValue number 最大值
---@param spellId number 法术ID
function CyberDeck:CreateAutoLayoutBar(valueType, minValue, maxValue, spellId)
    maxValue = maxValue or 0
    minValue = minValue or 0
    -- 重复性检查
    if spellIdToBar[spellId] then
        return spellIdToBar[spellId]
    end

    local startIndex = nextAvailableIndex
    local barWidth = maxValue * BAR_CONFIG.width
    -- +1 为末尾灰色终点色块，再 +2 为与下一条 bar 的间隔（与原逻辑一致）
    nextAvailableIndex = startIndex + maxValue + 3

    if nextAvailableIndex > BAR_CONFIG.count then
        print("警告: CyberDeck_CountBars 空间不足!")
        return nil
    end

    -- 1. 创建进度条主体
    local bar = CreateFrame("StatusBar", nil, countBars)
    bar:SetSize(barWidth + 1, BAR_CONFIG.height) -- +1 确保满格时能完全覆盖
    bar:SetPoint("TOPLEFT", countBars, "TOPLEFT", (startIndex - 1) * BAR_CONFIG.width, 0)
    bar:SetStatusBarTexture("Interface\\ChatFrame\\ChatFrameBackground")
    bar:GetStatusBarTexture():SetDrawLayer("ARTWORK")
    bar:SetStatusBarColor(1, 1, 1, 1)
    bar:SetFrameLevel(5000)

    -- 2. 创建背景色块 (左右各多出一个)
    for i = -1, maxValue do
        local currentRelativeIndex = i + 1
        local absolutePos = startIndex + i

        local tex = countBars:CreateTexture(nil, "BACKGROUND")
        tex:SetSize(BAR_CONFIG.width, BAR_CONFIG.height)
        tex:SetPoint("TOPLEFT", countBars, "TOPLEFT", (absolutePos - 1) * BAR_CONFIG.width, 0)
        tex:SetColorTexture(1 / 255, currentRelativeIndex / 255, 0, 1)
    end

    -- 2b. 末尾终点色块 (200, 200, 200)：仅显示在最后一次创建的 bar 上（复用同一纹理并改锚点）
    local endPos = startIndex + maxValue + 1
    if not countBarEndTexture then
        countBarEndTexture = countBars:CreateTexture(nil, "BACKGROUND")
        countBarEndTexture:SetSize(BAR_CONFIG.width, BAR_CONFIG.height)
    end
    countBarEndTexture:ClearAllPoints()
    countBarEndTexture:SetPoint("TOPLEFT", countBars, "TOPLEFT", (endPos - 1) * BAR_CONFIG.width, 0)
    countBarEndTexture:SetColorTexture(200 / 255, 200 / 255, 200 / 255, 1)
    countBarEndTexture:Show()

    -- 3. 刷新逻辑
    local function Refresh()
        local val = 0
        if valueType == "castCount" then
            val = C_Spell.GetSpellCastCount(spellId) or 0
        elseif valueType == "charge" then
            local charges = C_Spell.GetSpellCharges(spellId)
            if not charges then return end
            val = charges.currentCharges or 0
        end
        bar:SetMinMaxValues(minValue, maxValue)
        bar:SetValue(val)
    end

    for _, event in ipairs(events) do
        bar:RegisterEvent(event)
    end
    bar:SetScript("OnEvent", Refresh)

    Refresh()

    tinsert(createdBars, bar)
    spellIdToBar[spellId] = bar -- 记录此 spellId 已被创建

    return bar
end

--- 清除所有已创建的进度条和背景
function CyberDeck:ClearAllCyberDeckBars()
    -- 1. 释放框架
    for _, bar in ipairs(createdBars) do
        bar:UnregisterAllEvents()
        bar:SetScript("OnEvent", nil)
        bar:Hide()
        bar:SetParent(nil)
    end

    -- 2. 清除纹理
    local regions = { countBars:GetRegions() }
    for _, region in ipairs(regions) do
        if region:IsObjectType("Texture") then
            region:SetColorTexture(0, 0, 0, 0)
            region:Hide()
        end
    end

    -- 3. 重置所有状态表
    wipe(createdBars)
    wipe(spellIdToBar) -- 必须清空映射表，否则下次无法重新创建
    nextAvailableIndex = 2

    -- print("|cff00ff00CyberDeckBars 清除成功: 计数器与法术映射已重置。|r")
end

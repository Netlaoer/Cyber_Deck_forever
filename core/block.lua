local addon, ns = ...

-- 像素总线：与 Shingen Forever 版同款分档编码
--   索引 1..255   -> r=0,        g=序号/255
--   索引 256..510 -> r=1/255,    g=(序号-255)/255
--   索引 511      -> 纯红终止格 (1,0,0)，消费端读到即结束本行扫描
--
-- ★ 从 255 格升到 510 格的原因：队伍块要按 Shingen 的做法「每个可驱类型每人一格」，
--   圣骑士 3 类 x 30 人 = 90 格，加上原有的状态/技能不够放。
--   1..255 的编码完全不变，已有索引和 config.yml 不用动。
local BLOCK_SCHEME_SPAN = 255
local BLOCK_CAPACITY = 510

local screenWidth = GetScreenWidth()

local BLOCK_FIX_CONFIG = {
    capacity = BLOCK_CAPACITY,                 -- 可写数据格
    blockCount = BLOCK_CAPACITY + 1,           -- + 末尾终止格
    blockWidth = screenWidth / (BLOCK_CAPACITY + 1),
    blockHeight = 2,                           -- 色块高度
    blockSpacing = 0,                          -- 色块间距
}

--- 色块几何/容量（队伍驱散像素要用同一套宽高，见 core/group_aura.lua）
CyberDeck.BLOCK_FIX_CONFIG = BLOCK_FIX_CONFIG

--- 索引 -> (r, g)：r 是方案号，g 是套内序号
local function EncodeBlockChannels(index)
    local scheme = math.floor((index - 1) / BLOCK_SCHEME_SPAN)
    return scheme / 255, (index - scheme * BLOCK_SCHEME_SPAN) / 255
end

-- 计算 X 偏移
local function GetXOffset(index, Width, spacing)
    return index * (Width + spacing)
end

-- 创建"色条"的容器
local colorBars = CreateFrame("Frame", "CyberDeckColorBars", UIParent)
colorBars:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
colorBars:SetSize(screenWidth, BLOCK_FIX_CONFIG.blockHeight)
colorBars:SetFrameStrata("TOOLTIP") -- 确保在最上层
-- 层级必须与 Shingen 一致：色条 9001、队伍驱散 AuraContainer 9003（见 core/group_aura.lua）。
-- 之前用 10000/10001 时，引擎建的 AuraButton 落在色条下面，整行读到的是色条自己的 b=0。
colorBars:SetFrameLevel(9001)
-- colorBars:Raise()   -- Increases the frame's frame level above all other frames in its strata

-- 存储纹理的数组 (1 到 capacity)
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

-- 末尾终止格：纯红，不参与索引编码
local function DrawBlockEndMarker()
    local tex = creatTextureByIndex(BLOCK_FIX_CONFIG.blockCount)
    if tex then
        tex:SetColorTexture(1, 0, 0, 1)
    end
end

-- 更新或创建静态色块 (按索引)
function CyberDeck:CreatTexture(i, b)
    -- 没有对应块（本职业没配、或该专精没有这一格）时直接跳过：
    -- 之前 nil 会撞上下面的数值比较，抛错打断整个调用方
    if type(i) ~= "number" then return end
    -- 终止格不参与数据写入，否则消费端找不到行尾
    if i > BLOCK_FIX_CONFIG.capacity then return end
    local tex = creatTextureByIndex(i)
    if tex then
        local r, g = EncodeBlockChannels(i)
        tex:SetColorTexture(r, g, b, 1)
    end
end

-- 索引 -> (r, g)：core/group_aura.lua 的计时曲线复用同一套编码（红=方案号，绿=序号）
function CyberDeck:EncodeBlockChannels(index)
    return EncodeBlockChannels(index)
end

function CyberDeck:clearAllTextures()
    for i = 1, BLOCK_FIX_CONFIG.capacity do
        self:CreatTexture(i, 0)
    end
    DrawBlockEndMarker()
end

for i = 1, BLOCK_FIX_CONFIG.capacity do
    CyberDeck:CreatTexture(i, 0)
end
DrawBlockEndMarker()

-- ================================================================
-- 施法计数 / 充能条（**预留能力，勿删**）
-- 目前 9 个职业的 ClassBlocks 都没有 countBars 配置，所以这段一次都不会执行；
-- 需要时在 class/*.lua 的 buildBlocks 返回值里加：
--   countBars = { [1] = { valueType = "charge", minValue = 0, maxValue = 5, spellId = 123 } }
-- 即可由 main.lua 的 updatePlayerBarInfo() 自动建条（valueType: "castCount" / "charge"）。
-- ================================================================
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

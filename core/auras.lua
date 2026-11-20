local addon, ns = ...
local classFilename, classId = UnitClassBase("player")
local e = CyberDeck.e
local addAuras, updateAuras, removeAuras = {}, {}, {} -- 添加、更新、移除光环

--[[
    auras.lua — 逻辑光环状态机（按职业）
    如何在本文件里新增一条光环
    1. 在 `auras[职业ID]` 下增加键名（中文名），与职业 Lua 里 `CyberDeck.blocks.auras` 引用的名称一致。
    2. 常用字段：
       - remaining / duration / expirationTime：倒计时；有 duration 时事件会刷新 expirationTime。
       - count, countMin, countMax：层数；配合映射表里的 step（正加负减）在「法术冷却」或「施法成功」等路径更新。
       - addAuras / updateAuras / removeAuras：三张「法术 ID -> { event = e["…"], … }」表；

       event 必须是`e` 的键之一:
       「法术冷却」
       「施法成功」
       「图标改变」
       「法术覆盖」
       「屏幕提示显示/隐藏」
       「图标发光隐藏」
       - 可选：step、castBar（施法成功时是否要求有读条）、overrideSpellID、单条上的 duration 覆盖、isIcon 等；
         若多条逻辑共用显示名可用 name + spellId 指向另一条（见文件中武僧等示例）。

]]

-- 光环列表
local auras = {

    -- 圣骑士
    [2] = {
        -- 圣印（无限服）：7 种圣印共用一个条目，每次施放成功重置 30 秒。
        -- 不挂 addAuras——圣印有 7 个 rank 段共约 30 个 spellID，列全不划算；
        -- 由 forever.lua 的 MarkForeverAuraCast 直接把 spellID 解析成圣印编号后写入。
        ["圣印"] = {
            remaining = 0,
            duration = 30,
            expirationTime = nil,
            sealValue = 0,   -- 1 正义 2 命令 3 十字军 4 光明 5 智慧 6 愤怒 7 公正
        },
        ["神圣意志"] = {
            remaining = 0,
            duration = 12,
            expirationTime = nil,
            addAuras = {
                [223819] = { event = e["法术冷却"] },
                [408458] = { event = e["法术冷却"] },
            },
            updateAuras = nil,
            removeAuras = {
                [223819] = { event = e["屏幕提示隐藏"] },
                [408458] = { event = e["屏幕提示隐藏"] },
            },
        },
        ["圣光灌注"] = {
            remaining = 0,
            duration = 15,
            count = 0,
            countMin = 0,
            countMax = 2,
            expirationTime = nil,
            addAuras = {
                [54149] = { event = e["法术冷却"], step = 2 },
            },
            updateAuras = {
                [19750] = { event = e["施法成功"], step = -1 }, -- 圣光闪现
                [275773] = { event = e["施法成功"], step = -1 }, -- 审判
            },
            removeAuras = {
                [54149] = { event = e["屏幕提示隐藏"] },
            },
        },
        ["神性之手"] = {
            remaining = 0,
            duration = 15,
            count = 0,
            countMin = 0,
            countMax = 2,
            expirationTime = nil,
            addAuras = {
                [414273] = { event = e["法术冷却"], step = 2 },
            },
            updateAuras = {
                [82326] = { event = e["施法成功"], step = -1 }, -- 圣光术
            },
            removeAuras = nil,
        },
        ["神圣壁垒"] = {
            remaining = 0,
            duration = 20,
            expirationTime = nil,
            addAuras = {
                [432496] = { event = e["法术冷却"] },
            },
            updateAuras = nil,
            removeAuras = nil,
        },
        ["圣洁武器"] = {
            remaining = 0,
            duration = 20,
            expirationTime = nil,
            addAuras = {
                [432502] = { event = e["法术冷却"] },
            },
            updateAuras = nil,
            removeAuras = nil,
        },
        ["闪耀之光"] = {
            remaining = 0,
            duration = 30,
            count = 0,
            countMin = 0,
            countMax = 2,
            expirationTime = nil,
            addAuras = {
                [327510] = { event = e["法术冷却"], step = 1 },
            },
            updateAuras = {
                [85673] = { event = e["施法成功"], step = -1 }, -- 荣耀圣令
            },
            removeAuras = nil,
        },
        ["奉献"] = {
            remaining = 0,
            duration = 12,
            expirationTime = nil,
            addAuras = {
                [188370] = { event = e["法术冷却"] },
            },
            updateAuras = nil,
            removeAuras = nil,
        },
        ["复仇之怒"] = {
            remaining = 0,
            duration = 24,
            expirationTime = nil,
            addAuras = {
                [31884] = { event = e["法术冷却"] },
            },
            updateAuras = nil,
            removeAuras = nil,
        },
        ["处决宣判"] = {
            remaining = 0,
            duration = 10,
            expirationTime = nil,
            addAuras = {
                [343527] = { event = e["法术冷却"] },
            },
            updateAuras = nil,
            removeAuras = nil,
        },
        ["圣光之锤"] = {
            remaining = 0,
            duration = 20,
            expirationTime = nil,
            addAuras = {
                [1246643] = { event = e["法术冷却"] },
                [427441] = { event = e["法术冷却"] },
            },
            updateAuras = nil,
            removeAuras = {
                [427453] = { event = e["施法成功"] }, -- 施放圣光之锤后清除buff
            },
        },
        ["神圣军备"] = {
            remaining = 0,
            duration = 0,
            expirationTime = nil,
            isIcon = 0,
            addAuras = {
                [432459] = {
                    event = e["图标改变"],
                    overrideSpellID = 432472,
                },
            },
            updateAuras = nil,
            removeAuras = {
                [432459] = {
                    event = e["图标改变"],
                    overrideSpellID = 432472,
                },
            },
        },
        ["美德道标"] = {
            remaining = 0,
            duration = 9,
            expirationTime = nil,
            addAuras = {
                [200025] = { event = e["法术冷却"] },
            },
            updateAuras = nil,
            removeAuras = nil,
        },
    },







}

CyberDeck.Auras = {}
do
    CyberDeck.Auras = auras[classId] or {}
    local function indexAura(target, auraName, auraData)
        for spellId, info in pairs(auraData) do
            local ev = info.event
            local byEvent = target[ev]
            if not byEvent then
                byEvent = {}
                target[ev] = byEvent
            end
            local bySpell = byEvent[spellId]
            if not bySpell then
                bySpell = {}
                byEvent[spellId] = bySpell
            end
            bySpell[auraName] = info
        end
    end

    for name, data in pairs(CyberDeck.Auras) do
        if data.addAuras then
            indexAura(addAuras, name, data.addAuras)
        end
        if data.updateAuras then
            indexAura(updateAuras, name, data.updateAuras)
        end
        if data.removeAuras then
            indexAura(removeAuras, name, data.removeAuras)
        end
    end
end

---@param auraMap table<string, table>|nil 光环名 -> info
---@param castBarID any|nil 施法成功时传入读条 ID；冷却类调用传 nil，不按读条过滤
local function applyAuraMapForSpellEvent(auraMap, castBarID)
    if not auraMap then
        return
    end
    local now = GetTime()
    for auraName, info in pairs(auraMap) do
        local aura = CyberDeck.Auras[auraName]
        if aura and ((not info.castBar) or castBarID) then
            if info.duration then
                aura.expirationTime = now + info.duration
            elseif aura.duration then
                aura.expirationTime = now + aura.duration
            end
            if aura.count and info.step then
                if info.step > 0 then
                    aura.expirationTime = now + aura.duration
                    aura.count = math.min(aura.countMax, aura.count + info.step)
                else
                    aura.count = math.max(aura.countMin, aura.count + info.step)
                end
            end
        end
    end
end

---@param auraMap table<string, table>|nil 光环名 -> info
---@param castBarID any|nil 施法成功时传入读条 ID；冷却类调用传 nil，不按读条过滤
local function updateAuraMapForSpellEvent(auraMap, castBarID)
    if not auraMap then
        return
    end
    local now = GetTime()
    for auraName, info in pairs(auraMap) do
        local aura = CyberDeck.Auras[auraName]
        if aura and ((not info.castBar) or castBarID) then
            if aura.count and info.step then
                if info.step > 0 then
                    aura.expirationTime = now + aura.duration
                    aura.count = math.min(aura.countMax, aura.count + info.step)
                else
                    aura.count = math.max(aura.countMin, aura.count + info.step)
                end
            elseif aura.duration then
                aura.expirationTime = now + aura.duration
            end
        end
    end
end

---@param removeMap table<string, table>|nil 光环名 -> info
---@param resetCount boolean|nil 为 true 时重置层数（冷却/施法成功移除）；屏幕提示类仅清时间传 false
local function clearAurasFromRemoveMap(removeMap, resetCount)
    if not removeMap then
        return
    end
    for auraName in pairs(removeMap) do
        local aura = CyberDeck.Auras[auraName]
        if aura then
            if resetCount and aura.count then
                aura.count = aura.countMin
            end
            aura.expirationTime = nil
        end
    end
end

---@param spellID number 法术 ID（冷却事件键）
-- 通过 SPELL_UPDATE_COOLDOWN 同步光环结束时间与层数
function CyberDeck:updateAuraBySpellCooldown(spellID)
    local ev = e["法术冷却"]
    local addBySpell = addAuras[ev]
    local updateBySpell = updateAuras[ev]
    local removeBySpell = removeAuras[ev]
    applyAuraMapForSpellEvent(addBySpell and addBySpell[spellID], nil)
    updateAuraMapForSpellEvent(updateBySpell and updateBySpell[spellID], nil)
    clearAurasFromRemoveMap(removeBySpell and removeBySpell[spellID], true)
end

---@param spellID number 法术ID
---@param castBarID number 施法条ID
-- 通过事件"UNIT_SPELLCAST_SUCCEEDED"更新光环, 并更新光环的层数
function CyberDeck:updateAuraBySuccess(spellID, castBarID)
    local ev = e["施法成功"]
    local addBySpell = addAuras[ev]
    local updateBySpell = updateAuras[ev]
    local removeBySpell = removeAuras[ev]
    applyAuraMapForSpellEvent(addBySpell and addBySpell[spellID], castBarID)
    updateAuraMapForSpellEvent(updateBySpell and updateBySpell[spellID], castBarID)
    clearAurasFromRemoveMap(removeBySpell and removeBySpell[spellID], true)
end

local function updateAuraByIconMap(map, spellID)
    if not map then
        return
    end
    local hasOverride = false
    local overrideSpellID = C_Spell.GetOverrideSpell(spellID)
    for auraName, info in pairs(map) do
        local aura = CyberDeck.Auras[auraName]
        if overrideSpellID and info.overrideSpellID and overrideSpellID == info.overrideSpellID then
            hasOverride = true
        end
        if aura.isIcon then
            if hasOverride then
                aura.isIcon = 2
            else
                aura.isIcon = 1
            end
        end
        if aura then
            if hasOverride and aura.duration then
                aura.expirationTime = GetTime() + aura.duration
            else
                aura.expirationTime = nil
            end
        end
    end
end

---@param spellID number 法术ID
-- 通过事件"SPELL_UPDATE_ICON"更新光环, 并更新光环的层数
function CyberDeck:updateAuraByIcon(spellID)
    local ev = e["图标改变"]
    local addBySpell = addAuras[ev]
    local updateBySpell = updateAuras[ev]
    local removeBySpell = removeAuras[ev]
    if addBySpell and addBySpell[spellID] then
        updateAuraByIconMap(addBySpell[spellID], spellID)
    end
    if updateBySpell and updateBySpell[spellID] then
        updateAuraByIconMap(updateBySpell[spellID], spellID)
    end
    if removeBySpell and removeBySpell[spellID] then
        updateAuraByIconMap(removeBySpell[spellID], spellID)
    end
end

-- 首次登录遍历所有Icon光环
function CyberDeck:updateAuraIconByEnteringWorld()
    local ev = e["图标改变"]
    local addBySpell = addAuras[ev]
    local updateBySpell = updateAuras[ev]
    local removeBySpell = removeAuras[ev]
    if addBySpell then
        for spellId, info in pairs(addBySpell) do
            updateAuraByIconMap(addBySpell[spellId], spellId)
        end
    end
    if updateBySpell then
        for spellId, info in pairs(updateBySpell) do
            updateAuraByIconMap(updateBySpell[spellId], spellId)
        end
    end
    if removeBySpell then
        for spellId, info in pairs(removeBySpell) do
            updateAuraByIconMap(removeBySpell[spellId], spellId)
        end
    end
end

local function updateAuraByOverrideMap(map, overrideSpellID)
    if not map then
        return
    end

    for auraName, info in pairs(map) do
        local aura = CyberDeck.Auras[auraName]
        if aura then
            if overrideSpellID and aura.duration and overrideSpellID == info.overrideSpellID then
                if aura.duration then
                    aura.expirationTime = GetTime() + aura.duration
                end
            else
                aura.expirationTime = nil
            end
        end
    end
end

---@param baseSpellID number 基本法术ID
---@param overrideSpellID number 覆盖法术ID
-- 通过事件"COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED"更新光环, 并更新光环的结束时间
function CyberDeck:updateAuraBySpellOverride(baseSpellID, overrideSpellID)
    local ev = e["法术覆盖"]
    local addBySpell = addAuras[ev]
    local updateBySpell = updateAuras[ev]
    local removeBySpell = removeAuras[ev]
    if addBySpell and addBySpell[baseSpellID] then
        updateAuraByOverrideMap(addBySpell[baseSpellID], overrideSpellID)
    end
    if updateBySpell and updateBySpell[baseSpellID] then
        updateAuraByOverrideMap(updateBySpell[baseSpellID], overrideSpellID)
    end
    if removeBySpell and removeBySpell[baseSpellID] then
        updateAuraByOverrideMap(removeBySpell[baseSpellID], overrideSpellID)
    end
end

---@param spellId number 光环ID, 屏幕提示
-- 通过事件"SPELL_ACTIVATION_OVERLAY_HIDE"更新光环, 并更新光环的结束时间
function CyberDeck:updateAuraByActivationOverlayShow(spellId)
    local addBySpell = addAuras[e["屏幕提示显示"]]
    local updateBySpell = updateAuras[e["屏幕提示显示"]]
    applyAuraMapForSpellEvent(addBySpell and addBySpell[spellId], nil)
    updateAuraMapForSpellEvent(updateBySpell and updateBySpell[spellId], nil)
end

---@param spellId number 光环ID, 屏幕提示
-- 通过事件"SPELL_ACTIVATION_OVERLAY_HIDE"更新光环, 并更新光环的结束时间
function CyberDeck:updateAuraByActivationOverlayHide(spellId)
    local removeBySpell = removeAuras[e["屏幕提示隐藏"]]
    clearAurasFromRemoveMap(removeBySpell and removeBySpell[spellId], false)
end

-- SPELL_ACTIVATION_OVERLAY_GLOW_SHOW / HIDE：与 main.lua 一致，按是否仍发光刷新或清除时间
function CyberDeck:updateAuraByOverlayGlow(spellID)
    local ev = e["图标发光隐藏"]
    local removeBySpell = removeAuras[ev]
    local map = removeBySpell and removeBySpell[spellID]
    if not map then
        return
    end
    local now = GetTime()
    local isSpellOverlayed = C_SpellActivationOverlay.IsSpellOverlayed(spellID)
    for auraName in pairs(map) do
        local aura = CyberDeck.Auras[auraName]
        if aura then
            if isSpellOverlayed and aura.duration then
                aura.expirationTime = now + aura.duration
            else
                aura.expirationTime = nil
            end
        end
    end
end

-- 通过每帧更新光环
function CyberDeck:updateAura()
    local currentTime = GetTime()
    for name, info in pairs(CyberDeck.Auras) do
        local expTime = info.expirationTime
        if expTime then
            if info.count and info.count <= 0 then
                expTime = nil
            end
            if expTime then
                local remaining = expTime - currentTime
                if remaining > 0 then
                    info.remaining = remaining
                else
                    info.expirationTime = nil
                    info.remaining = 0
                    if info.count then info.count = 0 end
                end
            else
                info.expirationTime = nil
                info.remaining = 0
                if info.count then info.count = 0 end
            end
        else
            if info.remaining ~= 0 then info.remaining = 0 end
            if info.count and info.count ~= info.countMin then info.count = info.countMin end
        end
    end
end

function CyberDeck:updateAuraBlocks()
    if not self.blocks or not self.blocks.auras then
        return
    end
    for k, info in pairs(self.blocks.auras) do
        if info.auraName and info.showKey then
            local aura = CyberDeck.Auras and CyberDeck.Auras[info.auraName]
            if not aura then
                self:CreatTexture(k, 0)
            else
                local v = aura[info.showKey]
                if v then
                    self:CreatTexture(k, v / 255)
                else
                    self:CreatTexture(k, 0)
                end
            end
        else
            self:CreatTexture(k, 0)
        end
    end
end

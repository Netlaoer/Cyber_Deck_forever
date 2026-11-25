local addon, ns = ...
--[[
    core/forever.lua — 无限服(wowf, Interface 16001)适配层
    差异：60 级经典技能组带 rank（正式服 ID 大多不存在）；无专精系统，按天赋树判定；
          无英雄天赋 / 一键辅助；药水物品 ID 是经典旧世的。

    提供：
    - F:ResolveSpellID(name)        名称 -> 已学会的 rank ID
    - F:GetActiveSpecIndex()        按天赋树算专精 1..3
    - F:UpdateForeverAuras()        圣印/神恩术/圣光灌注/正义之怒 像素
    - F.itemGroups                  药水物品 ID 分组
]]

local F = CyberDeck
local _, _, _, tocVersion = GetBuildInfo()
F.tocVersion = tocVersion
F.isForever = (tocVersion == 16001)

-- 旧全局 API 兜底
if type(IsPlayerMoving) ~= "function" then
    function IsPlayerMoving()
        local speed = GetUnitSpeed and GetUnitSpeed("player") or 0
        return (speed or 0) > 0
    end
end

-- 事件注册容错：无限服没有的事件不应该让整个 OnEnable 中断
local rawRegisterEvent = F.RegisterEvent
if type(rawRegisterEvent) == "function" then
    function F:RegisterEvent(event, ...)
        local ok = pcall(rawRegisterEvent, self, event, ...)
        if not ok then
            self.badEvents = self.badEvents or {}
            self.badEvents[event] = true
        end
    end
end

-- ================================================================
--                      名称 -> 法术ID
-- ================================================================
local spellNameToID = {}
-- 训练师表里的“名字 -> 最早能学到的 rank”，用来区分“没学会”和“表里没这个技能名”
local trainerSpellNames = {}
local spellBookBuilt = false

local function tryAddSpell(id)
    if type(id) ~= "number" or id <= 0 then return end
    local ok, name = pcall(C_Spell.GetSpellName, id)
    if ok and type(name) == "string" and name ~= "" then
        spellNameToID[name] = id -- 后写覆盖：同一技能高 rank 一般排在后面
    end
end

-- 兼容两种 GetSpellBookItemInfo 返回形态
local function spellIDFromSlot(slot, bank)
    local ok, a, b = pcall(C_SpellBook.GetSpellBookItemInfo, slot, bank)
    if not ok then return nil end
    if type(a) == "table" then
        return a.spellID or a.actionID or a.id
    end
    if a == "SPELL" and type(b) == "number" then
        return b
    end
    return nil
end

-- 用离线表建“名称 -> 已学会的最高 rank”；名称由客户端提供，自动跟随语言
function F:BuildSpellIndexFromData()
    local all = CyberDeck.ForeverSpellData
    local classKey = self.state and self.state.classFilename
    local list = all and classKey and all[classKey]
    if type(list) ~= "table" then return 0 end

    -- 同名技能会有多个 rank，按学习等级分桶
    local byName = {}
    for i = 1, #list do
        local entry = list[i]
        local level, id = entry[1], entry[2]
        if type(level) == "number" and type(id) == "number" then
            local ok, info = pcall(C_Spell.GetSpellInfo, id)
            local name = (ok and type(info) == "table") and info.name or nil
            if type(name) == "string" and name ~= "" then
                local bucket = byName[name]
                if not bucket then
                    bucket = {}
                    byName[name] = bucket
                end
                bucket[#bucket + 1] = { level = level, id = id }
            end
        end
    end

    local count = 0
    for name, bucket in pairs(byName) do
        table.sort(bucket, function(a, b) return a.level > b.level end)
        -- 记录最早能学到的 rank（bucket 排的是 level 降序，最后一个就是 rank 1）
        if not trainerSpellNames[name] then
            local lowest = bucket[#bucket]
            trainerSpellNames[name] = { id = lowest.id, level = lowest.level }
        end
        for j = 1, #bucket do
            if C_SpellBook.IsSpellKnown(bucket[j].id) then
                spellNameToID[name] = bucket[j].id
                count = count + 1
                break
            end
        end
    end
    return count
end

function F:RebuildSpellBookIndex()
    wipe(spellNameToID)
    local seen = {}
    local bank = "spell"

    -- 快路径：按技能线遍历
    local ok = pcall(function()
        local numLines = C_SpellBook.GetNumSpellBookSkillLines()
        for line = 1, (numLines or 0) do
            local info = C_SpellBook.GetSpellBookSkillLineInfo(line)
            if info then
                local offset = info.itemIndexOffset or 0
                local count = info.numSpellBookItems or 0
                for i = 1, count do
                    local slot = offset + i
                    if not seen[slot] then
                        seen[slot] = true
                        tryAddSpell(spellIDFromSlot(slot, bank))
                    end
                end
            end
        end
    end)

    -- 兜底：暴力扫槽位（API 形态变化时仍能建索引）
    if not ok or next(spellNameToID) == nil then
        for slot = 1, 300 do
            if not seen[slot] then
                seen[slot] = true
                tryAddSpell(spellIDFromSlot(slot, bank))
            end
        end
    end

-- 离线表覆盖同名最高 rank，比法术书更准；天赋技能仍靠上面的法术书索引
    self.dataSpellCount = self:BuildSpellIndexFromData()

    spellBookBuilt = true
end

-- 名称转 ID：只在“已学会”时返回，避免拿到未学的 rank 导致冷却永远不可用
function F:ResolveSpellID(name)
    if type(name) ~= "string" or name == "" then return nil end
    if not spellBookBuilt then self:RebuildSpellBookIndex() end

    local id = spellNameToID[name]
    if id and C_SpellBook.IsSpellKnown(id) then
        return id
    end

    -- 备用：客户端自带的名称解析
    if C_Spell.GetSpellIDForSpellIdentifier then
        local ok, v = pcall(C_Spell.GetSpellIDForSpellIdentifier, name)
        if ok and type(v) == "number" and v > 0 and C_SpellBook.IsSpellKnown(v) then
            spellNameToID[name] = v
            return v
        end
    end
    return nil
end

function F:InvalidateSpellBookIndex()
    spellBookBuilt = false
    wipe(spellNameToID)
end

-- 技能名状态：已学会 / 未学会(训练师表有) / 表里也没有
-- 天赋技能不在训练师表里，落第三种时不能当成“没学”
function F:GetSpellNameStatus(name)
    local learned = self:ResolveSpellID(name)
    if learned then
        return learned, "已学会"
    end
    local info = trainerSpellNames[name]
    if info then
        return nil, ("未学会(训练师表 %d 级 ID=%d)"):format(info.level, info.id)
    end
    return nil, "训练师表里没有(天赋未解锁或名字对不上)"
end

-- ================================================================
--                        专精判定
-- ================================================================
F.foreverSpecs = {
    -- 圣骑士（唯一有决策层的职业，专精判定经过实机校准）
    ["PALADIN"] = {
        [1] = { id = 100021, name = "神圣", role = "HEALER", range = 30 },
        [2] = { id = 100022, name = "防护", role = "TANK", range = 10 },
        [3] = { id = 100023, name = "惩戒", role = "DAMAGER", range = 10 },
    },
    -- 以下 8 个职业为骨架阶段（决策层未实现），取经典 60 级标准值
    ["WARRIOR"] = {
        [1] = { id = 100001, name = "武器", role = "DAMAGER", range = 5 },
        [2] = { id = 100002, name = "狂怒", role = "DAMAGER", range = 5 },
        [3] = { id = 100003, name = "防护", role = "TANK", range = 5 },
    },
    ["HUNTER"] = {
        [1] = { id = 100004, name = "野兽控制", role = "DAMAGER", range = 5 },
        [2] = { id = 100005, name = "射击", role = "DAMAGER", range = 25 },
        [3] = { id = 100006, name = "生存", role = "TANK", range = 5 },
    },
    ["ROGUE"] = {
        [1] = { id = 100007, name = "狂徒", role = "DAMAGER", range = 5 },
        [2] = { id = 100008, name = "敏锐", role = "DAMAGER", range = 5 },
        [3] = { id = 100009, name = "刺杀", role = "DAMAGER", range = 5 },
    },
    ["PRIEST"] = {
        [1] = { id = 100010, name = "戒律", role = "HEALER", range = 30 },
        [2] = { id = 100011, name = "圣言", role = "HEALER", range = 30 },
        [3] = { id = 100012, name = "暗影", role = "DAMAGER", range = 30 },
    },
    ["SHAMAN"] = {
        [1] = { id = 100013, name = "元素", role = "DAMAGER", range = 25 },
        [2] = { id = 100014, name = "增强", role = "DAMAGER", range = 25 },
        [3] = { id = 100015, name = "恢复", role = "HEALER", range = 30 },
    },
    ["MAGE"] = {
        [1] = { id = 100016, name = "奥术", role = "DAMAGER", range = 30 },
        [2] = { id = 100017, name = "火焰", role = "DAMAGER", range = 25 },
        [3] = { id = 100018, name = "冰霜", role = "DAMAGER", range = 25 },
    },
    ["WARLOCK"] = {
        [1] = { id = 100019, name = "痛苦", role = "DAMAGER", range = 30 },
        [2] = { id = 100020, name = "恶魔学识", role = "DAMAGER", range = 20 },
        [3] = { id = 100024, name = "毁灭", role = "DAMAGER", range = 25 },
    },
    ["DRUID"] = {
        [1] = { id = 100025, name = "平衡", role = "HEALER", range = 30 },
        [2] = { id = 100026, name = "野性", role = "DAMAGER", range = 25 },
        [3] = { id = 100027, name = "守护", role = "TANK", range = 25 },
    },
}

-- 树名 -> 专精索引：无限服 treeIDs 顺序不等于 1/2/3 系，必须按树名归类
local specTreeKeys = {
    { index = 1, keys = { "神圣", "HOLY" } },
    { index = 2, keys = { "防护", "PROTECT" } },
    { index = 3, keys = { "惩戒", "RETRIBUT" } },
}

local function matchSpecTree(name)
    if type(name) ~= "string" then return nil end
    local upper = name:upper()
    for _, entry in ipairs(specTreeKeys) do
        for _, key in ipairs(entry.keys) do
            if upper:find(key, 1, true) then
                return entry.index
            end
        end
    end
    return nil
end

-- 经典三系天赋树点数（无限服的天赋界面就是经典布局：1 神圣 / 2 防护 / 3 惩戒）
local function readTalentTabPoints()
    if type(GetNumTalentTabs) ~= "function" or type(GetTalentTabInfo) ~= "function" then
        return nil
    end
    local ok, num = pcall(GetNumTalentTabs)
    if not ok or type(num) ~= "number" or num <= 0 then return nil end
    local out = { 0, 0, 0 }
    local any = false
    for i = 1, 3 do
        if i <= num then
            local okTab, _, _, points = pcall(GetTalentTabInfo, i)
            if okTab and type(points) == "number" then
                out[i] = points
                if points > 0 then any = true end
            end
        end
    end
    return any and out or nil
end

local specCache = { index = 1 }

-- 专精探测节点（ForeverDB Talents）：三系各一个 10 点前置天赋，互斥
local SPEC_PROBE_NODES = {
    { index = 1, node = 105325, name = "Divine Favor" },      -- 神圣
    { index = 2, node = 105625, name = "Templar's Bulwark" }, -- 防护
    { index = 3, node = 105696, name = "Seal of Command" },   -- 惩戒
}

function F:GetActiveSpecIndex()
    -- 战斗中天赋读取可能返回 secret，直接用上次结果
    if InCombatLockdown() then
        return specCache.index
    end

    local points = readTalentTabPoints()

    local byOrder = { 0, 0, 0 }
    local byName = { 0, 0, 0 }
    local treeDump = {}
    local probeIndex, probeNodeName
    pcall(function()
        local cfg = C_ClassTalents.GetActiveConfigID()
        if not cfg then return end

        -- 先按专精天赋节点判定：比树名/treeIDs 顺序都可靠
        for _, probe in ipairs(SPEC_PROBE_NODES) do
            local okProbe, ni = pcall(C_Traits.GetNodeInfo, cfg, probe.node)
            if okProbe and type(ni) == "table" then
                local rank = ni.activeRank
                if type(rank) ~= "number" then rank = ni.currentRank end
                if type(rank) == "number" and rank > 0 then
                    probeIndex, probeNodeName = probe.index, probe.name
                    break
                end
            end
        end

        local info = C_Traits.GetConfigInfo(cfg)
        local trees = info and info.treeIDs
        if type(trees) ~= "table" then return end
        for ti, treeID in ipairs(trees) do
            local nodes = C_Traits.GetTreeNodes(treeID)
            if type(nodes) == "table" then
                local sum = 0
                for _, nodeID in ipairs(nodes) do
                    local ni = C_Traits.GetNodeInfo(cfg, nodeID)
                    if type(ni) == "table" then
                        local rank = ni.activeRank
                        if type(rank) ~= "number" then rank = ni.currentRank end
                        if type(rank) == "number" and rank > 0 then
                            sum = sum + rank
                        end
                    end
                end
                local treeName
                local okName, treeInfo = pcall(C_Traits.GetTreeInfo, cfg, treeID)
                if okName and type(treeInfo) == "table" then
                    treeName = treeInfo.name or treeInfo.treeName
                end
                treeDump[#treeDump + 1] = { idx = ti, id = treeID, name = treeName, points = sum }
                if ti <= 3 then
                    byOrder[ti] = byOrder[ti] + sum
                end
                local specIndex = matchSpecTree(treeName)
                if specIndex then
                    byName[specIndex] = byName[specIndex] + sum
                end
            end
        end
    end)

    local specIndex, source

    -- 0) 专精天赋节点（最准）：Divine Favor / Templar's Bulwark / Seal of Command
    if probeIndex then
        specIndex, source = probeIndex, "专精天赋(" .. tostring(probeNodeName) .. ")"
    end

    -- 1) 树名归类（能读到树名时最准；无限服实际读到 nil）
    local namedBest, namedIndex = 0, nil
    for i = 1, 3 do
        if byName[i] > namedBest then
            namedBest, namedIndex = byName[i], i
        end
    end

    if not specIndex and namedIndex then
        specIndex, source = namedIndex, "树名归类"
    end

    -- 2) 经典天赋树（顺序固定：1 神圣 / 2 防护 / 3 惩戒）
    if not specIndex and points then
        local best = 0
        for i = 1, 3 do
            if points[i] > best then
                best, specIndex = points[i], i
            end
        end
        source = "经典天赋树"
    end

    -- 3) 专精专属技能（各锁一系；查不到只说明没学/没点，不能反证不是这一系）：
    --    神圣之盾 20927 = 防护(训练师 Lv40)；神圣震击 1311606 = 神圣(天赋 Lv30)；忏悔 9623 = 惩戒(天赋)
    local probe = {}
    local probeStatus = {}
    for _, probeName in ipairs({ "神圣之盾", "神圣震击", "忏悔" }) do
        local probeID, status = self:GetSpellNameStatus(probeName)
        probe[probeName] = probeID
        probeStatus[probeName] = status
    end
    if not specIndex then
        if probe["神圣之盾"] then
            specIndex, source = 2, "技能(神圣之盾)"
        elseif probe["神圣震击"] then
            specIndex, source = 1, "技能(神圣震击)"
        elseif probe["忏悔"] then
            specIndex, source = 3, "技能(忏悔)"
        end
    end

    -- 4) treeIDs 顺序（已知不可靠，仅最后兜底）
    local display = points or byOrder
    if not specIndex then
        local best = 0
        for i = 1, 3 do
            if display[i] > best then
                best, specIndex = display[i], i
            end
        end
        source = "treeIDs 顺序"
    end

    -- 无限服只返回 1 棵树，byOrder 会把点数全堆在第 1 位；有 traitNode 判定、
    -- 又读不到经典三系点数时，把总点数归到判定出的那一系
    if probeIndex and not points then
        local total = 0
        for i = 1, 3 do
            total = total + (display[i] or 0)
        end
        display = { 0, 0, 0 }
        display[probeIndex] = total
    end

    specCache.index = specIndex or specCache.index or 1
    specCache.points = display
    specCache.pointsSource = source
    specCache.pointsByOrder = byOrder
    specCache.pointsByName = byName
    specCache.trees = treeDump
    specCache.skillProbe = probe
    specCache.skillProbeStatus = probeStatus
    specCache.probeNode = probeIndex and { index = probeIndex, name = probeNodeName } or nil
    specCache.dataSpells = self.dataSpellCount
    return specCache.index
end

function F:GetForeverSpecInfo(index)
    local map = self.foreverSpecs and self.foreverSpecs[self.state.classFilename]
    local info = map and map[index or 1]
    return info or { id = 0, name = "未知", role = "DAMAGER", range = 10 }
end

-- ================================================================
--                     无限服光环像素
-- ================================================================
-- 圣印：同一时间只有一个
local SEAL_ORDER = {
    { name = "正义圣印", value = 1 },
    { name = "命令圣印", value = 2 },
    { name = "十字军圣印", value = 3 },
    { name = "光明圣印", value = 4 },
    { name = "智慧圣印", value = 5 },
    { name = "愤怒圣印", value = 6 },
    { name = "公正圣印", value = 7 },
}

local function isSecret(v)
    return type(issecretvalue) == "function" and issecretvalue(v)
end

-- 扫描某个单位的光环，返回 name -> aura 表
local function scanAuras(unit, filter, maxIndex)
    local t = {}
    if not UnitExists(unit) then return t end
    for i = 1, maxIndex do
        local ok, aura = pcall(C_UnitAuras.GetBuffDataByIndex, unit, i, filter)
        if not ok or type(aura) ~= "table" then break end
        local name = aura.name
        if name and not isSecret(name) then
            t[name] = aura
        end
    end
    return t
end

local function remainingSeconds(aura)
    if type(aura) ~= "table" then return 0 end
    local exp = aura.expirationTime
    if isSecret(exp) or type(exp) ~= "number" then return 0 end
    if exp == 0 then return 0 end -- 永久光环
    local left = exp - GetTime()
    if left < 0 then left = 0 end
    return left
end

-- 常驻 buff 的最后看到时间：战斗中名字偶尔读不到时不要立刻判成没有（否则一开一关）
local lastSeenAt = {}
local spellIDByName = {}
local SEEN_GRACE = 1.5   -- 只兜住单帧读不到；再长就会让“buff 已经掉了”迟迟不回落

-- 施放成功后的保底有效期：战斗中读不到名字时用，避免把已开的光环当成没开反复重开
local AURA_LOCK_SECONDS = {
    ["正义之怒"] = 1700,   -- 30 分钟 buff，留 100 秒余量
}
local auraLockUntil = {}
local auraSpellName = {}

-- 圣印计时交给 core/auras.lua 的 Auras["圣印"]：MarkForeverAuraCast 写入，
-- updateAura() 每帧算 remaining，这里不再维护锁

function F:MarkForeverAuraCast(spellID)
    if type(spellID) ~= "number" then return end
    local name = auraSpellName[spellID]
    if not name then
        local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
        name = (ok and type(info) == "table" and info.name) or nil
        if not name or isSecret(name) then
            -- 战斗中 GetSpellInfo 可能被保护，退回法术书名称索引反查
            name = nil
            if not spellBookBuilt then self:RebuildSpellBookIndex() end
            for n, id in pairs(spellNameToID) do
                if id == spellID then
                    name = n
                    break
                end
            end
        end
        if name then
            auraSpellName[spellID] = name
        end
    end
    if not name then return end

    local seconds = AURA_LOCK_SECONDS[name]
    if seconds then
        auraLockUntil[name] = GetTime() + seconds
        return
    end
    for _, seal in ipairs(SEAL_ORDER) do
        if seal.name == name then
            local aura = CyberDeck.Auras and CyberDeck.Auras["圣印"]
            if aura then
                local dur = aura.duration or 30
                aura.sealValue = seal.value
                aura.expirationTime = GetTime() + dur
                aura.remaining = dur
            end
            return
        end
    end
end

function F:UpdateForeverAuras()
    if not self.blocks or not self.blocks.state then return end
    local st = self.blocks.state
    if not (st["圣印"] or st["神恩术"] or st["圣光灌注"] or st["正义之怒"]) then
        return
    end

    local buffs = scanAuras("player", "HELPFUL", 40)
    local now = GetTime()
    local function stillThere(name)
        if buffs[name] then
            lastSeenAt[name] = now
-- 不能续 auraLockUntil：每帧续满会让 buff 真到期时锁还剩一整个周期，像素继续显示“有”
            return true
        end
        -- 战斗中 buff 读不到时，用“最近施放成功”的保底有效期兜住
        local lockUntil = auraLockUntil[name]
        if lockUntil and now < lockUntil and UnitAffectingCombat("player") then
            return true
        end
        -- 战斗中 buff 名可能读不到，改按 spellID 再确认一次（结果缓存，避免反复解析）
        local id = spellIDByName[name]
        if id == nil then
            id = F:ResolveSpellID(name) or false
            spellIDByName[name] = id
        end
        if id and C_UnitAuras.GetPlayerAuraBySpellID then
            local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, id)
            if ok and type(aura) == "table" then
                lastSeenAt[name] = now
                return true
            end
        end
        local seen = lastSeenAt[name]
        return seen ~= nil and (now - seen) < SEEN_GRACE
    end

    if st["圣印"] then
        local value = 0
        local sealAuraFound
        for _, seal in ipairs(SEAL_ORDER) do
            local found = buffs[seal.name]
            if found then
                value = seal.value
                sealAuraFound = found
                break
            end
        end
        -- 战斗中名字可能整段读不到（secret），按 spellID 复查；
        -- 不靠时间猜，否则进战斗瞬间会被判成没挂圣印、立刻重放一次
        if value == 0 and C_UnitAuras.GetPlayerAuraBySpellID then
            for _, seal in ipairs(SEAL_ORDER) do
                local id = spellIDByName[seal.name]
                if id == nil then
                    id = F:ResolveSpellID(seal.name) or false
                    spellIDByName[seal.name] = id
                end
                if id then
                    local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, id)
                    if ok and type(aura) == "table" then
                        value = seal.value
                        break
                    end
                end
            end
        end

        -- 圣印剩余（338 格）：本地计时为主，脱战读到真实 expirationTime 时用它校正
        local sealAura = CyberDeck.Auras and CyberDeck.Auras["圣印"]
        if sealAura and not UnitAffectingCombat("player") then
            local realExp = sealAuraFound and sealAuraFound.expirationTime
            if type(realExp) == "number" and realExp > 0 and not isSecret(realExp) then
                sealAura.expirationTime = realExp
                sealAura.remaining = math.max(0, realExp - now)
            elseif value == 0 then
                -- 脱战且一个圣印都读不到 = 真没了，别让本地计时继续挂着
                sealAura.expirationTime = nil
                sealAura.remaining = 0
                sealAura.sealValue = 0
            end
        end

        -- 战斗中都读不到时用施放计时的 sealValue 兜住；脱战读不到就是真到期
        if value == 0 and UnitAffectingCombat("player") then
            if sealAura and sealAura.expirationTime and now < sealAura.expirationTime then
                value = sealAura.sealValue or 0
            end
        end
        self:CreatTexture(st["圣印"], value / 255)
    end

    if st["神恩术"] then
        self:CreatTexture(st["神恩术"], remainingSeconds(buffs["神恩术"]) / 255)
    end

    if st["圣光灌注"] then
        local aura = buffs["圣光灌注"]
        local count = 0
        if type(aura) == "table" and type(aura.applications) == "number" and not isSecret(aura.applications) then
            count = aura.applications
        end
        self:CreatTexture(st["圣光灌注"], count / 255)
    end

    if st["正义之怒"] then
        -- 常驻 buff：0 = 没有，>0 = 有；同样只判存在性，避免永久 buff 被误判成“没有”
        self:CreatTexture(st["正义之怒"], stillThere("正义之怒") and 1 or 0)
    end

end

-- ================================================================
--                       自动攻击状态（近战平砍）
-- ================================================================
-- 无限服没有 START_AUTO_ATTACK / STOP_AUTO_ATTACK，只有 PLAYER_ENTER_COMBAT /
-- PLAYER_LEAVE_COMBAT；远程自动射击走 START_AUTOREPEAT_SPELL，与近战无关。
-- /reload 时正在砍怪不会补发事件，需重新攻击一次才识别得到。
F.autoAttackOn = false

function F:PLAYER_ENTER_COMBAT()
    F.autoAttackOn = true
end

function F:PLAYER_LEAVE_COMBAT()
    F.autoAttackOn = false
end

function F:UpdateForeverAutoAttack()
    local index = self.blocks and self.blocks.state and self.blocks.state["自动攻击"]
    if not index then return end
    -- 死亡/幽灵兜底：客户端不会再发 LEAVE_COMBAT
    if UnitIsDeadOrGhost("player") then
        F.autoAttackOn = false
    end
    self:CreatTexture(index, (F.autoAttackOn and 1 or 0) / 255)
end


-- ================================================================
--                       调试输出 /cy spec
-- ================================================================
function F:PrintSpecDebug()
    print("|cff00ff00[Cyber Deck]|r 接口版本:", tostring(self.tocVersion), "无限服:", tostring(self.isForever))
    print("专精:", tostring(self.state.specIndex), tostring(self.state.specName), tostring(self.state.specRole),
        "射程", tostring(self.state.specRange))
    local p = specCache.points or {}
    print("天赋点数 1/2/3:", tostring(p[1] or 0), tostring(p[2] or 0), tostring(p[3] or 0),
        "来源:", tostring(specCache.pointsSource))
    local po = specCache.pointsByOrder
    if po then
        print("按 treeIDs 顺序归类:", tostring(po[1] or 0), tostring(po[2] or 0), tostring(po[3] or 0))
    end
    for _, t in ipairs(specCache.trees or {}) do
        print(("  树[%d] id=%s name=%s points=%s"):format(t.idx, tostring(t.id), tostring(t.name),
            tostring(t.points)))
    end
    local sp = specCache.skillProbe
    if sp then
        local st = specCache.skillsProbeStatus or {}
        -- 三个招牌技能各锁一系：神圣之盾=防护 / 神圣震击=神圣 / 忏悔=惩戒
        print(("专属技能探测: 神圣之盾=%s 神圣震击=%s 忏悔=%s"):format(
            tostring(sp["神圣之盾"]), tostring(sp["神圣震击"]), tostring(sp["忏悔"])))
        print(("  状态: 神圣之盾[%s] 神圣震击[%s] 忏悔[%s]"):format(
            tostring(st["神圣之盾"]), tostring(st["神圣震击"]), tostring(st["忏悔"])))
    end

    local pn = specCache.probeNode
    print("专精天赋探测:", pn and (tostring(pn.name) .. " -> 第 " .. tostring(pn.index) .. " 系")
        or "无（等级不足 10 或未分配前置点数）")
    print("离线技能表:", tostring(specCache.dataSpells or 0), "个技能名（不含天赋技能）")

    -- 玩家当前增益：排查圣印/光环名是否和客户端一致（名字对不上就会一直重复补）
    local buffs = scanAuras("player", "HELPFUL", 40)
    local buffNames = {}
    for name in pairs(buffs) do
        buffNames[#buffNames + 1] = name
    end
    table.sort(buffNames)
    print("玩家增益:", table.concat(buffNames, ", "))

    -- 圣印计时状态：expirationTime 是数字 = 记上了，nil = 没记上
    local sa = CyberDeck.Auras and CyberDeck.Auras["圣印"]
    if sa then
        print(("圣印计时: 编号=%s 到期=%s 剩余=%.1fs 战斗中=%s"):format(
            tostring(sa.sealValue), tostring(sa.expirationTime), sa.remaining or 0,
            tostring(UnitAffectingCombat("player"))))
    else
        print("圣印计时: 无 CyberDeck.Auras[\"圣印\"] 条目")
    end

    -- 目标减益：核对“目标审判”debuff 真名（名字对不上时 27 号像素会一直是 0）
    local tdebuffs = scanAuras("target", "HARMFUL|PLAYER", 30)
    local tNames = {}
    for name in pairs(tdebuffs) do
        tNames[#tNames + 1] = name
    end
    table.sort(tNames)
    print("目标减益:", #tNames > 0 and table.concat(tNames, ", ") or "（无）")

    -- 法术书全部技能名：对照无限服真实技能，清理 blocks 里不存在的正式服技能
    if not spellBookBuilt then
        self:RebuildSpellBookIndex()
    end
    local book = {}
    for name in pairs(spellNameToID) do
        book[#book + 1] = name
    end
    table.sort(book)
    print(("法术书 %d 个: %s"):format(#book, table.concat(book, ", ")))

    if self.blocks and self.blocks.spells then
        local list = {}
        for id, info in pairs(self.blocks.spells) do
            list[#list + 1] = { id = id, index = info.index or info.charge or 0, name = info.name or "?" }
        end
        table.sort(list, function(a, b) return a.index < b.index end)
        for _, v in ipairs(list) do
            print(("  [%d] %s -> %s"):format(v.index, v.name, tostring(v.id)))
        end
    end
end

-- ================================================================
--                     光环实例 API 兼容
-- ================================================================
-- C_UnitAuras.GetUnitAuraInstanceIDs 在无限服上若不存在，退回逐条扫描
function F:GetAuraInstanceIDs(unit, filter, maxCount, sortRule)
    -- 签名：GetUnitAuraInstanceIDs(unit, filter [, maxCount, sortRule, sortDirection])，
    -- 第 4 个参数是 sortRule 枚举，不是 includeNameplateIndex，传错会报 bad argument #4。
    -- 受限时返回 nil（读不到），空表才是「确实没有减益」——两者必须区分。
    if C_UnitAuras.GetUnitAuraInstanceIDs then
        local ok, ids
        if sortRule ~= nil then
            -- 正式服用法：GetUnitAuraInstanceIDs(unit, filter, maxCount, sortRule)
            ok, ids = pcall(C_UnitAuras.GetUnitAuraInstanceIDs, unit, filter, maxCount, sortRule)
        else
            ok, ids = pcall(C_UnitAuras.GetUnitAuraInstanceIDs, unit, filter, maxCount)
        end
        if ok and type(ids) == "table" then
            return ids
        end
        -- 抛错了 -> 记下来，最后返回 nil
        return nil
    end
    local ids = {}
    local harmful = type(filter) == "string" and filter:find("HARMFUL")
    local getter = harmful and C_UnitAuras.GetDebuffDataByIndex or C_UnitAuras.GetBuffDataByIndex
    if not getter then return ids end
    for i = 1, 40 do
        local ok, aura = pcall(getter, unit, i, filter)
        if not ok or type(aura) ~= "table" then break end
        if aura.auraInstanceID then
            ids[#ids + 1] = aura.auraInstanceID
        end
    end
    return ids
end

-- 签名与零售不同：零售 (unit, auraInstanceID, curve)，无限服 (auraInstanceID, curve)。
-- 按零售传会报 bad argument #3，颜色拿不到 -> 「目标类型」永远退回基线。两种都试。
function F:GetAuraDispelTypeColor(unit, auraInstanceID, curve)
    if not C_UnitAuras.GetAuraDispelTypeColor then return nil end
    local ok, color = pcall(C_UnitAuras.GetAuraDispelTypeColor, auraInstanceID, curve)
    if ok and color then return color end
    ok, color = pcall(C_UnitAuras.GetAuraDispelTypeColor, unit, auraInstanceID, curve)
    if ok and color then return color end
    return nil
end

-- ================================================================
--                       物品（药水/治疗石）
-- ================================================================
F.itemGroups = {
    HealthPotion = { 13446, 3928, 1710, 929, 118, 858 }, -- 极效/优质/强效/治疗/次级/次级治疗药水
    ManaPotion = { 13443, 3827, 3385, 2455, 3826 },      -- 极效/优质/强效/次级/次级法力药水
    Healthstone = { 5512, 19013 },                       -- 治疗石
    Recklessness = {},                                   -- 无限服无鲁莽药水
    LightsPotential = {},                                -- 无限服无圣光潜力
}

-- 像素块名 -> 物品分组
F.itemBlocks = {
    ["大红冷却"] = "HealthPotion",
    ["大蓝冷却"] = "ManaPotion",
    ["治疗石冷却"] = "Healthstone",
    ["鲁莽药水冷却"] = "Recklessness",
    ["圣光潜力冷却"] = "LightsPotential",
}

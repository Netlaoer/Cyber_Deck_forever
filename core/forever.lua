local addon, ns = ...
--[[
    core/forever.lua — 无限服(wowf, Interface 16001)适配层
    ------------------------------------------------------------------
    无限服与正式服的差异（已核实）：
    1. 客户端版本 1.60.1，TOC 版本号 16001；
    2. 技能是 60 级经典技能组，带 rank（同一技能多个 ID），正式服的技能 ID 大多不存在；
    3. 每个职业只有一个伪专精（圣骑士 1486），实际天赋树决定定位，
       所以专精索引要按“天赋树投入点数最多的一系”算，不能用 GetSpecialization()；
    4. 没有英雄天赋、没有一键辅助；
    5. 药水/物品 ID 是经典旧世的，不是正式服 2413xx。

    本文件提供（全部为无限服专用逻辑）：
    - CyberDeck.isForever  仅用于 /cy spec 调试输出，逻辑分支不再依赖它
    - F:ResolveSpellID(name)        名称 -> 已学会的 rank ID（扫法术书）
    - F:RebuildSpellBookIndex()     重建 名称->ID 索引
    - F:GetActiveSpecIndex()        按天赋树算专精索引 1..3
    - F:GetForeverSpecInfo(index)   专精 ID/名称/职责/射程
    - F:UpdateForeverAuras()        圣印/神恩术/圣光灌注 像素
    - F.itemGroups                  药水物品 ID 分组（两套客户端各一份）
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
-- 离线训练师表里的“名字 -> 最早能学到的 rank”。不管学没学会都记一份，
-- 用来区分“没学会”和“客户端根本没这个技能名”（天赋技能不在训练师表里，会落到后者）。
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

-- 用 ForeverDB 离线表（core/forever_data.lua）建“中文名 -> 已学会的最高 rank”
-- 表里只有 {学习等级, spellID} 事实数据；中文名由客户端 GetSpellInfo 提供，自动跟随语言
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

    -- 离线表覆盖：同名取“已学会的最高 rank”，比法术书遍历更准；
    -- 法术书先跑的好处是天赋技能（不在训练师表里）仍能进索引
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

-- 技能名状态：已学会 / 没学会（但训练师表里有）/ 表里也没有
-- 天赋技能（如 神圣震击、忏悔）不在训练师表里，探测不到时落到第三种，
-- 不能直接判定成“这个号没学这个技能”——有可能是天赋没点，也有可能是名字对不上。
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
    -- 以下 8 个职业是骨架阶段（像素块已配好，决策层未实现）。
    -- 专精名/职责/射程取经典 60 级的标准值，接决策层时用 /cy spec 实机核对。
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

-- 树名 -> 专精索引。无限服的 treeIDs 顺序不等于 1/2/3 系
-- （实测防护树排在第一位，会把防护 22 点算到神圣头上），必须按树名归类。
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

-- 专精探测节点：数据来自 ForeverDB Talents.lua（build 1.60.1.70862）
-- 这三个天赋各系独有、都要 10 点前置，同一套天赋不可能同时点亮，所以互斥且确定
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

    -- 3) 专精专属技能（无限服实测数据）：
    --    神圣之盾 = Holy Shield 20927，防护 训练师技能 Lv40
    --    神圣震击 = Holy Shock 1311606，神圣 天赋 Lv30（要点了天赋才进法术书）
    --    忏悔     = Repentance 9623，惩戒 天赋
    --    三者各锁一系（互斥来自"专精锁"，不是正式服那种点数上限互斥），查到就能直接定专精；
    --    查不到只说明这一系的招牌技能没学/没点，不能当成"不是这一系"。
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

    -- 无限服 C_Traits.GetConfigInfo 只返回 1 棵树（实测 id=1100），byOrder 会把全部点数堆在
    -- 第 1 位，显示成“22 0 0”会误以为点在神圣。有 traitNode 判定、又读不到经典三系点数时，
    -- 把总点数归到判定出的那一系，显示才和游戏内一致。
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

-- 常驻 buff 的“最后看到时间”：战斗中 buff 名偶尔读不到时不要立刻判成没有，
-- 否则决策层会每个节流周期重补一次，光环看起来一开一关
local lastSeenAt = {}
local spellIDByName = {}
local SEEN_GRACE = 1.5   -- 只兜住单帧读不到；再长就会让“buff 已经掉了”迟迟不回落

-- 施放成功后的“保底有效期”：战斗中 buff 名可能整个读不到，
-- 有了这个就不会把已经开好的光环/正义之怒当成没开，从而反复重开（一开一关）
local AURA_LOCK_SECONDS = {
    ["正义之怒"] = 1700,   -- 30 分钟 buff，留 100 秒余量
}
local auraLockUntil = {}
local auraSpellName = {}

-- 圣印持续 30 秒，锁 28 秒：战斗中读不到时靠它防刷屏，留 2 秒余量照常补
-- 圣印计时统一交给 core/auras.lua 的 CyberDeck.Auras["圣印"]：
-- 施放成功时由 MarkForeverAuraCast 写入 expirationTime + sealValue，
-- updateAura() 每帧算 remaining，到期自动清空。这里不再自己维护锁。

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
            -- 这里**不能**续 auraLockUntil：如果每 0.2 秒都续满一次，buff 真正到期时
            -- 锁还剩整整一个周期，像素会继续显示“有”，决策层就一直不补。
            -- 兜底只依赖 MarkForeverAuraCast 设的一次性锁 + 下面的 1.5 秒 grace。
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
        for _, seal in ipairs(SEAL_ORDER) do
            if buffs[seal.name] then
                value = seal.value
                break
            end
        end
        -- 战斗中 buff 名可能整段读不到（secret），按 spellID 复查一次。
        -- 不靠时间猜：进战斗瞬间若判成“没挂圣印”，决策层会立刻重放一次，
        -- 表现为“每次进战斗都重新上一次圣印”。
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
        -- 战斗中 buff 名/spellID 都读不到（secret），用 auras 的施放计时推算：
        -- 施放成功记 30 秒，到期由 updateAura() 自动清空，归 0 让决策层补。
        -- 战斗外读不到就是真到期了，直接归 0，不查计时（避免被驱散时误判）。
        if value == 0 and UnitAffectingCombat("player") then
            local sealAura = CyberDeck.Auras and CyberDeck.Auras["圣印"]
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
-- 无限服没有 START_AUTO_ATTACK / STOP_AUTO_ATTACK 事件，只有经典的两个：
--   PLAYER_ENTER_COMBAT  开始近战攻击
--   PLAYER_LEAVE_COMBAT  停止
-- EllesmereUIActionBars / SwingTimer 也是用这两个维护 meleeOn，可作参照。
-- 远程自动射击是 START_AUTOREPEAT_SPELL / STOP_AUTOREPEAT_SPELL，与近战无关。
--
-- 注意：/reload 时如果正在砍怪，事件不会补发，需要重新攻击一次才识别得到；
-- 死亡或脱战会复位（死亡自动停止攻击）。
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

    -- 圣印计时状态：验证"战斗中施放能不能记上 30 秒"。
    -- expirationTime 是数字 = 记上了；nil = 没记上（spellID 被保护 / 名字没解析出来）。
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
--                     光环可读性探测
-- ================================================================
-- 无限服的 secret 机制：战斗中某些光环字段读出来是不可比较的 secret 值。
-- 这个命令逐字段试读，告诉你 name / spellId / expirationTime / applications
-- 各自能不能用 —— 写奶骑这类"要盯队友 buff"的循环时，先跑一次确认依赖什么。
-- 用法：/cy auraprobe
function F:ProbeAuras()
    if not C_UnitAuras or not C_UnitAuras.GetBuffDataByIndex then
        print("|cffff0000[Cyber Deck]|r 当前客户端没有 C_UnitAuras.GetBuffDataByIndex")
        return
    end

    local inCombat = UnitAffectingCombat("player")
    print(("|cff00ff00[Cyber Deck]|r 光环可读性探测 %s"):format(
        inCombat and "|cffff0000[战斗中]|r" or "[脱战]"))

    -- 单字段试读：返回 (值, 状态)，状态 = ok / nil / SECRET / error
    local function probe(fn)
        local ok, v = pcall(fn)
        if not ok then return nil, "error" end
        if v == nil then return nil, "nil" end
        if type(issecretvalue) == "function" and issecretvalue(v) then
            return nil, "SECRET"
        end
        return v, "ok"
    end

    local units = { { "player", "player" } }
    for i = 1, 4 do
        local u = "party" .. i
        if UnitExists(u) then
            units[#units + 1] = { u, ("party%d %s"):format(i, tostring(UnitName(u) or "?")) }
        end
    end

    for _, entry in ipairs(units) do
        local unit, label = entry[1], entry[2]
        local total, okName, okSpell, okTime, okStack = 0, 0, 0, 0, 0
        local lines = {}
        for i = 1, 40 do
            local ok, aura = pcall(C_UnitAuras.GetBuffDataByIndex, unit, i, "HELPFUL")
            if not ok or type(aura) ~= "table" then break end
            total = total + 1
            local name, ns = probe(function() return aura.name end)
            local sid, ss = probe(function() return aura.spellId end)
            local exp, es = probe(function() return aura.expirationTime end)
            local cnt, cs = probe(function() return aura.applications end)
            if ns == "ok" then okName = okName + 1 end
            if ss == "ok" then okSpell = okSpell + 1 end
            if es == "ok" then okTime = okTime + 1 end
            if cs == "ok" then okStack = okStack + 1 end
            local remain = "-"
            if exp then
                local r = exp - GetTime()
                remain = (r > 0) and ("%.1f"):format(r) or "0"
            end
            lines[#lines + 1] = ("  %-16s spell=%-7s name=%-7s remain=%-6s stack=%s"):format(
                tostring(name or "?"), tostring(sid or "?"), ns, remain, tostring(cnt or "-"))
        end
        if total == 0 then
            print(("|cff00ff00[%s]|r 0 条（无增益或读不到）"):format(label))
        else
            print(("|cff00ff00[%s]|r %d 条  name %d/%d  spellId %d/%d  时间 %d/%d  层数 %d/%d"):format(
                label, total, okName, total, okSpell, total, okTime, total, okStack, total))
            for _, line in ipairs(lines) do print(line) end
        end
    end

    -- 队友减益：奶骑判断"谁需要驱散"靠这条通道
    for i = 1, 4 do
        local u = "party" .. i
        if UnitExists(u) then
            local n = 0
            for idx = 1, 20 do
                local ok, aura = pcall(C_UnitAuras.GetDebuffDataByIndex, u, idx, "HARMFUL|RAID")
                if not ok or type(aura) ~= "table" then break end
                n = n + 1
            end
            if n > 0 then
                print(("  party%d 减益条数（HARMFUL|RAID）= %d"):format(i, n))
            end
        end
    end

    -- 目标身上「我施加的 debuff」：审判/十字军印记这类全靠这条通道。
    -- HARMFUL|PLAYER 是"自己放的"专用 filter，secret 保护通常不覆盖它。
    if UnitExists("target") then
        local total, okName, okSpell, okTime = 0, 0, 0, 0
        local lines = {}
        for i = 1, 40 do
            local ok, aura = pcall(C_UnitAuras.GetDebuffDataByIndex, "target", i, "HARMFUL|PLAYER")
            if not ok or type(aura) ~= "table" then break end
            total = total + 1
            local name, ns = probe(function() return aura.name end)
            local sid, ss = probe(function() return aura.spellId end)
            local exp, es = probe(function() return aura.expirationTime end)
            if ns == "ok" then okName = okName + 1 end
            if ss == "ok" then okSpell = okSpell + 1 end
            if es == "ok" then okTime = okTime + 1 end
            local remain = "-"
            if exp then
                local r = exp - GetTime()
                remain = (r > 0) and ("%.1f"):format(r) or "0"
            end
            lines[#lines + 1] = ("  %-16s spell=%-7s name=%-7s remain=%s"):format(
                tostring(name or "?"), tostring(sid or "?"), ns, remain)
        end
        print(("|cff00ff00[target %s 我放的 debuff]|r %d 条  name %d/%d  spellId %d/%d  时间 %d/%d"):format(
            tostring(UnitName("target") or "?"), total, okName, total, okSpell, total, okTime, total))
        for _, line in ipairs(lines) do print(line) end
    end

end


-- ================================================================
--                     光环实例 API 兼容
-- ================================================================
-- C_UnitAuras.GetUnitAuraInstanceIDs 在无限服上若不存在，退回逐条扫描
function F:GetAuraInstanceIDs(unit, filter, maxCount)
    -- ⚠️ 客户端签名：GetUnitAuraInstanceIDs(unit, filter [, maxCount, sortRule, sortDirection])
    -- 第 4 个参数是 **sortRule（枚举）**，不是 includeNameplateIndex ——
    -- 传错会报 "bad argument #4 to '?'"。
    -- 这里只传前三个（maxCount），sortRule 用客户端默认值。
    --
    -- ⚠️ 受限（战斗中）时两条路都会抛
    --   "Auras cannot be accessed when secret while tainted by '<addon>'"
    -- 这时返回 **nil**（不是空表）—— 区分「读不到」和「确实没有减益」：
    --   空表 = 真的没有减益 -> 可以安全地不驱散
    --   nil  = 读不到（可能受限）-> 要降级到 AuraContainer 或盲驱
    if C_UnitAuras.GetUnitAuraInstanceIDs then
        local ok, ids = pcall(C_UnitAuras.GetUnitAuraInstanceIDs, unit, filter, maxCount)
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

function F:GetAuraDispelTypeColor(unit, auraInstanceID, curve)
    if C_UnitAuras.GetAuraDispelTypeColor then
        local ok, color = pcall(C_UnitAuras.GetAuraDispelTypeColor, unit, auraInstanceID, curve)
        if ok then return color end
    end
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

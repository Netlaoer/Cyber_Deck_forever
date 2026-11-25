local addon, ns = ...
local format = string.format

-- 队伍上限 40 人：键位总数 = 7 组修饰 × 46 键 = 322；每个动态技能占「人数」个键位，
-- 剩下的给静态技能（圣骑士 7×40 + 34 = 314）。超出会在 CreateMacro 里报错，不会静默少建。
CyberDeck.GROUP_TARGET_LIMIT = CyberDeck.GROUP_TARGET_LIMIT or 40

local macroList = {}
local macroKind = {}
local modifiers = {
    "CTRL", "ALT", "SHIFT",
    "ALT-CTRL", "ALT-SHIFT", "CTRL-SHIFT",
    "ALT-CTRL-SHIFT"
}

local keys = {
    "NUMPAD1", "NUMPAD2", "NUMPAD3", "NUMPAD4", "NUMPAD5",
    "NUMPAD6", "NUMPAD7", "NUMPAD8", "NUMPAD9", "NUMPAD0",
    "NUMPADDECIMAL", "NUMPADPLUS", "NUMPADMINUS", "NUMPADMULTIPLY", "NUMPADDIVIDE",
    "F1", "F2", "F3", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
    ",", ".", "/", ";", "'", "[", "]", "\\",
    "7", "8", "9", "0", "=",
    -- 追加 7 个主键：40 人需要 7×40=280 个动态位，原来 39 键 ×7=273 放不下
    "INSERT", "HOME", "END", "PAGEUP", "PAGEDOWN", "UP", "DOWN"
}

do
    local i = 1
    for _, m in ipairs(modifiers) do
        for _, k in ipairs(keys) do
            macroKind[i] = m .. "-" .. k
            i = i + 1
        end
    end
end

-- 键位总数（7 × 46 = 322）：告警文案和人数上限都用它，别再写死数字
CyberDeck.GROUP_KEY_SLOTS = #macroKind


local function createMacro(name, key, macro)
    if InCombatLockdown() then
        -- print("|cFFFF0000错误：战斗中不能创建按钮|r")
        return
    end
    local btn = macroList[name]
    if not btn then
        btn = CreateFrame("Button", name, UIParent, "SecureActionButtonTemplate")
        btn:SetAttribute("type", "macro")
        btn:RegisterForClicks("AnyUp", "AnyDown")
        macroList[name] = btn
        SetOverrideBindingClick(UIParent, false, key, name, "LeftButton")
    end
    btn:SetAttribute("macrotext", macro)
    -- print(name, key, macro)
end

function CyberDeck:CreateMacro(dynamicData, staticData, specialData)
    dynamicData = dynamicData or {}
    staticData = staticData or {}
    specialData = specialData or {}

    local unitLimit = CyberDeck.GROUP_TARGET_LIMIT
    local dynamicSlots = #dynamicData * unitLimit

    -- 宏位不够就明确报错，绝不静默少建（少建 = 某些队友永远没反应）
    local maxStatic = 0
    for k in pairs(staticData) do
        if type(k) == "number" and k > maxStatic then maxStatic = k end
    end
    for k in pairs(specialData) do
        if type(k) == "number" and k > maxStatic then maxStatic = k end
    end
    local needed = dynamicSlots + maxStatic
    if needed > #macroKind then
        CyberDeck:Print(("|cffff0000宏位不足|r：需要 %d 个（动态 %d + 静态 %d），只有 %d 个；"
            .. "末尾技能或靠后的队友不会被创建。")
            :format(needed, dynamicSlots, maxStatic, #macroKind))
    end

    for i = 1, #macroKind do
        local keyBinding = macroKind[i]
        local macroBody
        if i <= dynamicSlots then
            local groupIndex = math.floor((i - 1) / unitLimit) + 1
            local spell = dynamicData[groupIndex]

            if spell then
                local raidIdx = ((i - 1) % unitLimit) + 1
                if raidIdx == 1 then
                    -- 无限服是 1.12 核心（GetBuildInfo 返回 1.60.1 / 16001），
                    -- [nogroup] 是 5.0.4 才引入的条件，这里不认，会整段失效。
                    -- 改用无组队条件的 [@player] 作兜底：团队/小队先匹配，其余落到自己。
                    macroBody = format("/cast [group:raid,@raid1]%s;[group:party,@player]%s;[@player]%s", spell,
                        spell,
                        spell)
                elseif raidIdx <= 5 then
                    macroBody = format("/cast [group:raid,@raid%d]%s;[group:party,@party%d]%s", raidIdx, spell,
                        raidIdx - 1, spell)
                else
                    macroBody = format("/cast [group:raid,@raid%d]%s", raidIdx, spell)
                end
            end
        else
            local index = i - dynamicSlots
            macroBody = specialData[index]
            if not macroBody then
                local spell = staticData[index]
                if spell then
                    macroBody = "/cast " .. spell
                end
            end
        end
        if macroBody then
            createMacro("s" .. i, keyBinding, macroBody)
        end
    end
end

-- ================================================================
--  诊断：/cy macro  看宏按钮到底建出来没有
-- ================================================================
function CyberDeck:PrintMacroDebug()
    if InCombatLockdown() then
        self:Print("|cffff0000战斗中无法诊断（宏也建不出来），请脱战后再说|r")
        return
    end
    local count = 0
    for _ in pairs(macroList) do count = count + 1 end

    local limit = CyberDeck.GROUP_TARGET_LIMIT or 40
    local m = self.MacrosList or {}
    local dynamic = m.dynamicSpells or {}
    local dynSlots = #dynamic * limit
    self:Print(("宏按钮: |cff00ff00%d|r 个 | 键位 %d | 动态 %d 技能 x %d 人 = %d 槽 | 静态从 %d 起")
        :format(count, #macroKind, #dynamic, limit, dynSlots, dynSlots + 1))
    if count == 0 then
        self:Print("|cffff0000一个都没建|r —— 载入时应该在战斗中，脱战后 /reload 一次")
        return
    end

    -- 探针下标按当前布局推算（写死下标一改宏表就指向别的技能），并直接打印宏体
    local probes = {
        { 1, "动态1 unit1" },
        { limit, "动态1 unit" .. limit },
        { dynSlots, "末组动态 unit" .. limit },
        { dynSlots + 1, "静态槽 1" },
    }
    for _, item in ipairs(probes) do
        local idx = item[1]
        if macroKind[idx] then
            local btn = macroList["s" .. idx]
            self:Print(("  s%-3d %-16s %s  键位=%s | 宏=%s"):format(
                idx, item[2],
                btn and "|cff00ff00已建|r" or "|cffff0000未建|r",
                tostring(macroKind[idx]),
                btn and (btn:GetAttribute("macrotext") or "") or ""))
        end
    end

    -- 最后一个真正建出来的槽（静态技能通常排在这里）
    for idx = #macroKind, 1, -1 do
        local btn = macroList["s" .. idx]
        if btn then
            self:Print(("  s%-3d %-16s %s  键位=%s | 宏=%s"):format(
                idx, "末尾槽", "|cff00ff00已建|r", tostring(macroKind[idx]),
                btn:GetAttribute("macrotext") or ""))
            break
        end
    end
end

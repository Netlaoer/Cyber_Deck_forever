local addon, ns = ...
local actionBars = CyberDeck.actionBars
local keymap = CyberDeck.keymap
local keybindings = {}

--- 从宏体里取第一个 /cast 的技能名（跳过 [group:raid,@raid5] 这类条件）
--- 本插件的宏形如：/cast [group:raid,@raid5]圣光术;[group:party,@party4]圣光术
local function MacroSpellName(body)
    if type(body) ~= "string" then return nil end
    local name = body:match("/cast%s+%[[^%]]*%]%s*([^;%s]+)")
    if name then return name end
    return body:match("/cast%s+([^;%[%s]+)")
end

--- 动作槽 -> (spellID, 兜底名字)
--- ⚠️ GetActionInfo 的第二个返回值：spell 类型是**法术 ID**，
---    macro 类型是**宏序号**（1~120）。以前直接把它当法术 ID 去查
---    C_Spell.GetSpellInfo，结果要么查到完全无关的法术（序号撞上真实 ID），
---    要么查不到被整条丢弃 —— 动作条上放宏的槽位全部记录错误。
local function ResolveActionSpell(actionType, id)
    if actionType == "spell" then
        return id
    end
    -- 宏：读宏体 -> 取技能名 -> 解析成本服已学会的 rank ID
    local ok, _, _, body = pcall(GetMacroInfo, id)
    if not ok then return nil end
    local spellName = MacroSpellName(body)
    if not spellName then return nil end
    local spellID = CyberDeck.ResolveSpellID and CyberDeck:ResolveSpellID(spellName)
    return spellID, spellName
end

local function ProcessActionSlot(slot)
    -- 1. 获取动作信息并进行卫语句检查
    local actionType, id = GetActionInfo(slot)
    if actionType ~= "macro" and actionType ~= "spell" then
        return
    end

    -- 2. 解析出真正的法术 ID（宏要过一遍宏体），再取法术信息
    local spellID, fallbackName = ResolveActionSpell(actionType, id)
    if not spellID then return end

    -- GetSpellInfo 在未知 ID / 受限上下文里可能抛错；
    -- 这个函数跑在 C_Timer 回调里，抛一次会打断整轮扫描，所以必须 pcall。
    local ok, spellinfo = pcall(C_Spell.GetSpellInfo, spellID)
    if not ok or type(spellinfo) ~= "table" then return end

    local name = spellinfo.name or fallbackName
    local icon = spellinfo.iconID or spellinfo.icon

    -- 3. 遍历动作条
    for _, bar in ipairs(actionBars) do
        -- 4. 检查槽位是否在当前动作条范围内
        if slot >= bar.startSlot and slot <= bar.endSlot then
            local slotInBar = slot - bar.startSlot + 1
            local command = bar.bindingPrefix .. slotInBar -- 构造绑定命令
            local key = GetBindingKey(command)             -- 获取绑定的按键
            -- 5. 检查是否有按键绑定
            if key then
                keybindings[spellID] = {
                    key = key,
                    slot = slot,
                    keycode = keymap[key],
                    icon = icon,
                    name = name,
                    actionType = actionType, -- "spell" 直接来自动作槽；"macro" 由宏体解析而来
                }
                -- 如果一个动作（如法术）只需要被记录一次，
                -- 找到绑定后就可以跳出动作条循环 (break)
                -- break
            end
        end
    end
end

-- 扫描按键
function CyberDeck:readKeybindings()
    -- 清理并重新扫描
    table.wipe(keybindings)
    C_Timer.After(0.5, function()
        for slot = 1, 180 do
            ProcessActionSlot(slot)
        end
    end)
    CyberDeck.keybindings = keybindings
end

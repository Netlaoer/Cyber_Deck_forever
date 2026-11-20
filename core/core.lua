local addon, ns = ...
local className, classFilename, classId = UnitClass("player")
CyberDeck = LibStub("AceAddon-3.0"):NewAddon("CyberDeck", "AceEvent-3.0", "AceConsole-3.0")
local AC = LibStub("AceConfig-3.0") -- AceConfig-3.0 是 Ace3 库中的一个模块，用于注册和管理配置选项
local ACD = LibStub("AceConfigDialog-3.0")

function CyberDeck:OnInitialize()
    -- 使用“默认”配置文件，而非特定角色的配置文件。
    -- https://www.wowace.com/projects/ace3/pages/api/ace-db-3-0
    self.db = LibStub("AceDB-3.0"):New("CyberDeckADB", self.defaults, true)
    -- 注册一个选项表，并将其添加到暴雪选项窗口中。
    -- https://www.wowace.com/projects/ace3/pages/api/ace-config-3-0
    AC:RegisterOptionsTable("CyberDeck_Options", self.options)
    self.optionsFrame = ACD:AddToBlizOptions("CyberDeck_Options", "Cyber Deck")
    -- 添加一个子选项表 —— 即我们的配置文件面板。
    local profiles = LibStub("AceDBOptions-3.0"):GetOptionsTable(self.db)
    AC:RegisterOptionsTable("CyberDeck_Profiles", profiles)
    ACD:AddToBlizOptions("CyberDeck_Profiles", "Profiles", "Cyber Deck")
    -- 注册斜杠命令
    self:RegisterChatCommand("cy", "SlashCommand")
    self:RegisterChatCommand("CyberDeck", "SlashCommand")

    self:GetCharacterInfo()
end

function CyberDeck:OnEnable()
    self:GetCharacterSpecInfo()
    self:updateSpellKnown()
    self:updatePlayerBlocks()
    self:readKeybindings()
    self:hookChatFrameEditBox()
    self:updateAuraIconByEnteringWorld()

    self:RegisterEvent("ZONE_CHANGED")
    self:RegisterEvent("ZONE_CHANGED_INDOORS")
    self:RegisterEvent("PLAYER_ENTERING_WORLD")
    self:RegisterEvent("PLAYER_TALENT_UPDATE")
    self:RegisterEvent("PLAYER_DEAD")
    self:RegisterEvent("PLAYER_ALIVE")
    self:RegisterEvent("PLAYER_UNGHOST")
    self:RegisterEvent("PLAYER_MOUNT_DISPLAY_CHANGED")
    self:RegisterEvent("PLAYER_REGEN_DISABLED")
    self:RegisterEvent("PLAYER_REGEN_ENABLED")
    self:RegisterEvent("PLAYER_ENTER_COMBAT")
    self:RegisterEvent("PLAYER_LEAVE_COMBAT")
    self:RegisterEvent("PLAYER_STARTED_MOVING")
    self:RegisterEvent("PLAYER_STOPPED_MOVING")
    self:RegisterEvent("UNIT_SPELLCAST_SENT")
    self:RegisterEvent("UNIT_SPELLCAST_START")
    self:RegisterEvent("UNIT_SPELLCAST_STOP")
    self:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
    self:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
    self:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    self:RegisterEvent("UNIT_SPELLCAST_FAILED")
    self:RegisterEvent("UNIT_POWER_UPDATE")
    self:RegisterEvent("UNIT_HEALTH")
    self:RegisterEvent("UNIT_MAXHEALTH")
    self:RegisterEvent("UNIT_HEAL_ABSORB_AMOUNT_CHANGED")
    self:RegisterEvent("UNIT_HEAL_PREDICTION")
    self:RegisterEvent("SPELL_UPDATE_USES")
    self:RegisterEvent("GROUP_ROSTER_UPDATE")
    self:RegisterEvent("UNIT_DIED")
    self:RegisterEvent("SPELL_RANGE_CHECK_UPDATE")
    self:RegisterEvent("ACTION_RANGE_CHECK_UPDATE")
    self:RegisterEvent("UI_ERROR_MESSAGE")
    self:RegisterEvent("PLAYER_TARGET_CHANGED")
    self:RegisterEvent("NAME_PLATE_UNIT_ADDED")
    self:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
    self:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
    self:RegisterEvent("UPDATE_SHAPESHIFT_FORMS")
    self:RegisterEvent("UNIT_AURA")
    self:RegisterEvent("SPELL_UPDATE_COOLDOWN")
    self:RegisterEvent("SPELL_UPDATE_ICON")
    self:RegisterEvent("COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED")
    self:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW")
    self:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE")
    self:RegisterEvent("SPELL_ACTIVATION_OVERLAY_SHOW")
    self:RegisterEvent("SPELL_ACTIVATION_OVERLAY_HIDE")
    self:RegisterEvent("UPDATE_BINDINGS")
    self:RegisterEvent("SPELLS_CHANGED")
    self:RegisterEvent("ACTIONBAR_HIDEGRID")
    self:RegisterEvent("ACTIONBAR_SHOWGRID")
    self:RegisterEvent("SPELL_UPDATE_CHARGES")
    if self.StartFrameUpdates then
        self:StartFrameUpdates()
    end
    if self.InitQuickToggleButton then
        self:InitQuickToggleButton()
    end
    self.Initialize = true
end

local function CharCfg()
    return CyberDeck.db and CyberDeck.db.char
end

local fuDelayEndTimer = nil

local function SaveConfig()
    local c = CharCfg()
    if not c then return end
    c.aoeMode = c.aoeMode or 0
    c.cooldowns = c.cooldowns or 0
    c.dpsMode = c.dpsMode or 0
    c.delay = c.delay or 0
    c.potion = c.potion or 0
end

--- 与斜杠 / 配置界面一致：print、同步顶部像素、规范化 db.char
function CyberDeck:SwitchCooldown()
    local c = self.db and self.db.char
    if not c then return end
    if c.cooldowns == 0 then
        print("|cff00ff00[Cyber Deck]|r 爆发已|cffff0000关闭|r") -- 修改"关闭"为红色
    else
        print("|cff00ff00[Cyber Deck]|r 爆发已|cff00ff00开启|r")
    end
    local st = self.blocks and self.blocks.state
    if st and st["爆发开关"] then
        self:CreatTexture(st["爆发开关"], (c.cooldowns or 0) / 255)
    end
    SaveConfig()
    if self.RefreshQuickToggleAppearance then
        self:RefreshQuickToggleAppearance()
    end
end

function CyberDeck:SwitchAoeMode()
    local c = self.db and self.db.char
    if not c then return end
    if c.aoeMode == 0 then
        print("|cff00ff00[Cyber Deck]|r 已切换|cff00ff00自动|r模式！")
    else
        print("|cff00ff00[Cyber Deck]|r 已切换|cff00ff00单体|r模式！")
    end
    local st = self.blocks and self.blocks.state
    if st and st["AOE开关"] then
        self:CreatTexture(st["AOE开关"], (c.aoeMode or 0) / 255)
    end
    SaveConfig()
    if self.RefreshQuickToggleAppearance then
        self:RefreshQuickToggleAppearance()
    end
end

function CyberDeck:SwitchDpsMode()
    local c = self.db and self.db.char
    if not c then return end
    if c.dpsMode == 0 then
        print("|cff00ff00[Cyber Deck]|r 输出模式已修改为|cff00ff00官方一键辅助|r") -- 修改"关闭"为红色
    else
        print("|cff00ff00[Cyber Deck]|r 输出模式已修改为|cff00ff00手动编写逻辑|r")
    end
    local st = self.blocks and self.blocks.state
    if st and st["输出模式"] then
        self:CreatTexture(st["输出模式"], (c.dpsMode or 0) / 255)
    end
    SaveConfig()
    if self.RefreshQuickToggleAppearance then
        self:RefreshQuickToggleAppearance()
    end
end

function CyberDeck:SwitchDelay()
    local c = self.db and self.db.char
    if not c then return end
    local st = self.blocks and self.blocks.state
    if st and st["延迟"] then
        self:CreatTexture(st["延迟"], (c.delay or 0) / 255)
    end
    SaveConfig()
end

function CyberDeck:SwitchPotion()
    local c = self.db and self.db.char
    if not c then return end
    if c.potion == 0 then
        print("|cff00ff00[Cyber Deck]|r 药水已|cffff0000关闭|r")
    else
        print("|cff00ff00[Cyber Deck]|r 药水已|cff00ff00开启|r")
    end
    local st = self.blocks and self.blocks.state
    if st and st["爆发药水开关"] then
        self:CreatTexture(st["爆发药水开关"], (c.potion or 0) / 255)
    end
    SaveConfig()
    if self.RefreshQuickToggleAppearance then
        self:RefreshQuickToggleAppearance()
    end
end

function CyberDeck:SwitchDispel()
    local c = self.db and self.db.char
    if not c then return end
    if c.dispel == 0 then
        print("|cff00ff00[Cyber Deck]|r 驱散已|cffff0000关闭|r")
    else
        print("|cff00ff00[Cyber Deck]|r 驱散已|cff00ff00开启|r")
    end
    if self.blocks and self.blocks.state and self.blocks.state["驱散开关"] then
        self:CreatTexture(self.blocks.state["驱散开关"], (c.dispel or 1) / 255)
    end
end

--- AceConsole：由 RegisterChatCommand("cy"|"CyberDeck", "SlashCommand") 分发，勿再手写 SlashCmdList
function CyberDeck:SlashCommand(input, editbox)
    input = (input or ""):trim()
    local command = string.lower(input)

    -- Ace 调试 / 选项（子命令优先于游戏逻辑同名）
    if command == "enable" then
        self:Enable()
        self:Print("Enabled.")
        return
    elseif command == "disable" then
        self:Disable()
        self:Print("Disabled.")
        return
    elseif command == "message" then
        print("this is our saved message:", self.db and self.db.profile and self.db.profile.someInput)
        return
    elseif command == "macro" then
        self:PrintMacroDebug()
        return
    elseif command == "options" or command == "config" then
        if self.optionsFrame and self.optionsFrame.name and Settings and Settings.OpenToCategory then
            pcall(Settings.OpenToCategory, self.optionsFrame.name)
        else
            self:Print("选项界面未就绪。")
        end
        return
    end

    -- 游戏内功能
    local c = self.db and self.db.char
    if command == "cd" then
        if not c then return end
        c.cooldowns = (c.cooldowns == 0) and 1 or 0
        self:SwitchCooldown()
    elseif command == "cd on" then
        if not c then return end
        c.cooldowns = 1
        self:SwitchCooldown()
    elseif command == "cd off" then
        if not c then return end
        c.cooldowns = 0
        self:SwitchCooldown()
    elseif command == "aoemode" then
        if not c then return end
        c.aoeMode = (c.aoeMode == 0) and 1 or 0
        self:SwitchAoeMode()
    elseif command == "aoemode auto" then
        if not c then return end
        c.aoeMode = 0
        self:SwitchAoeMode()
    elseif command == "aoemode aoe" then
        if not c then return end
        c.aoeMode = 1
        self:SwitchAoeMode()
    elseif command == "dpsmode" then
        if not c then return end
        c.dpsMode = (c.dpsMode == 0) and 1 or 0
        self:SwitchDpsMode()
    elseif command == "dpsmode manual" then
        if not c then return end
        c.dpsMode = 1
        self:SwitchDpsMode()
    elseif command == "dpsmode assistant" then
        if not c then return end
        c.dpsMode = 0
        self:SwitchDpsMode()
    elseif command == "potion" then
        if not c then return end
        c.potion = (c.potion == 0) and 1 or 0
        self:SwitchPotion()
    elseif command == "potion on" then
        if not c then return end
        c.potion = 1
        self:SwitchPotion()
    elseif command == "potion off" then
        if not c then return end
        c.potion = 0
        self:SwitchPotion()
    elseif command:match("^delay") then
        if not c then return end
        local secStr = command:match("^delay%s+(.+)$")
        local sec = 1
        if secStr then
            local trimmed = secStr:match("^%s*(.-)%s*$") or ""
            if trimmed ~= "" then
                local parsed = tonumber(trimmed)
                if parsed and parsed > 0 then
                    sec = parsed
                else
                    print("|cff00ff00[Cyber Deck]|r 无效秒数；请输入正数（例如 /cy delay 5），或不写秒数使用默认 1 秒。")
                    return
                end
            end
        end
        local delayAlreadyActive = fuDelayEndTimer ~= nil
        if fuDelayEndTimer then
            fuDelayEndTimer:Cancel()
            fuDelayEndTimer = nil
        end
        c.delay = 1
        self:SwitchDelay()
        fuDelayEndTimer = C_Timer.NewTimer(sec, function()
            fuDelayEndTimer = nil
            local cc = CyberDeck.db and CyberDeck.db.char
            if cc then
                cc.delay = 0
                self:Print("延迟已恢复。")
                self:SwitchDelay()
            end
        end)
        if not delayAlreadyActive then
            self:Print("延迟已生效，" .. sec .. " 秒后恢复。")
        end
    elseif command == "dispel" then
        if not c then return end
        c.dispel = (c.dispel == 0) and 1 or 0
        self:SwitchDispel()
    elseif command == "dispel on" then
        if not c then return end
        c.dispel = 1
        self:SwitchDispel()
    elseif command == "dispel off" then
        if not c then return end
        c.dispel = 0
        self:SwitchDispel()
    elseif command == "dispel blind" then
        if not c then return end
        c.blindDispel = (c.blindDispel == 1) and 0 or 1
        print(("  战斗中盲驱（读不到减益信息时也驱）：%s")
            :format(c.blindDispel == 1 and "|cffff0000开（可能空放）|r" or "|cff00ff00关（不空放）|r"))
    elseif command == "dispel blind on" then
        if not c then return end
        c.blindDispel = 1
        print("  战斗中盲驱：|cffff0000开（可能空放）|r")
    elseif command == "dispel blind off" then
        if not c then return end
        c.blindDispel = 0
        print("  战斗中盲驱：|cff00ff00关（不空放）|r")
    elseif command == "help" then
        print("|cff00ff00Cyber Deck|r 命令列表:")
        print("爆发开关: /cy cd")
        print("|cff00ff00开启|r爆发: /cy cd on")
        print("|cffff0000关闭|r爆发: /cy cd off")
        print("切换AOE模式: /cy aoemode")
        print("切换AOE为|cff00ff00自动|r: /cy aoemode auto")
        print("切换AOE为|cff00ff00单体|r: /cy aoemode aoe")
        print("切换输出模式: /cy dpsmode")
        print("切换输出模式为|cff00ff00手写逻辑|r: /cy dpsmode manual")
        print("切换输出模式为|cff00ff00一键辅助|r: /cy dpsmode assistant")
        print("爆发药水开关: /cy potion")
        print("|cff00ff00开启|r药水: /cy potion on")
        print("|cffff0000关闭|r药水: /cy potion off")
        print("驱散开关: /cy dispel")
        print("|cff00ff00开启|r驱散: /cy dispel on")
        print("|cffff0000关闭|r驱散: /cy dispel off")
        print("战斗中盲驱开关: /cy dispel blind")
        print("临时 delay 标志（db.char.delay 置 1 持续 x 秒后归零）: /cy delay [秒]，省略秒数则为 1 秒")
        print("界面设置(Ace): /cy options")
        print("查看专精/技能解析: /cy spec")
        print("探测光环字段可读性: /cy auraprobe")
        print("探测当前上下文的 secret 限制: /cy secrets")
        print("探测驱散能力/曲线点位: /cy dispelprobe")
        print("驱散链路逐环诊断: /cy dispelscan")
        print("驱散探测实验(一次性定性): /cy dispeltest")
        print("引擎染色驱散探针状态: /cy dispelpix")
        print("像素块调试界面: /cy gui")
        print("本命令列表: /cy help")
    elseif command == "spec" then
        if self.PrintSpecDebug then
            self:PrintSpecDebug()
        end
    elseif command == "auraprobe" or command == "ap" then
        -- 探测无限服的 secret 范围：哪些光环字段读得到、哪些是秘密值
        if self.ProbeAuras then
            self:ProbeAuras()
        end
    elseif command == "secrets" or command == "sec" then
        -- 探测当前上下文的 secret 限制：哪些类别的数据会变成 secret 值
        if self.PrintSecretContext then
            self:PrintSecretContext()
        end
    elseif command == "dispelprobe" or command == "dp" then
        -- 驱散失效排查：能力表里的法术 ID 是否对得上无限服、曲线点位是不是 0
        if self.PrintDispelDebug then
            self:PrintDispelDebug()
        end
    elseif command == "dispelscan" or command == "ds" then
        -- 驱散链路逐环诊断：战斗中/脱战各跑一次，对比输出
        if self.PrintDispelScan then
            self:PrintDispelScan()
        end
    elseif command == "dispelpix" or command == "dpx" then
        -- 引擎染色驱散探针：每个队友一格，引擎按 debuff 类型染色到色条上
        if self.PrintDispelProbe then
            self:PrintDispelProbe()
        end
    elseif command == "gui" then
        if self.OpenInfoGUI then
            self:OpenInfoGUI()
        end
    else
        if self.OpenInfoGUI then
            self:OpenInfoGUI()
        elseif self.optionsFrame and self.optionsFrame.name and Settings and Settings.OpenToCategory then
            pcall(Settings.OpenToCategory, self.optionsFrame.name)
        else
            self:Print("输入 /cy help 查看命令。")
        end
    end
end

function SetTestSecret(set)
    -- 无限服不一定有这些 CVar，逐个 pcall，避免加载期报错
    for _, cvar in ipairs({
        "secretChallengeModeRestrictionsForced",
        "secretCombatRestrictionsForced",
        "secretEncounterRestrictionsForced",
        "secretMapRestrictionsForced",
        "secretPvPMatchRestrictionsForced",
        "secretAuraDataRestrictionsForced",
        "scriptErrors",
        "doNotFlashLowHealthWarning",
    }) do
        pcall(SetCVar, cvar, set)
    end
end

-- /script SetTestSecret(0)
SetTestSecret(1)

function CyberDeck:IterateGroupMembers(reversed, forceParty)
    local unit = (not forceParty and IsInRaid()) and 'raid' or 'party'
    local numGroupMembers = unit == 'party' and GetNumSubgroupMembers() or GetNumGroupMembers()
    local i = reversed and numGroupMembers or (unit == 'party' and 0 or 1)
    return function()
        local ret
        if i == 0 and unit == 'party' then
            ret = 'player'
        elseif i <= numGroupMembers and i > 0 then
            ret = unit .. i
        end
        i = i + (reversed and -1 or 1)
        return ret
    end
end

function CyberDeck:creatColorCurve(point, b)
    local curve = C_CurveUtil.CreateColorCurve()
    curve:SetType(Enum.LuaCurveType.Linear)
    curve:AddPoint(0, CreateColor(0, 0, 0, 1))
    curve:AddPoint(point, CreateColor(0, 0, b / 255, 1))
    return curve
end

CyberDeck.state = {
    classId = classId,
    className = className,
    classFilename = classFilename,
}
CyberDeck.blocks = {}
CyberDeck.target = {}
CyberDeck.focus = {}
CyberDeck.nameplate = {}
CyberDeck.group = {}
CyberDeck.groupList = {}
CyberDeck.defaults = {
    profile = {
        someInput = "",
    },
    char = {
        level = 0,
        aoeMode = 0,
        cooldowns = 0,
        dpsMode = 0,
        delay = 0,
        potion = 0,
        dispel = 1,
        blindDispel = 0,      -- 战斗中读不到减益信息时是否盲驱（0=不空放，1=宁可空放也要驱）
        -- debuff spellID -> 驱散类型（1魔法 2诅咒 3疾病 4中毒），脱战时自动学习并累积
        dispelSpellTypes = {},
        quickButtonCX = 180,
        quickButtonCY = -100,
        quickButtonShow = true,
    },
}
CyberDeck.options = {
    type = "group",
    name = "Cyber Deck",
    args = {
        intro = {
            type = "description",
            name = "与 /cy 子命令配合；游戏内开关仍保存在「角色专用」变量 CyberDeckADB（db.char）。",
            fontSize = "medium",
            order = 0,
        },
        someInput = {
            type = "input",
            name = "示例文本",
            desc = "/cy message 会打印此项（profile）",
            order = 10,
            width = "full",
            get = function()
                return (CyberDeck.db and CyberDeck.db.profile and CyberDeck.db.profile.someInput) or ""
            end,
            set = function(_, v)
                if CyberDeck.db and CyberDeck.db.profile then
                    CyberDeck.db.profile.someInput = v or ""
                end
            end,
        },
    }
}

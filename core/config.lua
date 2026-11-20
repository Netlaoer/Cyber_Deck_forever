local addon, ns = ...

CyberDeck.e = {
    ["法术冷却"] = "SPELL_UPDATE_COOLDOWN", -- 冷却事件
    ["施法成功"] = "UNIT_SPELLCAST_SUCCEEDED", -- 成功事件
    ["图标改变"] = "SPELL_UPDATE_ICON", -- ICON事件
    ["法术覆盖"] = "COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED", -- 法术临时覆盖事件
    ["图标发光显示"] = "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW", -- 图标发光显示
    ["图标发光隐藏"] = "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE", -- 图标发光隐藏
    ["屏幕提示显示"] = "SPELL_ACTIVATION_OVERLAY_SHOW", -- 屏幕提示显示
    ["屏幕提示隐藏"] = "SPELL_ACTIVATION_OVERLAY_HIDE", -- 屏幕提示隐藏
}
-- 英雄天赋

CyberDeck.EnumPowerType = {
    ["MANA"] = 0,
    ["RAGE"] = 1,
    ["FOCUS"] = 2,
    ["ENERGY"] = 3,
    ["COMBO_POINTS"] = 4,
    ["RUNES"] = 5,
    ["RUNIC_POWER"] = 6,
    ["SOUL_SHARDS"] = 7,
    ["LUNAR_POWER"] = 8,
    ["HOLY_POWER"] = 9,
    ["MAELSTROM"] = 11,
    ["CHI"] = 12,
    ["INSANITY"] = 13,
    ["BURNING_EMBERS"] = 14,
    ["DEMONIC_FURY"] = 15,
    ["ARCANE_CHARGES"] = 16,
    ["FURY"] = 17,
    ["PAIN"] = 17, -- 痛苦,原 18, 暂时由愤怒["FURY"]代替, 未知BUG
    ["ESSENCE"] = 19,
    ["SHADOW_ORBS"] = 28,
}
-- 专精范围
CyberDeck.actionBars = {
    { startSlot = 1,   endSlot = 12,  bindingPrefix = "ACTIONBUTTON" },
    { startSlot = 13,  endSlot = 24,  bindingPrefix = "ACTIONBUTTON" },
    { startSlot = 25,  endSlot = 36,  bindingPrefix = "MULTIACTIONBAR3BUTTON" },
    { startSlot = 37,  endSlot = 48,  bindingPrefix = "MULTIACTIONBAR4BUTTON" },
    { startSlot = 49,  endSlot = 60,  bindingPrefix = "MULTIACTIONBAR2BUTTON" },
    { startSlot = 61,  endSlot = 72,  bindingPrefix = "MULTIACTIONBAR1BUTTON" },
    { startSlot = 73,  endSlot = 84,  bindingPrefix = "ACTIONBUTTON" }, -- 战斗姿态, 猫形态, 潜行, 暗影
    { startSlot = 85,  endSlot = 96,  bindingPrefix = "ACTIONBUTTON" }, -- 防御姿态,
    { startSlot = 97,  endSlot = 108, bindingPrefix = "ACTIONBUTTON" }, -- 狂暴姿态, 熊形态
    { startSlot = 109, endSlot = 120, bindingPrefix = "ACTIONBUTTON" }, -- 枭兽形态
    { startSlot = 121, endSlot = 143, bindingPrefix = "ACTIONBUTTON" },
    { startSlot = 145, endSlot = 156, bindingPrefix = "MULTIACTIONBAR5BUTTON" },
    { startSlot = 157, endSlot = 168, bindingPrefix = "MULTIACTIONBAR6BUTTON" },
    { startSlot = 169, endSlot = 180, bindingPrefix = "MULTIACTIONBAR7BUTTON" }
}
-- 按键映射
CyberDeck.keymap = {
    ["1"] = 49,
    ["2"] = 50,
    ["3"] = 51,
    ["4"] = 52,
    ["5"] = 53,
    ["6"] = 54,
    ["7"] = 55,
    ["8"] = 56,
    ["9"] = 57,
    ["0"] = 48,

    ["F1"] = 112,
    ["F2"] = 113,
    ["F3"] = 114,
    ["F4"] = 115,
    ["F5"] = 116,
    ["F6"] = 117,
    ["F7"] = 118,
    ["F8"] = 119,
    ["F9"] = 120,
    ["F10"] = 121,
    ["F11"] = 122,
    ["F12"] = 123,

    ["Q"] = 81,
    ["W"] = 87,
    ["E"] = 69,
    ["R"] = 82,
    ["T"] = 84,
    ["Y"] = 89,
    ["U"] = 85,
    ["I"] = 73,
    ["O"] = 79,
    ["P"] = 80,
    ["A"] = 65,
    ["S"] = 83,
    ["D"] = 68,
    ["F"] = 70,
    ["G"] = 71,
    ["H"] = 72,
    ["J"] = 74,
    ["K"] = 75,
    ["L"] = 76,
    ["Z"] = 90,
    ["X"] = 88,
    ["C"] = 67,
    ["V"] = 86,
    ["B"] = 66,
    ["N"] = 78,
    ["M"] = 77,

    ["NUMPAD0"] = 96,
    ["NUMPAD1"] = 97,
    ["NUMPAD2"] = 98,
    ["NUMPAD3"] = 99,
    ["NUMPAD4"] = 100,
    ["NUMPAD5"] = 101,
    ["NUMPAD6"] = 102,
    ["NUMPAD7"] = 103,
    ["NUMPAD8"] = 104,
    ["NUMPAD9"] = 105,
    ["NUMPADMULTIPLY"] = 106,
    ["NUMPADPLUS"] = 107,
    ["NUMPADMINUS"] = 109,
    ["NUMPADDECIMAL"] = 110,
    ["NUMPADDIVIDE"] = 111,

    ["N0"] = 96,  -- 0x60
    ["N1"] = 97,  -- 0x61
    ["N2"] = 98,  -- 0x62
    ["N3"] = 99,  -- 0x63
    ["N4"] = 100, -- 0x64
    ["N5"] = 101, -- 0x65
    ["N6"] = 102, -- 0x66
    ["N7"] = 103, -- 0x67
    ["N8"] = 104, -- 0x68
    ["N9"] = 105, -- 0x69
    ["N*"] = 106, -- 0x6A
    ["N+"] = 107, -- 0x6B
    ["N-"] = 109, -- 0x6D
    ["N."] = 110, -- 0x6E
    ["N/"] = 111, -- 0x6F

    ["SPACE"] = 32,
    ["="] = 187,
    ["EQUALS"] = 187, -- WoW可能返回EQUALS而不是=
    ["-"] = 189,
    ["MINUS"] = 189,  -- WoW可能返回MINUS而不是-
    ["["] = 219,
    ["]"] = 221,
    ["\\"] = 220,
    [";"] = 186,
    ["SEMICOLON"] = 186, -- WoW可能返回SEMICOLON而不是;
    ["'"] = 222,
    [","] = 188,
    ["COMMA"] = 188,  -- WoW可能返回COMMA而不是,
    ["."] = 190,
    ["PERIOD"] = 190, -- WoW可能返回PERIOD而不是.
    ["/"] = 191,
}
-- 角色类型映射
CyberDeck.roleMap = {
    ["TANK"] = 1,
    ["HEALER"] = 2,
    ["DAMAGER"] = 3,
    ["NONE"] = 0,
}

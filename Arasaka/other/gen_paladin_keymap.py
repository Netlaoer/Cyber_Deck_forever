# -*- coding: utf-8 -*-
"""从 class/Paladin.lua 的 MacrosList 生成 Arasaka/keymap/paladin.yml。

宏位规则与 core/macro.lua 完全一致：
  macroKind = 7 组修饰键 x 39 个键 = 273 个
  前 #dynamic*30 个：第 g 个动态技能的第 n 个宏位 -> @raidN / @party(N-1)
  其余：第 j 个静态技能 -> macroKind[#dynamic*30 + j]

改了 Paladin.lua 的 MacrosList 后重新跑本脚本即可。

用法：python Arasaka/other/gen_paladin_keymap.py
"""

import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.abspath(os.path.join(HERE, "..", ".."))
LUA_PATH = os.path.join(ADDON, "class", "Paladin.lua")
OUT_PATH = os.path.join(ADDON, "Arasaka", "keymap", "paladin.yml")

MODIFIERS = ["CTRL", "ALT", "SHIFT", "ALT-CTRL", "ALT-SHIFT", "CTRL-SHIFT", "ALT-CTRL-SHIFT"]
KEYS = [
    "NUMPAD1", "NUMPAD2", "NUMPAD3", "NUMPAD4", "NUMPAD5",
    "NUMPAD6", "NUMPAD7", "NUMPAD8", "NUMPAD9", "NUMPAD0",
    "NUMPADDECIMAL", "NUMPADPLUS", "NUMPADMINUS", "NUMPADMULTIPLY", "NUMPADDIVIDE",
    "F1", "F2", "F3", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
    ",", ".", "/", ";", "'", "[", "]", "\\", "7", "8", "9", "0", "=",
]
MACRO_KIND = [m + "-" + k for m in MODIFIERS for k in KEYS]


def _parse_lua_list(block):
    return re.findall(r'"([^"]*)"', block)


# specialSpells 是完整宏体，名字从宏命令推导后再套中文别名
SPECIAL_ALIAS = {
    "startattack": "开始攻击",
}


def read_macros():
    with open(LUA_PATH, "r", encoding="utf-8") as f:
        src = f.read()
    m = re.search(r"dynamicSpells\s*=\s*\{([^}]*)\}", src)
    if not m:
        raise SystemExit("Paladin.lua 里找不到 dynamicSpells")
    dynamic = _parse_lua_list(m.group(1))

    m = re.search(r"staticSpells\s*=\s*\{([^}]*)\}", src, re.S)
    if not m:
        raise SystemExit("Paladin.lua 里找不到 staticSpells")
    static = _parse_lua_list(m.group(1))

    # specialSpells: [索引] = "完整宏体"，与 staticSpells 同位置时优先。
    # 用非贪婪匹配到第一个 }：空表 specialSpells = {} 必须匹配为空，
    # 否则会一路吃到 staticSpells 的结尾，把静态技能全当成 special。
    m = re.search(r"specialSpells\s*=\s*\{(.*?)\}", src, re.S)
    special = {}
    if m:
        special = {int(k): v for k, v in
                   re.findall(r'\[(\d+)\]\s*=\s*"([^"]*)"', m.group(1))}
    return dynamic, static, special


def special_name(body):
    """从 /startattack [harm,nodead] 推导 keymap 里显示的技能名。"""
    m = re.match(r"/(\w+)", body.strip())
    cmd = m.group(1) if m else body.strip()
    return SPECIAL_ALIAS.get(cmd, cmd)


def strip_prefix(entry):
    """去掉 [@mouseover] / [@player] 前缀，取技能名。

    以 / 开头的是完整宏体（如 "/startattack [harm,nodead]"），按宏命令推导名字。
    """
    name = re.sub(r"^\[[^\]]*\]", "", entry)
    if name.startswith("/"):
        return special_name(name)
    return name


def yaml_quote(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    dynamic, static, special = read_macros()
    slot_count = max([len(static)] + list(special.keys()))
    total = len(dynamic) * 30 + slot_count
    print(f"动态 {len(dynamic)} 个 x30 + 静态槽 {slot_count} 个（special {len(special)}）= {total} / {len(MACRO_KIND)} 宏位")
    if total > len(MACRO_KIND):
        raise SystemExit("宏位不足：减少 dynamicSpells 或 staticSpells")

    lines = [
        "# 由 Arasaka/other/gen_paladin_keymap.py 生成，勿手改；改 class/Paladin.lua 后重跑。",
        "# 宏位与 core/macro.lua 的 macroKind 顺序一致（修饰键 x 键位）。",
        "# 前 %d 个是动态技能（unit 1-30 = @raidN / @partyN-1），后面是静态技能（unit 0）。" % (len(dynamic) * 30),
        "",
    ]
    idx = 1
    for g, spell in enumerate(dynamic, start=1):
        for raid_idx in range(1, 31):
            lines.append(
                "%d: {unit: %d, 技能: %s, 热键: %s}"
                % (idx, raid_idx, yaml_quote(spell), yaml_quote(MACRO_KIND[idx - 1]))
            )
            idx += 1
    for slot in range(1, slot_count + 1):
        if slot in special:
            name = special_name(special[slot])
        elif slot <= len(static):
            name = strip_prefix(static[slot - 1])
        else:
            continue
        lines.append(
            "%d: {unit: 0, 技能: %s, 热键: %s}"
            % (idx, yaml_quote(name), yaml_quote(MACRO_KIND[idx - 1]))
        )
        idx += 1

    with open(OUT_PATH, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print(f"已写入 {OUT_PATH}（{idx - 1} 条）")


if __name__ == "__main__":
    main()

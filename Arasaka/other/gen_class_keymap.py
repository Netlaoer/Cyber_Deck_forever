# -*- coding: utf-8 -*-
"""
从 class/<Class>.lua 的 MacrosList 生成 Arasaka/keymap/<class>.yml。

宏位规则与 core/macro.lua 完全一致：
  macroKind = 7 组修饰键 x 39 个键 = 273 个
  前 #dynamic*30 个：第 g 个动态技能的第 n 个宏位 -> @raidN / @party(N-1)
  其余：第 j 个静态技能 -> macroKind[#dynamic*30 + j]

用法：
    python Arasaka/other/gen_class_keymap.py              # 生成全部职业
    python Arasaka/other/gen_class_keymap.py Warrior      # 只生成一个
    python Arasaka/other/gen_class_keymap.py Paladin      # 圣骑士（保持原样）
"""

import io
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.abspath(os.path.join(HERE, "..", ".."))

MODIFIERS = ["CTRL", "ALT", "SHIFT", "ALT-CTRL", "ALT-SHIFT", "CTRL-SHIFT", "ALT-CTRL-SHIFT"]
KEYS = [
    "NUMPAD1", "NUMPAD2", "NUMPAD3", "NUMPAD4", "NUMPAD5",
    "NUMPAD6", "NUMPAD7", "NUMPAD8", "NUMPAD9", "NUMPAD0",
    "NUMPADDECIMAL", "NUMPADPLUS", "NUMPADMINUS", "NUMPADMULTIPLY", "NUMPADDIVIDE",
    "F1", "F2", "F3", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
    ",", ".", "/", ";", "'", "[", "]", "\\", "7", "8", "9", "0", "=",
]
MACRO_KIND = [m + "-" + k for m in MODIFIERS for k in KEYS]

SPECIAL_ALIAS = {
    "startattack": "开始攻击",
}


def _parse_lua_list(block):
    return re.findall(r'"([^"]*)"', block)


def read_macros(lua_path):
    src = io.open(lua_path, encoding="utf-8").read()

    m = re.search(r"dynamicSpells\s*=\s*\{([^}]*)\}", src)
    dynamic = _parse_lua_list(m.group(1)) if m else []

    m = re.search(r"staticSpells\s*=\s*\{([^}]*)\}", src, re.S)
    static = _parse_lua_list(m.group(1)) if m else []

    # specialSpells: [索引] = "完整宏体"，与 staticSpells 同位置时优先
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


def build_rows(dynamic, static, special):
    """返回 [(unit, 技能名, 热键)]"""
    rows = []
    slot = 0
    # 动态技能：每个技能 30 个宏位（unit 1-30）
    for name in dynamic:
        for unit in range(1, 31):
            slot += 1
            if slot > len(MACRO_KIND):
                raise SystemExit("动态宏位超过上限（%d）：%d 个动态技能 × 30" % (len(MACRO_KIND), len(dynamic)))
            rows.append((unit, name, MACRO_KIND[slot - 1]))
    # 静态技能：unit 0
    static_map = {}
    for body in static:
        pass
    # 重新解析 staticSpells 保留索引（special 同位置优先）
    return rows, static, special


def gen_file(class_name, out_path):
    lua_path = os.path.join(ADDON, "class", class_name + ".lua")
    if not os.path.exists(lua_path):
        raise SystemExit("找不到 %s" % lua_path)
    src = io.open(lua_path, encoding="utf-8").read()

    m = re.search(r"dynamicSpells\s*=\s*\{([^}]*)\}", src)
    dynamic = _parse_lua_list(m.group(1)) if m else []
    m = re.search(r"staticSpells\s*=\s*\{(.*?)\n\}", src, re.S)
    if not m:
        m = re.search(r"staticSpells\s*=\s*\{([^}]*)\}", src, re.S)
    static_pairs = re.findall(r'\[(\d+)\]\s*=\s*"([^"]*)"', m.group(1)) if m else []
    m = re.search(r"specialSpells\s*=\s*\{(.*?)\}", src, re.S)
    special = {}
    if m:
        special = {int(k): v for k, v in
                   re.findall(r'\[(\d+)\]\s*=\s*"([^"]*)"', m.group(1))}

    rows = []
    slot = 0
    for name in dynamic:
        for unit in range(1, 31):
            slot += 1
            if slot > len(MACRO_KIND):
                raise SystemExit("宏位超过上限")
            rows.append((unit, name, MACRO_KIND[slot - 1]))

    # 静态部分：按**槽位号**遍历（special 与 static 同槽位时 special 优先）。
    # 注意 special 可能占一个 static 没有的槽（如 33），不能只遍历 static_pairs。
    static_map = {int(k): v for k, v in static_pairs}
    all_slots = sorted(set(static_map.keys()) | set(special.keys()))
    for idx in all_slots:
        if idx in special:
            nm = special_name(special[idx])
        else:
            body = static_map[idx]
            nm = body.lstrip("@")
            if nm.startswith("[") and "]" in nm:
                nm = nm[nm.index("]") + 1:]
        slot += 1
        if slot > len(MACRO_KIND):
            raise SystemExit("宏位超过上限")
        rows.append((0, nm, MACRO_KIND[slot - 1]))

    out = [
        "# 由 Arasaka/other/gen_class_keymap.py 生成，勿手改；改 class/%s.lua 后重跑。" % class_name,
        "# 宏位与 core/macro.lua 的 macroKind 顺序一致（修饰键 x 键位）。",
        "# 前 %d 个是动态技能（unit 1-30 = @raidN / @partyN-1），后面是静态技能（unit 0）。" % (len(dynamic) * 30),
        "",
    ]
    for i, (unit, name, key) in enumerate(rows, 1):
        # YAML 双引号字符串里反斜杠要转义，否则 "CTRL-\" 会被当成转义了引号
        key = key.replace("\\", "\\\\")
        out.append('%d: {unit: %d, 技能: "%s", 热键: "%s"}' % (i, unit, name, key))
    with io.open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out) + "\n")
    return len(dynamic), len(static_pairs), len(rows)


def main():
    args = sys.argv[1:]
    classes = args or ["Paladin", "Warrior", "Hunter", "Rogue", "Priest",
                       "Shaman", "Mage", "Warlock", "Druid"]
    for cn in classes:
        key = cn.lower()
        out = os.path.join(ADDON, "Arasaka", "keymap", "%s.yml" % key)
        try:
            nd, ns, nr = gen_file(cn, out)
            print("  %-10s -> keymap/%s.yml  动态 %d 静态 %d 共 %d 行" % (cn, key, nd, ns, nr))
        except SystemExit as e:
            print("  %-10s ★ %s" % (cn, e))
        except Exception as e:
            print("  %-10s ★ %s: %s" % (cn, type(e).__name__, e))


if __name__ == "__main__":
    main()

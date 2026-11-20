# -*- coding: utf-8 -*-
"""从 ForeverDB 生成 core/forever_data.lua（无限服技能离线表）。

流程（幂等，可重复执行）：
  1. 拉 https://foreverdb.net/downloads/addon-manifest.json
  2. 下载 Data/Spells.lua 并校验 manifest 里的 sha256 / bytes
  3. 按职业提取 {学习等级, spellID}，写成 Lua 表

只提取事实数据（等级门槛 + spellID），不复制描述文本。
来源必须署名：Data from ForeverDB.net（GPL-3.0 section 7(b)）。

用法：
    python Arasaka/other/gen_forever_spells.py
    python Arasaka/other/gen_forever_spells.py WARRIOR PALADIN
"""

import hashlib
import io
import json
import os
import re
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT_PATH = os.path.join(ADDON, "core", "forever_data.lua")

BASE = "https://foreverdb.net/"
MANIFEST = BASE + "downloads/addon-manifest.json"
UA = {"User-Agent": "Mozilla/5.0 (Cyber_Deck data generator)"}

DEFAULT_CLASSES = ["PALADIN"]

# Spells.lua 的字段：{level, name, rank, spell, races, faction, questTitle, questID, isClassic}
ROW_RE = r'\{(?P<level>\d+),"([^"]*)","([^"]*)",(?P<spell>\d+),"([^"]*)","([^"]*)","([^"]*)",(\d+),(\d+)\}'

HEADER = '''-- ================================================================
--  无限服技能离线表（core/forever_data.lua）
--  来源：ForeverDB.net (https://foreverdb.net)  build {build}
--  许可：GPL-3.0 + 署名条款 —— 再分发须保留本注释并注明
--        "Data from ForeverDB.net"（见其 NOTICE.txt）
--  内容：仅 {{level, spellID}} 事实数据，不含任何描述文本
--  用途：按等级从高到低取“已学会的最高 rank”，
--        与运行时扫法术书互为补充（天赋技能仍走法术书）
--  生成：Arasaka/other/gen_forever_spells.py（自动校验 sha256）
-- ================================================================
local addon, ns = ...

CyberDeck = CyberDeck or {{}}
CyberDeck.ForeverSpellData = {{
'''


def fetch(url, timeout=60):
    req = urllib.request.Request(url, headers=UA)
    return urllib.request.urlopen(req, timeout=timeout).read()


def get_spells_lua():
    manifest = json.loads(fetch(MANIFEST).decode("utf-8"))
    entry = None
    for f in manifest["data"]["files"]:
        if f["path"] == "Data/Spells.lua":
            entry = f
            break
    if not entry:
        raise SystemExit("manifest 里找不到 Data/Spells.lua")

    data = fetch(BASE + entry["url"])
    digest = hashlib.sha256(data).hexdigest()
    if digest != entry["sha256"] or len(data) != entry["bytes"]:
        raise SystemExit(
            "Spells.lua 校验失败：期望 %s/%d，实际 %s/%d"
            % (entry["sha256"][:16], entry["bytes"], digest[:16], len(data))
        )
    print("Spells.lua 校验通过  %d bytes  sha256 %s" % (len(data), digest[:16]))
    return data.decode("utf-8"), manifest.get("data", {}).get("version", "?"), entry


def extract(src, class_name):
    start = src.find(class_name + "=")
    if start < 0:
        raise SystemExit("Spells.lua 里找不到职业 " + class_name)
    # 用下一个职业键作为边界更稳
    nxt = len(src)
    for m in re.finditer(r",([A-Z]+)=\{\{", src[start:]):
        nxt = start + m.start()
        break
    rows = re.findall(ROW_RE, src[start:nxt])
    out = []
    for level, name, rank, sid, *_ in rows:
        out.append((int(level), int(sid), name, rank))
    return out


def main():
    classes = sys.argv[1:] or DEFAULT_CLASSES
    src, data_version, _entry = get_spells_lua()

    # build 号从 Meta.lua 读（是 Lua 不是 JSON，用正则）
    build = "1.60.1.70862"
    try:
        meta_txt = fetch(BASE + "downloads/addon-data/Meta.lua").decode("utf-8")
        m = re.search(r'build="([^"]+)"', meta_txt)
        if m:
            build = m.group(1)
    except Exception:
        pass

    parts = [HEADER.format(build=build)]
    total = 0
    for cls in classes:
        rows = extract(src, cls)
        total += len(rows)
        parts.append("    -- %s：%d 条训练师技能（等级 1-60）\n" % (cls, len(rows)))
        parts.append("    %s = {\n" % cls)
        line = "       "
        for level, sid, _name, _rank in rows:
            item = " {%d,%d}," % (level, sid)
            if len(line) + len(item) > 100:
                parts.append(line + "\n")
                line = "       "
            line += item
        if line.strip():
            parts.append(line + "\n")
        parts.append("    },\n")
    parts.append("}\n")

    with io.open(OUT_PATH, "w", encoding="utf-8", newline="\n") as f:
        f.write("".join(parts))
    print("已写入 %s（%d 条，数据版本 %s）" % (OUT_PATH, total, data_version))

    # 与本地客户端版本对比：服务器每次热修都会改客户端文件，离线表可能落后
    local_build = guess_local_client_build()
    if local_build and local_build != build:
        print("  ⚠️ 本地客户端是 %s，数据源是 %s —— 数据可能落后，建议在游戏里 /cy spec 核对" % (local_build, build))
    elif local_build:
        print("  ✓ 与本地客户端版本一致（%s）" % build)


def guess_local_client_build():
    """从常见安装目录找 Wow.exe，读取文件版本号（找不到返回 None）"""
    import glob
    for pat in (
        r"O:\World of Warcraft\_forever_\Wow.exe",
        r"C:\Program Files (x86)\World of Warcraft\_classic_\Wow.exe",
        r"C:\Program Files (x86)\World of Warcraft\_classic_beta_\Wow.exe",
    ):
        for path in glob.glob(pat):
            v = read_pe_version(path)
            if v:
                return v
    return None


def read_pe_version(path):
    """读 PE 的字符串版本信息（FileVersion），返回形如 1.60.1.70959。

    注意：不能用 VS_FIXEDFILEINFO 的二进制位 —— 无限服客户端那里是
    160.1.7095.9，和资源里的字符串版本 1.60.1.70959 不是一回事。
    """
    import ctypes
    import re
    try:
        size = ctypes.windll.version.GetFileVersionInfoSizeW(path, None)
        if not size:
            return None
        buf = ctypes.create_string_buffer(size)
        if not ctypes.windll.version.GetFileVersionInfoW(path, 0, size, buf):
            return None
        raw = bytes(buf)
        for key in ("FileVersion", "ProductVersion"):
            needle = key.encode("utf-16le")
            for m in re.finditer(re.escape(needle), raw):
                txt = raw[m.end():m.end() + 120].decode("utf-16le", "ignore")
                mm = re.search(r"(\d+(?:\.\d+)+)", txt)
                if mm:
                    return mm.group(1)
        return None
    except Exception:
        return None


if __name__ == "__main__":
    main()

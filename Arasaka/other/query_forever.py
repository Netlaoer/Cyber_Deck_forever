# -*- coding: utf-8 -*-
"""
无限服法术/物品查询工具（命令行）

用法：
    python Arasaka/other/query_forever.py 4987          # 查法术 4987
    python Arasaka/other/query_forever.py 4987 --json   # 输出原始 JSON
    python Arasaka/other/query_forever.py --search Cleanse   # 按名字搜
    python Arasaka/other/query_forever.py --build       # 看当前客户端 build
    python Arasaka/other/query_forever.py --file        # 从本地 Data/Spells.lua 查（无需网络）

数据源：
  1. 本地 ForeverDB 数据文件（已下载的 Data/Spells.lua）—— 离线，最快
  2. ForeverDB API api.foreverdb.net —— 需要 X-API-Key（免费 5000 次/天）
  3. wow-forever.gg 网页 —— 免 key，输出人类可读摘要

署名要求：数据来自 ForeverDB.net（GPL-3.0 section 7(b)），再分发须保留署名。
"""

import io
import json
import os
import re
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.abspath(os.path.join(HERE, "..", ".."))

API_BASE = "https://api.foreverdb.net/api/v1"
SITE_SPELL = "https://wow-forever.gg/db/spells/{id}"
UA = {"User-Agent": "Mozilla/5.0 (Cyber_Deck query tool)"}

# 环境变量放 key：FOREVERDB_API_KEY
KEY = os.environ.get("FOREVERDB_API_KEY", "")

# 本地已下载的 ForeverDB 数据（若有）
LOCAL_SPELLS = os.path.join(HERE, "Data", "Spells.lua")


def fetch(url, headers=None, timeout=30):
    req = urllib.request.Request(url, headers=headers or UA)
    return urllib.request.urlopen(req, timeout=timeout).read()


def api_get(path, params=None):
    """调用 ForeverDB API（需要 key）"""
    if not KEY:
        return None, "没有设置 FOREVERDB_API_KEY，跳过 API"
    url = API_BASE + path
    if params:
        url += "?" + "&".join("%s=%s" % (k, v) for k, v in params.items())
    h = dict(UA)
    h["X-API-Key"] = KEY
    try:
        data = json.loads(fetch(url, h).decode("utf-8"))
        return data.get("data"), None
    except Exception as e:
        return None, "API 调用失败：%s" % e


def api_search(kind, q, limit=10):
    return api_get("/%s" % kind, {"q": q, "limit": limit})


def site_spell(spell_id):
    """从 wow-forever.gg 抓单法术页，提取人类可读摘要"""
    url = SITE_SPELL.format(id=spell_id)
    try:
        html = fetch(url).decode("utf-8", "ignore")
    except Exception as e:
        return None, "网页抓取失败：%s" % e
    # 去掉标签，只留纯文本
    text = re.sub(r"<script.*?</script>", " ", html, flags=re.S | re.I)
    text = re.sub(r"<style.*?</style>", " ", text, flags=re.S | re.I)
    text = re.sub(r"<[^>]+>", " ", text)
    text = re.sub(r"&[a-z]+;", " ", text)
    text = re.sub(r"\s+", " ", text)
    # 抓关键片段
    out = []
    for pat in (
        r"[A-Z][A-Za-z '\-]+ is a [A-Za-z]+ ability[^.]*\.",
        r"learned at level \d+",
        r"removing[^.]*\.",
        r"Spell ID\s*\d+",
    ):
        m = re.search(pat, text)
        if m:
            out.append(m.group(0).strip())
    if not out:
        return None, "页面结构变了，抓不到摘要（可直接打开 %s）" % url
    return out, None


def local_spell(spell_id):
    """从本地 Data/Spells.lua 查（如果有这个文件）"""
    if not os.path.exists(LOCAL_SPELLS):
        return None
    try:
        src = io.open(LOCAL_SPELLS, encoding="utf-8").read()
    except Exception:
        return None
    # 行格式：{"level","name","rank","spell","races","faction","questTitle","questID","isClassic"}
    hits = []
    for m in re.finditer(r'\{(\d+),"([^"]*)","([^"]*)",(\d+),"([^"]*)","([^"]*)","([^"]*)",(\d+),(\d+)\}', src):
        if int(m.group(4)) == spell_id:
            hits.append({
                "level": int(m.group(1)),
                "name": m.group(2),
                "rank": m.group(3),
                "spellID": int(m.group(4)),
                "races": m.group(5),
                "faction": m.group(6),
            })
    return hits or None


def print_spell(spell_id, as_json=False):
    result = {"spellID": spell_id}

    local = local_spell(spell_id)
    if local:
        result["local"] = local

    api, err = api_get("/spells/%d" % spell_id)
    if api:
        result["api"] = api

    summary, err2 = site_spell(spell_id)
    if summary:
        result["site"] = summary

    if as_json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return

    print("=" * 66)
    print("spellID %d" % spell_id)
    print("=" * 66)
    if local:
        for h in local:
            print("  本地表  等级=%-4s 名称=%-24s rank=%-6s 种族=%-22s 阵营=%s"
                  % (h["level"], h["name"], h["rank"], h["races"], h["faction"]))
    else:
        print("  本地表  （无本地 Data/Spells.lua，跳过）")
    if api:
        for k in ("name", "level", "rank", "school", "castTime", "manaCost", "description"):
            if k in api:
                print("  API     %-12s %s" % (k + ":", str(api[k])[:90]))
    else:
        print("  API     （无 key 或调用失败）")
    if summary:
        for line in summary:
            print("  网页    %s" % line[:100])
    print()
    print("  详情页  %s" % SITE_SPELL.format(id=spell_id))


def print_search(q, kind="spells", limit=10):
    data, err = api_search(kind, q, limit)
    if data:
        print("API 搜索「%s」(%s)：" % (q, kind))
        items = data if isinstance(data, list) else data.get("items", data.get("results", []))
        for it in items[:limit]:
            print("  %-10s %s" % (it.get("id"), it.get("name")))
        return
    print("（无 API key，改用网页搜索入口）")
    print("  法术  https://wow-forever.gg/db/spells/?search=%s" % q)
    print("  物品  https://foreverdb.net/items?q=%s" % q)
    print("  申请 key: https://foreverdb.net/developers")


def print_build():
    try:
        sys.path.insert(0, HERE)
        import gen_forever_spells as g
        local = g.guess_local_client_build()
        print("本地客户端 build : %s" % (local or "未找到 Wow.exe"))
    except Exception as e:
        print("本地客户端 build : 读取失败（%s）" % e)
    meta = None
    try:
        txt = fetch("https://foreverdb.net/downloads/addon-data/Meta.lua").decode("utf-8")
        m = re.search(r'build="([^"]+)"', txt)
        meta = m.group(1) if m else None
    except Exception:
        pass
    print("ForeverDB 数据 build : %s" % (meta or "拉取失败"))


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return

    if args[0] == "--build":
        print_build()
        return
    if args[0] == "--search":
        q = args[1] if len(args) > 1 else ""
        kind = args[2] if len(args) > 2 else "spells"
        print_search(q, kind)
        return
    if args[0] == "--file":
        print("本地数据文件：%s（存在=%s）" % (LOCAL_SPELLS, os.path.exists(LOCAL_SPELLS)))
        return

    spell_id = int(args[0])
    print_spell(spell_id, as_json="--json" in args)


if __name__ == "__main__":
    main()

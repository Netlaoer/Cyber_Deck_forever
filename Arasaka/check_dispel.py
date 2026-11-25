# -*- coding: utf-8 -*-
"""驱散链路诊断（Python 侧）：用真实像素读一遍，看决策层到底拿到什么

用法（游戏里跑着插件，身上最好挂着 debuff）：
    D:/DevTools/pyenv-re313/Scripts/python.exe Arasaka/check_dispel.py

打印：
  1. 读到的 state_dict 关键字段（驱散开关 / group 各项 / 驱散技能的 CD）
  2. 决策层跑一遍的返回值（action_hotkey, current_step）
  3. 结论：卡在哪一环
"""
import io
import os
import sys

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _SCRIPT_DIR)
sys.path.insert(0, os.path.join(_SCRIPT_DIR, "class"))

import utils                     # noqa: E402
from GetPixels import get_info  # noqa: E402


def _load_logic(class_id):
    """按 class_id 找对应的 *_logic.py 并加载"""
    mapping = {
        1: "warrior", 2: "paladin", 3: "hunter", 4: "rogue", 5: "priest",
        7: "shaman", 8: "mage", 9: "warlock", 11: "druid",
    }
    key = mapping.get(class_id)
    if not key:
        return None, None
    import importlib.util
    path = os.path.join(_SCRIPT_DIR, "class", "%s_logic.py" % key)
    spec = importlib.util.spec_from_file_location("%s_logic" % key, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    fn = getattr(mod, "run_%s_logic" % key, None)
    return key, fn


DISPEL_SPELL = {
    "paladin": "清洁术", "priest": "驱散魔法", "shaman": "净化术",
    "druid": "解除诅咒", "mage": "解除次级诅咒",
}


def main():
    sd = get_info()
    if not sd:
        print("★ 读不到游戏状态（get_info 返回 None）")
        print("  检查：游戏窗口标题是不是「魔兽世界」、插件是否在跑、色条是否在最顶端")
        return

    class_id = sd.get("职业")
    spec_id = sd.get("专精")
    print("=" * 60)
    print("职业=%s  专精=%s" % (class_id, spec_id))
    print("=" * 60)

    # --- 1) 开关 ---
    print("\n[1] 开关")
    print("  驱散开关 = %s   (0 = 插件侧 /cy dispel off 关着)" % sd.get("驱散开关"))
    print("  有效性   = %s   (0 = 死亡/坐骑/打字/吃喝中，逻辑层会直接跳过)" % sd.get("有效性"))
    print("  战斗     = %s" % sd.get("战斗"))

    # --- 2) group ---
    print("\n[2] group（每人：生命值 / 职责 / 各类驱散剩余秒数）")
    group = sd.get("group") or {}
    field_cells = {}       # (槽位, 字段) -> 色条格号
    dispel_fields = []
    try:
        from GetPixels import _get_spec_config, load_config
        cfg2 = load_config()
        sc = _get_spec_config(cfg2, class_id, spec_id) or {}
        g = sc.get("group") or {}
        st, num = g.get("start"), g.get("num")
        if st and num:
            fields = sorted(
                ((k, v.get("step")) for k, v in g.items()
                 if isinstance(v, dict) and isinstance(v.get("step"), int)),
                key=lambda kv: kv[1])
            dispel_fields = [k for k, _ in fields if k not in ("生命值", "职责")]
            for i in range(1, 11):
                for name, step in fields:
                    field_cells[(i, name)] = st + (i - 1) * num + step
    except Exception as e:
        print("  （读配置失败：%s）" % e)

    for i in range(1, 11):
        d = group.get(str(i))
        if not d:
            continue
        extra = "  ".join("%s=%s" % (f, d.get(f)) for f in dispel_fields)
        print("  槽位%-2d 生命值=%-4s 职责=%-4s %s" % (
            i, d.get("生命值"), d.get("职责"), extra))

    nz = {k: {f: v.get(f) for f in dispel_fields if v.get(f)}
          for k, v in group.items()
          if any(v.get(f) for f in dispel_fields)}
    print("  >> 身上有可驱减益的槽位：%s" % (nz if nz else "（无）"))

    # --- 2b) 原始像素：读每格中心，确认真实颜色和秒数一致 ---
    #     每类型一格，蓝通道 = 同类最长剩余秒数（0 无 / 1 不足一秒 / 255 永久）
    #     ★ 扫描必须走 GetPixels.decode_top_row（510 格 + 中心采样），不能按 255 格自己算 x
    try:
        import ctypes
        from ctypes import wintypes
        import mss
        from GetPixels import (decode_top_row, _find_top_row_end, _px,
                               TOP_ROW_DIVISOR)

        hwnd = ctypes.windll.user32.FindWindowW(None, "魔兽世界")
        ctypes.windll.user32.SetProcessDPIAware()
        pt = wintypes.POINT(0, 0)
        ctypes.windll.user32.ClientToScreen(hwnd, ctypes.byref(pt))
        rect = wintypes.RECT()
        ctypes.windll.user32.GetClientRect(hwnd, ctypes.byref(rect))
        width = rect.right - rect.left
        with mss.mss() as sct:
            img = sct.grab({"top": pt.y, "left": pt.x, "width": width, "height": 1})
        row = decode_top_row(img.raw, img.width)

        # 行宽：从起点标记 (0,1,0) 到纯红终止格（和解码器同一套几何）
        raw = img.raw
        width = img.width
        start_x = None
        for x in range(min(510, width)):
            px = _px(raw, x)
            if px and px[1] == 1 and px[0] == 0 and px[2] == 0:
                start_x = x
                break
        end_x = _find_top_row_end(raw, start_x if start_x is not None else 0, width)
        row_width = (end_x + 1 - start_x) if (start_x is not None and end_x is not None) else 0

        def raw_color(cell):
            if not row_width:
                return "?"
            cx = start_x + ((2 * cell - 1) * row_width) // (2 * TOP_ROW_DIVISOR)
            px = _px(raw, cx)
            return "(%d,%d,%d)" % (px[2], px[1], px[0]) if px else "?"

        print()
        print("[2b] 每格中心：解出的值 + 原始 RGB（R,G,B）")
        if not row_width:
            print("  ！没找到起点/终止格：色条没画（UI 未加载）或被遮挡")
        for i in range(1, 6):
            parts = []
            for f in dispel_fields:
                cell = field_cells.get((i, f))
                if not cell:
                    continue
                parts.append("%s=格%d→%s 原始%s" % (f, cell, row.get(cell), raw_color(cell)))
            if parts:
                print("  槽位%-2d %s" % (i, "  ".join(parts)))

    except Exception as e:
        print("  （读原始像素失败：%s）" % e)

    # --- 3) 驱散技能的 CD ---
    key, fn = _load_logic(class_id)
    spell = DISPEL_SPELL.get(key)
    print("\n[3] 驱散技能冷却")
    spells = sd.get("spells") or {}
    if spell:
        print("  %s = %s   (0 = 就绪；255 = 没学会/不可用)" % (spell, spells.get(spell)))
    else:
        print("  该职业没有驱散技能条目")

    # --- 4) 决策层实跑 ---
    print("\n[4] 决策层实跑")
    if not fn:
        print("  ★ 找不到逻辑模块")
        return
    cfg = utils.load_config()
    spec_name = utils.get_class_and_spec_name(cfg, class_id, spec_id)[1]
    try:
        utils.select_keymap_for_class(class_id)
        utils.load_keymap()
    except Exception as e:
        print("  keymap 加载异常：%s" % e)
    try:
        action, step, info = fn(sd, spec_name)
        print("  专精=%s" % spec_name)
        print("  action_hotkey = %r" % (action,))
        print("  current_step  = %r" % (step,))
        if action:
            print("\n  ✓ 决策层给出了动作 -> 应该会 send_key_to_wow(%r)" % action)
            print("    如果游戏里没施放，问题在 send_key_to_wow / 游戏焦点")
        else:
            print("\n  ★ 决策层没给动作 —— 问题在上面的字段")
    except Exception as e:
        import traceback
        print("  决策层异常：%s" % e)
        traceback.print_exc()


if __name__ == "__main__":
    main()

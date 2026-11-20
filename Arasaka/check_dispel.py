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
    print("\n[2] group（每个队友 3 格：生命值 / 职责 / 驱散）")
    group = sd.get("group") or {}
    for i in range(1, 11):
        d = group.get(str(i))
        if not d:
            continue
        print("  槽位%-2d 生命值=%-4s 职责=%-4s 驱散=%s" % (
            i, d.get("生命值"), d.get("职责"), d.get("驱散")))
    nz = [(k, v.get("驱散")) for k, v in group.items()
          if v.get("驱散") not in (0, None)]
    print("  >> 有驱散标记的槽位：%s" % (nz if nz else "（无）"))

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

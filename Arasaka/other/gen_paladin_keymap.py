# -*- coding: utf-8 -*-
"""兼容入口：圣骑士 keymap 生成。

真正的实现在 `gen_class_keymap.py`（40 人 / 45 键 / 9 职业通用）。
本文件保留只为兼容旧习惯的 `python Arasaka/other/gen_paladin_keymap.py`，
等价于 `python Arasaka/other/gen_class_keymap.py Paladin`。

★ 别再往这里写生成逻辑：旧版写死 30 人 / 39 键 / 273 宏位，
  跑一次就会把 keymap/paladin.yml 覆盖回旧布局（40 号队友没有热键）。
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import gen_class_keymap  # noqa: E402

if __name__ == "__main__":
    sys.argv = [sys.argv[0], "Paladin"]
    gen_class_keymap.main()

import ctypes            # 用于调用 Windows 底层的 C 函数库（操作窗口、处理缩放）
from ctypes import wintypes # 定义了 Windows 专用的数据类型（如 POINT, RECT）
import mss              # 一个极速的屏幕截图库，比 PIL 快很多
import os               # 用于配置路径
import sys              # 用于添加父目录到导入路径
import time             # 用于统计扫描耗时
import yaml             # 加载 config.yml

# 添加当前目录到路径，用于导入 utils
_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if _SCRIPT_DIR not in sys.path:
    sys.path.insert(0, _SCRIPT_DIR)

# 解决 Windows 屏幕缩放问题（高 DPI 适配）
try:
    ctypes.windll.user32.SetProcessDPIAware()
except Exception:
    pass

# config.yml 与 GetPixels.py 同目录
CONFIG_PATH = os.path.join(_SCRIPT_DIR, "config.yml")

PIXELS_PER_ROW = 255  # 扫描 255 个数据点

# mss 的 DC 是线程局部的，用 threading.local 让每个线程持有自己的单例
import threading
_tls = threading.local()

def _get_sct():
    if not hasattr(_tls, "sct"):
        _tls.sct = mss.mss()
    return _tls.sct

def load_config():
    """加载 config.yml（缓存，避免每帧重复解析 YAML）"""
    if load_config._cache is None:
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            load_config._cache = yaml.safe_load(f)
    return load_config._cache

load_config._cache = None



def _is_rgb_red_marker(b, g, r):
    """RGB (1, 0, 0)；mss 为 BGRA 顺序入参。"""
    return r == 1 and g == 0 and b == 0


def _is_rgb_red_green_marker(b, g, r):
    """RGB (1, 1, 0)；与 (1,0,0) 配对表示一个「开始」。"""
    return r == 1 and g == 1 and b == 0


def _is_rgb_white(b, g, r):
    """RGB (255, 255, 255)。"""
    return r == 255 and g == 255 and b == 255


def _is_rgb_green_marker(b, g, r):
    """RGB (0, 1, 0)；顶部长条起点标记。"""
    return r == 0 and g == 1 and b == 0


def _is_rgb_gray_end_marker(b, g, r):
    """RGB (200, 200, 200)；与 Lua 中 count bar 行末终点色块一致，遇则终止该行扫描。"""
    return r == 200 and g == 200 and b == 200


# 队伍可施法人数上限（与 core/macro.lua 的 GROUP_TARGET_LIMIT 一致）：
#   键位总数 = 7 种修饰 × 46 键 = 322
#   圣骑士 7 个动态技能 × 40 人 = 280 + 静态/特殊 34 = 314 <= 322  -> 覆盖 40 人
#   （Shingen 用 26 组左右修饰 × 44 键 = 1143 位；我们只加主键，不动修饰键）
#   config 的 group.units 可覆盖（1~40），超 40 会被夹住。
DEFAULT_GROUP_UNITS = 40

TOP_ROW_CAPACITY = 510          # 数据格数（与 core/block.lua 的 BLOCK_CAPACITY 一致）
TOP_ROW_SCHEME_SPAN = 255       # 每套 255 格，r 通道 = 方案号
TOP_ROW_DIVISOR = TOP_ROW_CAPACITY + 1   # + 末尾纯红终止格


def _px(raw, x):
    """取第 x 个像素的 (b, g, r)；越界返回 None。"""
    off = x * 4
    if off + 2 >= len(raw):
        return None
    return raw[off], raw[off + 1], raw[off + 2]


def _expected_channels(index):
    """索引 -> (r, g)：与 Lua EncodeBlockChannels 完全一致。"""
    scheme = (index - 1) // TOP_ROW_SCHEME_SPAN
    return scheme, index - scheme * TOP_ROW_SCHEME_SPAN


def _find_top_row_end(raw, start_x, width):
    """
    从起点向右找纯红终止格，返回终止格**最后一个像素**的 x。

    ★ 终止格在 Lua 侧是 `SetColorTexture(1, 0, 0, 1)`，落到 8bit 是 (255,0,0)，
      不是 (1,0,0)（1/255 那个红是左侧计数条的标记，别混）。
    ★ 必须吃掉连续的整段红：终止格在物理屏幕上是 3~4 个像素宽，
      只取第一颗会把行宽算小 2~3 像素，格中心整体左移 -> 每格错位一格。
      右端可能和黑底混色成 (127,0,0)，所以扩展条件只要求「红 > 0 且 g=b=0」。
    ★ 数据格的 g 恒 >= 1（序号从 1 开始），所以 g == 0 不会误伤数据格。
    """
    start = None
    for x in range(start_x + 1, width):
        px = _px(raw, x)
        if px is None:
            return None
        b, g, r = px
        # r > 0 即可：数据格的 g 恒 >= 1，所以 (r>0, g=0, b=0) 只可能是终止格；
        # 这样 1/255 和 1.0 两种写法（8bit 1 或 255）都能认。
        if g == 0 and b == 0 and r > 0:
            start = x
            break
    if start is None:
        return None

    end = start
    for x in range(start + 1, width):
        px = _px(raw, x)
        if px is None:
            break
        b, g, r = px
        if g == 0 and b == 0 and r > 0:
            end = x
        else:
            break
    return end


def decode_top_row(raw, width):
    """
    解码顶行像素（Shingen 同款分档编码 + 按格中心采样）。

    编码：索引 1..255 -> (r=0, g=序号/255)；256..510 -> (r=1, g=(序号-255)/255)
    末尾一格纯红（Lua 写 `SetColorTexture(1,0,0)`，落到屏幕是 8bit (255,0,0)）作为行尾。

    ★ 为什么按「格中心」采样而不是逐像素解码：
      510 格时每格只有 ~3.5 物理像素，格边界的混合像素会被解成相邻格的序号，
      逐像素写入会把相邻格的数值覆盖掉。中心采样天然跳过边界。

    返回 {索引: 蓝通道值}；找不到起始标记/终止格时返回 {}。
    """
    row_data = {}
    start_x = -1
    for x in range(min(TOP_ROW_CAPACITY, width)):
        px = _px(raw, x)
        if px is None:
            break
        b, g, r = px
        if _is_rgb_green_marker(b, g, r):
            start_x = x
            break
    if start_x < 0:
        return row_data

    end_x = _find_top_row_end(raw, start_x, width)
    if end_x is None:
        # 色条没画完整（UI 未加载/被遮挡）-> 不猜
        return row_data

    row_width = end_x + 1 - start_x
    if row_width < TOP_ROW_DIVISOR:
        return row_data

    for index in range(1, TOP_ROW_CAPACITY + 1):
        # 格中心：start + (2i-1) * W / (2 * 511)
        cx = start_x + ((2 * index - 1) * row_width) // (2 * TOP_ROW_DIVISOR)
        px = _px(raw, cx)
        if px is None:
            break
        b, g, r = px
        scheme, pos = _expected_channels(index)
        # 严格校验：只有解码出的 (r,g) 与索引完全吻合才采信，混合像素直接丢弃
        if r == scheme and g == pos:
            row_data[index] = b

    return row_data


def scan_screen_data(window_title="魔兽世界"):
    """
    两次窄截图分别扫描顶部长条和左边界标记，大幅减少截图数据量。
    返回 (row_data, bar_data) 元组：
    - row_data: 顶部长条数据 {1: val1, 2: val2, ...}
    - bar_data: 左边界标记数据 {1: val1, 2: val2, ...}
    若扫描失败返回 (None, None)
    """
    hwnd = ctypes.windll.user32.FindWindowW(None, window_title)
    if not hwnd:
        return None, None

    point = wintypes.POINT(0, 0)
    ctypes.windll.user32.ClientToScreen(hwnd, ctypes.byref(point))

    rect = wintypes.RECT()
    ctypes.windll.user32.GetClientRect(hwnd, ctypes.byref(rect))
    width = rect.right - rect.left
    height = rect.bottom - rect.top
    if width <= 0 or height <= 0:
        return None, None

    base_x, base_y = point.x, point.y
    sct = _get_sct()

    # ========== 扫描顶部长条：截取第一行（width × 1）==========
    top_img = sct.grab({"top": base_y, "left": base_x, "width": width, "height": 1})
    row_data = decode_top_row(top_img.raw, width)

    # ========== 扫描左边界标记：截取第一列（1 × height）==========
    bar_data = {}
    left_img = sct.grab({"top": base_y, "left": base_x, "width": 1, "height": height})
    left_raw = left_img.raw
    left_bytes = len(left_raw)
    marker_y = None

    # 单列截图每行只有 4 字节（BGRA），逐行找第一个红色标记
    for y in range(height):
        offset = y * 4
        if offset + 2 >= left_bytes:
            break
        b, g, r = left_raw[offset], left_raw[offset + 1], left_raw[offset + 2]
        if _is_rgb_red_marker(b, g, r):
            marker_y = y
            break

    if marker_y is not None:
        # 找到标记行后，需要截取该行完整数据来解析 bar 值
        marker_row_img = sct.grab({"top": base_y + marker_y, "left": base_x, "width": width, "height": 1})
        raw_data = marker_row_img.raw
        total_bytes = len(raw_data)

        def consume_value_from(from_x, already_saw_white=False):
            sx = from_x
            need_white = not already_saw_white
            while sx < width:
                offset = sx * 4
                if offset + 2 >= total_bytes:
                    break
                b2, g2, r2 = raw_data[offset], raw_data[offset + 1], raw_data[offset + 2]
                if _is_rgb_gray_end_marker(b2, g2, r2):
                    return 0, width
                if _is_rgb_red_marker(b2, g2, r2):
                    return 0, sx
                if need_white:
                    if _is_rgb_white(b2, g2, r2):
                        need_white = False
                    sx += 1
                    continue
                if _is_rgb_white(b2, g2, r2):
                    sx += 1
                    continue
                return int(g2), sx + 1
            # 如果找不到白色像素，直接返回 0
            if need_white:
                return 0, width
            return 0, width

        def _dict_value_from_raw_g(raw_g):
            return max(0, int(raw_g) - 1)

        seg_idx = 0
        x = 0
        pending_1_0_0 = False

        while x < width:
            offset = x * 4
            if offset + 2 >= total_bytes:
                break
            b, g, r = raw_data[offset], raw_data[offset + 1], raw_data[offset + 2]

            if _is_rgb_gray_end_marker(b, g, r):
                break

            if pending_1_0_0 and _is_rgb_red_green_marker(b, g, r):
                pending_1_0_0 = False
                seg_idx += 1
                val, next_x = consume_value_from(x + 1, already_saw_white=False)
                bar_data[seg_idx] = _dict_value_from_raw_g(val)
                x = next_x
                continue

            if _is_rgb_red_marker(b, g, r):
                pending_1_0_0 = True
                x += 1
                continue

            if _is_rgb_white(b, g, r):
                prev_white = False
                if x > 0:
                    prev_offset = (x - 1) * 4
                    if prev_offset + 2 < total_bytes:
                        pb, pg, pr = raw_data[prev_offset], raw_data[prev_offset + 1], raw_data[prev_offset + 2]
                        prev_white = _is_rgb_white(pb, pg, pr)

                if not prev_white:
                    pending_1_0_0 = False
                    seg_idx += 1
                    val, next_x = consume_value_from(x + 1, already_saw_white=True)
                    bar_data[seg_idx] = _dict_value_from_raw_g(val)
                    x = next_x
                    continue

            x += 1

    return (row_data if row_data else None, bar_data if bar_data else {})


def scan_top_bar(window_title="魔兽世界"):
    """
    扫描客户区顶部长条（自适应步长）：
    找 (R=0,G=1,B=0) 为起点，向右逐像素扫描，当 R=0 且 1<=G<=200 时，
    用 G 通道作为索引、B 通道作为数值，填充 row_data。
    返回 row_data: {1: val1, 2: val2, ...} 或 None
    
    已弃用：请使用 scan_screen_data() 替代，以减少屏幕截图次数。
    """
    row_data, _ = scan_screen_data(window_title)
    return row_data


def scan_row_data_red_white_markers(window_title="魔兽世界"):
    """
    从魔兽世界客户区左上角开始，沿左边界 (x=0) 向下扫描，找到首个 RGB(1,0,0) 的像素所在行。
    在该行上从左到右扫描，每识别到一种「开始」则新建一个键（从 1 递增）。
    
    已弃用：请使用 scan_screen_data() 替代，以减少屏幕截图次数。
    """
    _, bar_data = scan_screen_data(window_title)
    return bar_data


# 可与 state 分开展开在 YAML 顶层的像素元字段（step 与 state 同一套索引）
_META_PIXEL_KEYS = ("锚点", "职业", "专精")


def _resolve_raw_from_field(field, row_data, bar_data):
    """
    从 row_data 或 bar 扫描字典取原始值。
    step 为 bar 时，用配置中的 bar 整数为键，取 scan_row_data_red_white_markers 返回字典中的值。
    """
    if not isinstance(field, dict) or "step" not in field:
        return None
    step = field["step"]
    if step == "bar":
        bd = bar_data or {}
        bi = field.get("bar")
        if bi is None:
            return None
        return bd.get(int(bi))
    return row_data.get(step)


def _get_spec_config(config, class_id, spec_id):
    """合并顶层元字段、state 与职业专精配置。config 结构：锚点/职业/专精、state，以及 5->1 等。"""
    state = config.get("state") or {}
    spec_cfg = {}
    class_dict = config.get(class_id) if class_id is not None else None
    if isinstance(class_dict, dict):
        spec_cfg = class_dict.get(spec_id) or {}
    merged = {}
    for key in _META_PIXEL_KEYS:
        block = config.get(key)
        if isinstance(block, dict) and "step" in block:
            merged[key] = block
    merged.update(state)
    for k, v in (spec_cfg or {}).items():
        merged[k] = v
    return merged


def build_state_dict(config, row_data, state_config, class_id=None, spec_id=None, bar_data=None):
    """
    根据 state_config 和 row_data 构建完整字典。
    键 = 配置的 key（如 职业、专精、生命值），值 = 按 type 转换后的整数/布尔/字符串；
    spells 和 group 为子字典；
    group 从 start 开始，每隔 num 个 step 为一个子字典（每个队友/小队成员）。
    bar_data：scan_row_data_red_white_markers 的返回值；字段 step 为 bar 时用 bar 为下标从中取值。
    """
    result = {}
    if class_id is None and 2 in row_data:
        class_id = row_data[2]
    if spec_id is None and 3 in row_data:
        spec_id = row_data[3]

    # 解析 state 中的普通字段（非 spells、group）
    for key, field in (state_config or {}).items():
        if key in ("group", "spells"):
            continue
        if not isinstance(field, dict) or "step" not in field:
            continue
        name = key
        type_ = field.get("type", "int")
        raw = _resolve_raw_from_field(field, row_data, bar_data)

        if type_ == "int":
            result[name] = int(raw) if raw is not None else 0
        elif type_ == "bool":
            result[name] = bool(int(raw)) if raw is not None else False
        else:
            result[name] = raw

    # spells 子字典
    spells_config = (state_config or {}).get("spells")
    if spells_config and isinstance(spells_config, dict):
        spells_sub = {}
        for spell_key, spell_field in spells_config.items():
            if not isinstance(spell_field, dict) or "step" not in spell_field:
                continue
            type_ = spell_field.get("type", "int")
            raw = _resolve_raw_from_field(spell_field, row_data, bar_data)
            if type_ == "int":
                spells_sub[spell_key] = int(raw) if raw is not None else 0
            elif type_ == "bool":
                spells_sub[spell_key] = bool(int(raw)) if raw is not None else False
            else:
                spells_sub[spell_key] = int(raw) if raw is not None else 0
        result["spells"] = spells_sub

    # group 子字典：从 start 开始，每隔 num 个 step 为一个成员
    # Lua: index = unit_start + obj.index * unit_num + field_offset (1~5)
    # Python: base_step=start+(i-1)*num, row_key=base_step+(rel_step-1) 对应 Lua 的 index
    group_config = (state_config or {}).get("group")
    if group_config and isinstance(group_config, dict):
        start = group_config.get("start", 26)
        num_params = group_config.get("num", 5)
        try:
            num_units = int(group_config.get("units", DEFAULT_GROUP_UNITS))
        except (TypeError, ValueError):
            num_units = DEFAULT_GROUP_UNITS
        # 总线最多 510 格，单人格数由 config 决定，40 人是队伍上限（raid 上限）
        num_units = max(1, min(40, num_units))
        result["group"] = {}
        for i in range(1, num_units + 1):
            base_step = start + (i - 1) * num_params
            sub = {}
            for field_key, field in group_config.items():
                if field_key in ("start", "num") or not isinstance(field, dict) or "step" not in field:
                    continue
                rel_step = field.get("step")
                type_ = field.get("type", "int")
                if rel_step == "bar":
                    raw = _resolve_raw_from_field(field, row_data, bar_data)
                else:
                    row_key = base_step + rel_step
                    raw = row_data.get(row_key)
                if type_ == "int":
                    sub[field_key] = int(raw) if raw is not None else 0
                elif type_ == "bool":
                    sub[field_key] = bool(int(raw)) if raw is not None else False
                else:
                    sub[field_key] = int(raw) if raw is not None else 0
            result["group"][str(i)] = sub

    return result


def get_info(window_title="魔兽世界"):
    """
    主入口：扫描顶部长条，加载配置，根据职业专精扩展字典，返回完整状态字典。
    """
    row_data, bar_data = scan_screen_data(window_title)
    if not row_data:
        return None

    config = load_config()
    class_id = row_data.get(2)
    spec_id = row_data.get(3)

    state_config = _get_spec_config(config, class_id, spec_id)
    if bar_data is None:
        bar_data = {}
    return build_state_dict(config, row_data, state_config, class_id, spec_id, bar_data=bar_data)


if __name__ == "__main__":
    import json

    start_time = time.perf_counter()
    info = get_info()
    elapsed_ms = (time.perf_counter() - start_time) * 1000

    print(f"扫描耗时: {elapsed_ms:.2f} ms")
    if info:
        # 简单打印（json 对中文友好）
        print(json.dumps(info, ensure_ascii=False, indent=2))
    else:
        print("未找到游戏窗口或扫描失败")

    print("--- scan_row_data_red_white_markers ---")
    t0 = time.perf_counter()
    rw = scan_row_data_red_white_markers()
    print(f"扫描耗时: {(time.perf_counter() - t0) * 1000:.2f} ms")
    if rw is None:
        print("未找到游戏窗口")
    else:
        print(json.dumps(rw, ensure_ascii=False, indent=2))

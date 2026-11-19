# Cyber Deck（赛博义肢）

**独立的 WoW 辅助决策插件**

> **施工中（WIP）** — 功能仍在迭代，像素索引、配置结构和存档格式随时可能调整。
>
> 目前只有 **圣骑士（无限服 1.60.1）** 完成适配与验证；其余 12 个职业的
> `class/*.lua` 与 `Arasaka/class/*_logic.py` 仍沿用正式服逻辑，在无限服上表现不可预期。

<!--
AI_INSTRUCTION（AI 必读）：
1. 在修改此项目任何代码之前，请完整阅读本文件，理解整体架构、所有函数、编码约定和开发规范。
2. 本项目是一个 WoW 辅助决策系统，分为 Lua 插件层（游戏内）和 Python 决策层（外部程序）。
3. 核心原则：直接修改对应文件。Lua 端编辑 Cyber_Deck 目录下文件，Python 端编辑 Arasaka/ 下文件。
4. 完成代码修改后，必须同步更新本文件中对应的章节。
5. 像素块名称、状态字段、GUI 文本统一使用中文。
6. 新增像素块索引从 210 起（1~208 已被占用：1~57 单体字段、58~207 队伍块、208 圣印剩余）。
-->
<!-- AI: Before making any changes to this project, read this entire file first. After completing code changes, you MUST update the corresponding sections in this file. -->

> 用户使用说明：[使用说明.md](使用说明.md)

---

## 一、项目概述

**Cyber Deck（赛博义肢）** 是一个独立的 WoW 辅助决策系统，分为两层：

1. **WoW 插件层（Lua）**：在游戏内运行，将玩家/目标/队伍/法术等状态编码为屏幕顶部像素条的颜色值
2. **Python 决策层**：在外部运行，通过屏幕像素扫描读取游戏状态，根据职业逻辑做决策，通过后台按键（PostMessage）向游戏发送操作

### 特性

- **不读写内存、不注入**：游戏状态压进屏幕顶部 255 个色块的 RGB 值，外部截图解码
- **13 个职业**：每个职业独立的像素布局（`class/*.lua`）与决策逻辑（`Arasaka/class/*_logic.py`）
- **零侵入操作**：`PostMessage` 后台发键，不抢焦点，可以边挂机边打字
- **热重载**：改完 Python 逻辑点一下 GUI「重载」即可，不用重启进程
- **可观测**：`/cy gui` 看像素原始值、`/cy spec` 看专精/技能解析、`/cy auraprobe` 探测哪些光环字段被 secret 保护

### 快速开始

| 项 | 要求 |
|---|---|
| 游戏 | 魔兽世界**无限服** 1.60.1（Interface 16001）。正式服 12.x 的 Lua 层兼容，但职业逻辑需自行移植 |
| 显示模式 | **窗口化 / 无边框窗口**（全屏独占截不到像素条） |
| Python | 3.10+（仅源码方式需要） |
| 依赖 | `customtkinter`（GUI）、`mss`（截图）、`pyyaml`（配置）；发键用内置 `ctypes`，无需 `pywin32` |

```bash
pip install customtkinter mss pyyaml
```

**安装四步**

1. 整个 `Cyber_Deck` 目录放进 `Interface/AddOns/`
2. 进游戏 `/reload`（或重启客户端）
3. 启动决策层：`python logic_gui_Tools.py`
4. 按住鼠标侧键（`XBUTTON1`，可在 GUI 改）执行逻辑；GUI 会自动识别职业/专精

> 插件只做**状态采集与显示**，所有决策在外部的 Python 进程里；关掉 Python，游戏侧不会有任何动作。

---

## 二、文件结构

```
Cyber_Deck/
├── Cyber_Deck.toc          # 插件定义（v0.1.0-forever, 接口 16001 / 120000-120005）
├── embeds.xml              # Ace3 库嵌入
├── LICENSE                 # MIT
├── README.md               # 完整技术文档（本文件）
├── 使用说明.md              # 用户使用说明
├── .gitignore
├── logic_gui_Tools.py      # 主 GUI（明文源码，`python logic_gui_Tools.py` 运行）
├── gui_window_state.json   # GUI 窗口状态（本地生成，已 gitignore）
│
├── Libs/                   # 第三方库（Ace3 系列 + LibRangeCheck-3.0）
│
├── core/                   # Lua 核心模块
│   ├── core.lua            # 插件初始化、AceDB、事件注册、斜杠命令、开关切换
│   ├── forever_data.lua    # 无限服离线技能表（{level, spellID}，ForeverDB 1.60.1）
│   ├── forever.lua         # 无限服适配层（专精判定/技能名→rank/光环扫描/物品分组）
│   ├── config.lua          # spellsList/events/heroTalents/difficulty/keymap 等配置
│   ├── block.lua           # 像素色条创建（255个色块 + 法术充能进度条）
│   ├── macro.lua           # 动态宏创建（@raid/party 智能切换）
│   ├── keybinds.lua        # 扫描动作条按键绑定
│   ├── auras.lua           # 光环状态机（按classId索引）
│   ├── quickbutton.lua     # 四按钮可拖拽面板（爆发/AOE/输出模式/驱散）
│   └── Spell_Misc_EmotionHappy.blp  # 插件图标
│
├── class/                  # 职业模块（13个职业的像素块布局 ClassBlocks）
│   ├── Paladin.lua         # 圣骑士 — 含驱散开关/5码敌人/焦点施法宏
│   └── ...                 # Warrior/Hunter/Rogue/Priest/DK/Shaman/Mage/
│                           #   Warlock/Monk/Druid/DH/Evoker
│
├── main.lua                # 事件处理函数 + OnUpdate 帧循环
├── gui.lua                 # Ace3 配置界面（/cy gui 像素块调试）
│
├── Arasaka/                # Python 决策层
│   ├── config.yml          # 像素块配置（按职业ID分段）
│   ├── utils.py            # 核心工具库（配置加载、按键发送、单位查询）
│   ├── GetPixels.py        # 屏幕像素扫描引擎（mss 截图 + RGB 解码）
│   ├── class/              # 职业逻辑模块（14个.py，13职业 + __init__）
│   │   ├── paladin_logic.py   # 圣骑士（含驱散开关+Holy进攻+5码判断）
│   │   └── ...             # 其余12个职业
│   ├── keymap/             # 按键映射（14个.yml：1个默认 keymap.yml + 13个职业专用）
│   └── other/              # 调试工具 + icon.ico + 数据生成脚本
│
└── pack/                   # 打包工具（可选，Cython + PyInstaller + UPX → exe）
    ├── launcher.py
    ├── 打包exe.py
    └── 打包exe.bat         # 需自备 upx.exe（https://upx.github.io）放进同目录
```

> **运行方式（二选一）**
> 1. 源码：`python logic_gui_Tools.py`（Python 3 + `customtkinter` / `mss` / `pyyaml` / `pywin32`）
> 2. 打包：`python pack/打包exe.py` 生成 `Cyber_Deck.exe`，分发时无需 Python 环境（exe 不入库）
>
> 两种方式共用同一份 `Arasaka/`，改逻辑层不必重新打包（点"重载"就生效）。
>
> **动态加载**：`Arasaka/` 下模块通过 `importlib.import_module` 从磁盘加载，修改 Python 文件后点击 GUI"重载"即生效。
>
> **路径定位**：1. 脚本同级 `Arasaka/` → 2. 注册表 WoW 路径 → 3. WoW 进程路径反推

---

## 三、加载顺序

### Lua 端（按 Cyber_Deck.toc 顺序）

1. `embeds.xml` + `Libs/LibRangeCheck-3.0`
2. `core/core.lua`（建 `CyberDeck` 对象、AceDB、事件注册）
3. `core/forever_data.lua`（离线技能表）→ `core/forever.lua`（无限服适配层）
4. `core/quickbutton.lua` → `core/config.lua` → `core/block.lua` → `core/macro.lua`
   → `core/keybinds.lua` → `core/auras.lua`
5. 13 个 `class/*.lua`（Warrior → Paladin → … → Evoker）
6. `main.lua` → `gui.lua`

顺序不能随意调，依赖关系是单向的：

| 文件 | 依赖谁 |
|------|--------|
| `forever.lua` | `forever_data.lua`（读离线表）、`core.lua`（CyberDeck 对象） |
| `auras.lua` | `config.lua` 的 `CyberDeck.e` 事件枚举 |
| `class/*.lua` | `core.lua` 的 `CyberDeck.ClassBlocks` 容器 |
| `main.lua` | 以上全部（`loadPlayerBlocks` 要读 `ClassBlocks`） |

### Python 端

`logic_gui_Tools.py` 启动时：
1. 定位 `Arasaka/` 目录并加入 `sys.path`
2. `importlib.import_module("utils")` + `importlib.import_module("GetPixels")`
3. `_build_class_module_map()` — 构建职业ID→模块名映射
4. `create_gui()` — 创建 GUI，启动按键检测和逻辑执行线程

---

## 四、核心数据流

```
WoW 游戏事件 → Lua 插件 → 编码为像素颜色 → 屏幕顶部 255 像素色块
                                              ↓ 像素扫描 (RGB)
GetPixels.py → state_dict → 职业逻辑 → (hotkey, step, info)
                                              ↓
utils.send_key_to_wow() → PostMessage → WoW 窗口
```

---

## 五、像素编码原理

- **255 个像素**，宽 = 屏幕宽度/255，高 2px
- 颜色编码：`RGB = (0, index/255, value/255)`
  - G 通道 = 索引号（1~255），标识数据含义
  - B 通道 = 数值（0~1），通过颜色曲线映射
- 充能进度条：第二行，255 像素宽，20px 高
- 左边界红/白标记对用于 Python 定位

---

## 六、Lua 端核心机制

### 全局表

```lua
CyberDeck.state       -- 玩家状态 (classId, className, specName, specID, ...)
CyberDeck.blocks      -- 当前加载的像素块配置
CyberDeck.target      -- 目标信息
CyberDeck.group       -- 队伍单位信息
CyberDeck.groupList   -- 队伍单位列表
CyberDeck.defaults    -- AceDB 默认值
CyberDeck.keybindings -- 按键绑定映射
CyberDeck.timeElapsed -- OnUpdate 计时器
```

### AceDB 保存变量（`CyberDeckADB`）

```lua
char = { level, aoeMode, cooldowns, dpsMode, delay, potion,
         quickButtonCX, quickButtonCY, quickButtonShow, dispel }
```

> **改名说明**：v0.1.0 之前叫 `FuyutsuiADB`。`Cyber_Deck.toc` 目前仍声明旧名，
> `core/core.lua:OnInitialize` 里会把旧数据整体搬到 `CyberDeckADB` 再清空旧表 ——
> 老玩家升级不会丢开关状态/窗口位置。
> 等确认用户都升过级，把 toc 里的 `FuyutsuiADB` 和那段迁移代码一起删掉即可。

### 关键函数表

| 函数 | 所在文件 | 说明 |
|------|---------|------|
| `F:OnInitialize()` | core.lua | AceDB 初始化，注册 `/cy` 命令 |
| `F:OnEnable()` | core.lua | 获取专精、加载 blocks、注册事件 |
| `F:SwitchCooldown()` | core.lua | 打印爆发状态+写入像素（切换逻辑在 SlashCommand） |
| `F:SwitchAoeMode()` | core.lua | 打印 AOE 模式+写入像素（切换逻辑在 SlashCommand） |
| `F:SwitchDpsMode()` | core.lua | 打印输出模式+写入像素（切换逻辑在 SlashCommand） |
| `F:SwitchDispel()` | core.lua | 切换驱散开关（含切换逻辑+打印+像素写入） |
| `F:OnUpdate(elapsed)` | main.lua | 帧循环（高频+低频轮询） |
| `F:updatePlayerConfig()` | main.lua | 初始化驱散开关等像素 |
| `F:updateEnemyCount()` | main.lua | 敌人计数（含5码姓名版） |
| `CreatTexture(index, value)` | core/block.lua | 写入像素块（参数为索引号+数值） |
| `creatColorCurveScaling(b)` | main.lua | 非线性颜色曲线编码 |
| `InitQuickToggleButton()` | quickbutton.lua | 四按钮面板 |
| `updateAura()` | auras.lua | 光环倒计时 |
| `updateAuraBlocks()` | auras.lua | 光环像素更新 |

**斜杠命令**：`/cy help / cd / aoemode / potion / dispel / delay / gui / spec / auraprobe / options / dpsmode / message`（完整表见「十四、调试技巧」）

完整命令列表：

| 命令 | 说明 |
|------|------|
| `/cy cd` / `cd on` / `cd off` | 切换/开启/关闭爆发 |
| `/cy aoemode` / `auto` / `aoe` | 切换/自动/单体 AOE 模式 |
| `/cy dpsmode` / `manual` / `assistant` | 切换/手写逻辑/一键辅助 |
| `/cy potion` / `on` / `off` | 切换/开启/关闭爆发药水 |
| `/cy delay [秒]` | 临时延迟逻辑（默认 1 秒） |
| `/cy dispel` / `on` / `off` | 切换/开启/关闭驱散 |
| `/cy gui` | 打开像素块调试界面 |
| `/cy options` / `config` | 打开 Ace3 选项界面 |
| `/cy message <文本>` | 聊天框测试 |
| `/cy help` | 打印帮助信息 |

---

## 七、Python 端核心机制

### logic_gui_Tools.py

| 函数 | 说明 |
|------|------|
| `_build_class_module_map()` | 构建职业ID→模块名映射（扫 `Arasaka/class/*_logic.py`） |
| `reload_logic_modules()` | 热重载所有逻辑模块（GUI"重载"按钮） |
| `get_class_spec_view_data()` | 返回 `(status_keys, (group_num, fields), spells_list, buff_keys)`，GUI 三分区数据源 |
| `format_buff_value()` | 增益区显示格式化（255→有、圣印→名称、护盾→秒） |
| `create_gui()` | 创建 GUI，启动线程，进入 mainloop |

**线程模型**：按键检测 50ms / 逻辑执行 200ms / GUI 刷新 100ms

### utils.py（20 个选择器，写决策前先翻这里）

**配置与按键**

| 函数 | 返回 |
|------|------|
| `load_config()` | `config.yml` 解析结果 |
| `load_keymap()` / `select_keymap_for_class(class_id)` | 切换并加载 `keymap/<职业>.yml` |
| `get_hotkey(unit, spell)` | 热键字符串；找不到返回 `None` |
| `get_class_and_spec_name(config, class_id, spec_id)` | `(职业名, 专精名)` |
| `send_key_to_wow(keys_str, window_title)` | PostMessage 发送按键 |

**找单个单位**（`slot` 是 `"1"`~`"30"` 字符串，对应宏的 `@raidN`）

| 函数 | 返回 |
|------|------|
| `get_lowest_health_unit(state_dict, threshold=100)` | `(slot, pct)`，血量 0 视为死亡不选 |
| `get_unit_with_role(state_dict, role, reverse=False)` | `(slot, data)`，role: 1 坦 2 奶 3 输出 |
| `get_unit_with_role_and_without_aura_name(...)` | `(slot, pct)`，有职责且缺某 buff |
| `get_unit_with_aura(state_dict, aura_name)` | `(slot, remaining)`，取剩余最长的那个 |
| `get_lowest_health_unit_with_aura(...)` | `(slot, pct)`，有某 buff 的人里血最低 |
| `get_lowest_health_unit_without_aura(...)` | `(slot, pct)`，缺某 buff 的人里血最低 |
| `get_lowest_health_unit_with_any_aura(..., *names)` | `(slot, pct)`，有任意一个 buff |
| `get_lowest_health_unit_with_aura_count(...)` | `(slot, pct)`，按层数条件筛 |
| `get_unit_with_dispel_type(state_dict, dispel_type)` | `(slot, data)`，1 魔法 3 疾病 4 中毒 |

**统计数量**

| 函数 | 返回 |
|------|------|
| `get_count_units_below_health(state_dict, threshold)` | 血量低于阈值的**人数** |
| `count_units_below_health(state_dict, threshold)` | 同上（两套命名并存，实现一致） |
| `count_units_with_aura(state_dict, aura_name)` | 有该 buff 的人数 |
| `count_units_without_aura_below_health(...)` | 缺该 buff 且血低于阈值的人数 |

**统一约定**：只统计 `职责 != 0` 的单位；`state_dict["group"]` 的键是 `"1"`~`"30"`，字段为
`生命值 / 职责 / 驱散 / 光环`（`光环` 是 `{名称: 剩余秒}` 字典）。

### 职业逻辑统一接口

```python
def run_xxx_logic(state_dict: dict, spec_name: str) -> tuple:
    """返回 (action_hotkey, current_step, unit_info)，无操作时 action_hotkey = None"""
```

---

## 八、状态数据结构

```python
state_dict = {
    "职业": int,          # 1-13
    "专精": str,          # 专精名称
    "生命值": float,      # 玩家血量%
    "能量值": float,      # 玩家能量%
    "战斗": bool,
    "移动": bool,
    "施法": int,          # 施法中
    "引导": int,          # 引导中
    "蓄力": int,          # 蓄力中
    "蓄力层数": int,      # 蓄力层数
    "目标类型": int,      # 0=无/超距/死亡, 1~10=敌对, 11~20=友善（见编码表）
    "目标距离": int,      # 码
    "目标生命值": float,
    "爆发开关": int,      # 0/1
    "AOE开关": int,       # 0=自动, 1=单体
    "输出模式": int,      # 0=一键辅助, 1=手写逻辑
    "敌人人数": int,
    "5码敌人": int,       # Cyber Deck 扩展
    "队伍类型": int,      # 0=单人, 1-40=团本, 46=大秘
    "首领战": int,        # Boss ID
    "难度": int,
    "英雄天赋": int,
    "法术失败": int,
    "驱散开关": int,      # Cyber Deck 扩展
    "spells": { "法术名": 冷却值 },  # 0=就绪
    "group": {
        "1": {
            "生命值": float,     # 血量%
            "职责": int,         # 坦克/治疗/输出
            "驱散": int,         # 需要驱散的类型
            # 职业特定字段如 "永恒之火", "救世道标" 等
        },
        ...
    },
    "auras": { "光环名": int },  # 光环状态（如 "神圣意志", "圣光灌注"）
}
```

### 关键约定

| 概念 | 说明 |
|------|------|
| 冷却值 | 0=就绪, 1~254=冷却中(秒), 255=不可用 |
| 目标类型 | 0=无/超距/死亡, 1~10=敌对, 11~20=友善（1/11 为基线，其余为可驱散细分） |
| 队伍类型 | 0=单人, 1-40=团本, 46=大秘 |
| 职业ID | 1=战士 2=圣骑 3=猎人 4=盗贼 5=牧师 6=DK 7=萨满 8=法师 9=术士 10=武僧 11=德 12=DH 13=唤魔师 |

---

## 九、Cyber Deck 扩展功能

### Lua 端

| 文件 | 功能 | 说明 |
|------|------|------|
| `core/core.lua` | `SwitchDispel` | 驱散开关 |
| `main.lua` | `updatePlayerConfig` | 驱散开关像素初始化 |
| `main.lua` | `updateEnemyCount` | 5码姓名版敌人计数 |
| `main.lua` | `updateUnitCastingOrChannelingInfo` | 修复焦点引导报错 |
| `class/Paladin.lua` | `ClassBlocks[1]` | 追加驱散开关/5码敌人像素块 |
| `class/Paladin.lua` | `MacrosList.staticSpells` | 焦点施法宏 |
| `core/quickbutton.lua` | `InitQuickToggleButton` | 四按钮面板 |

### Python 端

| 文件 | 内容 |
|------|------|
| `Arasaka/config.yml` | 圣骑士三系（spec 1/2/3）各一段：全局 state + 专精字段 + spells CD + `group(start:76, num:3)` + `buff_fields` |
| `Arasaka/class/paladin_logic.py` | 三系决策：神圣（治疗/驱散/圣印）、防护（盾/圣印/审判/奉献）、惩戒（斩杀/圣印/驱散） |
| `Arasaka/keymap/paladin.yml` | 圣印与技能的热键映射（由 `other/gen_paladin_keymap.py` 生成） |

---

## 十、圣骑士定制详解

### 驱散开关（Lua + Python 双层）

- **Lua**：`SwitchDispel()` 切换 0/1，写入像素块 + SavedVariables
- **Python**：关闭时临时移除 group 中驱散字段 → 原始逻辑跳过队友驱散 → 恢复字段
- 目标驱散不受影响（依赖 `目标类型`，不依赖 group）

### 三专精共用一套索引

无限服圣骑士只有一个伪专精（1486），三系共用 `class/Paladin.lua` 的同一套像素布局，
完整索引表见「十六、无限服适配」。要点：

| 索引段 | 内容 |
|--------|------|
| `1~8` | 锚点 / 职业 / 专精 / 有效性 / 战斗 / 移动 / 施法 / 引导 |
| `9~26` | 生命值、能量值、虔诚光环、法术失败、目标类型、队伍类型、队伍人数、首领战、难度、圣印、施法技能/目标、目标距离、自动攻击、神恩术、圣光灌注、敌人人数、爆发开关 |
| `27~56` | 技能 CD（制裁之锤 / 圣盾术 / 圣佑术 / 圣疗术 / 神圣震击 / 审判 / 奉献 / 驱邪术 / 愤怒之锤 / 神圣打击 / 神圣愤怒 / 清洁术 / 正义之怒 / 目标施法 / 神圣之盾 / 神恩术 / 七种圣印探测） |
| `57` | 队伍块 `start` |
| `58~207` | 队伍块（每人 5 格：生命值 / 职责 / 驱散 / 圣光守望 / 圣光誓约） |
| `208` | 圣印剩余秒（auras 计时） |

> 编号已压缩为连续值，无空洞。`group.start = 57` 是**起始偏移**，队友 1 的
> 生命值落在 `57+1=58`，队友 30 的第 5 个 buff 位落在 `57 + 29*5 + 5 = 207`。
>
> **注意**：`197 生物类型` 已删除（正式服也没有，靠游戏自己拒绝非法目标）；
> 圣光术/圣光闪现不再采集 CD（无冷却）。

> 已删除的正式服索引（`200~211`）：复仇之怒、圣洁护盾、正义盾击、神圣风暴、责难、神圣牺牲、
> 殉道圣印/审判、洛丹伦号角、激励典范、神圣之光、真理之音 —— 无限服 60 级技能组不提供。

### 圣印机制

- 7 种圣印共用一个 `Auras["圣印"]` 条目，不列 `addAuras`（7 个 rank 段约 30 个 spellID，列全不划算）
- 施放成功由 `forever.lua:MarkForeverAuraCast` 解析出圣印编号，写入 `sealValue` + `expirationTime = now + 30`
- 18 号像素给决策层「当前挂的是哪个」，208 号给「还剩几秒」
- 防护选择：`<50%` 立即换智慧；`≥50%` 且智慧未到期则保持；到期或挂错才换愤怒

### 四按钮面板

| 按钮 | 功能 |
|------|------|
| 爆发 | 切换爆发开关 |
| 自动/单体 | 切换 AOE 模式 |
| 逻辑/辅助 | 切换输出模式 |
| 驱散 | 切换驱散开关 |

---

## 十一、按键发送机制

Python 通过 `PostMessage(WM_KEYDOWN/WM_KEYUP)` 向 WoW 窗口发送按键：

| 模式 | 说明 |
|------|------|
| `switch` | 按下+释放（默认，适合瞬发） |
| `click` | 鼠标点击 |
| `hold` | 按住不放（持续施法/引导） |

---

## 十二、添加新职业逻辑

### Lua 端

1. 创建/编辑 `class/NewClass.lua`，定义 `CyberDeck.ClassBlocks[classId]`
2. 在 `core/config.lua` 的 `spellsList` 中添加法术映射
3. 在 `Cyber_Deck.toc` 中注册文件

### Python 端

1. 创建 `Arasaka/class/newclass_logic.py`，实现 `run_newclass_logic(state_dict, spec_name)`
2. 在 `Arasaka/config.yml` 中添加 `keymap: "newclass.yml"`
3. 创建 `Arasaka/keymap/newclass.yml`

---

## 十三、开发规范

### 通用规则

1. **直接修改**：所有功能直接编辑对应文件
2. **中文命名**：像素块、状态字段、GUI 文本
3. **像素索引**：新增从 210 起（1~208 已占用）
4. **SavedVariables**：新增字段在 `core/core.lua` 的 `defaults.char` 注册

### Python 端规则

- 职业逻辑返回 `(action_hotkey, current_step, unit_info)` 三元组
- 优先使用 `utils.py` 工具函数
- 修改后点击 GUI"重载"生效

### 常见陷阱

- **elif 链无法回退**：跳过某优先级需在调用前修改 `state_dict`
- **线程安全**：访问 `_state_dict` 注意 `_state_lock`
- **TOC 顺序**：`core/*.lua` → `class/*.lua` → `main.lua` → `gui.lua`
- **模块缓存**：热重载需 `importlib.reload()`

---

## 十四、调试技巧

### 全部斜杠命令（`/cy` / `/cyberdeck`）

> `/fu` 仍然注册着，等价于 `/cy`（老习惯/旧宏可直接用）。想彻底停用把 `core/core.lua:23` 那行删掉即可。

| 命令 | 作用 |
|------|------|
| `/cy help` | 打印命令列表 |
| `/cy cd` / `cd on` / `cd off` | 爆发开关（切换 / 开 / 关） |
| `/cy aoemode` / `auto` / `aoe` | AOE 模式（切换 / 自动 / 单体） |
| `/cy potion` / `on` / `off` | 爆发药水开关 |
| `/cy dispel` / `on` / `off` | 驱散开关（同时改 Lua 像素和 Python 行为） |
| `/cy delay [秒]` | 临时暂停决策 N 秒（默认 1 秒，用于手动插技能） |
| `/cy gui` | 像素块调试界面 |
| `/cy spec` | 专精判定 / 技能解析 / 圣印计时 |
| `/cy auraprobe`（`/cy ap`） | 光环字段可读性探测，见下方 |
| `/cy options` / `/cy config` | Ace3 选项面板 |
| `/cy dpsmode` / `manual` / `assistant` | 输出模式切换 ⚠️ **无限服无「一键辅助」，决策层也不读这个值，属于遗留功能** |
| `/cy enable` / `/cy disable` | Ace3 启用/停用插件本体 |
| `/cy message 文本` | 聊天框测试输入 |

### 其它调试手段

- `/script SetTestSecret(0)` — 关闭秘密值限制（启动时默认 `SetTestSecret(1)` 开启）
- `Arasaka/other/GetRGB.py` — 获取像素 RGB
- `Arasaka/other/GetInfo.py` — 打印 state_dict
- `Arasaka/other/hex_to_decode.py` — 十六进制解码
- GUI「重载」按钮 — 热重载 Python 模块

### secret 探测（写治疗职业前先跑一次）

无限服的 secret 机制会让部分光环字段在战斗中变成不可比较的值。`/cy auraprobe` 逐字段试读，
输出 `name / spellId / expirationTime / applications` 各自能不能用：

示例输出（数值仅示意格式，实际以游戏内为准）：

```
[Cyber Deck] 光环可读性探测 [战斗中]
[player] 8 条  name 8/8  spellId 8/8  时间 6/8  层数 8/8
  圣印             spell=21084  name=ok     remain=24.3  stack=-
  正义之怒          spell=25780  name=ok     remain=-     stack=-
  party1 减益条数（HARMFUL|RAID）= 2
[target 怪名 我放的 debuff] 2 条  name 2/2  spellId 2/2  时间 2/2
  审判             spell=20271  name=ok     remain=8.0
  十字军圣印        spell=21082  name=ok     remain=12.5
```

最后一段走 `HARMFUL|PLAYER`（"我施加的 debuff"专用 filter），
和玩家自身 buff 的 `HELPFUL` 是两条独立通道。`getTargetDispelType()` 一直在用这条路径，
所以它至少能拿到**数量和驱散类型**；名字和剩余时间在战斗中是否也被保护，跑一次看这一段的
`name x/y` 与 `时间 x/y` 即可确认。

判断依据：

| 现象 | 含义 |
|------|------|
| `name=ok` | 可以直接按名字匹配（最省事） |
| `name=SECRET` 但 `spellId=ok` | 按 spellID 匹配 |
| 两个都 `SECRET` | 只能用 `auraInstanceID` 集合或 filter 计数 |
| `remain=SECRET` | 只知道"有"，不知道"还剩多久" |

写新职业时先跑这个，再决定像素块怎么设计——别先写逻辑再猜能不能读到。

---

## 十五、快速参考（AI 速查）

> **先读第十七节**。加功能之前先在「17.2 想做什么 → 改哪里」和「17.3 已在跑的轮子」
> 里找一遍，绝大多数需求都有现成实现，重写一遍的代价见「17.6 踩过的坑」。

### 关键文件定位

| 需求 | 文件 |
|------|------|
| Lua 帧循环/事件处理 | `Cyber_Deck/main.lua` |
| Lua 开关/配置 | `Cyber_Deck/core/core.lua` |
| Lua 像素块扩展 | `Cyber_Deck/class/<职业>.lua` |
| Lua 光环计时（施放后 N 秒） | `Cyber_Deck/core/auras.lua` |
| Lua 无限服适配（技能名→rank） | `Cyber_Deck/core/forever.lua` |
| Python 职业逻辑 | `Arasaka/class/<职业>_logic.py` |
| Python 选人 / 计数选择器 | `Arasaka/utils.py` |
| 按键映射 | `Arasaka/keymap/<职业>.yml` |
| 像素块配置 | `Arasaka/config.yml` |
| SavedVariables | `Cyber_Deck/core/core.lua` 的 `defaults.char` |

### 像素编码速查

| 概念 | 说明 |
|------|------|
| G 通道 | 索引号 (1~255) |
| B 通道 | 数值 (0~1) |
| 冷却值 | 0=就绪, 1~254=冷却中(秒), 255=不可用 |
| 写入像素 | `self:CreatTexture(index, value)`  (定义在 core/block.lua) |

### 线程模型速查

| 线程 | 间隔 | 职责 |
|------|------|------|
| 按键检测 | 50ms | 轮询绑定按键 |
| 逻辑执行 | 200ms | 扫描→决策→发送 |
| GUI 刷新 | 100ms | 更新状态面板 |

### 职业逻辑返回值

```python
return (action_hotkey, current_step, unit_info)
# action_hotkey: 按键字符串 或 None（无操作）
# current_step: 步骤描述（GUI 显示）
# unit_info: 附加信息字典（GUI 显示）
```

---

## 十六、无限服（1.60.1 / Interface 16001）适配

`core/forever.lua`、`class/Paladin.lua`、`Arasaka/class/paladin_logic.py`、
`Arasaka/keymap/paladin.yml`、`Arasaka/config.yml` 的圣骑士段均已改为无限服版本。
正式服原版备份未随仓库分发（如需从原版回退，自行保留一份 `0.0.1-retail` 的副本）。

### 判定与降级

| 项 | 正式服 | 无限服 | 处理 |
|----|--------|--------|------|
| TOC 接口 | 120000+ | 16001 | `## Interface: 16001, 120000, 120001, 120005` |
| 专精 | `C_SpecializationInfo` 返回 65/66/70 | 每职业一个伪专精（圣骑士 1486），真实定位看天赋 | `F:GetActiveSpecIndex()`：**优先**用专精天赋节点（见下），读不到再依次退回树名 → 经典天赋树 → 技能探测 → treeIDs 顺序 |
| 技能 | 固定 spellID | 同一技能多个 rank | `F:ResolveSpellID(name)`：先用 `core/forever_data.lua` 离线表取“已学会的最高 rank”，再用法术书兜底（覆盖天赋技能）；未学会写 255 |
| 英雄天赋 / 一键辅助 | 有 | 无 | 20 / 13 号像素恒 0 |
| 药水 | 2413xx | 经典药水 | `F.itemGroups` 两套物品 ID（决策层暂不自动喝药，只上报冷却） |
| 法力 | 仅秘密值时写 12 | 无秘密值 | 无限服恒按百分比写 12.能量值 |

### 圣骑士像素索引（三系共用，编号已压缩为连续值）

| 索引 | 含义 |
|------|------|
| 1~8 | 锚点 / 职业 / 专精 / 有效性 / 战斗 / 移动 / 施法 / 引导 |
| 9 | 生命值（%） |
| 10 | 能量值（无限服 = 法力 %） |
| 11 | 虔诚光环：有 = 1，限时 = 剩余秒，没有 = 0 |
| 12 | 法术失败 |
| 13 | 目标类型（分段编码，见下） |
| 14 | 队伍类型 |
| 15 | 队伍人数 |
| 16 | 首领战 |
| 17 | 难度 |
| 18 | 圣印：1 正义 2 命令 3 十字军 4 光明 5 智慧 6 愤怒 7 公正 |
| 19~21 | 施法技能 / 施法目标 / 目标距离 |
| 22 | **自动攻击**：1 = 正在近战平砍（事件驱动） |
| 23 | 神恩术剩余秒 |
| 24 | 圣光灌注层数 |
| 25 | 敌人人数 |
| 26 | 爆发开关 |
| 27~37 | 技能 CD：制裁之锤 / 圣盾术 / 圣佑术 / 圣疗术 / 神圣震击 / 审判 / 奉献 / 驱邪术 / 愤怒之锤 / 神圣打击 / 神圣愤怒 |
| 38~41 | 大红冷却 / 延迟 / 驱散开关 / 5码敌人 |
| 42 | 清洁术 |
| 43 | 正义之怒（冷却） |
| 44~45 | 圣光术 / 圣光闪现 —— **已不采集 CD**（无冷却），块保留但 config 不再读取 |
| 46~47 | 正义之怒（buff）/ 目标施法 |
| 48~49 | 神圣之盾 / 神恩术（冷却 + 是否学会） |
| 50~56 | 七种圣印「是否学会」探测：50 正义 51 命令 52 十字军 53 光明 54 智慧 55 愤怒 56 公正 |
| **57** | 队伍块 `start`（是起始偏移，队友 1 的生命值落在 58） |
| **58~207** | 队伍块：每人 **5 格**（生命值 / 职责 / 驱散 / **圣光守望** / **圣光誓约**），30 人 × 5 = 150 |
| **208** | 圣印剩余秒（`type = "aura"`，auras 计时写入，0 = 没挂/到期） |

> 队伍块的算法：`start + (i-1)*num + 偏移`。`start=57`、`num=5` 时
> 队友 1 = 58~62，队友 30 = 202~207。
>
> **编号已压缩，无空洞**。以前 9/10/27/33-35/43/50-57/61-64 这些空位都填上了；
> 现在只有 44/45（圣光术/圣光闪现）内容作废，但编号仍占着。
>
> **已删除**：`197 生物类型`（正式服也没有这个设计，交给游戏自己拒绝非法目标）。

`目标类型` 的编码（`main.lua:623 getTargetDispelType`）不是 0/1/2/3，而是三段区间：

| 区间 | 含义 |
|------|------|
| `0` | 无目标 / 超出射程 / 目标已死（`updateTargetValid` 只在 `inRange and not isDead` 时才算） |
| `1~10` | 敌对：`1` = 身上没有可驱散光环，`2~10` = 有（颜色曲线细分） |
| `11~20` | 友善：`11` = 没有可驱散光环，`12~20` = 有 |

决策层用 `1 <= 目标类型 <= 10` 判敌。早期写成 `== 1`，会让「带可驱散 buff 的敌人」
被当成非敌人，防护/惩戒整条战斗链都不走。

### 专精判定（traitNode）

数据来自 ForeverDB `Talents.lua`（build 1.60.1.70862）：圣骑士三个专精各有一个**独有**天赋，
都要 10 点前置，同一套天赋不可能同时点亮，所以拿来当专精探针最可靠：

| 专精 | 天赋 | traitNode |
|------|------|-----------|
| 神圣 | Divine Favor（神恩术） | 105325 |
| 防护 | Templar's Bulwark（圣殿骑士壁垒） | 105625 |
| 惩戒 | Seal of Command（命令圣印） | 105696 |

`C_Traits.GetNodeInfo(cfg, node).activeRank > 0` 命中哪一个就是哪一系。
10 级以下三个都没点，退回“天赋点数额度最多”的老逻辑（此时专精也不影响决策）。

### 离线技能表（core/forever_data.lua）

`CyberDeck.ForeverSpellData.PALADIN` = 140 条 `{学习等级, spellID}` 训练师技能（1–60 级）。

- 生成：`python Arasaka/other/gen_forever_spells.py`（自动拉 ForeverDB manifest 并校验 sha256）
- 中文名不写死：运行时 `C_Spell.GetSpellInfo(spellID).name` 取，自动跟随客户端语言
- 作用：同一技能多个 rank 时，**按等级从高到低**找第一个 `IsSpellKnown` 的，比扫法术书的“后写覆盖”准
- 天赋技能（神恩术/神圣震击/神圣之盾/命令圣印/忏悔/圣殿骑士壁垒/圣光灌注等）不在训练师表里，仍由法术书补
- 来源署名：**Data from ForeverDB.net**（GPL-3.0 section 7(b)，勿删文件头注释）

### 自动攻击状态（24 号像素）

无限服客户端里**没有** `START_AUTO_ATTACK` / `STOP_AUTO_ATTACK` 事件，只有经典的两个：

| 事件 | 时机 |
|------|------|
| `PLAYER_ENTER_COMBAT` | 开始近战攻击 |
| `PLAYER_LEAVE_COMBAT` | 停止近战攻击 |

`core/forever.lua` 用它们维护 `F.autoAttackOn`，`UpdateForeverAutoAttack()` 每 200ms
把 `1` / `0` 写进 24 号像素。EllesmereUIActionBars 和 SwingTimer 也是同一套做法
（`meleeOn`），可作交叉验证。

已知边界：

- `/reload` 或登录时如果**正在砍怪**，事件不会补发，需要重新攻击一次才能识别；
- 死亡时客户端不会再发 `LEAVE_COMBAT`，所以 `UpdateForeverAutoAttack()` 里加了
  `UnitIsDeadOrGhost` 兜底复位；
- 远程自动射击（弓/枪/魔杖）走的是 `START_AUTOREPEAT_SPELL` / `STOP_AUTOREPEAT_SPELL`，
  和这个近战状态无关。

`C_Spell.IsCurrentSpell(6603)` 理论上也能判自动攻击，但经典内容下行为不稳定，
所以只作事件方案的参考，没有依赖它。

### 圣印计时（core/auras.lua）

圣印的 30 秒持续时间交给光环系统推算，不再自己维护锁：

| 层 | 手段 | 适用 |
|----|------|------|
| 1 | 按 **buff 名**匹配 `scanAuras("player","HELPFUL",40)` | 战斗外，最准 |
| 2 | 按 **spellID** 复查 `C_UnitAuras.GetPlayerAuraBySpellID(id)` | 多一层保险（实测战斗中它也读不到） |
| 3 | **施放计时**：`CyberDeck.Auras["圣印"]` 的 `expirationTime` | 战斗中唯一可用的手段 |

实现：

```lua
-- core/auras.lua 的 auras[2]
["圣印"] = { remaining = 0, duration = 30, expirationTime = nil, sealValue = 0 },

-- core/forever.lua 的 MarkForeverAuraCast（施放成功时）
local aura = CyberDeck.Auras["圣印"]
aura.sealValue = seal.value                    -- 1 正义 … 6 愤怒 7 公正
aura.expirationTime = GetTime() + aura.duration
```

不挂 `addAuras`：7 种圣印跨 rank 共约 30 个 spellID，列全不划算；
`MarkForeverAuraCast` 本来就能把 spellID 解析成中文名再匹配 `SEAL_ORDER`，直接写更省。

为什么不用自维护的 `lastSealUntil`：它在战斗外每次扫描到圣印都被改成 `now+2`，
进战斗瞬间锁就失效 → 像素归 0 → 决策层以为没挂 → **每次进战斗重放一次圣印**。
施放计时只在成功施放时写入，战斗外扫描不会碰它。

边界：

- **死亡**：`PLAYER_DEAD` 里清空 `expirationTime` / `sealValue`，否则复活后误判 30 秒
- **被驱散 / 手动取消**：计时仍在，最多空窗 30 秒（概率低，不额外处理）
- **战斗中补印**：`UNIT_SPELLCAST_SUCCEEDED` 的 `spellID` 可能是 secret，
  计时建不起来；30 秒后自然归 0 再补，不会卡死
- `duration = 30` 对应愤怒圣印实测时长（提示框显示剩余秒）

顺带白送一个 **208 号像素**（`type = "aura"`）：`updateAuraBlocks()` 把
`Auras["圣印"].remaining` 写进去，GUI 增益区显示「圣印剩余: 27s」。

### 兜底起手（`/startattack`）

`specialSpells` 里放的是**完整宏体**（不拼 `/cast`），与 `staticSpells` 同位置时优先：

```lua
specialSpells = {
    [35] = "/startattack [harm,nodead]",
},
```

- `/startattack` **不占 GCD**，可以随时按；
- `[harm,nodead]` 保证对友方/尸体不执行，不产生「无效目标」红字；
- 热键 `ALT-SHIFT-/`（第 185 个宏位）；
- `gen_paladin_keymap.py` 读取 `specialSpells`，名字由宏命令推导
  （`startattack` → `开始攻击`，见 `SPECIAL_ALIAS`）。

决策层用的是**兜底**位置，不是第一优先级：

```python
# 防护/惩戒战斗分支的**最后一个** elif
elif 自动攻击 == 0 and _upkeep_ok("开始攻击", 2):
    current_step = "开始攻击"
```

为什么必须放最后：`自动攻击` 像素在 `/reload` 后、停手、切目标、目标死亡时都是 0。
放在分支最前面会把后面所有 `elif`（补盾/圣印/审判…）全部挡死，表现为「一个技能都不放」。
放末尾 + 2 秒节流后，最坏情况只是每 2 秒多按一次 `startattack`，任何技能都不会被抢占。

### 窗口不抢键盘焦点（`WS_EX_NOACTIVATE`）

主窗口是 `overrideredirect(True)` 的无边框置顶悬浮窗，默认**点一下就会激活**：
一旦激活，键盘焦点从游戏转到 GUI，游戏内按键全部失效，输入法也会跟着弹出来。

`logic_gui_Tools.py` 在设置 `WS_EX_APPWINDOW` 的同时加上 `WS_EX_NOACTIVATE`：

```python
_WS_EX_NOACTIVATE = 0x08000000
style = (style & ~_WS_EX_TOOLWINDOW) | _WS_EX_APPWINDOW | _WS_EX_NOACTIVATE
```

效果：

| 操作 | 行为 |
|------|------|
| 点 GUI 按钮 / 拖标题栏 | 正常响应（鼠标消息不受影响） |
| 键盘焦点 | 始终留在游戏，输入法不会被唤出 |
| 任务栏图标 | 仍显示（`APPWINDOW`），但点击不激活窗口 |

标题栏拖动只用到 `winfo_x/y + event.x/y`，不依赖鼠标抓取，所以加了这个属性也能拖。

### GUI 三分区与 buff 显示

GUI 把像素值分成三块展示，避免语义混淆：

| 分区 | 数据来源 | 取值含义 |
|------|----------|----------|
| 实时状态 | config 职业/专精段的普通字段 | 血量、能量、战斗、距离、敌人数量… |
| 技能冷却 | config 的 `spells` 子段 | 0 = 就绪，1~254 = 剩余秒，255 = 未学会 |
| 增益状态 | config 职业级的 `buff_fields` 名单 | 255 = 有 / 0 = 没有（圣印显示名称，神恩术显示剩余秒） |

历史上 `正义之怒`、`虔诚光环` 在「实时状态」区显示 255，容易被误读成「不可用」——
实际它们是 `0/1` 写入后乘以 255 的结果，**255 表示 buff 存在**。移进独立分区并翻译成
`有/无` 后，两种 255 不再混在一起。

名单放在**职业级**（`config[class]["buff_fields"]`），不在专精级：
`build_state_dict()` 只处理带 `step` 的字段、旧版打包 exe 只读专精段，两边都不会碰到它，
所以这份名单只影响 GUI 分组，对决策和兼容性零风险。没有名单的职业该分区自动隐藏。

同一位置还有 `probe_fields`（探测块名单），这些块**不参与冷却显示**：

```yaml
  probe_fields: [正义圣印, 命令圣印, 十字军圣印, 光明圣印, 智慧圣印, 愤怒圣印, 公正圣印,
                 正义之怒CD]
```

探测块的像素含义是 `0 = 已学会 / 255 = 未学会`，不是剩余秒数。它们留在冷却区会直接误导
（例如圣印明明挂着、提示框写着「剩余 27 秒」，面板却显示 `愤怒圣印: 0`）。
`get_class_spec_view_data()` 把它们从 `spells_list` 里过滤掉，像素和决策层数据完全不动，
所以冷却区从 24 项收敛到 16 项。圣骑士当前挂的是哪个圣印，看增益区的「圣印」即可。

**`神圣之盾CD` / `神恩术CD` 不在探测名单里**——它们是有真实冷却的技能
（10 秒 / 2 分钟），只是名字带 CD 后缀、长得像探测块，必须留在冷却区显示。

`神圣之盾` 的 buff 块（24 号）**已彻底删除**：战斗中的 aura 是 secret 值，
名称和剩余时间都读不到可靠数据，采集它没有意义。决策只看 `神圣之盾CD == 0`，
和审判完全一致——盾持续 10 秒、CD 也是 10 秒，卡 CD 补即可；
buff 被提前打掉时 CD 还在转，CD 一好就补就能无缝覆盖。
没学会时 CD 像素是 255，条件不成立，不会空按。

### 按键映射（自动生成）

`Arasaka/keymap/paladin.yml` 由 `Arasaka/other/gen_paladin_keymap.py` 从
`class/Paladin.lua` 的 `MacrosList` 反推宏位生成，规则与 `core/macro.lua` 的
`macroKind`（7 组修饰键 × 39 键 = 273）完全一致：

- 动态技能 **6 个**（圣光术 / 圣光闪现 / 神圣震击 / 清洁术 / 圣疗术 / **圣光誓约**）× 30 = **180** 个宏位，`unit 1-30`；
- 静态技能 **36 个**（含 3 个 `[@player]` 变体：圣光闪现、圣光术、神圣震击）+ 1 个完整宏体 `/startattack`，`unit 0`；
- 合计 **217** 个宏位（6×30 + 36 + 1），`macroKind` 上限 273；
- **单人时**决策层用 `_solo_unit()` 自动切到 `unit 0`（`[@player]` 宏）。无限服的自定义核心
  不认动态宏里的 `[nogroup,@player]` 回退条件，所以单人必须走独立的 `[@player]` 宏；
- **宏按钮是 UIParent 下的隐藏 Frame**（`SecureActionButtonTemplate` + `SetOverrideBindingClick`），
  **不依赖动作条**，技能不拖出来也能触发；
- 改了 `MacrosList` 后重跑：`python Arasaka/other/gen_paladin_keymap.py`。

### 决策层（paladin_logic.py）

| 专精 | 优先级 |
|------|--------|
| 神圣 | 保命(圣盾<15%→圣疗) → 清洁术驱散 → **圣光守望震击**（队友身上有 1310909 时优先给他震击）→ **圣光誓约**（坦克没 buff 就补）→ 圣光术(<60%) → 圣光闪现(≤90%) → 神圣震击(<95%) → 智慧圣印（进攻块首位）→ 审判 → 神圣打击 |
| 防护 | 圣疗自救(<10%) → 补正义之怒 → 补虔诚光环 → **战斗且有敌人时**：换圣印 → 补神圣之盾（只看 CD）→ 审判 → **奉献(5码内 ≥2)** → 神圣打击(5码) → 神圣愤怒(亡灵/恶魔 ≥2) → 兜底起手；**战斗中暂无敌人**（目标刚死、未脱战）：仍补圣印；**脱战：什么都不做** |
| 惩戒 | 自疗圣光闪现(<45%) → 制裁之锤打断 → **战斗且有敌人时**：愤怒之锤(≤20%,30码) → 换圣印 → 审判 → 神圣打击(5码) → 驱邪术(亡灵/恶魔,30码) → **奉献(5码内 ≥2)** → 兜底起手；**战斗中暂无敌人**：仍补圣印（命令，缺蓝智慧）；**脱战：什么都不做** |

**防护的圣印选择**按法力**回差**判断（`能量值` 即法力百分比）：

| 法力 | 当前挂智慧且**未到期** | 其他情况 |
|------|----------------------|----------|
| < 50% | —（立即换） | **立即**换智慧 |
| ≥ 50% | **保持不动**，等它自己到期 | 换回愤怒 |

- 低于 50% 是**立即**切，不管当前圣印还剩多久；
- 回到 50% 以上**不立即取消**，让这颗智慧把剩余时间跑完，下次到期才换回愤怒
  （中途取消等于白丢一个 GCD + 一份回蓝）。
- 剩余时间优先读 **208 号像素**（auras 计时）；读不到（战斗中 `spellID` 是 secret，
  计时建不起来）时退回本地估算：`SEAL_DURATION(30s) - 距上次下达换智慧的时间`。

候选顺序（取第一个已学会的）：`<50%` 智慧→愤怒→正义；`≥50%` 愤怒→正义→智慧。
探测像素 69-75 表示是否学会（0 = 会 / 255 = 不会），智慧没学会时自动退到下一个候选，不会空按。

> 神圣（<35% 智慧）与惩戒（<25% 智慧）仍是单点阈值，本次未调整。

**补印只看 20 号编号**

圣印施放成功后由插件记 30 秒（`core/auras.lua` 的 `expirationTime`），到期后
`UpdateForeverAuras` 自动把 20 号编号归 `0`。所以决策层补印的判据就一条：

```
当前圣印编号 != 想要圣印编号  →  补（2 秒防抖，只盖像素刷新的那一两个 tick）
```

| 编号 | 剩余 | 决策 |
|---|---|---|
| 6（愤怒） | 20s | 不动 |
| 6（愤怒） | 0s | 不动（编号还在，等它归 0） |
| **0** | 0s | **补**（到期了） |
| 6（愤怒），法力 40 | 20s | 换智慧 |

208 号「圣印剩余」只参与一件事：**挂智慧回蓝时判断这颗智慧有没有到期**
（未到期就保持，别中途取消）。补印不读它，避免刚按完像素还没刷新时被误判成到期。

不需要节流的那种时间闸：编号对上就不动作，一次换印最多按一次。

已删除正式服残留：神圣能量、圣洁鸣钟、圣洁武器、英雄天赋、一键辅助 `action_map`、
`failed_spell_map`（无限服 `spellsList` 不含经典技能 ID，法术失败像素恒 0）。

### 验证

- `luaparse`（Lua 5.1）解析 **24 个** Lua 文件通过（13 职业 + 9 个 core 模块 + `main.lua` + `gui.lua`，不含 `Libs/`）；
- **fengari 行为测试**（`forever_harness.lua`，独立于仓库）：**34 项**通过
  （专精判定 / 技能名→rank / 圣印像素 / 圣印计时 / 自动攻击 / 离线表）；
- **决策链路测试**（`paladin_forever_test.py`，独立于仓库）：**68 项**通过
  （config↔Lua 索引一致性、块编号不撞队伍块、逻辑用到的技能都有宏键、圣印回差/乐观记录等）；
- 游戏内 `/cy spec` 看专精/点数/解析到的 spellID，`/cy gui` 核对像素。

### 仍未适配

其余 12 个职业的 `class/*.lua` 与 `Arasaka/class/*_logic.py` 仍是正式服版本，
在无限服只会加载到 0 值；需要时按圣骑士这套流程逐个改。

---

## 十七、扩展前先查这里（现有能力对照）

这一节的目的只有一个：**别重造轮子**。下面的每一条都是仓库里已经在跑的实现，
加新功能时先在这里找，找不到再写新的。

### 17.1 三个必答问题

动手之前先回答：

1. **这个数据是不是已经有像素了？**
   查 `Arasaka/config.yml`（按职业分段）+ `class/<职业>.lua` 的 `buildBlocks`。
   同一个数值写两遍像素会互相覆盖，且两处语义会漂移。
2. **这个「计时」需求能不能挂到 `core/auras.lua`？**
   只要是「施放成功后持续 N 秒」的东西，一律用光环状态机，不要自己维护 `until` 变量。
3. **这个「选人 / 计数」需求 `Arasaka/utils.py` 有没有？**
   20 个选择器覆盖了低血、职责、带 buff、缺 buff、按层数、按驱散类型、批量计数。

### 17.2 想做什么 → 改哪里

| 我想…… | 改这里 | 关键写法 |
|---------|--------|----------|
| 加一个技能冷却像素 | `class/<职业>.lua` | `[N] = { type = "spell", name = "技能名" }`；无限服自动按名解析到已学会 rank，未学会写 255 |
| 加一个自身 buff **倒计时** | `core/auras.lua` + `class/<职业>.lua` | `["名字"] = { duration = 20, addAuras = { [spellID] = { event = e["施法成功"] } } }` + `[N] = { type = "aura", name = "…", auraName = "…", showKey = "remaining" }` |
| 加一个自身 buff **层数** | 同上 | `showKey = "count"`，条目里配 `count / countMin / countMax` |
| 加一个「有 / 没有」的状态 | `class/<职业>.lua` + `main.lua` | `[N] = { type = "block", name = "…" }`，在对应 `updateXxx()` 里 `CreatTexture(idx, 1 or 0)` |
| 加一个可切换开关 | `core/core.lua` + `core/quickbutton.lua` | `SwitchXxx()` 写像素 + `SaveConfig()`；按钮面板自动收录 |
| 加一个宏 | `class/<职业>.lua` 的 `MacrosList` | 普通技能进 `staticSpells`；`@raidN` 循环施放进 `dynamicSpells`（每个占 30 位）；完整宏体（`/castsequence`、`/startattack`）进 `specialSpells` |
| 读敌人数量 / 5 码敌人 | `main.lua:updateEnemyCount` | 已有 `state.enemyCount` / `state.enemyCount5y` → 像素 `敌人人数` / `5码敌人` |
| 读目标距离 | `main.lua:updateTargetRangeBlock`（LibRangeCheck） | 像素 `目标距离`，单位码 |
| 判断该不该放地面 AoE | `main.lua:updateEnemyCount` 的 `enemyCount5y` | 像素 `5码敌人`（48 号）= 姓名版里 ≤5 码且战斗中的人数；**依赖姓名版开启** |
| 读目标类型（敌对/友善） | `main.lua:updateTargetType` + `updateTargetValid` | `目标类型`：0 无/超距/死亡，1~10 敌对，11~20 友善 |
| 读队伍某人血量/职责/驱散 | `main.lua:updateUnitFullAura` + `blocks.groups` | Python 侧直接用 `state_dict["group"]` |
| 读药水 / 治疗石冷却 | `core/forever.lua` 的 `itemGroups` + `itemBlocks` | 像素名 `大红冷却` / `大蓝冷却` / `治疗石冷却`，物品 ID 两套客户端各一份 |
| 让某个技能不进冷却区显示 | `config.yml` 职业级 `probe_fields` | 只影响 GUI 显示，像素和决策数据不动 |
| 让某组字段单独一个 GUI 分区 | `config.yml` 职业级 `buff_fields` | 同上，读不到该键的一侧（旧 exe）也不受影响 |
| 加一条调试输出 | `core/forever.lua:PrintSpecDebug` | `/cy spec` 触发，**不要**塞进 `OnUpdate` 调用链 |
| 改 GUI 布局 | `logic_gui_Tools.py` | 三分区：`update_status_display` / `update_cooldown_display` / `update_buff_display` |
| 让插件在死亡/坐骑/打字/吃喝时不按键 | 已由调度层统一处理 | `logic_gui_Tools.py:585` 的 `if not sd.get("有效性"): continue`，无需在职业逻辑里加 |

### 17.3 已在跑的「轮子」（禁止重造）

| 能力 | 现成实现 | 位置 |
|------|----------|------|
| 施放成功后计时 N 秒 | 光环状态机（事件驱动，13 职业各一段） | `core/auras.lua` |
| 读自身 buff 剩余秒 | `C_UnitAuras.GetAuraDuration` + 颜色曲线 `curve255` | `main.lua:GetDefensiveAuraDuration` |
| 读光环实例 ID（兼容老客户端） | `F:GetAuraInstanceIDs`（先试 `GetUnitAuraInstanceIDs`，退回 `GetDebuffDataByIndex`） | `core/forever.lua:734` |
| 判断值是否为 secret | `issecretvalue(v)` | `main.lua:850` |
| 技能名 → 已学会 rank ID | `F:ResolveSpellID(name)`（法术书索引 + 离线表） | `core/forever.lua:159` |
| 专精判定（天赋树点数） | `F:GetActiveSpecIndex()` | `core/forever.lua:248` |
| 写像素 | `self:CreatTexture(index, value)` | `core/block.lua:41` |
| 近战平砍状态 | `PLAYER_ENTER_COMBAT` / `PLAYER_LEAVE_COMBAT` → `F.autoAttackOn` | `core/forever.lua:624` |
| 找低血队友 / 缺 buff 队友 / 驱散目标 | 20 个 `get_*` 选择器 | `Arasaka/utils.py` |
| 热键查找与发送 | `get_hotkey()` + `send_key_to_wow()` | `Arasaka/utils.py:50` / `:686` |
| 像素 → state_dict | `build_state_dict()`（含 spells 子字典、group 展开） | `Arasaka/GetPixels.py:302` |
| 决策层热重载 | `reload_logic_modules()` | `logic_gui_Tools.py:193` |
| 宏体创建 | `loadPlayerMacros()` → `CreateMacro()`（进入世界时一次，无手动命令） | `core/macro.lua:49` |

### 17.4 决策层内部小工具（`paladin_logic.py` 已定义，写新分支直接用）

| 函数 | 说明 |
|------|------|
| `_cd(spells, name)` | 取冷却值，`None` → 255（当作不可用） |
| `_ready(spells, name)` | `CD == 0` 的布尔简写 |
| `_int(state, key, default=0)` | 取整型状态，缺字段回默认 |
| `_is_enemy(目标类型)` | `1 <= 目标类型 <= 10`（敌对区间，别再写 `== 1`） |
| `_in_melee(距离, yards=10)` | 距离码 → 码数比较 |
| `_upkeep_ok(key, interval=None)` | 节流（默认按 `_UPKEEP_INTERVAL`，兜底 3 秒）。用于补 buff 和换印防抖，**别用在主力技能上** |
| `_seal_known(spells, seal)` | 该圣印是否已学会（探测像素 0 = 会 / 255 = 不会） |
| `_first_known_seal(spells, order)` | 按优先级取第一个已学会的圣印；全落空时退回 `order[0]`，宁可空按一次也不让圣印卡死 |
| `_prot_seal(spells, mana, current_seal, seal_remaining)` | 防护圣印选择：`<50%` 立即智慧；`≥50%` 且智慧未到期则保持；否则愤怒 |
| `_holy_seal(spells, mana)` / `_ret_seal(spells, mana)` | 神圣（`<35%` 智慧）/ 惩戒（`<25%` 智慧），本次未调整 |
| `_pick_dispel_unit(state_dict, 驱散开关)` | 魔法 > 疾病 > 中毒，内部已复用 `get_unit_with_dispel_type` |
| （非职业层）`有效性` | 死亡 / 坐骑中 / 打字中 / 吃喝中 → **调度层** `_run_logic_loop` 已 `continue`，13 个职业共享，职业逻辑里不要再判一遍 |

### 17.5 已知死代码 / 别照着抄

| 位置 | 状态 |
|------|------|
| `core/config.lua` 的 `noSecretAuras` | 定义了 30+ 条，**没有任何代码引用**。正式服治疗职业的设计，无限服不需要 |
| `spellsList` 里的正式服技能 ID | 606 条里无限服只存在一小部分；无限服技能一律走 `forever_data.lua` |
| 圣骑士 200-211 索引 | 已删（WLK/TBC/11.x 技能），其它职业仍按原样 |
| `staticSpells` 的 `/` 前缀判断 | **已回滚**。`staticSpells` 一律拼 `/cast`，完整宏体只能放 `specialSpells` |

### 17.6 重复造轮子的真实代价（本仓库踩过的坑）

| 症状 | 根因 | 正确做法 |
|------|------|----------|
| 每次进战斗重放圣印 | 自维护 `lastSealUntil`，战斗外扫描每 0.2 秒把它覆盖成 `now+2`，进战斗锁只剩 2 秒 | 用 `auras.lua` 的 `expirationTime`，只在施放成功时写 |
| 一个技能都不放 | 起手 `if 自动攻击 == 0` 放在战斗分支**最前面**，与后续共用 if/elif 链，一次为真挡死全部 | 兜底分支必须放**最后一个 elif** + 节流 |
| `/cy spec` 输出刷屏 | 跨行正则删代码时吞掉函数边界，把 `PrintSpecDebug` 的 print 并进了 0.2 秒循环 | 删代码用**行号**定位（先 `grep -n` 再按行切片），不要用 `.*?` 匹配缩进 `end` |
| 防护骑永远认为没挂圣印 | 把字段挪进 `buffs:` 子段，`state_dict["圣印"]` 消失 | 分组名单放**职业级**（`buff_fields` / `probe_fields`），字段位置不动 |
| 神圣之盾 CD 好了不补 | 节流设成 10 秒 = 盾的持续时间 | 有真 CD 的技能只看 `CD == 0`，不要叠加节流 |
| GUI 能打字、游戏按键失效 | 无边框窗口没加 `WS_EX_NOACTIVATE`，点一下就抢焦点 | 建窗时补 `0x08000000` |
| 部分怪一个技能都不放 | `_is_enemy` 写成 `目标类型 == 1`，而敌对带可驱散 buff 时是 2~10 | 判区间 `1 <= 目标类型 <= 10` |
| 脱战时角色自己按技能 | 把「维持圣印」写成无 `战斗` 条件的兜底分支，脱战也每 30 秒按一次 | 维持类分支一律加 `战斗 and`，脱战不做任何操作 |
| 面板显示队友血量变成「100s」 | 圣印剩余块落进了队伍块区间，两个 updater 抢同一像素 | 新块编号先算队伍块区间：`start=57`、`num=5` 时是 `58~207`，208 之后才安全 |
| 以为「打字时会乱按键」要加守卫 | 只 grep 了 `Arasaka/` 就下结论——调度层 `logic_gui_Tools.py:585` 早就有 `if not sd.get("有效性"): continue` | 查横切逻辑要连调度层一起看；职业逻辑里重复判反而会漂移 |

### 17.7 加完功能的自检顺序

```bash
# 1) Lua 语法（排除 Libs/）
node -e "require('luaparse') 遍历并 parse 所有 *.lua"

# 2) fengari 行为测试（需自备 fengari + forever_harness.lua）
HARNESS_DIR="<插件目录>" node run_lua.js forever_harness.lua

# 3) 决策链路测试（需自备 paladin_forever_test.py）
python paladin_forever_test.py
```

> 第 2、3 步的脚本是开发期验证工具，不随插件分发。
> 只想确认改动没坏，进游戏打 `/cy spec` 和 `/cy gui` 看像素即可。

全部通过再交付。只跑语法检查会漏掉「函数被吞并」「分支被挡死」这类结构性问题。

---

## 十八、许可与致谢

| 范围 | 许可 |
|------|------|
| 本项目代码（Lua 插件 + Python 决策层） | **MIT**，见 [LICENSE](LICENSE) |
| `core/forever_data.lua`（无限服技能离线表） | **GPL-3.0 + 署名**，数据来自 [ForeverDB.net](https://foreverdb.net)，再分发须保留文件头注释并注明来源 |
| `Libs/`（Ace3 系列、LibStub、LibRangeCheck-3.0） | 各自原作者的 MIT 许可，文件内保留原始声明 |

> ⚠️ **注意**：`core/forever_data.lua` 是 GPL-3.0 授权的数据。如果你要把本项目**整体**再分发或做成衍生作品，
> 该文件的部分需遵守 GPL-3.0；如果只想用 MIT，请删除该文件并自行实现技能表
> （删掉后无限服只能靠运行时扫法术书解析等级，部分天赋技能可能识别不到）。

**致谢**

- [Fuyutsui](https://github.com/waynebian01/Fuyutsui/) — 「像素编码 + 外部决策层」思路的早期参考
- [ForeverDB.net](https://foreverdb.net) — 无限服 1.60.1 技能数据
- [Ace3](https://www.wowace.com/projects/ace3) / [LibRangeCheck-3.0](https://www.curseforge.com/wow/addons/librangecheck-3-0) — 插件基础设施

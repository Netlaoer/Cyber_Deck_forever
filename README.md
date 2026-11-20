# Cyber Deck（赛博义肢）

**独立的 WoW 辅助决策插件**

> **施工中（WIP）** — 功能仍在迭代，像素索引、配置结构和存档格式随时可能调整。
>
> 当前为**无限服专用**版本：9 个职业全部有像素块布局与决策层。
> **圣骑士**已完整验证；其余 8 个职业的决策逻辑是**初版**（能跑、优先级合理，
> 但没经过实机校准），后续按需打磨。

<!--
AI_INSTRUCTION（AI 必读）：
1. 在修改此项目任何代码之前，请完整阅读本文件，理解整体架构、所有函数、编码约定和开发规范。
2. 本项目是一个 WoW 辅助决策系统，分为 Lua 插件层（游戏内）和 Python 决策层（外部程序）。
3. 核心原则：直接修改对应文件。Lua 端编辑 Cyber_Deck 目录下文件，Python 端编辑 Arasaka/ 下文件。
4. 完成代码修改后，必须同步更新本文件中对应的章节。
5. 像素块名称、状态字段、GUI 文本统一使用中文。
6. 新增像素块索引从 210 起（1~57 单体字段、58~207 队伍块、208~209 预留）。
7. **职业专属内容写在 `Progress/<职业>.md`**，不要写进本文件。本文件只放通用架构与机制。
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
- **无限服专用**：Lua 层只走本服路径（Interface 16001），无其它版本分支
- **9 个职业**：战士/圣骑/猎人/盗贼/牧师/萨满/法师/术士/德鲁伊，各有独立的像素布局与决策逻辑
- **零侵入操作**：`PostMessage` 后台发键，不抢焦点，可以边挂机边打字
- **热重载**：改完 Python 逻辑点一下 GUI「重载」即可，不用重启进程
- **可观测**：`/cy gui` 看像素原始值、`/cy spec` 看专精/技能解析、`/cy auraprobe` 探测哪些光环字段被 secret 保护、`/cy dispelprobe` 看驱散点位、`/cy dispelscan` 逐环诊断驱散链路、`/cy dispelpix` 看引擎染色探针状态

### 快速开始

| 项 | 要求 |
|---|---|
| 游戏 | 魔兽世界**无限服** 1.60.1（Interface 16001） |
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
├── Cyber_Deck.toc          # 插件定义（v0.1.0-forever，接口 16001）
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
│   ├── config.lua          # roleMap / events / keymap 等配置（无对应机制的表已清空）
│   ├── block.lua           # 像素色条创建（255个色块 + 法术充能进度条）
│   ├── macro.lua           # 动态宏创建（@raid/party 智能切换）
│   ├── keybinds.lua        # 扫描动作条按键绑定
│   ├── auras.lua           # 光环状态机（当前仅圣骑士段；其它职业按经典 ID 补即可）
│   ├── quickbutton.lua     # 四按钮可拖拽面板（爆发/AOE/输出模式/驱散）
│   └── Spell_Misc_EmotionHappy.blp  # 插件图标
│
├── class/                  # 职业模块（像素块布局 ClassBlocks）
│   ├── Paladin.lua         # 圣骑士 — 三系共用一套索引，含驱散开关/5码敌人/焦点施法宏
│   ├── Warrior.lua         # 战士   ┐
│   ├── Hunter.lua          # 猎人   │
│   ├── Rogue.lua           # 盗贼   │
│   ├── Priest.lua          # 牧师   ├ 9 个职业各一套布局：
│   ├── Shaman.lua          # 萨满   │ 通用块 1~15 + 状态块 18~28
│   ├── Mage.lua            # 法师   │ + 技能块 29 起 + 队伍块
│   ├── Warlock.lua         # 术士   │
│   └── Druid.lua           # 德鲁伊  ┘
│
├── main.lua                # 事件处理函数 + OnUpdate 帧循环
├── gui.lua                 # Ace3 配置界面（/cy gui 像素块调试）
│
├── Progress/               # 各职业的专属实现文档（9 份）
│   ├── paladin.md          # 圣骑士：像素索引/驱散能力表/专精判定/圣印机制/决策优先级
│   └── (warrior/hunter/rogue/priest/shaman/mage/warlock/druid).md
│
├── Arasaka/                # Python 决策层
│   ├── config.yml          # 像素块配置（按职业ID分段：1战士 2圣骑 3猎人 4盗贼 5牧师
│   │                       #   7萨满 8法师 9术士 11德鲁伊）
│   ├── utils.py            # 核心工具库（配置加载、按键发送、单位选择器）
│   ├── GetPixels.py        # 屏幕像素扫描引擎（mss 截图 + RGB 解码）
│   ├── check_dispel.py     # 驱散一键诊断（读真实像素 + 实跑决策层，不在生产路径上）
│   ├── class/              # 职业逻辑模块（9 个职业各一个）
│   │   ├── __init__.py
│   │   ├── paladin_logic.py   # 圣骑士（神圣/防护/惩戒三系，已完整验证）
│   │   ├── warrior_logic.py   # 战士（武器/狂怒/防护，初版）
│   │   ├── hunter_logic.py    # 猎人（野兽控制/射击/生存，初版）
│   │   ├── rogue_logic.py     # 盗贼（狂徒/敏锐/刺杀，初版）
│   │   ├── priest_logic.py    # 牧师（戒律/圣言/暗影，初版）
│   │   ├── shaman_logic.py    # 萨满（元素/增强/恢复，初版）
│   │   ├── mage_logic.py      # 法师（奥术/火焰/冰霜，初版）
│   │   ├── warlock_logic.py   # 术士（恶魔学识/毁灭/痛苦，初版）
│   │   └── druid_logic.py     # 德鲁伊（平衡/野性/守护，初版）
│   ├── keymap/             # 按键映射（keymap.yml 默认表 + 9 个职业各自的 yml）
│   │                       #   由 other/gen_class_keymap.py 从 class/*.lua 的宏表生成
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
5. `class/*.lua`（当前只有 `Paladin.lua`）
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

> 存档变量名：`CyberDeckADB`（`Cyber_Deck.toc` 的 `## SavedVariables`）。
> 旧名 `FuyutsuiADB` 与对应的迁移逻辑已移除 —— 插件已改名 Cyber Deck。

### 关键函数表

| 函数 | 所在文件 | 说明 |
|------|---------|------|
| `F:OnInitialize()` | core.lua | AceDB 初始化，注册 `/cy` 命令 |
| `F:OnEnable()` | core.lua | 获取专精、加载 blocks、注册事件 |
| `F:SwitchCooldown()` | core.lua | 打印爆发状态+写入像素（切换逻辑在 SlashCommand） |
| `F:SwitchAoeMode()` | core.lua | 打印 AOE 模式+写入像素（切换逻辑在 SlashCommand） |
| `F:SwitchDispel()` | core.lua | 切换驱散开关（含切换逻辑+打印+像素写入） |
| `F:OnUpdate(elapsed)` | main.lua | 帧循环（高频+低频轮询） |
| `F:updatePlayerConfig()` | main.lua | 初始化驱散开关等像素 |
| `F:updateEnemyCount()` | main.lua | 敌人计数（含 5 码姓名版、有光环敌人数） |
| `F:updateSpellKnown()` | main.lua | 生成防御/进攻驱散曲线点位（按已学会法术动态算） |
| `F:updateShapeshiftForm()` | main.lua | 形态（德鲁伊「姿态」块） |
| `F:updateTargetAuraCount()` | main.lua | 目标光环数量（牧师「目标光环数量」块） |
| `F:updateUnitAuraCount(unit)` | main.lua | 单位负面光环计数（通用，被上一条和敌人计数调用） |
| `CreatTexture(index, value)` | core/block.lua | 写入像素块（参数为索引号+数值） |
| `creatColorCurveScaling(b)` | main.lua | 非线性颜色曲线编码 |
| `InitQuickToggleButton()` | quickbutton.lua | 四按钮面板 |
| `updateAura()` | auras.lua | 光环倒计时 |
| `updateAuraBlocks()` | auras.lua | 光环像素更新 |

**斜杠命令**：`/cy help / cd / aoemode / potion / dispel / delay / gui / spec / auraprobe / dispelprobe / options / message`（完整表见「十四、调试技巧」）

完整命令列表：

| 命令 | 说明 |
|------|------|
| `/cy cd` / `cd on` / `cd off` | 切换/开启/关闭爆发 |
| `/cy aoemode` / `auto` / `aoe` | 切换/自动/单体 AOE 模式 |
| `/cy potion` / `on` / `off` | 切换/开启/关闭爆发药水 |
| `/cy delay [秒]` | 临时延迟逻辑（默认 1 秒） |
| `/cy dispel` / `on` / `off` | 切换/开启/关闭驱散 |
| `/cy gui` | 打开像素块调试界面 |
| `/cy spec` | 打印专精判定过程、招牌技能探测、离线技能表 |
| `/cy auraprobe` / `ap` | 探测哪些光环字段被 secret 保护 |
| `/cy dispelprobe` | 打印 4 种驱散类型的命中法术、曲线点位、各单位可驱散减益条数 |
| `/cy dispelscan`（`/cy ds`） | **驱散链路逐环诊断**：受限状态 / 玩家能驱的类型 / 每个 debuff 的 spellId 与 dispelName / 曲线求值 / 驱散像素索引 |
| `/cy dispelpix`（`/cy dpx`） | **引擎染色探针状态**：每个队友占色条第几格、容器建起来没 |
| `/cy options` / `config` | 打开 Ace3 选项界面 |
| `/cy message <文本>` | 聊天框测试 |
| `/cy help` | 打印帮助信息 |

> ⚠️ 无限服**没有**「一键辅助」，`/cy dpsmode` 与「输出模式」像素已移除。
> GUI 里的「输出模式」按钮名保留是为了不破坏已保存的 AceDB 变量名，无限服上该模式没有对应块。

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

### utils.py（25 个函数，写决策前先翻这里）

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

### 决策层内部小工具（**各职业自带一份**）

**9 个职业互不共用决策层工具** —— 每个 `Arasaka/class/<职业>_logic.py`
在文件顶部自带一套小工具，改一个职业不会影响其它职业。

> 没有 `battle_common.py` 这类公共模块。**要加能力就加在职业自己的文件里。**

每个职业的工具段大致是这样（按该职业实际用到的裁剪，不用的不带）：

```python
class Ctx(object):
    """一次决策的读数打包"""
    def __init__(self, state_dict, spec_name):
        self.spells = (state_dict or {}).get("spells") or {}
        self.spec = spec_name or ""
        self.hp = _int(self.sd, "生命值")
        self.melee = ...          # 目标在近战距离内
    def cd(self, name): ...      # 取冷却值
    def ready(self, name): ...   # CD == 0 的布尔简写
```

| 小工具 | 作用 |
|--------|------|
| `_cd(spells, name)` | 取冷却值，缺失 → `255`（不可用） |
| `_ready(spells, name)` | `CD == 0` 的布尔简写 |
| `_int(state, key, default=0)` | 安全取整数（缺失/非数字 → default） |
| `_is_enemy(目标类型)` | 敌对判定（**区间** `1~10`，不要写 `== 1`） |
| `_in_melee(距离, yards=10)` | 距离在近战范围内 |
| `_upkeep_ok(key, interval=3.0)` | 节流器：维持类操作（补 buff/换武器）防重复按 |
| `_reset_upkeep()` | 清空节流状态（换专精/重载时调） |
| `_pick_dispel_unit(state_dict, 驱散开关, types)` | 从队友里挑要驱散的目标，返回 `(槽位, 单位数据)` |

各职业实际带了哪几个，看对应 `Progress/<职业>.md` 的「内部小工具」表。

**冷却值约定**：`0` = 就绪，`1~254` = 冷却中（秒），`255` = 不可用。
**节流约定**：只用在「补 buff / 换印 / 换武器」这类维持类操作上，
**别用在主力技能上**（否则会错过该打的技能）。

---

## 八、状态数据结构

```python
state_dict = {
    # ── 全局 state 段 ──
    # config.yml 顶层 state，所有职业共用同一批字段。
    # 字段名 → step 号的对照见 config.yml 本身；这里是它读出来的样子。
    "有效性": bool,       # 玩家可操作（没死/没上马/不在聊天/没吃药）
    "战斗": bool,
    "移动": bool,
    "施法": int,          # 施法中
    "引导": int,          # 引导中
    "生命值": int,        # 玩家血量%
    "能量值": int,        # 玩家资源%（经典职业是法力）
    "法术失败": int,      # 被抵抗/打断的技能块索引，0=无
    "目标类型": int,      # 0=无/超距/死亡, 1~10=敌对, 11~20=友善
    "队伍类型": int,      # 0=单人, 1-40=团本
    "队伍人数": int,

    # ── 职业段 ──
    # config.yml 的 <职业ID>/<专精ID>。字段分两类：
    #   通用：所有职业都有的（下面列的是当前这批，各职业新增时沿用同名）
    #   专属：只有该职业有的（见 Progress/<职业>.md）
    "目标生命值": int,    # 目标血量%
    "施法技能": int,      # 正在施放的技能块索引
    "施法目标": int,
    "目标距离": int,      # 码
    "自动攻击": int,      # 1=平砍中
    "敌人人数": int,
    "爆发开关": int,      # 0/1
    "大红冷却": int,
    "延迟": int,
    "驱散开关": int,
    "5码敌人": int,
    "目标施法": int,
    # …职业专属字段若干，名字与 step 由该职业自己定

    # ── 其它 ──
    "职业": int,          # 职业 ID
    "专精": str,          # 专精名称
    "spells": { "法术名": 冷却值 },  # 0=就绪；键名 = 技能中文名
    "group": {
        "1": {                       # 键是队友序号 "1"~"30"
            "生命值": int,           # 血量%
            "职责": int,             # 1=坦克 2=治疗 3=输出 0=不计
            "驱散": int,             # 需要驱散的类型（1 魔法 2 诅咒 3 疾病 4 中毒 5=未知）
            # …该职业的队友追踪字段（光环秒数之类），由 group 段配置决定
        },
        ...
    },
    "auras": { "光环名": int },  # 光环状态
}
```

> **怎么知道某个字段属于哪一类**：全局 state 段在 `config.yml` 顶层，是所有职业共用的；
> 职业段在 `<职业ID>/<专精ID>` 下，各职业可以自由定义。
> **新增字段时三处同步**：Lua 块定义（`class/<职业>.lua`）→ `config.yml` 字段 → Python 读取。
> 用 `.workbuddy/check_integrity.py` 查断链。

### 关键约定

| 概念 | 说明 |
|------|------|
| 冷却值 | 0=就绪, 1~254=冷却中(秒), 255=不可用 |
| 目标类型 | 0=无/超距/死亡, 1~10=敌对, 11~20=友善（1/11 为基线，其余为可驱散细分） |
| 队伍类型 | 0=单人, 1-40=团本, 46=大秘 |
| 职业ID | 1=战士 2=圣骑 3=猎人 4=盗贼 5=牧师 6=DK 7=萨满 8=法师 9=术士 10=武僧 11=德 12=DH 13=唤魔师（无限服只有 1~5、7~9、11 存在） |
| 驱散类型 | 1=魔法 2=诅咒 3=疾病 4=中毒 **5=未知**（有减益但类型读不到，见下）；**各职业能驱的类型不同**，看 `Progress/<职业>.md` |

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
| `Arasaka/config.yml` | 圣骑士三系（spec 1/2/3）各一段：全局 state + 专精字段 + spells CD + `group(start:57, num:5)`（生命值/职责/驱散/圣光守望/圣光誓约） |
| `Arasaka/class/paladin_logic.py` | 三系决策：神圣（治疗/驱散/圣印）、防护（盾/圣印/审判/奉献）、惩戒（斩杀/圣印/驱散）。**优先级表见 `Progress/paladin.md`** |
| `Arasaka/keymap/paladin.yml` | 圣印与技能的热键映射（由 `other/gen_paladin_keymap.py` 生成） |

---

## 十、圣骑士定制详解

圣骑士是当前唯一完成适配的职业。它的**专属实现细节**（像素索引表、驱散能力表、
专精判定三层、圣印机制、三系决策优先级、按键映射、离线技能表）已移出到
**[`Progress/paladin.md`](Progress/paladin.md)** —— 新增职业时照着那份文件抄结构。

通用部分（驱散开关、四按钮面板、像素编码、事件机制）见下：

### 四按钮面板

| 按钮 | 功能 |
|------|------|
| 爆发 | 切换爆发开关 |
| 自动/单体 | 切换 AOE 模式 |
| 逻辑/辅助 | 切换输出模式（⚠️ 无限服无「一键辅助」，该模式没有对应块，是遗留 UI） |
| 驱散 | 切换驱散开关（同时改 Lua 像素和 Python 行为） |

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

> 无限服只有 9 个职业：战士 2=圣骑 3=猎人 4=盗贼 5=牧师 7=萨满 8=法师 9=术士 11=德鲁伊
> （6=DK、10=武僧、12=DH、13=唤魔师 在这个服务器上**不存在**）。
>
> **当前进度**：9 个职业全部有 `class/*.lua`（像素布局）+ `Arasaka/class/*_logic.py`
> （决策层）+ `Arasaka/keymap/*.yml`（热键）+ `Progress/<职业>.md`（职业文档）。
> 圣骑士是**完整验证过**的；其余 8 个是**初版**（能跑、优先级合理，未实机校准）。
>
> **决策层各写各的**：9 个职业的 `_logic.py` **互不共用工具代码**，
> 每个文件在顶部自带一套内部小工具（读数打包 / 冷却读取 / 区间判断 / 节流 / 驱散选人）。
> 改一个职业不会波及其它职业，代价是每个文件多几十行。
>
> 写新职业时照 `Progress/<职业>.md` 的「内部小工具」表抄一份即可。
>
> ⚠️ **无限服（1.60.1）的关键约束**：
> - 法术 ID 是**经典 ID**（4987 清洁术、1152 纯净术），用其它版本的 ID 一律无效
> - 60 级经典技能组，没有 11.x/12.x 的专精机制（beacon、圣光守望、充能系统…）
> - 玩家资源是**法力**（不是 11.x 的神圣能量）
> - `spellsList` 已删除；技能索引改由 `core/forever.lua` 的 `ResolveSpellID(name)` 按**技能名**解析

### Lua 端

1. **建 `class/NewClass.lua`** — 定义 `CyberDeck.ClassBlocks[classId]`
   - 块写法：`[索引] = { type = "block", name = "中文名" }`
   - 技能写法：`[索引] = { type = "spell", name = "技能中文名" }`（**用 name 不用 spellId**）
   - 光环写法：`[索引] = { type = "aura", name = "光环名", auraName = "光环名", showKey = "remaining" }`
   - 在 `Cyber_Deck.toc` 的 `class/` 段落注册新文件
2. **建/补 `core/auras.lua` 的该职业段** — 光环状态机条目
   - ⚠️ 必须用**经典 spellID**，其它版本的 ID 一律无效
   - 复杂光环（如圣印）参考圣骑士的「`MarkForeverAuraCast` + 不列 addAuras」做法
3. **补 `core/forever_data.lua`** — 该职业的离线训练师技能表（`{level, spellID}` 二元组）
   - 生成脚本：`Arasaka/other/gen_forever_spells.py`
   - 数据源：ForeverDB 1.60.1（来源署名勿删，见文件头）
4. **检查 `main.lua` 的通用块覆盖** — 若该职业需要通用块（如牧师的「目标光环数量」、
   德鲁伊的「姿态」），确认 `updateTargetAuraCount` / `updateShapeshiftForm` 的写入分支已覆盖
   （这两个函数是**跨职业通用件**，删了会缺数据）

### Python 端

1. **建 `Arasaka/class/newclass_logic.py`** — 实现 `run_newclass_logic(state_dict, spec_name)`
   - 返回 `(action_hotkey, current_step, unit_info)`，`action_hotkey = None` 表示无操作
   - `spec_name` 是中文专精名（"神圣"/"防护"/"惩戒"/…）
   - **文件顶部自带一套内部小工具**（`Ctx` / `_cd` / `_ready` / `_int` /
     `_is_enemy` / `_in_melee` / `_upkeep_ok` / `_pick_dispel_unit`）
     —— 照 `Progress/<职业>.md` 的「内部小工具」表抄，**各职业互不共用**
   - 单位选择器从 `Arasaka/utils.py` 直接 import（**25 个函数都在，别重复实现**）：
     `get_lowest_health_unit` / `get_lowest_health_unit_with_aura` /
     `get_lowest_health_unit_without_aura` / `get_lowest_health_unit_with_aura_count` /
     `get_unit_with_role` / `get_unit_with_aura` / `count_units_with_aura` /
     `count_units_without_aura_below_health` / `get_count_units_below_health` /
     `get_unit_with_dispel_type` …
2. **在 `Arasaka/config.yml` 添加职业段** — 顶层键是职业 ID（`2` = 圣骑士），下面按专精 ID 分段
   - 每段写：`{step, type}` 字段 + `spells: {技能名: {step, type}}` + `group: {start, num, ...}`
3. **建 `Arasaka/keymap/newclass.yml`** — 热键映射
   - 格式：`序号: {unit: 单位序号, 技能: "技能名", 热键: "按键串"}`
   - 生成脚本：`Arasaka/other/gen_class_keymap.py`（**已泛化**，不带参数则全量生成 9 个职业）
   - 它从 `class/*.lua` 的 `MacrosList` 反推热键表 —— 改完宏表要重跑：
     `python Arasaka/other/gen_class_keymap.py`
4. **在 `Arasaka/keymap/keymap.yml` 注册**新职业的 keymap 文件名

### 验证清单

```
✓ luac -p <所有 lua 文件>                       # 语法
✓ py_compile <所有 py 文件>                    # 语法
✓ yaml.safe_load(config.yml)                   # 配置
✓ check_class_integration.py  四方一致（class↔config↔keymap↔logic）
✓ check_integrity.py          五维交叉校验（像素↔config↔Python↔事件↔宏）
✓ check_readme.py             文档与代码一致
✓ /cy spec  看专精判定、技能书解析、法术 ID    # 游戏内
✓ /cy gui    看像素原始值是否与索引表一致      # 游戏内
```

**静态交叉校验脚本**：

| 脚本 | 检查什么 |
|------|---------|
| `check_class_integration.py` | **四方一致**：`class/*.lua` ↔ `config.yml` ↔ `keymap/*.yml` ↔ `*_logic.py`（9 职业逐个查） |
| `check_integrity.py` | 五维交叉校验（**多职业版**）：像素↔config 字段按 step 对齐、Python 读的字段↔config 声明、注册事件↔处理函数、宏↔keymap 热键 |
| `check_readme.py` | 文档与代码一致（数字声明、职业文档存在性、无用件残留检查） |
| `audit_redundancy.py` | 单文件未使用 import/函数/常量/变量 + 注释密度 |
| `audit_crossfile.py` | 跨文件确认（单文件分析会把「被 import 的函数」误报成死代码） |
| `audit_wrong_deletion.py` | 误删审计：把 git HEAD 的删除逐条对照「无限服 9 职业是否存在」判定 |

---

## 十三、开发规范

### 通用规则

1. **直接修改**：所有功能直接编辑对应文件
2. **中文命名**：像素块、状态字段、GUI 文本
3. **像素索引**：新增从 210 起。1~15 是全局 state、57 是队伍块起点、58~207 是队伍块
   （`start=57`、`num=5` 时），**208 之后才安全** —— 新块编号先算队伍块区间，别撞进去
4. **SavedVariables**：新增字段在 `core/core.lua` 的 `defaults.char` 注册

### Lua 端规则

- 技能块用 `name`（技能中文名）**不要用 `spellId`** —— 无限服同技能多 rank，由
  `core/forever.lua:ResolveSpellID(name)` 解析到已学会的 rank
- 光环 ID 必须是**经典 ID**；`core/auras.lua` 里其它版本的 ID 一律无效
- 注释用**单排**形式（注释在条件上一行），不用尾注释
- 中文变量名 + 中文注释

### Python 端规则

- 职业逻辑返回 `(action_hotkey, current_step, unit_info)` 三元组
- 优先使用 `utils.py` 工具函数（**25 个都在**，别重复实现，也别删）
- 修改后点击 GUI"重载"生效

### 常见陷阱

- **elif 链无法回退**：跳过某优先级需在调用前修改 `state_dict`
- **兜底分支必须放最后**：放最前面会让后面全部 elif 被挡死
- **线程安全**：访问 `_state_dict` 注意 `_state_lock`
- **TOC 顺序**：`core/*.lua` → `class/*.lua` → `main.lua` → `gui.lua`
- **模块缓存**：热重载需 `importlib.reload()`
- **删代码用行号定位**：不要用 `.*?` 匹配缩进 `end`（会吞掉函数边界）
- **通用工具函数不要按「当前是否被调用」判断死活**：见 17.5 的四类判定标准

---

## 十四、调试技巧

### 全部斜杠命令（`/cy` / `/cyberdeck`）

> 命令别名：`/cy` 和 `/CyberDeck`（大小写不敏感）。
> 旧版的 `/fu` 已移除 —— 插件已改名 Cyber Deck，不再兼容老命令。

| 命令 | 作用 |
|------|------|
| `/cy help` | 打印命令列表 |
| `/cy cd` / `cd on` / `cd off` | 爆发开关（切换 / 开 / 关） |
| `/cy aoemode` / `auto` / `aoe` | AOE 模式（切换 / 自动 / 单体） |
| `/cy potion` / `on` / `off` | 爆发药水开关 |
| `/cy dispel` / `on` / `off` | 驱散开关（同时改 Lua 像素和 Python 行为） |
| `/cy delay [秒]` | 临时暂停决策 N 秒（默认 1 秒，用于手动插技能） |
| `/cy gui` | 像素块调试界面 |
| `/cy spec` | 专精判定 / 技能解析 / 招牌技能探测三态 / 各技能 CD |
| `/cy auraprobe`（`/cy ap`） | 光环字段可读性探测（逐字段试读），见下方 |
| `/cy secrets`（`/cy sec`） | secret 上下文探测（问客户端 `C_Secrets` 谓词），见下方 |
| `/cy dispelprobe`（`/cy dp`） | 驱散能力探测：4 种类型的命中法术 / 曲线点位 / 各单位可驱散减益条数 |
| `/cy options` / `/cy config` | Ace3 选项面板 |
| `/cy enable` / `/cy disable` | Ace3 启用/停用插件本体 |
| `/cy macro` | 打印当前宏列表 |
| `/cy dpsmode` / `manual` / `assistant` | 输出模式切换 ⚠️ **无限服无「一键辅助」，对应像素已删除，命令保留只是不生效** |
| `/cy message 文本` | 聊天框测试输入 |

### 其它调试手段

- `/script SetTestSecret(0)` — 关闭秘密值限制（启动时默认 `SetTestSecret(1)` 开启）
- `Arasaka/other/GetRGB.py` — 获取像素 RGB
- `Arasaka/other/GetInfo.py` — 打印 state_dict
- `Arasaka/other/hex_to_decode.py` — 十六进制解码
- GUI「重载」按钮 — 热重载 Python 模块

### secret 探测（写治疗职业前先跑一次）

> ⚠️ **1.60.1 带 Secret Values 机制**（不限于某个版本）。
> 客户端自带 `C_Secrets` API，Decursive / EllesmereUI / SpellActivationOverlay 都在用。

#### `/cy secrets` —— 问客户端「现在什么会变 secret」（推荐先跑这个）

`C_Secrets` 的谓词能**直接问**当前上下文里某一类数据会不会变成 secret 值，
比逐字段试读准得多 —— 试读只能告诉你「这一次读到了什么」，
谓词能告诉你「什么时候会变」。

| 谓词 | 管的什么 |
|------|---------|
| `ShouldAurasBeSecret()` | 光环数据（名字/层数/剩余时间） |
| `ShouldCooldownsBeSecret()` | 冷却 |
| `ShouldUnitIdentityBeSecret(unit)` | 单位名字/身份 |
| `ShouldUnitStatsBeSecret()` | 单位属性 |
| `ShouldUnitThreatValuesBeSecret(unit, target)` | 威胁值 |
| `ShouldUnitSpellCastingBeSecret(unit)` | 施法信息 |
| `ShouldUnitHealthMaxBeSecret(unit)` | 血量上限 |
| `ShouldUnitPowerBeSecret(unit, powerType)` | 能量 |
| `ShouldSpellAuraBeSecret(spellID)` | 单个法术的光环是否 secret（**返回布尔**） |
| `GetSpellAuraSecrecy(spellID)` | 单个法术的光环保密等级（**返回 `Enum.SecrecyLevel` 枚举**） |
| `CanCompareUnitTokens(a, b)` | `UnitIsUnit` 会不会返回 nil（不是变 secret，是直接不给答案） |
| `IsAddOnRestrictionActive()` | 当前是否处于地图限制（副本/战场/竞技场） |

`Enum.SecrecyLevel` 三档：
- `NeverSecret` —— 任何时候都能读（Decursive 只把这类法术加进跳过列表）
- `ContextuallySecret` —— 视上下文而定（战斗/地图限制触发）
- `AlwaysSecret` —— 永远是 secret（暴雪单独标记的法术）

**用法**：脱战跑一次 `/cy secrets`，战斗中再跑一次，**对比两组的差异**——
差异项就是「战斗中会变 secret」的部分。写完新职业后对着这个清单检查你的读取路径。

#### `/cy auraprobe` —— 逐字段试读

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

`core/forever.lua` 与各职业的 `class/*.lua`、`Arasaka/class/*_logic.py`、
`Arasaka/keymap/*.yml`、`Arasaka/config.yml` 的职业段均已改为无限服版本。
职业专属细节见 `Progress/<职业>.md`。

> **无对应机制的分支全部移除**：`C_SpecializationInfo` / `rangeSpecID` /
> `spellsList` / `heroTalents` / `bossID` / `difficutlyToText` / `noSecretAuras` /
> `C_AssistedCombat` / 蓄力 / `C_Scenario` 首领战 / `ENCOUNTER_*` 事件 / 切天赋法术 ID
> 全部删除，`Cyber_Deck.toc` 锁定 `## Interface: 16001`。
> 插件是**本服专用**，在其它客户端上不会加载。

### 判定与降级

| 项 | 无限服的做法 |
|----|------------|
| TOC 接口 | `## Interface: 16001` |
| 专精 | 每职业一个伪专精（各职业 ID 不同），真实定位看天赋 → `F:GetActiveSpecIndex()`：**优先**用专精天赋节点（见下），读不到再依次退回树名 → 经典天赋树 → 技能探测 → treeIDs 顺序 |
| 技能 | 同一技能多个 rank → `F:ResolveSpellID(name)`：先用 `core/forever_data.lua` 离线表取“已学会的最高 rank”，再用法术书兜底（覆盖天赋技能）；未学会写 255 |
| 英雄天赋 / 一键辅助 | 无此机制，**像素与代码已删除** |
| 蓄力 / 首领战 / 难度 | 无此机制，**像素与代码已删除** |
| 药水 | `F.itemGroups` 用经典物品 ID（决策层暂不自动喝药，只上报冷却） |
| 法力 | 无限服恒按百分比写 10.能量值 |
| 「施法技能」「法术失败」像素 | 查 `blocks.spells[spellId].index`（由 `ResolveSpellID` 建好的映射） |

### 专精判定（通用机制）

无限服每职业只有一个伪专精，真实定位看天赋。
三层降级：**traitNode 探针** → **招牌技能探测** → **treeIDs 顺序**。

各职业的具体探针节点和招牌技能见对应职业文档
（当前：[`Progress/paladin.md`](Progress/paladin.md)）。

> ⚠️ **treeIDs 顺序这层不可靠** —— 无限服 `C_Traits.GetTreeInfo` 拿不到天赋树中文名
> （`树[1] id=1100 name=nil`），只能按 treeID 顺序猜，实测会把点数堆到第 1 位。
> 补齐 treeID→专精 映射后可以**直接按树判定专精，完全不依赖天赋**。

### 离线技能表（core/forever_data.lua）

每个职业一段 `{学习等级, spellID}` 训练师技能（1–60 级），格式 `{level, spellID}`。
9 个职业全都有（合计 1314 条）：战士 98 / 圣骑 140 / 猎人 122 / 盗贼 90 /
牧师 207 / 萨满 164 / 法师 157 / 术士 146 / 德鲁伊 190。

- 生成：`python Arasaka/other/gen_forever_spells.py`（自动拉 ForeverDB manifest 并校验 sha256）
- 中文名不写死：运行时 `C_Spell.GetSpellInfo(spellID).name` 取，自动跟随客户端语言
- 作用：同一技能多个 rank 时，**按等级从高到低**找第一个 `IsSpellKnown` 的，比扫法术书的「后写覆盖」准
- 天赋技能不在训练师表里，仍由法术书补
- 来源署名：**Data from ForeverDB.net**（GPL-3.0 section 7(b)，勿删文件头注释）

#### 命令行查询工具（免 key，直接查 spellID）

```bash
python Arasaka/other/query_forever.py 4987          # 查法术：等级、名称、效果
python Arasaka/other/query_forever.py 4987 --json   # 输出结构化 JSON
python Arasaka/other/query_forever.py --search Purify   # 按名字搜
python Arasaka/other/query_forever.py --build       # 对比本地客户端 vs 数据源 build
```

免 key 时走 `wow-forever.gg` 网页抓取，输出人类可读摘要：

```
spellID 4987
  网页    Cleanse is a Paladin ability in WoW Forever, learned at level 42: Holy school.
  网页    removing 1 poison effect, 1 disease effect…
  详情页  https://wow-forever.gg/db/spells/4987
```

**想要完整结构化数据就申请 API key**（免费额度 5000 次/天、30 次/分钟）：

| 项 | 说明 |
|----|------|
| 申请 | https://foreverdb.net/developers （用 Battle.net 登录，在账户 access box 里申请） |
| 认证 | `X-API-Key: fdb_xxx` header，或 `Authorization: Bearer fdb_xxx` |
| 基础地址 | `https://api.foreverdb.net`（**不要**用主站域名，会被机器人检查拦） |
| 查单个法术 | `GET /api/v1/spells/{id}` |
| 搜法术 | `GET /api/v1/spells?q={关键词}&limit=10` |
| 查物品 | `GET /api/v1/items/{id}` ／ 搜 `GET /api/v1/items?q=&quality=&class=&minLevel=` |
| 查职业 | `GET /api/v1/classes/{name}`（如 `warrior`） |
| 查天赋 | `GET /api/v1/talents` |
| 查版本变更 | `GET /api/v1/builds/latest` ／ `GET /api/v1/builds/{build}?type=ability&class=paladin&change=changed` |
| 接口目录 | `GET https://api.foreverdb.net/api/v1`（**不需要 key**，返回全部端点） |
| 多语言 | 加 `lang=zh-CN` / `lang=de` / `lang=fr` |

给工具配 key：设环境变量 `FOREVERDB_API_KEY=fdb_xxx`。

> ⚠️ **免费额度必须署名**：展示数据的地方要有
> `<a href="https://foreverdb.net">Data from ForeverDB.net</a>`，否则 key 可能被撤销。
> **别把 key 打进公开发布的插件里** —— 官方建议由自己服务器调 API 再分发数据。

#### 直接可查的网址（收藏用）

| 想查什么 | 网址 | 备注 |
|---------|------|------|
| 单个法术（**最常用**） | `https://wow-forever.gg/db/spells/{spellID}` | 免 key。含等级/学派/法力/射程/施法时间/**驱散效果**/各 rank 链接 |
| 法术按名字找 | `https://wow-forever.gg/db/spells/?search={关键词}` | |
| 某职业全部法术 | `https://wow-forever.gg/classes/paladin/` | 9 个职业都有；也有 `/talents/paladin/` 天赋树 |
| 天赋模拟器 | `https://wow-forever.gg/talents/paladin/` | 能看专精归属 |
| 单个物品 | `https://foreverdb.net/items/{itemID}` | |
| 物品搜索 | `https://foreverdb.net/items?q={关键词}` | |
| **无限服 vs 经典旧世差异** | `https://foreverdb.net/datamine` | 「Forever 改了什么」的权威汇总 |
| 单个法术的版本变化史 | `https://wow-forever.gg/db/spells/{spellID}` 页面底部 | 每个 build 的数值变化 |
| 玩家实测掉落/价格 | `https://foreverdb.net/seen-in-game` | 标注 Verified / Not confirmed |
| 职业法术一览（**中文**） | `https://endgametools.com/zh-CN/wow-forever/spells` | 按职业列 1~60 级每个法术 |
| 无尽数据库（中文） | `https://wowforever.wclbox.com/` | 天赋/法术/物品/地图，逐条对照经典 |
| 英文深度档案 | `https://bindonforever.com/` | 每条数据标注来自哪个 build |

#### 数据源怎么选（各站点的权威性）

**最权威的源头是游戏客户端本身** —— 无限服客户端里的数据表（DBC / Spell.dbc）就是一切的事实。
下面这些站点都是从客户端提取的，区别只在「提取频率、呈现形式、许可条款」：

| 站点 | 数据来源 | 特点 | 适合 |
|------|---------|------|------|
| **ForeverDB.net**（当前用的） | 每个 build 从客户端提取 + 重建 | 有 `addon-manifest.json`（含 **sha256 校验**）+ 原始 `Spells.lua`；另有 API 和玩家上传的实测数据 | 自动化生成、需要 sha256 校验、许可清晰 |
| **endgametools.com/wow-forever** | 直接读客户端 | 中文界面，按职业列出 1~60 级每个法术及等级/消耗/射程/施法时间/冷却；标注 build 版本 | 人工查证某个法术在几级学 |
| **wowforever.wclbox.com** | 直接读客户端 | 天赋/法术/物品/地下城/世界地图，逐条与经典旧世对照 | 查「无限服改了什么」 |
| **bindonforever.com** | 每个 build 读客户端 + 对照暴雪公告 | 每条数据都标注来自哪个 build、来自文件/服务器/实测 | 查数值改动历史 |
| **wow-forever.gg/db/spells/** | 客户端 + 版本历史 | 单个法术一页，含各 build 的数值变化 | 查某个法术的版本差异 |
| **游戏内运行时**（`C_SpellBook` / `C_Spell`） | 服务器实际下发的数据 | **绝对权威**，服务器改了立刻生效 | 判断「你这个号实际会学到什么」 |

> ⚠️ **离线表只是补充，不是真相**。
> 离线表的唯一价值是「等级 → rank」的映射关系（运行时扫法术书拿不到这个映射），
> 具体的「学没学到」永远以 `C_SpellBook.IsSpellKnown(spellID)` 为准。
>
> **离线表会落后于客户端**：服务器每次热修都会改客户端文件。生成脚本会自动从
> `Meta.lua` 读当前 build 号写进文件头 —— 看到文件头的 build 和客户端 `Wow.exe` 版本
> 对不上，就重跑一次生成脚本。

### secret 值机制（无限服 1.60.1 也有）

本服**不是**没有 secret 机制 —— 它带 Secret Values 系统（客户端自带 `C_Secrets` API）。
受影响的类别：**光环、冷却、单位身份（名字）、属性、威胁值、施法信息、血量上限、能量**。

受限上下文（战斗 / 副本 / 战场 / 竞技场）下这些值会变成「不可比较、不可运算」的 secret 值。
判定方式与调试命令见「十四、调试技巧 → secret 探测」。

| 判定手段 | 说明 |
|---------|------|
| `C_Secrets.ShouldXxxBeSecret()` | **权威**：直接问「当前上下文会不会变 secret」 |
| `C_Secrets.GetSpellAuraSecrecy(spellID)` | 单个法术的保密等级（`NeverSecret` / `ContextuallySecret` / `AlwaysSecret`） |
| `issecretvalue(v)` | 事后判断「这个值已经是 secret 了」 |
| `C_Secrets.CanCompareUnitTokens(a, b)` | `UnitIsUnit` 是否还能用（不能用时返回 nil，不是 secret） |

> ⚠️ `UnitCreatureType` 在地图限制下返回 secret 值 → **不能做 `==3` / `==6` 判断**
> （亡灵/恶魔检测因此不可靠，客户端的 SpellActivationOverlay 也是用 `canaccessvalue` 兜底的）。

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
| 增益状态 | config 职业级的 `buff_fields` 名单 | 255 = 有 / 0 = 没有（有的显示名称，有的显示剩余秒） |

「有 buff 就写 255」型字段在「实时状态」区容易被误读成「不可用」——
实际它们是 `0/1` 写入后乘以 255 的结果，**255 表示 buff 存在**。移进独立分区并翻译成
`有/无` 后，两种 255 不再混在一起。

名单放在**职业级**（`config[class]["buff_fields"]`），不在专精级：
`build_state_dict()` 只处理带 `step` 的字段、旧版打包 exe 只读专精段，两边都不会碰到它，
所以这份名单只影响 GUI 分组，对决策和兼容性零风险。没有名单的职业该分区自动隐藏。

同一位置还有 `probe_fields`（探测块名单），这些块**不参与冷却显示**：

```yaml
  probe_fields: [<该职业的「是否学会」探测块>, ...]
```

探测块的像素含义是 `0 = 已学会 / 255 = 未学会`，不是剩余秒数。它们留在冷却区会直接误导
（例如某个 buff 明明挂着、提示框写着「剩余 27 秒」，面板却显示 `X: 0`）。
`get_class_spec_view_data()` 把它们从 `spells_list` 里过滤掉，像素和决策层数据完全不动。

> ⚠️ **名字带 `CD` 后缀的不一定是探测块** —— 有真实冷却的技能（`XXXCD`）长得像探测块，
> 但必须留在冷却区显示。区分依据是**这个技能到底有没有真实冷却**，不是名字长相。
> 各职业的探测名单见 `Progress/<职业>.md`。

### 9 个职业的现状

| 职业 | 职业 ID | 像素布局 | 决策层 | keymap | 职业文档 | 实机验证 |
|------|-------|---------|--------|--------|---------|---------|
| 圣骑士 | `2` | ✓ | ✓ 已完整验证 | ✓ | [paladin.md](Progress/paladin.md) | **已完整验证** |
| 战士 | `1` | ✓ | ✓ 初版 | ✓ | [warrior.md](Progress/warrior.md) | 未校准 |
| 猎人 | `3` | ✓ | ✓ 初版 | ✓ | [hunter.md](Progress/hunter.md) | 未校准 |
| 盗贼 | `4` | ✓ | ✓ 初版 | ✓ | [rogue.md](Progress/rogue.md) | 未校准 |
| 牧师 | `5` | ✓ | ✓ 初版 | ✓ | [priest.md](Progress/priest.md) | 未校准 |
| 萨满 | `7` | ✓ | ✓ 初版 | ✓ | [shaman.md](Progress/shaman.md) | 未校准 |
| 法师 | `8` | ✓ | ✓ 初版 | ✓ | [mage.md](Progress/mage.md) | 未校准 |
| 术士 | `9` | ✓ | ✓ 初版 | ✓ | [warlock.md](Progress/warlock.md) | 未校准 |
| 德鲁伊 | `11` | ✓ | ✓ 初版 | ✓ | [druid.md](Progress/druid.md) | 未校准 |

**每个职业的决策层互不共用工具代码** —— 各自的文件顶部自带一套内部小工具
（读数打包 / 冷却读取 / 区间判断 / 节流 / 驱散选人），改一个职业不影响其它 8 个。

**其它 8 个职业的决策层是初版** —— 能跑、优先级合理，但没经过实机校准。
接的时候按这个顺序打磨：先跑 `/cy spec` 确认专精判定，再打 BOSS 看技能选择对不对。

每个职业的 `Progress/<职业>.md` 里有：像素索引表、技能与块索引对照、
**内部小工具表**、**决策优先级表（技能 + 触发条件 + 限定专精 + 节流）**、
阈值常量、待办清单。

被移除的 4 个职业（死亡骑士 / 恶魔猎手 / 唤魔师 / 武僧）在这个服务器上不存在，不要加。

**技能名的来源**：`class/*.lua` 里的技能用**中文名**（不写 spellId），
由 `core/forever.lua:ResolveSpellID(name)` 在运行时解析到「已学会的最高 rank」。
中文名 + 等级清单抓自 endgametools 的无限服职业法术页。

**改完职业相关代码后跑这几个校验**：

```bash
python .workbuddy/check_class_integration.py   # class ↔ config ↔ keymap ↔ logic 四方一致
python .workbuddy/check_integrity.py            # 五维交叉校验
python .workbuddy/check_readme.py               # 文档与代码一致
```

改宏表后要重生成 keymap：`python Arasaka/other/gen_class_keymap.py`

---

## 十六点五、驱散机制

驱散就一件事：**把「队友身上有哪种可驱减益」画进像素，Python 侧据此选人施法。**

### 脱战时：Lua 读光环，算出类型，写进像素

```lua
-- main.lua
local function readDispelType(unit)
    local ids = CyberDeck:GetAuraInstanceIDs(unit, "HARMFUL|RAID_PLAYER_DISPELLABLE", 40)
    if ids == nil then
        return nil, "受限"          -- 读不到（光环被 secret 化）
    end
    if #ids == 0 then
        return nil, "ok"             -- 确实没有可驱减益
    end
    local b = pickTypeByCurve(unit, ids, dispelCurve)   -- 曲线求值
    if b then
        local t = math.floor(b * 255 + 0.5)            -- 蓝通道 = 类型号
        if t > 0 and t < 10 then return t, "ok" end
    end
    return DISPEL_TYPE_UNKNOWN, "ok"   -- 读得到光环但类型算不出来 -> 类型未知
end

local function getAuraDispelTypeColor(unit)
    local index = blocks.groups.start + (obj.index - 1) * blocks.groups.num + blocks.groups.dispel
    local t, st = readDispelType(unit)
    if st == "受限" then
        -- 读不到（战斗中光环被 secret 化）：**不写这一格**。
        -- 引擎会把 debuff 类型直接染到这一格上，写 0 会盖掉它。
        return
    end
    CyberDeck:CreatTexture(index, t and t / 255 or 0)
end
```

色条第 i 格的编码是 `(0, i/255, value)` —— **绿=索引、蓝=值、红=0**，
Python 侧 `row_data[g] = b` 直接读走。

> ⚠️ **「读不到」必须和「没有」分开**：
> 受限时**不能往那一格写 0**，否则会盖掉引擎染上去的正确值。
> 早期版本 `readDispelType` 用 nil 同时表示两种情况，导致战斗中驱散时好时坏
> （2026-11-21 踩过）。

### 唯一的问题：无限服在战斗中把光环 secret 化

`C_UnitAuras.*` 全部读不到（抛 secret 错误 / 返回 nil 被扣留），
所以 `readDispelType` 在战斗中返回 nil → 那一格写 0 → **不驱散**。

实测确认（2026-11-21，无限服 1.60.1）：

| 通道 | 战斗中 | 证据 |
|------|--------|------|
| 索引型光环 API | ❌ 抛 secret 错误 | `Auras cannot be accessed when secret` |
| 按 ID / 名字查询 | ❌ 返回 nil（被扣留） | 与「没有这个 debuff」无法区分 |
| UNIT_AURA 的 payload | ❌ 字段全是 secret | `addedAuras` / `isFullUpdate` 都读不到 |
| AuraContainer 的 slot | ❌ forbidden | 对受保护 button 调方法会被拒 |
| `SetApplicationBar` 数值 | ❌ forbidden | |
| `initializeFrame` 回调次数 | ❌ 只在创建时触发一次 | 不是内容信号 |
| NeverSecret 光环 | ❌ 全是 ContextuallySecret | 24 个经典 debuff 逐个查过 |
| tooltip 类光环 API | ❌ 客户端没有 | `C_TooltipInfo` 只有物品/法术 |

### 解法：**还是画进色条，只是「画」这一步改由引擎代劳**

客户端自带的 Decursive 在受限（`DC.RESTRICTED_AURAS`）时就是这么干的
（`Dcr_DebuffsFrame.lua:1168`）：**把一块我们自己创建的纹理交给引擎**，
引擎按光环的驱散类型给它染色 —— **引擎侧操作，插件全程不读光环数据，所以不受限**。

```lua
-- 在 initializeFrame 回调（创建窗口）里
local tex = ab:CreateTexture(nil, "OVERLAY")
tex:SetPoint("TOPLEFT", UIParent, "TOPLEFT", cellX, cellY)   -- 精确落在色条那一格
tex:SetSize(cellW, cellH)
tex:SetColorTexture(1, 1, 1, 1)                             -- ⚠️ 白色，见下
ab:ClearDispelTypeTextures()
ab:AddDispelTypeTexture(tex, {
    showIcon = false,
    style = Enum.CustomAuraButtonDispelTypeTextureStyle.PreserveAsset,
    customDispelColorCurve = curve,     -- 类型 -> (0, 索引/255, 类型/255)
})
```

曲线按**色条索引**各建一条（绿通道要编码索引）：

```lua
curve:AddPoint(0, CreateColor(0, cell / 255, 0, 1))            -- 无 debuff
for t = 1, 4 do
    curve:AddPoint(t, CreateColor(0, cell / 255, t / 255, 1))   -- 魔法/诅咒/疾病/中毒
end
curve:AddPoint(5, CreateColor(0, cell / 255, 5 / 255, 1))      -- 其它类型 = 未知
```

**像素编码统一是 `(0, 索引/255, 类型/255)`** —— 无论脱战（Lua 写）还是
战斗中（引擎染），Python 侧读的都是同一根色条、同一套编码，
**Python 端一行都不用改**。

| 上下文 | 谁算出类型 | 谁来画 |
|---|---|---|
| 脱战 | Lua 读光环 → 曲线求值 | Lua `CreatTexture(格索引, t/255)` |
| 战斗中（受限） | **引擎**按光环类型判定 | 引擎染色条上那一格的纹理 |

### 三个必须记住的坑

**① 模板必须先加载**

```lua
LoadAddOn("Blizzard_AuraContainer")   -- 不加载的话 CreateFrame 出来的只是普通 frame
```

不加载 → `AddAuraSlot` 是 nil → 探针压根建不起来 → 那一格永远是 Lua 写的值
→ 战斗中读到 0 → **从不驱散**。（2026-11-21 踩过）

**② 纹理必须是白色**

颜色**全部由曲线提供**。若纹理自带颜色，引擎若是用「乘法」把曲线色乘上去，
结果会被压成全黑（实测：纹理 `(0, 索引/255, 0)` × 曲线 `(0, 索引/255, 类型/255)`
= `(0,0,0)`）→ 那一格全黑 → Python 读到驱散=0。
白色纹理无论引擎是「设置」还是「相乘」都正确。

**③ 曲线的 x 轴是类型原始值**

x = 1魔法 / 2诅咒 / 3疾病 / 4中毒（Decursive 的 `DC.DTtoBT` 与本插件一致），
**不是**归一化的 `t/255`。实测引擎取 Disease 时精确落在 x=3 那点。

### 第二层：驱散技能必须走动态宏

驱散要按队友施放 → 必须走 `dynamicSpells`（`@raidN`）。
放 `staticSpells` 的后果很隐蔽：静态宏在 keymap 里只有 `unit: 0`，
而 Python 侧是 `get_hotkey(队友槽位, "驱散技能")` → **查不到该队友的热键 → 返回 None → 不驱散**，
而且不报任何错。

```lua
-- class/Priest.lua
dynamicSpells = { "驱散魔法", "祛病术" },   -- ✓ 按队友施放
-- staticSpells 里不能放驱散技能
```

### 第三层：驱散能力表要按实际法术填

`DISPEL_TYPES` 决定「本职业能驱哪些类型」，填错会导致**选错人**或**永远匹配不到**：

| 职业 | `DISPEL_TYPES` | 无限服实际法术 |
|------|----------------|---------------|
| 圣骑士 | `(1, 3, 4)` | 清洁术 4987（魔法/疾病/中毒）、纯净术 1152（疾病/中毒） |
| 牧师 | `(1, 3)` | 驱散魔法 527（魔法）、祛病术 988（疾病） |
| 萨满 | `(2, 3)` | 净化术 526（诅咒）、祛病术 2870（疾病） |
| 德鲁伊 | `(2, 4)` | 解除诅咒 2782（诅咒）、驱毒术 8946（中毒） |
| 法师 | `(2,)` | 解除次级诅咒 475（诅咒） |
| 战士 / 猎人 / 盗贼 / 术士 | `()` | 无驱散技能 |

### 排查顺序

```bash
/cy dispelpix       # 引擎染色探针：每个槽位指向谁、色条第几格、AddAuraSlot 成功没
/cy dispelscan      # 驱散链路逐环诊断（战斗中跑一次，脱战再跑一次对比）
/cy dispelprobe     # 驱散能力探测（点位 = 写进像素的驱散类型）
```

**Python 侧一键诊断**（读真实像素，直接告诉你卡在哪一环）：

```bash
D:/DevTools/pyenv-re313/Scripts/python.exe Arasaka/check_dispel.py
```

它会打印：驱散开关 / 有效性 / group 每格的 生命值·职责·驱散 / 驱散技能 CD，
然后**把决策层实跑一遍**，给出 `action_hotkey` 和 `current_step`，
并直接判断是「决策层没给动作」还是「动作给了但没发出去」。

| 看什么 | 说明什么 |
|--------|---------|
| 探针的 `AddAuraSlot=失败` | 模板没加载（坑 ①） |
| group 某格 `驱散=0` 但身上明明有 debuff | 引擎没染色 / 纹理被压黑（坑 ②） |
| 「受限状态：是」 | 战斗中光环数据受限 → 只能靠引擎染色这条路 |
| 「类型N：会/不会」 | 玩家会不会驱这一类 —— 「不会」说明能力表或已学会判定有问题 |
| `action_hotkey=None` | 决策层没给动作 → 看 group 字段和技能 CD |

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
   25 个函数覆盖了低血、职责、带 buff、缺 buff、按层数、按驱散类型、批量计数。
   **这些是跨职业通用件，即使当前职业没用到也不要删**（将来加职业直接 import）。

### 17.2 想做什么 → 改哪里

| 我想…… | 改这里 | 关键写法 |
|---------|--------|----------|
| 加一个技能冷却像素 | `class/<职业>.lua` | `[N] = { type = "spell", name = "技能名" }`；无限服自动按名解析到已学会 rank，未学会写 255 |
| 加一个自身 buff **倒计时** | `core/auras.lua` + `class/<职业>.lua` | `["名字"] = { duration = 20, addAuras = { [spellID] = { event = e["施法成功"] } } }` + `[N] = { type = "aura", name = "…", auraName = "…", showKey = "remaining" }` |
| 加一个自身 buff **层数** | 同上 | `showKey = "count"`，条目里配 `count / countMin / countMax` |
| 加一个「有 / 没有」的状态 | `class/<职业>.lua` + `main.lua` | `[N] = { type = "block", name = "…" }`，在对应 `updateXxx()` 里 `CreatTexture(idx, 1 or 0)` |
| 加一个可切换开关 | `core/core.lua` + `core/quickbutton.lua` | `SwitchXxx()` 写像素 + `SaveConfig()`；按钮面板自动收录 |
| 加一个宏 | `class/<职业>.lua` 的 `MacrosList` | 普通技能进 `staticSpells`；`@raidN` 循环施放进 `dynamicSpells`（每个占 30 位）；完整宏体（`/castsequence`、`/startattack`）进 `specialSpells` |
| 加一条决策分支（技能优先级） | `Arasaka/class/<职业>_logic.py` | 读数用本文件自带的 `Ctx`（`ctx.hp/ctx.ready(name)/ctx.melee`…）；条件用本文件的 `_is_enemy` / `_in_melee`；维持类操作加 `_upkeep_ok(name, 秒)` 防抖。**分支顺序 = 优先级**，第一个满足就返回 |
| 调决策松紧（阈值） | logic 顶部常量（`AOE_3` / `AOE_5` / `HEAL_LOW`…） | 改常量即可，不必动逻辑代码。各职业的常量清单见 `Progress/<职业>.md` 的「阈值常量」表 |
| 读敌人数量 / 5 码敌人 | `main.lua:updateEnemyCount` | 已有 `state.enemyCount` / `state.enemyCount5y` → 像素 `敌人人数` / `5码敌人` |
| 读目标距离 | `main.lua:updateTargetRangeBlock`（LibRangeCheck） | 像素 `目标距离`，单位码 |
| 判断该不该放地面 AoE | `main.lua:updateEnemyCount` 的 `enemyCount5y` | 像素 `5码敌人`（41 号）= 姓名版里 ≤5 码且战斗中的人数；**依赖姓名版开启** |
| 读目标类型（敌对/友善） | `main.lua:updateTargetType` + `updateTargetValid` | `目标类型`：0 无/超距/死亡，1~10 敌对，11~20 友善 |
| 读队伍某人血量/职责/驱散 | `main.lua:updateUnitFullAura` + `blocks.groups` | Python 侧直接用 `state_dict["group"]` |
| 读药水 / 治疗石冷却 | `core/forever.lua` 的 `itemGroups` + `itemBlocks` | 像素名 `大红冷却` / `大蓝冷却` / `治疗石冷却`，物品 ID 用无限服经典 ID |
| 让某个技能不进冷却区显示 | `config.yml` 职业级 `probe_fields` | 只影响 GUI 显示，像素和决策数据不动 |
| 让某组字段单独一个 GUI 分区 | `config.yml` 职业级 `buff_fields` | 同上，读不到该键的一侧（旧 exe）也不受影响 |
| 加一条调试输出 | `core/forever.lua:PrintSpecDebug` | `/cy spec` 触发，**不要**塞进 `OnUpdate` 调用链 |
| 改 GUI 布局 | `logic_gui_Tools.py` | 三分区：`update_status_display` / `update_cooldown_display` / `update_buff_display` |
| 让插件在死亡/坐骑/打字/吃喝时不按键 | 已由调度层统一处理 | `logic_gui_Tools.py` 的 `if not sd.get("有效性"): continue`，无需在职业逻辑里加 |

### 17.3 已在跑的「轮子」（禁止重造）

| 能力 | 现成实现 | 位置 |
|------|----------|------|
| 施放成功后计时 N 秒 | 光环状态机（事件驱动，当前只有圣骑士段） | `core/auras.lua` |
| 读自身 buff 剩余秒 | `C_UnitAuras.GetAuraDuration` + 颜色曲线 `curve255` | `main.lua:updateAuraBySpellCooldown` 等 |
| 读光环实例 ID（兼容老客户端） | `F:GetAuraInstanceIDs`（先试 `GetUnitAuraInstanceIDs`，退回 `GetDebuffDataByIndex`） | `core/forever.lua` |
| 判断值是否为 secret | `issecretvalue(v)` | `main.lua` 的 `canaccessvalue` 兜底 |
| 技能名 → 已学会 rank ID | `F:ResolveSpellID(name)`（法术书索引 + 离线表） | `core/forever.lua` |
| 专精判定（天赋树点数） | `F:GetActiveSpecIndex()` | `core/forever.lua` |
| 写像素 | `self:CreatTexture(index, value)` | `core/block.lua` |
| 近战平砍状态 | `PLAYER_ENTER_COMBAT` / `PLAYER_LEAVE_COMBAT` → `F.autoAttackOn` | `core/forever.lua` 的 `UpdateForeverAutoAttack` |
| 找低血队友 / 缺 buff 队友 / 驱散目标 | 25 个 `get_*` / `count_*` 选择器 | `Arasaka/utils.py` |
| 热键查找与发送 | `get_hotkey()` + `send_key_to_wow()` | `Arasaka/utils.py` |
| 像素 → state_dict | `build_state_dict()`（含 spells 子字典、group 展开） | `Arasaka/GetPixels.py` |
| 光环受限（战斗中） | **引擎按 debuff 类型给色条「驱散」格染色**（Decursive 同款）→ Python 照旧从色条读，拿到精确类型 | `main.lua` 的 `UpdateDispelProbeUnit` |
| 决策层热重载 | `reload_logic_modules()` | `logic_gui_Tools.py` |
| 宏体创建 | `loadPlayerMacros()` → `CreateMacro()`（进入世界时一次，无手动命令） | `core/macro.lua` |

### 17.4 决策层内部小工具（**各职业自带一份**）

**9 个职业互不共用决策层工具** —— 没有 `battle_common.py` 这类公共模块。
每个 `Arasaka/class/<职业>_logic.py` 在文件顶部自带一套小工具，
只带该职业实际用到的那几个。

| 需要什么 | 用哪个 |
|---------|--------|
| 打包 state_dict | `Ctx(state_dict, spec_name)` |
| 技能就绪？ | `ctx.ready(name)` / `ctx.cd(name)` |
| 取整数（缺失不炸） | `_int(state, key, default=0)` |
| 目标是敌人？ | `_is_enemy(目标类型)`（**区间** `1~10`，不要写 `== 1`） |
| 贴身了？ | `_in_melee(距离, yards)` / `ctx.melee` |
| 维持类操作防重复按 | `_upkeep_ok(key, interval=3.0)` |
| 该给谁驱散 | `_pick_dispel_unit(state_dict, 驱散开关, types)` |

**加新能力就加在职业自己的文件里** —— 别去建公共模块，改一个职业不该波及其它 8 个。
各职业带了哪几个，看对应 `Progress/<职业>.md` 的「内部小工具」表。

通用约定：
- 冷却值 `0` = 就绪，`1~254` = 冷却中（秒），`255` = 不可用
- 敌对判定用**区间** `1 <= 目标类型 <= 10`，不要写 `== 1`
- 节流/防抖只用在「补 buff / 换印」这类维持类操作上，**别用在主力技能上**

### 17.5 已知死代码 / 别照着抄

| 位置 | 状态 |
|------|------|
| `core/config.lua` 的 `noSecretAuras` / `difficutlyToText` / `bossID` / `heroTalents` | **已删除**（本服无对应机制，全仓零引用） |
| `core/config.lua` 的 `spellsList`（606 条硬编码法术 ID） | **已删除**。技能索引改由 `core/forever.lua` 的 `ResolveSpellID(name)` 按技能名解析 |
| 后续版本才有的机制像素（蓄力 / 蓄力层数 / 一键辅助 / 英雄天赋 / 首领战 / 难度） | **已删除**。本服是 1.60.1，没有这些机制，且部分与其它字段撞像素（如 `蓄力` 与 `生命值` 都占 9 号） |
| 各职业的 200~211 索引 | 已删（后续版本技能，60 级经典技能组不提供） |
| `staticSpells` 的 `/` 前缀判断 | **已回滚**。`staticSpells` 一律拼 `/cast`，完整宏体只能放 `specialSpells` |
| `main.lua` 的驱散探测实验脚手架（`DT2`~`DT8` / `dt*_safeStr` / `dt3_probe` / `dt4_access` / `dt7_*` / `DT8_PROBES`） | **已删除**（2026-11-21）。8 轮实验的结论已固化进生产路径，代码本身零引用 |
| `core/forever.lua` 的 debuff 学习表（`dispelTypeFromName` / `LearnDebuffTypes` / `QueryDispelBySpellTable`）+ `db.char.dispelSpellTypes` | **已删除**。「脱战学表→战斗查表」实测走不通（受限时按 ID 查询返回 nil，无法区分命中与读不到），已被引擎染色路径取代 |
| `main.lua` 的 `clearGroupBlocks` | **已删除**（2026-11-21）。队伍块清零已由 `updateGroup` 重建 + Python 端 `_role_not_zero` 过滤覆盖 |
| `core/core.lua` help 里的 `/cy dispeltest` | **已删除**。该命令分支从来就不存在（只有 `dispelprobe` / `dispelscan` / `dispelpix`） |
| `core/block.lua` 的 `ClearAllCyberDeckBars` | **保留并已接上调用点**（2026-11-21）。换专精时清掉上一套专精建的计数条，见下方说明 |

> ⚠️ **删「当前没调用」的代码前先分类**：
> - **通用件**（跨职业可复用、其它职业将来会用到）→ **保留**
>   例：`Arasaka/utils.py` 的 25 个选择器函数、`main.lua` 的
>   `updateUnitAuraCount` / `updateTargetAuraCount`（牧师「目标光环数量」块）、
>   `updateShapeshiftForm` 里的「姿态」写入（德鲁伊块）—— 这些即使当前职业用不到也不能删
> - **职业专属件 + 该职业不在本服** → 可删
>   例：酒池（武僧）、符文（死骑）、疾病判断（死骑）、防御光环（恶魔猎手）
> - **本服没有的机制件** → 可删
> - **判不准的一律保留**：留着不花钱，删了要重写 |
>
> ⚠️ **「触发条件不存在」≠「这个函数多余」**：
> 换专精要重建计数条这件事本身是必须的；只是**触发它的条件**在本服不一样
> —— 本服没有「切天赋/切专精」那两个施法，改天赋走 `PLAYER_TALENT_UPDATE`，
> 所以调用点得自己补在 `main.lua` 的 `updatePlayerSpecInfo()`：专精索引变了就清一次。

### 17.5.1 切专精要重建计数条（`ClearAllCyberDeckBars`）

本服 1.60.1 = TBC 2.4.3，**有双天赋系统**（每职业两棵树）。切换后像素块配置要整套换，
`CreateAutoLayoutBar` 建出来的计数条也必须重建，否则残留上一套专精的旧条。

```lua
-- main.lua: updatePlayerSpecInfo()
local newSpecIndex = self:GetActiveSpecIndex()
-- 换专精：把上一套专精建的计数条清掉重建。
-- 本服没有「切天赋/切专精」那两个施法，改天赋走 PLAYER_TALENT_UPDATE，所以在这里补。
-- 必须在 loadPlayerBlocks 之前清：CreateAutoLayoutBar 开头有
-- 「spellIdToBar 已有就复用」的复检，不先清会命中旧映射，条不会重建。
if self.state.specIndex and self.state.specIndex ~= newSpecIndex then
    self:ClearAllCyberDeckBars()
end
self.state.specIndex = newSpecIndex
```

两个要点：
- **必须在 `loadPlayerBlocks` 之前清** —— `CreateAutoLayoutBar` 开头有
  `if spellIdToBar[spellId] then return spellIdToBar[spellId] end` 复检，
  不先清会命中旧映射，新专精的条根本不会重建。
- **只在专精真的变了时才清** —— `PLAYER_TALENT_UPDATE` 每次加天赋点都会触发，
  无条件清会导致频繁重建。

> 当前 9 个职业的 `class/*.lua` 里 `countBars` 配置数都是 0，
> 所以这条路径暂时走不到实际效果；但调用点已就位，将来配了 countBars 就能正确重建。

### 17.6 重复造轮子的真实代价（本仓库踩过的坑）

| 症状 | 根因 | 正确做法 |
|------|------|----------|
| 每次进战斗重放光环（如圣印） | 自维护 `lastSealUntil`，战斗外扫描每 0.2 秒把它覆盖成 `now+2`，进战斗锁只剩 2 秒 | 用 `auras.lua` 的 `expirationTime`，只在施放成功时写 |
| 一个技能都不放 | 起手 `if 自动攻击 == 0` 放在战斗分支**最前面**，与后续共用 if/elif 链，一次为真挡死全部 | 兜底分支必须放**最后一个 elif** + 节流 |
| `/cy spec` 输出刷屏 | 跨行正则删代码时吞掉函数边界，把 `PrintSpecDebug` 的 print 并进了 0.2 秒循环 | 删代码用**行号**定位（先 `grep -n` 再按行切片），不要用 `.*?` 匹配缩进 `end` |
| 永远认为没挂常驻 buff | 把字段挪进 `buffs:` 子段，`state_dict["<字段名>"]` 消失 | 分组名单放**职业级**（`buff_fields` / `probe_fields`），字段位置不动 |
| 某个 CD 好了不补 | 节流设成了等于该 buff 的持续时间 | 有真 CD 的技能只看 `CD == 0`，不要叠加节流 |
| GUI 能打字、游戏按键失效 | 无边框窗口没加 `WS_EX_NOACTIVATE`，点一下就抢焦点 | 建窗时补 `0x08000000` |
| 部分怪一个技能都不放 | `_is_enemy` 写成 `目标类型 == 1`，而敌对带可驱散 buff 时是 2~10 | 判区间 `1 <= 目标类型 <= 10` |
| 队友中毒/疾病了但不驱散 | `main.lua` 的 `dispelAbilities` 里写了**别的版本的法术 ID**，本服是经典 ID，一个都对不上 → `hasLearnedAnySpell` 全 false → 驱散曲线点位被写成 0 → 队友的「驱散」像素恒为 0（**不报错，很难查**） | 能力表按本服实际法术 ID 写；改完用 `/cy dispelprobe` 看点位是不是 0 |
| 脱战时角色自己按技能 | 把「维持 buff」写成无 `战斗` 条件的兜底分支，脱战也每 30 秒按一次 | 维持类分支一律加 `战斗 and`，脱战不做任何操作 |
| 面板显示队友血量变成「100s」 | 新增的计时块落进了队伍块区间，两个 updater 抢同一像素 | 新块编号先算队伍块区间：`start=57`、`num=5` 时是 `58~207`，**208 之后才安全** |
| 以为「打字时会乱按键」要加守卫 | 只 grep 了 `Arasaka/` 就下结论——调度层 `logic_gui_Tools.py` 早就有 `if not sd.get("有效性"): continue` | 查横切逻辑要连调度层一起看；职业逻辑里重复判反而会漂移 |
| 惩戒对着满血怪也放愤怒之锤 | 「目标生命值」像素从来没建过（`class/Paladin.lua` 缺块 + `config.yml` 缺字段）→ Python 读到恒 0 → `目标生命值 <= 20` 恒真 | 新增状态字段要**三处同步**：Lua 块定义 + `config.yml` 字段 + Python 读取；用 `check_integrity.py` 查断链 |
| 加了职业后选人函数「不存在」 | 删「当前没调用」的代码时把 `Arasaka/utils.py` 的通用选择器一起删了 | 通用工具库不按「当前是否被调用」判断死活；加职业前先确认 `utils.py` 25 个函数齐全 |

### 17.7 加完功能的自检顺序

```bash
# 1) Lua 语法（排除 Libs/）
"D:/DevTools/lua54/lua-5.4.6/src/luac.exe" -p <每个 .lua 文件>

# 2) Python + YAML 语法
python -m py_compile <每个 .py 文件>
python -c "import yaml; yaml.safe_load(open('Arasaka/config.yml',encoding='utf-8'))"

# 3) 五维交叉校验（抓「像素↔config↔Python」断链）
python .workbuddy/check_integrity.py

# 4) 误删审计（把 git HEAD 的删除逐条对照「无限服 9 职业是否存在」判定）
python .workbuddy/audit_wrong_deletion.py
```

> 只跑语法检查会漏掉「函数被吞并」「分支被挡死」「配置断链」这类结构性问题。
> 只想确认改动没坏，进游戏打 `/cy spec`、`/cy gui`、`/cy dispelprobe` 看像素即可。

全部通过再交付。

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

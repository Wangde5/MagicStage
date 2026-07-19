# MagicStage — 界面设计与公共组件规范

> 本文档约束设置界面和可复用 UI 组件。项目结构见 `PROJECT_GUIDE.md`，发布流程见 `RELEASE_GUIDE.md`。功能页面不得自行复制一套近似样式。

## 1. 设计原则

- 优先采用 macOS 原生控件、菜单、键盘操作和状态反馈。
- 同一种设置含义使用同一个公共组件；尺寸、间距、颜色和动画从 `UIConfig` 读取。
- 常态界面保持克制，悬停、按压、选中、禁用和错误状态必须有明确但不过度的反馈。
- 右侧控件统一右对齐，文字长度变化不能挤乱左侧标题。
- 新样式只有在两个及以上页面需要复用时才进入公共组件；一次性功能布局仍应复用现有 token。

## 2. 公共组件索引

| 用途 | 使用组件 | 文件 |
|---|---|---|
| 设置卡片 | `SettingsCard` | `Shared/Components/SettingsRow.swift` |
| 标准设置行 | `SettingsRow` | `Shared/Components/SettingsRow.swift` |
| 卡片分隔线 | `SettingsDivider` | `Shared/Components/SettingsRow.swift` |
| 离散选项菜单 | `SettingsOptionMenu`、`SettingsMenuOption` | `Shared/Components/SettingsRow.swift` |
| 数值调节 | `SettingsSliderRow` | `Shared/Components/SettingsRow.swift` |
| 快捷键录制 | `ShortcutRecorderView` | `Shared/Components/ShortcutRecorder.swift` |
| 页面尺寸与视觉 token | `UIConfig.SettingsPage`、`SettingsRow`、`Typography`、`ColorTokens`、`Animation` | `Shared/DesignSystem/UIConfig.swift` |
| 侧栏与页面入口 | `SettingsCategory`、`ContentView.contentArea` | `Shared/ContentView.swift` |

表中的路径均相对于 `MagicStage/`。

## 3. 页面结构

- 页面使用垂直 `ScrollView`，内容区间距和边距引用 `UIConfig.SettingsPage`。
- 每个语义分组由 section 标题和 `SettingsCard` 组成；同一卡片的相邻行之间使用 `SettingsDivider`。
- 功能主开关和依赖它的子开关连续排列。快捷键独占一行，放在相关开关之后，不夹在两个连续开关之间。
- 新页面同时注册到 `SettingsCategory` 与 `ContentView.contentArea`。
- 不在页面内硬编码另一套行高、圆角、卡片描边或分隔线颜色。

## 4. 控件选型

| 设置含义 | 使用方式 |
|---|---|
| 开关 | `SettingsRow` 内使用系统 `Toggle`，配合 `.toggleStyle(.switch)` 和 `.labelsHidden()` |
| 两个及以上互斥选项 | `SettingsOptionMenu`，选项由 `SettingsMenuOption` 提供 |
| 有合法范围的数值 | `SettingsSliderRow` |
| 快捷键 | 独立 `SettingsRow` 内使用 `ShortcutRecorderView` |
| 普通文字操作 | `SettingsRow` 右侧使用系统 `Button` |
| 删除、设为默认等列表操作 | plain 系统按钮、SF Symbol、tooltip，置于固定的右侧操作区 |
| 列表项移除按钮 | 20×20 pt 圆形（`Color.primary.opacity(0.08)` 底）+ 9 pt `.bold` `minus` + `.secondary` 前景；不使用红色或大尺寸 |
| 整行新增操作 | `SettingsCard` 内的 plain 整行按钮，边距与高度引用设置行 token |
| 危险确认与错误 | 系统 `.alert`，破坏性动作使用 `.destructive`，取消使用 `.cancel` |

禁止用自绘弹窗替代系统菜单、用按钮模拟开关、在单个页面手写另一种 Slider 行，或用无说明的纯图标承担关键操作。

## 5. 选择菜单

- 有限选项统一使用 `SettingsOptionMenu`。底层透明 `NSPopUpButton` 提供原生菜单、键盘操作和当前项勾选。
- 常态只显示右对齐的当前值与上下尖角，不显示灰色矩形。尖角使用 `chevron.up.chevron.down`，9 pt `.bold`，`.foregroundStyle(.primary)`，包裹在 20×20 pt 圆形背景中。
- 悬停时，灰色反馈区域只包裹“当前值 + 尖角”的实际内容宽度；背景色与尖角所在圆形保持一致，圆形尺寸使用公共组件定义，不由页面覆盖。
- 菜单项需要图标时使用 `SettingsMenuOption(symbolName:)`；无图标时传 `nil`，不手动插入空白占位。
- 文本过长由公共组件截断并提供 tooltip，功能页不设置固定宽度来伪造对齐。
- 多选场景（如文件抽屉出现位置）使用每行一个 `Toggle` 开关，不用菜单；至少保留一项选中。

## 6. 滑杆

- 参数调节统一使用 `SettingsSliderRow`，顺序为：标题、最小值、系统 Slider、最大值、当前值。
- 使用系统活动轨道和滑块，不绘制密集小圆点或另一条假轨道。
- 最小值、最大值和当前值使用相同单位；当前值采用等宽数字并右对齐。
- `range`、`step` 与服务层合法范围保持一致。只有真实存在离散档位时才使用合理步长。

## 7. 状态、动画与可访问性

- Toggle 动画使用 `UIConfig.Animation` 的统一参数。
- 依赖主开关的设置必须用 `.disabled(...)` 真正禁用，不能只降低透明度。
- hover、pressed、selected、recording、disabled 和 error 状态由系统控件或公共组件表达。
- 图标按钮提供 `.help(...)`；不能只靠颜色表达危险或当前状态。
- 浅色、深色、不同窗口宽度和“减少动态效果”下都应保持布局稳定、信息可读。

## 8. 修改设置界面时的检查

- 页面入口、标题、分组、卡片、行和分隔线与其他设置页一致。
- 选项菜单常态无灰底，悬停区域宽度和颜色正确，弹出菜单为原生样式且有勾选。
- 滑杆具有系统活动轨道，范围、步长、单位和当前值正确。
- 快捷键单独成行；开关和其子项保持连续。
- 所有右侧控件和列表操作位置对齐，长文本不会造成跳动。
- 新增 token 已被实际使用；公共组件行为变化已在所有使用页面回归。

# MagicStage — 项目概览与工程导航

> 本文档用于快速浏览整个项目：产品能力、代码入口、核心架构、修改路径和验证范围。它不是界面规范，也不是发布操作手册；界面规则见 `DESIGN_GUIDE.md`，正式发布流程见 `RELEASE_GUIDE.md`。内容以当前源码为准，若文档与代码冲突，应核对实现并同步修正文档。

## 1. 快速事实

- 产品：macOS 窗口管理工具。
- 技术：Swift 5、SwiftUI、AppKit、Accessibility、Core Graphics、ScreenCaptureKit、Sparkle。
- 最低系统：macOS 14.0。
- 工程入口：`MagicStage/App/MagicStageApp.swift`。
- 生命周期入口：`AppDelegate.applicationDidFinishLaunching`。
- 设置窗口：`AppDelegate.openPreferences()` 创建，`ContentView` 提供页面导航；`⌘,` 也调用该入口。
- Xcode 工程使用 filesystem-synchronized groups：放入 `MagicStage/` 的 Swift 文件通常会自动进入 target。
- App Sandbox 关闭，Hardened Runtime 开启。
- 当前版本号由 target 的 `MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION` 提供，Info.plist 不写死版本。

### 文档分工

| 文档 | 用途 | 不应包含 |
|---|---|---|
| `PROJECT_GUIDE.md` | 浏览功能、目录、服务关系、关键约束与回归入口 | 发布凭据操作、逐项控件视觉参数 |
| `DESIGN_GUIDE.md` | 设置界面和公共控件的设计、选型与交互规范 | 签名、公证、上传步骤 |
| `RELEASE_GUIDE.md` | 版本准备、签名、公证、Sparkle、上传、验证与回滚 | 功能实现说明、控件设计规范 |
| `CHANGELOG.md` | 已交付版本的用户可见变化 | 开发计划和未完成事项 |

## 2. 修改前必须遵守

1. 不要提交、打印或移动任何 Sparkle 私钥。仓库历史中的旧私钥已经暴露，见 `RELEASE_GUIDE.md`。
2. 不要直接调用未验证存在的私有 API。SkyLight 符号必须经 `dlopen`/`dlsym` 后判空。
3. 不要用 PID 作为窗口唯一身份。同一应用可有多个窗口，必须使用 `WindowIdentity`。
4. 不要混用 AppKit 与 Quartz/AX 坐标。统一通过 `ScreenCoordinates` 转换。
5. 不要在 CGEvent tap 回调内阻塞、等待、执行长耗时 AX 查询或同步截图。
6. 修改事件 tap、窗口恢复、异步预览后，必须运行单元测试、Debug build 和 Release build。
7. 不要修改仓库根目录下未跟踪的历史 `.app` 目录。
8. 不要为了缩短大文件而做无行为依据的重构。先补测试，再拆分。

## 3. 产品能力与入口

| 能力 | 主要入口 | 设置页面 |
|---|---|---|
| 快捷键窗口布局与 Toggle 恢复 | `WindowManagementService` | `WindowManagementSettingsView` |
| 拖拽到顶部热区分屏 | `DragSplitService` | `WindowManagementSettingsView` |
| 按纯修饰键拖动任意窗口区域 | `MoveWindowService` | `WindowManagementSettingsView` |
| 点击 Dock 图标切换/最小化窗口 | `AppDelegate` | `WindowMinimizeSettingsView` |
| Dock 悬停退出应用 | `DockHoverQuitService` | `DockHoverQuitSettingsView` |
| Dock 悬停窗口预览 | `WindowPreviewService` | `WindowPreviewSettingsView` |
| 快捷文件抽屉 | `FileDrawerService`、`FileDrawerPanelController` | `FileDrawerSettingsView` |
| 触控板反馈 | 各功能服务 | `HapticFeedbackSettingsView` |
| 登录启动与 Sparkle 更新 | `SystemSettingsView`、`UpdaterService` | `SystemSettingsView` |

## 4. 目录导航

```text
MagicStage/
  App/
    MagicStageApp.swift              SwiftUI @main、⌘, 命令
    AppDelegate.swift                启动顺序、权限恢复、Dock 点击、设置窗口
  Core/
    Models/
      KeyboardShortcut.swift         快捷键模型与纯修饰键校验
      FileDrawerItem.swift           文件抽屉条目与排序模式
      ScreenCoordinates.swift        AppKit ↔ Quartz/AX 坐标转换
      WindowIdentity.swift           PID + window token，多窗口隔离
      WindowLayout.swift             10 种布局及 frame 计算
    Extensions/
      AXUIElement+Extensions.swift    Dock AX 树与应用匹配工具
      CGEventFlags+NSEventModifiers.swift
    Services/
      HotkeyManager.swift            键盘 event tap、降级 monitor、快捷键录制
      ShortcutRegistry.swift         快捷键映射、冲突检测、handler 分发
      WindowManagementService.swift  布局执行、动画、Toggle 快照
      DragSplitService.swift         拖拽分屏、恢复 frame、热区状态机
      MoveWindowService.swift        修饰键 + 鼠标拖动窗口
      DockHoverQuitService.swift     Dock 悬停退出
      WindowPreviewService.swift     Dock 检测、窗口过滤、截图、交互
      FileDrawerService.swift        文件夹读取、搜索、导航、Quick Look、持久化
      SkyLightBridge.swift           可选私有 API 桥接与安全降级
      UpdaterService.swift           Sparkle 状态与设置绑定
  Features/                          设置页面
  Shared/
    ContentView.swift                设置导航
    Components/                      通用设置控件
    DesignSystem/UIConfig.swift      实际使用中的 UI token
  Windows/                           NSPanel、overlay 与预览卡片
    FileDrawerPanelController.swift  非激活 HUD 文件抽屉与窗口动画
    FileDrawerPanelView.swift        文件网格、缩略图、搜索与拖拽交互
MagicStageTests/                     纯逻辑与回归测试
MagicStageUITests/                   UI 测试骨架
```

## 5. 启动和权限生命周期

`AppDelegate.applicationDidFinishLaunching` 的顺序不可随意改变：

1. 设置 `.regular` activation policy。
2. 注册 UserDefaults 默认值。
3. 初始化 `DragSplitService`、`MoveWindowService`、`WindowPreviewService`、`FileDrawerService`。
4. 延迟创建 Sparkle updater。
5. 启动 `HotkeyManager` 并加载 `ShortcutRegistry`。
6. 启动 Dock 鼠标 tap。
7. 请求辅助功能权限并激活窗口布局快捷键。

首次授权存在 TCC 传播延迟。`AppDelegate.refreshPermissionDependentServices` 会有限重试，并调用三个服务的 `refreshForAccessibilityChange()`。服务必须保留用户的 enabled 偏好；权限缺失不能擅自把开关改成 false。

`AccessibilityPermissionCoordinator` 统一管理首次欢迎页和权限页：两页共用同一尺寸窗口，欢迎页居中；切到权限页时窗口以约 0.82 秒的缓动移至当前屏幕左侧，避开系统设置和右上角授权提示。权限页的操作按钮与授权卡片在 macOS 26 使用系统 `regular` 液态玻璃，不得再叠加自定义高光描边；已授权状态仅以绿色图标和勾号表示。

主要权限：

- Accessibility：全局事件、AX 窗口读写。
- Screen Recording：窗口预览截图。
- Apple Events：仅用于 AX 失败后的 AppleScript 降级。

## 6. 快捷键架构

```text
CGEvent/NSEvent
  → HotkeyManager
  → ShortcutRegistry
  → FeatureID 对应 handler
  → WindowManagementService 或 AppDelegate 行为
```

- 普通快捷键：真实 `keyCode` + modifiers。
- 纯修饰键：`keyCode == UInt16.max`。
- 空快捷键：`KeyboardShortcut.empty`。
- Move Window 只能使用纯修饰键；普通按键无法从鼠标事件 flags 中可靠匹配。
- `HotkeyManager` 负责持久化和冲突处理；不要绕过 registry 建第二套映射。
- 文件抽屉默认快捷键是 `⌃⌥Space`；用户录制后仍由 `ShortcutRegistry` 统一覆盖和持久化。

## 7. 窗口布局与恢复

### 7.1 快捷键布局

`WindowManagementService.performLayout`：

1. 获取前台或最近目标 PID。
2. 获取 focused/main/first AX window。
3. 构造 `WindowIdentity(window:)`。
4. 选择相交面积最大的屏幕。
5. 由 `WindowLayout.targetFrame(screenAXFrame:currentSize:)` 计算目标。
6. 若当前 frame 接近该布局已保存的 applied frame，则恢复 original frame。
7. 否则保存快照并动画到目标。

快照结构是 `[WindowIdentity: [WindowLayout: LayoutSnapshot]]`。快速连续触发布局时，动画中间 frame 不能成为新的 original frame。

### 7.2 拖拽分屏

`DragSplitService` 状态机：

```text
idle → peeking → expanded → applyLayout
```

- 普通系统拖拽：NSEvent monitor + 40ms polling。
- Move Window 拖拽：由 `handleExternalDrag*` 驱动。
- 标题栏恢复：独立 CGEvent tap + `TitleBarDragOverlay`。
- 恢复 frame 以 `WindowIdentity` 为 key。
- 应用终止时清理该 PID 的所有窗口记录；切换应用时不清理。

## 8. 坐标系规则

| API | 原点/方向 |
|---|---|
| AppKit `NSScreen.frame`、`NSEvent.mouseLocation` | 左下，Y 向上 |
| CGEvent、CGWindow bounds、AX window position | 主屏左上，Y 向下 |

必须使用 `NSScreen.screens.first?.frame.maxY` 作为主屏翻转基准，不能只用 `frame.height`，也不能假设所有屏幕位于主屏右侧或上方。

可复用 API：

- `ScreenCoordinates.cocoaPoint(fromQuartz:primaryScreenMaxY:)`
- `ScreenCoordinates.quartzPoint(fromCocoa:primaryScreenMaxY:)`
- `ScreenCoordinates.quartzFrame(fromCocoa:primaryScreenMaxY:)`
- `ScreenCoordinates.cocoaFrame(fromQuartz:primaryScreenMaxY:)`

新增坐标逻辑时必须补负 X、负 Y 或副屏场景测试。

## 9. Dock 窗口预览

### 9.1 Dock 图标识别

`detectDockIcon()` 遍历 Dock AX 树，只保留 `AXDockItem`，选择鼠标命中的最小 frame。应用匹配优先 AXURL 与 bundleURL；只有 AXURL 不可用时才按名称降级。

### 9.2 窗口过滤与截图

```text
CGWindowList 白名单
  + ScreenCaptureKit 窗口源
  + AX 真实窗口交叉验证
  → 并行截图
```

截图降级顺序：

1. `SkyLightBridge.captureWindow`。
2. `SCScreenshotManager.captureImage`。
3. 动态获取 `CGWindowListCreateImage`。
4. 生成 placeholder。

### 9.3 异步不变量

- `sessionGeneration` 标识一次悬停会话。
- 每次换目标、离开或隐藏都会让旧任务失效。
- 截图完成后必须同时检查：task 未取消、generation 相同、PID 仍相同。
- 延迟 hide cleanup 只能清理创建它的 generation。
- Cmd+W 降级发送前必须再次确认目标 PID 仍是 frontmost application。

## 10. SkyLight 私有 API 边界

SkyLight 用于补足 Electron/CEF 等应用的窗口操作。所有符号动态加载：

- 加载失败必须返回 false/nil，并允许上层走 AX、ScreenCaptureKit 或 AppleScript。
- 不得新增 `@_silgen_name` 直连私有符号。
- 不得假设不同 macOS 版本都有相同符号。
- 私有 API 变更必须同时验证 Intel/Apple Silicon 的风险；当前自动测试不能覆盖 WindowServer 行为。

## 11. 文件抽屉

- `FileDrawerService` 管理“下载”“桌面”和自定义标签、目录导航、筛选及文件操作；设置存于 UserDefaults。目录枚举、复制和移动必须在后台执行，枚举结果用 `loadGeneration` 防止旧任务覆盖新目录；当前目录用文件描述符事件监听并合并刷新。排序有名称、修改日期、添加时间、类型、大小五种，名称/类型时目录置顶，日期/大小不强制置顶。出现位置 `placements: Set<FileDrawerPlacement>` 支持多选，边缘触发时由 `activePlacement` 记录鼠标命中的方位。`defaultOpenLocation` 控制启动时打开哪个标签（"lastOpened" 或具体标签 ID）。
- `FileDrawerPanelController` 是可成为 key window 的 nonactivating HUD panel，禁止用 `NSApp.activate` 抢前台应用。支持左、右、左上、右上四个多屏位置，可同时多选；边缘先显示 Peek、继续移入才展开，离开后按设置延迟收起。面板显示期间暂停边缘 mouse-move monitor，菜单、框选、拖拽和 Quick Look 期间暂停自动收起。
- 顶部依次是位置标签、工具栏、可展开筛选栏和路径面包屑；“下载/桌面”不可删除，自定义标签可移除。菜单使用 AppKit `NSMenu` presenter，并在菜单跟踪期间保持面板可见。单击立即选中，Command/Shift 扩展选择，双击打开，Return 仅在单选时重命名，空白点击结束重命名并清空选择。
- 顶部位置标签维持扁平选中/悬停反馈，不使用液态玻璃、投影或高光；工具栏、筛选栏和路径栏的圆形或胶囊按钮必须声明完整 `contentShape`，按钮留白与图标/文字同样可点击。顶部菜单栏、路径栏和文件网格统一使用 18 pt 左右边距；导航与搜索/筛选使用等宽、40 pt 高的双按钮胶囊，并各自带内部细分隔线；中间四个主要功能键同为 40 pt，作为整体居中。标签栏 54 pt 高，顶部两行间距 10 pt；筛选按钮宽度须随左右边距收窄，避免换行或溢出。顶部菜单栏使用 `NSVisualEffectView.Material.headerView`，Peek 条也使用同款材质；不要在整条菜单栏施加会造成边缘折射的 `glassEffect`。
- Finder 文件操作必须完整保留：Command+O 打开，Command+C 拷贝本地文件 URL，Command+V 复制到当前目录，Option+Command+V 移到当前目录，Command+D 制作副本，Shift+Command+N 新建文件夹并立即重命名，Command+Delete 移到废纸篓；空白右键提供“新建文件夹/粘贴项目”，项目右键提供拷贝、制作副本、重命名等操作，也允许把外部文件拖入当前目录。所有冲突都生成不覆盖原文件的“副本/编号”名称，文件操作完成后刷新并选中新项目。
- **普通文件名最多显示 2 行，所有 2–5 列布局都不得改成 1 行。** 使用 11.5 pt `.regular`、居中、末行中间截断；短名称自然为 1 行。显示态宽度取实际最长排版行，蓝色选中背景仅在文字外加水平 4 pt、垂直 2 pt，不能设置人为最小宽度，也不能因选中改变字重。
- **重命名框最多可见 3 行，不是 2 行，并且没有人为最小宽度。** 宽度始终按当前文字最长排版行动态变化，只增加左右各 4 pt 内边距，最大不超过卡片可用宽度；即使只有一个字符也不能扩成统一宽度。1/2/3 行分别保持对应高度，超过 3 行后固定三行并使用 overlay 自动隐藏滚动条。只选中主文件名、不选扩展名；Return 提交、Escape 取消。编辑器向下溢出且不改变卡片/网格高度；重命名拒绝空名、斜杠和真实同名冲突，大小写变更先确认是同一文件再原子改名。
- 空白拖动使用矩形框选：无修饰键时选择集合等于当前相交项目，Command/Shift 才保留原选择；项目命中与悬停必须共同使用缩略图占位与真实文件名占位的并集，不能用撑满整列或整张固定卡片的矩形，否则图标和名称之间、名称两侧的空白会错误选中项目、触发悬停或阻止框选。第一行距路径栏的留白与网格纵向行距相同；网格行距保持紧凑。切换标签或路径时只替换滚动内容，框选覆盖层、手势、原生拖拽监听和命名坐标空间必须留在 identity 边界外；坐标快照按目录路径隔离，过渡期旧视图销毁不能断开新覆盖层。边缘自动滚动直接驱动原生 `NSScrollView`，到边界或结束时必须停止计时器。键盘方向、Page Up/Down、Home/End 按网格阅读顺序移动，并将目标滚入可见区域。
- Space 优先预览主选项目，无选择时才预览悬停项目。只使用共享 `QLPreviewPanel`：展示前设置窗口层级，只调用一次 `makeKeyAndOrderFront`，展示后校准索引；通过 delegate 返回缓存缩略图及其实际屏幕矩形。文件和文件夹都走同一关闭路径，系统缩回末段仅让独立“幽灵缩略图”从 100% 淡到 0%，真实卡片不改透明度；清理完成后再恢复层级、delegate 和抽屉焦点。Space/Escape 由临时 CGEvent 拦截器消费，避免传到后方应用。
- 文件拖出使用原生 `NSDraggingSession` 和 `NSURL` pasteboard writer；多选拖拽处理整个选择，实际按住的可见文件必须排在首个 `NSDraggingItem`，以确保拖拽预览框稳定出现。取消/失败回位以及 Quick Look 收回的末帧淡化都只能操作独立幽灵层。只有抽屉废纸篓目标或 Dock 返回 `.delete` 才调用 `NSWorkspace.recycle`，普通 `.move` 不能当删除；隔空投送结束后释放 sharing service delegate。
- 性能底线：网格使用 `LazyVGrid`；普通名称只用 SwiftUI `Text`，仅正在重命名的项目创建 TextKit；悬停状态留在单卡片。缩略图使用内存 LRU 与磁盘缓存跨睡眠/重启复用，当前目录只允许单路低优先级预热，并始终为可见卡片预留两个 Quick Look 通道；滚动期间暂停新的缩略图工作。缩略图磁盘编码必须在后台执行，缓存目录清理要限频，不能每写入一张图片就重新枚举目录。不得给每张卡片增加屏幕坐标 NSView、同步取图标或常驻 Quick Look 几何读取。液态玻璃只放静态背景层，排序/筛选只重建内存结果，框选更新最高 60 Hz。

## 12. 设置与持久化

- 服务开关通常由 `@Published` + UserDefaults 保存。
- 初始化赋值不会触发 `didSet`，所以 enabled 服务必须在 init 后显式 start。
- 登录启动状态以 `SMAppService.mainApp.status` 为准，不以 UserDefaults 为准。
- UI token 只保留实际使用项；新增 token 后必须在 UI 中引用。
- 设置页面统一加入 `SettingsCategory` 和 `ContentView.contentArea`，不要创建无导航入口的重复页面。
- 设置界面必须复用 `Shared/Components` 与 `UIConfig`，不得在功能页面复制控件样式。
- 选择菜单、滑杆、开关、快捷键、按钮、卡片和对齐规则统一以 `DESIGN_GUIDE.md` 为准；修改公共设置组件时同步更新该文档。

## 13. 常见修改路径

### 新增布局

1. 修改 `WindowLayout` case、显示名、分类、默认快捷键、AX/AppKit frame、preview rect。
2. 确认 `WindowLayout.allCases` 自动进入设置与 registry。
3. 增加 frame 单元测试。

### 新增全局快捷键功能

1. 增加 `FeatureID`。
2. 在 `ShortcutRegistry` 维护显示名/映射。
3. 在启动阶段设置 handler。
4. 使用 `HotkeyManager` 录制和持久化。
5. 验证冲突、清除、无辅助功能权限三条路径。

### 修改窗口预览

1. 保持 PID + windowID 精确匹配优先。
2. 不在主线程同步截图。
3. 不删除 generation/cancellation guard。
4. 验证窗口关闭、应用退出、快速跨图标、鼠标离开后截图才完成等场景。

## 14. 验证命令

```bash
# 单元测试；避免启动依赖桌面自动化权限的 UI runner
xcodebuild test \
  -project MagicStage.xcodeproj \
  -scheme MagicStage \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/MagicStageTests \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:MagicStageTests

# Debug
xcodebuild -project MagicStage.xcodeproj -scheme MagicStage \
  -configuration Debug -derivedDataPath /tmp/MagicStageDebug \
  CODE_SIGNING_ALLOWED=NO build

# Release 编译验证；这不是正式签名发行包
xcodebuild -project MagicStage.xcodeproj -scheme MagicStage \
  -configuration Release -derivedDataPath /tmp/MagicStageRelease \
  CODE_SIGNING_ALLOWED=NO build

git diff --check
plutil -lint MagicStage/Resources/Info.plist
xmllint --noout docs/appcast.xml
```

Xcode 的 `Metadata extraction skipped. No AppIntents.framework dependency found.` 是无 App Intents 时的工具提示，不是项目代码警告。

## 15. 手工回归清单

自动测试无法替代这些检查：

- 首次启动拒绝/授予辅助功能权限，返回 App 后服务自动恢复。
- 权限引导：欢迎页居中，切换权限页的移动平滑且不过快；授权按钮和两张授权卡片使用系统玻璃，已授权状态只显示绿色勾。
- 主屏上下左右各放一个副屏，验证热区、Dock、窗口布局和预览定位。
- 同一应用打开两个窗口，分别分屏、Toggle、拖拽恢复。
- 快速连续触发两个布局，最终 Toggle 回真正原始 frame。
- 快速划过多个 Dock 图标后离开，不出现迟到预览。
- 预览关闭窗口时切换前台应用，不误发 Cmd+W。
- Electron、AppKit、全屏、最小化、跨 Space 窗口各至少一个。
- 文件抽屉：在多种位置组合和多屏环境验证热区 → Peek → 展开、延迟收起、标签/路径导航、单击/多选/框选/键盘导航、双击打开；工具栏、筛选和路径栏按钮的整个圆形/胶囊区域（含留白）必须可点，搜索与筛选两个半区都应独立触发。确认顶部栏、路径栏与网格左右边距对齐，网格纵向间距紧凑且不重叠。框选自动滚动到边界必须停止。组合测试全部类型筛选、2–5 列、名称/日期/添加时间/类型/大小五种排序及正反方向。验证"默认打开"设置为"上次打开"和具体标签两种模式。
- 文件操作：从 Finder 拷贝单个、多个、文件夹后验证 Command+V；验证 Option+Command+V、Command+D、Shift+Command+N、Command+Delete、空白及项目右键菜单和外部文件拖入。重名不得覆盖，完成后应刷新并选中新项目；外部新建/删除/重命名也应自动刷新。
- 文件名：普通态严格最多 2 行，短名自然 1 行，末行中间截断，蓝色背景随真实文字宽度且字重/位置不变；重命名态严格最多可见 3 行，分别验证 1/2/3/超过 3 行、仅选主名、overlay 滚动条和向下溢出不挤动网格。
- Quick Look 与拖出：文件和文件夹都验证 Space 打开/关闭、正确项目、前台焦点稳定、系统缩放及幽灵层末段 100%→0% 淡出；验证多选拖出、取消回位、隔空投送和抽屉/Dock 废纸篓。大图片目录快速滚动与切层级不得明显掉帧，旧加载/缩略图不得回写当前目录。

## 16. 当前已知工程风险

- `WindowPreviewService`、`AppDelegate`、`DragSplitService` 仍然较大，后续应先建立协议/纯逻辑测试再拆分。
- SkyLight 属于私有 API，系统升级可能失效，降级链必须保留。
- UI 测试目前只是骨架，桌面权限与 TCC 场景没有自动化。
- 文件抽屉的目录监听基于当前文件夹的文件描述符事件，网络卷、部分云盘占位文件或提供方语义仍需手工回归；大型目录的 Quick Look 缩略图由系统按需生成。
- 仓库历史含已暴露的 Sparkle 私钥，正式发布前必须处理密钥迁移。
- 历史发布包不等于可发布基线；正式发布要求见 `RELEASE_GUIDE.md`。

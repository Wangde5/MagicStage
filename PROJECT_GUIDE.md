# MagicStage 项目开发指南

> **适用对象**：AI、新开发者
> **目标**：5 分钟理解架构，立即上手改代码

---

## 一、项目概述

macOS 窗口管理工具（SwiftUI + AppKit，macOS 14+），提供五大功能模块：

| 功能 | 入口 | 触发方式 |
|------|------|----------|
| 窗口分屏 | `WindowManagementService` | 快捷键（⌘⌥→ 等） |
| 拖拽分屏 | `DragSplitService` | 拖窗口到屏幕顶部热区 |
| 拖拽移动窗口 | `MoveWindowService` | ⌘⌃ + 拖拽窗口任意位置 |
| Dock 窗口反转 | `AppDelegate` | 点击 Dock 图标 |
| Dock 退出 | `DockHoverQuitService` | 快捷键 + 鼠标悬停 Dock |

**入口**：`MagicStageApp.swift` → `AppDelegate.applicationDidFinishLaunching`

---

## 二、目录结构

```
MagicStage/
  App/
    MagicStageApp.swift               ← @main 入口，创建 NSApplication
    AppDelegate.swift                  ← 生命周期、Dock 点击反转（~500 行）
  Core/
    Models/
      WindowLayout.swift              ← 10 种布局枚举 + 预览/目标帧计算
      KeyboardShortcut.swift          ← 快捷键模型（keyCode + modifiers）
    Services/
      HotkeyManager.swift             ← 全局键盘 CGEvent tap + 录制
      ShortcutRegistry.swift          ← 快捷键 ↔ 功能双向映射 + 冲突检测
      WindowManagementService.swift   ← 快捷键分屏执行 + Toggle 恢复
      DragSplitService.swift          ← 拖拽分屏面板 + 标题栏拖拽恢复尺寸
      MoveWindowService.swift         ← ⌘⌃ 拖拽移动窗口
      DockHoverQuitService.swift      ← Dock 悬停退出
      SkyLightBridge.swift            ← 私有框架桥接（SLSOrderWindow 最小化/恢复）
    Extensions/
      CGEventFlags+NSEventModifiers.swift ← CGEventFlags → NSEvent.ModifierFlags
  Features/
    WindowManagement/
      WindowManagementSettingsView.swift  ← 分屏布局设置页
      DragSplitPanelView.swift            ← 分屏面板卡片 UI
    WindowMinimize/
      WindowMinimizeSettingsView.swift    ← 最小化快捷键 + Dock 反转设置
    MoveWindow/
      MoveWindowSettingsView.swift        ← 移动窗口设置
    DockQuit/
      DockHoverQuitSettingsView.swift     ← Dock 退出设置
    SystemSettings/
      SystemSettingsView.swift            ← 系统设置（开机启动、触觉反馈）
  Shared/
    DesignSystem/
      UIConfig.swift                  ← 所有颜色/字号/间距/动画 Token
    Components/
      SettingsRow.swift               ← SettingsRow + SettingsCard + SettingsDivider
      ShortcutRecorder.swift          ← 快捷键录制器 UI 控件
      VisualEffectView.swift          ← HudWindowBackground 毛玻璃材质
    ContentView.swift                 ← 主设置窗口（侧边栏导航 + 内容区）
  Windows/
    DragSplitPanelController.swift    ← 分屏面板 NSWindow（peek + expand 两阶段）
    DragSplitPreviewOverlay.swift     ← 分屏预览矩形
    TitleBarDragOverlay.swift         ← 标题栏拖拽恢复叠加层
```

### 编码规则

| 规则 | 说明 |
|------|------|
| 新增功能页 | `Features/<名称>/` 目录，纯 SwiftUI View |
| 新增服务 | `Core/Services/`，单例模式 |
| UI 参数 | 必须引用 `UIConfig.*`，禁止硬编码 |
| CGEvent tap | 每个 Service 最多一个，监听不同事件类型不冲突 |
| 坐标转换 | 见第五章，必须统一坐标系 |

---

## 三、架构与数据流

### 3.1 快捷键分屏 → Toggle 流程

```
用户按快捷键（如 ⌘⌥M 最大化）
  → HotkeyManager CGEvent tap 拦截 keyDown
  → ShortcutRegistry.dispatchKeyDown 匹配快捷键 → 功能
  → WindowManagementService.performLayout(.maximize)
  → currentTargetPID() 获取前台 App 的 PID
  → focusedWindow(forPID:) 获取 AX 窗口（focused → main → 首个）
  → 计算目标 frame（AX 坐标系，左上原点）
  → Toggle 判断：
      snapshot[pid][layout] 存在 && currentFrame ≈ appliedTargetFrame(±12pt)？
        是 → 恢复 snapshot[pid][layout].originalFrame，清除快照
        否 → 保存 LayoutSnapshot(originalFrame, appliedTargetFrame)，应用布局
  → 动画：quadratic easeOut，动态帧率（NSScreen.main?.maximumFramesPerSecond，60-120fps）
```

### 3.2 拖拽分屏流程

```
用户拖窗口到屏幕顶部热区
  → DragSplitService NSEvent monitor 检测拖拽
  → 显示 peek 条（高 20pt，从菜单栏滑出）
  → 展开面板（从 peek 平滑展开）
  → 用户松开 → 选中布局
  → applyLayout() 保存恢复帧到 dragSplitRestoreFrames
  → AX 动画窗口到目标位置
```

### 3.3 拖拽恢复尺寸

```
快捷键分屏或拖拽分屏后，用户拖标题栏恢复原尺寸：
  → DragSplitService 独立 CGEvent tap（headInsertEventTap）
  → leftMouseDragged 触发 tryRestoreOnNormalDrag
  → pidAtPoint() 通过 CGWindowList 定位 PID
  → dragSplitRestoreFrames 匹配 → AX 设定原始尺寸（仅尺寸，不碰位置）
  → WindowServer 用新尺寸继续系统拖拽
```

**关键决策**：
- **headInsertEventTap**：在 WindowServer 之前执行，改完尺寸后 WindowServer 拿到恢复后的
- **仅恢复尺寸**：位置由用户拖拽控制
- **PID 做 key**：不依赖窗口标题（标题可能变）
- **独立 tap**：不依赖 MoveWindowService，即使移动窗口功能未启用也正常工作

### 3.4 ⌘⌃ 拖拽移动窗口

```
按住 ⌘⌃ + 拖拽窗口任意位置
  → MoveWindowService CGEvent tap 拦截 leftMouseDown
  → 消费事件（return nil），阻止 WindowServer 启动系统拖拽
  → leftMouseDragged：全部消费 → AX 控制窗口位置
  → leftMouseUp：放行（不消费），保持系统鼠标状态一致
  → 修饰键中途释放：handleExternalDragEnd 应用当前悬停布局
```

### 3.5 Dock 点击窗口反转

```
用户点击 Dock 图标
  → cghidEventTap 只监听 leftMouseUp（不监听 leftMouseDown）
  → AXUIElementCopyElementAtPosition 获取点击元素
  → 检查 PID 是否属于 com.apple.dock（不是则放行）
  → 向上查找 AXDockItem 标题
  → 匹配前台 App 名称（localizedName / bundleName / hasPrefix）
  → 匹配成功且有可见窗口：
      1. 后台线程调用 SkyLightBridge.minimizeWindows（SLSOrderWindow）
      2. 降级：AX 最小化 → AppleScript miniaturize every window
      3. event.location = (0,0) 瞬移鼠标，让 Dock 取消恢复行为
  → 不匹配前台 App：放行事件，系统正常处理
```

**关键决策**：
- **cghidEventTap**（HID 层级）：比 cgSessionEventTap 更底层，不干扰系统事件流
- **只监听 leftMouseUp**：不监听 leftMouseDown，避免干扰 Dock 按下动画
- **后台线程执行最小化**：绝不阻塞事件回调，防止系统误判长按触发右键菜单
- **鼠标瞬移 (0,0)**：Dock 收到屏幕外坐标后认为用户拖走了鼠标，取消恢复行为
- **PID 检查代替区域判断**：直接检查元素是否属于 Dock 进程
- **只拦截前台 App**：非前台 App 点击完全放行

### 3.6 SkyLightBridge 窗口操作

```
最小化（hideAppWindow）：
  SkyLightBridge.minimizeWindows(pid)     ← 主路径：CGWindowList + SLSOrderWindow(OUT)
    → tryMinimizeViaAX                    ← 降级1：AX kAXMinimizedAttribute
    → AppleScript miniaturize every window ← 降级2：Electron 应用 AX 不可写时

恢复（restoreAppWindow）：
  SkyLightBridge.restoreWindows(pid)      ← 主路径：缓存窗口ID + SLSOrderWindow(IN)
    → tryRestoreViaAX                     ← 降级1：AX 恢复 + activate
    → AppleScript                         ← 降级2
    → app.activate                        ← 最终兜底
```

**内部实现**：
- `dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight")` 动态加载
- `dlsym` 获取 `SLSMainConnectionID`、`SLSOrderWindow` 函数指针
- 最小化时缓存窗口 ID，恢复时优先用缓存（order out 后窗口不在屏幕上）
- 恢复时 `onScreenOnly: false` 查询所有窗口（含 off-screen）

### 3.7 恢复帧系统

```
快捷键分屏：
  WindowManagementService.performLayout
    → snapshot[pid][layout] = (originalFrame, appliedTargetFrame)  ← Toggle 恢复用
    → DragSplitService.registerSnappedFrame(pid, frame)            ← 拖拽恢复用

拖拽分屏：
  DragSplitService.applyLayout
    → dragSplitRestoreFrames[ref] = savedFrame                     ← 拖拽恢复用

清除时机：
  - Toggle 回退时两处都清除
  - App 终止时清除（clearRestoreFrames）
  - App 切换时清除旧 App 帧（activation observer）
```

---

## 四、CGEvent Tap 清单

| Tap | 所属 | 层级 / 位置 | 监听事件 |
|-----|------|-------------|----------|
| 键盘 | `HotkeyManager` | cgSessionEventTap / headInsert | keyDown + flagsChanged |
| 移动窗口 | `MoveWindowService` | cgSessionEventTap / headInsert | leftMouse 全系列 |
| 拖拽恢复 | `DragSplitService` | cgSessionEventTap / headInsert | leftMouseDown |
| Dock 点击 | `AppDelegate` | **cghidEventTap** / headInsert | **leftMouseUp only** |

**规则**：
- 后注册的先收到事件
- 多个 tap 监听同类事件时，每个 tap 都能看到事件，除非某个返回 `nil`（消费）
- Dock 点击 tap 始终返回 `Unmanaged.passUnretained(event)`（放行），从不消费事件

---

## 五、坐标系统

| 坐标系 | 原点 | Y 方向 | 使用场景 |
|--------|------|--------|----------|
| **Cocoa/AppKit** | 主屏左下角 | ↑ 向上 | `NSScreen.frame`、`NSEvent.mouseLocation` |
| **Quartz/CG** | 主屏左上角 | ↓ 向下 | `CGEvent.location`、`CGWindowList` bounds |
| **AX** | 主屏左上角 | ↓ 向下 | `kAXPositionAttribute`、`kAXSizeAttribute` |

**转换公式**：`axY = primaryScreenMaxY - cocoaY`

> `primaryScreenMaxY` = `NSScreen.screens.first?.frame.maxY ?? 0`

**注意**：AX 和 Quartz 使用相同的坐标系（左上原点 Y↓），可以直接比较。但 Cocoa 和 AX/Quartz 之间需要转换。

---

## 六、已知的坑

### 坑 1：AX 坐标系 ≠ Cocoa
`kAXPositionAttribute` 返回的 y 是距主屏**顶部**的距离，不是底部。和 AppKit 坐标系相反。忘记转换就会窗口飞到屏幕外。

### 坑 2：动画中 AX 可能暂时失效
窗口 resize 动画期间 `AXUIElementCopyAttributeValue` 可能返回错误。用 `getWindowFrame` 失败时重试一次。

### 坑 3：keyCode 0 = A 键
`UCKeyTranslate` 对 keyCode 0 返回 "a"。纯修饰键快捷键用 `UInt16.max` 作哨兵。

### 坑 4：flagsChanged 触发两次
按键和松手各触发一次。用 `formUnion` 累积 peak，松手时才触发纯修饰键快捷键。

### 坑 5：多个 headInsertEventTap 不互斥
每个 tap 都能看到事件。后注册的先执行。不要依赖"只有我消费了事件"的假设。

### 坑 6：AXValueCreate 返回 nil
可能返回 nil，不要强制解包。用 `if let` 或 `guard let`，配合 `CFGetTypeID` 检查。

### 坑 7：AXUIElementCopyElementAtPosition 不可靠
返回不稳定的中间 AX 元素（toolbar、group 等），无 pid。找窗口用 CGWindowList。

### 坑 8：WindowServer 拖拽期间 AX 改尺寸可能被覆盖
系统拖拽进行中通过 AX 改窗口尺寸会被 WindowServer 覆盖。必须在拖拽**开始前**（headInsertEventTap）改。

### 坑 9：WindowStateKey 用 title 会导致 key 不匹配
窗口标题可能随时变化（微信→微信(3条消息)），导致恢复帧查找失败。用 PID 作 key。

### 坑 10：AX frame 和 Cocoa pt 不能直接比较
`kAXPositionAttribute` 返回 y 从主屏顶部向下，而 `NSEvent.mouseLocation` 的 y 从底部向上。用 `CGRect.contains()` 比对前必须统一坐标系。

### 坑 11：Toggle 回退不能每次重新计算 targetFrame
`performLayout` 的 Toggle 判断曾每次都重新计算目标帧。由于动画结束时用 `pixelAligned` 四舍五入，而重新计算的 targetFrame 没有四舍五入，`isClose(to:tolerance:)` 可能失败。现在保存 `appliedTargetFrame`（首次应用时计算的值），Toggle 时用内存中的值对比。

### 坑 12：Dock 点击事件回调中同步操作导致右键菜单
在 cghidEventTap 回调中同步执行 `hideAppWindow`（含枚举窗口 + SLSOrderWindow）会阻塞事件回调，系统误判为长按触发右键菜单。**必须后台线程执行最小化，回调立即返回**。

### 坑 13：Dock 点击后窗口被系统弹回
Dock 原生行为：点击前台 App 图标 → 最小化最前窗口 → 再点恢复。用 event tap 最小化后，Dock 仍会收到 mouseUp 事件并尝试恢复。**解决：`event.location = (0,0)` 瞬移鼠标坐标**，让 Dock 以为用户拖走了鼠标，取消恢复行为。

### 坑 14：SLSOrderWindow 对 Electron 应用窗口 order out 后无法恢复
order out 后的窗口不再出现在 `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` 中。**解决：最小化时缓存窗口 ID 到 `minimizedWindowCache[pid]`，恢复时优先用缓存；缓存不存在时用 `onScreenOnly: false` 查询所有窗口。**

### 坑 15：AXUIElement 非 CFType 时强制解包会崩溃
`AXUIElement` 是 toll-free bridged 类型，`as? AXUIElement` 永远成功。正确做法是用 `CFGetTypeID(parent) == AXUIElementGetTypeID()` 做类型检查。

### 坑 16：CGEvent tap 回调中 passRetained 导致内存泄漏
`Unmanaged.passRetained(event)` 会给 event +1 retain count，系统不会释放额外的引用。CGEvent tap 回调统一使用 `Unmanaged.passUnretained(event)`。

---

## 七、修改代码前检查清单

1. ✅ 我的改动需要改几个文件？列出所有
2. ✅ 坐标系统：我在用 Cocoa 还是 AX/Quartz 坐标？需要转换吗？
3. ✅ 线程安全：CGEvent tap 回调不在主线程，访问 @MainActor 属性需要 `DispatchQueue.main.sync`
4. ✅ 事件回调不能阻塞：cghidEventTap 回调中禁止同步执行耗时操作（枚举窗口、AX 查询）
5. ✅ 恢复帧：保存时是否同步了 `registerSnappedFrame`？清除时是否同步了 `clearSnappedFrame`？
6. ✅ UI Token：所有颜色/字号/间距都来自 `UIConfig` 吗？
7. ✅ 类型安全：AXValue/AXUIElement 强制解包前加了 `CFGetTypeID` 检查吗？
8. ✅ 构建：`xcodebuild -project MagicStage.xcodeproj -scheme MagicStage -configuration Debug build`

---

> **最后更新**：2026-07-04（清理冗余代码 + 新增坑 15/16 + 更新目录结构）
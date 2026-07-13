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
| Dock 窗口预览 | `WindowPreviewService` | 鼠标悬停 Dock 图标 |
| 触控反馈 | 各 Service 独立开关 | 拖拽分屏/预览弹出/最小化/Dock 退出时震动 |
| 自动更新 | `UpdaterService` + Sparkle | 后台自动 / 手动检查 |

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
      WindowPreviewService.swift      ← Dock 窗口预览（CG+SC+AX 三层检测）
    Extensions/
      AXUIElement+Extensions.swift      ← Dock AX 工具方法（dockAXElement/flattenAXElements/hasAXPosition/axElementFrame/axElementTitle/findRunningApp）
      CGEventFlags+NSEventModifiers.swift ← CGEventFlags → NSEvent.ModifierFlags
  Features/
    WindowManagement/
      WindowManagementSettingsView.swift  ← 分屏布局 + 移动窗口快捷键设置
      DragSplitPanelView.swift            ← 分屏面板卡片 UI
    WindowMinimize/
      WindowMinimizeSettingsView.swift    ← 最小化快捷键 + Dock 反转设置
    WindowPreview/
      WindowPreviewSettingsView.swift     ← 窗口预览设置
    DockQuit/
      DockHoverQuitSettingsView.swift     ← Dock 退出快捷键
    HapticFeedback/
      HapticFeedbackSettingsView.swift    ← 触控反馈设置（拖拽分屏/预览/最小化/Dock 退出震动）
    SystemSettings/
      SystemSettingsView.swift            ← 系统设置（开机启动、版本/更新/自动更新）
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
    WindowPreviewPanel.swift          ← 窗口预览 NSPanel + SwiftUI 卡片 UI
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
  → 超过阈值（8pt）→ beginDrag 保存原始 frame + 停掉动画 Timer
  → 统一阶段处理 handleDragStage：
     idle → 进入热区 → 显示 peek 条（高 20pt，从菜单栏滑出）
     peeking → 拖到 peek 条上 → 展开面板（peek→expand）
     expanded → 悬停布局卡片 → 显示预览 + 震动
  → 用户松手 → applyLayout() 保存恢复帧到 dragSplitRestoreFrames（PID key）
  → AX 动画窗口到目标位置
```

### 3.3 拖拽恢复尺寸

```
快捷键分屏或拖拽分屏后，用户拖标题栏恢复原尺寸：
  → DragSplitService 独立 CGEvent tap（headInsertEventTap）
  → leftMouseDown → tryCreateTitleBarOverlay：PID key 匹配恢复帧 → 创建 TitleBarDragOverlay
  → leftMouseDragged → overlay 负责窗口移动 + handleOverlayHotZone 并行热区检测
  → 超过拖拽阈值 → startDragAt：
      1. setAXSize 恢复原始尺寸（SkyLightBridge CG 路径保持原位置仅改尺寸）
      2. setAXOrigin 修正位置，约束右边界不超出 visibleFrame
  → handleDrag：显式传 restoreSize 用 setAXFrame 更新位置（不依赖系统返回的旧尺寸）
  → leftMouseUp → 保存 stage/layout/window → routeOverlayUp → applyLayout（若在 expanded）
```

**关键决策**：
- **PID 做 key**：`AXWindowRef(pid:)` 统一存储和查找，applyLayout/tryCreateTitleBarOverlay/tryRestoreSnappedWindow 都用 PID key
- **beginDrag 保存 dragSplitPreDragFrame**：在拖拽开始时（而非 applyLayout 时）捕获原始 frame
- **动画 Timer 管理**：新增 `animationTimer` 属性，beginDrag/overlay 创建时立即 invalidate，防止分屏动画覆盖恢复操作
- **handleDrag 显式传 restoreSize**：用 `setAXFrame(origin:size:)` 而非 `setAXOrigin`，避免 SkyLightBridge 内部读窗口旧尺寸
- **右边界约束**：startDragAt 中 clamp expectedOrigin.x 不超过 `visibleFrame.maxX - restoreSize.width`，防止 macOS 拒绝超出屏幕的尺寸恢复

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

### 3.8 Dock 窗口预览（WindowPreviewService）

**鼠标悬停 Dock 图标 → 显示该应用所有窗口缩略图 → 点击激活/关闭**

```
鼠标悬停 Dock 图标
  → NSEvent mouseMoved 监听 → detectDockIcon() AX 定位 Dock 图标
  → Dock 图标识别：遍历 Dock AX 子元素 → 过滤 AXDockItemRole → 选面积最小命中项
  → 应用匹配：优先 AXURL → bundleURL 精确比较，名称匹配仅作兜底
  → 获取 PID + Dock 图标物理边框
  → 面板已显示？ → switchToTarget(pid)：直接更新内容 + 面板位移动画
  → 面板未显示？ → showThumbnails(pid):
      1. CG 层窗口白名单（getCGWindowInfo）
         CGWindowListCopyWindowInfo(.optionAll) + layer==0 + alpha>0.1
         返回 (ids, titles, entries) 三元组
      2. SC 候选窗口过滤（SCShareableContent）
         同 PID + 尺寸>120x120 + windowID 在 CG 白名单中
      3. AX 硬过滤 + 幽灵检测（getAXWindows + scMatchesAXFromPool）
         - AX 树不为空（Typora/QQ/微信）→ 硬过滤 + 一对一消耗 + 幽灵检测
         - AX 树为空（VS Code/网易云）→ 软过滤 + 本地去重
      4. 并行截图（TaskGroup）
         - SkyLightBridge.captureWindow（CGSHWCaptureWindowList）← 主路径
         - 降级：SCScreenshotManager.captureImage
         - 降级：CGWindowListCreateImage（全屏窗口跨 Space）
      5. 显示预览面板（NSPanel + SwiftUI）
```

**Dock 图标识别（detectDockIcon）**：
- 展开 Dock 进程 AX 树，遍历所有子元素
- `AXDockItemRole` 过滤，只处理 Dock 图标
- `axElementFrame` 检查鼠标是否在图标范围内，选面积最小的命中项
- **优先通过 AXURL → bundleURL 精确匹配**（`standardizedFileURL` 比较），解决 VS Code/Cursor 等 Electron 应用 AXTitle 相同导致误匹配
- 名称匹配仅作兜底（AXURL 不可用时），**AXURL 存在但找不到运行中应用时跳过名称回退**（避免已退出 App 误匹配到同名应用）

**窗口检测三层架构**：

| 层 | API | 用途 | 过滤条件 |
|---|---|---|---|
| CG | `CGWindowListCopyWindowInfo` | 窗口白名单 | layer==0 + alpha>0.1 |
| SC | `SCShareableContent` | 截图源 | 同 PID + 尺寸>120x120 + 在 CG 白名单中 |
| AX | `kAXWindowsAttribute` | 真实窗口校验 | 标题+尺寸联合强校验 + 一对一消耗 |

**幽灵窗口检测四层防线**：

1. **CG Alpha 过滤**：`kCGWindowAlpha > 0.1`（Electron 隐藏白板 alpha=0）
2. **AX 白名单强校验**：SC 窗口必须在 AX 树中匹配（标题 AND 尺寸）
3. **AX 内部去重**：相同（标题+尺寸）的 AX 窗口只保留第一个（防止 Typora 缓存白板注册到 AX）
4. **一对一消耗**：每个 AX 窗口只能被一个 SC 匹配（防止搭便车）
5. **isOnscreen 防御**：`!cgIsOnscreen && !axIsMinimized && !appIsHidden` → 丢弃

**智能退避机制**：
- AX 树不为空 → 严格强校验（Typora/QQ/微信/Safari）
- AX 树为空 → 软过滤（VS Code/网易云等 Electron/自研 GUI 应用）

**激活窗口（DockDoor bringToFront 风格）**：
1. `SkyLightBridge.bringWindowToFront` — `_SLPSSetFrontProcessWithOptions` + `makeKeyWindow`
2. AX `kAXRaiseAction` — 精确操纵窗口
3. AX `kAXMainAttribute=true` — 设置主窗口
- 注意：**不使用** `NSApp.activate` 或 `NSRunningApplication.activate`（会抢占前台焦点）
- 3 次重试，每次间隔 50ms

**关闭窗口降级路径**：
1. AX `kAXCloseButtonAttribute` + `kAXPressAction` — 模拟点击关闭按钮
2. AppleScript `tell application "System Events" to keystroke "w" using command down` — AX 失败降级（网易云等无 AX 树应用）

**截图三级降级路径**：
1. `SkyLightBridge.captureWindow`（`CGSHWCaptureWindowList`，通过 `@_silgen_name` 声明）— 主路径，速度最快
2. `SCScreenshotManager.captureImage` — SC 降级
3. `CGWindowListCreateImage` — 最终降级（全屏窗口跨 Space）
- 三者都失败才返回占位图，绝不返回 nil

**Panel 容器圆角方案（RoundedVisualEffectView）**：
- `NSVisualEffectView` 子类，`material=.hudWindow` 毛玻璃材质
- `maskImage`（NSImage 圆角矩形）裁切材质到圆角 — `layer.cornerRadius` 不裁切材质渲染
- `layer.cornerRadius=16` + `masksToBounds=true` 裁切 hostingView 内容到圆角
- `TransparentHostingView`（NSHostingView 子类，`isOpaque=false`）确保不绘制矩形背景
- SwiftUI overlay `RoundedRectangle.stroke` 灰色描边
- 无阴影（用户选择去掉）

**FlowLayout 自动换行布局**：
- macOS 13+ `Layout` 协议，替换 `ScrollView+HStack`
- 超屏幕宽度自动换行，无 maxColumns 限制
- `updatePanelFrame` 中同步模拟 FlowLayout 换行逻辑计算面板尺寸

**连续 Dock 切换（switchToTarget）**：
- 面板已显示时，鼠标移到新 Dock 图标，不重新触发入场动画
- 直接同时更新 `activeWindows` + `visibleWindowIDs`（保持同步避免闪烁）
- 面板位移动画到新位置（`NSWindow.setFrame` 动画）
- **不做淡入淡出**（之前淡入淡出导致 activeWindows 和 visibleWindowIDs 不同步，卡片瞬间消失）

**窗口数量自动检测（checkWindowCountChanged）**：
- `trackingTimer` 每 0.5s 检测一次窗口变化
- 用 `lastCheckedWindowIDs` 记录上次检测结果，只检测新增窗口
- **不与 `activeWindows` 比较**（getCGWindowInfo 返回的集合含未过 SC/AX 过滤的窗口，差异会导致误判）
- 检测到新窗口时调用 `switchToTarget` 重新捕获

**卡片入场动画（StaggeredCardWrapper）**：
- `@State animateIn` 驱动 opacity + scale + offset
- `.animation(.spring.delay(index * 0.04), value: animateIn)` 自动触发动画
- `onAppear` 中直接 `animateIn = true`（**不用 DispatchQueue.main.async + withAnimation**，那会导致闪烁）
- `.transition(.asymmetric(insertion: .identity, removal: .opacity + .move(.bottom)))`

**点击缩略图出场动画（CATransaction）**：
- `CATransaction` 驱动 `panel.contentView.layer.opacity` 从 1→0
- Core Animation 层级，**不受 App 焦点切换影响**（NSAnimationContext 的 alphaValue 会被打断）
- 延迟 50ms 后再激活窗口，让动画起手不被打断

### 3.9 离屏窗口预览拼接（padOffScreenImage）

**问题**：窗口部分拖出屏幕时，WindowServer 只渲染屏幕内像素，`CGSHWCaptureWindowList`/`SCScreenshotManager`/`CGWindowListCreateImage` 三级截图都只能拿到可见部分，缩略图被截断。

**方案**：按窗口真实尺寸（`windowFrame`）创建画布，清晰截图叠加在正确位置，超出方向的边缘用各向异性距离场羽化，自然融入卡片背景。

```
padOffScreenImage(image, windowFrame, screenUnion, scale)
  → 截图像素尺寸 vs windowFrame×scale 比较（2px 误差），一致则返回原图
  → visibleRect = windowFrame ∩ screenUnion（CG 坐标系）
  → 可见区域过小（<20pt）直接返回原图（兜底，避免几乎全透明）
  → 创建画布（窗口完整尺寸 × scale，premultipliedLast alpha）
  → 清晰图位置：clearX = (visibleRect.minX - windowFrame.minX) × scale
                 clearY = (windowFrame.maxY - visibleRect.maxY) × scale（Y 翻转）
  → 各方向填充量：leftPad/rightPad/topPad/bottomPad
  → 自适应羽化：各方向 feather = min(40×scale, 该方向填充量×0.8)
  → makeFeatherMask 生成距离场 mask
  → context.clip(to: clearRect, mask: clearMask) + context.draw(image, in: clearRect)
```

**距离场 mask（makeFeatherMask）核心算法**：

```
1. 降采样：mask 长边降到 ~500px（减少 16x 计算量），shouldInterpolate=true
   让 CGContext.clip(to:mask:) 自动双线性插值放大

2. 内部矩形：羽化方向向内收缩对应 feather 像素
   innerLeft   = fadeLeft   ? feather : 0
   innerRight  = fadeRight  ? width - feather : width
   innerTop    = fadeTop    ? feather : 0
   innerBottom = fadeBottom ? height - feather : height

3. 各向异性归一化距离（支持各方向不同羽化宽度，角落等值线为椭圆弧）：
   dx = max(innerLeft - x, 0, x - innerRight)
   dy = max(innerTop - y, 0, y - innerBottom)
   ndx = dx > 0 ? (x < innerLeft ? dx/featherLeft : dx/featherRight) : 0
   ndy = dy > 0 ? (y < innerTop ? dy/featherTop : dy/featherBottom) : 0
   ndist = sqrt(ndx² + ndy²)

4. smoothstep 缓动（比线性更柔和，两端平滑）：
   t = 1 - ndist
   alpha = t² × (3 - 2t)
```

**四个优化点**：

| 优化 | 实现 | 效果 |
|---|---|---|
| 性能 | mask 降采样到 ~500px + 插值放大 | 减少 16x 计算量，视觉无差别 |
| 缓动 | smoothstep 替代线性 | 过渡两端平滑，像 macOS 原生效果 |
| 自适应羽化 | 各方向独立 `min(40×scale, 填充量×0.8)` | 填充量小时羽化带不超过填充区 |
| 兜底 | 可见区域 <20pt 直接返回原图 | 避免几乎全透明的无意义结果 |

**关键决策**：
- **纯透明渐变，无填充内容**：超出部分直接透出卡片背景，不依赖窗口边缘像素（避免杂乱边缘延伸显脏）
- **各向异性距离场**：各方向羽化宽度独立，角落等值线为椭圆弧（非正圆），适配不同填充量
- **smoothstep 缓动**：`t²(3-2t)` 比线性过渡更柔和，过渡起止处变化率趋近 0
- **CGImage 数据坐标**：y=0 是顶部，y=height-1 是底部（与 CGContext 左下原点不同）

---

## 四、CGEvent Tap 清单

| Tap | 所属 | 层级 / 位置 | 监听事件 |
|-----|------|-------------|----------|
| 键盘 | `HotkeyManager` | cgSessionEventTap / headInsert | keyDown + flagsChanged |
| 移动窗口 | `MoveWindowService` | cgSessionEventTap / headInsert | leftMouse 全系列 |
| 拖拽恢复 | `DragSplitService` | cgSessionEventTap / headInsert | leftMouseDown |
| Dock 点击 | `AppDelegate` | **cghidEventTap** / headInsert | **leftMouseUp only** |
| 窗口预览 | `WindowPreviewService` | NSEvent monitor（非 CGEvent tap） | mouseMoved |

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

### 坑 17：NSHostingView isOpaque=true 导致容器"直角包圆角"
`NSHostingView` 默认 `isOpaque=true`，系统会绘制矩形不透明背景。即使设置 `layer?.backgroundColor=.clear` 也无效，因为 `isOpaque` 标志告诉系统该视图不透明。**解决：用普通 `NSView` 作为 contentView，`layer.cornerRadius=16` + `layer.backgroundColor=controlBackgroundColor`，NSHostingView 作为子视图完全透明叠加**。

### 坑 18：VS Code/网易云 AX 树为空导致窗口预览失败
VS Code（Electron 默认关闭 Accessibility）和网易云（自研 GUI 不注册 AX）的 `kAXWindowsAttribute` 返回空数组。如果在窗口检测中把 AX 作为硬过滤器，这些应用的窗口会被全部丢弃。**解决：智能退避机制 — AX 树为空时降级到 CG+SC 软过滤 + 本地去重**。

### 坑 19：Electron 应用幽灵窗口（Typora 缓存白板）
Typora 等 Electron 应用会保留已关闭窗口的缓存白板（Exposé 调度中心缓存），它们：layer=0、alpha=1.0、有标题、有尺寸，与真实窗口完全一样。**解决：AX 内部去重（相同标题+尺寸只保留一个）+ 一对一消耗（每个 AX 窗口只能被一个 SC 匹配）+ isOnscreen 防御（!cgIsOnscreen && !axIsMinimized && !appIsHidden → 丢弃）**。

### 坑 20：网易云点击缩略图无法激活
网易云无 AX 树，`activateWindow` 的 AX 路径（kAXRaiseAction 等）直接 return，无法激活窗口。**解决：AX 失败时降级到 AppleScript `tell application "X" to activate`**。

### 坑 21：全屏窗口跨 Space 截图失败
全屏窗口在另一个 Space，`SCScreenshotManager.captureImage` 可能失败。**解决：SC 失败时降级到 `CGWindowListCreateImage`（通过 `CFBundleGetFunctionPointerForName` 从 CoreGraphics bundle 获取函数指针）**。

### 坑 22：SC 截图失败时窗口被静默跳过
之前 `guard let cgImage = try? await SCScreenshotManager.captureImage(...) else { return nil }` 失败时返回 nil，该窗口被跳过。用户看到"某些软件预览不了"。**解决：SC 失败 → CGWindowListCreateImage 降级 → 两者都失败才返回 nil**。

### 坑 23：NSVisualEffectView layer.cornerRadius 不裁切材质
`NSVisualEffectView` 的材质渲染在特殊路径，`layer.cornerRadius` 和 `layer.mask` 都不会裁切材质本身。设置后看到"直角里面包裹圆角"——直角是材质的矩形渲染，圆角是 layer 的 border/sublayer 裁切。**解决：用 `RoundedVisualEffectView` 子类，设置 `maskImage`（NSImage 圆角矩形）裁切材质到圆角。`maskImage` 是 NSVisualEffectView 专用属性，用 image 的 alpha 通道裁切材质**。

### 坑 24：switchToTarget 中 activeWindows 和 visibleWindowIDs 不同步导致闪烁
`switchToTarget` 中先更新 `activeWindows`（新应用窗口），但 `visibleWindowIDs` 还是旧的（旧应用窗口 ID）。ForEach 用新的 `activeWindows` 遍历，但 `visibleWindowIDs.contains(window.id)` 为 false，导致所有卡片瞬间消失。0.15s 后 `visibleWindowIDs` 更新，卡片才重新出现。**解决：去掉淡入淡出，同时更新 `activeWindows` + `visibleWindowIDs`（保持同步），面板位移动画到新位置**。

### 坑 25：DispatchQueue.main.async + withAnimation 导致入场闪烁
卡片入场动画用 `DispatchQueue.main.async { withAnimation { animateIn = true } }` 延迟一帧触发动画，但在这帧之间 SwiftUI 渲染时序不确定，卡片可能先用 `animateIn=true` 状态闪现，再回到 `false`，最后动画到 `true`。**解决：改用 `.animation(.spring.delay(index * 0.04), value: animateIn)`，`onAppear` 中直接 `animateIn = true`。`.animation(value:)` 在值变化时自动触发动画，不需要手动管理时序**。

### 坑 26：getCGWindowInfo 与 activeWindows 差异导致误判新窗口
`getCGWindowInfo` 返回所有 layer==0 + alpha>0.1 的窗口（含被 SC/AX 过滤的），而 `activeWindows` 只含通过过滤的。两者差异导致每次检测都误判有"新窗口"，频繁触发 `switchToTarget` 的淡入淡出，造成持续闪烁。**解决：用 `lastCheckedWindowIDs` 记录上次 `getCGWindowInfo` 的检测结果，只与上次比较，不与 `activeWindows` 比较**。

### 坑 27：NSAnimationContext alphaValue 动画被窗口激活打断
点击缩略图激活窗口时，`NSAnimationContext` 的 `animator().alphaValue` 动画会被 `SkyLightBridge.bringWindowToFront`（改变前台进程）打断，导致面板直接消失无出场动画。**解决：改用 `CATransaction` 驱动 `panel.contentView.layer.opacity` 从 1→0（Core Animation 层级，不受 App 焦点切换影响），延迟 50ms 后再激活窗口**。

### 坑 28：同一应用面板隐藏后鼠标回到 Dock 不重新显示
`triggerHoverCheck` 中只在 `info.pid != currentHoverPID` 时触发 `showThumbnails`。调节设置后面板隐藏，鼠标回到 Dock 时 `currentHoverPID` 没变，不会重新显示。**解决：新增 `else if !isPanelVisible` 分支，同一应用但面板已隐藏时重新触发 `showThumbnails`**。

### 坑 29：已退出 App 误匹配到同名应用（Codex → VS Code）
`detectDockIcon` 用 AXTitle（如 "Code"）通过 `findRunningApp` 匹配，如果 Codex 已退出，"Code" 会误匹配到 VS Code。**解决：AXURL 存在时优先 URL bundle 精确匹配，名称仅兜底；AXURL 存在但找不到运行中应用时跳过名称回退**。

### 坑 30：预览面板遮挡右键菜单
NSPanel floating 层级 + clickThrough 行为会拦截右键点击事件。**解决：添加 `globalClickMonitor`（NSEvent addGlobalMonitorForEvents），面板显示时检测 Dock 区域点击（左/右/中键），立即隐藏面板**。

### 坑 31：离屏窗口缩略图截断
窗口部分拖出屏幕时，`CGSHWCaptureWindowList`/`CGWindowListCreateImage` 只返回可见部分，缩略图被截断。**解决：`padOffScreenImage` 按窗口真实尺寸创建画布，清晰截图叠加在正确位置，超出方向的边缘用各向异性距离场羽化（smoothstep 缓动 + 圆角过渡），自然融入卡片背景**。详见 3.9 节。

### 坑 32：minimizedWindowCache 线程安全
`minimizedWindowCache` 在后台线程写入、主线程读取。**解决：`cacheLock = NSLock()` 保护读写操作**。

### 坑 33：hasAXPosition 与 DockHoverQuitService 不一致
`WindowPreviewService` 和 `DockHoverQuitService` 各有独立 `hasAXPosition` 实现，曾经过滤阈值不一致。**解决：抽取到 `AXUIElement+Extensions.swift` 统一实现，保持 `sz.width > 0 && sz.height > 0 && sz.width < 500 && sz.height < 500`**。

### 坑 34：closeWindowAndAnimate 未同步 lastCheckedWindowIDs
关闭窗口后 `lastCheckedWindowIDs` 未同步，导致 `checkWindowCountChanged` 误判新窗口。**解决：关闭窗口时同时更新 `lastCheckedWindowIDs.remove(closedWindowID)`**。

### 坑 35：terminationObserver 重复注册
每次 `showThumbnails` 都通过 `addObserver` 注册新的 `NSWorkspace.didTerminateApplication` 通知，累积多个 observer。**解决：用 `terminationObserver` 属性 + `removeObserver` 防止重复**。

### 坑 36：findRunningApp 两处重复
`WindowPreviewService` 和 `DockHoverQuitService` 各自实现相同的 `findRunningApp`（5 级匹配策略），修改时需同步两处。**解决：移到 `AXUIElement+Extensions.swift` 统一实现**。

### 坑 37：applyLayout ↔ tryCreateTitleBarOverlay Key 不匹配
`applyLayout` 曾用 `AXWindowRef(element: window)`（windowID key）存储恢复帧，但 `tryCreateTitleBarOverlay` 用 `AXWindowRef(pid: pid)`（PID key）查找，导致拖拽分屏后恢复失败。**解决：统一使用 PID key**。

### 坑 38：TitleBarDragOverlay 阻塞热区检测
Overlay 活跃时 `pollMousePosition` 直接 return，跳过热区检测，快捷键分屏后 peek 条不出现。**解决：restoreTap 的 leftMouseDragged 中调用 `handleOverlayHotZone` 并行热区检测；leftMouseUp 中保存状态后 applyLayout**。

### 坑 39：分屏动画 Timer 覆盖恢复操作
`animateAXWindow` 的 0.2s Timer 在分屏后继续跑，用户立即拖拽时 Timer 覆盖 overlay 的 `setAXSize`，导致尺寸不恢复 + 窗口拖不动。**解决：新增 `animationTimer` 属性，所有拖拽入口 invalidate**。

### 坑 40：startDragAt 两步调用导致视觉卡顿
`setAXSize` + `setAXOrigin` 分两次窗口服务调用，大尺寸差（全高→600px）时两次视觉刷新。**解决：尝试合并为一次 `setAXFrame`，但 `axToCG` 坐标转换使用 `primaryScreenMaxY` 与当前位置不一致导致右半屏失败，回退为两步调用。`handleDrag` 中显式传 `restoreSize` 而非依赖 `setAXOrigin` 内部读旧尺寸**。

### 坑 41：visibleFrame y 约束用错坐标系
`visibleFrame.origin.y` 是 Cocoa 坐标（底部原点），`expectedOrigin.y` 是 AX 坐标（顶部原点），直接比较导致窗口 y 被推到错误位置，标题栏和指针错位。**解决：仅保留 x 轴约束（两坐标系 x 原点相同），移除 y 约束**。

### 坑 42：DockHoverQuitService 未实现 ObservableObject
HapticFeedbackSettingsView 中 `@ObservedObject` 绑定 `DockHoverQuitService.shared` 编译报错。**解决：`DockHoverQuitService` 添加 `: ObservableObject` 协议**。

### 坑 43：Sparkle 更新窗口显示英文
`CFBundleDevelopmentRegion` 未设置，`developmentRegion = en`，Sparkle 默认显示英文 UI。**解决：`Info.plist` 添加 `CFBundleDevelopmentRegion = zh-Hans`，`project.pbxproj` 中 `developmentRegion` 改为 `zh-Hans`，`knownRegions` 添加 `"zh-Hans"`**。

### 坑 44：UpdaterService 未跟踪更新状态导致一直显示"正在检查…"
`updateAvailable` 初始为 nil，Sparkle 的首次后台检查不触发 delegate 回调或回调在 configure 之前已完成。**解决：`configure(with:)` 中检查 `lastUpdateCheckDate != nil` → 默认 `updateAvailable = false`。通过 `SPUUpdaterDelegate`（`didFindValidUpdate`/`didNotFindUpdate`）追踪后续检查结果**。

---

## 七、修改代码前检查清单

1. ✅ 我的改动需要改几个文件？列出所有
2. ✅ 坐标系统：我在用 Cocoa 还是 AX/Quartz 坐标？需要转换吗？
3. ✅ 线程安全：CGEvent tap 回调不在主线程，访问 @MainActor 属性需要 `DispatchQueue.main.sync`
4. ✅ 事件回调不能阻塞：cghidEventTap 回调中禁止同步执行耗时操作（枚举窗口、AX 查询）
5. ✅ 恢复帧：保存时是否同步了 `registerSnappedFrame`？清除时是否同步了 `clearSnappedFrame`？
6. ✅ UI Token：所有颜色/字号/间距都来自 `UIConfig` 吗？
7. ✅ 类型安全：AXValue/AXUIElement 强制解包前加了 `CFGetTypeID` 检查吗？
8. ✅ 窗口预览：AX 树为空时是否走了智能退避？SC 截图失败时是否降级到 CGWindowListCreateImage？
9. ✅ 窗口预览动画：是否用了 `.animation(value:)` 而非 `DispatchQueue.main.async + withAnimation`？`activeWindows` 和 `visibleWindowIDs` 是否同时更新？
10. ✅ 窗口预览材质：液态玻璃开关切换后是否调用了 `rebuildPanel()`？圆角描边是否用 `.strokeBorder` + `style:.continuous`（避免圆角处变粗）？
11. ✅ 构建：`xcodebuild -project MagicStage.xcodeproj -scheme MagicStage -configuration Debug build`

---

> **最后更新**：2026-07-13（新增 3.9 离屏窗口预览拼接 padOffScreenImage：距离场羽化 + smoothstep 缓动 + 自适应羽化 + 降采样性能优化；更新坑 31 为已解决）
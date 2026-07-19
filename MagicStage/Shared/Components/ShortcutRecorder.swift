import SwiftUI

// MARK: - 统一快捷键录制器

/// 通用快捷键录制控件，支持普通组合键（如 ⌘A）和纯修饰键（如 ⌘⌃），
/// 统一内部维护录制状态，通过 onRecord/onClear 回调通知调用方。
///
/// 使用示例：
/// ```swift
/// ShortcutRecorderView(
///     shortcut: KeyboardShortcut.empty,
///     isRecording: $isRecording,
///     isEnabled: true,
///     onRecord: { startRecordingWithHotkeyManager() },
///     onClear: { clearShortcut() }
/// )
/// ```
struct ShortcutRecorderView: View {
    let shortcut: KeyboardShortcut
    let isRecording: Bool
    let isEnabled: Bool
    var onRecord: (() -> Void)?
    var onClear: (() -> Void)?

    @State private var isPressed = false
    @State private var showCursor = true
    @State private var cursorTimer: Timer?
    @State private var focusRingScale: CGFloat = UIConfig.ShortcutRecorder.focusRingInitialScale
    @State private var focusRingOpacity: Double = 0

    private var hasShortcut: Bool { shortcut.keyCode != 0 || shortcut.modifierFlags != 0 }
    private var displayText: String { shortcut.displayString }

    var body: some View {
        ZStack(alignment: .trailing) {
            // 录制区域——点击触发录制
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Text(isRecording
                    ? "按下按键"
                    : (!hasShortcut ? "设置" : displayText))
                    .font(.system(size: UIConfig.Typography.recorderTextSize,
                                  weight: hasShortcut ? .medium : .regular))
                    .foregroundColor(foregroundColor)
                    .lineLimit(1)
                    .layoutPriority(1)
                    .overlay(alignment: .leading) {
                        if isRecording {
                            Rectangle()
                                .fill(Color.accentColor)
                                .frame(width: UIConfig.ShortcutRecorder.cursorWidth,
                                       height: UIConfig.ShortcutRecorder.cursorHeight)
                                .opacity(showCursor ? UIConfig.ShortcutRecorder.cursorVisibleOpacity : 0)
                                .offset(x: UIConfig.ShortcutRecorder.cursorOffsetX)
                        }
                    }
                Spacer(minLength: 0)
                // 清除按钮占位，保持文字居中
                if hasShortcut && !isRecording {
                    Color.clear
                        .frame(width: UIConfig.Typography.recorderClearIconSize + UIConfig.ShortcutRecorder.horizontalPadding)
                }
            }
            .padding(.horizontal, UIConfig.ShortcutRecorder.horizontalPadding)
            .frame(width: UIConfig.ShortcutRecorder.minWidth,
                   height: UIConfig.ShortcutRecorder.minHeight)
            .background(
                RoundedRectangle(
                    cornerRadius: UIConfig.ShortcutRecorder.cornerRadius, style: .continuous)
                    .fill(UIConfig.ShortcutRecorder.backgroundColor)
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: UIConfig.ShortcutRecorder.cornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(UIConfig.ColorTokens.recorderBorderIdleOpacity),
                            lineWidth: UIConfig.Card.borderWidth)
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: UIConfig.ShortcutRecorder.cornerRadius, style: .continuous)
                    .stroke(Color.accentColor.opacity(focusRingOpacity),
                            lineWidth: UIConfig.ShortcutRecorder.focusRingLineWidth)
                    .scaleEffect(focusRingScale)
                    .opacity(focusRingOpacity)
                    .allowsHitTesting(false)
            )
            .contentShape(RoundedRectangle(
                cornerRadius: UIConfig.ShortcutRecorder.cornerRadius, style: .continuous))
            .onTapGesture {
                guard isEnabled, !isRecording else { return }
                withAnimation(.easeOut(duration: UIConfig.Animation.pressScaleDuration)) {
                    isPressed = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + UIConfig.Animation.pressScaleDuration) {
                    withAnimation(.easeOut(duration: UIConfig.Animation.pressScaleDuration)) {
                        isPressed = false
                    }
                }
                onRecord?()
            }

            // 清除按钮——ZStack 顶层，独立接收点击，不被底部 onTapGesture 干扰
            if hasShortcut && !isRecording {
                Button {
                    onClear?()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: UIConfig.Typography.recorderClearIconSize))
                        .foregroundColor(.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("清空快捷键")
                .padding(.trailing, UIConfig.ShortcutRecorder.horizontalPadding)
            }
        }
        .allowsHitTesting(isEnabled)
        .scaleEffect(isPressed && isEnabled ? UIConfig.ShortcutRecorder.pressScale : 1.0)
        .animation(.spring(response: UIConfig.Animation.recordingSpringResponse,
                           dampingFraction: UIConfig.Animation.recordingSpringDamping),
                   value: isRecording)
        .animation(.easeOut(duration: UIConfig.Animation.pressScaleDuration), value: isPressed)
        .onChange(of: isRecording) { _, recording in
            if recording {
                startCursorBlink()
                animateFocusRingIn()
            } else {
                stopCursorBlink()
                animateFocusRingOut()
                HotkeyManager.shared.cancelRecording()
            }
        }
        .onDisappear { stopCursorBlink() }
    }

    // MARK: - 文字颜色

    private var foregroundColor: Color {
        if !isEnabled { return UIConfig.ColorTokens.foregroundDisabled }
        if isRecording { return UIConfig.ColorTokens.recorderRecordingText }
        if !hasShortcut { return UIConfig.ColorTokens.foregroundPlaceholder }
        return .primary
    }

    // MARK: - 光标闪烁

    private func startCursorBlink() {
        showCursor = true
        cursorTimer?.invalidate()
        cursorTimer = Timer.scheduledTimer(
            withTimeInterval: UIConfig.ShortcutRecorder.cursorBlinkInterval, repeats: true
        ) { _ in
            withAnimation(.easeOut(duration: UIConfig.Animation.cursorBlinkTransitionDuration)) {
                showCursor.toggle()
            }
        }
    }

    private func stopCursorBlink() {
        cursorTimer?.invalidate()
        cursorTimer = nil
        showCursor = true
    }

    // MARK: - 焦点环动画

    private func animateFocusRingIn() {
        focusRingScale = UIConfig.ShortcutRecorder.focusRingInitialScale
        focusRingOpacity = 0
        withAnimation(.spring(response: UIConfig.Animation.focusRingInSpringResponse,
                              dampingFraction: UIConfig.Animation.focusRingInSpringDamping)) {
            focusRingScale = 1.0
            focusRingOpacity = 1.0
        }
    }

    private func animateFocusRingOut() {
        withAnimation(.easeOut(duration: UIConfig.Animation.focusRingOutDuration)) {
            focusRingScale = 1.0
            focusRingOpacity = 0
        }
    }
}


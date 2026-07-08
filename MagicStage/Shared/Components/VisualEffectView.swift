import SwiftUI

// MARK: - Visual Effect NSViewRepresentable Wrappers

/// 侧边栏 - hudWindow 材质
/// 侧边栏使用，保持简单，不操作 layer
struct HudWindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.isEmphasized = true
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}



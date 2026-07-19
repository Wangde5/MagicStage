import ApplicationServices
import Foundation

/// 进程内稳定的窗口身份。PID 只能标识应用，不能区分同一应用的多个窗口。
struct WindowIdentity: Hashable {
    let pid: pid_t
    let token: UInt64

    init(pid: pid_t, windowID: UInt32) {
        self.pid = pid
        self.token = UInt64(windowID)
    }

    init(pid: pid_t, token: UInt64) {
        self.pid = pid
        self.token = token
    }

    init(window: AXUIElement) {
        var ownerPID: pid_t = 0
        AXUIElementGetPid(window, &ownerPID)
        pid = ownerPID

        if let windowID = SkyLightBridge.getWindowID(from: window), windowID != 0 {
            token = UInt64(windowID)
        } else {
            // 部分应用不暴露 CGWindowID；AX 元素的 CFHash 可在该进程生命周期内
            // 区分窗口。最高位用于避免与真实 UInt32 windowID 冲突。
            token = (UInt64(CFHash(window)) & 0x7fff_ffff_ffff_ffff) | 0x8000_0000_0000_0000
        }
    }
}

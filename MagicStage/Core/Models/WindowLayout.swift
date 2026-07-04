import Foundation
import AppKit
import CoreGraphics

// MARK: - 窗口布局类型

/// 定义所有窗口布局操作类型，每种布局对应一个窗口位置/大小的预设。
enum WindowLayout: String, CaseIterable, Codable {
    // 基础
    case maximize        // 最大化（充满屏幕可见区域）
    case center          // 居中（保持原始大小）

    // 半分屏
    case leftHalf        // 左半分屏
    case rightHalf       // 右半分屏

    // 比例分屏
    case leftTwoThirds   // 左三分之二
    case rightOneThird   // 右三分之一

    // 四宫格
    case quadTopLeft      // 左上
    case quadTopRight     // 右上
    case quadBottomLeft   // 左下
    case quadBottomRight  // 右下

    // MARK: - 显示信息

    var displayName: String {
        switch self {
        case .maximize:        return "最大化"
        case .center:          return "居中"
        case .leftHalf:        return "左半分屏"
        case .rightHalf:       return "右半分屏"
        case .leftTwoThirds:   return "左 2/3"
        case .rightOneThird:   return "右 1/3"
        case .quadTopLeft:     return "左上"
        case .quadTopRight:    return "右上"
        case .quadBottomLeft:  return "左下"
        case .quadBottomRight: return "右下"
        }
    }

    var description: String {
        switch self {
        case .maximize:        return "将窗口扩展至整个屏幕可见区域"
        case .center:          return "将窗口居中，保持原有大小"
        case .leftHalf:        return "窗口占据屏幕左半部分"
        case .rightHalf:       return "窗口占据屏幕右半部分"
        case .leftTwoThirds:   return "窗口占据屏幕左侧三分之二"
        case .rightOneThird:   return "窗口占据屏幕右侧三分之一"
        case .quadTopLeft:     return "窗口占据屏幕左上四分之一"
        case .quadTopRight:    return "窗口占据屏幕右上四分之一"
        case .quadBottomLeft:  return "窗口占据屏幕左下四分之一"
        case .quadBottomRight: return "窗口占据屏幕右下四分之一"
        }
    }

    /// 分组类别
    var category: LayoutCategory {
        switch self {
        case .maximize, .center:
            return .position
        case .leftHalf, .rightHalf,
             .leftTwoThirds, .rightOneThird,
             .quadTopLeft, .quadTopRight, .quadBottomLeft, .quadBottomRight:
            return .splitScreen
        }
    }

    // MARK: - 默认快捷键

    var defaultShortcut: KeyboardShortcut {
        switch self {
        case .maximize:        return KeyboardShortcut(keyCode: 46, modifiers: [.command, .option])
        case .center:          return KeyboardShortcut(keyCode: 8,  modifiers: [.command, .option])
        case .leftHalf:        return KeyboardShortcut(keyCode: 123, modifiers: [.command, .option])
        case .rightHalf:       return KeyboardShortcut(keyCode: 124, modifiers: [.command, .option])
        case .leftTwoThirds:   return KeyboardShortcut(keyCode: 33, modifiers: [.command, .option])
        case .rightOneThird:   return KeyboardShortcut(keyCode: 30, modifiers: [.command, .option])
        case .quadTopLeft:     return KeyboardShortcut(keyCode: 0,  modifiers: [])
        case .quadTopRight:    return KeyboardShortcut(keyCode: 0,  modifiers: [])
        case .quadBottomLeft:  return KeyboardShortcut(keyCode: 0,  modifiers: [])
        case .quadBottomRight: return KeyboardShortcut(keyCode: 0,  modifiers: [])
        }
    }

    // MARK: - 目标 Frame 计算（AX 坐标系：原点左上角）

    func targetFrame(screenAXFrame: CGRect, currentSize: CGSize) -> CGRect {
        let v = screenAXFrame
        switch self {
        case .maximize:
            return v
        case .center:
            return CGRect(
                x: v.origin.x + (v.width - currentSize.width) / 2,
                y: v.origin.y + (v.height - currentSize.height) / 2,
                width: currentSize.width,
                height: currentSize.height
            )
        case .leftHalf:
            return CGRect(x: v.origin.x, y: v.origin.y, width: v.width / 2, height: v.height)
        case .rightHalf:
            return CGRect(x: v.origin.x + v.width / 2, y: v.origin.y, width: v.width / 2, height: v.height)
        case .leftTwoThirds:
            return CGRect(x: v.origin.x, y: v.origin.y, width: v.width * 2 / 3, height: v.height)
        case .rightOneThird:
            return CGRect(x: v.origin.x + v.width * 2 / 3, y: v.origin.y, width: v.width / 3, height: v.height)
        case .quadTopLeft:
            return CGRect(x: v.origin.x, y: v.origin.y, width: v.width / 2, height: v.height / 2)
        case .quadTopRight:
            return CGRect(x: v.origin.x + v.width / 2, y: v.origin.y, width: v.width / 2, height: v.height / 2)
        case .quadBottomLeft:
            return CGRect(x: v.origin.x, y: v.origin.y + v.height / 2, width: v.width / 2, height: v.height / 2)
        case .quadBottomRight:
            return CGRect(x: v.origin.x + v.width / 2, y: v.origin.y + v.height / 2, width: v.width / 2, height: v.height / 2)
        }
    }

    // MARK: - 预览图标坐标（用于设置界面）

    func previewRect(in size: CGSize) -> CGRect {
        let w = size.width
        let h = size.height
        let inset: CGFloat = 2.5
        let iw = w - inset * 2
        let ih = h - inset * 2
        switch self {
        case .maximize:
            return CGRect(x: inset, y: inset, width: iw, height: ih)
        case .center:
            let cw = iw * 0.52
            let ch = ih * 0.52
            return CGRect(x: inset + (iw - cw) / 2, y: inset + (ih - ch) / 2, width: cw, height: ch)
        case .leftHalf:
            return CGRect(x: inset, y: inset, width: iw / 2, height: ih)
        case .rightHalf:
            return CGRect(x: inset + iw / 2, y: inset, width: iw / 2, height: ih)
        case .leftTwoThirds:
            return CGRect(x: inset, y: inset, width: iw * 2 / 3, height: ih)
        case .rightOneThird:
            return CGRect(x: inset + iw * 2 / 3, y: inset, width: iw / 3, height: ih)
        case .quadTopLeft:
            return CGRect(x: inset, y: inset, width: iw / 2, height: ih / 2)
        case .quadTopRight:
            return CGRect(x: inset + iw / 2, y: inset, width: iw / 2, height: ih / 2)
        case .quadBottomLeft:
            return CGRect(x: inset, y: inset + ih / 2, width: iw / 2, height: ih / 2)
        case .quadBottomRight:
            return CGRect(x: inset + iw / 2, y: inset + ih / 2, width: iw / 2, height: ih / 2)
        }
    }
}

// MARK: - AppKit 坐标系 targetFrame（用于预览定位）

extension WindowLayout {
    /// 在 AppKit 坐标系中计算目标 frame（原点左下角）
    func targetFrame(in bounds: CGRect) -> CGRect {
        switch self {
        case .maximize:
            return bounds
        case .center:
            let cw = bounds.width * 0.7
            let ch = bounds.height * 0.7
            return CGRect(x: bounds.midX - cw / 2, y: bounds.midY - ch / 2, width: cw, height: ch)
        case .leftHalf:
            return CGRect(x: bounds.minX, y: bounds.minY,
                          width: bounds.width / 2, height: bounds.height)
        case .rightHalf:
            return CGRect(x: bounds.midX, y: bounds.minY,
                          width: bounds.width / 2, height: bounds.height)
        case .leftTwoThirds:
            let w = bounds.width * 2 / 3
            return CGRect(x: bounds.minX, y: bounds.minY, width: w, height: bounds.height)
        case .rightOneThird:
            let w = bounds.width / 3
            return CGRect(x: bounds.maxX - w, y: bounds.minY, width: w, height: bounds.height)
        case .quadTopLeft:
            return CGRect(x: bounds.minX, y: bounds.midY,
                          width: bounds.width / 2, height: bounds.height / 2)
        case .quadTopRight:
            return CGRect(x: bounds.midX, y: bounds.midY,
                          width: bounds.width / 2, height: bounds.height / 2)
        case .quadBottomLeft:
            return CGRect(x: bounds.minX, y: bounds.minY,
                          width: bounds.width / 2, height: bounds.height / 2)
        case .quadBottomRight:
            return CGRect(x: bounds.midX, y: bounds.minY,
                          width: bounds.width / 2, height: bounds.height / 2)
        }
    }
}

// MARK: - 布局分类

enum LayoutCategory: String, CaseIterable {
    case position     // 位置调整
    case splitScreen  // 分屏（半/比例/四宫格合并）

    var displayName: String {
        switch self {
        case .position:    return "位置"
        case .splitScreen: return "分屏"
        }
    }

    var layouts: [WindowLayout] {
        WindowLayout.allCases.filter { $0.category == self }
    }
}

import CoreGraphics

/// AppKit 使用左下原点，Quartz/AX 窗口坐标使用主屏左上原点。
enum ScreenCoordinates {
    static func cocoaPoint(fromQuartz point: CGPoint, primaryScreenMaxY: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenMaxY - point.y)
    }

    static func quartzPoint(fromCocoa point: CGPoint, primaryScreenMaxY: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenMaxY - point.y)
    }

    static func quartzFrame(fromCocoa frame: CGRect, primaryScreenMaxY: CGFloat) -> CGRect {
        CGRect(x: frame.minX,
               y: primaryScreenMaxY - frame.maxY,
               width: frame.width,
               height: frame.height)
    }

    static func cocoaFrame(fromQuartz frame: CGRect, primaryScreenMaxY: CGFloat) -> CGRect {
        CGRect(x: frame.minX,
               y: primaryScreenMaxY - frame.maxY,
               width: frame.width,
               height: frame.height)
    }
}

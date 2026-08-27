import Cocoa

/// Synthesizes a Dock swipe so WindowServer actually changes Space.
/// `CGSManagedDisplaySetCurrentSpace` only updates bookkeeping, which is why
/// Mission Control still showed the previous Space.
enum SpaceSwitcher {
    private static let eventType = CGEventField(rawValue: 55)!
    private static let hidType = CGEventField(rawValue: 110)!
    private static let motion = CGEventField(rawValue: 123)!
    private static let progress = CGEventField(rawValue: 124)!
    private static let velocityX = CGEventField(rawValue: 129)!
    private static let velocityY = CGEventField(rawValue: 130)!
    private static let phase = CGEventField(rawValue: 132)!

    static func move(steps: Int) async {
        guard steps != 0 else { return }
        let forward = steps > 0
        for _ in 0..<abs(steps) {
            postSwipe(forward: forward)
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
    }

    static func focusDisplay(_ displayID: String) {
        guard let screen = NSScreen.screens.first(where: { $0.displayUUID == displayID })
                ?? (displayID == "Main" ? NSScreen.screens.first { $0.frame.origin == .zero } : nil)
        else { return }
        CGWarpMouseCursorPosition(quartzPoint(fromCocoa: CGPoint(x: screen.frame.midX, y: screen.frame.midY)))
    }

    static func restoreCursor(to cocoaPoint: CGPoint) {
        CGWarpMouseCursorPosition(quartzPoint(fromCocoa: cocoaPoint))
    }

    private static func postSwipe(forward: Bool) {
        let sign: Double = forward ? 1 : -1
        let delta = sign * Double(Float.leastNonzeroMagnitude)
        let velocity = sign * 1000
        for phaseValue in [Int64(1), Int64(2), Int64(4)] {
            guard let event = CGEvent(source: nil) else { continue }
            event.setIntegerValueField(eventType, value: 30)
            event.setIntegerValueField(hidType, value: 23)
            event.setIntegerValueField(phase, value: phaseValue)
            event.setDoubleValueField(progress, value: delta)
            event.setIntegerValueField(motion, value: 1)
            event.setDoubleValueField(velocityX, value: velocity)
            event.setDoubleValueField(velocityY, value: velocity)
            event.post(tap: .cgSessionEventTap)
        }
    }

    private static func quartzPoint(fromCocoa point: CGPoint) -> CGPoint {
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
        let maxY = primary?.frame.maxY ?? 0
        return CGPoint(x: point.x, y: maxY - point.y)
    }
}

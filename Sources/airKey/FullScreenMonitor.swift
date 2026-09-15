import AppKit

/// Window geometry only. This does not capture the screen, inspect browser tabs,
/// request audio permissions, or guess whether a windowed video is playing.
enum FullScreenMonitor {
    static func covers(_ window: CGRect, screen: CGRect) -> Bool {
        abs(window.minX - screen.minX) <= 3 && abs(window.minY - screen.minY) <= 3
            && abs(window.width - screen.width) <= 3 && abs(window.height - screen.height) <= 3
    }

    @MainActor static func isFullScreen(on screen: NSScreen?) -> Bool {
        guard let screen, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        let desktopTop = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let bounds = CGRect(x: screen.frame.minX, y: desktopTop - screen.frame.maxY,
                            width: screen.frame.width, height: screen.frame.height)
        return windows.contains { window in
            guard window[kCGWindowOwnerPID as String] as? Int32 == app.processIdentifier,
                  window[kCGWindowLayer as String] as? Int == 0,
                  let dictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dictionary) else { return false }
            return covers(rect, screen: bounds)
        }
    }
}

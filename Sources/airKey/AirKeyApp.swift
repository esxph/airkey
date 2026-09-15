import AppKit

@main
struct AirKeyApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = KeyboardAppDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

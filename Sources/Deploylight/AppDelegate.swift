import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusController = StatusItemController()
        statusController?.start()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(retryTokenStorage), name: NSWorkspace.didWakeNotification, object: nil
        )
        LegacyApp.offerReplacement()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        retryTokenStorage()
    }

    @objc private func retryTokenStorage() {
        PreferencesStore.shared.retryTokenStorage()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusController?.stop()
    }
}

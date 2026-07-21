import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
#if APP_STORE_SCREENSHOTS
        AppStoreScreenshotRenderer.renderAll()
        NSApp.terminate(nil)
#else
        LegacyMigration.runIfNeeded()
        self.controller = StatusBarController()
#if SANDBOX_PROBE
        controller?.runSandboxProbe()
#else
        if !UserDefaults.standard.bool(forKey: StatusBarController.onboardingKey) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.controller?.showPanel()
            }
        }
#endif
#endif
    }
}

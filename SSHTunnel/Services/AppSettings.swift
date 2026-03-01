import Foundation
import ServiceManagement

@Observable
final class AppSettings {
    private var isApplyingLaunchAtLogin = false

    var launchAtLogin: Bool {
        didSet {
            guard !isApplyingLaunchAtLogin else { return }
            updateLaunchAtLogin()
        }
    }
    var openManagerOnLaunch: Bool {
        didSet { UserDefaults.standard.set(openManagerOnLaunch, forKey: "openManagerOnLaunch") }
    }
    var autoCheckForUpdates: Bool {
        didSet { UserDefaults.standard.set(autoCheckForUpdates, forKey: "autoCheckForUpdates") }
    }

    init() {
        self.openManagerOnLaunch = UserDefaults.standard.bool(forKey: "openManagerOnLaunch")
        self.launchAtLogin = SMAppService.mainApp.status == .enabled

        if UserDefaults.standard.object(forKey: "autoCheckForUpdates") == nil {
            self.autoCheckForUpdates = true
        } else {
            self.autoCheckForUpdates = UserDefaults.standard.bool(forKey: "autoCheckForUpdates")
        }
    }

    private func updateLaunchAtLogin() {
        isApplyingLaunchAtLogin = true
        defer { isApplyingLaunchAtLogin = false }

        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to update launch at login: \(error)")
            let actual = SMAppService.mainApp.status == .enabled
            if launchAtLogin != actual {
                launchAtLogin = actual
            }
        }
    }
}

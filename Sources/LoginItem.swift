import Cocoa
import ServiceManagement

enum LoginItem {
    static let agentLabel = "com.arnovaneetvelde.macos-spaces"

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: agentURL.path)
            || SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        if enabled {
            installAgent()
            _ = registerMainApp()
        } else {
            unregisterMainApp()
            removeAgent()
        }
    }

    @discardableResult
    private static func registerMainApp() -> Bool {
        do {
            try SMAppService.mainApp.register()
            return true
        } catch {
            return false
        }
    }

    private static func unregisterMainApp() {
        try? SMAppService.mainApp.unregister()
    }

    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    private static func installAgent() {
        let appURL = Bundle.main.bundleURL
        guard appURL.pathExtension == "app" else { return }

        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": ["/usr/bin/open", "-ga", appURL.path],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
        ]

        let agentDir = agentURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
            return
        }
        try? data.write(to: agentURL, options: .atomic)
    }

    private static func removeAgent() {
        try? FileManager.default.removeItem(at: agentURL)
    }
}

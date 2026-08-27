import Cocoa
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = NameStore()
    private lazy var service = SpaceService(store: store)
    private let layouts = LayoutEngine()
    private let panel = PanelController()
    private var statusItem: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []
    private var frozenFocusedUUID: String?
    private var flashTimer: Timer?
    private var latestSnapshot = SpaceSnapshot()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = NSFont.menuBarFont(ofSize: 0)
        item.button?.title = "Spaces"
        item.button?.toolTip = "Named Spaces"
        statusItem = item

        panel.model.onRename = { [weak self] space, name in
            self?.service.rename(space, to: name)
        }
        panel.model.onSelect = { [weak self] space in
            self?.panel.close()
            self?.frozenFocusedUUID = nil
            self?.service.select(space)
        }
        panel.model.onSave = { [weak self] space in
            self?.saveLayout(of: space)
        }
        panel.model.onRestore = { [weak self] space in
            self?.restoreLayout(of: space)
        }
        panel.model.onToggleLogin = {
            LoginItem.setEnabled(!LoginItem.isEnabled)
        }
        panel.model.onQuit = {
            NSApp.terminate(nil)
        }
        panel.onWillOpen = { [weak self] in
            self?.frozenFocusedUUID = self?.service.snapshot.focusedSpaceUUID
            self?.refreshLayoutState()
        }
        panel.onDidClose = { [weak self] in
            self?.frozenFocusedUUID = nil
            self?.service.refresh(force: true)
        }
        panel.attach(to: item)

        service.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                guard let self else { return }
                self.latestSnapshot = snapshot
                let presented = snapshot.pinningFocus(to: self.frozenFocusedUUID)
                self.panel.model.snapshot = presented
                self.updateStatusItem(presented)
            }
            .store(in: &cancellables)

        refreshLayoutState()
        updateStatusItem(service.snapshot)
    }

    private func saveLayout(of space: Space) {
        let result = layouts.capture(space)
        refreshLayoutState()
        let label = space.displayName
        if result.windowCount == 0 {
            panel.model.statusMessage = "Nothing to save on \(label)"
        } else {
            panel.model.statusMessage = "Saved \(label) · \(result.windowCount) window\(result.windowCount == 1 ? "" : "s")"
        }
    }

    private func restoreLayout(of space: Space) {
        guard layouts.summary(for: space.uuid) != nil else { return }
        guard ensureAccessibility() else { return }

        panel.close()
        frozenFocusedUUID = nil
        flashStatus("Restoring \(space.displayName)…", seconds: 20)

        Task { @MainActor in
            let result = await layouts.restore(space) { [weak self] target in
                self?.service.select(target)
            }
            flashStatus(result.message, seconds: 4)
        }
    }

    private func refreshLayoutState() {
        panel.model.savedLayouts = layouts.summaries()
        panel.model.liveApps = layouts.liveBundleIDs(in: service.snapshot.allSpaces)
    }

    private func ensureAccessibility() -> Bool {
        if LayoutEngine.isTrusted(prompt: false) { return true }
        _ = LayoutEngine.isTrusted(prompt: true)

        let alert = NSAlert()
        alert.messageText = "Spaces needs Accessibility permission"
        alert.informativeText = "Restoring window layouts requires moving and resizing other apps. Enable Spaces in System Settings → Privacy & Security → Accessibility, then try Restore again."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        return LayoutEngine.isTrusted(prompt: false)
    }

    private func flashStatus(_ text: String, seconds: TimeInterval) {
        flashTimer?.invalidate()
        statusItem?.button?.title = text
        flashTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.updateStatusItem(self.latestSnapshot.pinningFocus(to: self.frozenFocusedUUID))
        }
    }

    private func updateStatusItem(_ snapshot: SpaceSnapshot) {
        if flashTimer?.isValid == true { return }
        let uuid = frozenFocusedUUID ?? snapshot.focusedSpaceUUID
        let space = uuid.flatMap { snapshot.space(uuid: $0) } ?? snapshot.focusedSpace
        let title = space?.displayName ?? "Spaces"
        let trimmed = title.count > 24 ? String(title.prefix(23)) + "…" : title
        statusItem?.button?.title = trimmed

        if let space {
            let display = snapshot.displays.first(where: { $0.id == space.displayID })?.name
            statusItem?.button?.toolTip = [display, space.displayName]
                .compactMap { $0 }
                .joined(separator: " · ")
        }
    }
}

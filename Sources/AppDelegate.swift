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
        panel.model.onReopenClosed = { [weak self] summary in
            self?.reopenClosed(summary)
        }
        panel.model.onForgetClosed = { [weak self] summary in
            self?.layouts.removeLayout(for: summary.spaceUUID)
            self?.refreshLayoutState()
            self?.panel.model.statusMessage = "Removed saved \(summary.spaceName)"
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
        guard let layout = layouts.layout(for: space.uuid) else { return }
        guard ensureAccessibility() else { return }

        panel.close()
        frozenFocusedUUID = nil
        flashStatus("Restoring \(space.displayName)…", seconds: 20)

        Task { @MainActor in
            let result = await layouts.restore(layout, onto: space) { [weak self] target in
                self?.service.select(target)
            }
            flashStatus(result.message, seconds: 4)
        }
    }

    private func reopenClosed(_ summary: LayoutSummary) {
        guard let layout = layouts.layout(for: summary.spaceUUID) else { return }
        guard ensureAccessibility() else { return }

        panel.close()
        frozenFocusedUUID = nil
        flashStatus("Reopening \(summary.spaceName)…", seconds: 30)

        Task { @MainActor in
            let displayID = layouts.inferredDisplayID(for: layout)
                ?? service.snapshot.focusedSpace?.displayID
            let created = await service.addDesktop(on: displayID)
            let target = created
                ?? service.snapshot.focusedSpace
                ?? service.snapshot.allSpaces.first
            guard let target else {
                flashStatus("Could not reopen \(summary.spaceName)", seconds: 4)
                return
            }

            if created != nil {
                service.rename(uuid: target.uuid, to: layout.spaceName)
                layouts.rekey(from: layout.spaceUUID, to: target.uuid)
            }

            let result = await layouts.restore(layout, onto: target) { [weak self] space in
                self?.service.select(space)
            }
            refreshLayoutState()
            if created != nil {
                flashStatus("Reopened \(layout.spaceName) · \(result.message)", seconds: 5)
            } else {
                flashStatus("Opened on current Space · \(result.message)", seconds: 5)
            }
        }
    }

    private func refreshLayoutState() {
        let live = Set(service.snapshot.allSpaces.map(\.uuid))
        let all = layouts.summaries()
        panel.model.savedLayouts = all.filter { live.contains($0.key) }
        panel.model.closedLayouts = all.values
            .filter { !live.contains($0.spaceUUID) }
            .sorted { $0.savedAt > $1.savedAt }
        panel.model.liveApps = layouts.liveBundleIDs(in: service.snapshot.allSpaces)
    }

    private func ensureAccessibility() -> Bool {
        if LayoutEngine.isTrusted() { return true }

        let alert = NSAlert()
        alert.messageText = "Spaces needs Accessibility permission"
        alert.informativeText = """
        Restore and Reopen need permission to move windows and create desktops.

        In System Settings → Privacy & Security → Accessibility:
        1. If Spaces is already listed, turn it off, select it, and click −.
        2. Click +, press Shift-Command-G, and choose ~/Applications/Spaces.app.
        3. Turn the toggle on, then click Relaunch Spaces.

        The toggle you already enabled was for an older unsigned build, so macOS still blocks this copy.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Relaunch Spaces")
        alert.addButton(withTitle: "Later")
        NSApp.activate()
        let response = alert.runModal()
        if response == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
            return false
        }
        if response == .alertSecondButtonReturn {
            relaunch()
            return false
        }
        return false
    }

    private func relaunch() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-n", Bundle.main.bundlePath]
        try? proc.run()
        proc.waitUntilExit()
        NSApp.terminate(nil)
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

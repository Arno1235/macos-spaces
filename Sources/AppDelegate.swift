import Cocoa
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = NameStore()
    private lazy var service = SpaceService(store: store)
    private let panel = PanelController()
    private var statusItem: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []
    private var frozenFocusedUUID: String?

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
        panel.model.onToggleLogin = {
            LoginItem.setEnabled(!LoginItem.isEnabled)
        }
        panel.model.onQuit = {
            NSApp.terminate(nil)
        }
        panel.onWillOpen = { [weak self] in
            self?.frozenFocusedUUID = self?.service.snapshot.focusedSpaceUUID
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
                let presented = snapshot.pinningFocus(to: self.frozenFocusedUUID)
                self.panel.model.snapshot = presented
                self.updateStatusItem(presented)
            }
            .store(in: &cancellables)

        updateStatusItem(service.snapshot)
    }

    private func updateStatusItem(_ snapshot: SpaceSnapshot) {
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

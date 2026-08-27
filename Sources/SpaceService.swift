import Cocoa
import Combine

final class SpaceService: ObservableObject {
    @Published private(set) var snapshot = SpaceSnapshot()

    private let store: NameStore
    private let connection: CGSConnectionID
    private var timer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var defaultObservers: [NSObjectProtocol] = []

    init(store: NameStore) {
        self.store = store
        self.connection = CGSMainConnectionID()
        start()
        refresh()
    }

    deinit {
        timer?.invalidate()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        defaultObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        let center = NotificationCenter.default

        let refreshSelector: (Notification) -> Void = { [weak self] _ in
            self?.refresh()
        }

        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main,
            using: refreshSelector
        ))
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main,
            using: refreshSelector
        ))
        defaultObservers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main,
            using: refreshSelector
        ))

        let timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer.tolerance = 0.15
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func rename(_ space: Space, to name: String) {
        store.setName(name, for: space.uuid)
        refresh(force: true)
    }

    func select(_ space: Space) {
        let needsSwitch = !space.isCurrentOnDisplay
        if needsSwitch {
            CGSManagedDisplaySetCurrentSpace(connection, space.displayID as CFString, space.managedID)
        }
        let delay: TimeInterval = needsSwitch ? 0.08 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.activateWindow(onDisplay: space.displayID)
            self?.refresh(force: true)
        }
    }

    func refresh(force: Bool = false) {
        let next = readSnapshot()
        guard force || next != snapshot else { return }
        snapshot = next
    }

    private func readSnapshot() -> SpaceSnapshot {
        guard let displays = CGSCopyManagedDisplaySpaces(connection) else {
            return snapshot
        }

        let focusedID = CGSGetActiveSpace(connection)
        let screenOrder = NSScreen.screens.compactMap(\.displayUUID)

        struct RawDisplay {
            let id: String
            let currentID: CGSSpaceID
            let spaces: [[String: Any]]
        }

        let rawDisplays: [RawDisplay] = displays.compactMap { display in
            guard let id = display["Display Identifier"] as? String,
                  let spaces = display["Spaces"] as? [[String: Any]] else { return nil }
            let current = uint64ID((display["Current Space"] as? [String: Any])?["ManagedSpaceID"])
                ?? CGSManagedDisplayGetCurrentSpace(connection, id as CFString)
            return RawDisplay(id: id, currentID: current, spaces: spaces)
        }

        let sorted = rawDisplays.sorted { a, b in
            let ia = screenOrder.firstIndex(of: a.id) ?? Int.max
            let ib = screenOrder.firstIndex(of: b.id) ?? Int.max
            if ia != ib { return ia < ib }
            return a.id < b.id
        }

        var focusedUUID: String?
        var result: [DisplayInfo] = []

        for raw in sorted {
            var desktopNumber = 0
            var spaces: [Space] = []

            for (index, info) in raw.spaces.enumerated() {
                guard let managedID = uint64ID(info["ManagedSpaceID"]) else { continue }
                let uuid = (info["uuid"] as? String) ?? "managed-\(managedID)"
                let type = (info["type"] as? NSNumber)?.intValue ?? 0
                let isFullScreen = type == CGSSpaceType.fullscreen.rawValue || info["TileLayoutManager"] is [String: Any]
                if !isFullScreen { desktopNumber += 1 }

                let isFocused = managedID == focusedID
                if isFocused { focusedUUID = uuid }

                spaces.append(Space(
                    uuid: uuid,
                    managedID: managedID,
                    displayID: raw.id,
                    indexOnDisplay: index,
                    desktopNumber: desktopNumber,
                    isFullScreen: isFullScreen,
                    isCurrentOnDisplay: managedID == raw.currentID,
                    isFocused: isFocused,
                    customName: store.name(for: uuid)
                ))
            }

            result.append(DisplayInfo(
                id: raw.id,
                name: Self.displayName(for: raw.id, fallbackIndex: result.count),
                isFocused: spaces.contains(where: \.isFocused),
                spaces: spaces
            ))
        }

        guard !result.isEmpty else { return snapshot }

        return SpaceSnapshot(displays: result, focusedSpaceUUID: focusedUUID)
    }

    private static func displayName(for displayID: String, fallbackIndex: Int) -> String {
        if let screen = NSScreen.screens.first(where: { $0.displayUUID == displayID }) {
            let name = screen.localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        if displayID == "Main" {
            return NSScreen.screens.first?.localizedName ?? "Built-in Display"
        }
        return "Display \(fallbackIndex + 1)"
    }

    private func activateWindow(onDisplay displayUUID: String) {
        guard let screen = NSScreen.screens.first(where: { $0.displayUUID == displayUUID }) else { return }
        let targetDisplay = screen.cgDisplayID
        let selfPID = ProcessInfo.processInfo.processIdentifier

        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return
        }

        for window in windows {
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  pid != selfPID,
                  let owner = window[kCGWindowOwnerName as String] as? String,
                  owner != "Window Server",
                  owner != "Dock",
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width > 80, rect.height > 80
            else { continue }

            var count: UInt32 = 0
            var ids = [CGDirectDisplayID](repeating: 0, count: 8)
            CGGetDisplaysWithRect(rect, 8, &ids, &count)
            guard ids.prefix(Int(count)).contains(targetDisplay) else { continue }

            NSRunningApplication(processIdentifier: pid)?.activate()
            return
        }
    }
}

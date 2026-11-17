import Cocoa

/// A Space that disappeared together with an unplugged display. WindowServer
/// "collapses" it: its windows are merged into a Space on a remaining display,
/// and the Space is recreated with the same UUID (and its windows moved back)
/// when that display is plugged in again.
struct AwaySpace: Codable, Equatable, Identifiable {
    var id: String { uuid }
    var uuid: String
    var name: String?
    var displayID: String
    var displayName: String
    var mergedIntoUUID: String?
    var bundleIDs: [String]
    var windowCount: Int
    var since: Date
}

/// A Space that WindowServer moved intact to another display because its own
/// display was unplugged. It moves back when that display returns.
struct ParkedSpace: Codable, Equatable {
    var uuid: String
    var homeDisplayID: String
    var homeDisplayName: String
    var since: Date
}

/// Where a desktop's windows go when macOS collapses it on unplug.
struct MergeRisk: Equatable {
    var targetName: String
    var targetDisplayName: String
}

private struct TrackedWindow: Equatable {
    var id: CGWindowID
    var bundleID: String
}

/// Watches Space snapshots for displays coming and going, and remembers which
/// Spaces left with an unplugged display. It only observes; it never moves
/// windows or Spaces.
///
/// What WindowServer does (macOS 15, "Displays have separate Spaces" on): the
/// menu-bar display's set of Spaces is kept and follows the menu bar. For every
/// other display that goes away, the first desktop is destroyed and its windows
/// are merged into the menu-bar set's first desktop; its other Spaces are
/// appended to the menu-bar set ("parked"). When that display returns, the
/// first desktop is recreated with the same UUID, the merged windows that were
/// not closed or moved go back into it, and the parked Spaces return.
final class DisplayTracker {
    private enum Keys {
        static let enabled = "displayTracking.enabled"
        static let away = "displayTracking.away.v1"
        static let parked = "displayTracking.parked.v1"
        static let dismissed = "displayTracking.dismissed.v1"
        static let displayNames = "displayTracking.displayNames.v1"
    }

    private let defaults: UserDefaults
    private let store: NameStore
    private let connection: CGSConnectionID

    private(set) var away: [String: AwaySpace] = [:]
    private(set) var parked: [String: ParkedSpace] = [:]
    /// Away Spaces the user chose to stop seeing; kept until the Space is live again.
    private var dismissed: Set<String> = []
    private var displayNames: [String: String] = [:]

    /// Last snapshot taken while the set of displays was stable.
    private var baseline: SpaceSnapshot?
    /// Windows per Space UUID, captured while `baseline`'s displays were connected.
    private var baselineWindows: [String: [TrackedWindow]] = [:]
    /// Menu-bar display while `baseline` was current.
    private var baselineMainID: String?
    private var latest: SpaceSnapshot?
    private var settleTimer: Timer?
    private var transitionStarted: Date?
    private var windowTimer: Timer?

    var onChange: (() -> Void)?
    /// UUID of the menu-bar display; injectable for tests.
    var mainDisplayID: () -> String? = DisplayTracker.mainDisplayUUID
    /// Reads a key of WindowServer's com.apple.spaces preferences; injectable for tests.
    var spacesPreference: (String) -> Any? = DisplayTracker.readSpacesPreference

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Keys.enabled)
            reset()
            onChange?()
        }
    }

    init(store: NameStore, defaults: UserDefaults = .standard, connection: CGSConnectionID = CGSMainConnectionID()) {
        self.store = store
        self.defaults = defaults
        self.connection = connection
        self.isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        away = Self.decode([String: AwaySpace].self, defaults.data(forKey: Keys.away)) ?? [:]
        parked = Self.decode([String: ParkedSpace].self, defaults.data(forKey: Keys.parked)) ?? [:]
        dismissed = Set(defaults.stringArray(forKey: Keys.dismissed) ?? [])
        displayNames = defaults.dictionary(forKey: Keys.displayNames) as? [String: String] ?? [:]

        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshBaselineWindows()
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        windowTimer = timer
    }

    deinit {
        settleTimer?.invalidate()
        windowTimer?.invalidate()
    }

    /// Stops showing an away Space. WindowServer still restores it if its display returns.
    func forget(_ uuid: String) {
        guard away.removeValue(forKey: uuid) != nil else { return }
        dismissed.insert(uuid)
        persist()
        onChange?()
    }

    /// The desktops macOS will merge away when displays are unplugged: the first
    /// desktop of every display except the menu-bar one, merged into the menu-bar
    /// display's first desktop. Emptiness, names and focus play no role.
    static func mergeCandidates(
        in snapshot: SpaceSnapshot,
        mainID: String? = DisplayTracker.mainDisplayUUID()
    ) -> [String: MergeRisk] {
        guard snapshot.displays.count > 1 else { return [:] }
        guard let main = snapshot.displays.first(where: { normalized($0.id, mainID: mainID) == mainID })
                ?? snapshot.displays.first,
              let target = main.spaces.first(where: { !$0.isFullScreen })
        else { return [:] }

        var result: [String: MergeRisk] = [:]
        for display in snapshot.displays where display.id != main.id {
            guard let first = display.spaces.first(where: { !$0.isFullScreen }) else { continue }
            result[first.uuid] = MergeRisk(targetName: target.displayName, targetDisplayName: main.name)
        }
        return result
    }

    func observe(_ snapshot: SpaceSnapshot) {
        guard isEnabled, !snapshot.displays.isEmpty else { return }

        // One set of Spaces spanning all displays ("Displays have separate Spaces"
        // off): nothing is merged or parked, and nothing comes back.
        if isSpanningMode(snapshot) {
            reset()
            if !away.isEmpty || !parked.isEmpty {
                away = [:]
                parked = [:]
                persist()
                onChange?()
            }
            return
        }

        rememberDisplayNames(snapshot)

        guard let baseline else {
            self.baseline = snapshot
            baselineMainID = mainDisplayID()
            refreshBaselineWindows()
            let seeded = seedFromWindowServer(snapshot)
            if resolve(with: snapshot, activeDisplays: displaySet(snapshot)) || seeded {
                persist()
                onChange?()
            }
            return
        }

        if transitionStarted == nil, displaySet(snapshot) == displaySet(baseline) {
            self.baseline = snapshot
            baselineMainID = mainDisplayID()
            reconcile(with: snapshot)
            return
        }

        // Displays changed. Wait until WindowServer and the Dock settle before diffing,
        // because Spaces move and collapse over a few hundred milliseconds.
        latest = snapshot
        if transitionStarted == nil { transitionStarted = Date() }
        scheduleSettle()
    }

    // MARK: - Transitions

    private func scheduleSettle() {
        settleTimer?.invalidate()
        let waited = Date().timeIntervalSince(transitionStarted ?? Date())
        let timer = Timer(timeInterval: waited > 8 ? 0.1 : 1.5, repeats: false) { [weak self] _ in
            self?.settle()
        }
        RunLoop.main.add(timer, forMode: .common)
        settleTimer = timer
    }

    private func settle() {
        settleTimer = nil
        transitionStarted = nil
        guard let old = baseline, let new = latest else { return }
        latest = nil

        let newWindows = captureWindows(for: new)
        apply(transitionFrom: old, to: new, oldWindows: baselineWindows, newWindows: newWindows)
        baseline = new
        baselineWindows = newWindows
        baselineMainID = mainDisplayID()
    }

    private func apply(
        transitionFrom old: SpaceSnapshot,
        to new: SpaceSnapshot,
        oldWindows: [String: [TrackedWindow]],
        newWindows: [String: [TrackedWindow]]
    ) {
        let oldDisplays = displaySet(old)
        let newDisplays = displaySet(new)
        let removed = oldDisplays.subtracting(newDisplays)
        let added = newDisplays.subtracting(oldDisplays)
        let removedMain = baselineMainID.flatMap { removed.contains($0) ? $0 : nil }
        let live = Dictionary(new.allSpaces.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        let now = Date()
        var changed = false

        // Windows shown on every desktop are not part of a merge.
        let spacesBefore = Self.spaceCounts(oldWindows)
        let spacesAfter = Self.spaceCounts(newWindows)

        for space in old.allSpaces where !space.isFullScreen && !removed.isEmpty {
            let displayID = normalized(space.displayID)

            if let current = live[space.uuid] {
                // Moved intact off a display that went away onto one that was already
                // connected: parked until its display returns. Spaces that land on a
                // display added in the same change were inherited by it, not parked.
                let currentDisplay = normalized(current.displayID)
                guard removed.contains(displayID),
                      currentDisplay != displayID,
                      !added.contains(currentDisplay),
                      parked[space.uuid] == nil
                else { continue }
                parked[space.uuid] = ParkedSpace(
                    uuid: space.uuid,
                    homeDisplayID: displayID,
                    homeDisplayName: displayName(displayID),
                    since: now
                )
                changed = true
                continue
            }

            // Vanished while displays changed: WindowServer collapsed it. When the
            // menu-bar display itself went away, the collapsed desktop belongs to a
            // display that stayed, and it comes back when the menu-bar display returns.
            let returnsWith = removed.contains(displayID) ? displayID : (removedMain ?? removed.sorted()[0])
            let windows = (oldWindows[space.uuid] ?? []).filter {
                spacesBefore[$0.id] == 1 && (spacesAfter[$0.id] ?? 0) <= 1
            }
            parked.removeValue(forKey: space.uuid)
            guard space.hasCustomName || !windows.isEmpty else { continue }

            dismissed.remove(space.uuid)
            away[space.uuid] = AwaySpace(
                uuid: space.uuid,
                name: space.customName,
                displayID: returnsWith,
                displayName: displayName(returnsWith),
                mergedIntoUUID: mergeTarget(of: windows, in: newWindows),
                bundleIDs: uniqueBundleIDs(windows),
                windowCount: windows.count,
                since: now
            )
            changed = true
        }

        // A record whose display is connected again while its Space is still gone
        // waits for a display that left now: e.g. the lid was closed while docked,
        // then the external display was unplugged and the lid opened elsewhere.
        if let target = removedMain ?? (removed.count == 1 ? removed.first : nil) {
            for (uuid, record) in away where live[uuid] == nil && record.displayID != target && newDisplays.contains(record.displayID) {
                away[uuid]?.displayID = target
                away[uuid]?.displayName = displayName(target)
                changed = true
            }
        }

        if resolve(with: new, activeDisplays: newDisplays) { changed = true }
        if changed {
            persist()
            onChange?()
        }
    }

    /// Clears records whose Space is back, outside of display transitions.
    private func reconcile(with snapshot: SpaceSnapshot) {
        if resolve(with: snapshot, activeDisplays: displaySet(snapshot)) {
            persist()
            onChange?()
        }
    }

    private func resolve(with snapshot: SpaceSnapshot, activeDisplays: Set<String>) -> Bool {
        let live = Dictionary(snapshot.allSpaces.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        let mainID = mainDisplayID()
        var changed = false

        for uuid in away.keys where live[uuid] != nil {
            away.removeValue(forKey: uuid)
            changed = true
        }
        for uuid in dismissed where live[uuid] != nil {
            dismissed.remove(uuid)
            changed = true
        }
        for (uuid, record) in parked {
            guard let space = live[uuid] else {
                // Closed in Mission Control.
                parked.removeValue(forKey: uuid)
                changed = true
                continue
            }
            // WindowServer keeps parked Spaces in the menu-bar display's set. Found on
            // another display, the Space went home or a newly connected display
            // inherited it; either way it is no longer waiting.
            let leftMainSet = mainID.map { normalized(space.displayID) != $0 } ?? false
            if leftMainSet || activeDisplays.contains(record.homeDisplayID) {
                parked.removeValue(forKey: uuid)
                changed = true
            }
        }
        return changed
    }

    /// Picks up what WindowServer itself remembers about unplugged displays
    /// (com.apple.spaces), so Spaces that left while this app was not running
    /// are known too. WindowServer writes that file lazily, so it is only a seed.
    private func seedFromWindowServer(_ snapshot: SpaceSnapshot) -> Bool {
        guard let config = spacesPreference("SpacesDisplayConfiguration") as? [String: Any],
              let management = config["Management Data"] as? [String: Any],
              let monitors = management["Monitors"] as? [[String: Any]]
        else { return false }

        let active = displaySet(snapshot)
        let live = Dictionary(snapshot.allSpaces.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        var changed = false

        for monitor in monitors {
            guard let displayID = monitor["Display Identifier"] as? String,
                  displayID != "Main",
                  !active.contains(displayID)
            else { continue }

            for info in monitor["Spaces"] as? [[String: Any]] ?? [] {
                guard let uuid = info["uuid"] as? String,
                      let space = live[uuid],
                      normalized(space.displayID) != displayID,
                      parked[uuid] == nil
                else { continue }
                parked[uuid] = ParkedSpace(uuid: uuid, homeDisplayID: displayID, homeDisplayName: displayName(displayID), since: Date())
                changed = true
            }

            if let collapsed = monitor["Collapsed Space"] as? [String: Any],
               let uuid = collapsed["uuid"] as? String,
               live[uuid] == nil,
               away[uuid] == nil,
               !dismissed.contains(uuid),
               let name = store.name(for: uuid) {
                away[uuid] = AwaySpace(
                    uuid: uuid,
                    name: name,
                    displayID: displayID,
                    displayName: displayName(displayID),
                    mergedIntoUUID: nil,
                    bundleIDs: [],
                    windowCount: 0,
                    since: Date()
                )
                changed = true
            }
        }
        return changed
    }

    private func reset() {
        settleTimer?.invalidate()
        settleTimer = nil
        transitionStarted = nil
        baseline = nil
        baselineMainID = nil
        latest = nil
        baselineWindows = [:]
        if !isEnabled {
            // Dismissals are kept, so turning tracking back on doesn't bring them back.
            away = [:]
            parked = [:]
            persist()
        }
    }

    private func isSpanningMode(_ snapshot: SpaceSnapshot) -> Bool {
        guard snapshot.displays.count == 1, snapshot.displays[0].id == "Main" else { return false }
        return (spacesPreference("spans-displays") as? NSNumber)?.boolValue == true
    }

    // MARK: - Windows

    private func refreshBaselineWindows() {
        guard isEnabled, transitionStarted == nil, let baseline, baseline.displays.count > 1 else { return }
        // Skip if displays already changed and the snapshot has not caught up yet,
        // and discard the capture if they changed while it ran.
        let displays = displaySet(baseline)
        guard liveDisplaySet() == displays else { return }
        let windows = captureWindows(for: baseline)
        guard transitionStarted == nil, liveDisplaySet() == displays else { return }
        baselineWindows = windows
    }

    private func captureWindows(for snapshot: SpaceSnapshot) -> [String: [TrackedWindow]] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        let uuidByManagedID = Dictionary(
            snapshot.allSpaces.map { ($0.managedID, $0.uuid) },
            uniquingKeysWith: { first, _ in first }
        )
        let selfPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        var bundleByPID: [pid_t: String?] = [:]
        var result: [String: [TrackedWindow]] = [:]

        for info in list {
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pidNumber = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let number = info[kCGWindowNumber as String] as? NSNumber,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width > 60, frame.height > 60,
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue != 0
            else { continue }

            let pid = pid_t(pidNumber.int32Value)
            guard pid != selfPID else { continue }
            let bundleID: String?
            if let cached = bundleByPID[pid] {
                bundleID = cached
            } else {
                let app = NSRunningApplication(processIdentifier: pid)
                bundleID = app?.activationPolicy == .regular ? app?.bundleIdentifier : nil
                bundleByPID[pid] = bundleID
            }
            guard let bundleID else { continue }

            let windowID = CGWindowID(number.uint32Value)
            for spaceID in spacesContainingWindow(connection, windowID) {
                guard let uuid = uuidByManagedID[spaceID] else { continue }
                result[uuid, default: []].append(TrackedWindow(id: windowID, bundleID: bundleID))
            }
        }
        return result
    }

    private static func spaceCounts(_ windows: [String: [TrackedWindow]]) -> [CGWindowID: Int] {
        var counts: [CGWindowID: Int] = [:]
        for list in windows.values {
            for window in list { counts[window.id, default: 0] += 1 }
        }
        return counts
    }

    private func mergeTarget(of windows: [TrackedWindow], in newWindows: [String: [TrackedWindow]]) -> String? {
        let ids = Set(windows.map(\.id))
        guard !ids.isEmpty else { return nil }
        let best = newWindows
            .map { uuid, list in (uuid, list.filter { ids.contains($0.id) }.count) }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }
        return best?.0
    }

    private func uniqueBundleIDs(_ windows: [TrackedWindow]) -> [String] {
        var seen: [String] = []
        for window in windows where !seen.contains(window.bundleID) {
            seen.append(window.bundleID)
        }
        return seen
    }

    // MARK: - Displays

    private func displaySet(_ snapshot: SpaceSnapshot) -> Set<String> {
        Set(snapshot.displays.map { normalized($0.id) })
    }

    private func liveDisplaySet() -> Set<String> {
        guard let displays = CGSCopyManagedDisplaySpaces(connection) else { return [] }
        return Set(displays.compactMap { ($0["Display Identifier"] as? String).map(normalized) })
    }

    private func displayName(_ displayID: String) -> String {
        displayNames[displayID] ?? "External display"
    }

    private func normalized(_ displayID: String) -> String {
        guard displayID == "Main" else { return displayID }
        return mainDisplayID() ?? displayID
    }

    /// WindowServer reports the main display as "Main" in some modes; compare by UUID.
    private static func normalized(_ displayID: String, mainID: String?) -> String {
        guard displayID == "Main", let mainID else { return displayID }
        return mainID
    }

    static func mainDisplayUUID() -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID()) else { return nil }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
    }

    private static func readSpacesPreference(_ key: String) -> Any? {
        let domain = "com.apple.spaces" as CFString
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(key as CFString, domain)
    }

    private func rememberDisplayNames(_ snapshot: SpaceSnapshot) {
        var changed = false
        for display in snapshot.displays {
            let id = normalized(display.id)
            // SpaceService falls back to "Display N" for a display NSScreen doesn't list
            // (yet, or any more); never let that replace a real name.
            let isFallback = display.name.range(of: #"^Display \d+$"#, options: .regularExpression) != nil
            if isFallback, displayNames[id] != nil { continue }
            if displayNames[id] != display.name {
                displayNames[id] = display.name
                changed = true
            }
        }
        if changed {
            defaults.set(displayNames, forKey: Keys.displayNames)
        }
    }

    // MARK: - Persistence

    private func persist() {
        defaults.set(Self.encode(away), forKey: Keys.away)
        defaults.set(Self.encode(parked), forKey: Keys.parked)
        defaults.set(Array(dismissed), forKey: Keys.dismissed)
    }

    private static func encode<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(value)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }
}

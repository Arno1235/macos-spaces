import Foundation

struct Space: Identifiable, Equatable {
    var id: String { uuid }

    let uuid: String
    let managedID: CGSSpaceID
    let displayID: String
    let indexOnDisplay: Int
    let desktopNumber: Int
    let isFullScreen: Bool
    let isCurrentOnDisplay: Bool
    let isFocused: Bool
    let customName: String?

    var defaultName: String {
        if isFullScreen { return "Full Screen" }
        return "Desktop \(desktopNumber)"
    }

    var displayName: String {
        if let customName, !customName.isEmpty { return customName }
        return defaultName
    }
}

struct DisplayInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let isFocused: Bool
    let spaces: [Space]
}

struct SpaceSnapshot: Equatable {
    var displays: [DisplayInfo] = []
    var focusedSpaceUUID: String?

    var allSpaces: [Space] {
        displays.flatMap(\.spaces)
    }

    var focusedSpace: Space? {
        allSpaces.first(where: { $0.uuid == focusedSpaceUUID })
            ?? allSpaces.first(where: \.isFocused)
    }

    func space(uuid: String) -> Space? {
        allSpaces.first(where: { $0.uuid == uuid })
    }

    /// Keeps the pre-open focused space highlighted while the menu-bar panel is key.
    func pinningFocus(to uuid: String?) -> SpaceSnapshot {
        guard let uuid else { return self }
        let displays = displays.map { display in
            DisplayInfo(
                id: display.id,
                name: display.name,
                isFocused: display.spaces.contains(where: { $0.uuid == uuid }),
                spaces: display.spaces.map { space in
                    Space(
                        uuid: space.uuid,
                        managedID: space.managedID,
                        displayID: space.displayID,
                        indexOnDisplay: space.indexOnDisplay,
                        desktopNumber: space.desktopNumber,
                        isFullScreen: space.isFullScreen,
                        isCurrentOnDisplay: space.isCurrentOnDisplay,
                        isFocused: space.uuid == uuid,
                        customName: space.customName
                    )
                }
            )
        }
        return SpaceSnapshot(displays: displays, focusedSpaceUUID: uuid)
    }
}

import Cocoa
import SwiftUI

final class PanelModel: ObservableObject {
    @Published var snapshot = SpaceSnapshot()
    @Published var loginEnabled = LoginItem.isEnabled

    var onRename: ((Space, String) -> Void)?
    var onSelect: ((Space) -> Void)?
    var onToggleLogin: (() -> Void)?
    var onQuit: (() -> Void)?
}

struct SpaceRow: View {
    let space: Space
    let onRename: (String) -> Void
    let onSelect: () -> Void

    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onSelect) {
                Image(systemName: indicatorSymbol)
                    .foregroundStyle(indicatorColor)
                    .font(.system(size: 12))
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .help(space.isFocused ? "This space is in focus" : "Switch to this space")

            TextField(space.defaultName, text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: space.isFocused ? .semibold : .regular))
                .focused($fieldFocused)
                .onSubmit { commit() }
                .onExitCommand { fieldFocused = false; commit() }

            if space.isFocused {
                Text("Focus")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.25)))
                    .foregroundStyle(Color.accentColor)
            } else {
                Button(action: onSelect) {
                    Image(systemName: "arrow.right.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Go to this space")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(space.isFocused ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .onAppear { draft = space.customName ?? "" }
        .onChange(of: space.customName) { _, value in
            if !fieldFocused {
                draft = value ?? ""
            }
        }
        .onChange(of: fieldFocused) { _, focused in
            if !focused { commit() }
        }
    }

    private var indicatorSymbol: String {
        if space.isFocused { return "checkmark.circle.fill" }
        if space.isCurrentOnDisplay { return "circle.inset.filled" }
        return "circle"
    }

    private var indicatorColor: Color {
        if space.isFocused { return .accentColor }
        if space.isCurrentOnDisplay { return .secondary }
        return Color.secondary.opacity(0.45)
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != (space.customName ?? "") {
            onRename(trimmed)
        }
    }
}

struct SpacesPanelView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.snapshot.displays) { display in
                        displaySection(display)
                    }
                }
            }
            .frame(maxHeight: 420)

            Divider()

            footer
        }
        .padding(12)
        .frame(width: 320)
        .background(Color.clear)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Spaces")
                .font(.system(size: 15, weight: .semibold))
            if let focused = model.snapshot.focusedSpace {
                Text(focused.displayName)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func displaySection(_ display: DisplayInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(display.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                if display.isFocused {
                    Text("In focus")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)

            ForEach(display.spaces) { space in
                SpaceRow(
                    space: space,
                    onRename: { model.onRename?(space, $0) },
                    onSelect: { model.onSelect?(space) }
                )
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Button {
                model.onToggleLogin?()
                model.loginEnabled = LoginItem.isEnabled
            } label: {
                HStack {
                    Image(systemName: model.loginEnabled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(model.loginEnabled ? Color.accentColor : Color.secondary)
                    Text("Launch at login")
                    Spacer()
                }
                .font(.system(size: 12))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                model.onQuit?()
            } label: {
                HStack {
                    Image(systemName: "power")
                    Text("Quit Spaces")
                    Spacer()
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class PanelController: NSObject {
    let model = PanelModel()

    private var panel: NSPanel?
    private var outsideMonitor: Any?
    private var escapeMonitor: Any?
    private weak var statusItem: NSStatusItem?

    var onWillOpen: (() -> Void)?
    var onDidClose: (() -> Void)?

    var isOpen: Bool { panel?.isVisible == true }

    func attach(to statusItem: NSStatusItem) {
        self.statusItem = statusItem
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
        statusItem.button?.sendAction(on: [.leftMouseUp])
    }

    @objc private func toggle() {
        if isOpen {
            close()
        } else {
            show()
        }
    }

    func close() {
        panel?.close()
        panel = nil
        if let outsideMonitor {
            NSEvent.removeMonitor(outsideMonitor)
        }
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
        outsideMonitor = nil
        escapeMonitor = nil
        onDidClose?()
    }

    private func show() {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return }
        onWillOpen?()
        model.loginEnabled = LoginItem.isEnabled

        let hosting = NSHostingView(rootView: SpacesPanelView(model: model))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor

        let width: CGFloat = 320
        hosting.frame.size = NSSize(width: width, height: 800)
        hosting.layoutSubtreeIfNeeded()
        let fitted = hosting.fittingSize.height
        let screen = buttonWindow.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let height = min(max(fitted > 1 ? fitted : 360, 180), screen.visibleFrame.height - 24)

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.moveToActiveSpace, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        effect.material = .menu
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true

        hosting.frame = effect.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        effect.addSubview(hosting)
        panel.contentView = effect

        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var x = buttonRect.midX - width / 2
        x = max(screen.visibleFrame.minX + 8, min(x, screen.visibleFrame.maxX - width - 8))
        let y = buttonRect.minY - height - 6
        panel.setFrameOrigin(NSPoint(x: x, y: y))

        panel.orderFrontRegardless()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, let button = self.statusItem?.button, let window = button.window else {
                self?.close()
                return
            }
            let buttonScreen = window.convertToScreen(button.convert(button.bounds, to: nil))
            if buttonScreen.contains(NSEvent.mouseLocation) { return }
            self.close()
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            if let responder = self?.panel?.firstResponder,
               responder is NSTextView || responder is NSTextField {
                return event
            }
            self?.close()
            return nil
        }
    }
}

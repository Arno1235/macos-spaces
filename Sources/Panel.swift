import Cocoa
import SwiftUI

final class PanelModel: ObservableObject {
    @Published var snapshot = SpaceSnapshot()
    @Published var loginEnabled = LoginItem.isEnabled
    @Published var liveApps: [String: [String]] = [:]
    @Published var savedLayouts: [String: LayoutSummary] = [:]
    @Published var closedLayouts: [LayoutSummary] = []
    @Published var statusMessage: String?

    var onRename: ((Space, String) -> Void)?
    var onSelect: ((Space) -> Void)?
    var onSave: ((Space) -> Void)?
    var onRestore: ((Space) -> Void)?
    var onReopenClosed: ((LayoutSummary) -> Void)?
    var onForgetClosed: ((LayoutSummary) -> Void)?
    var onToggleLogin: (() -> Void)?
    var onQuit: (() -> Void)?
}

struct AppIconStack: View {
    let bundleIDs: [String]
    var size: CGFloat = 14

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(bundleIDs.prefix(4)), id: \.self) { id in
                AppIcon(bundleID: id, size: size)
            }
            if bundleIDs.count > 4 {
                Text("+\(bundleIDs.count - 4)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct AppIcon: View {
    let bundleID: String
    var size: CGFloat = 14

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: size, height: size)
        }
    }
}

struct SpaceRow: View {
    let space: Space
    let liveApps: [String]
    let saved: LayoutSummary?
    let onRename: (String) -> Void
    let onSelect: () -> Void
    let onSave: () -> Void
    let onRestore: () -> Void

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

            AppIconStack(bundleIDs: liveApps)

            if space.isFocused {
                Text("Focus")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.25)))
                    .foregroundStyle(Color.accentColor)
            }

            Button(action: onSave) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(saved.map { "Replace saved layout (\($0.windowCount) windows)" } ?? "Save apps and window layout")

            if saved != nil {
                Button(action: onRestore) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(restoreHelp)
            }

            if !space.isFocused {
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
            RoundedRectangle(cornerRadius: 8, style: .continuous)
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

    private var restoreHelp: String {
        guard let saved else { return "Restore layout" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Restore \(saved.windowCount) windows · saved \(formatter.localizedString(for: saved.savedAt, relativeTo: Date()))"
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

    private let cornerRadius: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.snapshot.displays) { display in
                        displaySection(display)
                    }
                    if !model.closedLayouts.isEmpty {
                        closedSection
                    }
                }
            }
            .frame(maxHeight: 420)

            Divider()

            footer
        }
        .padding(14)
        .frame(width: 340)
        .background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.regularMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Spaces")
                .font(.system(size: 15, weight: .semibold))
            if let status = model.statusMessage {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(2)
            } else if let focused = model.snapshot.focusedSpace {
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
                    liveApps: model.liveApps[space.uuid] ?? [],
                    saved: model.savedLayouts[space.uuid],
                    onRename: { model.onRename?(space, $0) },
                    onSelect: { model.onSelect?(space) },
                    onSave: { model.onSave?(space) },
                    onRestore: { model.onRestore?(space) }
                )
            }
        }
    }

    private var closedSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Closed spaces")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 10)

            ForEach(model.closedLayouts) { layout in
                HStack(spacing: 8) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(layout.spaceName)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        Text("\(layout.windowCount) window\(layout.windowCount == 1 ? "" : "s") saved")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer(minLength: 4)

                    AppIconStack(bundleIDs: layout.bundleIDs)

                    Button {
                        model.onReopenClosed?(layout)
                    } label: {
                        Text("Reopen")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .help("Create a new Space and restore the saved apps")

                    Button {
                        model.onForgetClosed?(layout)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove this saved layout")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Save stores apps and window layout. If you close a Space, it appears under Closed spaces so you can reopen it.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

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

final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configure()
    }

    override func layout() {
        super.layout()
        configure()
    }

    private func configure() {
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false
    }
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

        let hosting = TransparentHostingView(rootView: SpacesPanelView(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]

        let width: CGFloat = 340
        let fitted = hosting.fittingSize
        let screen = buttonWindow.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let height = min(max(fitted.height > 1 ? fitted.height : 380, 180), screen.visibleFrame.height - 24)

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
        panel.isFloatingPanel = true

        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var x = buttonRect.midX - width / 2
        x = max(screen.visibleFrame.minX + 8, min(x, screen.visibleFrame.maxX - width - 8))
        let y = buttonRect.minY - height - 6
        panel.setFrameOrigin(NSPoint(x: x, y: y))

        panel.orderFrontRegardless()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
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

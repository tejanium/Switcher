import Cocoa

// Cmd+` window switcher: a vertical list (icon + title) of the frontmost app's
// windows. Windows come from AX, which — like native Cmd+` — only reaches the
// current Space.

struct WindowInfo {
    let element: AXUIElement
    let title: String
    let isMinimized: Bool
    let icon: NSImage
}

enum WindowListProvider {

    /// The app's standard windows in AX order (front to back), the same order
    /// native Cmd+` cycles through.
    static func windows(of app: NSRunningApplication) -> [WindowInfo] {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // Calls into the target app; a hung app must not freeze the switcher.
        AXUIElementSetMessagingTimeout(axApp, 0.5)

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else { return [] }

        let appName = app.localizedName ?? "Window"
        let appIcon = app.icon ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()

        return elements.compactMap { element in
            // Skip panels, sheets, popovers and other non-document windows.
            guard string(element, kAXSubroleAttribute) == kAXStandardWindowSubrole as String else { return nil }
            let title = string(element, kAXTitleAttribute) ?? ""
            var icon = appIcon
            if let doc = string(element, kAXDocumentAttribute), let url = URL(string: doc), url.isFileURL {
                icon = NSWorkspace.shared.icon(forFile: url.path)
            }
            return WindowInfo(element: element,
                              title: title.isEmpty ? appName : title,
                              isMinimized: bool(element, kAXMinimizedAttribute),
                              icon: icon)
        }
    }

    /// Bring a window to the front of its (already frontmost) app, restoring it
    /// first if minimized.
    static func focus(_ window: WindowInfo, of app: NSRunningApplication) {
        let element = window.element
        if window.isMinimized {
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        app.activate(options: [.activateIgnoringOtherApps])
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }
}

/// Non-activating HUD panel listing windows as rows, styled like AppSwitcherPanel.
class WindowSwitcherPanel: NSPanel {

    private static let rowHeight: CGFloat = 42
    private static let iconSize: CGFloat = 30
    private static let padding: CGFloat = 10
    private static let cornerRadius: CGFloat = 22
    private static let minWidth: CGFloat = 320
    private static let maxWidth: CGFloat = 640

    private var rows: [WindowRowView] = []
    private let stack = NSStackView()
    private(set) var windows: [WindowInfo] = []
    private(set) var selectedIndex = 0

    init() {
        super.init(contentRect: .zero,
                   styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
                   backing: .buffered, defer: false)
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Same look as AppSwitcherPanel: a frosted HUD blur, wrapped in Liquid
        // Glass on macOS 26+ for the edge highlight.
        let effect = NSView()
        let radius = WindowSwitcherPanel.cornerRadius
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = radius
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(effect)
        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            effect.topAnchor.constraint(equalTo: blur.topAnchor),
            effect.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = radius
            glass.contentView = blur
            contentView = glass
        } else {
            contentView = blur
        }

        stack.orientation = .vertical
        stack.spacing = 2
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        let p = WindowSwitcherPanel.padding
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: p),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -p),
            stack.topAnchor.constraint(equalTo: effect.topAnchor, constant: p),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -p),
        ])
    }

    func show(_ windows: [WindowInfo], selectIndex: Int) {
        self.windows = windows
        rows.forEach { $0.removeFromSuperview() }
        rows = windows.map { WindowRowView(window: $0, iconSize: WindowSwitcherPanel.iconSize) }

        // Size to the longest title, within bounds; long titles truncate in the middle.
        let font = NSFont.systemFont(ofSize: 14, weight: .medium)
        let longest = windows.map { ($0.title as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let chrome = WindowSwitcherPanel.iconSize + 48 + 2 * WindowSwitcherPanel.padding
        let width = min(WindowSwitcherPanel.maxWidth, max(WindowSwitcherPanel.minWidth, longest + chrome))

        for row in rows {
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: width - 2 * WindowSwitcherPanel.padding).isActive = true
            row.heightAnchor.constraint(equalToConstant: WindowSwitcherPanel.rowHeight).isActive = true
        }

        let height = CGFloat(rows.count) * (WindowSwitcherPanel.rowHeight + stack.spacing) - stack.spacing
            + 2 * WindowSwitcherPanel.padding
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        setFrame(NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height),
                 display: true)

        select(selectIndex)
        orderFrontRegardless()
    }

    func hidePanel() {
        orderOut(nil)
        rows.forEach { $0.removeFromSuperview() }
        rows = []
        windows = []
    }

    func selectNext() { select((selectedIndex + 1) % max(1, rows.count)) }
    func selectPrevious() { select((selectedIndex - 1 + rows.count) % max(1, rows.count)) }

    var selectedWindow: WindowInfo? { windows.indices.contains(selectedIndex) ? windows[selectedIndex] : nil }

    /// The row under a screen point, if any.
    func windowIndex(at screenPoint: NSPoint) -> Int? {
        guard frame.contains(screenPoint) else { return nil }
        for (i, row) in rows.enumerated() {
            let rect = row.convert(row.bounds, to: nil)
            if convertToScreen(rect).contains(screenPoint) { return i }
        }
        return nil
    }

    func select(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        selectedIndex = index
        for (i, row) in rows.enumerated() { row.isSelected = i == index }
    }
}

private class WindowRowView: NSView {
    var isSelected = false {
        didSet { layer?.backgroundColor = isSelected ? NSColor.white.withAlphaComponent(0.3).cgColor : nil }
    }

    init(window: WindowInfo, iconSize: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(image: window.icon)
        icon.imageScaling = .scaleProportionallyUpOrDown
        let label = NSTextField(labelWithString: window.title)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        label.alphaValue = window.isMinimized ? 0.6 : 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var views: [NSView] = [icon, label]
        if window.isMinimized {
            let badge = NSImageView(image: NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left",
                                                   accessibilityDescription: "Minimized") ?? NSImage())
            badge.contentTintColor = .secondaryLabelColor
            views.append(badge)
        }
        let row = NSStackView(views: views)
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: iconSize),
            icon.heightAnchor.constraint(equalToConstant: iconSize),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

import Cocoa

/// Owns the optional menu bar icon (`NSStatusItem`) and its menu.
/// The status item is not retained by the system, so this controller holds a
/// strong reference for as long as the icon should be visible.
class StatusBarController: NSObject, NSMenuDelegate {

    /// Invoked when the user picks "Preferences…" from the menu.
    var onOpenPreferences: (() -> Void)?

    /// Invoked when the user picks "Hide Other Apps" from the menu.
    var onHideOtherApps: (() -> Void)?

    private var statusItem: NSStatusItem?
    private var grayscaleItem: NSMenuItem?
    private var showAllItem: NSMenuItem?
    private let hiddenAppsMenu = NSMenu()

    /// Shows the menu bar icon (no-op if already visible).
    func show() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // ⌘ glyph, matching the app's command-key icon. Template image so it
        // adapts to the light/dark menu bar.
        let image = NSImage(systemSymbolName: "command", accessibilityDescription: "Switcher")
        image?.isTemplate = true
        item.button?.image = image
        item.menu = makeMenu()
        statusItem = item
    }

    /// Removes the menu bar icon (no-op if already hidden).
    func hide() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
        grayscaleItem = nil
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let prefs = NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        // Quick toggle — checkmark reflects the current setting (see menuNeedsUpdate).
        let grayscale = NSMenuItem(title: "Grayscale Icons", action: #selector(toggleGrayscale), keyEquivalent: "")
        grayscale.target = self
        grayscale.state = Preferences.grayscaleIcons ? .on : .off
        menu.addItem(grayscale)
        grayscaleItem = grayscale

        let showAll = NSMenuItem(title: "Show All Running Apps", action: #selector(toggleShowAll), keyEquivalent: "")
        showAll.target = self
        menu.addItem(showAll)
        showAllItem = showAll

        // Rebuilt on open (menuNeedsUpdate) from running apps + the saved list.
        let hidden = NSMenuItem(title: "Hidden from Switcher", action: nil, keyEquivalent: "")
        hiddenAppsMenu.delegate = self
        hidden.submenu = hiddenAppsMenu
        menu.addItem(hidden)

        menu.addItem(.separator())

        // Declutter: hide all apps except the frontmost so the switcher shows fewer
        // icons. No key equivalent — a status-menu accelerator only fires while the
        // menu is open; the real shortcut is ⌥⌘H inside the switcher panel.
        let hideOthers = NSMenuItem(title: "Hide Other Apps", action: #selector(hideOtherApps), keyEquivalent: "")
        hideOthers.target = self
        menu.addItem(hideOthers)

        menu.addItem(.separator())

        let donate = NSMenuItem(title: "Donate", action: #selector(donate), keyEquivalent: "")
        donate.target = self
        menu.addItem(donate)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Switcher", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === hiddenAppsMenu {
            rebuildHiddenAppsMenu()
            return
        }
        showAllItem?.state = Preferences.showAllRunningApps ? .on : .off
        // Reflect the current grayscale setting each time the menu opens (it may
        // have changed from the Preferences window or the terminal).
        grayscaleItem?.state = Preferences.grayscaleIcons ? .on : .off
    }

    /// Checked = hidden. Lists every running regular app plus any saved entry
    /// that isn't running, so an excluded app can be un-hidden at any time.
    private func rebuildHiddenAppsMenu() {
        hiddenAppsMenu.removeAllItems()
        let excluded = Preferences.excludedBundleIDs
        var entries: [String: (name: String, icon: NSImage?)] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { continue }
            entries[id] = (app.localizedName ?? id, app.icon)
        }
        for id in excluded where entries[id] == nil {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            let name = url.map { FileManager.default.displayName(atPath: $0.path) } ?? id
            entries[id] = (name.replacingOccurrences(of: ".app", with: ""), url.map { NSWorkspace.shared.icon(forFile: $0.path) })
        }
        for (id, entry) in entries.sorted(by: { $0.value.name.localizedCaseInsensitiveCompare($1.value.name) == .orderedAscending }) {
            let item = NSMenuItem(title: entry.name, action: #selector(toggleHiddenApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = excluded.contains(id) ? .on : .off
            if let icon = entry.icon?.copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            hiddenAppsMenu.addItem(item)
        }
    }

    // MARK: - Actions

    @objc private func toggleHiddenApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        // Takes effect on the next Cmd+Tab, since the list is rebuilt on open.
        var excluded = Preferences.excludedBundleIDs
        if excluded.contains(id) { excluded.remove(id) } else { excluded.insert(id) }
        Preferences.excludedBundleIDs = excluded
    }

    @objc private func toggleShowAll() {
        Preferences.showAllRunningApps.toggle()
    }

    @objc private func openPreferences() {
        onOpenPreferences?()
    }

    @objc private func toggleGrayscale() {
        // Takes effect on the next Cmd+Tab, since the panel rebuilds its icons.
        Preferences.grayscaleIcons.toggle()
    }

    @objc private func hideOtherApps() {
        onHideOtherApps?()
    }

    @objc private func donate() {
        Preferences.openDonatePage()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

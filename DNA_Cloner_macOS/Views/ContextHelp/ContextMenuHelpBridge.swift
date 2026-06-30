//
//  ContextMenuHelpBridge.swift
//  Cloner 64
//
//  Makes menu bar items drive the Context Help panel.
//
//  SwiftUI menu items don't expose a hover event, so to light up the help
//  panel as the user moves through the menu bar we have to drop down to
//  AppKit and act as an NSMenuDelegate. This class listens for
//  `NSMenu.didBeginTrackingNotification` — which fires every time any menu
//  starts opening — and at that moment installs itself as delegate on the
//  menu (overriding whatever SwiftUI set). SwiftUI rebuilds menus between
//  openings, so we re-install every time rather than once at launch.
//
//  When the user then highlights an item, `menu(_:willHighlight:)` fires;
//  we look up the item's title in `ContextHelpManager.menuItemHelpKeys`
//  and update the panel.
//

import AppKit

final class ContextMenuHelpBridge: NSObject, NSMenuDelegate {

    static let shared = ContextMenuHelpBridge()

    private var trackingObserver: Any?

    private override init() { super.init() }

    /// Begin listening for menu events. Safe to call multiple times.
    func install() {
        // Also do an initial sweep of the main menu so items that might
        // already be open get covered.
        if let mainMenu = NSApp.mainMenu {
            installRecursively(in: mainMenu)
        }

        // Re-install on every menu tracking event. This is the key to
        // making it work against SwiftUI's menu system — SwiftUI rebuilds
        // its NSMenus between openings, so a one-shot install at launch
        // would only work on the first opening at best.
        if trackingObserver == nil {
            trackingObserver = NotificationCenter.default.addObserver(
                forName: NSMenu.didBeginTrackingNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self = self,
                      let menu = notification.object as? NSMenu else { return }
                self.installRecursively(in: menu)
            }
        }
    }

    /// Walk a menu tree and force ourselves to be the delegate on every
    /// submenu, overriding any existing delegate. SwiftUI's delegate does
    /// very little, and without overriding it the `menu(_:willHighlight:)`
    /// callback never reaches us.
    private func installRecursively(in menu: NSMenu) {
        menu.delegate = self
        for item in menu.items {
            if let sub = item.submenu {
                installRecursively(in: sub)
            }
        }
    }

    // MARK: - NSMenuDelegate

    /// Fires every time the highlighted menu item changes while a
    /// menu is open. `item` is nil when nothing is highlighted.
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard ContextHelpManager.shared.isEnabled else { return }

        // If the highlighted item has a submenu, pre-install ourselves on
        // it so that when the user arrows into it our highlight callback
        // still fires.
        if let item = item, let sub = item.submenu {
            installRecursively(in: sub)
        }

        if let item = item,
           let key = ContextHelpManager.shared.menuItemHelpKeys[item.title] {
            ContextHelpManager.shared.show(forKey: key)
        } else {
            ContextHelpManager.shared.clear()
        }
    }

    /// Clear the panel back to its idle message when a menu closes.
    func menuDidClose(_ menu: NSMenu) {
        if ContextHelpManager.shared.isEnabled {
            ContextHelpManager.shared.clear()
        }
    }
}

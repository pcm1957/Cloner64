//
//  ContextHelpPanel.swift
//  Cloner 64
//
//  A small floating panel that displays the current context help text.
//  It floats above other windows but does NOT steal keyboard focus,
//  so the user can keep typing in the sequence editor while it's open.
//

import SwiftUI
import AppKit

// MARK: - The SwiftUI view shown inside the panel

struct ContextHelpPanelView: View {
    @ObservedObject var manager = ContextHelpManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(manager.currentTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                Button(action: { manager.isEnabled = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close Context Help")
            }

            Divider()

            Text(manager.currentText)
                .font(.system(size: 14))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(minWidth: 340, maxWidth: 420)
    }
}

// MARK: - The window controller that owns the floating panel

final class ContextHelpPanelController {

    static let shared = ContextHelpPanelController()

    private var panel: NSPanel?
    private var hosting: NSHostingController<ContextHelpPanelView>?

    private init() {}

    func show() {
        if panel == nil {
            let hosting = NSHostingController(rootView: ContextHelpPanelView())
            self.hosting = hosting

            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 100),
                styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel, .resizable],
                backing: .buffered,
                defer: false
            )
            panel.title = "Context Help"
            panel.contentViewController = hosting
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            // Position it in the top-right of the main screen by default.
            if let screen = NSScreen.main {
                let f = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: f.maxX - 440, y: f.maxY - 300))
            }

            // If the user closes the panel via its red button, flip the toggle off.
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: panel,
                queue: .main
            ) { _ in
                ContextHelpManager.shared.isEnabled = false
            }

            self.panel = panel
        }
        panel?.orderFrontRegardless()
    }

    /// Resize the panel to exactly fit its current SwiftUI content.
    /// Called by ContextHelpManager whenever the displayed text changes.
    func sizeToFit() {
        guard let panel = panel, let hosting = hosting else { return }
        let fitted = hosting.sizeThatFits(in: CGSize(width: 380, height: CGFloat.greatestFiniteMagnitude))
        // Keep the panel's current top-left corner fixed while resizing downward
        let currentFrame = panel.frame
        let newHeight = fitted.height + 28   // +28 for the NSPanel title bar
        let newOriginY = currentFrame.maxY - newHeight
        panel.setFrame(NSRect(x: currentFrame.origin.x,
                              y: newOriginY,
                              width: max(fitted.width, 340),
                              height: newHeight), display: true, animate: false)
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

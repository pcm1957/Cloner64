import SwiftUI
import AppKit

// MARK: - Window Manager for Graphical Map
// MARK: - Self-removing window-close observer

/// Registers an NSWindow.willCloseNotification observer that unregisters itself
/// as soon as it fires, and runs `action`.
///
/// Why this exists: the obvious inline version needs a mutable local to hold the
/// observer token so the handler can remove it —
///
///     var token: NSObjectProtocol?
///     token = NotificationCenter.default.addObserver(...) { _ in
///         ...
///         if let token { NotificationCenter.default.removeObserver(token) }
///     }
///
/// — but NotificationCenter's block API takes a @Sendable closure, and Swift
/// rejects mutating a captured variable after capture ("'token' mutated after
/// capture by sendable closure"). Holding the token inside a reference box means
/// the captured value itself never changes, only the box's contents.
///
/// Without removal, NotificationCenter keeps the handler for the lifetime of the
/// app, the handler holds the window, and — with isReleasedWhenClosed = false —
/// nothing ever releases the window, its hosting controller, its SwiftUI view or
/// the sequence data captured with it.
@discardableResult
func observeWindowClose(_ window: NSWindow,
                        perform action: @escaping () -> Void) -> NSObjectProtocol {
    /// Everything here runs on the main queue, so the box is safe to share.
    final class TokenBox: @unchecked Sendable {
        var token: NSObjectProtocol?
    }
    let box = TokenBox()
    let token = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification,
        object: window,
        queue: .main
    ) { _ in
        action()
        if let existing = box.token {
            NotificationCenter.default.removeObserver(existing)
            box.token = nil
        }
    }
    box.token = token
    return token
}

class GraphicalMapWindowManager {
    static let shared = GraphicalMapWindowManager()
    
    private var mapWindows: [NSWindow] = []
    
    private init() {}
    
    /// Opens a new window with the graphical map view for the given sequence
    func openGraphicalMapWindow(for sequence: DNASequence) {
        // If a map window for this sequence is already open, just bring it forward.
        let expectedTitle = "Graphical Map - \(sequence.name)"
        if let existing = mapWindows.first(where: { $0.isVisible && $0.title == expectedTitle }) {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // Create the SwiftUI view
        let mapView = GraphicalMapWindow(sequence: sequence)
        
        // Wrap in a hosting controller
        let hostingController = NSHostingController(rootView: mapView)
        
        // Size the window to show the full map — use most of the screen
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let windowWidth = min(screenFrame.width * 0.85, 1350)
        let windowHeight = min(screenFrame.height * 0.85, 850)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        window.title = "Graphical Map - \(sequence.name)"
        window.contentViewController = hostingController
        window.setFrameAutosaveName("GraphicalMap")
        if !window.setFrameUsingName(window.frameAutosaveName) { window.center() }
        window.isReleasedWhenClosed = false
        
        // Set minimum size
        window.minSize = NSSize(width: 900, height: 650)
        
        // Show the window
        window.makeKeyAndOrderFront(nil)
        
        // Keep track of the window
        mapWindows.append(window)
        
        // Clean up when the window closes. observeWindowClose unregisters itself,
        // which releases the handler and with it the window — previously the
        // observer was never removed, so every map ever opened stayed in memory.
        observeWindowClose(window) { [weak self] in
            self?.mapWindows.removeAll { $0 == window }
        }
    }
    
    /// Closes all graphical map windows
    func closeAllMapWindows() {
        mapWindows.forEach { $0.close() }
        mapWindows.removeAll()
    }
}

// MARK: - Usage Example
// Add this to your main ContentView or sequence view:
/*
 Button("Show Graphical Map") {
     GraphicalMapWindowManager.shared.openGraphicalMapWindow(for: sequence)
 }
 .keyboardShortcut("g", modifiers: [.command, .shift])
*/

// MARK: - Alternative: Sheet-based approach (if you prefer sheets over windows)
extension View {
    func graphicalMapSheet(
        sequence: Binding<DNASequence?>,
        isPresented: Binding<Bool>
    ) -> some View {
        self.sheet(isPresented: isPresented) {
            if let seq = sequence.wrappedValue {
                GraphicalMapWindow(sequence: seq)
                    .frame(minWidth: 800, minHeight: 600)
            }
        }
    }
}

import SwiftUI
import AppKit

// MARK: - Window Manager for Graphical Map
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
        
        // Clean up when window is closed
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
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

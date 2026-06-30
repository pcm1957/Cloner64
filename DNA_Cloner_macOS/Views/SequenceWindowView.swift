//
//  SequenceWindowView.swift
//  Cloner 64
//
//  A standalone window that shows a single SequenceEditorView.
//  Opened via WindowGroup(for: UUID.self) — the UUID identifies which
//  sequence from the SequenceManager to display.
//

import SwiftUI
import AppKit
import Combine


// MARK: - Sequence Window Root View
/// Used by the default (unnamed) WindowGroup on launch and Cmd+N.
/// Creates a new empty sequence for each window instance.
/// If a file is opened while this window's sequence is empty, it adopts the loaded sequence
/// in-place rather than opening a separate window.
struct SequenceWindowRootView: View {
    @EnvironmentObject var sequenceManager: SequenceManager
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    
    @State private var windowSequenceID: UUID?
    @State private var didSetup = false
    @ObservedObject private var helpManager = ContextHelpManager.shared
    
    /// Whether our window's sequence is an untouched empty placeholder
    private var windowSequenceIsEmpty: Bool {
        guard let id = windowSequenceID,
              let seq = sequenceManager.sequences.first(where: { $0.id == id }) else { return true }
        return seq.sequence.isEmpty
    }
    
    var body: some View {
        Group {
            if let id = windowSequenceID,
               let seq = sequenceManager.sequences.first(where: { $0.id == id }) {
                SequenceEditorView(sequence: seq)
                    .id(seq.id)
                    .textSelection(.enabled)
                    .navigationTitle(seq.name.isEmpty ? "Untitled Sequence" : seq.name)
            } else {
                VStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
        }
        .frame(minWidth: 600, minHeight: 500)
        .background {
            if let id = windowSequenceID,
               let seq = sequenceManager.sequences.first(where: { $0.id == id }) {
                WindowCloseGuard(sequence: seq, sequenceManager: sequenceManager)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                if let id = windowSequenceID,
                   let sequence = sequenceManager.sequences.first(where: { $0.id == id }) {
                    Button(action: {
                        FeatureCollectionWindowManager.shared.openWindow(for: sequence)
                    }) {
                        VStack(spacing: 1) {
                            Image(systemName: "tag")
                                .foregroundColor(.blue)
                            Text("Feature Collection")
                                .font(.caption2)
                        }
                    }
                    .help("Open Feature Collection")
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .contextHelp("toolbar.featureCollection")
                    
                    Button(action: {
                        SequenceMapWindowManager.shared.openSequenceMapWindow(for: sequence)
                    }) {
                        VStack(spacing: 1) {
                            Image(systemName: "list.bullet.rectangle")
                                .foregroundColor(.green)
                            Text("Sequence Map")
                                .font(.caption2)
                        }
                    }
                    .help("Open sequence map in new window")
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .contextHelp("toolbar.sequenceMap")
                    
                    Button(action: {
                        GraphicalMapWindowManager.shared.openGraphicalMapWindow(for: sequence)
                    }) {
                        VStack(spacing: 1) {
                            Image(systemName: "circle.hexagonpath")
                                .foregroundColor(.red)
                            Text("Graphic Map")
                                .font(.caption2)
                        }
                    }
                    .help("Open graphical plasmid map in new window")
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .contextHelp("toolbar.graphicMap")
                    
                    Button(action: {
                        VirtualCutterWindowManager.shared.openWindow(sequenceManager: sequenceManager)
                    }) {
                        VStack(spacing: 1) {
                            Image(systemName: "scissors")
                                .foregroundColor(.orange)
                            Text("Virtual Cutter")
                                .font(.caption2)
                        }
                    }
                    .help("Open Virtual Cutter")
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .contextHelp("toolbar.virtualCutter")
                    
                    Button(action: {
                        ConstructCheckWindowManager.shared.openWindow(for: sequence)
                    }) {
                        VStack(spacing: 1) {
                            Image(systemName: "stethoscope")
                                .foregroundColor(.teal)
                            Text("Check Construct")
                                .font(.caption2)
                        }
                    }
                    .help("Recommend diagnostic digests to verify this construct")
                    .contextHelp("toolbar.checkConstruct")
                    
                    Button(action: {
                        helpManager.isEnabled.toggle()
                    }) {
                        VStack(spacing: 1) {
                            Image(systemName: helpManager.isEnabled
                                  ? "questionmark.circle.fill"
                                  : "questionmark.circle")
                                .foregroundColor(.purple)
                            Text("Context Help")
                                .font(.caption2)
                        }
                    }
                    .help("Toggle Context Help (⇧⌘?)")
                    .contextHelp("toolbar.contextHelpToggle")
                }
            }
        }
        .onAppear {
            // Wire up the singleton so menu commands can open named windows.
            // Set installedHandler (NOT the public openSequenceWindow method)
            // and flip hasHandler so the safe wrapper takes the fast path.
            SequenceWindowOpener.shared.installedHandler = { seqID in
                let forceNew = SequenceWindowOpener.shared.forceNewWindow
                SequenceWindowOpener.shared.forceNewWindow = false  // reset after reading
                
                // Adopt-into-empty-placeholder is only valid for the FIRST
                // file opened after app launch — at that point the root
                // window is still showing the auto-created Untitled empty
                // sequence and we can swap it for the file. After that,
                // subsequent opens always create a new named window so the
                // user doesn't lose their current sequence.
                let canAdopt = !forceNew
                    && !SequenceWindowOpener.shared.hasAdoptedFirstFile
                    && windowSequenceIsEmpty
                    && seqID != windowSequenceID
                
                if canAdopt {
                    let oldID = windowSequenceID
                    windowSequenceID = seqID
                    SequenceWindowOpener.shared.hasAdoptedFirstFile = true
                    // Tell the opener we adopted in-place so it suppresses
                    // the notification backstop.
                    SequenceWindowOpener.shared.lastAdoptedID = seqID
                    // Remove the old empty placeholder
                    if let oldID = oldID {
                        sequenceManager.sequences.removeAll { $0.id == oldID }
                    }
                } else if seqID != windowSequenceID {
                    openWindow(id: "sequence", value: seqID)
                }
            }
            SequenceWindowOpener.shared.hasHandler = true
            
            // Wire up protein window opener
            ProteinWindowOpener.shared.openProteinWindow = { protID in
                openWindow(id: "protein", value: protID)
            }
            
            // Create a new empty sequence for this window (once only)
            if !didSetup {
                didSetup = true
                let newSeq = DNASequence(name: "Untitled", sequence: "")
                sequenceManager.sequences.append(newSeq)
                sequenceManager.currentSequence = newSeq
                windowSequenceID = newSeq.id
            }
        }
    }
}


// MARK: - Sequence Window View (for named/programmatic windows)
struct SequenceWindowView: View {
    let sequenceID: UUID
    @EnvironmentObject var sequenceManager: SequenceManager
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var helpManager = ContextHelpManager.shared
    
    var body: some View {
        Group {
            if let sequence = sequenceManager.sequences.first(where: { $0.id == sequenceID }) {
                SequenceEditorView(sequence: sequence)
                    .textSelection(.enabled)
                    .frame(minWidth: 600, minHeight: 500)
                    .navigationTitle(sequence.name.isEmpty ? "Untitled Sequence" : sequence.name)
                    .background(WindowCloseGuard(sequence: sequence, sequenceManager: sequenceManager))
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("Sequence not found")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("This sequence may have been deleted.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(minWidth: 400, minHeight: 300)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                if let sequence = sequenceManager.sequences.first(where: { $0.id == sequenceID }) {
                    Button(action: {
                        FeatureCollectionWindowManager.shared.openWindow(for: sequence)
                    }) {
                        VStack(spacing: 1) {
                            Image(systemName: "tag")
                                .foregroundColor(.blue)
                            Text("Feature Collection")
                                .font(.caption2)
                        }
                    }
                    .help("Open Feature Collection")
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .contextHelp("toolbar.featureCollection")
                    
                    Button(action: {
                        SequenceMapWindowManager.shared.openSequenceMapWindow(for: sequence)
                    }) {
                        VStack(spacing: 1) {
                            Image(systemName: "list.bullet.rectangle")
                                .foregroundColor(.green)
                            Text("Sequence Map")
                                .font(.caption2)
                        }
                    }
                    .help("Open sequence map in new window")
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .contextHelp("toolbar.sequenceMap")
                    
                    Button(action: {
                        GraphicalMapWindowManager.shared.openGraphicalMapWindow(for: sequence)
                    }) {
                        VStack(spacing: 1) {
                            Image(systemName: "circle.hexagonpath")
                                .foregroundColor(.red)
                            Text("Graphic Map")
                                .font(.caption2)
                        }
                    }
                    .help("Open graphical plasmid map in new window")
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .contextHelp("toolbar.graphicMap")
                    
                    Button(action: {
                        VirtualCutterWindowManager.shared.openWindow(sequenceManager: sequenceManager)
                    }) {
                        VStack(spacing: 1) {
                            Image(systemName: "scissors")
                                .foregroundColor(.orange)
                            Text("Virtual Cutter")
                                .font(.caption2)
                        }
                    }
                    .help("Open Virtual Cutter")
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .contextHelp("toolbar.virtualCutter")
                    
                    Button(action: {
                        ConstructCheckWindowManager.shared.openWindow(for: sequence)
                    }) {
                        VStack(spacing: 1) {
                            Image(systemName: "stethoscope")
                                .foregroundColor(.teal)
                            Text("Check Construct")
                                .font(.caption2)
                        }
                    }
                    .help("Recommend diagnostic digests to verify this construct")
                    .contextHelp("toolbar.checkConstruct")
                    
                    Button(action: {
                        helpManager.isEnabled.toggle()
                    }) {
                        VStack(spacing: 1) {
                            Image(systemName: helpManager.isEnabled
                                  ? "questionmark.circle.fill"
                                  : "questionmark.circle")
                                .foregroundColor(.purple)
                            Text("Context Help")
                                .font(.caption2)
                        }
                    }
                    .help("Toggle Context Help (⇧⌘?)")
                    .contextHelp("toolbar.contextHelpToggle")
                }
            }
        }
        .onAppear {
            // Keep the opener wired (set installedHandler, NOT the public method)
            SequenceWindowOpener.shared.installedHandler = { seqID in
                openWindow(id: "sequence", value: seqID)
            }
            SequenceWindowOpener.shared.hasHandler = true
            
            // Wire up protein window opener
            ProteinWindowOpener.shared.openProteinWindow = { protID in
                openWindow(id: "protein", value: protID)
            }
            
            // Set as current sequence when window appears
            if let seq = sequenceManager.sequences.first(where: { $0.id == sequenceID }) {
                sequenceManager.currentSequence = seq
            }
        }
    }
}


// MARK: - Window Close Guard
/// Invisible NSViewRepresentable that intercepts the window close button.
/// If the sequence has unsaved changes, shows a Save / Don't Save / Cancel alert.
struct WindowCloseGuard: NSViewRepresentable {
    let sequence: DNASequence
    let sequenceManager: SequenceManager
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.sequenceManager = sequenceManager
        // Attach to the hosting window once it's available
        DispatchQueue.main.async {
            if let window = view.window {
                context.coordinator.attach(to: window, sequence: sequence)
            }
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.sequence = sequence
        context.coordinator.sequenceManager = sequenceManager
        // Re-attach if window changed
        if let window = nsView.window, context.coordinator.attachedWindow !== window {
            context.coordinator.attach(to: window, sequence: sequence)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject, NSWindowDelegate {
        var sequence: DNASequence?
        var sequenceManager: SequenceManager?
        weak var attachedWindow: NSWindow?
        private var originalDelegate: NSWindowDelegate?
        
        func attach(to window: NSWindow, sequence: DNASequence) {
            self.sequence = sequence
            // Store original delegate so we can forward other calls
            if window.delegate !== self {
                self.originalDelegate = window.delegate
                window.delegate = self
            }
            self.attachedWindow = window
        }
        
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard let seq = sequence, seq.isDirty else {
                return true  // No unsaved changes — close immediately
            }
            
            // Show save alert
            let alert = NSAlert()
            alert.messageText = "Do you want to save changes to \"\(seq.name)\"?"
            alert.informativeText = "Your changes will be lost if you don't save them."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")
            
            let response = alert.runModal()
            
            switch response {
            case .alertFirstButtonReturn:
                // Save — then close
                if let mgr = sequenceManager {
                    mgr.currentSequence = seq
                    if seq.sourceURL != nil {
                        mgr.saveSequence()
                        return true
                    } else {
                        // Save As — show panel, close after save completes
                        mgr.saveSequenceAs()
                        // If they saved, isDirty will be false
                        return !seq.isDirty
                    }
                }
                return true
                
            case .alertSecondButtonReturn:
                // Don't Save — close without saving
                return true
                
            default:
                // Cancel — don't close
                return false
            }
        }
        
        /// When the window closes, remove the sequence from the manager's array
        func windowWillClose(_ notification: Notification) {
            if let seq = sequence, let mgr = sequenceManager {
                mgr.sequences.removeAll { $0.id == seq.id }
                if mgr.currentSequence?.id == seq.id {
                    mgr.currentSequence = mgr.sequences.first
                }
            }
            originalDelegate?.windowWillClose?(notification)
        }
        
        /// When this DNA window becomes key, clear protein context so Save targets the right thing
        func windowDidBecomeKey(_ notification: Notification) {
            if let seq = sequence, let mgr = sequenceManager {
                mgr.currentSequence = seq
                mgr.currentProtein = nil
            }
            originalDelegate?.windowDidBecomeKey?(notification)
        }
        
        func windowDidResignKey(_ notification: Notification) {
            originalDelegate?.windowDidResignKey?(notification)
        }
    }
}

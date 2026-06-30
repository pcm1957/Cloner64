//
//  DNAClonerApp.swift
//  Cloner 64 - A macOS DNA Analysis Application
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit
import Combine

extension Notification.Name {
    static let makeUppercase = Notification.Name("makeUppercase")
    static let makeLowercase = Notification.Name("makeLowercase")
    static let sequenceUndo = Notification.Name("sequenceUndo")
    static let sequenceRedo = Notification.Name("sequenceRedo")
    static let sequenceSave = Notification.Name("sequenceSave")
    static let sequenceSaveAs = Notification.Name("sequenceSaveAs")
    /// Posted by SequenceWindowOpener whenever a sequence window should be opened.
    /// userInfo["id"] = UUID, userInfo["forceNew"] = Bool
    static let openSequenceWindowRequest = Notification.Name("openSequenceWindowRequest")
}

@main
struct Cloner64App: App {
    @StateObject private var sequenceManager = SequenceManager()
    @StateObject private var appState = AppState()
    @ObservedObject private var helpManager = ContextHelpManager.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    @FocusedValue(\.activeSequence) var activeSequence: DNASequence?
    @FocusedValue(\.sequenceEditActions) var editActions: SequenceEditActions?
    
    var body: some Scene {
        // MARK: - Default Window
        WindowGroup {
            SequenceWindowRootView()
                .environmentObject(sequenceManager)
                .environmentObject(appState)
                .modifier(SequenceWindowOpenDispatcher())
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    handleFileDrop(providers)
                }
                .onAppear {
                    // Set the sequenceManager on the delegate on every appear,
                    // but only show the welcome screen once (on first launch).
                    appDelegate.sequenceManager = sequenceManager
                    ConstructCheckWindowManager.shared.sequenceManager = sequenceManager  // ← add this
                    if !appDelegate.hasFinishedInitialSetup {
                        appDelegate.hasFinishedInitialSetup = true
                        let shouldShow = UserDefaults.standard.object(forKey: "Welcome.ShowOnStartup") as? Bool ?? true
                        if shouldShow {
                            WelcomeWindowManager.shared.openWindow(sequenceManager: sequenceManager)
                        }
                    }
                }
        }
        .defaultSize(width: 750, height: 600)
        
        // MARK: - Named Sequence Windows
        WindowGroup(id: "sequence", for: UUID.self) { $sequenceID in
            if let id = sequenceID {
                SequenceWindowView(sequenceID: id)
                    .environmentObject(sequenceManager)
                    .environmentObject(appState)
                    .modifier(SequenceWindowOpenDispatcher())
                    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                        handleFileDrop(providers)
                    }
                    .onDisappear {
                        // Clear the adopted-in-place marker so this file can be
                        // reopened from Open Recent after its window is closed.
                        SequenceWindowOpener.shared.clearAdoptedID(id)
                    }
            }
        }
        .defaultSize(width: 750, height: 600)
        
        // MARK: - Commands
        .commands {
            // ── File Menu ──
            CommandGroup(replacing: .newItem) {
                Menu("New") {
                    Button("DNA Sequence") {
                        let newSeq = DNASequence(name: "Untitled", sequence: "")
                        sequenceManager.sequences.append(newSeq)
                        sequenceManager.currentSequence = newSeq
                        SequenceWindowOpener.shared.forceNewWindow = true
                        SequenceWindowOpener.shared.openSequenceWindow(newSeq.id)
                    }
                    .keyboardShortcut("n", modifiers: .command)
                    
                    Button("Protein Sequence") {
                        let newProt = ProteinSequence(name: "Untitled Protein", sequence: "")
                        sequenceManager.proteinSequences.append(newProt)
                        sequenceManager.currentProtein = newProt
                        ProteinWindowOpener.shared.openProteinWindow(newProt.id)
                    }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                }
                
                Divider()
                
                Button("Open...") {
                    sequenceManager.openSequence()
                }
                .keyboardShortcut("o", modifiers: .command)
                
                Menu("Open Recent") {
                    // INTENTIONALLY STATIC. The real contents are a native NSMenu
                    // installed by AppDelegate.refreshNativeRecentFilesMenu(), which
                    // runs in menuWillOpen(_:) just before the menu renders.
                    //
                    // This body must NOT reference RecentFilesManager.recentFiles or
                    // any other observable: doing so makes SwiftUI re-evaluate the
                    // Menu while the submenu is open (on hover, or when @Published
                    // recentFiles changes), which replaces the native submenu mid-
                    // track and makes the list vanish before the user can click a
                    // file. A single static placeholder keeps SwiftUI from ever
                    // rebuilding this submenu; the native menu supplies the items.
                    Text("No Recent Files").foregroundColor(.secondary)
                }
                
                Button("Open Sample File (pUC19)") {
                    // If a pUC19 sample is already open, just bring it forward.
                    if let existing = sequenceManager.sequences.first(where: { $0.name == "pUC19" }) {
                        SequenceWindowOpener.shared.openSequenceWindow(existing.id)
                    } else {
                        // No sample open yet — create a fresh copy.
                        let sample = sequenceManager.loadSampleSequence()
                        SequenceWindowOpener.shared.forceNewWindow = true
                        SequenceWindowOpener.shared.openSequenceWindow(sample.id)
                    }
                }
                
                Divider()
                
                Menu("DNA Sequences") {
                    if sequenceManager.sequences.isEmpty {
                        Text("No DNA sequences open")
                    } else {
                        ForEach(sequenceManager.sequences) { seq in
                            Button {
                                sequenceManager.currentSequence = seq
                                SequenceWindowOpener.shared.openSequenceWindow(seq.id)
                            } label: {
                                HStack {
                                    Text(seq.name)
                                    Text("(\(seq.length) bp, \(seq.isCircular ? "circular" : "linear"))")
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        
                        Divider()
                        
                        Button("Close All DNA Sequences") {
                            sequenceManager.sequences.removeAll()
                            sequenceManager.currentSequence = nil
                        }
                    }
                }
                
                Menu("Protein Sequences") {
                    if sequenceManager.proteinSequences.isEmpty {
                        Text("No protein sequences open")
                    } else {
                        ForEach(sequenceManager.proteinSequences) { prot in
                            Button {
                                sequenceManager.currentProtein = prot
                                ProteinWindowOpener.shared.openProteinWindow(prot.id)
                            } label: {
                                HStack {
                                    Text(prot.name)
                                    Text("(\(prot.length) aa)")
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        
                        Divider()
                        
                        Button("Close All Protein Sequences") {
                            sequenceManager.proteinSequences.removeAll()
                            sequenceManager.currentProtein = nil
                        }
                    }
                }
            }
            
            // ── Edit Menu: Undo / Redo ──
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    NotificationCenter.default.post(name: .sequenceUndo, object: nil)
                }
                .keyboardShortcut("z", modifiers: .command)
                
                Button("Redo") {
                    NotificationCenter.default.post(name: .sequenceRedo, object: nil)
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            
            // ── Edit Menu: Pasteboard ──
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") {
                    NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("x", modifiers: .command)
                
                Button("Copy") {
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("c", modifiers: .command)
                
                Button("Paste") {
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("v", modifiers: .command)
                
                Button("Delete") {
                    NSApp.sendAction(#selector(NSText.delete(_:)), to: nil, from: nil)
                }
                .keyboardShortcut(.delete, modifiers: [])
                
                Divider()
                
                Button("Select All") {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("a", modifiers: .command)
                
                Divider()
                
                Button("Make Uppercase") {
                    // Route through the responder chain — reaches MouseTrackingNSView
                    // (custom sequence editor) or NSTextView field editor (standard TextFields)
                    NSApp.sendAction(NSSelectorFromString("uppercaseWord:"), to: nil, from: nil)
                }
                .keyboardShortcut("u", modifiers: .command)
                
                Button("Make Lowercase") {
                    NSApp.sendAction(NSSelectorFromString("lowercaseWord:"), to: nil, from: nil)
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                
                Divider()
                
                Button("Paste as New Sequence") {
                    sequenceManager.pasteAsNewSequence()
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            }
            
            // ── Save / Export ──
            CommandGroup(after: .newItem) {
                Button("Save") {
                    NotificationCenter.default.post(name: .sequenceSave, object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)
                
                Button("Save As...") {
                    NotificationCenter.default.post(name: .sequenceSaveAs, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                
                Divider()
                
                Menu("Export DNA") {
                    Button("as FASTA...") {
                        sequenceManager.exportAsFASTA()
                    }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    
                    Button("as GenBank...") {
                        sequenceManager.exportAsGenBank()
                    }
                    
                    Button("as APE...") {
                        sequenceManager.exportAsAPE()
                    }
                }
                
                Menu("Export Protein") {
                    Button("as FASTA...") {
                        if let prot = sequenceManager.currentProtein {
                            sequenceManager.exportProteinAsFASTA(prot)
                        }
                    }
                    
                    Button("as XPRT...") {
                        if let prot = sequenceManager.currentProtein {
                            sequenceManager.saveProteinAs(prot)
                        }
                    }
                }
            }
            
            // ── Print ──
            CommandGroup(replacing: .printItem) {
                Button("Page Setup...") {
                    sequenceManager.pageSetup()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                
                Button("Print...") {
                    guard let window = NSApp.keyWindow,
                          let contentView = window.contentView else {
                        sequenceManager.printSequence()
                        return
                    }
                    guard let bitmapRep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else {
                        sequenceManager.printSequence()
                        return
                    }
                    contentView.cacheDisplay(in: contentView.bounds, to: bitmapRep)
                    let image = NSImage(size: contentView.bounds.size)
                    image.addRepresentation(bitmapRep)
                    let imageView = NSImageView(frame: contentView.bounds)
                    imageView.image = image
                    let printInfo = NSPrintInfo.shared
                    let op = NSPrintOperation(view: imageView, printInfo: printInfo)
                    op.showsPrintPanel = true
                    op.showsProgressPanel = true
                    op.run()
                }
                .keyboardShortcut("p", modifiers: .command)
            }
            
            // ── Tools Menu ──
            CommandMenu("Tools") {
                Button("Feature Collection...") {
                    FeatureCollectionWindowManager.shared.openWindow(for: sequenceManager.currentSequence)
                }
                .keyboardShortcut("l", modifiers: .command)
                
                Divider()
                
                Button("Scan Sequence for Features") {
                    if let seq = sequenceManager.currentSequence {
                        let library = FeatureLibraryManager.shared
                        library.scanSequence(seq)
                        library.applyResults(to: seq, results: library.scanResults)
                    }
                }
                .keyboardShortcut("b", modifiers: .command)
                
                Divider()
                
                Button("Translate Selection...") {
                    sequenceManager.translateSelection()
                }
                .keyboardShortcut("t", modifiers: .command)
                
                Button("Reverse Complement") {
                                    if let seq = activeSequence { sequenceManager.currentSequence = seq }
                                    sequenceManager.reverseComplement()
                                }
                                
                                Button("Reverse") {
                                    if let seq = activeSequence { sequenceManager.currentSequence = seq }
                                    sequenceManager.reverseSequence()
                                }
                                
                                Button("Complement") {
                                    if let seq = activeSequence { sequenceManager.currentSequence = seq }
                                    sequenceManager.complementSequence()
                                }
                                
                                Divider()
                                
                                Button("Convert to RNA (T→U)") {
                                    if let seq = activeSequence { sequenceManager.currentSequence = seq }
                                    sequenceManager.convertToRNA()
                                }
                                
                                Button("Convert to DNA (U→T)") {
                                    if let seq = activeSequence { sequenceManager.currentSequence = seq }
                                    sequenceManager.convertToDNA()
                                }
                
                Divider()
                
                Button("Site Usage...") {
                    // Robustly determine which sequence the user wants to analyse,
                    // trying multiple sources in priority order.  Without this the
                    // window can come up showing an empty Untitled placeholder if
                    // activeSequence is nil at click time and currentSequence
                    // happens to point at a stale or empty entry.
                    var initial: DNASequence? = activeSequence
                        ?? sequenceManager.currentSequence
                    
                    // Fallback 1: try matching the frontmost window's title against
                    // an open non-empty sequence name.
                    if initial == nil || (initial?.sequence.isEmpty ?? true),
                       let title = NSApp.keyWindow?.title {
                        if let match = sequenceManager.sequences.first(where: {
                            !$0.sequence.isEmpty && title.contains($0.name)
                        }) {
                            initial = match
                        }
                    }
                    
                    // Fallback 2: first non-empty sequence in the manager.
                    if initial == nil || (initial?.sequence.isEmpty ?? true) {
                        if let nonEmpty = sequenceManager.sequences.first(where: { !$0.sequence.isEmpty }) {
                            initial = nonEmpty
                        }
                    }
                    
                    if let seq = initial {
                        sequenceManager.currentSequence = seq
                    }
                    SiteUsageWindowManager.shared.openWindow(
                        sequenceManager: sequenceManager,
                        initialSequence: initial
                    )
                }
                
                Divider()
                
                Button("Restriction Enzyme List...") {
                    RestrictionEnzymeListWindowManager.shared.openWindow()
                }
                
                Button("Compatible Cohesive Ends...") {
                    CompatibleEndsWindowManager.shared.openWindow()
                }
                Button("Cloning Vector Library…") {
                    ShuttleVectorListWindowManager.shared.openWindow()
                }
                Divider()
                
                Button("Genetic Code") {
                    GeneticCodeWindowManager.shared.openWindow()
                }
                
                Button("IUPAC Nucleotide Codes") {
                    IUPACCodesWindowManager.shared.openWindow()
                }
            }
            
            // ── Function Menu ──
            CommandMenu("Function") {
                Button("Build a Construct...") {
                    ConstructBuilderWindowManager.shared.openWindow(sequenceManager: sequenceManager)
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                
                Button("Check Construct…") {
                    var target: DNASequence? = activeSequence
                    ?? sequenceManager.currentSequence
                    if target == nil || (target?.sequence.isEmpty ?? true),
                       let title = NSApp.keyWindow?.title {
                        if let match = sequenceManager.sequences.first(where: {
                            !$0.sequence.isEmpty && title.contains($0.name)
                        }) {
                            target = match
                        }
                    }
                    if target == nil || (target?.sequence.isEmpty ?? true) {
                        if let nonEmpty = sequenceManager.sequences.first(where: { !$0.sequence.isEmpty }) {
                            target = nonEmpty
                        }
                    }
                    ConstructCheckWindowManager.shared.openWindow(for: target)                }
                
                Button("Virtual Cutter...") {
                    VirtualCutterWindowManager.shared.openWindow(sequenceManager: sequenceManager)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                
                Button("Design PCR Primers...") {
                    PCRSimulationWindowManager.shared.storeSequenceManager(sequenceManager)
                    PrimerDesignWindowManager.shared.openWindow(
                        sequenceManager: sequenceManager,
                        initialSequenceID: sequenceManager.currentSequence?.id
                    )
                }
                
                Button("Run a PCR...") {
                    PCRSimulationWindowManager.shared.openWindow(sequenceManager: sequenceManager)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Predictive Cloning…") {
                    PredictiveCloningWindowManager.shared.openWindow(sequenceManager: sequenceManager)
                }
                
                Divider()
                
                Button("Align Two DNA Sequences...") {
                    AlignTwoSequencesWindowManager.shared.openWindow(sequenceManager: sequenceManager)
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                
                Button("Align Two Protein Sequences...") {
                    AlignTwoProteinSequencesWindowManager.shared.openWindow(sequenceManager: sequenceManager)
                }
                
                Divider()
                
                Button("NCBI BLAST Search DNA...") {
                    if let seq = activeSequence {
                        sequenceManager.currentSequence = seq
                    }
                    sequenceManager.openNCBIBlastDNA()
                }
                
                Button("NCBI BLAST Search Protein...") {
                    sequenceManager.openNCBIBlastProtein()
                }
                
                Divider()
                
                Button("Hydropathy Plot...") {
                    if let prot = sequenceManager.currentProtein {
                        HydropathyPlotWindowManager.shared.openWindow(protein: prot)
                    }
                }
            }
            
            // ── Help Menu ──
            CommandGroup(replacing: .help) {
                Button("Cloner 64 Help") {
                    if let pdfURL = Bundle.main.url(forResource: "Cloner_64_Handbook", withExtension: "pdf") {
                        NSWorkspace.shared.open(pdfURL)
                    } else {
                        let alert = NSAlert()
                        alert.messageText = "Handbook Not Found"
                        alert.informativeText = "The Cloner 64 Handbook (Cloner_64_Handbook.pdf) could not be found in the app bundle. Please reinstall the app, or contact the developer if this keeps happening."
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                    }
                }
                Divider()
                Button(helpManager.isEnabled ? "Turn Off Context Help" : "Turn On Context Help") {
                    helpManager.isEnabled.toggle()
                }
                .keyboardShortcut("?", modifiers: [.command, .shift])
                Divider()
                Button("Welcome to Cloner 64") {
                    WelcomeWindowManager.shared.openWindow(sequenceManager: sequenceManager)
                }
            }
        }
        
        // MARK: - Protein Windows
        WindowGroup(id: "protein", for: UUID.self) { $proteinID in
            if let id = proteinID,
               let protein = sequenceManager.proteinSequences.first(where: { $0.id == id }) {
                ProteinWindowView(protein: protein)
                    .environmentObject(sequenceManager)
            }
        }
        .defaultSize(width: 700, height: 500)
    }
    
    // MARK: - Drag-and-Drop File Handling
    
    /// Handle files dropped onto any app window
    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                    guard let data = data as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    DispatchQueue.main.async {
                        self.sequenceManager.openSequenceFromURL(url)
                    }
                }
                handled = true
            }
        }
        return handled
    }
}


// MARK: - Window Openers

/// View modifier that listens for `.openSequenceWindowRequest` notifications
/// and uses SwiftUI's `openWindow` action to open a named sequence window.
/// Attached to every long-lived SwiftUI scene so the notification always has
/// at least one receiver.
///
/// Deduplication: each notification carries a unique posting timestamp via
/// the userInfo dictionary's identity. Multiple receivers will all fire, but
/// SwiftUI's openWindow with `for: UUID.self` is idempotent for an
/// already-open window — it just brings it forward — so duplicate calls are
/// harmless. We additionally guard with a per-process "last handled" stamp
/// to avoid the named-window receiver re-opening windows on its own appear.
struct SequenceWindowOpenDispatcher: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    
    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .openSequenceWindowRequest)) { notif in
                guard let id = notif.userInfo?["id"] as? UUID else { return }
                let force = (notif.userInfo?["forceNew"] as? Bool) ?? false
                // Reset the force flag now that we've consumed it
                if force { SequenceWindowOpener.shared.forceNewWindow = false }
                openWindow(id: "sequence", value: id)
            }
    }
}


/// Routes "open this sequence in a window" requests from anywhere in the app
/// to whichever scene is currently alive and able to call SwiftUI's openWindow.
///
/// IMPORTANT: This used to be a single mutable closure that the most recently
/// appearing window's onAppear would overwrite. That created a race: if the
/// closure happened to be the default no-op (e.g. between window lifecycles)
/// when a file finished loading, the open request was silently swallowed and
/// the file never appeared on screen even though it was loaded successfully.
///
/// The fix: openSequenceWindow now ALWAYS posts a notification in addition to
/// calling the legacy closure. The DNAClonerApp root scene observes the
/// notification and calls SwiftUI's openWindow directly — this path is always
/// available regardless of which sequence windows happen to be alive.
class SequenceWindowOpener: ObservableObject {
    static let shared = SequenceWindowOpener()
    
    /// Closure installed by SequenceWindowRootView / SequenceWindowView in
    /// their onAppear. Handles the "adopt sequence into empty placeholder
    /// window" fast-path AND the "open new named window" path.
    /// Set together with `hasHandler = true`. Use openSequenceWindow(_:) below
    /// rather than calling this directly — it has the safe fallback.
    var installedHandler: (UUID) -> Void = { _ in } {
        didSet {
            // When a handler is freshly installed, drain any pending opens
            // that were queued before the first window appeared.
            if hasHandler && !pendingOpens.isEmpty {
                let queued = pendingOpens
                pendingOpens.removeAll()
                for id in queued { installedHandler(id) }
            }
        }
    }
    
    /// True when a window's onAppear has installed a real handler closure.
    /// Once true, openSequenceWindow takes the fast path. The handler is
    /// updated (not cleared) when subsequent windows appear, so this stays
    /// true for the rest of the app's lifetime in normal operation.
    var hasHandler: Bool = false
    
    /// When true, always opens a new window (used by New Sequence)
    var forceNewWindow: Bool = false
    
    /// Set to true after SequenceWindowRootView's installed handler adopts
    /// a sequence into its empty placeholder window. After that, the root
    /// window is no longer "fresh" and subsequent opens should create new
    /// named windows rather than replacing the root window's contents.
    /// Reset only on new app launch (i.e. never, in normal use).
    var hasAdoptedFirstFile: Bool = false
    
    /// Set by SequenceWindowRootView's installed handler when it adopts a
    /// sequence into its existing empty placeholder window (rather than
    /// opening a brand new named window). When openSequenceWindow sees that
    /// this matches the requested ID, it suppresses the notification fallback
    /// to avoid creating a duplicate window for the same sequence.
    var lastAdoptedID: UUID?
    
    /// Persistent record of every UUID that has been adopted in-place into a
    /// window. Unlike lastAdoptedID (which is reset on each call), this set
    /// survives subsequent calls. This prevents a second open of the same file
    /// from firing the backstop and creating a duplicate named window — which
    /// was causing a hang when the user then closed one of the copies.
    /// Note: UUIDs are generated fresh each time a file is loaded, so a
    /// genuinely re-opened file (after closing) will have a new UUID and won't
    /// be blocked by this set.
    private var adoptedInPlaceIDs: Set<UUID> = []
    
    /// Opens queued before any window's onAppear had a chance to install
    /// the handler. Drained when installedHandler is set. Catches the case
    /// where the user double-clicks a file at app launch and the loader
    /// fires before the SwiftUI scene has finished constructing.
    private var pendingOpens: [UUID] = []
    
    /// Request that a sequence window be opened/brought-forward.
    /// This is the safe call site — guaranteed not to drop the request even
    /// if no window has wired up the legacy closure yet, AND guaranteed not
    /// to silently fail when SwiftUI's openWindow no-ops on stale scene
    /// state. We belt-and-braces this:
    ///
    /// 1. Call the installed handler (fast-path, in-place adoption when possible)
    /// 2. After a brief delay, post the notification as a backstop
    /// 3. If the handler set lastAdoptedID == id, the backstop is a no-op
    ///    (the sequence is already showing in the placeholder window)
    /// Called when a sequence window closes. Removes the ID from the
    /// adopted-in-place set so the same file can be opened again later.
    /// Without this, once a sequence was adopted in-place its ID stayed in
    /// the set forever, and every later open of the same file was silently
    /// skipped ("already adopted in-place previously") — the file loaded but
    /// no window appeared.
    func clearAdoptedID(_ id: UUID) {
        adoptedInPlaceIDs.remove(id)
        if lastAdoptedID == id { lastAdoptedID = nil }
        #if DEBUG
        print("🪟 cleared adopted ID \(id) on window close")
        #endif
    }

    func openSequenceWindow(_ id: UUID) {
        #if DEBUG
        print("🪟 openSequenceWindow(\(id)) hasHandler=\(hasHandler) forceNewWindow=\(forceNewWindow)")
        #endif
        
        // If this ID was previously adopted in-place, it's already showing in a
        // window. Skip the whole open — don't even call the handler — to prevent
        // a duplicate named window being created for the same sequence.
        if adoptedInPlaceIDs.contains(id) && !forceNewWindow {
            #if DEBUG
            print("🪟 skipped — already adopted in-place previously")
            #endif
            return
        }
        
        // Reset the adoption marker before calling the handler so we can
        // tell whether the handler set it during this call.
        lastAdoptedID = nil
        
        if hasHandler {
            installedHandler(id)
        } else {
            // No handler at all — queue for replay when one appears.
            pendingOpens.append(id)
        }
        
        // Record in the persistent set if this call resulted in an in-place adoption.
        if lastAdoptedID == id {
            adoptedInPlaceIDs.insert(id)
        }
        
        // Post the notification as a backstop. SequenceWindowOpenDispatcher
        // observes it and calls SwiftUI's openWindow directly. This catches
        // the case where the installed handler called openWindow but SwiftUI
        // silently no-op'd it (a known issue when WindowGroup scene state
        // gets stale, e.g. after closing & reopening windows of the same id).
        // We dispatch with a tiny delay so the handler's in-place adoption
        // (if any) completes first and sets lastAdoptedID.
        let force = forceNewWindow
        forceNewWindow = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self = self else { return }
            // If the handler adopted this id into a placeholder window,
            // skip the backstop — there's nothing to open.
            if self.lastAdoptedID == id || self.adoptedInPlaceIDs.contains(id) {
                #if DEBUG
                print("🪟 backstop skipped — adopted in-place")
                #endif
                return
            }
            #if DEBUG
            print("🪟 firing notification backstop for \(id)")
            #endif
            NotificationCenter.default.post(
                name: .openSequenceWindowRequest,
                object: nil,
                userInfo: ["id": id, "forceNew": force]
            )
        }
    }
}

class ProteinWindowOpener: ObservableObject {
    static let shared = ProteinWindowOpener()
    var openProteinWindow: (UUID) -> Void = { _ in }
}


// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var sequenceManager: SequenceManager?
    var hasFinishedInitialSetup = false
    private var menuObserver: Any?
    private var menuTrackingObserver: Any?
    private var keyMonitor: Any?
    private var recentMenuCancellable: AnyCancellable?
    /// Strong ref so ARC keeps self as the File menu delegate
    private var retainedSelf: AppDelegate?
    /// True while any menu is open. Guards refreshNativeRecentFilesMenu()
    /// against mutating the menu item array mid-render (causes AppKit
    /// out-of-bounds crash: cached row count vs actual item count mismatch).
    private var isTrackingAnyMenu: Bool = false
    
    private let unwantedTitles: Set<String> = [
        "Writing Tools", "AutoFill",
        "Start Dictation…", "Start Dictation...",
        "Emoji & Symbols", "Transformations"
    ]
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        // Tell macOS to ignore saved window state from previous launches.
        // Without this, SwiftUI's WindowGroup cache can think a sequence
        // window is "still open" even after it was closed, causing
        // openWindow(id:value:) to silently no-op when the user reopens
        // the same file. The "restoreWindowWithIdentifier... className=(null)"
        // warning in the console comes from this same restoration system.
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
        UserDefaults.standard.set(false, forKey: "NSWindowRestoresWorkspaceAtLaunch")
        
        removeViewMenu()
        
        // Catch unwanted items as macOS adds them, and kill the View menu if re-added
        menuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didAddItemNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let menu = notification.object as? NSMenu else { return }
            if menu == NSApp.mainMenu {
                DispatchQueue.main.async { self.removeViewMenu() }
            }
            if menu.items.contains(where: { self.unwantedTitles.contains($0.title) }) {
                DispatchQueue.main.async { self.cleanMenu(menu) }
            }
        }
        
        menuTrackingObserver = nil

        // Sweep once after SwiftUI finishes building menus, then install self
        // as the File menu's NSMenuDelegate so menuWillOpen(_:) can re-attach
        // the native Open Recent submenu *before* the menu renders — this is
        // the safe moment (unlike the old menuTrackingObserver which fired
        // during rendering and caused out-of-bounds crashes).
        for delay in [0.5, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.cleanAllMenus()
                self.removeViewMenu()
                self.refreshNativeRecentFilesMenu()
                self.installFileMenuDelegate()
                ContextMenuHelpBridge.shared.install()
            }
        }

        // Also keep Open Recent fresh whenever the file list changes
        // (e.g. after opening or drag-dropping a file).
        //
        // CRITICAL: the refresh must NOT mutate the menu synchronously inside
        // this sink. When a file opens, the new window takes focus and SwiftUI
        // rebuilds the main menu via setItemArray: at the same moment. If we
        // swap the Open Recent submenu mid-rebuild, AppKit's cached menu row
        // heights reference the old item count and crash with an out-of-bounds
        // (NSRangeException in preferredViewHeightForMenuItemAtIndex:).
        // Hop to the next runloop tick so the refresh runs AFTER SwiftUI's
        // menu rebuild has settled, and skip it while a menu is being tracked.
        recentMenuCancellable = RecentFilesManager.shared.$recentFiles
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    // Don't touch the menu while the user is interacting with it
                    // or while AppKit is mid menu-tracking.
                    if self.isTrackingAnyMenu { return }
                    self.refreshNativeRecentFilesMenu()
                }
            }
        
        // Escape key exits full screen
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53,
               let window = NSApp.keyWindow,
               window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
                return nil
            }
            return event
        }
    }
    
    // MARK: - Menu Delegates

    /// Installs self as the NSMenuDelegate on every top-level menu in the
    /// menu bar so menuWillOpen / menuDidClose fire for any menu interaction,
    /// not just the File menu. This lets isTrackingAnyMenu reliably gate
    /// refreshNativeRecentFilesMenu() against mid-render mutations.
    private func installFileMenuDelegate() {
        guard let mainMenu = NSApp.mainMenu else { return }
        for item in mainMenu.items {
            item.submenu?.delegate = self
        }
        retainedSelf = self   // keep ARC from dropping the weak delegate ref
    }

    /// NSMenuDelegate — called just before any top-level menu appears.
    func menuWillOpen(_ menu: NSMenu) {
        // Refresh Open Recent *before* setting the tracking flag, so the
        // guard inside refreshNativeRecentFilesMenu() doesn't block this
        // intentional, pre-render update.
        if menu === NSApp.mainMenu?.items.first(where: { $0.title == "File" })?.submenu {
            refreshNativeRecentFilesMenu()
        }
        isTrackingAnyMenu = true
    }

    /// NSMenuDelegate — called after any top-level menu closes.
    func menuDidClose(_ menu: NSMenu) {
        isTrackingAnyMenu = false
    }

    // MARK: - Native Open Recent Menu

    /// Replaces the SwiftUI-managed "Open Recent" submenu with a native NSMenu.
    /// Called on every menu-open event and whenever recentFiles changes, so the
    /// user always sees the correct list regardless of SwiftUI command rebuilds.
    private func refreshNativeRecentFilesMenu() {
        // Never mutate the menu item array while a menu is being tracked —
        // AppKit caches row heights at layout time and crashes if the count
        // changes between layout and display.
        guard !isTrackingAnyMenu else { return }
        guard let mainMenu = NSApp.mainMenu,
              let fileMenu = mainMenu.items.first(where: { $0.title == "File" })?.submenu,
              let recentItem = fileMenu.items.first(where: { $0.title == "Open Recent" })
        else { return }

        // Reuse the existing submenu and rebuild its contents in place rather
        // than assigning a brand-new NSMenu object. Swapping the whole submenu
        // object while AppKit holds a cached row-height table for the old menu
        // is what triggers the out-of-bounds crash during focus transitions.
        let sub: NSMenu
        if let existing = recentItem.submenu {
            sub = existing
            sub.removeAllItems()
        } else {
            sub = NSMenu(title: "Open Recent")
            recentItem.submenu = sub
        }

        let files = RecentFilesManager.shared.recentFiles

        for url in files {
            let item = NSMenuItem(title: url.lastPathComponent,
                                  action: #selector(openRecentNativeItem(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = url
            sub.addItem(item)
        }

        if files.isEmpty {
            let empty = NSMenuItem(title: "No Recent Files", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            sub.addItem(empty)
        } else {
            sub.addItem(.separator())
            let clear = NSMenuItem(title: "Clear Menu",
                                   action: #selector(clearNativeRecentFiles),
                                   keyEquivalent: "")
            clear.target = self
            sub.addItem(clear)
        }
    }
    
    @objc private func openRecentNativeItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        sequenceManager?.openSequenceFromURL(url)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc private func clearNativeRecentFiles() {
        RecentFilesManager.shared.clearRecent()
        refreshNativeRecentFilesMenu()
    }
    
    private func removeViewMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let standardViewItems = Set(["Enter Full Screen", "Show Toolbar", "Customize Toolbar..."])
        for item in mainMenu.items {
            if item.title.lowercased() == "view" {
                mainMenu.removeItem(item)
            } else if let sub = item.submenu,
                      sub.items.contains(where: { standardViewItems.contains($0.title) }) {
                mainMenu.removeItem(item)
            }
        }
    }
    
    private func cleanAllMenus() {
        guard let mainMenu = NSApp.mainMenu else { return }
        for item in mainMenu.items {
            if let sub = item.submenu { cleanMenu(sub) }
        }
    }
    
    private func cleanMenu(_ menu: NSMenu) {
        // Remove unwanted items
        for item in Array(menu.items) where unwantedTitles.contains(item.title) {
            menu.removeItem(item)
        }
        // Remove double/leading/trailing separators
        var prev: NSMenuItem?
        for item in Array(menu.items) {
            if item.isSeparatorItem && (prev?.isSeparatorItem == true) {
                menu.removeItem(item)
            } else {
                prev = item
            }
        }
        if menu.items.last?.isSeparatorItem == true { menu.removeItem(menu.items.last!) }
        if menu.items.first?.isSeparatorItem == true { menu.removeItem(menu.items.first!) }
    }
    
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let sm = sequenceManager else { return .terminateNow }
        
        let dirtyDNA = sm.sequences.filter { $0.isDirty }
        let dirtyProtein = sm.proteinSequences.filter { $0.isDirty }
        let totalDirty = dirtyDNA.count + dirtyProtein.count
        
        guard totalDirty > 0 else { return .terminateNow }
        
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "You have unsaved changes"
        
        if totalDirty == 1 {
            let name = dirtyDNA.first?.name ?? dirtyProtein.first?.name ?? "Untitled"
            alert.informativeText = "\"\(name)\" has unsaved changes. Quit anyway?"
        } else {
            alert.informativeText = "\(totalDirty) sequences have unsaved changes. Quit anyway?"
        }
        
        alert.addButton(withTitle: "Quit Without Saving")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag {
            NSApp.windows.first { $0.isVisible }?.makeKeyAndOrderFront(nil)
            return false
        }
        // All windows were closed. Reset opener state so the new root window
        // macOS is about to create can absorb the first file opened, instead
        // of appearing blank alongside a separate named sequence window.
        SequenceWindowOpener.shared.hasAdoptedFirstFile = false
        SequenceWindowOpener.shared.hasHandler = false
        return true
    }
    
    func application(_ application: NSApplication, open urls: [URL]) {
        for (index, url) in urls.enumerated() {
            let delay = Double(index) * 1.2
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.sequenceManager?.openSequenceFromURL(url)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}


// MARK: - Recent Files Manager

class RecentFilesManager: ObservableObject {
    static let shared = RecentFilesManager()
    
    private let maxRecent = 10
    private let key = "recentSequenceFiles"
    
    @Published var recentFiles: [URL] = []
    
    private init() { loadRecent() }
    
    func addRecent(_ url: URL) {
        let canonical = url.standardizedFileURL
        recentFiles.removeAll { $0.standardizedFileURL == canonical }
        recentFiles.insert(canonical, at: 0)
        if recentFiles.count > maxRecent {
            recentFiles = Array(recentFiles.prefix(maxRecent))
        }
        saveRecent()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }
    
    func clearRecent() {
        recentFiles.removeAll()
        saveRecent()
    }
    
    private func saveRecent() {
        let bookmarks = recentFiles.compactMap { url -> Data? in
            try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        if !bookmarks.isEmpty {
            UserDefaults.standard.set(bookmarks, forKey: key)
            UserDefaults.standard.removeObject(forKey: key + "_paths")
        } else {
            UserDefaults.standard.set(recentFiles.map { $0.path }, forKey: key + "_paths")
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
    
    private func loadRecent() {
        var needsResave = false
        if let bookmarks = UserDefaults.standard.array(forKey: key) as? [Data] {
            recentFiles = bookmarks.compactMap { bookmark -> URL? in
                var isStale = false
                guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                                         relativeTo: nil, bookmarkDataIsStale: &isStale),
                      url.startAccessingSecurityScopedResource(),
                      FileManager.default.fileExists(atPath: url.path)
                else { return nil }
                if isStale { needsResave = true }
                return url
            }
            if needsResave && !recentFiles.isEmpty { saveRecent() }
            if !recentFiles.isEmpty { return }
            var seen = Set<String>()
            recentFiles = recentFiles.filter { seen.insert($0.standardizedFileURL.path).inserted }
        }
        
        if let paths = UserDefaults.standard.array(forKey: key + "_paths") as? [String] {
            recentFiles = paths.compactMap { path in
                FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
            }
        }
    }
}

//
//  ConstructBuilderView.swift
//  Cloner 64
//
//  Molecular cloning workbench.  Left panel shows the graphical map of the
//  active fragment (vector or insert).  Click two restriction enzyme sites
//  on the map (green = left cut, red = right cut) to define each fragment.
//  Right panel shows the fragment configurations, overhang display, end
//  processing options, and the Ligate button.
//
//  Press Tab to flip the insert orientation.  ⌘Return to ligate.
//

import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers


// MARK: - Window Manager

class ConstructBuilderWindowManager {
    static let shared = ConstructBuilderWindowManager()
    private var window: NSWindow?
    
    func openWindow(sequenceManager: SequenceManager) {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        
        let view = ConstructBuilderView(sequenceManager: sequenceManager)
        let hostingView = NSHostingView(rootView: view)
        
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 750),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Build a Construct"
        win.contentView = hostingView
        win.setFrameAutosaveName("BuildaConstruct")
        if !win.setFrameUsingName(win.frameAutosaveName) { win.center() }
        win.makeKeyAndOrderFront(nil)
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 1000, height: 650)
        
        self.window = win
    }
}


// MARK: - End Processing

enum EndProcessing: String, CaseIterable {
    case nonProcessed = "Non-processed"
    case fillIn       = "Blunt (Fill-In)"
    case remove       = "Blunt (Remove)"
}


// MARK: - Overhang End Info

/// Describes what to display on each strand at one end of a fragment.
struct StickyEndDisplay {
    let topStrand: String     // bases shown on the 5′→3′ line (empty = recessed)
    let botStrand: String     // bases shown on the 3′→5′ line (empty = recessed)
}


// MARK: - Ligation State (survives sequenceManager @ObservedObject republishes)

/// Holds all state that must persist across SequenceManager @Published updates.
/// As a @StateObject this is never recreated by SwiftUI re-renders.
class ConstructBuilderState: ObservableObject {
    @Published var activeFragment: Int = 1
    @Published var vectorSequenceID: UUID?
    @Published var insertSequenceID: UUID?
    @Published var vectorLeftSite: CutSiteRef?
    @Published var vectorRightSite: CutSiteRef?
    @Published var insertLeftSite: CutSiteRef?
    @Published var insertRightSite: CutSiteRef?
    @Published var vectorLeft5Processing: EndProcessing = .nonProcessed
    @Published var vectorRight3Processing: EndProcessing = .nonProcessed
    @Published var insertLeft5Processing: EndProcessing = .nonProcessed
    @Published var insertRight3Processing: EndProcessing = .nonProcessed
    @Published var insertUndigested: Bool = false
    @Published var insertFlipped: Bool = false
    @Published var vectorUseWrap: Bool = false
    @Published var insertUseWrap: Bool = false
    @Published var ligationResult: String = ""
    @Published var ligationError: String = ""
    @Published var originalVectorID: UUID?
    @Published var constructSequenceID: UUID?
    @Published var constructInsertName: String = ""
    @Published var constructInsertStart: Int = 0
    @Published var constructInsertLength: Int = 0
    @Published var constructIsDirectional: Bool = false
}

// MARK: - Main View

struct ConstructBuilderView: View {
    @ObservedObject var sequenceManager: SequenceManager
    
    // All ligation state lives in a @StateObject so it survives
    // SequenceManager @Published updates (which would reset @State)
    @StateObject private var st = ConstructBuilderState()
    
    // ── Map filter toggles (safe as @State — UI-only, not ligation state) ──
    @State private var showUniqueSites: Bool = true
    @State private var showDoubleSites: Bool = false
    @State private var showParticularSites: Bool = false
    @State private var showBluntSites: Bool = false
    @State private var showFeatures: Bool = true
    @State private var showORFs: Bool = false
    @State private var selectedParticularEnzymes: Set<String> = []
    @State private var useMyEnzymesOnly: Bool = false
    @State private var mapScale: CGFloat = 1.0
    @State private var labelFontSize: CGFloat = 11
    @State private var resetLabelTrigger: Bool = false
    @State private var showEnzymePicker: Bool = false

    // Methylation sensitivity (shared with the rest of the app via AppStorage)
    @AppStorage("methylation_dam") private var methylationDam: Bool = true
    @AppStorage("methylation_dcm") private var methylationDcm: Bool = true
    @AppStorage("methylation_cpg") private var methylationCpG: Bool = false
    
    // ── Tab key monitor ──
    @State private var tabMonitor: Any?

    // ── Cached enzyme name list for the picker popover ──
    // Rebuilt on a background thread when the active sequence or filter changes,
    // so opening the picker is instant rather than blocking on a full database scan.
    @State private var cachedEnzymeNames: [String] = []

    private func refreshEnzymeNames() {
        guard let seq = activeSequence else { cachedEnzymeNames = []; return }
        let seqStr       = seq.sequence.uppercased()
        let circular     = seq.isCircular
        let useMyEnzymes = useMyEnzymesOnly
        DispatchQueue.global(qos: .userInitiated).async {
            let database = RestrictionEnzymeDatabase.shared
            let enzList  = useMyEnzymes ? database.myEnzymes : database.enzymes
            let names    = enzList
                .filter { !$0.findCutSites(in: seqStr, circular: circular).isEmpty }
                .map(\.name)
                .sorted()
            DispatchQueue.main.async { self.cachedEnzymeNames = names }
        }
    }
    
    // Resolved sequences
    private var vectorSequence: DNASequence? {
        guard let id = st.vectorSequenceID else { return nil }
        return sequenceManager.sequences.first(where: { $0.id == id })
    }
    
    private var insertSequence: DNASequence? {
        guard let id = st.insertSequenceID else { return nil }
        return sequenceManager.sequences.first(where: { $0.id == id })
    }
    
    private var constructSequence: DNASequence? {
        guard let id = st.constructSequenceID else { return nil }
        return sequenceManager.sequences.first(where: { $0.id == id })
    }
    
    private var activeSequence: DNASequence? {
        switch st.activeFragment {
        case 1: return vectorSequence
        case 2: return insertSequence
        case 3: return constructSequence
        default: return nil
        }
    }
    
    var canLigate: Bool {
        guard vectorSequence != nil && insertSequence != nil else { return false }
        guard st.vectorLeftSite != nil && st.vectorRightSite != nil else { return false }
        if st.insertUndigested { return true }
        return st.insertLeftSite != nil && st.insertRightSite != nil
    }
    
    // MARK: - Body
    
    var body: some View {
        HSplitView {
            // ── Left panel: graphical map of active fragment ──
            mapPanel
                .frame(minWidth: 450, idealWidth: 600)
            
            // ── Right panel: fragment configuration ──
            ScrollView {
                VStack(spacing: 8) {
                    // ── Tab buttons ──
                    HStack(spacing: 6) {
                        tabButton("Vector", fragment: 1)
                            .contextHelp("build.vectorTab")
                        tabButton("Insert", fragment: 2)
                            .contextHelp("build.insertTab")
                        
                        if st.constructSequenceID != nil {
                            tabButton("Construct", fragment: 3)
                                .contextHelp("build.constructTab")
                        }
                        
                        Spacer()
                        
                        if st.constructSequenceID != nil {
                            Button("New Ligation") {
                                st.ligationResult = ""
                                st.ligationError = ""
                                st.constructSequenceID = nil
                                st.constructInsertName = ""
                                if let originalID = st.originalVectorID {
                                    st.vectorSequenceID = originalID
                                }
                                st.vectorLeftSite = nil
                                st.vectorRightSite = nil
                                st.vectorLeft5Processing = .nonProcessed
                                st.vectorRight3Processing = .nonProcessed
                                st.vectorUseWrap = false
                                st.insertLeftSite = nil
                                st.insertRightSite = nil
                                st.insertLeft5Processing = .nonProcessed
                                st.insertRight3Processing = .nonProcessed
                                st.insertUseWrap = false
                                st.insertFlipped = false
                                st.insertUndigested = false
                                st.activeFragment = 1
                                // Force GraphicalMapView to fully re-render
                                // (without this, SwiftUI may reuse the existing
                                // map view since the sequence ID hasn't changed)
                                resetLabelTrigger.toggle()
                            }
                            .buttonStyle(.bordered)
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                            .contextHelp("build.newLigation")
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    
                    if st.activeFragment == 3, let seq = constructSequence {
                        // ── Construct view (on its own) ──
                        constructPanel(seq)
                    } else {
                        // ── Vector + Insert panels (both visible, click to activate) ──
                        fragmentPanel(
                            title: "Vector",
                            fragmentIndex: 1,
                            sequence: vectorSequence,
                            sequenceID: $st.vectorSequenceID,
                            leftSite: st.vectorLeftSite,
                            rightSite: st.vectorRightSite,
                            left5Processing: $st.vectorLeft5Processing,
                            right3Processing: $st.vectorRight3Processing,
                            flipped: .constant(false),
                            showFlip: false,
                            useWrap: st.vectorUseWrap
                        )
                        
                        fragmentPanel(
                            title: "Insert",
                            fragmentIndex: 2,
                            sequence: insertSequence,
                            sequenceID: $st.insertSequenceID,
                            leftSite: st.insertLeftSite,
                            rightSite: st.insertRightSite,
                            left5Processing: $st.insertLeft5Processing,
                            right3Processing: $st.insertRight3Processing,
                            flipped: $st.insertFlipped,
                            showFlip: true,
                            useWrap: st.insertUseWrap
                        )
                        
                        // ── Ligate button ──
                        VStack(spacing: 6) {
                            if !st.ligationError.isEmpty {
                                Text(st.ligationError)
                                    .foregroundColor(.orange)
                                    .font(.system(size: 11))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if !st.ligationResult.isEmpty {
                                Text(st.ligationResult)
                                    .foregroundColor(.green)
                                    .font(.system(size: 12, weight: .medium))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            
                            Button(action: performLigation) {
                                Text("LIGATE")
                                    .font(.system(size: 14, weight: .bold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            .disabled(!canLigate)
                            .keyboardShortcut(.return, modifiers: [.command])
                            .contextHelp("build.ligate")
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(minWidth: 380, idealWidth: 420)
        }
        .frame(minWidth: 1000, minHeight: 650)
        .onAppear {
            if st.vectorSequenceID == nil, let cur = sequenceManager.currentSequence {
                st.vectorSequenceID = cur.id
            }
            refreshEnzymeNames()
            // Install Tab-key monitor for flipping insert orientation
            tabMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 48 {  // 48 = Tab
                    st.insertFlipped.toggle()
                    return nil   // consume the event
                }
                return event
            }
        }
        .onDisappear {
            if let monitor = tabMonitor {
                NSEvent.removeMonitor(monitor)
                tabMonitor = nil
            }
        }
        .onChange(of: st.activeFragment)      { _ in refreshEnzymeNames() }
        .onChange(of: st.vectorSequenceID)    { _ in refreshEnzymeNames() }
        .onChange(of: st.insertSequenceID)    { _ in refreshEnzymeNames() }
        .onChange(of: useMyEnzymesOnly)    { _ in refreshEnzymeNames() }
        // Observe site selection notifications from the embedded map
        .onReceive(NotificationCenter.default.publisher(for: .constructSiteSelectionChanged)) { notification in
            guard let info = notification.userInfo,
                  let fragIndex = info["fragmentIndex"] as? Int else { return }
            
            // Respect click order from the map: first click = green = left,
            // second click = red = right.  Do NOT reorder by position — the
            // user's click order determines which enzymes meet at each junction.
            let first = info["first"] as? CutSiteRef      // green / left
            var second = info["second"] as? CutSiteRef     // red / right
            
            // ── Auto-fill: single enzyme on circular sequence ──
            // Cutting a circular molecule with one unique-cutter linearises it;
            // both the 5′ and 3′ ends carry that enzyme's cut.  Auto-assign the
            // same site as both left AND right so the user only needs one click.
            if first != nil && second == nil {
                let seq = fragIndex == 1 ? vectorSequence : insertSequence
                if let seq = seq, seq.isCircular, let site = first {
                    let db = RestrictionEnzymeDatabase.shared
                    if let enz = db.enzymes.first(where: { $0.name == site.enzyme }) {
                        let sites = enz.findCutSites(in: seq.sequence.uppercased(), circular: true)
                        let distinctCount = Set(sites.map(\.position)).count
                        if distinctCount == 1 {
                            second = first   // same site for both ends
                        }
                    }
                }
            }
            
            if fragIndex == 1 {
                st.vectorLeftSite = first
                st.vectorRightSite = second
                st.vectorUseWrap = (info["useWrap"] as? Bool) ?? false
            } else if fragIndex == 2 {
                st.insertLeftSite = first
                st.insertRightSite = second
                st.insertUseWrap = (info["useWrap"] as? Bool) ?? false
            }
        }
    }
    
    
    // MARK: - Map Panel (Left Side)
    
    private var mapPanel: some View {
        VStack(spacing: 0) {
            // ── Filter controls ──
            HStack(spacing: 10) {
                Toggle("Features", isOn: $showFeatures)
                    .toggleStyle(.checkbox)
                    .contextHelp("build.showFeatures")
                Toggle("Unique Sites", isOn: $showUniqueSites)
                    .toggleStyle(.checkbox)
                    .contextHelp("build.uniqueSites")
                Toggle("Double Sites", isOn: $showDoubleSites)
                    .toggleStyle(.checkbox)
                    .contextHelp("build.doubleSites")
                Toggle("Blunt Sites", isOn: $showBluntSites)
                    .toggleStyle(.checkbox)
                    .contextHelp("build.bluntSites")
                Toggle("Particular sites", isOn: $showParticularSites)
                    .toggleStyle(.checkbox)
                    .contextHelp("build.particularSites")
                
                Toggle(isOn: $useMyEnzymesOnly) {
                    Label("My Enzymes", systemImage: "star.fill")
                }
                .toggleStyle(.checkbox)
                .disabled(RestrictionEnzymeDatabase.shared.myEnzymeNames.isEmpty)
                .contextHelp("build.myEnzymesOnly")
                
                if showParticularSites {
                    Button("Choose site…") {
                        showEnzymePicker = true
                    }
                    .controlSize(.small)
                    .popover(isPresented: $showEnzymePicker) {
                        enzymePickerPopover
                    }
                }
                
                Spacer()
            }
            .font(.system(size: 11))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // ── The graphical map ──
            if let seq = activeSequence {
                GraphicalMapView(
                    sequence: seq,
                    showUniqueSites: showUniqueSites,
                    showDoubleSites: showDoubleSites,
                    showParticularSites: showParticularSites,
                    showBluntSites: showBluntSites,
                    showFeatures: showFeatures,
                    showORFs: showORFs,
                    selectedParticularEnzymes: selectedParticularEnzymes,
                    hiddenFeatureIDs: [],
                    mapScale: $mapScale,
                    labelFontSize: labelFontSize,
                    resetLabelTrigger: $resetLabelTrigger,
                    constructFragmentIndex: st.activeFragment == 3 ? 0 : st.activeFragment,
                    hideFragmentBar: st.activeFragment == 3,
                    useMyEnzymesOnly: useMyEnzymesOnly,
                    isReady: .constant(true)
                )
                // Combine seq.id with resetLabelTrigger so that toggling the
                // trigger forces SwiftUI to destroy and recreate the map view,
                // clearing any stale internal state (e.g. after New Ligation)
                .id("\(seq.id)-\(resetLabelTrigger)")
            } else {
                VStack {
                    Spacer()
                    Text(st.activeFragment == 3
                         ? "No construct yet — ligate first"
                         : "Select a DNA sequence for \(st.activeFragment == 1 ? "vector" : "insert")")
                        .foregroundColor(.secondary)
                        .font(.system(size: 14))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.textBackgroundColor))
            }
        }
    }
    
    // ── Enzyme picker popover ──
    private var enzymePickerPopover: some View {
        VStack(spacing: 10) {
            Text("Select enzymes to display")
                .font(.headline)
            
            let names = cachedEnzymeNames
            
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(names, id: \.self) { name in
                        Toggle(name, isOn: Binding(
                            get: { selectedParticularEnzymes.contains(name) },
                            set: { on in
                                if on { selectedParticularEnzymes.insert(name) }
                                else { selectedParticularEnzymes.remove(name) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                    }
                }
                .padding(.horizontal)
            }
            .frame(height: 300)
            
            HStack {
                Button("Select All") { selectedParticularEnzymes = Set(names) }
                Button("Clear") { selectedParticularEnzymes.removeAll() }
                Spacer()
                Button("Done") { showEnzymePicker = false }
                    .keyboardShortcut(.return)
            }
        }
        .padding()
        .frame(width: 280, height: 400)
    }
    
    private func allEnzymeNames() -> [String] {
        guard let seq = activeSequence else { return [] }
        let database = RestrictionEnzymeDatabase.shared
        let enzList = useMyEnzymesOnly ? database.myEnzymes : database.enzymes
        return enzList
            .filter { !$0.findCutSites(in: seq.sequence.uppercased(), circular: seq.isCircular).isEmpty }
            .map(\.name)
            .sorted()
    }
    
    
    // MARK: - Fragment Panel (Right Side)
    
    private func fragmentPanel(
        title: String,
        fragmentIndex: Int,
        sequence: DNASequence?,
        sequenceID: Binding<UUID?>,
        leftSite: CutSiteRef?,
        rightSite: CutSiteRef?,
        left5Processing: Binding<EndProcessing>,
        right3Processing: Binding<EndProcessing>,
        flipped: Binding<Bool>,
        showFlip: Bool,
        useWrap: Bool
    ) -> some View {
        let isActive = st.activeFragment == fragmentIndex
        
        return VStack(alignment: .leading, spacing: 6) {
            // ── Header row ──
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                
                Spacer()
                
                // Sequence picker — exclude the current construct so it can't
                // accidentally be chosen as the next vector or insert
                Picker("", selection: sequenceID) {
                    Text("Select DNA \(fragmentIndex)…").tag(nil as UUID?)
                    ForEach(sequenceManager.sequences.filter { $0.id != st.constructSequenceID }) { seq in
                        Text("\(seq.name) (\(seq.length) bp)")
                            .tag(seq.id as UUID?)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
                .onChange(of: sequenceID.wrappedValue) { _ in
                    if fragmentIndex == 1 {
                        st.vectorLeftSite = nil; st.vectorRightSite = nil
                        st.vectorUseWrap = false
                    } else {
                        st.insertLeftSite = nil; st.insertRightSite = nil
                        st.insertUseWrap = false
                        st.insertUndigested = false
                    }
                    st.activeFragment = fragmentIndex
                }
                .contextHelp("build.sequencePicker")
                
                Button("Browse…") {
                    browseForSequence(sequenceID: sequenceID, fragmentIndex: fragmentIndex)
                }
                .font(.system(size: 11))
            }
            
            // ── Overhang display ──
            if let seq = sequence {
                overhangDisplay(
                    sequence: seq,
                    leftSite: leftSite,
                    rightSite: rightSite,
                    left5Processing: left5Processing.wrappedValue,
                    right3Processing: right3Processing.wrappedValue,
                    isVector: fragmentIndex == 1,
                    flipped: flipped.wrappedValue,
                    useWrap: useWrap
                )
                
                // ── End processing + flip ──
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("5′ Extremity").font(.system(size: 10, weight: .medium))
                        ForEach(EndProcessing.allCases, id: \.self) { proc in
                            radioRow(proc.rawValue, isSelected: left5Processing.wrappedValue == proc) {
                                left5Processing.wrappedValue = proc
                            }
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text("From:").font(.system(size: 10, weight: .medium))
                            Text(seq.name).font(.system(size: 10)).lineLimit(1)
                        }
                        HStack(spacing: 4) {
                            if seq.isCircular {
                                Image(systemName: "arrow.2.circlepath").font(.system(size: 9))
                                Text("circular").font(.system(size: 9)).foregroundColor(.secondary)
                            } else {
                                Image(systemName: "arrow.left.and.right").font(.system(size: 9))
                                Text("linear").font(.system(size: 9)).foregroundColor(.secondary)
                            }
                        }
                        if showFlip {
                            HStack(spacing: 4) {
                                Toggle("Flip orientation", isOn: flipped)
                                    .toggleStyle(.checkbox)
                                    .font(.system(size: 10))
                                    .contextHelp("build.flipOrientation")
                                Text("(Tab)").font(.system(size: 9)).foregroundColor(.secondary)
                            }
                            Toggle("Undigested insert (blunt ends)", isOn: $st.insertUndigested)
                                .toggleStyle(.checkbox)
                                .font(.system(size: 10))
                                .help("Use the full insert sequence with blunt ends — no restriction digest needed. Only compatible with a blunt-ended vector (e.g. SmaI).")
                                .onChange(of: st.insertUndigested) { _ in
                                    if st.insertUndigested {
                                        st.insertLeftSite = nil
                                        st.insertRightSite = nil
                                    }
                                }
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("3′ Extremity").font(.system(size: 10, weight: .medium))
                        ForEach(EndProcessing.allCases, id: \.self) { proc in
                            radioRow(proc.rawValue, isSelected: right3Processing.wrappedValue == proc) {
                                right3Processing.wrappedValue = proc
                            }
                        }
                    }
                }
            } else {
                HStack {
                    Text("5′ xxxxxxxxxxxx")
                    Spacer()
                    Text("… nt")
                    Spacer()
                    Text("xxxxxxxxxxxx 3′")
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.vertical, 6)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isActive ? Color.accentColor : Color.gray.opacity(0.3),
                        lineWidth: isActive ? 2 : 1)
        )
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor.opacity(0.04) : Color.clear)
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { st.activeFragment = fragmentIndex }
    }
    
    private func radioRow(_ label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                .font(.system(size: 10))
                .foregroundColor(.accentColor)
            Text(label).font(.system(size: 10))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
    
    // MARK: - Tab Button
    
    private func tabButton(_ label: String, fragment: Int) -> some View {
        Button(label) {
            st.activeFragment = fragment
        }
        .buttonStyle(.bordered)
        .font(.system(size: 12, weight: st.activeFragment == fragment ? .semibold : .regular))
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(st.activeFragment == fragment ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .cornerRadius(5)
    }
    
    // MARK: - Construct Panel (simplified)
    
    private func constructPanel(_ seq: DNASequence) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // ── Header ──
            Text(seq.name)
                .font(.system(size: 13, weight: .semibold))
            
            // ── Summary ──
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Image(systemName: seq.isCircular ? "arrow.2.circlepath" : "arrow.left.and.right")
                        .font(.system(size: 10))
                    Text(seq.isCircular ? "Circular" : "Linear")
                        .font(.system(size: 11))
                }
                .foregroundColor(.secondary)
                
                Text("\(seq.length) bp")
                    .font(.system(size: 11, weight: .medium))
                
                if !st.constructInsertName.isEmpty {
                    Text("Insert: \(st.constructInsertName)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            
            // ── Features list ──
            if !seq.features.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Features (\(seq.features.count))")
                        .font(.system(size: 11, weight: .semibold))
                    
                    ForEach(seq.features) { feat in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color(red: feat.color.red, green: feat.color.green, blue: feat.color.blue))
                                .frame(width: 8, height: 8)
                            Text(feat.name)
                                .font(.system(size: 10))
                            Spacer()
                            Text("\(feat.start + 1)–\(feat.end)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                            Image(systemName: feat.strand == .forward ? "arrow.right" : "arrow.left")
                                .font(.system(size: 8))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.top, 4)
            }
            
            Divider()
            
            // ── Sequence display ──
            VStack(alignment: .leading, spacing: 4) {
                Text("Sequence")
                    .font(.system(size: 11, weight: .semibold))
                
                ScrollView(.vertical) {
                    Text(seq.sequence)
                        .font(.system(size: 10, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(height: 200)
                .frame(maxWidth: .infinity)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
            }
            
            Divider()
            
            // ── Open button ──
            Button(action: {
                if let id = st.constructSequenceID {
                    SequenceWindowOpener.shared.openSequenceWindow(id)
                }
            }) {
                Label("Open in New Window", systemImage: "macwindow.badge.plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            
            // ── Verify Digest button ──
            Button(action: openVerificationWindow) {
                Label("Verify Digest…", systemImage: "checkmark.shield")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .help("Suggest a restriction-digest strategy to distinguish recombinant clones from non-recombinant parental vector.")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.accentColor, lineWidth: 2)
        )
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.04))
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }
    
    /// Open the Verification Digest window for the current construct.
    private func openVerificationWindow() {
        guard let construct = constructSequence else { return }
        // Look up the parental (empty) vector by the saved ID.  Fall back to
        // the construct itself if it can't be found, so the analyser can
        // still run in flanking mode against the construct's own digest.
        let parental: DNASequence
        if let id = st.originalVectorID,
           let v = sequenceManager.sequences.first(where: { $0.id == id }) {
            parental = v
        } else {
            parental = construct
        }
        DigestVerificationWindowManager.shared.openWindow(
            construct: construct,
            parentalVector: parental,
            insertStart: st.constructInsertStart,
            insertLength: st.constructInsertLength,
            // Default: if directional cloning, orientation is forced.
            orientationMatters: !st.constructIsDirectional
        )
    }
    
    
    // =====================================================================
    // MARK: - Correct Sticky-End Overhang Display
    // =====================================================================
    //
    //  For a 5′ overhang (cut5 < cut3, e.g. EcoRI):
    //    LEFT end of fragment — top strand protrudes inward:
    //        5′  AATT————————  3′
    //        3′      ————————  5′
    //    RIGHT end of fragment — bottom strand protrudes inward:
    //        5′  ————————      3′
    //        3′  ————————TTAA  5′     (complement, not revcomp)
    //
    //  For a 3′ overhang (cut5 > cut3, e.g. PstI):
    //    LEFT end — bottom strand protrudes inward:
    //        5′      ————————  3′
    //        3′  ACGT————————  5′     (complement)
    //    RIGHT end — top strand protrudes inward:
    //        5′  ————————TGCA  3′
    //        3′  ————————      5′
    //
    //  "Overhang bases" = sequence between min(cut5,cut3) and max(cut5,cut3)
    //  "Complement" = per-base complement (A↔T, G↔C), NOT reversed
    // =====================================================================
    
    private func overhangDisplay(
        sequence: DNASequence,
        leftSite: CutSiteRef?,
        rightSite: CutSiteRef?,
        left5Processing: EndProcessing,
        right3Processing: EndProcessing,
        isVector: Bool,
        flipped: Bool,
        useWrap: Bool
    ) -> some View {
        let seqStr = sequence.sequence.uppercased()
        let seqLen = seqStr.count
        
        // ── Fragment A / B end assignment ──
        // On the map, Fragment A is defined by cut *positions*: the shorter
        // arc from the lower-position cut (A's 5′ end) to the higher-position
        // cut (A's 3′ end).  Fragment B is the complementary arc.  The click
        // order that arrived here (leftSite = 1st click = green) is unrelated
        // to position order, so we must re-order by cutPos5 on circular
        // sequences before mapping ends.  On linear sequences we keep the
        // click-order behaviour.
        let effLeftSite:  CutSiteRef?
        let effRightSite: CutSiteRef?
        if sequence.isCircular, let l = leftSite, let r = rightSite {
            let lPos = normPos(l.cutPos5, seqLen)
            let rPos = normPos(r.cutPos5, seqLen)
            let lowerSite = (lPos <= rPos) ? l : r
            let upperSite = (lPos <= rPos) ? r : l
            // Fragment A: left = lower-position site, right = upper-position site
            // Fragment B: swap (wrap-around arc through origin)
            effLeftSite  = useWrap ? upperSite : lowerSite
            effRightSite = useWrap ? lowerSite : upperSite
        } else {
            effLeftSite  = leftSite
            effRightSite = rightSite
        }
        
        let fragmentSize = computeFragmentSize(
            seqLen: seqLen, isCircular: sequence.isCircular,
            leftSite: leftSite, rightSite: rightSite,
            isVector: isVector, useWrap: useWrap
        )
        
        // Compute sticky-end displays for each end (using effective sites)
        let rawLeftEnd  = effLeftSite.map  { stickyEnd(site: $0, seqStr: seqStr, seqLen: seqLen, isLeftEnd: true)  }
                          ?? StickyEndDisplay(topStrand: "", botStrand: "")
        let rawRightEnd = effRightSite.map { stickyEnd(site: $0, seqStr: seqStr, seqLen: seqLen, isLeftEnd: false) }
                          ?? StickyEndDisplay(topStrand: "", botStrand: "")
        
        // When flipped, the insert is reverse-complemented, so left ↔ right
        // AND top ↔ bottom swap (because revcomp swaps strands)
        let leftEnd: StickyEndDisplay
        let rightEnd: StickyEndDisplay
        let leftEnzyme: String
        let rightEnzyme: String
        
        if flipped {
            // Flip: left gets right's info with strands swapped, and vice versa
            leftEnd  = StickyEndDisplay(topStrand: complementStr(rawRightEnd.botStrand),
                                        botStrand: complementStr(rawRightEnd.topStrand))
            rightEnd = StickyEndDisplay(topStrand: complementStr(rawLeftEnd.botStrand),
                                        botStrand: complementStr(rawLeftEnd.topStrand))
            leftEnzyme  = effRightSite?.enzyme ?? "—"
            rightEnzyme = effLeftSite?.enzyme ?? "—"
        } else {
            leftEnd  = rawLeftEnd
            rightEnd = rawRightEnd
            leftEnzyme  = effLeftSite?.enzyme ?? "—"
            rightEnzyme = effRightSite?.enzyme ?? "—"
        }
        
        // Apply end processing (blunt fill-in or remove → no overhang)
        let dispLeft  = applyProcessing(leftEnd, left5Processing)
        let dispRight = applyProcessing(rightEnd, right3Processing)
        
        let dashLine = "————————————————————"
        let leftTopPad  = String(repeating: " ", count: max(dispLeft.botStrand.count - dispLeft.topStrand.count, 0))
        let leftBotPad  = String(repeating: " ", count: max(dispLeft.topStrand.count - dispLeft.botStrand.count, 0))
        let rightTopPad = String(repeating: " ", count: max(dispRight.botStrand.count - dispRight.topStrand.count, 0))
        let rightBotPad = String(repeating: " ", count: max(dispRight.topStrand.count - dispRight.botStrand.count, 0))
        
        // Check methylation status for the two displayed cut sites.
        // After the flip swap above, leftCheckSite is the CutSiteRef whose
        // overhang is shown at the left end of the diagram; rightCheckSite
        // at the right end.  All three palindromic methylation types (Dam,
        // Dcm, CpG) are unaffected by strand reversal, so checking the
        // original site positions against the original sequence is correct
        // even when the insert is flipped.
        let leftCheckSite  = flipped ? effRightSite : effLeftSite
        let rightCheckSite = flipped ? effLeftSite  : effRightSite
        let leftMethyl  = methylationStatus(for: leftCheckSite,
                                             in: seqStr, isCircular: sequence.isCircular)
        let rightMethyl = methylationStatus(for: rightCheckSite,
                                             in: seqStr, isCircular: sequence.isCircular)

        return VStack(spacing: 1) {
            // Enzyme names + fragment size.
            // Colour: green/red = normal; orange + ⚠ = blocked by methylation;
            // blue = requires methylation to cut (e.g. DpnI with Dam active).
            HStack {
                HStack(spacing: 3) {
                    if leftMethyl.blocked {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8))
                            .foregroundColor(.orange)
                    }
                    Text(leftEnzyme)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(leftMethyl.blocked  ? .orange
                                       : leftMethyl.required ? .blue
                                       : Color(red: 0, green: 0.55, blue: 0))
                }
                .help(leftMethyl.blocked  ? "\(leftEnzyme) is blocked by Dam/Dcm/CpG methylation at this site and will not cut methylated DNA."
                    : leftMethyl.required ? "\(leftEnzyme) requires methylation to cut — only active on methylated templates (e.g. Dam+ E. coli)."
                    : "")
                Spacer()
                Text(fragmentSize > 0 ? "\(fragmentSize) nt" : "… nt")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                HStack(spacing: 3) {
                    Text(rightEnzyme)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(rightMethyl.blocked  ? .orange
                                       : rightMethyl.required ? .blue
                                       : Color(red: 0.75, green: 0, blue: 0))
                    if rightMethyl.blocked {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8))
                            .foregroundColor(.orange)
                    }
                }
                .help(rightMethyl.blocked  ? "\(rightEnzyme) is blocked by Dam/Dcm/CpG methylation at this site and will not cut methylated DNA."
                    : rightMethyl.required ? "\(rightEnzyme) requires methylation to cut — only active on methylated templates (e.g. Dam+ E. coli)."
                    : "")
            }
            
            // 5′→3′ strand (top line)
            HStack(spacing: 0) {
                Text("5′").font(.system(size: 10, design: .monospaced))
                Text(leftTopPad).font(.system(size: 10, design: .monospaced))
                styledOH(dispLeft.topStrand)
                Text(dashLine).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).lineLimit(1)
                styledOH(dispRight.topStrand)
                Text(rightTopPad).font(.system(size: 10, design: .monospaced))
                Text("3′").font(.system(size: 10, design: .monospaced))
            }
            
            // 3′→5′ strand (bottom line)
            HStack(spacing: 0) {
                Text("3′").font(.system(size: 10, design: .monospaced))
                Text(leftBotPad).font(.system(size: 10, design: .monospaced))
                styledOH(dispLeft.botStrand)
                Text(dashLine).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).lineLimit(1)
                styledOH(dispRight.botStrand)
                Text(rightBotPad).font(.system(size: 10, design: .monospaced))
                Text("5′").font(.system(size: 10, design: .monospaced))
            }
            // ── Methylation inline notes ──
            // Show a brief coloured line if either enzyme has a methylation issue,
            // so the user sees the reason without having to hover for the tooltip.
            let leftNote  = leftMethyl.shortNote
            let rightNote = rightMethyl.shortNote
            if !leftNote.isEmpty || !rightNote.isEmpty {
                HStack(spacing: 0) {
                    if !leftNote.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: leftMethyl.blocked ? "exclamationmark.triangle.fill" : "m.circle.fill")
                                .font(.system(size: 9))
                            Text(leftNote)
                                .font(.system(size: 9))
                        }
                        .foregroundColor(leftMethyl.blocked ? .orange : .blue)
                    }
                    Spacer()
                    if !rightNote.isEmpty {
                        HStack(spacing: 3) {
                            Text(rightNote)
                                .font(.system(size: 9))
                            Image(systemName: rightMethyl.blocked ? "exclamationmark.triangle.fill" : "m.circle.fill")
                                .font(.system(size: 9))
                        }
                        .foregroundColor(rightMethyl.blocked ? .orange : .blue)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.top, 2)
            }

            // ── Small vector fragment warning ──
            // Warn when the chosen vector fragment is suspiciously small —
            // any backbone under ~500 bp almost certainly lacks an origin of
            // replication and a selectable marker, making it useless as a
            // cloning vector.  Show only when both sites are chosen (so
            // fragmentSize > 0) and this is the vector panel.
            if isVector && fragmentSize > 0 && fragmentSize < 500 {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 11))
                    Text("This fragment (\(fragmentSize) bp) is very small and unlikely to contain an origin of replication or selectable marker. Did you mean to pick the other fragment?")
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 4)
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(Color(NSColor.textBackgroundColor).opacity(0.5))
        .cornerRadius(4)
    }
    
    /// Styled overhang text (blue, monospaced) — empty string produces nothing
    @ViewBuilder
    private func styledOH(_ text: String) -> some View {
        if !text.isEmpty {
            Text(text)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.blue)
        }
    }
    
    /// Compute sticky-end display for one end of a fragment.
    private func stickyEnd(site: CutSiteRef, seqStr: String, seqLen: Int, isLeftEnd: Bool) -> StickyEndDisplay {
        // Use RAW cut positions — overhang is always a small span
        let cut5 = site.cutPos5
        let cut3 = site.cutPos3
        
        // Blunt
        if cut5 == cut3 { return StickyEndDisplay(topStrand: "", botStrand: "") }
        
        // Extract overhang bases from the top strand (5′→3′)
        let ohStart = min(cut5, cut3)
        let ohEnd   = max(cut5, cut3)
        
        // Extract bases (handling possible origin wrapping)
        var ohBases = ""
        for i in ohStart..<ohEnd {
            var idx = i % seqLen
            if idx < 0 { idx += seqLen }
            guard idx >= 0, idx < seqLen else { continue }
            ohBases.append(seqStr[seqStr.index(seqStr.startIndex, offsetBy: idx)])
        }
        guard !ohBases.isEmpty else { return StickyEndDisplay(topStrand: "", botStrand: "") }
        
        let ohComp = complementStr(ohBases)
        let is5PrimeOverhang = (cut5 < cut3)  // top strand cut first → 5′ overhang
        
        if isLeftEnd {
            if is5PrimeOverhang {
                // 5′ OH at left end: top protrudes inward
                return StickyEndDisplay(topStrand: ohBases, botStrand: "")
            } else {
                // 3′ OH at left end: bottom protrudes inward
                return StickyEndDisplay(topStrand: "", botStrand: ohComp)
            }
        } else {
            if is5PrimeOverhang {
                // 5′ OH at right end: bottom protrudes inward
                return StickyEndDisplay(topStrand: "", botStrand: ohComp)
            } else {
                // 3′ OH at right end: top protrudes inward
                return StickyEndDisplay(topStrand: ohBases, botStrand: "")
            }
        }
    }
    
    /// Apply end processing — fill-in or remove makes the end blunt (no overhang).
    private func applyProcessing(_ end: StickyEndDisplay, _ proc: EndProcessing) -> StickyEndDisplay {
        if proc == .nonProcessed { return end }
        return StickyEndDisplay(topStrand: "", botStrand: "")
    }
    
    
    // MARK: - Overhang String (for ligation compatibility check)
    
    private func overhangString(site: CutSiteRef, seqStr: String, seqLen: Int) -> String {
        // Use RAW cut positions (not modulo-wrapped) — the overhang
        // is always a small span between cut5 and cut3
        let cut5 = site.cutPos5
        let cut3 = site.cutPos3
        if cut5 == cut3 { return "" }  // blunt
        
        let ohStart = min(cut5, cut3)
        let ohEnd   = max(cut5, cut3)
        
        // Normal case: both positions within sequence
        if ohStart >= 0 && ohEnd <= seqLen {
            let startIdx = seqStr.index(seqStr.startIndex, offsetBy: ohStart)
            let endIdx   = seqStr.index(seqStr.startIndex, offsetBy: ohEnd)
            return String(seqStr[startIdx..<endIdx])
        }
        
        // Wrapping case (site straddles origin): extract with modulo
        var result = ""
        for i in ohStart..<ohEnd {
            var idx = i % seqLen
            if idx < 0 { idx += seqLen }
            result.append(seqStr[seqStr.index(seqStr.startIndex, offsetBy: idx)])
        }
        return result
    }
    
    private func normPos(_ pos: Int, _ seqLen: Int) -> Int {
        guard seqLen > 0 else { return 0 }
        var p = pos % seqLen
        if p < 0 { p += seqLen }
        return p
    }

    /// Pick the cut boundary for one fragment end, honouring how a sticky end
    /// was blunted before ligation.
    ///
    ///  - `.nonProcessed`: returns `legacyPos` unchanged, so ordinary cohesive-
    ///    end cloning behaves exactly as before (no regression).
    ///  - `.fillIn`: the single-stranded overhang is filled to double-stranded
    ///    and therefore STAYS in this fragment → use the OUTER boundary.
    ///  - `.remove` (nibble-back): the overhang is chewed off → use the INNER
    ///    boundary so those bases are excluded.
    ///
    /// `isLeftType` is true when the fragment lies to the RIGHT of this cut
    /// (i.e. this is a left end); false when the fragment lies to the LEFT.
    /// The overhang span is always between min(cut5,cut3) and max(cut5,cut3),
    /// regardless of whether it is a 5′ or 3′ overhang.
    private func bluntBoundary(cut5: Int, cut3: Int, seqLen: Int,
                               isLeftType: Bool, processing: EndProcessing,
                               legacyPos: Int) -> Int {
        guard processing != .nonProcessed else { return legacyPos }
        let lo = min(cut5, cut3)
        let hi = max(cut5, cut3)
        let includePos = isLeftType ? lo : hi   // keeps overhang bases in fragment
        let excludePos = isLeftType ? hi : lo   // drops overhang bases
        let pos = (processing == .fillIn) ? includePos : excludePos
        return normPos(pos, seqLen)
    }
    
    /// Per-base complement (A↔T, G↔C).  NOT reversed.
    /// Static table built once; no allocation on every call.
    private static let complementMap: [Character: Character] = [
        "A": "T", "T": "A", "G": "C", "C": "G", "N": "N",
        "a": "t", "t": "a", "g": "c", "c": "g", "n": "n"
    ]
    private func complementStr(_ seq: String) -> String {
        String(seq.map { Self.complementMap[$0] ?? $0 })
    }
    
    /// Full reverse complement (complement + reverse).
    private func reverseComplementStr(_ seq: String) -> String {
        String(complementStr(seq).reversed())
    }
    
    
    // MARK: - Fragment Size
    
    private func computeFragmentSize(
        seqLen: Int, isCircular: Bool,
        leftSite: CutSiteRef?, rightSite: CutSiteRef?,
        isVector: Bool, useWrap: Bool
    ) -> Int {
        guard let left = leftSite, let right = rightSite, seqLen > 0 else { return 0 }
        
        let leftCut  = normPos(left.cutPos5, seqLen)
        let rightCut = normPos(right.cutPos5, seqLen)
        
        if isCircular {
            // Match the map's definition: Fragment A = shorter direct arc
            // between the two cut positions (pos2 - pos1), independent of
            // click order.  Fragment B = the complementary wrap-around arc.
            let pos1 = min(leftCut, rightCut)
            let pos2 = max(leftCut, rightCut)
            let direct = pos2 - pos1
            return useWrap ? (seqLen - direct) : direct
        }
        
        // ── Linear sequences (no wrap) ──
        if isVector {
            // Linear backbone: [0→leftCut] + [rightCut→end]
            return leftCut + (seqLen - rightCut)
        } else {
            // Linear insert
            return abs(rightCut - leftCut)
        }
    }
    
    
    // MARK: - Browse for Sequence File
    
    private func browseForSequence(sequenceID: Binding<UUID?>, fragmentIndex: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "xdna") ?? .plainText,
            UTType(filenameExtension: "ape") ?? .plainText,
            UTType(filenameExtension: "fasta") ?? .plainText,
            UTType(filenameExtension: "fa") ?? .plainText,
            UTType(filenameExtension: "gb") ?? .plainText,
            UTType(filenameExtension: "gbk") ?? .plainText,
            .plainText, .data
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a DNA sequence file"
        
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            
            let countBefore = self.sequenceManager.sequences.count
            self.sequenceManager.loadSequenceFromFile(url)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if self.sequenceManager.sequences.count > countBefore,
                   let newSeq = self.sequenceManager.sequences.last {
                    sequenceID.wrappedValue = newSeq.id
                    if fragmentIndex == 1 {
                        self.st.vectorLeftSite = nil
                        self.st.vectorRightSite = nil
                        self.st.vectorUseWrap = false
                    } else {
                        self.st.insertLeftSite = nil
                        self.st.insertRightSite = nil
                        self.st.insertUseWrap = false
                    }
                    self.st.activeFragment = fragmentIndex
                }
            }
        }
    }
    
    // MARK: - Ends Compatible
    
    private func endsCompatible(_ oh1: String, _ oh2: String) -> Bool {
        // Blunt ends (empty strings) are compatible with each other
        if oh1.isEmpty && oh2.isEmpty { return true }
        // Cohesive ends must match — compare case-insensitively since sequences
        // may be stored in mixed case (e.g. exons uppercase, introns lowercase).
        return oh1.uppercased() == oh2.uppercased()
    }

    // MARK: - Methylation Status

    /// Check whether a specific cut site is affected by current methylation settings.
    /// Returns blocked/required flags plus a short inline note naming the specific
    /// methylation type (e.g. "blocked by Dam", "needs Dam methylation").
    /// Returns (false, false, "") when no methylation is active or site is nil.
    private func methylationStatus(
        for site: CutSiteRef?,
        in seqStr: String,
        isCircular: Bool
    ) -> (blocked: Bool, required: Bool, shortNote: String) {
        guard let site = site,
              methylationDam || methylationDcm || methylationCpG,
              let enz = RestrictionEnzymeDatabase.shared.enzymes.first(where: { $0.name == site.enzyme })
        else { return (false, false, "") }
        let warnings = MethylationChecker.checkSite(
            enzymeName:      site.enzyme,
            sitePosition:    site.position,
            recognitionSite: enz.recognitionSite,
            sequence:        seqStr,
            circular:        isCircular,
            activeDam:       methylationDam,
            activeDcm:       methylationDcm,
            activeCpG:       methylationCpG
        )
        let isBlocked  = MethylationChecker.isCutBlocked(warnings)
        let isRequired = warnings.contains { $0.effect == .required }

        // Build a short note naming the specific methylation type.
        // Derived from the recognition site so it is independent of
        // however warningText() words its output.
        var shortNote = ""
        if isRequired {
            // Enzyme requires methylation to cut (e.g. DpnI needs Dam-methylated GATC).
            if methylationDam      { shortNote = "needs Dam methylation" }
            else if methylationDcm { shortNote = "needs Dcm methylation" }
            else if methylationCpG { shortNote = "needs CpG methylation" }
        } else if isBlocked {
            let rec = enz.recognitionSite.uppercased()
            var types: [String] = []
            if methylationDam && rec.contains("GATC")                                           { types.append("Dam") }
            if methylationDcm && (rec.contains("CCAGG") || rec.contains("CCTGG")
                               || rec.contains("CCWGG"))                                        { types.append("Dcm") }
            if methylationCpG && rec.contains("CG")                                             { types.append("CpG") }
            shortNote = types.isEmpty ? "blocked by methylation"
                                      : "blocked by \(types.joined(separator: "/"))"
        }
        return (blocked: isBlocked, required: isRequired, shortNote: shortNote)
    }
    
    // MARK: - Ligation
    
    private func performLigation() {
        // Force print to console
        
        st.ligationError = ""
        st.ligationResult = ""
        
        guard let vecSeq = vectorSequence,
              let insSeq = insertSequence,
              let vLeft_raw = st.vectorLeftSite,
              let vRight_raw = st.vectorRightSite else {
            st.ligationError = "Select both sequences and two cut sites for the vector."
            return
        }
        
        // For an undigested insert, skip site requirement entirely
        if st.insertUndigested && (st.insertLeftSite != nil || st.insertRightSite != nil) {
            // user turned on undigested but left old sites — clear them
            st.insertLeftSite = nil
            st.insertRightSite = nil
        }
        
        guard st.insertUndigested || (st.insertLeftSite != nil && st.insertRightSite != nil) else {
            st.ligationError = "Select two cut sites for the insert, or enable 'Undigested insert (blunt ends)'."
            return
        }
        
        let iLeft_raw = st.insertLeftSite
        let iRight_raw = st.insertRightSite
        
        let vecStr = vecSeq.sequence.uppercased()
        let insStr = insSeq.sequence.uppercased()
        let vecLen = vecStr.count
        let insLen = insStr.count
        
        // ── Normalize VECTOR cut-site assignment ──
        // The user may click the two vector sites in either order, but downstream
        // extraction and assembly need vLeft to be at the lower position and vRight
        // at the higher position, otherwise:
        //   • On a CIRCULAR vector, the backbone-extraction debug variable gets the
        //     small 21 bp stuffer instead of the real backbone (cosmetic — the
        //     actual construct is still built correctly via the assembly's case 2
        //     branch, but the reported "Backbone: N bp" is misleading).
        //   • On a LINEAR vector, leftFlank and rightFlank overlap and the backbone
        //     contains the stuffer region twice — actual data corruption.
        // After this normalize step, the existing extraction and assembly always
        // take their "case 1" branches; the "case 2" branches become defensive
        // dead code for normal inputs.
        //
        // The Fragment A/B picker (st.vectorUseWrap) IS honoured below via the
        // useSmallBackbone flag, which selects whether the backbone is the wrap
        // arc (the typical case, big backbone) or the direct arc (the rarer case
        // where the small arc IS the real plasmid backbone — e.g. cutting a
        // 12 kb plasmid that contains pUC19 plus a 10 kb insert with EcoRI/BamHI:
        // the small ~2.7 kb arc is the actual cloning vector, the big arc is the
        // discarded stuffer).
        let vLeft: CutSiteRef
        let vRight: CutSiteRef
        do {
            let lPos = normPos(vLeft_raw.cutPos5, vecLen)
            let rPos = normPos(vRight_raw.cutPos5, vecLen)
            if lPos <= rPos {
                vLeft  = vLeft_raw
                vRight = vRight_raw
            } else {
                vLeft  = vRight_raw
                vRight = vLeft_raw
            }
        }
        
        // useSmallBackbone: when true, the backbone is the direct arc
        // vec[vLeftCutPos..vRightCutPos) (the small piece between cuts) and the
        // construct is just backbone + insert.  When false, the backbone is the
        // wrap arc (everything except the direct arc) and the existing assembly
        // logic applies.  Only meaningful for circular vectors.
        let useSmallBackbone = vecSeq.isCircular && !st.vectorUseWrap
        
        // ── Normalize INSERT cut-site assignment ──
        // The user can click the two insert sites in either order, but extraction
        // and the compatibility check both need a consistent "iLeft is the 5′ end
        // of the chosen fragment, iRight is the 3′ end" convention.
        //
        // For LINEAR inserts: there is only one sensible fragment between two cuts
        // (the piece BETWEEN them), so iLeft must always be at the lower position.
        // The previous "Linear insert with left > right" extraction branch produced
        // a nonsensical concatenation of the two flanking pieces — this normalize
        // step makes that branch unreachable.
        //
        // For CIRCULAR inserts: the Fragment A/B picker (st.insertUseWrap) chooses the
        // arc.  Fragment A = direct arc (lower → upper).  Fragment B = wrap arc
        // (upper → lower, going through the origin).  This makes the existing
        // circular extraction branches do the right thing for either picker choice.
        //
        // For UNDIGESTED inserts: iLeft/iRight are unused; the full sequence is used.
        let iLeft: CutSiteRef?
        let iRight: CutSiteRef?
        if st.insertUndigested {
            iLeft = nil
            iRight = nil
        } else if let iLeft_raw = iLeft_raw, let iRight_raw = iRight_raw {
            let lPos = normPos(iLeft_raw.cutPos5, insLen)
            let rPos = normPos(iRight_raw.cutPos5, insLen)
            let lowerSite = (lPos <= rPos) ? iLeft_raw : iRight_raw
            let upperSite = (lPos <= rPos) ? iRight_raw : iLeft_raw
            if insSeq.isCircular && st.insertUseWrap {
                iLeft  = upperSite
                iRight = lowerSite
            } else {
                iLeft  = lowerSite
                iRight = upperSite
            }
        } else {
            st.ligationError = "Select two cut sites for the insert, or enable 'Undigested insert (blunt ends)'."
            return
        }
        
        // ── Get overhang sequences ──
        let vecLeftOH  = overhangString(site: vLeft,  seqStr: vecStr, seqLen: vecLen)
        let vecRightOH = overhangString(site: vRight, seqStr: vecStr, seqLen: vecLen)
        // Undigested insert has blunt ends (empty overhangs)
        let insLeftOH  = st.insertUndigested ? "" : overhangString(site: iLeft!,  seqStr: insStr, seqLen: insLen)
        let insRightOH = st.insertUndigested ? "" : overhangString(site: iRight!, seqStr: insStr, seqLen: insLen)
        
        // Apply processing
        let effVecLeftOH  = st.vectorLeft5Processing  == .nonProcessed ? vecLeftOH  : ""
        let effVecRightOH = st.vectorRight3Processing == .nonProcessed ? vecRightOH : ""
        
        // ── Compute effective insert overhangs (accounting for flip) ──
        // The flip swaps left ↔ right; end processing is then applied to the
        // DISPLAYED ends (matching overhangDisplay), so a filled-in or
        // nibbled-back insert end is treated as blunt (empty overhang) here too.
        // (Previously the insert's processing was ignored in this check, so a
        // sticky end that had been blunted was still compared as sticky and
        // wrongly reported as incompatible.)
        let insLeftFlipped:  String
        let insRightFlipped: String
        if st.insertFlipped {
            insLeftFlipped  = reverseComplementStr(insRightOH)
            insRightFlipped = reverseComplementStr(insLeftOH)
        } else {
            insLeftFlipped  = insLeftOH
            insRightFlipped = insRightOH
        }
        let effInsLeftOH  = st.insertLeft5Processing  == .nonProcessed ? insLeftFlipped  : ""
        let effInsRightOH = st.insertRight3Processing == .nonProcessed ? insRightFlipped : ""
        
        // ── Overhang compatibility check ──
        // Only the sticky end sequences matter for annealing, not the enzyme
        // names.  This allows compatible pairs like BamHI/BglII (both GATC
        // overhangs), MfeI/EcoRI (both AATT), SalI/XhoI (both TCGA), etc.
        let j1OK = endsCompatible(effVecLeftOH, effInsLeftOH)
        let j2OK = endsCompatible(effVecRightOH, effInsRightOH)
        
        if !j1OK || !j2OK {
            // Check if flipping the insert would make ends compatible
            let j1FlipOK = endsCompatible(effVecLeftOH, reverseComplementStr(effInsRightOH))
            let j2FlipOK = endsCompatible(effVecRightOH, reverseComplementStr(effInsLeftOH))
            if j1FlipOK && j2FlipOK && !st.insertFlipped {
                st.insertFlipped = true
                return
            }
            let msg = !j1OK && !j2OK ? "Neither junction has compatible overhangs."
            : !j1OK ? "Left junction overhangs are not compatible."
            : "Right junction overhangs are not compatible."
            st.ligationError = "Error: \(msg) Cannot ligate incompatible ends."
            return
        }
        
        // ══════════════════════════════════════════════════════════════════
        // DETERMINE CUT POSITIONS
        // ══════════════════════════════════════════════════════════════════
        //
        // CutSiteRef.cutPos5/cutPos3 are already 0-based string indices
        // (position + enzyme.cutOffset).  Use them directly.
        //
        // For a 5' overhang enzyme (cut5 < cut3):
        //   - fragment boundary at cut5
        // For a 3' overhang enzyme (cut5 > cut3):
        //   - fragment boundary at cut3
        // For blunt (cut5 == cut3):
        //   - both are the same, use either
        // ══════════════════════════════════════════════════════════════════
        
        let vLeft5 = vLeft.cutPos5
        let vLeft3 = vLeft.cutPos3
        let vRight5 = vRight.cutPos5
        let vRight3 = vRight.cutPos3
        let iLeft5 = iLeft?.cutPos5 ?? 0
        let iLeft3 = iLeft?.cutPos3 ?? 0
        let iRight5 = iRight?.cutPos5 ?? 0
        let iRight3 = iRight?.cutPos3 ?? 0
        
        // Vector backbone runs from vRight (RED) to vLeft (GREEN) clockwise.
        // Default boundary = recessed (inner) cut position = min(cut5,cut3),
        // the standard cohesive-end convention.  bluntBoundary() only shifts an
        // end that has been blunted: fill-in keeps the overhang bases in the
        // backbone, nibble-back drops them; unprocessed ends are unchanged.
        //
        // vRight is the START of the backbone (backbone lies to its RIGHT) → left-type.
        // vLeft  is the END   of the backbone (backbone lies to its LEFT)  → right-type.
        let vRightLegacy = normPos(min(vRight5, vRight3), vecLen)
        let vLeftLegacy  = normPos(min(vLeft5,  vLeft3),  vecLen)
        let vRightCutPos = bluntBoundary(cut5: vRight5, cut3: vRight3, seqLen: vecLen,
                                         isLeftType: true,  processing: st.vectorRight3Processing,
                                         legacyPos: vRightLegacy)  // START of backbone
        let vLeftCutPos  = bluntBoundary(cut5: vLeft5,  cut3: vLeft3,  seqLen: vecLen,
                                         isLeftType: false, processing: st.vectorLeft5Processing,
                                         legacyPos: vLeftLegacy)   // END of backbone
        

        
        // ══════════════════════════════════════════════════════════════════
        // EXTRACT VECTOR BACKBONE
        // ══════════════════════════════════════════════════════════════════
        
        var backbone: String
        
        if vecSeq.isCircular {
            if vLeftCutPos == vRightCutPos {
                // Single-enzyme cut on circular vector → linearise:
                // the entire sequence IS the backbone, rearranged to start
                // at the cut site.  (Picker irrelevant — only one arc.)
                let part1 = String(vecStr.suffix(vecLen - vRightCutPos))
                let part2 = String(vecStr.prefix(vRightCutPos))
                backbone = part1 + part2
            } else if useSmallBackbone {
                // Small backbone (Fragment A picked): backbone = direct arc
                // [vLeftCutPos..vRightCutPos).  Used when the small arc IS the
                // real cloning vector (e.g. pUC19+huge insert source plasmid).
                let s = vecStr.index(vecStr.startIndex, offsetBy: vLeftCutPos)
                let e = vecStr.index(vecStr.startIndex, offsetBy: vRightCutPos)
                backbone = String(vecStr[s..<e])
            } else if vRightCutPos < vLeftCutPos {
                // Defensive dead code post-normalize: vLeft is always at the
                // lower position, so vRight < vLeft cannot happen for normal
                // inputs.  Kept as a safety net.
                let s = vecStr.index(vecStr.startIndex, offsetBy: vRightCutPos)
                let e = vecStr.index(vecStr.startIndex, offsetBy: vLeftCutPos)
                backbone = String(vecStr[s..<e])
            } else {
                // Big backbone (Fragment B picked, the typical case):
                // wrap arc through origin = [vRightCutPos..end] + [0..vLeftCutPos)
                let part1 = String(vecStr.suffix(vecLen - vRightCutPos))
                let part2 = String(vecStr.prefix(vLeftCutPos))
                backbone = part1 + part2
            }
            
            guard !backbone.isEmpty else {
                st.ligationError = "Vector backbone is empty — check cut site positions."
                return
            }
        } else {
            // Linear vector
            let leftFlank = String(vecStr.prefix(vLeftCutPos))
            let rightFlank = String(vecStr.suffix(vecLen - vRightCutPos))
            
            guard !leftFlank.isEmpty || !rightFlank.isEmpty else {
                st.ligationError = "Vector backbone is empty — check cut site positions."
                return
            }
            
            backbone = leftFlank + rightFlank
        }
        
        // ══════════════════════════════════════════════════════════════════
        // EXTRACT INSERT FRAGMENT - CORRECTED FOR SIZE
        // ══════════════════════════════════════════════════════════════════
        
        let insertFragment: String
        
        if st.insertUndigested {
            // Undigested: use the complete insert sequence as-is
            insertFragment = insStr
        } else if let iL = iLeft, let iR = iRight {
            // Flipped insert uses cutPos3 boundaries to include full overhangs,
            // so after RC each end presents the correct 5' overhang for ligation.
            let iLC: Int
            let iRC: Int
            if st.insertFlipped {
                // Flipped legacy boundary = max (outer); the fragment is reverse-
                // complemented afterwards.  Under flip the DISPLAYED ends swap,
                // so the physical-left end (iL) carries the display-RIGHT
                // processing flag, and the physical-right end (iR) the display-LEFT.
                let iLLegacy = normPos(max(iL.cutPos5, iL.cutPos3), insLen)
                let iRLegacy = normPos(max(iR.cutPos5, iR.cutPos3), insLen)
                iLC = bluntBoundary(cut5: iL.cutPos5, cut3: iL.cutPos3, seqLen: insLen,
                                    isLeftType: true,  processing: st.insertRight3Processing,
                                    legacyPos: iLLegacy)
                iRC = bluntBoundary(cut5: iR.cutPos5, cut3: iR.cutPos3, seqLen: insLen,
                                    isLeftType: false, processing: st.insertLeft5Processing,
                                    legacyPos: iRLegacy)
            } else {
                // Non-flipped legacy boundary = min (recessed/inner).  iL is the
                // left end (fragment to its right → left-type); iR the right end.
                let iLLegacy = normPos(min(iL.cutPos5, iL.cutPos3), insLen)
                let iRLegacy = normPos(min(iR.cutPos5, iR.cutPos3), insLen)
                iLC = bluntBoundary(cut5: iL.cutPos5, cut3: iL.cutPos3, seqLen: insLen,
                                    isLeftType: true,  processing: st.insertLeft5Processing,
                                    legacyPos: iLLegacy)
                iRC = bluntBoundary(cut5: iR.cutPos5, cut3: iR.cutPos3, seqLen: insLen,
                                    isLeftType: false, processing: st.insertRight3Processing,
                                    legacyPos: iRLegacy)
            }
            if iLC == iRC && insSeq.isCircular {
                // Single-enzyme cut on circular insert → linearise (entire insert)
                let part1 = String(insStr.suffix(insLen - iLC))
                let part2 = String(insStr.prefix(iLC))
                insertFragment = part1 + part2
            } else if iLC < iRC {
                let startIdx = insStr.index(insStr.startIndex, offsetBy: iLC)
                let endIdx = insStr.index(insStr.startIndex, offsetBy: iRC)
                insertFragment = String(insStr[startIdx..<endIdx])
            } else if insSeq.isCircular {
                let part1 = String(insStr.suffix(insLen - iLC))
                let part2 = String(insStr.prefix(iRC))
                insertFragment = part1 + part2
            } else {
                let lo = min(iLC, iRC)
                let hi = max(iLC, iRC)
                let startIdx = insStr.index(insStr.startIndex, offsetBy: lo)
                let endIdx = insStr.index(insStr.startIndex, offsetBy: hi)
                insertFragment = String(insStr[startIdx..<endIdx])
            }
        } else {
            st.ligationError = "Insert cut sites missing."
            return
        }
        
        guard !insertFragment.isEmpty else {
            st.ligationError = "Insert fragment is empty — check cut site positions."
            return
        }
        
        // Apply flip if needed
        let finalInsertFragment = st.insertFlipped ? reverseComplementStr(insertFragment) : insertFragment
        
        if st.insertFlipped {
        }
        
        // ══════════════════════════════════════════════════════════════════
        // ASSEMBLE CONSTRUCT
        // ══════════════════════════════════════════════════════════════════
        
        var construct: String
        let backboneLen = backbone.count
        var insertStartInConstruct: Int
        
        if vecSeq.isCircular {
            if useSmallBackbone && vLeftCutPos != vRightCutPos {
                // Small-backbone mode: backbone IS the direct arc, construct is
                // simply backbone + insert (then circularised).  The discarded
                // stuffer is the wrap arc (everything except [vLeft..vRight)).
                //
                // Guarded against vLeftCutPos == vRightCutPos (single-enzyme
                // cut on a circular vector): in that case the direct arc is
                // empty, so the small-backbone construction would produce just
                // the insert with no vector at all.  The single-enzyme case
                // falls through to the standard branch below, which handles it
                // correctly (prefix + insert + suffix == full linearised vector
                // with insert at the cut site).
                let backbonePiece = String(vecStr[vecStr.index(vecStr.startIndex, offsetBy: vLeftCutPos)..<vecStr.index(vecStr.startIndex, offsetBy: vRightCutPos)])
                construct = backbonePiece + finalInsertFragment
                insertStartInConstruct = backbonePiece.count
            } else if vLeftCutPos <= vRightCutPos {
                // Common big-backbone case: both sites in MCS, stuffer between them.
                // Stuffer = [vLeft..vRight), backbone wraps through origin.
                // Assemble as prefix + insert + suffix to preserve the vector origin.
                let prefix = String(vecStr.prefix(vLeftCutPos))
                let suffix = String(vecStr.suffix(vecLen - vRightCutPos))
                construct = prefix + finalInsertFragment + suffix
                insertStartInConstruct = vLeftCutPos
            } else {
                // Defensive dead code post-normalize (vLeft <= vRight always).
                // vLeft > vRight: stuffer is the short direct span [vRight..vLeft).
                // Backbone wraps through origin: [vLeft..end) + [0..vRight).
                let backboneSuffix = String(vecStr.suffix(vecLen - vLeftCutPos))  // [vLeft..end)
                let backbonePrefix = String(vecStr.prefix(vRightCutPos))           // [0..vRight)
                construct = backboneSuffix + finalInsertFragment + backbonePrefix
                insertStartInConstruct = backboneSuffix.count
            }
        } else {
            // Linear vector
            let leftFlank = String(vecStr.prefix(vLeftCutPos))
            let rightFlank = String(vecStr.suffix(vecLen - vRightCutPos))
            construct = leftFlank + finalInsertFragment + rightFlank
            insertStartInConstruct = vLeftCutPos
        }
        
        // ── Build descriptive fragment name ──
        let insertFragmentName: String
        if st.insertUndigested {
            insertFragmentName = "\(insSeq.name) (undigested)"
        } else if iLeft?.enzyme == iRight?.enzyme {
            insertFragmentName = "\(insSeq.name) \(iLeft?.enzyme ?? "") fragment"
        } else {
            insertFragmentName = "\(insSeq.name) \(iLeft?.enzyme ?? "")-\(iRight?.enzyme ?? "") fragment"
        }
        
        let constructName = "\(insertFragmentName) in \(vecSeq.name)"
        
        // Look for restriction sites
        if construct.range(of: "GAATTC") != nil {
        } else {
        }
        
        if construct.range(of: "AAGCTT") != nil {
        } else {
        }
        
        // Show junctions
        // ══════════════════════════════════════════════════════════════════
        // CREATE NEW SEQUENCE
        // ══════════════════════════════════════════════════════════════════
        
        DispatchQueue.main.async {
            let newSeq = DNASequence(name: constructName, sequence: construct, isCircular: vecSeq.isCircular)
            
            // Populate Comments panel with cloning details
            var descLines: [String] = []
            descLines.append("Construct: \(constructName)")
            descLines.append("Vector: \(vecSeq.name) (\(vecSeq.sequence.count) bp, \(vecSeq.isCircular ? "circular" : "linear"))")
            descLines.append("Insert: \(insSeq.name) (\(insSeq.sequence.count) bp)")
            descLines.append("Vector enzymes: \(vLeft.enzyme) (5') / \(vRight.enzyme) (3')")
            descLines.append("Insert enzymes: \(st.insertUndigested ? "none (undigested, blunt ends)" : "\(iLeft?.enzyme ?? "") (5') / \(iRight?.enzyme ?? "") (3')")")
            descLines.append("Insert fragment: \(finalInsertFragment.count) bp")
            descLines.append("Backbone: \(backboneLen) bp")
            if st.insertFlipped { descLines.append("Insert orientation: reversed") }
            descLines.append("Total construct: \(construct.count) bp")
            
            // Record any methylation sensitivities on the chosen enzymes so
            // the construct record serves as an audit trail.
            if self.methylationDam || self.methylationDcm || self.methylationCpG {
                var methWarnings: [String] = []
                let ms_vLeft  = self.methylationStatus(for: vLeft,  in: vecStr, isCircular: vecSeq.isCircular)
                let ms_vRight = self.methylationStatus(for: vRight, in: vecStr, isCircular: vecSeq.isCircular)
                let ms_iLeft  = self.methylationStatus(for: iLeft,  in: insStr, isCircular: insSeq.isCircular)
                let ms_iRight = self.methylationStatus(for: iRight, in: insStr, isCircular: insSeq.isCircular)
                if !ms_vLeft.shortNote.isEmpty  { methWarnings.append("\(vLeft.enzyme) (vector 5′): \(ms_vLeft.shortNote)") }
                if !ms_vRight.shortNote.isEmpty { methWarnings.append("\(vRight.enzyme) (vector 3′): \(ms_vRight.shortNote)") }
                if !ms_iLeft.shortNote.isEmpty  { methWarnings.append("\(iLeft?.enzyme ?? "insert 5′") (insert 5′): \(ms_iLeft.shortNote)") }
                if !ms_iRight.shortNote.isEmpty { methWarnings.append("\(iRight?.enzyme ?? "insert 3′") (insert 3′): \(ms_iRight.shortNote)") }
                if !methWarnings.isEmpty {
                    descLines.append("⚠ Methylation warnings: " + methWarnings.joined(separator: "; "))
                }
            }
            
            newSeq.description = descLines.joined(separator: "\n")
            
            // ── Carry over vector features, remapping positions ──
            // Features inside the excised stuffer are destroyed by cloning;
            // features in the kept backbone are remapped to their new positions.
            var carriedFeatures: [Feature] = []
            let insertLen = finalInsertFragment.count
            
            if useSmallBackbone && vLeftCutPos != vRightCutPos {
                // Small-backbone mode: backbone = [vLeftCutPos..vRightCutPos),
                // construct = backbone + insert.  Only features INSIDE the
                // direct arc are carried; everything else is in the discarded
                // wrap-arc stuffer and is destroyed.  Carried features shift
                // by -vLeftCutPos so the backbone starts at construct position 0.
                //
                // Guarded against vLeftCutPos == vRightCutPos (single-enzyme
                // circular cut): in that case the direct arc is empty and
                // we want all features carried, so fall through to the
                // standard branch below.
                for feature in vecSeq.features {
                    if feature.start >= vLeftCutPos && feature.end <= vRightCutPos {
                        var f = feature
                        f.id = UUID()
                        f.start = feature.start - vLeftCutPos
                        f.end = feature.end - vLeftCutPos
                        carriedFeatures.append(f)
                    }
                    // Otherwise lies in the discarded wrap arc — destroyed
                }
            } else if vecSeq.isCircular && vLeftCutPos > vRightCutPos {
                // Defensive dead code post-normalize: stuffer = short span [vRight..vLeft).
                // Construct = [vLeft..end) + insert + [0..vRight).
                // Features in [vLeft..end) shift to start of construct.
                // Features in [0..vRight) shift past the suffix and insert.
                let suffixLen = vecLen - vLeftCutPos
                for feature in vecSeq.features {
                    if feature.start >= vLeftCutPos {
                        // In backbone suffix [vLeft..end) — shift to start
                        var f = feature
                        f.id = UUID()
                        f.start = feature.start - vLeftCutPos
                        f.end = feature.end - vLeftCutPos
                        carriedFeatures.append(f)
                    } else if feature.end <= vRightCutPos {
                        // In backbone prefix [0..vRight) — shift past suffix + insert
                        var f = feature
                        f.id = UUID()
                        f.start = feature.start + suffixLen + insertLen
                        f.end = feature.end + suffixLen + insertLen
                        carriedFeatures.append(f)
                    }
                    // Otherwise overlaps stuffer [vRight..vLeft) — destroyed
                }
            } else {
                // Common big-backbone circular case & linear:
                // construct = prefix + insert + suffix
                // prefix = [0..<vLeftCutPos], suffix = [vRightCutPos..<vecLen]
                // stuffer = [vLeftCutPos..<vRightCutPos] (destroyed)
                let shift = insertLen - (vRightCutPos - vLeftCutPos)
                for feature in vecSeq.features {
                    if feature.end <= vLeftCutPos {
                        // Entirely in prefix — position unchanged
                        var f = feature
                        f.id = UUID()
                        carriedFeatures.append(f)
                    } else if feature.start >= vRightCutPos {
                        // Entirely in suffix — shift positions
                        var f = feature
                        f.id = UUID()
                        f.start = feature.start + shift
                        f.end = feature.end + shift
                        carriedFeatures.append(f)
                    }
                    // Otherwise overlaps stuffer — destroyed
                }
            }
            
            newSeq.features = carriedFeatures
            
            // Add insert as a feature
            let insertStart = insertStartInConstruct
            newSeq.features.append(Feature(
                name: insertFragmentName,
                type: .custom,
                start: insertStart,
                end: insertStart + finalInsertFragment.count,
                strand: st.insertFlipped ? .reverse : .forward,
                color: CodableColor(red: 0.2, green: 0.6, blue: 0.9)
            ))
            
            // Store IDs BEFORE appending, so the picker filter is already
            // active when SwiftUI redraws — prevents the construct briefly
            // appearing as a selectable vector/insert option
            self.st.originalVectorID   = self.st.vectorSequenceID
            self.st.constructSequenceID = newSeq.id
            
            self.sequenceManager.sequences.append(newSeq)
            self.sequenceManager.currentSequence = newSeq
            self.st.constructInsertName = insertFragmentName
            self.st.constructInsertStart = insertStartInConstruct
            self.st.constructInsertLength = finalInsertFragment.count
            self.st.constructIsDirectional = (vLeft.enzyme != vRight.enzyme)
            
            // Switch to the Construct tab
            self.st.activeFragment = 3
            
            self.st.ligationResult = "✓ \(constructName) — \(construct.count) bp"
            self.st.ligationError = ""
        }
    }
}

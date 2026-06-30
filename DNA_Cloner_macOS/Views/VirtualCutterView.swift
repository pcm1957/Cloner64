//
//  VirtualCutterView.swift
//  Cloner 64
//
//  Virtual restriction digest with gel electrophoresis visualization.
//  Select one or more sequences, choose restriction enzymes, and visualize
//  the resulting fragments on a simulated agarose gel.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers


// MARK: - Window Manager

class VirtualCutterWindowManager {
    static let shared = VirtualCutterWindowManager()
    private var window: NSWindow?
    
    func openWindow(sequenceManager: SequenceManager) {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        
        let view = VirtualCutterView(sequenceManager: sequenceManager)
        let hostingView = NSHostingView(rootView: view)
        
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Virtual Cutter"
        win.contentView = hostingView
        win.setFrameAutosaveName("VirtualCutter")
        if !win.setFrameUsingName(win.frameAutosaveName) { win.center() }
        win.makeKeyAndOrderFront(nil)
        win.isReleasedWhenClosed = false
        
        self.window = win
    }
}


// MARK: - Marker Definitions

struct MWMarker: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let fragments: [Int]  // sizes in bp, descending
    
    func hash(into hasher: inout Hasher) { hasher.combine(name) }
    static func == (lhs: MWMarker, rhs: MWMarker) -> Bool { lhs.name == rhs.name }
}

let standardMarkers: [MWMarker] = [
    MWMarker(name: "λ HindIII", fragments: [23130, 9416, 6557, 4361, 2322, 2027, 564, 125]),
    MWMarker(name: "λ HindIII / EcoRI", fragments: [21226, 5148, 4973, 4268, 3530, 2027, 1904, 1584, 1375, 947, 831, 564, 125]),
    MWMarker(name: "1 kb Ladder", fragments: [10000, 8000, 6000, 5000, 4000, 3000, 2000, 1500, 1000, 750, 500, 250]),
    MWMarker(name: "100 bp Ladder", fragments: [1000, 900, 800, 700, 600, 500, 400, 300, 200, 100]),
    MWMarker(name: "1 kb Plus Ladder", fragments: [15000, 10000, 8000, 7000, 6000, 5000, 4000, 3000, 2000, 1500, 1000, 850, 650, 500, 400, 300, 200, 100]),
    MWMarker(name: "Supercoiled Ladder", fragments: [10000, 8000, 6000, 5000, 4000, 3000, 2500, 2000]),
]


// MARK: - Digest Lane

struct DigestLane: Identifiable {
    let id = UUID()
    var label: String
    let enzymes: [String]
    let fragments: [Int]   // sizes in bp, descending
    var sequenceName: String = ""  // source sequence; non-empty when multiple sequences are digested
    var expectedLength: Int = 0    // used for sanity check: fragments should sum to this
}


// MARK: - Lane Label Style

enum LaneLabelStyle: String, CaseIterable {
    case full    = "Full"
    case numbers = "1, 2, 3"
    case letters = "A, B, C"
}


// MARK: - Main View

struct VirtualCutterView: View {
    @ObservedObject var sequenceManager: SequenceManager
    
    // Sequence selection — now a Set to support multiple sequences
    @State private var selectedSequenceIDs: Set<UUID> = []
    
    // Enzyme selection
    @State private var selectedEnzymes: Set<String> = []
    @State private var enzymeSearchText: String = ""
    @State private var nonCuttingEnzymes: Set<String> = []
    @State private var useMyEnzymesOnly: Bool = false
    
    // Marker
    @State private var selectedMarkerIndex: Int = 0
    
    // Results
    @State private var lanes: [DigestLane] = []
    @State private var digestReport: String = ""  // text report of all fragments
    @State private var skippedEnzymes: [String] = []  // enzymes removed from combined digest
    
    // Options
    @State private var showSingleDigests: Bool = true
    @State private var showCombinedDigest: Bool = false
    
    // Methylation sensitivity (shared with GraphicalMapView via AppStorage)
    @AppStorage("methylation_dam") private var methylationDam: Bool = true
    @AppStorage("methylation_dcm") private var methylationDcm: Bool = true
    @AppStorage("methylation_cpg") private var methylationCpG: Bool = false
    
    // Hover tooltip
    @State private var hoveredBandText: String = ""
    @State private var hoverPoint: CGPoint = .zero
    
    // Lane reordering / label editing
    @State private var editingLaneID: UUID? = nil
    @State private var editingLabel: String = ""
    @State private var previousLanes: [DigestLane]? = nil   // one-level undo
    @State private var laneLabelStyle: LaneLabelStyle = .full
    @State private var showEnzymeInLabel: Bool = false
    
    // Display enhancements
    @State private var showBandLabels: Bool = false
    @State private var minFragmentBP: Double = 0
    
    // Print orientation
    @State private var printLandscape: Bool = true
    
    private var selectedMarker: MWMarker { standardMarkers[selectedMarkerIndex] }
    
    /// All currently selected sequences, in the order they appear in the manager.
    private var selectedSequences: [DNASequence] {
        sequenceManager.sequences.filter { selectedSequenceIDs.contains($0.id) }
    }
    
    private let enzymeDB = RestrictionEnzymeDatabase.shared
    
    private var filteredEnzymes: [String] {
        let enzList = useMyEnzymesOnly ? enzymeDB.myEnzymes : enzymeDB.enzymes
        let names = enzList.map { $0.name }.sorted()
        if enzymeSearchText.isEmpty { return names }
        return names.filter { $0.localizedCaseInsensitiveContains(enzymeSearchText) }
    }
    
    var body: some View {
        HSplitView {
            // Left panel: controls
            controlsPanel
                .frame(minWidth: 240, maxWidth: 300)
            
            // Right panel: gel
            gelPanel
                .frame(minWidth: 500)
        }
        .frame(minWidth: 800, minHeight: 600)
        .textSelection(.enabled)
        .onAppear {
            if selectedSequenceIDs.isEmpty, let first = sequenceManager.sequences.first {
                selectedSequenceIDs = [first.id]
            }
            computeNonCuttingEnzymes()
        }
        .onChange(of: selectedSequenceIDs) { _ in
            computeNonCuttingEnzymes()
        }
    }
    
    /// Computes which enzymes do not cut ANY of the currently selected sequences.
    /// An enzyme is only shown italic/greyed if it fails to cut every selected sequence.
    private func computeNonCuttingEnzymes() {
        let seqObjects = selectedSequences
        guard !seqObjects.isEmpty else {
            nonCuttingEnzymes = []
            return
        }
        let database = enzymeDB
        DispatchQueue.global(qos: .userInitiated).async {
            var nonCutters = Set<String>()
            for enzyme in database.enzymes {
                let cutsAny = seqObjects.contains { seq in
                    !enzyme.findCutSites(in: seq.sequence, circular: seq.isCircular).isEmpty
                }
                if !cutsAny { nonCutters.insert(enzyme.name) }
            }
            DispatchQueue.main.async { nonCuttingEnzymes = nonCutters }
        }
    }
    
    
    // MARK: - Controls Panel
    
    private var controlsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Sequence selector — checkbox list, tick one or more sequences
            GroupBox("Sequences") {
                VStack(alignment: .leading, spacing: 4) {
                    if sequenceManager.sequences.isEmpty {
                        Text("No sequences open")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(sequenceManager.sequences) { seq in
                                    Toggle(isOn: Binding(
                                        get: { selectedSequenceIDs.contains(seq.id) },
                                        set: { isOn in
                                            if isOn { selectedSequenceIDs.insert(seq.id) }
                                            else    { selectedSequenceIDs.remove(seq.id) }
                                        }
                                    )) {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(seq.name)
                                                .font(.system(size: 13))
                                            Text("\(seq.length) bp · \(seq.isCircular ? "circular" : "linear")")
                                                .font(.system(size: 11))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .toggleStyle(.checkbox)
                                    .padding(.horizontal, 2)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .frame(maxHeight: 110)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contextHelp("vcutter.sequencePicker")
            .padding(.horizontal, 10).padding(.top, 10)
            
            // Marker picker
            GroupBox("MW Marker") {
                Picker("", selection: $selectedMarkerIndex) {
                    ForEach(0..<standardMarkers.count, id: \.self) { i in
                        Text(standardMarkers[i].name).tag(i)
                    }
                }
                .labelsHidden()
                .contextHelp("vcutter.markerPicker")
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10).padding(.top, 6)
            
            // Options
            GroupBox("Options") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Individual digests", isOn: $showSingleDigests)
                        .font(.caption).toggleStyle(.checkbox)
                        .contextHelp("vcutter.individualDigests")
                    Toggle("Combined digest", isOn: $showCombinedDigest)
                        .font(.caption).toggleStyle(.checkbox)
                        .contextHelp("vcutter.combinedDigest")
                    
                    Divider().padding(.vertical, 2)
                    
                    Text("Methylation").font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
                    Toggle("Dam (GATC)", isOn: $methylationDam)
                        .font(.caption).toggleStyle(.checkbox)
                        .contextHelp("vcutter.methylationDam")
                    Toggle("Dcm (CCWGG)", isOn: $methylationDcm)
                        .font(.caption).toggleStyle(.checkbox)
                        .contextHelp("vcutter.methylationDcm")
                    Toggle("CpG", isOn: $methylationCpG)
                        .font(.caption).toggleStyle(.checkbox)
                        .contextHelp("vcutter.methylationCpG")
                    
                    Divider().padding(.vertical, 2)
                    
                    Text("Lane labels").font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
                    Picker("", selection: $laneLabelStyle) {
                        ForEach(LaneLabelStyle.allCases, id: \.self) { style in
                            Text(style.rawValue).tag(style)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .font(.caption)
                    .contextHelp("vcutter.laneLabelStyle")
                    Toggle("Show enzyme name", isOn: $showEnzymeInLabel)
                        .font(.caption).toggleStyle(.checkbox)
                        .disabled(laneLabelStyle == .full)
                        .foregroundColor(laneLabelStyle == .full ? .secondary : .primary)
                        .contextHelp("vcutter.showEnzymeInLabel")
                    
                    Divider().padding(.vertical, 2)
                    
                    Text("Gel display").font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
                    Toggle("Show band sizes", isOn: $showBandLabels)
                        .font(.caption).toggleStyle(.checkbox)
                        .contextHelp("vcutter.showBandLabels")
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Min size: \(Int(minFragmentBP)) bp")
                            .font(.caption)
                            .foregroundColor(minFragmentBP > 0 ? .primary : .secondary)
                        Slider(value: $minFragmentBP, in: 0...1000, step: 25)
                            .contextHelp("vcutter.minFragmentSize")
                        if minFragmentBP > 0 {
                            Text("Hiding fragments < \(Int(minFragmentBP)) bp")
                                .font(.system(size: 10))
                                .foregroundColor(.orange)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10).padding(.top, 6)
            
            // Enzyme picker
            GroupBox("Restriction Enzymes") {
                VStack(spacing: 6) {
                    TextField("Search enzymes…", text: $enzymeSearchText)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    
                    Toggle(isOn: $useMyEnzymesOnly) {
                        Label("My Enzymes Only", systemImage: "star.fill")
                            .font(.caption)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(enzymeDB.myEnzymeNames.isEmpty)
                    .help(enzymeDB.myEnzymeNames.isEmpty
                          ? "No enzymes marked — use Tools → Restriction Enzyme List to star enzymes"
                          : "Show only enzymes in your freezer")
                    
                    if !selectedEnzymes.isEmpty {
                        HStack(spacing: 4) {
                            Text("Selected:")
                                .font(.caption).foregroundColor(.secondary)
                            Text(selectedEnzymes.sorted().joined(separator: ", "))
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(2)
                            Spacer()
                            Button("Clear") { selectedEnzymes.removeAll() }
                                .font(.caption).controlSize(.small)
                        }
                    }
                    
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(filteredEnzymes, id: \.self) { name in
                                let doesNotCut = nonCuttingEnzymes.contains(name)
                                Toggle(isOn: Binding(
                                    get: { selectedEnzymes.contains(name) },
                                    set: { isOn in
                                        if isOn { selectedEnzymes.insert(name) }
                                        else { selectedEnzymes.remove(name) }
                                    }
                                )) {
                                    HStack(spacing: 6) {
                                        Text(name)
                                            .font(.system(.caption, design: .monospaced))
                                            .italic(doesNotCut)
                                            .foregroundColor(doesNotCut ? .secondary : .primary)
                                        if let enzyme = enzymeDB.enzymes.first(where: { $0.name == name }) {
                                            Text(enzyme.recognitionSite)
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundColor(.secondary)
                                            
                                            // Methylation sensitivity indicator
                                            let sens = MethylationSensitivityDB.sensitivities(for: name)
                                            let activeSens = sens.filter { s in
                                                switch s.type {
                                                case .dam: return methylationDam
                                                case .dcm: return methylationDcm
                                                case .cpg: return methylationCpG
                                                }
                                            }
                                            if !activeSens.isEmpty {
                                                let blocked = activeSens.contains(where: { $0.effect == .blocked })
                                                let required = activeSens.contains(where: { $0.effect == .required })
                                                Text(MethylationChecker.warningText(activeSens.map { MethylationWarning(type: $0.type, effect: $0.effect) }))
                                                    .font(.system(size: 9))
                                                    .foregroundColor(required ? .blue : (blocked ? .red : .orange))
                                            }
                                        }
                                    }
                                }
                                .toggleStyle(.checkbox)
                                .padding(.horizontal, 4)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .contextHelp("vcutter.enzymeList")
            .padding(.horizontal, 10).padding(.top, 6)
            
            Spacer(minLength: 8)
            
            // Run button
            HStack {
                Spacer()
                Button(action: runDigest) {
                    Text("Run Digest")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(selectedSequences.isEmpty || selectedEnzymes.isEmpty)
                .contextHelp("vcutter.runDigest")
                Spacer()
            }
            .padding(.horizontal, 10).padding(.bottom, 10)
        }
    }
    
    
    // MARK: - Gel Panel
    
    private var gelPanel: some View {
        let seqs = selectedSequences
        return VStack(spacing: 0) {
            // Header with sequence name(s) and action buttons
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Virtual Gel Electrophoresis")
                        .font(.headline)
                    if seqs.count == 1, let seq = seqs.first {
                        Text("\(seq.name)  (\(seq.length) bp, \(seq.isCircular ? "circular" : "linear"))")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    } else if seqs.count > 1 {
                        Text("\(seqs.count) sequences: \(seqs.map { $0.name }.joined(separator: ", "))")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                
                // Home — return to sequence editor
                if !seqs.isEmpty {
                    Button(action: goHome) {
                        Label("Home", systemImage: "house")
                    }
                    .controlSize(.small)
                    .help(selectedSequenceIDs.count > 1 ? "Bring all selected sequence windows to front" : "Return to sequence editor window")
                    .contextHelp("vcutter.home")
                }
                
                if !lanes.isEmpty {
                    Button("Copy Fragment Sizes") {
                        copyFragmentTable()
                    }
                    .controlSize(.small)
                    .contextHelp("vcutter.copyFragmentSizes")
                    
                    Button(action: copyGelToClipboard) {
                        Label("Copy Image", systemImage: "doc.on.clipboard")
                    }
                    .controlSize(.small)
                    .contextHelp("vcutter.copyImage")
                    
                    Button(action: { saveGelAs(format: .pdf) }) {
                        Label("PDF", systemImage: "doc")
                    }
                    .controlSize(.small)
                    .contextHelp("vcutter.savePDF")
                    
                    Button(action: { saveGelAs(format: .png) }) {
                        Label("PNG", systemImage: "photo")
                    }
                    .controlSize(.small)
                    .contextHelp("vcutter.savePNG")
                    
                    Button(action: printGel) {
                        Label("Print", systemImage: "printer")
                    }
                    .controlSize(.small)
                    .contextHelp("vcutter.printGel")
                    
                    Button(action: { printLandscape.toggle() }) {
                        Label(printLandscape ? "Landscape" : "Portrait",
                              systemImage: printLandscape ? "rectangle" : "rectangle.portrait")
                            .foregroundColor(printLandscape ? .accentColor : .orange)
                    }
                    .controlSize(.small)
                    .contextHelp("vcutter.printOrientation")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            
            Divider()
            
            if lanes.isEmpty {
                Spacer()
                Text("Select enzymes and click Run Digest")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                // Gel image + scrollable fragment table
                GeometryReader { geometry in
                    let gelWidth = geometry.size.width - 40
                    let fragmentTableHeight: CGFloat = min(160, geometry.size.height * 0.28)
                    let gelHeight = geometry.size.height - fragmentTableHeight - 10
                    
                    VStack(spacing: 0) {
                        gelView(width: gelWidth, height: max(200, gelHeight))
                            .padding(.horizontal, 20)
                            .padding(.top, 6)
                        
                        Divider()
                        
                        // Fragment table below gel — scrollable
                        ScrollView {
                            fragmentTable
                        }
                        .frame(height: fragmentTableHeight)
                    }
                }
            }
        }
        .background(Color(.controlBackgroundColor))
    }
    
    
    // MARK: - Gel Drawing
    
    private func gelView(width: CGFloat, height: CGFloat) -> some View {
        let allLanes = buildAllLanes()
        let laneCount = allLanes.count
        let laneWidth = min(80, width / CGFloat(laneCount + 1))
        let totalLanesWidth = laneWidth * CGFloat(laneCount)
        let markerLabelSpace: CGFloat = 80
        let leftOffset = markerLabelSpace + (width - markerLabelSpace - totalLanesWidth) / 2
        
        let allFragments = selectedMarker.fragments + lanes.flatMap { $0.fragments }
        let minBP = max(50, (allFragments.min() ?? 100) / 2)
        let maxBP = max(25000, (allFragments.max() ?? 23130) * 2)
        let logMin = log10(Double(minBP))
        let logMax = log10(Double(maxBP))
        
        let headerHeight: CGFloat = (showEnzymeInLabel && laneLabelStyle != .full) ? 62 : 36
        let wellHeight: CGFloat = 12
        let topMargin: CGFloat = headerHeight + wellHeight + 8
        let bottomMargin: CGFloat = 16
        let gelRunHeight = height - topMargin - bottomMargin
        
        func yForBP(_ bp: Int) -> CGFloat {
            let logBP = log10(Double(max(bp, 1)))
            let fraction = (logMax - logBP) / (logMax - logMin)
            return topMargin + CGFloat(fraction) * gelRunHeight
        }
        
        // Pre-compute all band positions for the tooltip overlay
        var bandInfos: [GelBandInfo] = []
        for i in 0..<laneCount {
            let lane = allLanes[i]
            let x = leftOffset + laneWidth * (CGFloat(i) + 0.5)
            let bandWidth = laneWidth * 0.6
            let frags = lane.enzymes.isEmpty ? lane.fragments : visibleFragments(for: lane)
            for j in 0..<frags.count {
                let bp = frags[j]
                let y = yForBP(bp)
                let rect = CGRect(x: x - bandWidth / 2 - 5, y: y - 8, width: bandWidth + 10, height: 16)
                bandInfos.append(GelBandInfo(rect: rect, label: lane.label, size: bp))
            }
        }
        
        return ZStack {
            // Gel background
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
            
            // Lane headers
            ForEach(0..<laneCount, id: \.self) { i in
                let lane = allLanes[i]
                let x = leftOffset + laneWidth * (CGFloat(i) + 0.5)
                let isMarker = lane.enzymes.isEmpty
                let useShort = !isMarker && laneLabelStyle != .full
                let code = isMarker ? "M" : shortLabel(forLaneIndex: i - 1)
                let labelCount = (laneLabelStyle == .full && !isMarker) ? lane.enzymes.count : 1
                let fontSize: CGFloat = labelCount > 2 ? min(9, laneWidth * 0.13) :
                                        labelCount > 1 ? min(10, laneWidth * 0.14) :
                                        min(13, laneWidth * 0.18)
                
                if useShort && showEnzymeInLabel {
                    // Two-line header: code (large) + enzyme name (small)
                    let enzymeLine = lane.enzymes.joined(separator: "+")
                    let enzyFontSize: CGFloat = min(11, laneWidth * 0.16)
                    VStack(spacing: 1) {
                        Text(code)
                            .font(.system(size: min(14, laneWidth * 0.20), weight: .bold))
                            .foregroundColor(.black.opacity(0.85))
                        Text(enzymeLine)
                            .font(.system(size: enzyFontSize))
                            .foregroundColor(.black.opacity(0.7))
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                            .multilineTextAlignment(.center)
                    }
                    .frame(width: laneWidth + 6, height: headerHeight)
                    .position(x: x, y: headerHeight / 2 + 2)
                } else {
                    Text(code)
                        .font(.system(size: fontSize, weight: .semibold))
                        .foregroundColor(.black.opacity(0.8))
                        .lineLimit(3)
                        .minimumScaleFactor(0.6)
                        .multilineTextAlignment(.center)
                        .frame(width: laneWidth + 6, height: headerHeight)
                        .position(x: x, y: headerHeight / 2 + 2)
                }
            }
            
            // Wells
            ForEach(0..<laneCount, id: \.self) { i in
                let x = leftOffset + laneWidth * (CGFloat(i) + 0.5)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.25))
                    .frame(width: laneWidth * 0.65, height: wellHeight)
                    .position(x: x, y: headerHeight + wellHeight / 2 + 2)
            }
            
            // Draw bands using Canvas (reliable, no hit-testing issues)
            Canvas { context, size in
                for i in 0..<laneCount {
                    let lane = allLanes[i]
                    let x = leftOffset + laneWidth * (CGFloat(i) + 0.5)
                    let bandWidth = laneWidth * 0.6
                    let frags = lane.enzymes.isEmpty ? lane.fragments : visibleFragments(for: lane)
                    
                    for j in 0..<frags.count {
                        let bp = frags[j]
                        let y = yForBP(bp)
                        let maxFrag = Double(frags.max() ?? 1)
                        let relIntensity = 0.7 + 0.3 * (Double(bp) / maxFrag)
                        let isMarker = lane.enzymes.isEmpty
                        let brightness = isMarker ? relIntensity * 0.85 : relIntensity
                        
                        let bandRect = CGRect(x: x - bandWidth / 2, y: y - 1.5, width: bandWidth, height: 3)
                        let color = Color(red: 0.85 * brightness, green: 0.12 * brightness, blue: 0.06 * brightness)
                        context.fill(Path(roundedRect: bandRect, cornerRadius: 1), with: .color(color))
                    }
                }
            }
            
            // Marker size labels
            ForEach(0..<laneCount, id: \.self) { i in
                let lane = allLanes[i]
                if lane.enzymes.isEmpty {
                    let x = leftOffset + laneWidth * (CGFloat(i) + 0.5)
                    ForEach(0..<lane.fragments.count, id: \.self) { j in
                        let bp = lane.fragments[j]
                        let y = yForBP(bp)
                        Text(formatBP(bp))
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.black)
                            .frame(width: 70, alignment: .trailing)
                            .position(x: x - laneWidth * 0.35 - 40, y: y)
                    }
                }
            }
            
            // Band size labels (optional toggle)
            if showBandLabels {
                ForEach(0..<laneCount, id: \.self) { i in
                    let lane = allLanes[i]
                    if !lane.enzymes.isEmpty {
                        let x = leftOffset + laneWidth * (CGFloat(i) + 0.5)
                        let frags = visibleFragments(for: lane)
                        ForEach(0..<frags.count, id: \.self) { j in
                            let bp = frags[j]
                            let y = yForBP(bp)
                            Text(formatBP(bp))
                                .font(.system(size: min(10, laneWidth * 0.14), design: .monospaced))
                                .foregroundColor(.black.opacity(0.7))
                                .frame(width: 55, alignment: .leading)
                                .position(x: x + laneWidth * 0.35 + 30, y: y)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
            
            // Mouse tracking overlay for band tooltips
            GelMouseTracker(bandInfos: bandInfos, hoveredText: $hoveredBandText, hoverPoint: $hoverPoint)
            
            // Floating tooltip label
            if !hoveredBandText.isEmpty {
                Text(hoveredBandText)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white)
                            .shadow(color: .black.opacity(0.2), radius: 3, x: 0, y: 1)
                    )
                    .position(x: hoverPoint.x, y: max(20, hoverPoint.y - 20))
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: height)
        .clipped()
    }
    
    
    
    // MARK: - Fragment Table (vertical layout)
    
    private var fragmentTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Skipped enzymes warning
            if !skippedEnzymes.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 11))
                    Text("Excluded from combined digest (no sites or methylation-blocked): \(skippedEnzymes.joined(separator: ", "))")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                }
            }
            
            ForEach(Array(lanes.enumerated()), id: \.element.id) { index, lane in
                HStack(alignment: .center, spacing: 6) {
                    
                    // ◀ ▶ move buttons
                    HStack(spacing: 3) {
                        Button(action: { moveLane(at: index, by: -1) }) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12, weight: .bold))
                                .frame(width: 22, height: 22)
                                .background(Color.accentColor.opacity(0.12))
                                .cornerRadius(5)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(index == 0 ? Color.secondary.opacity(0.3) : Color.accentColor)
                        .disabled(index == 0)
                        .help("Move lane left")
                        
                        Button(action: { moveLane(at: index, by: 1) }) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                                .frame(width: 22, height: 22)
                                .background(Color.accentColor.opacity(0.12))
                                .cornerRadius(5)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(index == lanes.count - 1 ? Color.secondary.opacity(0.3) : Color.accentColor)
                        .disabled(index == lanes.count - 1)
                        .help("Move lane right")
                    }
                    .contextHelp("vcutter.laneMove")
                    
                    // Short label badge — shown when using numbers or letters
                    if laneLabelStyle != .full {
                        Text(shortLabel(forLaneIndex: index))
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .frame(width: 24, height: 22)
                            .background(Color.secondary)
                            .cornerRadius(4)
                    }
                    // Lane label + pencil popover
                    HStack(spacing: 4) {
                        Text(lane.label)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .frame(width: 150, alignment: .trailing)
                        Button(action: { startEditingLabel(for: lane) }) {
                            Image(systemName: "pencil")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white)
                                .frame(width: 20, height: 20)
                                .background(Color.accentColor)
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                        .help("Rename this lane")
                        .contextHelp("vcutter.laneRename")
                        .popover(isPresented: Binding(
                            get: { editingLaneID == lane.id },
                            set: { if !$0 { cancelLabelEdit() } }
                        ), arrowEdge: .trailing) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Rename Lane")
                                    .font(.headline)
                                TextField("Lane name", text: $editingLabel)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 220)
                                    .onSubmit { commitLabelEdit(for: lane.id) }
                                    .onExitCommand { cancelLabelEdit() }
                                HStack(spacing: 8) {
                                    Spacer()
                                    Button("Cancel") { cancelLabelEdit() }
                                        .keyboardShortcut(.escape)
                                    Button("OK") { commitLabelEdit(for: lane.id) }
                                        .buttonStyle(.borderedProminent)
                                        .keyboardShortcut(.return)
                                }
                            }
                            .padding(14)
                            .frame(width: 260)
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(lane.fragments.count) fragment\(lane.fragments.count == 1 ? "" : "s"): \(lane.fragments.map { "\(formatBP($0))" }.joined(separator: ", "))")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.primary)
                        
                        let laneWarnings = methylationWarningsForLane(lane)
                        if !laneWarnings.isEmpty {
                            Text(laneWarnings)
                                .font(.system(size: 11))
                                .foregroundColor(.red)
                        }
                        
                        // Co-migration warning
                        if let coMigWarn = coMigratingWarning(for: lane) {
                            Text(coMigWarn)
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                        }
                        
                        // Sanity check: fragment sizes should sum to sequence length
                        if lane.expectedLength > 0 {
                            let fragSum = lane.fragments.reduce(0, +)
                            if fragSum != lane.expectedLength {
                                Text("⚠ Fragment sum (\(formatBP(fragSum))) ≠ sequence length (\(formatBP(lane.expectedLength)))")
                                    .font(.system(size: 11))
                                    .foregroundColor(.red)
                            }
                        }
                    }
                }
            }
            
            // Report buttons + Undo
            HStack(spacing: 8) {
                if previousLanes != nil {
                    Button(action: undoLaneChange) {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Undo last move or rename")
                    .contextHelp("vcutter.laneUndo")
                }
                Spacer()
                Button("Copy Report") { copyReport() }
                    .controlSize(.small)
                    .contextHelp("vcutter.copyReport")
                Button("Save Report…") { saveReport() }
                    .controlSize(.small)
                    .contextHelp("vcutter.saveReport")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
    
    /// Check if any enzymes in a lane are affected by active methylation settings
    private func methylationWarningsForLane(_ lane: DigestLane) -> String {
        var warnings: [String] = []
        for enzymeName in lane.enzymes {
            let sens = MethylationSensitivityDB.sensitivities(for: enzymeName)
            let active = sens.filter { s in
                switch s.type {
                case .dam: return methylationDam
                case .dcm: return methylationDcm
                case .cpg: return methylationCpG
                }
            }
            if !active.isEmpty {
                let warnText = MethylationChecker.warningText(active.map { MethylationWarning(type: $0.type, effect: $0.effect) })
                warnings.append("\(enzymeName): \(warnText)")
            }
        }
        return warnings.joined(separator: "  ")
    }
    
    
    // MARK: - Digest Logic
    
    private func runDigest() {
        lanes.removeAll()
        skippedEnzymes.removeAll()
        digestReport = ""
        
        let sequences = selectedSequences
        guard !sequences.isEmpty else { return }
        let multiSeq = sequences.count > 1
        
        for sequence in sequences {
            let seqStr = sequence.sequence.uppercased()
            let seqLen = seqStr.count
            let isCircular = sequence.isCircular
            guard seqLen > 0 else { continue }
            
            // Find cut positions for each selected enzyme
            var enzymePositions: [String: [Int]] = [:]
            var enzymeBlocked: Set<String> = []  // fully blocked by methylation
            
            for enzymeName in selectedEnzymes.sorted() {
                if let enzyme = enzymeDB.enzymes.first(where: { $0.name == enzymeName }) {
                    let sites = enzyme.findCutSites(in: seqStr, circular: isCircular)
                    let positions = sites.map { $0.position + enzyme.cutPosition5Prime }
                        .map { pos in ((pos % seqLen) + seqLen) % seqLen }
                    let uniquePositions = Array(Set(positions)).sorted()
                    
                    // Check if ALL sites for this enzyme are methylation-blocked
                    if !uniquePositions.isEmpty {
                        let allBlocked = sites.allSatisfy { site in
                            let warnings = MethylationChecker.checkSite(
                                enzymeName: enzymeName,
                                sitePosition: site.position,
                                recognitionSite: enzyme.recognitionSite,
                                sequence: seqStr,
                                circular: isCircular,
                                activeDam: methylationDam,
                                activeDcm: methylationDcm,
                                activeCpG: methylationCpG
                            )
                            return MethylationChecker.isCutBlocked(warnings)
                        }
                        if allBlocked { enzymeBlocked.insert(enzymeName) }
                    }
                    
                    enzymePositions[enzymeName] = uniquePositions
                }
            }
            
            // Lane label prefix: include sequence name when digesting multiple sequences
            let prefix = multiSeq ? "\(sequence.name) / " : ""
            
            // Single digests — always show a lane for each selected enzyme
            if showSingleDigests {
                for enzymeName in selectedEnzymes.sorted() {
                    let positions = enzymePositions[enzymeName] ?? []
                    if positions.isEmpty {
                        lanes.append(DigestLane(
                            label: "\(prefix)\(enzymeName) (uncut)",
                            enzymes: [enzymeName],
                            fragments: [seqLen],
                            sequenceName: sequence.name,
                            expectedLength: seqLen
                        ))
                    } else if enzymeBlocked.contains(enzymeName) {
                        lanes.append(DigestLane(
                            label: "\(prefix)\(enzymeName) (blocked)",
                            enzymes: [enzymeName],
                            fragments: [seqLen],
                            sequenceName: sequence.name,
                            expectedLength: seqLen
                        ))
                    } else {
                        let fragments = computeFragments(cutPositions: positions, seqLen: seqLen, circular: isCircular)
                        lanes.append(DigestLane(
                            label: "\(prefix)\(enzymeName)",
                            enzymes: [enzymeName],
                            fragments: fragments.sorted(by: >),
                            sequenceName: sequence.name,
                            expectedLength: seqLen
                        ))
                    }
                }
            }
            
            // Combined digest — exclude enzymes that don't cut or are blocked
            if showCombinedDigest && selectedEnzymes.count > 1 {
                var activeCutters: [String] = []
                var combinedPositions: [Int] = []
                var newlySkipped: [String] = []
                
                for enzymeName in selectedEnzymes.sorted() {
                    let positions = enzymePositions[enzymeName] ?? []
                    if positions.isEmpty || enzymeBlocked.contains(enzymeName) {
                        newlySkipped.append(enzymeName)
                    } else {
                        activeCutters.append(enzymeName)
                        combinedPositions.append(contentsOf: positions)
                    }
                }
                
                // Accumulate skipped enzymes without duplicates
                for e in newlySkipped where !skippedEnzymes.contains(e) {
                    skippedEnzymes.append(e)
                }
                
                let uniquePositions = Array(Set(combinedPositions)).sorted()
                if activeCutters.isEmpty {
                    lanes.append(DigestLane(
                        label: "\(prefix)Combined (no cutters)",
                        enzymes: [],
                        fragments: [seqLen],
                        sequenceName: sequence.name,
                        expectedLength: seqLen
                    ))
                } else {
                    let fragments = computeFragments(cutPositions: uniquePositions, seqLen: seqLen, circular: isCircular)
                    let label = "\(prefix)\(activeCutters.joined(separator: " + "))"
                    lanes.append(DigestLane(
                        label: label,
                        enzymes: activeCutters,
                        fragments: fragments.sorted(by: >),
                        sequenceName: sequence.name,
                        expectedLength: seqLen
                    ))
                }
            }
        }
        
        // Build text report
        buildReport()
    }
    
    private func computeFragments(cutPositions: [Int], seqLen: Int, circular: Bool) -> [Int] {
        guard !cutPositions.isEmpty else { return [seqLen] }
        
        let sorted = cutPositions.sorted()
        var fragments: [Int] = []
        
        if circular {
            // Circular: fragments between consecutive cuts, wrapping around
            for i in 0..<sorted.count {
                let next = (i + 1) % sorted.count
                var size: Int
                if next > i {
                    size = sorted[next] - sorted[i]
                } else {
                    // Wraps around origin
                    size = (seqLen - sorted[i]) + sorted[next]
                }
                if size > 0 { fragments.append(size) }
            }
        } else {
            // Linear: fragment before first cut, between cuts, after last cut
            if sorted[0] > 0 {
                fragments.append(sorted[0])
            }
            for i in 0..<sorted.count - 1 {
                let size = sorted[i + 1] - sorted[i]
                if size > 0 { fragments.append(size) }
            }
            if sorted.last! < seqLen {
                fragments.append(seqLen - sorted.last!)
            }
        }
        
        return fragments.filter { $0 > 0 }
    }
    
    
    // MARK: - Build All Lanes (marker + digest lanes)
    
    private func buildAllLanes() -> [DigestLane] {
        let markerLane = DigestLane(
            label: selectedMarker.name,
            enzymes: [],
            fragments: selectedMarker.fragments
        )
        return [markerLane] + lanes
    }
    
    
    // MARK: - Report Generation
    
    private func buildReport() {
        let sequences = selectedSequences
        
        var lines: [String] = []
        lines.append("Restriction Digest Report")
        
        if sequences.count == 1, let seq = sequences.first {
            lines.append("Template: \(seq.name) (\(seq.length) bp, \(seq.isCircular ? "circular" : "linear"))")
        } else if sequences.count > 1 {
            lines.append("Templates:")
            for seq in sequences {
                lines.append("  • \(seq.name) (\(seq.length) bp, \(seq.isCircular ? "circular" : "linear"))")
            }
        }
        lines.append("Marker: \(selectedMarker.name)")
        lines.append(String(repeating: "─", count: 60))
        lines.append("")
        
        for lane in lanes {
            lines.append("\(lane.label)")
            lines.append("  \(lane.fragments.count) fragment\(lane.fragments.count == 1 ? "" : "s")")
            for (i, bp) in lane.fragments.enumerated() {
                lines.append("  \(i + 1). \(bp) bp  (\(formatBP(bp)))")
            }
            let laneWarnings = methylationWarningsForLane(lane)
            if !laneWarnings.isEmpty {
                lines.append("  ⚠ Methylation: \(laneWarnings)")
            }
            lines.append("")
        }
        
        if !skippedEnzymes.isEmpty {
            lines.append("Excluded from combined digest:")
            for enz in skippedEnzymes {
                lines.append("  \(enz) — no sites or methylation-blocked")
            }
            lines.append("")
        }
        
        var methStatus: [String] = []
        if methylationDam { methStatus.append("Dam+") } else { methStatus.append("Dam−") }
        if methylationDcm { methStatus.append("Dcm+") } else { methStatus.append("Dcm−") }
        if methylationCpG { methStatus.append("CpG+") } else { methStatus.append("CpG−") }
        lines.append("Methylation: \(methStatus.joined(separator: ", "))")
        lines.append("Generated by Cloner 64")
        
        digestReport = lines.joined(separator: "\n")
    }
    
    private func copyReport() {
        if digestReport.isEmpty { buildReport() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(digestReport, forType: .string)
    }
    
    private func saveReport() {
        if digestReport.isEmpty { buildReport() }
        let seqs = selectedSequences
        let baseName: String
        if seqs.count == 1 {
            baseName = (seqs.first?.name ?? "digest").replacingOccurrences(of: " ", with: "_")
        } else {
            baseName = "multi_digest"
        }
        
        let panel = NSSavePanel()
        panel.title = "Save Digest Report"
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(baseName)_digest_report.txt"
        
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? digestReport.write(to: url, atomically: true, encoding: .utf8)
    }
    
    
    // MARK: - Helpers
    
    /// Returns the display label for a digest lane (not the marker) based on current style.
    private func shortLabel(forLaneIndex index: Int) -> String {
        switch laneLabelStyle {
        case .full:
            return index < lanes.count ? lanes[index].label : ""
        case .numbers:
            return "\(index + 1)"
        case .letters:
            let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
            guard index < alphabet.count else { return "\(index + 1)" }
            return String(alphabet[alphabet.index(alphabet.startIndex, offsetBy: index)])
        }
    }
    
    private func formatBP(_ bp: Int) -> String {
        if bp >= 1000 {
            let kb = Double(bp) / 1000.0
            if kb == Double(Int(kb)) {
                return "\(Int(kb)) kb"
            }
            return String(format: "%.1f kb", kb)
        }
        return "\(bp)"
    }
    
    private func copyFragmentTable() {
        var text = ""
        for lane in lanes {
            text += "\(lane.label): \(lane.fragments.map { "\($0) bp" }.joined(separator: ", "))\n"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    
    
    // MARK: - Display Helpers
    
    /// Returns only the fragments at or above the current minimum size filter.
    private func visibleFragments(for lane: DigestLane) -> [Int] {
        let threshold = Int(minFragmentBP)
        guard threshold > 0 else { return lane.fragments }
        return lane.fragments.filter { $0 >= threshold }
    }
    
    /// Returns a warning string if two or more fragments in this lane are so close
    /// in size (within 5%) that they would likely appear as a single band on a real gel.
    private func coMigratingWarning(for lane: DigestLane) -> String? {
        let frags = visibleFragments(for: lane).sorted(by: >)
        guard frags.count > 1 else { return nil }
        var visibleCount = 0
        var i = 0
        while i < frags.count {
            visibleCount += 1
            var j = i + 1
            while j < frags.count &&
                  Double(abs(frags[j] - frags[i])) / Double(frags[i]) < 0.05 {
                j += 1
            }
            i = j
        }
        let hidden = frags.count - visibleCount
        guard hidden > 0 else { return nil }
        return "⚠ \(hidden) co-migrating fragment\(hidden > 1 ? "s" : "") — \(visibleCount) visible band\(visibleCount != 1 ? "s" : "") expected"
    }
    
    /// Copy the rendered gel image to the system clipboard.
    private func copyGelToClipboard() {
        guard let image = renderGelImage() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }
    
    
    // MARK: - Lane Reordering & Label Editing
    
    private func moveLane(at index: Int, by offset: Int) {
        let newIndex = index + offset
        guard newIndex >= 0 && newIndex < lanes.count else { return }
        previousLanes = lanes          // save for undo
        lanes.swapAt(index, newIndex)
    }
    
    private func startEditingLabel(for lane: DigestLane) {
        editingLaneID = lane.id
        editingLabel = lane.label
    }
    
    private func commitLabelEdit(for id: UUID) {
        let trimmed = editingLabel.trimmingCharacters(in: .whitespaces)
        if let i = lanes.firstIndex(where: { $0.id == id }), !trimmed.isEmpty {
            previousLanes = lanes      // save for undo
            lanes[i].label = trimmed
        }
        editingLaneID = nil
        editingLabel = ""
    }
    
    private func cancelLabelEdit() {
        editingLaneID = nil
        editingLabel = ""
    }
    
    private func undoLaneChange() {
        if let saved = previousLanes {
            lanes = saved
            previousLanes = nil
        }
    }
    
    
    // MARK: - Home
    
    private func goHome() {
        for seq in selectedSequences {
            for window in NSApp.windows where window != NSApp.keyWindow {
                let title = window.title
                if title == seq.name
                    || (seq.name.isEmpty && (title == "Untitled Sequence" || title == "Untitled"))
                {
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    
    // MARK: - Save / Print
    
    private enum ImageFormat { case pdf, png }
    
    /// Render the gel to an NSImage via cacheDisplay (the only reliable
    /// way to capture SwiftUI content from an NSHostingView).
    private func renderGelImage() -> NSImage? {
        let imageWidth: CGFloat = 860
        let sequences = selectedSequences
        
        let templateDisplay: String
        if sequences.count == 1, let seq = sequences.first {
            templateDisplay = "\(seq.name) (\(seq.length) bp, \(seq.isCircular ? "circular" : "linear"))"
        } else if sequences.count > 1 {
            templateDisplay = "\(sequences.count) sequences: \(sequences.map { $0.name }.joined(separator: ", "))"
        } else {
            templateDisplay = "Unknown"
        }
        
        let titleHeight: CGFloat = 50
        let gelHeight: CGFloat = 450
        let fragmentInfoHeight: CGFloat = CGFloat(lanes.count) * 20 + 40
        let imageHeight: CGFloat = titleHeight + gelHeight + fragmentInfoHeight + 20
        
        let gelContent = gelView(width: imageWidth - 60, height: gelHeight)
        
        let wrapped = VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Virtual Restriction Digest")
                    .font(.system(size: 16, weight: .bold))
                Text(templateDisplay)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 6)
            
            gelContent
            
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(height: 1)
                .padding(.horizontal, 20)
                .padding(.top, 8)
            
            VStack(alignment: .leading, spacing: 6) {
                ForEach(lanes) { lane in
                    HStack(alignment: .top, spacing: 8) {
                        Text(lane.label)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .frame(width: 140, alignment: .trailing)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(lane.fragments.count) fragment\(lane.fragments.count == 1 ? "" : "s"): \(lane.fragments.map { formatBP($0) }.joined(separator: ", "))")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.primary)
                            
                            let laneWarnings = methylationWarningsForLane(lane)
                            if !laneWarnings.isEmpty {
                                Text(laneWarnings)
                                    .font(.system(size: 11))
                                    .foregroundColor(.red)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            
            HStack {
                Text("Generated by Cloner 64")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
                Text("Marker: \(selectedMarker.name)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .frame(width: imageWidth, height: imageHeight)
        .background(Color.white)
        
        let hostingView = NSHostingView(rootView: wrapped)
        hostingView.frame = NSRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        
        guard let bitmapRep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else { return nil }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmapRep)
        
        let image = NSImage(size: NSSize(width: imageWidth, height: imageHeight))
        image.addRepresentation(bitmapRep)
        return image
    }
    
    private func saveGelAs(format: ImageFormat) {
        let seqs = selectedSequences
        let baseName: String
        if seqs.count == 1 {
            baseName = (seqs.first?.name ?? "virtual_gel").replacingOccurrences(of: " ", with: "_")
        } else {
            baseName = "multi_virtual_gel"
        }
        
        let panel = NSSavePanel()
        panel.title = "Save Gel Image"
        panel.canCreateDirectories = true
        
        switch format {
        case .pdf:
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = "\(baseName)_digest.pdf"
        case .png:
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "\(baseName)_digest.png"
        }
        
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let image = renderGelImage() else { return }
        
        switch format {
        case .pdf:
            let pdfData = NSMutableData()
            var mediaBox = CGRect(origin: .zero, size: image.size)
            guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return }
            
            context.beginPDFPage(nil)
            if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                context.draw(cgImage, in: mediaBox)
            }
            context.endPDFPage()
            context.closePDF()
            
            pdfData.write(to: url, atomically: true)
            
        case .png:
            if let tiffData = image.tiffRepresentation,
               let bitmapRep = NSBitmapImageRep(data: tiffData),
               let pngData = bitmapRep.representation(using: .png, properties: [:]) {
                try? pngData.write(to: url)
            }
        }
    }
    
    private func printGel() {
        guard let image = renderGelImage() else { return }
        
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: image.size))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyDown
        
        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .fit
        printInfo.isHorizontallyCentered = true
        printInfo.isVerticallyCentered = true
        printInfo.orientation = printLandscape ? .landscape : .portrait
        let printOp = NSPrintOperation(view: imageView, printInfo: printInfo)
        printOp.showsPrintPanel = true
        printOp.showsProgressPanel = true
        printOp.run()
    }
}


// MARK: - Gel Band Info

struct GelBandInfo {
    let rect: CGRect
    let label: String
    let size: Int
}


// MARK: - Mouse Tracking for Gel Tooltips

struct GelMouseTracker: NSViewRepresentable {
    let bandInfos: [GelBandInfo]
    @Binding var hoveredText: String
    @Binding var hoverPoint: CGPoint
    
    func makeNSView(context: Context) -> GelTrackingNSView {
        let view = GelTrackingNSView()
        view.onMouseMoved = { point in
            checkBandHit(at: point)
        }
        view.onMouseExited = {
            DispatchQueue.main.async {
                hoveredText = ""
            }
        }
        view.bandInfos = bandInfos
        return view
    }
    
    func updateNSView(_ nsView: GelTrackingNSView, context: Context) {
        nsView.bandInfos = bandInfos
        nsView.onMouseMoved = { point in
            checkBandHit(at: point)
        }
        nsView.onMouseExited = {
            DispatchQueue.main.async {
                hoveredText = ""
            }
        }
    }
    
    private func checkBandHit(at point: CGPoint) {
        for band in bandInfos {
            if band.rect.contains(point) {
                let text: String
                if band.size >= 1000 {
                    text = "\(band.label): \(String(format: "%.1f", Double(band.size) / 1000.0)) kb (\(band.size) bp)"
                } else {
                    text = "\(band.label): \(band.size) bp"
                }
                DispatchQueue.main.async {
                    hoveredText = text
                    hoverPoint = point
                }
                return
            }
        }
        DispatchQueue.main.async {
            hoveredText = ""
        }
    }
}

class GelTrackingNSView: NSView {
    var bandInfos: [GelBandInfo] = []
    var onMouseMoved: ((CGPoint) -> Void)?
    var onMouseExited: (() -> Void)?
    private var trackingArea: NSTrackingArea?
    
    override var isFlipped: Bool { true }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }
    
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Flip Y since isFlipped = true
        onMouseMoved?(point)
    }
    
    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }
}

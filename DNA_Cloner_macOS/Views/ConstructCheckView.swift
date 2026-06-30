//
//  ConstructCheckView.swift
//  Cloner 64
//
//  Standalone "Check Construct" window.  Operates on any open DNA sequence.
//  The user can optionally select a feature or ORF to focus the analysis,
//  toggle orientation checking, or switch to Comparison Mode to find digests
//  that distinguish two plasmids (e.g. parent vector vs recombinant).
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers


// MARK: - View

struct ConstructCheckView: View {
    @ObservedObject var sequenceManager: SequenceManager

    /// The sequence the window opened with. Fallback if the chosen primary
    /// isn't found in the manager's list.
    private let initialSequence: DNASequence

    /// Which open sequence is currently being checked. Defaults to the one the
    /// window opened with; changeable via the picker or the Browse button.
    @State private var primaryID: UUID

    /// True while a Browse-opened file is loading, so it can be auto-selected
    /// as the primary once it appears in the manager's list.
    @State private var pendingBrowseSelect: Bool = false

    /// The active primary sequence, resolved from the current selection.
    private var sequence: DNASequence {
        sequenceManager.sequences.first { $0.id == primaryID } ?? initialSequence
    }
    
    // Single-sequence mode state
    @State private var regions: [CheckRegion] = []
    @State private var selectedRegionID: UUID?
    @State private var orientationMatters: Bool = false
    @State private var includeDoubleDigests: Bool = false
    @State private var useMyEnzymesOnly: Bool = false
    
    // Comparison mode state
    @State private var comparisonMode: Bool = false
    @State private var comparisonSequenceID: UUID?
    
    // Methylation sensitivity (shared with rest of app via AppStorage)
    @AppStorage("methylation_dam") private var methylationDam: Bool = true
    @AppStorage("methylation_dcm") private var methylationDcm: Bool = true
    @AppStorage("methylation_cpg") private var methylationCpG: Bool = false
    
    // Output state
    @State private var report: String = ""
    @State private var hasAnalysed: Bool = false
    
    private let analyzer = ConstructCheckAnalyzer()
    private let enzDB = RestrictionEnzymeDatabase.shared
    
    private var comparisonSequence: DNASequence? {
        guard let id = comparisonSequenceID else { return nil }
        return sequenceManager.sequences.first { $0.id == id }
    }
    
    private var otherSequences: [DNASequence] {
        sequenceManager.sequences.filter { $0.id != sequence.id }
    }
    
    private var canAnalyse: Bool {
        if comparisonMode { return comparisonSequence != nil }
        return true
    }
    
    init(sequence: DNASequence, sequenceManager: SequenceManager) {
        self.initialSequence = sequence
        self._sequenceManager = ObservedObject(wrappedValue: sequenceManager)
        self._primaryID = State(initialValue: sequence.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            
            // ── Header ──
            VStack(alignment: .leading, spacing: 6) {
                Text("Check Construct")
                    .font(.headline)
                HStack(spacing: 8) {
                    Text("Sequence to check:")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Picker("", selection: $primaryID) {
                        ForEach(sequenceManager.sequences) { seq in
                            Text("\(seq.name)  (\(seq.sequence.count) bp, \(seq.isCircular ? "circular" : "linear"))")
                                .tag(seq.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 360)
                    .contextHelp("check.primarySequence")
                    Button("Browse…") { browseForPrimary() }
                        .help("Open a file from disk and check it. The file also opens as a normal sequence window.")
                        .contextHelp("check.primaryBrowse")
                }
            }
            
            // ── Comparison mode toggle ──
            Toggle(isOn: $comparisonMode) {
                Text("Compare with another plasmid")
                    .font(.system(size: 13))
            }
            .toggleStyle(.checkbox)
            .help("Find digests that distinguish two plasmids, e.g. a parent vector and its recombinant.")
            .contextHelp("check.comparePlasmids")
            
            // ── Comparison sequence picker ──
            if comparisonMode {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Sequence A (this window):")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Text(sequence.name)
                            .font(.system(size: 13, weight: .medium))
                        Text("\(sequence.sequence.count) bp, \(sequence.isCircular ? "circular" : "linear")")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(8)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(6)
                    
                    Image(systemName: "arrow.left.arrow.right")
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Sequence B (compare against):")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        if otherSequences.isEmpty {
                            Text("No other sequences open")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .italic(true)
                        } else {
                            Picker("", selection: $comparisonSequenceID) {
                                Text("Select a sequence…").tag(nil as UUID?)
                                ForEach(otherSequences) { seq in
                                    Text("\(seq.name) (\(seq.sequence.count) bp, \(seq.isCircular ? "circular" : "linear"))")
                                        .tag(seq.id as UUID?)
                                }
                            }
                            .labelsHidden()
                            .frame(minWidth: 280)
                        }
                    }
                    .padding(8)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(6)
                    
                    Spacer()
                }
                
                if otherSequences.isEmpty {
                    Text("Open a second sequence to use comparison mode.")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                }
            }
            
            // ── Region picker (single-sequence mode only) ──
            if !comparisonMode {
                HStack(spacing: 12) {
                    Text("Region to verify:")
                        .font(.system(size: 13))
                    
                    Picker("", selection: $selectedRegionID) {
                        Text("None — general fingerprint").tag(nil as UUID?)
                        
                        if !regions.isEmpty {
                            Divider()
                            let featureRegions = regions.filter {
                                if case .feature = $0.source { return true }; return false
                            }
                            if !featureRegions.isEmpty {
                                Section(header: Text("Features")) {
                                    ForEach(featureRegions) { r in
                                        Text(r.displayLabel).tag(r.id as UUID?)
                                    }
                                }
                            }
                            let orfRegions = regions.filter {
                                if case .orf = $0.source { return true }; return false
                            }
                            if !orfRegions.isEmpty {
                                Section(header: Text("ORFs")) {
                                    ForEach(orfRegions) { r in
                                        Text(r.displayLabel).tag(r.id as UUID?)
                                    }
                                }
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(minWidth: 300)
                }
            }
            
            // ── Options row ──
            HStack(spacing: 20) {
                if !comparisonMode {
                    Toggle(isOn: $orientationMatters) {
                        Text("Check orientation").font(.system(size: 13))
                    }
                    .toggleStyle(.checkbox)
                    .disabled(selectedRegionID == nil)
                    .help("Find digests that distinguish forward vs reverse orientation of the selected region.")
                    .contextHelp("check.orientationCheck")
                }
                
                Toggle(isOn: $includeDoubleDigests) {
                    Text("Include double digests").font(.system(size: 13))
                }
                .toggleStyle(.checkbox)
                .disabled(!comparisonMode && orientationMatters)
                
                Toggle(isOn: $useMyEnzymesOnly) {
                    Label("My enzymes only", systemImage: "star.fill").font(.system(size: 13))
                }
                .toggleStyle(.checkbox)
                .disabled(enzDB.myEnzymeNames.isEmpty)
                .help(enzDB.myEnzymeNames.isEmpty
                      ? "No enzymes marked — use Tools → Restriction Enzyme List to star enzymes"
                      : "Restrict to the \(enzDB.myEnzymeNames.count) enzymes in your freezer")
                .contextHelp("check.myEnzymesOnly")
                
                Spacer()
                
                Button("Analyse") { regenerateReport() }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canAnalyse)
            }
            
            // ── Mode hint ──
            if hasAnalysed {
                let hint: String = {
                    if comparisonMode {
                        return "→ comparison mode: \(sequence.name) vs \(comparisonSequence?.name ?? "?")"
                    } else if selectedRegionID == nil {
                        return "→ fingerprint mode: looking for distinctive gel patterns"
                    } else if orientationMatters {
                        return "→ orientation mode: looking for asymmetric cutters in the region"
                    } else {
                        return "→ presence mode: looking for digests that confirm the feature"
                    }
                }()
                Text(hint).font(.system(size: 11)).foregroundColor(.secondary)
            } else if comparisonMode && comparisonSequence == nil && !otherSequences.isEmpty {
                Text("→ Select Sequence B above, then click Analyse")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            
            // ── Report panel ──
            ScrollView {
                if report.isEmpty && !hasAnalysed {
                    VStack(spacing: 8) {
                        Spacer(minLength: 40)
                        if comparisonMode {
                            Text("Select a second sequence and click Analyse")
                                .font(.system(size: 13)).foregroundColor(.secondary)
                            Text("to find digests that distinguish the two plasmids.")
                                .font(.system(size: 13)).foregroundColor(.secondary)
                        } else {
                            Text("Select a region (optional) and click Analyse")
                                .font(.system(size: 13)).foregroundColor(.secondary)
                            Text("to get diagnostic digest recommendations.")
                                .font(.system(size: 13)).foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Text(report)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
            }
            .background(Color(NSColor.textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3), lineWidth: 1))
            
            // ── Action buttons ──
            HStack {
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                }
                .buttonStyle(.bordered).disabled(report.isEmpty)
                
                Button("Save…") {
                    let panel = NSSavePanel()
                    let name = comparisonMode
                        ? "\(sequence.name) vs \(comparisonSequence?.name ?? "B") — Check Construct.txt"
                        : "\(sequence.name) — Check Construct.txt"
                    panel.nameFieldStringValue = name
                    panel.allowedContentTypes = [.plainText]
                    if panel.runModal() == .OK, let url = panel.url {
                        try? report.write(to: url, atomically: true, encoding: .utf8)
                    }
                }
                .buttonStyle(.bordered).disabled(report.isEmpty)
                
                Button(action: printReport) { Label("Print", systemImage: "printer") }
                    .buttonStyle(.bordered).disabled(report.isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 700, minHeight: 560)
        .onAppear {
            refreshRegions()
        }
        .onChange(of: selectedRegionID) { newVal in
            if newVal == nil { orientationMatters = false }
        }
        .onChange(of: comparisonMode) { enabled in
            hasAnalysed = false
            report = ""
            if enabled { orientationMatters = false }
            else { comparisonSequenceID = nil }
        }
        .onChange(of: primaryID) { _ in
            // Primary changed: clear stale results, rebuild regions, and avoid
            // comparing a sequence against itself.
            if comparisonSequenceID == primaryID { comparisonSequenceID = nil }
            report = ""
            hasAnalysed = false
            selectedRegionID = nil
            refreshRegions()
        }
        .onChange(of: sequenceManager.sequences.count) { _ in
            // A Browse-opened file has just appeared — select it as the primary.
            if pendingBrowseSelect, let newest = sequenceManager.sequences.last {
                primaryID = newest.id
                pendingBrowseSelect = false
            }
        }
    }
    
    
    // MARK: - Source helpers

    private func refreshRegions() {
        if sequence.orfResults.isEmpty {
            sequence.orfResults = sequence.findORFs(minNucleotides: 150)
        }
        regions = analyzer.buildRegions(from: sequence)
    }

    private func browseForPrimary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "xdna") ?? .plainText,
            UTType(filenameExtension: "xprt") ?? .plainText,
            UTType(filenameExtension: "dna") ?? .plainText,
            UTType(filenameExtension: "ape") ?? .plainText,
            UTType(filenameExtension: "fasta") ?? .plainText,
            UTType(filenameExtension: "fa") ?? .plainText,
            UTType(filenameExtension: "gb") ?? .plainText,
            UTType(filenameExtension: "gbk") ?? .plainText,
            .plainText,
            .data
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            // Reuse the app's normal loader (handles every format). The file
            // opens as a sequence window and appears in the manager's list; the
            // onChange handler above then selects it as the primary here.
            pendingBrowseSelect = true
            sequenceManager.loadSequenceFromFile(url)
        }
    }
    
    // MARK: - Analysis
    
    /// Human-readable summary of active methylation settings for the report header.
    private var methylationNoteForReport: String? {
        var active: [String] = []
        if methylationDam { active.append("Dam (GATC)") }
        if methylationDcm { active.append("Dcm (CCWGG)") }
        if methylationCpG { active.append("CpG") }
        guard !active.isEmpty else { return nil }
        return active.joined(separator: ", ")
            + " methylation active — blocked sites excluded from predictions"
    }
    
    private var currentMethylation: MethylationContext {
        MethylationContext(activeDam: methylationDam,
                           activeDcm: methylationDcm,
                           activeCpG: methylationCpG)
    }
    
    private func regenerateReport() {
        let enzymeList = useMyEnzymesOnly ? enzDB.myEnzymes : enzDB.enzymes
        if comparisonMode { runComparisonAnalysis(enzymeList: enzymeList) }
        else { runSingleSequenceAnalysis(enzymeList: enzymeList) }
        hasAnalysed = true
    }
    
    private func runSingleSequenceAnalysis(enzymeList: [RestrictionEnzyme]) {
        let selectedRegion = regions.first { $0.id == selectedRegionID }
        let strategies = analyzer.analyze(
            sequence: sequence, region: selectedRegion,
            orientationMatters: orientationMatters,
            includeDoubleDigests: includeDoubleDigests,
            enzymes: enzymeList,
            methylation: currentMethylation
        )
        let seqInfo = "\(sequence.name) — \(sequence.sequence.count) bp, \(sequence.isCircular ? "circular" : "linear")"
        let regionInfo: String? = selectedRegion.map {
            "\($0.name) — \($0.length) bp at positions \($0.start + 1)–\($0.end)"
        }
        report = analyzer.formatReport(
            sequenceInfo: seqInfo, regionInfo: regionInfo,
            orientationMatters: orientationMatters, strategies: strategies,
            methylationNote: methylationNoteForReport
        )
    }
    
    private func runComparisonAnalysis(enzymeList: [RestrictionEnzyme]) {
        guard let seqB = comparisonSequence else { return }
        let strategies = analyzer.analyseComparison(
            sequenceA: sequence, sequenceB: seqB,
            includeDoubleDigests: includeDoubleDigests,
            enzymes: enzymeList,
            methylation: currentMethylation
        )
        let seqAInfo = "\(sequence.name) — \(sequence.sequence.count) bp, \(sequence.isCircular ? "circular" : "linear")"
        let seqBInfo = "\(seqB.name) — \(seqB.sequence.count) bp, \(seqB.isCircular ? "circular" : "linear")"
        report = analyzer.formatComparisonReport(
            seqAInfo: seqAInfo, seqBInfo: seqBInfo,
            sizeDiff: seqB.sequence.count - sequence.sequence.count,
            strategies: strategies,
            methylationNote: methylationNoteForReport
        )
    }
    
    
    // MARK: - Printing
    
    private func printReport() {
        let printInfo = (NSPrintInfo.shared.copy() as! NSPrintInfo)
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination  = .automatic
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered   = false
        printInfo.topMargin = 72; printInfo.bottomMargin = 72
        printInfo.leftMargin = 72; printInfo.rightMargin = 72
        
        let pw = printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin
        let ph = printInfo.paperSize.height - printInfo.topMargin - printInfo.bottomMargin
        
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: pw, height: ph))
        textView.string = report
        textView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        textView.isEditable = false; textView.isSelectable = true
        textView.textContainerInset = .zero
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: pw, height: .greatestFiniteMagnitude)
        if let lm = textView.layoutManager, let tc = textView.textContainer {
            lm.ensureLayout(for: tc)
            textView.frame.size.height = lm.usedRect(for: tc).height
        }
        let op = NSPrintOperation(view: textView, printInfo: printInfo)
        op.showsPrintPanel = true; op.showsProgressPanel = true; op.run()
    }
}


// MARK: - Window Manager

class ConstructCheckWindowManager {
    static let shared = ConstructCheckWindowManager()
    
    /// Injected once at app startup from DNAClonerApp's onAppear.
    /// Provides the sequence list for the comparison-mode picker.
    var sequenceManager: SequenceManager?
    
    private var windows: [NSWindow] = []
    private init() {}
    
    func openWindow(for sequence: DNASequence?) {
        guard let sequence = sequence, !sequence.sequence.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No Sequence"
            alert.informativeText = "Open or create a DNA sequence before using Check Construct."
            alert.alertStyle = .informational
            alert.runModal()
            return
        }
        guard let sm = sequenceManager else { return }
        
        // If a Check Construct window for THIS sequence is already open, bring
        // it forward instead of opening a duplicate. Different sequences still
        // get their own windows (so two constructs can be compared side by side).
        let expectedTitle = "Check Construct — \(sequence.name)"
        windows.removeAll { !$0.isVisible }
        if let existing = windows.first(where: { $0.title == expectedTitle }) {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let view = ConstructCheckView(sequence: sequence, sequenceManager: sm)
        let host = NSHostingController(rootView: view)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        win.title = "Check Construct — \(sequence.name)"
        win.contentViewController = host
        win.setFrameAutosaveName("CheckConstruct")
        if !win.setFrameUsingName(win.frameAutosaveName) { win.center() }
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 650, height: 500)
        win.makeKeyAndOrderFront(nil)
        windows.append(win)
    }
}

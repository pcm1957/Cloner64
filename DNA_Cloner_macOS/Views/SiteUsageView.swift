//
//  SiteUsageView.swift
//  Cloner 64
//
//  Restriction Site Usage analysis — shows a full table of all enzymes,
//  their cut counts and fragment sizes, plus summary lists of unique cutters,
//  blunt cutters, and non-cutting enzymes. Copyable and printable.
//

import SwiftUI
import AppKit


// MARK: - Window Manager

class SiteUsageWindowManager {
    static let shared = SiteUsageWindowManager()
    private var window: NSWindow?
    
    func openWindow(sequenceManager: SequenceManager, initialSequence: DNASequence?) {
        // If a window already exists, swap in a fresh SiteUsageView so the
        // picker resets to the requested initial sequence (if any).  This keeps
        // the window's frame and position but ensures the analysis reflects the
        // sequence the user just asked about.
        if let existing = window, existing.isVisible {
            let newView = SiteUsageView(
                sequenceManager: sequenceManager,
                initialSequence: initialSequence
            )
            existing.contentView = NSHostingView(rootView: newView)
            existing.makeKeyAndOrderFront(nil)
            return
        }
        
        let view = SiteUsageView(
            sequenceManager: sequenceManager,
            initialSequence: initialSequence
        )
        let hostingView = NSHostingView(rootView: view)
        
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 850, height: 650),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Site Usage"
        win.contentView = hostingView
        win.setFrameAutosaveName("SiteUsagesequencename")
        if !win.setFrameUsingName(win.frameAutosaveName) { win.center() }
        win.makeKeyAndOrderFront(nil)
        win.isReleasedWhenClosed = false
        
        self.window = win
    }
}


// MARK: - Data Model

struct EnzymeSiteInfo: Identifiable {
    let id = UUID()
    let name: String
    let recognitionSite: String
    let isBlunt: Bool
    let cutCount: Int
    let positions: [Int]      // 1-based cut positions
    let fragments: [Int]      // fragment sizes in bp, descending
    let methylationNote: String  // "" = no issue; set when Dam/Dcm/CpG affects this enzyme
    let isMyEnzyme: Bool         // true when enzyme is in the user's freezer stock
}

enum SiteUsageTab: String, CaseIterable {
    case all = "All Enzymes"
    case unique = "Unique Cutters"
    case blunt = "Blunt Cutters"
    case nonCutters = "Non-Cutters"
}


// MARK: - Main View

struct SiteUsageView: View {
    @ObservedObject var sequenceManager: SequenceManager
    @State private var selectedSequenceID: UUID?
    
    @State private var selectedTab: SiteUsageTab = .all
    @State private var sortByName: Bool = true   // true = name, false = cut count
    @State private var searchText: String = ""
    @State private var enzymeData: [EnzymeSiteInfo] = []
    @State private var isAnalysing: Bool = false
    @State private var copiedMessage: String? = nil

    // My Enzymes filter — shows only the user's freezer stock when on
    @State private var showMyEnzymesOnly: Bool = false

    // Methylation settings — shared with rest of app
    @AppStorage("methylation_dam") private var methylationDam: Bool = true
    @AppStorage("methylation_dcm") private var methylationDcm: Bool = true
    @AppStorage("methylation_cpg") private var methylationCpG: Bool = false
    
    init(sequenceManager: SequenceManager, initialSequence: DNASequence?) {
        self.sequenceManager = sequenceManager
        // Pick the initial sequence the caller asked for, falling back to the
        // manager's current sequence, then the first NON-EMPTY available
        // sequence (avoids landing on an Untitled placeholder), then any
        // sequence at all as a final resort.
        let initialID = initialSequence?.id
            ?? sequenceManager.currentSequence?.id
            ?? sequenceManager.sequences.first(where: { !$0.sequence.isEmpty })?.id
            ?? sequenceManager.sequences.first?.id
        self._selectedSequenceID = State(initialValue: initialID)
    }
    
    /// Currently displayed sequence — looked up live from the manager so that
    /// edits to the sequence (or its deletion) are reflected reactively.
    private var sequence: DNASequence? {
        guard let id = selectedSequenceID else { return nil }
        return sequenceManager.sequences.first(where: { $0.id == id })
    }
    
    // Filtered/sorted data for each tab
    private var displayData: [EnzymeSiteInfo] {
        var data: [EnzymeSiteInfo]
        switch selectedTab {
        case .all:
            data = enzymeData
        case .unique:
            data = enzymeData.filter { $0.cutCount == 1 }
        case .blunt:
            data = enzymeData.filter { $0.isBlunt && $0.cutCount > 0 }
        case .nonCutters:
            data = enzymeData.filter { $0.cutCount == 0 }
        }
        
        if showMyEnzymesOnly {
            data = data.filter { $0.isMyEnzyme }
        }

        if !searchText.isEmpty {
            data = data.filter { $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.recognitionSite.localizedCaseInsensitiveContains(searchText) }
        }
        
        if sortByName {
            data.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        } else {
            data.sort { $0.cutCount == $1.cutCount ? $0.name < $1.name : $0.cutCount > $1.cutCount }
        }
        
        return data
    }
    
    // Summary counts
    private var uniqueCount: Int { enzymeData.filter { $0.cutCount == 1 }.count }
    private var bluntCutterCount: Int { enzymeData.filter { $0.isBlunt && $0.cutCount > 0 }.count }
    private var nonCutterCount: Int { enzymeData.filter { $0.cutCount == 0 }.count }
    private var totalEnzymes: Int { enzymeData.count }
    private var cuttingEnzymes: Int { enzymeData.filter { $0.cutCount > 0 }.count }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerBar
            Divider()
            
            // Summary strip
            summaryBar
            Divider()
            
            // Tab bar
            tabBar
            Divider()
            
            // Table
            if isAnalysing {
                Spacer()
                ProgressView("Analysing \(totalEnzymes > 0 ? "\(totalEnzymes)" : "") enzymes…")
                Spacer()
            } else if enzymeData.isEmpty {
                Spacer()
                ProgressView("Analysing enzymes…")
                Spacer()
            } else {
                tableView
            }
        }
        .frame(minWidth: 750, minHeight: 500)
        .onAppear {
            analyseSequence()
        }
        .onChange(of: selectedSequenceID) { _ in
            enzymeData.removeAll()
            analyseSequence()
        }
        .onChange(of: methylationDam) { _ in analyseSequence() }
        .onChange(of: methylationDcm) { _ in analyseSequence() }
        .onChange(of: methylationCpG) { _ in analyseSequence() }
        .overlay(alignment: .bottom) {
            if let msg = copiedMessage {
                Text(msg)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)
                    .shadow(radius: 4)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.3), value: copiedMessage)
            }
        }
    }
    
    
    // MARK: - Header
    
    private var headerBar: some View {
        HStack {
            Text("Site Usage")
                .font(.headline)
            
            // Sequence picker — lets the user explicitly choose which open
            // sequence to analyse, regardless of which one was passed in when
            // the window opened.  Indispensable when multiple sequence windows
            // are open at once.
            Picker("", selection: $selectedSequenceID) {
                Text("(no sequence)").tag(nil as UUID?)
                ForEach(sequenceManager.sequences) { seq in
                    Text("\(seq.name) (\(seq.length) bp)")
                        .tag(seq.id as UUID?)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 280)
            .contextHelp("siteusage.sequencePicker")
            
            if let seq = sequence {
                Text("— \(seq.isCircular ? "circular" : "linear")")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button(action: copyCurrentTab) {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .controlSize(.small)
            .disabled(enzymeData.isEmpty)
            .contextHelp("siteusage.copy")
            
            Button(action: printReport) {
                Label("Print…", systemImage: "printer")
            }
            .controlSize(.small)
            .disabled(enzymeData.isEmpty)
            .contextHelp("siteusage.print")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
    
    
    // MARK: - Summary
    
    private var summaryBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 20) {
                summaryItem("Total", value: "\(totalEnzymes)")
                summaryItem("Cutting", value: "\(cuttingEnzymes)")
                summaryItem("Unique", value: "\(uniqueCount)")
                summaryItem("Blunt cutters", value: "\(bluntCutterCount)")
                summaryItem("Non-cutters", value: "\(nonCutterCount)")
                Spacer()
            }
            
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Text("Search:")
                        .font(.system(size: 13)).foregroundColor(.primary)
                        .fixedSize()
                    TextField("enzyme name…", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                        .font(.system(size: 13, design: .monospaced))
                        .contextHelp("siteusage.search")
                }
                
                HStack(spacing: 4) {
                    Text("Sort:")
                        .font(.system(size: 13)).foregroundColor(.primary)
                        .fixedSize()
                    Picker("", selection: $sortByName) {
                        Text("Name").tag(true)
                        Text("Cut count").tag(false)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                    .contextHelp("siteusage.sort")
                }
                
                // My Enzymes filter toggle
                Toggle(isOn: $showMyEnzymesOnly) {
                    Text("My Enzymes only")
                        .font(.system(size: 13))
                }
                .toggleStyle(.checkbox)
                .help("Show only enzymes in your freezer stock")
                .contextHelp("siteusage.myEnzymes")

                Spacer()
            }

            // Methylation notice — shown only when at least one methylation type is active
            let activeTypes: [String] = [
                methylationDam ? "Dam (GATC)" : nil,
                methylationDcm ? "Dcm (CCWGG)" : nil,
                methylationCpG ? "CpG" : nil
            ].compactMap { $0 }
            if !activeTypes.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                    Text("Methylation active: \(activeTypes.joined(separator: ", ")) — affected enzymes are flagged in the ⚠ column.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func summaryItem(_ label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 13)).foregroundColor(.primary.opacity(0.7))
            Text(value).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundColor(.primary)
        }
    }
    
    
    // MARK: - Tab Bar
    
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(SiteUsageTab.allCases, id: \.self) { tab in
                Button(action: { selectedTab = tab }) {
                    VStack(spacing: 2) {
                        Text(tabLabel(tab))
                            .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .regular))
                            .foregroundColor(selectedTab == tab ? .accentColor : .primary)
                        Rectangle()
                            .fill(selectedTab == tab ? Color.accentColor : Color.clear)
                            .frame(height: 2)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .contextHelp("siteusage.tabs")
            }
            Spacer()
        }
        .padding(.horizontal, 8)
    }
    
    private func tabLabel(_ tab: SiteUsageTab) -> String {
        switch tab {
        case .all: return "All Enzymes (\(totalEnzymes))"
        case .unique: return "Unique Cutters (\(uniqueCount))"
        case .blunt: return "Blunt Cutters (\(bluntCutterCount))"
        case .nonCutters: return "Non-Cutters (\(nonCutterCount))"
        }
    }
    
    
    // MARK: - Table
    
    private var tableView: some View {
        VStack(spacing: 0) {
            // Column headers
            HStack(spacing: 0) {
                Text("Enzyme")
                    .frame(width: 100, alignment: .leading)
                Text("Site")
                    .frame(width: 120, alignment: .leading)
                Text("Type")
                    .frame(width: 60, alignment: .center)
                Text("Cuts")
                    .frame(width: 50, alignment: .center)
                Text("Positions")
                    .frame(width: 160, alignment: .leading)
                Text("Fragment sizes")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("⚠")
                    .frame(width: 22, alignment: .center)
                    .help("Methylation sensitivity")
                    .contextHelp("siteusage.methylationColumn")
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color(.controlBackgroundColor))
            
            Divider()
            
            // Rows
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(displayData.enumerated()), id: \.element.id) { index, enzyme in
                        HStack(spacing: 0) {
                            Text(enzyme.name)
                                .fontWeight(.medium)
                                .frame(width: 100, alignment: .leading)
                            Text(enzyme.recognitionSite)
                                .frame(width: 120, alignment: .leading)
                            Text(enzyme.isBlunt ? "Blunt" : "Sticky")
                                .foregroundColor(enzyme.isBlunt ? .orange : .secondary)
                                .frame(width: 60, alignment: .center)
                            Text("\(enzyme.cutCount)")
                                .fontWeight(enzyme.cutCount == 1 ? .bold : .regular)
                                .foregroundColor(enzyme.cutCount == 1 ? .blue : (enzyme.cutCount == 0 ? .secondary : .primary))
                                .frame(width: 50, alignment: .center)
                            Text(enzyme.positions.isEmpty ? "—" : enzyme.positions.map { "\($0)" }.joined(separator: ", "))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .frame(width: 160, alignment: .leading)
                            Text(enzyme.fragments.isEmpty ? "—" : enzyme.fragments.map { formatBP($0) }.joined(separator: ", "))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            // Methylation warning cell
                            Group {
                                if !enzyme.methylationNote.isEmpty {
                                    let isRequired = enzyme.methylationNote.contains("requires")
                                    Image(systemName: isRequired ? "m.circle.fill" : "exclamationmark.triangle.fill")
                                        .font(.system(size: 10))
                                        .foregroundColor(isRequired ? .blue : .orange)
                                        .help(enzyme.methylationNote)
                                } else {
                                    Text("").frame(width: 22)
                                }
                            }
                            .frame(width: 22, alignment: .center)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 12).padding(.vertical, 3)
                        .background(index % 2 == 0 ? Color.clear : Color(.controlBackgroundColor).opacity(0.5))
                        .contextMenu {
                            Button("Copy row") {
                                let text = "\(enzyme.name)\t\(enzyme.recognitionSite)\t\(enzyme.isBlunt ? "Blunt" : "Sticky")\t\(enzyme.cutCount)\t\(enzyme.positions.map { "\($0)" }.joined(separator: ", "))\t\(enzyme.fragments.map { "\($0)" }.joined(separator: ", "))"
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(text, forType: .string)
                                showCopied("Row copied")
                            }
                        }
                    }
                }
            }
            
            Divider()
            
            // Footer
            HStack {
                Text("\(displayData.count) enzymes shown")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
        }
    }
    
    
    // MARK: - Analysis
    
    private func analyseSequence() {
        guard let sequence = self.sequence else {
            enzymeData.removeAll()
            isAnalysing = false
            return
        }
        isAnalysing = true
        enzymeData.removeAll()
        
        let seqStr = sequence.sequence.uppercased()
        let isCircular = sequence.isCircular
        let seqLen = seqStr.count
        let db = RestrictionEnzymeDatabase.shared
        
        // Snapshot methylation + My Enzymes settings for background thread
        let checkDam    = self.methylationDam
        let checkDcm    = self.methylationDcm
        let checkCpG    = self.methylationCpG
        let myEnzNames  = Set(db.myEnzymeNames)

        DispatchQueue.global(qos: .userInitiated).async {
            var results: [EnzymeSiteInfo] = []

            for enzyme in db.enzymes {
                let sites = enzyme.findCutSites(in: seqStr, circular: isCircular)

                // Deduplicate positions
                var seen: Set<Int> = []
                var positions: [Int] = []
                for site in sites {
                    if !seen.contains(site.position) {
                        positions.append(site.position)
                        seen.insert(site.position)
                    }
                }
                positions.sort()

                // Compute fragments
                let fragments: [Int]
                if positions.isEmpty {
                    fragments = []
                } else {
                    let cutPositions = positions.map { $0 + enzyme.cutPosition5Prime }
                        .map { pos -> Int in
                            var p = pos
                            if p < 0 { p += seqLen }
                            if p > seqLen { p -= seqLen }
                            return p
                        }
                        .sorted()
                    fragments = computeFragments(cutPositions: cutPositions, seqLen: seqLen, circular: isCircular)
                        .sorted(by: >)
                }

                // Methylation note — check the first actual site for context-specific warnings
                var methylNote = ""
                if (checkDam || checkDcm || checkCpG) && !positions.isEmpty {
                    let sitePos = positions[0]  // check against first site position
                    let warnings = MethylationChecker.checkSite(
                        enzymeName:      enzyme.name,
                        sitePosition:    sitePos,
                        recognitionSite: enzyme.recognitionSite,
                        sequence:        seqStr,
                        circular:        isCircular,
                        activeDam:       checkDam,
                        activeDcm:       checkDcm,
                        activeCpG:       checkCpG
                    )
                    let isRequired = warnings.contains { $0.effect == .required }
                    let isBlocked  = MethylationChecker.isCutBlocked(warnings)
                    let rec = enzyme.recognitionSite.uppercased()
                    if isRequired {
                        methylNote = "requires methylation to cut (e.g. Dam+ only)"
                    } else if isBlocked {
                        var types: [String] = []
                        if checkDam && rec.contains("GATC")                                    { types.append("Dam") }
                        if checkDcm && (rec.contains("CCAGG") || rec.contains("CCTGG")
                                     || rec.contains("CCWGG"))                                 { types.append("Dcm") }
                        if checkCpG && rec.contains("CG")                                      { types.append("CpG") }
                        methylNote = "blocked by \(types.isEmpty ? "methylation" : types.joined(separator: "/"))"
                    }
                }

                results.append(EnzymeSiteInfo(
                    name: enzyme.name,
                    recognitionSite: enzyme.recognitionSite,
                    isBlunt: enzyme.overhangType == .blunt,
                    cutCount: positions.count,
                    positions: positions,
                    fragments: fragments,
                    methylationNote: methylNote,
                    isMyEnzyme: myEnzNames.contains(enzyme.name)
                ))
            }
            
            DispatchQueue.main.async {
                enzymeData = results
                isAnalysing = false
            }
        }
    }
    
    private func computeFragments(cutPositions: [Int], seqLen: Int, circular: Bool) -> [Int] {
        guard !cutPositions.isEmpty else { return [seqLen] }
        let sorted = cutPositions.sorted()
        var fragments: [Int] = []
        
        if circular {
            for i in 0..<sorted.count {
                let next = (i + 1) % sorted.count
                var size: Int
                if next > i {
                    size = sorted[next] - sorted[i]
                } else {
                    size = (seqLen - sorted[i]) + sorted[next]
                }
                if size > 0 { fragments.append(size) }
            }
        } else {
            if sorted[0] > 0 { fragments.append(sorted[0]) }
            for i in 0..<sorted.count - 1 {
                let size = sorted[i + 1] - sorted[i]
                if size > 0 { fragments.append(size) }
            }
            if sorted.last! < seqLen { fragments.append(seqLen - sorted.last!) }
        }
        
        return fragments.filter { $0 > 0 }
    }
    
    
    // MARK: - Copy
    
    private func copyCurrentTab() {
        guard let sequence = self.sequence else { return }
        let data = displayData
        var text = "Site Usage — \(sequence.name) (\(sequence.length) bp, \(sequence.isCircular ? "circular" : "linear"))\n"
        text += "Tab: \(selectedTab.rawValue)\n\n"
        text += "Enzyme\tSite\tType\tCuts\tPositions\tFragments\n"
        
        for enzyme in data {
            let positions = enzyme.positions.map { "\($0)" }.joined(separator: ", ")
            let fragments = enzyme.fragments.map { "\($0)" }.joined(separator: ", ")
            text += "\(enzyme.name)\t\(enzyme.recognitionSite)\t\(enzyme.isBlunt ? "Blunt" : "Sticky")\t\(enzyme.cutCount)\t\(positions)\t\(fragments)\n"
        }
        
        text += "\nTotal: \(data.count) enzymes"
        
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showCopied("\(selectedTab.rawValue) copied to clipboard")
    }
    
    
    // MARK: - Print
    
    private func printReport() {
        guard let sequence = self.sequence else { return }
        let data = displayData
        
        // Build an attributed string report
        var report = "SITE USAGE REPORT\n"
        report += "\(sequence.name) — \(sequence.length) bp, \(sequence.isCircular ? "circular" : "linear")\n"
        report += "Tab: \(selectedTab.rawValue)\n"
        report += String(repeating: "─", count: 80) + "\n\n"
        
        // Summary
        report += "Summary: \(totalEnzymes) enzymes total, \(cuttingEnzymes) cutting, "
        report += "\(uniqueCount) unique, \(bluntCutterCount) blunt cutters, \(nonCutterCount) non-cutters\n\n"
        
        // Table header
        report += String(format: "%-14s %-14s %-7s %5s  %-20s  %s\n", "Enzyme", "Site", "Type", "Cuts", "Positions", "Fragments")
        report += String(repeating: "─", count: 100) + "\n"
        
        for enzyme in data {
            let positions = enzyme.positions.isEmpty ? "—" : enzyme.positions.map { "\($0)" }.joined(separator: ", ")
            let fragments = enzyme.fragments.isEmpty ? "—" : enzyme.fragments.map { formatBP($0) }.joined(separator: ", ")
            let type = enzyme.isBlunt ? "Blunt" : "Sticky"
            report += String(format: "%-14s %-14s %-7s %5d  %-20s  %s\n",
                             String(enzyme.name.prefix(14)),
                             String(enzyme.recognitionSite.prefix(14)),
                             type,
                             enzyme.cutCount,
                             String(positions.prefix(20)),
                             fragments)
        }
        
        report += "\n\(data.count) enzymes shown"
        
        // Create text view for printing
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 680, height: 900))
        textView.string = report
        textView.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        textView.isEditable = false
        textView.sizeToFit()
        
        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = true
        printInfo.topMargin = 36
        printInfo.bottomMargin = 36
        printInfo.leftMargin = 36
        printInfo.rightMargin = 36
        
        let printOp = NSPrintOperation(view: textView, printInfo: printInfo)
        printOp.showsPrintPanel = true
        printOp.showsProgressPanel = true
        printOp.run()
    }
    
    
    // MARK: - Helpers
    
    private func formatBP(_ bp: Int) -> String {
        if bp >= 1000 {
            let kb = Double(bp) / 1000.0
            if kb == Double(Int(kb)) { return "\(Int(kb)) kb" }
            return String(format: "%.1f kb", kb)
        }
        return "\(bp)"
    }
    
    private func showCopied(_ message: String) {
        copiedMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            copiedMessage = nil
        }
    }
}

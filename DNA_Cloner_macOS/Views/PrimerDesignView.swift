//
//  PrimerDesignView.swift
//  Cloner 64
//
//  PCR Primer Design tool -- designs forward and reverse primer pairs
//  for amplifying a target region.  Supports circular templates where
//  the amplicon spans the origin (e.g. forward at 4000, reverse at 200).
//  Includes visual amplicon map with draggable handles, primer-dimer
//  screening, and optional 5-prime tails (restriction sites or custom).
//

import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers


// MARK: - Window Manager

class PrimerDesignWindowManager {
    static let shared = PrimerDesignWindowManager()
    private var window: NSWindow?
    
    func openWindow(sequenceManager: SequenceManager, initialSequenceID: UUID? = nil) {
        if CloningPrimerTransfer.shared.hasPendingTransfer {
            window?.close()
            window = nil
        }
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        
        let view = PrimerDesignView(sequenceManager: sequenceManager, initialSequenceID: initialSequenceID)
        let hostingView = NSHostingView(rootView: view)
        
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 880),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Design PCR Primers"
        win.contentView = hostingView
        win.setFrameAutosaveName("DesignPCRPrimers")
        if !win.setFrameUsingName(win.frameAutosaveName) { win.center() }
        win.makeKeyAndOrderFront(nil)
        win.isReleasedWhenClosed = false
        
        self.window = win
    }
}


// MARK: - Data Models

struct PrimerCandidate {
    let sequence: String       // 5'->3' (annealing portion only)
    let position: Int          // 1-based start on sense strand
    let length: Int
    let tm: Double
    let gcPercent: Double
    let selfDimerScore: Int
    let offsetFromTarget: Int  // 0 = on target boundary, >0 = placed outside target region
    let isStock: Bool          // true = from primer stock folder
    let stockName: String?     // name of stock primer (nil if designed)
    
    init(sequence: String, position: Int, length: Int, tm: Double, gcPercent: Double,
         selfDimerScore: Int, offsetFromTarget: Int, isStock: Bool = false, stockName: String? = nil) {
        self.sequence = sequence; self.position = position; self.length = length
        self.tm = tm; self.gcPercent = gcPercent; self.selfDimerScore = selfDimerScore
        self.offsetFromTarget = offsetFromTarget; self.isStock = isStock; self.stockName = stockName
    }
}

struct PrimerPair: Identifiable {
    let id = UUID()
    let forward: PrimerCandidate
    let reverse: PrimerCandidate
    let productSize: Int       // actual amplicon size (may exceed target region)
    let crossDimerScore: Int
    
    var tmDifference: Double { abs(forward.tm - reverse.tm) }
    var worstDimerScore: Int { max(forward.selfDimerScore, reverse.selfDimerScore, crossDimerScore) }
    var totalOffset: Int { forward.offsetFromTarget + reverse.offsetFromTarget }
    var stockCount: Int { (forward.isStock ? 1 : 0) + (reverse.isStock ? 1 : 0) }
}

enum TailMode: String, CaseIterable {
    case none = "None"
    case enzyme = "Restriction Site"
    case custom = "Custom"
}

enum FixedPrimerMode: String, CaseIterable {
    case none = "Design Both"
    case fixedForward = "Fix Forward"
    case fixedReverse = "Fix Reverse"
    case fixedBoth = "Fix Both"
}

/// A primer loaded from a stock folder (.xdna file)
struct StockPrimer: Identifiable {
    let id = UUID()
    let name: String           // file name (without extension)
    let coreSequence: String   // annealing/core portion, uppercased
    let tailSequence: String   // 5' tail portion, uppercased (may be empty)
    let fullSequence: String   // tail + core, uppercased
    let sourceFile: String     // relative path within the stock folder
}

/// A stock primer that has been matched against the current template
struct StockPrimerMatch: Identifiable {
    let id = UUID()
    let stockPrimer: StockPrimer
    let bindingPosition: Int     // 1-based position on template sense strand
    let annealingSequence: String // the portion that actually binds (uppercased)
    let tailPortion: String      // the 5' portion that doesn't bind (uppercased)
    let isReverse: Bool          // true = reverse primer (binds antisense strand)
    let tm: Double
    let gcPercent: Double
}


enum SDMStrategy: String, CaseIterable {
    case quickChange = "QuikChange"
    case backToBack  = "Back-to-Back (KLD)"
}

enum SDMMutationType: String, CaseIterable {
    case dna             = "DNA sequence"
    case aminoAcid       = "Amino acid change"
    case restrictionSite = "Restriction site"
}

enum SDMREAction: String, CaseIterable {
    case introduce = "Introduce site"
    case destroy   = "Destroy site"
}


// MARK: - Main View

struct PrimerDesignView: View {
    @ObservedObject var sequenceManager: SequenceManager
    let initialSequenceID: UUID?
    
    // -- Template selection --
    @State private var selectedSequenceID: UUID?
    
    /// The currently selected template sequence
    private var sequence: DNASequence {
        if let id = selectedSequenceID,
           let seq = sequenceManager.sequences.first(where: { $0.id == id }) {
            return seq
        }
        return sequenceManager.sequences.first ?? DNASequence(name: "", sequence: "")
    }
    
    private var hasTemplate: Bool {
        !sequenceManager.sequences.isEmpty
    }
    
    // -- Parameters --
    @State private var targetStartText: String = "1"
    @State private var targetEndText: String   = ""
    @State private var minPrimerLength: Int     = 18
    @State private var maxPrimerLength: Int     = 25
    @State private var targetTm: Double         = 60.0
    @State private var maxTmDiff: Double        = 5.0
    @State private var saltConc: Double         = 50.0   // mM
    @State private var maxDimerScore: Int       = 4
    @State private var searchWindow: Int         = 100   // bp either side of target region
    @State private var allowInternalPrimers: Bool = false

    // -- Whole-plasmid amplification --
    // When true, designs outward-pointing primers at a single site so the
    // entire circular plasmid is the product (inverse / whole-plasmid PCR).
    @State private var wholePlasmidMode: Bool   = false
    @State private var primerSiteText: String   = "1"   // site where primers are placed
    @State private var addOverlapTails: Bool    = false  // add homology tails for self-circularisation
    @State private var overlapLength: Int       = 25     // bp of homology on each tail

    // -- Site-Directed Mutagenesis --
    @State private var sdmMode: Bool                    = false
    @State private var sdmStrategy: SDMStrategy         = .quickChange
    @State private var sdmMutationType: SDMMutationType = .dna

    // Local mirrors of sequenceManager.selectionStart/End so SwiftUI
    // reliably redraws this view when the user selects bases in Sequence View.
    @State private var seqViewSelStart: Int = 0
    @State private var seqViewSelEnd:   Int = 0
    // DNA mutation
    @State private var sdmSiteText: String              = "1"    // 1-based position of first mutant base
    @State private var sdmMutantSequence: String        = ""     // the replacement sequence (typed by user)
    @State private var sdmOriginalLength: Int           = 1      // how many template bases are replaced
    @State private var sdmFlankLength: Int              = 15     // bp of exact match either side (QuikChange)
    // Amino acid
    @State private var sdmFeatureID: UUID?              = nil    // which CDS feature
    @State private var sdmCodonNumberText: String       = "1"    // codon number within CDS (1-based)
    @State private var sdmNewCodonText: String          = ""     // user-chosen replacement codon
    // Restriction site
    @State private var sdmREName: String                = "EcoRI"
    @State private var sdmREAction: SDMREAction         = .introduce
    @State private var sdmRESiteText: String            = "1"    // position to introduce/destroy
    
    // -- Fixed Primer --
    @State private var fixedPrimerMode: FixedPrimerMode = .none
    @State private var fixedFwdSequence: String = ""
    @State private var fixedRevSequence: String = ""
    
    // -- Feature Overlay --
    @State private var showFeatureOverlay: Bool    = false
    @State private var selectedFeatureIDs: Set<UUID> = []
    @State private var selectedORFIDs: Set<UUID>     = []
    @State private var selectedTargetIndex: Int = -1
    
    // -- Tails --
    @State private var showTailSection: Bool      = false
    @State private var fwdTailMode: TailMode      = .none
    @State private var revTailMode: TailMode      = .none
    @State private var fwdSelectedEnzyme: String   = "EcoRI"
    @State private var revSelectedEnzyme: String   = "BamHI"
    @State private var fwdCustomTail: String       = ""
    @State private var revCustomTail: String       = ""
    @State private var fwdPaddingBases: Int        = 2
    @State private var revPaddingBases: Int        = 2
    @State private var fwdPadding3Prime: Int       = 0
    @State private var revPadding3Prime: Int       = 0
    
    private let enzymeDB = RestrictionEnzymeDatabase.shared
    // GC-rich padding bases for efficient RE cutting near ends
    private let paddingSequences = ["", "G", "GC", "GCG", "GCGC", "GCGCG", "GCGCGC"]

    /// O(1) enzyme recognition site lookup — built once from the shared database.
    private static let enzymeRecognitionSites: [String: String] = {
        Dictionary(uniqueKeysWithValues:
            RestrictionEnzymeDatabase.shared.enzymes.map { ($0.name, $0.recognitionSite) })
    }()

    private var fwdTail: String {
        switch fwdTailMode {
        case .none: return ""
        case .enzyme:
            let pad5 = paddingString(fwdPaddingBases)
            let site = Self.enzymeRecognitionSites[fwdSelectedEnzyme] ?? ""
            let pad3 = paddingString(fwdPadding3Prime)
            return (pad5 + site + pad3).lowercased()
        case .custom:
            return fwdCustomTail.uppercased().filter { "ACGTN".contains($0) }.lowercased()
        }
    }

    private var revTail: String {
        switch revTailMode {
        case .none: return ""
        case .enzyme:
            let pad5 = paddingString(revPaddingBases)
            let site = Self.enzymeRecognitionSites[revSelectedEnzyme] ?? ""
            let pad3 = paddingString(revPadding3Prime)
            return (pad5 + site + pad3).lowercased()
        case .custom:
            return revCustomTail.uppercased().filter { "ACGTN".contains($0) }.lowercased()
        }
    }
    // -- Results --
    @State private var primerPairs: [PrimerPair] = []
    @State private var selectedPairID: UUID?
    @State private var errorMessage: String?
    @State private var hasRun = false
    @State private var isRunning = false
    @State private var copiedField: String?
    @State private var isDraggingStart = false
    @State private var isDraggingEnd = false

    // -- Primer Stock --
    @State private var showStockSection: Bool      = false
    @State private var primerStockURL: URL?
    @State private var stockPrimers: [StockPrimer] = []
    @State private var stockScanMessage: String?
    @State private var stockMatches: [StockPrimerMatch] = []
    @State private var preferStock: Bool           = true

    private var selectedPair: PrimerPair? {
        primerPairs.first(where: { $0.id == selectedPairID })
    }

    // -- Parsed inputs --
    private var targetStart: Int? { Int(targetStartText) }
    private var targetEnd: Int?   { Int(targetEndText) }

    private var wrapsOrigin: Bool {
        guard sequence.isCircular, let s = targetStart, let e = targetEnd else { return false }
        return s > e
    }

    private var productSize: Int? {
        guard let s = targetStart, let e = targetEnd else { return nil }
        if wrapsOrigin {
            return (sequence.length - s + 1) + e
        } else {
            guard e > s else { return nil }
            return e - s + 1
        }
    }

    private func paddingString(_ count: Int) -> String {
        guard count >= 0, count < paddingSequences.count else { return "" }
        return paddingSequences[count]
    }

    private func fullPrimer(tail: String, annealing: String) -> String {
        tail.lowercased() + annealing.uppercased()
    }
    
    var body: some View {
        VStack(spacing: 0) {
            templatePickerSection
            Divider()
            if hasTemplate {
                // Top half: scrollable parameters area
                ScrollView {
                    VStack(spacing: 0) {
                        parametersSection
                        Divider()
                        tailSection
                        Divider()
                        primerStockSection
                        Divider()
                        featureOverlaySection
                        ampliconMapSection
                    }
                }
                .frame(minHeight: 380)
                Divider()
                resultsSection
                    .contextHelp("primer.resultsTable")
                Divider()
                detailSection
            } else {
                Spacer()
                Text("No sequences open. Open a sequence file to use as template.")
                    .foregroundColor(.primary.opacity(0.55))
                    .font(.system(size: 14))
                Spacer()
            }
        }
        .frame(minWidth: 700, minHeight: 600)
        .onReceive(Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()) { _ in
            // selectionStart/End are deliberately not @Published (comment in SequenceManager)
            // so we poll them on a short timer instead.
            let s = sequenceManager.selectionStart
            let e = sequenceManager.selectionEnd
            if s != seqViewSelStart { seqViewSelStart = s }
            if e != seqViewSelEnd   { seqViewSelEnd   = e }
        }
        .onAppear {
            if selectedSequenceID == nil {
                selectedSequenceID = initialSequenceID ?? sequenceManager.sequences.first?.id
            }
            if targetEndText.isEmpty {
                targetEndText = "\(sequence.length)"
            }
            
            // Apply cloning primer transfer if pending.
            // IMPORTANT: setting selectedSequenceID triggers onChange which resets
            // targetStartText/targetEndText to 1/length. We must apply the transfer
            // target values AFTER that reset fires, so we defer to the next two
            // run-loop ticks to guarantee we land after any SwiftUI state propagation.
            let transfer = CloningPrimerTransfer.shared
            if transfer.hasPendingTransfer {
                let pendingID    = transfer.templateSequenceID
                let pendingStart = transfer.targetStart
                let pendingEnd   = transfer.targetEnd
                let pendingFwd   = transfer.fwdEnzymeName
                let pendingRev   = transfer.revEnzymeName
                let pendingFwdPad = transfer.fwdPaddingBases
                let pendingRevPad = transfer.revPaddingBases
                transfer.clear()

                // First tick: set the template sequence (triggers onChange reset)
                if let id = pendingID { selectedSequenceID = id }

                // Second tick: apply target after onChange has reset
                DispatchQueue.main.async {
                    DispatchQueue.main.async {
                        if let s = pendingStart { targetStartText = "\(s)" }
                        if let e = pendingEnd   { targetEndText   = "\(e)" }
                        if let fwd = pendingFwd {
                            showTailSection = true
                            fwdTailMode = .enzyme
                            fwdSelectedEnzyme = fwd
                            fwdPaddingBases = pendingFwdPad
                        }
                        if let rev = pendingRev {
                            showTailSection = true
                            revTailMode = .enzyme
                            revSelectedEnzyme = rev
                            revPaddingBases = pendingRevPad
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Template Picker Section
    
    private var templatePickerSection: some View {
        HStack(spacing: 12) {
            Text("Template:")
                .font(.headline)
            
            Picker("", selection: $selectedSequenceID) {
                ForEach(sequenceManager.sequences, id: \.id) { seq in
                    Text("\(seq.name)  (\(seq.length) bp, \(seq.isCircular ? "circular" : "linear"))")
                        .tag(Optional(seq.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 400)
            .id(sequenceManager.sequences.map { $0.id })
            .onReceive(sequenceManager.$sequences) { newSequences in
                // macOS SwiftUI Picker bug: NSPopUpButton can render blank after
                // the sequence list changes even with a valid selection.
                // Only do the nil/restore cycle when the current selection is
                // no longer present in the list (e.g. a sequence was deleted).
                // When the selection IS still valid, leave it alone — this
                // avoids the blank-flash and stops onChange firing unnecessarily.
                let saved = selectedSequenceID
                let stillValid = saved != nil && newSequences.contains(where: { $0.id == saved })
                if !stillValid {
                    selectedSequenceID = nil
                    DispatchQueue.main.async {
                        selectedSequenceID = newSequences.first?.id
                    }
                }
            }
            .onChange(of: selectedSequenceID) { _ in
                // Reset when switching templates
                primerPairs = []
                selectedPairID = nil
                hasRun = false
                errorMessage = nil
                targetStartText = "1"
                targetEndText = "\(sequence.length)"
                selectedTargetIndex = -1
                selectedFeatureIDs = []
                selectedORFIDs = []
                stockMatches = []
                wholePlasmidMode = false
                primerSiteText = "1"
                addOverlapTails = false
                // Re-screen stock primers against the new template
                if !stockPrimers.isEmpty {
                    // Defer to allow sequence to update
                    DispatchQueue.main.async { screenStockAgainstTemplate() }
                }
            }
            .contextHelp("primer.templatePicker")
            
            Button("Open…") {
                openTemplateFromFile()
            }
            .help("Open a sequence file to use as template")
            .contextHelp("primer.openTemplate")
            
            Spacer()
        }
        .padding()
    }
    
    
    // MARK: - Import / Export Primers (.xdna format)
    
    /// Build a DNASequence for a single primer, with "Primer Core" and
    /// optional "Primer Tail" features.  Core is uppercase, tail is lowercase.
    private func buildPrimerSequence(name: String, annealing: String, tail: String) -> DNASequence {
        let tailPart = tail.lowercased()
        let corePart = annealing.uppercased()
        let fullSeq = tailPart + corePart
        
        let seq = DNASequence(name: name, sequence: fullSeq, isCircular: false)
        seq.description = "Primer designed from template: \(sequence.name)"
        
        var features: [Feature] = []
        
        // Tail feature (red, lowercase portion)
        if !tail.isEmpty {
            features.append(Feature(
                name: "Primer Tail",
                type: .custom,
                start: 0,               // 0-based start
                end: tail.count,         // exclusive end
                strand: .forward,
                color: CodableColor(red: 0.85, green: 0.15, blue: 0.15)  // red
            ))
        }
        
        // Core feature (black)
        let coreStart = tail.isEmpty ? 0 : tail.count
        features.append(Feature(
            name: "Primer Core",
            type: .primerBinding,
            start: coreStart,
            end: coreStart + annealing.count,
            strand: .forward,
            color: CodableColor(red: 0.0, green: 0.0, blue: 0.0)  // black
        ))
        
        seq.features = features
        return seq
    }
    
    /// Export selected primer pair as two .xdna files (one per primer).
    /// User picks a folder, and we save ForwardPrimer.xdna + ReversePrimer.xdna.
    private func exportPrimers() {
        guard let pair = selectedPair else { return }
        
        let panel = NSOpenPanel()
        panel.title = "Choose Folder for Primer Files"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        
        let baseName = sequence.name.replacingOccurrences(of: " ", with: "_")
        let parser = XDNAParser()
        
        // Build and save forward primer
        let fwdSeq = buildPrimerSequence(
            name: "\(baseName)_Forward",
            annealing: pair.forward.sequence,
            tail: fwdTail
        )
        let fwdURL = folder.appendingPathComponent("\(baseName)_Forward.xdna")
        if !parser.writeXDNA(fwdSeq, to: fwdURL) {
            errorMessage = "Failed to write forward primer file."
            return
        }
        
        // Build and save reverse primer
        let revSeq = buildPrimerSequence(
            name: "\(baseName)_Reverse",
            annealing: pair.reverse.sequence,
            tail: revTail
        )
        let revURL = folder.appendingPathComponent("\(baseName)_Reverse.xdna")
        if !parser.writeXDNA(revSeq, to: revURL) {
            errorMessage = "Failed to write reverse primer file."
            return
        }
        
        copiedField = "exported"
        clearCopiedAfterDelay()
    }
    
    /// Export a single primer as an .xdna file via a save dialog.
    private func exportSinglePrimer(name: String, annealing: String, tail: String) {
        let baseName = sequence.name.replacingOccurrences(of: " ", with: "_")
        let defaultName = "\(baseName)_\(name).xdna"
        
        let panel = NSSavePanel()
        panel.title = "Save \(name) Primer"
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [.data]
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        
        guard panel.runModal() == .OK, let url = panel.url else { return }
        
        let parser = XDNAParser()
        let primerSeq = buildPrimerSequence(
            name: url.deletingPathExtension().lastPathComponent,
            annealing: annealing,
            tail: tail
        )
        
        if parser.writeXDNA(primerSeq, to: url) {
            let label = name.lowercased() == "forward" ? "forward_saved" : "reverse_saved"
            copiedField = label
            clearCopiedAfterDelay()
        } else {
            errorMessage = "Failed to save primer file."
        }
    }
    
    /// Extract tail and core from a DNASequence that has Primer Core / Primer Tail features.
    /// Falls back to case convention (lowercase = tail, uppercase = core) for legacy primers.
    /// Returns (tail, core) or nil if no Primer Core feature found.
    private func extractPrimerParts(from seq: DNASequence) -> (tail: String, core: String)? {
        let coreFeature = seq.features.first(where: { $0.name == "Primer Core" })
        let tailFeature = seq.features.first(where: { $0.name == "Primer Tail" })
        
        let fullSeq = seq.sequence
        guard let core = coreFeature else {
            // No Primer Core/Tail features — try case convention:
            // lowercase prefix = tail, uppercase suffix = core
            // e.g. "gcgaattcATCGATCGATCG" → tail "gcgaattc", core "ATCGATCGATCG"
            let chars = Array(fullSeq)
            
            // Find the start of the trailing uppercase run
            var coreStartIdx = chars.count
            for i in stride(from: chars.count - 1, through: 0, by: -1) {
                let c = chars[i]
                if c.isUppercase || !c.isLetter {
                    coreStartIdx = i
                } else {
                    break  // hit a lowercase letter — stop
                }
            }
            
            if coreStartIdx > 0 && coreStartIdx < chars.count {
                // Mixed case: split into tail + core
                let tailPart = String(chars[0..<coreStartIdx]).uppercased()
                let corePart = String(chars[coreStartIdx...]).uppercased()
                return (tail: tailPart, core: corePart)
            }
            
            // All same case or no letters — treat entire sequence as core
            return (tail: "", core: fullSeq.uppercased())
        }
        
        // Extract core portion
        let coreStart = max(0, core.start)
        let coreEnd = min(fullSeq.count, core.end)
        guard coreStart < coreEnd else { return nil }
        let coreStr = String(fullSeq[fullSeq.index(fullSeq.startIndex, offsetBy: coreStart)..<fullSeq.index(fullSeq.startIndex, offsetBy: coreEnd)])
        
        // Extract tail portion
        var tailStr = ""
        if let tail = tailFeature {
            let tailStart = max(0, tail.start)
            let tailEnd = min(fullSeq.count, tail.end)
            if tailStart < tailEnd {
                tailStr = String(fullSeq[fullSeq.index(fullSeq.startIndex, offsetBy: tailStart)..<fullSeq.index(fullSeq.startIndex, offsetBy: tailEnd)])
            }
        }
        
        return (tail: tailStr.uppercased(), core: coreStr.uppercased())
    }
    
    /// Open a sequence file from disk and add it to the open sequences list,
    /// then select it as the template.
    private func openTemplateFromFile() {
        let panel = NSOpenPanel()
        panel.title = "Open Template Sequence"
        panel.allowedContentTypes = [.data]
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        
        guard panel.runModal() == .OK, let url = panel.url else { return }
        
        let parser = XDNAParser()
        
        // Try .xdna first
        if let seq = parser.parseXDNA(url) {
            seq.sourceURL = url
            sequenceManager.sequences.append(seq)
            selectedSequenceID = seq.id
            targetStartText = "1"
            targetEndText = "\(seq.length)"
            return
        }
        
        // Try reading as plain text / FASTA
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            let cleaned = text.components(separatedBy: .newlines)
                .filter { !$0.hasPrefix(">") }
                .joined()
                .filter { "ACGTURYSWKMBDHVNacgturyswkmbdhvn".contains($0) }
            if !cleaned.isEmpty {
                let seq = DNASequence(name: url.deletingPathExtension().lastPathComponent, sequence: cleaned)
                seq.sourceURL = url
                sequenceManager.sequences.append(seq)
                selectedSequenceID = seq.id
                targetStartText = "1"
                targetEndText = "\(seq.length)"
                return
            }
        }
        
        errorMessage = "Could not read sequence from \(url.lastPathComponent)"
    }
    
    /// Open a primer .xdna file and load its core/tail into the fixed primer fields.
    private func openPrimerFile(direction: String) {
        let panel = NSOpenPanel()
        panel.title = "Open \(direction.capitalized) Primer"
        panel.allowedContentTypes = [.data]
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        
        guard panel.runModal() == .OK, let url = panel.url else { return }
        
        let parser = XDNAParser()
        guard let seq = parser.parseXDNA(url) else {
            errorMessage = "Could not read \(url.lastPathComponent)"
            return
        }
        
        let parts = extractPrimerParts(from: seq)
        let core = parts?.core ?? seq.sequence.uppercased()
        let tail = parts?.tail ?? ""
        
        // Set the annealing core into the correct fixed primer field
        if direction == "forward" {
            fixedFwdSequence = core
        } else {
            fixedRevSequence = core
        }
        
        // Set the tail into the appropriate custom tail field
        if direction == "forward" {
            if !tail.isEmpty {
                fwdTailMode = .custom
                fwdCustomTail = tail
                showTailSection = true
            }
        } else {
            if !tail.isEmpty {
                revTailMode = .custom
                revCustomTail = tail
                showTailSection = true
            }
        }
        
        // Clear previous results so user can re-run
        primerPairs = []
        selectedPairID = nil
        hasRun = false
        errorMessage = nil
    }
    
    
    // MARK: - Parameters Section
    
    private var parametersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Parameters")
                    .font(.headline)
                Spacer()
                if sequence.isCircular {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundColor(.blue)
                        Text("Circular")
                            .font(.system(size: 13))
                            .foregroundColor(.blue)
                    }
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "line.horizontal.3")
                            .foregroundColor(.primary.opacity(0.55))
                        Text("Linear")
                            .font(.system(size: 13))
                            .foregroundColor(.primary.opacity(0.55))
                    }
                }
            }
            
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                
                GridRow {
                    Text("Target Feature:")
                        .frame(width: 140, alignment: .trailing)
                    HStack(spacing: 8) {
                        Picker("", selection: $selectedTargetIndex) {
                            Text("— Manual —").tag(-1)
                            
                            if !sequence.features.isEmpty {
                                Section("Features") {
                                    ForEach(Array(sequence.features.enumerated()), id: \.element.id) { idx, feature in
                                        Text("\(feature.name)  (\(feature.start + 1)..\(feature.end), \(feature.end - feature.start) bp, \(feature.strand == .forward ? "+" : "−"))")
                                            .tag(idx)
                                    }
                                }
                            }
                            
                            if !sequence.orfResults.isEmpty {
                                Section("ORFs") {
                                    ForEach(Array(sequence.orfResults.enumerated()), id: \.element.id) { idx, orf in
                                        Text("\(orf.label)  (pos \(orf.position), \(orf.size) bp, \(orf.strand))")
                                            .tag(1000 + idx)
                                    }
                                }
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 400)
                        .onChange(of: selectedTargetIndex) { newValue in
                            applyTargetSelection(newValue)
                        }
                        .contextHelp("primer.targetFeature")
                    }
                }
                
                GridRow {
                    Text("Product Region:")
                        .frame(width: 140, alignment: .trailing)
                    HStack(spacing: 8) {
                        TextField("Start", text: $targetStartText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .disabled(wholePlasmidMode)
                        Text("to")
                        TextField("End", text: $targetEndText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .disabled(wholePlasmidMode)
                            .contextHelp("primer.productRegion")
                        if wholePlasmidMode {
                            Text("(entire plasmid, \(sequence.length) bp)")
                                .foregroundColor(.purple)
                                .font(.system(size: 13))
                        } else if let ps = productSize {
                            HStack(spacing: 4) {
                                Text("(\(ps) bp)")
                                    .foregroundColor(.primary.opacity(0.55))
                                    .font(.system(size: 13))
                                if wrapsOrigin {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .font(.system(size: 12))
                                        .foregroundColor(.orange)
                                        .help("Product spans the origin")
                                }
                            }
                        }
                    }
                }

                // Whole-plasmid mode — only shown for circular sequences
                if sequence.isCircular {
                    GridRow {
                        Text("")
                            .frame(width: 140, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Whole-plasmid amplification", isOn: $wholePlasmidMode)
                                .toggleStyle(.checkbox)
                                .font(.system(size: 13))
                                .contextHelp("primer.wholePlasmidMode")
                                .onChange(of: wholePlasmidMode) { on in
                                    if on {
                                        primerSiteText = targetStartText
                                        sdmMode = false   // mutually exclusive
                                    } else {
                                        // Clear any auto-generated overlap tails
                                        if addOverlapTails {
                                            fwdTailMode   = .none
                                            revTailMode   = .none
                                            fwdCustomTail = ""
                                            revCustomTail = ""
                                        }
                                        addOverlapTails = false
                                    }
                                }
                            if wholePlasmidMode {
                                HStack(spacing: 8) {
                                    Text("Primer site:")
                                        .font(.system(size: 13))
                                        .foregroundColor(.primary.opacity(0.7))
                                    TextField("Position", text: $primerSiteText)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 80)
                                        .contextHelp("primer.primerSite")
                                    Text("Primers placed back-to-back at this position, pointing outward")
                                        .font(.system(size: 12))
                                        .foregroundColor(.purple.opacity(0.8))
                                }  // end HStack

                                // Overlap tail option
                                Divider().padding(.vertical, 2)
                                Toggle("Add overlap tails for self-circularisation", isOn: $addOverlapTails)
                                    .toggleStyle(.checkbox)
                                    .font(.system(size: 13))
                                    .contextHelp("primer.overlapTails")
                                if addOverlapTails {
                                    HStack(spacing: 8) {
                                        Text("Overlap length:")
                                            .font(.system(size: 13))
                                            .foregroundColor(.primary.opacity(0.7))
                                        Stepper("\(overlapLength) bp", value: $overlapLength, in: 15...50, step: 5)
                                            .frame(width: 130)
                                    }
                                    Text("Each primer gets a \(overlapLength) bp 5′ tail homologous to the opposite end of the linear product. The ends anneal on transformation, giving a stably circular product (Gibson/SLIC style). Requires DpnI treatment of template.")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                // QuikChange alternative tip
                                Divider().padding(.vertical, 2)
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: "lightbulb")
                                        .font(.system(size: 12))
                                        .foregroundColor(.yellow)
                                        .padding(.top, 1)
                                    Text("Alternative — no tails needed: design primers that overlap each other by 15–25 bp at the chosen site using a high-fidelity polymerase. The extended strands are already topologically circular (nicked circles), so bacteria repair and replicate them without ligation. DpnI is not required — since no mutation is introduced. Use Site-Directed Mutagenesis → QuikChange → DNA sequence, enter the site position, and set the new sequence identical to the original.")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                
                GridRow {
                    Text("Primer Length:")
                        .frame(width: 140, alignment: .trailing)
                    HStack(spacing: 8) {
                        Stepper("Min \(minPrimerLength)", value: $minPrimerLength, in: 14...maxPrimerLength)
                            .frame(width: 120)
                        Stepper("Max \(maxPrimerLength)", value: $maxPrimerLength, in: minPrimerLength...35)
                            .frame(width: 120)
                        Text("bp").foregroundColor(.primary.opacity(0.55)).font(.system(size: 13))
                    }
                    .contextHelp("primer.primerLength")
                }
                
                GridRow {
                    Text("Target Tm:")
                        .frame(width: 140, alignment: .trailing)
                    HStack(spacing: 8) {
                        Slider(value: $targetTm, in: 45...80, step: 0.5)
                            .frame(width: 200)
                        Text(String(format: "%.1f \u{00B0}C", targetTm))
                            .frame(width: 60, alignment: .leading)
                            .monospacedDigit()
                    }
                    .contextHelp("primer.targetTm")
                }
                
                GridRow {
                    Text("Max \u{0394}Tm:")
                        .frame(width: 140, alignment: .trailing)
                    HStack(spacing: 8) {
                        Stepper(String(format: "%.1f \u{00B0}C", maxTmDiff), value: $maxTmDiff, in: 0.5...15.0, step: 0.5)
                            .frame(width: 140)
                    }
                    .contextHelp("primer.maxTmDiff")
                }
                
                GridRow {
                    Text("Na\u{207A} Concentration:")
                        .frame(width: 140, alignment: .trailing)
                    HStack(spacing: 8) {
                        TextField("mM", value: $saltConc, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Text("mM").foregroundColor(.primary.opacity(0.55)).font(.system(size: 13))
                    }
                    .contextHelp("primer.saltConcentration")
                }
                
                GridRow {
                    Text("Search Window:")
                        .frame(width: 140, alignment: .trailing)
                    HStack(spacing: 8) {
                        Stepper("\(searchWindow) bp", value: $searchWindow, in: 0...500, step: 10)
                            .frame(width: 130)
                        Text("Search up to \(searchWindow) bp outside target region")
                            .foregroundColor(.primary.opacity(0.55))
                            .font(.system(size: 14))
                    }
                    .contextHelp("primer.searchWindow")
                }
                
                GridRow {
                    Text("")
                        .frame(width: 140, alignment: .trailing)
                    HStack(spacing: 8) {
                        Toggle("Allow primers within target region", isOn: $allowInternalPrimers)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 13))
                        Text(allowInternalPrimers ? "(confirmatory PCR — amplicon may be shorter than target)" : "(default — primers will anneal outside target)")
                            .foregroundColor(allowInternalPrimers ? .orange : .primary.opacity(0.55))
                            .font(.system(size: 13))
                    }
                    .contextHelp("primer.allowInternal")
                }
                
                GridRow {
                    Text("Max Dimer 3' Run:")
                        .frame(width: 140, alignment: .trailing)
                    HStack(spacing: 8) {
                        Stepper("\(maxDimerScore) bp", value: $maxDimerScore, in: 2...10)
                            .frame(width: 120)
                        Text("Pairs with dimer runs of \(maxDimerScore)+ bp are rejected")
                            .foregroundColor(.primary.opacity(0.55))
                            .font(.system(size: 14))
                    }
                    .contextHelp("primer.maxDimer")
                }
            }  // end Grid

            // -- Site-Directed Mutagenesis --
            if sequence.isCircular {
                Divider().padding(.vertical, 2)
                sdmSection
            }

            // -- Fixed primer --
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text("Primer Mode:")
                        .frame(width: 140, alignment: .trailing)
                    Picker("", selection: $fixedPrimerMode) {
                        ForEach(FixedPrimerMode.allCases, id: \.self) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 380)
                    .contextHelp("primer.primerMode")
                }
                
                // Forward fixed primer field (shown for fixedForward and fixedBoth)
                if fixedPrimerMode == .fixedForward || fixedPrimerMode == .fixedBoth {
                    HStack(spacing: 8) {
                        Text("Fixed Fwd:")
                            .frame(width: 140, alignment: .trailing)
                        TextField("5\u{2032}-primer sequence-3\u{2032}", text: $fixedFwdSequence)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 300)
                        if !fixedFwdSequence.isEmpty {
                            let cleaned = fixedFwdSequence.uppercased().filter { "ACGTN".contains($0) }
                            Text("\(cleaned.count) bp")
                                .font(.system(size: 13))
                                .foregroundColor(.primary.opacity(0.55))
                        }
                        Button("Open…") {
                            openPrimerFile(direction: "forward")
                        }
                        .help("Open a forward primer .xdna file")
                        .contextHelp("primer.openForwardPrimer")
                    }
                    
                    // Show loaded fwd tail info if present
                    if !fwdCustomTail.isEmpty && fwdTailMode == .custom {
                        HStack(spacing: 8) {
                            Text("")
                                .frame(width: 140)
                            HStack(spacing: 4) {
                                Text("Tail loaded:")
                                    .font(.system(size: 12))
                                    .foregroundColor(.primary.opacity(0.55))
                                Text(fwdCustomTail)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.red)
                                Text("(\(fwdCustomTail.count) bp)")
                                    .font(.system(size: 12))
                                    .foregroundColor(.primary.opacity(0.55))
                            }
                        }
                    }
                }
                
                // Reverse fixed primer field (shown for fixedReverse and fixedBoth)
                if fixedPrimerMode == .fixedReverse || fixedPrimerMode == .fixedBoth {
                    HStack(spacing: 8) {
                        Text("Fixed Rev:")
                            .frame(width: 140, alignment: .trailing)
                        TextField("5\u{2032}-primer sequence-3\u{2032}", text: $fixedRevSequence)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 300)
                        if !fixedRevSequence.isEmpty {
                            let cleaned = fixedRevSequence.uppercased().filter { "ACGTN".contains($0) }
                            Text("\(cleaned.count) bp")
                                .font(.system(size: 13))
                                .foregroundColor(.primary.opacity(0.55))
                        }
                        Button("Open…") {
                            openPrimerFile(direction: "reverse")
                        }
                        .help("Open a reverse primer .xdna file")
                        .contextHelp("primer.openReversePrimer")
                    }
                    
                    // Show loaded rev tail info if present
                    if !revCustomTail.isEmpty && revTailMode == .custom {
                        HStack(spacing: 8) {
                            Text("")
                                .frame(width: 140)
                            HStack(spacing: 4) {
                                Text("Tail loaded:")
                                    .font(.system(size: 12))
                                    .foregroundColor(.primary.opacity(0.55))
                                Text(revCustomTail)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.red)
                                Text("(\(revCustomTail.count) bp)")
                                    .font(.system(size: 12))
                                    .foregroundColor(.primary.opacity(0.55))
                            }
                        }
                    }
                }
            }
            
            HStack {
                Button("Design Primers") {
                    runDesign()
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(targetStart == nil || targetEnd == nil || isRunning)
                .contextHelp("primer.designPrimers")
                
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.leading, 4)
                    Text("Searching...")
                        .font(.system(size: 13))
                        .foregroundColor(.primary.opacity(0.55))
                }
                
                if let err = errorMessage {
                    Text(err)
                        .foregroundColor(.red)
                        .font(.system(size: 13))
                }
            }
        }
        .padding()
    }
    
    
    // MARK: - Tail Configuration Section
    
    private var tailSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Disclosure toggle
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showTailSection.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: showTailSection ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 12)
                    Text("5\u{2032} Primer Tails")
                        .font(.headline)
                    if fwdTailMode != .none || revTailMode != .none {
                        Text("(active)")
                            .font(.system(size: 13))
                            .foregroundColor(.orange)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .contextHelp("primer.tailSection")
            
            if showTailSection {
                VStack(spacing: 12) {
                    // Forward tail
                    tailRow(
                        label: "Forward tail:",
                        mode: $fwdTailMode,
                        selectedEnzyme: $fwdSelectedEnzyme,
                        customTail: $fwdCustomTail,
                        padding5Prime: $fwdPaddingBases,
                        padding3Prime: $fwdPadding3Prime,
                        preview: fwdTail
                    )
                    
                    // Reverse tail
                    tailRow(
                        label: "Reverse tail:",
                        mode: $revTailMode,
                        selectedEnzyme: $revSelectedEnzyme,
                        customTail: $revCustomTail,
                        padding5Prime: $revPaddingBases,
                        padding3Prime: $revPadding3Prime,
                        preview: revTail
                    )
                    
                    // Info text
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle")
                            .foregroundColor(.primary.opacity(0.55))
                        Text("Tails are added to the 5\u{2032} end. 5\u{2032} padding (GC-rich) helps restriction enzymes cut near the primer end. 3\u{2032} padding (between site and annealing region) adjusts reading frame. Annealing Tm is on the binding portion only; full Tm includes the tail.")
                            .font(.system(size: 12))
                            .foregroundColor(.primary.opacity(0.55))
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
    
    /// A single tail configuration row (forward or reverse)
    private func tailRow(
        label: String,
        mode: Binding<TailMode>,
        selectedEnzyme: Binding<String>,
        customTail: Binding<String>,
        padding5Prime: Binding<Int>,
        padding3Prime: Binding<Int>,
        preview: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(label)
                    .frame(width: 100, alignment: .trailing)
                    .font(.system(size: 14))
                
                Picker("", selection: mode) {
                    ForEach(TailMode.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                .contextHelp("primer.tailMode")
            }
            
            if mode.wrappedValue == .enzyme {
                HStack(spacing: 12) {
                    Text("")
                        .frame(width: 100)
                    
                    Picker("Enzyme:", selection: selectedEnzyme) {
                        ForEach(enzymeDB.enzymes, id: \.name) { enz in
                            Text("\(enz.name) (\(enz.recognitionSite))")
                                .tag(enz.name)
                        }
                    }
                    .frame(width: 220)
                }
                
                HStack(spacing: 12) {
                    Text("")
                        .frame(width: 100)
                    
                    Stepper("5\u{2032} pad: \(padding5Prime.wrappedValue) bp", value: padding5Prime, in: 0...6)
                        .frame(width: 150)
                        .help("GC-rich bases before the RE site for efficient cutting")
                    
                    Stepper("3\u{2032} pad: \(padding3Prime.wrappedValue) bp", value: padding3Prime, in: 0...6)
                        .frame(width: 150)
                        .help("Bases between RE site and annealing region to adjust reading frame")
                }
            }
            
            if mode.wrappedValue == .custom {
                HStack(spacing: 12) {
                    Text("")
                        .frame(width: 100)
                    TextField("Custom 5\u{2032} tail sequence (A/C/G/T)", text: customTail)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                        .font(.system(.body, design: .monospaced))
                }
            }
            
            if !preview.isEmpty {
                HStack(spacing: 12) {
                    Text("")
                        .frame(width: 100)
                    
                    if mode.wrappedValue == .enzyme {
                        // Show structure breakdown for enzyme mode
                        let pad5 = paddingString(padding5Prime.wrappedValue)
                        let site = enzymeDB.enzymes.first(where: { $0.name == selectedEnzyme.wrappedValue })?.recognitionSite ?? ""
                        let pad3 = paddingString(padding3Prime.wrappedValue)
                        
                        HStack(spacing: 1) {
                            Text("5\u{2032}-")
                                .foregroundColor(.primary.opacity(0.55))
                            if !pad5.isEmpty {
                                Text(pad5)
                                    .foregroundColor(.gray)
                            }
                            Text(site)
                                .foregroundColor(.orange)
                                .fontWeight(.medium)
                            if !pad3.isEmpty {
                                Text(pad3)
                                    .foregroundColor(.gray)
                            }
                            Text("-[annealing]-3\u{2032}")
                                .foregroundColor(.primary.opacity(0.55))
                        }
                        .font(.system(size: 14, design: .monospaced))
                        
                        Text("(\(preview.count) bp tail)")
                            .font(.system(size: 13))
                            .foregroundColor(.primary.opacity(0.55))
                    } else {
                        // Custom mode - simple preview
                        HStack(spacing: 4) {
                            Text("5\u{2032}-")
                                .foregroundColor(.primary.opacity(0.55))
                            Text(preview)
                                .foregroundColor(.orange)
                                .fontWeight(.medium)
                            Text("-[annealing]-3\u{2032}")
                                .foregroundColor(.primary.opacity(0.55))
                        }
                        .font(.system(size: 14, design: .monospaced))
                        
                        Text("(\(preview.count) bp tail)")
                            .font(.system(size: 13))
                            .foregroundColor(.primary.opacity(0.55))
                    }
                }
            }
        }
    }
    
    
    // MARK: - Primer Stock Section
    
    private var primerStockSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showStockSection.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: showStockSection ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 12)
                    Text("Primer Stock")
                        .font(.headline)
                    if !stockPrimers.isEmpty {
                        Text("(\(stockPrimers.count) loaded)")
                            .font(.system(size: 13))
                            .foregroundColor(.accentColor)
                    }
                    if !stockMatches.isEmpty {
                        let fwdCount = stockMatches.filter { !$0.isReverse }.count
                        let revCount = stockMatches.filter { $0.isReverse }.count
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 12))
                            Text("\(fwdCount) fwd, \(revCount) rev bind template")
                                .font(.system(size: 13))
                                .foregroundColor(.green)
                        }
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .contextHelp("primer.primerStock")
            
            if showStockSection {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Button("Choose Folder\u{2026}") {
                            choosePrimerStockFolder()
                        }
                        .buttonStyle(.bordered)
                        .contextHelp("primer.chooseStockFolder")
                        
                        if let url = primerStockURL {
                            Image(systemName: "folder.fill")
                                .foregroundColor(.accentColor)
                            Text(url.lastPathComponent)
                                .font(.system(size: 13))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            
                            Button(action: {
                                primerStockURL = nil
                                stockPrimers = []
                                stockMatches = []
                                stockScanMessage = nil
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                            .help("Remove loaded stock primers")
                            .contextHelp("primer.removeStock")
                        }
                    }
                    
                    if let msg = stockScanMessage {
                        Text(msg)
                            .font(.system(size: 12))
                            .foregroundColor(.primary.opacity(0.55))
                    }
                    
                    if !stockPrimers.isEmpty {
                        HStack(spacing: 8) {
                            Toggle("Prefer stock in results", isOn: $preferStock)
                                .font(.system(size: 13))
                                .toggleStyle(.checkbox)
                                .help("When enabled, primer pairs that include stock primers are ranked above fully designed pairs")
                                .contextHelp("primer.preferStock")
                            
                            if !stockMatches.isEmpty {
                                let fwdCount = stockMatches.filter { !$0.isReverse }.count
                                let revCount = stockMatches.filter { $0.isReverse }.count
                                Text("\(stockMatches.count) match\(stockMatches.count == 1 ? "" : "es") on template (\(fwdCount) fwd, \(revCount) rev)")
                                    .font(.system(size: 12))
                                    .foregroundColor(.green)
                            }
                        }
                        
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(stockPrimers) { primer in
                                    let match = stockMatches.first(where: { $0.stockPrimer.id == primer.id })
                                    HStack(spacing: 8) {
                                        // Match indicator
                                        if let m = match {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.green)
                                                .font(.system(size: 11))
                                            Text(m.isReverse ? "Rev" : "Fwd")
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundColor(.green)
                                                .frame(width: 26)
                                        } else if !stockMatches.isEmpty {
                                            Image(systemName: "minus.circle")
                                                .foregroundColor(.primary.opacity(0.3))
                                                .font(.system(size: 11))
                                            Text("")
                                                .frame(width: 26)
                                        }
                                        
                                        Text(primer.name)
                                            .font(.system(size: 13))
                                            .lineLimit(1)
                                            .frame(minWidth: 120, alignment: .leading)
                                        Text(primer.coreSequence.prefix(30) + (primer.coreSequence.count > 30 ? "\u{2026}" : ""))
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundColor(.primary.opacity(0.7))
                                            .lineLimit(1)
                                        Text("\(primer.coreSequence.count) bp")
                                            .font(.system(size: 12))
                                            .foregroundColor(.primary.opacity(0.55))
                                        if let m = match {
                                            if !m.tailPortion.isEmpty {
                                                Text("(\(m.annealingSequence.count) anneal + \(m.tailPortion.count) tail)")
                                                    .font(.system(size: 11))
                                                    .foregroundColor(.orange)
                                            }
                                            Text("pos \(m.bindingPosition)")
                                                .font(.system(size: 11))
                                                .foregroundColor(.accentColor)
                                            
                                            // Explicit buttons to set this stock primer as fixed fwd or rev
                                            Button("Fix Fwd") {
                                                setStockAsFixed(primer: primer, match: m, asForward: true)
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.mini)
                                            .help("Set \(primer.name) as the fixed forward primer")
                                            
                                            Button("Fix Rev") {
                                                setStockAsFixed(primer: primer, match: m, asForward: false)
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.mini)
                                            .help("Set \(primer.name) as the fixed reverse primer")
                                        }
                                        Spacer()
                                        Text(primer.sourceFile)
                                            .font(.system(size: 11))
                                            .foregroundColor(.primary.opacity(0.4))
                                            .lineLimit(1)
                                            .truncationMode(.head)
                                    }
                                    .padding(.leading, 4)
                                }
                            }
                        }
                        .frame(maxHeight: 120)
                    }
                    
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle")
                            .foregroundColor(.primary.opacity(0.55))
                        Text("Point to a folder of .xdna primer files (sub-folders are included). Stock primers are screened against the template automatically. Use \u{201C}Use as Fixed\u{201D} to set a matched stock primer as the fixed forward or reverse primer.")
                            .font(.system(size: 12))
                            .foregroundColor(.primary.opacity(0.55))
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
    
    /// Open a folder chooser for primer stock
    private func choosePrimerStockFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Primer Stock Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.prompt = "Choose"
        
        guard panel.runModal() == .OK, let url = panel.url else { return }
        primerStockURL = url
        scanPrimerStockFolder(url)
    }
    
    /// Recursively scan a folder for .xdna primer files
    private func scanPrimerStockFolder(_ folderURL: URL) {
        stockPrimers = []
        stockScanMessage = "Scanning\u{2026}"
        
        let fm = FileManager.default
        let parser = XDNAParser()
        var loaded: [StockPrimer] = []
        var fileCount = 0
        var parseFailCount = 0
        var sizeSkipCount = 0
        
        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            stockScanMessage = "Could not read folder."
            return
        }
        
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "xdna" else { continue }
            fileCount += 1
            
            guard let seq = parser.parseXDNA(fileURL) else {
                parseFailCount += 1
                continue
            }
            
            let parts = extractPrimerParts(from: seq)
            let core = parts?.core ?? seq.sequence.uppercased()
            let tail = parts?.tail ?? ""
            
            // Only include sequences that look like primers (< 200 bp)
            guard core.count >= 10, core.count <= 200 else {
                sizeSkipCount += 1
                continue
            }
            
            // Build relative path for display
            let relativePath: String
            if let range = fileURL.path.range(of: folderURL.lastPathComponent + "/") {
                relativePath = String(fileURL.path[range.upperBound...])
            } else {
                relativePath = fileURL.lastPathComponent
            }
            
            loaded.append(StockPrimer(
                name: fileURL.deletingPathExtension().lastPathComponent,
                coreSequence: core,
                tailSequence: tail,
                fullSequence: (tail + core).uppercased(),
                sourceFile: relativePath
            ))
        }
        
        stockPrimers = loaded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        
        var msg = "Found \(fileCount) .xdna file\(fileCount == 1 ? "" : "s"), loaded \(loaded.count) primer\(loaded.count == 1 ? "" : "s")."
        if parseFailCount > 0 { msg += "  \(parseFailCount) could not be parsed." }
        if sizeSkipCount > 0 { msg += "  \(sizeSkipCount) skipped (not primer-sized)." }
        stockScanMessage = msg
        
        // Auto-screen against current template
        if hasTemplate { screenStockAgainstTemplate() }
    }
    
    /// Check whether a designed primer's annealing sequence matches any stock primer
    /// that has been screened against the current template.
    /// For forward primers, looks for stock matches at similar positions.
    /// For reverse primers, looks for reverse-orientation stock matches.
    private func stockMatch(for annealingSequence: String, isReverse: Bool = false) -> StockPrimerMatch? {
        let query = annealingSequence.uppercased()
        return stockMatches.first { match in
            guard match.isReverse == isReverse else { return false }
            let ann = match.annealingSequence
            // Exact match
            if ann == query { return true }
            // Same 3' end (one is a suffix of the other, min 15 bp overlap)
            if ann.count >= 15 && ann.hasSuffix(query) { return true }
            if query.count >= 15 && query.hasSuffix(ann) && ann.count >= 15 { return true }
            return false
        }
    }
    
    /// Set a matched stock primer as the fixed forward or reverse primer.
    /// Direction is chosen explicitly by the user via the Fix Fwd / Fix Rev buttons.
    /// If the other direction is already fixed, switches to Fix Both mode.
    private func setStockAsFixed(primer: StockPrimer, match: StockPrimerMatch, asForward: Bool) {
        if asForward {
            fixedFwdSequence = match.annealingSequence
            if fixedPrimerMode == .fixedReverse || fixedPrimerMode == .fixedBoth {
                fixedPrimerMode = .fixedBoth
            } else {
                fixedPrimerMode = .fixedForward
            }
            // Load tail if present
            if !match.tailPortion.isEmpty {
                showTailSection = true
                fwdTailMode = .custom
                fwdCustomTail = match.tailPortion
            }
        } else {
            fixedRevSequence = match.annealingSequence
            if fixedPrimerMode == .fixedForward || fixedPrimerMode == .fixedBoth {
                fixedPrimerMode = .fixedBoth
            } else {
                fixedPrimerMode = .fixedReverse
            }
            // Load tail if present
            if !match.tailPortion.isEmpty {
                showTailSection = true
                revTailMode = .custom
                revCustomTail = match.tailPortion
            }
        }
    }
    
    /// Screen all loaded stock primers against the current template sequence.
    /// For each stock primer, searches the template (both strands) using
    /// progressive trimming to find the annealing region regardless of
    /// how the tail/core was stored in the file.
    private func screenStockAgainstTemplate() {
        stockMatches = []
        guard !stockPrimers.isEmpty else { return }

        let templateSeq  = sequence.sequence.uppercased()
        let templateLen  = templateSeq.count
        let isCirc       = sequence.isCircular
        let naM          = saltConc / 1000.0
        let primers      = stockPrimers
        guard templateLen >= 15 else { return }

        let searchSeq = isCirc ? templateSeq + templateSeq : templateSeq

        DispatchQueue.global(qos: .userInitiated).async {
            var matches: [StockPrimerMatch] = []

            for stock in primers {
                let cleanedFull = stock.fullSequence.uppercased().filter { "ACGTN".contains($0) }
                guard cleanedFull.count >= 15 else { continue }

                // Forward orientation
                if let result = self.findBySuffixTrimming(cleanedFull, in: searchSeq, templateLen: templateLen) {
                    let tm = self.calculateTm(result.anneal, naM: naM)
                    let gc = self.gcPercent(result.anneal)
                    matches.append(StockPrimerMatch(
                        stockPrimer: stock, bindingPosition: result.position,
                        annealingSequence: result.anneal, tailPortion: result.tail,
                        isReverse: false, tm: tm, gcPercent: gc
                    ))
                }

                // Reverse orientation
                let rcFull = self.reverseComplement(cleanedFull)
                if let result = self.findByPrefixTrimming(rcFull, in: searchSeq, templateLen: templateLen) {
                    let originalAnneal = self.reverseComplement(result.anneal)
                    let originalTail   = String(cleanedFull.prefix(cleanedFull.count - originalAnneal.count))
                    let tm = self.calculateTm(originalAnneal, naM: naM)
                    let gc = self.gcPercent(originalAnneal)
                    let bindEnd = result.position + result.anneal.count - 1
                    let normEnd = isCirc ? ((bindEnd - 1) % templateLen) + 1 : min(bindEnd, templateLen)
                    matches.append(StockPrimerMatch(
                        stockPrimer: stock, bindingPosition: normEnd,
                        annealingSequence: originalAnneal, tailPortion: originalTail,
                        isReverse: true, tm: tm, gcPercent: gc
                    ))
                }
            }

            DispatchQueue.main.async { self.stockMatches = matches }
        }
    }
    
    /// Try progressively shorter suffixes of `primer` in `searchSeq` (trims 5' tail).
    /// Used for forward primer matching.
    private func findBySuffixTrimming(_ primer: String, in searchSeq: String, templateLen: Int) -> (anneal: String, tail: String, position: Int)? {
        let minAnneal = 15
        guard primer.count >= minAnneal else { return nil }
        for trimLen in 0...(primer.count - minAnneal) {
            let suffix = String(primer.suffix(primer.count - trimLen))
            if let range = searchSeq.range(of: suffix) {
                let pos0 = searchSeq.distance(from: searchSeq.startIndex, to: range.lowerBound)
                let pos1 = (pos0 % templateLen) + 1
                let tail = String(primer.prefix(trimLen))
                return (anneal: suffix, tail: tail, position: pos1)
            }
        }
        return nil
    }
    
    /// Try progressively shorter prefixes of `primer` in `searchSeq` (trims 3' end).
    /// Used for reverse primer matching (searching with RC, where RC(tail) is at the 3' end).
    private func findByPrefixTrimming(_ primer: String, in searchSeq: String, templateLen: Int) -> (anneal: String, tail: String, position: Int)? {
        let minAnneal = 15
        guard primer.count >= minAnneal else { return nil }
        for trimLen in 0...(primer.count - minAnneal) {
            let prefix = String(primer.prefix(primer.count - trimLen))
            if let range = searchSeq.range(of: prefix) {
                let pos0 = searchSeq.distance(from: searchSeq.startIndex, to: range.lowerBound)
                let pos1 = (pos0 % templateLen) + 1
                let tail = String(primer.suffix(trimLen))
                return (anneal: prefix, tail: tail, position: pos1)
            }
        }
        return nil
    }
    
    
    // MARK: - Feature Overlay Picker
    
    private var featureOverlaySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showFeatureOverlay.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: showFeatureOverlay ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 12)
                    Text("Show Features on Map")
                        .font(.subheadline).fontWeight(.medium)
                    if !selectedFeatureIDs.isEmpty || !selectedORFIDs.isEmpty {
                        let count = selectedFeatureIDs.count + selectedORFIDs.count
                        Text("(\(count) selected)")
                            .font(.system(size: 13))
                            .foregroundColor(.accentColor)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .contextHelp("primer.featureOverlay")
            
            if showFeatureOverlay {
                let features = sequence.features
                let orfs = sequence.orfResults
                
                if features.isEmpty && orfs.isEmpty {
                    Text("No features or ORFs on this sequence.")
                        .font(.system(size: 13))
                        .foregroundColor(.primary.opacity(0.55))
                        .padding(.leading, 18)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            if !features.isEmpty {
                                Text("Features")
                                    .font(.system(size: 13))
                                    .fontWeight(.semibold)
                                    .foregroundColor(.primary.opacity(0.55))
                                    .padding(.leading, 18)
                                ForEach(features) { feat in
                                    featureCheckRow(
                                        name: feat.name,
                                        detail: "\(feat.start)-\(feat.end) (\(feat.strand == .forward ? "+" : "-"))",
                                        color: feat.color.color,
                                        isSelected: selectedFeatureIDs.contains(feat.id),
                                        toggle: { toggleFeature(feat.id) }
                                    )
                                }
                            }
                            if !orfs.isEmpty {
                                Text("ORFs")
                                    .font(.system(size: 13))
                                    .fontWeight(.semibold)
                                    .foregroundColor(.primary.opacity(0.55))
                                    .padding(.leading, 18)
                                    .padding(.top, features.isEmpty ? 0 : 4)
                                ForEach(orfs) { orf in
                                    featureCheckRow(
                                        name: orf.label,
                                        detail: "\(orf.position)-\(orf.end) (\(orf.strand))",
                                        color: orf.isForward ? .blue : .purple,
                                        isSelected: selectedORFIDs.contains(orf.id),
                                        toggle: { toggleORF(orf.id) }
                                    )
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }
    
    private func featureCheckRow(name: String, detail: String, color: Color, isSelected: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .font(.system(size: 13))
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(name)
                    .font(.system(size: 14))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundColor(.primary.opacity(0.55))
                Spacer()
            }
            .padding(.leading, 18)
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    private func toggleFeature(_ id: UUID) {
        if selectedFeatureIDs.contains(id) {
            selectedFeatureIDs.remove(id)
        } else {
            selectedFeatureIDs.insert(id)
        }
    }
    
    private func toggleORF(_ id: UUID) {
        if selectedORFIDs.contains(id) { selectedORFIDs.remove(id) }
        else { selectedORFIDs.insert(id) }
    }


    // MARK: - Site-Directed Mutagenesis Section

    private var sdmSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle("Site-Directed Mutagenesis", isOn: $sdmMode)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 13, weight: .semibold))
                    .contextHelp("primer.sdmMode")
                    .onChange(of: sdmMode) { on in
                        if on {
                            // SDM and whole-plasmid are mutually exclusive
                            wholePlasmidMode = false
                        }
                    }
                if sdmMode {
                    Text("(circular template only — DpnI digestion required after PCR)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }

            if sdmMode {
                // Strategy
                HStack(spacing: 12) {
                    Text("Strategy:")
                        .font(.system(size: 13))
                        .frame(width: 140, alignment: .trailing)
                    Picker("", selection: $sdmStrategy) {
                        ForEach(SDMStrategy.allCases, id: \.self) { s in
                            Text(s.rawValue).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 340)
                    .contextHelp("primer.sdmStrategy")
                }

                // Strategy explanation
                Group {
                    if sdmStrategy == .quickChange {
                        Text("QuikChange: both primers overlap the mutation on opposite strands. Use with a high-fidelity polymerase. The product is the whole plasmid with the mutation on both strands.")
                    } else {
                        Text("Back-to-Back (KLD): outward-pointing primers flank the mutation. The mutant sequence goes into 5′ tails. After PCR, the linear product is circularised by Kinase-Ligase-DpnI (NEB KLD) or Gibson/SLIC. Better for larger sequence changes.")
                    }
                }
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 156)

                Divider()

                // Mutation type
                HStack(spacing: 12) {
                    Text("Mutation type:")
                        .font(.system(size: 13))
                        .frame(width: 140, alignment: .trailing)
                    Picker("", selection: $sdmMutationType) {
                        ForEach(SDMMutationType.allCases, id: \.self) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 400)
                    .contextHelp("primer.sdmMutationType")
                }

                // Mutation inputs
                switch sdmMutationType {
                case .dna:
                    sdmDNAInputs
                case .aminoAcid:
                    sdmAminoAcidInputs
                case .restrictionSite:
                    sdmRestrictionSiteInputs
                }

                // QuikChange-specific flank length
                if sdmStrategy == .quickChange {
                    HStack(spacing: 12) {
                        Text("Flank length:")
                            .font(.system(size: 13))
                            .frame(width: 140, alignment: .trailing)
                        Stepper("\(sdmFlankLength) bp each side", value: $sdmFlankLength, in: 10...25)
                            .frame(width: 180)
                            .contextHelp("primer.sdmFlankLength")
                        Text("10–15 bp recommended; mutation centred; total primer 25–45 bp, Tm ≥ 78 °C")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    // True when Sequence View has a selection on the same sequence as the chosen template
    private var hasUsableSequenceViewSelection: Bool {
        seqViewSelEnd > seqViewSelStart
    }

    private func applySequenceViewSelection() {
        guard hasUsableSequenceViewSelection else { return }
        sdmSiteText      = "\(seqViewSelStart + 1)"   // 0-based → 1-based
        sdmOriginalLength = seqViewSelEnd - seqViewSelStart
    }

    private var sdmDNAInputs: some View {
        VStack(alignment: .leading, spacing: 6) {
            // "Use Selection" row — only shown when Sequence View has a usable selection
            if hasUsableSequenceViewSelection {
                HStack(spacing: 12) {
                    Spacer().frame(width: 140)
                    Button("Use Sequence View Selection") {
                        applySequenceViewSelection()
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: 12))
                    let len = seqViewSelEnd - seqViewSelStart
                    let pos = seqViewSelStart + 1
                    Text("(\(pos)…\(pos + len - 1), \(len) bp)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            } else {
                HStack(spacing: 12) {
                    Spacer().frame(width: 140)
                    Text("Select bases in the template Sequence View to auto-fill position")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            HStack(spacing: 12) {
                Text("Mutation site:")
                    .font(.system(size: 13))
                    .frame(width: 140, alignment: .trailing)
                TextField("Position", text: $sdmSiteText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                Stepper("Replace \(sdmOriginalLength) bp", value: $sdmOriginalLength, in: 1...100)
                    .frame(width: 160)
                // Show original bases
                if let site = Int(sdmSiteText), site >= 1, site <= sequence.length {
                    let orig = sdmOriginalBases(site: site, length: sdmOriginalLength)
                    Text("Original: \(orig)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            HStack(spacing: 12) {
                Text("New sequence:")
                    .font(.system(size: 13))
                    .frame(width: 140, alignment: .trailing)
                TextField("Replacement bases (5′→3′)", text: $sdmMutantSequence)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(width: 300)
                if !sdmMutantSequence.isEmpty {
                    Text("\(sdmMutantSequence.filter { "ACGTacgt".contains($0) }.count) bp")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var sdmAminoAcidInputs: some View {
        let cdsFeatues = sequence.features.filter {
            $0.type == .cds || $0.type == .gene || $0.name.lowercased().contains("cds")
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("CDS feature:")
                    .font(.system(size: 13))
                    .frame(width: 140, alignment: .trailing)
                if cdsFeatues.isEmpty {
                    Text("No CDS features found. Switch to DNA mode and enter the codon position manually.")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                } else {
                    Picker("", selection: $sdmFeatureID) {
                        Text("— Select —").tag(nil as UUID?)
                        ForEach(cdsFeatues) { f in
                            Text("\(f.name) (\(f.start+1)–\(f.end))").tag(f.id as UUID?)
                        }
                    }
                    .frame(width: 280)
                }
            }
            // "Use Selection" row — shown when Sequence View has a usable selection
            if hasUsableSequenceViewSelection {
                HStack(spacing: 12) {
                    Spacer().frame(width: 140)
                    Button("Use Sequence View Selection") {
                        applyAASelectionFromSequenceView()
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: 12))
                    .disabled(sdmFeatureID == nil)
                    if let fid = sdmFeatureID,
                       let feat = sequence.features.first(where: { $0.id == fid }),
                       seqViewSelStart >= feat.start {
                        let codonNum = (seqViewSelStart - feat.start) / 3 + 1
                        Text("\u{2192} codon \(codonNum)")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    } else {
                        let len = seqViewSelEnd - seqViewSelStart
                        let pos = seqViewSelStart + 1
                        Text("(pos \(pos)\u{2026}\(pos + len - 1), \(len) bp \u{2014} select a CDS feature first)")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                HStack(spacing: 12) {
                    Spacer().frame(width: 140)
                    Text("Select a codon in the template Sequence View to auto-fill codon number")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            HStack(spacing: 12) {
                Text("Codon number:")
                    .font(.system(size: 13))
                    .frame(width: 140, alignment: .trailing)
                TextField("1", text: $sdmCodonNumberText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                // Show current codon/AA
                if let (currentCodon, currentAA) = sdmCurrentCodon {
                    Text("Current: \(currentCodon) (\(currentAA))")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            HStack(spacing: 12) {
                Text("New codon:")
                    .font(.system(size: 13))
                    .frame(width: 140, alignment: .trailing)
                TextField("e.g. GAC or D", text: $sdmNewCodonText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(width: 120)
                    .onChange(of: sdmNewCodonText) { _ in
                        applyAAMutationToSDM()
                    }
                // Preview
                if let resolved = resolvedNewCodon {
                    Text("\u{2192} \(resolved.codon) (\(resolved.aa))")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.blue)
                }
            }
            Text("Enter a 3-letter codon (e.g. GAC) or a single amino-acid letter (e.g. D). For a stop codon enter * or TGA/TAA/TAG.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .padding(.leading, 156)
        }
    }

    private var sdmRestrictionSiteInputs: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("Action:")
                    .font(.system(size: 13))
                    .frame(width: 140, alignment: .trailing)
                Picker("", selection: $sdmREAction) {
                    ForEach(SDMREAction.allCases, id: \.self) { a in
                        Text(a.rawValue).tag(a)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }
            HStack(spacing: 12) {
                Text("Enzyme:")
                    .font(.system(size: 13))
                    .frame(width: 140, alignment: .trailing)
                Picker("", selection: $sdmREName) {
                    ForEach(enzymeDB.enzymes.filter { $0.recognitionSite.count >= 4 }, id: \.name) { e in
                        Text("\(e.name)  (\(e.recognitionSite))").tag(e.name)
                    }
                }
                .frame(width: 200)
            }
            // "Use Selection" row — shown when Sequence View has a usable selection
            if hasUsableSequenceViewSelection {
                HStack(spacing: 12) {
                    Spacer().frame(width: 140)
                    Button("Use Sequence View Selection") {
                        applyRESelectionFromSequenceView()
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: 12))
                    let len = seqViewSelEnd - seqViewSelStart
                    let pos = seqViewSelStart + 1
                    Text("(pos \(pos)\u{2026}\(pos + len - 1), \(len) bp)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            } else {
                HStack(spacing: 12) {
                    Spacer().frame(width: 140)
                    Text("Select the site in the template Sequence View to auto-fill position")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            HStack(spacing: 12) {
                Text(sdmREAction == .introduce ? "Site position:" : "Existing site:")
                    .font(.system(size: 13))
                    .frame(width: 140, alignment: .trailing)
                TextField("Position", text: $sdmRESiteText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                // For destroy: show the recognition site at that position
                if sdmREAction == .destroy,
                   let site = Int(sdmRESiteText),
                   let enz  = enzymeDB.enzymes.first(where: { $0.name == sdmREName }) {
                    let siteSeq = sdmOriginalBases(site: site, length: enz.recognitionSite.count)
                    let match = siteSeq.uppercased() == enz.recognitionSite.uppercased()
                    Text(match ? "\u{2713} \(enz.recognitionSite) found" : "\u{26A0} site not found at this position")
                        .font(.system(size: 12))
                        .foregroundColor(match ? .green : .orange)
                }
            }
            if sdmREAction == .introduce {
                Text("The minimal number of silent substitutions needed to create the site will be computed automatically.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.leading, 156)
            } else {
                Text("One or more bases in the recognition site will be silently mutated to destroy cutting without changing the protein (if in a CDS).")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.leading, 156)
            }
        }
    }

    // MARK: - SDM helper computed properties

    /// The current template bases at the SDM site
    private func sdmOriginalBases(site: Int, length: Int) -> String {
        let seq = sequence.sequence.uppercased()
        let len = seq.count
        guard site >= 1, len > 0 else { return "" }
        let start0 = site - 1
        return Self.extractStatic(from: seq, start0: start0, length: length, circular: sequence.isCircular)
    }

    /// Current codon and amino acid at sdmCodonNumber within the selected CDS feature
    private var sdmCurrentCodon: (codon: String, aa: String)? {
        guard let fid = sdmFeatureID,
              let feat = sequence.features.first(where: { $0.id == fid }),
              let codonNum = Int(sdmCodonNumberText), codonNum >= 1 else { return nil }
        let seq = sequence.sequence.uppercased()
        let cdsStart0 = feat.start  // 0-based
        let codonStart0 = cdsStart0 + (codonNum - 1) * 3
        let codon = Self.extractStatic(from: seq, start0: codonStart0, length: 3, circular: sequence.isCircular)
        guard codon.count == 3 else { return nil }
        return (codon: codon, aa: String(translateCodon(codon)))
    }

    /// Resolved new codon from user input (3-letter DNA or 1-letter AA)
    private var resolvedNewCodon: (codon: String, aa: String)? {
        let t = sdmNewCodonText.uppercased().filter { "ACGT*FLIMSPTAYHQNDECWRG".contains($0) }
        guard !t.isEmpty else { return nil }
        if t.count == 1 {
            let aa = Character(t)
            let codon = preferredCodon(for: aa)
            return (codon: codon, aa: t)
        } else if t.count == 3 && t.allSatisfy({ "ACGT".contains($0) }) {
            let aa = String(translateCodon(t))
            return (codon: t, aa: aa)
        }
        return nil
    }

    /// When user selects a new codon in AA mode, auto-populate the DNA mutation fields
    private func applyAAMutationToSDM() {
        guard let resolved = resolvedNewCodon,
              let fid = sdmFeatureID,
              let feat = sequence.features.first(where: { $0.id == fid }),
              let codonNum = Int(sdmCodonNumberText), codonNum >= 1 else { return }
        let cdsStart0  = feat.start
        let codonStart = cdsStart0 + (codonNum - 1) * 3 + 1  // 1-based
        sdmSiteText        = "\(codonStart)"
        sdmOriginalLength  = 3
        sdmMutantSequence  = resolved.codon
    }

    /// Fill the codon number from a Sequence View selection (amino acid mode).
    /// Requires a CDS feature to be selected — the codon is calculated as the
    /// offset of the selection start from the CDS start, divided by 3.
    private func applyAASelectionFromSequenceView() {
        guard hasUsableSequenceViewSelection,
              let fid = sdmFeatureID,
              let feat = sequence.features.first(where: { $0.id == fid }) else { return }
        let selStart0 = seqViewSelStart   // 0-based
        let cdsStart0 = feat.start        // 0-based
        guard selStart0 >= cdsStart0 else { return }
        let offsetInCDS = selStart0 - cdsStart0
        let codonNum = offsetInCDS / 3 + 1
        sdmCodonNumberText = "\(codonNum)"
    }

    /// Fill the restriction site position from a Sequence View selection.
    private func applyRESelectionFromSequenceView() {
        guard hasUsableSequenceViewSelection else { return }
        sdmRESiteText = "\(seqViewSelStart + 1)"   // 0-based → 1-based
    }
    
    private let mapPadding: CGFloat = 20
    private let barY: CGFloat = 30
    private let barHeight: CGFloat = 14
    private let handleWidth: CGFloat = 8
    private let handleHeight: CGFloat = 28
    
    private func xToPosition(_ x: CGFloat, totalWidth: CGFloat) -> Int {
        let seqLen = CGFloat(max(sequence.length, 1))
        let fraction = max(0, min(1, (x - mapPadding) / totalWidth))
        return max(1, min(sequence.length, Int(round(fraction * seqLen)) + 1))
    }
    
    private func positionToX(_ pos: Int, totalWidth: CGFloat) -> CGFloat {
        let seqLen = CGFloat(max(sequence.length, 1))
        return mapPadding + (CGFloat(pos - 1) / seqLen) * totalWidth
    }
    
    /// For the Introduce action: substitute the recognition sequence directly at the position.
    private func createRESite(_ reSite: String, at position: Int, in seq: String) -> String? {
        let cleaned = reSite.uppercased().filter { "ACGT".contains($0) }
        return cleaned.isEmpty ? nil : cleaned
    }

    /// For the Destroy action: change one base of the recognition site at the position.
    private func destroyRESite(_ reSite: String, at position: Int, in seq: String) -> String? {
        let seqLen = seq.count
        guard position >= 1, position <= seqLen else { return nil }
        let current = Self.extractStatic(from: seq, start0: position - 1, length: reSite.count, circular: sequence.isCircular)
        guard current.uppercased() == reSite.uppercased() else { return nil }
        var bases = Array(current.uppercased())
        let lastIdx = bases.count - 1
        for alt: Character in ["A","C","G","T"] where alt != bases[lastIdx] {
            bases[lastIdx] = alt
            let candidate = String(bases)
            if candidate.uppercased() != reSite.uppercased() { return candidate }
        }
        return nil
    }

    private var ampliconMapSection: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width - mapPadding * 2
            let seqLen = CGFloat(max(sequence.length, 1))

            ZStack(alignment: .topLeading) {
                if wholePlasmidMode {
                let site = Int(primerSiteText) ?? 1
                let siteX = mapPadding + (CGFloat(site - 1) / seqLen) * totalWidth

                ZStack(alignment: .topLeading) {
                    // Full bar highlighted purple — product is the whole plasmid
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.purple.opacity(0.25))
                        .frame(width: totalWidth, height: barHeight)
                        .offset(x: mapPadding, y: barY)

                    // Site marker line
                    Rectangle()
                        .fill(Color.purple)
                        .frame(width: 2, height: barHeight + 8)
                        .offset(x: siteX - 1, y: barY - 4)

                    // Outward-pointing arrows at site
                    Text("◄")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.red)
                        .offset(x: max(siteX - 16, mapPadding), y: barY - 14)
                    Text("►")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.green)
                        .offset(x: siteX + 4, y: barY - 14)

                    Text("Whole plasmid (\(sequence.length) bp)")
                        .font(.system(size: 9))
                        .foregroundColor(.purple)
                        .offset(x: mapPadding + totalWidth / 2 - 50, y: 16)

                    Text("Site \(site)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.purple)
                        .offset(x: max(siteX - 16, mapPadding), y: barY + barHeight + 6)

                    // Draggable site handle
                    dragHandle(x: siteX, isDragging: isDraggingStart, totalWidth: totalWidth,
                        onDrag: { pos in isDraggingStart = true; primerSiteText = "\(pos)" },
                        onEnd: { isDraggingStart = false })

                    // Primer arrows from result
                    if let pair = selectedPair {
                        primerArrows(pair: pair, seqLen: seqLen, totalWidth: totalWidth)
                    }

                    // Position labels
                    positionLabels(totalWidth: totalWidth)
                }

            } else {
                let startPos = CGFloat(max((targetStart ?? 1) - 1, 0))
                let endPos   = CGFloat(min(targetEnd ?? sequence.length, sequence.length))
                let startX = mapPadding + (startPos / seqLen) * totalWidth
                let endX   = mapPadding + (endPos / seqLen) * totalWidth

                ZStack(alignment: .topLeading) {

                    // Full sequence bar (grey)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.25))
                        .frame(width: totalWidth, height: barHeight)
                        .offset(x: mapPadding, y: barY)

                    // Amplicon region
                    if wrapsOrigin {
                        let rightW = mapPadding + totalWidth - startX
                        let leftW  = endX - mapPadding

                        if rightW > 0 {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.accentColor.opacity(0.35))
                                .frame(width: max(rightW, 2), height: barHeight)
                                .offset(x: startX, y: barY)
                        }
                        if leftW > 0 {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.accentColor.opacity(0.35))
                                .frame(width: max(leftW, 2), height: barHeight)
                                .offset(x: mapPadding, y: barY)
                        }

                        Path { path in
                            let connY = barY + barHeight + 4
                            let midY  = connY + 12
                            path.move(to: CGPoint(x: mapPadding + totalWidth, y: connY))
                            path.addCurve(
                                to: CGPoint(x: mapPadding, y: connY),
                                control1: CGPoint(x: mapPadding + totalWidth + 6, y: midY),
                                control2: CGPoint(x: mapPadding - 6, y: midY)
                            )
                        }
                        .stroke(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))

                        Text("origin \u{21BB}")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(.orange)
                            .offset(x: mapPadding + totalWidth / 2 - 18, y: barY + barHeight + 14)

                        Text("Amplicon (spans origin)")
                            .font(.system(size: 9))
                            .foregroundColor(.accentColor)
                            .offset(x: mapPadding + totalWidth / 2 - 50, y: 16)

                    } else {
                        let ampW = endX - startX
                        if ampW > 0 {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.accentColor.opacity(0.35))
                                .frame(width: max(ampW, 2), height: barHeight)
                                .offset(x: startX, y: barY)

                            Text("Amplicon")
                                .font(.system(size: 9))
                                .foregroundColor(.accentColor)
                                .offset(x: startX + ampW / 2 - 22, y: 16)
                        }
                    }

                    featureOverlayBars(seqLen: seqLen, totalWidth: totalWidth)

                    dragHandle(x: startX, isDragging: isDraggingStart, totalWidth: totalWidth,
                        onDrag: { pos in isDraggingStart = true; targetStartText = "\(pos)" },
                        onEnd: { isDraggingStart = false })

                    dragHandle(x: endX, isDragging: isDraggingEnd, totalWidth: totalWidth,
                        onDrag: { pos in isDraggingEnd = true; targetEndText = "\(pos)" },
                        onEnd: { isDraggingEnd = false })

                    if let pair = selectedPair {
                        primerArrows(pair: pair, seqLen: seqLen, totalWidth: totalWidth)
                    }

                    positionLabels(totalWidth: totalWidth)
                }
            } // end else
            } // end outer ZStack
            .coordinateSpace(name: "ampliconMap")
        }
        .frame(height: {
            var h: CGFloat = 84
            if wrapsOrigin { h = 100 }
            let overlayCount = selectedFeatureIDs.count + selectedORFIDs.count
            if overlayCount > 0 { h += 20 }
            return h
        }())
        .padding(.horizontal, 4)
    }
    
    private func dragHandle(
        x: CGFloat,
        isDragging: Bool,
        totalWidth: CGFloat,
        onDrag: @escaping (Int) -> Void,
        onEnd: @escaping () -> Void
    ) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(isDragging ? Color.accentColor : Color.accentColor.opacity(0.7))
            .frame(width: handleWidth, height: handleHeight)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.accentColor, lineWidth: 1)
            )
            .offset(x: x - handleWidth / 2, y: barY - (handleHeight - barHeight) / 2)
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("ampliconMap"))
                    .onChanged { value in
                        let newPos = xToPosition(value.location.x, totalWidth: totalWidth)
                        let clamped = max(1, min(sequence.length, newPos))
                        onDrag(clamped)
                    }
                    .onEnded { _ in onEnd() }
            )
    }
    
    private func primerArrows(pair: PrimerPair, seqLen: CGFloat, totalWidth: CGFloat) -> some View {
        let fwdX = mapPadding + (CGFloat(pair.forward.position - 1) / seqLen) * totalWidth
        let fwdW = (CGFloat(pair.forward.length) / seqLen) * totalWidth
        let revX = mapPadding + (CGFloat(pair.reverse.position - 1) / seqLen) * totalWidth
        let revW = (CGFloat(pair.reverse.length) / seqLen) * totalWidth
        
        return ZStack(alignment: .topLeading) {
            PrimerArrowShape(pointsRight: true)
                .fill(Color.green.opacity(0.7))
                .frame(width: max(fwdW, 8), height: 8)
                .offset(x: fwdX, y: 20)
            Text("Fwd")
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(.green)
                .offset(x: fwdX, y: 10)
            
            PrimerArrowShape(pointsRight: false)
                .fill(Color.red.opacity(0.7))
                .frame(width: max(revW, 8), height: 8)
                .offset(x: revX, y: 45)
            Text("Rev")
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(.red)
                .offset(x: revX + max(revW, 8) - 16, y: 55)
        }
    }
    
    private func positionLabels(totalWidth: CGFloat) -> some View {
        let labelY: CGFloat = wrapsOrigin ? 80 : 68
        return ZStack(alignment: .topLeading) {
            Text("1")
                .font(.system(size: 9))
                .foregroundColor(.primary.opacity(0.55))
                .offset(x: mapPadding, y: labelY)
            Text("\(sequence.length) bp")
                .font(.system(size: 9))
                .foregroundColor(.primary.opacity(0.55))
                .offset(x: mapPadding + totalWidth - 36, y: labelY)
            if let s = targetStart {
                let sX = positionToX(s, totalWidth: totalWidth)
                Text("\(s)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .offset(x: max(sX - 10, mapPadding), y: labelY)
            }
            if let e = targetEnd {
                let eX = positionToX(e, totalWidth: totalWidth)
                Text("\(e)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .offset(x: min(eX - 10, mapPadding + totalWidth - 36), y: labelY)
            }
        }
    }
    
    /// Draw coloured bars for selected features and ORFs on the amplicon map
    private func featureOverlayBars(seqLen: CGFloat, totalWidth: CGFloat) -> some View {
        let featureBarHeight: CGFloat = 6
        let featureY: CGFloat = barY - featureBarHeight - 2  // just above the sequence bar
        
        return ZStack(alignment: .topLeading) {
            // Features
            ForEach(sequence.features.filter { selectedFeatureIDs.contains($0.id) }) { feat in
                let x1 = mapPadding + (CGFloat(feat.start - 1) / seqLen) * totalWidth
                let x2 = mapPadding + (CGFloat(feat.end) / seqLen) * totalWidth
                let w = max(x2 - x1, 2)
                
                RoundedRectangle(cornerRadius: 2)
                    .fill(feat.color.color.opacity(0.7))
                    .frame(width: w, height: featureBarHeight)
                    .offset(x: x1, y: featureY)
                    .help("\(feat.name) (\(feat.start)-\(feat.end))")
                
                // Label if wide enough
                if w > 30 {
                    Text(feat.name)
                        .font(.system(size: 7))
                        .foregroundColor(feat.color.color)
                        .lineLimit(1)
                        .offset(x: x1 + 2, y: featureY - 9)
                }
            }
            
            // ORFs (drawn slightly below features, above the bar)
            let orfY = featureY - (selectedFeatureIDs.isEmpty ? 0 : featureBarHeight + 2)
            ForEach(sequence.orfResults.filter { selectedORFIDs.contains($0.id) }) { orf in
                let orfColor: Color = orf.isForward ? .blue : .purple
                let x1 = mapPadding + (CGFloat(orf.position - 1) / seqLen) * totalWidth
                let x2 = mapPadding + (CGFloat(orf.end) / seqLen) * totalWidth
                let w = max(x2 - x1, 2)
                
                RoundedRectangle(cornerRadius: 2)
                    .fill(orfColor.opacity(0.5))
                    .frame(width: w, height: featureBarHeight)
                    .offset(x: x1, y: orfY)
                    .help("\(orf.label) (\(orf.position)-\(orf.end), \(orf.strand))")
                
                if w > 30 {
                    Text(orf.label)
                        .font(.system(size: 7))
                        .foregroundColor(orfColor)
                        .lineLimit(1)
                        .offset(x: x1 + 2, y: orfY - 9)
                }
            }
        }
    }
    
    
    // MARK: - Results Table
    
    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Primer Pairs")
                    .font(.headline)
                Spacer()
                if hasRun {
                    Text(primerPairs.count >= 500
                         ? "Top 500 pairs shown (ranked by suitability)"
                         : "\(primerPairs.count) pair\(primerPairs.count == 1 ? "" : "s") found")
                        .font(.system(size: 13))
                        .foregroundColor(.primary.opacity(0.55))
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            
            if primerPairs.isEmpty && hasRun {
                VStack(spacing: 6) {
                    Text("No suitable primer pairs found.")
                        .foregroundColor(.primary.opacity(0.55))
                    Text("Try adjusting the target Tm, primer length, max \u{0394}Tm, search window, or dimer threshold.")
                        .font(.system(size: 13))
                        .foregroundColor(.primary.opacity(0.55))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(primerPairs, selection: $selectedPairID) {
                    TableColumn("#") { pair in
                        if let idx = primerPairs.firstIndex(where: { $0.id == pair.id }) {
                            Text("\(idx + 1)").monospacedDigit()
                        }
                    }
                    .width(min: 28, ideal: 32, max: 40)
                    
                    TableColumn("Length") { pair in
                        Text("\(pair.forward.length)/\(pair.reverse.length)")
                            .monospacedDigit()
                            .contextHelp("primer.colLength")
                    }
                    .width(min: 50, ideal: 60, max: 72)
                    
                    TableColumn("Fwd Tm") { pair in
                        Text(String(format: "%.1f\u{00B0}C", pair.forward.tm))
                            .monospacedDigit()
                            .contextHelp("primer.colTm")
                    }
                    .width(min: 55, ideal: 62, max: 72)
                    
                    TableColumn("Rev Tm") { pair in
                        Text(String(format: "%.1f\u{00B0}C", pair.reverse.tm))
                            .monospacedDigit()
                            .contextHelp("primer.colTm")
                    }
                    .width(min: 55, ideal: 62, max: 72)
                    
                    TableColumn("\u{0394}Tm") { pair in
                        Text(String(format: "%.1f", pair.tmDifference))
                            .monospacedDigit()
                            .foregroundColor(pair.tmDifference > maxTmDiff ? .red : .primary)
                            .contextHelp("primer.colDeltaTm")
                    }
                    .width(min: 36, ideal: 42, max: 52)
                    
                    TableColumn("GC%") { pair in
                        HStack(spacing: 2) {
                            Text(String(format: "%.0f", pair.forward.gcPercent))
                                .foregroundColor(gcColor(pair.forward.gcPercent))
                            Text("/")
                                .foregroundColor(.primary.opacity(0.55))
                            Text(String(format: "%.0f", pair.reverse.gcPercent))
                                .foregroundColor(gcColor(pair.reverse.gcPercent))
                        }
                        .monospacedDigit()
                        .contextHelp("primer.colGC")
                    }
                    .width(min: 55, ideal: 65, max: 80)
                    
                    TableColumn("Dimer") { pair in
                        Text("\(pair.worstDimerScore)")
                            .monospacedDigit()
                            .foregroundColor(dimerColor(pair.worstDimerScore))
                            .contextHelp("primer.colDimer")
                    }
                    .width(min: 40, ideal: 48, max: 58)
                    
                    TableColumn("Offset") { pair in
                        Group {
                            if pair.totalOffset == 0 {
                                Text("0")
                                    .monospacedDigit()
                                    .foregroundColor(.green)
                            } else {
                                Text("+\(pair.totalOffset)")
                                    .monospacedDigit()
                                    .foregroundColor(.primary.opacity(0.55))
                            }
                        }
                        .contextHelp("primer.colOffset")
                    }
                    .width(min: 40, ideal: 48, max: 58)
                    
                    TableColumn("Product") { pair in
                        HStack(spacing: 2) {
                            Text("\(pair.productSize) bp").monospacedDigit()
                            if wrapsOrigin {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 8))
                                    .foregroundColor(.orange)
                            }
                        }
                        .contextHelp("primer.colProduct")
                    }
                    .width(min: 60, ideal: 72, max: 85)
                    
                    TableColumn("Stock") { pair in
                        let sc = pair.stockCount
                        Group {
                            if sc == 2 {
                                HStack(spacing: 2) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                        .font(.system(size: 11))
                                    Text("Both")
                                        .font(.system(size: 11))
                                        .foregroundColor(.green)
                                }
                            } else if pair.forward.isStock {
                                HStack(spacing: 2) {
                                    Image(systemName: "checkmark.circle")
                                        .foregroundColor(.green)
                                        .font(.system(size: 11))
                                    Text("Fwd")
                                        .font(.system(size: 11))
                                        .foregroundColor(.green)
                                }
                            } else if pair.reverse.isStock {
                                HStack(spacing: 2) {
                                    Image(systemName: "checkmark.circle")
                                        .foregroundColor(.green)
                                        .font(.system(size: 11))
                                    Text("Rev")
                                        .font(.system(size: 11))
                                        .foregroundColor(.green)
                                }
                            } else {
                                Text("")
                            }
                        }
                        .contextHelp("primer.colStock")
                    }
                    .width(min: 50, ideal: 60, max: 75)
                }
                .tableStyle(.bordered)
            }
        }
    }
    
    
    // MARK: - Detail / Copy Section
    
    private var detailSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let pair = selectedPair {
                    primerDetailRow(
                        title: "Forward Primer",
                        candidate: pair.forward,
                        tail: fwdTail,
                        copyLabel: "forward"
                    )
                    
                    Divider()
                    
                    primerDetailRow(
                        title: "Reverse Primer",
                        candidate: pair.reverse,
                        tail: revTail,
                        copyLabel: "reverse"
                    )
                    
                    // Dimer / wrap info
                    if pair.crossDimerScore > 0 || wrapsOrigin {
                        Divider()
                        VStack(alignment: .leading, spacing: 4) {
                            if pair.crossDimerScore > 0 {
                                HStack(spacing: 6) {
                                    Image(systemName: pair.crossDimerScore >= maxDimerScore ? "exclamationmark.triangle.fill" : "info.circle")
                                        .foregroundColor(dimerColor(pair.crossDimerScore))
                                    Text("Cross-dimer 3\u{2032} complementarity: \(pair.crossDimerScore) bp")
                                        .font(.system(size: 13))
                                        .foregroundColor(dimerColor(pair.crossDimerScore))
                                }
                            }
                            if wrapsOrigin {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .foregroundColor(.orange)
                                    Text("This product spans the origin of the circular sequence.")
                                        .font(.system(size: 13))
                                        .foregroundColor(.orange)
                                }
                            }
                        }
                    }
                    
                    Divider()
                    
                    // Copy Both and Run PCR buttons
                    HStack {
                        Spacer()
                        Button("Copy Both") {
                            let fFull = fullPrimer(tail: fwdTail, annealing: pair.forward.sequence)
                            let rFull = fullPrimer(tail: revTail, annealing: pair.reverse.sequence)
                            var text = "Forward: 5\u{2032}-\(fFull)-3\u{2032}"
                            if !fwdTail.isEmpty {
                                text += "  (tail: \(fwdTail.lowercased()), annealing: \(pair.forward.sequence.uppercased()))"
                            }
                            text += "\nReverse: 5\u{2032}-\(rFull)-3\u{2032}"
                            if !revTail.isEmpty {
                                text += "  (tail: \(revTail.lowercased()), annealing: \(pair.reverse.sequence.uppercased()))"
                            }
                            text += "\nProduct: \(pair.productSize) bp"
                            text += "\nAnnealing Tm: Fwd \(String(format: "%.1f", pair.forward.tm))\u{00B0}C  Rev \(String(format: "%.1f", pair.reverse.tm))\u{00B0}C"
                            if !fwdTail.isEmpty || !revTail.isEmpty {
                                let naM = saltConc / 1000.0
                                let fFullTm = calculateTm(fFull, naM: naM)
                                let rFullTm = calculateTm(rFull, naM: naM)
                                text += "\nFull Tm (with tail): Fwd \(String(format: "%.1f", fFullTm))\u{00B0}C  Rev \(String(format: "%.1f", rFullTm))\u{00B0}C"
                            }
                            if wrapsOrigin {
                                text += "\nNote: Product spans the origin of a circular template."
                            }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                            copiedField = "both"
                            clearCopiedAfterDelay()
                        }
                        .buttonStyle(.bordered)
                        .contextHelp("primer.copyBoth")
                        if copiedField == "both" {
                            Text("Copied!").font(.system(size: 12)).foregroundColor(.green)
                        }
                        
                        Button("Run PCR with These Primers…") {
                            let transfer = PCRPrimerTransfer.shared
                            transfer.fwdAnnealing = pair.forward.sequence
                            transfer.revAnnealing = pair.reverse.sequence
                            transfer.fwdTail = fwdTail.isEmpty ? nil : fwdTail
                            transfer.revTail = revTail.isEmpty ? nil : revTail
                            transfer.sequenceID = sequence.id
                            PCRSimulationWindowManager.shared.openWindowWithTransfer()
                        }
                        .buttonStyle(.bordered)
                        .contextHelp("primer.runPCRWithThese")

                        // SDM note
                        if sdmMode {
                            Text(sdmStrategy == .quickChange
                                 ? "QuikChange: template is the circular plasmid. DpnI-digest product after PCR."
                                 : "KLD: after PCR, treat with Kinase + Ligase + DpnI to circularise.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else if hasRun && !primerPairs.isEmpty {
                    Text("Select a primer pair above to see details")
                        .foregroundColor(.primary.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .center)
                } else if !hasRun {
                    Text("Set parameters and click Design Primers")
                        .foregroundColor(.primary.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding()
        }
        .frame(minHeight: 140)
    }
    
    /// Detail row for a single primer showing annealing and (if tailed) full sequence with both Tms
    private func primerDetailRow(title: String, candidate: PrimerCandidate, tail: String, copyLabel: String) -> some View {
        let hasTail = !tail.isEmpty
        let fullSeq = fullPrimer(tail: tail, annealing: candidate.sequence)
        let naM = saltConc / 1000.0
        let fullTm = hasTail ? calculateTm(fullSeq, naM: naM) : candidate.tm
        
        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13))
                    .fontWeight(.semibold)
                    .foregroundColor(.primary.opacity(0.55))
                
                if hasTail {
                    // Show full primer with tail (lowercase, orange) + core (uppercase)
                    HStack(spacing: 0) {
                        Text("5\u{2032}- ")
                            .font(.system(.body, design: .monospaced))
                        Text(tail.lowercased())
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.orange)
                        Text(candidate.sequence.uppercased())
                            .font(.system(.body, design: .monospaced))
                        Text(" -3\u{2032}")
                            .font(.system(.body, design: .monospaced))
                    }
                    .textSelection(.enabled)
                    
                    // Tm info: annealing Tm and full Tm
                    HStack(spacing: 12) {
                        Text("\(fullSeq.count) bp total (\(tail.count) tail + \(candidate.length) annealing)")
                        Text(String(format: "Annealing Tm %.1f \u{00B0}C", candidate.tm))
                        Text(String(format: "Full Tm %.1f \u{00B0}C", fullTm))
                            .fontWeight(.medium)
                    }
                    .font(.system(size: 13))
                    .foregroundColor(.primary.opacity(0.55))
                    
                } else {
                    // No tail -- simple display
                    Text("5\u{2032}- \(candidate.sequence.uppercased()) -3\u{2032}")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                
                // Standard info line
                HStack(spacing: 12) {
                    if !hasTail {
                        Text("\(candidate.length) bp")
                        Text(String(format: "Tm %.1f \u{00B0}C", candidate.tm))
                    }
                    Text(String(format: "GC %.0f%%", candidate.gcPercent))
                    Text("Pos \(candidate.position)")
                    if candidate.offsetFromTarget > 0 {
                        Text("\(candidate.offsetFromTarget) bp outside target")
                            .foregroundColor(.orange)
                    } else {
                        Text("on target")
                            .foregroundColor(.green)
                    }
                    if candidate.selfDimerScore > 0 {
                        Text("Self-dimer: \(candidate.selfDimerScore) bp")
                            .foregroundColor(dimerColor(candidate.selfDimerScore))
                    }
                }
                .font(.system(size: 13))
                .foregroundColor(.primary.opacity(0.55))
                
                // Stock match indicator
                if candidate.isStock, let name = candidate.stockName {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("In Stock:")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.green)
                        Text(name)
                            .font(.system(size: 13))
                            .foregroundColor(.primary)
                    }
                } else if let match = stockMatch(for: candidate.sequence, isReverse: copyLabel == "reverse") {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("In Stock:")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.green)
                        Text(match.stockPrimer.name)
                            .font(.system(size: 13))
                            .foregroundColor(.primary)
                        if !match.tailPortion.isEmpty {
                            Text("(tail: \(match.tailPortion.count) bp)")
                                .font(.system(size: 12))
                                .foregroundColor(.orange)
                        }
                    }
                }
            }
            
            Spacer(minLength: 20)
            
            VStack(spacing: 4) {
                Button(hasTail ? "Copy Full" : "Copy") {
                    copyToClipboard(fullSeq, label: copyLabel)
                }
                .buttonStyle(.bordered)
                
                if hasTail {
                    Button("Copy Annealing") {
                        copyToClipboard(candidate.sequence, label: copyLabel + "_ann")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                
                Button("Save…") {
                    exportSinglePrimer(name: copyLabel == "forward" ? "Forward" : "Reverse",
                                       annealing: candidate.sequence,
                                       tail: tail)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
                if copiedField == copyLabel || copiedField == copyLabel + "_ann" {
                    Text("Copied!").font(.system(size: 12)).foregroundColor(.green)
                }
                if copiedField == copyLabel + "_saved" {
                    Text("Saved!").font(.system(size: 12)).foregroundColor(.green)
                }
            }
        }
    }
    
    
    // MARK: - Primer Design Algorithm
    
    private func runDesign() {
        errorMessage = nil
        copiedField = nil
        primerPairs = []
        selectedPairID = nil
        hasRun = true

        // ── Site-Directed Mutagenesis path ────────────────────────────────────
        if sdmMode {
            guard sequence.isCircular else {
                errorMessage = "SDM requires a circular template."
                return
            }

            // Resolve the mutant sequence from whichever input mode was used
            let mutantSeq: String
            let mutSite: Int
            let origLen: Int

            switch sdmMutationType {
            case .dna:
                guard let s = Int(sdmSiteText), s >= 1, s <= sequence.length else {
                    errorMessage = "Enter a valid mutation site position."
                    return
                }
                let cleaned = sdmMutantSequence.uppercased().filter { "ACGT".contains($0) }
                guard !cleaned.isEmpty else {
                    errorMessage = "Enter the replacement DNA sequence."
                    return
                }
                mutantSeq = cleaned
                mutSite   = s
                origLen   = sdmOriginalLength

            case .aminoAcid:
                guard let resolved = resolvedNewCodon else {
                    errorMessage = "Enter a valid new codon or amino acid letter."
                    return
                }
                guard let fid = sdmFeatureID,
                      let feat = sequence.features.first(where: { $0.id == fid }),
                      let codonNum = Int(sdmCodonNumberText), codonNum >= 1 else {
                    errorMessage = "Select a CDS feature and enter a codon number."
                    return
                }
                mutantSeq = resolved.codon
                mutSite   = feat.start + (codonNum - 1) * 3 + 1   // 1-based
                origLen   = 3

            case .restrictionSite:
                guard let enz = enzymeDB.enzymes.first(where: { $0.name == sdmREName }),
                      let s = Int(sdmRESiteText), s >= 1, s <= sequence.length else {
                    errorMessage = "Select an enzyme and valid site position."
                    return
                }
                let reSite = enz.recognitionSite.uppercased()
                if sdmREAction == .introduce {
                    // Find minimal mutations to create the site at position s
                    if let created = createRESite(reSite, at: s, in: sequence.sequence.uppercased()) {
                        mutantSeq = created
                    } else {
                        errorMessage = "Could not create \(sdmREName) site at position \(s) with silent mutations only. Try a nearby position."
                        return
                    }
                    mutSite = s
                    origLen = reSite.count
                } else {
                    // Destroy: change one base in the recognition site
                    if let destroyed = destroyRESite(reSite, at: s, in: sequence.sequence.uppercased()) {
                        mutantSeq = destroyed
                    } else {
                        errorMessage = "\(sdmREName) recognition site not found at position \(s)."
                        return
                    }
                    mutSite = s
                    origLen = reSite.count
                }
            }

            // Build full mutant context: upstream flank + mutantSeq + downstream flank
            let seq    = sequence.sequence.uppercased()
            let seqLen = seq.count
            let naM    = saltConc / 1000.0
            let flank  = sdmFlankLength
            let minLen = minPrimerLength
            let maxLen = maxPrimerLength
            let tTm    = targetTm
            let maxDTm = maxTmDiff
            let maxDimer = maxDimerScore
            let strategy = sdmStrategy
            let site0    = mutSite - 1   // 0-based

            // Build the mutant local sequence (used for both strategies)
            // upstream + mutant + downstream, long enough for any primer
            let contextFlank = max(maxLen, 40)
            let upstreamStart0 = Self.wrapIdx(site0 - contextFlank, n: seqLen)
            let upstream = Self.extractStatic(from: seq, start0: upstreamStart0, length: contextFlank, circular: true)
            let downstreamStart0 = Self.wrapIdx(site0 + origLen, n: seqLen)
            let downstream = Self.extractStatic(from: seq, start0: downstreamStart0, length: contextFlank, circular: true)
            let mutantContext = upstream + mutantSeq + downstream
            // The mutation in mutantContext starts at index `contextFlank`

            isRunning = true

            DispatchQueue.global(qos: .userInitiated).async {
                var pairs: [PrimerPair] = []

                if strategy == .quickChange {
                    // QuikChange design rules (Agilent/Stratagene protocol):
                    //   • Total primer length 25–45 bp
                    //   • Tm ≥ 78 °C (hard minimum)
                    //   • Mutation centred: flanks within 3 bp of each other
                    //   • GC content 40–60%; prefer primers ending in G or C
                    //   • Rev primer = exact RC of fwd (symmetric by construction)
                    let qcMinLen      = 25
                    // Relax upper bound for large mutations so the algorithm can still find candidates
                    let qcMaxLen      = max(45, mutantSeq.count + 22)

                    for fFlank in max(10, flank - 3)...min(flank + 3, 25) {
                        for rFlank in max(10, flank - 3)...min(flank + 3, 25) {
                            // Keep mutation roughly centred
                            guard abs(fFlank - rFlank) <= 3 else { continue }
                            let totalLen = fFlank + mutantSeq.count + rFlank
                            guard totalLen >= qcMinLen, totalLen <= qcMaxLen else { continue }

                            // Extract from mutantContext
                            let primerStart = contextFlank - fFlank
                            guard primerStart >= 0, primerStart + totalLen <= mutantContext.count else { continue }
                            let startIdx = mutantContext.index(mutantContext.startIndex, offsetBy: primerStart)
                            let endIdx   = mutantContext.index(startIdx, offsetBy: totalLen)
                            let fwdSeq   = String(mutantContext[startIdx..<endIdx])

                            let fwdTm = self.calculateTm(fwdSeq, naM: naM)
                            // Hard requirement: Tm ≥ 78 °C (QuikChange protocol)
                            guard fwdTm >= 78.0 else { continue }
                            let revSeq = self.reverseComplement(fwdSeq)
                            let revTm  = fwdTm  // symmetric by definition

                            let fwdSD = self.selfDimerScore(fwdSeq)
                            let revSD = self.selfDimerScore(revSeq)
                            guard max(fwdSD, revSD) < maxDimer else { continue }
                            let cross = self.crossDimerScore(fwdSeq, revSeq)
                            guard cross < maxDimer else { continue }

                            // Position on original template (1-based sense strand)
                            let fwdPos = Self.wrapIdx(site0 - fFlank, n: seqLen) + 1
                            let revPos = Self.wrapIdx(site0 + origLen + rFlank - 1, n: seqLen) + 1

                            let fwdCand = PrimerCandidate(sequence: fwdSeq, position: fwdPos,
                                length: fwdSeq.count, tm: fwdTm, gcPercent: self.gcPercent(fwdSeq),
                                selfDimerScore: fwdSD, offsetFromTarget: 0)
                            let revCand = PrimerCandidate(sequence: revSeq, position: revPos,
                                length: revSeq.count, tm: revTm, gcPercent: self.gcPercent(revSeq),
                                selfDimerScore: revSD, offsetFromTarget: 0)
                            pairs.append(PrimerPair(forward: fwdCand, reverse: revCand,
                                productSize: seqLen, crossDimerScore: cross))
                        }
                    }

                } else {
                    // Back-to-Back (KLD): outward primers flank the mutation.
                    // Fwd primer anneals to sense strand just AFTER the mutation.
                    // Rev primer anneals to antisense strand just BEFORE the mutation.
                    // Mutant sequence becomes 5′ tails (auto-populated after design).
                    let fwdAnnealStart0 = Self.wrapIdx(site0 + origLen, n: seqLen)
                    let revAnnealEnd0   = Self.wrapIdx(site0 - 1, n: seqLen)

                    for fwdLen in minLen...maxLen {
                        let fwdSeq = Self.extractStatic(from: seq, start0: fwdAnnealStart0, length: fwdLen, circular: true)
                        guard fwdSeq.count == fwdLen else { continue }
                        let fwdTm = self.calculateTm(fwdSeq, naM: naM)
                        guard abs(fwdTm - tTm) <= maxDTm + 3.0 else { continue }
                        let fwdSD = self.selfDimerScore(fwdSeq)
                        guard fwdSD < maxDimer else { continue }

                        for revLen in minLen...maxLen {
                            let revSenseStart0 = Self.wrapIdx(revAnnealEnd0 - revLen + 1, n: seqLen)
                            let revSenseSeq = Self.extractStatic(from: seq, start0: revSenseStart0, length: revLen, circular: true)
                            guard revSenseSeq.count == revLen else { continue }
                            let revSeq = self.reverseComplement(revSenseSeq)
                            let revTm  = self.calculateTm(revSeq, naM: naM)
                            guard abs(revTm - tTm) <= maxDTm + 3.0 else { continue }
                            guard abs(fwdTm - revTm) <= maxDTm else { continue }
                            let revSD = self.selfDimerScore(revSeq)
                            guard revSD < maxDimer else { continue }
                            let cross = self.crossDimerScore(fwdSeq, revSeq)
                            guard cross < maxDimer else { continue }

                            let fwdPos = fwdAnnealStart0 + 1
                            let revPos = revSenseStart0 + 1
                            let fwdCand = PrimerCandidate(sequence: fwdSeq, position: fwdPos,
                                length: fwdLen, tm: fwdTm, gcPercent: self.gcPercent(fwdSeq),
                                selfDimerScore: fwdSD, offsetFromTarget: 0)
                            let revCand = PrimerCandidate(sequence: revSeq, position: revPos,
                                length: revLen, tm: revTm, gcPercent: self.gcPercent(revSeq),
                                selfDimerScore: revSD, offsetFromTarget: 0)
                            pairs.append(PrimerPair(forward: fwdCand, reverse: revCand,
                                productSize: seqLen, crossDimerScore: cross))
                        }
                    }
                }

                pairs.sort { self.scoreOf($0, targetTm: tTm, qcMode: strategy == .quickChange) < self.scoreOf($1, targetTm: tTm, qcMode: strategy == .quickChange) }
                if pairs.count > 200 { pairs = Array(pairs.prefix(200)) }

                DispatchQueue.main.async {
                    self.isRunning   = false
                    self.primerPairs = pairs
                    if let first = pairs.first { self.selectedPairID = first.id }
                    if pairs.isEmpty {
                        self.errorMessage = "No suitable SDM primers found. Try adjusting Tm, primer length, or dimer threshold."
                        return
                    }
                    // For back-to-back: auto-populate tails with the mutant sequence
                    if strategy == .backToBack {
                        self.fwdTailMode    = .custom
                        self.revTailMode    = .custom
                        self.fwdCustomTail  = mutantSeq.lowercased()
                        self.revCustomTail  = self.reverseComplement(mutantSeq).lowercased()
                        self.showTailSection = true
                    }
                }
            }
            return  // skip normal design path
        }
        // ─────────────────────────────────────────────────────────────────────

        // ── Whole-plasmid amplification path ──────────────────────────────────
        // Both primers sit back-to-back at primerSite, pointing outward.
        // Forward primer reads the sense strand starting at primerSite (→).
        // Reverse primer reads the antisense strand ending just before primerSite
        // (its revcomp starts just upstream of the site, so it points ←).
        // The amplicon is the entire plasmid, linearised at primerSite.
        if wholePlasmidMode {
            guard sequence.isCircular else {
                errorMessage = "Whole-plasmid mode requires a circular template."
                return
            }
            guard let site = Int(primerSiteText), site >= 1, site <= sequence.length else {
                errorMessage = "Enter a valid primer site position (1–\(sequence.length))."
                return
            }
            let seq      = sequence.sequence.uppercased()
            let seqLen   = seq.count
            let naM      = saltConc / 1000.0
            let minLen   = minPrimerLength
            let maxLen   = maxPrimerLength
            let tTm      = targetTm
            let maxDTm   = maxTmDiff
            let maxDimer = maxDimerScore
            let doOverlap  = addOverlapTails
            let overlapLen = overlapLength

            isRunning = true
            DispatchQueue.global(qos: .userInitiated).async {
                var pairs: [PrimerPair] = []

                for fwdLen in minLen...maxLen {
                    let fwdStart0 = Self.wrapIdx(site - 1, n: seqLen)
                    let fwdSeq = Self.extractStatic(from: seq, start0: fwdStart0, length: fwdLen, circular: true)
                    guard fwdSeq.count == fwdLen else { continue }
                    let fwdTm = self.calculateTm(fwdSeq, naM: naM)
                    guard abs(fwdTm - tTm) <= maxDTm + 3.0 else { continue }
                    let fwdSD = self.selfDimerScore(fwdSeq)
                    guard fwdSD < maxDimer else { continue }
                    let fwdCand = PrimerCandidate(
                        sequence: fwdSeq, position: site, length: fwdLen,
                        tm: fwdTm, gcPercent: self.gcPercent(fwdSeq),
                        selfDimerScore: fwdSD, offsetFromTarget: 0
                    )

                    for revLen in minLen...maxLen {
                        let revSenseStart0 = Self.wrapIdx(site - 1 - revLen, n: seqLen)
                        let revSenseSeq = Self.extractStatic(from: seq, start0: revSenseStart0, length: revLen, circular: true)
                        guard revSenseSeq.count == revLen else { continue }
                        let revSeq = self.reverseComplement(revSenseSeq)
                        let revTm  = self.calculateTm(revSeq, naM: naM)
                        guard abs(revTm - tTm) <= maxDTm + 3.0 else { continue }
                        guard abs(fwdTm - revTm) <= maxDTm else { continue }
                        let revSD = self.selfDimerScore(revSeq)
                        guard revSD < maxDimer else { continue }
                        let crossDimer = self.crossDimerScore(fwdSeq, revSeq)
                        guard crossDimer < maxDimer else { continue }

                        let revPos = (revSenseStart0 % seqLen) + 1
                        let revCand = PrimerCandidate(
                            sequence: revSeq, position: revPos, length: revLen,
                            tm: revTm, gcPercent: self.gcPercent(revSeq),
                            selfDimerScore: revSD, offsetFromTarget: 0
                        )
                        pairs.append(PrimerPair(
                            forward: fwdCand, reverse: revCand,
                            productSize: seqLen,
                            crossDimerScore: crossDimer
                        ))
                    }
                }

                pairs.sort { self.scoreOf($0, targetTm: tTm) < self.scoreOf($1, targetTm: tTm) }
                if pairs.count > 200 { pairs = Array(pairs.prefix(200)) }

                // ── Overlap tails for self-circularisation ──────────────────
                // Fwd tail = last overlapLen bp of the product (sense strand just
                //            upstream of the primer site — this is what the 3′ end
                //            of the linear product looks like, so the fwd primer's
                //            tail anneals to it after exonuclease chewback).
                // Rev tail = RC of first overlapLen bp of the product (sense strand
                //            starting at the primer site — this is what the 5′ end
                //            of the linear product looks like after chewback).
                var computedFwdTail = ""
                var computedRevTail = ""
                if doOverlap {
                    // Fwd tail: template sequence [site-overlapLen .. site-1]
                    let fwdTailStart0 = Self.wrapIdx(site - 1 - overlapLen, n: seqLen)
                    computedFwdTail   = Self.extractStatic(from: seq, start0: fwdTailStart0,
                                                           length: overlapLen, circular: true)
                    // Rev tail: RC of template sequence [site .. site+overlapLen-1]
                    let revTailStart0 = Self.wrapIdx(site - 1, n: seqLen)
                    let revTailSense  = Self.extractStatic(from: seq, start0: revTailStart0,
                                                           length: overlapLen, circular: true)
                    computedRevTail   = String(revTailSense.reversed().map {
                        Self.complementMap[$0] ?? $0
                    })
                }
                // ─────────────────────────────────────────────────────────────

                DispatchQueue.main.async {
                    self.isRunning   = false
                    self.primerPairs = pairs
                    if let first = pairs.first { self.selectedPairID = first.id }
                    if pairs.isEmpty {
                        self.errorMessage = "No suitable primer pairs found at this site. Try adjusting Tm, primer length, or moving the primer site."
                    }
                    // Apply overlap tails through the existing custom tail system
                    if doOverlap && !computedFwdTail.isEmpty {
                        self.fwdTailMode    = .custom
                        self.revTailMode    = .custom
                        self.fwdCustomTail  = computedFwdTail.lowercased()
                        self.revCustomTail  = computedRevTail.lowercased()
                        self.showTailSection = true
                    }
                }
            }
            return   // skip the normal design path below
        }
        // ─────────────────────────────────────────────────────────────────────

        guard let start = targetStart, let end = targetEnd else {
            errorMessage = "Enter valid start and end positions."
            return
        }
        guard start >= 1, start <= sequence.length,
              end >= 1, end <= sequence.length else {
            errorMessage = "Positions must be between 1 and \(sequence.length)."
            return
        }
        if !sequence.isCircular && start >= end {
            errorMessage = "Invalid region. For linear sequences, Start must be less than End."
            return
        }
        if start == end {
            errorMessage = "Start and End must be different positions."
            return
        }
        guard let _ = productSize, productSize! > maxPrimerLength else {
            errorMessage = "Product region must be longer than maximum primer length."
            return
        }
        
        // Capture values for background thread
        let seq = sequence.sequence.uppercased()
        let seqLen = seq.count
        let isCirc = sequence.isCircular
        let naM = saltConc / 1000.0
        let minLen = minPrimerLength
        let maxLen = maxPrimerLength
        let tTm = targetTm
        let maxDTm = maxTmDiff
        let maxDimer = maxDimerScore
        let window = searchWindow
        let doesWrap = wrapsOrigin
        let allowInternal = allowInternalPrimers
        
        // Fixed primer handling
        let fixedMode = fixedPrimerMode
        let fixedFwdSeq = fixedFwdSequence.uppercased().filter { "ACGTN".contains($0) }
        let fixedRevSeq = fixedRevSequence.uppercased().filter { "ACGTN".contains($0) }
        
        let needsFwd = fixedMode == .fixedForward || fixedMode == .fixedBoth
        let needsRev = fixedMode == .fixedReverse || fixedMode == .fixedBoth
        
        if needsFwd && fixedFwdSeq.count < 10 {
            errorMessage = "Fixed forward primer must be at least 10 bases."
            return
        }
        if needsRev && fixedRevSeq.count < 10 {
            errorMessage = "Fixed reverse primer must be at least 10 bases."
            return
        }
        
        isRunning = true
        
        // Capture stock matches for background thread
        let capturedStockMatches = stockMatches
        let useStock = preferStock && !capturedStockMatches.isEmpty
        
        DispatchQueue.global(qos: .userInitiated).async {
            
            // -- Build fixed primer candidate if applicable --
            var fixedFwd: PrimerCandidate?
            var fixedRev: PrimerCandidate?
            
            if (fixedMode == .fixedForward || fixedMode == .fixedBoth) && !fixedFwdSeq.isEmpty {
                let tm = self.calculateTm(fixedFwdSeq, naM: naM)
                let gc = self.gcPercent(fixedFwdSeq)
                let sd = self.selfDimerScore(fixedFwdSeq)
                let bind = Self.findBindingPosition(primer: fixedFwdSeq, in: seq, circular: isCirc)
                
                // Three checks before accepting the user's fixed forward primer:
                //   1. It must match the template at all (either strand).
                //   2. It must be on the SENSE strand — otherwise it's actually
                //      a geometrically reverse primer and belongs in the Fixed
                //      Reverse field.
                //   3. Its binding position must be at or upstream of the target
                //      start (allowing the same wrap tolerance as designed
                //      forward primers, i.e. up to `window` bases past start).
                // Without these checks the old code silently substituted `start`
                // when no match was found, so a non-matching or wrong-strand
                // primer would be accepted and the resulting "amplicon" would
                // be junk.
                if bind == nil {
                    DispatchQueue.main.async {
                        self.isRunning = false
                        self.errorMessage = "Fixed forward primer does not match the template sequence on either strand."
                    }
                    return
                }
                if let b = bind, !b.onSense {
                    DispatchQueue.main.async {
                        self.isRunning = false
                        self.errorMessage = "The sequence you entered as a Fixed Forward primer is geometrically a reverse primer for this template — its reverse complement matches the sense strand. Move it to the Fixed Reverse field, or check you have the right primer."
                    }
                    return
                }
                if let b = bind {
                    let acceptableStart = max(1, start - window)
                    if b.position < acceptableStart || b.position > start {
                        DispatchQueue.main.async {
                            self.isRunning = false
                            self.errorMessage = "Fixed forward primer binds at position \(b.position), which is outside the search window for the target region (start \(start), window \(window)). It would not amplify the target you've selected."
                        }
                        return
                    }
                }
                
                fixedFwd = PrimerCandidate(
                    sequence: fixedFwdSeq, position: bind!.position,
                    length: fixedFwdSeq.count, tm: tm, gcPercent: gc,
                    selfDimerScore: sd, offsetFromTarget: 0
                )
            }
            
            if (fixedMode == .fixedReverse || fixedMode == .fixedBoth) && !fixedRevSeq.isEmpty {
                let tm = self.calculateTm(fixedRevSeq, naM: naM)
                let gc = self.gcPercent(fixedRevSeq)
                let sd = self.selfDimerScore(fixedRevSeq)
                
                // For a geometric reverse primer, its REVERSE COMPLEMENT should
                // appear on the sense strand near the target end.  We search for
                // the primer itself first and use the strand flag to validate.
                let bind = Self.findBindingPosition(primer: fixedRevSeq, in: seq, circular: isCirc)
                
                if bind == nil {
                    DispatchQueue.main.async {
                        self.isRunning = false
                        self.errorMessage = "Fixed reverse primer does not match the template sequence on either strand."
                    }
                    return
                }
                if let b = bind, b.onSense {
                    DispatchQueue.main.async {
                        self.isRunning = false
                        self.errorMessage = "The sequence you entered as a Fixed Reverse primer is geometrically a forward primer for this template — its literal sequence matches the sense strand. Move it to the Fixed Forward field, or check you have the right primer."
                    }
                    return
                }
                
                // bind.position is the sense-strand position where revcomp(primer)
                // begins.  The primer's 3' end on the antisense strand corresponds
                // to position bind.position on the sense strand; its binding
                // region ends at bind.position + primer.count - 1.  For the primer
                // to amplify the chosen target, this end must be at or just past
                // the user's target end.
                if let b = bind {
                    let bindEnd = b.position + fixedRevSeq.count - 1
                    let acceptableEnd = end + window
                    if bindEnd < end || bindEnd > acceptableEnd {
                        DispatchQueue.main.async {
                            self.isRunning = false
                            self.errorMessage = "Fixed reverse primer binds with its 3' end at template position \(bindEnd), which is outside the search window for the target region (end \(end), window \(window)). It would not amplify the target you've selected."
                        }
                        return
                    }
                }
                
                fixedRev = PrimerCandidate(
                    sequence: fixedRevSeq, position: bind!.position,
                    length: fixedRevSeq.count, tm: tm, gcPercent: gc,
                    selfDimerScore: sd, offsetFromTarget: 0
                )
            }
            
            // -- Generate forward candidates (skip if fixed) --
            var fwdRaw: [(seq: String, pos: Int, len: Int, tm: Double, gc: Double, offset: Int)] = []
            if fixedFwd == nil {
                for offset in 0...window {
                    let fwdStart1 = start - offset
                    if !isCirc && fwdStart1 < 1 { break }
                    let fwdStart0 = Self.wrapIdx(fwdStart1 - 1, n: seqLen)
                    
                    for len in minLen...maxLen {
                        // When external-only mode: skip primers whose 3' end extends into the target
                        if !allowInternal && offset < len { continue }
                        
                        let primerSeq = Self.extractStatic(from: seq, start0: fwdStart0, length: len, circular: isCirc)
                        guard primerSeq.count == len else { continue }
                        let tm = self.calculateTm(primerSeq, naM: naM)
                        guard abs(tm - tTm) <= maxDTm + 3.0 else { continue }
                        let normPos = (fwdStart0 % seqLen) + 1
                        fwdRaw.append((primerSeq, normPos, len, tm, self.gcPercent(primerSeq), offset))
                    }
                }
            }
            
            // -- Generate reverse candidates (skip if fixed) --
            var revRaw: [(seq: String, pos: Int, len: Int, tm: Double, gc: Double, offset: Int)] = []
            if fixedRev == nil {
                for offset in 0...window {
                    let revEnd1 = end + offset
                    if !isCirc && revEnd1 > seqLen { break }
                    
                    for len in minLen...maxLen {
                        // When external-only mode: skip primers whose 3' end extends into the target
                        if !allowInternal && offset < len { continue }
                        
                        let senseStart0 = Self.wrapIdx(revEnd1 - len, n: seqLen)
                        let senseSeq = Self.extractStatic(from: seq, start0: senseStart0, length: len, circular: isCirc)
                        guard senseSeq.count == len else { continue }
                        let primerSeq = self.reverseComplement(senseSeq)
                        let tm = self.calculateTm(primerSeq, naM: naM)
                        guard abs(tm - tTm) <= maxDTm + 3.0 else { continue }
                        let normPos = (senseStart0 % seqLen) + 1
                        revRaw.append((primerSeq, normPos, len, tm, self.gcPercent(primerSeq), offset))
                    }
                }
            }
            
            // Check we have candidates
            let haveFwd = fixedFwd != nil || !fwdRaw.isEmpty
            let haveRev = fixedRev != nil || !revRaw.isEmpty
            guard haveFwd, haveRev else {
                DispatchQueue.main.async {
                    self.isRunning = false
                    if !allowInternal {
                        self.errorMessage = "Could not generate candidates outside the target region. Try increasing the Search Window (must be larger than primer length), or enable \u{201C}Allow primers within target region\u{201D}."
                    } else {
                        self.errorMessage = "Could not generate candidates. Check region and length settings."
                    }
                }
                return
            }
            
            // -- Pre-rank generated candidates: keep top 60 per side --
            let quickScore: ((seq: String, pos: Int, len: Int, tm: Double, gc: Double, offset: Int)) -> Double = { c in
                abs(c.tm - tTm) + Double(c.offset) * 0.5 + self.gcPenalty(c.gc)
            }
            
            let maxCandidates = 60
            fwdRaw.sort { quickScore($0) < quickScore($1) }
            if fwdRaw.count > maxCandidates { fwdRaw = Array(fwdRaw.prefix(maxCandidates)) }
            revRaw.sort { quickScore($0) < quickScore($1) }
            if revRaw.count > maxCandidates { revRaw = Array(revRaw.prefix(maxCandidates)) }
            
            // -- Build full PrimerCandidates --
            var fwdCandidates: [PrimerCandidate] = []
            if let fixed = fixedFwd {
                fwdCandidates = [fixed]
            } else {
                fwdCandidates = fwdRaw.map { c in
                    PrimerCandidate(
                        sequence: c.seq, position: c.pos, length: c.len,
                        tm: c.tm, gcPercent: c.gc,
                        selfDimerScore: self.selfDimerScore(c.seq),
                        offsetFromTarget: c.offset
                    )
                }
            }
            
            var revCandidates: [PrimerCandidate] = []
            if let fixed = fixedRev {
                revCandidates = [fixed]
            } else {
                revCandidates = revRaw.map { c in
                    PrimerCandidate(
                        sequence: c.seq, position: c.pos, length: c.len,
                        tm: c.tm, gcPercent: c.gc,
                        selfDimerScore: self.selfDimerScore(c.seq),
                        offsetFromTarget: c.offset
                    )
                }
            }
            
            // -- Inject stock primer candidates --
            if useStock {
                for match in capturedStockMatches {
                    let anneal = match.annealingSequence
                    let sd = self.selfDimerScore(anneal)
                    
                    // Calculate offset from target boundary
                    let pos = match.bindingPosition
                    
                    if !match.isReverse && fixedFwd == nil {
                        // Forward stock primer — offset is how far its start is from target start
                        let offset: Int
                        if isCirc {
                            let diff = Self.wrapIdx(start - pos, n: seqLen)
                            offset = min(diff, seqLen - diff)
                        } else {
                            offset = abs(pos - start)
                        }
                        
                        // In external-only mode, skip stock primers that overlap the target
                        if !allowInternal && (pos + anneal.count - 1 >= start && pos <= end) { continue }
                        
                        let candidate = PrimerCandidate(
                            sequence: anneal, position: pos,
                            length: anneal.count, tm: match.tm, gcPercent: match.gcPercent,
                            selfDimerScore: sd, offsetFromTarget: offset,
                            isStock: true, stockName: match.stockPrimer.name
                        )
                        // Add to pool (avoid duplicates by sequence)
                        if !fwdCandidates.contains(where: { $0.sequence == anneal }) {
                            fwdCandidates.append(candidate)
                        }
                    }
                    
                    if match.isReverse && fixedRev == nil {
                        // Reverse stock primer — pos is sense-strand END from screening
                        // Convert to sense-strand START for consistency with designed reverse primers
                        let senseStart = Self.wrapIdx(pos - anneal.count, n: seqLen) + 1
                        
                        // Offset: how far the primer's sense-strand end is from target end
                        let offset: Int
                        if isCirc {
                            let diff = Self.wrapIdx(pos - end, n: seqLen)
                            offset = min(diff, seqLen - diff)
                        } else {
                            offset = abs(pos - end)
                        }
                        
                        // In external-only mode, skip stock primers that overlap the target
                        if !allowInternal && (senseStart <= end && pos >= start) { continue }
                        let candidate = PrimerCandidate(
                            sequence: anneal, position: senseStart,
                            length: anneal.count, tm: match.tm, gcPercent: match.gcPercent,
                            selfDimerScore: sd, offsetFromTarget: offset,
                            isStock: true, stockName: match.stockPrimer.name
                        )
                        if !revCandidates.contains(where: { $0.sequence == anneal }) {
                            revCandidates.append(candidate)
                        }
                    }
                }
            }
            
            // -- Pair and score --
            var pairs: [PrimerPair] = []
            for fwd in fwdCandidates {
                for rev in revCandidates {
                    // Relax delta-Tm for fixed or stock primers
                    let hasFixedOrStock = fixedFwd != nil || fixedRev != nil || fwd.isStock || rev.isStock
                    let effectiveMaxDTm = hasFixedOrStock ? max(maxDTm, 10.0) : maxDTm
                    let dtm = abs(fwd.tm - rev.tm)
                    guard dtm <= effectiveMaxDTm else { continue }
                    
                    let crossDimer = self.crossDimerScore(fwd.sequence, rev.sequence)
                    let worstDimer = max(fwd.selfDimerScore, rev.selfDimerScore, crossDimer)
                    guard worstDimer < maxDimer else { continue }
                    
                    let fwdStart1 = fwd.position
                    let revEnd1 = Self.wrapIdx(rev.position - 1 + rev.length - 1, n: seqLen) + 1
                    
                    let actualProductSize: Int
                    if isCirc && (fwdStart1 > revEnd1 || doesWrap) {
                        actualProductSize = (seqLen - fwdStart1 + 1) + revEnd1
                    } else {
                        actualProductSize = revEnd1 - fwdStart1 + 1
                    }
                    guard actualProductSize > 0, actualProductSize <= seqLen else { continue }
                    
                    pairs.append(PrimerPair(
                        forward: fwd, reverse: rev,
                        productSize: actualProductSize,
                        crossDimerScore: crossDimer
                    ))
                }
            }
            
            pairs.sort { self.scoreOf($0, targetTm: tTm, stockBonus: useStock) < self.scoreOf($1, targetTm: tTm, stockBonus: useStock) }
            if pairs.count > 200 { pairs = Array(pairs.prefix(200)) }
            
            DispatchQueue.main.async {
                self.isRunning = false
                self.primerPairs = pairs
                if let first = pairs.first { self.selectedPairID = first.id }
                if pairs.isEmpty {
                    self.errorMessage = "No pairs found. Try adjusting target Tm, search window, or dimer threshold."
                }
                // Screen stock primers against the template
                self.screenStockAgainstTemplate()
            }
        }
    }
    
    /// Lower score = better. Prioritises Tm match, low delta-Tm,
    /// GC 40-60%, low dimer score, and proximity to target boundaries.
    /// When stockBonus is true, stock primers get a large scoring advantage.
    /// When qcMode is true, an extra penalty is applied for primers that don't end in G or C.
    private func scoreOf(_ pair: PrimerPair, targetTm tTm: Double, stockBonus: Bool = false, qcMode: Bool = false) -> Double {
        let fwdTmPenalty    = abs(pair.forward.tm - tTm)
        let revTmPenalty    = abs(pair.reverse.tm - tTm)
        let dtmPenalty      = pair.tmDifference * 2.0
        let fwdGCPenalty    = gcPenalty(pair.forward.gcPercent)
        let revGCPenalty    = gcPenalty(pair.reverse.gcPercent)
        let dimerPenalty    = Double(pair.worstDimerScore) * 3.0
        let distancePenalty = Double(pair.totalOffset) * 0.5
        
        var score = fwdTmPenalty + revTmPenalty + dtmPenalty + fwdGCPenalty + revGCPenalty + dimerPenalty + distancePenalty
        
        // Stock bonus: subtract a large amount for each stock primer in the pair
        if stockBonus {
            score -= Double(pair.stockCount) * 50.0
        }
        
        // QuikChange: prefer primers whose 3′ end is G or C (protocol recommendation)
        if qcMode {
            score += gcEndsPenalty(pair.forward.sequence)
            score += gcEndsPenalty(pair.reverse.sequence)
        }
        
        return score
    }
    
    /// Returns a penalty (0–4) if the primer's 5′ or 3′ terminus is not G or C.
    private func gcEndsPenalty(_ seq: String) -> Double {
        guard !seq.isEmpty else { return 0 }
        let gcSet: Set<Character> = ["G", "C", "g", "c"]
        var penalty = 0.0
        if !gcSet.contains(seq.first!) { penalty += 2.0 }
        if !gcSet.contains(seq.last!)  { penalty += 2.0 }
        return penalty
    }
    
    private func gcPenalty(_ gc: Double) -> Double {
        if gc >= 40 && gc <= 60 { return 0 }
        return abs(gc - 50.0) * 0.3
    }
    
    
    // MARK: - Target Feature Selection
    
    private func applyTargetSelection(_ index: Int) {
        if index >= 0 && index < sequence.features.count {
            // Feature selected
            let feature = sequence.features[index]
            targetStartText = "\(feature.start + 1)"  // 1-based
            targetEndText = "\(feature.end)"
        } else if index >= 1000 {
            // ORF selected
            let orfIndex = index - 1000
            if orfIndex < sequence.orfResults.count {
                let orf = sequence.orfResults[orfIndex]
                targetStartText = "\(orf.position)"  // already 1-based
                targetEndText = "\(orf.position + orf.size - 1)"
            }
        }
        // -1 = manual, do nothing
    }
    
    
    // MARK: - Circular Sequence Helpers
    
    /// Static wrap for background thread use
    private static func wrapIdx(_ idx: Int, n: Int) -> Int {
        guard n > 0 else { return 0 }
        return ((idx % n) + n) % n
    }
    
    /// Static base extraction for background thread use
    private static func extractStatic(from seq: String, start0: Int, length: Int, circular: Bool) -> String {
        let n = seq.count
        guard n > 0 else { return "" }
        let normStart = ((start0 % n) + n) % n
        if normStart + length <= n {
            let s = seq.index(seq.startIndex, offsetBy: normStart)
            let e = seq.index(s, offsetBy: length)
            return String(seq[s..<e])
        } else if circular {
            let tailLen = n - normStart
            let headLen = length - tailLen
            guard headLen <= n else { return "" }
            let ts = seq.index(seq.startIndex, offsetBy: normStart)
            let tail = String(seq[ts...])
            let he = seq.index(seq.startIndex, offsetBy: headLen)
            let head = String(seq[seq.startIndex..<he])
            return tail + head
        }
        return ""
    }
    
    /// Find where a primer sequence binds on the template (1-based position, or nil if not found)
    /// Strand-aware binding position lookup.
    /// Returns the 1-based start position of the primer's binding site on the
    /// template, plus a flag indicating which strand it matched:
    ///   `onSense = true`  → the primer's literal sequence appears on the
    ///                       sense strand (i.e. it anneals to antisense and
    ///                       primes 5'→3' along increasing sense positions).
    ///                       Geometrically a "forward" primer for this region.
    ///   `onSense = false` → the primer's reverse complement appears on the
    ///                       sense strand (i.e. it anneals to sense and primes
    ///                       5'→3' along decreasing sense positions).
    ///                       Geometrically a "reverse" primer for this region.
    /// Returns nil if neither strand contains a match.
    private static func findBindingPosition(primer: String, in seq: String, circular: Bool) -> (position: Int, onSense: Bool)? {
        let p = primer.uppercased()
        let s = seq.uppercased()
        let pRC = String(p.reversed().map { c -> Character in
            switch c {
            case "A": return "T"; case "T": return "A"
            case "G": return "C"; case "C": return "G"
            default:  return "N"
            }
        })
        
        // Sense-strand literal match
        if let range = s.range(of: p) {
            return (s.distance(from: s.startIndex, to: range.lowerBound) + 1, true)
        }
        // Sense-strand match of revcomp
        if let range = s.range(of: pRC) {
            return (s.distance(from: s.startIndex, to: range.lowerBound) + 1, false)
        }
        // Circular: also check across the origin
        if circular {
            let doubled = s + s
            if let range = doubled.range(of: p) {
                let pos0 = doubled.distance(from: doubled.startIndex, to: range.lowerBound)
                if pos0 < s.count {
                    return ((pos0 % s.count) + 1, true)
                }
            }
            if let range = doubled.range(of: pRC) {
                let pos0 = doubled.distance(from: doubled.startIndex, to: range.lowerBound)
                if pos0 < s.count {
                    return ((pos0 % s.count) + 1, false)
                }
            }
        }
        return nil
    }
    
    
    // MARK: - Primer-Dimer Analysis
    
    private func selfDimerScore(_ primer: String) -> Int {
        let p = Array(primer.uppercased())
        let rc = Array(reverseComplement(primer))
        let n = p.count
        guard n >= 4 else { return 0 }
        
        var worst = 0
        for offset in -(n - 1)..<n {
            var run = 0
            var maxRunAt3End = 0
            for i in 0..<n {
                let j = i - offset
                guard j >= 0, j < n else { run = 0; continue }
                if isComplement(p[i], rc[j]) {
                    run += 1
                    if i == n - 1 || j == n - 1 { maxRunAt3End = max(maxRunAt3End, run) }
                } else { run = 0 }
            }
            worst = max(worst, maxRunAt3End)
        }
        return worst
    }
    
    private func crossDimerScore(_ a: String, _ b: String) -> Int {
        let pa = Array(a.uppercased())
        let rcb = Array(reverseComplement(b))
        let na = pa.count
        let nb = rcb.count
        guard na >= 4, nb >= 4 else { return 0 }
        
        var worst = 0
        
        for offset in -(nb - 1)..<na {
            var run = 0
            var maxRunAt3End = 0
            for i in 0..<na {
                let j = i - offset
                guard j >= 0, j < nb else { run = 0; continue }
                if isComplement(pa[i], rcb[j]) {
                    run += 1
                    if i == na - 1 || j == 0 { maxRunAt3End = max(maxRunAt3End, run) }
                } else { run = 0 }
            }
            worst = max(worst, maxRunAt3End)
        }
        
        let pb = Array(b.uppercased())
        let rca = Array(reverseComplement(a))
        for offset in -(na - 1)..<nb {
            var run = 0
            var maxRunAt3End = 0
            for i in 0..<nb {
                let j = i - offset
                guard j >= 0, j < na else { run = 0; continue }
                if isComplement(pb[i], rca[j]) {
                    run += 1
                    if i == nb - 1 || j == 0 { maxRunAt3End = max(maxRunAt3End, run) }
                } else { run = 0 }
            }
            worst = max(worst, maxRunAt3End)
        }
        
        return worst
    }
    
    private func isComplement(_ a: Character, _ b: Character) -> Bool {
        switch (a, b) {
        case ("A", "T"), ("T", "A"), ("G", "C"), ("C", "G"): return true
        default: return false
        }
    }
    
    
    // MARK: - Tm Calculation (Serial Cloner 3-tier formula)
    
    func calculateTm(_ primer: String, naM: Double) -> Double {
        var gc = 0, at = 0
        for ch in primer.uppercased() {
            switch ch {
            case "G", "C": gc += 1
            case "A", "T": at += 1
            default: break
            }
        }
        let total = gc + at
        guard total > 0 else { return 0 }
        
        let logNa = log10(max(naM, 0.001))
        
        if total < 14 {
            return Double(at * 2 + gc * 4) - 16.6 * log10(0.050) + 16.6 * logNa
        } else if total <= 51 {
            return 100.5 + 41.0 * Double(gc) / Double(total) - 820.0 / Double(total) + 16.6 * logNa
        } else {
            return 81.5 + 41.0 * Double(gc) / Double(total) - 500.0 / Double(total) + 16.6 * logNa
        }
    }
    
    
    // MARK: - Codon utilities (for SDM amino acid mode)

    private static let codonTable: [String: Character] = [
        "TTT": "F", "TTC": "F", "TTA": "L", "TTG": "L",
        "CTT": "L", "CTC": "L", "CTA": "L", "CTG": "L",
        "ATT": "I", "ATC": "I", "ATA": "I", "ATG": "M",
        "GTT": "V", "GTC": "V", "GTA": "V", "GTG": "V",
        "TCT": "S", "TCC": "S", "TCA": "S", "TCG": "S",
        "CCT": "P", "CCC": "P", "CCA": "P", "CCG": "P",
        "ACT": "T", "ACC": "T", "ACA": "T", "ACG": "T",
        "GCT": "A", "GCC": "A", "GCA": "A", "GCG": "A",
        "TAT": "Y", "TAC": "Y", "TAA": "*", "TAG": "*",
        "CAT": "H", "CAC": "H", "CAA": "Q", "CAG": "Q",
        "AAT": "N", "AAC": "N", "AAA": "K", "AAG": "K",
        "GAT": "D", "GAC": "D", "GAA": "E", "GAG": "E",
        "TGT": "C", "TGC": "C", "TGA": "*", "TGG": "W",
        "CGT": "R", "CGC": "R", "CGA": "R", "CGG": "R",
        "AGT": "S", "AGC": "S", "AGA": "R", "AGG": "R",
        "GGT": "G", "GGC": "G", "GGA": "G", "GGG": "G"
    ]

    // Reverse lookup: amino acid → preferred codons (E. coli / general preference)
    private static let preferredCodons: [Character: [String]] = [
        "F": ["TTC","TTT"], "L": ["CTG","TTA","TTG","CTT","CTC","CTA"],
        "I": ["ATC","ATT","ATA"], "M": ["ATG"],
        "V": ["GTG","GTC","GTT","GTA"], "S": ["AGC","TCG","TCC","TCT","TCA","AGT"],
        "P": ["CCG","CCC","CCT","CCA"], "T": ["ACC","ACG","ACT","ACA"],
        "A": ["GCG","GCC","GCT","GCA"], "Y": ["TAC","TAT"],
        "H": ["CAC","CAT"], "Q": ["CAG","CAA"],
        "N": ["AAC","AAT"], "K": ["AAG","AAA"],
        "D": ["GAC","GAT"], "E": ["GAG","GAA"],
        "C": ["TGC","TGT"], "W": ["TGG"],
        "R": ["CGC","CGT","CGG","CGA","AGA","AGG"], "G": ["GGC","GGT","GGG","GGA"],
        "*": ["TAA","TGA","TAG"]
    ]

    /// Translate a DNA codon (3 bases) to single-letter amino acid.
    private func translateCodon(_ codon: String) -> Character {
        Self.codonTable[codon.uppercased()] ?? "X"
    }

    /// Return the first preferred codon for a given amino acid letter.
    private func preferredCodon(for aa: Character) -> String {
        Self.preferredCodons[aa]?.first ?? "NNN"
    }

    /// Find all codons encoding a given amino acid.
    private func allCodons(for aa: Character) -> [String] {
        Self.preferredCodons[aa] ?? []
    }

    // MARK: - Helpers
    
    private func gcPercent(_ seq: String) -> Double {
        guard !seq.isEmpty else { return 0 }
        var gc = 0
        for ch in seq.uppercased() {
            if ch == "G" || ch == "C" { gc += 1 }
        }
        return Double(gc) / Double(seq.count) * 100.0
    }
    
    private static let complementMap: [Character: Character] = [
        "A": "T", "T": "A", "G": "C", "C": "G",
        "N": "N", "R": "Y", "Y": "R", "S": "S",
        "W": "W", "K": "M", "M": "K"
    ]

    private func reverseComplement(_ seq: String) -> String {
        String(seq.uppercased().reversed().map { Self.complementMap[$0] ?? $0 })
    }
    
    private func gcColor(_ gc: Double) -> Color {
        if gc >= 40 && gc <= 60 { return .primary }
        return .orange
    }
    
    private func dimerColor(_ score: Int) -> Color {
        if score < 3 { return .primary }
        if score < maxDimerScore { return .orange }
        return .red
    }
    
    private func copyToClipboard(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedField = label
        clearCopiedAfterDelay()
    }
    
    private func clearCopiedAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            copiedField = nil
        }
    }
}


// MARK: - Primer Arrow Shape

struct PrimerArrowShape: Shape {
    let pointsRight: Bool
    
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let arrowHead: CGFloat = min(rect.height, rect.width * 0.3)
        
        if pointsRight {
            p.move(to: CGPoint(x: rect.minX, y: rect.midY - rect.height * 0.3))
            p.addLine(to: CGPoint(x: rect.maxX - arrowHead, y: rect.midY - rect.height * 0.3))
            p.addLine(to: CGPoint(x: rect.maxX - arrowHead, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX - arrowHead, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX - arrowHead, y: rect.midY + rect.height * 0.3))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.3))
            p.closeSubpath()
        } else {
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.minX + arrowHead, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX + arrowHead, y: rect.midY - rect.height * 0.3))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY - rect.height * 0.3))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY + rect.height * 0.3))
            p.addLine(to: CGPoint(x: rect.minX + arrowHead, y: rect.midY + rect.height * 0.3))
            p.addLine(to: CGPoint(x: rect.minX + arrowHead, y: rect.maxY))
            p.closeSubpath()
        }
        
        return p
    }
}

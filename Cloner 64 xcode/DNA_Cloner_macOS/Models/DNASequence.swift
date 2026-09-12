import SwiftUI
import Foundation
import Combine

// MARK: - Melting Temperature

/// The single implementation of primer/oligo melting temperature.
///
/// This calculation previously existed in three places — PrimerDesignView,
/// PCRSimulationView and SequenceEditorView. Two of them guarded the salt term
/// with `max(naM, 0.001)`; the third used a bare `log10(naConcentration)`, which
/// returns −infinity at zero. That copy is currently safe only because its salt
/// concentration is hard-coded to 0.050 — but the other two views bind theirs to
/// an editable text field, so the guard exists precisely because a user can type
/// a zero. Keeping three copies is how one of them came to lose it.
///
/// The formula itself is unchanged: Serial Cloner's three-tier rule, so every
/// number the app currently shows stays the same.
enum MeltingTemperature {

    /// Melting temperature in °C for an oligo, using Serial Cloner's three-tier
    /// formula with a salt correction.
    ///
    /// - Parameters:
    ///   - oligo: the sequence. Only A/T/G/C are counted; anything else
    ///     (ambiguity codes, gaps, whitespace) is ignored, as before.
    ///   - sodiumMolar: Na⁺ concentration in MOLES per litre — note that the
    ///     views hold it in mM and divide by 1000 before calling.
    /// - Returns: Tm in °C, or 0 for an oligo with no countable bases.
    static func celsius(for oligo: String, sodiumMolar: Double) -> Double {
        var gc = 0, at = 0
        for ch in oligo.uppercased() {
            switch ch {
            case "G", "C": gc += 1
            case "A", "T": at += 1
            default: break
            }
        }
        let total = gc + at
        guard total > 0 else { return 0 }

        // Clamp the salt term. log10(0) is −infinity, which would propagate an
        // infinite Tm through every downstream calculation and display.
        let logNa = log10(max(sodiumMolar, 0.001))

        if total < 14 {
            // Wallace rule, corrected from the 50 mM the rule assumes.
            return Double(at * 2 + gc * 4) - 16.6 * log10(0.050) + 16.6 * logNa
        } else if total <= 51 {
            return 100.5 + 41.0 * Double(gc) / Double(total) - 820.0 / Double(total) + 16.6 * logNa
        } else {
            return 81.5 + 41.0 * Double(gc) / Double(total) - 500.0 / Double(total) + 16.6 * logNa
        }
    }
}

// MARK: - Strand Enum
enum Strand: String, Codable {
    case forward
    case reverse
}

// MARK: - FeatureType Enum
enum FeatureType: String, Codable, CaseIterable {
    case promoter
    case gene
    case cds
    case terminator
    case origin
    case selectionMarker
    case primerBinding
    case mcs                // multiple cloning site / polylinker
    case enhancer
    case regulatory         // RBS, operator, attenuator, etc.
    case reporter           // GFP, lacZ, luciferase, etc.
    case tag                // His-tag, FLAG, HA, etc.
    case loxP               // recombination site (lox, FRT, att, etc.)
    case intron
    case exon
    case signalPeptide
    case misc               // misc_feature, misc_binding, etc.
    case custom
    
    /// Human-readable label for UI display.
    /// The rawValue is kept short for Codable serialization.
    var displayName: String {
        switch self {
        case .promoter:        return "Promoter"
        case .gene:            return "Gene"
        case .cds:             return "CDS"
        case .terminator:      return "Terminator"
        case .origin:          return "Origin"
        case .selectionMarker: return "Selection Marker"
        case .primerBinding:   return "Primer Binding"
        case .mcs:             return "MCS"
        case .enhancer:        return "Enhancer"
        case .regulatory:      return "Regulatory"
        case .reporter:        return "Reporter"
        case .tag:             return "Tag"
        case .loxP:            return "Recombination Site"
        case .intron:          return "Intron"
        case .exon:            return "Exon"
        case .signalPeptide:   return "Signal Peptide"
        case .misc:            return "Misc Feature"
        case .custom:          return "Custom"
        }
    }
}

// MARK: - Feature Struct
/// Tracks how a Feature was added to a sequence.
enum FeatureSource: String, Codable {
    case imported   // Came from a GB/XDNA/SnapGene/APE file
    case scanned    // Added by the feature library scanner
    case userAdded  // Manually added by the user via Add Feature
}

struct Feature: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var type: FeatureType
    var start: Int
    var end: Int
    var strand: Strand
    var color: CodableColor
    var showArrow: Bool = true   // Whether to draw directional arrow on graphical map
    var source: FeatureSource = .imported  // How this feature was added
}

// MARK: - Feature Coordinate Adjustment
//
// Editing a sequence moves every downstream feature. These helpers are the
// SINGLE place that logic lives — previously it was duplicated (and subtly
// wrong) in SequenceEditorView, and missing entirely from ProteinWindowView.
//
// COORDINATE CONVENTION
// `start` is inclusive, `end` is EXCLUSIVE, matching subsequence(from:to:)
// and `length = end - start` as used throughout the app.
//
// ORIGIN-WRAPPING FEATURES
// On a circular sequence a feature may store start > end, meaning it wraps the
// origin and covers TWO arcs: [start, sequenceLength) and [0, end). See
// CloningStrategyAnalyzer.wrapsOrigin and PredictiveCloningView.wrapsOrigin.
// This is NOT the same as reverse strand — direction lives in `strand`.
//
// Wrapping features are why these helpers need the sequence length: without
// it there is no way to tell where the first arc ends. Treating a wrapping
// feature as min(start,end)...max(start,end) turns a small feature straddling
// the origin into one covering almost the whole plasmid.

extension Feature {

    /// True if this feature wraps the origin of a circular sequence.
    var wrapsOrigin: Bool { start > end }

    /// Adjusts this feature's coordinates after the bases in
    /// `[deleteStart, deleteEnd)` are removed from the sequence.
    ///
    /// - Parameters:
    ///   - deleteStart: first base removed (inclusive).
    ///   - deleteEnd: one past the last base removed (exclusive).
    ///   - sequenceLength: length of the sequence BEFORE the deletion. Required
    ///     to interpret origin-wrapping features.
    /// - Returns: the adjusted feature, or `nil` if nothing of it survives.
    func adjustedForDeletion(deleteStart: Int, deleteEnd: Int, sequenceLength: Int) -> Feature? {
        guard deleteEnd > deleteStart else { return self }   // nothing removed

        let deleteLen = deleteEnd - deleteStart
        let newLength = Swift.max(0, sequenceLength - deleteLen)

        /// Maps one coordinate through the deletion. Coordinates that fall
        /// inside the removed region collapse onto `deleteStart`.
        func mapped(_ c: Int) -> Int {
            if c <= deleteStart { return c }
            if c >= deleteEnd   { return c - deleteLen }
            return deleteStart
        }

        var result = self

        // --- Ordinary feature: a single arc [start, end) ---
        if !wrapsOrigin {
            // Entirely inside the deleted region — gone.
            if start >= deleteStart && end <= deleteEnd { return nil }
            let newStart = mapped(start)
            let newEnd   = mapped(end)
            if newStart >= newEnd { return nil }   // trimmed to nothing
            result.start = newStart
            result.end   = newEnd
            return result
        }

        // --- Origin-wrapping feature: [start, sequenceLength) + [0, end) ---
        let arc1Start = mapped(start)          // tail arc, runs to the end
        let arc2End   = mapped(end)            // head arc, runs from 0
        let arc1Alive = arc1Start < newLength
        let arc2Alive = arc2End   > 0

        switch (arc1Alive, arc2Alive) {
        case (false, false):
            return nil                          // both arcs deleted

        case (true, false):
            // Only the tail survives — no longer wraps.
            result.start = arc1Start
            result.end   = newLength
            return result.start < result.end ? result : nil

        case (false, true):
            // Only the head survives — no longer wraps.
            result.start = 0
            result.end   = arc2End
            return result

        case (true, true):
            // Both arcs survive. If they now meet or overlap, the feature
            // covers the whole (shortened) sequence.
            if arc1Start <= arc2End {
                result.start = 0
                result.end   = newLength
            } else {
                result.start = arc1Start
                result.end   = arc2End
            }
            return result
        }
    }

    /// Adjusts this feature's coordinates after `length` bases are inserted
    /// at position `insertAt`.
    ///
    /// A feature spanning the insertion point grows; one entirely downstream
    /// slides right; one entirely upstream is unchanged. A feature whose
    /// exclusive end sits exactly on `insertAt` does NOT grow — the new bases
    /// land after it.
    ///
    /// No sequence length is needed here: applying the shift to `start` and
    /// `end` independently is already correct for origin-wrapping features,
    /// because their implicit boundary is the (also shifted) sequence end.
    func adjustedForInsertion(at insertAt: Int, length: Int) -> Feature {
        guard length > 0 else { return self }
        var result = self
        result.start = start >= insertAt ? start + length : start
        result.end   = end   >  insertAt ? end   + length : end
        return result
    }
}

extension Array where Element == Feature {

    /// Adjusts every feature after bases in `[deleteStart, deleteEnd)` are
    /// removed, dropping any feature that no longer exists.
    /// `sequenceLength` is the length BEFORE the deletion.
    func shiftedForDeletion(deleteStart: Int, deleteEnd: Int, sequenceLength: Int) -> [Feature] {
        compactMap {
            $0.adjustedForDeletion(deleteStart: deleteStart,
                                   deleteEnd: deleteEnd,
                                   sequenceLength: sequenceLength)
        }
    }

    /// Adjusts every feature after `length` bases are inserted at `insertAt`.
    func shiftedForInsertion(at insertAt: Int, length: Int) -> [Feature] {
        map { $0.adjustedForInsertion(at: insertAt, length: length) }
    }

    /// Convenience for edits that replace `[replaceStart, replaceEnd)` with
    /// `insertedLength` new bases (paste or typing over a selection).
    /// Applies the deletion first, then the insertion.
    /// `sequenceLength` is the length BEFORE the edit.
    func shiftedForReplacement(replaceStart: Int, replaceEnd: Int,
                               insertedLength: Int, sequenceLength: Int) -> [Feature] {
        shiftedForDeletion(deleteStart: replaceStart,
                           deleteEnd: replaceEnd,
                           sequenceLength: sequenceLength)
            .shiftedForInsertion(at: replaceStart, length: insertedLength)
    }
}

// MARK: - CodableColor Struct
struct CodableColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: Color) {
        // Convert NSColor to sRGB color space first
        let nsColor = NSColor(color)
        
        // Convert to sRGB color space to ensure we can extract RGB values
        guard let rgbColor = nsColor.usingColorSpace(.sRGB) else {
            // Fallback to gray if conversion fails
            self.red = 0.5
            self.green = 0.5
            self.blue = 0.5
            self.alpha = 1.0
            return
        }
        
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        rgbColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        
        self.red = Double(r)
        self.green = Double(g)
        self.blue = Double(b)
        self.alpha = Double(a)
    }
    
    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }
}

// MARK: - GeneticCode Enum
enum GeneticCode: String, CaseIterable {
    case standard = "Standard"
    case vertebrateMitochondrial = "Vertebrate Mitochondrial"
    case yeastMitochondrial = "Yeast Mitochondrial"
    case moldMitochondrial = "Mold Mitochondrial"
    case invertebrateMitochondrial = "Invertebrate Mitochondrial"
    case ciliate = "Ciliate"
    case echinodermMitochondrial = "Echinoderm Mitochondrial"
    case euplotid = "Euplotid"
    case bacterial = "Bacterial"
    case alternativeYeast = "Alternative Yeast"
    case ascidianMitochondrial = "Ascidian Mitochondrial"
    case flatwormMitochondrial = "Flatworm Mitochondrial"
    
    // Only expose codes that have full codon tables implemented below.
    // The remaining cases exist for file-format compatibility (XDNA files that
    // previously stored other codes) but must not appear in the UI picker —
    // they would silently use the standard table and give wrong translations.
    static var allCases: [GeneticCode] {
        [.standard, .vertebrateMitochondrial]
    }
    
    var codonTable: [String: Character] {
        switch self {
        case .standard:
            return GeneticCode.standardCodonTable
        case .vertebrateMitochondrial:
            return GeneticCode.vertebrateMitochondrialCodonTable
        default:
            return GeneticCode.standardCodonTable
        }
    }
    
    static let standardCodonTable: [String: Character] = [
        "TTT": "F", "TTC": "F", "TTA": "L", "TTG": "L",
        "TCT": "S", "TCC": "S", "TCA": "S", "TCG": "S",
        "TAT": "Y", "TAC": "Y", "TAA": "*", "TAG": "*",
        "TGT": "C", "TGC": "C", "TGA": "*", "TGG": "W",
        "CTT": "L", "CTC": "L", "CTA": "L", "CTG": "L",
        "CCT": "P", "CCC": "P", "CCA": "P", "CCG": "P",
        "CAT": "H", "CAC": "H", "CAA": "Q", "CAG": "Q",
        "CGT": "R", "CGC": "R", "CGA": "R", "CGG": "R",
        "ATT": "I", "ATC": "I", "ATA": "I", "ATG": "M",
        "ACT": "T", "ACC": "T", "ACA": "T", "ACG": "T",
        "AAT": "N", "AAC": "N", "AAA": "K", "AAG": "K",
        "AGT": "S", "AGC": "S", "AGA": "R", "AGG": "R",
        "GTT": "V", "GTC": "V", "GTA": "V", "GTG": "V",
        "GCT": "A", "GCC": "A", "GCA": "A", "GCG": "A",
        "GAT": "D", "GAC": "D", "GAA": "E", "GAG": "E",
        "GGT": "G", "GGC": "G", "GGA": "G", "GGG": "G"
    ]
    
    static let vertebrateMitochondrialCodonTable: [String: Character] = [
        "TTT": "F", "TTC": "F", "TTA": "L", "TTG": "L",
        "TCT": "S", "TCC": "S", "TCA": "S", "TCG": "S",
        "TAT": "Y", "TAC": "Y", "TAA": "*", "TAG": "*",
        "TGT": "C", "TGC": "C", "TGA": "W", "TGG": "W",
        "CTT": "L", "CTC": "L", "CTA": "L", "CTG": "L",
        "CCT": "P", "CCC": "P", "CCA": "P", "CCG": "P",
        "CAT": "H", "CAC": "H", "CAA": "Q", "CAG": "Q",
        "CGT": "R", "CGC": "R", "CGA": "R", "CGG": "R",
        "ATT": "I", "ATC": "I", "ATA": "M", "ATG": "M",
        "ACT": "T", "ACC": "T", "ACA": "T", "ACG": "T",
        "AAT": "N", "AAC": "N", "AAA": "K", "AAG": "K",
        "AGT": "S", "AGC": "S", "AGA": "*", "AGG": "*",
        "GTT": "V", "GTC": "V", "GTA": "V", "GTG": "V",
        "GCT": "A", "GCC": "A", "GCA": "A", "GCG": "A",
        "GAT": "D", "GAC": "D", "GAA": "E", "GAG": "E",
        "GGT": "G", "GGC": "G", "GGA": "G", "GGG": "G"
    ]
}

// MARK: - DNASequence Class
class DNASequence: ObservableObject, Identifiable {
    var id = UUID()
    
    @Published var name: String
    @Published var sequence: String
    @Published var description: String = ""
    @Published var isCircular: Bool = false
    @Published var isDoubleStranded: Bool = true
    @Published var features: [Feature] = []
    
    /// Cohesive (sticky) end overhangs for linear sequences
    @Published var cohesive5Prime: String = ""
    @Published var cohesive3Prime: String = ""
    
    /// The file URL this sequence was loaded from (nil for new/unsaved sequences)
    var sourceURL: URL?
    
    /// Whether the sequence has unsaved changes
    @Published var isDirty: Bool = false
    
    /// While true, the dirty-tracking subscribers ignore property changes.
    /// Loaders set this to true before mutating the sequence and back to false
    /// on the NEXT main run-loop tick (via DispatchQueue.main.async). That
    /// gives Combine time to drain all the queued publisher events from the
    /// load before tracking resumes — without this, even removeDuplicates()
    /// can't help, because the events from the load are real changes (e.g.
    /// from "" to the loaded sequence), they just shouldn't count as "dirty".
    /// Use markCleanAfterLoad() rather than touching this directly.
    var isLoading: Bool = false
    
    // MARK: - ORF Results (shared with Graphic Map)
    
    struct ORFResult: Identifiable {
        let id = UUID()
        let position: Int    // 1-based start position on the sequence
        let size: Int        // length in nucleotides
        let strand: String   // e.g. "+1", "-2"
        let label: String    // e.g. "ORF 150aa"
        let frame: Int       // e.g. 1, 2, 3, -1, -2, -3
        let protein: String  // amino acid sequence (M...before stop)
        
        var isForward: Bool { strand.hasPrefix("+") }
        var end: Int { position + size - 1 }
        var lengthAA: Int { size / 3 }
    }
    
    @Published var orfResults: [ORFResult] = []
    
    // MARK: - Undo / Redo
    
    /// One undo step. Features MUST be captured alongside the sequence string:
    /// deleting bases shifts every downstream feature, so restoring only the
    /// string would leave the features pointing at the wrong coordinates.
    private struct EditSnapshot {
        let sequence: String
        let features: [Feature]
    }

    private var undoStack: [EditSnapshot] = []
    private var redoStack: [EditSnapshot] = []
    private var isUndoRedoing = false
    private let maxUndoLevels = 50

    /// The current state, for pushing onto either stack.
    private var currentSnapshot: EditSnapshot {
        EditSnapshot(sequence: sequence, features: features)
    }

    /// Call this BEFORE mutating the sequence to save the current state for undo.
    func registerUndo() {
        guard !isUndoRedoing else { return }
        undoStack.append(currentSnapshot)
        if undoStack.count > maxUndoLevels {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        isUndoRedoing = true
        redoStack.append(currentSnapshot)
        sequence = previous.sequence
        features = previous.features
        isUndoRedoing = false
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        isUndoRedoing = true
        undoStack.append(currentSnapshot)
        sequence = next.sequence
        features = next.features
        isUndoRedoing = false
    }
    
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    
    /// Tracks changes to sequence content and features automatically
    private var dirtyCancellables = Set<AnyCancellable>()

    var length: Int { sequence.count }

    init(name: String, sequence: String = "", isCircular: Bool = false) {
        self.name = name
        self.sequence = sequence
        self.isCircular = isCircular
        setupDirtyTracking()
    }
    
    /// Monitors published properties and marks the sequence as dirty when they change.
    /// Uses removeDuplicates() so that spurious same-value writes (e.g. from SwiftUI
    /// text-binding re-commits, view re-mounts, or parsers re-asserting existing values)
    /// do NOT mark the sequence dirty — only genuine changes do.
    /// Also gated on `isLoading` so that real changes happening during a file
    /// load (which Combine delivers asynchronously, after isDirty has been
    /// reset by the loader) do not retroactively dirty the sequence.
    private func setupDirtyTracking() {
        $sequence.removeDuplicates().dropFirst().sink { [weak self] _ in self?.markDirtyIfNotLoading() }.store(in: &dirtyCancellables)
        $name.removeDuplicates().dropFirst().sink { [weak self] _ in self?.markDirtyIfNotLoading() }.store(in: &dirtyCancellables)
        $features.removeDuplicates().dropFirst().sink { [weak self] _ in self?.markDirtyIfNotLoading() }.store(in: &dirtyCancellables)
        $description.removeDuplicates().dropFirst().sink { [weak self] _ in self?.markDirtyIfNotLoading() }.store(in: &dirtyCancellables)
        $isCircular.removeDuplicates().dropFirst().sink { [weak self] _ in self?.markDirtyIfNotLoading() }.store(in: &dirtyCancellables)
        $isDoubleStranded.removeDuplicates().dropFirst().sink { [weak self] _ in self?.markDirtyIfNotLoading() }.store(in: &dirtyCancellables)
        $cohesive5Prime.removeDuplicates().dropFirst().sink { [weak self] _ in self?.markDirtyIfNotLoading() }.store(in: &dirtyCancellables)
        $cohesive3Prime.removeDuplicates().dropFirst().sink { [weak self] _ in self?.markDirtyIfNotLoading() }.store(in: &dirtyCancellables)
    }
    
    private func markDirtyIfNotLoading() {
        guard !isLoading else { return }
        isDirty = true
    }
    
    /// Marks the sequence as clean and suppresses dirty events for one
    /// run-loop tick. Loaders should call this AFTER setting all properties
    /// from the file. The brief suppression window catches Combine events
    /// queued during the load that haven't been delivered yet.
    func markCleanAfterLoad() {
        isLoading = true
        isDirty = false
        DispatchQueue.main.async { [weak self] in
            // One run-loop tick later, all queued Combine events have been
            // delivered (and ignored thanks to isLoading). Now make sure
            // isDirty is still false (in case it was set inside the same
            // tick by the queued events) and re-enable tracking.
            guard let self = self else { return }
            self.isDirty = false
            self.isLoading = false
        }
    }
    
    // MARK: - Sequence Analysis Methods
    
    /// Calculate GC content as a percentage
    func gcContent() -> Double {
        let seq = sequence.uppercased()
        let gcCount = seq.filter { $0 == "G" || $0 == "C" }.count
        guard seq.count > 0 else { return 0 }
        return Double(gcCount) / Double(seq.count) * 100.0
    }
    
    /// Reverse complement of a DNA/RNA string — standalone, no object allocation.
    /// Handles IUPAC ambiguity codes and preserves case.
    /// Used internally by translate() and findORFs() to avoid creating temporary
    /// DNASequence ObservableObjects (which would spin up 8 Combine subscriptions each).
    static func reverseComplementString(_ seq: String) -> String {
        let complementMap: [Character: Character] = [
            "A": "T", "T": "A", "G": "C", "C": "G",
            "a": "t", "t": "a", "g": "c", "c": "g",
            "N": "N", "n": "n",
            "R": "Y", "Y": "R", "S": "S", "W": "W",
            "K": "M", "M": "K", "B": "V", "V": "B",
            "D": "H", "H": "D",
            "r": "y", "y": "r", "s": "s", "w": "w",
            "k": "m", "m": "k", "b": "v", "v": "b",
            "d": "h", "h": "d",
            "U": "A", "u": "a"   // RNA → DNA complement
        ]
        return String(seq.reversed().map { complementMap[$0] ?? $0 })
    }
    
    /// Returns the reverse complement of the DNA sequence.
    /// Delegates to the static helper so the complement map stays in one place.
    func reverseComplement() -> String {
        DNASequence.reverseComplementString(sequence)
    }
    
    /// Translates the DNA sequence to protein
    /// - Parameters:
    ///   - frame: Reading frame (-3 to +3, excluding 0). Positive = forward strand, negative = reverse strand
    ///   - geneticCode: Genetic code to use for translation (default: standard)
    /// - Returns: Protein sequence as a String
    func translate(frame: Int = 1, geneticCode: GeneticCode = .standard) -> String {
        var workingSeq = sequence.uppercased()
        var frameOffset = 0
        
        // Handle negative frames (reverse complement).
        // Use the static helper to avoid allocating a temporary DNASequence ObservableObject.
        if frame < 0 {
            workingSeq = DNASequence.reverseComplementString(workingSeq)
            frameOffset = abs(frame) - 1
        } else if frame > 0 {
            frameOffset = frame - 1
        }
        
        let codonTable = geneticCode.codonTable

        // Work on a Character array indexed by integer.
        //
        // The previous version walked the String on every iteration: both
        // `workingSeq.count` and `workingSeq.index(startIndex, offsetBy: i)` are
        // O(n) on a Swift String, and both sat inside the loop. That made
        // translation O(n²) — on a 50 kb sequence roughly 2.5 billion character
        // steps per reading frame, and findORFs() calls this six times. Taking
        // one O(n) snapshot up front makes the whole loop linear.
        let bases = Array(workingSeq)
        let baseCount = bases.count

        var protein = ""
        protein.reserveCapacity(max(0, (baseCount - frameOffset) / 3))

        // Iterate through sequence in codons (groups of 3)
        var i = frameOffset
        while i + 2 < baseCount {
            let codon = String(bases[i ..< (i + 3)])
            // Unknown or ambiguous codons (anything not in the table, e.g. one
            // containing N) translate to X, as before.
            protein.append(codonTable[codon] ?? "X")
            i += 3
        }

        return protein
    }
    

    
}

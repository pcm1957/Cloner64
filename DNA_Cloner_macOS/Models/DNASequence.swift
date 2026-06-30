import SwiftUI
import Foundation
import Combine

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
    
    private var undoStack: [String] = []
    private var redoStack: [String] = []
    private var isUndoRedoing = false
    private let maxUndoLevels = 50
    
    /// Call this BEFORE mutating the sequence to save the current state for undo.
    func registerUndo() {
        guard !isUndoRedoing else { return }
        undoStack.append(sequence)
        if undoStack.count > maxUndoLevels {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }
    
    func undo() {
        guard let previous = undoStack.popLast() else { return }
        isUndoRedoing = true
        redoStack.append(sequence)
        sequence = previous
        isUndoRedoing = false
    }
    
    func redo() {
        guard let next = redoStack.popLast() else { return }
        isUndoRedoing = true
        undoStack.append(sequence)
        sequence = next
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
        var protein = ""
        
        // Iterate through sequence in codons (groups of 3)
        var i = frameOffset
        while i + 2 < workingSeq.count {
            let startIndex = workingSeq.index(workingSeq.startIndex, offsetBy: i)
            let endIndex = workingSeq.index(startIndex, offsetBy: 3)
            let codon = String(workingSeq[startIndex..<endIndex])
            
            // Translate codon to amino acid
            if let aminoAcid = codonTable[codon] {
                protein.append(aminoAcid)
            } else {
                protein.append("X") // Unknown amino acid
            }
            
            i += 3
        }
        
        return protein
    }
    

    
}

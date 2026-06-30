//
//  RestrictionEnzyme.swift
//  Cloner 64
//

import Foundation
import Combine

struct RestrictionEnzyme: Identifiable, Codable {
    let id: UUID
    let name: String
    let recognitionSite: String
    let cutPosition5Prime: Int // Position relative to recognition site start
    let cutPosition3Prime: Int
    let overhangType: OverhangType
    let methylationSensitivity: String
    let isoschizomers: [String]
    
    init(id: UUID = UUID(), name: String, recognitionSite: String,
         cutPosition5Prime: Int, cutPosition3Prime: Int, overhangType: OverhangType = .sticky5Prime,
         methylationSensitivity: String = "") {
        self.id = id
        self.name = name
        self.recognitionSite = recognitionSite.uppercased()
        self.cutPosition5Prime = cutPosition5Prime
        self.cutPosition3Prime = cutPosition3Prime
        self.overhangType = overhangType
        self.methylationSensitivity = methylationSensitivity
        self.isoschizomers = []
    }
    
    enum OverhangType: String, Codable {
        case blunt = "Blunt"
        case sticky5Prime = "5' Overhang"
        case sticky3Prime = "3' Overhang"
        
        var sticky: Bool {
            self != .blunt
        }
    }
    
    /// The single-stranded overhang sequence produced by this enzyme.
    /// For 5' overhangs: the exposed 5'→3' sequence between cut5 and cut3.
    /// For 3' overhangs: the exposed sequence between cut3 and cut5.
    /// Empty string for blunt cutters.
    var overhangSequence: String {
        let site = recognitionSite
        switch overhangType {
        case .blunt:
            return ""
        case .sticky5Prime:
            let lo = min(cutPosition5Prime, cutPosition3Prime)
            let hi = max(cutPosition5Prime, cutPosition3Prime)
            guard lo >= 0 && hi <= site.count else { return "" }
            let start = site.index(site.startIndex, offsetBy: lo)
            let end = site.index(site.startIndex, offsetBy: hi)
            return String(site[start..<end])
        case .sticky3Prime:
            let lo = min(cutPosition5Prime, cutPosition3Prime)
            let hi = max(cutPosition5Prime, cutPosition3Prime)
            guard lo >= 0 && hi <= site.count else { return "" }
            let start = site.index(site.startIndex, offsetBy: lo)
            let end = site.index(site.startIndex, offsetBy: hi)
            return String(site[start..<end])
        }
    }
    
    // Find all cut sites in a sequence.
    // For circular sequences, also detects recognition sites that wrap across
    // the origin (e.g. "…CCC|GGG…" for SmaI on a circular plasmid).
    func findCutSites(in sequence: String, circular: Bool = false) -> [CutSite] {
        var sites: [CutSite] = []
        let seq = sequence.uppercased()
        let seqLen = seq.count
        let seqArray = Array(seq)
        let pattern = recognitionSite
        let patLen = pattern.count
        
        // For circular sequences, append the first (patLen-1) bases so that
        // recognition sites spanning the origin are found.  Only keep hits
        // whose start position falls within the original sequence length.
        let searchSeq: String
        if circular && seqLen >= patLen {
            searchSeq = seq + String(seq.prefix(patLen - 1))
        } else {
            searchSeq = seq
        }
        
        // Search forward strand
        var searchStart = 0
        while let range = searchSeq.range(of: pattern,
                    range: searchSeq.index(searchSeq.startIndex, offsetBy: searchStart)..<searchSeq.endIndex) {
            let position = searchSeq.distance(from: searchSeq.startIndex, to: range.lowerBound)
            if position < seqLen {
                let warning = checkMethylationOverlap(seqArray: seqArray, seqLen: seqLen, at: position, siteLength: patLen, circular: circular)
                sites.append(CutSite(enzyme: self, position: position, strand: .forward, methylationWarning: warning))
            }
            searchStart = position + 1
        }
        
        // Search reverse strand (using reverse complement of recognition site)
        let reversePattern = reverseComplement(pattern)
        // Skip reverse search for palindromic sites — forward search already found them
        if reversePattern != pattern {
            searchStart = 0
            while let range = searchSeq.range(of: reversePattern,
                        range: searchSeq.index(searchSeq.startIndex, offsetBy: searchStart)..<searchSeq.endIndex) {
                let position = searchSeq.distance(from: searchSeq.startIndex, to: range.lowerBound)
                if position < seqLen {
                    let warning = checkMethylationOverlap(seqArray: seqArray, seqLen: seqLen, at: position, siteLength: patLen, circular: circular)
                    sites.append(CutSite(enzyme: self, position: position, strand: .reverse, methylationWarning: warning))
                }
                searchStart = position + 1
            }
        }
        
        return sites.sorted { $0.position < $1.position }
    }
    
    /// Check whether dam (GATC), dcm (CCAGG/CCTGG), or CpG (CG) methylation
    /// motifs overlap the recognition site at this specific position in the
    /// actual sequence.  Returns an empty string when there is no concern,
    /// or a short warning like "⚠ dam blocked" when there is.
    private func checkMethylationOverlap(seqArray: [Character], seqLen: Int,
                                          at position: Int, siteLength: Int, circular: Bool) -> String {
        guard !methylationSensitivity.isEmpty else { return "" }
        
        // Build a context window: recognition site + up to 4 bp of flanking on each side
        // so that partially-overlapping methylation motifs are detected.
        let flank = 4
        var contextChars: [Character] = []
        var siteOffset = flank  // where the recognition site starts within context
        
        if circular {
            for i in -flank ..< (siteLength + flank) {
                let idx = ((position + i) % seqLen + seqLen) % seqLen
                contextChars.append(seqArray[idx])
            }
        } else {
            siteOffset = min(flank, position)
            let start = max(0, position - flank)
            let end = min(seqLen, position + siteLength + flank)
            for i in start ..< end {
                contextChars.append(seqArray[i])
            }
        }
        
        let context = String(contextChars)
        let contextLen = context.count
        
        // Does a given motif overlap the recognition-site region in the context?
        func motifOverlaps(_ motif: String) -> Bool {
            let motifLen = motif.count
            guard contextLen >= motifLen else { return false }
            let contextArr = Array(context)
            let motifArr = Array(motif)
            for i in 0 ... (contextLen - motifLen) {
                if contextArr[i ..< (i + motifLen)].elementsEqual(motifArr) {
                    // Overlap exists when the motif intersects the recognition site
                    if (i + motifLen) > siteOffset && i < (siteOffset + siteLength) {
                        return true
                    }
                }
            }
            return false
        }
        
        var warnings: [String] = []
        let sens = methylationSensitivity.lowercased()
        
        // dam (GATC) — adenine methylation in E. coli
        if sens.contains("requires dam") {
            warnings.append("⚠ Requires dam methylation")
        } else if sens.contains("dam") {
            if motifOverlaps("GATC") {
                warnings.append(sens.contains("impaired") ? "⚠ dam impaired" : "⚠ dam blocked")
            }
        }
        
        // dcm (CCAGG / CCTGG) — cytosine methylation in E. coli
        if sens.contains("dcm") {
            if motifOverlaps("CCAGG") || motifOverlaps("CCTGG") {
                warnings.append(sens.contains("impaired") ? "⚠ dcm impaired" : "⚠ dcm blocked")
            }
        }
        
        // CpG — eukaryotic cytosine methylation
        if sens.contains("cpg") && !sens.contains("not blocked") {
            if motifOverlaps("CG") {
                warnings.append("⚠ CpG blocked")
            }
        }
        
        return warnings.joined(separator: "; ")
    }
    
    private func reverseComplement(_ seq: String) -> String {
        let complement: [Character: Character] = ["A": "T", "T": "A", "G": "C", "C": "G", "N": "N"]
        return String(seq.reversed().map { complement[$0] ?? $0 })
    }
}

struct CutSite: Identifiable {
    let id = UUID()
    let enzyme: RestrictionEnzyme
    let position: Int
    let strand: Strand
    let methylationWarning: String
    
    var cutPosition5Prime: Int {
        position + enzyme.cutPosition5Prime
    }
    
    var cutPosition3Prime: Int {
        position + enzyme.cutPosition3Prime
    }
}

class RestrictionEnzymeDatabase: ObservableObject {
    static let shared = RestrictionEnzymeDatabase()
    
    @Published private(set) var enzymes: [RestrictionEnzyme] = []
    
    // MARK: - My Enzymes (user's freezer stock)
    
    /// Names of enzymes the user has in their freezer.
    /// Persisted via UserDefaults so the list survives app restarts.
    @Published var myEnzymeNames: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(Array(myEnzymeNames), forKey: "myEnzymeNames")
        }
    }
    
    /// The subset of the database that the user has marked as "in my freezer".
    var myEnzymes: [RestrictionEnzyme] {
        enzymes.filter { myEnzymeNames.contains($0.name) }
    }
    
    /// Whether a given enzyme is in the user's freezer list.
    func isMyEnzyme(_ name: String) -> Bool {
        myEnzymeNames.contains(name)
    }
    
    /// Toggle an enzyme in/out of the user's freezer list.
    func toggleMyEnzyme(_ name: String) {
        if myEnzymeNames.contains(name) {
            myEnzymeNames.remove(name)
        } else {
            myEnzymeNames.insert(name)
        }
    }
    
    init() {
        // Restore saved freezer list
        if let saved = UserDefaults.standard.stringArray(forKey: "myEnzymeNames") {
            myEnzymeNames = Set(saved)
        }
        loadCommonEnzymes()
    }
    
    func addEnzyme(_ enzyme: RestrictionEnzyme) {
        enzymes.append(enzyme)
        enzymes.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    
    func removeEnzyme(id: UUID) {
        enzymes.removeAll { $0.id == id }
    }
    
    func updateEnzyme(_ enzyme: RestrictionEnzyme) {
        if let idx = enzymes.firstIndex(where: { $0.id == enzyme.id }) {
            enzymes[idx] = enzyme
        }
    }
    
    /// Groups enzymes by their compatible overhang: (overhangType, overhangSequence).
    /// All blunt cutters form one group. Sticky cutters are grouped by overhang type + sequence.
    func compatibleEndGroups() -> [(overhang: String, type: RestrictionEnzyme.OverhangType, enzymes: [RestrictionEnzyme])] {
        var groups: [String: (type: RestrictionEnzyme.OverhangType, enzymes: [RestrictionEnzyme])] = [:]
        
        for enzyme in enzymes {
            let key: String
            switch enzyme.overhangType {
            case .blunt:
                key = "BLUNT"
            case .sticky5Prime:
                key = "5_\(enzyme.overhangSequence)"
            case .sticky3Prime:
                key = "3_\(enzyme.overhangSequence)"
            }
            if groups[key] == nil {
                groups[key] = (type: enzyme.overhangType, enzymes: [])
            }
            groups[key]!.enzymes.append(enzyme)
        }
        
        // Only return groups with 2+ enzymes (those that have compatible partners)
        // plus the blunt group (always useful to show)
        return groups.map { (overhang: $0.value.enzymes.first?.overhangSequence ?? "", type: $0.value.type, enzymes: $0.value.enzymes.sorted { $0.name < $1.name }) }
            .filter { $0.enzymes.count >= 2 || $0.type == .blunt }
            .sorted { a, b in
                if a.type == .blunt && b.type != .blunt { return true }
                if a.type != .blunt && b.type == .blunt { return false }
                if a.type.rawValue != b.type.rawValue { return a.type.rawValue < b.type.rawValue }
                return a.overhang < b.overhang
            }
    }
    
    // CORRECTED VERSION - Add these to your enzymes array in loadCommonEnzymes()
    // Make sure to add a COMMA after each line!

    private func loadCommonEnzymes() {
        enzymes = [
            // EXISTING ENZYMES (keep your current ones)
            // Common 6-cutters
            RestrictionEnzyme(name: "EcoRI", recognitionSite: "GAATTC", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime),
            RestrictionEnzyme(name: "BamHI", recognitionSite: "GGATCC", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime),
            RestrictionEnzyme(name: "HindIII", recognitionSite: "AAGCTT", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime),
            RestrictionEnzyme(name: "PstI", recognitionSite: "CTGCAG", cutPosition5Prime: 5, cutPosition3Prime: 1, overhangType: .sticky3Prime),
            RestrictionEnzyme(name: "SalI", recognitionSite: "GTCGAC", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime),
            RestrictionEnzyme(name: "XhoI", recognitionSite: "CTCGAG", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime),
            RestrictionEnzyme(name: "SacI", recognitionSite: "GAGCTC", cutPosition5Prime: 5, cutPosition3Prime: 1, overhangType: .sticky3Prime),
            RestrictionEnzyme(name: "KpnI", recognitionSite: "GGTACC", cutPosition5Prime: 5, cutPosition3Prime: 1, overhangType: .sticky3Prime),
            RestrictionEnzyme(name: "SmaI", recognitionSite: "CCCGGG", cutPosition5Prime: 3, cutPosition3Prime: 3, overhangType: .blunt, methylationSensitivity: "CpG blocked"),
            RestrictionEnzyme(name: "PvuII", recognitionSite: "CAGCTG", cutPosition5Prime: 3, cutPosition3Prime: 3, overhangType: .blunt),
            RestrictionEnzyme(name: "XbaI", recognitionSite: "TCTAGA", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime, methylationSensitivity: "dam blocked (partial overlap)"),
            RestrictionEnzyme(name: "SpeI/BcuI", recognitionSite: "ACTAGT", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime),
            RestrictionEnzyme(name: "NotI", recognitionSite: "GCGGCCGC", cutPosition5Prime: 2, cutPosition3Prime: 6, overhangType: .sticky5Prime, methylationSensitivity: "CpG blocked"),
            RestrictionEnzyme(name: "NcoI", recognitionSite: "CCATGG", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime),
            RestrictionEnzyme(name: "NdeI", recognitionSite: "CATATG", cutPosition5Prime: 2, cutPosition3Prime: 4, overhangType: .sticky5Prime),
            
            // Common 4-cutters
            RestrictionEnzyme(name: "MspI", recognitionSite: "CCGG", cutPosition5Prime: 1, cutPosition3Prime: 3, overhangType: .sticky5Prime, methylationSensitivity: "CpG: not blocked"),
            RestrictionEnzyme(name: "HaeIII/BsuRI", recognitionSite: "GGCC", cutPosition5Prime: 2, cutPosition3Prime: 2, overhangType: .blunt),
            RestrictionEnzyme(name: "AluI", recognitionSite: "AGCT", cutPosition5Prime: 2, cutPosition3Prime: 2, overhangType: .blunt),
            RestrictionEnzyme(name: "TaqI", recognitionSite: "TCGA", cutPosition5Prime: 1, cutPosition3Prime: 3, overhangType: .sticky5Prime, methylationSensitivity: "dam blocked (partial overlap)"),
            RestrictionEnzyme(name: "DpnI", recognitionSite: "GATC", cutPosition5Prime: 2, cutPosition3Prime: 2, overhangType: .blunt, methylationSensitivity: "Requires dam methylation"),
            
            // Common 8-cutters
            RestrictionEnzyme(name: "AscI/SgsI", recognitionSite: "GGCGCGCC", cutPosition5Prime: 2, cutPosition3Prime: 6, overhangType: .sticky5Prime, methylationSensitivity: "CpG blocked"),
            RestrictionEnzyme(name: "PacI", recognitionSite: "TTAATTAA", cutPosition5Prime: 5, cutPosition3Prime: 3, overhangType: .sticky3Prime),
            RestrictionEnzyme(name: "SbfI/SdaI", recognitionSite: "CCTGCAGG", cutPosition5Prime: 6, cutPosition3Prime: 2, overhangType: .sticky3Prime),
            
            // ========== NEW ENZYMES BELOW ==========
            
            // MORE COMMON 6-CUTTERS
            RestrictionEnzyme(name: "EcoRV/Eco32I", recognitionSite: "GATATC", cutPosition5Prime: 3, cutPosition3Prime: 3, overhangType: .blunt),
            RestrictionEnzyme(name: "ApaI", recognitionSite: "GGGCCC", cutPosition5Prime: 5, cutPosition3Prime: 1, overhangType: .sticky3Prime, methylationSensitivity: "dcm impaired (partial overlap)"),
            RestrictionEnzyme(name: "BglII", recognitionSite: "AGATCT", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime),
            RestrictionEnzyme(name: "NheI", recognitionSite: "GCTAGC", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime),
            RestrictionEnzyme(name: "SphI/PaeI", recognitionSite: "GCATGC", cutPosition5Prime: 5, cutPosition3Prime: 1, overhangType: .sticky3Prime),
            RestrictionEnzyme(name: "ClaI/Bsu15I", recognitionSite: "ATCGAT", cutPosition5Prime: 2, cutPosition3Prime: 4, overhangType: .sticky5Prime, methylationSensitivity: "dam blocked (partial overlap)"),
            RestrictionEnzyme(name: "MluI", recognitionSite: "ACGCGT", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime, methylationSensitivity: "CpG blocked"),
            RestrictionEnzyme(name: "AgeI", recognitionSite: "ACCGGT", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime),
            RestrictionEnzyme(name: "AflII/BspTI", recognitionSite: "CTTAAG", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime),
            RestrictionEnzyme(name: "AseI/VspI", recognitionSite: "ATTAAT", cutPosition5Prime: 2, cutPosition3Prime: 4, overhangType: .sticky5Prime),
            RestrictionEnzyme(name: "AvrII/XmaJI", recognitionSite: "CCTAGG", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime),
            RestrictionEnzyme(name: "BclI", recognitionSite: "TGATCA", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime, methylationSensitivity: "dam blocked"),
            RestrictionEnzyme(name: "BsiWI/Pfl23II", recognitionSite: "CGTACG", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime, methylationSensitivity: "CpG blocked"),
            RestrictionEnzyme(name: "BspEI/Kpn2I", recognitionSite: "TCCGGA", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime),
            RestrictionEnzyme(name: "BspHI/PagI", recognitionSite: "TCATGA", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime, methylationSensitivity: "dam impaired (partial overlap)"),
            RestrictionEnzyme(name: "BsrGI/Bsp1407I", recognitionSite: "TGTACA", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime),
            RestrictionEnzyme(name: "BssHII/PauI", recognitionSite: "GCGCGC", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime, methylationSensitivity: "CpG blocked"),
            RestrictionEnzyme(name: "BstBI/Bsp119I", recognitionSite: "TTCGAA", cutPosition5Prime: 2, cutPosition3Prime: 4, overhangType: .sticky5Prime, methylationSensitivity: "CpG blocked"),
            RestrictionEnzyme(name: "BstZ17I/Bst1107I", recognitionSite: "GTATAC", cutPosition5Prime: 3, cutPosition3Prime: 3, overhangType: .blunt),
            RestrictionEnzyme(name: "DraI", recognitionSite: "TTTAAA", cutPosition5Prime: 3, cutPosition3Prime: 3, overhangType: .blunt),
            RestrictionEnzyme(name: "ScaI", recognitionSite: "AGTACT", cutPosition5Prime: 3, cutPosition3Prime: 3, overhangType: .blunt),
            RestrictionEnzyme(name: "StuI/Eco147I", recognitionSite: "AGGCCT", cutPosition5Prime: 3, cutPosition3Prime: 3, overhangType: .blunt, methylationSensitivity: "dcm blocked (partial overlap)"),
            RestrictionEnzyme(name: "PvuI", recognitionSite: "CGATCG", cutPosition5Prime: 4, cutPosition3Prime: 2, overhangType: .sticky3Prime),
            RestrictionEnzyme(name: "ZraI", recognitionSite: "GACGTC", cutPosition5Prime: 3, cutPosition3Prime: 3, overhangType: .blunt, methylationSensitivity: "CpG blocked"),
            RestrictionEnzyme(name: "MfeI/MunI", recognitionSite: "CAATTG", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime),
            RestrictionEnzyme(name: "NsiI/Mph1103I", recognitionSite: "ATGCAT", cutPosition5Prime: 5, cutPosition3Prime: 1, overhangType: .sticky3Prime),
            RestrictionEnzyme(name: "SacII/Cfr42I", recognitionSite: "CCGCGG", cutPosition5Prime: 4, cutPosition3Prime: 2, overhangType: .sticky3Prime, methylationSensitivity: "CpG blocked"),
            RestrictionEnzyme(name: "SnaBI/Eco105I", recognitionSite: "TACGTA", cutPosition5Prime: 3, cutPosition3Prime: 3, overhangType: .blunt, methylationSensitivity: "CpG blocked"),
            RestrictionEnzyme(name: "NruI/Bsp68I", recognitionSite: "TCGCGA", cutPosition5Prime: 3, cutPosition3Prime: 3, overhangType: .blunt),
            RestrictionEnzyme(name: "NaeI/PdiI", recognitionSite: "GCCGGC", cutPosition5Prime: 3, cutPosition3Prime: 3, overhangType: .blunt, methylationSensitivity: "CpG blocked"),
            RestrictionEnzyme(name: "HpaI/KspAI", recognitionSite: "GTTAAC", cutPosition5Prime: 3, cutPosition3Prime: 3, overhangType: .blunt),
            RestrictionEnzyme(name: "ApaLI/Alw44I", recognitionSite: "GTGCAC", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime),
            RestrictionEnzyme(name: "PciI/PscI", recognitionSite: "ACATGT", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime),
            
            // TYPE IIS ENZYMES (for Golden Gate cloning)
            RestrictionEnzyme(name: "BsaI", recognitionSite: "GGTCTC", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime, methylationSensitivity: "dcm impaired (partial overlap)"),
            RestrictionEnzyme(name: "BsmBI", recognitionSite: "CGTCTC", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime, methylationSensitivity: "CpG blocked"),
            RestrictionEnzyme(name: "BbsI", recognitionSite: "GAAGAC", cutPosition5Prime: 2, cutPosition3Prime: 6, overhangType: .sticky5Prime),
            
            // MORE 8-BASE RARE CUTTERS
            RestrictionEnzyme(name: "FseI", recognitionSite: "GGCCGGCC", cutPosition5Prime: 6, cutPosition3Prime: 2, overhangType: .sticky3Prime, methylationSensitivity: "CpG blocked"),
            RestrictionEnzyme(name: "SwaI/SmiI", recognitionSite: "ATTTAAAT", cutPosition5Prime: 4, cutPosition3Prime: 4, overhangType: .blunt),
            RestrictionEnzyme(name: "PmeI/MssI", recognitionSite: "GTTTAAAC", cutPosition5Prime: 4, cutPosition3Prime: 4, overhangType: .blunt),
            RestrictionEnzyme(name: "AsiSI/SfaAI/SgfI", recognitionSite: "GCGATCGC", cutPosition5Prime: 5, cutPosition3Prime: 3, overhangType: .sticky3Prime, methylationSensitivity: "CpG blocked"),
            
            // ADDITIONAL 4-CUTTERS
            RestrictionEnzyme(name: "HpaII", recognitionSite: "CCGG", cutPosition5Prime: 1, cutPosition3Prime: 3, overhangType: .sticky5Prime, methylationSensitivity: "CpG blocked"),
            RestrictionEnzyme(name: "RsaI", recognitionSite: "GTAC", cutPosition5Prime: 2, cutPosition3Prime: 2, overhangType: .blunt),
            RestrictionEnzyme(name: "Sau3AI/Bsp143I", recognitionSite: "GATC", cutPosition5Prime: 0, cutPosition3Prime: 4, overhangType: .sticky5Prime),
            RestrictionEnzyme(name: "MboI", recognitionSite: "GATC", cutPosition5Prime: 0, cutPosition3Prime: 4, overhangType: .sticky5Prime, methylationSensitivity: "dam blocked"),
            RestrictionEnzyme(name: "HinfI", recognitionSite: "GANTC", cutPosition5Prime: 1, cutPosition3Prime: 4, overhangType: .sticky5Prime),
            RestrictionEnzyme(name: "HhaI", recognitionSite: "GCGC", cutPosition5Prime: 3, cutPosition3Prime: 1, overhangType: .sticky3Prime, methylationSensitivity: "CpG blocked"),
            RestrictionEnzyme(name: "CviAII", recognitionSite: "CATG", cutPosition5Prime: 1, cutPosition3Prime: 3, overhangType: .sticky5Prime),
            RestrictionEnzyme(name: "MseI/Tru1I", recognitionSite: "TTAA", cutPosition5Prime: 1, cutPosition3Prime: 3, overhangType: .sticky5Prime),
            RestrictionEnzyme(name: "NlaIII", recognitionSite: "CATG", cutPosition5Prime: 4, cutPosition3Prime: 0, overhangType: .sticky5Prime),
            RestrictionEnzyme(name: "BfaI", recognitionSite: "CTAG", cutPosition5Prime: 1, cutPosition3Prime: 3, overhangType: .sticky5Prime),
            RestrictionEnzyme(name: "BstUI/Bsh1236I", recognitionSite: "CGCG", cutPosition5Prime: 2, cutPosition3Prime: 2, overhangType: .blunt, methylationSensitivity: "CpG blocked"),

            // ========== THERMO SCIENTIFIC ADDITIONS ==========
            
            // 6-CUTTERS (new recognition sites or neoschizomers with different cut positions)
            RestrictionEnzyme(name: "AanI/PsiI", recognitionSite: "TTATAA", cutPosition5Prime: 3, cutPosition3Prime: 3, overhangType: .blunt),
            RestrictionEnzyme(name: "AatII", recognitionSite: "GACGTC", cutPosition5Prime: 5, cutPosition3Prime: 1, overhangType: .sticky3Prime, methylationSensitivity: "CpG blocked"),
            RestrictionEnzyme(name: "Acc65I", recognitionSite: "GGTACC", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime, methylationSensitivity: "dcm impaired (partial overlap)"),
            RestrictionEnzyme(name: "AjiI/BmgBI", recognitionSite: "CACGTC", cutPosition5Prime: 3, cutPosition3Prime: 3, overhangType: .blunt, methylationSensitivity: "CpG blocked"),
            RestrictionEnzyme(name: "Bsp120I/PspOMI", recognitionSite: "GGGCCC", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime, methylationSensitivity: "dcm blocked (partial overlap)"),
            RestrictionEnzyme(name: "Cfr9I/XmaI", recognitionSite: "CCCGGG", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime, methylationSensitivity: "CpG blocked"),
            RestrictionEnzyme(name: "Ecl136II/EcoICRI", recognitionSite: "GAGCTC", cutPosition5Prime: 3, cutPosition3Prime: 3, overhangType: .blunt),
            RestrictionEnzyme(name: "Eco47III/AfeI", recognitionSite: "AGCGCT", cutPosition5Prime: 3, cutPosition3Prime: 3, overhangType: .blunt, methylationSensitivity: "CpG blocked"),
            RestrictionEnzyme(name: "Eco52I/EagI", recognitionSite: "CGGCCG", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime, methylationSensitivity: "CpG blocked"),
            RestrictionEnzyme(name: "Eco72I/PmlI", recognitionSite: "CACGTG", cutPosition5Prime: 3, cutPosition3Prime: 3, overhangType: .blunt, methylationSensitivity: "CpG blocked"),
            RestrictionEnzyme(name: "EheI/SfoI", recognitionSite: "GGCGCC", cutPosition5Prime: 3, cutPosition3Prime: 3, overhangType: .blunt, methylationSensitivity: "CpG blocked"),
            RestrictionEnzyme(name: "MlsI/MscI", recognitionSite: "TGGCCA", cutPosition5Prime: 3, cutPosition3Prime: 3, overhangType: .blunt, methylationSensitivity: "dcm blocked (partial overlap)"),
            RestrictionEnzyme(name: "NsbI/FspI", recognitionSite: "TGCGCA", cutPosition5Prime: 3, cutPosition3Prime: 3, overhangType: .blunt, methylationSensitivity: "CpG blocked"),
            RestrictionEnzyme(name: "Psp1406I/AclI", recognitionSite: "AACGTT", cutPosition5Prime: 2, cutPosition3Prime: 4, overhangType: .sticky5Prime, methylationSensitivity: "CpG blocked"),
            RestrictionEnzyme(name: "SspI", recognitionSite: "AATATT", cutPosition5Prime: 3, cutPosition3Prime: 3, overhangType: .blunt),
            RestrictionEnzyme(name: "SspDI/KasI", recognitionSite: "GGCGCC", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime, methylationSensitivity: "CpG blocked"),
            
            // ADDITIONAL 4-CUTTERS
            RestrictionEnzyme(name: "Csp6I/CviQI", recognitionSite: "GTAC", cutPosition5Prime: 1, cutPosition3Prime: 3, overhangType: .sticky5Prime),
            RestrictionEnzyme(name: "Hin6I/HinP1I", recognitionSite: "GCGC", cutPosition5Prime: 1, cutPosition3Prime: 3, overhangType: .sticky5Prime, methylationSensitivity: "CpG blocked"),
            RestrictionEnzyme(name: "SsiI/AciI", recognitionSite: "CCGC", cutPosition5Prime: 1, cutPosition3Prime: 3, overhangType: .sticky5Prime, methylationSensitivity: "CpG blocked"),
            RestrictionEnzyme(name: "TaiI/MaeII", recognitionSite: "ACGT", cutPosition5Prime: 2, cutPosition3Prime: 2, overhangType: .blunt, methylationSensitivity: "CpG blocked"),
            RestrictionEnzyme(name: "TasI/Tsp509I", recognitionSite: "AATT", cutPosition5Prime: 0, cutPosition3Prime: 4, overhangType: .sticky5Prime),
            
            // ADDITIONAL 8-CUTTERS
            RestrictionEnzyme(name: "MauBI", recognitionSite: "CGCGCGCG", cutPosition5Prime: 2, cutPosition3Prime: 6, overhangType: .sticky5Prime, methylationSensitivity: "CpG blocked"),
            RestrictionEnzyme(name: "MreI/Sse232I", recognitionSite: "CGCCGGCG", cutPosition5Prime: 2, cutPosition3Prime: 6, overhangType: .sticky5Prime, methylationSensitivity: "CpG blocked"),
            
            // HOMING ENDONUCLEASE (18bp site - extremely rare cutter)
            RestrictionEnzyme(name: "I-SceI", recognitionSite: "TAGGGATAACAGGGTAAT", cutPosition5Prime: 9, cutPosition3Prime: 13, overhangType: .sticky3Prime),
            
            // ========== REBASE-VERIFIED ADDITIONS ==========
            
            // ADDITIONAL 4-CUTTER (blunt)
            // CviRI and HpyCH4V are isoschizomers cutting TGCA to give a blunt end.
            RestrictionEnzyme(name: "CviRI/HpyCH4V", recognitionSite: "TGCA", cutPosition5Prime: 2, cutPosition3Prime: 2, overhangType: .blunt),
            
            // ADDITIONAL 8-CUTTERS WITH TCGA OVERHANG
            // AbsI (CCTCGAGG) creates a 4-base 5' TCGA overhang — compatible with
            // XhoI, SalI, ClaI, and TaqI.  CpG blocked because the site contains CG.
            RestrictionEnzyme(name: "AbsI", recognitionSite: "CCTCGAGG", cutPosition5Prime: 2, cutPosition3Prime: 6, overhangType: .sticky5Prime, methylationSensitivity: "CpG blocked"),
            
            // SgrDI (CGTCGACG) similarly creates a 4-base 5' TCGA overhang and is
            // therefore compatible with XhoI, SalI, ClaI, and TaqI.
            RestrictionEnzyme(name: "SgrDI", recognitionSite: "CGTCGACG", cutPosition5Prime: 2, cutPosition3Prime: 6, overhangType: .sticky5Prime, methylationSensitivity: "CpG blocked"),
            
            // SrfI (GCCCGGGC) is a blunt-end 8-cutter — a GC-flanked relative of SmaI.
            RestrictionEnzyme(name: "SrfI", recognitionSite: "GCCCGGGC", cutPosition5Prime: 4, cutPosition3Prime: 4, overhangType: .blunt, methylationSensitivity: "CpG blocked"),
            
            // ADDITIONAL TYPE IIS ENZYME
            // SapI is widely used for Golden Gate assembly and tRNA-based expression
            // systems.  Like BsaI/BsmBI it cuts outside its recognition site; cut
            // positions here are stored as placeholders (consistent with the convention
            // used for BsaI/BsmBI) and represent a 3-base 5' overhang.
            RestrictionEnzyme(name: "SapI", recognitionSite: "GCTCTTC", cutPosition5Prime: 1, cutPosition3Prime: 4, overhangType: .sticky5Prime),
            
        ]
    }
    
    func search(name: String) -> [RestrictionEnzyme] {
        let lowercaseName = name.lowercased()
        return enzymes.filter { $0.name.lowercased().contains(lowercaseName) }
    }
}

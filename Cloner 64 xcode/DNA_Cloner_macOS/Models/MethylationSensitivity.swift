//
//  MethylationSensitivity.swift
//  Cloner 64
//
//  Methylation sensitivity database and per-site overlap checking.
//  Supports Dam (GATC, m6A), Dcm (CCWGG, m5C), and CpG (CG, m5C).
//  Based on NEB enzyme catalog data.
//

import Foundation

// MARK: - Methylation Types

enum MethylationType: String, CaseIterable {
    case dam  = "Dam"      // GATC methylation (m6A) — standard E. coli
    case dcm  = "Dcm"      // CCWGG methylation (m5C, W = A or T) — standard E. coli
    case cpg  = "CpG"      // CG methylation (m5C) — mammalian
}

enum MethylationEffect: String {
    case blocked  = "Blocked"     // enzyme cannot cut
    case impaired = "Impaired"    // enzyme cuts poorly
    case required = "Required"    // enzyme REQUIRES methylation (e.g. DpnI)
}

struct MethylationWarning {
    let type: MethylationType
    let effect: MethylationEffect
}

// MARK: - Methylation Sensitivity Database

/// Stores which enzymes are sensitive to which methylation types.
/// Only enzymes with known sensitivity are listed — unlisted enzymes
/// are assumed to be unaffected.
struct MethylationSensitivityDB {
    
    /// Returns the methylation sensitivities for a given enzyme name.
    /// Empty array = not sensitive to any methylation.
    static func sensitivities(for enzymeName: String) -> [(type: MethylationType, effect: MethylationEffect)] {
        // Normalize: take first name before "/" (e.g. "ClaI/Bsu15I" → "ClaI")
        let name = enzymeName.components(separatedBy: "/").first?.trimmingCharacters(in: .whitespaces) ?? enzymeName
        return database[name] ?? []
    }
    
    /// Master database of methylation sensitivities.
    /// Sources: NEB catalog, REBASE.
    private static let database: [String: [(type: MethylationType, effect: MethylationEffect)]] = [
        
        // ── Dam sensitive (GATC, m6A at adenine) ──
        // These enzymes are blocked or impaired when their recognition site
        // overlaps with a methylated GATC motif.
        
        "BclI":    [(.dam, .blocked)],     // TGATCA — always contains GATC
        "ClaI":    [(.dam, .blocked)],     // ATCGAT — blocked when preceded by G (GATCGAT)
        "Bsu15I":  [(.dam, .blocked)],     // same as ClaI
        "MboI":    [(.dam, .blocked)],     // GATC — directly methylated
        "DpnII":   [(.dam, .blocked)],     // GATC — blocked by dam
        "XbaI":    [(.dam, .impaired)],    // TCTAGA — impaired when GATCTAGA context
        "NdeI":    [(.dam, .impaired)],    // CATATG — impaired at some overlapping contexts
        "BglII":   [(.dam, .impaired)],    // AGATCT — impaired at AGATCTC context
        "BspHI":   [(.dam, .impaired)],    // TCATGA — impaired when TCATGATC
        
        // DpnI is special: it REQUIRES Dam methylation to cut
        "DpnI":    [(.dam, .required)],    // GATC — only cuts when methylated
        
        // Sau3AI is NOT affected by Dam — cuts GATC regardless
        // (intentionally omitted = unaffected)
        
        // ── Dcm sensitive (CCWGG, m5C at internal cytosine, W = A or T) ──
        
        "AvrII":   [(.dcm, .impaired)],   // CCTAGG — overlaps CCWGG in some contexts
        "BstBI":   [(.dcm, .impaired)],   // TTCGAA — impaired at certain overlaps
        "StuI":    [(.dcm, .impaired)],   // AGGCCT — impaired at certain overlaps
        
        // ── CpG sensitive (CG dinucleotide, m5C) ──
        // These enzymes are blocked when CpG methylation overlaps their site.
        // Common in mammalian DNA but absent in E. coli.
        
        "HpaII":   [(.cpg, .blocked)],    // CCGG — blocked by CpG methylation
        "HhaI":    [(.cpg, .blocked)],    // GCGC — blocked
        "BstUI":   [(.cpg, .blocked)],    // CGCG — blocked
        "NotI":    [(.cpg, .blocked)],    // GCGGCCGC — blocked
        "SacII":   [(.cpg, .blocked)],    // CCGCGG — blocked
        "NaeI":    [(.cpg, .blocked)],    // GCCGGC — blocked
        "NruI":    [(.cpg, .blocked)],    // TCGCGA — blocked
        "BssHII":  [(.cpg, .blocked)],    // GCGCGC — blocked
        "AgeI":    [(.cpg, .impaired)],   // ACCGGT — impaired
        "SalI":    [(.cpg, .impaired)],   // GTCGAC — impaired at CpG overlaps
        "AscI":    [(.cpg, .blocked)],    // GGCGCGCC — blocked
        "SgfI":    [(.cpg, .blocked)],    // GCGATCGC — blocked
        "AsiSI":   [(.cpg, .blocked)],    // GCGATCGC — blocked
        "PvuI":    [(.cpg, .impaired)],   // CGATCG — impaired
        "BsiWI":   [(.cpg, .impaired)],   // CGTACG — impaired
        "MluI":    [(.cpg, .impaired)],   // ACGCGT — impaired
        
        // MspI is NOT affected by CpG — cuts CCGG regardless
        // (intentionally omitted = unaffected)
        
        // ── Multiple sensitivities ──
        
        "NheI":    [(.dam, .impaired), (.cpg, .impaired)],  // GCTAGC
        "SphI":    [(.dam, .impaired)],                       // GCATGC
        "PaeI":    [(.dam, .impaired)],                       // same as SphI
    ]
}


// MARK: - Per-Site Methylation Checking

/// Checks whether a specific cut site on a sequence is actually affected
/// by active methylation systems.
struct MethylationChecker {
    
    /// The methylation motif sequences to search for
    private static let damMotif = "GATC"
    private static let dcmMotifs = ["CCAGG", "CCWGG", "CCTGG"]  // W = A or T
    
    /// Check if a specific restriction site at a given position is affected
    /// by any of the active methylation systems.
    ///
    /// - Parameters:
    ///   - enzymeName: Name of the restriction enzyme
    ///   - sitePosition: 0-based position of the recognition site on the sequence
    ///   - recognitionSite: The enzyme's recognition sequence
    ///   - sequence: The full DNA sequence (uppercased)
    ///   - circular: Whether the sequence is circular
    ///   - activeDam: Whether Dam methylation is active
    ///   - activeDcm: Whether Dcm methylation is active
    ///   - activeCpG: Whether CpG methylation is active
    /// - Returns: Array of warnings for this specific site (empty = unaffected)
    static func checkSite(
        enzymeName: String,
        sitePosition: Int,
        recognitionSite: String,
        sequence: String,
        circular: Bool,
        activeDam: Bool,
        activeDcm: Bool,
        activeCpG: Bool
    ) -> [MethylationWarning] {
        
        let sensitivities = MethylationSensitivityDB.sensitivities(for: enzymeName)
        guard !sensitivities.isEmpty else { return [] }
        
        var warnings: [MethylationWarning] = []
        let seqLen = sequence.count
        
        // Extract a window around the site: recognition site + 4 bp flanking each side
        let flank = 4
        let windowStart = sitePosition - flank
        let windowEnd = sitePosition + recognitionSite.count + flank
        let window = extractWindow(from: sequence, start: windowStart, end: windowEnd, seqLen: seqLen, circular: circular)
        let siteOffsetInWindow = flank  // recognition site starts at this offset in the window
        
        for (methType, effect) in sensitivities {
            switch methType {
            case .dam:
                guard activeDam else { continue }
                // Check if GATC overlaps the recognition site within the window
                if motifOverlapsSite(motif: damMotif, window: window, siteOffset: siteOffsetInWindow, siteLength: recognitionSite.count) {
                    warnings.append(MethylationWarning(type: .dam, effect: effect))
                }
                // Special case: if the recognition site IS GATC (DpnI, MboI), always flag
                if recognitionSite == "GATC" {
                    if !warnings.contains(where: { $0.type == .dam }) {
                        warnings.append(MethylationWarning(type: .dam, effect: effect))
                    }
                }
                
            case .dcm:
                guard activeDcm else { continue }
                // Check if CCAGG or CCTGG overlaps the recognition site
                for motif in ["CCAGG", "CCTGG"] {
                    if motifOverlapsSite(motif: motif, window: window, siteOffset: siteOffsetInWindow, siteLength: recognitionSite.count) {
                        warnings.append(MethylationWarning(type: .dcm, effect: effect))
                        break
                    }
                }
                
            case .cpg:
                guard activeCpG else { continue }
                // Check if any CG dinucleotide overlaps the recognition site
                if motifOverlapsSite(motif: "CG", window: window, siteOffset: siteOffsetInWindow, siteLength: recognitionSite.count) {
                    warnings.append(MethylationWarning(type: .cpg, effect: effect))
                }
            }
        }
        
        return warnings
    }
    
    /// Check if a methylation motif overlaps with the recognition site region
    /// within the extracted window.
    private static func motifOverlapsSite(motif: String, window: String, siteOffset: Int, siteLength: Int) -> Bool {
        // The site occupies positions siteOffset..<(siteOffset + siteLength) in the window
        // A motif overlaps if its range intersects with the site range
        let siteRange = siteOffset..<(siteOffset + siteLength)
        
        var searchStart = window.startIndex
        while let range = window.range(of: motif, range: searchStart..<window.endIndex) {
            let motifStart = window.distance(from: window.startIndex, to: range.lowerBound)
            let motifEnd = motifStart + motif.count
            let motifRange = motifStart..<motifEnd
            
            // Check if ranges overlap
            if motifRange.overlaps(siteRange) {
                return true
            }
            
            // Advance search
            searchStart = window.index(after: range.lowerBound)
        }
        
        return false
    }
    
    /// Extract a window of bases from the sequence, handling circular wrapping.
    private static func extractWindow(from seq: String, start: Int, end: Int, seqLen: Int, circular: Bool) -> String {
        guard seqLen > 0 else { return "" }
        var result = ""
        for i in start..<end {
            var pos = i
            if circular {
                pos = ((pos % seqLen) + seqLen) % seqLen
            } else {
                if pos < 0 || pos >= seqLen { result.append("N"); continue }
            }
            let idx = seq.index(seq.startIndex, offsetBy: pos)
            result.append(seq[idx])
        }
        return result
    }
    
    
    // MARK: - Convenience: Check all sites for an enzyme on a sequence
    
    /// Returns a dictionary mapping site positions to their methylation warnings.
    /// Only positions with actual warnings are included.
    static func checkAllSites(
        enzyme: RestrictionEnzyme,
        sequence: String,
        circular: Bool,
        activeDam: Bool,
        activeDcm: Bool,
        activeCpG: Bool
    ) -> [Int: [MethylationWarning]] {
        let seq = sequence.uppercased()
        let sites = enzyme.findCutSites(in: seq, circular: circular)
        var results: [Int: [MethylationWarning]] = [:]
        
        for site in sites {
            let warnings = checkSite(
                enzymeName: enzyme.name,
                sitePosition: site.position,
                recognitionSite: enzyme.recognitionSite,
                sequence: seq,
                circular: circular,
                activeDam: activeDam,
                activeDcm: activeDcm,
                activeCpG: activeCpG
            )
            if !warnings.isEmpty {
                results[site.position] = warnings
            }
        }
        
        return results
    }
    
    
    // MARK: - Display Helpers
    
    /// Short warning text for a set of warnings (e.g. "Dam⊘" or "CpG⊘ Dcm!")
    static func warningText(_ warnings: [MethylationWarning]) -> String {
        warnings.map { w in
            let symbol: String
            switch w.effect {
            case .blocked:  symbol = "⊘"
            case .impaired: symbol = "!"
            case .required: symbol = "✓"
            }
            return "\(w.type.rawValue)\(symbol)"
        }.joined(separator: " ")
    }
    
    /// Tooltip text for a set of warnings
    static func tooltipText(_ warnings: [MethylationWarning]) -> String {
        warnings.map { w in
            let desc: String
            switch w.effect {
            case .blocked:  desc = "blocked by"
            case .impaired: desc = "impaired by"
            case .required: desc = "requires"
            }
            let methDesc: String
            switch w.type {
            case .dam: methDesc = "Dam methylation (GATC)"
            case .dcm: methDesc = "Dcm methylation (CCWGG)"
            case .cpg: methDesc = "CpG methylation"
            }
            return "Cutting \(desc) \(methDesc)"
        }.joined(separator: "\n")
    }
    
    /// Whether any warning indicates the site won't be cut
    static func isCutBlocked(_ warnings: [MethylationWarning]) -> Bool {
        warnings.contains(where: { $0.effect == .blocked })
    }
    
    /// Whether the enzyme requires methylation to cut (e.g. DpnI)
    static func requiresMethylation(_ warnings: [MethylationWarning]) -> Bool {
        warnings.contains(where: { $0.effect == .required })
    }
}

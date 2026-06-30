//
//  ConstructCheckAnalyzer.swift
//  Cloner 64
//
//  Standalone diagnostic-digest recommender.  Given any plasmid sequence
//  (and optionally a selected feature or ORF), recommends restriction
//  digests that would produce a distinctive, easy-to-read gel pattern
//  proving the plasmid is what the map says it is.
//
//  Four analysis modes:
//   • Fingerprint  — no feature selected.  Finds digests whose band
//                    pattern is clean and distinctive (few well-separated
//                    bands in resolvable range).
//   • Presence     — feature selected, orientation not critical.  Finds
//                    digests that cut within or flanking the feature,
//                    releasing a recognisable fragment.
//   • Orientation  — feature selected and orientation must be confirmed.
//                    Finds asymmetric cutters inside the feature plus
//                    backbone cuts so forward vs reverse give different
//                    patterns.
//   • Comparison   — two sequences supplied (e.g. parent + recombinant).
//                    Finds digests that produce clearly different patterns
//                    between them, confirming a modification was made.
//

import Foundation

// MARK: - Region to check (feature or ORF)

/// Uniform representation of a region to verify — can originate from
/// a Feature annotation or a detected ORF.
struct CheckRegion: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let start: Int          // 0-based inclusive
    let end: Int            // 0-based exclusive (i.e. start + length)
    let strand: Strand
    let source: RegionSource
    
    enum RegionSource: Hashable {
        case feature(UUID)   // Feature.id
        case orf(Int)        // index into orfResults
    }
    
    var length: Int { end - start }
    
    /// Label for the picker dropdown.
    var displayLabel: String {
        let dir = (strand == .forward) ? "→" : "←"
        switch source {
        case .feature: return "\(name) (\(length) bp, \(dir)) — feature"
        case .orf:     return "\(name) (\(length) bp, \(dir)) — ORF"
        }
    }
}


// MARK: - Result type

struct CheckDigestStrategy: Identifiable {
    let id = UUID()
    
    enum Mode: String {
        case fingerprint  = "Fingerprint digest"
        case presence     = "Feature-presence digest"
        case orientation  = "Orientation diagnostic"
        case comparison   = "Plasmid comparison"
    }
    
    let mode: Mode
    let enzymeNames: [String]       // 1 or 2
    let predictedBands: [Int]       // sorted descending;  for comparison: sequence B bands
    let comparisonBands: [Int]      // empty for fingerprint; reverse-orient for orientation; sequence A bands for comparison
    let diagnosticBands: [Int]      // bands that are particularly informative
    let rationale: String
    let score: Int                  // higher = better
}


// MARK: - Methylation context

/// Passed in from app settings so the analyzer can filter out sites that
/// won't cut (blocked by Dam/Dcm/CpG methylation) or flag sites that require
/// methylation to cut (e.g. DpnI).
struct MethylationContext {
    let activeDam: Bool
    let activeDcm: Bool
    let activeCpG: Bool
    /// Convenience: all checks disabled — equivalent to current behaviour.
    static let none = MethylationContext(activeDam: false, activeDcm: false, activeCpG: false)
    var anyActive: Bool { activeDam || activeDcm || activeCpG }
}


// MARK: - Analyzer

final class ConstructCheckAnalyzer {
    
    // Gel resolution parameters
    private let bandTolerancePct = 0.05
    private let bandToleranceBp  = 50
    private let minResolvableBp  = 300
    private let maxResolvableBp  = 10_000
    private let maxResults       = 8
    
    
    // MARK: Public API
    
    /// Build the list of selectable regions from a sequence's features + ORFs.
    func buildRegions(from sequence: DNASequence) -> [CheckRegion] {
        var regions: [CheckRegion] = []
        
        // Features — Feature.start is stored 0-based, Feature.end is 1-based (exclusive).
        // No conversion needed; use start and end directly as 0-based string indices.
        for feat in sequence.features {
            let s = feat.start      // already 0-based
            let e = feat.end        // already 1-based (exclusive upper bound)
            guard e > s, e <= sequence.sequence.count else { continue }
            regions.append(CheckRegion(
                name: feat.name, start: s, end: e,
                strand: feat.strand, source: .feature(feat.id)))
        }
        
        // ORFs — position is 1-based, size is in nucleotides
        for (i, orf) in sequence.orfResults.enumerated() {
            let s = orf.position - 1
            let e = s + orf.size
            guard e <= sequence.sequence.count else { continue }
            regions.append(CheckRegion(
                name: orf.label, start: s, end: e,
                strand: orf.isForward ? .forward : .reverse,
                source: .orf(i)))
        }
        
        return regions.sorted { $0.start < $1.start }
    }
    
    /// Analyse a single sequence and return ranked diagnostic digest strategies.
    func analyze(
        sequence: DNASequence,
        region: CheckRegion?,
        orientationMatters: Bool,
        includeDoubleDigests: Bool,
        enzymes: [RestrictionEnzyme],
        methylation: MethylationContext = .none
    ) -> [CheckDigestStrategy] {
        if let region = region {
            if orientationMatters {
                return analyseOrientation(
                    sequence: sequence, region: region,
                    enzymes: enzymes, methylation: methylation)
            } else {
                return analysePresence(
                    sequence: sequence, region: region,
                    includeDoubles: includeDoubleDigests,
                    enzymes: enzymes, methylation: methylation)
            }
        } else {
            return analyseFingerprint(
                sequence: sequence,
                includeDoubles: includeDoubleDigests,
                enzymes: enzymes, methylation: methylation)
        }
    }
    
    /// Analyse two sequences and return ranked diagnostic strategies that
    /// distinguish them.  sequenceA is typically the original/parent,
    /// sequenceB the modified/recombinant, but the analysis is symmetric.
    func analyseComparison(
        sequenceA: DNASequence,
        sequenceB: DNASequence,
        includeDoubleDigests: Bool,
        enzymes: [RestrictionEnzyme],
        methylation: MethylationContext = .none
    ) -> [CheckDigestStrategy] {
        let seqA = sequenceA.sequence.uppercased()
        let seqB = sequenceB.sequence.uppercased()
        let lenA = seqA.count
        let lenB = seqB.count
        guard lenA > 0, lenB > 0 else { return [] }
        
        // Positive value means B is larger (typical recombinant vs parent scenario).
        let sizeDiff = lenB - lenA
        
        // Pre-compute cut positions for both sequences, respecting methylation.
        var cutsA: [String: [Int]] = [:]
        var cutsB: [String: [Int]] = [:]
        var methylationNotes: [String: String] = [:]
        for enz in enzymes {
            let (ca, allBlocA, someBlocA, isReqA) = methylationAwareCuts(
                enzyme: enz, seq: seqA, circular: sequenceA.isCircular, methylation: methylation)
            let (cb, allBlocB, someBlocB, isReqB) = methylationAwareCuts(
                enzyme: enz, seq: seqB, circular: sequenceB.isCircular, methylation: methylation)
            if !ca.isEmpty { cutsA[enz.name] = ca }
            if !cb.isEmpty { cutsB[enz.name] = cb }
            // Build a note if methylation affects this enzyme on either sequence.
            var note = ""
            if allBlocA && allBlocB {
                note = "all sites blocked by methylation in both sequences"
            } else if allBlocA {
                note = "all sites blocked by methylation in sequence A"
            } else if allBlocB {
                note = "all sites blocked by methylation in sequence B"
            } else if someBlocA || someBlocB {
                note = "some sites blocked by methylation — band pattern reflects unblocked sites only"
            }
            if isReqA || isReqB {
                if !note.isEmpty { note += "; " }
                note += "only cuts methylated DNA"
            }
            if !note.isEmpty { methylationNotes[enz.name] = note }
        }
        
        var results: [CheckDigestStrategy] = []
        
        // ── Single enzymes ──
        for enz in enzymes {
            let ca = cutsA[enz.name] ?? []
            let cb = cutsB[enz.name] ?? []
            let bandsA = digestFragments(seqLen: lenA, isCircular: sequenceA.isCircular,
                                         cutPositions: ca)
            let bandsB = digestFragments(seqLen: lenB, isCircular: sequenceB.isCircular,
                                         cutPositions: cb)
            if let strat = scoreComparison(
                enzymes: [enz.name], aBands: bandsA, bBands: bandsB,
                sizeDiff: sizeDiff, isDouble: false) {
                results.append(strat)
            }
        }
        
        // ── Double enzymes (optional) ──
        if includeDoubleDigests {
            // Include enzymes that cut at least one of the two sequences
            let enzWithCuts = enzymes.filter {
                cutsA[$0.name] != nil || cutsB[$0.name] != nil
            }
            let strongSingles = results.filter { $0.score >= 60 }.count
            if strongSingles < 4 {
                let limit = min(enzWithCuts.count, 80)
                for i in 0..<limit {
                    for j in (i + 1)..<limit {
                        let e1 = enzWithCuts[i]; let e2 = enzWithCuts[j]
                        let combA = (cutsA[e1.name] ?? []) + (cutsA[e2.name] ?? [])
                        let combB = (cutsB[e1.name] ?? []) + (cutsB[e2.name] ?? [])
                        let bandsA = digestFragments(seqLen: lenA, isCircular: sequenceA.isCircular,
                                                     cutPositions: combA)
                        let bandsB = digestFragments(seqLen: lenB, isCircular: sequenceB.isCircular,
                                                     cutPositions: combB)
                        if let strat = scoreComparison(
                            enzymes: [e1.name, e2.name], aBands: bandsA, bBands: bandsB,
                            sizeDiff: sizeDiff, isDouble: true) {
                            results.append(strat)
                        }
                    }
                }
            }
        }
        
        let unique = deduplicate(results)
        let topped = Array(unique.sorted { $0.score > $1.score }.prefix(maxResults))
        return topped.map { appendingNote($0, methylationNotes: methylationNotes) }
    }
    
    /// Pretty-print the results for single-sequence modes.
    func formatReport(
        sequenceInfo: String,
        regionInfo: String?,
        orientationMatters: Bool,
        strategies: [CheckDigestStrategy],
        methylationNote: String? = nil
    ) -> String {
        var s = ""
        let line = String(repeating: "═", count: 70)
        let thin = String(repeating: "─", count: 70)
        
        s += "\(line)\n"
        s += "CHECK CONSTRUCT — DIAGNOSTIC DIGEST STRATEGIES\n"
        s += "Sequence    : \(sequenceInfo)\n"
        if let ri = regionInfo {
            s += "Region      : \(ri)\n"
        }
        if regionInfo != nil {
            s += "Orientation : \(orientationMatters ? "must be determined" : "not critical")\n"
        }
        if let mn = methylationNote {
            s += "Methylation : \(mn)\n"
        }
        s += "\(line)\n\n"
        
        if strategies.isEmpty {
            s += "No suitable diagnostic digest could be found.\n\n"
            s += "Things to try:\n"
            s += "  • Select a different feature or ORF\n"
            s += "  • Enable double digests\n"
            s += "  • Use Virtual Cutter to explore digest patterns manually\n"
            return s
        }
        
        for (i, strat) in strategies.enumerated() {
            let label = (i == 0) ? "  ★ recommended" : ""
            let enzList = strat.enzymeNames.joined(separator: " + ")
            s += "Strategy \(i + 1) — \(strat.mode.rawValue) with \(enzList)\(label)\n"
            s += "  Predicted bands    : \(formatBands(strat.predictedBands))\n"
            
            if strat.mode == .orientation && !strat.comparisonBands.isEmpty {
                s += "  Reverse-orient     : \(formatBands(strat.comparisonBands))\n"
            }
            if !strat.diagnosticBands.isEmpty {
                s += "  Diagnostic band(s) : \(formatBands(strat.diagnosticBands))\n"
            }
            let wrapped = wrap(strat.rationale, width: 60,
                               indent: "                       ")
            s += "  Rationale          : \(wrapped)\n"
            
            if i < strategies.count - 1 { s += "\(thin)\n" }
        }
        
        s += "\n\(line)\n"
        s += "Notes:\n"
        s += "  • Bands within ~5% / 50 bp are treated as co-migrating.\n"
        s += "  • Resolvable range: \(minResolvableBp)–\(maxResolvableBp) bp\n"
        s += "    (typical agarose gel).\n"
        return s
    }
    
    /// Pretty-print the results for plasmid comparison mode.
    func formatComparisonReport(
        seqAInfo: String,
        seqBInfo: String,
        sizeDiff: Int,
        strategies: [CheckDigestStrategy],
        methylationNote: String? = nil
    ) -> String {
        var s = ""
        let line = String(repeating: "═", count: 70)
        let thin = String(repeating: "─", count: 70)
        
        s += "\(line)\n"
        s += "CHECK CONSTRUCT — PLASMID COMPARISON\n"
        s += "Sequence A  : \(seqAInfo)\n"
        s += "Sequence B  : \(seqBInfo)\n"
        if sizeDiff > 0 {
            s += "Size diff   : B is \(formatBp(abs(sizeDiff))) larger than A\n"
        } else if sizeDiff < 0 {
            s += "Size diff   : A is \(formatBp(abs(sizeDiff))) larger than B\n"
        } else {
            s += "Size diff   : sequences are the same length\n"
        }
        if let mn = methylationNote {
            s += "Methylation : \(mn)\n"
        }
        s += "\(line)\n\n"
        
        if strategies.isEmpty {
            s += "No digest found that clearly distinguishes these two plasmids.\n\n"
            s += "Things to try:\n"
            s += "  • Enable double digests\n"
            s += "  • The sequences may differ only in a region not captured by\n"
            s += "    restriction sites — try sequencing or PCR instead\n"
            s += "  • Use Virtual Cutter to compare digest patterns manually\n"
            return s
        }
        
        for (i, strat) in strategies.enumerated() {
            let label = (i == 0) ? "  ★ recommended" : ""
            let enzList = strat.enzymeNames.joined(separator: " + ")
            s += "Strategy \(i + 1) — Comparison digest with \(enzList)\(label)\n"
            s += "  Sequence A bands   : \(formatBands(strat.comparisonBands))\n"
            s += "  Sequence B bands   : \(formatBands(strat.predictedBands))\n"
            if !strat.diagnosticBands.isEmpty {
                s += "  Diagnostic band(s) : \(formatBands(strat.diagnosticBands))\n"
                s += "                       (present in B but not A)\n"
            }
            let wrapped = wrap(strat.rationale, width: 60,
                               indent: "                       ")
            s += "  Rationale          : \(wrapped)\n"
            
            if i < strategies.count - 1 { s += "\(thin)\n" }
        }
        
        s += "\n\(line)\n"
        s += "Notes:\n"
        s += "  • Sequence A = first selected; Sequence B = second selected.\n"
        s += "  • 'Diagnostic bands' are present in B but absent in A.\n"
        s += "  • Run both digests side by side on the same gel for easy\n"
        s += "    comparison (load parent and recombinant in adjacent lanes).\n"
        s += "  • Bands within ~5% / 50 bp are treated as co-migrating.\n"
        s += "  • Resolvable range: \(minResolvableBp)–\(maxResolvableBp) bp.\n"
        return s
    }
    
    
    // MARK: - Fingerprint analysis (no feature selected)
    
    private func analyseFingerprint(
        sequence: DNASequence,
        includeDoubles: Bool,
        enzymes: [RestrictionEnzyme],
        methylation: MethylationContext
    ) -> [CheckDigestStrategy] {
        let seq = sequence.sequence
        let len = seq.count
        let circ = sequence.isCircular
        guard len > 0 else { return [] }
        
        // Pre-compute cut positions, filtering blocked sites.
        var cutsByEnz: [String: [Int]] = [:]
        var methylationNotes: [String: String] = [:]
        for enz in enzymes {
            let (cuts, allBlocked, someBlocked, isRequired) = methylationAwareCuts(
                enzyme: enz, seq: seq, circular: circ, methylation: methylation)
            if !cuts.isEmpty { cutsByEnz[enz.name] = cuts }
            var note = ""
            if allBlocked        { note = "all sites blocked by methylation — excluded" }
            else if someBlocked  { note = "some sites blocked by methylation — band pattern reflects unblocked sites only" }
            if isRequired        { note += (note.isEmpty ? "" : "; ") + "only cuts methylated DNA" }
            if !note.isEmpty     { methylationNotes[enz.name] = note }
        }
        
        var results: [CheckDigestStrategy] = []
        
        // ── Single enzymes ──
        for enz in enzymes {
            guard let cuts = cutsByEnz[enz.name] else { continue }
            let bands = digestFragments(seqLen: len, isCircular: circ,
                                        cutPositions: cuts)
            if let strat = scoreFingerprint(enzymes: [enz.name], bands: bands,
                                            isDouble: false) {
                results.append(strat)
            }
        }
        
        // ── Double enzymes (optional) ──
        if includeDoubles {
            let enzWithCuts = enzymes.filter { cutsByEnz[$0.name] != nil }
            let strongSingles = results.filter { $0.score >= 80 }.count
            // Only enumerate doubles if we don't have plenty of strong singles
            if strongSingles < 5 {
                let limit = min(enzWithCuts.count, 80)  // cap combinatorics
                for i in 0..<limit {
                    for j in (i + 1)..<limit {
                        let e1 = enzWithCuts[i]; let e2 = enzWithCuts[j]
                        let combined = (cutsByEnz[e1.name] ?? [])
                            + (cutsByEnz[e2.name] ?? [])
                        let bands = digestFragments(seqLen: len, isCircular: circ,
                                                    cutPositions: combined)
                        if let strat = scoreFingerprint(
                            enzymes: [e1.name, e2.name], bands: bands,
                            isDouble: true) {
                            results.append(strat)
                        }
                    }
                }
            }
        }
        
        let unique = deduplicate(results)
        let topped = Array(unique.sorted { $0.score > $1.score }.prefix(maxResults))
        return topped.map { appendingNote($0, methylationNotes: methylationNotes) }
    }
    
    private func scoreFingerprint(
        enzymes: [String], bands: [Int], isDouble: Bool
    ) -> CheckDigestStrategy? {
        // Want 3–8 bands, all in resolvable range, well separated
        let resolvable = bands.filter { $0 >= minResolvableBp && $0 <= maxResolvableBp }
        guard resolvable.count >= 2 else { return nil }
        
        // Too many bands = messy gel
        if bands.count > 10 { return nil }
        
        // ── Score components ──
        // Ideal band count: 3–6
        let idealBandBonus: Int
        switch bands.count {
        case 3...6:  idealBandBonus = 30
        case 7...8:  idealBandBonus = 15
        default:     idealBandBonus = 0
        }
        
        // Fraction of bands in resolvable range
        let resolvableFrac = Double(resolvable.count) / Double(max(1, bands.count))
        let resolvableBonus = Int(resolvableFrac * 20)
        
        // Band separation — minimum distance between any two neighbours
        let sorted = bands.sorted()
        var minSep = Int.max
        for i in 0..<(sorted.count - 1) {
            minSep = min(minSep, sorted[i + 1] - sorted[i])
        }
        let separationBonus = min(20, max(0, minSep - 100) / 30)
        
        // Single digest bonus
        let singleBonus = isDouble ? 0 : 20
        
        let score = idealBandBonus + resolvableBonus + separationBonus + singleBonus
        guard score > 20 else { return nil }  // skip weak strategies
        
        let enzLabel = enzymes.joined(separator: " + ")
        let rationale: String
        if isDouble {
            rationale = "\(enzLabel) double digest gives \(bands.count) bands with good separation, providing a distinctive fingerprint pattern."
        } else {
            rationale = "\(enzLabel) gives \(bands.count) well-separated bands. A distinctive fingerprint pattern for confirming the plasmid identity."
        }
        
        return CheckDigestStrategy(
            mode: .fingerprint, enzymeNames: enzymes,
            predictedBands: bands, comparisonBands: [],
            diagnosticBands: resolvable, rationale: rationale, score: score)
    }
    
    
    // MARK: - Presence analysis (feature selected, orientation not critical)
    
    private func analysePresence(
        sequence: DNASequence,
        region: CheckRegion,
        includeDoubles: Bool,
        enzymes: [RestrictionEnzyme],
        methylation: MethylationContext
    ) -> [CheckDigestStrategy] {
        let seq = sequence.sequence
        let len = seq.count
        let circ = sequence.isCircular
        guard len > 0, region.length > 0 else { return [] }
        
        let regStart = region.start
        let regEnd   = region.end
        
        // Pre-compute cuts, filtering blocked sites.
        var cutsByEnz: [String: [Int]] = [:]
        var methylationNotes: [String: String] = [:]
        for enz in enzymes {
            let (cuts, allBlocked, someBlocked, isRequired) = methylationAwareCuts(
                enzyme: enz, seq: seq, circular: circ, methylation: methylation)
            if !cuts.isEmpty { cutsByEnz[enz.name] = cuts }
            var note = ""
            if allBlocked        { note = "all sites blocked by methylation — excluded" }
            else if someBlocked  { note = "some sites blocked by methylation — band pattern reflects unblocked sites only" }
            if isRequired        { note += (note.isEmpty ? "" : "; ") + "only cuts methylated DNA" }
            if !note.isEmpty     { methylationNotes[enz.name] = note }
        }
        
        var results: [CheckDigestStrategy] = []
        
        // ── Single enzymes ──
        for enz in enzymes {
            guard let cuts = cutsByEnz[enz.name] else { continue }
            let bands = digestFragments(seqLen: len, isCircular: circ,
                                        cutPositions: cuts)
            if let strat = scorePresence(
                enzymes: [enz.name], bands: bands, cuts: cuts,
                regStart: regStart, regEnd: regEnd, regionLength: region.length,
                seqLen: len, isDouble: false) {
                results.append(strat)
            }
        }
        
        // ── Double enzymes (optional) ──
        if includeDoubles {
            let enzWithCuts = enzymes.filter { cutsByEnz[$0.name] != nil }
            let strongSingles = results.filter { $0.score >= 80 }.count
            if strongSingles < 5 {
                let limit = min(enzWithCuts.count, 80)
                for i in 0..<limit {
                    for j in (i + 1)..<limit {
                        let e1 = enzWithCuts[i]; let e2 = enzWithCuts[j]
                        let combined = (cutsByEnz[e1.name] ?? [])
                            + (cutsByEnz[e2.name] ?? [])
                        let bands = digestFragments(seqLen: len, isCircular: circ,
                                                    cutPositions: combined)
                        if let strat = scorePresence(
                            enzymes: [e1.name, e2.name], bands: bands,
                            cuts: combined,
                            regStart: regStart, regEnd: regEnd,
                            regionLength: region.length, seqLen: len,
                            isDouble: true) {
                            results.append(strat)
                        }
                    }
                }
            }
        }
        
        let unique = deduplicate(results)
        let topped = Array(unique.sorted { $0.score > $1.score }.prefix(maxResults))
        return topped.map { appendingNote($0, methylationNotes: methylationNotes) }
    }
    
    private func scorePresence(
        enzymes: [String], bands: [Int], cuts: [Int],
        regStart: Int, regEnd: Int, regionLength: Int,
        seqLen: Int, isDouble: Bool
    ) -> CheckDigestStrategy? {
        // Classify cuts relative to the region
        let internalCuts = cuts.filter { $0 >= regStart && $0 < regEnd }
        let flankingCuts = cuts.filter { !($0 >= regStart && $0 < regEnd) }
        
        // Must have at least one cut related to the region:
        //  - cuts inside the region, or
        //  - cuts flanking on both sides (to release a fragment containing the region)
        let hasInternalCut = !internalCuts.isEmpty
        let hasFlankingPair: Bool
        if flankingCuts.count >= 2 {
            // At least one cut before and one after the region
            hasFlankingPair = flankingCuts.contains { $0 < regStart }
                           && flankingCuts.contains { $0 >= regEnd }
        } else {
            hasFlankingPair = false
        }
        
        guard hasInternalCut || hasFlankingPair else { return nil }
        
        // Too many bands = messy
        if bands.count > 10 { return nil }
        
        // At least some bands must be resolvable
        let resolvable = bands.filter { $0 >= minResolvableBp && $0 <= maxResolvableBp }
        guard resolvable.count >= 1 else { return nil }
        
        // ── Score ──
        // Internal cuts are more informative (prove the feature itself is there)
        let internalBonus = hasInternalCut ? 25 : 0
        
        // Flanking pair that releases a recognisable fragment containing the feature
        let flankBonus = hasFlankingPair ? 15 : 0
        
        // If a band is close to the region length, that's very diagnostic
        // (it means the enzyme(s) are neatly excising the feature)
        let releaseBonus = bands.contains(where: {
            abs($0 - regionLength) < max(200, regionLength / 4)
        }) ? 20 : 0
        
        // Prefer fewer total bands (cleaner gel)
        let bandCountPenalty = max(0, bands.count - 5) * 3
        
        // Single digest bonus
        let singleBonus = isDouble ? 0 : 20
        
        // Band separation
        let sorted = bands.sorted()
        var minSep = Int.max
        for i in 0..<max(0, sorted.count - 1) {
            minSep = min(minSep, sorted[i + 1] - sorted[i])
        }
        if minSep == Int.max { minSep = 0 }
        let separationBonus = min(15, max(0, minSep - 80) / 30)
        
        let score = 30 + internalBonus + flankBonus + releaseBonus
            + singleBonus + separationBonus - bandCountPenalty
        guard score > 25 else { return nil }
        
        // Diagnostic bands — those near the feature size or in the region
        let diagnostic = bands.filter { band in
            (abs(band - regionLength) < max(300, regionLength / 3))
            || (band >= minResolvableBp && band <= maxResolvableBp)
        }
        
        let enzLabel = enzymes.joined(separator: " + ")
        var rationale = ""
        if hasInternalCut && hasFlankingPair {
            rationale = "\(enzLabel) cuts inside and flanking the selected region, releasing a diagnostic fragment."
        } else if hasInternalCut {
            rationale = "\(enzLabel) cuts within the selected region. The band pattern confirms the feature is present."
        } else {
            rationale = "\(enzLabel) flanks the selected region, releasing a fragment whose size confirms the feature."
        }
        if releaseBonus > 0 {
            rationale += " One band is close to the expected feature size (\(regionLength) bp)."
        }
        
        return CheckDigestStrategy(
            mode: .presence, enzymeNames: enzymes,
            predictedBands: bands, comparisonBands: [],
            diagnosticBands: diagnostic, rationale: rationale, score: score)
    }
    
    
    // MARK: - Orientation analysis (feature selected, orientation matters)
    
    private func analyseOrientation(
        sequence: DNASequence,
        region: CheckRegion,
        enzymes: [RestrictionEnzyme],
        methylation: MethylationContext
    ) -> [CheckDigestStrategy] {
        let seq = sequence.sequence
        let len = seq.count
        let circ = sequence.isCircular
        guard len > 0, region.length > 0, region.end <= len else { return [] }
        
        let regStart = region.start
        let regEnd   = region.end
        let regLen   = region.length
        
        // Build a hypothetical "reversed-insertion" sequence:
        // same backbone, but the region is reverse-complemented in place.
        let prefix = String(seq.prefix(regStart))
        let regionSeq = String(seq[
            seq.index(seq.startIndex, offsetBy: regStart)
            ..<
            seq.index(seq.startIndex, offsetBy: regEnd)
        ])
        let suffix = String(seq.suffix(len - regEnd))
        let revConstruct = prefix + reverseComplement(regionSeq) + suffix
        
        var results: [CheckDigestStrategy] = []
        
        for enz in enzymes {
            let (fwdCuts, fwdAllBlocked, fwdSomeBlocked, isRequired) = methylationAwareCuts(
                enzyme: enz, seq: seq, circular: circ, methylation: methylation)
            if fwdAllBlocked { continue }  // won't cut — skip
            
            // Need at least one cut INSIDE the region and one OUTSIDE
            let internalCuts = fwdCuts.filter { $0 >= regStart && $0 < regEnd }
            let externalCuts = fwdCuts.filter { !($0 >= regStart && $0 < regEnd) }
            if internalCuts.isEmpty || externalCuts.isEmpty { continue }
            
            // Asymmetry test — at least one internal cut must not sit at the midpoint
            let mid = regStart + regLen / 2
            let midTolerance = max(20, regLen / 20)
            let asymmetric = internalCuts.contains { abs($0 - mid) > midTolerance }
            if !asymmetric { continue }
            
            let (revCuts, _, revSomeBlocked, _) = methylationAwareCuts(
                enzyme: enz, seq: revConstruct, circular: circ, methylation: methylation)
            let fwdBands = digestFragments(seqLen: len, isCircular: circ,
                                           cutPositions: fwdCuts)
            let revBands = digestFragments(seqLen: len, isCircular: circ,
                                           cutPositions: revCuts)
            
            // Patterns must actually differ
            let diff = patternDifference(fwdBands, revBands)
            if diff < 100 { continue }
            
            // Distinguishing bands
            let distinguishing = fwdBands.filter { fb in
                !revBands.contains { abs($0 - fb) <= tol(fb) }
            }
            if !distinguishing.contains(where: {
                $0 >= minResolvableBp && $0 <= maxResolvableBp }) {
                continue
            }
            
            // ── Score ──
            let bestCut = internalCuts.max(by: {
                abs($0 - mid) < abs($1 - mid) }) ?? mid
            let asymPct = Double(abs(bestCut - mid))
                / Double(max(1, regLen / 2))
            let asymBonus = Int(asymPct * 30)
            let diffBonus = min(40, diff / 50)
            let bandCountPenalty = max(0, fwdBands.count - 5) * 5
            let internalCountBonus = (internalCuts.count == 1) ? 10 : 0
            
            let score = 50 + asymBonus + diffBonus
                + internalCountBonus - bandCountPenalty
            
            var rationale = "\(enz.name) cuts asymmetrically inside the selected region and also cuts the backbone. Forward and reverse orientations give distinguishable band patterns on a gel."
            // Append any methylation note inline (orientation mode uses per-strategy notes).
            var methylNote = ""
            if fwdSomeBlocked || revSomeBlocked {
                methylNote = "some sites blocked by methylation — band pattern reflects unblocked sites only"
            }
            if isRequired {
                methylNote += (methylNote.isEmpty ? "" : "; ") + "only cuts methylated DNA"
            }
            if !methylNote.isEmpty {
                rationale += " ⚠ Methylation: \(methylNote)."
            }
            
            results.append(CheckDigestStrategy(
                mode: .orientation, enzymeNames: [enz.name],
                predictedBands: fwdBands, comparisonBands: revBands,
                diagnosticBands: distinguishing, rationale: rationale,
                score: score))
        }
        
        let unique = deduplicate(results)
        return Array(unique.sorted { $0.score > $1.score }.prefix(maxResults))
    }
    
    
    // MARK: - Comparison scoring (two real sequences)
    
    /// Score a digest for how well it distinguishes sequenceA from sequenceB.
    private func scoreComparison(
        enzymes: [String],
        aBands: [Int],   // original / parent
        bBands: [Int],   // modified / recombinant
        sizeDiff: Int,   // lenB - lenA
        isDouble: Bool
    ) -> CheckDigestStrategy? {
        guard !aBands.isEmpty, !bBands.isEmpty else { return nil }
        if aBands.count > 10 || bBands.count > 10 { return nil }
        
        // Patterns must actually differ
        let diff = patternDifference(aBands, bBands)
        if diff < 100 { return nil }
        
        // Need resolvable bands in at least one sequence
        let aRes = aBands.filter { $0 >= minResolvableBp && $0 <= maxResolvableBp }
        let bRes = bBands.filter { $0 >= minResolvableBp && $0 <= maxResolvableBp }
        guard !aRes.isEmpty || !bRes.isEmpty else { return nil }
        
        // Bands unique to B (new bands — confirm the modification)
        let newInB = bBands.filter { bb in
            !aBands.contains { abs($0 - bb) <= tol(bb) }
        }
        // Bands in A that disappeared in B
        let lostFromA = aBands.filter { ab in
            !bBands.contains { abs($0 - ab) <= tol(ab) }
        }
        
        // Must have at least some difference in the resolvable range to be useful
        let usefulNew  = newInB.filter   { $0 >= minResolvableBp && $0 <= maxResolvableBp }
        let usefulLost = lostFromA.filter { $0 >= minResolvableBp && $0 <= maxResolvableBp }
        guard !usefulNew.isEmpty || !usefulLost.isEmpty else { return nil }
        
        // ── Score components ──
        
        // Overall pattern difference
        let diffBonus = min(40, diff / 150)
        
        // New resolvable bands in B (the clearest sign of a modification)
        let newBandBonus = usefulNew.count * 12
        
        // Does a band shift match the known insert size?
        // Classic case: a band in A grows by ~sizeDiff in B because the insert
        // landed inside that fragment.
        let shiftBonus: Int
        if abs(sizeDiff) > 200 {
            let matchesExpectedShift = lostFromA.contains { la in
                newInB.contains { nb in
                    abs((nb - la) - sizeDiff) < max(300, abs(sizeDiff) / 4)
                }
            }
            shiftBonus = matchesExpectedShift ? 25 : 0
        } else {
            shiftBonus = 0
        }
        
        // Clean gel (penalise too many bands)
        let bandCountPenalty = max(0, max(aBands.count, bBands.count) - 5) * 3
        
        // Single digest bonus
        let singleBonus = isDouble ? 0 : 15
        
        // Band separation across both patterns
        let allSorted = (aBands + bBands).sorted()
        var minSep = Int.max
        for i in 0..<max(0, allSorted.count - 1) {
            minSep = min(minSep, allSorted[i + 1] - allSorted[i])
        }
        let separationBonus = min(10, max(0, (minSep == Int.max ? 0 : minSep) - 50) / 30)
        
        let score = 25 + diffBonus + newBandBonus + shiftBonus
            + singleBonus + separationBonus - bandCountPenalty
        guard score > 30 else { return nil }
        
        // Diagnostic bands — new bands in B in resolvable range
        let diagnosticBands = usefulNew
        
        // Build rationale
        let enzLabel = enzymes.joined(separator: " + ")
        var rationale = "\(enzLabel) produces different band patterns for the two plasmids."
        if !newInB.isEmpty {
            rationale += " New band(s) in B: \(newInB.map { formatBp($0) }.joined(separator: ", "))."
        }
        if !lostFromA.isEmpty {
            rationale += " Band(s) present in A but not B: \(lostFromA.map { formatBp($0) }.joined(separator: ", "))."
        }
        if shiftBonus > 0 {
            rationale += " The shift in band size is consistent with the expected size difference (\(formatBp(abs(sizeDiff))))."
        }
        
        return CheckDigestStrategy(
            mode: .comparison,
            enzymeNames: enzymes,
            predictedBands: bBands,      // B = modified
            comparisonBands: aBands,     // A = original
            diagnosticBands: diagnosticBands,
            rationale: rationale,
            score: score
        )
    }
    
    
    // MARK: - Helpers
    
    private func tol(_ band: Int) -> Int {
        max(bandToleranceBp, Int(Double(band) * bandTolerancePct))
    }
    
    private func digestFragments(seqLen: Int, isCircular: Bool,
                                 cutPositions: [Int]) -> [Int] {
        guard seqLen > 0 else { return [] }
        let cuts = cutPositions
            .map { (($0 % seqLen) + seqLen) % seqLen }
            .sorted()
        if cuts.isEmpty { return [seqLen] }
        var fragments: [Int] = []
        if isCircular {
            for i in 0..<cuts.count {
                let next = (i + 1) % cuts.count
                let dist = (cuts[next] - cuts[i] + seqLen) % seqLen
                fragments.append(dist == 0 ? seqLen : dist)
            }
        } else {
            fragments.append(cuts[0])
            for i in 0..<(cuts.count - 1) {
                fragments.append(cuts[i + 1] - cuts[i])
            }
            fragments.append(seqLen - cuts.last!)
        }
        return fragments.filter { $0 > 0 }.sorted(by: >)
    }
    
    private func patternDifference(_ a: [Int], _ b: [Int]) -> Int {
        let aSort = a.sorted(); let bSort = b.sorted()
        let n = min(aSort.count, bSort.count)
        var diff = 0
        for i in 0..<n { diff += abs(aSort[i] - bSort[i]) }
        diff += (max(aSort.count, bSort.count) - n) * 1000
        return diff
    }
    
    private func reverseComplement(_ s: String) -> String {
        let comp: [Character: Character] = [
            "A": "T", "T": "A", "G": "C", "C": "G", "N": "N",
            "a": "t", "t": "a", "g": "c", "c": "g", "n": "n"
        ]
        return String(s.reversed().map { comp[$0] ?? $0 })
    }
    
    private func deduplicate(_ strategies: [CheckDigestStrategy]) -> [CheckDigestStrategy] {
        var bestByKey: [String: CheckDigestStrategy] = [:]
        for s in strategies {
            let key = s.predictedBands.map { String($0 / 50) }
                .joined(separator: ",")
            if let existing = bestByKey[key], existing.score >= s.score {
                continue
            }
            bestByKey[key] = s
        }
        return Array(bestByKey.values)
    }
    
    private func formatBands(_ bands: [Int]) -> String {
        if bands.isEmpty { return "—" }
        return bands.map { formatBp($0) }.joined(separator: ", ")
    }
    
    // MARK: - Methylation-aware cut computation

    /// Compute cut positions for an enzyme, silently filtering out any sites
    /// that are blocked by the current methylation context.
    ///
    /// Returns:
    ///  - positions   : 5′ cut positions that will actually cut (unblocked)
    ///  - allBlocked  : every site on this sequence is methylation-blocked
    ///  - someBlocked : at least one (but not all) site is blocked
    ///  - isRequired  : enzyme requires methylation to cut (e.g. DpnI)
    private func methylationAwareCuts(
        enzyme:      RestrictionEnzyme,
        seq:         String,
        circular:    Bool,
        methylation: MethylationContext
    ) -> (positions: [Int], allBlocked: Bool, someBlocked: Bool, isRequired: Bool) {

        let allCuts = enzyme.findCutSites(in: seq, circular: circular)
        guard !allCuts.isEmpty else { return ([], false, false, false) }

        // Fast path: nothing to check — return all cut positions unchanged.
        guard methylation.anyActive else {
            return (allCuts.map { $0.cutPosition5Prime }, false, false, false)
        }

        let seqUpper    = seq.uppercased()
        var unblocked   : [Int] = []
        var anyBlocked  = false
        var anyRequired = false

        for cs in allCuts {
            let warnings = MethylationChecker.checkSite(
                enzymeName:      enzyme.name,
                sitePosition:    cs.position,
                recognitionSite: enzyme.recognitionSite,
                sequence:        seqUpper,
                circular:        circular,
                activeDam:       methylation.activeDam,
                activeDcm:       methylation.activeDcm,
                activeCpG:       methylation.activeCpG
            )
            if MethylationChecker.isCutBlocked(warnings) {
                anyBlocked = true
            } else {
                unblocked.append(cs.cutPosition5Prime)
            }
            if warnings.contains(where: { $0.effect == .required }) {
                anyRequired = true
            }
        }

        let allBlocked  = unblocked.isEmpty && anyBlocked
        let someBlocked = anyBlocked && !allBlocked
        return (unblocked, allBlocked, someBlocked, anyRequired)
    }

    /// Return a copy of a strategy with a methylation warning appended to its
    /// rationale, based on the per-enzyme notes collected during analysis.
    private func appendingNote(
        _ strategy: CheckDigestStrategy,
        methylationNotes: [String: String]
    ) -> CheckDigestStrategy {
        let notes = strategy.enzymeNames.compactMap { methylationNotes[$0] }
        guard !notes.isEmpty else { return strategy }
        let noteText = notes.joined(separator: "; ")
        return CheckDigestStrategy(
            mode:             strategy.mode,
            enzymeNames:      strategy.enzymeNames,
            predictedBands:   strategy.predictedBands,
            comparisonBands:  strategy.comparisonBands,
            diagnosticBands:  strategy.diagnosticBands,
            rationale:        strategy.rationale + " ⚠ Methylation: " + noteText + ".",
            score:            strategy.score
        )
    }

    func formatBp(_ bp: Int) -> String {
        if bp >= 1000 {
            return String(format: "%.2f kb", Double(bp) / 1000.0)
        }
        return "\(bp) bp"
    }
    
    private func wrap(_ text: String, width: Int, indent: String) -> String {
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ") {
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count <= width {
                current += " " + word
            } else {
                lines.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.enumerated().map { i, line in
            i == 0 ? line : indent + line
        }.joined(separator: "\n")
    }
}

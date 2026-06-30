//
//  DigestVerificationAnalyzer.swift
//  Cloner 64
//
//  Suggests restriction-digest verification strategies for distinguishing
//  recombinant from non-recombinant clones, and for determining insert
//  orientation when it matters.
//
//  Two analysis modes:
//   • Flanking digest — used when orientation is forced (directional cloning)
//     or doesn't matter.  Looks for an enzyme (or pair) that gives a band
//     pattern unique to the recombinant clone, by comparing the construct
//     digest to the empty parental vector digest.
//   • Orientation digest — used when the insert could go in either way.
//     Looks for an enzyme that cuts asymmetrically inside the insert AND
//     also cuts the vector backbone, so forward and reverse insertions
//     give distinguishable band patterns.
//

import Foundation

// MARK: - Result type

struct VerificationStrategy: Identifiable {
    let id = UUID()
    enum Mode { case singleFlanking, doubleFlanking, orientation }
    
    let mode: Mode
    let enzymeNames: [String]      // 1 or 2
    let recombinantBands: [Int]    // sorted descending
    let comparisonBands: [Int]     // parental (flanking) or reverse-orientation
    let diagnosticBands: [Int]     // bands that distinguish the two patterns
    let rationale: String
    let score: Int                 // higher = better
}


// MARK: - Analyzer

final class DigestVerificationAnalyzer {
    
    /// Tolerance for calling two bands "the same size" on a gel.
    private let bandTolerancePct = 0.05
    private let bandToleranceBp  = 50
    
    /// Range of band sizes resolvable on a typical agarose gel.
    private let minResolvableBp = 300
    private let maxResolvableBp = 10_000
    
    /// Maximum number of strategies to return per analysis.
    private let maxResults = 5
    
    
    // MARK: Public API
    
    /// Analyse a construct and return ranked verification-digest strategies.
    /// - Parameters:
    ///   - construct: the assembled construct (circular or linear).
    ///   - parentalVector: the empty (non-recombinant) vector to compare against.
    ///   - insertStart: 0-based start position of the insert in the construct.
    ///   - insertLength: length of the insert in bp.
    ///   - orientationMatters: true if forward vs reverse insertion must be distinguished.
    ///   - enzymes: enzymes to consider (typically the full database).
    func analyze(
        construct: DNASequence,
        parentalVector: DNASequence,
        insertStart: Int,
        insertLength: Int,
        orientationMatters: Bool,
        enzymes: [RestrictionEnzyme]
    ) -> [VerificationStrategy] {
        let insertEnd = insertStart + insertLength
        if orientationMatters {
            return analyseOrientation(construct: construct,
                                      insertStart: insertStart,
                                      insertEnd: insertEnd,
                                      enzymes: enzymes)
        } else {
            return analyseFlanking(construct: construct,
                                   parentalVector: parentalVector,
                                   insertStart: insertStart,
                                   insertEnd: insertEnd,
                                   enzymes: enzymes)
        }
    }
    
    /// Pretty-print a result list as a plain text report.
    func formatReport(
        constructInfo: String,
        insertInfo: String,
        orientationMatters: Bool,
        strategies: [VerificationStrategy]
    ) -> String {
        var s = ""
        let line = String(repeating: "═", count: 70)
        let thin = String(repeating: "─", count: 70)
        s += "\(line)\n"
        s += "DIAGNOSTIC DIGEST STRATEGIES\n"
        s += "Construct       : \(constructInfo)\n"
        s += "Insert          : \(insertInfo)\n"
        s += "Orientation     : \(orientationMatters ? "must be determined" : "not critical")\n"
        s += "\(line)\n\n"
        
        if strategies.isEmpty {
            s += "No suitable verification digest could be found in the\n"
            s += "current enzyme database for this construct.\n\n"
            s += "Things to try:\n"
            s += "  • Add more enzymes to the database\n"
            s += "  • Use Virtual Cutter to explore digest patterns manually\n"
            s += "  • Toggle the orientation setting above\n"
            return s
        }
        
        for (i, strat) in strategies.enumerated() {
            let label = (i == 0) ? "  ★ recommended" : ""
            let modeLabel: String
            switch strat.mode {
            case .singleFlanking:  modeLabel = "Single digest"
            case .doubleFlanking:  modeLabel = "Double digest"
            case .orientation:     modeLabel = "Orientation diagnostic"
            }
            let enzList = strat.enzymeNames.joined(separator: " + ")
            s += "Strategy \(i + 1) — \(modeLabel) with \(enzList)\(label)\n"
            s += "  Recombinant bands  : \(formatBands(strat.recombinantBands))\n"
            let compLabel = strat.mode == .orientation ? "Reverse-insert bands" : "Empty-vector bands "
            s += "  \(compLabel) : \(formatBands(strat.comparisonBands))\n"
            if !strat.diagnosticBands.isEmpty {
                s += "  Diagnostic band(s) : \(formatBands(strat.diagnosticBands))\n"
            }
            // Wrap rationale at ~62 chars
            let wrapped = wrap(strat.rationale, width: 62, indent: "                       ")
            s += "  Rationale          : \(wrapped)\n"
            if i < strategies.count - 1 {
                s += "\(thin)\n"
            }
        }
        s += "\n\(line)\n"
        s += "Notes:\n"
        s += "  • Bands within ~5% / 50 bp are treated as co-migrating.\n"
        s += "  • Diagnostic bands must lie in \(minResolvableBp)–\(maxResolvableBp) bp\n"
        s += "    (typical agarose gel resolution).\n"
        return s
    }
    
    
    // MARK: Flanking analysis
    
    private func analyseFlanking(
        construct: DNASequence,
        parentalVector: DNASequence,
        insertStart: Int,
        insertEnd: Int,
        enzymes: [RestrictionEnzyme]
    ) -> [VerificationStrategy] {
        let cSeq = construct.sequence
        let vSeq = parentalVector.sequence
        let cLen = cSeq.count
        let vLen = vSeq.count
        let cCirc = construct.isCircular
        let vCirc = parentalVector.isCircular
        let insertSize = insertEnd - insertStart
        
        // Pre-compute cut positions for every enzyme on both sequences once.
        var cCutsByEnz: [String: [Int]] = [:]
        var vCutsByEnz: [String: [Int]] = [:]
        for enz in enzymes {
            cCutsByEnz[enz.name] = enz.findCutSites(in: cSeq, circular: cCirc).map { $0.cutPosition5Prime }
            vCutsByEnz[enz.name] = enz.findCutSites(in: vSeq, circular: vCirc).map { $0.cutPosition5Prime }
        }
        
        var results: [VerificationStrategy] = []
        
        // ── Single enzyme digests ──
        for enz in enzymes {
            let cBands = digestFragments(seqLen: cLen, isCircular: cCirc,
                                         cutPositions: cCutsByEnz[enz.name] ?? [])
            let vBands = digestFragments(seqLen: vLen, isCircular: vCirc,
                                         cutPositions: vCutsByEnz[enz.name] ?? [])
            if let strat = scoreFlanking(
                enzymes: [enz.name], mode: .singleFlanking,
                recombinantBands: cBands, parentalBands: vBands,
                insertSize: insertSize) {
                results.append(strat)
            }
        }
        
        // ── Double enzyme digests ──
        // Only enumerate if we don't already have several strong single hits.
        let strongSingles = results.filter { $0.score >= 90 }.count
        if strongSingles < 3 {
            for i in 0..<enzymes.count {
                for j in (i + 1)..<enzymes.count {
                    let e1 = enzymes[i]; let e2 = enzymes[j]
                    let cCuts = (cCutsByEnz[e1.name] ?? []) + (cCutsByEnz[e2.name] ?? [])
                    let vCuts = (vCutsByEnz[e1.name] ?? []) + (vCutsByEnz[e2.name] ?? [])
                    let cBands = digestFragments(seqLen: cLen, isCircular: cCirc, cutPositions: cCuts)
                    let vBands = digestFragments(seqLen: vLen, isCircular: vCirc, cutPositions: vCuts)
                    if let strat = scoreFlanking(
                        enzymes: [e1.name, e2.name], mode: .doubleFlanking,
                        recombinantBands: cBands, parentalBands: vBands,
                        insertSize: insertSize) {
                        results.append(strat)
                    }
                }
            }
        }
        
        // De-duplicate near-identical patterns: keep the highest-scoring per
        // unique band signature.
        let unique = deduplicate(results)
        return Array(unique.sorted { $0.score > $1.score }.prefix(maxResults))
    }
    
    private func scoreFlanking(
        enzymes: [String], mode: VerificationStrategy.Mode,
        recombinantBands: [Int], parentalBands: [Int], insertSize: Int
    ) -> VerificationStrategy? {
        // Bands present in recombinant but absent (within tolerance) from parental
        let unique = recombinantBands.filter { rBand in
            !parentalBands.contains { abs($0 - rBand) <= tol(rBand) }
        }
        if unique.isEmpty { return nil }
        
        // At least one diagnostic band must be in resolvable range
        let resolvable = unique.filter { $0 >= minResolvableBp && $0 <= maxResolvableBp }
        if resolvable.isEmpty { return nil }
        
        // ── Score components ──
        let modeBonus       = (mode == .singleFlanking) ? 30 : 0
        let bandCountPenalty = max(0, recombinantBands.count - 4) * 5
        let separation      = minNeighbourDistance(target: resolvable[0], in: recombinantBands)
        let separationBonus = min(20, separation / 50)
        // Reward "clean fragment release" — diagnostic band ~ insert size
        let releaseBonus = resolvable.contains(where: { abs($0 - insertSize) < insertSize / 4 + 200 }) ? 25 : 0
        // Prefer few total bands
        let tooManyPenalty = recombinantBands.count > 6 ? 15 : 0
        
        let score = 50 + modeBonus + separationBonus + releaseBonus - bandCountPenalty - tooManyPenalty
        
        let rationale: String
        if mode == .singleFlanking {
            rationale = "\(enzymes[0]) gives a band pattern that differs from the empty vector. The diagnostic band(s) confirm insert presence."
        } else {
            rationale = "\(enzymes[0]) + \(enzymes[1]) double digest releases a fragment whose size is unique to the recombinant clone."
        }
        
        return VerificationStrategy(
            mode: mode, enzymeNames: enzymes,
            recombinantBands: recombinantBands, comparisonBands: parentalBands,
            diagnosticBands: resolvable, rationale: rationale, score: score)
    }
    
    
    // MARK: Orientation analysis
    
    private func analyseOrientation(
        construct: DNASequence,
        insertStart: Int,
        insertEnd: Int,
        enzymes: [RestrictionEnzyme]
    ) -> [VerificationStrategy] {
        let cSeq = construct.sequence
        let cLen = cSeq.count
        let cCirc = construct.isCircular
        let insertLen = insertEnd - insertStart
        guard insertLen > 0, insertEnd <= cLen else { return [] }
        
        // Build the "reversed-insertion" sequence: same backbone, insert RC'd.
        let prefix = String(cSeq.prefix(insertStart))
        let insertSeq = String(cSeq[
            cSeq.index(cSeq.startIndex, offsetBy: insertStart)
            ..<
            cSeq.index(cSeq.startIndex, offsetBy: insertEnd)
        ])
        let suffix = String(cSeq.suffix(cLen - insertEnd))
        let reverseConstruct = prefix + reverseComplement(insertSeq) + suffix
        
        var results: [VerificationStrategy] = []
        
        for enz in enzymes {
            let fwdCuts = enz.findCutSites(in: cSeq, circular: cCirc).map { $0.cutPosition5Prime }
            // Need at least one cut INSIDE the insert and one OUTSIDE
            let internalCuts = fwdCuts.filter { $0 >= insertStart && $0 < insertEnd }
            let externalCuts = fwdCuts.filter { !($0 >= insertStart && $0 < insertEnd) }
            if internalCuts.isEmpty || externalCuts.isEmpty { continue }
            
            // Asymmetry test — at least one internal cut must not sit at the midpoint
            let mid = insertStart + insertLen / 2
            let midTolerance = max(20, insertLen / 20)
            let asymmetric = internalCuts.contains { abs($0 - mid) > midTolerance }
            if !asymmetric { continue }
            
            let revCuts = enz.findCutSites(in: reverseConstruct, circular: cCirc).map { $0.cutPosition5Prime }
            let fwdBands = digestFragments(seqLen: cLen, isCircular: cCirc, cutPositions: fwdCuts)
            let revBands = digestFragments(seqLen: cLen, isCircular: cCirc, cutPositions: revCuts)
            
            // Patterns must actually differ
            let diff = patternDifference(fwdBands, revBands)
            if diff < 100 { continue }
            
            // Bands that distinguish the two patterns
            let distinguishing = fwdBands.filter { fb in
                !revBands.contains { abs($0 - fb) <= tol(fb) }
            }
            // At least one distinguishing band must be resolvable
            if !distinguishing.contains(where: { $0 >= minResolvableBp && $0 <= maxResolvableBp }) {
                continue
            }
            
            // Score: more asymmetric internal cut = better; more pattern diff = better
            let bestCut = internalCuts.max(by: { abs($0 - mid) < abs($1 - mid) }) ?? mid
            let asymPct = Double(abs(bestCut - mid)) / Double(max(1, insertLen / 2))
            let asymBonus = Int(asymPct * 30)
            let diffBonus = min(40, diff / 50)
            let bandCountPenalty = max(0, fwdBands.count - 5) * 5
            let internalCountBonus = (internalCuts.count == 1) ? 10 : 0
            
            let score = 50 + asymBonus + diffBonus + internalCountBonus - bandCountPenalty
            
            let rationale = "\(enz.name) cuts asymmetrically inside the insert and also cuts the vector backbone. Forward and reverse insertions give distinguishable band patterns on a gel."
            
            results.append(VerificationStrategy(
                mode: .orientation, enzymeNames: [enz.name],
                recombinantBands: fwdBands, comparisonBands: revBands,
                diagnosticBands: distinguishing, rationale: rationale, score: score))
        }
        
        let unique = deduplicate(results)
        return Array(unique.sorted { $0.score > $1.score }.prefix(maxResults))
    }
    
    
    // MARK: Helpers
    
    private func tol(_ band: Int) -> Int {
        max(bandToleranceBp, Int(Double(band) * bandTolerancePct))
    }
    
    private func digestFragments(seqLen: Int, isCircular: Bool, cutPositions: [Int]) -> [Int] {
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
    
    private func minNeighbourDistance(target: Int, in bands: [Int]) -> Int {
        let others = bands.filter { $0 != target }
        if others.isEmpty { return target }
        return others.map { abs($0 - target) }.min() ?? 0
    }
    
    private func patternDifference(_ a: [Int], _ b: [Int]) -> Int {
        let aSort = a.sorted(); let bSort = b.sorted()
        let n = min(aSort.count, bSort.count)
        var diff = 0
        for i in 0..<n { diff += abs(aSort[i] - bSort[i]) }
        diff += (max(aSort.count, bSort.count) - n) * 1000  // missing band = large diff
        return diff
    }
    
    private func reverseComplement(_ s: String) -> String {
        let comp: [Character: Character] = [
            "A": "T", "T": "A", "G": "C", "C": "G", "N": "N",
            "a": "t", "t": "a", "g": "c", "c": "g", "n": "n"
        ]
        return String(s.reversed().map { comp[$0] ?? $0 })
    }
    
    private func deduplicate(_ strategies: [VerificationStrategy]) -> [VerificationStrategy] {
        // Two strategies are duplicates if their recombinant band signatures
        // (rounded to 50 bp) are identical.  Keep the highest score per signature.
        var bestByKey: [String: VerificationStrategy] = [:]
        for s in strategies {
            let key = s.recombinantBands.map { String($0 / 50) }.joined(separator: ",")
            if let existing = bestByKey[key], existing.score >= s.score { continue }
            bestByKey[key] = s
        }
        return Array(bestByKey.values)
    }
    
    private func formatBands(_ bands: [Int]) -> String {
        if bands.isEmpty { return "—" }
        return bands.map { formatBp($0) }.joined(separator: ", ")
    }
    
    private func formatBp(_ bp: Int) -> String {
        if bp >= 1000 {
            return String(format: "%.2f kb", Double(bp) / 1000.0)
        }
        return "\(bp) bp"
    }
    
    /// Word-wrap a string at `width` characters, indenting continuation lines.
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

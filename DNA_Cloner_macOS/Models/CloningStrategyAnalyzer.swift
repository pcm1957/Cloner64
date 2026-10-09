import Foundation

// MARK: - Cloning Mode

enum CloningMode {
    case simpleInsertion
    case fusionNTerminal
    case fusionCTerminal
    case fusionBoth
}

struct JunctionFrame {
    let vectorOffset: Int
    let insertOffset: Int
}

// MARK: - Insert Region

struct InsertRegion {
    let start: Int      // 0-based start within the source sequence
    let end: Int        // 0-based end (inclusive). For wrapping regions on circular
                        // sources, start > end (e.g. start=5826, end=1 on a 6307bp plasmid)
    let name: String
    
    /// True if the region wraps the origin (start > end), only valid for circular sources
    var wrapsOrigin: Bool { start > end }
    
    var length: Int {
        if start <= end { return end - start + 1 }
        // Wrapping is handled by extractSequence which needs sourceLength
        return 0  // caller should use lengthInSource(_:) instead
    }
    
    /// Length of the insert on a source of the given length (handles wrapping)
    func lengthInSource(_ sourceLength: Int) -> Int {
        if start <= end { return end - start + 1 }
        return (sourceLength - start) + (end + 1)
    }
    
    func extractSequence(from source: String, circular: Bool = false) -> String {
        let src = source.uppercased()
        if start <= end {
            guard start >= 0, end < src.count, start <= end else { return src }
            let s = src.index(src.startIndex, offsetBy: start)
            let e = src.index(src.startIndex, offsetBy: end + 1)
            return String(src[s..<e])
        } else if circular {
            // Wrapping region: from start to end of sequence + from 0 to end
            guard start < src.count, end < src.count else { return src }
            let part1 = String(src[src.index(src.startIndex, offsetBy: start)...])
            let part2 = String(src[...src.index(src.startIndex, offsetBy: end)])
            return part1 + part2
        }
        return src
    }
}

// MARK: - Cloning Path

enum CloningPath {
    /// Both enzymes have flanking sites — digest both vector and source/insert directly
    case directDigest
    /// Insert is already a blunt-ended fragment — only cut the vector with a blunt cutter
    case bluntInsertDirect
    /// 5' enzyme has a flanking site but 3' does not — reverse primer needs RE site tail
    case onePrimerReverse
    /// 3' enzyme has a flanking site but 5' does not — forward primer needs RE site tail
    case onePrimerForward
    /// Neither enzyme has flanking sites — both primers need RE site tails
    case pcrRequired
    /// Insert released by its own (sticky) enzymes, then made blunt by fill-in
    /// or nibble-back, and ligated into a blunt vector cut. Non-directional.
    case bluntedInsert
    
    var isDirectDigest: Bool {
        switch self {
        case .directDigest, .bluntInsertDirect, .bluntedInsert: return true
        default: return false
        }
    }
    
    var needsPrimers: Bool {
        switch self {
        case .directDigest, .bluntInsertDirect, .bluntedInsert: return false
        default: return true
        }
    }
    
    var label: String {
        switch self {
        case .directDigest: return "Direct digest"
        case .bluntInsertDirect: return "Blunt insert (no digest)"
        case .bluntedInsert: return "Blunt via fill-in / nibble"
        case .onePrimerForward: return "PCR — add 5' site"
        case .onePrimerReverse: return "PCR — add 3' site"
        case .pcrRequired: return "PCR — add both sites"
        }
    }
    
    var badgeColor: String {
        switch self {
        case .directDigest: return "green"
        case .bluntInsertDirect: return "green"
        case .bluntedInsert: return "teal"
        case .onePrimerForward, .onePrimerReverse: return "teal"
        case .pcrRequired: return "blue"
        }
    }
}

/// How a sticky end is converted to a blunt end before a blunt ligation.
enum BluntingMethod: String {
    /// Klenow fragment + dNTPs: fills in a 5' overhang. KEEPS the overhang bases.
    case fillIn = "fill-in"
    /// Mung bean / S1 nuclease: removes a single-stranded overhang. DROPS the bases.
    case nibble = "nibble"
    
    var label: String { rawValue }
    
    /// Only fill-in is valid on a 5' overhang; 3' overhangs can only be removed.
    var enzymeDescription: String {
        switch self {
        case .fillIn: return "fill in 5' overhang with Klenow + dNTPs"
        case .nibble: return "remove overhang with mung bean nuclease"
        }
    }
}

// MARK: - Partial Digest Side

enum PartialDigestSide: String {
    case none
    case vector = "Vector"       // vector enzyme requires partial digest (2 sites, cut only 1)
    case insert = "Insert"       // insert/source enzyme requires partial digest
    
    var label: String {
        switch self {
        case .none:   return ""
        case .vector: return "Partial digest (vector)"
        case .insert: return "Partial digest (insert)"
        }
    }
    
    var badgeColor: String { "orange" }
}

// MARK: - Frame Analysis

struct FrameAnalysis {
    let fiveprimeInFrame: Bool?
    let threeprimeInFrame: Bool?
    
    /// If non-nil, the analyzer auto-aligned the 5' junction vectorOffset to
    /// this value to keep the reading frame continuous with the upstream
    /// fusion feature. Callers surface this in a per-strategy warning.
    let fiveprimeAutoOffset: Int?
    
    /// If non-nil, the analyzer auto-aligned the 3' junction vectorOffset
    /// (e.g. for C-terminal fusion to GFP through NcoI in pCambia).
    let threeprimeAutoOffset: Int?
    
    init(fiveprimeInFrame: Bool?,
         threeprimeInFrame: Bool?,
         fiveprimeAutoOffset: Int? = nil,
         threeprimeAutoOffset: Int? = nil) {
        self.fiveprimeInFrame = fiveprimeInFrame
        self.threeprimeInFrame = threeprimeInFrame
        self.fiveprimeAutoOffset = fiveprimeAutoOffset
        self.threeprimeAutoOffset = threeprimeAutoOffset
    }
    
    var allInFrame: Bool {
        (fiveprimeInFrame ?? true) && (threeprimeInFrame ?? true)
    }
    
    /// Badge text. Deliberately says "junction", not "insert" or "vector":
    /// being in frame is a property of the JOIN between the two, not of
    /// either sequence on its own. Users read "Out-of-frame (5')" as
    /// "my insert is wrong", which it is not.
    var label: String? {
        switch (fiveprimeInFrame, threeprimeInFrame) {
        case (.some(true), .some(true)):   return "Both junctions in frame"
        case (.some(true), nil):           return "5' junction in frame"
        case (nil, .some(true)):           return "3' junction in frame"
        case (.some(true), .some(false)):  return "5' junction in frame · 3' junction out of frame"
        case (.some(false), .some(true)):  return "5' junction out of frame · 3' junction in frame"
        case (.some(false), .some(false)): return "Both junctions out of frame"
        case (.some(false), nil):          return "5' junction out of frame"
        case (nil, .some(false)):          return "3' junction out of frame"
        case (nil, nil):                   return nil
        }
    }

    /// Tooltip spelling out what the badge means in plain language.
    var tooltip: String? {
        guard label != nil else { return nil }
        let five  = "The 5' junction is where the N-terminal tag in the vector meets the start of your insert."
        let three = "The 3' junction is where the end of your insert meets the C-terminal tag in the vector."
        let ok    = "The codons run straight through, so the tag and your insert are read as one protein."
        let bad   = "The codons do not line up across the join, so the tag and your insert would be read in different frames. Neither sequence is wrong in itself — it is the join that does not fit. A different enzyme, or a PCR strategy where 1 or 2 extra bases can be added in the primer, will usually fix it."
        switch (fiveprimeInFrame, threeprimeInFrame) {
        case (.some(true), nil):           return five + " " + ok
        case (nil, .some(true)):           return three + " " + ok
        case (.some(true), .some(true)):   return five + " " + three + " " + ok
        case (.some(false), nil):          return five + " " + bad
        case (nil, .some(false)):          return three + " " + bad
        case (.some(false), .some(false)): return five + " " + three + " " + bad
        case (.some(true), .some(false)):  return three + " " + bad
        case (.some(false), .some(true)):  return five + " " + bad
        case (nil, nil):                   return nil
        }
    }
}

// MARK: - Cloning Strategy

struct CloningStrategy: Identifiable {
    let id = UUID()
    let enzyme5: RestrictionEnzyme              // enzyme used on the VECTOR 5' side
    let enzyme3: RestrictionEnzyme?             // enzyme used on the VECTOR 3' side
    var isDirectional: Bool { enzyme3 != nil && enzyme3!.name != enzyme5.name }
    let insertEnzyme5: RestrictionEnzyme?       // if different from enzyme5, the compatible enzyme on the INSERT 5' side
    let insertEnzyme3: RestrictionEnzyme?       // if different from enzyme3, the compatible enzyme on the INSERT 3' side
    let internalCutters: [String]
    let frameAnalysis: FrameAnalysis?
    var warnings: [String]
    var score: Int
    /// Length in amino acids of the fusion protein this strategy would give,
    /// counted from the tag's start codon to the first stop. nil when it could
    /// not be worked out with confidence (no tag, no start codon found, or the
    /// tag falls in the piece of vector being removed) — a wrong number here
    /// would be worse than none.
    var predictedFusionAA: Int? = nil
    let vectorSite5Position: Int
    let vectorSite3Position: Int
    let insertReversed: Bool
    let cloningPath: CloningPath
    let backboneSize: Int       // backbone fragment kept after vector digest
    let excisedSize: Int        // stuffer fragment removed (0 for single-enzyme)
    let insertSize: Int         // insert fragment size
    // Actual insert cut positions in SOURCE coordinates, as chosen by this
    // analyzer when releasing the insert (nil for PCR / blunt-fragment paths).
    // Recorded so the frame validator can use the SAME cut the builder uses
    // instead of re-deriving it (the cause of the earlier out-of-frame bug).
    var insertCut5Source: Int? = nil
    var insertCut3Source: Int? = nil
    // Excerpt-local cut positions: position within the excerpt sequence where the
    // insert is actually cut (= insertCut5Source - insertRegion.start).
    // Used by buildConstruct to trim the insert correctly at the ligation point.
    var insertCut5Excerpt: Int? = nil
    var insertCut3Excerpt: Int? = nil
    // Fusion insert-truncation: forward-excerpt position of the insert cut SITE
    // when this strategy deliberately trims a few N- or C-terminal insert codons
    // to reach an in-frame junction. nil for ordinary (non-truncating) strategies.
    // The View's fusion frame-filter uses these to validate the junction on the
    // truncating cut instead of the outermost clean flank.
    var insertTruncCut5: Int? = nil   // N-terminal trim (5') — forward-excerpt site pos
    var insertTruncCut3: Int? = nil   // C-terminal trim (3') — forward-excerpt site pos
    let partialDigest: PartialDigestSide   // whether a partial digest is needed
    // Blunt-mediated (.bluntedInsert) strategies only: how each insert end is
    // made blunt before ligation. nil = that end is left untouched (already
    // blunt, or this isn't a blunted strategy). For .bluntedInsert paths,
    // insertCut5Source / insertCut3Source hold the FORWARD source-coordinate
    // fragment boundaries AFTER blunting (fill-in keeps overhang bases, nibble
    // drops them), so the builder can extract the exact blunted fragment.
    var insert5Blunting: BluntingMethod? = nil
    var insert3Blunting: BluntingMethod? = nil
    
    /// True if the insert uses a different (compatible-end) enzyme on either side
    var usesCompatibleEnds: Bool {
        insertEnzyme5 != nil || insertEnzyme3 != nil
    }
    
    /// The enzyme that actually cuts the insert on the 5' side
    var effectiveInsertEnzyme5: RestrictionEnzyme { insertEnzyme5 ?? enzyme5 }
    /// The enzyme that actually cuts the insert on the 3' side
    var effectiveInsertEnzyme3: RestrictionEnzyme { insertEnzyme3 ?? (enzyme3 ?? enzyme5) }
}

// MARK: - Analyzer

class CloningStrategyAnalyzer {
    
    /// Default flank tolerance (bp).  Overridden per-call via the
    /// `flankTolerance` parameter of `analyzeStrategies` — e.g. ORF
    /// inserts pass a larger value so cutting a short way into the
    /// ORF edge is accepted while the coding core stays protected.
    static let defaultFlankTolerance = 20
    
    /// Diagnostic log populated by `analyzeStrategies`. Cleared at the start
    /// of each run. When no strategies come back, the UI can display this to
    /// show the user exactly which filter stage dropped all candidates.
    var lastDiagnostic: [String] = []

    // =========================================================================
    // MARK: Analyze strategies
    // =========================================================================
    
    func analyzeStrategies(
        vectorSequence: String,
        sourceSequence: String,
        insertRegion: InsertRegion,
        cloningRegionRange: ClosedRange<Int>? = nil,
        protectedRegions: [ClosedRange<Int>] = [],
        vectorIsCircular: Bool = true,
        sourceIsCircular: Bool = false,
        enzymes: [RestrictionEnzyme],
        cloningMode: CloningMode = .simpleInsertion,
        fiveprimeFrame: JunctionFrame? = nil,
        threeprimeFrame: JunctionFrame? = nil,
        insertReversed: Bool = false,
        insertIsBluntFragment: Bool = false,
        vectorFeatures: [Feature] = [],
        autoAlign5Prime: Bool = false,
        autoAlign3Prime: Bool = false,
        flankTolerance: Int = CloningStrategyAnalyzer.defaultFlankTolerance,
        sourceORFRanges: [(start: Int, end: Int)] = [],
        coreInsertLength: Int? = nil,
        methylation: MethylationContext = .none,
        // Fusion insert-truncation search (optional; only the fusion path passes
        // these). Forward-excerpt 0-based coordinates of the insert ORF's coding
        // start and last coding base, in the SAME coordinate system as insertSeq
        // (which is always the forward excerpt). nil for every other caller, in
        // which case the truncation search below is skipped entirely.
        insertORFForwardStart: Int? = nil,
        insertORFForwardEnd: Int? = nil
    ) -> [CloningStrategy] {
        
        let vectorSeq = vectorSequence.uppercased()
        let sourceSeq = sourceSequence.uppercased()
        let insertSeq = insertRegion.extractSequence(from: sourceSeq, circular: sourceIsCircular)
        let insertLen = insertSeq.count

        // MARK: Type IIS enzymes are not usable by this analyzer
        //
        // Every strategy built here rests on knowing an enzyme's overhang in
        // advance, so it can decide whether two cut ends will ligate. A Type IIS
        // enzyme (BsaI, BsmBI, BbsI, SapI …) cuts a fixed distance OUTSIDE its
        // recognition site, so its overhang is whatever sequence happens to sit
        // at the cut — a property of the target, not of the enzyme. "Will these
        // ends ligate?" therefore has no answer in the abstract, which is why
        // RestrictionEnzyme.producesEndsCompatible(with:) already refuses to
        // pair them.
        //
        // The paths this analyzer models (direct digest, blunt ligation, PCR
        // with restriction tails) are all digest-and-ligate. Golden Gate
        // assembly — where these enzymes belong, and where the sequence-derived
        // overhang is the whole point — would need its own path with overhangs
        // read from the target. Until that exists, offering Type IIS strategies
        // here would mean presenting confident advice the model cannot support.
        //
        // Shadowing the parameter keeps every use below unchanged.
        let excludedTypeIIS = enzymes.filter { $0.cutsOutsideSite }.map(\.name)
        let enzymes = enzymes.filter { !$0.cutsOutsideSite }

        // Reset diagnostic log for this run.
        lastDiagnostic = []
        if !excludedTypeIIS.isEmpty {
            lastDiagnostic.append("Excluded \(excludedTypeIIS.count) Type IIS enzyme(s) — they cut outside their recognition site, so their overhang depends on the target sequence and cannot be matched: \(excludedTypeIIS.sorted().joined(separator: ", "))")
        }
        lastDiagnostic.append("Vector length: \(vectorSeq.count) bp, circular: \(vectorIsCircular)")
        if let r = cloningRegionRange {
            if r.upperBound >= vectorSeq.count {
                lastDiagnostic.append("Cloning region: \(r.lowerBound + 1)–\(vectorSeq.count), 1–\(r.upperBound - vectorSeq.count + 1) (\(r.count) bp, wraps origin)")
            } else {
                lastDiagnostic.append("Cloning region: \(r.lowerBound + 1)–\(r.upperBound + 1) (\(r.count) bp)")
            }
        } else {
            lastDiagnostic.append("Cloning region: entire vector (no region constraint)")
        }
        lastDiagnostic.append("Protected ranges: \(protectedRegions.count)")
        lastDiagnostic.append("Cloning mode: \(cloningMode)")
        lastDiagnostic.append("Enzymes available: \(enzymes.count)")
        lastDiagnostic.append("Flank tolerance: \(flankTolerance) bp")
        
        // --- Source ORF avoidance helper ---
        // Returns true if the given source-coordinate position falls within
        // one of the other ORFs on the source (NOT the insert ORF itself).
        // Used to penalise flanking sites that would destroy a neighbouring ORF.
        func sourcePositionInOtherORF(_ pos: Int) -> Bool {
            for orf in sourceORFRanges {
                if orf.start <= orf.end {
                    if pos >= orf.start && pos <= orf.end { return true }
                } else {
                    // wrapping ORF
                    if pos >= orf.start || pos <= orf.end { return true }
                }
            }
            return false
        }
        
        /// Score penalty when a flanking cut site falls within another ORF
        /// on the source. Checks both the 5' and 3' flanking positions.
        func orfAvoidancePenalty(enz5Name: String, enz3Name: String) -> Int {
            guard !sourceORFRanges.isEmpty else { return 0 }
            var penalty = 0
            if let pos = flank5SourcePosition(enz5Name), sourcePositionInOtherORF(pos) { penalty += 8 }
            if let pos = flank3SourcePosition(enz3Name), sourcePositionInOtherORF(pos) { penalty += 8 }
            return penalty
        }
        
        /// Penalty for excess flanking sequence around the core ORF / feature.
        /// Prefers compact inserts where the cut sites sit close to the target
        /// boundaries.  –1 pt per 100 bp of excess, capped at –10.
        func excessFlankPenalty(realInsertSize: Int) -> Int {
            guard let core = coreInsertLength, core > 0 else { return 0 }
            let excess = max(0, realInsertSize - core)
            return min(excess / 100, 10)
        }
        
        if let core = coreInsertLength {
            lastDiagnostic.append("Core insert (ORF/feature): \(core) bp  (padded region: \(insertLen) bp)")
        }
        
        // --- Scan vector ---
        var vectorSitesByEnzyme: [String: [CutSite]] = [:]
        for enzyme in enzymes {
            let sites = enzyme.findCutSites(in: vectorSeq, circular: vectorIsCircular)
            if !sites.isEmpty { vectorSitesByEnzyme[enzyme.name] = sites }
        }
        
        // --- Scan source for flanking sites outside the insert ---
        var sourceSitesByEnzyme: [String: [CutSite]] = [:]
        for enzyme in enzymes {
            let sites = enzyme.findCutSites(in: sourceSeq, circular: sourceIsCircular)
            if !sites.isEmpty { sourceSitesByEnzyme[enzyme.name] = sites }
        }
        
        // --- Scan the insert itself ---
        var insertSitesByEnzyme: [String: [CutSite]] = [:]
        for enzyme in enzymes {
            let sites = enzyme.findCutSites(in: insertSeq, circular: false)
            if !sites.isEmpty { insertSitesByEnzyme[enzyme.name] = sites }
        }
        
        // --- Classify insert sites as 5'-flank, 3'-flank, or truly internal ---
        // A site near the 5' end (position < flankTolerance) is a usable 5' flanking site.
        // A site near the 3' end (position > insertLen - flankTolerance - siteLen) is a usable 3' flanking site.
        // Everything else is truly internal (problematic).
        // Positions are stored so we can compute actual digest fragment sizes.
        
        struct InsertSiteClassification {
            var fivePrimeFlankPos: Int? = nil    // position within insert seq (0-based) nearest to 5' end
            var threePrimeFlankPos: Int? = nil   // position within insert seq nearest to 3' end
            var trulyInternal: Bool = false      // enzyme cuts in the middle of the insert

            // --- Fusion insert-truncation candidates (forward-excerpt coords) ---
            // A site that sits a few codons INTO the insert ORF, used only as a
            // fallback when no clean flank exists at that junction. Stored
            // separately so existing (clean) strategy generation is untouched.
            // fivePrimeTruncFlankPos: nearest in-budget site at/after the ORF
            //   start (minimal N-terminal truncation).
            // threePrimeTruncFlankPos: nearest in-budget site at/before the ORF
            //   end (minimal C-terminal truncation).
            var fivePrimeTruncFlankPos: Int? = nil
            var threePrimeTruncFlankPos: Int? = nil

            var fivePrimeFlank: Bool { fivePrimeFlankPos != nil }
            var threePrimeFlank: Bool { threePrimeFlankPos != nil }
        }
        
        var insertClassification: [String: InsertSiteClassification] = [:]

        // Fusion insert-truncation search is active only in a fusion cloning mode
        // AND when the caller supplied the ORF coordinates. maxInsertTruncBP caps
        // how far into the ORF a fallback cut may land (≈10 codons).
        let isFusionMode: Bool = {
            switch cloningMode {
            case .fusionNTerminal, .fusionCTerminal, .fusionBoth: return true
            default: return false
            }
        }()
        let maxInsertTruncBP = 30
        let truncSearchActive = isFusionMode
            && insertORFForwardStart != nil
            && insertORFForwardEnd != nil

        for (name, sites) in insertSitesByEnzyme {
            var classification = InsertSiteClassification()
            let enzyme = enzymes.first { $0.name == name }
            let siteLen = enzyme?.recognitionSite.count ?? 6
            
            for site in sites {
                let pos = site.position
                if pos < flankTolerance {
                    // Keep the one nearest to position 0 (outermost 5' site)
                    if classification.fivePrimeFlankPos == nil || pos < classification.fivePrimeFlankPos! {
                        classification.fivePrimeFlankPos = pos
                    }
                } else if pos > insertLen - flankTolerance - siteLen {
                    // Keep the one nearest to the 3' end (outermost)
                    if classification.threePrimeFlankPos == nil || pos > classification.threePrimeFlankPos! {
                        classification.threePrimeFlankPos = pos
                    }
                } else {
                    classification.trulyInternal = true
                }
            }

            // --- Fusion insert-truncation search (fallback candidates) ---
            // Independent of the clean classification above: a site that lands a
            // few codons INTO the ORF is "truly internal" in the clean scheme but
            // may serve as a fallback fusion cut that trims a few residues. We
            // record the site nearest each ORF coding boundary (minimal trim),
            // within maxInsertTruncBP. Frame is NOT checked here — the View's
            // joint-frame filter is the authoritative gatekeeper and rejects any
            // out-of-frame candidate; this pass only surfaces them.
            if truncSearchActive,
               let orfFwdStart = insertORFForwardStart,
               let orfFwdEnd = insertORFForwardEnd {
                for site in sites {
                    let pos = site.position
                    // 5' (N-terminal) trim window: at/after the ORF start, within budget.
                    if pos >= orfFwdStart && pos <= orfFwdStart + maxInsertTruncBP {
                        if classification.fivePrimeTruncFlankPos == nil
                            || pos < classification.fivePrimeTruncFlankPos! {
                            classification.fivePrimeTruncFlankPos = pos
                        }
                    }
                    // 3' (C-terminal) trim window: at/before the ORF coding end, within budget.
                    if pos <= orfFwdEnd && pos >= orfFwdEnd - maxInsertTruncBP {
                        if classification.threePrimeTruncFlankPos == nil
                            || pos > classification.threePrimeTruncFlankPos! {
                            classification.threePrimeTruncFlankPos = pos
                        }
                    }
                }
            }
            insertClassification[name] = classification
        }

        // --- Also check source sequence for flanking sites OUTSIDE the insert region ---
        // Store the nearest site position on each side so we can compute real fragment sizes.
        // For circular sources, sites can flank by wrapping around the origin.
        struct SourceFlankInfo {
            var nearestUpstreamPos: Int? = nil    // source-coord of nearest 5' flanking site
            var nearestDownstreamPos: Int? = nil  // source-coord of nearest 3' flanking site
            
            var hasUpstreamSite: Bool { nearestUpstreamPos != nil }
            var hasDownstreamSite: Bool { nearestDownstreamPos != nil }
        }
        
        let srcLen = sourceSeq.count
        
        /// Classify whether a site at position P is inside, upstream, or downstream
        /// of the insert region, handling circular topology.
        func classifySitePosition(_ pos: Int) -> (isInside: Bool, isUpstream: Bool, isDownstream: Bool) {
            if !insertRegion.wrapsOrigin {
                // Non-wrapping insert: inside = start..end
                if pos >= insertRegion.start && pos <= insertRegion.end {
                    return (true, false, false)
                }
                if sourceIsCircular {
                    // On a circle, upstream = shortest path backwards to start,
                    // downstream = shortest path forwards from end
                    let distToStart: Int
                    let distFromEnd: Int
                    if pos < insertRegion.start {
                        distToStart = insertRegion.start - pos
                        distFromEnd = srcLen - insertRegion.end + pos
                    } else {
                        // pos > insertRegion.end
                        distToStart = srcLen - pos + insertRegion.start
                        distFromEnd = pos - insertRegion.end
                    }
                    return (false, distToStart <= distFromEnd, distToStart > distFromEnd)
                } else {
                    // Linear: simple comparison
                    return (false, pos < insertRegion.start, pos > insertRegion.end)
                }
            } else {
                // Wrapping insert (start > end): inside = pos >= start OR pos <= end
                if pos >= insertRegion.start || pos <= insertRegion.end {
                    return (true, false, false)
                }
                // Outside region is end+1 .. start-1
                // Upstream = closest to start (from below), downstream = closest to end (from above)
                let distToStart = insertRegion.start - pos
                let distFromEnd = pos - insertRegion.end
                return (false, distToStart <= distFromEnd, distToStart > distFromEnd)
            }
        }
        
        var sourceFlank: [String: SourceFlankInfo] = [:]
        for (name, sites) in sourceSitesByEnzyme {
            var info = SourceFlankInfo()
            for site in sites {
                let (isInside, isUp, isDown) = classifySitePosition(site.position)
                if isInside { continue }
                
                if isUp {
                    // Keep the one closest to the insert start
                    if let current = info.nearestUpstreamPos {
                        let curDist: Int
                        let newDist: Int
                        if sourceIsCircular {
                            curDist = (insertRegion.start - current + srcLen) % srcLen
                            newDist = (insertRegion.start - site.position + srcLen) % srcLen
                        } else {
                            curDist = insertRegion.start - current
                            newDist = insertRegion.start - site.position
                        }
                        if newDist < curDist { info.nearestUpstreamPos = site.position }
                    } else {
                        info.nearestUpstreamPos = site.position
                    }
                }
                if isDown {
                    // Keep the one closest to the insert end
                    if let current = info.nearestDownstreamPos {
                        let curDist: Int
                        let newDist: Int
                        if sourceIsCircular {
                            let effEnd = insertRegion.wrapsOrigin ? insertRegion.end : insertRegion.end
                            curDist = (current - effEnd + srcLen) % srcLen
                            newDist = (site.position - effEnd + srcLen) % srcLen
                        } else {
                            curDist = current - insertRegion.end
                            newDist = site.position - insertRegion.end
                        }
                        if newDist < curDist { info.nearestDownstreamPos = site.position }
                    } else {
                        info.nearestDownstreamPos = site.position
                    }
                }
            }
            sourceFlank[name] = info
        }
        
        // --- When the insert will be reverse-complemented, swap 5'/3' ---
        // The analyzer scans the forward-strand insert for sites. When the
        // insert is reversed before ligation, what was the 5' flanking end
        // becomes the 3' end in the final construct and vice versa. Swapping
        // now means all downstream logic (has5PrimeFlank, compatible*Flank,
        // hasConflictingInsertSites, flank*SourcePosition) automatically
        // refers to the correct side as it appears in the construct.
        if insertReversed {
            for (name, var cls) in insertClassification {
                let tmp = cls.fivePrimeFlankPos
                cls.fivePrimeFlankPos = cls.threePrimeFlankPos
                cls.threePrimeFlankPos = tmp
                insertClassification[name] = cls
            }
            for (name, var info) in sourceFlank {
                let tmp = info.nearestUpstreamPos
                info.nearestUpstreamPos = info.nearestDownstreamPos
                info.nearestDownstreamPos = tmp
                sourceFlank[name] = info
            }
        }
        
        // --- Build compatible-enzyme lookup ---
        // For each enzyme, find all other enzymes that produce the same overhang
        // (same type + same sequence). E.g. NheI ↔ XbaI, SpeI, AvrII (all 5'-CTAG).
        let enzymeMap = Dictionary(uniqueKeysWithValues: enzymes.map { ($0.name, $0) })
        
        var compatibleEnzymeNames: [String: [String]] = [:]
        for enzyme in enzymes {
            compatibleEnzymeNames[enzyme.name] = enzymes.compactMap { other in
                guard other.name != enzyme.name else { return nil }
                return endsAreCompatible(enzyme, other) ? other.name : nil
            }
        }
        
        // --- Combined: does an enzyme have a usable 5' flanking site? ---
        func has5PrimeFlank(_ enzymeName: String) -> Bool {
            (insertClassification[enzymeName]?.fivePrimeFlank ?? false) ||
            (sourceFlank[enzymeName]?.hasUpstreamSite ?? false)
        }
        
        func has3PrimeFlank(_ enzymeName: String) -> Bool {
            (insertClassification[enzymeName]?.threePrimeFlank ?? false) ||
            (sourceFlank[enzymeName]?.hasDownstreamSite ?? false)
        }
        
        // --- Compatible-end flanking: find a DIFFERENT enzyme with compatible ends
        //     that flanks the insert on the given side ---
        // Returns the name of the compatible enzyme, or nil if none found.
        // Blunt-blunt pairings are allowed: e.g. DraI (insert) ↔ SmaI (vector)
        // is valid when the other side of a directional pair provides sticky-end
        // specificity.
        func compatible5PrimeFlank(_ vectorEnzymeName: String) -> String? {
            guard let partners = compatibleEnzymeNames[vectorEnzymeName] else { return nil }
            return partners.first(where: { has5PrimeFlank($0) && !hasConflictingInsertSites($0, usedAs5Prime: true) })
        }
        
        func compatible3PrimeFlank(_ vectorEnzymeName: String) -> String? {
            guard let partners = compatibleEnzymeNames[vectorEnzymeName] else { return nil }
            return partners.first(where: { has3PrimeFlank($0) && !hasConflictingInsertSites($0, usedAs5Prime: false) })
        }
        
        // --- True internal cutters (sites in the middle of the insert) ---
        func isTrulyInternal(_ enzymeName: String) -> Bool {
            insertClassification[enzymeName]?.trulyInternal ?? false
        }
        
        // --- Cross-enzyme internal site check for directional pairs ---
        // When enzyme A provides the 5' cut, enzyme B's sites near the insert
        // 5' end (classified as fivePrimeFlank) become internal cutters that
        // would destroy the insert. And vice versa for the 3' side.
        //
        // Returns true if the enzyme has insert sites that conflict with
        // being used on the given side of a directional pair.
        //   usedAs5Prime = true  → enzyme provides the 5' end; check it doesn't
        //                         ALSO have a 3'-flanking site (that would be internal)
        //   usedAs5Prime = false → enzyme provides the 3' end; check it doesn't
        //                         ALSO have a 5'-flanking site (that would be internal)
        func hasConflictingInsertSites(_ enzymeName: String, usedAs5Prime: Bool) -> Bool {
            guard let classification = insertClassification[enzymeName] else { return false }
            if classification.trulyInternal { return true }
            if usedAs5Prime && classification.threePrimeFlank { return true }
            if !usedAs5Prime && classification.fivePrimeFlank { return true }
            return false
        }
        
        // --- Actual flanking site positions in source-sequence coordinates ---
        // Returns the source-coordinate position of the nearest flanking site
        // for the given enzyme on the 5' or 3' side of the insert.
        // Needed to compute the real digest fragment size.
        
        func flank5SourcePosition(_ enzymeName: String) -> Int? {
            // Prefer site within the insert boundary (closer to the insert)
            if let insPos = insertClassification[enzymeName]?.fivePrimeFlankPos {
                // Map insert-local position back to source coordinates
                // For wrapping inserts, this needs modular arithmetic
                return (insertRegion.start + insPos) % srcLen
            }
            // Otherwise use external upstream site
            return sourceFlank[enzymeName]?.nearestUpstreamPos
        }
        
        func flank3SourcePosition(_ enzymeName: String) -> Int? {
            if let insPos = insertClassification[enzymeName]?.threePrimeFlankPos {
                return (insertRegion.start + insPos) % srcLen
            }
            return sourceFlank[enzymeName]?.nearestDownstreamPos
        }
        
        /// Compute the actual fragment size released by digesting the source
        /// with the given 5' and 3' enzymes. Uses cut positions for accuracy.
        /// Returns insertLen as fallback if flanking positions can't be determined
        /// (e.g. PCR strategies where flanking sites don't exist).
        // --- Orientation-aware fragment geometry ---
        //
        // When the insert is reversed before ligation, the 5'/3' flank labels are
        // swapped above but the POSITIONS stay in forward source coordinates. So
        // for a reversed insert the construct's 5' end is the HIGH forward
        // coordinate and its 3' end is the LOW one. Anything that fills in a
        // missing boundary, or measures the distance between two boundaries, has
        // to respect that.
        //
        // Getting this wrong is what produced a 7 bp insert for a reversed
        // fragment: the 5' end used the swapped site position (524, correct)
        // while the missing 3' end fell back to insertRegion.end + 1 (532, the
        // wrong end), leaving the 7 bases beyond the cut instead of the 525
        // before it.
        func missingFragmentBoundary(isFivePrime: Bool) -> Int {
            let low  = insertRegion.start
            let high = insertRegion.end + 1
            if insertReversed { return isFivePrime ? high : low }
            return isFivePrime ? low : high
        }

        func fragmentLength(cut5: Int, cut3: Int) -> Int {
            if insertReversed {
                if cut5 > cut3 { return cut5 - cut3 }
                return sourceIsCircular ? (srcLen - cut3) + cut5 : -1
            } else {
                if cut3 > cut5 { return cut3 - cut5 }
                return sourceIsCircular ? (srcLen - cut5) + cut3 : -1
            }
        }

        func actualFragmentSize(enz5Name: String, enz3Name: String,
                                enz5: RestrictionEnzyme, enz3: RestrictionEnzyme) -> Int {
            guard let pos5 = flank5SourcePosition(enz5Name),
                  let pos3 = flank3SourcePosition(enz3Name) else {
                return insertLen
            }
            let cut5 = pos5 + enz5.cutPosition5Prime
            let cut3 = pos3 + enz3.cutPosition5Prime
            let size = fragmentLength(cut5: cut5, cut3: cut3)
            return size > 0 ? size : insertLen
        }
        
        // --- Filter vector sites to cloning region ---
        //
        // Origin-wrap support: `cloningRegionRange` may be a wrapping range on a
        // circular vector — for example, region 10545...10550 on a 10549 bp plasmid
        // means "positions 10545..10549 plus positions 1..2" (end-beyond-length
        // convention set by PredictiveCloningView.betweenFeaturesRange).
        //
        // A raw `range.contains(pos)` check would miss the wrapped-around positions
        // (0, 1 in the example) because CutSite positions are always in
        // [0, vectorSeq.count − 1]. The helper below tests membership correctly
        // for both normal and wrapping ranges.
        let vLen = vectorSeq.count
        func cloningRegionContains(_ range: ClosedRange<Int>, _ pos: Int) -> Bool {
            if range.upperBound < vLen {
                // Normal, non-wrapping range.
                return range.contains(pos)
            }
            // Wrapping range: pos is in the region if it's either
            //   (a) at or after lowerBound (still before the origin), or
            //   (b) at or below (upperBound − vLen) (after wrapping past the origin).
            return pos >= range.lowerBound || pos <= range.upperBound - vLen
        }
        
        let regionSitesByEnzyme: [String: [CutSite]]
        if let region = cloningRegionRange {
            var filtered: [String: [CutSite]] = [:]
            for (name, sites) in vectorSitesByEnzyme {
                let inRegion = sites.filter { cloningRegionContains(region, $0.position) }
                if !inRegion.isEmpty { filtered[name] = inRegion }
            }
            regionSitesByEnzyme = filtered
        } else {
            regionSitesByEnzyme = vectorSitesByEnzyme
        }
        lastDiagnostic.append("Enzymes cutting vector at all: \(vectorSitesByEnzyme.count)")
        lastDiagnostic.append("Enzymes with ≥1 site in cloning region: \(regionSitesByEnzyme.count)")
        if regionSitesByEnzyme.count <= 15 && !regionSitesByEnzyme.isEmpty {
            let names = regionSitesByEnzyme.keys.sorted().joined(separator: ", ")
            lastDiagnostic.append("  → \(names)")
        }
        
        // --- Exclude enzymes cutting in protected regions ---
        let safeSitesByEnzyme: [String: [CutSite]]
        if !protectedRegions.isEmpty {
            var filtered: [String: [CutSite]] = [:]
            var droppedByProtection: [String] = []
            for (name, sites) in regionSitesByEnzyme {
                let allVectorSites = vectorSitesByEnzyme[name] ?? []
                let cutsProtected = allVectorSites.contains { site in
                    protectedRegions.contains { $0.contains(site.position) }
                }
                if !cutsProtected {
                    filtered[name] = sites
                } else {
                    droppedByProtection.append(name)
                }
            }
            safeSitesByEnzyme = filtered
            lastDiagnostic.append("Enzymes surviving protection filter: \(filtered.count) (dropped \(droppedByProtection.count))")
            if !droppedByProtection.isEmpty && droppedByProtection.count <= 15 {
                lastDiagnostic.append("  dropped: \(droppedByProtection.sorted().joined(separator: ", "))")
            }
        } else {
            safeSitesByEnzyme = regionSitesByEnzyme
            lastDiagnostic.append("Enzymes surviving protection filter: \(safeSitesByEnzyme.count) (no protection)")
        }
        
        // --- Single-cutters in the vector's cloning region ---
        // Also exclude enzymes with multiple total vector sites — these need
        // partial digests and are handled separately in the partial digest section.
        let candidateNames = safeSitesByEnzyme
            .filter { $0.value.count == 1 }
            .filter { (vectorSitesByEnzyme[$0.key]?.count ?? 0) == 1 }
            .keys
            .sorted()
        lastDiagnostic.append("Single-cutter candidates (1 site in region AND 1 site in full vector): \(candidateNames.count)")
        if !candidateNames.isEmpty && candidateNames.count <= 20 {
            lastDiagnostic.append("  → \(candidateNames.joined(separator: ", "))")
        }
        
        // Enzymes in the region but NOT in candidates — report why
        let inRegionButNotCandidate = regionSitesByEnzyme.keys.filter { !candidateNames.contains($0) }.sorted()
        if !inRegionButNotCandidate.isEmpty && inRegionButNotCandidate.count <= 15 {
            var reasons: [String] = []
            for name in inRegionButNotCandidate {
                let totalVec = vectorSitesByEnzyme[name]?.count ?? 0
                let inSafe = safeSitesByEnzyme[name]?.count ?? 0
                if inSafe == 0 {
                    reasons.append("\(name) (dropped by protection)")
                } else if totalVec > 1 {
                    reasons.append("\(name) (\(totalVec)× in full vector)")
                } else {
                    reasons.append("\(name) (other)")
                }
            }
            lastDiagnostic.append("  excluded from candidates: \(reasons.joined(separator: ", "))")
        }
        
        var strategies: [CloningStrategy] = []
        
        // --- Blunt insert strategies (insert is already a blunt-ended fragment) ---
        // Uses regionSitesByEnzyme (NOT safeSitesByEnzyme) because the blunt insert
        // section handles its own MCS/avoid-region warnings — protected regions
        // should not hide blunt options from the user.
        if insertIsBluntFragment {
            let bluntCandidateNames = regionSitesByEnzyme
                .filter { $0.value.count == 1 }
                .keys
                .sorted()
            
            // Identify MCS features on the vector for prioritization
            let mcsKeywords = ["mcs", "multiple cloning site", "polylinker", "cloning site", "linker"]
            let avoidKeywords = ["resistance", "marker", "ampr", "kanr", "cmr", "tetr",
                                 "ampicillin", "kanamycin", "chloramphenicol", "tetracycline",
                                 "bla", "aph", "cat", "npt", "origin", " ori", "promoter",
                                 "terminator", "lacz"]
            
            let mcsFeatures = vectorFeatures.filter { f in
                let lower = f.name.lowercased()
                return mcsKeywords.contains(where: { lower.contains($0) })
            }
            let avoidFeatures = vectorFeatures.filter { f in
                let lower = f.name.lowercased()
                return avoidKeywords.contains(where: { lower.contains($0) })
            }
            
            func siteInMCS(_ pos: Int) -> Bool {
                mcsFeatures.contains { f in
                    let lo = min(f.start, f.end); let hi = max(f.start, f.end)
                    return pos >= lo && pos <= hi
                }
            }
            
            func siteInAvoidRegion(_ pos: Int) -> String? {
                for f in avoidFeatures {
                    let lo = min(f.start, f.end); let hi = max(f.start, f.end)
                    if pos >= lo && pos <= hi { return f.name }
                }
                return nil
            }
            
            let hasMCSFeature = !mcsFeatures.isEmpty
            
            for name in bluntCandidateNames {
                guard let enzyme = enzymeMap[name],
                      let site = regionSitesByEnzyme[name]?.first else { continue }
                
                // Only blunt cutters can accept a blunt insert directly
                guard enzyme.overhangType == .blunt else { continue }
                
                let frame = analyzeFrame(enzyme5: enzyme, enzyme3: enzyme,
                                         mode: cloningMode,
                                         fiveprimeFrame: fiveprimeFrame,
                                         threeprimeFrame: threeprimeFrame,
                                         autoAlign5Prime: autoAlign5Prime, autoAlign3Prime: autoAlign3Prime,
                                         needsPrimers: false)
                
                var warnings: [String] = []
                appendAutoAlignWarnings(&warnings, frame: frame)
                let totalCuts = vectorSitesByEnzyme[name]?.count ?? 0
                if totalCuts > 1 { warnings.append("\(name) cuts \(totalCuts)× in full vector") }
                warnings.append(contentsOf: contextMethylationWarnings(enzyme: enzyme, sitePosition: site.position, sequence: vectorSeq, methylation: methylation))
                warnings.append("Insert used directly as blunt-ended fragment — no insert digestion")
                
                let inMCS = siteInMCS(site.position)
                let avoidRegion = siteInAvoidRegion(site.position)
                
                if inMCS {
                    warnings.append("Site is within MCS")
                }
                if let region = avoidRegion {
                    warnings.append("⚠ Site is within \(region) — may disrupt essential element")
                }
                
                var score = computeScore(isDirectional: false, internalCutters: [],
                                         frameAnalysis: frame, warningCount: warnings.count,
                                         totalVectorCuts5: totalCuts, totalVectorCuts3: nil,
                                         path: .bluntInsertDirect,
                                         enzyme5IsBlunt: true, enzyme3IsBlunt: true)
                
                // Prioritize MCS sites, deprioritize sites in essential regions
                if hasMCSFeature {
                    if inMCS { score += 10 }
                    else { score -= 8 }
                }
                if avoidRegion != nil { score -= 12 }
                score += CloningStrategyAnalyzer.methylationScorePenalty(warnings: warnings)

                strategies.append(CloningStrategy(
                    enzyme5: enzyme, enzyme3: nil,
                    insertEnzyme5: nil, insertEnzyme3: nil,
                    internalCutters: [],
                    frameAnalysis: frame,
                    warnings: warnings, score: score,
                    vectorSite5Position: site.position, vectorSite3Position: site.position,
                    insertReversed: insertReversed,
                    cloningPath: .bluntInsertDirect,
                    backboneSize: vectorSeq.count,
                    excisedSize: 0,
                    insertSize: insertLen,
                    partialDigest: .none
                ))
            }
        }
        
        // -----------------------------------------------------------------
        // Blunt-mediated insertion (fill-in / nibble-back)
        // -----------------------------------------------------------------
        // Release the insert with its own flanking enzymes, make any sticky
        // end blunt — fill-in (Klenow, KEEPS the overhang bases) or nibble-back
        // (nuclease, DROPS them) — then ligate into a single BLUNT vector cut.
        // Non-directional, and the original recognition sites are NOT
        // regenerated at the junctions.
        //
        // Supports both simple insertion and fusion modes. Fill-in and nibble
        // produce different blunted boundaries, so they may differ in frame —
        // one variant may be in-frame for a fusion while the other is not.
        do {
            // Blunt vector cutters with exactly one site in the cloning region.
            let bluntVectorNames = regionSitesByEnzyme
                .filter { $0.value.count == 1 }
                .keys
                .filter { enzymeMap[$0]?.overhangType == .blunt }
                .sorted()
            
            // Enzymes that flank the insert on each side without also cutting
            // inside it.
            let insert5Names = enzymeMap.keys
                .filter { has5PrimeFlank($0) && !hasConflictingInsertSites($0, usedAs5Prime: true)
                          && flank5SourcePosition($0) != nil }
                .sorted()
            let insert3Names = enzymeMap.keys
                .filter { has3PrimeFlank($0) && !hasConflictingInsertSites($0, usedAs5Prime: false)
                          && flank3SourcePosition($0) != nil }
                .sorted()
            
            // Forward fragment boundary for one blunted end (same geometry as
            // the Construct Builder): fill-in keeps the overhang bases (outer
            // boundary), nibble drops them (inner/recessed boundary).
            func bluntedBoundary(sitePos: Int, enz: RestrictionEnzyme,
                                 isFivePrimeEnd: Bool, method: BluntingMethod?) -> Int {
                let topCut = sitePos + enz.cutPosition5Prime
                let botCut = sitePos + enz.cutPosition3Prime
                let lo = min(topCut, botCut)
                let hi = max(topCut, botCut)
                switch method {
                case .none:   return topCut
                case .fillIn: return isFivePrimeEnd ? lo : hi
                case .nibble: return isFivePrimeEnd ? hi : lo
                }
            }
            
            // fill-in is only chemically valid on a 5' overhang; a 3' overhang
            // falls back to nibble even in the "fill-in" variant.
            func methodFor(_ enz: RestrictionEnzyme, preferFill: Bool) -> BluntingMethod? {
                guard enz.overhangType.sticky else { return nil }
                if preferFill && enz.overhangType == .sticky5Prime { return .fillIn }
                return .nibble
            }
            
            // For fusion modes: compute the insertOffset relative to the
            // blunted boundary rather than the excerpt start. The ATG is at
            // `insertORFForwardStart` within insertSeq (0-based). The blunted
            // boundary is at `left` in source coordinates, which corresponds to
            // `left - insertRegion.start` within insertSeq. So the distance
            // from blunted boundary to ATG = insertORFForwardStart - boundaryInExcerpt.
            // overhang is 0 for a blunt junction, so frame check is simply
            // (vectorOffset + bluntedInsertOffset5) % 3 == 0.
            func bluntedInsertOffset5(left: Int) -> Int {
                guard let orfStart = insertORFForwardStart else {
                    return fiveprimeFrame?.insertOffset ?? 0
                }
                let boundaryInExcerpt = left - insertRegion.start
                return ((orfStart - boundaryInExcerpt) % 3 + 3) % 3
            }
            func bluntedInsertOffset3(right: Int) -> Int {
                guard let orfEnd = insertORFForwardEnd else {
                    return threeprimeFrame?.insertOffset ?? 0
                }
                // For 3' fusion: remainder of coding sequence from start to
                // the blunted boundary. orfEnd is the last coding base position.
                let boundaryInExcerpt = right - insertRegion.start
                return ((boundaryInExcerpt - orfEnd) % 3 + 3) % 3
            }

            for bvName in bluntVectorNames {
                guard let bvEnz = enzymeMap[bvName],
                      let bvSite = regionSitesByEnzyme[bvName]?.first else { continue }
                let totalBvCuts = vectorSitesByEnzyme[bvName]?.count ?? 0
                
                for n5 in insert5Names {
                    for n3 in insert3Names {
                        guard let e5 = enzymeMap[n5], let e3 = enzymeMap[n3],
                              let pos5 = flank5SourcePosition(n5),
                              let pos3 = flank3SourcePosition(n3) else { continue }
                        
                        // The pair must bracket the insert (5' cut upstream of 3').
                        let topCut5 = pos5 + e5.cutPosition5Prime
                        let topCut3 = pos3 + e3.cutPosition5Prime
                        let brackets = topCut3 > topCut5 || (sourceIsCircular && topCut3 != topCut5)
                        guard brackets else { continue }
                        
                        // Need at least one sticky end — two blunt flanks are
                        // already covered by the blunt-insert-direct path.
                        guard e5.overhangType.sticky || e3.overhangType.sticky else { continue }
                        
                        // Two variants: fill-in-preferred and nibble-only.
                        // Dedupe when they collapse to the same method pair.
                        var emitted: Set<String> = []
                        for preferFill in [true, false] {
                            let m5 = methodFor(e5, preferFill: preferFill)
                            let m3 = methodFor(e3, preferFill: preferFill)
                            let key = "\(m5?.rawValue ?? "-")|\(m3?.rawValue ?? "-")"
                            if emitted.contains(key) { continue }
                            emitted.insert(key)
                            
                            let left  = bluntedBoundary(sitePos: pos5, enz: e5, isFivePrimeEnd: true,  method: m5)
                            let right = bluntedBoundary(sitePos: pos3, enz: e3, isFivePrimeEnd: false, method: m3)
                            let fragSize: Int
                            if right > left { fragSize = right - left }
                            else if sourceIsCircular { fragSize = (srcLen - left) + right }
                            else { continue }
                            guard fragSize > 0 else { continue }
                            
                            // Frame analysis for fusion modes.
                            // Blunt junction: overhang = 0, so check is purely
                            // (vectorOffset + bluntedInsertOffset) % 3 == 0.
                            // Auto-align is NOT valid here (direct digest, not PCR).
                            // Each method variant gets its own frame analysis since
                            // fill-in and nibble produce different insert offsets.
                            var adjustedFrame5: JunctionFrame? = nil
                            var adjustedFrame3: JunctionFrame? = nil
                            if cloningMode != .simpleInsertion {
                                if let f5 = fiveprimeFrame {
                                    adjustedFrame5 = JunctionFrame(
                                        vectorOffset: f5.vectorOffset,
                                        insertOffset: bluntedInsertOffset5(left: left)
                                    )
                                }
                                if let f3 = threeprimeFrame {
                                    adjustedFrame3 = JunctionFrame(
                                        vectorOffset: f3.vectorOffset,
                                        insertOffset: bluntedInsertOffset3(right: right)
                                    )
                                }
                            }
                            
                            // analyzeFrame with overhang=0 (blunt vector enzyme).
                            // We pass bvEnz for both enzyme5 and enzyme3 — since
                            // it's a blunt cutter its overhang is 0, which is correct.
                            let frame = cloningMode == .simpleInsertion ? nil :
                                analyzeFrame(enzyme5: bvEnz, enzyme3: bvEnz,
                                             mode: cloningMode,
                                             fiveprimeFrame: adjustedFrame5,
                                             threeprimeFrame: adjustedFrame3,
                                             autoAlign5Prime: false,
                                             autoAlign3Prime: false,
                                             needsPrimers: false)
                            
                            // For fusion modes: check for in-frame stop codons
                            // between the blunted insert boundary and the ORF ATG.
                            // A stop codon there would terminate translation before
                            // reaching the fusion ORF, making the strategy unusable.
                            if cloningMode != .simpleInsertion,
                               let fa = frame,
                               fa.fiveprimeInFrame == true,
                               let orfStart = insertORFForwardStart {
                                let boundaryInExcerpt = left - insertRegion.start
                                let ohLen = 0  // blunt junction, no shared overhang
                                if CloningStrategyAnalyzer.hasInFrameStopCodon(in: insertSeq,
                                                       from: boundaryInExcerpt + ohLen,
                                                       to: orfStart,
                                                       frame: 0) {
                                    continue  // stop codon between boundary and ATG
                                }
                            }
                            
                            var warnings: [String] = []
                            if let m = m5 { warnings.append("5' end (\(e5.name)): \(m.enzymeDescription)") }
                            if let m = m3 { warnings.append("3' end (\(e3.name)): \(m.enzymeDescription)") }
                            warnings.append("Original \(n5)/\(n3) site(s) not regenerated at the junctions")
                            warnings.append("Non-directional — insert can ligate in either orientation")
                            let oh5 = abs(e5.cutPosition5Prime - e5.cutPosition3Prime)
                            let oh3 = abs(e3.cutPosition5Prime - e3.cutPosition3Prime)
                            let fillBases   = (m5 == .fillIn ? oh5 : 0) + (m3 == .fillIn ? oh3 : 0)
                            let nibbleBases = (m5 == .nibble ? oh5 : 0) + (m3 == .nibble ? oh3 : 0)
                            if fillBases > 0 {
                                warnings.append("Fill-in keeps the overhang bases (\(fillBases) bp added)")
                            }
                            if nibbleBases > 0 {
                                warnings.append("Nibble-back removes the overhang bases (\(nibbleBases) bp lost)")
                            }
                            // In a fusion, adding or removing bases at the junction
                            // moves the reading frame. The two blunting variants of
                            // the same enzyme pair therefore land in DIFFERENT frames,
                            // which is why both are listed. Say so, or the near-
                            // duplicate rows look like noise.
                            if cloningMode != .simpleInsertion, fillBases > 0 || nibbleBases > 0 {
                                warnings.append("Adding or removing bases here moves the reading frame — the fill-in and nibble-back versions of this enzyme pair land in different frames, so compare both rows")
                            }
                            if totalBvCuts > 1 { warnings.append("\(bvName) cuts \(totalBvCuts)× in full vector") }
                            warnings.append(contentsOf: contextMethylationWarnings(
                                enzyme: bvEnz, sitePosition: bvSite.position,
                                sequence: vectorSeq, methylation: methylation))
                            
                            // Coding bases lost at the 5' fusion junction:
                            // how far the blunted boundary sits past the ORF ATG.
                            // For fill-in retaining the full N-terminus this is 0.
                            var codingLost = 0
                            if cloningMode != .simpleInsertion, let orfStart = insertORFForwardStart {
                                let boundaryInExcerpt = left - insertRegion.start
                                if boundaryInExcerpt > orfStart {
                                    codingLost = boundaryInExcerpt - orfStart
                                }
                            }
                            
                            var score = computeScore(isDirectional: false, internalCutters: [],
                                                     frameAnalysis: frame, warningCount: warnings.count,
                                                     totalVectorCuts5: totalBvCuts, totalVectorCuts3: nil,
                                                     path: .bluntedInsert,
                                                     enzyme5IsBlunt: true, enzyme3IsBlunt: true,
                                                     codingBasesLost: codingLost,
                                                     isFusion: cloningMode != .simpleInsertion)
                            score += CloningStrategyAnalyzer.methylationScorePenalty(warnings: warnings)
                            
                            strategies.append(CloningStrategy(
                                enzyme5: bvEnz, enzyme3: nil,
                                insertEnzyme5: e5, insertEnzyme3: e3,
                                internalCutters: [],
                                frameAnalysis: frame,
                                warnings: warnings, score: score,
                                vectorSite5Position: bvSite.position, vectorSite3Position: bvSite.position,
                                insertReversed: insertReversed,
                                cloningPath: .bluntedInsert,
                                backboneSize: vectorSeq.count,
                                excisedSize: 0,
                                insertSize: fragSize,
                                insertCut5Source: left, insertCut3Source: right,
                                insertCut5Excerpt: left - insertRegion.start,
                                insertCut3Excerpt: right - insertRegion.start,
                                partialDigest: .none,
                                insert5Blunting: m5, insert3Blunting: m3
                            ))
                        }
                    }
                }
            }
        }
        
        // --- Directional (two-enzyme) strategies ---
        for i in 0..<candidateNames.count {
            for j in (i+1)..<candidateNames.count {
                let name5 = candidateNames[i]
                let name3 = candidateNames[j]
                
                guard let enz5 = enzymeMap[name5],
                      let enz3 = enzymeMap[name3] else { continue }
                
                if endsAreCompatible(enz5, enz3) { continue }
                
                guard let site5 = safeSitesByEnzyme[name5]?.first,
                      let site3 = safeSitesByEnzyme[name3]?.first else { continue }
                
                // Order by vector position
                let (upEnz, dnEnz, upSite, dnSite): (RestrictionEnzyme, RestrictionEnzyme, CutSite, CutSite)
                if site5.position <= site3.position {
                    (upEnz, dnEnz, upSite, dnSite) = (enz5, enz3, site5, site3)
                } else {
                    (upEnz, dnEnz, upSite, dnSite) = (enz3, enz5, site3, site5)
                }
                
                // Skip if the excised segment (between the two cuts) would destroy protected features.
                // The excised region upSite...dnSite gets replaced by the insert; the backbone
                // (dnSite → origin → upSite) is what's kept.
                if excisedSegmentOverlapsProtected(
                    upPos: upSite.position, dnPos: dnSite.position,
                    protectedRegions: protectedRegions) {
                    continue
                }
                
                // Determine effective insert enzymes (may differ via compatible ends)
                let up5flank = has5PrimeFlank(upEnz.name)
                let dn3flank = has3PrimeFlank(dnEnz.name)
                let compat5name = !up5flank ? compatible5PrimeFlank(upEnz.name) : nil
                let compat3name = !dn3flank ? compatible3PrimeFlank(dnEnz.name) : nil
                let effective5flank = up5flank || compat5name != nil
                let effective3flank = dn3flank || compat3name != nil
                
                // The enzyme that actually cuts the insert on each side
                let eff5name = compat5name ?? upEnz.name
                let eff3name = compat3name ?? dnEnz.name
                
                // Cross-enzyme conflict check: if the 3' insert enzyme also has
                // a site near the insert 5' end, it would cut internally and
                // destroy the insert. (E.g. SacI flanks both ends but Acc65I
                // provides the 5' cut → the SacI 5'-flank site is now internal.)
                // Same logic applies in reverse for the 5' enzyme.
                if hasConflictingInsertSites(eff5name, usedAs5Prime: true) { continue }
                if hasConflictingInsertSites(eff3name, usedAs5Prime: false) { continue }
                
                // Internal cutters (other enzymes with sites in the insert middle)
                var internalCutters: [String] = []
                if isTrulyInternal(upEnz.name) && upEnz.name != eff5name { internalCutters.append(upEnz.name) }
                if isTrulyInternal(dnEnz.name) && dnEnz.name != eff3name { internalCutters.append(dnEnz.name) }
                
                let path: CloningPath
                if effective5flank && effective3flank {
                    path = .directDigest
                } else if effective5flank && !effective3flank {
                    path = .onePrimerReverse
                } else if !effective5flank && effective3flank {
                    path = .onePrimerForward
                } else {
                    path = .pcrRequired
                }
                
                // Record which insert enzymes are used (nil = same as vector enzyme)
                let iEnz5: RestrictionEnzyme? = compat5name != nil ? enzymeMap[compat5name!] : nil
                let iEnz3: RestrictionEnzyme? = compat3name != nil ? enzymeMap[compat3name!] : nil
                
                let frame = analyzeFrame(enzyme5: upEnz, enzyme3: dnEnz,
                                         mode: cloningMode,
                                         fiveprimeFrame: fiveprimeFrame,
                                         threeprimeFrame: threeprimeFrame,
                                         autoAlign5Prime: autoAlign5Prime, autoAlign3Prime: autoAlign3Prime,
                                         needsPrimers: path.needsPrimers)
                
                var warnings: [String] = []
                appendAutoAlignWarnings(&warnings, frame: frame)
                let totalCuts5 = vectorSitesByEnzyme[upEnz.name]?.count ?? 0
                let totalCuts3 = vectorSitesByEnzyme[dnEnz.name]?.count ?? 0
                if totalCuts5 > 1 { warnings.append("\(upEnz.name) cuts \(totalCuts5)× in full vector") }
                if totalCuts3 > 1 { warnings.append("\(dnEnz.name) cuts \(totalCuts3)× in full vector") }
                warnings.append(contentsOf: contextMethylationWarnings(enzyme: upEnz, sitePosition: upSite.position, sequence: vectorSeq, methylation: methylation))
                warnings.append(contentsOf: contextMethylationWarnings(enzyme: dnEnz, sitePosition: dnSite.position, sequence: vectorSeq, methylation: methylation))
                // Also check the insert/source flanking sites (not just vector)
                if let src5 = flank5SourcePosition(eff5name), let iE5 = (iEnz5 ?? enzymeMap[eff5name]) {
                    warnings.append(contentsOf: contextMethylationWarnings(enzyme: iE5, sitePosition: src5, sequence: sourceSeq, methylation: methylation))
                }
                if let src3 = flank3SourcePosition(eff3name), let iE3 = (iEnz3 ?? enzymeMap[eff3name]) {
                    warnings.append(contentsOf: contextMethylationWarnings(enzyme: iE3, sitePosition: src3, sequence: sourceSeq, methylation: methylation))
                }

                // Note flanking site locations in warnings for user clarity
                if up5flank {
                    let where5 = (insertClassification[upEnz.name]?.fivePrimeFlank ?? false) ? "insert 5' end" : "source upstream"
                    warnings.append("\(upEnz.name) flanking site found at \(where5)")
                } else if let cn5 = compat5name {
                    warnings.append("Insert 5' end: \(cn5) (compatible ends with \(upEnz.name))")
                }
                if dn3flank {
                    let where3 = (insertClassification[dnEnz.name]?.threePrimeFlank ?? false) ? "insert 3' end" : "source downstream"
                    warnings.append("\(dnEnz.name) flanking site found at \(where3)")
                } else if let cn3 = compat3name {
                    warnings.append("Insert 3' end: \(cn3) (compatible ends with \(dnEnz.name))")
                }
                
                var score = computeScore(isDirectional: true, internalCutters: internalCutters,
                                         frameAnalysis: frame, warningCount: warnings.count,
                                         totalVectorCuts5: totalCuts5, totalVectorCuts3: totalCuts3,
                                         path: path,
                                         enzyme5IsBlunt: upEnz.overhangType == .blunt,
                                         enzyme3IsBlunt: dnEnz.overhangType == .blunt)
                    - orfAvoidancePenalty(enz5Name: eff5name, enz3Name: eff3name)
                
                let excised = dnSite.position - upSite.position
                let backbone = vectorSeq.count - excised
                
                // Compute actual insert fragment size from digest
                // For PCR sides, the primer places the site at the insert boundary
                var insCut5Src: Int? = nil
                var insCut3Src: Int? = nil
                let realInsertSize: Int
                if path == .pcrRequired {
                    realInsertSize = insertLen
                } else {
                    let src5 = effective5flank ? flank5SourcePosition(eff5name) : nil
                    let src3 = effective3flank ? flank3SourcePosition(eff3name) : nil
                    let enz5obj = iEnz5 ?? upEnz
                    let enz3obj = iEnz3 ?? dnEnz
                    let cut5 = src5 != nil ? src5! + enz5obj.cutPosition5Prime : missingFragmentBoundary(isFivePrime: true)
                    let cut3 = src3 != nil ? src3! + enz3obj.cutPosition5Prime : missingFragmentBoundary(isFivePrime: false)
                    if src5 != nil { insCut5Src = cut5 }
                    if src3 != nil { insCut3Src = cut3 }
                    let computed = fragmentLength(cut5: cut5, cut3: cut3)
                    realInsertSize = computed > 0 ? computed : insertLen
                }
                score -= excessFlankPenalty(realInsertSize: realInsertSize)
                score += CloningStrategyAnalyzer.methylationScorePenalty(warnings: warnings)

                let exc5 = insCut5Src.map { $0 - insertRegion.start }
                let exc3 = insCut3Src.map { $0 - insertRegion.start }
                strategies.append(CloningStrategy(
                    enzyme5: upEnz, enzyme3: dnEnz,
                    insertEnzyme5: iEnz5, insertEnzyme3: iEnz3,
                    internalCutters: internalCutters, frameAnalysis: frame,
                    warnings: warnings, score: score,
                    vectorSite5Position: upSite.position, vectorSite3Position: dnSite.position,
                    insertReversed: insertReversed,
                    cloningPath: path,
                    backboneSize: backbone,
                    excisedSize: excised,
                    insertSize: realInsertSize,
                    insertCut5Source: insCut5Src, insertCut3Source: insCut3Src,
                    insertCut5Excerpt: exc5, insertCut3Excerpt: exc3,
                    partialDigest: .none
                ))
            }
        }
        
        // --- Non-directional (single-enzyme) strategies ---
        for name in candidateNames {
            guard let enzyme = enzymeMap[name],
                  let site = safeSitesByEnzyme[name]?.first else { continue }
            
            var internalCutters: [String] = []
            if isTrulyInternal(name) { internalCutters.append(name) }
            
            // Check same-enzyme flanking first, then compatible-end enzymes
            let same5 = has5PrimeFlank(name)
            let same3 = has3PrimeFlank(name)
            let compat5name = !same5 ? compatible5PrimeFlank(name) : nil
            let compat3name = !same3 ? compatible3PrimeFlank(name) : nil
            let effective5 = same5 || compat5name != nil
            let effective3 = same3 || compat3name != nil
            
            let bothFlanks = effective5 && effective3
            let path: CloningPath = bothFlanks ? .directDigest : .pcrRequired
            
            // For non-directional, the compatible insert enzymes may differ
            // on each side (e.g. DraI flanks 5', HincII flanks 3' — both
            // blunt, both ligate into a blunt vector site). Record each
            // side's insert enzyme independently.
            let iEnz5: RestrictionEnzyme? = compat5name != nil ? enzymeMap[compat5name!] : nil
            let iEnz3: RestrictionEnzyme? = compat3name != nil ? enzymeMap[compat3name!] : nil
            
            let frame = analyzeFrame(enzyme5: enzyme, enzyme3: enzyme,
                                     mode: cloningMode,
                                     fiveprimeFrame: fiveprimeFrame,
                                     threeprimeFrame: threeprimeFrame,
                                         autoAlign5Prime: autoAlign5Prime, autoAlign3Prime: autoAlign3Prime,
                                         needsPrimers: path.needsPrimers)
            
            var warnings: [String] = []
            appendAutoAlignWarnings(&warnings, frame: frame)
            let totalCuts = vectorSitesByEnzyme[name]?.count ?? 0
            if totalCuts > 1 { warnings.append("\(name) cuts \(totalCuts)× in full vector") }
            warnings.append(contentsOf: contextMethylationWarnings(enzyme: enzyme, sitePosition: site.position, sequence: vectorSeq, methylation: methylation))
            
            if same5 || same3 {
                let where5 = same5 ? "5'" : ""
                let where3 = same3 ? "3'" : ""
                let sides = [where5, where3].filter { !$0.isEmpty }.joined(separator: " & ")
                warnings.append("\(name) flanking site found at insert \(sides) end")
            }
            if let cn5 = compat5name {
                warnings.append("Insert 5' end: \(cn5) (compatible ends with \(name))")
            }
            if let cn3 = compat3name {
                warnings.append("Insert 3' end: \(cn3) (compatible ends with \(name))")
            }
            
            var score = computeScore(isDirectional: false, internalCutters: internalCutters,
                                     frameAnalysis: frame, warningCount: warnings.count,
                                     totalVectorCuts5: totalCuts, totalVectorCuts3: nil,
                                     path: path,
                                     enzyme5IsBlunt: enzyme.overhangType == .blunt,
                                     enzyme3IsBlunt: enzyme.overhangType == .blunt)
                - orfAvoidancePenalty(enz5Name: compat5name ?? name,
                                     enz3Name: compat3name ?? name)
            
            // Compute actual insert fragment size
            var insCut5Src: Int? = nil
            var insCut3Src: Int? = nil
            let realInsertSize: Int
            if path == .pcrRequired {
                realInsertSize = insertLen
            } else {
                let e5name = compat5name ?? name
                let e3name = compat3name ?? name
                let src5 = flank5SourcePosition(e5name)
                let src3 = flank3SourcePosition(e3name)
                let enzObj5 = iEnz5 ?? enzyme
                let enzObj3 = iEnz3 ?? enzyme
                let cut5 = src5 != nil ? src5! + enzObj5.cutPosition5Prime : missingFragmentBoundary(isFivePrime: true)
                let cut3 = src3 != nil ? src3! + enzObj3.cutPosition5Prime : missingFragmentBoundary(isFivePrime: false)
                if src5 != nil { insCut5Src = cut5 }
                if src3 != nil { insCut3Src = cut3 }
                let computed = fragmentLength(cut5: cut5, cut3: cut3)
                realInsertSize = computed > 0 ? computed : insertLen
            }
            score -= excessFlankPenalty(realInsertSize: realInsertSize)
            score += CloningStrategyAnalyzer.methylationScorePenalty(warnings: warnings)

            // Fusion native-retention penalty: if this strategy's insert cut
            // sits past the ORF boundary it discards native coding sequence.
            // Penalise per codon lost so a clean retaining strategy can outrank
            // a sticky one that chews into the protein. Zero when nothing lost.
            if cloningMode != .simpleInsertion {
                var basesLost = 0
                if (cloningMode == .fusionNTerminal || cloningMode == .fusionBoth),
                   let c5 = insCut5Src, let orfStart = insertORFForwardStart {
                    let cutInExcerpt = c5 - insertRegion.start
                    if cutInExcerpt > orfStart { basesLost = max(basesLost, cutInExcerpt - orfStart) }
                }
                if (cloningMode == .fusionCTerminal || cloningMode == .fusionBoth),
                   let c3 = insCut3Src, let orfEnd = insertORFForwardEnd {
                    let cutInExcerpt = c3 - insertRegion.start
                    if cutInExcerpt < orfEnd { basesLost = max(basesLost, orfEnd - cutInExcerpt) }
                }
                if basesLost > 0 {
                    score -= ((basesLost + 2) / 3) * 25
                }
            }

            let sExc5 = insCut5Src.map { $0 - insertRegion.start }
            let sExc3 = insCut3Src.map { $0 - insertRegion.start }
            strategies.append(CloningStrategy(
                enzyme5: enzyme, enzyme3: nil,
                insertEnzyme5: iEnz5,
                insertEnzyme3: iEnz3,
                internalCutters: internalCutters, frameAnalysis: frame,
                warnings: warnings, score: score,
                vectorSite5Position: site.position, vectorSite3Position: site.position,
                insertReversed: insertReversed,
                cloningPath: path,
                backboneSize: vectorSeq.count,
                excisedSize: 0,
                insertSize: realInsertSize,
                insertCut5Source: insCut5Src, insertCut3Source: insCut3Src,
                insertCut5Excerpt: sExc5, insertCut3Excerpt: sExc3,
                partialDigest: .none
            ))

            // --- Fusion insert-truncation variant (single-enzyme, ranked lower) ---
            // If this enzyme also cuts a few codons INTO the ORF near a junction,
            // emit an extra fusion strategy that uses that in-ORF cut to reach an
            // in-frame junction, sacrificing a few terminal residues. Only the
            // fusion side uses the truncating cut; the other end uses the clean
            // flank. The View's joint-frame filter validates the junction on the
            // truncating cut (and rejects it for vectors where it is out of frame).
            if truncSearchActive, let cls = insertClassification[name] {
                let orfFwdStart = insertORFForwardStart ?? 0
                let orfFwdEnd   = insertORFForwardEnd ?? 0
                let cleanFlank5 = cls.fivePrimeFlankPos
                let cleanFlank3 = cls.threePrimeFlankPos

                // N-terminal fusion: in-ORF 5' cut + clean 3' end.
                if (cloningMode == .fusionNTerminal || cloningMode == .fusionBoth),
                   let tPos5 = cls.fivePrimeTruncFlankPos, effective3 {
                    let cut5site = tPos5 + enzyme.cutPosition5Prime
                    let lostAA = max(0, cut5site - orfFwdStart) / 3
                    let tSize = (cleanFlank5 != nil) ? max(1, realInsertSize - (tPos5 - cleanFlank5!)) : realInsertSize
                    let tWarn = warnings
                    strategies.append(CloningStrategy(
                        enzyme5: enzyme, enzyme3: nil,
                        insertEnzyme5: iEnz5, insertEnzyme3: iEnz3,
                        internalCutters: internalCutters.filter { $0 != name },
                        frameAnalysis: frame,
                        warnings: tWarn, score: score - 60 - lostAA * 3,
                        vectorSite5Position: site.position, vectorSite3Position: site.position,
                        insertReversed: insertReversed,
                        cloningPath: path,
                        backboneSize: vectorSeq.count, excisedSize: 0, insertSize: tSize,
                        insertCut5Source: (tPos5 + insertRegion.start) + enzyme.cutPosition5Prime,
                        insertCut3Source: insCut3Src,
                        insertCut5Excerpt: nil, insertCut3Excerpt: sExc3,
                        insertTruncCut5: tPos5,
                        partialDigest: .none
                    ))
                }

                // C-terminal fusion: clean 5' end + in-ORF 3' cut.
                if (cloningMode == .fusionCTerminal || cloningMode == .fusionBoth),
                   let tPos3 = cls.threePrimeTruncFlankPos, effective5 {
                    let cut3site = tPos3 + enzyme.cutPosition5Prime
                    let lostAA = max(0, orfFwdEnd - cut3site) / 3
                    let tSize = (cleanFlank3 != nil) ? max(1, realInsertSize - (cleanFlank3! - tPos3)) : realInsertSize
                    let tWarn = warnings
                    strategies.append(CloningStrategy(
                        enzyme5: enzyme, enzyme3: nil,
                        insertEnzyme5: iEnz5, insertEnzyme3: iEnz3,
                        internalCutters: internalCutters.filter { $0 != name },
                        frameAnalysis: frame,
                        warnings: tWarn, score: score - 60 - lostAA * 3,
                        vectorSite5Position: site.position, vectorSite3Position: site.position,
                        insertReversed: insertReversed,
                        cloningPath: path,
                        backboneSize: vectorSeq.count, excisedSize: 0, insertSize: tSize,
                        insertCut5Source: insCut5Src,
                        insertCut3Source: (tPos3 + insertRegion.start) + enzyme.cutPosition5Prime,
                        insertCut5Excerpt: sExc5, insertCut3Excerpt: nil,
                        insertTruncCut3: tPos3,
                        partialDigest: .none
                    ))
                }
            }
        }

        // =====================================================================
        // --- Partial digest strategies: VECTOR (enzyme has exactly 2 sites) ---
        // =====================================================================
        // An enzyme with exactly 2 sites on the vector is normally excluded.
        // With a partial digest you cut only ONE of the two sites.
        // Site selection: prefer the site OUTSIDE protected regions.
        //   - Both in protected → skip enzyme
        //   - One in protected, one not → cut the unprotected one
        //   - Neither in protected → both viable, prefer the one in cloning region
        
        let vectorPartialCandidates = vectorSitesByEnzyme.filter { $0.value.count == 2 }
        
        for (partialName, allSites) in vectorPartialCandidates {
            guard let partialEnzyme = enzymeMap[partialName] else { continue }
            let sortedSites = allSites.sorted { $0.position < $1.position }
            let site0 = sortedSites[0]
            let site1 = sortedSites[1]
            
            let site0InProtected = protectedRegions.contains { $0.contains(site0.position) }
            let site1InProtected = protectedRegions.contains { $0.contains(site1.position) }
            
            // Both sites protected → can't safely cut either one
            if site0InProtected && site1InProtected { continue }
            
            let cutSite: CutSite
            let preservedSite: CutSite
            
            if site0InProtected && !site1InProtected {
                cutSite = site1; preservedSite = site0
            } else if site1InProtected && !site0InProtected {
                cutSite = site0; preservedSite = site1
            } else {
                // Both outside protected — prefer the one in the cloning region
                let site0InRegion = cloningRegionRange.map { cloningRegionContains($0, site0.position) } ?? true
                let site1InRegion = cloningRegionRange.map { cloningRegionContains($0, site1.position) } ?? true
                if site0InRegion && !site1InRegion {
                    cutSite = site0; preservedSite = site1
                } else {
                    cutSite = site1; preservedSite = site0
                }
            }
            
            // Cut site must be in the cloning region (if one is defined)
            if let region = cloningRegionRange, !cloningRegionContains(region, cutSite.position) { continue }
            
            // --- Non-directional partial (linearise vector at the cut site) ---
            do {
                var internalCutters: [String] = []
                if isTrulyInternal(partialName) { internalCutters.append(partialName) }
                
                let bothFlanks = has5PrimeFlank(partialName) && has3PrimeFlank(partialName)
                let path: CloningPath = bothFlanks ? .directDigest : .pcrRequired
                
                let frame = analyzeFrame(enzyme5: partialEnzyme, enzyme3: partialEnzyme,
                                         mode: cloningMode,
                                         fiveprimeFrame: fiveprimeFrame,
                                         threeprimeFrame: threeprimeFrame,
                                         autoAlign5Prime: autoAlign5Prime, autoAlign3Prime: autoAlign3Prime,
                                         needsPrimers: path.needsPrimers)
                
                var warnings: [String] = []
                appendAutoAlignWarnings(&warnings, frame: frame)
                warnings.append("Partial digest: cut \(partialName) at position \(cutSite.position + 1), preserve site at \(preservedSite.position + 1)")
                warnings.append(contentsOf: contextMethylationWarnings(enzyme: partialEnzyme, sitePosition: cutSite.position, sequence: vectorSeq, methylation: methylation))
                
                var score = computeScore(isDirectional: false, internalCutters: internalCutters,
                                         frameAnalysis: frame, warningCount: warnings.count,
                                         totalVectorCuts5: 1, totalVectorCuts3: nil,
                                         path: path, isPartial: true,
                                         enzyme5IsBlunt: partialEnzyme.overhangType == .blunt,
                                         enzyme3IsBlunt: partialEnzyme.overhangType == .blunt)
                    - orfAvoidancePenalty(enz5Name: partialName, enz3Name: partialName)
                
                let realInsertSize: Int
                if path == .pcrRequired {
                    realInsertSize = insertLen
                } else {
                    realInsertSize = actualFragmentSize(enz5Name: partialName, enz3Name: partialName,
                                                        enz5: partialEnzyme, enz3: partialEnzyme)
                }
                score -= excessFlankPenalty(realInsertSize: realInsertSize)
                
                strategies.append(CloningStrategy(
                    enzyme5: partialEnzyme, enzyme3: nil,
                    insertEnzyme5: nil, insertEnzyme3: nil,
                    internalCutters: internalCutters, frameAnalysis: frame,
                    warnings: warnings, score: score,
                    vectorSite5Position: cutSite.position, vectorSite3Position: cutSite.position,
                    insertReversed: insertReversed,
                    cloningPath: path,
                    backboneSize: vectorSeq.count,
                    excisedSize: 0,
                    insertSize: realInsertSize,
                    partialDigest: .vector
                ))
            }
            
            // --- Directional partial: pair with single-cutter on vector ---
            for partnerName in candidateNames {
                if partnerName == partialName { continue }
                guard let partnerEnz = enzymeMap[partnerName],
                      let partnerSite = safeSitesByEnzyme[partnerName]?.first else { continue }
                
                // Ends must be incompatible for directional cloning
                if endsAreCompatible(partialEnzyme, partnerEnz) { continue }
                
                // Order by vector position: the partial cut site vs the partner site
                let (upEnz, dnEnz, upSite, dnSite): (RestrictionEnzyme, RestrictionEnzyme, CutSite, CutSite)
                if cutSite.position <= partnerSite.position {
                    (upEnz, dnEnz, upSite, dnSite) = (partialEnzyme, partnerEnz, cutSite, partnerSite)
                } else {
                    (upEnz, dnEnz, upSite, dnSite) = (partnerEnz, partialEnzyme, partnerSite, cutSite)
                }
                
                // Check that excised segment doesn't overlap protected regions
                if excisedSegmentOverlapsProtected(upPos: upSite.position, dnPos: dnSite.position,
                                                   protectedRegions: protectedRegions) { continue }
                
                // Also check that the PRESERVED partial site isn't in the excised segment
                // (it would be lost even though we didn't cut it)
                let excisedRange = upSite.position...dnSite.position
                if excisedRange.contains(preservedSite.position) { continue }
                
                // Cross-enzyme conflict check on insert
                if hasConflictingInsertSites(upEnz.name, usedAs5Prime: true) { continue }
                if hasConflictingInsertSites(dnEnz.name, usedAs5Prime: false) { continue }
                
                var internalCutters: [String] = []
                if isTrulyInternal(upEnz.name) { internalCutters.append(upEnz.name) }
                if isTrulyInternal(dnEnz.name) { internalCutters.append(dnEnz.name) }
                
                let up5flank = has5PrimeFlank(upEnz.name)
                let dn3flank = has3PrimeFlank(dnEnz.name)
                let path: CloningPath
                if up5flank && dn3flank { path = .directDigest }
                else if up5flank && !dn3flank { path = .onePrimerReverse }
                else if !up5flank && dn3flank { path = .onePrimerForward }
                else { path = .pcrRequired }
                
                let frame = analyzeFrame(enzyme5: upEnz, enzyme3: dnEnz,
                                         mode: cloningMode,
                                         fiveprimeFrame: fiveprimeFrame,
                                         threeprimeFrame: threeprimeFrame,
                                         autoAlign5Prime: autoAlign5Prime, autoAlign3Prime: autoAlign3Prime,
                                         needsPrimers: path.needsPrimers)
                
                var warnings: [String] = []
                appendAutoAlignWarnings(&warnings, frame: frame)
                warnings.append("Partial digest: cut \(partialName) at position \(cutSite.position + 1), preserve site at \(preservedSite.position + 1)")
                warnings.append(contentsOf: contextMethylationWarnings(enzyme: upEnz, sitePosition: upSite.position, sequence: vectorSeq, methylation: methylation))
                warnings.append(contentsOf: contextMethylationWarnings(enzyme: dnEnz, sitePosition: dnSite.position, sequence: vectorSeq, methylation: methylation))
                
                // Report flanking info
                if up5flank {
                    let w = (insertClassification[upEnz.name]?.fivePrimeFlank ?? false) ? "insert 5' end" : "source upstream"
                    warnings.append("\(upEnz.name) flanking site found at \(w)")
                }
                if dn3flank {
                    let w = (insertClassification[dnEnz.name]?.threePrimeFlank ?? false) ? "insert 3' end" : "source downstream"
                    warnings.append("\(dnEnz.name) flanking site found at \(w)")
                }
                
                // Use totalVectorCuts = 1 for the partner (single-cutter) and
                // treat the partial enzyme as effectively 1 cut for scoring purposes
                let partnerCuts = vectorSitesByEnzyme[partnerName]?.count ?? 0
                var score = computeScore(isDirectional: true, internalCutters: internalCutters,
                                         frameAnalysis: frame, warningCount: warnings.count,
                                         totalVectorCuts5: 1, totalVectorCuts3: partnerCuts,
                                         path: path, isPartial: true,
                                         enzyme5IsBlunt: upEnz.overhangType == .blunt,
                                         enzyme3IsBlunt: dnEnz.overhangType == .blunt)
                    - orfAvoidancePenalty(enz5Name: upEnz.name, enz3Name: dnEnz.name)
                
                let excised = dnSite.position - upSite.position
                let backbone = vectorSeq.count - excised
                
                let realInsertSize: Int
                if path == .pcrRequired {
                    realInsertSize = insertLen
                } else {
                    let e5 = upEnz.name, e3 = dnEnz.name
                    let src5 = has5PrimeFlank(e5) ? flank5SourcePosition(e5) : nil
                    let src3 = has3PrimeFlank(e3) ? flank3SourcePosition(e3) : nil
                    let cut5 = src5 != nil ? src5! + upEnz.cutPosition5Prime : missingFragmentBoundary(isFivePrime: true)
                    let cut3 = src3 != nil ? src3! + dnEnz.cutPosition5Prime : missingFragmentBoundary(isFivePrime: false)
                    let computed = fragmentLength(cut5: cut5, cut3: cut3)
                    realInsertSize = computed > 0 ? computed : insertLen
                }
                score -= excessFlankPenalty(realInsertSize: realInsertSize)
                score += CloningStrategyAnalyzer.methylationScorePenalty(warnings: warnings)

                strategies.append(CloningStrategy(
                    enzyme5: upEnz, enzyme3: dnEnz,
                    insertEnzyme5: nil, insertEnzyme3: nil,
                    internalCutters: internalCutters, frameAnalysis: frame,
                    warnings: warnings, score: score,
                    vectorSite5Position: upSite.position, vectorSite3Position: dnSite.position,
                    insertReversed: insertReversed,
                    cloningPath: path,
                    backboneSize: backbone,
                    excisedSize: excised,
                    insertSize: realInsertSize,
                    partialDigest: .vector
                ))
            }
        }

        // =====================================================================
        // --- Partial digest strategies: INSERT (enzyme has flanking + internal) ---
        // =====================================================================
        // Scenario: enzyme A (e.g. XbaI) has 1 flanking site (external to the
        // insert, or at the insert edge) + 1 truly internal site within the insert.
        // Total = 2 sites on the source sequence. A partial digest of enzyme A
        // preserves the internal site, releasing the full insert on a gel.
        //
        // The VECTOR enzyme for the partial side can be:
        //   (a) the same enzyme (if it's a single-cutter on the vector), or
        //   (b) a compatible-end enzyme on the vector (e.g. NheI for XbaI)
        //
        // Enzyme B provides the other end. It too can use compatible-end
        // substitution on the insert side.
        
        // Gather enzymes with a truly internal site in the insert
        let internalCutterNames = insertClassification.filter { $0.value.trulyInternal }.map { $0.key }
        
        for partialName in internalCutterNames {
            guard let partialEnzyme = enzymeMap[partialName] else { continue }
            
            // Must have exactly 2 sites on the WHOLE source sequence
            guard let totalSourceSites = sourceSitesByEnzyme[partialName], totalSourceSites.count == 2 else { continue }
            
            // Must have a flanking site (either at insert edge or external in source)
            let hasFlank5 = has5PrimeFlank(partialName)
            let hasFlank3 = has3PrimeFlank(partialName)
            guard hasFlank5 || hasFlank3 else { continue }
            
            // Find which vector single-cutters can serve as the vector enzyme
            // for the partial side: either the partial enzyme itself, or a compatible one
            var vectorOptionsForPartial: [(vectorEnzyme: RestrictionEnzyme, vectorSite: CutSite, isCompatSub: Bool)] = []
            
            // (a) Partial enzyme is itself a vector single-cutter
            if candidateNames.contains(partialName),
               let vSite = safeSitesByEnzyme[partialName]?.first {
                vectorOptionsForPartial.append((partialEnzyme, vSite, false))
            }
            
            // (b) Compatible enzymes that are vector single-cutters (sticky ends only)
            if partialEnzyme.overhangType != .blunt,
               let compatNames = compatibleEnzymeNames[partialName] {
                for cn in compatNames {
                    if candidateNames.contains(cn),
                       let cEnz = enzymeMap[cn],
                       let cSite = safeSitesByEnzyme[cn]?.first {
                        vectorOptionsForPartial.append((cEnz, cSite, true))
                    }
                }
            }
            
            guard !vectorOptionsForPartial.isEmpty else { continue }
            
            // For each vector option on the partial side, pair with a partner
            for partialOption in vectorOptionsForPartial {
                let partialVecEnz = partialOption.vectorEnzyme
                let partialVSite = partialOption.vectorSite
                let partialIsCompatSub = partialOption.isCompatSub
                
                // Now find a partner: a vector single-cutter that provides the other end.
                // The partner must flank the insert on the opposite side (directly or via compatible enzyme).
                for partnerVecName in candidateNames {
                    if partnerVecName == partialVecEnz.name { continue }
                    guard let partnerVecEnz = enzymeMap[partnerVecName],
                          let partnerVSite = safeSitesByEnzyme[partnerVecName]?.first else { continue }
                    
                    // Vector enzymes must have incompatible ends for directional cloning
                    if endsAreCompatible(partialVecEnz, partnerVecEnz) { continue }
                    
                    // Does the partner (or a compatible enzyme) flank the insert on the other side?
                    let partnerSameFlank5 = has5PrimeFlank(partnerVecName)
                    let partnerSameFlank3 = has3PrimeFlank(partnerVecName)
                    let partnerCompat5 = !partnerSameFlank5 ? compatible5PrimeFlank(partnerVecName) : nil
                    let partnerCompat3 = !partnerSameFlank3 ? compatible3PrimeFlank(partnerVecName) : nil
                    let partnerEff5 = partnerSameFlank5 || partnerCompat5 != nil
                    let partnerEff3 = partnerSameFlank3 || partnerCompat3 != nil
                    
                    // Valid combos: partial flanks one side, partner flanks the other
                    let validCombo: Bool
                    let partialIs5: Bool
                    if hasFlank5 && partnerEff3 {
                        validCombo = true; partialIs5 = true
                    } else if hasFlank3 && partnerEff5 {
                        validCombo = true; partialIs5 = false
                    } else {
                        validCombo = false; partialIs5 = true
                    }
                    guard validCombo else { continue }
                    
                    // Partner must NOT have conflicting insert sites
                    // The effective partner insert enzyme depends on which side it provides
                    let partnerEffName: String
                    let partnerUsedAs5: Bool
                    if partialIs5 {
                        // Partner provides 3' end
                        partnerEffName = partnerCompat3 ?? partnerVecName
                        partnerUsedAs5 = false
                    } else {
                        // Partner provides 5' end
                        partnerEffName = partnerCompat5 ?? partnerVecName
                        partnerUsedAs5 = true
                    }
                    if hasConflictingInsertSites(partnerEffName, usedAs5Prime: partnerUsedAs5) { continue }
                    
                    // Determine vector enzyme ordering by position
                    let (upVecEnz, dnVecEnz, upVSite, dnVSite): (RestrictionEnzyme, RestrictionEnzyme, CutSite, CutSite)
                    if partialIs5 {
                        if partialVSite.position <= partnerVSite.position {
                            (upVecEnz, dnVecEnz, upVSite, dnVSite) = (partialVecEnz, partnerVecEnz, partialVSite, partnerVSite)
                        } else {
                            (upVecEnz, dnVecEnz, upVSite, dnVSite) = (partnerVecEnz, partialVecEnz, partnerVSite, partialVSite)
                        }
                    } else {
                        if partnerVSite.position <= partialVSite.position {
                            (upVecEnz, dnVecEnz, upVSite, dnVSite) = (partnerVecEnz, partialVecEnz, partnerVSite, partialVSite)
                        } else {
                            (upVecEnz, dnVecEnz, upVSite, dnVSite) = (partialVecEnz, partnerVecEnz, partialVSite, partnerVSite)
                        }
                    }
                    
                    // Check excised segment on vector doesn't overlap protected regions
                    if excisedSegmentOverlapsProtected(upPos: upVSite.position, dnPos: dnVSite.position,
                                                       protectedRegions: protectedRegions) { continue }
                    
                    // Work out the insert enzymes
                    // 5' side insert enzyme:
                    let iEnz5: RestrictionEnzyme?
                    if partialIs5 {
                        // Partial enzyme cuts insert on 5' side
                        iEnz5 = partialIsCompatSub ? partialEnzyme : nil
                    } else {
                        // Partner cuts insert on 5' side
                        if let pc5 = partnerCompat5, let e = enzymeMap[pc5] { iEnz5 = e }
                        else { iEnz5 = nil }
                    }
                    // 3' side insert enzyme:
                    let iEnz3: RestrictionEnzyme?
                    if !partialIs5 {
                        // Partial enzyme cuts insert on 3' side
                        iEnz3 = partialIsCompatSub ? partialEnzyme : nil
                    } else {
                        // Partner cuts insert on 3' side
                        if let pc3 = partnerCompat3, let e = enzymeMap[pc3] { iEnz3 = e }
                        else { iEnz3 = nil }
                    }
                    
                    let frame = analyzeFrame(enzyme5: upVecEnz, enzyme3: dnVecEnz,
                                             mode: cloningMode,
                                             fiveprimeFrame: fiveprimeFrame,
                                             threeprimeFrame: threeprimeFrame,
                                         autoAlign5Prime: autoAlign5Prime, autoAlign3Prime: autoAlign3Prime,
                                         needsPrimers: false)
                    
                    var warnings: [String] = []
                    appendAutoAlignWarnings(&warnings, frame: frame)
                    warnings.append("Partial digest on insert: \(partialName) has internal site — partial digest releases full insert")
                    if partialIsCompatSub {
                        warnings.append("Vector: \(partialVecEnz.name) (compatible ends with \(partialName))")
                    }
                    if let pc5 = partnerCompat5, !partialIs5 == false {
                        // partner is on 3' side and uses compatible enzyme
                        _ = pc5 // already reported in iEnz3
                    }
                    let totalCuts5 = vectorSitesByEnzyme[upVecEnz.name]?.count ?? 0
                    let totalCuts3 = vectorSitesByEnzyme[dnVecEnz.name]?.count ?? 0
                    if totalCuts5 > 1 { warnings.append("\(upVecEnz.name) cuts \(totalCuts5)× in full vector") }
                    if totalCuts3 > 1 { warnings.append("\(dnVecEnz.name) cuts \(totalCuts3)× in full vector") }
                    warnings.append(contentsOf: contextMethylationWarnings(enzyme: upVecEnz, sitePosition: upVSite.position, sequence: vectorSeq, methylation: methylation))
                    warnings.append(contentsOf: contextMethylationWarnings(enzyme: dnVecEnz, sitePosition: dnVSite.position, sequence: vectorSeq, methylation: methylation))
                    
                    if let ie5 = iEnz5 {
                        warnings.append("Insert 5' end: \(ie5.name) (compatible ends with \(upVecEnz.name))")
                    }
                    if let ie3 = iEnz3 {
                        warnings.append("Insert 3' end: \(ie3.name) (compatible ends with \(dnVecEnz.name))")
                    }
                    
                    var score = computeScore(isDirectional: true, internalCutters: [],
                                             frameAnalysis: frame, warningCount: warnings.count,
                                             totalVectorCuts5: totalCuts5, totalVectorCuts3: totalCuts3,
                                             path: .directDigest, isPartial: true,
                                             enzyme5IsBlunt: upVecEnz.overhangType == .blunt,
                                             enzyme3IsBlunt: dnVecEnz.overhangType == .blunt)
                        - orfAvoidancePenalty(
                            enz5Name: partialIs5 ? partialName : (partnerCompat5 ?? partnerVecName),
                            enz3Name: partialIs5 ? (partnerCompat3 ?? partnerVecName) : partialName)
                    
                    let excised = dnVSite.position - upVSite.position
                    let backbone = vectorSeq.count - excised
                    
                    // Compute actual insert fragment size from partial digest
                    let partialE5name = partialIs5 ? partialName : (partnerCompat5 ?? partnerVecName)
                    let partialE3name = partialIs5 ? (partnerCompat3 ?? partnerVecName) : partialName
                    let src5 = flank5SourcePosition(partialE5name)
                    let src3 = flank3SourcePosition(partialE3name)
                    let eObj5 = iEnz5 ?? upVecEnz
                    let eObj3 = iEnz3 ?? dnVecEnz
                    let cut5 = src5 != nil ? src5! + eObj5.cutPosition5Prime : insertRegion.start
                    let cut3 = src3 != nil ? src3! + eObj3.cutPosition5Prime : (insertRegion.end + 1)
                    let computedSize = cut3 > cut5 ? cut3 - cut5 : (sourceIsCircular ? (srcLen - cut5) + cut3 : -1)
                    let realInsertSize = computedSize > 0 ? computedSize : insertLen
                    score -= excessFlankPenalty(realInsertSize: realInsertSize)
                    
                    strategies.append(CloningStrategy(
                        enzyme5: upVecEnz, enzyme3: dnVecEnz,
                        insertEnzyme5: iEnz5, insertEnzyme3: iEnz3,
                        internalCutters: [], frameAnalysis: frame,
                        warnings: warnings, score: score,
                        vectorSite5Position: upVSite.position, vectorSite3Position: dnVSite.position,
                        insertReversed: insertReversed,
                        cloningPath: .directDigest,
                        backboneSize: backbone,
                        excisedSize: excised,
                        insertSize: realInsertSize,
                        partialDigest: .insert
                    ))
                }
            }
        }
        
        // --- Strategy-type breakdown (for diagnostic) ---
        // Counts strategies by cloning path so we can see, e.g., whether the
        // analyzer returned PCR strategies that the results window may be
        // hiding or filtering.
        var pathCounts: [String: Int] = [:]
        for s in strategies {
            let key = "\(s.cloningPath)"
            pathCounts[key, default: 0] += 1
        }
        lastDiagnostic.append("Final strategies generated: \(strategies.count)")
        if !pathCounts.isEmpty {
            let breakdown = pathCounts.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")
            lastDiagnostic.append("  by cloning path: \(breakdown)")
        }
        
        // --- Drop degenerate two-enzyme strategies ---
        //
        // Isoschizomers that cut the same recognition sequence at different
        // offsets (ApaI GGGCC^C and Bsp120I G^GGCCC, for instance) can be paired
        // by the search as if they were two separate sites. They are not: both
        // land on the SAME site in the vector, four bases apart, and a single
        // site cannot be cut twice to give a backbone with two ends. The giveaway
        // is a "3' cut" that falls before the "5' cut".
        //
        // These were reaching the results as rows that quietly produced no
        // construct. Removing them here is better than filtering downstream,
        // because the strategy was never real.
        let usable = strategies.filter { st in
            guard st.enzyme3 != nil else { return true }   // single-cut: fine
            return st.vectorSite5Position != st.vectorSite3Position
        }
        return usable.sorted { $0.score > $1.score }
    }

    // =========================================================================
    // MARK: Build construct
    // =========================================================================
    
    func buildConstruct(
        strategy: CloningStrategy,
        vector: DNASequence,
        insertName: String,
        insertSequence: String
    ) -> DNASequence {
        
        let vectorSeq = vector.sequence.uppercased()
                // Apply truncation trim if this strategy cuts inside the insert ORF
                // to achieve an in-frame fusion junction. Both coords are forward-excerpt
                // offsets into insertSequence (position 0 = start of the padded insert).
                var insertSeq = insertSequence.uppercased()
                let _rawLen = insertSeq.count
                let _lo = strategy.insertTruncCut5 ?? 0
                let _hi = strategy.insertTruncCut3.map { min($0, _rawLen) } ?? _rawLen
                if _lo > 0 || _hi < _rawLen {
                    let _start = insertSeq.index(insertSeq.startIndex, offsetBy: _lo)
                    let _end   = insertSeq.index(insertSeq.startIndex, offsetBy: _hi)
                    insertSeq = String(insertSeq[_start..<_end])
                }
                let vecLen = vectorSeq.count
        
        let constructSequence: String
        let insertStartInConstruct: Int
        let backboneFeatures: [Feature]
        let constructIsCircular: Bool
        
        if strategy.isDirectional {
            let cut5 = strategy.vectorSite5Position + strategy.enzyme5.cutPosition5Prime
            let cut3 = strategy.vectorSite3Position + strategy.enzyme3!.cutPosition5Prime
            
            // Trim insert at the actual cut sites within the excerpt.
            // The excerpt may start before the flank cut (e.g. the NdeI site overlaps
            // the insert ATG, so the excerpt starts with CATATG but the actual cut
            // releases from position 2 onward — TATG). Without trimming, the vector's
            // CA prefix would be doubled in the construct.
            if let e5 = strategy.insertCut5Excerpt, e5 > 0, e5 < insertSeq.count {
                insertSeq = String(insertSeq.dropFirst(e5))
            }
            if let e3 = strategy.insertCut3Excerpt, e3 > 0, e3 < insertSeq.count {
                insertSeq = String(insertSeq.prefix(e3 - (strategy.insertCut5Excerpt ?? 0)))
            }
            
            if vector.isCircular {
                // prefix + insert + suffix preserves the vector origin
                constructSequence = String(vectorSeq.prefix(cut5))
                    + insertSeq + String(vectorSeq.suffix(vecLen - cut3))
                insertStartInConstruct = cut5
                constructIsCircular = true
            } else {
                constructSequence = String(vectorSeq.prefix(cut5))
                    + insertSeq + String(vectorSeq.suffix(vecLen - cut3))
                insertStartInConstruct = cut5
                constructIsCircular = false
            }
            
            backboneFeatures = remapFeatures(
                originalFeatures: vector.features, vectorLength: vecLen,
                cut5: cut5, cut3: cut3, insertLength: insertSeq.count,
                vectorIsCircular: vector.isCircular)
            
        } else {
            let cut = strategy.vectorSite5Position + strategy.enzyme5.cutPosition5Prime
            
            if vector.isCircular {
                // prefix + insert + suffix preserves the vector origin
                constructSequence = String(vectorSeq.prefix(cut))
                    + insertSeq + String(vectorSeq.suffix(vecLen - cut))
                insertStartInConstruct = cut
                constructIsCircular = true
            } else {
                constructSequence = String(vectorSeq.prefix(cut))
                    + insertSeq + String(vectorSeq.suffix(vecLen - cut))
                insertStartInConstruct = cut
                constructIsCircular = false
            }
            
            backboneFeatures = remapFeaturesLinearised(
                originalFeatures: vector.features, vectorLength: vecLen,
                cutPosition: cut, insertLength: insertSeq.count,
                vectorIsCircular: vector.isCircular)
        }
        
        let enzName5 = strategy.enzyme5.name
        let enzName3 = strategy.enzyme3?.name ?? enzName5
        let rcNote = strategy.insertReversed ? " [RC]" : ""
        let pathNote = strategy.cloningPath.isDirectDigest ? "" : " (PCR)"
        let partialNote = strategy.partialDigest != .none ? " [partial]" : ""
        let compatNote = strategy.usesCompatibleEnds ? " [compat]" : ""
                let constructName = "\(insertName)\(rcNote) in \(vector.name) (\(enzName5) and \(enzName3))\(pathNote)\(partialNote)\(compatNote)"
        
        let construct = DNASequence(name: constructName, sequence: constructSequence, isCircular: constructIsCircular)
        // Populate Comments panel with cloning details
        var descLines: [String] = []
        descLines.append("Construct: \(constructName)")
        descLines.append("Vector: \(vector.name) (\(vector.sequence.count) bp, \(vector.isCircular ? "circular" : "linear"))")
        descLines.append("Insert: \(insertName) (\(insertSeq.count) bp)")
        descLines.append("Vector enzymes: \(enzName5) (5') / \(enzName3) (3')")
        if strategy.usesCompatibleEnds {
            let iE5 = strategy.effectiveInsertEnzyme5.name
            let iE3 = strategy.effectiveInsertEnzyme3.name
            descLines.append("Insert enzymes: \(iE5) (5') / \(iE3) (3') - compatible ends")
        }
        descLines.append("Backbone: \(strategy.backboneSize) bp, Insert fragment: \(strategy.insertSize) bp")
        if strategy.insertReversed { descLines.append("Insert orientation: reversed") }
        descLines.append("Cloning path: \(strategy.cloningPath.label)")
        if strategy.partialDigest != .none { descLines.append(strategy.partialDigest.label) }
        if let frameLabel = strategy.frameAnalysis?.label { descLines.append("Frame: \(frameLabel)") }
        if !strategy.warnings.isEmpty { descLines.append("Warnings: \(strategy.warnings.joined(separator: "; "))") }
        descLines.append("Strategy score: \(strategy.score)")
        descLines.append("Total construct: \(constructSequence.count) bp")
        construct.description = descLines.joined(separator: "\n")
        
        construct.features = backboneFeatures
        
        let insertEnd = insertStartInConstruct + insertSeq.count - 1
        let insertLabel = strategy.insertReversed ? "\(insertName) (RC)" : insertName
        let insertStrand: Strand = strategy.insertReversed ? .reverse : .forward
        construct.features.append(Feature(
            name: insertLabel, type: .gene,
            start: insertStartInConstruct, end: insertEnd,
            strand: insertStrand,
            color: CodableColor(red: 0.2, green: 0.6, blue: 0.9)))
        
        construct.features.append(Feature(
            name: "\(enzName5) junction", type: .custom,
            start: max(0, insertStartInConstruct - 1), end: insertStartInConstruct,
            strand: .forward,
            color: CodableColor(red: 1.0, green: 0.4, blue: 0.0), showArrow: false))
        
        construct.features.append(Feature(
            name: "\(enzName3) junction", type: .custom,
            start: insertEnd, end: min(constructSequence.count - 1, insertEnd + 1),
            strand: .forward,
            color: CodableColor(red: 1.0, green: 0.4, blue: 0.0), showArrow: false))
        
        return construct
    }

    // =========================================================================
    // MARK: Feature remapping
    // =========================================================================
    
    private func remapFeatures(
        originalFeatures: [Feature], vectorLength: Int,
        cut5: Int, cut3: Int, insertLength: Int, vectorIsCircular: Bool
    ) -> [Feature] {
        var result: [Feature] = []
        let shift = insertLength - (cut3 - cut5)
        for feature in originalFeatures {
            // Skip features in the excised stuffer region
            if feature.start >= cut5 && feature.end < cut3 { continue }
            // Features before the 5' cut — unchanged position
            if feature.end < cut5 {
                result.append(feature)
            }
            // Features after the 3' cut — shift by insert size minus stuffer
            else if feature.start >= cut3 {
                var f = feature; f.start += shift; f.end += shift; result.append(f)
            }
        }
        return result
    }
    
    private func remapFeaturesLinearised(
        originalFeatures: [Feature], vectorLength: Int,
        cutPosition: Int, insertLength: Int, vectorIsCircular: Bool
    ) -> [Feature] {
        var result: [Feature] = []
        for feature in originalFeatures {
            // Features before the cut — unchanged position
            if feature.end < cutPosition {
                result.append(feature)
            }
            // Features after the cut — shift by insert length
            else if feature.start >= cutPosition {
                var f = feature; f.start += insertLength; f.end += insertLength; result.append(f)
            }
        }
        return result
    }

    // =========================================================================
    // MARK: Helpers
    // =========================================================================
    
    /// Delegates to the canonical implementation on RestrictionEnzyme, which
    /// also excludes Type IIS enzymes — their overhangs depend on the target
    /// sequence, so two of them are not compatible in the abstract. The old
    /// inline version compared two empty strings and said "yes".
    func endsAreCompatible(_ e1: RestrictionEnzyme, _ e2: RestrictionEnzyme) -> Bool {
        e1.producesEndsCompatible(with: e2)
    }
    
    /// Check whether the segment that would be excised (between the two cut sites)
    /// overlaps with any protected region. For directional cloning, the excised segment
    /// is the region between upSite and dnSite — this gets discarded and replaced by the insert.
    /// If a protected feature falls in that segment, the strategy would destroy it.
    func excisedSegmentOverlapsProtected(
        upPos: Int, dnPos: Int, protectedRegions: [ClosedRange<Int>]
    ) -> Bool {
        guard !protectedRegions.isEmpty else { return false }
        let excised = upPos...dnPos
        return protectedRegions.contains { $0.overlaps(excised) }
    }
    
    /// Append human-readable warnings to a strategy's warning list when
    /// the frame analyzer auto-adjusted a junction offset. Called from every
    /// strategy-construction block so the user sees why the frame check is
    /// showing "in frame" despite the default offsets being mathematically
    /// out-of-frame.
    private func appendAutoAlignWarnings(_ warnings: inout [String], frame: FrameAnalysis?) {
        guard let frame = frame else { return }
        if let auto5 = frame.fiveprimeAutoOffset {
            warnings.append("5' junction frame auto-aligned for fusion (vector offset = \(auto5))")
        }
        if let auto3 = frame.threeprimeAutoOffset {
            warnings.append("3' junction frame auto-aligned for fusion (vector offset = \(auto3))")
        }
    }
    
    /// Returns true if there is an in-frame stop codon in `sequence[from..<to]`.
    /// Used for blunt-mediated fusion validation: checks that no stop codon sits
    /// between the blunted insert boundary and the fusion ORF's ATG.
    /// `frame` is the reading-frame offset at `from` (bases to skip to reach the
    /// first codon boundary). For a blunt junction this is always 0.
    nonisolated static func hasInFrameStopCodon(in sequence: String, from: Int, to: Int, frame: Int) -> Bool {
        guard to > from, from >= 0, to <= sequence.count else { return false }
        let start = from + frame
        guard start >= 0, start + 3 <= to else { return false }
        let stops: Set<String> = ["TAA", "TAG", "TGA"]
        let lo = sequence.index(sequence.startIndex, offsetBy: start)
        let hi = sequence.index(sequence.startIndex, offsetBy: to)
        let window = Array(sequence[lo..<hi].uppercased())
        var i = 0
        while i + 3 <= window.count {
            if stops.contains(String(window[i ..< i + 3])) { return true }
            i += 3
        }
        return false
    }

    func analyzeFrame(
        enzyme5: RestrictionEnzyme, enzyme3: RestrictionEnzyme,
        mode: CloningMode, fiveprimeFrame: JunctionFrame?, threeprimeFrame: JunctionFrame?,
        autoAlign5Prime: Bool = false, autoAlign3Prime: Bool = false,
        needsPrimers: Bool = false
    ) -> FrameAnalysis? {
        guard mode != .simpleInsertion else { return nil }
        let overhang5 = abs(enzyme5.cutPosition5Prime - enzyme5.cutPosition3Prime)
        let overhang3 = abs(enzyme3.cutPosition5Prime - enzyme3.cutPosition3Prime)
        
        // 5' junction check with optional auto-alignment.
        //
        // Auto-align only fires when the user left `vectorOffset` at its
        // default of 0 (i.e. they haven't manually tuned the junction).
        // Auto-align is only valid for PCR-based strategies where extra bases
        // can be added in the primer to achieve the right reading frame.
        // For direct digest strategies the vector reading frame is fixed —
        // auto-align would always find a passing offset and hide real
        // out-of-frame junctions. So it is gated on needsPrimers.
        var check5: Bool? = nil
        var auto5: Int? = nil
        if (mode == .fusionNTerminal || mode == .fusionBoth), let f5 = fiveprimeFrame {
            let native5 = (f5.vectorOffset + overhang5 + f5.insertOffset) % 3 == 0
            if native5 {
                check5 = true
            } else if autoAlign5Prime && needsPrimers && f5.vectorOffset == 0 {
                for v in 0...2 where (v + overhang5 + f5.insertOffset) % 3 == 0 {
                    auto5 = v
                    check5 = true
                    break
                }
                if auto5 == nil { check5 = false }
            } else {
                check5 = false
            }
        }
        
        // 3' junction check with optional auto-alignment.
        var check3: Bool? = nil
        var auto3: Int? = nil
        if (mode == .fusionCTerminal || mode == .fusionBoth), let f3 = threeprimeFrame {
            let native3 = (f3.insertOffset + overhang3 + f3.vectorOffset) % 3 == 0
            if native3 {
                check3 = true
            } else if autoAlign3Prime && needsPrimers && f3.vectorOffset == 0 {
                for v in 0...2 where (f3.insertOffset + overhang3 + v) % 3 == 0 {
                    auto3 = v
                    check3 = true
                    break
                }
                if auto3 == nil { check3 = false }
            } else {
                check3 = false
            }
        }
        
        return FrameAnalysis(
            fiveprimeInFrame: check5,
            threeprimeInFrame: check3,
            fiveprimeAutoOffset: auto5,
            threeprimeAutoOffset: auto3
        )
    }
    
    /// Tier-based scoring.  Each tier has a 30-point gap so within-tier
    /// penalties (warnings, frame, internal cutters) cannot cross boundaries.
    ///
    ///  Tier 1  (230) — Sticky-end directional, direct digest
    ///  Tier 2  (200) — One sticky + one blunt, directional, direct digest
    ///  Tier 3  (170) — Partial digest, directional
    ///  Tier 3b (155) — Partial digest, non-directional
    ///  Tier 4  (140) — Single enzyme, non-directional (sticky)
    ///  Tier 5  (110) — Both blunt, non-directional (incl. blunt insert direct)
    ///  Tier 6  ( 50) — PCR one primer
    ///  Tier 7  ( 20) — PCR both primers
    ///
    /// Shuttle vector routes are scored separately in ShuttleVectorPathfinder.
    func computeScore(
        isDirectional: Bool, internalCutters: [String], frameAnalysis: FrameAnalysis?,
        warningCount: Int, totalVectorCuts5: Int, totalVectorCuts3: Int?,
        path: CloningPath, isPartial: Bool = false,
        enzyme5IsBlunt: Bool = false, enzyme3IsBlunt: Bool = false,
        codingBasesLost: Int = 0, isFusion: Bool = false
    ) -> Int {
        var score: Int
        
        if case .bluntedInsert = path {
            // Below clean blunt-insert (110): needs an extra enzymatic blunting
            // step, destroys the recognition sites, and is non-directional.
            score = 95
        } else if path.needsPrimers {
            // --- Tier 6–7: PCR approaches ---
            switch path {
            case .onePrimerForward, .onePrimerReverse: score = 50
            default:                                    score = 20  // pcrRequired
            }
        } else if isPartial {
            // --- Tier 3 / 3b: Partial digest ---
            score = isDirectional ? 170 : 155
        } else if isDirectional {
            let bothSticky = !enzyme5IsBlunt && !enzyme3IsBlunt
            if bothSticky {
                // --- Tier 1: Sticky directional ---
                score = 230
            } else {
                // --- Tier 2: One sticky + one blunt directional ---
                score = 200
            }
        } else {
            // --- Non-directional single enzyme ---
            if enzyme5IsBlunt {
                // --- Tier 5: Both blunt non-directional ---
                score = 110
            } else {
                // --- Tier 4: Sticky non-directional ---
                score = 140
            }
        }
        
        // --- Within-tier modifiers (max swing ~25 pts, well inside 30-pt gaps) ---
        score -= internalCutters.count * 12
        if let fa = frameAnalysis {
            if fa.allInFrame { score += 8 }
            if fa.fiveprimeInFrame == false { score -= 6 }
            if fa.threeprimeInFrame == false { score -= 6 }
        }
        if totalVectorCuts5 == 1 { score += 4 }
        if totalVectorCuts5 > 1 { score -= (totalVectorCuts5 - 1) * 6 }
        if let cuts3 = totalVectorCuts3 {
            if cuts3 == 1 { score += 4 }
            if cuts3 > 1 { score -= (cuts3 - 1) * 6 }
        }
        score -= warningCount * 2

        // --- Fusion native-sequence retention (fusion modes only) ---
        // A fusion strategy that cuts INTO the ORF discards native coding
        // sequence at the junction. Penalise proportionally to codons lost so
        // that, within a fusion analysis, a strategy retaining the full native
        // terminus ranks above one that chews into the protein — even when the
        // truncating strategy uses a more convenient sticky end.
        //
        // This penalty is deliberately allowed to cross tier boundaries (unlike
        // the other within-tier modifiers): a sticky cutter that removes coding
        // sequence SHOULD be able to fall below a clean blunt-mediated strategy
        // that keeps everything. The penalty is zero when nothing is lost, so
        // non-truncating strategies are never affected.
        if isFusion && codingBasesLost > 0 {
            let codonsLost = (codingBasesLost + 2) / 3   // round up partial codons
            score -= codonsLost * 25
        }

        // --- Fusion frame failure (fusion modes only) ---
        // In a fusion, an out-of-frame junction is not a drawback to weigh up
        // against convenience — it means the construct does not make the fusion
        // protein at all. The old within-tier penalty of 6 points left a slick
        // out-of-frame direct digest (score ~85-230) ranked above a working
        // in-frame PCR strategy (20-50), which is exactly backwards for the job
        // the user is trying to do. This penalty deliberately crosses every tier
        // boundary so that ANY in-frame strategy outranks ANY out-of-frame one.
        if isFusion, let fa = frameAnalysis, !fa.allInFrame {
            score -= 250
        }

        return score
    }

    // MARK: - Predicted fusion protein

    /// The blunted insert fragment for a fill-in / nibble-back strategy, taken
    /// from the SOURCE sequence at the boundaries the strategy recorded. Mirrors
    /// bluntedInsertFragment in the strategy views, which is what Build uses, so
    /// the predicted protein describes the construct Build would make.
    nonisolated static func bluntedFragment(
        insertCut5Source: Int?, insertCut3Source: Int?,
        sourceSequence: String, sourceIsCircular: Bool, reversed: Bool
    ) -> String? {
        guard let left = insertCut5Source, let right = insertCut3Source else { return nil }
        let src = Array(sourceSequence.uppercased())
        let n = src.count
        guard n > 0 else { return nil }
        func norm(_ i: Int) -> Int { (((i % n) + n) % n) }
        let forward: String
        if right > left && left >= 0 && right <= n {
            forward = String(src[left..<right])
        } else if sourceIsCircular {
            let l = norm(left); let r = norm(right)
            forward = String(src[l..<n]) + String(src[0..<r])
        } else {
            return nil
        }
        guard !forward.isEmpty else { return nil }
        return reversed ? String(forward.reversed().map { c -> Character in
            switch c { case "A": return "T"; case "T": return "A"
                       case "G": return "C"; case "C": return "G"
                       default: return c }
        }) : forward
    }

    /// Works out how long the fusion protein would be for one strategy.
    ///
    /// Uses the SAME splice arithmetic as buildConstruct — vector prefix up to
    /// the 5' cut, then the insert, then the vector from the 3' cut on — so the
    /// number describes the construct the Build button would actually make.
    ///
    /// Returns nil whenever the answer is not certain: no tag, the tag sits in
    /// the stretch of vector being cut out, no start codon upstream of the tag,
    /// or translation runs off the end without a stop. A missing number is
    /// honest; a wrong one would send someone to the bench.
    func predictedFusionAA(
        strategy: CloningStrategy,
        vectorSequence: String,
        vectorIsCircular: Bool,
        insertSequence: String,
        tagStartInVector: Int,
        sourceSequence: String = "",
        sourceIsCircular: Bool = false,
        orfStartInInsert: Int? = nil
    ) -> Int? {
        // Blunt-mediated strategies build from a separately derived blunted
        // fragment rather than from the extracted insert region, so use the same
        // fragment Build would use. Without it there is nothing to splice.
        var insertSequence = insertSequence
        // PCR routes: the fragment that gets ligated is the PCR product, which
        // does not exist yet. The insert region handed to us carries ~200 bp of
        // flanking sequence on each side so that nearby cut sites can be found —
        // splicing all of that in would put 200 bases of untranslated flank
        // between the tag and the coding sequence, which runs into a stop almost
        // at once and predicts a fusion protein a few residues long. That is an
        // artefact of the padding, not of the strategy.
        //
        // What the primer designer will actually do is put the forward primer at
        // the start of the chosen reading frame, so model that: begin the insert
        // at the ORF start. Reversed inserts are left out, because the ORF start
        // is recorded in the forward frame and mapping it is a separate job.
        if strategy.cloningPath.needsPrimers {
            // A PCR route has no cut in the insert: the primer carries the
            // restriction site, and after digestion the site is split between
            // the two partners. The vector keeps the bases before its cut; the
            // PCR product carries the rest. Leaving those out shifts the whole
            // insert by up to two bases and translation stops just past the tag
            // — which is what "33 aa" was.
            //
            // Verified against pET-28a + the PM19 fragment: vector + ORF alone
            // gives 64 aa, while vector + the 5 bases of BamHI the product
            // carries + ORF gives 205 aa, which is the tag, a GS from the site,
            // and the 171 aa ORF.
            // The caller is responsible for handing us an insert sequence and an
            // ORF start that are in the SAME coordinate frame. It knows whether
            // the whole insert was flipped for the fusion and whether this
            // particular strategy flips it again, so it does the conversion.
            guard let orfStart = orfStartInInsert else { return nil }
            guard orfStart >= 0, orfStart < insertSequence.count else { return nil }

            let iEnz = strategy.effectiveInsertEnzyme5
            let siteRemainder = max(0, iEnz.recognitionSite.count - iEnz.cutPosition5Prime)
            let carried = String(iEnz.recognitionSite.suffix(siteRemainder))

            // Spare bases the primer adds to set the reading frame, when the
            // junction does not come out in frame by itself. Zero when it does.
            let pad = strategy.frameAnalysis?.fiveprimeAutoOffset ?? 0
            let filler = String(repeating: "G", count: pad)

            insertSequence = carried + filler + String(insertSequence.dropFirst(orfStart))
        }
        if case .bluntedInsert = strategy.cloningPath {
            guard let frag = Self.bluntedFragment(
                insertCut5Source: strategy.insertCut5Source,
                insertCut3Source: strategy.insertCut3Source,
                sourceSequence: sourceSequence,
                sourceIsCircular: sourceIsCircular,
                reversed: strategy.insertReversed)
            else { return nil }
            insertSequence = frag
        }

        let vectorSeq = vectorSequence.uppercased()
        let vecLen = vectorSeq.count

        // Same insert trimming as buildConstruct.
        var insertSeq = insertSequence.uppercased()
        let rawLen = insertSeq.count
        let lo = strategy.insertTruncCut5 ?? 0
        let hi = strategy.insertTruncCut3.map { min($0, rawLen) } ?? rawLen
        if lo > 0 || hi < rawLen, lo < hi, hi <= insertSeq.count {
            let a = insertSeq.index(insertSeq.startIndex, offsetBy: lo)
            let b = insertSeq.index(insertSeq.startIndex, offsetBy: hi)
            insertSeq = String(insertSeq[a..<b])
        }

        let cut5: Int
        let cut3: Int
        if strategy.isDirectional, let e3 = strategy.enzyme3 {
            cut5 = strategy.vectorSite5Position + strategy.enzyme5.cutPosition5Prime
            cut3 = strategy.vectorSite3Position + e3.cutPosition5Prime
            if let e5x = strategy.insertCut5Excerpt, e5x > 0, e5x < insertSeq.count {
                insertSeq = String(insertSeq.dropFirst(e5x))
            }
            if let e3x = strategy.insertCut3Excerpt, e3x > 0,
               e3x - (strategy.insertCut5Excerpt ?? 0) > 0,
               e3x - (strategy.insertCut5Excerpt ?? 0) <= insertSeq.count {
                insertSeq = String(insertSeq.prefix(e3x - (strategy.insertCut5Excerpt ?? 0)))
            }
        } else {
            cut5 = strategy.vectorSite5Position + strategy.enzyme5.cutPosition5Prime
            cut3 = cut5
        }
        guard cut5 >= 0, cut3 >= cut5, cut3 <= vecLen else { return nil }

        let constructSeq = String(vectorSeq.prefix(cut5)) + insertSeq + String(vectorSeq.suffix(vecLen - cut3))
        let insertLen = insertSeq.count

        // Where does the tag land in the construct?
        let tagInConstruct: Int
        if tagStartInVector < cut5 {
            tagInConstruct = tagStartInVector          // upstream piece is untouched
        } else if tagStartInVector >= cut3 {
            tagInConstruct = tagStartInVector - (cut3 - cut5) + insertLen
        } else {
            return nil
        }
        guard tagInConstruct >= 0, tagInConstruct < constructSeq.count else { return nil }

        guard let initiator = Self.fusionInitiator(in: constructSeq, tagStart: tagInConstruct) else { return nil }
        return Self.aaUntilStop(in: constructSeq, from: initiator, wrapCircular: vectorIsCircular)
    }


    nonisolated static let stopCodons: Set<String> = ["TAA", "TAG", "TGA"]

    /// Translates `seq` from `start` until the first stop codon and returns the
    /// number of amino acids before it. Returns nil if no stop is reached, so a
    /// run off the end of a linear sequence is reported as "unknown" rather than
    /// as a length.
    nonisolated static func aaUntilStop(in seq: String, from start: Int, wrapCircular: Bool) -> Int? {
        let chars = Array(seq.uppercased())
        guard start >= 0, start < chars.count else { return nil }
        let limit = wrapCircular ? chars.count : chars.count - start
        var i = start
        var aa = 0
        var consumed = 0
        while consumed + 3 <= limit {
            let idx = wrapCircular ? (i % chars.count) : i
            guard idx + 3 <= chars.count || wrapCircular else { break }
            let c0 = chars[idx % chars.count]
            let c1 = chars[(idx + 1) % chars.count]
            let c2 = chars[(idx + 2) % chars.count]
            if stopCodons.contains(String([c0, c1, c2])) { return aa }
            aa += 1
            i += 3
            consumed += 3
        }
        return nil
    }

    /// Finds the start codon that begins the tagged protein: the nearest ATG
    /// upstream of the tag from which translation reaches the tag without
    /// meeting a stop codon.
    ///
    /// Note what is NOT required: that the ATG be in the same reading frame as
    /// the tag feature's annotated first base. A feature's boundaries are drawn
    /// by whoever annotated the file and need not sit on a codon boundary — in
    /// pET-28a the 6xHis feature begins 10 bases after the initiator, which is
    /// not a multiple of three. Requiring the annotated frame made this search
    /// step straight past the real start codon and find nothing at all. What
    /// matters is that translation from the ATG runs into the tag uninterrupted,
    /// so that is what is checked.
    nonisolated static func fusionInitiator(in seq: String, tagStart: Int, maxLookback: Int = 400) -> Int? {
        let chars = Array(seq.uppercased())
        guard tagStart >= 0, tagStart < chars.count else { return nil }
        let lowest = max(0, tagStart - maxLookback)
        var i = tagStart
        while i >= lowest {
            if i + 3 <= chars.count, chars[i] == "A", chars[i + 1] == "T", chars[i + 2] == "G" {
                // Translate forward from this ATG and make sure nothing stops
                // it before it reaches the tag.
                var j = i
                var clean = true
                while j + 3 <= tagStart {
                    if stopCodons.contains(String([chars[j], chars[j + 1], chars[j + 2]])) {
                        clean = false
                        break
                    }
                    j += 3
                }
                if clean { return i }     // nearest one wins
            }
            i -= 1
        }
        return nil
    }

    /// A plain-language word for a strategy score.
    ///
    /// Every strategy that reaches the list is one that should work — anything
    /// that would not give the intended construct is filtered out before this
    /// point (out-of-frame fusion junctions, for instance). So the score is not
    /// a judgement on the experiment; it ranks what the experiment COSTS:
    /// time, hands-on steps, reagents and the number of things that can go
    /// wrong. The wording reflects that, so a low score reads as "this takes
    /// more doing", never as "this is a worse experiment".
    ///
    /// Bands follow the 30-point tier gaps in computeScore, with a little room
    /// either side for the within-tier modifiers.
    nonisolated static func scoreLabel(_ score: Int) -> String {
        switch score {
        case 185...:    return "Simplest"
        case 140..<185: return "Simple"
        case 95..<140:  return "Moderate"
        case 45..<95:   return "More involved"
        default:        return "Most involved"
        }
    }

    /// Score penalty for methylation issues in a strategy's warning list.
    /// "Blocked" is a hard practical problem (-15); "requires methylation" is
    /// also significant since it means the enzyme won't work without a Dam+ host (-10).
    /// Call after computing all warnings, add to score (value is negative).
    static func methylationScorePenalty(warnings: [String]) -> Int {
        var penalty = 0
        for w in warnings {
            let wl = w.lowercased()
            if wl.contains("blocked by") { penalty += 15 }
            else if wl.contains("requires dam methylation") { penalty += 10 }
            else if wl.contains("may be blocked") { penalty += 5 }
        }
        return -penalty
    }

    /// Check whether a specific cut site in the actual sequence is affected by
    /// active methylation settings. Returns warnings only when the methylation
    /// motif actually overlaps the recognition site at that position.
    ///
    /// Pass a non-nil `methylation` to respect the user's active Dam/Dcm/CpG
    /// toggles; the default (.none) reproduces the old always-on behaviour for
    /// backward-compatible call sites that don't pass methylation context.
    ///
    /// Also detects enzymes that REQUIRE methylation to cut (e.g. DpnI).
    /// Returns an empty array when neither the active flags nor the enzyme's
    /// sensitivity profile indicate any issue.
    func contextMethylationWarnings(
        enzyme: RestrictionEnzyme,
        sitePosition: Int,
        sequence: String,
        methylation: MethylationContext = .none
    ) -> [String] {
        let sens = enzyme.methylationSensitivity
        guard !sens.isEmpty else { return [] }

        let checkDam = methylation.anyActive ? methylation.activeDam : true
        let checkDcm = methylation.anyActive ? methylation.activeDcm : true
        let checkCpG = methylation.anyActive ? methylation.activeCpG : true

        let seq = sequence.uppercased()
        let seqLen = seq.count
        let siteLen = enzyme.recognitionSite.replacingOccurrences(of: "^", with: "").count
        let sensLower = sens.lowercased()

        // Extract recognition site footprint for CpG check
        let siteEnd = min(seqLen, sitePosition + siteLen)
        let siteStartIdx = seq.index(seq.startIndex, offsetBy: sitePosition)
        let siteEndIdx   = seq.index(seq.startIndex, offsetBy: siteEnd)
        let siteSequence = String(seq[siteStartIdx..<siteEndIdx])

        var warnings: [String] = []

        // ── Requires methylation to cut (e.g. DpnI needs Dam-methylated GATC) ──
        if sensLower.contains("requires") || sensLower.contains("only cut") || sensLower.contains("only cleave") {
            warnings.append("\(enzyme.name): requires Dam methylation to cut — will not work on unmethylated DNA")
            return warnings   // no "blocked" check needed — opposite situation
        }

        // ── Dam (GATC, 4 bp) ──
        if checkDam && sensLower.contains("dam") {
            let damStart = max(0, sitePosition - 3)
            let damEnd   = min(seqLen, sitePosition + siteLen)
            if damStart < damEnd {
                let s = seq.index(seq.startIndex, offsetBy: damStart)
                let e = seq.index(seq.startIndex, offsetBy: damEnd)
                if String(seq[s..<e]).contains("GATC") {
                    warnings.append("\(enzyme.name): blocked by Dam methylation (GATC) at position \(sitePosition + 1)")
                }
            }
        }

        // ── Dcm (CCWGG = CCAGG or CCTGG, 5 bp) ──
        if checkDcm && sensLower.contains("dcm") {
            let dcmStart = max(0, sitePosition - 4)
            let dcmEnd   = min(seqLen, sitePosition + siteLen)
            if dcmStart < dcmEnd {
                let s = seq.index(seq.startIndex, offsetBy: dcmStart)
                let e = seq.index(seq.startIndex, offsetBy: dcmEnd)
                let zone = String(seq[s..<e])
                if zone.contains("CCAGG") || zone.contains("CCTGG") {
                    warnings.append("\(enzyme.name): blocked by Dcm methylation (CCWGG) at position \(sitePosition + 1)")
                }
            }
        }

        // ── CpG ──
        if checkCpG && sensLower.contains("cpg") && siteSequence.contains("CG") {
            warnings.append("\(enzyme.name): may be blocked by CpG methylation at position \(sitePosition + 1)")
        }

        return warnings
    }

    // =========================================================================
    // MARK: Protocol export
    // =========================================================================
    
    func generateProtocol(strategy: CloningStrategy, vectorName: String, insertName: String, sourceName: String) -> String {
        let enz5 = strategy.enzyme5
        let enz3 = strategy.enzyme3 ?? enz5
        let isDirectional = strategy.isDirectional
        let vectorEnzNames = isDirectional ? "\(enz5.name) and \(enz3.name)" : enz5.name
        
        // Insert enzyme names (may differ from vector if using compatible ends)
        let iEnz5 = strategy.effectiveInsertEnzyme5
        let iEnz3 = strategy.effectiveInsertEnzyme3
        let insertEnzNames = isDirectional ? "\(iEnz5.name) and \(iEnz3.name)" : iEnz5.name
        
        var lines: [String] = []
        
        lines.append("CLONING PROTOCOL")
        lines.append("================")
        lines.append("")
        lines.append("Goal: Clone \(insertName)\(strategy.insertReversed ? " (reverse complement)" : "") into \(vectorName)")
        lines.append("Insert source: \(sourceName)")
        lines.append("Strategy: \(strategy.cloningPath.label)")
        lines.append("Vector enzymes: \(vectorEnzNames)")
        if strategy.usesCompatibleEnds {
            lines.append("Insert enzymes: \(insertEnzNames) (compatible cohesive ends)")
        }
        if strategy.partialDigest != .none {
            lines.append("Partial digest: \(strategy.partialDigest.label)")
        }
        lines.append("Directionality: \(isDirectional ? "Directional" : "Non-directional")")
        lines.append("")
        
        // Fragment sizes
        lines.append("EXPECTED FRAGMENTS")
        lines.append("------------------")
        lines.append("Backbone (vector):  \(formatBP(strategy.backboneSize))")
        if strategy.excisedSize > 0 {
            lines.append("Stuffer (excised):  \(formatBP(strategy.excisedSize))")
        }
        lines.append("Insert:             \(formatBP(strategy.insertSize))")
        let constructSize = strategy.backboneSize + strategy.insertSize
        lines.append("Final construct:    ~\(formatBP(constructSize))")
        
        let sizeRatio = Double(min(strategy.backboneSize, strategy.insertSize)) / Double(max(strategy.backboneSize, strategy.insertSize))
        if sizeRatio > 0.8 {
            lines.append("⚠ Backbone and insert are similar in size — may be difficult to resolve on gel.")
        }
        lines.append("")
        
        // Step 1: Vector digest
        lines.append("STEP 1 — VECTOR DIGEST")
        lines.append("----------------------")
        if strategy.partialDigest == .vector {
            if isDirectional {
                lines.append("PARTIAL digest of \(vectorName) with \(enz5.name) and \(enz3.name).")
                lines.append("  - Perform a partial digest for the enzyme with 2 vector sites")
                lines.append("  - Gel purify the correctly linearised backbone band (\(formatBP(strategy.backboneSize)))")
            } else {
                lines.append("PARTIAL digest of \(vectorName) with \(enz5.name).")
                lines.append("  - \(enz5.name) has 2 sites — use short digestion time or reduced enzyme")
                lines.append("  - Gel purify the linearised (uncut-once) band (\(formatBP(strategy.backboneSize)))")
            }
            lines.append("  - Use compatible buffer (check manufacturer recommendations)")
        } else if isDirectional {
            lines.append("Digest \(vectorName) with \(enz5.name) and \(enz3.name).")
            lines.append("  - Use compatible buffer (check manufacturer recommendations)")
            lines.append("  - If enzymes require different buffers, perform sequential digests")
        } else {
            lines.append("Digest \(vectorName) with \(enz5.name).")
        }
        lines.append("  - Incubate at 37°C for 1–2 hours")
        lines.append("  - Gel purify the backbone band (\(formatBP(strategy.backboneSize)))")
        if !isDirectional {
            lines.append("  - IMPORTANT: Dephosphorylate the linearised vector (e.g. CIP/SAP)")
            lines.append("    to reduce self-ligation background")
        }
        lines.append("")
        
        // Step 2: Insert preparation
        lines.append("STEP 2 — INSERT PREPARATION")
        lines.append("---------------------------")
        if strategy.partialDigest == .insert {
            lines.append("PARTIAL digest of source DNA with \(insertEnzNames) to release the insert.")
            lines.append("  - One enzyme has an internal site — use partial digest conditions")
            lines.append("    (reduced time or enzyme concentration) so the internal site is not cut")
            lines.append("  - Gel purify the full-length insert band (\(formatBP(strategy.insertSize)))")
            lines.append("  - A smaller fragment from complete digestion will also be visible — avoid it")
        } else {
        switch strategy.cloningPath {
        case .directDigest:
            lines.append("Digest the source DNA with \(insertEnzNames) to release the insert.")
            lines.append("  - Incubate at 37°C for 1–2 hours")
            lines.append("  - Gel purify the insert band (\(formatBP(strategy.insertSize)))")
        case .bluntInsertDirect:
            lines.append("Insert is a blunt-ended fragment — no digestion needed.")
            lines.append("  - Gel purify if necessary (\(formatBP(strategy.insertSize)))")
        case .bluntedInsert:
            let relEnz = (iEnz5.name == iEnz3.name) ? iEnz5.name : "\(iEnz5.name) and \(iEnz3.name)"
            lines.append("Digest the source DNA with \(relEnz) to release the insert.")
            lines.append("  - Incubate at 37°C for 1–2 hours, then gel purify (\(formatBP(strategy.insertSize)))")
            if let m = strategy.insert5Blunting {
                lines.append("  - 5' end (\(iEnz5.name)): \(m.enzymeDescription)")
            }
            if let m = strategy.insert3Blunting {
                lines.append("  - 3' end (\(iEnz3.name)): \(m.enzymeDescription)")
            }
            lines.append("  - Clean up the blunted fragment before ligation")
            lines.append("  - NOTE: the \(relEnz) site(s) are destroyed — not regenerated in the construct")
        case .onePrimerForward:
            lines.append("PCR amplify the insert:")
            lines.append("  - Forward primer: add \(iEnz5.name) site + 2–4 nt padding at 5' end")
            lines.append("  - Reverse primer: binds insert 3' end (flanking \(iEnz3.name) site exists in source)")
            lines.append("  - After PCR, digest product with \(insertEnzNames)")
            lines.append("  - Gel purify the insert band (\(formatBP(strategy.insertSize)))")
        case .onePrimerReverse:
            lines.append("PCR amplify the insert:")
            lines.append("  - Forward primer: binds insert 5' end (flanking \(iEnz5.name) site exists in source)")
            lines.append("  - Reverse primer: add \(iEnz3.name) site + 2–4 nt padding at 5' end")
            lines.append("  - After PCR, digest product with \(insertEnzNames)")
            lines.append("  - Gel purify the insert band (\(formatBP(strategy.insertSize)))")
        case .pcrRequired:
            lines.append("PCR amplify the insert:")
            lines.append("  - Forward primer: add \(iEnz5.name) site + 2–4 nt padding at 5' end")
            lines.append("  - Reverse primer: add \(iEnz3.name) site + 2–4 nt padding at 5' end")
            lines.append("  - After PCR, digest product with \(insertEnzNames)")
            lines.append("  - Gel purify the digested insert (\(formatBP(strategy.insertSize)))")
        }
        }
        lines.append("")
        
        // Step 3: Ligation
        lines.append("STEP 3 — LIGATION")
        lines.append("------------------")
        lines.append("Ligate the purified backbone and insert:")
        lines.append("  - Use T4 DNA ligase")
        lines.append("  - Molar ratio: ~1:3 (vector:insert) for cohesive ends, ~1:1 for blunt")
        lines.append("  - Incubate at 16°C overnight, or room temperature for 1–2 hours")
        if !isDirectional {
            lines.append("  - Include a vector-only control (no insert) to assess self-ligation background")
        }
        if strategy.usesCompatibleEnds {
            lines.append("  - NOTE: Compatible-end ligation — junction(s) may not be recleavable by either enzyme")
        }
        lines.append("")
        lines.append("STEP 4 — TRANSFORMATION")
        lines.append("-----------------------")
        lines.append("Transform competent cells with the ligation reaction.")
        lines.append("  - Use appropriate antibiotic selection")
        lines.append("  - Screen colonies by restriction digest or colony PCR")
        if !isDirectional {
            lines.append("  - Non-directional cloning: check insert orientation by diagnostic digest or sequencing")
        }
        lines.append("")
        
        // Warnings
        if !strategy.warnings.isEmpty {
            lines.append("NOTES & WARNINGS")
            lines.append("-----------------")
            for w in strategy.warnings {
                lines.append("• \(w)")
            }
            lines.append("")
        }
        
        // Frame analysis
        if let fa = strategy.frameAnalysis, let label = fa.label {
            lines.append("READING FRAME")
            lines.append("--------------")
            lines.append(label)
            lines.append("")
        }
        
        return lines.joined(separator: "\n")
    }
    
    private func formatBP(_ bp: Int) -> String {
        if bp >= 1000 {
            let kb = Double(bp) / 1000.0
            return String(format: "%.1f kb (%d bp)", kb, bp)
        }
        return "\(bp) bp"
    }
}

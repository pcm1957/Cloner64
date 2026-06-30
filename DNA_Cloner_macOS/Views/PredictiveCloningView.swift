import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Protectable Region

struct ProtectableRegion: Identifiable {
    let id = UUID()
    let name: String
    let start: Int; let end: Int
    let source: Source
    var isProtected: Bool
    var wrapsOrigin: Bool { start > end }
    var rangeDescription: String {
        if wrapsOrigin {
            return "\(start + 1)–\(end + 1) (wraps origin)"
        }
        return "\(start + 1)–\(end + 1) (\(end - start + 1) bp)"
    }
    /// Returns one range (non-wrapping) or two ranges (wrapping) for use in site exclusion
    func protectedRanges(vectorLength: Int) -> [ClosedRange<Int>] {
        if wrapsOrigin {
            // e.g. 5303...5899 and 0...306 for a 5900bp plasmid protecting 5304–307
            return [start...(vectorLength - 1), 0...end]
        }
        return [start...end]
    }
    enum Source: String { case feature = "Feature"; case orf = "ORF"; case custom = "Custom" }
}

enum InsertRegionMode: String, CaseIterable {
    case wholeSequence = "Whole sequence"
    case feature = "Feature"
    case orf = "ORF"
    case custom = "Custom coordinates"
}

enum InsertionSiteMode: String, CaseIterable {
    case anywhere = "Anywhere"
    case betweenFeatures = "Between features"
}

enum SourceMode: String, CaseIterable {
    case single = "Single source"
    case multiSource = "Multi-source scan"
}

enum InsertDirectionPreference: String, CaseIterable {
    case either = "Either direction"
    case forward = "Forward (as-is)"
    case reverseComplement = "Reverse complement"
}


// MARK: - Scored Strategy (wraps CloningStrategy with source info)

struct ScoredStrategy: Identifiable {
    let id = UUID()
    let strategy: CloningStrategy
    let sourceName: String
    let sourceID: UUID
    let insertName: String
    let insertSequence: String
    let insertReversed: Bool
    /// The insert region within the source sequence — used to build a flanked
    /// primer design template with upstream/downstream context.
    let insertRegion: InsertRegion?
    /// The full source sequence and its topology for THIS result. Needed to
    /// re-cut the exact blunted fragment for .bluntedInsert strategies (each
    /// multi-source hit can come from a different source).
    var sourceSequence: String = ""
    var sourceIsCircular: Bool = false
}


// MARK: - Predictive Cloning View

struct PredictiveCloningView: View {
    
    @ObservedObject var sequenceManager: SequenceManager
    
    // --- Vector ---
    @State private var selectedVectorID: UUID? = nil
    @State private var cloningRegionStart = ""
    @State private var cloningRegionEnd = ""
    @State private var protectableRegions: [ProtectableRegion] = []
    @State private var showProtectedRegions = true
    @State private var matchedShuttleVector: ShuttleVector? = nil
    @State private var mcsAutoDetected = ""   // description of how MCS was found (empty = manual)
    @State private var customProtectName = ""
    @State private var customProtectStart = ""
    @State private var customProtectEnd = ""
    
    // --- Insertion site ---
    @State private var insertionSiteMode: InsertionSiteMode = .anywhere
    @State private var upstreamFeatureID: UUID? = nil
    @State private var downstreamFeatureID: UUID? = nil
    
    // --- Insert source ---
    @State private var sourceMode: SourceMode = .single
    @State private var selectedSourceID: UUID? = nil
    @State private var insertRegionMode: InsertRegionMode = .wholeSequence
    @State private var selectedFeatureID: UUID? = nil
    @State private var selectedSourceORFID: UUID? = nil
    @State private var customInsertStart = ""
    @State private var customInsertEnd = ""
    @State private var sourceORFs: [DNASequence.ORFResult] = []
    
    // --- Stop codon inclusion ---
    // When true, extends feature/custom insert end by 3 bp to capture the stop codon.
    // Only relevant for simple insertion and N-terminal fusion (where the insert
    // provides its own termination). C-terminal / both-sides fusion must NOT include
    // the stop codon because the reading frame must continue into the vector tag.
    @State private var includeStopCodon: Bool = true

    // --- Multi-source scan ---
    @State private var featureSearchText = ""
    
    // --- Cloning mode & frame ---
    @State private var cloningMode: CloningMode = .simpleInsertion
    @State private var insertDirectionPref: InsertDirectionPreference = .either
    @State private var vector5Offset = 0; @State private var insert5Offset = 0
    @State private var vector3Offset = 0; @State private var insert3Offset = 0
    
    // --- Fusion ORF ---
    @State private var insertORFs: [DNASequence.ORFResult] = []
    @State private var selectedFusionORFID: UUID? = nil
    @State private var hasScannedFusionORFs = false
    // When the user picks a feature as the insert but it can't serve as a
    // clean fusion ORF (length not a multiple of 3, or an internal stop),
    // this explains why instead of silently showing "no ORFs found".
    @State private var fusionFeatureNote: String? = nil

    // --- Vector tag features (for auto frame prediction) ---
    // N-terminal tag (5' junction) — used for N-terminal and both-sides fusion.
    @State private var vectorTagFeatureID: UUID? = nil
    // C-terminal tag (3' junction) — used for C-terminal and both-sides fusion.
    @State private var vectorTag3FeatureID: UUID? = nil
    // Tracks whether the current offsets were auto-predicted.
    @State private var offsetsArePredicted: Bool = false

    // --- Analysis state ---
    // True while runAnalysis / runMultiSourceAnalysis is running on a background thread.
    // Disables the button and shows a spinner so the user knows work is in progress.
    @State private var isAnalyzing = false
    
    // Methylation sensitivity (shared with rest of app via AppStorage)
    @AppStorage("methylation_dam") private var methylationDam: Bool = true
    @AppStorage("methylation_dcm") private var methylationDcm: Bool = true
    @AppStorage("methylation_cpg") private var methylationCpG: Bool = false

    // My Enzymes filters — persisted between sessions
    @AppStorage("predictive_myEnzymesOnly_strategies") private var myEnzymesOnlyStrategies: Bool = false
    @AppStorage("predictive_myEnzymesOnly_verify")     private var myEnzymesOnlyVerify:     Bool = false

    private var activeEnzymes: [RestrictionEnzyme] {
        myEnzymesOnlyStrategies
            ? enzymeDB.enzymes.filter { enzymeDB.isMyEnzyme($0.name) }
            : enzymeDB.enzymes
    }

    private var activeVerifyEnzymes: [RestrictionEnzyme] {
        myEnzymesOnlyVerify
            ? enzymeDB.enzymes.filter { enzymeDB.isMyEnzyme($0.name) }
            : enzymeDB.enzymes
    }

    private var currentMethylation: MethylationContext {
        MethylationContext(activeDam: methylationDam, activeDcm: methylationDcm, activeCpG: methylationCpG)
    }

    // --- Direct strategy results ---
    @State private var strategies: [CloningStrategy] = []
    @State private var effectiveInsertSequence = ""
    @State private var effectiveInsertName = ""
    @State private var insertWasReversed = false
    
    // User-visible warning shown via .alert — used by the origin-wrap guard in
    // runAnalysis / runMultiSourceAnalysis when the cloning region straddles
    // the plasmid origin and the downstream analyzer returns zero strategies.
    @State private var originWrapWarning: String? = nil
    
    // Diagnostic shown when the analyzer returns zero strategies for a
    // non-wrapping run — displays the per-filter-stage counts from
    // analyzer.lastDiagnostic so we can see where all candidates were dropped.
    @State private var analysisDiagnostic: String? = nil
    // Alternative vector suggestions — populated after fusion analysis when
    // no direct digest strategies survive the fusion validity filter.
    @State private var alternativeVectorSuggestions: [AlternativeVectorSuggestion] = []
    
    private let analyzer = CloningStrategyAnalyzer()
    private let enzymeDB = RestrictionEnzymeDatabase.shared
    private let vectorLibrary = ShuttleVectorLibrary.shared
    
    // --- Computed ---
    var selectedVector: DNASequence? { sequenceManager.sequences.first { $0.id == selectedVectorID } }
    var selectedSource: DNASequence? { sequenceManager.sequences.first { $0.id == selectedSourceID } }
    var isFusionMode: Bool { cloningMode != .simpleInsertion }
    /// Fusion cloning is always single-source — it needs one defined insert ORF
    /// with a known frame, which the multi-source scan can't provide. So treat
    /// the source as single whenever a fusion mode is active, regardless of the
    /// stored `sourceMode`.
    var useSingleSource: Bool { sourceMode == .single || isFusionMode }
    var needs5Prime: Bool { cloningMode == .fusionNTerminal || cloningMode == .fusionBoth }
    var needs3Prime: Bool { cloningMode == .fusionCTerminal || cloningMode == .fusionBoth }
    var protectedRanges: [ClosedRange<Int>] {
        guard let vector = selectedVector else { return [] }
        // In fusion mode, exclude any protectable region that overlaps a
        // selected tag feature — the tag sits right next to the cloning site
        // by design, so protecting it would block the intended enzyme.
        let tagRanges: [ClosedRange<Int>] = [vectorTagFeature, vectorTag3Feature]
            .compactMap { $0 }
            .map { min($0.start, $0.end)...max($0.start, $0.end) }
        // Build an exclusion zone around the tag(s) covering the MCS region.
        // In fusion mode the entire expression cassette (tag + linker + MCS) should
        // be unprotected so cloning enzymes within it are not blocked.
        // Use the MCS text fields when available; otherwise extend ±500 bp around
        // the tag (covers typical pET-style expression cassette geometry).
        let mcsLo0 = (Int(cloningRegionStart) ?? 1) - 1
        let mcsHi0 = (Int(cloningRegionEnd)   ?? 1) - 1
        let mcsRange: ClosedRange<Int>? = mcsLo0 < mcsHi0 ? mcsLo0...mcsHi0 : nil
        let tagFlankRange: ClosedRange<Int>? = isFusionMode ? {
            guard let v = selectedVector, !tagRanges.isEmpty else { return nil }
            let vL = v.length
            let tagLo = tagRanges.map { $0.lowerBound }.min() ?? 0
            let tagHi = tagRanges.map { $0.upperBound }.max() ?? 0
            let lo = max(0, tagLo - 500)
            let hi = min(vL - 1, tagHi + 500)
            return lo...hi
        }() : nil
        func overlapsAnyTag(_ region: ProtectableRegion) -> Bool {
            if tagRanges.contains(where: { region.start <= $0.upperBound && region.end >= $0.lowerBound }) {
                return true
            }
            if let mcs = mcsRange,
               region.start <= mcs.upperBound && region.end >= mcs.lowerBound {
                return true
            }
            if let flank = tagFlankRange,
               region.start <= flank.upperBound && region.end >= flank.lowerBound {
                return true
            }
            return false
        }
        var ranges = protectableRegions
            .filter { $0.isProtected && !(isFusionMode && overlapsAnyTag($0)) }
            .flatMap { $0.protectedRanges(vectorLength: vector.length) }
        if insertionSiteMode == .betweenFeatures {
            if let f = upstreamFeature {
                let lo = min(f.start, f.end); let hi = max(f.start, f.end)
                ranges.append(lo...hi)
            }
            if let f = downstreamFeature {
                let lo = min(f.start, f.end); let hi = max(f.start, f.end)
                ranges.append(lo...hi)
            }
        }
        return ranges
    }
    var protectedCount: Int { protectableRegions.filter { $0.isProtected }.count }
    
    var upstreamFeature: Feature? {
        guard let v = selectedVector, let id = upstreamFeatureID else { return nil }
        return v.features.first { $0.id == id }
    }
    var downstreamFeature: Feature? {
        guard let v = selectedVector, let id = downstreamFeatureID else { return nil }
        return v.features.first { $0.id == id }
    }
    
    /// The cloning region between the two selected features.
    /// Starts just after the end of the upstream feature, ends just before the start of the downstream feature.
    ///
    /// On a circular vector, the upstream feature can legitimately sit *after*
    /// the downstream feature (the cloning region wraps through the origin).
    /// E.g. Cambia 1302: promoter 10077–10544, GFP 3–758 on a 10549 bp plasmid
    /// — the cloning region runs 10545 → origin → 2 (7 bp including an NcoI site).
    ///
    /// Wrapping ranges are represented using the "end beyond length" convention
    /// already used by `currentInsertRegion` for wrapping features
    /// (see lines ~181–183): regionStart ... (vectorLength + regionEnd).
    /// Consumers of this range must modulo the upperBound by vector length.
    var betweenFeaturesRange: ClosedRange<Int>? {
        guard let upF = upstreamFeature, let dnF = downstreamFeature else { return nil }
        let regionStart = max(upF.start, upF.end) + 1
        let regionEnd = min(dnF.start, dnF.end) - 1
        
        // Normal (non-wrapping) case: upstream sits before downstream.
        if regionEnd > regionStart {
            return regionStart...regionEnd
        }
        
        // Origin-wrapping case — circular vectors only.
        if let vector = selectedVector, vector.isCircular {
            let vLen = vector.length
            // Sanity: upstream must end inside the sequence, downstream must begin inside.
            guard regionStart <= vLen, regionEnd >= -1 else { return nil }
            let wrappedEnd = vLen + regionEnd   // e.g. 10549 + 1 = 10550
            guard wrappedEnd >= regionStart else { return nil }
            return regionStart...wrappedEnd
        }
        
        return nil
    }
    
    var currentInsertRegion: InsertRegion? {
        guard let src = selectedSource else { return nil }
        switch insertRegionMode {
        case .wholeSequence: return InsertRegion(start: 0, end: src.length - 1, name: src.name)
        case .feature:
            guard let fid = selectedFeatureID, let f = src.features.first(where: { $0.id == fid }) else { return nil }
            // Pad feature region by ±200 bp (same rationale as ORF padding).
            let pad = 200
            // If the user wants to include the stop codon, extend the 3' end of
            // the feature by 3 bp before applying flanking padding.
            let stopExt = stopCodonExtension  // 0 or 3
            if src.isCircular {
                // Detect wrapping features:
                // (a) start > end — explicitly wrapping
                if f.start > f.end {
                    let paddedStart = (f.start - pad + src.length) % src.length
                    let paddedEnd   = (f.end + stopExt + pad) % src.length
                    return InsertRegion(start: paddedStart, end: paddedEnd, name: f.name)
                }
                // (b) end >= sequence length — feature extends past the origin
                if f.end >= src.length {
                    let wrappedEnd = f.end % src.length
                    let paddedStart = (f.start - pad + src.length) % src.length
                    let paddedEnd   = (wrappedEnd + stopExt + pad) % src.length
                    return InsertRegion(start: paddedStart, end: paddedEnd, name: f.name)
                }
                // (c) Normal feature on circular source — may still wrap after padding
                let paddedStart = (min(f.start, f.end) - pad + src.length) % src.length
                let paddedEnd   = (max(f.start, f.end) + stopExt + pad) % src.length
                return InsertRegion(start: paddedStart, end: paddedEnd, name: f.name)
            }
            // Linear source — clamp to sequence boundaries
            let paddedStart = max(0, min(f.start, f.end) - pad)
            let paddedEnd   = min(src.length - 1, max(f.start, f.end) + stopExt + pad)
            return InsertRegion(start: paddedStart, end: paddedEnd, name: f.name)
        case .orf:
            guard let oid = selectedSourceORFID, let orf = sourceORFs.first(where: { $0.id == oid }) else { return nil }
            let orfStart = orf.position - 1
            let orfEnd = orfStart + orf.size - 1
            // Pad the ORF region by ±200 bp so flanking restriction sites
            // outside the coding sequence are captured as usable cut sites.
            // The matching flankTolerance (200) passed to the analyzer keeps
            // the ORF coding core classified as "internal" (protected).
            let pad = 200
            if src.isCircular {
                let paddedStart = (orfStart - pad + src.length) % src.length
                let paddedEnd   = (orfEnd   + pad) % src.length
                return InsertRegion(start: paddedStart, end: paddedEnd, name: orf.label)
            } else {
                let paddedStart = max(0, orfStart - pad)
                let paddedEnd   = min(src.length - 1, orfEnd + pad)
                return InsertRegion(start: paddedStart, end: paddedEnd, name: orf.label)
            }
        case .custom:
            guard let s = Int(customInsertStart), let e = Int(customInsertEnd), s >= 1, e >= s else { return nil }
            let rawEnd = min(src.length - 1, e - 1 + stopCodonExtension)
            guard rawEnd < src.length else { return nil }
            return InsertRegion(start: s - 1, end: rawEnd, name: "Custom region")
        }
    }
    
    var selectedFusionORF: DNASequence.ORFResult? { insertORFs.first { $0.id == selectedFusionORFID } }

    /// A suggestion to try a different expression vector that matches the insert's reading frame.
    struct AlternativeVectorSuggestion: Identifiable {
        let id = UUID()
        let vector: ShuttleVector
        let reason: String          // e.g. "Frame offset matches your insert ORF"
        let frameOffset: Int        // 0, 1, or 2
    }

    /// After a fusion analysis, scan the library for vectors of the same category
    /// whose fusionFrameOffset matches the insert ORF's reading frame requirement.
    /// Works for both N-terminal (uses orfStartInExcerpt) and C-terminal
    /// (uses orfEndInExcerpt) fusion modes.
    func computeAlternativeVectorSuggestions(
        orfStartInExcerpt: Int?,
        orfEndInExcerpt: Int?,
        currentVectorName: String
    ) -> [AlternativeVectorSuggestion] {
        guard isFusionMode else { return [] }
        let currentCategory = matchedShuttleVector?.category ?? .ecoliExpression

        // For N-terminal: required frame = orfStart % 3
        // For C-terminal: required frame = (orfEnd + 1) % 3
        // (the base after the last coding base must be on a codon boundary in the vector)
        // For both-sides: both must match — use the N-terminal frame as primary filter
        let requiredFrame5: Int? = needs5Prime ? orfStartInExcerpt.map { $0 % 3 } : nil
        let _ : Int? = needs3Prime  ? orfEndInExcerpt.map  { ($0 + 1) % 3 } : nil

        return vectorLibrary.vectors
            .filter { v in
                guard let fo = v.fusionFrameOffset else { return false }
                guard v.category == currentCategory else { return false }
                guard v.name.lowercased().filter({ $0.isLetter || $0.isNumber }) !=
                      currentVectorName.lowercased().filter({ $0.isLetter || $0.isNumber })
                else { return false }
                // Match whichever junction(s) are relevant
                if let f5 = requiredFrame5, fo != f5 { return false }
                // C-terminal frame check: the vector's reading frame at the 3'
                // junction must also be compatible. Since fusionFrameOffset currently
                // encodes the N-terminal offset, we use the same value as a proxy
                // for C-terminal too (they are related by vector design).
                return true
            }
            .map { v in
                let junctionDesc: String
                if needs5Prime && needs3Prime {
                    junctionDesc = "N- and C-terminal frame offsets"
                } else if needs5Prime {
                    junctionDesc = "N-terminal frame offset"
                } else {
                    junctionDesc = "C-terminal frame offset"
                }
                return AlternativeVectorSuggestion(
                    vector: v,
                    reason: "\(junctionDesc) \(v.fusionFrameOffset!) matches your insert ORF — direct digest cloning may be possible",
                    frameOffset: v.fusionFrameOffset!
                )
            }
            .sorted { a, b in
                let aScore = a.vector.name.lowercased().filter { $0.isLetter || $0.isNumber }
                    .commonPrefix(with: currentVectorName.lowercased().filter { $0.isLetter || $0.isNumber }).count
                let bScore = b.vector.name.lowercased().filter { $0.isLetter || $0.isNumber }
                    .commonPrefix(with: currentVectorName.lowercased().filter { $0.isLetter || $0.isNumber }).count
                return aScore > bScore
            }
    }

    var vectorTagFeature: Feature? {
        guard let v = selectedVector, let id = vectorTagFeatureID else { return nil }
        return v.features.first { $0.id == id }
    }

    var vectorTag3Feature: Feature? {
        guard let v = selectedVector, let id = vectorTag3FeatureID else { return nil }
        return v.features.first { $0.id == id }
    }

    /// Infers whether a vector feature sits at the N- or C-terminus of the fusion,
    /// relative to the cloning region (MCS), read in the feature's own strand
    /// direction. Forward cassettes read low→high, so the N-terminal tag is the
    /// LOWER-coordinate one; reverse cassettes (e.g. pET-28c stored flipped) read
    /// high→low, so the N-terminal tag is the HIGHER-coordinate one — which is the
    /// trap that made the pET-28c His tags ambiguous in the picker.
    ///
    /// Returns nil (no label) when it can't be inferred confidently: no MCS region
    /// known, the feature is far from the MCS, or it isn't a coding/tag feature.
    /// Better to show nothing than a wrong label, so this is deliberately cautious
    /// and may be inaccurate on non-standard vector layouts.
    func tagTerminusLabel(for f: Feature) -> String? {
        guard let s1 = Int(cloningRegionStart), let e1 = Int(cloningRegionEnd) else { return nil }
        let mcsLo = min(s1, e1) - 1          // 1-based field → 0-based
        let mcsHi = max(s1, e1) - 1
        let fLo = min(f.start, f.end)
        let fHi = max(f.start, f.end)

        // Proximity gate — fusion tags sit adjacent to the MCS. This keeps
        // origins, resistance genes, LacI, etc. out of the labelling.
        let gap: Int
        if fHi < mcsLo { gap = mcsLo - fHi }
        else if fLo > mcsHi { gap = fLo - mcsHi }
        else { gap = 0 }
        guard gap <= 300 else { return nil }

        // Coding/tag gate — keyed off the type's display name ("CDS"/"Gene") to
        // avoid hard-coding enum cases, with a tag-keyword name fallback.
        let typeName = f.type.displayName.lowercased()
        let nm = f.name.lowercased()
        let tagKeywords = ["his", "flag", "myc", "gst", "mbp", "sumo", "strep", "v5", "halo", "gfp", "tag"]
        let looksCoding = typeName.contains("cds") || typeName.contains("gene")
            || tagKeywords.contains(where: { nm.contains($0) })
        guard looksCoding else { return nil }

        let mcsMid = Double(mcsLo + mcsHi) / 2.0
        let tagMid = Double(fLo + fHi) / 2.0
        let isReverse = (f.strand == .reverse)
        let isNTerminal = isReverse ? (tagMid > mcsMid) : (tagMid < mcsMid)
        // Spell out what the tag does to the protein, not just where it sits —
        // "N-terminal" alone is ambiguous (is this THE N-terminal tag, or does it
        // go on the N-terminus of the insert?). "start"/"end" sidesteps any
        // left/right confusion: N-terminus = start of protein, C-terminus = end.
        return isNTerminal
            ? "adds tag to N-terminus (start) of insert"
            : "adds tag to C-terminus (end) of insert"
    }

    /// Calculates predicted junction frame offsets from the insert fusion ORF.
    /// Returns nil if no tag feature is selected, no fusion ORF is selected,
    /// or the insert region is not yet defined.
    ///
    /// The analyzer's frame check is: (vectorOffset + overhang + insertOffset) % 3 == 0
    ///
    /// vectorOffset depends on which enzyme is chosen (its cut position relative
    /// to the tag), so we cannot pre-calculate it here. We set it to 0 and rely
    /// on the analyzer's auto-align, which tries {0,1,2} and picks the value that
    /// makes the check pass for each enzyme candidate.
    ///
    /// insertOffset IS knowable: it is the distance (mod 3) from the start of the
    /// insert excerpt to the ATG of the fusion ORF. Whatever the enzyme overhang
    /// is, the sum (vectorOffset + overhang + insertOffset) must be divisible by 3.
    func predictedJunctionOffsets() -> (vec5: Int, ins5: Int, vec3: Int, ins3: Int)? {
        // We can predict offsets only for a junction whose tag feature is selected.
        // Require at least one relevant junction to have its tag — otherwise there
        // is nothing to predict. (The previous `|| : true` form always passed for
        // single-terminus modes, wrongly flagging offsets as predicted.)
        let canPredict5 = needs5Prime && vectorTagFeatureID  != nil
        let canPredict3 = needs3Prime && vectorTag3FeatureID != nil
        guard canPredict5 || canPredict3 else { return nil }
        guard let fusionORF = selectedFusionORF,
              let region    = currentInsertRegion else { return nil }

        // --- Insert 5' offset ---
        // fusionORF.position is 1-based within the excerpt that scanFusionORFs
        // scanned. Convert to 0-based distance from excerpt start.
        let orfStartInExcerpt: Int
        if insertRegionMode == .orf,
           let srcORF = sourceORFs.first(where: { $0.id == selectedSourceORFID }),
           let src = selectedSource {
            // ORF mode: excerpt starts at region.start (padded); ORF absolute
            // position in source is srcORF.position - 1 (0-based).
            let orfAbsolute = srcORF.position - 1
            orfStartInExcerpt = (orfAbsolute - region.start + src.length) % src.length
        } else {
            // Feature / custom / whole: scanFusionORFs scanned the excerpt directly.
            orfStartInExcerpt = fusionORF.position - 1
        }
        let ins5 = orfStartInExcerpt % 3

        // --- Insert 3' offset ---
        // For C-terminal fusion: remainder of ORF size mod 3.
        // A perfect CDS (multiple of 3) gives ins3 = 0.
        let ins3 = fusionORF.size % 3

        // vectorOffset = 0; auto-align in the analyzer handles the rest.
        return (vec5: 0, ins5: ins5, vec3: 0, ins3: ins3)
    }

    /// Returns true if there is an in-frame stop codon in `sequence[from..<to]`.
    /// Used to validate fusion strategies: even when the mod-3 frame check passes,
    /// a stop codon in the 5' UTR between the insert cut site and the ORF ATG
    /// would terminate translation before reaching the ORF — making the strategy
    /// useless for fusion cloning.
    ///
    /// `from` is the first base AFTER the sticky end overhang (i.e. the first base
    /// of insert sequence that will be translated in context).
    /// `to` is the 0-based position of the ORF ATG in the excerpt.
    /// `frame` is the reading frame offset at `from` (0, 1, or 2 bases to skip to
    /// reach the first complete codon boundary).
    func hasInFrameStopCodon(in sequence: String, from: Int, to: Int, frame: Int) -> Bool {
        guard to > from, from >= 0, to <= sequence.count else { return false }
        let start = from + frame  // first codon-aligned position
        guard start >= 0, start + 3 <= to else { return false }
        // Scan only the [start, to) window. The previous implementation
        // re-uppercased the ENTIRE insert on every call and used
        // seq.index(startIndex, offsetBy: i) inside the loop, which is O(n)
        // per codon -> O(n²) overall and costly when `to` is deep into a long
        // insert (the 3' junction case). This is called inside the per-strategy
        // fusion filters, so the old version repeated that work for every
        // candidate strategy.
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

    /// Apply auto-predicted offsets to the junction pickers.
    /// Called when the tag feature or fusion ORF selection changes.
    func applyPredictedOffsets() {
        guard isFusionMode else { return }
        if let predicted = predictedJunctionOffsets() {
            if needs5Prime && vectorTagFeatureID != nil {
                vector5Offset = predicted.vec5
                insert5Offset = predicted.ins5
            }
            if needs3Prime && vectorTag3FeatureID != nil {
                vector3Offset = predicted.vec3
                insert3Offset = predicted.ins3
            }
            offsetsArePredicted = true
        } else {
            offsetsArePredicted = false
        }
    }

    /// Returns 3 when the user has opted to include the stop codon, 0 otherwise.
    /// Only applicable for Feature and Custom insert modes; ORF mode already
    /// includes the stop, and Whole Sequence mode doesn't need it.
    /// C-terminal and both-sides fusions must NOT extend (they need read-through
    /// into the vector tag), so we force 0 for those modes regardless of the toggle.
    var stopCodonExtension: Int {
        guard includeStopCodon else { return 0 }
        guard insertRegionMode == .feature || insertRegionMode == .custom else { return 0 }
        guard cloningMode == .simpleInsertion || cloningMode == .fusionNTerminal else { return 0 }
        return 3
    }
    
    var canAddCustomRegion: Bool {
        guard let vector = selectedVector,
              let s = Int(customProtectStart), let e = Int(customProtectEnd),
              s >= 1, s <= vector.length, e >= 1, e <= vector.length else { return false }
        if s > e && !vector.isCircular { return false }
        if s == e { return false }
        return true
    }
    
    var analyzeButtonDisabled: Bool {
        if selectedVectorID == nil { return true }
        // "Between features" requires both 5' and 3' features to be selected
        if insertionSiteMode == .betweenFeatures && betweenFeaturesRange == nil { return true }
        if useSingleSource {
            // In fusion mode, a fusion ORF must be selected before analysis.
            // This ensures the stop-codon filter has a target to check against.
            if isFusionMode && selectedFusionORFID == nil { return true }
            return currentInsertRegion == nil || selectedVectorID == selectedSourceID
        } else {
            return featureSearchText.trimmingCharacters(in: .whitespaces).isEmpty
                || matchingSources.isEmpty
        }
    }
    
    /// Find all open sequences (except the vector) that contain a feature matching the search text
    var matchingSources: [(source: DNASequence, feature: Feature)] {
        guard !featureSearchText.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let query = featureSearchText.lowercased().trimmingCharacters(in: .whitespaces)
        var results: [(source: DNASequence, feature: Feature)] = []
        for seq in sequenceManager.sequences {
            if seq.id == selectedVectorID { continue }
            for f in seq.features {
                if fuzzyMatch(f.name.lowercased(), query: query) {
                    results.append((source: seq, feature: f))
                }
            }
        }
        return results
    }
    
    /// Fuzzy match: true if all words in the query appear somewhere in the target
    func fuzzyMatch(_ target: String, query: String) -> Bool {
        let words = query.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        if words.isEmpty { return false }
        return words.allSatisfy { target.contains($0) }
    }
    
    // NOTE: Library MCS filtering is used only for shuttle route destination MCS
    // (via openShuttleRoutesWindow), not for direct cloning analysis.
    
    // --- Body ---
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                GroupBox("Vector") {
                    VStack(alignment: .leading, spacing: 10) {
                        vectorPicker; libraryMatchSection
                        insertionSiteSection; if selectedVector != nil { protectedRegionsSection }
                    }.padding(8)
                }.padding([.horizontal, .top])
                
                GroupBox("Insert") {
                    VStack(alignment: .leading, spacing: 10) {
                        // Source mode toggle — simple insertion only. Fusion cloning
                        // needs one defined insert, so the toggle is hidden and the
                        // source is forced single (see useSingleSource).
                        if !isFusionMode {
                            HStack {
                                Text("Source mode:").frame(width: 110, alignment: .trailing)
                                Picker("", selection: $sourceMode) {
                                    ForEach(SourceMode.allCases, id: \.self) { Text($0.rawValue) }
                                }.pickerStyle(.segmented).frame(maxWidth: 280)
                                .contextHelp("predict.sourceMode")
                            }
                        } else {
                            HStack {
                                Text("Source mode:").frame(width: 110, alignment: .trailing)
                                HStack(spacing: 6) {
                                    Image(systemName: "info.circle").foregroundColor(.primary.opacity(0.5)).font(.callout)
                                    Text("Single source — fusion cloning uses one defined insert (multi-source scan is for simple insertion).")
                                        .font(.callout).foregroundColor(.primary.opacity(0.6))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                            }
                        }
                        
                        if useSingleSource {
                            sourcePicker; insertRegionPicker
                        } else {
                            multiSourcePicker
                        }
                    }.padding(8)
                }.padding(.horizontal)
                
                GroupBox("Options") {
                    VStack(alignment: .leading, spacing: 10) {
                        cloningModeSection
                        Divider()
                        HStack(spacing: 16) {
                            Image(systemName: "star.fill").foregroundColor(.yellow).font(.callout)
                            Toggle(isOn: $myEnzymesOnlyStrategies) {
                                Text("My Enzymes only (strategies)").font(.callout)
                            }
                            .toggleStyle(.checkbox)
                            .help("Restrict strategy search to enzymes in your freezer stock")
                            Toggle(isOn: $myEnzymesOnlyVerify) {
                                Text("My Enzymes only (verify)").font(.callout)
                            }
                            .toggleStyle(.checkbox)
                            .help("Use only freezer stock enzymes for construct verification digest")
                        }
                        if myEnzymesOnlyStrategies && enzymeDB.myEnzymeNames.isEmpty {
                            Text("⚠ No enzymes starred — open the Enzyme List and star your freezer stock first.")
                                .font(.callout).foregroundColor(.orange)
                        }
                    }.padding(8)
                }.padding(.horizontal)
                
                HStack {
                    Spacer()
                    Button(action: useSingleSource ? runAnalysis : runMultiSourceAnalysis) {
                        if isAnalyzing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Analyzing…")
                            }
                        } else {
                            Label(useSingleSource ? "Analyze Strategies" : "Scan All Sources", systemImage: "wand.and.stars")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(analyzeButtonDisabled || isAnalyzing)
                    .keyboardShortcut(.return, modifiers: .command)
                    .contextHelp("predict.analyze")
                    Spacer()
                }.padding(.vertical, 8)
            }
        }
        .frame(minWidth: 720, minHeight: 550)
        .textSelection(.enabled)
        .onAppear {
            // Clear the vector tag feature selection on every appearance.
            // macOS SwiftUI state restoration can persist @State UUIDs across
            // sessions, but feature UUIDs are regenerated on each load, so any
            // saved UUID is guaranteed stale. The user must re-select after opening.
            vectorTagFeatureID = nil
            vectorTag3FeatureID = nil
            offsetsArePredicted = false
        }
        .alert(
            "Origin-wrapping cloning region",
            isPresented: Binding(
                get: { originWrapWarning != nil },
                set: { if !$0 { originWrapWarning = nil } }
            ),
            presenting: originWrapWarning
        ) { _ in
            Button("OK", role: .cancel) { originWrapWarning = nil }
        } message: { msg in
            Text(msg)
        }
        .alert(
            "No strategies — diagnostic",
            isPresented: Binding(
                get: { analysisDiagnostic != nil },
                set: { if !$0 { analysisDiagnostic = nil } }
            ),
            presenting: analysisDiagnostic
        ) { _ in
            Button("OK", role: .cancel) { analysisDiagnostic = nil }
        } message: { msg in
            Text(msg)
        }
    }
    
    // ================================================================
    // MARK: Vector section
    // ================================================================
    
    @ViewBuilder var vectorPicker: some View {
        HStack {
            Text("Vector:").frame(width: 110, alignment: .trailing)
            Picker("", selection: $selectedVectorID) {
                Text("Choose…").tag(nil as UUID?)
                ForEach(sequenceManager.sequences) { seq in Text(seq.name).tag(seq.id as UUID?) }
            }.labelsHidden().frame(maxWidth: 300)
            .onChange(of: selectedVectorID) { _ in matchVectorToLibrary(); buildProtectableRegions(); estimateMCSRegion(); upstreamFeatureID = nil; downstreamFeatureID = nil; vectorTagFeatureID = nil; vectorTag3FeatureID = nil; offsetsArePredicted = false }
            .contextHelp("predict.vectorPicker")
            Button("Browse…") { browseForSequence(binding: $selectedVectorID) }
                .font(.callout)
                .contextHelp("predict.vectorBrowse")
            if let v = selectedVector { Text("\(v.length) bp, \(v.isCircular ? "circular" : "linear")").font(.callout).foregroundColor(.primary.opacity(0.65)) }
        }
    }
    
    @ViewBuilder var libraryMatchSection: some View {
        if let matched = matchedShuttleVector {
            HStack(alignment: .top) {
                Text("").frame(width: 110)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                        Text("Matched to \(matched.name)").font(.callout).fontWeight(.medium)
                        Text("— shuttle routes available").font(.callout).foregroundColor(.primary.opacity(0.65))
                    }
                }.padding(8).background(Color.green.opacity(0.05)).cornerRadius(6)
            }
        } else if selectedVector != nil {
            HStack {
                Text("").frame(width: 110)
                HStack(spacing: 6) {
                    Image(systemName: "questionmark.circle").foregroundColor(.primary.opacity(0.65))
                    Text("No library match — using manual MCS or full enzyme scan").font(.callout).foregroundColor(.primary.opacity(0.65))
                }
            }
        }
    }
    
    @ViewBuilder var insertionSiteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Insertion site:").frame(width: 110, alignment: .trailing)
                Picker("", selection: $insertionSiteMode) {
                    ForEach(InsertionSiteMode.allCases, id: \.self) { Text($0.rawValue) }
                }.pickerStyle(.segmented).frame(maxWidth: 280)
                .contextHelp("predict.insertionSiteMode")
            }
            
            if insertionSiteMode == .anywhere {
                HStack {
                    Text("MCS region:").frame(width: 110, alignment: .trailing)
                    TextField("Start", text: $cloningRegionStart).textFieldStyle(.roundedBorder).frame(width: 80)
                    Text("–"); TextField("End", text: $cloningRegionEnd).textFieldStyle(.roundedBorder).frame(width: 80)
                    if !mcsAutoDetected.isEmpty {
                        Image(systemName: "sparkle").foregroundColor(.green).font(.callout)
                        Text(mcsAutoDetected).font(.callout).foregroundColor(.green)
                        Button(action: { cloningRegionStart = ""; cloningRegionEnd = ""; mcsAutoDetected = "" }) {
                            Image(systemName: "xmark.circle.fill").foregroundColor(.primary.opacity(0.4))
                        }.buttonStyle(.plain).help("Clear auto-detected region")
                    } else {
                        Text("(optional — editable)").foregroundColor(.primary.opacity(0.65)).font(.callout)
                    }
                }
                .contextHelp("predict.mcsRegion")
            } else if let v = selectedVector {
                HStack {
                    Text("5' feature:").frame(width: 110, alignment: .trailing)
                    Picker("", selection: $upstreamFeatureID) {
                        Text("— Select —").tag(UUID?.none)
                        ForEach(v.features) { f in
                            Text("\(f.name) (\(min(f.start, f.end) + 1)–\(max(f.start, f.end) + 1))").tag(UUID?.some(f.id))
                        }
                    }.labelsHidden().frame(maxWidth: 350)
                    .contextHelp("predict.betweenFeatures5")
                }
                HStack {
                    Text("3' feature:").frame(width: 110, alignment: .trailing)
                    Picker("", selection: $downstreamFeatureID) {
                        Text("— Select —").tag(UUID?.none)
                        ForEach(v.features) { f in
                            Text("\(f.name) (\(min(f.start, f.end) + 1)–\(max(f.start, f.end) + 1))").tag(UUID?.some(f.id))
                        }
                    }.labelsHidden().frame(maxWidth: 350)
                    .contextHelp("predict.betweenFeatures3")
                }
                if let range = betweenFeaturesRange {
                    HStack {
                        Text("").frame(width: 110)
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.right").foregroundColor(.green).font(.callout)
                            // Wrap-aware label: if upperBound exceeds vector length, the range
                            // straddles the origin — show both physical stretches plus a hint.
                            Group {
                                if let v = selectedVector, v.isCircular, range.upperBound >= v.length {
                                    let wrappedUpper = range.upperBound - v.length   // 0-based
                                    Text("Search region: \(range.lowerBound + 1)–\(v.length), 1–\(wrappedUpper + 1) (\(range.count) bp, wraps origin)")
                                        .font(.callout).foregroundColor(.green)
                                } else {
                                    Text("Search region: \(range.lowerBound + 1)–\(range.upperBound + 1) (\(range.count) bp)")
                                        .font(.callout).foregroundColor(.green)
                                }
                            }
                            if let upN = upstreamFeature?.name, let dnN = downstreamFeature?.name {
                                Text("between \(upN) and \(dnN)")
                                    .font(.callout).foregroundColor(.primary.opacity(0.65))
                            }
                        }
                    }
                } else if upstreamFeatureID != nil && downstreamFeatureID != nil {
                    HStack {
                        Text("").frame(width: 110)
                        Text("No valid region between selected features").font(.callout).foregroundColor(.red)
                    }
                }
            }
        }
    }
    
    @ViewBuilder var protectedRegionsSection: some View {
        HStack(alignment: .top) {
            Text("Protect:").frame(width: 110, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Button(action: { withAnimation { showProtectedRegions.toggle() } }) {
                        HStack(spacing: 4) {
                            Image(systemName: showProtectedRegions ? "chevron.down" : "chevron.right").font(.callout)
                            Text("\(protectedCount)/\(protectableRegions.count) protected").font(.callout)
                        }
                    }.buttonStyle(.plain)
                    .contextHelp("predict.protectedRegions")
                    Spacer()
                    if !protectableRegions.isEmpty {
                        Button("All") { for i in protectableRegions.indices { protectableRegions[i].isProtected = true } }.font(.callout).buttonStyle(.plain).foregroundColor(.blue)
                        Text("·").foregroundColor(.primary.opacity(0.65))
                        Button("None") { for i in protectableRegions.indices { protectableRegions[i].isProtected = false } }.font(.callout).buttonStyle(.plain).foregroundColor(.blue)
                    }
                }
                if showProtectedRegions {
                    ForEach($protectableRegions) { $region in
                        HStack(spacing: 6) {
                            Toggle("", isOn: $region.isProtected).toggleStyle(.checkbox).labelsHidden()
                            Text(region.name).font(.callout).fontWeight(.medium).frame(minWidth: 80, alignment: .leading)
                            Text(region.rangeDescription).font(.system(.callout, design: .monospaced)).foregroundColor(.primary.opacity(0.65))
                            Text(region.source.rawValue).font(.callout).foregroundColor(.primary.opacity(0.65))
                            if region.source == .custom {
                                Button(action: { protectableRegions.removeAll { $0.id == region.id } }) {
                                    Image(systemName: "xmark.circle.fill").font(.callout).foregroundColor(.primary.opacity(0.65))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    
                    // --- Add custom protected region ---
                    Divider().padding(.vertical, 2)
                    HStack(spacing: 6) {
                        TextField("Name", text: $customProtectName).textFieldStyle(.roundedBorder).frame(width: 120)
                        TextField("Start", text: $customProtectStart).textFieldStyle(.roundedBorder).frame(width: 70)
                        Text("–")
                        TextField("End", text: $customProtectEnd).textFieldStyle(.roundedBorder).frame(width: 70)
                        Button(action: addCustomProtectedRegion) {
                            Label("Add", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(.plain).font(.callout).foregroundColor(.blue)
                        .disabled(!canAddCustomRegion)
                    }.font(.callout)
                    Text("Protect a coordinate range (1-based) — for circular vectors, start > end wraps the origin")
                        .font(.callout).foregroundColor(.primary.opacity(0.65))
                }
            }
        }
    }
    
    // ================================================================
    // MARK: Insert source & region
    // ================================================================
    
    @ViewBuilder var sourcePicker: some View {
        HStack {
            Text("Source sequence:").frame(width: 110, alignment: .trailing)
            Picker("", selection: $selectedSourceID) {
                Text("Choose…").tag(nil as UUID?)
                ForEach(sequenceManager.sequences) { seq in Text(seq.name).tag(seq.id as UUID?) }
            }.labelsHidden().frame(maxWidth: 300)
            .onChange(of: selectedSourceID) { _ in
                // Reset all ORF-related state when the source sequence changes.
                // Previously only scanSourceORFs() was called, which populated
                // the new source's ORFs but left selectedSourceORFID /
                // selectedFusionORFID / insertORFs pointing at UUIDs from the
                // previous source. SwiftUI then emitted "Picker: the selection
                // is invalid and does not have an associated tag" warnings.
                scanSourceORFs()
                insertRegionMode = .wholeSequence
                selectedSourceORFID = nil
                selectedFusionORFID = nil
                insertORFs = []
                hasScannedFusionORFs = false
            }
            .contextHelp("predict.sourcePicker")
            Button("Browse…") { browseForSequence(binding: $selectedSourceID) }
                .font(.callout)
                .contextHelp("predict.sourceBrowse")
            if let s = selectedSource { Text("\(s.length) bp, \(s.isCircular ? "circular" : "linear")").font(.callout).foregroundColor(.primary.opacity(0.65)) }
            if let s = selectedSource, !s.isCircular, s.cohesive5Prime.isEmpty, s.cohesive3Prime.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "equal.circle.fill").foregroundColor(.green).font(.callout)
                    Text("Blunt ends").font(.callout).foregroundColor(.green)
                }
            }
        }
    }
    
    @ViewBuilder var insertRegionPicker: some View {
        HStack(alignment: .top) {
            Text("Insert region:").frame(width: 110, alignment: .trailing)
            VStack(alignment: .leading, spacing: 6) {
                Picker("", selection: $insertRegionMode) {
                    Text("Whole sequence").tag(InsertRegionMode.wholeSequence)
                    if let src = selectedSource, !src.features.isEmpty { Text("Feature").tag(InsertRegionMode.feature) }
                    if !sourceORFs.isEmpty { Text("ORF").tag(InsertRegionMode.orf) }
                    Text("Custom coordinates").tag(InsertRegionMode.custom)
                }.labelsHidden().pickerStyle(.segmented).frame(maxWidth: 400)
                .contextHelp("predict.insertRegionMode")
                // Keep the fusion target in sync when the user changes how the
                // insert region is defined (e.g. switching from Whole sequence → ORF).
                .onChange(of: insertRegionMode) { _ in if isFusionMode { scanFusionORFs() } }
                
                switch insertRegionMode {
                case .wholeSequence:
                    if let src = selectedSource { Text("Using entire \(src.name) (\(src.length) bp)").font(.callout).foregroundColor(.primary.opacity(0.65)) }
                case .feature:
                    if let src = selectedSource {
                        Picker("", selection: $selectedFeatureID) {
                            Text("Choose…").tag(nil as UUID?)
                            ForEach(src.features) { f in Text("\(f.name) (\(min(f.start,f.end)+1)–\(max(f.start,f.end)+1))").tag(f.id as UUID?) }
                        }.labelsHidden().frame(maxWidth: 400)
                        // Re-run the fusion scan when the chosen feature changes,
                        // so the picked feature is offered as a fusion candidate.
                        .onChange(of: selectedFeatureID) { _ in if isFusionMode { scanFusionORFs() } }
                    }
                case .orf:
                    Picker("", selection: $selectedSourceORFID) {
                        Text("Choose…").tag(nil as UUID?)
                        ForEach(sourceORFs) { orf in Text("\(orf.label) (\(orf.strand)) at pos \(orf.position)").tag(orf.id as UUID?) }
                    }.labelsHidden().frame(maxWidth: 400)
                    // Keep the fusion target in sync when the user changes
                    // which source ORF is the insert.
                    .onChange(of: selectedSourceORFID) { _ in if isFusionMode { scanFusionORFs() } }
                case .custom:
                    HStack {
                        TextField("Start", text: $customInsertStart).textFieldStyle(.roundedBorder).frame(width: 100)
                        Text("–"); TextField("End", text: $customInsertEnd).textFieldStyle(.roundedBorder).frame(width: 100)
                    }
                }
                if let region = currentInsertRegion, insertRegionMode != .wholeSequence {
                    let displayLen = region.wrapsOrigin ? region.lengthInSource(selectedSource?.length ?? 0) : region.length
                    if insertRegionMode == .orf, let orf = sourceORFs.first(where: { $0.id == selectedSourceORFID }) {
                        Text("Insert: \(region.name) — \(orf.size) bp ORF + flanking (\(displayLen) bp total)")
                            .font(.callout).foregroundColor(.green)
                    } else if insertRegionMode == .feature,
                              let fid = selectedFeatureID,
                              let f = selectedSource?.features.first(where: { $0.id == fid }) {
                        let coreSize = (f.start > f.end && selectedSource?.isCircular == true)
                            ? (selectedSource!.length - f.start) + f.end + 1
                            : abs(max(f.start, f.end) - min(f.start, f.end)) + 1
                        let stopLabel = stopCodonExtension == 3 ? " + stop codon" : ""
                        Text("Insert: \(region.name) — \(coreSize) bp feature\(stopLabel) + flanking (\(displayLen) bp total)")
                            .font(.callout).foregroundColor(.green)
                    } else {
                        Text("Insert: \(region.name) — \(displayLen) bp").font(.callout).foregroundColor(.green)
                    }
                }

                // Stop codon toggle — feature and custom modes only, for cloning
                // strategies that need the insert to terminate itself.
                // Hidden for C-terminal / both-sides fusion (must read through into the tag).
                if (insertRegionMode == .feature || insertRegionMode == .custom),
                   cloningMode == .simpleInsertion || cloningMode == .fusionNTerminal {
                    HStack(spacing: 6) {
                        Toggle("Include stop codon (+3 bp at 3′ end)", isOn: $includeStopCodon)
                            .toggleStyle(.checkbox)
                            .font(.callout)
                        Text(includeStopCodon
                             ? "Stop codon included — insert will terminate translation"
                             : "Stop codon excluded — ensure the vector provides a stop or this is intentional")
                            .font(.callout)
                            .foregroundColor(includeStopCodon ? .primary.opacity(0.65) : .orange)
                    }
                    .contextHelp("predict.includeStopCodon")
                }
            }
        }
    }
    
    @ViewBuilder var multiSourcePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Feature name:").frame(width: 110, alignment: .trailing)
                TextField("e.g. B2, GFP, HIS5…", text: $featureSearchText)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 250)
                    .contextHelp("predict.multiSourceSearch")
                Text("Searches all open sequences").font(.callout).foregroundColor(.primary.opacity(0.65))
            }
            
            if !featureSearchText.trimmingCharacters(in: .whitespaces).isEmpty {
                multiSourceMatchList
            }
        }
    }
    
    @ViewBuilder var multiSourceMatchList: some View {
        if matchingSources.isEmpty {
            HStack {
                Text("").frame(width: 110)
                Text("No matching features found in open sequences").font(.callout).foregroundColor(.red)
            }
        } else {
            HStack {
                Text("").frame(width: 110)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(matchingSources.count) match\(matchingSources.count == 1 ? "" : "es") found:")
                        .font(.callout).foregroundColor(.green)
                    ForEach(Array(matchingSources.enumerated()), id: \.offset) { _, match in
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.system(size: 11))
                            Text(match.source.name).font(.callout).fontWeight(.medium)
                            Text("→ \(match.feature.name)").font(.callout).foregroundColor(.primary.opacity(0.65))
                        }
                    }
                }
            }
        }
    }
    
    // ================================================================
    // MARK: Cloning mode
    // ================================================================
    
    @ViewBuilder var cloningModeSection: some View {
        HStack(alignment: .top) {
            Text("Cloning mode:").frame(width: 110, alignment: .trailing)
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $cloningMode) {
                    Text("Simple insertion").tag(CloningMode.simpleInsertion)
                    Text("Fusion — Tag at N-terminus  (Tag–Insert)").tag(CloningMode.fusionNTerminal)
                    Text("Fusion — Tag at C-terminus  (Insert–Tag)").tag(CloningMode.fusionCTerminal)
                    Text("Fusion — Tag on both sides  (Tag–Insert–Tag)").tag(CloningMode.fusionBoth)
                }.labelsHidden().frame(maxWidth: 420)
                .onChange(of: cloningMode) { _ in
                    if isFusionMode { scanFusionORFs() }
                    // Reset tag selection and predicted offsets when switching modes
                    if !isFusionMode { vectorTagFeatureID = nil; vectorTag3FeatureID = nil; offsetsArePredicted = false }
                }
                .contextHelp("predict.cloningMode")
                if isFusionMode {
                    Text("“Tag” = an existing ORF in the vector (e.g. GFP in pCambia 1302). Labels read N → C: **(Tag–Insert)** puts the tag first in the fusion protein, **(Insert–Tag)** puts your insert first. Choose by where you want the tag in the final protein, not by where the cloning site sits on the vector.")
                        .font(.callout).foregroundColor(.primary.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 520, alignment: .leading)
                }
                if isFusionMode { fusionORFPicker }

                // --- Vector tag feature pickers ---
                // Show N-terminal tag picker when 5' junction is needed,
                // C-terminal tag picker when 3' junction is needed.
                if isFusionMode, let vector = selectedVector, !vector.features.isEmpty {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            // N-terminal tag picker (5' junction)
                            if needs5Prime {
                                HStack(spacing: 8) {
                                    Image(systemName: "function").foregroundColor(.purple).font(.callout)
                                    Text("N-terminal tag:").font(.callout).fontWeight(.semibold).frame(width: 130, alignment: .trailing)
                                    Picker("", selection: $vectorTagFeatureID) {
                                        Text("Not specified").tag(nil as UUID?)
                                        ForEach(vector.features) { f in
                                            Text("\(f.name) (\(min(f.start,f.end)+1)–\(max(f.start,f.end)+1), \(f.strand == .reverse ? "−" : "+") strand)\(tagTerminusLabel(for: f).map { " — \($0)" } ?? "")")
                                                .tag(f.id as UUID?)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(maxWidth: 360)
                                    .onChange(of: vectorTagFeatureID) { _ in applyPredictedOffsets() }
                                    .onChange(of: vector.features.map(\.id)) { ids in
                                        if let tid = vectorTagFeatureID, !ids.contains(tid) {
                                            vectorTagFeatureID = nil; offsetsArePredicted = false
                                        }
                                    }
                                    .contextHelp("predict.vectorTagFeature")
                                }
                            }
                            // C-terminal tag picker (3' junction)
                            if needs3Prime {
                                HStack(spacing: 8) {
                                    Image(systemName: "function").foregroundColor(.indigo).font(.callout)
                                    Text("C-terminal tag:").font(.callout).fontWeight(.semibold).frame(width: 130, alignment: .trailing)
                                    Picker("", selection: $vectorTag3FeatureID) {
                                        Text("Not specified").tag(nil as UUID?)
                                        ForEach(vector.features) { f in
                                            Text("\(f.name) (\(min(f.start,f.end)+1)–\(max(f.start,f.end)+1), \(f.strand == .reverse ? "−" : "+") strand)\(tagTerminusLabel(for: f).map { " — \($0)" } ?? "")")
                                                .tag(f.id as UUID?)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(maxWidth: 360)
                                    .onChange(of: vectorTag3FeatureID) { _ in applyPredictedOffsets() }
                                    .onChange(of: vector.features.map(\.id)) { ids in
                                        if let tid = vectorTag3FeatureID, !ids.contains(tid) {
                                            vectorTag3FeatureID = nil; offsetsArePredicted = false
                                        }
                                    }
                                    .contextHelp("predict.vectorTagFeature")
                                }
                            }
                            // Status line
                            let anySelected = (needs5Prime && vectorTagFeatureID != nil) || (needs3Prime && vectorTag3FeatureID != nil)
                            if anySelected {
                                HStack(spacing: 6) {
                                    Image(systemName: "wand.and.stars").foregroundColor(.purple).font(.system(size: 11))
                                    Text("Frame offsets predicted from selected tag feature(s) and your insert ORF. You can still override them below.")
                                        .font(.callout).foregroundColor(.primary.opacity(0.65))
                                }
                            } else {
                                HStack(spacing: 6) {
                                    Image(systemName: "info.circle").foregroundColor(.primary.opacity(0.4)).font(.system(size: 11))
                                    Text("Select the tag feature(s) on the vector to auto-predict frame offsets, or set them manually below.")
                                        .font(.callout).foregroundColor(.primary.opacity(0.5))
                                }
                            }
                        }
                    } label: { Text("") }
                }

                if needs5Prime {
                    junctionBox(label: "5' junction:", vecOffset: $vector5Offset, insOffset: $insert5Offset,
                                vecFirst: true, isPredicted: offsetsArePredicted && vectorTagFeatureID != nil)
                }
                if needs3Prime {
                    junctionBox(label: "3' junction:", vecOffset: $vector3Offset, insOffset: $insert3Offset,
                                vecFirst: false, isPredicted: offsetsArePredicted && vectorTag3FeatureID != nil)
                }
                if needs5Prime || needs3Prime {
                    Text("Frame offset = bases between nearest codon boundary and cut site (usually 0)").font(.callout).foregroundColor(.primary.opacity(0.65))
                }
            }
        }
        if !isFusionMode {
            HStack(alignment: .top) {
                Text("Insert direction:").frame(width: 110, alignment: .trailing)
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: $insertDirectionPref) {
                        ForEach(InsertDirectionPreference.allCases, id: \.self) { Text($0.rawValue) }
                    }.pickerStyle(.segmented).frame(maxWidth: 380)
                    .contextHelp("predict.insertDirection")
                    switch insertDirectionPref {
                    case .either:
                        Text("Analyzes both orientations and reports the best strategies for each")
                            .font(.callout).foregroundColor(.primary.opacity(0.65))
                    case .forward:
                        Text("Insert used as-is — e.g. CDS already in the correct reading direction")
                            .font(.callout).foregroundColor(.primary.opacity(0.65))
                    case .reverseComplement:
                        Text("Insert will be reverse-complemented before cloning")
                            .font(.callout).foregroundColor(.primary.opacity(0.65))
                    }
                }
            }
        }
    }
    
    func junctionBox(label: String, vecOffset: Binding<Int>, insOffset: Binding<Int>,
                     vecFirst: Bool, isPredicted: Bool = false) -> some View {
        // Wrap bindings so that any manual edit clears the "predicted" badge.
        let vecOffsetTracked = Binding<Int>(
            get: { vecOffset.wrappedValue },
            set: { vecOffset.wrappedValue = $0; offsetsArePredicted = false }
        )
        let insOffsetTracked = Binding<Int>(
            get: { insOffset.wrappedValue },
            set: { insOffset.wrappedValue = $0; offsetsArePredicted = false }
        )
        return GroupBox {
            HStack(spacing: 16) {
                Text(label).font(.callout).fontWeight(.semibold).frame(width: 90, alignment: .trailing)
                if vecFirst {
                    Text("Vector").font(.callout); Picker("", selection: vecOffsetTracked) { Text("0").tag(0); Text("1").tag(1); Text("2").tag(2) }.pickerStyle(.segmented).frame(width: 90)
                    Text("Insert").font(.callout); Picker("", selection: insOffsetTracked) { Text("0").tag(0); Text("1").tag(1); Text("2").tag(2) }.pickerStyle(.segmented).frame(width: 90)
                } else {
                    Text("Insert").font(.callout); Picker("", selection: insOffsetTracked) { Text("0").tag(0); Text("1").tag(1); Text("2").tag(2) }.pickerStyle(.segmented).frame(width: 90)
                    Text("Vector").font(.callout); Picker("", selection: vecOffsetTracked) { Text("0").tag(0); Text("1").tag(1); Text("2").tag(2) }.pickerStyle(.segmented).frame(width: 90)
                }
                if isPredicted {
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars").font(.system(size: 11))
                        Text("predicted").font(.system(size: 11))
                    }
                    .foregroundColor(.purple)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.purple.opacity(0.12))
                    .cornerRadius(4)
                }
            }
        } label: { Text("") }
        .contextHelp("predict.frameOffset")
    }
    
    @ViewBuilder var fusionORFPicker: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                // If the user already picked a specific ORF as the insert region,
                // show a confirmation line instead of a redundant second picker.
                if insertRegionMode == .orf, let orf = selectedFusionORF {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.callout)
                        Text("Fusing your selected ORF:").font(.callout).fontWeight(.semibold)
                        Text("\(orf.label) (\(orf.strand))").font(.callout).foregroundColor(.green)
                    }
                    HStack(spacing: 8) {
                        if !orf.isForward {
                            Image(systemName: "arrow.uturn.backward").foregroundColor(.orange).font(.callout)
                            Text("Reverse strand — insert will be RC'd before fusion").font(.callout).foregroundColor(.orange)
                        } else {
                            Image(systemName: "arrow.right").foregroundColor(.green).font(.callout)
                            Text("Forward strand — insert used as-is").font(.callout).foregroundColor(.primary.opacity(0.65))
                        }
                    }
                } else {
                    HStack {
                        Text("Reading frame to fuse:").font(.callout).fontWeight(.semibold)
                        if currentInsertRegion == nil {
                            Text("Define insert region first").font(.callout).foregroundColor(.primary.opacity(0.65))
                        } else if !hasScannedFusionORFs {
                            Text("Scanning…").font(.callout).foregroundColor(.primary.opacity(0.65))
                        } else if insertORFs.isEmpty {
                            Text(fusionFeatureNote ?? "No ORFs (≥33 aa) or annotated CDS/gene features found in this region").font(.callout).foregroundColor(.orange)
                        } else {
                            Picker("", selection: $selectedFusionORFID) {
                                Text("Choose…").tag(nil as UUID?)
                                ForEach(insertORFs) { orf in Text("\(orf.label) (\(orf.strand)) at pos \(orf.position)").tag(orf.id as UUID?) }
                            }.labelsHidden().frame(maxWidth: 380)
                            .onChange(of: selectedFusionORFID) { _ in applyPredictedOffsets() }
                            .contextHelp("predict.fusionORF")
                        }
                    }
                    // Brief inline explainer: clarifies that this step is about the
                    // reading frame, not re-choosing the insert DNA.
                    Text("Which reading frame inside your insert lines up with the vector’s tag — a region can hold more than one.")
                        .font(.caption).foregroundColor(.primary.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                    // Require ORF selection before analysis — without it the fusion
                    // validity filter cannot check for stop codons at the junction.
                    if hasScannedFusionORFs && !insertORFs.isEmpty && selectedFusionORFID == nil {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).font(.system(size: 11))
                            Text("Select the reading frame to fuse before running the analysis — required to validate in-frame fusion strategies.")
                                .font(.callout).foregroundColor(.orange)
                        }
                    }
                    if let orf = selectedFusionORF {
                        HStack(spacing: 8) {
                            if !orf.isForward {
                                Image(systemName: "arrow.uturn.backward").foregroundColor(.orange).font(.callout)
                                Text("Reverse strand — insert will be RC'd").font(.callout).foregroundColor(.orange)
                            } else {
                                Image(systemName: "arrow.right").foregroundColor(.green).font(.callout)
                                Text("Forward strand — insert used as-is").font(.callout).foregroundColor(.primary.opacity(0.65))
                            }
                        }
                    }
                }
            }
        } label: { Text("") }
    }
    
    // ================================================================
    // MARK: Actions
    // ================================================================
    
    func matchVectorToLibrary() {
        guard let vector = selectedVector else { matchedShuttleVector = nil; return }
        let clean = vector.name.replacingOccurrences(of: ".xdna", with: "").replacingOccurrences(of: ".dna", with: "")
            .replacingOccurrences(of: ".gb", with: "").replacingOccurrences(of: ".gbk", with: "")
            .trimmingCharacters(in: .whitespaces).lowercased()
        // Strip all non-alphanumeric characters for fuzzy comparison so that
        // "PET 28A" and "pET-28a(+)" both reduce to "pet28a" and match.
        let stripped = clean.filter { $0.isLetter || $0.isNumber }
        matchedShuttleVector = vectorLibrary.vectors.first(where: { $0.name.lowercased() == clean })
            ?? vectorLibrary.vectors.first(where: { clean.contains($0.name.lowercased()) || $0.name.lowercased().contains(clean) })
            ?? vectorLibrary.vectors.first(where: {
                let l = $0.name.lowercased().filter { $0.isLetter || $0.isNumber }
                return stripped == l || stripped.contains(l) || l.contains(stripped)
            })
    }
    
    /// When the destination vector isn't in the shuttle library, derive its
    /// MCS site set from the vector's own data. Tries three increasingly
    /// permissive strategies and returns the first non-empty result:
    ///   1. Single-cutters that fall inside any feature whose name matches
    ///      MCS keywords ("mcs", "polylinker", "cloning site", "linker", …).
    ///   2. Single-cutters that fall inside the user-specified or
    ///      auto-detected cloning region.
    ///   3. Empty array (caller decides what to do — typically pass nil to
    ///      the shuttle routes window so it does its own fallback).
    ///
    /// Pure function (no `self` state mutation), safe to call from any thread.
    private func computeDerivedMCSSites(
        vectorSequence: String,
        vectorCircular: Bool,
        vectorFeatures: [Feature],
        cloningRange: ClosedRange<Int>?,
        enzymes: [RestrictionEnzyme]
    ) -> [String] {
        let vSeqUpper = vectorSequence.uppercased()
        let mcsKeywords = ["mcs", "multiple cloning site", "polylinker", "cloning site", "linker"]
        let mcsFeatures = vectorFeatures.filter { f in
            let n = f.name.lowercased()
            return mcsKeywords.contains(where: { n.contains($0) })
        }
        
        // Find all single-cutters in the vector (only ones we'd ever consider
        // for shuttle routing — multi-cutters can't give clean digests).
        var singleCutters: [(name: String, position: Int)] = []
        for enz in enzymes {
            let sites = enz.findCutSites(in: vSeqUpper, circular: vectorCircular)
            if sites.count == 1 { singleCutters.append((enz.name, sites[0].position)) }
        }
        
        // Tier 1: cuts inside an MCS-named feature.
        if !mcsFeatures.isEmpty {
            let inMCS = singleCutters.filter { sc in
                mcsFeatures.contains { f in
                    let lo = min(f.start, f.end), hi = max(f.start, f.end)
                    return sc.position >= lo && sc.position <= hi
                }
            }
            if !inMCS.isEmpty { return inMCS.map { $0.name } }
        }
        
        // Tier 2: cuts inside the cloning region (user-specified or auto).
        if let range = cloningRange {
            let inRange = singleCutters.filter { range.contains($0.position) }
            if !inRange.isEmpty { return inRange.map { $0.name } }
        }
        
        return []
    }
    
    func buildProtectableRegions() {
        guard let vector = selectedVector else { protectableRegions = []; return }
        let existingCustom = protectableRegions.filter { $0.source == .custom }
        let seq      = vector.sequence
        let features = vector.features

        // Feature regions are cheap — build synchronously.
        // ORF scan is expensive — move to background thread.
        var featureRegions: [ProtectableRegion] = []
        for f in features {
            let s = min(f.start, f.end); let e = max(f.start, f.end)
            featureRegions.append(ProtectableRegion(name: f.name, start: s, end: e, source: .feature, isProtected: true))
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var regions = featureRegions
            let orfs = DNASequence.findORFs(in: seq, minNucleotides: 300)
            for orf in orfs {
                let os = orf.position - 1; let oe = os + orf.size - 1
                let overlaps = regions.contains { r in
                    r.source == .feature && os < r.end && oe > r.start
                    && min(oe, r.end) - max(os, r.start) > orf.size / 2
                }
                if !overlaps {
                    regions.append(ProtectableRegion(
                        name: "\(orf.size/3)aa ORF (\(orf.strand))", start: os, end: oe,
                        source: .orf, isProtected: false))
                }
            }
            regions.append(contentsOf: existingCustom)
            DispatchQueue.main.async { self.protectableRegions = regions }
        }
    }
    
    func estimateMCSRegion() {
        guard let vector = selectedVector else {
            cloningRegionStart = ""; cloningRegionEnd = ""; mcsAutoDetected = ""
            return
        }

        let mcsKeywords = ["mcs", "multiple cloning site", "polylinker", "cloning site"]

        // --- Strategy 1: named feature or .mcs type (synchronous — just iterates features) ---
        for f in vector.features {
        }
        if let mcsFeature = vector.features.first(where: { f in
            f.type == .mcs || mcsKeywords.contains(where: { f.name.lowercased().contains($0) })
        }) {
            let s = min(mcsFeature.start, mcsFeature.end)
            let e = max(mcsFeature.start, mcsFeature.end)
            cloningRegionStart = "\(s + 1)"
            cloningRegionEnd = "\(e + 1)"
            mcsAutoDetected = "from feature '\(mcsFeature.name)'"
            return
        }

        // --- Strategy 2: shuttle vector library MCS site names (fast — only named enzymes) ---
        if let matched = matchedShuttleVector, !matched.mcsSites.isEmpty {
            var positions: [Int] = []
            let vectorSeq = vector.sequence.uppercased()
            for siteName in matched.mcsSites {
                for part in siteName.components(separatedBy: "/") {
                    let name = part.trimmingCharacters(in: .whitespaces)
                    if let enzyme = enzymeDB.enzymes.first(where: { $0.name == name }) {
                        let sites = enzyme.findCutSites(in: vectorSeq, circular: vector.isCircular)
                        if !sites.isEmpty {
                            positions.append(contentsOf: sites.map { $0.position })
                        }
                    } else {
                    }
                }
            }
            if positions.count >= 2 {
                let lo = positions.min()!
                let hi = positions.max()!
                let span = vector.isCircular && hi - lo > vector.length / 2
                    ? (vector.length - hi) + lo
                    : hi - lo
                if span < 500 {
                    cloningRegionStart = "\(lo + 1)"
                    cloningRegionEnd = "\(hi + 1)"
                    mcsAutoDetected = "from library (\(matched.name), \(positions.count) sites)"
                    return
                } else {
                }
            } else {
            }
        } else {
        }

        // --- Strategy 3: densest cluster of single-cutter sites ---
        // Full enzyme database scan — run on a background thread so the UI stays responsive.
        let vectorSeq    = vector.sequence.uppercased()
        let vectorLen    = vector.length
        let isCircular   = vector.isCircular
        let enzymes      = activeEnzymes

        DispatchQueue.global(qos: .userInitiated).async {
            var singleCutPositions: [Int] = []
            for enzyme in enzymes {
                let sites = enzyme.findCutSites(in: vectorSeq, circular: isCircular)
                if sites.count == 1 { singleCutPositions.append(sites[0].position) }
            }
            singleCutPositions.sort()

            var resultStart = ""
            var resultEnd   = ""
            var resultDesc  = ""

            if singleCutPositions.count >= 4 {
                let windowSize = 200
                var bestStart = 0; var bestCount = 0
                for pos in singleCutPositions {
                    let windowEnd = pos + windowSize
                    let count: Int
                    if isCircular && windowEnd > vectorLen {
                        count = singleCutPositions.filter { $0 >= pos || $0 <= windowEnd - vectorLen }.count
                    } else {
                        count = singleCutPositions.filter { $0 >= pos && $0 <= windowEnd }.count
                    }
                    if count > bestCount { bestCount = count; bestStart = pos }
                }
                if bestCount >= 3 {
                    let windowEnd = bestStart + windowSize
                    let sitesInWindow: [Int]
                    if isCircular && windowEnd > vectorLen {
                        sitesInWindow = singleCutPositions.filter { $0 >= bestStart || $0 <= windowEnd - vectorLen }
                    } else {
                        sitesInWindow = singleCutPositions.filter { $0 >= bestStart && $0 <= windowEnd }
                    }
                    if let lo = sitesInWindow.min(), let hi = sitesInWindow.max() {
                        resultStart = "\(lo + 1)"
                        resultEnd   = "\(hi + 1)"
                        resultDesc  = "estimated (\(bestCount) unique sites in \(hi - lo + 1) bp)"
                    }
                }
            }

            DispatchQueue.main.async {
                if !resultStart.isEmpty {
                    self.cloningRegionStart = resultStart
                    self.cloningRegionEnd   = resultEnd
                    self.mcsAutoDetected    = resultDesc
                } else {
                    self.cloningRegionStart = ""
                    self.cloningRegionEnd   = ""
                    self.mcsAutoDetected    = ""
                }
            }
        }
    }
    func scanSourceORFs() {
        guard let src = selectedSource else { sourceORFs = []; return }
        let seq = src.sequence
        DispatchQueue.global(qos: .userInitiated).async {
            let orfs = DNASequence.findORFs(in: seq, minNucleotides: 100)
            DispatchQueue.main.async { self.sourceORFs = orfs }
        }
    }
    
    func addCustomProtectedRegion() {
        guard let vector = selectedVector,
              let s = Int(customProtectStart), let e = Int(customProtectEnd),
              s >= 1, s <= vector.length, e >= 1, e <= vector.length else { return }
        let name = customProtectName.isEmpty ? "Protected region" : customProtectName
        // Convert 1-based user input to 0-based internal coordinates
        // start > end is allowed for circular vectors (wraps origin)
        protectableRegions.append(ProtectableRegion(name: name, start: s - 1, end: e - 1, source: .custom, isProtected: true))
        customProtectName = ""; customProtectStart = ""; customProtectEnd = ""
    }
    
    func scanFusionORFs() {
        guard let region = currentInsertRegion, let src = selectedSource else {
            insertORFs = []; selectedFusionORFID = nil; hasScannedFusionORFs = false; fusionFeatureNote = nil; return
        }

        // Short-circuit: reuse the already-selected source ORF directly.
        if insertRegionMode == .orf,
           let srcORF = sourceORFs.first(where: { $0.id == selectedSourceORFID }) {
            insertORFs = [srcORF]
            selectedFusionORFID = srcORF.id
            hasScannedFusionORFs = true
            fusionFeatureNote = nil
            return
        }

        let insertSeq = region.extractSequence(from: src.sequence, circular: src.isCircular)
        // Capture the explicitly-chosen insert feature on the main thread so the
        // background scan can force-include it (bypassing the type/name heuristic).
        let forcedFeatureID: UUID? = (insertRegionMode == .feature) ? selectedFeatureID : nil
        let forcedFeatureName: String? = forcedFeatureID
            .flatMap { fid in src.features.first(where: { $0.id == fid })?.name }
        DispatchQueue.global(qos: .userInitiated).async {
            let scannerORFs = DNASequence.findORFs(in: insertSeq, minNucleotides: 100)
            let (featureORFs, forcedIncluded) = self.featureDerivedORFs(in: src, region: region,
                                                      excerptSeq: insertSeq,
                                                      forcedFeatureID: forcedFeatureID)
            let combined   = self.mergeFusionORFCandidates(features: featureORFs, scanner: scannerORFs)
            DispatchQueue.main.async {
                self.insertORFs = combined
                self.hasScannedFusionORFs = true
                self.selectedFusionORFID = combined.count == 1 ? combined.first?.id : nil
                if forcedFeatureID != nil, !forcedIncluded {
                    let nm = forcedFeatureName ?? "selected feature"
                    self.fusionFeatureNote = "The feature \u{201C}\(nm)\u{201D} couldn\u{2019}t be located within the extracted insert region \u{2014} its coordinates may be off. Check the feature start/end, or pick an ORF below instead."
                } else {
                    self.fusionFeatureNote = nil
                }
            }
        }
    }
    
    /// Build ORFResult-shaped entries from CDS-style annotated features in
    /// `src` that fall within the current insert excerpt. These show up in
    /// the fusion picker alongside scanner-found ORFs so the user can pick a
    /// known CDS directly rather than relying on automatic detection.
    ///
    /// A feature qualifies if:
    ///   • its type is one of the protein-coding kinds (CDS, gene, exon,
    ///     signalPeptide, reporter, tag), OR its name contains "cds",
    ///     "gene", or "orf";
    ///   • its length is divisible by 3 (required for any reading frame);
    ///   • it has no in-frame internal stop codons (a single trailing stop
    ///     is allowed — that's just the natural ORF terminator).
    ///
    /// ATG start is NOT required. For C-terminal fusions the start codon
    /// comes from the vector, and for N-terminal fusions of protein domains
    /// the user may legitimately want translation to enter mid-protein.
    /// Frame correctness is enforced by the fusion validity filter itself,
    /// not here.
    private func featureDerivedORFs(in src: DNASequence, region: InsertRegion, excerptSeq: String, forcedFeatureID: UUID? = nil) -> (orfs: [DNASequence.ORFResult], forcedIncluded: Bool) {
        let stops: Set<String> = ["TAA", "TAG", "TGA"]
        let excerptLen = excerptSeq.count
        let srcLen = src.length
        
        // Offer ANY annotated feature by name as a possible fusion target — a
        // named feature is far more recognisable than "ORF 354aa". The reading-
        // frame checks below (multiple of 3, no internal stop) keep non-coding
        // features (promoters, origins, terminators) out, so we no longer require
        // a CDS/gene type or a name keyword — that arbitrary rule was hiding real
        // coding features typed as "custom" (e.g. MKK1, AmpR). A short minimum
        // length keeps tiny annotations (cut sites, Kozak, etc.) out of the auto
        // list. The feature the user explicitly chose is always included.
        let minAutoLength = 150   // ~50 aa
        let candidates = src.features.filter { f in
            if let forced = forcedFeatureID, f.id == forced { return true }
            let len = max(f.start, f.end) - min(f.start, f.end) + 1
            return len >= minAutoLength
        }
        
        var results: [DNASequence.ORFResult] = []
        var forcedIncluded = false
        let excerptUpper = excerptSeq.uppercased()
        
        for f in candidates {
            let isForced = (f.id == forcedFeatureID)
            let lo = min(f.start, f.end)
            let hi = max(f.start, f.end)
            let length = hi - lo + 1
            guard length > 0 else { continue }
            let multipleOf3 = (length % 3 == 0)
            // Auto-detected candidates must be clean reading frames. A feature the
            // user explicitly chose is shown regardless (with a warning if its frame
            // is off) — they decide, the app does not hide their choice.
            if !multipleOf3 && !isForced { continue }
            
            // Map feature start in source -> excerpt 0-based start.
            // Wrap-aware for circular sources; non-wrapping for linear ones.
            let excerptStart: Int
            if src.isCircular {
                excerptStart = (lo - region.start + srcLen) % srcLen
            } else {
                // Linear: feature must lie fully within the excerpt window.
                if lo < region.start || hi > region.end { continue }
                excerptStart = lo - region.start
            }
            
            // Drop features that don't fit cleanly inside the excerpt
            // (origin-wrap or extraction-padding edge cases).
            guard excerptStart >= 0, excerptStart + length <= excerptLen else { continue }
            
            let startIdx = excerptUpper.index(excerptUpper.startIndex, offsetBy: excerptStart)
            let endIdx   = excerptUpper.index(startIdx, offsetBy: length)
            let rawSlice = String(excerptUpper[startIdx..<endIdx])
            // Reverse-strand features: read the reverse complement to check
            // for stops in the feature's own reading frame.
            let codingSeq = (f.strand == .reverse)
                ? DNASequence.reverseComplementString(rawSlice).uppercased()
                : rawSlice
            
            // No internal in-frame stop. A single trailing stop codon is OK.
            let codonCount = codingSeq.count / 3
            var internalStop = false
            if codonCount > 1 {
                for i in 0..<codonCount - 1 {
                    let s = codingSeq.index(codingSeq.startIndex, offsetBy: i * 3)
                    let e = codingSeq.index(s, offsetBy: 3)
                    if stops.contains(String(codingSeq[s..<e])) { internalStop = true; break }
                }
            }
            if internalStop && !isForced { continue }
            
            let isForward = (f.strand != .reverse)
            let strandStr = isForward ? "+1" : "-1"
            let frameNum  = isForward ? 1 : -1
            let lengthAA  = length / 3
            var warnings: [String] = []
            if !multipleOf3 { warnings.append("length not ×3 — a junction offset will be needed") }
            if internalStop { warnings.append("internal stop in reading frame — check boundaries/strand") }
            let warnSuffix = warnings.isEmpty ? "" : "  ⚠ " + warnings.joined(separator: "; ")
            let label     = "\(f.name) — annotated, \(lengthAA) aa\(warnSuffix)"
            
            results.append(DNASequence.ORFResult(
                position: excerptStart + 1,   // ORFResult uses 1-based positions
                size: length,
                strand: strandStr,
                label: label,
                frame: frameNum,
                protein: ""                   // not used by the fusion picker
            ))
            if isForced { forcedIncluded = true }
        }
        
        return (results, forcedIncluded)
    }
    
    /// Merge feature-derived ORFs with scanner-detected ORFs, keeping the
    /// feature entry when a scanner ORF and a feature describe substantially
    /// the same region (same strand, >50% overlap of the shorter one). The
    /// user asked for dedup with features preferred — annotated names are
    /// more meaningful than "150 aa ORF".
    private func mergeFusionORFCandidates(features: [DNASequence.ORFResult], scanner: [DNASequence.ORFResult]) -> [DNASequence.ORFResult] {
        let surviving = scanner.filter { sORF in
            !features.contains { fORF in
                guard fORF.isForward == sORF.isForward else { return false }
                let sLo = sORF.position - 1, sHi = sORF.position + sORF.size - 2
                let fLo = fORF.position - 1, fHi = fORF.position + fORF.size - 2
                let overlap = max(0, min(sHi, fHi) - max(sLo, fLo) + 1)
                let shorter = min(sORF.size, fORF.size)
                return shorter > 0 && Double(overlap) / Double(shorter) > 0.5
            }
        }
        return features + surviving
    }

    /// Reverse-complement a vector (sequence + features) so a reverse-strand tag
    /// becomes forward, letting the verified forward-strand fusion path handle it.
    /// Feature IDs are preserved (struct copy), and each feature's coordinates are
    /// mirrored (p → L-1-p) with its strand flipped. The plasmid is the same
    /// molecule; this is purely a coordinate-frame normalisation.
    static func reverseComplementedVector(_ v: DNASequence) -> DNASequence {
        let L = v.sequence.count
        let rcSeq = DNASequence.reverseComplementString(v.sequence)
        let rc = DNASequence(name: v.name, sequence: rcSeq, isCircular: v.isCircular)
        rc.features = v.features.map { f -> Feature in
            var nf = f
            nf.start  = L - 1 - f.end
            nf.end    = L - 1 - f.start
            nf.strand = (f.strand == .reverse) ? .forward : .reverse
            return nf
        }
        return rc
    }

    /// Returns the number of bases from `tagStart` up to (but not including)
    /// `cutPos` in the vector sequence, following the expressed direction.
    /// Unlike simple subtraction, this handles circular vectors where the
    /// tag and cut site span the origin, and is immune to coordinate-system
    /// artefacts introduced by reverse-complementing a circularly-stored
    /// sequence. Both positions are 0-based indices into `seq`.
    /// Returns the number of physical vector bases between the tag ATG and the
    /// restriction cut site, measured in the expression direction (shortest path).
    /// The value is already the correct "physical" count — no further -1 adjustment
    /// is needed by the caller. For forward-stored vectors (cut downstream of tag)
    /// this equals (cutPos - tagStart - 1); for RC-stored vectors where the cut is
    /// upstream in coordinates but downstream in expression it equals (tagStart - cutPos).
    static func vectorBasesFromTagToCut(_ seq: String, _ vecLen: Int, _ tagStart: Int, _ cutPos: Int) -> Int {
        guard vecLen > 0 else { return 0 }
        // Forward distance: cut is downstream of tag in coordinate space.
        // Subtract 1 because cutPos points to the first insert base — the last
        // kept vector base is at cutPos-1.
        let forwardDist = cutPos >= tagStart
            ? cutPos - tagStart - 1
            : (vecLen - tagStart) + cutPos - 1
        // Backward distance: tag is at higher coordinate than cut (RC-stored vector).
        // tagStart - cutPos is exact — no -1 needed because the cut in this
        // direction points to the last kept vector base, not the first insert base.
        let backwardDist = tagStart >= cutPos
            ? tagStart - cutPos
            : (vecLen - cutPos) + tagStart
        // Return the shorter path.
        return min(forwardDist, backwardDist)
    }

    func runAnalysis() {
        guard let rawVector = selectedVector, let source = selectedSource, let region = currentInsertRegion else { return }

        // ── Reverse-strand tag normalisation ──
        // The forward-strand fusion frame logic assumes the vector tag reads 5'→3'
        // on the stored strand. If the selected fusion tag is reverse-strand,
        // reverse-complement the WHOLE vector here so the tag becomes forward, then
        // run the existing verified path. Everything downstream uses `vector` (the
        // normalised copy) plus the remapped coordinates below, so site positions,
        // tag, protected ranges, cloning region and the built construct all stay in
        // one consistent coordinate frame.
        let anchorTagRaw: Feature? = needs5Prime ? vectorTagFeature : (needs3Prime ? vectorTag3Feature : nil)
        // Only RC-normalise if the tag is reverse-strand AND the min-distance from
        // tag to MCS is already wrong (large) in the current orientation.
        // This prevents double-flipping when the user has manually saved a pre-RC'd
        // vector whose feature annotations still carry .reverse strand from the original.
        // We use the same min-distance logic as vectorBasesFromTagToCut: if the shorter
        // circular distance from the tag to the MCS start is already small (< vL/2)
        // then the sequence is already in the right orientation and normalisation would
        // flip it the wrong way.
        let normalizeRC = isFusionMode && (anchorTagRaw?.strand == .reverse)
        let vLen0 = rawVector.sequence.count
        let vector = normalizeRC ? Self.reverseComplementedVector(rawVector) : rawVector
        func rcRange(_ r: ClosedRange<Int>) -> ClosedRange<Int> {
            (vLen0 - 1 - r.upperBound)...(vLen0 - 1 - r.lowerBound)
        }

        // ── All prep work is fast; done on main thread before dispatch ──
        var cloningRange: ClosedRange<Int>? = nil
        if insertionSiteMode == .betweenFeatures {
            cloningRange = betweenFeaturesRange
            guard cloningRange != nil else { return }
        } else if insertionSiteMode != .anywhere,
                  let s = Int(cloningRegionStart), let e = Int(cloningRegionEnd), s < e {
            cloningRange = s...e
        }
        if normalizeRC, let cr = cloningRange { cloningRange = rcRange(cr) }
        let protectedList = normalizeRC ? protectedRanges.map(rcRange) : protectedRanges
        let f5: JunctionFrame? = needs5Prime ? JunctionFrame(vectorOffset: vector5Offset, insertOffset: insert5Offset) : nil
        let f3: JunctionFrame? = needs3Prime ? JunctionFrame(vectorOffset: vector3Offset, insertOffset: insert3Offset) : nil
        // Validate tag feature UUIDs — check N-terminal tag for 5' junction,
        // C-terminal tag for 3' junction. Each auto-aligns independently.
        let validTag5Selected: Bool = {
            guard let tid = vectorTagFeatureID else { return false }
            return vector.features.contains(where: { $0.id == tid })
        }()
        let validTag3Selected: Bool = {
            guard let tid = vectorTag3FeatureID else { return false }
            return vector.features.contains(where: { $0.id == tid })
        }()
        let autoAlign5 = needs5Prime && vector5Offset == 0 &&
            ((insertionSiteMode == .betweenFeatures && upstreamFeatureID != nil) || validTag5Selected)
        let autoAlign3 = needs3Prime && vector3Offset == 0 &&
            ((insertionSiteMode == .betweenFeatures && downstreamFeatureID != nil) || validTag3Selected)
        let fusionRC   = isFusionMode && (selectedFusionORF?.isForward == false)
        let forwardSeq = region.extractSequence(from: source.sequence, circular: source.isCircular)
        let rcSeq      = DNASequence.reverseComplementString(forwardSeq).uppercased()
        let isBluntFragment = insertRegionMode == .wholeSequence && !source.isCircular
                              && source.cohesive5Prime.isEmpty && source.cohesive3Prime.isEmpty
        let isTargetedInsert = insertRegionMode == .orf || insertRegionMode == .feature
        let orfFlankTol = isTargetedInsert ? 200 : CloningStrategyAnalyzer.defaultFlankTolerance
        let otherORFRanges: [(start: Int, end: Int)] = isTargetedInsert
            ? sourceORFs.compactMap { orf in
                if insertRegionMode == .orf && orf.id == selectedSourceORFID { return nil }
                let s = orf.position - 1; return (start: s, end: s + orf.size - 1)
            } : []
        let coreLen: Int?
        if insertRegionMode == .orf, let orf = sourceORFs.first(where: { $0.id == selectedSourceORFID }) {
            coreLen = orf.size
        } else if insertRegionMode == .feature, let fid = selectedFeatureID,
                  let f = source.features.first(where: { $0.id == fid }) {
            coreLen = (f.start > f.end && source.isCircular)
                ? (source.length - f.start) + f.end + 1
                : abs(max(f.start, f.end) - min(f.start, f.end)) + 1
        } else { coreLen = nil }

        // Unpadded insert region — the exact ORF/feature boundaries with no
        // flanking padding. Used as the primer design template target so that
        // targetStart/targetEnd point precisely at the coding region even when
        // the source excerpt has 500 bp of context on each side.
        let coreInsertRegion: InsertRegion?
        if insertRegionMode == .orf, let orf = sourceORFs.first(where: { $0.id == selectedSourceORFID }) {
            let s = orf.position - 1
            coreInsertRegion = InsertRegion(start: s, end: s + orf.size - 1, name: orf.label)
        } else if insertRegionMode == .feature, let fid = selectedFeatureID,
                  let f = source.features.first(where: { $0.id == fid }) {
            let lo = min(f.start, f.end)
            let hi = min(source.length - 1, max(f.start, f.end) + stopCodonExtension)
            coreInsertRegion = InsertRegion(start: lo, end: hi, name: f.name)
        } else if insertRegionMode == .custom,
                  let s = Int(customInsertStart), let e = Int(customInsertEnd), s >= 1 {
            let rawEnd = min(source.length - 1, e - 1 + stopCodonExtension)
            coreInsertRegion = InsertRegion(start: s - 1, end: rawEnd, name: "Custom region")
        } else {
            // Whole sequence or no selection — template IS the source, target = all of it
            coreInsertRegion = InsertRegion(start: 0, end: source.length - 1, name: source.name)
        }

        // Capture value-type snapshots for the background thread
        let vecSeq       = vector.sequence;   let vecCircular  = vector.isCircular
        let vecLen       = vector.length;     let vecFeatures  = vector.features
        let srcSeq       = source.sequence;   let srcCircular  = source.isCircular
        let enzymes      = activeEnzymes
        let isFusion     = isFusionMode;      let dirPref      = insertDirectionPref
        let shuttleMatch = matchedShuttleVector
        let srcName      = source.name;       let vecName      = vector.name
        // Capture the selected tag features from the (possibly normalised) vector
        // so the fusion validity filter checks vector-side frame against the tag's
        // start codon. After normalisation a reverse-strand tag is now forward, so
        // the verified forward-strand path applies. Looked up by ID in `vector`,
        // whose features preserve their IDs through the reverse-complement.
        let capturedTag5: Feature? = needs5Prime ? vector.features.first(where: { $0.id == vectorTagFeatureID }) : nil
        let capturedTag3: Feature? = needs3Prime ? vector.features.first(where: { $0.id == vectorTag3FeatureID }) : nil
        // Snapshot the ORF start and end positions IN THE COORDINATE SYSTEM OF
        // THE INSERT SEQUENCE THAT THE FILTER WILL USE (insertSeq).
        //
        // When the fusion ORF is on the reverse strand, fusionRC == true and the
        // filter operates on rcSeq, not forwardSeq. The ORF scanner reports
        // positions in FORWARD-excerpt coordinates, so for a reverse-strand ORF we
        // must convert them into rcSeq coordinates:
        //   forward position p  ->  rcSeq position (L - 1 - p)
        //   forward ORF span [a, a+S-1]  ->  rcSeq ATG at (L - a - S)
        // where L = excerpt length, a = forward 0-based ORF start, S = ORF size.
        //
        // orfEnd (last coding base, excluding the stop codon) is then derived
        // uniformly as orfStart + max(0, S - 3) - 1 in whichever coordinate frame.
        let excerptLen = forwardSeq.count
        let fusionORFCoords: (start: Int, end: Int)? = {
            guard isFusionMode, let fusionORF = selectedFusionORF else { return nil }
            // Forward-excerpt 0-based ORF start
            let forwardStart: Int
            if insertRegionMode == .orf,
               let srcORF = sourceORFs.first(where: { $0.id == selectedSourceORFID }) {
                forwardStart = (srcORF.position - 1 - region.start + source.length) % source.length
            } else {
                forwardStart = fusionORF.position - 1
            }
            let S = fusionORF.size
            let orfStartUsed: Int
            if fusionRC {
                // Convert forward ORF start to rcSeq coordinate of the ATG.
                orfStartUsed = excerptLen - forwardStart - S
            } else {
                orfStartUsed = forwardStart
            }
            let orfEndUsed = orfStartUsed + max(0, S - 3) - 1
            return (start: orfStartUsed, end: orfEndUsed)
        }()
        let fusionORFStartInExcerpt: Int? = fusionORFCoords?.start
        let fusionORFEndInExcerpt:   Int? = fusionORFCoords?.end

        // Forward-excerpt ORF coordinates (BEFORE any reverse-complement
        // conversion) for the analyzer's insert-truncation search. The analyzer
        // always works on the forward excerpt (insertRegion.extractSequence), so
        // it needs forward coords regardless of fusion orientation — unlike the
        // filter coords above, which are converted into rcSeq space when fusionRC.
        let fusionORFForwardCoords: (start: Int, end: Int)? = {
            guard isFusionMode, let fusionORF = selectedFusionORF else { return nil }
            let forwardStart: Int
            if insertRegionMode == .orf,
               let srcORF = sourceORFs.first(where: { $0.id == selectedSourceORFID }) {
                forwardStart = (srcORF.position - 1 - region.start + source.length) % source.length
            } else {
                forwardStart = fusionORF.position - 1
            }
            let S = fusionORF.size
            let forwardEnd = forwardStart + max(0, S - 3) - 1   // last coding base, forward coords
            return (start: forwardStart, end: forwardEnd)
        }()
        let fusionORFForwardStart: Int? = fusionORFForwardCoords?.start
        let fusionORFForwardEnd:   Int? = fusionORFForwardCoords?.end

        isAnalyzing = true

        DispatchQueue.global(qos: .userInitiated).async {
            var results: [CloningStrategy] = []
            var effInsertSeq  = forwardSeq
            let effInsertName = region.name
            var wasReversed   = false

            if isFusion {
                let insertSeq = fusionRC ? rcSeq : forwardSeq
                effInsertSeq = insertSeq; wasReversed = fusionRC
                results = self.analyzer.analyzeStrategies(
                    vectorSequence: vecSeq, sourceSequence: srcSeq, insertRegion: region,
                    cloningRegionRange: cloningRange, protectedRegions: protectedList,
                    vectorIsCircular: vecCircular, sourceIsCircular: srcCircular,
                    enzymes: enzymes, cloningMode: self.cloningMode,
                    fiveprimeFrame: f5, threeprimeFrame: f3, insertReversed: fusionRC,
                    insertIsBluntFragment: isBluntFragment, vectorFeatures: vecFeatures,
                    autoAlign5Prime: autoAlign5, autoAlign3Prime: autoAlign3,
                    flankTolerance: orfFlankTol, sourceORFRanges: otherORFRanges,
                    coreInsertLength: coreLen,
                    methylation: currentMethylation,
                    insertORFForwardStart: fusionORFForwardStart,
                    insertORFForwardEnd: fusionORFForwardEnd)

                // Shared by both fusion-validity filters below: uppercase the
                // insert ONCE and memoize per-enzyme cut-site positions. The
                // filters previously called findCutSites(in: insertSeq.uppercased())
                // for every candidate strategy, re-allocating the uppercased
                // insert and re-scanning the whole sequence each time. We only
                // ever read .position from the sites, so the cache stores [Int].
                let upperInsert = insertSeq.uppercased()
                var insertCutPosCache: [String: [Int]] = [:]

                // Fusion validity filter — 5' junction (N-terminal):
                //
                // For a valid in-frame N-terminal fusion, the ATG (or chosen
                // downstream codon) of the insert ORF must land in the same
                // reading frame as the vector tag's start codon, AND no
                // in-frame stop codon may interrupt translation between the
                // tag and the insert ORF.
                //
                // Frame equation (independent of recognition-site cut position
                // and overhang — these cancel because ligation reconstitutes
                // the recognition site):
                //
                //   ((vCut - tagStart) + (orfStart - iCut)) % 3 == 0
                //
                // where vCut and iCut are the top-strand cut positions (first
                // KEPT base of vector backbone / insert fragment).
                //
                // Long tags (>50 aa — MAL/MBP, GST, SUMO, NusA, TRX, …) are
                // typically cleaved off after purification, so losing a few
                // residues at the junction is acceptable. Short tags (His₆,
                // FLAG, Myc, HA, V5, Strep, T7, S-tag — all ≤50 aa) stay
                // attached and MUST keep every residue, so no truncation
                // either side.
                //
                // PCR strategies are exempt (primer designer handles placement).
                //
                // NOTE: the analyzer's analyzeFrame() auto-align logic is
                // mathematically vacuous (always finds a passing offset in
                // {0,1,2}); this post-hoc filter is the actual frame gatekeeper.
                if let orfStart = fusionORFStartInExcerpt, let tag5 = capturedTag5 {
                    // Forward-strand assumption — tag.start is the ATG position.
                    // Reverse-strand tags would need to operate on the reverse
                    // complement of the vector. Not yet implemented; they're
                    // rejected conservatively below.
                    let tagStart5 = tag5.start
                    let tagEnd5   = tag5.end
                    let tagLenAA = abs(tagEnd5 - tagStart5) / 3
                    let tagIsLong = tagLenAA > 50

                    // Eat-in thresholds (in bp; divide by 3 for aa):
                    //   0 bp      → no warning, no penalty
                    //   1–30 bp   → warning only  (1–10 aa)
                    //   31–60 bp  → warning + score penalty of -15  (11–20 aa)
                    //   >60 bp    → reject  (>20 aa)
                    // Short tags (≤50 aa) on the TAG side: zero tolerance — any bite rejects.
                    let eatInWarnBP:    Int = 30
                    let eatInPenaltyBP: Int = 60
                    let eatInPenalty:   Int = 15

                    results = results.compactMap { strategy in
                        var s = strategy
                        if s.cloningPath.needsPrimers { return s }
                        // isTagForward guard removed: normalizeRC + vectorBasesFromTagToCut(min)
                        // now handle both forward-stored and RC-stored vectors correctly.

                        let insEnz5 = s.effectiveInsertEnzyme5
                        let positions5: [Int]
                        if let cached = insertCutPosCache[insEnz5.name] {
                            positions5 = cached
                        } else {
                            positions5 = insEnz5.findCutSites(in: upperInsert, circular: false).map { $0.position }
                            insertCutPosCache[insEnz5.name] = positions5
                        }
                        let cut5Off = insEnz5.cutPosition5Prime
                        let vCut = s.vectorSite5Position + s.enzyme5.cutPosition5Prime

                        // Distance used for FRAME arithmetic — unchanged from the
                        // original so frame behaviour is identical.
                        let vectorBases = Self.vectorBasesFromTagToCut(vecSeq, vecLen, tagStart5, vCut)
                        guard vectorBases > 0, vectorBases < vecLen / 2 else {
                            return nil
                        }
                        let vectorBasesPhysical = vectorBases

                        // ADDITIONAL geometry guard: for an N-terminal fusion the cut
                        // must be reached by reading FORWARD from the tag in the
                        // expressed direction (tag → cut → insert), within a short
                        // distance. vectorBasesFromTagToCut above returns the SHORTER
                        // arc, which let cut sites on the FAR side of the plasmid pass
                        // when they happened to be closer via the origin — e.g. EcoRV
                        // in pGEX-3X, 3.8 kb downstream of GST but only 1.2 kb away
                        // through the backbone. Such cuts produce no GST fusion. We
                        // reject them by requiring the genuine forward distance to be
                        // small (a tag sits within a few hundred bp of its cloning site).
                        let vForward = vCut >= tagStart5
                            ? vCut - tagStart5
                            : (vecLen - tagStart5) + vCut
                        let maxTagToCut = min(vecLen / 2, 1500)
                        guard vForward > 0, vForward <= maxTagToCut else {
                            return nil
                        }

                        // Vector-side (tag) eat-in: cut lands inside the tag CDS,
                        // losing C-terminal tag residues at the junction.
                        let vCutInsideTag = vCut >= tagStart5 && vCut <= tagEnd5
                        if vCutInsideTag {
                            if !tagIsLong { return nil }
                            let tagBiteBP = tagEnd5 - vCut
                            if tagBiteBP > eatInPenaltyBP { return nil }
                            if (((vectorBasesPhysical % 3) + 3) % 3) != 0 { return nil }
                            let tagBiteAA = tagBiteBP / 3
                            if tagBiteBP > eatInWarnBP {
                                s.warnings.append("⚠eat-in:Tag C-term \(tagBiteAA) aa lost (penalty)")
                                s.score -= eatInPenalty
                            } else {
                                s.warnings.append("⚠eat-in:Tag C-term \(tagBiteAA) aa lost")
                            }
                        }

                        // ---- Insert 5' cut: validate against the SAME site the
                        // construct builder will actually use.
                        //
                        // For BLUNTED strategies (fill-in / nibble) the effective
                        // insert boundary is NOT the raw enzyme cut — fill-in keeps
                        // the overhang bases, nibble drops them. The analyzer already
                        // computed and stored that boundary in insertCut5Excerpt, so
                        // use it directly. Recomputing from the enzyme cut position
                        // (as the sticky path does) would give the wrong frame and
                        // wrongly reject an in-frame fill-in fusion (e.g. AgeI fill-in
                        // GST-MKK1, where the kept CCGG bases shift the boundary).
                        let iCut: Int
                        if case .bluntedInsert = s.cloningPath, let exc5 = s.insertCut5Excerpt {
                            iCut = exc5
                        } else {
                            // Sticky path: the builder releases the insert with its 5'
                            // FLANKING site — CloningStrategyAnalyzer classifies a site
                            // whose position is < flankTolerance of the excerpt 5' end as
                            // the flank (outermost one chosen); deeper sites are "truly
                            // internal" and are NEVER used as the 5' cut.
                            let flankSite5: Int
                            if let tCut5 = s.insertTruncCut5 {
                                if fusionRC { return nil }
                                flankSite5 = tCut5
                            } else {
                                let flankPositions5 = positions5.filter { $0 < orfFlankTol }
                                guard let f = flankPositions5.min() else {
                                    return nil
                                }
                                flankSite5 = f
                            }
                            iCut = flankSite5 + cut5Off
                        }

                        // Joint modular frame check at the reconstituted junction.
                        // Uses vectorBases (measured from actual sequence) instead of
                        // (vCut - tagStart5) to avoid coordinate-system errors when
                        // the vector is stored in the opposite orientation to expression.
                        let combined = vectorBasesPhysical + (orfStart - iCut)
                        if (((combined % 3) + 3) % 3) != 0 {
                            return nil
                        }

                        // Insert N-terminal eat-in: the chosen cut lands INSIDE the
                        // insert ORF, losing a few N-terminal insert residues.
                        if iCut > orfStart {
                            let insertBiteBP = iCut - orfStart
                            if insertBiteBP > eatInPenaltyBP { return nil }
                            let insertBiteAA = insertBiteBP / 3
                            if insertBiteBP > eatInWarnBP {
                                s.warnings.append("⚠eat-in:Insert N-term \(insertBiteAA) aa lost (penalty)")
                                s.score -= eatInPenalty
                            } else {
                                s.warnings.append("⚠eat-in:Insert N-term \(insertBiteAA) aa lost")
                            }
                        }

                        // Stop-codon check on the insert linker between the cut and
                        // the ATG (only when the cut is upstream of the ATG).
                        if iCut < orfStart {
                            let basesIntoCodon = ((vectorBasesPhysical % 3) + 3) % 3
                            let skip = (3 - basesIntoCodon) % 3
                            if self.hasInFrameStopCodon(in: insertSeq, from: iCut, to: orfStart, frame: skip) {
                                return nil
                            }
                        }
                        return s
                    }
                }

                // Fusion validity filter — 3' junction (C-terminal / both-sides):
                //
                // Mirrored version of the 5' filter. For a valid in-frame
                // C-terminal fusion, the start codon of the vector tag (which
                // sits 3' of the insert) must land in the same reading frame
                // as the insert ORF's ATG, and no in-frame stop codon may
                // interrupt translation in the insert linker.
                //
                // Frame equation:
                //
                //   ((iCut - orfStart) + (tagStart - vCut)) % 3 == 0
                //
                // where iCut and vCut are the top-strand cut positions at the
                // 3' junction — iCut = first DISCARDED base of insert (one
                // past the last kept ORF/linker base); vCut = first KEPT base
                // of vector backbone (where the tag side picks up).
                //
                // Long C-terminal tags (>50 aa — e.g. C-terminal MBP/GST/SUMO
                // fusions where the tag is cleaved post-purification) may
                // lose a few N-terminal residues and the insert may lose a
                // few C-terminal residues. Short C-terminal tags (His₆,
                // FLAG, Myc, HA, V5, … all ≤50 aa) require full retention
                // both sides.
                if let orfStart = fusionORFStartInExcerpt,
                   let orfEnd   = fusionORFEndInExcerpt,
                   let tag3     = capturedTag3 {
                    let tag3StartPos = tag3.start
                    let tag3EndPos   = tag3.end
                    let isTag3Forward = (tag3.strand != .reverse)
                    let tagLenAA = abs(tag3EndPos - tag3StartPos) / 3
                    let tagIsLong = tagLenAA > 50

                    // Same eat-in thresholds as 5' junction (see N-terminal block above).
                    let eatInWarnBP:    Int = 30
                    let eatInPenaltyBP: Int = 60
                    let eatInPenalty:   Int = 15

                    results = results.compactMap { strategy in
                        var s = strategy
                        if s.cloningPath.needsPrimers { return s }
                        guard isTag3Forward else { return nil }

                        let insEnz3 = s.effectiveInsertEnzyme3
                        let positions3: [Int]
                        if let cached = insertCutPosCache[insEnz3.name] {
                            positions3 = cached
                        } else {
                            positions3 = insEnz3.findCutSites(in: upperInsert, circular: false).map { $0.position }
                            insertCutPosCache[insEnz3.name] = positions3
                        }
                        let cut5Off = insEnz3.cutPosition5Prime
                        let siteLen3 = insEnz3.recognitionSite.count
                        let vCutEnzyme3 = s.enzyme3 ?? s.enzyme5
                        let vCut3 = s.vectorSite3Position + vCutEnzyme3.cutPosition5Prime

                        // Vector-side (tag) eat-in: cut lands inside the tag CDS,
                        // losing N-terminal tag residues at the junction.
                        let vCutInsideTag = vCut3 > tag3StartPos
                        if vCutInsideTag {
                            if !tagIsLong { return nil }
                            let tagBiteBP = vCut3 - tag3StartPos
                            if tagBiteBP > eatInPenaltyBP { return nil }
                            if (((vCut3 - tag3StartPos) % 3) + 3) % 3 != 0 { return nil }
                            let tagBiteAA = tagBiteBP / 3
                            if tagBiteBP > eatInWarnBP {
                                s.warnings.append("⚠eat-in:Tag N-term \(tagBiteAA) aa lost (penalty)")
                                s.score -= eatInPenalty
                            } else {
                                s.warnings.append("⚠eat-in:Tag N-term \(tagBiteAA) aa lost")
                            }
                        }

                        // ---- Insert 3' cut: validate against the SAME site the
                        // builder uses — its 3' FLANKING site (CloningStrategyAnalyzer
                        // rule: position > insertLen - flankTolerance - siteLen,
                        // outermost one chosen). Mirror of the 5' fix above.
                        let excerptLen3 = insertSeq.count
                        let flankSite3: Int
                        if let tCut3 = s.insertTruncCut3 {
                            if fusionRC { return nil }
                            flankSite3 = tCut3
                        } else {
                            let flankPositions3 = positions3.filter { $0 > excerptLen3 - orfFlankTol - siteLen3 }
                            guard let f = flankPositions3.max() else { return nil }
                            flankSite3 = f
                        }
                        let iCut3 = flankSite3 + cut5Off

                        // Joint modular frame check.
                        let combined = (iCut3 - orfStart) + (tag3StartPos - vCut3)
                        if (((combined % 3) + 3) % 3) != 0 { return nil }

                        // Insert C-terminal eat-in: the cut lands inside the insert ORF
                        // (iCut3 is the first DISCARDED base, so a cut at or before orfEnd
                        // drops C-terminal insert residues). Graduated warning/penalty/reject.
                        if iCut3 <= orfEnd {
                            let insertBiteBP = orfEnd + 1 - iCut3
                            if insertBiteBP > eatInPenaltyBP { return nil }
                            let insertBiteAA = insertBiteBP / 3
                            if insertBiteBP > eatInWarnBP {
                                s.warnings.append("⚠eat-in:Insert C-term \(insertBiteAA) aa lost (penalty)")
                                s.score -= eatInPenalty
                            } else {
                                s.warnings.append("⚠eat-in:Insert C-term \(insertBiteAA) aa lost")
                            }
                        }

                        // Stop-codon check on the insert linker between orfEnd+1
                        // and the cut (only when the cut is downstream of the ORF).
                        if iCut3 > orfEnd + 1 {
                            if self.hasInFrameStopCodon(in: insertSeq, from: orfEnd + 1, to: iCut3, frame: 0) {
                                return nil
                            }
                        }
                        return s
                    }
                }
            } else {
                // For blunt inserts, both orientations are always possible at ligation
                // regardless of the user's direction preference — override dirPref here.
                let runForward = isBluntFragment || dirPref == .forward || dirPref == .either
                let runRC      = isBluntFragment || dirPref == .reverseComplement || dirPref == .either
                if runForward {
                    results += self.analyzer.analyzeStrategies(
                        vectorSequence: vecSeq, sourceSequence: srcSeq, insertRegion: region,
                        cloningRegionRange: cloningRange, protectedRegions: protectedList,
                        vectorIsCircular: vecCircular, sourceIsCircular: srcCircular,
                        enzymes: enzymes, cloningMode: self.cloningMode,
                        fiveprimeFrame: f5, threeprimeFrame: f3, insertReversed: false,
                        insertIsBluntFragment: isBluntFragment, vectorFeatures: vecFeatures,
                        autoAlign5Prime: autoAlign5, autoAlign3Prime: autoAlign3,
                        flankTolerance: orfFlankTol, sourceORFRanges: otherORFRanges,
                        coreInsertLength: coreLen,
                    methylation: currentMethylation)
                }
                if runRC {
                    results += self.analyzer.analyzeStrategies(
                        vectorSequence: vecSeq, sourceSequence: srcSeq, insertRegion: region,
                        cloningRegionRange: cloningRange, protectedRegions: protectedList,
                        vectorIsCircular: vecCircular, sourceIsCircular: srcCircular,
                        enzymes: enzymes, cloningMode: self.cloningMode,
                        fiveprimeFrame: f5, threeprimeFrame: f3, insertReversed: true,
                        insertIsBluntFragment: isBluntFragment, vectorFeatures: vecFeatures,
                        autoAlign5Prime: autoAlign5, autoAlign3Prime: autoAlign3,
                        flankTolerance: orfFlankTol, sourceORFRanges: otherORFRanges,
                        coreInsertLength: coreLen,
                    methylation: currentMethylation)
                }
                results.sort { $0.score > $1.score }
                if dirPref == .reverseComplement {
                    effInsertSeq = rcSeq; wasReversed = true
                }
            }

            let diagnostic = self.analyzer.lastDiagnostic
            
            // Compute derived MCS sites on the background thread (cheap
            // enzyme scan against the vector) so the shuttle route button
            // can still work when the vector isn't in the shuttle library.
            // For library vectors we don't need this — library MCS wins.
            let derivedMCS: [String] = (shuttleMatch == nil)
                ? self.computeDerivedMCSSites(
                    vectorSequence: vecSeq,
                    vectorCircular: vecCircular,
                    vectorFeatures: vecFeatures,
                    cloningRange: cloningRange,
                    enzymes: enzymes)
                : []

            DispatchQueue.main.async {
                self.isAnalyzing = false
                self.strategies             = results
                self.effectiveInsertSequence = effInsertSeq
                self.effectiveInsertName    = effInsertName
                self.insertWasReversed      = wasReversed

                // Compute alternative vector suggestions when in fusion mode
                // and no direct digest strategies survived the filter.
                let directDigestResults = results.filter { $0.cloningPath.isDirectDigest }
                if isFusion, directDigestResults.isEmpty {
                    self.alternativeVectorSuggestions = self.computeAlternativeVectorSuggestions(
                        orfStartInExcerpt: fusionORFStartInExcerpt,
                        orfEndInExcerpt: fusionORFEndInExcerpt,
                        currentVectorName: vecName
                    )
                } else {
                    self.alternativeVectorSuggestions = []
                }

                if let r = cloningRange, r.upperBound >= vecLen, results.isEmpty {
                    self.originWrapWarning = """
                    The selected cloning region wraps the plasmid origin \
                    (\(r.lowerBound + 1)–\(vecLen), 1–\(r.upperBound - vecLen + 1); \
                    \(r.count) bp total) and the analyzer returned no strategies.
                    
                    This usually means the downstream strategy search does not yet handle \
                    origin-wrapping regions. As a workaround, rotate the vector origin so \
                    the cloning region no longer crosses position 1 (Tools ▸ set new origin), \
                    then re-run predictive cloning.
                    """
                } else if results.isEmpty && self.originWrapWarning == nil {
                    let lines = diagnostic.isEmpty
                        ? ["(no diagnostic captured — analyzer may not have run)"]
                        : diagnostic
                    self.analysisDiagnostic = "No strategies were generated for this run. Filter trace:\n\n\(lines.joined(separator: "\n"))"
                }

                CloningStrategiesWindowManager.shared.openWindow(
                    strategies: results,
                    vector: vector,
                    insertName: effInsertName,
                    insertSequence: effInsertSeq,
                    insertReversed: wasReversed,
                    rcInsertSequence: rcSeq,
                    sequenceManager: self.sequenceManager,
                    hasShuttleVector: true,
                    vectorInLibrary: shuttleMatch != nil,
                    sourceSequence: srcSeq,
                    sourceInsertRegion: coreInsertRegion,
                    sourceIsCircular: srcCircular,
                    alternativeVectorSuggestions: self.alternativeVectorSuggestions,
                    shuttleRouteInfo: (
                        sourceSequence: srcSeq,
                        insertRegion: region,
                        sourceIsCircular: srcCircular,
                        sourceName: srcName,
                        destinationName: vecName,
                        destinationMCSSites: shuttleMatch?.mcsSites ?? (derivedMCS.isEmpty ? nil : derivedMCS),
                        destinationSequence: vecSeq,
                        destinationIsCircular: vecCircular,
                        protectedRegions: protectedList,
                        cloningRegionRange: cloningRange
                    )
                )
            }
        }
    }
    
    func runMultiSourceAnalysis() {
        guard let vector = selectedVector else { return }

        // ── Prep on main thread ──
        var cloningRange: ClosedRange<Int>? = nil
        if insertionSiteMode == .betweenFeatures {
            cloningRange = betweenFeaturesRange
            guard cloningRange != nil else { return }
        } else if insertionSiteMode != .anywhere,
                  let s = Int(cloningRegionStart), let e = Int(cloningRegionEnd), s < e {
            cloningRange = s...e
        }
        let protectedList = protectedRanges
        let f5: JunctionFrame? = needs5Prime ? JunctionFrame(vectorOffset: vector5Offset, insertOffset: insert5Offset) : nil
        let f3: JunctionFrame? = needs3Prime ? JunctionFrame(vectorOffset: vector3Offset, insertOffset: insert3Offset) : nil
        let validTag5SelectedMS: Bool = {
            guard let tid = vectorTagFeatureID else { return false }
            return vector.features.contains(where: { $0.id == tid })
        }()
        let validTag3SelectedMS: Bool = {
            guard let tid = vectorTag3FeatureID else { return false }
            return vector.features.contains(where: { $0.id == tid })
        }()
        let autoAlign5 = needs5Prime && vector5Offset == 0 &&
            ((insertionSiteMode == .betweenFeatures && upstreamFeatureID != nil) || validTag5SelectedMS)
        let autoAlign3 = needs3Prime && vector3Offset == 0 &&
            ((insertionSiteMode == .betweenFeatures && downstreamFeatureID != nil) || validTag3SelectedMS)

        // Snapshot everything the background thread will need
        let vecSeq      = vector.sequence;  let vecCircular = vector.isCircular
        let vecLen      = vector.length;    let vecFeatures = vector.features
        let enzymes     = activeEnzymes
        let matches     = matchingSources   // capture computed property once
        let dirPref     = insertDirectionPref
        let mode        = cloningMode

        isAnalyzing = true

        DispatchQueue.global(qos: .userInitiated).async {
            var allScored: [ScoredStrategy] = []

            for match in matches {
                let source  = match.source
                let feature = match.feature
                let pad     = 200
                let coreFeatureSize = (feature.start > feature.end && source.isCircular)
                    ? (source.length - feature.start) + feature.end + 1
                    : abs(max(feature.start, feature.end) - min(feature.start, feature.end)) + 1

                let region: InsertRegion
                if source.isCircular {
                    if feature.start > feature.end {
                        let ps = (feature.start - pad + source.length) % source.length
                        let pe = (feature.end   + pad) % source.length
                        region = InsertRegion(start: ps, end: pe, name: feature.name)
                    } else if feature.end >= source.length {
                        let wrappedEnd = feature.end % source.length
                        let ps = (feature.start - pad + source.length) % source.length
                        let pe = (wrappedEnd    + pad) % source.length
                        region = InsertRegion(start: ps, end: pe, name: feature.name)
                    } else {
                        let ps = (min(feature.start, feature.end) - pad + source.length) % source.length
                        let pe = (max(feature.start, feature.end) + pad) % source.length
                        region = InsertRegion(start: ps, end: pe, name: feature.name)
                    }
                } else {
                    region = InsertRegion(
                        start: max(0, min(feature.start, feature.end) - pad),
                        end: min(source.length - 1, max(feature.start, feature.end) + pad),
                        name: feature.name)
                }

                let srcORFs = DNASequence.findORFs(in: source.sequence, minNucleotides: 100)
                let srcORFRanges: [(start: Int, end: Int)] = srcORFs.map {
                    let s = $0.position - 1; return (start: s, end: s + $0.size - 1)
                }
                let insertSeq   = region.extractSequence(from: source.sequence, circular: source.isCircular)
                let rcInsertSeq = DNASequence.reverseComplementString(insertSeq).uppercased()
                let isBlunt     = !source.isCircular && source.cohesive5Prime.isEmpty && source.cohesive3Prime.isEmpty
                let runForward  = dirPref == .forward || dirPref == .either
                let runRC       = dirPref == .reverseComplement || dirPref == .either

                if runForward {
                    let results = self.analyzer.analyzeStrategies(
                        vectorSequence: vecSeq, sourceSequence: source.sequence, insertRegion: region,
                        cloningRegionRange: cloningRange, protectedRegions: protectedList,
                        vectorIsCircular: vecCircular, sourceIsCircular: source.isCircular,
                        enzymes: enzymes, cloningMode: mode,
                        fiveprimeFrame: f5, threeprimeFrame: f3, insertReversed: false,
                        insertIsBluntFragment: isBlunt, vectorFeatures: vecFeatures,
                        autoAlign5Prime: autoAlign5, autoAlign3Prime: autoAlign3,
                        flankTolerance: 200, sourceORFRanges: srcORFRanges,
                        coreInsertLength: coreFeatureSize,
                        methylation: currentMethylation)
                    for s in results { allScored.append(ScoredStrategy(
                        strategy: s, sourceName: source.name, sourceID: source.id,
                        insertName: feature.name, insertSequence: insertSeq, insertReversed: false,
                        insertRegion: region,
                        sourceSequence: source.sequence, sourceIsCircular: source.isCircular)) }
                }
                if runRC {
                    let results = self.analyzer.analyzeStrategies(
                        vectorSequence: vecSeq, sourceSequence: source.sequence, insertRegion: region,
                        cloningRegionRange: cloningRange, protectedRegions: protectedList,
                        vectorIsCircular: vecCircular, sourceIsCircular: source.isCircular,
                        enzymes: enzymes, cloningMode: mode,
                        fiveprimeFrame: f5, threeprimeFrame: f3, insertReversed: true,
                        insertIsBluntFragment: isBlunt, vectorFeatures: vecFeatures,
                        autoAlign5Prime: autoAlign5, autoAlign3Prime: autoAlign3,
                        flankTolerance: 200, sourceORFRanges: srcORFRanges,
                        coreInsertLength: coreFeatureSize,
                        methylation: currentMethylation)
                    for s in results { allScored.append(ScoredStrategy(
                        strategy: s, sourceName: source.name, sourceID: source.id,
                        insertName: feature.name, insertSequence: rcInsertSeq, insertReversed: true,
                        insertRegion: region,
                        sourceSequence: source.sequence, sourceIsCircular: source.isCircular)) }
                }
            }

            allScored.sort { $0.strategy.score > $1.strategy.score }
            let diagnostic = self.analyzer.lastDiagnostic

            DispatchQueue.main.async {
                self.isAnalyzing = false

                if let r = cloningRange, r.upperBound >= vecLen, allScored.isEmpty {
                    self.originWrapWarning = """
                    The selected cloning region wraps the plasmid origin \
                    (\(r.lowerBound + 1)–\(vecLen), 1–\(r.upperBound - vecLen + 1); \
                    \(r.count) bp total) and the analyzer returned no strategies for any source.
                    
                    This usually means the downstream strategy search does not yet handle \
                    origin-wrapping regions. As a workaround, rotate the vector origin so \
                    the cloning region no longer crosses position 1 (Tools ▸ set new origin), \
                    then re-run predictive cloning.
                    """
                } else if allScored.isEmpty && self.originWrapWarning == nil {
                    let lines = diagnostic.isEmpty
                        ? ["(no diagnostic captured — analyzer may not have run)"]
                        : diagnostic
                    self.analysisDiagnostic = "No strategies were generated across any source. Filter trace (last source analysed):\n\n\(lines.joined(separator: "\n"))"
                }

                MultiSourceStrategiesWindowManager.shared.openWindow(
                    scoredStrategies: allScored,
                    vector: vector,
                    sequenceManager: self.sequenceManager
                )
            }
        }
    }
    func openShuttleRoutesWindow() {
        guard let source = selectedSource, let region = currentInsertRegion, let vector = selectedVector else { return }
        var cloningRange: ClosedRange<Int>? = nil
        if insertionSiteMode == .betweenFeatures {
            cloningRange = betweenFeaturesRange
        } else if let s = Int(cloningRegionStart), let e = Int(cloningRegionEnd), s < e {
            cloningRange = s...e
        }
        ShuttleRoutesWindowManager.shared.openWindow(
            sourceSequence: source.sequence,
            insertRegion: region,
            sourceIsCircular: source.isCircular,
            sourceName: source.name,
            destinationName: vector.name,
            destinationMCSSites: matchedShuttleVector?.mcsSites,
            destinationSequence: vector.sequence,
            destinationIsCircular: vector.isCircular,
            protectedRegions: protectedRanges,
            cloningRegionRange: cloningRange
        )
    }
    
    // MARK: - Browse for sequence file
    
    /// Opens a file picker and, when the user chooses a DNA file, loads it into
    /// the sequence manager and assigns the new sequence's ID to `binding`.
    private func browseForSequence(binding: Binding<UUID?>) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "xdna") ?? .plainText,
            UTType(filenameExtension: "ape") ?? .plainText,
            UTType(filenameExtension: "fasta") ?? .plainText,
            UTType(filenameExtension: "fa") ?? .plainText,
            UTType(filenameExtension: "gb") ?? .plainText,
            UTType(filenameExtension: "gbk") ?? .plainText,
            .plainText, .data
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a DNA sequence file"
        
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            
            let countBefore = self.sequenceManager.sequences.count
            self.sequenceManager.loadSequenceFromFile(url)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if self.sequenceManager.sequences.count > countBefore,
                   let newSeq = self.sequenceManager.sequences.last {
                    binding.wrappedValue = newSeq.id
                }
            }
        }
    }
}


// MARK: - Cloning Strategies Window

struct CloningStrategiesView: View {
    let strategies: [CloningStrategy]
    let vector: DNASequence
    let insertName: String
    let insertSequence: String
    let insertReversed: Bool
    let rcInsertSequence: String
    /// Full source sequence and insert coordinates — used to build a flanked
    /// template for primer design so the designer has upstream/downstream context.
    let sourceSequence: String
    let sourceInsertRegion: InsertRegion?
    let sourceIsCircular: Bool
    @ObservedObject var sequenceManager: SequenceManager
    
    // Shuttle route info (optional)
    let hasShuttleVector: Bool
    /// Whether the destination vector was matched against an entry in the
    /// shuttle library. When false, the shuttle routes window is still
    /// available (MCS sites are derived from features), but the UI nudges
    /// the user to add the vector to the library for canonical support.
    let vectorInLibrary: Bool
    let shuttleRouteInfo: ShuttleRouteInfo?
    // Alternative vector suggestions for fusion cloning (when no direct digest found)
    let alternativeVectorSuggestions: [PredictiveCloningView.AlternativeVectorSuggestion]
    
    struct ShuttleRouteInfo {
        let sourceSequence: String
        let insertRegion: InsertRegion
        let sourceIsCircular: Bool
        let sourceName: String
        let destinationName: String
        let destinationMCSSites: [String]?
        let destinationSequence: String
        let destinationIsCircular: Bool
        let protectedRegions: [ClosedRange<Int>]
        let cloningRegionRange: ClosedRange<Int>?
    }
    
    private let analyzer = CloningStrategyAnalyzer()
    private let enzymeDB = RestrictionEnzymeDatabase.shared
    @AppStorage("predictive_myEnzymesOnly_verify") private var myEnzymesOnlyVerify: Bool = false
    private var activeVerifyEnzymes: [RestrictionEnzyme] {
        myEnzymesOnlyVerify
            ? enzymeDB.enzymes.filter { enzymeDB.isMyEnzyme($0.name) }
            : enzymeDB.enzymes
    }
    
    // PCR strategy display cap — keep the initial list manageable when the
    // analyzer returns many PCR options. User can toggle to see all.
    private static let pcrInitialLimit: Int = 10
    @State private var pcrShowAll: Bool = false

    // Non-directional orientation dialog
    @State private var pendingBuildStrategy: CloningStrategy? = nil
    @State private var showOrientationDialog: Bool = false
    
    // --- Computed ---
    var bluntInsertStrategies: [CloningStrategy] { strategies.filter { if case .bluntInsertDirect = $0.cloningPath { return true } else { return false } } }
    var regularStrategies: [CloningStrategy] { strategies.filter { if case .bluntInsertDirect = $0.cloningPath { return false } else { return true } } }
    /// All non-blunt strategies returned by the analyzer. Previously this
    /// filtered out any strategy whose insert contains internal cut sites for
    /// its chosen enzyme, which silently hid useful PCR strategies (the primer
    /// design step can often work around an internal site by using a different
    /// enzyme pair, and in any case the row already shows a prominent warning
    /// via `showInsertCutWarning`). Let the row component handle the warning
    /// rather than hiding the strategy entirely.
    var displayedStrategies: [CloningStrategy] { regularStrategies }
    var displayedStrategiesDirect: [CloningStrategy] { displayedStrategies.filter { $0.cloningPath.isDirectDigest } }
    /// All PCR strategies (before display cap) — for the total-count label and
    /// the show-all toggle.
    var allPCRStrategies: [CloningStrategy] { displayedStrategies.filter { $0.cloningPath.needsPrimers } }
    /// PCR strategies actually shown — capped to `pcrInitialLimit` unless the
    /// user toggles. Strategies are score-sorted in `runAnalysis`, so `prefix`
    /// keeps the highest-scoring ones.
    var displayedStrategiesPCR: [CloningStrategy] {
        pcrShowAll ? allPCRStrategies : Array(allPCRStrategies.prefix(Self.pcrInitialLimit))
    }
    
    /// Enzyme names that require a partial digest in the direct cloning
    /// strategies. Shuttle routes involving the same partial offer no
    /// improvement over direct cloning and are filtered out.
    var directPartialDigestEnzymes: Set<String> {
        var names = Set<String>()
        for s in strategies where s.partialDigest != .none {
            names.insert(s.enzyme5.name)
            if let e3 = s.enzyme3 { names.insert(e3.name) }
        }
        return names
    }
    
    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
            if !bluntInsertStrategies.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "equal.circle.fill").foregroundColor(.green)
                        Text("Blunt Insert — No Digest Required").font(.headline)
                        Text("(\(bluntInsertStrategies.count) found)").font(.callout).foregroundColor(.primary.opacity(0.65))
                        Spacer()
                    }.padding(.horizontal).padding(.top, 8)
                    
                    Text("Insert is a blunt-ended fragment — ligate directly into a blunt-cut vector site. Both possible orientations are shown; the orientation badge on each row shows which is which. Screen colonies by diagnostic digest or sequencing to confirm orientation.")
                        .font(.callout).foregroundColor(.primary.opacity(0.65)).padding(.horizontal)
                    
                    List(bluntInsertStrategies) { strategy in
                        StrategyRow(
                            strategy: strategy, showInsertCutWarning: false,
                            vectorName: vector.name, insertName: insertName, sourceName: insertName,
                            onBuildConstruct: { buildAndOpenConstruct(strategy: strategy) },
                            onDesignPrimers: nil,
                            onVerify: { verifyConstruct(strategy: strategy) }
                        )
                    }.frame(minHeight: 80)
                }
                Divider().padding(.vertical, 4)
            }
            
            // Direct digest strategies section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "arrow.right").foregroundColor(.blue)
                    Text("Direct Digest Strategies").font(.headline)
                    Text("(\(displayedStrategiesDirect.count) found)").font(.callout).foregroundColor(.primary.opacity(0.65))
                    Spacer()
                }.padding(.horizontal).padding(.top, 8)
                
                if displayedStrategiesDirect.isEmpty {
                    Text("No direct digest strategies found. See PCR strategies below if available.").font(.callout).foregroundColor(.primary.opacity(0.65)).padding(.horizontal)
                    // Alternative vector suggestions — shown in fusion mode when the
                    // insert's reading frame doesn't match the current vector but does
                    // match another vector in the library.
                    if !alternativeVectorSuggestions.isEmpty {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 6) {
                                    Image(systemName: "lightbulb.fill").foregroundColor(.yellow)
                                    Text("Alternative vectors for direct cloning").font(.callout).fontWeight(.semibold)
                                }
                                Text("The insert ORF reading frame does not align with \(vector.name) for direct restriction cloning. These library vectors have a compatible frame offset and may allow a direct digest strategy:")
                                    .font(.callout).foregroundColor(.primary.opacity(0.75))
                                    .fixedSize(horizontal: false, vertical: true)
                                ForEach(alternativeVectorSuggestions) { suggestion in
                                    HStack(spacing: 8) {
                                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.system(size: 13))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(suggestion.vector.fullName).font(.callout).fontWeight(.semibold)
                                            Text(suggestion.vector.notes).font(.caption).foregroundColor(.primary.opacity(0.65))
                                            Text(suggestion.reason).font(.caption).foregroundColor(.green)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                                Text("To use one of these vectors: open it, run Predictive Cloning with it as the destination, and the direct digest strategies should appear.")
                                    .font(.caption).foregroundColor(.primary.opacity(0.55))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(6)
                        } label: { Text("") }
                        .padding(.horizontal)
                        .padding(.top, 4)
                    }
                } else {
                    if displayedStrategiesDirect.contains(where: { !$0.isDirectional }) {
                        Text("Strategies marked Non-directional (single enzyme or compatible ends) are shown in both orientations — the orientation badge on each row shows which is which. Screen colonies by diagnostic digest or sequencing to confirm orientation.")
                            .font(.callout).foregroundColor(.primary.opacity(0.65)).padding(.horizontal)
                    }
                    List(displayedStrategiesDirect) { strategy in
                        StrategyRow(
                            strategy: strategy, showInsertCutWarning: !strategy.internalCutters.isEmpty,
                            vectorName: vector.name, insertName: insertName, sourceName: insertName,
                            onBuildConstruct: { buildAndOpenConstruct(strategy: strategy) },
                            onDesignPrimers: nil,
                            onVerify: { verifyConstruct(strategy: strategy) }
                        )
                    }
                    .frame(minHeight: CGFloat(min(displayedStrategiesDirect.count, 6)) * 88,
                           maxHeight: CGFloat(min(displayedStrategiesDirect.count, 6)) * 88)
                }
            }
            
            // PCR-required strategies section
            // Previously these were either hidden (when internalCutters was
            // non-empty) or awkwardly mixed with direct strategies. Split them
            // out so the user sees exactly which approach each strategy takes.
            if !allPCRStrategies.isEmpty {
                Divider().padding(.vertical, 4)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "waveform.path.ecg").foregroundColor(.blue)
                        Text("PCR Strategies").font(.headline)
                        if allPCRStrategies.count > Self.pcrInitialLimit && !pcrShowAll {
                            Text("(showing top \(Self.pcrInitialLimit) of \(allPCRStrategies.count) — primer design required)")
                                .font(.callout).foregroundColor(.primary.opacity(0.65))
                        } else {
                            Text("(\(allPCRStrategies.count) found — primer design required)")
                                .font(.callout).foregroundColor(.primary.opacity(0.65))
                        }
                        Spacer()
                        if allPCRStrategies.count > Self.pcrInitialLimit {
                            Button(action: { pcrShowAll.toggle() }) {
                                Text(pcrShowAll ? "Show top \(Self.pcrInitialLimit)" : "Show all \(allPCRStrategies.count)")
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                        }
                    }.padding(.horizontal).padding(.top, 4)
                    
                    Text("PCR the insert with primers that add the required restriction sites, then digest and ligate. If a strategy shows an internal-cutter warning, the primer designer will flag affected sites — you may still be able to proceed with alternative enzymes or site-directed mutagenesis to remove the internal site.")
                        .font(.callout).foregroundColor(.primary.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal)
                    
                    List(displayedStrategiesPCR) { strategy in
                        StrategyRow(
                            strategy: strategy, showInsertCutWarning: !strategy.internalCutters.isEmpty,
                            vectorName: vector.name, insertName: insertName, sourceName: insertName,
                            onBuildConstruct: { buildAndOpenConstruct(strategy: strategy) },
                            onDesignPrimers: { openPrimerDesigner(for: strategy) },
                            onVerify: { verifyConstruct(strategy: strategy) }
                        )
                    }
                    .frame(minHeight: CGFloat(min(displayedStrategiesPCR.count, 10)) * 88,
                           maxHeight: CGFloat(min(displayedStrategiesPCR.count, 10)) * 88)
                }
            }
            
            // Shuttle vector routes button
            if hasShuttleVector {
                Divider().padding(.vertical, 4)
                HStack {
                    Image(systemName: "arrow.triangle.swap").foregroundColor(.purple)
                    Text("Shuttle Vector Routes").font(.headline)
                    Text("(PCR-free, via intermediate vectors)").font(.callout).foregroundColor(.primary.opacity(0.65))
                    Spacer()
                    Button(action: openShuttleRoutesWindow) {
                        Label("Find Shuttle Routes…", systemImage: "magnifyingglass")
                    }.buttonStyle(.bordered)
                    .contextHelp("predict.shuttleRoutes")
                }.padding(.horizontal).padding(.vertical, 8)
                
                // Nudge the user to add the vector to the library when no
                // library match was found. Shuttle routing still works using
                // MCS sites derived from the vector's annotated features.
                if !vectorInLibrary {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundColor(.blue)
                            .font(.caption)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(vector.name) is not in the shuttle vector library.")
                                .font(.caption).bold()
                            Text("MCS sites are auto-detected from this vector's features. For better support add it to ShuttleVectorLibrary (edit ShuttleVectorLibrary.swift and rebuild).")
                                .font(.caption).foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(.horizontal).padding(.bottom, 4)
                }
                
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text("Routes are predicted from MCS metadata only. Verify any strategy against the full vector sequence before proceeding to bench work.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }.padding(.horizontal).padding(.bottom, 6)
            }
        } // end VStack
        } // end ScrollView
        .frame(minWidth: 1000, minHeight: 700)
        .textSelection(.enabled)
        .confirmationDialog(
            "Choose insert orientation",
            isPresented: $showOrientationDialog,
            titleVisibility: .visible
        ) {
            Button("5'\u{2192}3' (forward)") { buildNonDirectional(reversed: false) }
            Button("3'\u{2192}5' (reverse complement)") { buildNonDirectional(reversed: true) }
            Button("Cancel", role: .cancel) { pendingBuildStrategy = nil }
        } message: {
            Text("This is a non-directional strategy \u{2014} the insert can ligate in either orientation. Choose which to build.")
        }
    }
    /// For a `.bluntedInsert` strategy, materialise the actual blunted insert
    /// fragment from the source sequence using the boundaries the analyzer
    /// recorded in `insertCut5Source` / `insertCut3Source` (fill-in keeps the
    /// overhang bases, nibble drops them). Returns nil for every other cloning
    /// path so callers fall back to the normal insert sequence. `reversed`
    /// reverse-complements the fragment for the chosen orientation.
    private func bluntedInsertFragment(_ strategy: CloningStrategy, reversed: Bool) -> String? {
        guard case .bluntedInsert = strategy.cloningPath,
              let left = strategy.insertCut5Source,
              let right = strategy.insertCut3Source else { return nil }
        let src = Array(sourceSequence.uppercased())
        let n = src.count
        guard n > 0 else { return nil }
        func norm(_ i: Int) -> Int { (((i % n) + n) % n) }
        
        let forward: String
        if right > left && left >= 0 && right <= n {
            // Normal (non-wrapping) fragment.
            forward = String(src[left..<right])
        } else if sourceIsCircular {
            // Fragment wraps the origin.
            let l = norm(left); let r = norm(right)
            forward = String(src[l..<n]) + String(src[0..<r])
        } else {
            return nil
        }
        guard !forward.isEmpty else { return nil }
        return reversed ? DNASequence.reverseComplementString(forward).uppercased() : forward
    }
    
    private func insertSequenceFor(_ strategy: CloningStrategy) -> String {
        strategy.insertReversed ? rcInsertSequence : insertSequence
    }
    
    func buildAndOpenConstruct(strategy: CloningStrategy) {
        if !strategy.isDirectional {
            pendingBuildStrategy = strategy
            showOrientationDialog = true
        } else {
            let seq = insertSequenceFor(strategy)
            let construct = analyzer.buildConstruct(strategy: strategy, vector: vector,
                                                    insertName: insertName, insertSequence: seq)
            sequenceManager.sequences.append(construct)
            sequenceManager.currentSequence = construct
            SequenceWindowOpener.shared.openSequenceWindow(construct.id)
        }
    }

    private func buildNonDirectional(reversed: Bool) {
        guard let strategy = pendingBuildStrategy else { return }
        // Blunt-mediated strategies use the source-derived blunted fragment, not
        // the raw insert region; everything else uses the extracted insert.
        let seq = bluntedInsertFragment(strategy, reversed: reversed)
            ?? (reversed ? rcInsertSequence : insertSequence)
        let construct = analyzer.buildConstruct(strategy: strategy, vector: vector,
                                                insertName: insertName, insertSequence: seq)
        sequenceManager.sequences.append(construct)
        sequenceManager.currentSequence = construct
        SequenceWindowOpener.shared.openSequenceWindow(construct.id)
        pendingBuildStrategy = nil
    }
    
    func verifyConstruct(strategy: CloningStrategy) {
        let seq = bluntedInsertFragment(strategy, reversed: strategy.insertReversed)
            ?? insertSequenceFor(strategy)
        let construct = analyzer.buildConstruct(strategy: strategy, vector: vector,
                                                insertName: insertName, insertSequence: seq)
        let insertStart = strategy.vectorSite5Position + strategy.enzyme5.cutPosition5Prime
        DigestVerificationWindowManager.shared.openWindow(
            construct: construct,
            parentalVector: vector,
            insertStart: insertStart,
            insertLength: seq.count,
            // Directional cloning forces orientation; non-directional needs verifying.
            orientationMatters: !strategy.isDirectional,
            enzymes: activeVerifyEnzymes
        )
    }
    
    /// Amount of flanking sequence added either side of the insert in the
    /// primer design template. 500 bp gives adequate context for primer
    /// binding and secondary-structure checks without being overwhelming.
    private static let primerFlankBp = 500

    func openPrimerDesigner(for strategy: CloningStrategy) {
        let insertSeq = insertSequenceFor(strategy)

        // Build a flanked template from the full source sequence so the primer
        // designer has upstream and downstream context beyond the bare ORF/feature.
        // targetStart/targetEnd point at the insert within the flanked excerpt.
        let (templateSeq, targetStart, targetEnd) = flankedTemplate(
            insertSeq: insertSeq,
            insertReversed: strategy.insertReversed)

        let templateName = strategy.insertReversed ? "\(insertName) (RC) + context" : "\(insertName) + context"
        let seqObj = DNASequence(name: templateName, sequence: templateSeq)
        sequenceManager.sequences.append(seqObj)

        let transfer = CloningPrimerTransfer.shared
        transfer.templateSequenceID = seqObj.id
        transfer.targetStart = targetStart
        transfer.targetEnd   = targetEnd
        transfer.fwdEnzymeName  = strategy.effectiveInsertEnzyme5.name
        transfer.revEnzymeName  = strategy.effectiveInsertEnzyme3.name
        transfer.fwdPaddingBases = strategy.effectiveInsertEnzyme5.recognitionSite.count >= 8 ? 4 : 2
        transfer.revPaddingBases = strategy.effectiveInsertEnzyme3.recognitionSite.count >= 8 ? 4 : 2
        PrimerDesignWindowManager.shared.openWindow(sequenceManager: sequenceManager, initialSequenceID: seqObj.id)
    }

    /// Build a flanked excerpt of the source sequence around the insert region.
    /// Returns (templateSequence, targetStart, targetEnd) where targetStart and
    /// targetEnd are 1-based positions of the insert within the template.
    ///
    /// When source context is unavailable (no sourceInsertRegion), the bare
    /// insert sequence is returned with targetStart=1/targetEnd=insertSeq.count.
    private func flankedTemplate(
        insertSeq: String,
        insertReversed: Bool
    ) -> (template: String, targetStart: Int, targetEnd: Int) {
        let flank = CloningStrategiesView.primerFlankBp

        guard let region = sourceInsertRegion, !sourceSequence.isEmpty, !region.wrapsOrigin else {
            // Fallback: no source context, or origin-wrapping region — use insert alone
            return (insertSeq, 1, insertSeq.count)
        }

        let src    = sourceSequence.uppercased()
        let srcLen = src.count
        let iStart = region.start
        let iEnd   = min(region.end, srcLen - 1)
        let iLen   = iEnd - iStart + 1

        let excerptStart = max(0, iStart - flank)
        let excerptEnd   = min(srcLen, iEnd + 1 + flank)       // exclusive

        let s = src.index(src.startIndex, offsetBy: excerptStart)
        let e = src.index(src.startIndex, offsetBy: excerptEnd)

        if insertReversed {
            // RC the excerpt so the primer designer sees the same strand as
            // the insert. targetStart/targetEnd are measured from the RC'd end.
            let fwdExcerpt = String(src[s..<e])
            let rcExcerpt  = DNASequence.reverseComplementString(fwdExcerpt).uppercased()
            let rcLen      = rcExcerpt.count
            // In the RC'd excerpt the insert occupies the mirror positions
            let fwdTargetStart = (iStart - excerptStart) + 1          // 1-based in fwd
            let fwdTargetEnd   = fwdTargetStart + iLen - 1
            let rcTargetStart  = rcLen - fwdTargetEnd + 1
            let rcTargetEnd    = rcLen - fwdTargetStart + 1
            return (rcExcerpt, rcTargetStart, rcTargetEnd)
        }

        let template    = String(src[s..<e])
        let targetStart = (iStart - excerptStart) + 1
        let targetEnd   = targetStart + iLen - 1

        return (template, targetStart, targetEnd)
    }
    
    func openShuttleRoutesWindow() {
        guard let info = shuttleRouteInfo else { return }
        ShuttleRoutesWindowManager.shared.openWindow(
            sourceSequence: info.sourceSequence,
            insertRegion: info.insertRegion,
            sourceIsCircular: info.sourceIsCircular,
            sourceName: info.sourceName,
            destinationName: info.destinationName,
            destinationMCSSites: info.destinationMCSSites,
            destinationSequence: info.destinationSequence,
            destinationIsCircular: info.destinationIsCircular,
            protectedRegions: info.protectedRegions,
            cloningRegionRange: info.cloningRegionRange,
            directPartialDigestEnzymes: directPartialDigestEnzymes
        )
    }
}


// MARK: - Cloning Strategies Window Manager

class CloningStrategiesWindowManager {
    static let shared = CloningStrategiesWindowManager()
    private var window: NSWindow?
    private init() {}
    
    func openWindow(
        strategies: [CloningStrategy],
        vector: DNASequence,
        insertName: String,
        insertSequence: String,
        insertReversed: Bool,
        rcInsertSequence: String,
        sequenceManager: SequenceManager,
        hasShuttleVector: Bool,
        vectorInLibrary: Bool = true,
        sourceSequence: String = "",
        sourceInsertRegion: InsertRegion? = nil,
        sourceIsCircular: Bool = false,
        alternativeVectorSuggestions: [PredictiveCloningView.AlternativeVectorSuggestion] = [],
        shuttleRouteInfo: (
            sourceSequence: String, insertRegion: InsertRegion,
            sourceIsCircular: Bool, sourceName: String,
            destinationName: String, destinationMCSSites: [String]?,
            destinationSequence: String, destinationIsCircular: Bool,
            protectedRegions: [ClosedRange<Int>],
            cloningRegionRange: ClosedRange<Int>?
        )?
    ) {
        let info: CloningStrategiesView.ShuttleRouteInfo?
        if let r = shuttleRouteInfo {
            info = CloningStrategiesView.ShuttleRouteInfo(
                sourceSequence: r.sourceSequence, insertRegion: r.insertRegion,
                sourceIsCircular: r.sourceIsCircular, sourceName: r.sourceName,
                destinationName: r.destinationName, destinationMCSSites: r.destinationMCSSites,
                destinationSequence: r.destinationSequence, destinationIsCircular: r.destinationIsCircular,
                protectedRegions: r.protectedRegions,
                cloningRegionRange: r.cloningRegionRange)
        } else { info = nil }
        
        let view = CloningStrategiesView(
            strategies: strategies, vector: vector,
            insertName: insertName, insertSequence: insertSequence,
            insertReversed: insertReversed, rcInsertSequence: rcInsertSequence,
            sourceSequence: sourceSequence,
            sourceInsertRegion: sourceInsertRegion,
            sourceIsCircular: sourceIsCircular,
            sequenceManager: sequenceManager,
            hasShuttleVector: hasShuttleVector,
            vectorInLibrary: vectorInLibrary,
            shuttleRouteInfo: info,
            alternativeVectorSuggestions: alternativeVectorSuggestions
        )
        let controller = NSHostingController(rootView: view)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "Cloning Strategies — \(insertName) → \(vector.name)"
        win.contentViewController = controller;
        win.setFrameAutosaveName("CloningStrategiesinsertNamevectorname")
        if !win.setFrameUsingName(win.frameAutosaveName) { win.center() }
        win.isReleasedWhenClosed = false; win.minSize = NSSize(width: 800, height: 500)
        win.makeKeyAndOrderFront(nil)
        window = win
    }
}


// MARK: - Multi-Source Strategies Window

struct MultiSourceStrategiesView: View {
    let scoredStrategies: [ScoredStrategy]
    let vector: DNASequence
    @ObservedObject var sequenceManager: SequenceManager
    
    private let analyzer = CloningStrategyAnalyzer()
    private let enzymeDB = RestrictionEnzymeDatabase.shared
    @AppStorage("predictive_myEnzymesOnly_verify") private var myEnzymesOnlyVerify: Bool = false
    private var activeVerifyEnzymes: [RestrictionEnzyme] {
        myEnzymesOnlyVerify
            ? enzymeDB.enzymes.filter { enzymeDB.isMyEnzyme($0.name) }
            : enzymeDB.enzymes
    }
    
    private var displayedStrategies: [ScoredStrategy] {
        // Previously filtered by `internalCutters.isEmpty`, which silently hid
        // viable PCR strategies that happened to have an internal cut site.
        // The row component already displays a prominent warning via
        // `showInsertCutWarning`.
        scoredStrategies
    }

    // Non-directional orientation dialog
    @State private var pendingBuildScored: ScoredStrategy? = nil
    @State private var showOrientationDialog: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "arrow.right").foregroundColor(.blue)
                Text("Multi-Source Strategies").font(.headline)
                Text("(\(displayedStrategies.count) found from \(sourceCount) source\(sourceCount == 1 ? "" : "s"))")
                    .font(.callout).foregroundColor(.primary.opacity(0.65))
                Spacer()
            }.padding(.horizontal).padding(.top, 8)
            
            if displayedStrategies.isEmpty {
                Text("No strategies found across any source.").font(.callout).foregroundColor(.primary.opacity(0.65)).padding()
            } else {
                List(displayedStrategies) { scored in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text").foregroundColor(.purple).font(.system(size: 11))
                            Text("Source: \(scored.sourceName)").font(.callout).fontWeight(.medium).foregroundColor(.purple)
                        }
                        StrategyRow(
                            strategy: scored.strategy,
                            showInsertCutWarning: !scored.strategy.internalCutters.isEmpty,
                            vectorName: vector.name,
                            insertName: scored.insertName, sourceName: scored.sourceName,
                            onBuildConstruct: { buildAndOpenConstruct(scored: scored) },
                            // Enable primer design for all PCR strategies.
                            // Internal-cutter warnings are shown on the row.
                            onDesignPrimers: scored.strategy.cloningPath.needsPrimers
                                ? { openPrimerDesigner(scored: scored) } : nil,
                            onVerify: { verifyConstruct(scored: scored) }
                        )
                    }
                }
            }
        }
        .frame(minWidth: 1000, minHeight: 700)
        .textSelection(.enabled)
        .confirmationDialog(
            "Choose insert orientation",
            isPresented: $showOrientationDialog,
            titleVisibility: .visible
        ) {
            Button("5'\u{2192}3' (forward)") { buildNonDirectionalScored(reversed: false) }
            Button("3'\u{2192}5' (reverse complement)") { buildNonDirectionalScored(reversed: true) }
            Button("Cancel", role: .cancel) { pendingBuildScored = nil }
        } message: {
            Text("This is a non-directional strategy \u{2014} the insert can ligate in either orientation. Choose which to build.")
        }
    }
    
    private var sourceCount: Int {
        Set(scoredStrategies.map { $0.sourceID }).count
    }
    
    /// For a `.bluntedInsert` scored strategy, rebuild the actual blunted insert
    /// fragment from THIS result's own source sequence, using the boundaries the
    /// analyzer recorded (fill-in keeps the overhang bases, nibble drops them).
    /// Returns nil for any other path so callers fall back to scored.insertSequence.
    private func bluntedInsertFragment(_ scored: ScoredStrategy, reversed: Bool) -> String? {
        guard case .bluntedInsert = scored.strategy.cloningPath,
              let left = scored.strategy.insertCut5Source,
              let right = scored.strategy.insertCut3Source,
              !scored.sourceSequence.isEmpty else { return nil }
        let src = Array(scored.sourceSequence.uppercased())
        let n = src.count
        guard n > 0 else { return nil }
        func norm(_ i: Int) -> Int { (((i % n) + n) % n) }
        
        let forward: String
        if right > left && left >= 0 && right <= n {
            forward = String(src[left..<right])
        } else if scored.sourceIsCircular {
            let l = norm(left); let r = norm(right)
            forward = String(src[l..<n]) + String(src[0..<r])
        } else {
            return nil
        }
        guard !forward.isEmpty else { return nil }
        return reversed ? DNASequence.reverseComplementString(forward).uppercased() : forward
    }
    
    func buildAndOpenConstruct(scored: ScoredStrategy) {
        if !scored.strategy.isDirectional {
            pendingBuildScored = scored
            showOrientationDialog = true
        } else {
            let construct = analyzer.buildConstruct(strategy: scored.strategy, vector: vector,
                                                    insertName: scored.insertName, insertSequence: scored.insertSequence)
            sequenceManager.sequences.append(construct)
            sequenceManager.currentSequence = construct
            SequenceWindowOpener.shared.openSequenceWindow(construct.id)
        }
    }

    private func buildNonDirectionalScored(reversed: Bool) {
        guard let scored = pendingBuildScored else { return }
        // Blunt-mediated strategies use the source-derived blunted fragment.
        let seq = bluntedInsertFragment(scored, reversed: reversed)
            ?? (reversed
                ? DNASequence.reverseComplementString(scored.insertSequence).uppercased()
                : scored.insertSequence)
        let construct = analyzer.buildConstruct(strategy: scored.strategy, vector: vector,
                                                insertName: scored.insertName, insertSequence: seq)
        sequenceManager.sequences.append(construct)
        sequenceManager.currentSequence = construct
        SequenceWindowOpener.shared.openSequenceWindow(construct.id)
        pendingBuildScored = nil
    }
    
    func verifyConstruct(scored: ScoredStrategy) {
        let seq = bluntedInsertFragment(scored, reversed: scored.insertReversed) ?? scored.insertSequence
        let construct = analyzer.buildConstruct(strategy: scored.strategy, vector: vector,
                                                insertName: scored.insertName, insertSequence: seq)
        let insertStart = scored.strategy.vectorSite5Position + scored.strategy.enzyme5.cutPosition5Prime
        DigestVerificationWindowManager.shared.openWindow(
            construct: construct,
            parentalVector: vector,
            insertStart: insertStart,
            insertLength: seq.count,
            orientationMatters: !scored.strategy.isDirectional,
            enzymes: activeVerifyEnzymes
        )
    }
    
    private static let primerFlankBp = 500

    func openPrimerDesigner(scored: ScoredStrategy) {
        // Build a flanked template from the full source sequence when available,
        // so the primer designer has context beyond the bare insert.
        let (templateSeq, targetStart, targetEnd) = flankedTemplate(scored: scored)
        let templateName = scored.insertReversed
            ? "\(scored.insertName) (RC) + context"
            : "\(scored.insertName) + context"
        let seqObj = DNASequence(name: templateName, sequence: templateSeq)
        sequenceManager.sequences.append(seqObj)

        let transfer = CloningPrimerTransfer.shared
        transfer.templateSequenceID = seqObj.id
        transfer.targetStart = targetStart
        transfer.targetEnd   = targetEnd
        transfer.fwdEnzymeName  = scored.strategy.effectiveInsertEnzyme5.name
        transfer.revEnzymeName  = scored.strategy.effectiveInsertEnzyme3.name
        transfer.fwdPaddingBases = scored.strategy.effectiveInsertEnzyme5.recognitionSite.count >= 8 ? 4 : 2
        transfer.revPaddingBases = scored.strategy.effectiveInsertEnzyme3.recognitionSite.count >= 8 ? 4 : 2
        PrimerDesignWindowManager.shared.openWindow(sequenceManager: sequenceManager, initialSequenceID: seqObj.id)
    }

    private func flankedTemplate(scored: ScoredStrategy) -> (template: String, targetStart: Int, targetEnd: Int) {
        let insertSeq = scored.insertSequence
        let flank = MultiSourceStrategiesView.primerFlankBp

        guard let region = scored.insertRegion,
              !region.wrapsOrigin,
              !scored.insertReversed,
              let src = sequenceManager.sequences.first(where: { $0.id == scored.sourceID })
        else {
            return (insertSeq, 1, insertSeq.count)
        }

        let srcStr = src.sequence.uppercased()
        let srcLen = srcStr.count
        let iStart = region.start
        let iEnd   = min(region.end, srcLen - 1)

        let excerptStart = max(0, iStart - flank)
        let excerptEnd   = min(srcLen, iEnd + 1 + flank)

        let s = srcStr.index(srcStr.startIndex, offsetBy: excerptStart)
        let e = srcStr.index(srcStr.startIndex, offsetBy: excerptEnd)
        let template = String(srcStr[s..<e])

        let targetStart = (iStart - excerptStart) + 1
        let targetEnd   = targetStart + (iEnd - iStart + 1) - 1
        return (template, targetStart, targetEnd)
    }
}


// MARK: - Multi-Source Strategies Window Manager

class MultiSourceStrategiesWindowManager {
    static let shared = MultiSourceStrategiesWindowManager()
    private var window: NSWindow?
    private init() {}
    
    func openWindow(
        scoredStrategies: [ScoredStrategy],
        vector: DNASequence,
        sequenceManager: SequenceManager
    ) {
        let view = MultiSourceStrategiesView(
            scoredStrategies: scoredStrategies,
            vector: vector,
            sequenceManager: sequenceManager
        )
        let controller = NSHostingController(rootView: view)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "Multi-Source Cloning Strategies → \(vector.name)"
        win.contentViewController = controller;
        win.setFrameAutosaveName("MultiSourceCloningStrategiesvectorname")
        if !win.setFrameUsingName(win.frameAutosaveName) { win.center() }
        win.isReleasedWhenClosed = false; win.minSize = NSSize(width: 800, height: 500)
        win.makeKeyAndOrderFront(nil)
        window = win
    }
}


// MARK: - Strategy Row

struct StrategyRow: View {
    let strategy: CloningStrategy; let showInsertCutWarning: Bool
    let vectorName: String; let insertName: String; let sourceName: String
    let onBuildConstruct: () -> Void; let onDesignPrimers: (() -> Void)?
    let onVerify: (() -> Void)?
    
    private let analyzer = CloningStrategyAnalyzer()
    
    private func formatBP(_ bp: Int) -> String {
        if bp >= 1000 { return String(format: "%.1f kb", Double(bp) / 1000.0) }
        return "\(bp) bp"
    }
    
    private var vecEnzLabel: String {
        if let e3 = strategy.enzyme3 {
            return "\(strategy.enzyme5.name)  +  \(e3.name)"
        }
        return strategy.enzyme5.name
    }
    
    private var insEnzLabel: String {
        let iE5 = strategy.effectiveInsertEnzyme5.name
        let iE3 = strategy.effectiveInsertEnzyme3.name
        if case .bluntedInsert = strategy.cloningPath {
            // Name both original cutters and how each end is blunted. The two
            // ends can differ (fill-in on a 5' overhang, nibble-back on a 3'),
            // and an end that was already blunt is labelled as such.
            func methodLabel(_ m: BluntingMethod?) -> String {
                switch m {
                case .fillIn: return "fill-in"
                case .nibble: return "nibble-back"
                case .none:   return "already blunt"
                }
            }
            let l = "\(iE5) (\(methodLabel(strategy.insert5Blunting)))"
            let r = "\(iE3) (\(methodLabel(strategy.insert3Blunting)))"
            return l == r ? l : "\(l)  +  \(r)"
        }
        return strategy.isDirectional ? "\(iE5)  +  \(iE3)" : iE5
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Enzyme names on their own full-width line so long blunt-method
            // labels don't get squished to one character per line by the badges.
            HStack(spacing: 4) {
                Text("Vector:").font(.callout).foregroundColor(.primary.opacity(0.65))
                Text(vecEnzLabel).font(.system(.body, design: .monospaced, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("  /  ").foregroundColor(.primary.opacity(0.4))
                Text("Insert:").font(.callout).foregroundColor(.primary.opacity(0.65))
                if case .bluntInsertDirect = strategy.cloningPath {
                    Text("No digest (blunt fragment)").font(.callout).foregroundColor(.green)
                } else {
                    Text(insEnzLabel).font(.system(.body, design: .monospaced, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            // Badges wrap onto new lines as needed (BadgeFlowLayout, macOS 13+).
            BadgeFlowLayout(spacing: 6, lineSpacing: 4) {
                badge(strategy.cloningPath.label, color: strategy.cloningPath.isDirectDigest ? .green : strategy.cloningPath.needsPrimers ? .blue : .teal)
                if strategy.partialDigest != .none { badge(strategy.partialDigest.label, color: .orange) }
                if strategy.usesCompatibleEnds { badge("Compatible ends", color: .cyan) }
                if strategy.isDirectional { badge("Directional", color: .green) } else { badge("Non-directional", color: .orange) }
                // Internal cutter warnings — distinguish between enzymes that
                // actually cut the insert (real problem) vs vector-only enzymes
                // whose sites happen to exist in the insert (informational).
                if showInsertCutWarning {
                    let insertEnzNames = Set([strategy.effectiveInsertEnzyme5.name,
                                              strategy.effectiveInsertEnzyme3.name])
                    ForEach(strategy.internalCutters, id: \.self) { cutter in
                        if insertEnzNames.contains(cutter) {
                            badge("⚠ \(cutter) cuts inside insert", color: .red)
                        } else {
                            badge("\(cutter) in insert (vector-only enzyme)", color: .orange)
                        }
                    }
                }
                if !strategy.isDirectional {
                    if strategy.insertReversed {
                        badge("Insert: 3'→5'", color: .orange)
                    } else {
                        badge("Insert: 5'→3'", color: .teal)
                    }
                } else if strategy.insertReversed { badge("Insert RC'd", color: .orange) }
                if let fa = strategy.frameAnalysis, let label = fa.label { badge(label, color: fa.allInFrame ? .purple : .red) }
                // Methylation badges — surfaced from warnings so no extra data needed
                let methylWarnings = strategy.warnings.filter { w in
                    let wl = w.lowercased()
                    return wl.contains("blocked by") || wl.contains("requires dam methylation") || wl.contains("may be blocked")
                }
                if !methylWarnings.isEmpty {
                    let isRequired  = methylWarnings.contains { $0.lowercased().contains("requires") }
                    let isBlocked   = methylWarnings.contains { $0.lowercased().contains("blocked by") }
                    let badgeColor: Color = isBlocked ? .orange : .blue
                    let badgeText = isRequired ? "⚠ Needs methylation" : "⚠ Methylation blocked"
                    badge(badgeText, color: badgeColor)
                }
                // Eat-in badges — surfaced from warnings into the header row
                ForEach(strategy.warnings.filter { $0.hasPrefix("⚠eat-in:") }, id: \.self) { w in
                    badge(
                        "✂ " + w.replacingOccurrences(of: "⚠eat-in:", with: "").replacingOccurrences(of: " (penalty)", with: ""),
                        color: w.hasSuffix("(penalty)") ? .red : .orange                    )
                }
                Text("Score: \(strategy.score)").font(.callout).foregroundColor(.primary.opacity(0.65))
            }
            
            // Fragment sizes
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Text("Backbone:").font(.callout).foregroundColor(.primary.opacity(0.65))
                    Text(formatBP(strategy.backboneSize)).font(.system(.callout, design: .monospaced)).fontWeight(.medium)
                }
                if strategy.excisedSize > 0 {
                    HStack(spacing: 4) {
                        Text("Stuffer:").font(.callout).foregroundColor(.primary.opacity(0.65))
                        Text(formatBP(strategy.excisedSize)).font(.system(.callout, design: .monospaced)).foregroundColor(.primary.opacity(0.65))
                    }
                }
                HStack(spacing: 4) {
                    Text("Insert:").font(.callout).foregroundColor(.primary.opacity(0.65))
                    Text(formatBP(strategy.insertSize)).font(.system(.callout, design: .monospaced)).fontWeight(.medium)
                }
                HStack(spacing: 4) {
                    Text("Construct:").font(.callout).foregroundColor(.primary.opacity(0.65))
                    Text("~\(formatBP(strategy.backboneSize + strategy.insertSize))").font(.system(.callout, design: .monospaced))
                }
                
                let sizeRatio = Double(min(strategy.backboneSize, strategy.insertSize)) / Double(max(strategy.backboneSize, strategy.insertSize))
                if sizeRatio > 0.8 {
                    HStack(spacing: 2) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).font(.callout)
                        Text("Recombinant backbone & insert similar size — hard to resolve on gel").font(.callout).foregroundColor(.orange)
                    }
                }
            }
            
            // Action buttons
            HStack(spacing: 8) {
                if let p = onDesignPrimers { Button(action: p) { Label("Primers", systemImage: "arrow.right.arrow.left") }.buttonStyle(.bordered).controlSize(.small).contextHelp("predict.stratPrimers") }
                Button(action: onBuildConstruct) { Label("Build", systemImage: "hammer.fill") }.buttonStyle(.bordered).controlSize(.small).contextHelp("predict.stratBuild")
                if let v = onVerify { Button(action: v) { Label("Verify", systemImage: "checkmark.shield") }.buttonStyle(.bordered).controlSize(.small).help("Suggest a restriction-digest strategy to verify recombinant clones.").contextHelp("predict.stratVerify") }
                Button(action: viewProtocol) { Label("View", systemImage: "eye") }.buttonStyle(.bordered).controlSize(.small).contextHelp("predict.stratView")
                Button(action: exportProtocol) { Label("Save", systemImage: "doc.text") }.buttonStyle(.bordered).controlSize(.small).contextHelp("predict.stratSave")
                Button(action: printProtocol) { Label("Print", systemImage: "printer") }.buttonStyle(.bordered).controlSize(.small).contextHelp("predict.stratPrint")
            }
            
            let bottomWarnings = strategy.warnings.filter { !$0.hasPrefix("⚠eat-in:") }
            if !bottomWarnings.isEmpty {
                ForEach(bottomWarnings, id: \.self) { w in
                    if w == "Site is within MCS" {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.callout)
                            Text(w).font(.callout).foregroundColor(.green)
                        }
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow).font(.callout)
                            Text(w).font(.callout).foregroundColor(.primary.opacity(0.65))
                        }
                    }
                }
            }
        }.padding(.vertical, 4)
    }
    
    func viewProtocol() {
        let protocol_ = analyzer.generateProtocol(strategy: strategy, vectorName: vectorName, insertName: insertName, sourceName: sourceName)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 500))
        scrollView.hasVerticalScroller = true; scrollView.hasHorizontalScroller = false
        scrollView.autoresizingMask = [.width, .height]
        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.string = protocol_
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isEditable = false; textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "Protocol — \(insertName) → \(vectorName)"
        win.contentView = scrollView;
        win.setFrameAutosaveName("ProtocolinsertNamevectorName")
        if !win.setFrameUsingName(win.frameAutosaveName) { win.center() }
        win.isReleasedWhenClosed = false; win.minSize = NSSize(width: 400, height: 300)
        win.makeKeyAndOrderFront(nil)
    }
    
    func exportProtocol() {
        let protocol_ = analyzer.generateProtocol(strategy: strategy, vectorName: vectorName, insertName: insertName, sourceName: sourceName)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Cloning Protocol — \(insertName) into \(vectorName).txt"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? protocol_.write(to: url, atomically: true, encoding: .utf8)
        }
    }
    
    func printProtocol() {
        let protocol_ = analyzer.generateProtocol(strategy: strategy, vectorName: vectorName, insertName: insertName, sourceName: sourceName)
        
        let printInfo = (NSPrintInfo.shared.copy() as! NSPrintInfo)
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination  = .automatic
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered   = false
        printInfo.topMargin    = 72
        printInfo.bottomMargin = 72
        printInfo.leftMargin   = 72
        printInfo.rightMargin  = 72
        
        let printableWidth  = printInfo.paperSize.width
            - printInfo.leftMargin - printInfo.rightMargin
        let printableHeight = printInfo.paperSize.height
            - printInfo.topMargin  - printInfo.bottomMargin
        
        let textView = NSTextView(frame: NSRect(x: 0, y: 0,
                                                width: printableWidth,
                                                height: printableHeight))
        textView.string = protocol_
        textView.font   = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        textView.isEditable   = false
        textView.isSelectable = true
        textView.textContainerInset = .zero
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize =
            NSSize(width: printableWidth, height: .greatestFiniteMagnitude)
        
        // Lay out the full text so the view height is correct for pagination
        if let lm = textView.layoutManager, let tc = textView.textContainer {
            lm.ensureLayout(for: tc)
            textView.frame.size.height = lm.usedRect(for: tc).height
        }
        
        let printOp = NSPrintOperation(view: textView, printInfo: printInfo)
        printOp.showsPrintPanel    = true
        printOp.showsProgressPanel = true
        printOp.run()
    }
    
    func badge(_ t: String, color: Color) -> some View {
        Text(t).font(.callout).fontWeight(.medium).padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15)).foregroundColor(color).cornerRadius(4)
    }
}


// MARK: - Route Row

struct RouteRow: View {
    let route: CloningRoute; let isExpanded: Bool; let onToggle: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(action: onToggle) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right").font(.callout).foregroundColor(.primary.opacity(0.65))
                }.buttonStyle(.plain)
                if route.isDirectRoute { badge("Direct", color: .green) } else { badge("\(route.stepCount) steps", color: .purple) }
                if route.steps.contains(where: { $0.needsPartialDigest }) { badge("Partial digest", color: .orange) }
                if route.orientation == .forward { badge("→ Forward", color: .green) }
                if route.orientation == .reverse { badge("← Reverse", color: .red) }
                Text(route.summary).font(.system(.body, design: .monospaced, weight: .medium))
                Spacer()
                Text("Score: \(route.score)").font(.callout).foregroundColor(.primary.opacity(0.65))
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(route.steps.enumerated()), id: \.element.id) { idx, step in
                        HStack(spacing: 8) {
                            Text("\(idx + 1)")
                                .font(.system(.callout, design: .monospaced, weight: .bold)).foregroundColor(.white)
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(step.isDirectional ? Color.green : Color.orange))
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(step.sourceName).font(.callout).fontWeight(.medium)
                                    Image(systemName: "arrow.right").font(.callout).foregroundColor(.primary.opacity(0.65))
                                    Text(step.destinationName).font(.callout).fontWeight(.medium)
                                }
                                HStack(spacing: 4) {
                                    Text("Digest with").font(.callout).foregroundColor(.primary.opacity(0.65))
                                    Text(step.enzymeDescription).font(.system(.callout, design: .monospaced)).foregroundColor(.blue)
                                    Text(step.isDirectional ? "(directional)" : "(non-directional)").font(.callout).foregroundColor(.primary.opacity(0.65))
                                }
                                if step.needsPartialDigest {
                                    HStack(spacing: 4) {
                                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).font(.callout)
                                        if step.partialDigest5 && step.isDirectional {
                                            Text("\(step.enzyme5Name) cuts >1× in \(step.destinationName) — partial digest required")
                                                .font(.callout).foregroundColor(.orange)
                                        }
                                        if step.partialDigest3 && step.isDirectional {
                                            Text("\(step.enzyme3Name) cuts >1× in \(step.destinationName) — partial digest required")
                                                .font(.callout).foregroundColor(.orange)
                                        }
                                        if !step.isDirectional && step.needsPartialDigest {
                                            Text("\(step.enzyme5Name) cuts >1× in \(step.destinationName) — partial digest required")
                                                .font(.callout).foregroundColor(.orange)
                                        }
                                    }
                                }
                            }
                        }.padding(.leading, 24)
                    }
                }.padding(.vertical, 4)
            }
        }.padding(.vertical, 4)
    }
    func badge(_ t: String, color: Color) -> some View {
        Text(t).font(.callout).fontWeight(.medium).padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15)).foregroundColor(color).cornerRadius(4)
    }
}


// MARK: - Window Manager

class PredictiveCloningWindowManager {
    static let shared = PredictiveCloningWindowManager()
    private var window: NSWindow?
    private init() {}
    func openWindow(sequenceManager: SequenceManager) {
        if let existing = window, existing.isVisible { existing.makeKeyAndOrderFront(nil); return }
        let view = PredictiveCloningView(sequenceManager: sequenceManager)
        let controller = NSHostingController(rootView: view)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 800),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        win.title = "Predictive Cloning"; win.contentViewController = controller;
        win.setFrameAutosaveName("PredictiveCloning_3")
        if !win.setFrameUsingName(win.frameAutosaveName) { win.center() }
        win.isReleasedWhenClosed = false; win.minSize = NSSize(width: 850, height: 650)
        win.makeKeyAndOrderFront(nil); window = win
    }
}


// MARK: - Shuttle Routes View

struct ShuttleRoutesView: View {
    let sourceSequence: String
    let insertRegion: InsertRegion
    let sourceIsCircular: Bool
    let sourceName: String
    let destinationName: String
    let destinationMCSSites: [String]?
    let destinationSequence: String
    let destinationIsCircular: Bool
    let protectedRegions: [ClosedRange<Int>]
    let cloningRegionRange: ClosedRange<Int>?
    /// Enzyme names that already require a partial digest in the direct
    /// cloning strategies. Shuttle routes involving the same partial digest
    /// offer no improvement and are filtered out.
    let directPartialDigestEnzymes: Set<String>
    
    @ObservedObject private var library = ShuttleVectorLibrary.shared
    @State private var routes: [CloningRoute] = []
    @State private var isSearching = true
    @State private var expandedRouteID: UUID? = nil
    @State private var myVectorsOnly = false
    
    private let pathfinder = ShuttleVectorPathfinder()
    
    private var hasMyVectors: Bool { !library.myVectors.isEmpty }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "arrow.triangle.swap").foregroundColor(.purple)
                Text("Shuttle Vector Routes").font(.title2).fontWeight(.semibold)
                Text("(PCR-free)").font(.callout).foregroundColor(.primary.opacity(0.65))
                Spacer()
                // My Vectors filter toggle
                if hasMyVectors {
                    Toggle(isOn: $myVectorsOnly) {
                        Label("My Vectors only", systemImage: "star.fill")
                    }
                    .toggleStyle(.button)
                    .tint(myVectorsOnly ? .yellow : .primary)
                    .controlSize(.small)
                    .help("Restrict search to your earmarked vectors")
                    .contextHelp("shuttleRoutes.myVectorsOnly")
                    .onChange(of: myVectorsOnly) { _ in search() }
                }
                if isSearching {
                    ProgressView().controlSize(.small)
                    Text("Searching…").font(.callout).foregroundColor(.primary.opacity(0.65))
                } else {
                    Text("\(routes.count) routes found").font(.callout).foregroundColor(.primary.opacity(0.65))
                    Button(action: search) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }.buttonStyle(.bordered)
                }
            }.padding([.horizontal, .top])
            
            HStack(spacing: 4) {
                Text("Insert:").fontWeight(.medium)
                Text(sourceName)
                Image(systemName: "arrow.right").foregroundColor(.primary.opacity(0.65))
                Text("shuttle").foregroundColor(.primary.opacity(0.65))
                Image(systemName: "arrow.right").foregroundColor(.primary.opacity(0.65))
                Text(destinationName)
            }.font(.callout).padding(.horizontal)
            
            Divider()
            
            // Metadata disclaimer
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                    .font(.caption)
                Text("Routes are predicted from MCS metadata only. Verify any strategy against the full vector sequence before proceeding to bench work.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.bottom, 2)
            
            Divider()
            
            if isSearching {
                Spacer()
                HStack { Spacer(); ProgressView("Searching vector library…"); Spacer() }
                Spacer()
            } else if routes.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.largeTitle).foregroundColor(.primary.opacity(0.3))
                        Text("No shuttle routes found.").font(.callout)
                        if myVectorsOnly {
                            Text("No compatible routes found in your My Vectors selection. Try turning off the My Vectors filter to search the full library.")
                                .font(.callout).foregroundColor(.primary.opacity(0.65))
                        } else {
                            Text("The vector library may not contain compatible intermediate vectors.")
                                .font(.callout).foregroundColor(.primary.opacity(0.65))
                        }
                    }
                    Spacer()
                }
                Spacer()
            } else {
                List(routes) { route in
                    RouteRow(route: route, isExpanded: expandedRouteID == route.id,
                             onToggle: { expandedRouteID = expandedRouteID == route.id ? nil : route.id })
                }
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .textSelection(.enabled)
        .onAppear { search() }
    }
    
    func search() {
        isSearching = true
        routes = []
        
        let srcSeq = sourceSequence
        let region = insertRegion
        let srcCirc = sourceIsCircular
        let sName = sourceName
        let dName = destinationName
        let dMCS = destinationMCSSites
        let dSeq = destinationSequence
        let dCirc = destinationIsCircular
        let prot = protectedRegions
        let cloneRange = cloningRegionRange
        let myOnly = myVectorsOnly
        
        DispatchQueue.global(qos: .userInitiated).async {
            let result = pathfinder.findRoutes(
                sourceSequence: srcSeq,
                insertRegion: region,
                sourceIsCircular: srcCirc,
                sourceName: sName,
                destinationName: dName,
                destinationMCSSites: dMCS,
                destinationSequence: dSeq,
                destinationIsCircular: dCirc,
                protectedRegions: prot,
                cloningRegionRange: cloneRange,
                myVectorsOnly: myOnly
            )
            DispatchQueue.main.async {
                // Filter out shuttle routes that involve the same partial
                // digest as direct cloning — they don't improve anything.
                if directPartialDigestEnzymes.isEmpty {
                    routes = result
                } else {
                    routes = result.filter { route in
                        // A route is useful only if none of its partial digest
                        // enzymes overlap with direct cloning partial digests.
                        let routePartials = route.partialDigestEnzymeNames   // Set<String>
                        return routePartials.isDisjoint(with: directPartialDigestEnzymes)
                    }
                }
                isSearching = false
            }
        }
    }
}


// MARK: - Shuttle Routes Window Manager

class ShuttleRoutesWindowManager {
    static let shared = ShuttleRoutesWindowManager()
    private var window: NSWindow?
    private init() {}
    
    func openWindow(
        sourceSequence: String,
        insertRegion: InsertRegion,
        sourceIsCircular: Bool,
        sourceName: String,
        destinationName: String,
        destinationMCSSites: [String]?,
        destinationSequence: String,
        destinationIsCircular: Bool,
        protectedRegions: [ClosedRange<Int>],
        cloningRegionRange: ClosedRange<Int>? = nil,
        directPartialDigestEnzymes: Set<String> = []
    ) {
        let view = ShuttleRoutesView(
            sourceSequence: sourceSequence,
            insertRegion: insertRegion,
            sourceIsCircular: sourceIsCircular,
            sourceName: sourceName,
            destinationName: destinationName,
            destinationMCSSites: destinationMCSSites,
            destinationSequence: destinationSequence,
            destinationIsCircular: destinationIsCircular,
            protectedRegions: protectedRegions,
            cloningRegionRange: cloningRegionRange,
            directPartialDigestEnzymes: directPartialDigestEnzymes
        )
        let controller = NSHostingController(rootView: view)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 750, height: 600),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        win.title = "Shuttle Vector Routes — \(sourceName) → \(destinationName)"
        win.contentViewController = controller;
        win.setFrameAutosaveName("ShuttleVectorRoutessourceNamedestinationName")
        if !win.setFrameUsingName(win.frameAutosaveName) { win.center() }
        win.isReleasedWhenClosed = false; win.minSize = NSSize(width: 600, height: 400)
        win.makeKeyAndOrderFront(nil)
        window = win
    }
}


// MARK: - BadgeFlowLayout
//
// A simple wrapping layout (macOS 13+): lays children left-to-right, wrapping
// to a new line when the next child would exceed the available width. Used for
// the strategy badges so they wrap cleanly instead of squishing. Named to avoid
// clashing with the project's existing FlowLayout.
struct BadgeFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0 && rowWidth + spacing + size.width > maxWidth {
                totalWidth = max(totalWidth, rowWidth)
                totalHeight += rowHeight + lineSpacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalWidth = max(totalWidth, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.minX + maxWidth {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

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
    
    // MARK: - Site geometry

    /// Number of bases in the recognition site.
    var siteLength: Int { recognitionSite.count }

    /// Length of the single-stranded overhang, in bases. 0 for blunt cutters.
    var overhangLength: Int { abs(cutPosition3Prime - cutPosition5Prime) }

    /// True when the enzyme cuts OUTSIDE its recognition site (Type IIS, e.g.
    /// BsaI GGTCTC(1/5), BbsI GAAGAC(2/6), SapI GCTCTTC(1/4)).
    ///
    /// Cut positions are stored as offsets from the start of the recognition
    /// site, so a Type IIS enzyme has offsets beyond `siteLength`. These
    /// enzymes' overhangs are whatever the target sequence happens to be at the
    /// cut, so the overhang CANNOT be derived from the recognition site —
    /// use `CutSite.overhang(in:circular:)` instead.
    var cutsOutsideSite: Bool {
        cutPosition5Prime > siteLength || cutPosition3Prime > siteLength
            || cutPosition5Prime < 0 || cutPosition3Prime < 0
    }

    /// True when the recognition site reads the same on both strands, so a
    /// forward-strand search already finds every occurrence.
    var isPalindromic: Bool {
        recognitionSite == RestrictionEnzyme.iupacReverseComplement(recognitionSite)
    }

    /// The fixed single-stranded overhang produced by this enzyme, read 5'→3'
    /// on the top strand, for enzymes that cut WITHIN their recognition site.
    ///
    /// Returns "" for blunt cutters and for Type IIS enzymes — the latter have
    /// no fixed overhang, so returning a recognition-site slice would be a
    /// fabrication. Callers that need a Type IIS overhang must read it from the
    /// target sequence via `CutSite.overhang(in:circular:)`.
    var overhangSequence: String {
        guard overhangType != .blunt else { return "" }
        guard !cutsOutsideSite else { return "" }

        let site = Array(recognitionSite)
        let lo = min(cutPosition5Prime, cutPosition3Prime)
        let hi = max(cutPosition5Prime, cutPosition3Prime)
        guard lo >= 0, hi <= site.count, lo < hi else { return "" }
        return String(site[lo..<hi])
    }

    /// True when the overhang contains an IUPAC ambiguity code, so the actual
    /// single-stranded bases depend on which sequence was cut.
    ///
    /// AccI (GT^MKAC) is the clearest case: its overhang reads "MK", which is
    /// AG, AT, CG or CT depending on the target. Two AccI ends therefore only
    /// ligate if the underlying bases happen to agree — the enzyme identity
    /// alone does not settle it.
    var hasDegenerateOverhang: Bool {
        overhangSequence.contains { !"ACGT".contains($0) }
    }

    /// True when this enzyme leaves the SAME overhang every time it cuts, so
    /// compatibility can be decided from the enzyme alone.
    ///
    /// False for blunt cutters (nothing to match), for Type IIS enzymes (cut
    /// outside the site) and for degenerate-site enzymes (overhang varies).
    var hasFixedOverhang: Bool {
        overhangType != .blunt && !cutsOutsideSite && !hasDegenerateOverhang
            && !overhangSequence.isEmpty
    }

    /// Whether two enzymes leave ligatable ends.
    ///
    /// Type IIS enzymes are deliberately excluded: their overhangs depend on
    /// the target sequence, so "are these two enzymes compatible?" has no
    /// answer in the abstract. Previously both `overhangSequence` values were
    /// empty strings, which made every Type IIS pair compare as compatible.
    ///
    /// Degenerate-site enzymes are excluded for the same reason. AccI, AvaI,
    /// HinfI, StyI and the rest have overhangs containing IUPAC codes, and
    /// comparing those codes as literal text ("MK" == "MK") would report ends
    /// as compatible when the actual bases may not pair at all. To decide a
    /// real case, read the overhang from the sequence with
    /// `CutSite.overhang(in:circular:)` and compare those.
    func producesEndsCompatible(with other: RestrictionEnzyme) -> Bool {
        if overhangType == .blunt && other.overhangType == .blunt { return true }
        guard overhangType == other.overhangType else { return false }
        guard hasFixedOverhang, other.hasFixedOverhang else { return false }
        return overhangSequence == other.overhangSequence
    }
    
    // Find all cut sites in a sequence.
    // For circular sequences, also detects recognition sites that wrap across
    // the origin (e.g. "…CCC|GGG…" for SmaI on a circular plasmid).
    func findCutSites(in sequence: String, circular: Bool = false) -> [CutSite] {
        var sites: [CutSite] = []
        let seqArray = Array(sequence.uppercased())
        let seqLen = seqArray.count
        let pattern = Array(recognitionSite)
        let patLen = pattern.count

        guard patLen > 0, seqLen > 0 else { return [] }

        // For circular sequences, append the first (patLen-1) bases so that
        // recognition sites spanning the origin are found. Only hits whose
        // start position falls within the original length are kept.
        var searchArray = seqArray
        if circular && seqLen >= patLen {
            searchArray.append(contentsOf: seqArray.prefix(patLen - 1))
        }
        let searchLen = searchArray.count
        guard searchLen >= patLen else { return [] }

        // Matching is IUPAC-aware: a pattern base like N, R or W matches any of
        // the bases it stands for. The previous implementation used a literal
        // String.range(of:) search, so degenerate sites such as HinfI's GANTC
        // silently matched nothing at all.
        //
        // Scanning an Array<Character> by integer index also removes the
        // repeated String.index(offsetBy:) walk, which made the old search
        // quadratic in sequence length.
        func matches(_ pattern: [Character], at offset: Int) -> Bool {
            for k in 0..<pattern.count {
                if !RestrictionEnzyme.iupacMatches(patternBase: pattern[k],
                                                   targetBase: searchArray[offset + k]) {
                    return false
                }
            }
            return true
        }

        /// A Type IIS enzyme cuts some distance beyond its recognition site. On
        /// a LINEAR molecule a site close to either end is recognised but
        /// cannot be cut — there is no DNA there to cut into. Such a site must
        /// not be reported, both because it is not really a cut site and
        /// because a cut coordinate past the end of the sequence would feed an
        /// out-of-range value into the fragment-size calculations.
        /// Circular sequences always have DNA on both sides, so nothing is
        /// dropped there.
        func cutIsUsable(_ site: CutSite) -> Bool {
            site.cutIsWithinBounds(sequenceLength: seqLen, circular: circular)
        }

        // Forward strand
        for position in 0...(searchLen - patLen) where position < seqLen {
            if matches(pattern, at: position) {
                let warning = checkMethylationOverlap(seqArray: seqArray, seqLen: seqLen,
                                                      at: position, siteLength: patLen,
                                                      circular: circular)
                let site = CutSite(enzyme: self, position: position,
                                   strand: .forward, methylationWarning: warning)
                if cutIsUsable(site) { sites.append(site) }
            }
        }

        // Reverse strand. Skipped for palindromic sites, which the forward
        // search has already found.
        let reversePattern = Array(RestrictionEnzyme.iupacReverseComplement(recognitionSite))
        if reversePattern != pattern {
            for position in 0...(searchLen - patLen) where position < seqLen {
                if matches(reversePattern, at: position) {
                    let warning = checkMethylationOverlap(seqArray: seqArray, seqLen: seqLen,
                                                          at: position, siteLength: patLen,
                                                          circular: circular)
                    let site = CutSite(enzyme: self, position: position,
                                       strand: .reverse, methylationWarning: warning)
                    if cutIsUsable(site) { sites.append(site) }
                }
            }
        }

        return sites.sorted { $0.position < $1.position }
    }

    // MARK: - IUPAC ambiguity handling

    /// Which concrete bases each IUPAC code stands for.
    static let iupacExpansion: [Character: Set<Character>] = [
        "A": ["A"], "C": ["C"], "G": ["G"], "T": ["T"], "U": ["T"],
        "R": ["A", "G"],           // puRine
        "Y": ["C", "T"],           // pYrimidine
        "S": ["G", "C"],           // Strong (3 H-bonds)
        "W": ["A", "T"],           // Weak (2 H-bonds)
        "K": ["G", "T"],           // Keto
        "M": ["A", "C"],           // aMino
        "B": ["C", "G", "T"],      // not A
        "D": ["A", "G", "T"],      // not C
        "H": ["A", "C", "T"],      // not G
        "V": ["A", "C", "G"],      // not T
        "N": ["A", "C", "G", "T"]  // aNy
    ]

    /// Does a recognition-site base match a base in the target sequence?
    ///
    /// An ambiguous base in the TARGET only matches an identical code, never a
    /// concrete base — an N in the user's sequence means "unknown", so treating
    /// it as a definite match would invent restriction sites that may not exist.
    static func iupacMatches(patternBase: Character, targetBase: Character) -> Bool {
        if patternBase == targetBase { return true }
        guard let allowed = iupacExpansion[patternBase] else { return false }
        // Normalise U to T so RNA-style sequences still match.
        let target: Character = (targetBase == "U") ? "T" : targetBase
        guard let targetSet = iupacExpansion[target], targetSet.count == 1,
              let concrete = targetSet.first else { return false }
        return allowed.contains(concrete)
    }

    /// Base-for-base complement across the full IUPAC alphabet.
    ///
    /// This is the ONE place the app decides what pairs with what. Several
    /// hand-written A/C/G/T-only tables used to exist alongside it; they left
    /// degenerate codes unchanged, so AccI (GTMKAC) displayed a lower strand of
    /// CAMKTG instead of CAKMTG, and AvaI (CYCGRG) showed GYGCRC instead of
    /// GRGCYC. Anything needing a complement must come through here.
    ///
    /// The pairings follow from the definitions: R (A or G) pairs with
    /// Y (T or C); K (G or T) with M (C or A); B (not A) with V (not T);
    /// D (not C) with H (not G). S, W and N are their own complements.
    static let iupacComplementMap: [Character: Character] = [
        "A": "T", "T": "A", "G": "C", "C": "G", "U": "A",
        "R": "Y", "Y": "R", "S": "S", "W": "W",
        "K": "M", "M": "K",
        "B": "V", "V": "B", "D": "H", "H": "D",
        "N": "N"
    ]

    /// Complement of a single base. Unrecognised characters pass through so a
    /// malformed site is still displayed rather than silently blanked.
    static func iupacComplement(_ base: Character) -> Character {
        iupacComplementMap[base] ?? base
    }

    /// Complement of a whole strand, WITHOUT reversing it.
    ///
    /// Used for the two-line cut diagrams, where the lower strand is printed
    /// left-to-right (3'→5') so each base sits directly beneath its partner.
    static func iupacComplement(_ seq: String) -> String {
        String(seq.uppercased().map { iupacComplement($0) })
    }

    /// Reverse complement that understands the full IUPAC alphabet. The old
    /// local helper mapped only A/C/G/T/N and passed everything else through
    /// unchanged, which produced wrong reverse-strand patterns for any
    /// degenerate site.
    static func iupacReverseComplement(_ seq: String) -> String {
        String(seq.uppercased().reversed().map { iupacComplement($0) })
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
    
    // The old private reverseComplement() lived here. It mapped only A/C/G/T/N
    // and passed any other letter through unchanged, so degenerate sites got a
    // wrong reverse-strand pattern. Replaced by the static
    // RestrictionEnzyme.iupacReverseComplement(_:) above.
}

struct CutSite: Identifiable {
    let id = UUID()
    let enzyme: RestrictionEnzyme
    /// Start of the recognition site on the top strand (0-based).
    /// This is what the graphical map and site lists label, even for Type IIS
    /// enzymes whose actual cut lies elsewhere.
    let position: Int
    let strand: Strand
    let methylationWarning: String

    /// Where the enzyme cuts the TOP strand, as a 0-based coordinate.
    ///
    /// For a reverse-strand hit the enzyme reads the bottom strand, so its cut
    /// offsets run leftward in top-strand coordinates and the two strands swap
    /// roles. An enzyme-frame offset `c` maps to top-strand coordinate
    /// `position + siteLength - c`.
    ///
    /// This matters only for non-palindromic enzymes, because palindromic sites
    /// are never reported on the reverse strand (the forward search finds them
    /// all). In practice that means the Type IIS enzymes and I-SceI.
    var cutPosition5Prime: Int {
        switch strand {
        case .forward:
            return position + enzyme.cutPosition5Prime
        case .reverse:
            return position + enzyme.siteLength - enzyme.cutPosition3Prime
        }
    }

    /// Where the enzyme cuts the BOTTOM strand, as a 0-based top-strand coordinate.
    var cutPosition3Prime: Int {
        switch strand {
        case .forward:
            return position + enzyme.cutPosition3Prime
        case .reverse:
            return position + enzyme.siteLength - enzyme.cutPosition5Prime
        }
    }

    /// True when the cut falls outside the sequence bounds. Type IIS sites near
    /// either end of a LINEAR sequence are recognised but not cut, because the
    /// enzyme needs flanking DNA to cut into.
    func cutIsWithinBounds(sequenceLength: Int, circular: Bool) -> Bool {
        if circular { return true }
        let lo = min(cutPosition5Prime, cutPosition3Prime)
        let hi = max(cutPosition5Prime, cutPosition3Prime)
        return lo >= 0 && hi <= sequenceLength
    }

    /// The single-stranded overhang this cut actually produces, read 5'→3' on
    /// the top strand, taken from the real target sequence.
    ///
    /// This is the only correct way to get a Type IIS overhang, since those
    /// enzymes cut into whatever sequence lies beyond their recognition site.
    /// Returns "" for blunt cuts, or when the cut runs off the end of a linear
    /// sequence.
    func overhang(in sequence: String, circular: Bool) -> String {
        guard enzyme.overhangType != .blunt else { return "" }
        let bases = Array(sequence.uppercased())
        let seqLen = bases.count
        guard seqLen > 0 else { return "" }

        let lo = min(cutPosition5Prime, cutPosition3Prime)
        let hi = max(cutPosition5Prime, cutPosition3Prime)
        guard hi > lo else { return "" }

        if circular {
            return String((lo..<hi).map { bases[(($0 % seqLen) + seqLen) % seqLen] })
        }
        guard lo >= 0, hi <= seqLen else { return "" }
        return String(bases[lo..<hi])
    }
}

// MARK: - Digest fragment sizes

/// The single implementation of "what fragments does this digest produce?".
///
/// This calculation previously existed in four places — ConstructCheckAnalyzer,
/// DigestVerificationAnalyzer, SiteUsageView and VirtualCutterView — and the
/// copies had drifted apart. The two analyzers computed a circular fragment as
/// `dist == 0 ? seqLen : dist`, which is right for a single cut (one break
/// linearises a plasmid, giving one full-length fragment) but wrong when two
/// enzymes cut the SAME base: each coincident pair produced a spurious extra
/// full-length band. That is reachable in ordinary use — MspI and HpaII both cut
/// CCGG at the same offset, as do other isoschizomer pairs — so a double digest
/// with such a pair reported bands that do not exist.
///
/// The behaviour below matches what the two views already did, which is correct,
/// so Site Usage and Virtual Cutter are unaffected by the consolidation.
enum DigestCalculator {

    /// Fragment lengths produced by cutting a molecule at the given positions.
    ///
    /// - Parameters:
    ///   - cutPositions: top-strand cut coordinates, 0-based. Duplicates are
    ///     expected and handled — two enzymes cutting the same base make one
    ///     break, not two. Values outside the sequence are wrapped into range.
    ///   - sequenceLength: length of the molecule in bp.
    ///   - circular: true for a plasmid, false for a linear fragment.
    /// - Returns: fragment lengths in cut order, unsorted, with zero-length
    ///   fragments omitted. Callers that want a gel-style list sort descending.
    static func fragmentSizes(cutPositions: [Int],
                              sequenceLength: Int,
                              circular: Bool) -> [Int] {
        guard sequenceLength > 0 else { return [] }

        // Wrap into range, then collapse coincident cuts.
        let cuts = Set(cutPositions.map {
            (($0 % sequenceLength) + sequenceLength) % sequenceLength
        }).sorted()

        // Uncut molecule.
        guard !cuts.isEmpty else { return [sequenceLength] }

        var fragments: [Int] = []

        if circular {
            // A single break turns the circle into one full-length linear piece.
            if cuts.count == 1 { return [sequenceLength] }
            for i in 0 ..< cuts.count {
                let next = (i + 1) % cuts.count
                let size = (cuts[next] - cuts[i] + sequenceLength) % sequenceLength
                if size > 0 { fragments.append(size) }
            }
        } else {
            // Piece before the first cut, pieces between cuts, piece after the last.
            if cuts[0] > 0 { fragments.append(cuts[0]) }
            for i in 0 ..< (cuts.count - 1) {
                let size = cuts[i + 1] - cuts[i]
                if size > 0 { fragments.append(size) }
            }
            if let last = cuts.last, last < sequenceLength {
                fragments.append(sequenceLength - last)
            }
        }

        return fragments
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
            guard !isLoading else { return }
            UserDefaults.standard.set(Array(myEnzymeNames), forKey: "myEnzymeNames")
            overlay.myEnzymeNames = Array(myEnzymeNames)
            persist()
        }
    }
    
    /// The subset of the database that the user has marked as "in my freezer".
    var myEnzymes: [RestrictionEnzyme] {
        enzymes.filter { myEnzymeNames.contains($0.name) }
    }

    /// How many starred enzymes actually EXIST in the database.
    ///
    /// Not the same as `myEnzymeNames.count`. Stars are stored by name, so a
    /// name can outlive the enzyme — delete a starred enzyme, or rename one in
    /// a later version, and the name lingers with nothing behind it. Counting
    /// the raw name set made the toolbar report more enzymes than the table
    /// was showing.
    var myEnzymeCount: Int { myEnzymes.count }
    
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
    
    // MARK: - Persistence
    //
    // `enzymes` is not stored directly. The built-in list is rebuilt from
    // source on every launch and the user's saved changes are laid over the top
    // (see EnzymeStore.swift for why). Everything that mutates the database
    // therefore edits `overlay`, saves it, and rebuilds.

    /// The built-in list, exactly as written in `commonEnzymes()`.
    private var builtIns: [RestrictionEnzyme] = []

    /// The user's saved changes.
    private var overlay = EnzymeOverlay()

    /// Suppresses saving while `init` is populating properties, so loading the
    /// store does not immediately write it back.
    private var isLoading = false

    /// Set when a save or load fails, so the UI can report it. Nil when fine.
    @Published private(set) var storeError: String?

    /// True when the user has added, edited or deleted anything.
    var hasCustomisations: Bool { !overlay.isEmpty }

    /// A copy of the current overlay, for Export.
    var currentOverlay: EnzymeOverlay {
        var o = overlay
        o.myEnzymeNames = Array(myEnzymeNames)
        return o
    }

    init() {
        isLoading = true

        builtIns = RestrictionEnzymeDatabase.commonEnzymes()
        overlay = EnzymeStore.load()
        storeError = EnzymeStore.lastError

        // Freezer list: prefer the copy inside the store, but fall back to the
        // old UserDefaults key so existing users do not lose their stars when
        // they first run a build that has the store.
        if overlay.myEnzymeNames.isEmpty,
           let legacy = UserDefaults.standard.stringArray(forKey: "myEnzymeNames") {
            overlay.myEnzymeNames = legacy
        }
        myEnzymeNames = Set(overlay.myEnzymeNames)

        isLoading = false
        rebuild()
        reconcileFavourites()
    }

    /// Tidy the freezer list against the enzymes that actually exist.
    ///
    /// Run once at launch, deliberately not after every edit: deleting an
    /// enzyme mid-session should not silently discard the star, in case the
    /// deletion was a slip and gets undone. By the next launch, anything still
    /// unmatched is genuinely stale.
    ///
    /// Before dropping a name, try to re-home it. Enzyme entries carry their
    /// isoschizomers in the name ("AvaI/BsoBI/Eco88I"), and those names get
    /// revised as the built-in list grows — a star on "AvaI/Eco88I" should
    /// follow the enzyme rather than be thrown away because the label changed.
    /// Matching on any shared alias handles that. The alias sets across the
    /// built-in list are unique, so this cannot silently move a star to a
    /// different enzyme.
    private func reconcileFavourites() {
        guard !myEnzymeNames.isEmpty else { return }

        /// "AvaI/BsoBI/Eco88I" -> ["AvaI", "BsoBI", "Eco88I"]
        func aliases(_ name: String) -> Set<String> {
            Set(name.split(separator: "/").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty })
        }

        let liveNames = Set(enzymes.map { $0.name })
        var resolved: Set<String> = []

        for starred in myEnzymeNames {
            if liveNames.contains(starred) {
                resolved.insert(starred)
                continue
            }
            // Exact name has gone. Look for an enzyme sharing an alias.
            let wanted = aliases(starred)
            if let match = enzymes.first(where: { !aliases($0.name).isDisjoint(with: wanted) }) {
                resolved.insert(match.name)
            }
            // Otherwise the star is dropped.
        }

        // Only write when something actually changed, so a normal launch does
        // not rewrite the store for no reason.
        if resolved != myEnzymeNames {
            myEnzymeNames = resolved
        }
    }

    /// Rebuild `enzymes` from the built-in list plus the overlay.
    private func rebuild() {
        let deleted = Set(overlay.deleted)
        var result: [RestrictionEnzyme] = []
        result.reserveCapacity(builtIns.count + overlay.added.count)

        for enzyme in builtIns where !deleted.contains(enzyme.name) {
            // An edited built-in is substituted in place; an untouched one
            // comes straight from source, so later corrections reach the user.
            result.append(overlay.edited[enzyme.name] ?? enzyme)
        }
        result.append(contentsOf: overlay.added)
        result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        enzymes = result
    }

    /// Write the overlay to disk and record any failure.
    private func persist() {
        var toSave = overlay
        toSave.myEnzymeNames = Array(myEnzymeNames)
        overlay = toSave
        if !EnzymeStore.save(toSave) {
            storeError = EnzymeStore.lastError
        } else {
            storeError = nil
        }
    }

    /// Is this name one of the built-in enzymes?
    private func isBuiltIn(_ name: String) -> Bool {
        builtIns.contains { $0.name == name }
    }

    /// The built-in name an overlay edit is keyed under, for a live enzyme.
    private func builtInKey(forEditedID id: UUID) -> String? {
        for (key, value) in overlay.edited where value.id == id { return key }
        return nil
    }

    // MARK: - Mutation

    func addEnzyme(_ enzyme: RestrictionEnzyme) {
        overlay.added.append(enzyme)
        // Adding back something previously deleted un-deletes it.
        overlay.deleted.removeAll { $0 == enzyme.name }
        persist()
        rebuild()
    }

    func removeEnzyme(id: UUID) {
        guard let target = enzymes.first(where: { $0.id == id }) else { return }

        // A user-added enzyme is simply dropped.
        if let idx = overlay.added.firstIndex(where: { $0.id == id }) {
            overlay.added.remove(at: idx)
            persist()
            rebuild()
            return
        }

        // Otherwise it is a built-in (possibly an edited one), so record a
        // deletion against the ORIGINAL built-in name.
        let key = builtInKey(forEditedID: id) ?? target.name
        overlay.edited.removeValue(forKey: key)
        if !overlay.deleted.contains(key) {
            overlay.deleted.append(key)
        }
        persist()
        rebuild()
    }

    func updateEnzyme(_ enzyme: RestrictionEnzyme) {
        // Editing a user-added enzyme.
        if let idx = overlay.added.firstIndex(where: { $0.id == enzyme.id }) {
            overlay.added[idx] = enzyme
            persist()
            rebuild()
            return
        }

        // Editing a built-in: store it against the built-in name, so the key
        // survives the user renaming the enzyme.
        if let existingKey = builtInKey(forEditedID: enzyme.id) {
            overlay.edited[existingKey] = enzyme
        } else if let original = builtIns.first(where: { $0.id == enzyme.id }) {
            overlay.edited[original.name] = enzyme
        } else if isBuiltIn(enzyme.name) {
            overlay.edited[enzyme.name] = enzyme
        } else {
            // Unknown provenance — treat it as a new addition rather than
            // dropping the user's edit on the floor.
            overlay.added.append(enzyme)
        }
        persist()
        rebuild()
    }

    // MARK: - Export / Import / Reset

    /// Replace all customisations with the contents of an imported file.
    func replaceCustomisations(with incoming: EnzymeOverlay) {
        isLoading = true
        overlay = incoming
        myEnzymeNames = Set(incoming.myEnzymeNames)
        UserDefaults.standard.set(incoming.myEnzymeNames, forKey: "myEnzymeNames")
        isLoading = false
        persist()
        rebuild()
    }

    /// Fold an imported file into the existing customisations.
    func mergeCustomisations(with incoming: EnzymeOverlay) {
        let merged = EnzymeStore.merge(incoming, into: currentOverlay)
        replaceCustomisations(with: merged)
    }

    /// Discard all added, edited and deleted enzymes. The freezer stars are
    /// kept, since they refer to enzymes rather than changing them.
    func restoreBuiltInDefaults() {
        overlay.added = []
        overlay.edited = [:]
        overlay.deleted = []
        persist()
        rebuild()
    }
    
    /// Groups enzymes by their compatible overhang: (overhangType, overhangSequence).
    /// All blunt cutters form one group. Sticky cutters are grouped by overhang type + sequence.
    func compatibleEndGroups() -> [(overhang: String, type: RestrictionEnzyme.OverhangType, enzymes: [RestrictionEnzyme])] {
        var groups: [String: (type: RestrictionEnzyme.OverhangType, enzymes: [RestrictionEnzyme])] = [:]

        for enzyme in enzymes {
            // Type IIS enzymes have no fixed overhang — it depends on the
            // sequence they happen to cut into — so they cannot belong to a
            // fixed compatibility group. Previously their overhangSequence was
            // an empty string, which lumped BsaI, BsmBI, BbsI and SapI into one
            // bogus "compatible" group.
            if enzyme.cutsOutsideSite { continue }

            // Likewise for degenerate sites: AccI's overhang "MK" is not a
            // sequence, it is four possible sequences. Grouping by the literal
            // text would claim compatibility that may not exist.
            if enzyme.overhangType != .blunt && enzyme.hasDegenerateOverhang { continue }

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
    
    // The built-in enzyme list. This is the single source of truth for the
    // enzymes that ship with the app; user changes live in the overlay and are
    // applied on top of whatever this returns, so corrections made here still
    // reach existing users.
    //
    // Coordinate convention, in case you are adding entries by hand:
    //   cutPosition5Prime = bases before the TOP strand cut, from the start of
    //                       the recognition site.
    //   cutPosition3Prime = the same axis, for the BOTTOM strand cut.
    // For a palindromic site of length n cut at p, the bottom cut is at n - p.
    // EcoRI G^AATTC is therefore 1 and 5.

    private static func commonEnzymes() -> [RestrictionEnzyme] {
        return [
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
            //
            // These cut OUTSIDE their recognition site. REBASE writes BsaI as
            // GGTCTC(1/5), meaning the top strand is cut 1 base past the 6-base
            // site and the bottom strand 5 bases past it. Because this app
            // stores cut positions as offsets from the START of the site, those
            // become 6+1=7 and 6+5=11.
            //
            // They were previously stored as the raw REBASE numbers (1 and 5),
            // which placed the cut inside the recognition site — the same
            // geometry as EcoRI. That made every Type IIS fragment size and
            // overhang wrong. The 4-base overhang these leave is sequence-
            // dependent, so it is read from the target via CutSite.overhang().
            RestrictionEnzyme(name: "BsaI", recognitionSite: "GGTCTC", cutPosition5Prime: 7, cutPosition3Prime: 11, overhangType: .sticky5Prime, methylationSensitivity: "dcm impaired (partial overlap)"),
            RestrictionEnzyme(name: "BsmBI", recognitionSite: "CGTCTC", cutPosition5Prime: 7, cutPosition3Prime: 11, overhangType: .sticky5Prime, methylationSensitivity: "CpG blocked"),
            RestrictionEnzyme(name: "BbsI", recognitionSite: "GAAGAC", cutPosition5Prime: 8, cutPosition3Prime: 12, overhangType: .sticky5Prime),
            
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
            // NlaIII is CATG^ — the top strand is cut after the site and the
            // bottom strand before it, leaving a 4-base 3' overhang. It was
            // labelled .sticky5Prime, which contradicted its own cut positions
            // (4 and 0) and would have paired it with the wrong partners.
            RestrictionEnzyme(name: "NlaIII", recognitionSite: "CATG", cutPosition5Prime: 4, cutPosition3Prime: 0, overhangType: .sticky3Prime),
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
            // I-SceI: NEB writes this as TAGGGATAACAGGGTAAT(-9/-13), where the
            // numbers count BACK from the 3' end of the 18-base site. As offsets
            // from the site start that is 18-9 = 9 and 18-13 = 5, giving the
            // 4-base 3' overhang the enzyme is known for.
            //
            // The stored value used to be 9 and 13 — the REBASE numbers copied
            // across without converting. That made the bottom cut fall to the
            // RIGHT of the top cut, i.e. a 4-base 5' overhang: the correct
            // length, the wrong strand, and incompatible with real I-SceI ends.
            RestrictionEnzyme(name: "I-SceI", recognitionSite: "TAGGGATAACAGGGTAAT", cutPosition5Prime: 9, cutPosition3Prime: 5, overhangType: .sticky3Prime),
            
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
            // SapI is GCTCTTC(1/4): a 7-base site, top strand cut 1 base past it
            // and bottom strand 4 bases past it, leaving a 3-base 5' overhang.
            // As offsets from the site start that is 7+1=8 and 7+4=11.
            // (These were previously stored as the literal 1 and 4 — the old
            // comment described them as placeholders.)
            RestrictionEnzyme(name: "SapI", recognitionSite: "GCTCTTC", cutPosition5Prime: 8, cutPosition3Prime: 11, overhangType: .sticky5Prime),
            
            // ================================================================
            // DEGENERATE-SITE ENZYMES (IUPAC ambiguity codes in the site)
            //
            // Recognition sequences taken from the NEB / REBASE alphabetized
            // list of recognition specificities. The top-strand cut is as
            // published; the bottom-strand cut is n - p, which is forced by the
            // two-fold symmetry of a palindromic site rather than typed by hand.
            //
            // Note that most of these leave a DEGENERATE overhang — AccI's is
            // "MK", which is AG, AT, CG or CT depending on the target. The app
            // therefore refuses to declare their ends compatible from the
            // enzyme identity alone (see `hasFixedOverhang`). ApoI is an
            // exception: its overhang is a plain AATT, matching EcoRI.
            // ================================================================
            
            // AccI  GT^MKAC  — 6 bp, 5' overhang, overhang MK (degenerate)
            RestrictionEnzyme(name: "AccI", recognitionSite: "GTMKAC", cutPosition5Prime: 2, cutPosition3Prime: 4, overhangType: .sticky5Prime),
            
            // AflIII  A^CRYGT  — 6 bp, 5' overhang, overhang CRYG (degenerate)
            RestrictionEnzyme(name: "AflIII", recognitionSite: "ACRYGT", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime),
            
            // AlwNI  CAGNNN^CTG  — 9 bp, 3' overhang, overhang NNN (degenerate)
            RestrictionEnzyme(name: "AlwNI", recognitionSite: "CAGNNNCTG", cutPosition5Prime: 6, cutPosition3Prime: 3, overhangType: .sticky3Prime),
            
            // ApoI  R^AATTY  — 6 bp, 5' overhang, overhang AATT
            RestrictionEnzyme(name: "ApoI", recognitionSite: "RAATTY", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime),
            
            // AvaI/BsoBI/Eco88I  C^YCGRG  — 6 bp, 5' overhang, overhang YCGR (degenerate)
            RestrictionEnzyme(name: "AvaI/BsoBI/Eco88I", recognitionSite: "CYCGRG", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime, methylationSensitivity: "CpG blocked"),
            
            // AvaII  G^GWCC  — 5 bp, 5' overhang, overhang GWC (degenerate)
            RestrictionEnzyme(name: "AvaII", recognitionSite: "GGWCC", cutPosition5Prime: 1, cutPosition3Prime: 4, overhangType: .sticky5Prime),
            
            // BanI  G^GYRCC  — 6 bp, 5' overhang, overhang GYRC (degenerate)
            RestrictionEnzyme(name: "BanI", recognitionSite: "GGYRCC", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime),
            
            // BanII/Eco24I  GRGCY^C  — 6 bp, 3' overhang, overhang RGCY (degenerate)
            RestrictionEnzyme(name: "BanII/Eco24I", recognitionSite: "GRGCYC", cutPosition5Prime: 5, cutPosition3Prime: 1, overhangType: .sticky3Prime),
            
            // BsaJI  C^CNNGG  — 6 bp, 5' overhang, overhang CNNG (degenerate)
            RestrictionEnzyme(name: "BsaJI", recognitionSite: "CCNNGG", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime, methylationSensitivity: "dcm blocked"),
            
            // BsaWI  W^CCGGW  — 6 bp, 5' overhang, overhang CCGG
            RestrictionEnzyme(name: "BsaWI", recognitionSite: "WCCGGW", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime),
            
            // BsiEI  CGRY^CG  — 6 bp, 3' overhang, overhang RY (degenerate)
            RestrictionEnzyme(name: "BsiEI", recognitionSite: "CGRYCG", cutPosition5Prime: 4, cutPosition3Prime: 2, overhangType: .sticky3Prime, methylationSensitivity: "CpG blocked"),
            
            // BsiHKAI  GWGCW^C  — 6 bp, 3' overhang, overhang WGCW (degenerate)
            RestrictionEnzyme(name: "BsiHKAI", recognitionSite: "GWGCWC", cutPosition5Prime: 5, cutPosition3Prime: 1, overhangType: .sticky3Prime),
            
            // BslI  CCNNNNN^NNGG  — 11 bp, 3' overhang, overhang NNN (degenerate)
            RestrictionEnzyme(name: "BslI", recognitionSite: "CCNNNNNNNGG", cutPosition5Prime: 7, cutPosition3Prime: 4, overhangType: .sticky3Prime),
            
            // Bsp1286I  GDGCH^C  — 6 bp, 3' overhang, overhang DGCH (degenerate)
            RestrictionEnzyme(name: "Bsp1286I", recognitionSite: "GDGCHC", cutPosition5Prime: 5, cutPosition3Prime: 1, overhangType: .sticky3Prime),
            
            // BsrFI  R^CCGGY  — 6 bp, 5' overhang, overhang CCGG
            RestrictionEnzyme(name: "BsrFI", recognitionSite: "RCCGGY", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime),
            
            // BstAPI  GCANNNN^NTGC  — 11 bp, 3' overhang, overhang NNN (degenerate)
            RestrictionEnzyme(name: "BstAPI", recognitionSite: "GCANNNNNTGC", cutPosition5Prime: 7, cutPosition3Prime: 4, overhangType: .sticky3Prime),
            
            // BstEII  G^GTNACC  — 7 bp, 5' overhang, overhang GTNAC (degenerate)
            RestrictionEnzyme(name: "BstEII", recognitionSite: "GGTNACC", cutPosition5Prime: 1, cutPosition3Prime: 6, overhangType: .sticky5Prime),
            
            // BstXI  CCANNNNN^NTGG  — 12 bp, 3' overhang, overhang NNNN (degenerate)
            RestrictionEnzyme(name: "BstXI", recognitionSite: "CCANNNNNNTGG", cutPosition5Prime: 8, cutPosition3Prime: 4, overhangType: .sticky3Prime),
            
            // BstYI  R^GATCY  — 6 bp, 5' overhang, overhang GATC
            RestrictionEnzyme(name: "BstYI", recognitionSite: "RGATCY", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime, methylationSensitivity: "dam blocked"),
            
            // BtgI  C^CRYGG  — 6 bp, 5' overhang, overhang CRYG (degenerate)
            RestrictionEnzyme(name: "BtgI", recognitionSite: "CCRYGG", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime),
            
            // Cac8I  GCN^NGC  — 6 bp, blunt
            RestrictionEnzyme(name: "Cac8I", recognitionSite: "GCNNGC", cutPosition5Prime: 3, cutPosition3Prime: 3, overhangType: .blunt),
            
            // DdeI  C^TNAG  — 5 bp, 5' overhang, overhang TNA (degenerate)
            RestrictionEnzyme(name: "DdeI", recognitionSite: "CTNAG", cutPosition5Prime: 1, cutPosition3Prime: 4, overhangType: .sticky5Prime),
            
            // DraIII  CACNNN^GTG  — 9 bp, 3' overhang, overhang NNN (degenerate)
            RestrictionEnzyme(name: "DraIII", recognitionSite: "CACNNNGTG", cutPosition5Prime: 6, cutPosition3Prime: 3, overhangType: .sticky3Prime),
            
            // DrdI  GACNNNN^NNGTC  — 12 bp, 3' overhang, overhang NN (degenerate)
            RestrictionEnzyme(name: "DrdI", recognitionSite: "GACNNNNNNGTC", cutPosition5Prime: 7, cutPosition3Prime: 5, overhangType: .sticky3Prime),
            
            // EaeI  Y^GGCCR  — 6 bp, 5' overhang, overhang GGCC
            RestrictionEnzyme(name: "EaeI", recognitionSite: "YGGCCR", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime),
            
            // EcoNI  CCTNN^NNNAGG  — 11 bp, 5' overhang, overhang N (degenerate)
            RestrictionEnzyme(name: "EcoNI", recognitionSite: "CCTNNNNNAGG", cutPosition5Prime: 5, cutPosition3Prime: 6, overhangType: .sticky5Prime),
            
            // EcoO109I  RG^GNCCY  — 7 bp, 5' overhang, overhang GNC (degenerate)
            RestrictionEnzyme(name: "EcoO109I", recognitionSite: "RGGNCCY", cutPosition5Prime: 2, cutPosition3Prime: 5, overhangType: .sticky5Prime),
            
            // Fnu4HI  GC^NGC  — 5 bp, 5' overhang, overhang N (degenerate)
            RestrictionEnzyme(name: "Fnu4HI", recognitionSite: "GCNGC", cutPosition5Prime: 2, cutPosition3Prime: 3, overhangType: .sticky5Prime),
            
            // HaeII  RGCGC^Y  — 6 bp, 3' overhang, overhang GCGC
            RestrictionEnzyme(name: "HaeII", recognitionSite: "RGCGCY", cutPosition5Prime: 5, cutPosition3Prime: 1, overhangType: .sticky3Prime, methylationSensitivity: "CpG blocked"),
            
            // HincII/HindII  GTY^RAC  — 6 bp, blunt
            RestrictionEnzyme(name: "HincII/HindII", recognitionSite: "GTYRAC", cutPosition5Prime: 3, cutPosition3Prime: 3, overhangType: .blunt),
            
            // Hpy166II  GTN^NAC  — 6 bp, blunt
            RestrictionEnzyme(name: "Hpy166II", recognitionSite: "GTNNAC", cutPosition5Prime: 3, cutPosition3Prime: 3, overhangType: .blunt),
            
            // Hpy188I  TCN^GA  — 5 bp, 3' overhang, overhang N (degenerate)
            RestrictionEnzyme(name: "Hpy188I", recognitionSite: "TCNGA", cutPosition5Prime: 3, cutPosition3Prime: 2, overhangType: .sticky3Prime),
            
            // Hpy188III  TC^NNGA  — 6 bp, 5' overhang, overhang NN (degenerate)
            RestrictionEnzyme(name: "Hpy188III", recognitionSite: "TCNNGA", cutPosition5Prime: 2, cutPosition3Prime: 4, overhangType: .sticky5Prime),
            
            // HpyCH4III  ACN^GT  — 5 bp, 3' overhang, overhang N (degenerate)
            RestrictionEnzyme(name: "HpyCH4III", recognitionSite: "ACNGT", cutPosition5Prime: 3, cutPosition3Prime: 2, overhangType: .sticky3Prime),
            
            // MslI  CAYNN^NNRTG  — 10 bp, blunt
            RestrictionEnzyme(name: "MslI", recognitionSite: "CAYNNNNRTG", cutPosition5Prime: 5, cutPosition3Prime: 5, overhangType: .blunt),
            
            // MspA1I  CMG^CKG  — 6 bp, blunt
            RestrictionEnzyme(name: "MspA1I", recognitionSite: "CMGCKG", cutPosition5Prime: 3, cutPosition3Prime: 3, overhangType: .blunt, methylationSensitivity: "CpG blocked"),
            
            // MwoI  GCNNNNN^NNGC  — 11 bp, 3' overhang, overhang NNN (degenerate)
            RestrictionEnzyme(name: "MwoI", recognitionSite: "GCNNNNNNNGC", cutPosition5Prime: 7, cutPosition3Prime: 4, overhangType: .sticky3Prime),
            
            // NciI  CC^SGG  — 5 bp, 5' overhang, overhang S (degenerate)
            RestrictionEnzyme(name: "NciI", recognitionSite: "CCSGG", cutPosition5Prime: 2, cutPosition3Prime: 3, overhangType: .sticky5Prime, methylationSensitivity: "dcm blocked"),
            
            // NlaIV  GGN^NCC  — 6 bp, blunt
            RestrictionEnzyme(name: "NlaIV", recognitionSite: "GGNNCC", cutPosition5Prime: 3, cutPosition3Prime: 3, overhangType: .blunt),
            
            // NspI  RCATG^Y  — 6 bp, 3' overhang, overhang CATG
            RestrictionEnzyme(name: "NspI", recognitionSite: "RCATGY", cutPosition5Prime: 5, cutPosition3Prime: 1, overhangType: .sticky3Prime),
            
            // PflFI/Tth111I  GACN^NNGTC  — 9 bp, 5' overhang, overhang N (degenerate)
            RestrictionEnzyme(name: "PflFI/Tth111I", recognitionSite: "GACNNNGTC", cutPosition5Prime: 4, cutPosition3Prime: 5, overhangType: .sticky5Prime),
            
            // PflMI  CCANNNN^NTGG  — 11 bp, 3' overhang, overhang NNN (degenerate)
            RestrictionEnzyme(name: "PflMI", recognitionSite: "CCANNNNNTGG", cutPosition5Prime: 7, cutPosition3Prime: 4, overhangType: .sticky3Prime),
            
            // PpuMI  RG^GWCCY  — 7 bp, 5' overhang, overhang GWC (degenerate)
            RestrictionEnzyme(name: "PpuMI", recognitionSite: "RGGWCCY", cutPosition5Prime: 2, cutPosition3Prime: 5, overhangType: .sticky5Prime),
            
            // PshAI  GACNN^NNGTC  — 10 bp, blunt
            RestrictionEnzyme(name: "PshAI", recognitionSite: "GACNNNNGTC", cutPosition5Prime: 5, cutPosition3Prime: 5, overhangType: .blunt),
            
            // RsrII  CG^GWCCG  — 7 bp, 5' overhang, overhang GWC (degenerate)
            RestrictionEnzyme(name: "RsrII", recognitionSite: "CGGWCCG", cutPosition5Prime: 2, cutPosition3Prime: 5, overhangType: .sticky5Prime, methylationSensitivity: "CpG blocked"),
            
            // Sau96I  G^GNCC  — 5 bp, 5' overhang, overhang GNC (degenerate)
            RestrictionEnzyme(name: "Sau96I", recognitionSite: "GGNCC", cutPosition5Prime: 1, cutPosition3Prime: 4, overhangType: .sticky5Prime),
            
            // ScrFI  CC^NGG  — 5 bp, 5' overhang, overhang N (degenerate)
            RestrictionEnzyme(name: "ScrFI", recognitionSite: "CCNGG", cutPosition5Prime: 2, cutPosition3Prime: 3, overhangType: .sticky5Prime, methylationSensitivity: "dcm blocked"),
            
            // SexAI  A^CCWGGT  — 7 bp, 5' overhang, overhang CCWGG (degenerate)
            RestrictionEnzyme(name: "SexAI", recognitionSite: "ACCWGGT", cutPosition5Prime: 1, cutPosition3Prime: 6, overhangType: .sticky5Prime, methylationSensitivity: "dcm blocked"),
            
            // SfcI  C^TRYAG  — 6 bp, 5' overhang, overhang TRYA (degenerate)
            RestrictionEnzyme(name: "SfcI", recognitionSite: "CTRYAG", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime),
            
            // SfiI  GGCCNNNN^NGGCC  — 13 bp, 3' overhang, overhang NNN (degenerate)
            RestrictionEnzyme(name: "SfiI", recognitionSite: "GGCCNNNNNGGCC", cutPosition5Prime: 8, cutPosition3Prime: 5, overhangType: .sticky3Prime),
            
            // SgrAI  CR^CCGGYG  — 8 bp, 5' overhang, overhang CCGG
            RestrictionEnzyme(name: "SgrAI", recognitionSite: "CRCCGGYG", cutPosition5Prime: 2, cutPosition3Prime: 6, overhangType: .sticky5Prime, methylationSensitivity: "CpG blocked"),
            
            // SmlI  C^TYRAG  — 6 bp, 5' overhang, overhang TYRA (degenerate)
            RestrictionEnzyme(name: "SmlI", recognitionSite: "CTYRAG", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime),
            
            // StyI  C^CWWGG  — 6 bp, 5' overhang, overhang CWWG (degenerate)
            RestrictionEnzyme(name: "StyI", recognitionSite: "CCWWGG", cutPosition5Prime: 1, cutPosition3Prime: 5, overhangType: .sticky5Prime, methylationSensitivity: "dcm blocked"),
            
            // TfiI  G^AWTC  — 5 bp, 5' overhang, overhang AWT (degenerate)
            RestrictionEnzyme(name: "TfiI", recognitionSite: "GAWTC", cutPosition5Prime: 1, cutPosition3Prime: 4, overhangType: .sticky5Prime),
            
            // Tsp45I  ^GTSAC  — 5 bp, 5' overhang, overhang GTSAC (degenerate)
            RestrictionEnzyme(name: "Tsp45I", recognitionSite: "GTSAC", cutPosition5Prime: 0, cutPosition3Prime: 5, overhangType: .sticky5Prime),
            
            // TseI/ApeKI  G^CWGC  — 5 bp, 5' overhang, overhang CWG (degenerate)
            RestrictionEnzyme(name: "TseI/ApeKI", recognitionSite: "GCWGC", cutPosition5Prime: 1, cutPosition3Prime: 4, overhangType: .sticky5Prime),
            
            // XcmI  CCANNNNNNNNN^TGG  — 15 bp, 3' overhang, overhang NNNNNNNNN (degenerate)
            RestrictionEnzyme(name: "XcmI", recognitionSite: "CCANNNNNNNNNTGG", cutPosition5Prime: 12, cutPosition3Prime: 3, overhangType: .sticky3Prime),
            
            // XmnI  GAANN^NNTTC  — 10 bp, blunt
            RestrictionEnzyme(name: "XmnI", recognitionSite: "GAANNNNTTC", cutPosition5Prime: 5, cutPosition3Prime: 5, overhangType: .blunt),
            
            // AhdI  GACNNN^NNGTC  — 11 bp, 3' overhang, overhang N (degenerate)
            RestrictionEnzyme(name: "AhdI", recognitionSite: "GACNNNNNGTC", cutPosition5Prime: 6, cutPosition3Prime: 5, overhangType: .sticky3Prime),
            
            // BsaBI  GATNN^NNATC  — 10 bp, blunt
            RestrictionEnzyme(name: "BsaBI", recognitionSite: "GATNNNNATC", cutPosition5Prime: 5, cutPosition3Prime: 5, overhangType: .blunt, methylationSensitivity: "dam blocked"),
            
        ]
    }
    
    func search(name: String) -> [RestrictionEnzyme] {
        let lowercaseName = name.lowercased()
        return enzymes.filter { $0.name.lowercased().contains(lowercaseName) }
    }
}

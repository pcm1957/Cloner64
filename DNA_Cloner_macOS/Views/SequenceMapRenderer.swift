//
//  SequenceMapRenderer.swift
//  Cloner 64
//
//  Core engine that generates the text-based restriction/sequence map.
//  Uses the app's existing types: DNASequence, Feature, CutSite, RestrictionEnzyme, GeneticCode
//

import AppKit
import Combine
import Foundation

// MARK: - Translation Strand

enum TranslationStrand: String, CaseIterable {
    case forward  = "Forward"
    case reverse  = "Reverse"
    case both     = "Both"
}

// MARK: - Settings

class SequenceMapSettings: ObservableObject {
    
    // Translation
    @Published var translateAll: Bool = true
    @Published var translationFrom: Int = 0
    @Published var translationTo: Int = 0
    @Published var showFrame1: Bool = true
    @Published var showFrame2: Bool = true
    @Published var showFrame3: Bool = true
    @Published var uppercaseOnly: Bool = false       // #6: only translate uppercase bases
    @Published var showCodons: Bool = false           // #11: codon triplet grouping
    @Published var translationStrand: TranslationStrand = .forward  // #13
    @Published var translationLabel: String = ""      // Caption for a filled-from ORF/feature, shown in the map header. Empty = no caption.
    @Published var translationLabelSpan: [Int] = []   // [from, to] the caption describes; used to clear the caption if From/To is hand-edited.
    
    // Restriction sites
    @Published var doNotShowRESites: Bool = false
    @Published var showAllSites: Bool = false
    @Published var maximumCut: Int = 1
    @Published var useParticularSites: Bool = false   // #9
    @Published var particularSites: Set<String> = []  // #9
    @Published var useMyEnzymesOnly: Bool = false      // My Enzymes filter
    
    // Display
    @Published var showReverseStrand: Bool = true
    @Published var showCoordinates: Bool = true
    @Published var showFeatures: Bool = true
    @Published var characterSize: CGFloat = 11        // screen display size
    @Published var printCharacterSize: CGFloat = 8    // #4: separate print size
    @Published var nucleotidesPerLine: Int = 100
    
    // Search
    @Published var searchQuery: String = ""
    
    var displayFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: characterSize, weight: .regular)
    }
    
    var printFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: printCharacterSize, weight: .regular)
    }
    
    var selectedFrameCount: Int {
        [showFrame1, showFrame2, showFrame3].filter { $0 }.count
    }
    
    /// Active frame offset (0-based) when exactly one frame is selected
    var singleFrameOffset: Int? {
        guard selectedFrameCount == 1 else { return nil }
        if showFrame1 { return 0 }
        if showFrame2 { return 1 }
        return 2
    }
    
    /// Whether codon grouping mode is active
    var codonModeActive: Bool {
        showCodons && selectedFrameCount == 1
    }
}


// MARK: - Deduplicated Enzyme Site

private struct UniqueEnzymeSite {
    let enzymeName: String
    let recognitionStart: Int   // 0-based position of first base of recognition site
    let strand: Strand
    var totalSites: Int         // how many distinct sites this enzyme has
    var isUnique: Bool { totalSites == 1 }  // #12
    var isHighlighted: Bool = false  // #9b: particular site highlight overlay
}


// MARK: - Renderer

class SequenceMapRenderer {
    
    // Colours
    static let sequenceColor     = NSColor.labelColor
    static let enzymeColor       = NSColor.labelColor
    static let rulerColor        = NSColor.secondaryLabelColor
    static let headerColor       = NSColor.secondaryLabelColor
    static let translationColor  = NSColor(red: 0.35, green: 0.35, blue: 0.35, alpha: 1.0)
    
    // MARK: - Public
    
    func render(
        sequence: DNASequence,
        settings: SequenceMapSettings,
        cutSites: [CutSite],
        forPrint: Bool = false,
        nPerLineOverride: Int? = nil
    ) -> NSAttributedString {
        
        let result = NSMutableAttributedString()
        let font = forPrint ? settings.printFont : settings.displayFont
        let seqUpper = Array(sequence.sequence.uppercased())
        let seqOriginal = Array(sequence.sequence)       // #6: preserve case
        let seqLength = seqUpper.count
        let nPerLine = nPerLineOverride ?? settings.nucleotidesPerLine
        
        guard seqLength > 0 else {
            result.append(NSAttributedString(string: "No sequence data to display.\n",
                                             attributes: [.font: font, .foregroundColor: Self.headerColor]))
            return result
        }
        
        result.append(buildHeader(sequence: sequence, settings: settings, font: font))
        
        let uniqueSites = deduplicateAndFilter(cutSites, settings: settings)
        let antisenseChars = seqOriginal.map { complementBase($0) }
        let colourMap = buildColourMap(features: sequence.features, seqLength: seqLength,
                                       showFeatures: settings.showFeatures)    // #5
        let codonTable = GeneticCode.standard.codonTable
        
        // Pre-compute reverse translation if needed (#13)
        let revComp = String(seqUpper.reversed().map { complementBase($0) })
        
        var lineStart = 0
        while lineStart < seqLength {
            let lineEnd = min(lineStart + nPerLine, seqLength)
            let lineLength = lineEnd - lineStart
            
            let block = renderLineBlock(
                seqUpper: seqUpper,
                seqOriginal: seqOriginal,
                antisenseChars: antisenseChars,
                revComp: Array(revComp),
                colourMap: colourMap,
                lineStart: lineStart,
                lineLength: lineLength,
                seqLength: seqLength,
                settings: settings,
                enzymeSites: uniqueSites,
                features: sequence.features,
                codonTable: codonTable,
                font: font
            )
            result.append(block)
            lineStart = lineEnd
        }
        
        return result
    }
    
    // MARK: - Find All Cut Sites
    
    static func findAllCutSites(in sequence: DNASequence, useMyEnzymesOnly: Bool = false) -> [CutSite] {
        let db = RestrictionEnzymeDatabase.shared
        let enzymeList = useMyEnzymesOnly ? db.myEnzymes : db.enzymes
        var allSites: [CutSite] = []
        for enzyme in enzymeList {
            allSites.append(contentsOf: enzyme.findCutSites(in: sequence.sequence, circular: sequence.isCircular))
        }
        return allSites
    }
    
    // MARK: - Deduplication & Filtering
    
    private func deduplicateAndFilter(_ sites: [CutSite], settings: SequenceMapSettings) -> [UniqueEnzymeSite] {
        
        var siteMap: [String: UniqueEnzymeSite] = [:]
        for site in sites {
            let key = "\(site.enzyme.name)@\(site.position)"
            if siteMap[key] == nil {
                siteMap[key] = UniqueEnzymeSite(
                    enzymeName: site.enzyme.name,
                    recognitionStart: site.position,
                    strand: site.strand,
                    totalSites: 0
                )
            }
        }
        
        var countByEnzyme: [String: Int] = [:]
        for (_, site) in siteMap { countByEnzyme[site.enzymeName, default: 0] += 1 }
        
        let all = siteMap.values.map { s -> UniqueEnzymeSite in
            var s = s; s.totalSites = countByEnzyme[s.enzymeName] ?? 0; return s
        }
        
        // #9b: Particular sites are a highlight overlay, not an exclusive filter.
        //  1. Apply cut-count filter as the base set of visible sites.
        //  2. If particular sites are active, mark matching enzymes as highlighted
        //     and add any particular sites that weren't already in the base set.
        //  "Do not show RE sites" suppresses the base set but particular sites
        //  still show through as highlighted.
        //  To see ONLY particular sites: tick "Do not show RE sites" or set max cut = 0.
        
        // Step 1: base set from cut-count filter (empty if doNotShowRESites)
        var base: [UniqueEnzymeSite]
        if settings.doNotShowRESites {
            base = []
        } else if settings.showAllSites {
            base = all
        } else {
            base = all.filter { $0.totalSites <= settings.maximumCut }
        }
        
        // Step 2: overlay particular site highlights
        if settings.useParticularSites && !settings.particularSites.isEmpty {
            // Mark existing base sites as highlighted if they're in the particular set
            base = base.map { s in
                var s = s
                if settings.particularSites.contains(s.enzymeName) { s.isHighlighted = true }
                return s
            }
            // Add any particular sites that weren't already in the base set
            let baseKeys = Set(base.map { "\($0.enzymeName)@\($0.recognitionStart)" })
            let extras = all.filter {
                settings.particularSites.contains($0.enzymeName)
                && !baseKeys.contains("\($0.enzymeName)@\($0.recognitionStart)")
            }.map { s -> UniqueEnzymeSite in
                var s = s; s.isHighlighted = true; return s
            }
            base.append(contentsOf: extras)
        }
        
        return base.sorted { $0.recognitionStart < $1.recognitionStart }
    }
    
    // MARK: - Colour Map  (#5: respect showFeatures toggle)
    
    private func buildColourMap(features: [Feature], seqLength: Int, showFeatures: Bool) -> [NSColor] {
        var map = Array(repeating: Self.sequenceColor, count: seqLength)
        guard showFeatures else { return map }  // #5: all black when features off
        
        for feature in features {
            let nsColor = NSColor(red: CGFloat(feature.color.red), green: CGFloat(feature.color.green),
                                  blue: CGFloat(feature.color.blue), alpha: CGFloat(feature.color.alpha))
            let fS = feature.start, fE = feature.end
            if fS <= fE {
                for i in fS..<min(fE, seqLength) where i >= 0 { map[i] = nsColor }
            } else {
                for i in fS..<seqLength { map[i] = nsColor }
                for i in 0..<min(fE, seqLength) { map[i] = nsColor }
            }
        }
        return map
    }
    
    // MARK: - Header
    
    private func buildHeader(sequence: DNASequence, settings: SequenceMapSettings, font: NSFont) -> NSAttributedString {
        let r = NSMutableAttributedString()
        let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Self.headerColor]
        let df = DateFormatter(); df.dateFormat = "d MMM yyyy    HH:mm"
        r.append(NSAttributedString(string: "<Cloner 64> -- <\(df.string(from: Date()))>\n", attributes: a))
        r.append(NSAttributedString(string: "Restriction map of \(sequence.name)\n", attributes: a))
        if !settings.doNotShowRESites {
            let t = settings.showAllSites
                ? "Showing all restriction enzyme sites"
                : "Showing restriction enzymes cutting maximum \(settings.maximumCut) time\(settings.maximumCut == 1 ? "" : "s")"
            r.append(NSAttributedString(string: "\(t) [using built-in Restriction Enzyme Library]\n", attributes: a))
        }
        // #9b: note highlighted particular sites
        if settings.useParticularSites && !settings.particularSites.isEmpty {
            let names = settings.particularSites.sorted().joined(separator: ", ")
            let highlightAttr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.systemRed]
            r.append(NSAttributedString(string: "Highlighted sites: ", attributes: a))
            r.append(NSAttributedString(string: "\(names)\n", attributes: highlightAttr))
        }
        // Translation caption — only when a region was filled from an ORF/feature
        if !settings.translateAll && !settings.translationLabel.isEmpty {
            let captionAttr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Self.translationColor]
            r.append(NSAttributedString(string: "Translating: ", attributes: a))
            r.append(NSAttributedString(string: "\(settings.translationLabel)\n", attributes: captionAttr))
        }
        r.append(NSAttributedString(string: "###\n\n", attributes: a))
        return r
    }
    
    // MARK: - Column Map  (#11: codon triplet spacing)
    
    /// Maps nucleotide index (0..<lineLength) to display column.
    /// In codon mode, inserts a space column at each codon boundary.
    /// When translating the reverse strand, codon boundaries are grouped from the
    /// right (3' end) of the sequence rather than the left.
    private func buildColumnMap(lineStart: Int, lineLength: Int, seqLength: Int, settings: SequenceMapSettings) -> (map: [Int], totalWidth: Int) {
        guard settings.codonModeActive, let frameOffset = settings.singleFrameOffset else {
            return (Array(0..<lineLength), lineLength)
        }
        
        let useReverseBoundaries = settings.translationStrand == .reverse
        
        var map = [Int]()
        var col = 0
        for i in 0..<lineLength {
            if i > 0 {
                if useReverseBoundaries {
                    // Reverse strand: codon boundaries group from the right end.
                    // Position i-1 on display has rcPos = seqLength - 1 - (lineStart + i - 1).
                    // A reverse codon STARTS at that rcPos when (rcPos - frameOffset) % 3 == 0,
                    // meaning the next display position (i) belongs to a different codon.
                    let rcPosPrev = seqLength - 1 - (lineStart + i - 1)
                    let posInFrame = rcPosPrev - frameOffset
                    if posInFrame >= 0 && posInFrame % 3 == 0 {
                        col += 1  // space column
                    }
                } else {
                    // Forward strand: codon boundaries group from the left end.
                    let globalPos = lineStart + i
                    let posInFrame = globalPos - frameOffset
                    if posInFrame >= 0 && posInFrame % 3 == 0 {
                        col += 1  // space column
                    }
                }
            }
            map.append(col)
            col += 1
        }
        return (map, col)
    }
    
    // MARK: - Line Block
    
    private func renderLineBlock(
        seqUpper: [Character],
        seqOriginal: [Character],
        antisenseChars: [Character],
        revComp: [Character],
        colourMap: [NSColor],
        lineStart: Int,
        lineLength: Int,
        seqLength: Int,
        settings: SequenceMapSettings,
        enzymeSites: [UniqueEnzymeSite],
        features: [Feature],
        codonTable: [String: Character],
        font: NSFont
    ) -> NSAttributedString {
        
        let result = NSMutableAttributedString()
        let lineEnd = lineStart + lineLength
        let (colMap, totalWidth) = buildColumnMap(lineStart: lineStart, lineLength: lineLength, seqLength: seqLength, settings: settings)
        
        // --- 1. Feature Labels (above enzymes so enzyme pipes stay close to sequence) ---
        if settings.showFeatures {
            let featuresHere = features.filter { $0.start >= lineStart && $0.start < lineEnd }
            if !featuresHere.isEmpty {
                result.append(layoutFeatureLabels(features: featuresHere, lineStart: lineStart,
                                                  colMap: colMap, totalWidth: totalWidth, font: font))
            }
        }
        
        // --- 2. Enzyme Labels with vertical line (#7, #12) — directly above sequence ---
        let enzymesInRange = enzymeSites.filter { $0.recognitionStart >= lineStart && $0.recognitionStart < lineEnd }
        if !enzymesInRange.isEmpty {
            result.append(layoutEnzymeLabels(sites: enzymesInRange, lineStart: lineStart,
                                             lineLength: lineLength, colMap: colMap,
                                             totalWidth: totalWidth, font: font))
        }
        
        // --- 3. Sense Strand (colour-coded, original case) ---
        result.append(renderColouredStrand(chars: seqOriginal, colourMap: colourMap, lineStart: lineStart,
                                           lineLength: lineLength, colMap: colMap, totalWidth: totalWidth, font: font))
        if settings.showCoordinates {
            result.append(NSAttributedString(string: "   < \(lineEnd)",
                                             attributes: [.font: font, .foregroundColor: Self.rulerColor]))
        }
        result.append(nl(font))
        
        // --- 4. Forward Translation (#6, #13) ---
        let transRange = translationRange(settings: settings, seqLength: seqLength)
        if settings.translationStrand == .forward || settings.translationStrand == .both {
            for frameOff in 0...2 {
                guard frameEnabled(frameOff, settings: settings) else { continue }
                result.append(renderForwardTranslation(
                    frameOffset: frameOff, seqUpper: seqUpper, seqOriginal: seqOriginal,
                    lineStart: lineStart, lineLength: lineLength, transRange: transRange,
                    codonTable: codonTable, uppercaseOnly: settings.uppercaseOnly,
                    colMap: colMap, totalWidth: totalWidth, font: font))
            }
        }
        
        // --- 5. Antisense Strand ---
        if settings.showReverseStrand {
            result.append(renderColouredStrand(chars: antisenseChars, colourMap: colourMap, lineStart: lineStart,
                                               lineLength: lineLength, colMap: colMap, totalWidth: totalWidth, font: font))
            result.append(nl(font))
        }
        
        // --- 6. Reverse Translation (#13) ---
        if settings.translationStrand == .reverse || settings.translationStrand == .both {
            for frameOff in 0...2 {
                guard frameEnabled(frameOff, settings: settings) else { continue }
                result.append(renderReverseTranslation(
                    frameOffset: frameOff, revComp: revComp, seqOriginal: seqOriginal,
                    seqLength: seqLength, lineStart: lineStart, lineLength: lineLength,
                    transRange: transRange, codonTable: codonTable, uppercaseOnly: settings.uppercaseOnly,
                    colMap: colMap, totalWidth: totalWidth, font: font))
            }
        }
        
        // --- 7. Position Ruler ---
        if settings.showCoordinates {
            result.append(renderRuler(lineStart: lineStart, lineLength: lineLength,
                                      colMap: colMap, totalWidth: totalWidth, font: font))
        }
        
        result.append(nl(font))
        return result
    }
    
    private func frameEnabled(_ offset: Int, settings: SequenceMapSettings) -> Bool {
        switch offset {
        case 0: return settings.showFrame1
        case 1: return settings.showFrame2
        case 2: return settings.showFrame3
        default: return false
        }
    }
    
    // MARK: - Colour-Coded Strand
    
    private func renderColouredStrand(
        chars: [Character], colourMap: [NSColor],
        lineStart: Int, lineLength: Int,
        colMap: [Int], totalWidth: Int, font: NSFont
    ) -> NSAttributedString {
        
        let result = NSMutableAttributedString()
        
        if totalWidth == lineLength {
            // No codon spacing — render in colour runs for efficiency
            var runStart = lineStart
            let lineEnd = lineStart + lineLength
            while runStart < lineEnd {
                let runColour = colourMap[runStart]
                var runEnd = runStart + 1
                while runEnd < lineEnd && colourMap[runEnd] == runColour { runEnd += 1 }
                result.append(NSAttributedString(string: String(chars[runStart..<runEnd]),
                                                 attributes: [.font: font, .foregroundColor: runColour]))
                runStart = runEnd
            }
        } else {
            // Codon spacing mode — build expanded line
            var display = Array(repeating: (Character(" "), Self.sequenceColor), count: totalWidth)
            for i in 0..<lineLength {
                display[colMap[i]] = (chars[lineStart + i], colourMap[lineStart + i])
            }
            // Render in colour runs
            var runStart = 0
            while runStart < totalWidth {
                let runColour = display[runStart].1
                var runEnd = runStart + 1
                while runEnd < totalWidth && display[runEnd].1 == runColour { runEnd += 1 }
                let text = String(display[runStart..<runEnd].map { $0.0 })
                result.append(NSAttributedString(string: text,
                                                 attributes: [.font: font, .foregroundColor: runColour]))
                runStart = runEnd
            }
        }
        
        return result
    }
    
    // MARK: - Forward Translation (#6 uppercase-only)
    
    private func renderForwardTranslation(
        frameOffset: Int,
        seqUpper: [Character], seqOriginal: [Character],
        lineStart: Int, lineLength: Int,
        transRange: ClosedRange<Int>?,
        codonTable: [String: Character],
        uppercaseOnly: Bool,
        colMap: [Int], totalWidth: Int, font: NSFont
    ) -> NSAttributedString {
        
        guard let range = transRange else { return NSAttributedString(string: "\n", attributes: [.font: font]) }
        
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Self.translationColor]
        var display = Array(repeating: Character(" "), count: totalWidth)
        let lineEnd = lineStart + lineLength
        
        var cs = frameOffset
        while cs + 3 <= lineStart { cs += 3 }
        
        while cs + 2 < seqUpper.count && cs < lineEnd {
            guard range.contains(cs) else { cs += 3; continue }
            
            // #6: uppercase-only — skip codons with any lowercase base
            if uppercaseOnly {
                let allUpper = (cs...cs+2).allSatisfy { seqOriginal[$0].isUppercase }
                if !allUpper { cs += 3; continue }
            }
            
            let codon = String([seqUpper[cs], seqUpper[cs+1], seqUpper[cs+2]])
            let aa = codonTable[codon] ?? Character("?")
            let midIdx = cs + 1 - lineStart
            if midIdx >= 0 && midIdx < lineLength {
                display[colMap[midIdx]] = aa
            }
            cs += 3
        }
        
        return NSAttributedString(string: String(display) + "\n", attributes: attrs)
    }
    
    // MARK: - Reverse Translation (#13)
    
    private func renderReverseTranslation(
        frameOffset: Int,
        revComp: [Character], seqOriginal: [Character],
        seqLength: Int,
        lineStart: Int, lineLength: Int,
        transRange: ClosedRange<Int>?,
        codonTable: [String: Character],
        uppercaseOnly: Bool,
        colMap: [Int], totalWidth: Int, font: NSFont
    ) -> NSAttributedString {
        
        guard let range = transRange else { return NSAttributedString(string: "\n", attributes: [.font: font]) }
        
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Self.translationColor]
        var display = Array(repeating: Character(" "), count: totalWidth)
        let lineEnd = lineStart + lineLength
        
        // Reverse complement position i corresponds to original position (seqLength - 1 - i)
        // Codons in revComp at positions: frameOffset, frameOffset+3, frameOffset+6, ...
        // The middle base of revComp codon starting at rc_pos is rc_pos + 1
        // This maps to original position: seqLength - 1 - (rc_pos + 1) = seqLength - 2 - rc_pos
        
        var rcPos = frameOffset
        while rcPos + 2 < seqLength {
            let origMiddle = seqLength - 2 - rcPos   // display position of middle base
            
            // Clip to the translation range. A reverse codon's first base (5' on the
            // bottom strand) sits at the HIGHEST top-strand coordinate it covers:
            // origStart = seqLength - 1 - rcPos. Mirror the forward function, which
            // includes a codon when its start base is inside the range.
            let origStart = seqLength - 1 - rcPos
            guard range.contains(origStart) else { rcPos += 3; continue }
            
            if origMiddle >= lineStart && origMiddle < lineEnd {
                // #6: check uppercase
                if uppercaseOnly {
                    let o0 = seqLength - 1 - rcPos
                    let o1 = seqLength - 1 - (rcPos + 1)
                    let o2 = seqLength - 1 - (rcPos + 2)
                    let allUpper = [o0, o1, o2].allSatisfy { $0 >= 0 && $0 < seqLength && seqOriginal[$0].isUppercase }
                    if !allUpper { rcPos += 3; continue }
                }
                
                let codon = String([revComp[rcPos], revComp[rcPos+1], revComp[rcPos+2]])
                let aa = codonTable[codon] ?? Character("?")
                let localIdx = origMiddle - lineStart
                if localIdx >= 0 && localIdx < lineLength {
                    display[colMap[localIdx]] = aa
                }
            }
            rcPos += 3
        }
        
        return NSAttributedString(string: String(display) + "\n", attributes: attrs)
    }
    
    // MARK: - Enzyme Labels (#7: vertical line, #12: bold unique)
    
    private func layoutEnzymeLabels(
        sites: [UniqueEnzymeSite],
        lineStart: Int, lineLength: Int,
        colMap: [Int], totalWidth: Int, font: NSFont
    ) -> NSAttributedString {
        
        let result = NSMutableAttributedString()
        let boldFont = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .bold)
        let maxCol = totalWidth + 30
        
        struct Placement {
            let text: String
            let startCol: Int
            let isBold: Bool
            let isHighlighted: Bool  // #9b: particular site overlay
            var endCol: Int { startCol + text.count }
        }
        
        // Build name placements — centre name above the pipe
        var placements: [Placement] = []
        for site in sites {
            let localIdx = site.recognitionStart - lineStart
            guard localIdx >= 0 && localIdx < lineLength else { continue }
            let pipeCol = colMap[localIdx]
            let name = site.enzymeName
            let startCol = max(0, pipeCol - name.count / 2)
            placements.append(Placement(text: name, startCol: startCol, isBold: site.isUnique,
                                        isHighlighted: site.isHighlighted))
        }
        
        // Stack name rows avoiding overlaps
        var rows: [[Placement]] = [[]]
        for p in placements {
            var placed = false
            for ri in 0..<rows.count {
                let fits = rows[ri].allSatisfy { $0.endCol + 1 <= p.startCol || p.endCol + 1 <= $0.startCol }
                if fits { rows[ri].append(p); placed = true; break }
            }
            if !placed { rows.append([p]) }
        }
        
        // Render name rows (topmost first)
        for row in rows.reversed() {
            var line = Array(repeating: Character(" "), count: maxCol)
            // We need per-placement bold, so build attributed string segment by segment
            for p in row.sorted(by: { $0.startCol < $1.startCol }) {
                for (i, ch) in p.text.enumerated() {
                    let c = p.startCol + i
                    if c >= 0 && c < maxCol { line[c] = ch }
                }
            }
            // Now build attributed string with bold ranges
            let lineStr = String(line).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            let base = NSMutableAttributedString(string: lineStr + "\n",
                                                  attributes: [.font: font, .foregroundColor: Self.enzymeColor])
            // Apply bold to bold placements
            for p in row where p.isBold {
                let nsRange = NSRange(location: p.startCol, length: min(p.text.count, lineStr.count - p.startCol))
                if nsRange.location + nsRange.length <= base.length - 1 {  // -1 for newline
                    base.addAttribute(.font, value: boldFont, range: nsRange)
                }
            }
            // #9b: Apply red colour to highlighted (particular) sites
            for p in row where p.isHighlighted {
                let nsRange = NSRange(location: p.startCol, length: min(p.text.count, lineStr.count - p.startCol))
                if nsRange.location + nsRange.length <= base.length - 1 {
                    base.addAttribute(.foregroundColor, value: NSColor.systemRed, range: nsRange)
                    base.addAttribute(.font, value: boldFont, range: nsRange)
                }
            }
            result.append(base)
        }
        
        // Render pipe row  (#7, #9b: red pipes for highlighted sites)
        var pipeLine = Array(repeating: Character(" "), count: maxCol)
        for site in sites {
            let localIdx = site.recognitionStart - lineStart
            if localIdx >= 0 && localIdx < lineLength {
                pipeLine[colMap[localIdx]] = "|"
            }
        }
        let pipeStr = String(pipeLine).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        let pipeAttr = NSMutableAttributedString(string: pipeStr + "\n",
                                                  attributes: [.font: font, .foregroundColor: Self.enzymeColor])
        // Colour highlighted pipes red
        for site in sites where site.isHighlighted {
            let localIdx = site.recognitionStart - lineStart
            if localIdx >= 0 && localIdx < lineLength {
                let col = colMap[localIdx]
                if col < pipeStr.count {
                    pipeAttr.addAttribute(.foregroundColor, value: NSColor.systemRed, range: NSRange(location: col, length: 1))
                }
            }
        }
        result.append(pipeAttr)
        
        return result
    }
    
    // MARK: - Feature Labels (#8: no > symbol, feature colour, row-packed)
    
    private func layoutFeatureLabels(
        features: [Feature],
        lineStart: Int,
        colMap: [Int], totalWidth: Int, font: NSFont
    ) -> NSAttributedString {
        
        let result = NSMutableAttributedString()
        let maxCol = totalWidth + 40
        
        struct FeaturePlacement {
            let name: String
            let startCol: Int
            let color: NSColor
            var endCol: Int { startCol + name.count }
        }
        
        // Build placements
        var placements: [FeaturePlacement] = []
        for feature in features {
            let localIdx = feature.start - lineStart
            guard localIdx >= 0 && localIdx < colMap.count else { continue }
            let col = colMap[localIdx]
            let nsColor = NSColor(red: CGFloat(feature.color.red), green: CGFloat(feature.color.green),
                                  blue: CGFloat(feature.color.blue), alpha: CGFloat(feature.color.alpha))
            placements.append(FeaturePlacement(name: feature.name, startCol: col, color: nsColor))
        }
        
        // Pack into rows with horizontal collision avoidance (1 char gap)
        var rows: [[FeaturePlacement]] = [[]]
        for p in placements {
            var placed = false
            for ri in 0..<rows.count {
                let fits = rows[ri].allSatisfy { $0.endCol + 1 <= p.startCol || p.endCol + 1 <= $0.startCol }
                if fits { rows[ri].append(p); placed = true; break }
            }
            if !placed { rows.append([p]) }
        }
        
        // Render rows (topmost first, so closest row to sequence is last)
        for row in rows.reversed() {
            let sorted = row.sorted { $0.startCol < $1.startCol }
            let line = NSMutableAttributedString()
            var cursor = 0
            let spaceAttrs: [NSAttributedString.Key: Any] = [.font: font]
            
            for p in sorted {
                let start = min(p.startCol, maxCol)
                if start > cursor {
                    line.append(NSAttributedString(string: String(repeating: " ", count: start - cursor),
                                                    attributes: spaceAttrs))
                    cursor = start
                }
                let labelLen = min(p.name.count, maxCol - cursor)
                guard labelLen > 0 else { continue }
                let label = String(p.name.prefix(labelLen))
                line.append(NSAttributedString(string: label,
                                                attributes: [.font: font, .foregroundColor: p.color]))
                cursor += labelLen
            }
            
            // Trim trailing spaces and append newline
            let trimmed = line.string.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            let trimmedAttr = NSMutableAttributedString(attributedString: line)
            if trimmedAttr.length > trimmed.count {
                trimmedAttr.deleteCharacters(in: NSRange(location: trimmed.count, length: trimmedAttr.length - trimmed.count))
            }
            trimmedAttr.append(NSAttributedString(string: "\n", attributes: spaceAttrs))
            result.append(trimmedAttr)
        }
        return result
    }
    
    // MARK: - Position Ruler
    
    private func renderRuler(lineStart: Int, lineLength: Int, colMap: [Int], totalWidth: Int, font: NSFont) -> NSAttributedString {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Self.rulerColor]
        var line = Array(repeating: Character(" "), count: totalWidth)
        
        let firstTick = ((lineStart / 10) + 1) * 10
        for pos in stride(from: firstTick, through: lineStart + lineLength, by: 10) {
            let localIdx = pos - 1 - lineStart
            guard localIdx >= 0 && localIdx < lineLength else { continue }
            let col = colMap[localIdx]
            let label = String(pos)
            let labelStart = col - label.count / 2
            for (i, ch) in label.enumerated() {
                let idx = labelStart + i
                if idx >= 0 && idx < totalWidth { line[idx] = ch }
            }
        }
        return NSAttributedString(string: String(line) + "\n", attributes: attrs)
    }
    
    // MARK: - Utilities
    
    private func translationRange(settings: SequenceMapSettings, seqLength: Int) -> ClosedRange<Int>? {
        guard seqLength > 0 else { return nil }
        if settings.translateAll { return 0...(seqLength - 1) }
        let from = max(0, settings.translationFrom - 1)
        let to = min(seqLength - 1, settings.translationTo - 1)
        guard from <= to else { return nil }
        return from...to
    }
    
    private func complementBase(_ b: Character) -> Character {
        switch b {
        case "A": return "T"; case "a": return "t"
        case "T": return "A"; case "t": return "a"
        case "G": return "C"; case "g": return "c"
        case "C": return "G"; case "c": return "g"
        default: return "N"
        }
    }
    
    private func nl(_ font: NSFont) -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: [.font: font])
    }
    
    func renderPlainText(sequence: DNASequence, settings: SequenceMapSettings, cutSites: [CutSite]) -> String {
        render(sequence: sequence, settings: settings, cutSites: cutSites).string
    }
}

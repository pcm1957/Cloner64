//
//  SequenceMapView.swift
//  Cloner 64
//
//  Sequence Map window — text-based restriction map with enzyme cut sites,
//  reading frame translations, and feature annotations.
//
//  INTEGRATION: Replaces the placeholder SequenceMapWindowManager at the
//  bottom of SequenceEditorView.swift.
//

import SwiftUI
import AppKit

// MARK: - NSTextView Wrapper  (#10: drag-select and copy works natively)

struct SequenceMapTextView: NSViewRepresentable {
    let attributedString: NSAttributedString
    let font: NSFont
    let searchQuery: String
    
    /// Compute reverse complement of a DNA string
    static func reverseComplement(_ seq: String) -> String {
        let complementMap: [Character: Character] = [
            "A": "T", "T": "A", "G": "C", "C": "G",
            "a": "t", "t": "a", "g": "c", "c": "g",
            "R": "Y", "Y": "R", "S": "S", "W": "W",
            "K": "M", "M": "K", "B": "V", "V": "B",
            "D": "H", "H": "D", "N": "N",
            "r": "y", "y": "r", "s": "s", "w": "w",
            "k": "m", "m": "k", "b": "v", "v": "b",
            "d": "h", "h": "d", "n": "n"
        ]
        return String(seq.reversed().map { complementMap[$0] ?? $0 })
    }
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        
        textView.isEditable = false
        textView.isSelectable = true              // #10: drag to select + copy
        textView.usesFindBar = true               // Cmd+F works
        textView.isIncrementalSearchingEnabled = true
        textView.backgroundColor = .white
        textView.textContainerInset = NSSize(width: 12, height: 12)
        
        // Disable word wrap — monospaced alignment must be preserved
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                        height: CGFloat.greatestFiniteMagnitude)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                   height: CGFloat.greatestFiniteMagnitude)
        
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        
        return scrollView
    }
    
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        
        let storage = textView.textStorage!
        storage.beginEditing()
        storage.setAttributedString(attributedString)
        storage.endEditing()
        
        // Search highlighting
        guard !searchQuery.isEmpty else { return }
        let fullText = textView.string as NSString
        var searchRange = NSRange(location: 0, length: fullText.length)
        var firstMatch: NSRange?
        
        // 1) Plain text search (finds DNA sequences on the sense strand line)
        while searchRange.location < fullText.length {
            let found = fullText.range(of: searchQuery, options: .caseInsensitive, range: searchRange)
            guard found.location != NSNotFound else { break }
            storage.addAttribute(.backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.35), range: found)
            if firstMatch == nil { firstMatch = found }
            searchRange.location = found.location + found.length
            searchRange.length = fullText.length - searchRange.location
        }
        
        // 1b) Reverse complement DNA search — finds the query on the antisense strand
        //     (which is displayed 3'→5', so a reverse-strand sequence appears reversed)
        let isDNA = searchQuery.count >= 2 && searchQuery.uppercased().allSatisfy({ "ACGTRYSWKMBDHVN".contains($0) })
        if isDNA {
            let rcQuery = Self.reverseComplement(searchQuery)
            if rcQuery.uppercased() != searchQuery.uppercased() {  // skip palindromes — already found above
                var rcRange = NSRange(location: 0, length: fullText.length)
                while rcRange.location < fullText.length {
                    let found = fullText.range(of: rcQuery, options: .caseInsensitive, range: rcRange)
                    guard found.location != NSNotFound else { break }
                    storage.addAttribute(.backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.35), range: found)
                    if firstMatch == nil { firstMatch = found }
                    rcRange.location = found.location + found.length
                    rcRange.length = fullText.length - rcRange.location
                }
            }
        }
        
        // 2) Amino acid search — translation lines have amino acids spaced out
        //    (e.g. "M  A  S") so plain text search can't find "MAS".
        //    Walk the attributed string, collect non-space chars from translation-
        //    coloured runs on each line, and search the extracted amino acid string.
        let translationColor = NSColor.labelColor.withAlphaComponent(0.7)
        let query = searchQuery.uppercased()
        let text = textView.string
        let lines = text.components(separatedBy: "\n")
        var lineOffset = 0
        
        for line in lines {
            let lineLen = (line as NSString).length
            
            // Collect non-space characters that have the translation colour
            var aaChars: [(char: Character, pos: Int)] = []
            for i in 0..<lineLen {
                let ch = (line as NSString).character(at: i)
                guard ch != 0x20 && ch != 0x0A else { continue }  // skip spaces/newlines
                // Check foreground colour
                if let fg = storage.attribute(.foregroundColor, at: lineOffset + i, effectiveRange: nil) as? NSColor {
                    // Compare in sRGB to avoid colorspace mismatches
                    if let fgRGB = fg.usingColorSpace(.sRGB),
                       let tRGB = translationColor.usingColorSpace(.sRGB),
                       abs(fgRGB.redComponent - tRGB.redComponent) < 0.02 &&
                       abs(fgRGB.greenComponent - tRGB.greenComponent) < 0.02 &&
                       abs(fgRGB.blueComponent - tRGB.blueComponent) < 0.02 {
                        if let scalar = UnicodeScalar(ch) {
                            aaChars.append((char: Character(scalar), pos: lineOffset + i))
                        }
                    }
                }
            }
            
            // Search the extracted amino acid sequence for the query
            if aaChars.count >= query.count {
                let aaString = String(aaChars.map { $0.char }).uppercased()
                
                // Forward search (matches forward-strand translation)
                var searchStart = aaString.startIndex
                while let range = aaString.range(of: query, options: .caseInsensitive, range: searchStart..<aaString.endIndex) {
                    let startIdx = aaString.distance(from: aaString.startIndex, to: range.lowerBound)
                    let matchLen = aaString.distance(from: range.lowerBound, to: range.upperBound)
                    for j in startIdx..<(startIdx + matchLen) {
                        let charPos = aaChars[j].pos
                        let highlightRange = NSRange(location: charPos, length: 1)
                        storage.addAttribute(.backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.35), range: highlightRange)
                        if firstMatch == nil { firstMatch = highlightRange }
                    }
                    searchStart = range.upperBound
                }
                
                // Reverse search (matches reverse-strand translation, which reads right-to-left)
                let aaReversed = String(aaString.reversed())
                let aaCharsReversed = Array(aaChars.reversed())
                var revSearchStart = aaReversed.startIndex
                while let range = aaReversed.range(of: query, options: .caseInsensitive, range: revSearchStart..<aaReversed.endIndex) {
                    let startIdx = aaReversed.distance(from: aaReversed.startIndex, to: range.lowerBound)
                    let matchLen = aaReversed.distance(from: range.lowerBound, to: range.upperBound)
                    for j in startIdx..<(startIdx + matchLen) {
                        let charPos = aaCharsReversed[j].pos
                        let highlightRange = NSRange(location: charPos, length: 1)
                        storage.addAttribute(.backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.35), range: highlightRange)
                        if firstMatch == nil { firstMatch = highlightRange }
                    }
                    revSearchStart = range.upperBound
                }
            }
            
            lineOffset += lineLen + 1  // +1 for the newline
        }
        
        if let first = firstMatch {
            textView.scrollRangeToVisible(first)
            textView.showFindIndicator(for: first)
        }
    }
}


// MARK: - Main Sequence Map View

struct SequenceMapView: View {
    @ObservedObject var sequence: DNASequence
    let sequenceID: UUID    // for Home button
    
    @StateObject private var settings = SequenceMapSettings()
    @State private var searchText: String = ""
    @State private var cutSites: [CutSite] = []
    @State private var isComputing: Bool = false
    @State private var showFeatureList: Bool = false
    @State private var showParticularSitesSheet: Bool = false
    @State private var orfsForFill: [DNASequence.ORFResult] = []
    @State private var translationLabelIsNamed: Bool = false   // true = caption came from picker (ORF/feature); false = generated from manual range
    @Environment(\.openWindow) private var openWindow

    // Methylation sensitivity — AppStorage keys shared with GraphicalMapView and VirtualCutter
    @AppStorage("methylation_dam") private var methylationDam: Bool = true
    @AppStorage("methylation_dcm") private var methylationDcm: Bool = true
    @AppStorage("methylation_cpg") private var methylationCpG: Bool = false
    // Enzyme names that are blocked or required under the current methylation settings.
    // Rebuilt asynchronously after each site scan or toggle.
    @State private var methylationBlockedEnzymes:  Set<String> = []
    @State private var methylationRequiredEnzymes: Set<String> = []
    
    private let renderer = SequenceMapRenderer()
    private let enzymeDB = RestrictionEnzymeDatabase.shared
    
    private var renderedMap: NSAttributedString {
        let base = renderer.render(sequence: sequence, settings: settings, cutSites: cutSites)
        return applyMethylationColours(to: base)
    }

    /// Post-process a rendered map to colour-code enzyme labels by methylation status.
    /// Blocked enzymes: red text + strikethrough (same as GraphicalMapView).
    /// Required enzymes: blue text.
    /// When no methylation toggle is on, the base string is returned unchanged.
    private func applyMethylationColours(to base: NSAttributedString) -> NSAttributedString {
        guard methylationDam || methylationDcm || methylationCpG,
              !methylationBlockedEnzymes.isEmpty || !methylationRequiredEnzymes.isEmpty else {
            return base
        }
        let mutable = NSMutableAttributedString(attributedString: base)
        let text = base.string as NSString

        func recolor(_ name: String, color: NSColor, strikethrough: Bool) {
            var range = NSRange(location: 0, length: text.length)
            while range.location < text.length {
                let found = text.range(of: name, options: [], range: range)
                guard found.location != NSNotFound else { break }
                mutable.addAttribute(.foregroundColor, value: color, range: found)
                if strikethrough {
                    mutable.addAttribute(.strikethroughStyle,
                                         value: NSUnderlineStyle.single.rawValue, range: found)
                    mutable.addAttribute(.strikethroughColor, value: color, range: found)
                }
                range.location = found.location + found.length
                range.length   = text.length - range.location
            }
        }

        // Apply required first; blocked overwrites if both somehow apply to the same enzyme.
        for name in methylationRequiredEnzymes { recolor(name, color: .systemBlue, strikethrough: false) }
        for name in methylationBlockedEnzymes  { recolor(name, color: .systemRed,  strikethrough: true)  }
        return mutable
    }
    
    var body: some View {
        VStack(spacing: 0) {
            toolbarSection
            Divider()
            
            // #1: Collapsible feature list
            if showFeatureList {
                featureListSection
                Divider()
            }
            
            // Map content
            if isComputing {
                VStack(spacing: 12) { Spacer(); ProgressView("Analysing restriction sites..."); Spacer() }
            } else {
                SequenceMapTextView(
                    attributedString: renderedMap,
                    font: settings.displayFont,
                    searchQuery: searchText
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
            Divider()
            footerSection
        }
        .frame(minWidth: 850, minHeight: 500)
        .onAppear {
            settings.translationTo = sequence.length
            computeCutSites()
        }
        .onChange(of: methylationDam) { newValue in computeMethylation(damOverride: newValue) }
        .onChange(of: methylationDcm) { newValue in computeMethylation(dcmOverride: newValue) }
        .onChange(of: methylationCpG) { newValue in computeMethylation(cpgOverride: newValue) }
    }
    
    // MARK: - Compute
    
    private func computeCutSites() {
        isComputing = true
        let myOnly = settings.useMyEnzymesOnly
        DispatchQueue.global(qos: .userInitiated).async {
            let sites = SequenceMapRenderer.findAllCutSites(in: sequence, useMyEnzymesOnly: myOnly)
            DispatchQueue.main.async {
                cutSites = sites
                isComputing = false
                // One extra main-thread cycle so the cutSites @State write has committed
                // before computeMethylation reads it.
                DispatchQueue.main.async { self.computeMethylation() }
            }
        }
    }
    
    /// Compute per-site methylation blocked flags on a background thread.
    /// Pass overrides when calling from an onChange closure to avoid reading a
    /// stale @AppStorage value (same pattern as GraphicalMapView).
    private func computeMethylation(damOverride: Bool? = nil,
                                    dcmOverride: Bool? = nil,
                                    cpgOverride: Bool? = nil) {
        let seq      = sequence.sequence.uppercased()
        let circular = sequence.isCircular
        let dam      = damOverride ?? methylationDam
        let dcm      = dcmOverride ?? methylationDcm
        let cpg      = cpgOverride ?? methylationCpG
        let sites    = cutSites

        DispatchQueue.global(qos: .userInitiated).async {
            var blocked:  Set<String> = []
            var required: Set<String> = []
            for site in sites {
                let w = MethylationChecker.checkSite(
                    enzymeName:      site.enzyme.name,
                    sitePosition:    site.position,
                    recognitionSite: site.enzyme.recognitionSite,
                    sequence:        seq,
                    circular:        circular,
                    activeDam:       dam,
                    activeDcm:       dcm,
                    activeCpG:       cpg
                )
                if MethylationChecker.isCutBlocked(w) {
                    blocked.insert(site.enzyme.name)
                } else if w.contains(where: { $0.effect == .required }) {
                    required.insert(site.enzyme.name)
                }
            }
            DispatchQueue.main.async {
                self.methylationBlockedEnzymes  = blocked
                self.methylationRequiredEnzymes = required
            }
        }
    }

    // MARK: - Feature List  (#1)
    
    private var featureListSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Features").font(.caption).fontWeight(.semibold)
                Spacer()
                Text("\(sequence.features.count) features").font(.caption).foregroundColor(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            
            if sequence.features.isEmpty {
                Text("No features annotated.")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 10).padding(.bottom, 4)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        // Header row
                        HStack(spacing: 0) {
                            Text("Name").frame(width: 160, alignment: .leading)
                            Text("Start").frame(width: 70, alignment: .trailing)
                            Text("End").frame(width: 70, alignment: .trailing)
                            Text("Length").frame(width: 70, alignment: .trailing)
                            Text("AA").frame(width: 50, alignment: .trailing)
                            Text("Direction").frame(width: 90, alignment: .center)
                            Spacer()
                        }
                        .font(.caption2).fontWeight(.semibold).foregroundColor(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 2)
                        
                        Divider()
                        
                        ForEach(sequence.features) { feature in
                            let lengthBP = abs(feature.end - feature.start)
                            let isCoding = feature.type == .gene || feature.type == .cds
                            
                            HStack(spacing: 0) {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(feature.color.color)
                                        .frame(width: 8, height: 8)
                                    Text(feature.name)
                                        .lineLimit(1)
                                }
                                .frame(width: 160, alignment: .leading)
                                
                                Text("\(feature.start)").frame(width: 70, alignment: .trailing)
                                Text("\(feature.end)").frame(width: 70, alignment: .trailing)
                                Text("\(lengthBP) bp").frame(width: 70, alignment: .trailing)
                                Text(isCoding && lengthBP >= 3 ? "\(lengthBP / 3)" : "–")
                                    .foregroundColor(isCoding ? .primary : .secondary)
                                    .frame(width: 50, alignment: .trailing)
                                Text(feature.strand == .forward ? "Clockwise \u{2192}" : "Anticlockwise \u{2190}")
                                    .frame(width: 90, alignment: .center)
                                Spacer()
                            }
                            .font(.caption)
                            .padding(.horizontal, 10).padding(.vertical, 2)
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }
    
    // MARK: - Toolbar
    
    private var toolbarSection: some View {
        VStack(spacing: 4) {
            HStack(alignment: .top, spacing: 12) {
                featuresAndSearch
                Divider().frame(height: 80)
                translationSection
                Divider().frame(height: 80)
                restrictionSection
                Divider().frame(height: 80)
                displaySection
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    // MARK: - Features & Search  (#1, #2)
    
    private var featuresAndSearch: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Toggle("Show Features", isOn: $settings.showFeatures)
                    .toggleStyle(.checkbox).font(.system(size: 12))
                    .contextHelp("smap.showFeatures")
                
                Button(action: { withAnimation { showFeatureList.toggle() } }) {
                    Image(systemName: showFeatureList ? "list.bullet.circle.fill" : "list.bullet.circle")
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain).help("Toggle feature list")
                .contextHelp("smap.featureList")
            }
            
            // #2: Search for DNA or amino acid sequence
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .onTapGesture { settings.searchQuery = searchText }
                
                TextField("DNA or amino acid...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150).font(.system(size: 12))
                    .onSubmit { settings.searchQuery = searchText }
            }
            

        }
    }
    
    // MARK: - Translation  (#6, #11, #13)
    
    private var translationSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Translation").font(.system(size: 12, weight: .semibold))
            
            HStack(spacing: 6) {
                Toggle("All", isOn: $settings.translateAll)
                    .toggleStyle(.checkbox).font(.system(size: 12))
                    .contextHelp("smap.translateAll")
                if !settings.translateAll {
                    Text("From").font(.system(size: 12))
                    TextField("", value: $settings.translationFrom, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 50).font(.system(size: 12))
                    Text("To").font(.system(size: 12))
                    TextField("", value: $settings.translationTo, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 50).font(.system(size: 12))

                    fillFromMenu
                }
            }
            .onChange(of: settings.translationFrom) { _ in clearStaleTranslationLabel() }
            .onChange(of: settings.translationTo) { _ in clearStaleTranslationLabel() }
            .onChange(of: settings.translationStrand) { _ in refreshManualTranslationLabel() }
            .onChange(of: settings.showFrame1) { _ in refreshManualTranslationLabel() }
            .onChange(of: settings.showFrame2) { _ in refreshManualTranslationLabel() }
            .onChange(of: settings.showFrame3) { _ in refreshManualTranslationLabel() }
            .onChange(of: settings.translateAll) { isAll in
                if isAll {
                    translationLabelIsNamed = false
                    settings.translationLabel = ""
                    settings.translationLabelSpan = []
                } else {
                    // Entering range mode by hand — show a manual caption for the range.
                    refreshManualTranslationLabel()
                }
            }
            
            HStack(spacing: 6) {
                Toggle("Frame 1", isOn: $settings.showFrame1).toggleStyle(.checkbox).font(.system(size: 12))
                    .contextHelp("smap.frame1")
                Toggle("Frame 2", isOn: $settings.showFrame2).toggleStyle(.checkbox).font(.system(size: 12))
                    .contextHelp("smap.frame2")
                Toggle("Frame 3", isOn: $settings.showFrame3).toggleStyle(.checkbox).font(.system(size: 12))
                    .contextHelp("smap.frame3")
            }
            
            HStack(spacing: 8) {
                // #6
                Toggle("Uppercase only", isOn: $settings.uppercaseOnly)
                    .toggleStyle(.checkbox).font(.system(size: 12))
                    .help("Only translate uppercase bases (exons)")
                    .contextHelp("smap.uppercaseOnly")
                
                Spacer().frame(width: 4)
                
                // #11
                Toggle("Show codons", isOn: $settings.showCodons)
                    .toggleStyle(.checkbox).font(.system(size: 12))
                    .disabled(settings.selectedFrameCount != 1)
                    .help("Group bases in codon triplets (single frame only)")
                    .contextHelp("smap.showCodons")
            }
            
            // #13: Strand selector on its own row
            HStack(spacing: 6) {
                Text("Strand:").font(.system(size: 12)).foregroundColor(.secondary)
                Picker("", selection: $settings.translationStrand) {
                    ForEach(TranslationStrand.allCases, id: \.self) { strand in
                        Text(strand.rawValue).tag(strand)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .font(.system(size: 12))
                .help("Translate forward strand, reverse strand, or both")
                .contextHelp("smap.translationStrand")
            }
        }
    }

    // MARK: - Fill From Feature / ORF

    /// A "Fill from…" menu that drops a feature's or ORF's coordinates into the
    /// From/To fields, sets the strand, and selects the single reading frame that
    /// starts on the item's first base.
    private var fillFromMenu: some View {
        Menu {
            // Features submenu
            if sequence.features.isEmpty {
                Text("No features").foregroundColor(.secondary)
            } else {
                Menu("Features") {
                    ForEach(sequence.features) { feature in
                        let lo = min(feature.start, feature.end)
                        let hi = max(feature.start, feature.end)
                        Button("\(feature.name)  (\(lo)–\(hi))") {
                            fillTranslation(from: lo,
                                             to: hi,
                                             isForward: feature.strand == .forward,
                                             label: "\(feature.name) (\(lo)–\(hi)) \(feature.strand == .forward ? "forward" : "reverse")")
                        }
                    }
                }
            }

            // ORFs submenu — computed on demand
            Menu("ORFs") {
                let orfs = orfsForFill
                if orfs.isEmpty {
                    Text("No ORFs found").foregroundColor(.secondary)
                } else {
                    ForEach(orfs) { orf in
                        Button("\(orf.label)  \(orf.strand)  (\(orf.position)–\(orf.end))") {
                            fillTranslation(from: orf.position,
                                             to: orf.end,
                                             isForward: orf.isForward,
                                             label: "\(orf.label) \(orf.strand) (\(orf.position)–\(orf.end))")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "text.insert")
            Text("Fill from…").font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Fill From/To from a feature or ORF, set the strand and reading frame")
        .contextHelp("smap.fillFromFeatureORF")
        // Compute ORFs lazily the first time the menu is built, and refresh if
        // the sequence length changes.
        .onAppear { refreshORFsForFill() }
        .onChange(of: sequence.length) { _ in refreshORFsForFill() }
    }

    /// Scan the current sequence for ORFs so the menu can list them.
    private func refreshORFsForFill() {
        orfsForFill = sequence.findORFs()
    }

    /// Called when From/To is hand-edited. If the range no longer matches the span
    /// a named (picker) caption was made for, the named caption is stale — drop the
    /// "named" status and replace it with a generated manual caption describing the
    /// current range, strand and frame.
    private func clearStaleTranslationLabel() {
        if translationLabelIsNamed,
           settings.translationLabelSpan != [settings.translationFrom, settings.translationTo] {
            translationLabelIsNamed = false
        }
        refreshManualTranslationLabel()
    }

    /// Build the caption for a hand-typed range, e.g. "bases 235–456 forward, frame 2".
    /// Only applies when the caption is NOT a named picker caption. Does nothing in
    /// "translate all" mode. If multiple frames are selected, the frame is omitted
    /// (there's no single frame to name).
    private func refreshManualTranslationLabel() {
        guard !translationLabelIsNamed else { return }
        guard !settings.translateAll else {
            settings.translationLabel = ""
            settings.translationLabelSpan = []
            return
        }

        let lo = settings.translationFrom
        let hi = settings.translationTo
        guard lo > 0, hi > 0, hi >= lo else {
            settings.translationLabel = ""
            return
        }

        let strandWord: String
        switch settings.translationStrand {
        case .forward: strandWord = "forward"
        case .reverse: strandWord = "reverse"
        case .both:    strandWord = "both strands"
        }

        // Name the frame only when exactly one is selected.
        let selectedFrames = [settings.showFrame1, settings.showFrame2, settings.showFrame3]
        let frameCount = selectedFrames.filter { $0 }.count
        var caption = "bases \(lo)–\(hi) \(strandWord)"
        if frameCount == 1 {
            let frameNo = settings.showFrame1 ? 1 : (settings.showFrame2 ? 2 : 3)
            caption += ", frame \(frameNo)"
        }

        settings.translationLabel = caption
        settings.translationLabelSpan = [lo, hi]
    }

    /// Apply a coordinate span to the translation controls.
    ///
    /// - Sets From/To (1-based, inclusive) and turns off "All".
    /// - Sets the strand to match the item.
    /// - Selects the SINGLE reading frame whose first codon starts on the item's
    ///   first base. The renderer numbers forward frames from base 1 (left end)
    ///   and reverse frames from base N (right end), so the two strands use
    ///   different offset maths.
    private func fillTranslation(from lo: Int, to hi: Int, isForward: Bool, label: String) {
        let seqLen = sequence.length
        let clampedLo = max(1, min(lo, seqLen))
        let clampedHi = max(clampedLo, min(hi, seqLen))

        // Set the "named" flag FIRST: changing the settings below fires onChange
        // handlers (strand, frame, From/To). With this flag already true, those
        // handlers' manual-caption refresh no-ops and won't overwrite the named
        // caption set here.
        translationLabelIsNamed = true

        settings.translateAll = false
        settings.translationFrom = clampedLo
        settings.translationTo = clampedHi
        settings.translationStrand = isForward ? .forward : .reverse
        settings.translationLabel = label
        // Remember which span this caption describes, so a later hand-edit of
        // From/To can detect the drift and replace the now-stale caption.
        settings.translationLabelSpan = [clampedLo, clampedHi]

        // Determine the 0-based frame offset of the item's first codon.
        let offset: Int
        if isForward {
            // Distance from base 1 (left end) to the start base.
            offset = (clampedLo - 1) % 3
        } else {
            // On the reverse strand the renderer reads from the right end, so the
            // first codon of a reverse item begins at its HIGH coordinate. The
            // offset is the distance from base N (right end) inward to that base.
            offset = (seqLen - clampedHi) % 3
        }

        // Select exactly the matching frame toggle (Frame 1/2/3 = offset 0/1/2).
        settings.showFrame1 = (offset == 0)
        settings.showFrame2 = (offset == 1)
        settings.showFrame3 = (offset == 2)
    }
    
    // MARK: - Restriction Sites  (#9)
    
    private var restrictionSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Restriction sites").font(.system(size: 12, weight: .semibold))
            
            HStack(spacing: 6) {
                Toggle("Do not show RE sites", isOn: $settings.doNotShowRESites)
                    .toggleStyle(.checkbox).font(.system(size: 12))
                    .contextHelp("smap.doNotShowRESites")
                Toggle("Show all sites", isOn: $settings.showAllSites)
                    .toggleStyle(.checkbox).font(.system(size: 12))
                    .contextHelp("smap.showAllSites")
            }
            
            if !settings.showAllSites {
                HStack(spacing: 6) {
                    Text("Maximum cut").font(.system(size: 12))
                    TextField("", value: $settings.maximumCut, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 40).font(.system(size: 12))
                }
                .contextHelp("smap.maximumCut")
            }
            
            // #9: Particular Sites
            HStack(spacing: 6) {
                Toggle("Particular Sites", isOn: $settings.useParticularSites)
                    .toggleStyle(.checkbox).font(.system(size: 12))
                    .contextHelp("smap.particularSites")
                
                Button(action: { showParticularSitesSheet = true }) {
                    HStack(spacing: 2) {
                        Text(particularSitesSummary)
                            .font(.system(size: 12)).foregroundColor(.secondary)
                            .lineLimit(1).frame(maxWidth: 100, alignment: .leading)
                        Image(systemName: "chevron.down").font(.system(size: 9))
                    }
                }
                .controlSize(.small)
                .disabled(!settings.useParticularSites)
            }
            
            // My Enzymes filter
            Toggle(isOn: $settings.useMyEnzymesOnly) {
                Label("My Enzymes Only", systemImage: "star.fill")
                    .font(.system(size: 12))
            }
            .toggleStyle(.checkbox)
            .disabled(enzymeDB.myEnzymeNames.isEmpty)
            .help(enzymeDB.myEnzymeNames.isEmpty
                  ? "No enzymes marked — use Tools → Restriction Enzyme List to star enzymes"
                  : "Show only enzymes in your freezer")
            .contextHelp("smap.myEnzymesOnly")
            .onChange(of: settings.useMyEnzymesOnly) { _ in computeCutSites() }

            Divider().padding(.vertical, 2)

            Text("Methylation").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
            Toggle("Dam (GATC)", isOn: $methylationDam)
                .toggleStyle(.checkbox).font(.system(size: 12))
                .contextHelp("smap.methylationDam")
            Toggle("Dcm (CCWGG)", isOn: $methylationDcm)
                .toggleStyle(.checkbox).font(.system(size: 12))
                .contextHelp("smap.methylationDcm")
            Toggle("CpG", isOn: $methylationCpG)
                .toggleStyle(.checkbox).font(.system(size: 12))
                .contextHelp("smap.methylationCpG")
            (Text("Red").foregroundColor(.red)
            + Text(" = blocked  ·  ").foregroundColor(.secondary)
            + Text("Blue").foregroundColor(.blue)
            + Text(" = required").foregroundColor(.secondary))
                .font(.system(size: 10))
        }
        .sheet(isPresented: $showParticularSitesSheet) {
            let enzList = settings.useMyEnzymesOnly
                ? enzymeDB.myEnzymes.sorted(by: { $0.name < $1.name })
                : enzymeDB.enzymes.sorted(by: { $0.name < $1.name })
            ParticularSitesSheet(
                selectedSites: $settings.particularSites,
                allEnzymes: enzList,
                nonCuttingEnzymes: computeNonCuttingEnzymes()
            )
        }
    }
    
    private var particularSitesSummary: String {
        if settings.particularSites.isEmpty { return "Choose..." }
        let names = settings.particularSites.sorted()
        if names.count <= 2 { return names.joined(separator: ", ") }
        return "\(names[0]), \(names[1]) +\(names.count - 2)"
    }
    
    /// Returns the names of enzymes that do not cut the current sequence.
    /// Used by the Particular Sites picker to display non-cutters in italics.
    private func computeNonCuttingEnzymes() -> Set<String> {
        let seq = sequence.sequence
        let circular = sequence.isCircular
        let enzymeList = settings.useMyEnzymesOnly ? enzymeDB.myEnzymes : enzymeDB.enzymes
        var nonCutters = Set<String>()
        for enzyme in enzymeList {
            if enzyme.findCutSites(in: seq, circular: circular).isEmpty {
                nonCutters.insert(enzyme.name)
            }
        }
        return nonCutters
    }
    
    // MARK: - Display  (#4)
    
    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Display").font(.system(size: 12, weight: .semibold))
            
            HStack(spacing: 6) {
                Toggle("Show Reverse strand", isOn: $settings.showReverseStrand)
                    .toggleStyle(.checkbox).font(.system(size: 12))
                    .contextHelp("smap.showReverseStrand")
                Toggle("Coord", isOn: $settings.showCoordinates)
                    .toggleStyle(.checkbox).font(.system(size: 12))
                    .contextHelp("smap.showCoordinates")
            }
            
            HStack(spacing: 6) {
                Text("Character size").font(.system(size: 12))
                Picker("", selection: $settings.characterSize) {
                    ForEach([8, 9, 10, 11, 12, 13, 14] as [CGFloat], id: \.self) { s in
                        Text("\(Int(s)) pts").tag(s)
                    }
                }
                .frame(width: 72).font(.system(size: 12))
            }
            .contextHelp("smap.characterSize")
            
            HStack(spacing: 6) {
                TextField("", value: $settings.nucleotidesPerLine, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 45).font(.system(size: 12))
                Text("n/line").font(.system(size: 12))
            }
            .contextHelp("smap.nucleotidesPerLine")
        }
    }
    
    // MARK: - Footer  (#3, #4)
    
    private var footerSection: some View {
        HStack(spacing: 12) {
            // #3: Home button
            Button(action: goHome) {
                Label("Home", systemImage: "house")
            }
            .controlSize(.small)
            .help("Return to sequence editor window")
            .contextHelp("smap.home")
            
            Button("Copy Restriction Map") {
                let text = renderer.renderPlainText(sequence: sequence, settings: settings, cutSites: cutSites)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .controlSize(.small)
            .contextHelp("smap.copyMap")
            
            Spacer()
            
            // #4: Print character size (separate from screen)
            HStack(spacing: 4) {
                Text("Print : Character size").font(.caption)
                Picker("", selection: $settings.printCharacterSize) {
                    ForEach([6, 7, 8, 9, 10, 11, 12] as [CGFloat], id: \.self) { s in
                        Text("\(Int(s)) pts").tag(s)
                    }
                }
                .frame(width: 60).font(.caption)
            }
            .contextHelp("smap.printCharacterSize")
            
            Spacer()
            
            Button("Page Setup") {
                NSPageLayout().runModal(with: NSPrintInfo.shared)
            }
            .controlSize(.small)
            .contextHelp("smap.pageSetup")
            
            Button("Print") { printMap() }
                .controlSize(.small)
            .contextHelp("smap.print")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    // MARK: - Actions
    
    // #3: Home — open/reopen the sequence editor window and bring it to front
    private func goHome() {
        // First try to find and activate an existing window
        for window in NSApp.windows where window != NSApp.keyWindow {
            let title = window.title
            if title == sequence.name
                || (sequence.name.isEmpty && (title == "Untitled Sequence" || title == "Untitled"))
            {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
        }
        // Window was closed — use SwiftUI's openWindow to create a new one
        openWindow(id: "sequence", value: sequenceID)
    }
    
    // #4: Print uses printCharacterSize
    private func printMap() {
        // Calculate how many bases fit on one line at the chosen print font size.
        // Uses the printable width of the page (paper minus margins) divided by
        // the advance width of one monospaced character, with a small safety margin.
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .clip
        info.verticalPagination = .automatic

        let printableWidth = info.paperSize.width - info.leftMargin - info.rightMargin
        let printFont = settings.printFont
        let charWidth = printFont.advancement(forGlyph: printFont.glyph(withName: "M") != 0
            ? printFont.glyph(withName: "M")
            : NSGlyph(77)   // 'M' fallback
        ).width
        // Fall back to pointSize * 0.6 if glyph lookup returns zero
        let safeCharWidth = charWidth > 1 ? charWidth : printFont.pointSize * 0.6
        // In codon mode each group of 3 bases gets an extra space column,
        // expanding the line by ~33%. Reduce nPerLine accordingly so it still fits.
        let rawNPerLine = max(40, Int(floor(printableWidth / safeCharWidth)) - 2)
        let nPerLine = settings.codonModeActive ? max(40, rawNPerLine * 3 / 4) : rawNPerLine

        let printAttr = renderer.render(sequence: sequence, settings: settings,
                                        cutSites: cutSites, forPrint: true,
                                        nPerLineOverride: nPerLine)
        let coloredAttr = applyMethylationColours(to: printAttr)
        let printView = NSTextView(frame: NSRect(x: 0, y: 0, width: printableWidth, height: 1000))
        printView.textStorage?.setAttributedString(coloredAttr)
        printView.sizeToFit()

        let op = NSPrintOperation(view: printView, printInfo: info)
        op.showsPrintPanel = true
        op.showsProgressPanel = true

        // Run as sheet on the current window — op.run() fails in sandboxed SwiftUI apps
        if let window = NSApp.keyWindow {
            op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            op.run()  // fallback
        }
    }
}


// MARK: - Particular Sites Sheet  (#9)

struct ParticularSitesSheet: View {
    @Binding var selectedSites: Set<String>
    let allEnzymes: [RestrictionEnzyme]
    let nonCuttingEnzymes: Set<String>
    @Environment(\.dismiss) private var dismiss
    @State private var filterText: String = ""
    
    private var filteredEnzymes: [RestrictionEnzyme] {
        if filterText.isEmpty { return allEnzymes }
        return allEnzymes.filter { $0.name.localizedCaseInsensitiveContains(filterText) }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Particular Sites").font(.headline)
                Spacer()
                Text("\(selectedSites.count) selected").font(.caption).foregroundColor(.secondary)
            }
            .padding()
            
            // Search
            TextField("Filter enzymes...", text: $filterText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
            
            // Enzyme list
            List {
                ForEach(filteredEnzymes, id: \.name) { enzyme in
                    let doesNotCut = nonCuttingEnzymes.contains(enzyme.name)
                    HStack {
                        Toggle(isOn: Binding(
                            get: { selectedSites.contains(enzyme.name) },
                            set: { isOn in
                                if isOn { selectedSites.insert(enzyme.name) }
                                else { selectedSites.remove(enzyme.name) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(enzyme.name)
                                    .font(.body)
                                    .italic(doesNotCut)
                                    .foregroundColor(doesNotCut ? .secondary : .primary)
                                Text(enzyme.recognitionSite)
                                    .font(.caption).foregroundColor(.secondary)
                                    .fontDesign(.monospaced)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(minHeight: 300)
            
            // Buttons
            HStack {
                Button("Select All") {
                    for e in filteredEnzymes { selectedSites.insert(e.name) }
                }
                .controlSize(.small)
                
                Button("Deselect All") {
                    for e in filteredEnzymes { selectedSites.remove(e.name) }
                }
                .controlSize(.small)
                
                Spacer()
                
                Button("Done") { dismiss() }
                    .keyboardShortcut(.return)
                    .controlSize(.small)
            }
            .padding()
        }
        .frame(width: 350, height: 500)
    }
}


// MARK: - Window Manager (replaces placeholder)

class SequenceMapWindowManager {
    static let shared = SequenceMapWindowManager()
    
    private var windows: [NSWindow] = []
    private init() {}
    
    func openSequenceMapWindow(for sequence: DNASequence) {
        let expectedTitle = "Restriction Map of \(sequence.name)"
        if let existing = windows.first(where: { $0.isVisible && $0.title == expectedTitle }) {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let mapView = SequenceMapView(sequence: sequence, sequenceID: sequence.id)
        let hostingController = NSHostingController(rootView: mapView)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        window.title = "Restriction Map of \(sequence.name)"
        window.contentViewController = hostingController
        window.setFrameAutosaveName("RestrictionMapofsequencename")
        if !window.setFrameUsingName(window.frameAutosaveName) { window.center() }
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 400)
        window.makeKeyAndOrderFront(nil)
        
        windows.append(window)
        
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.windows.removeAll { $0 == window }
        }
    }
    
    func closeAllWindows() {
        windows.forEach { $0.close() }
        windows.removeAll()
    }
}

//
//  AlignTwoSequencesView.swift
//  Cloner 64
//
//  "Align Two Sequences" window — local pairwise alignment with
//  Serial Cloner-style display.
//

import SwiftUI
import AppKit

// MARK: - Custom Attributes for Position Tracking

private extension NSAttributedString.Key {
    /// Which sequence: 1 or 2
    static let alignSeqNumber = NSAttributedString.Key("alignSeqNumber")
    /// 1-based position in the original (ungapped) sequence
    static let alignBasePosition = NSAttributedString.Key("alignBasePosition")
}

// MARK: - Position-Aware Text View

/// NSTextView subclass that shows the sequence position of a clicked base
/// for the duration of the mouse press.
private class PositionTrackingTextView: NSTextView {
    private var positionOverlay: NSView?
    
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        
        guard let container = textContainer, let lm = layoutManager else {
            super.mouseDown(with: event)
            return
        }
        let textPoint = NSPoint(x: point.x - textContainerInset.width,
                                y: point.y - textContainerInset.height)
        let charIndex = lm.characterIndex(for: textPoint, in: container,
                                          fractionOfDistanceBetweenInsertionPoints: nil)
        
        guard charIndex < textStorage?.length ?? 0,
              let storage = textStorage,
              let seqNum = storage.attribute(.alignSeqNumber, at: charIndex, effectiveRange: nil) as? Int,
              let basePos = storage.attribute(.alignBasePosition, at: charIndex, effectiveRange: nil) as? Int
        else {
            dismissPositionIndicator()
            super.mouseDown(with: event)
            return
        }
        
        showPositionIndicator(seqNum: seqNum, basePos: basePos, at: point)
        super.mouseDown(with: event)
    }
    
    override func mouseUp(with event: NSEvent) {
        dismissPositionIndicator()
        super.mouseUp(with: event)
    }
    
    override func mouseDragged(with event: NSEvent) {
        dismissPositionIndicator()
        super.mouseDragged(with: event)
    }
    
    private func showPositionIndicator(seqNum: Int, basePos: Int, at point: NSPoint) {
        dismissPositionIndicator()
        
        let label = NSTextField(labelWithString: " Seq \(seqNum), Pos \(basePos) ")
        label.font = NSFont(name: "Courier", size: 11) ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .labelColor
        label.backgroundColor = NSColor(calibratedWhite: 0.95, alpha: 0.95)
        label.isBezeled = false
        label.wantsLayer = true
        label.layer?.cornerRadius = 4
        label.layer?.masksToBounds = true
        label.layer?.borderWidth = 0.5
        label.layer?.borderColor = NSColor.separatorColor.cgColor
        label.sizeToFit()
        
        label.frame.origin = NSPoint(
            x: point.x + 8,
            y: seqNum == 1
                ? point.y - label.frame.height - 6   // above the line for Seq 1
                : point.y + 6                          // below the line for Seq 2
        )
        
        addSubview(label)
        positionOverlay = label
    }
    
    private func dismissPositionIndicator() {
        positionOverlay?.removeFromSuperview()
        positionOverlay = nil
    }
}

// MARK: - Alignment Text View (NSTextView wrapper)

struct AlignmentTextView: NSViewRepresentable {
    let attributedString: NSAttributedString
    
    func makeNSView(context: Context) -> NSScrollView {
        let textView = PositionTrackingTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.backgroundColor = .white
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                        height: CGFloat.greatestFiniteMagnitude)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                   height: CGFloat.greatestFiniteMagnitude)
        
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        textView.autoresizingMask = [.width, .height]
        
        return scrollView
    }
    
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let storage = textView.textStorage!
        storage.beginEditing()
        storage.setAttributedString(attributedString)
        storage.endEditing()
    }
}

// MARK: - Main View

struct AlignTwoSequencesView: View {
    @EnvironmentObject var sequenceManager: SequenceManager
    
    // Sequence selection
    @State private var seq1Index: Int = 0
    @State private var seq2Index: Int = 1
    @State private var antiParallel1 = false
    @State private var antiParallel2 = false
    
    // Translation
    @State private var seq1Frame1 = false
    @State private var seq1Frame2 = false
    @State private var seq1Frame3 = false
    @State private var seq2Frame1 = false
    @State private var seq2Frame2 = false
    @State private var seq2Frame3 = false
    
    // Alignment
    @State private var wordSize: Int = 15
    @State private var highlightDifferences = false
    @State private var showFeatures = true
    @State private var showFeatureList = false
    @State private var isAligning = false
    @State private var alignmentResult: AlignmentResult?
    @State private var alignmentAttrString: NSAttributedString?
    @State private var showLongAlignmentWarning = false
    @State private var pendingAlignmentParams: (s1: String, s2: String, ws: Int, ap1: Bool, ap2: Bool)?
    
    // Display
    @State private var screenFontSize: CGFloat = 12
    @State private var printFontSize: CGFloat = 8
    
    private let charsPerLine = 60
    /// Threshold above which we warn the user (product of lengths)
    private let longAlignmentThreshold = 50_000_000
    
    var body: some View {
        VStack(spacing: 0) {
            controlsSection
            Divider()
            toolRow
            Divider()
            
            // Collapsible feature list
            if showFeatureList {
                featureListSection
                Divider()
            }
            
            resultArea
            Divider()
            footerSection
        }
        .frame(minWidth: 800, minHeight: 550)
        .alert("Long Alignment Warning", isPresented: $showLongAlignmentWarning) {
            Button("Continue", role: .destructive) {
                if let params = pendingAlignmentParams {
                    executeAlignment(s1: params.s1, s2: params.s2, ws: params.ws,
                                     ap1: params.ap1, ap2: params.ap2)
                }
                pendingAlignmentParams = nil
            }
            Button("Cancel", role: .cancel) {
                pendingAlignmentParams = nil
            }
        } message: {
            if let params = pendingAlignmentParams {
                let len1 = params.s1.filter(\.isLetter).count
                let len2 = params.s2.filter(\.isLetter).count
                Text("Aligning \(len1) bp \u{00D7} \(len2) bp sequences may take a long time and use significant memory. Do you want to continue?")
            }
        }
    }
    
    // MARK: - Controls
    
    private var controlsSection: some View {
        HStack(alignment: .top, spacing: 16) {
            // Sequence 1
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Sequence 1").font(.caption).fontWeight(.semibold)
                    Spacer()
                    Toggle("anti-parallel", isOn: $antiParallel1)
                        .toggleStyle(.checkbox).font(.caption)
                        .contextHelp("align.antiParallel")
                }
                
                Picker("", selection: $seq1Index) {
                    ForEach(0..<max(1, sequenceManager.sequences.count), id: \.self) { idx in
                        if idx < sequenceManager.sequences.count {
                            Text(sequenceManager.sequences[idx].name)
                                .tag(idx)
                        }
                    }
                }
                .frame(maxWidth: 220)
                .contextHelp("align.sequencePicker")
                
                HStack(spacing: 6) {
                    Text("Translation :").font(.caption)
                    Toggle("Frame 1", isOn: $seq1Frame1).toggleStyle(.checkbox).font(.caption)
                        .onChange(of: seq1Frame1) { _ in rerender() }
                        .contextHelp("align.translation")
                    Toggle("Frame 2", isOn: $seq1Frame2).toggleStyle(.checkbox).font(.caption)
                        .onChange(of: seq1Frame2) { _ in rerender() }
                        .contextHelp("align.translation")
                    Toggle("Frame 3", isOn: $seq1Frame3).toggleStyle(.checkbox).font(.caption)
                        .onChange(of: seq1Frame3) { _ in rerender() }
                        .contextHelp("align.translation")
                }
            }
            
            // Sequence 2
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Sequence 2").font(.caption).fontWeight(.semibold)
                    Spacer()
                    Toggle("anti-parallel", isOn: $antiParallel2)
                        .toggleStyle(.checkbox).font(.caption)
                        .contextHelp("align.antiParallel")
                }
                
                Picker("", selection: $seq2Index) {
                    ForEach(0..<max(1, sequenceManager.sequences.count), id: \.self) { idx in
                        if idx < sequenceManager.sequences.count {
                            Text(sequenceManager.sequences[idx].name)
                                .tag(idx)
                        }
                    }
                }
                .frame(maxWidth: 220)
                .contextHelp("align.sequencePicker")
                
                HStack(spacing: 6) {
                    Text("Translation :").font(.caption)
                    Toggle("Frame 1", isOn: $seq2Frame1).toggleStyle(.checkbox).font(.caption)
                        .onChange(of: seq2Frame1) { _ in rerender() }
                        .contextHelp("align.translation")
                    Toggle("Frame 2", isOn: $seq2Frame2).toggleStyle(.checkbox).font(.caption)
                        .onChange(of: seq2Frame2) { _ in rerender() }
                        .contextHelp("align.translation")
                    Toggle("Frame 3", isOn: $seq2Frame3).toggleStyle(.checkbox).font(.caption)
                        .onChange(of: seq2Frame3) { _ in rerender() }
                        .contextHelp("align.translation")
                }
            }
            
            Spacer()
            
            // Right side: buttons
            VStack(alignment: .trailing, spacing: 6) {
                Button("Local Align") {
                    runAlignment()
                }
                .controlSize(.regular)
                .keyboardShortcut(.return, modifiers: .command)
                .contextHelp("align.localAlign")
                
                HStack(spacing: 4) {
                    Text("WordSize").font(.caption)
                    TextField("", value: $wordSize, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 40)
                        .font(.caption)
                    Text("nt").font(.caption)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
    
    // MARK: - Tool Row
    
    private var toolRow: some View {
        HStack(spacing: 8) {
            Toggle("Highlight differences", isOn: $highlightDifferences)
                .toggleStyle(.checkbox).font(.caption)
                .onChange(of: highlightDifferences) { _ in rerender() }
                .contextHelp("align.highlightDiffs")
            
            Divider().frame(height: 16)
            
            Toggle("Show Features", isOn: $showFeatures)
                .toggleStyle(.checkbox).font(.caption)
                .onChange(of: showFeatures) { _ in rerender() }
                .contextHelp("align.showFeatures")
            
            Button(action: { withAnimation { showFeatureList.toggle() } }) {
                Image(systemName: showFeatureList ? "list.bullet.circle.fill" : "list.bullet.circle")
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain).help("Toggle feature list")
            
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
    
    // MARK: - Feature List
    
    private var featureListSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            let sequences = sequenceManager.sequences
            let seq1 = seq1Index < sequences.count ? sequences[seq1Index] : nil
            let seq2 = seq2Index < sequences.count ? sequences[seq2Index] : nil
            let allFeatures = (seq1?.features ?? []) + (seq2?.features ?? [])
            
            HStack {
                Text("Features").font(.caption).fontWeight(.semibold)
                Spacer()
                if let s1 = seq1 {
                    Text("\(s1.name): \(s1.features.count)").font(.caption2).foregroundColor(.secondary)
                }
                if let s2 = seq2 {
                    Text("  \(s2.name): \(s2.features.count)").font(.caption2).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            
            if allFeatures.isEmpty {
                Text("No features annotated.")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 10).padding(.bottom, 4)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        // Header row
                        HStack(spacing: 0) {
                            Text("Sequence").frame(width: 100, alignment: .leading)
                            Text("Name").frame(width: 160, alignment: .leading)
                            Text("Start").frame(width: 70, alignment: .trailing)
                            Text("End").frame(width: 70, alignment: .trailing)
                            Text("Direction").frame(width: 90, alignment: .center)
                            Spacer()
                        }
                        .font(.caption2).fontWeight(.semibold).foregroundColor(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 2)
                        
                        Divider()
                        
                        // Seq 1 features
                        if let s1 = seq1 {
                            ForEach(s1.features) { feature in
                                featureRow(seqName: s1.name, feature: feature)
                            }
                        }
                        
                        // Seq 2 features
                        if let s2 = seq2 {
                            ForEach(s2.features) { feature in
                                featureRow(seqName: s2.name, feature: feature)
                            }
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }
    
    private func featureRow(seqName: String, feature: Feature) -> some View {
        HStack(spacing: 0) {
            Text(seqName)
                .lineLimit(1)
                .frame(width: 100, alignment: .leading)
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
            Text(feature.strand == .forward ? "\u{2192}" : "\u{2190}")
                .frame(width: 90, alignment: .center)
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 2)
    }
    
    // MARK: - Result Area
    
    private var resultArea: some View {
        Group {
            if isAligning {
                VStack {
                    Spacer()
                    ProgressView("Aligning sequences...")
                    Spacer()
                }
            } else if let attrStr = alignmentAttrString {
                AlignmentTextView(attributedString: attrStr)
            } else {
                VStack {
                    Spacer()
                    Text("ALIGN DNA SEQUENCES")
                        .font(.system(size: 28, weight: .bold))
                        .italic()
                        .foregroundColor(.secondary.opacity(0.4))
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
    }
    
    // MARK: - Footer
    
    private var footerSection: some View {
        HStack(spacing: 12) {
            Text("Character Size").font(.caption).fontWeight(.semibold)
            
            HStack(spacing: 4) {
                Text("Screen size").font(.caption)
                Picker("", selection: $screenFontSize) {
                    ForEach([8, 9, 10, 11, 12, 13, 14] as [CGFloat], id: \.self) { s in
                        Text("\(Int(s)) pts").tag(s)
                    }
                }
                .frame(width: 65).font(.caption)
                .onChange(of: screenFontSize) { _ in rerender() }
                .contextHelp("align.screenFontSize")
            }
            
            HStack(spacing: 4) {
                Text("Print size").font(.caption)
                Picker("", selection: $printFontSize) {
                    ForEach([6, 7, 8, 9, 10, 11, 12] as [CGFloat], id: \.self) { s in
                        Text("\(Int(s)) pts").tag(s)
                    }
                }
                .frame(width: 65).font(.caption)
                .contextHelp("align.printFontSize")
            }
            
            Spacer()
            
            Button("Copy to ClipBoard") {
                copyToClipboard()
            }
            .controlSize(.small)
            .contextHelp("align.copyClipboard")
            
            Button("Page Setup") {
                NSPageLayout().runModal(with: NSPrintInfo.shared)
            }
            .controlSize(.small)
            .contextHelp("align.pageSetup")
            
            Button("Print") {
                printAlignment()
            }
            .controlSize(.small)
            .contextHelp("align.print")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    // MARK: - Run Alignment
    
    private func runAlignment() {
        let sequences = sequenceManager.sequences
        guard sequences.count >= 2,
              seq1Index < sequences.count,
              seq2Index < sequences.count else { return }
        
        let s1 = sequences[seq1Index].sequence
        let s2 = sequences[seq2Index].sequence
        
        guard !s1.isEmpty && !s2.isEmpty else { return }
        
        let len1 = s1.filter(\.isLetter).count
        let len2 = s2.filter(\.isLetter).count
        
        let ws = wordSize
        let ap1 = antiParallel1
        let ap2 = antiParallel2
        
        // Warn if alignment could be slow
        if len1 * len2 > longAlignmentThreshold {
            pendingAlignmentParams = (s1, s2, ws, ap1, ap2)
            showLongAlignmentWarning = true
            return
        }
        
        executeAlignment(s1: s1, s2: s2, ws: ws, ap1: ap1, ap2: ap2)
    }
    
    private func executeAlignment(s1: String, s2: String, ws: Int, ap1: Bool, ap2: Bool) {
        isAligning = true
        
        DispatchQueue.global(qos: .userInitiated).async {
            let aligner = SequenceAligner()
            let result = aligner.align(seq1: s1, seq2: s2, wordSize: ws,
                                       antiParallel1: ap1, antiParallel2: ap2)
            let rendered = renderAlignment(result)
            DispatchQueue.main.async {
                alignmentResult = result
                alignmentAttrString = rendered
                isAligning = false
            }
        }
    }
    
    // MARK: - Feature Colour Maps
    
    /// Build a colour map: for each base position -> NSColor based on features.
    private func buildFeatureColourMap(for seqIndex: Int) -> [NSColor] {
        let sequences = sequenceManager.sequences
        guard showFeatures, seqIndex < sequences.count else { return [] }
        let seq = sequences[seqIndex]
        let seqLen = seq.sequence.filter(\.isLetter).count
        var map = Array(repeating: NSColor.labelColor, count: seqLen)
        
        for feature in seq.features {
            let nsColor = NSColor(red: CGFloat(feature.color.red), green: CGFloat(feature.color.green),
                                  blue: CGFloat(feature.color.blue), alpha: CGFloat(feature.color.alpha))
            let fS = feature.start, fE = feature.end
            if fS <= fE {
                for i in fS..<min(fE, seqLen) where i >= 0 { map[i] = nsColor }
            } else {
                for i in fS..<seqLen { map[i] = nsColor }
                for i in 0..<min(fE, seqLen) { map[i] = nsColor }
            }
        }
        return map
    }
    
    /// Map feature colours through alignment gaps.
    private func mapColoursToAlignment(_ aligned: [Character], baseColours: [NSColor]) -> [NSColor] {
        var result: [NSColor] = []
        var baseIdx = 0
        for ch in aligned {
            if ch == "-" {
                result.append(NSColor.black)
            } else {
                if baseIdx < baseColours.count {
                    result.append(baseColours[baseIdx])
                } else {
                    result.append(NSColor.black)
                }
                baseIdx += 1
            }
        }
        return result
    }
    
    // MARK: - Render Alignment Display
    
    private func renderAlignment(_ result: AlignmentResult, fontSize: CGFloat? = nil) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let useFontSize = fontSize ?? screenFontSize
        let font = NSFont.monospacedSystemFont(ofSize: useFontSize, weight: .regular)
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let matchAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let gapAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let diffBgColor = NSColor(calibratedRed: 0.7, green: 0.85, blue: 1.0, alpha: 1.0)
        let transAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(red: 0.35, green: 0.35, blue: 0.35, alpha: 1.0)
        ]
        
        let al1 = result.alignedSeq1
        let al2 = result.alignedSeq2
        let totalLen = al1.count
        
        guard totalLen > 0 else {
            output.append(NSAttributedString(string: "No alignment found.\n", attributes: labelAttrs))
            return output
        }
        
        // Build feature colour maps
        let baseColours1 = buildFeatureColourMap(for: seq1Index)
        let baseColours2 = buildFeatureColourMap(for: seq2Index)
        let alignColours1 = mapColoursToAlignment(al1, baseColours: baseColours1)
        let alignColours2 = mapColoursToAlignment(al2, baseColours: baseColours2)
        
        // Track positions (1-based, gaps don't count)
        var pos1 = 1
        var pos2 = 1
        
        let seq1Frames = [seq1Frame1, seq1Frame2, seq1Frame3]
        let seq2Frames = [seq2Frame1, seq2Frame2, seq2Frame3]
        let pad = String(repeating: " ", count: 13)
        
        var offset = 0
        while offset < totalLen {
            let end = min(offset + charsPerLine, totalLen)
            let chunk1 = Array(al1[offset..<end])
            let chunk2 = Array(al2[offset..<end])
            
            // Count non-gap bases in this chunk
            let bases1 = chunk1.filter { $0 != "-" }.count
            let bases2 = chunk2.filter { $0 != "-" }.count
            
            let startPos1 = pos1
            let endPos1   = bases1 > 0 ? pos1 + bases1 - 1 : pos1 - 1
            let startPos2 = pos2
            let endPos2   = bases2 > 0 ? pos2 + bases2 - 1 : pos2 - 1
            
            // --- Seq 1 translation lines (above Seq 1) ---
            if seq1Frames.contains(true) {
                for frameIdx in 0..<3 {
                    guard seq1Frames[frameIdx] else { continue }
                    let translated = translateAligned(al1, frame: frameIdx)
                    let chunk = translated[offset..<end]
                    output.append(NSAttributedString(string: pad + String(chunk) + "\n", attributes: transAttrs))
                }
            }
            
            // --- Seq 1 line (colour-coded) ---
            let label1 = "Seq_1".padding(toLength: 7, withPad: " ", startingAt: 0)
                       + String(startPos1).padding(toLength: 6, withPad: " ", startingAt: 0)
            output.append(NSAttributedString(string: label1, attributes: labelAttrs))
            
            // Build per-character position array for click tracking
            var basePositions1: [Int] = []
            var runPos1 = startPos1
            for ch in chunk1 {
                if ch == "-" {
                    basePositions1.append(0)
                } else {
                    basePositions1.append(runPos1)
                    runPos1 += 1
                }
            }
            
            appendColouredChunk(to: output, chunk: chunk1, otherChunk: chunk2,
                                colours: Array(alignColours1[offset..<end]),
                                font: font, gapAttrs: gapAttrs, diffBgColor: diffBgColor,
                                isHighlighting: highlightDifferences,
                                seqNumber: 1, basePositions: basePositions1)
            output.append(NSAttributedString(string: "    \(max(0, endPos1))\n", attributes: labelAttrs))
            
            // --- Match line ---
            output.append(NSAttributedString(string: pad, attributes: matchAttrs))
            for idx in offset..<end {
                let c1 = Character(String(al1[idx]).uppercased())
                let c2 = Character(String(al2[idx]).uppercased())
                if c1 != "-" && c2 != "-" && c1 == c2 {
                    output.append(NSAttributedString(string: "|", attributes: matchAttrs))
                } else {
                    output.append(NSAttributedString(string: " ", attributes: matchAttrs))
                }
            }
            output.append(NSAttributedString(string: "\n", attributes: matchAttrs))
            
            // --- Seq 2 line (colour-coded) ---
            let label2 = "Seq_2".padding(toLength: 7, withPad: " ", startingAt: 0)
                       + String(startPos2).padding(toLength: 6, withPad: " ", startingAt: 0)
            output.append(NSAttributedString(string: label2, attributes: labelAttrs))
            
            // Build per-character position array for click tracking
            var basePositions2: [Int] = []
            var runPos2 = startPos2
            for ch in chunk2 {
                if ch == "-" {
                    basePositions2.append(0)
                } else {
                    basePositions2.append(runPos2)
                    runPos2 += 1
                }
            }
            
            appendColouredChunk(to: output, chunk: chunk2, otherChunk: chunk1,
                                colours: Array(alignColours2[offset..<end]),
                                font: font, gapAttrs: gapAttrs, diffBgColor: diffBgColor,
                                isHighlighting: highlightDifferences,
                                seqNumber: 2, basePositions: basePositions2)
            output.append(NSAttributedString(string: "    \(max(0, endPos2))\n", attributes: labelAttrs))
            
            // --- Seq 2 translation lines (below Seq 2) ---
            if seq2Frames.contains(true) {
                for frameIdx in 0..<3 {
                    guard seq2Frames[frameIdx] else { continue }
                    let translated = translateAligned(al2, frame: frameIdx)
                    let chunk = translated[offset..<end]
                    output.append(NSAttributedString(string: pad + String(chunk) + "\n", attributes: transAttrs))
                }
            }
            
            // Blank line between blocks
            output.append(NSAttributedString(string: "\n", attributes: labelAttrs))
            
            pos1 += bases1
            pos2 += bases2
            offset = end
        }
        
        // Summary line
        let summaryStr = String(format: "\nAlignment: %d matches out of %d positions (%.1f%% identity)\n",
                                result.matches, result.alignmentLength, result.identity)
        output.append(NSAttributedString(string: summaryStr, attributes: labelAttrs))
        
        return output
    }
    
    /// Append a chunk of sequence characters with feature colour coding, optional diff highlighting,
    /// and position metadata for click-to-show-position.
    private func appendColouredChunk(
        to output: NSMutableAttributedString,
        chunk: [Character], otherChunk: [Character],
        colours: [NSColor],
        font: NSFont,
        gapAttrs: [NSAttributedString.Key: Any],
        diffBgColor: NSColor,
        isHighlighting: Bool,
        seqNumber: Int = 0,
        basePositions: [Int] = []
    ) {
        for (i, ch) in chunk.enumerated() {
            if ch == "-" {
                output.append(NSAttributedString(string: "-", attributes: gapAttrs))
            } else {
                let baseColour = i < colours.count ? colours[i] : NSColor.labelColor
                var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: baseColour]
                
                if isHighlighting && i < otherChunk.count && otherChunk[i] != "-" {
                    let upper1 = Character(String(ch).uppercased())
                    let upper2 = Character(String(otherChunk[i]).uppercased())
                    if upper1 != upper2 {
                        attrs[.backgroundColor] = diffBgColor
                    }
                }
                
                // Attach position metadata for click tracking
                if seqNumber > 0 && i < basePositions.count {
                    attrs[.alignSeqNumber] = seqNumber
                    attrs[.alignBasePosition] = basePositions[i]
                }
                
                output.append(NSAttributedString(string: String(ch), attributes: attrs))
            }
        }
    }
    
    // MARK: - Re-render Helper
    
    private func rerender() {
        if let result = alignmentResult {
            alignmentAttrString = renderAlignment(result)
        }
    }
    
    // MARK: - Codon Table
    
    private static let codonTable: [String: Character] = [
        "TTT": "F", "TTC": "F", "TTA": "L", "TTG": "L",
        "CTT": "L", "CTC": "L", "CTA": "L", "CTG": "L",
        "ATT": "I", "ATC": "I", "ATA": "I", "ATG": "M",
        "GTT": "V", "GTC": "V", "GTA": "V", "GTG": "V",
        "TCT": "S", "TCC": "S", "TCA": "S", "TCG": "S",
        "CCT": "P", "CCC": "P", "CCA": "P", "CCG": "P",
        "ACT": "T", "ACC": "T", "ACA": "T", "ACG": "T",
        "GCT": "A", "GCC": "A", "GCA": "A", "GCG": "A",
        "TAT": "Y", "TAC": "Y", "TAA": "*", "TAG": "*",
        "CAT": "H", "CAC": "H", "CAA": "Q", "CAG": "Q",
        "AAT": "N", "AAC": "N", "AAA": "K", "AAG": "K",
        "GAT": "D", "GAC": "D", "GAA": "E", "GAG": "E",
        "TGT": "C", "TGC": "C", "TGA": "*", "TGG": "W",
        "CGT": "R", "CGC": "R", "CGA": "R", "CGG": "R",
        "AGT": "S", "AGC": "S", "AGA": "R", "AGG": "R",
        "GGT": "G", "GGC": "G", "GGA": "G", "GGG": "G"
    ]
    
    /// Translate an aligned sequence for a given frame (0, 1, or 2).
    private func translateAligned(_ aligned: [Character], frame: Int) -> [Character] {
        let len = aligned.count
        var result = Array(repeating: Character(" "), count: len)
        
        var basePositions: [Int] = []
        for (i, ch) in aligned.enumerated() {
            if ch != "-" { basePositions.append(i) }
        }
        
        let baseCount = basePositions.count
        guard frame < baseCount else { return result }
        
        var bi = frame
        while bi + 2 < baseCount {
            let b0 = basePositions[bi]
            let b1 = basePositions[bi + 1]
            let b2 = basePositions[bi + 2]
            
            let codon = String([aligned[b0], aligned[b1], aligned[b2]]).uppercased()
            let aa = Self.codonTable[codon] ?? Character("?")
            
            result[b1] = aa
            bi += 3
        }
        
        return result
    }
    
    // MARK: - Copy / Print
    
    private func copyToClipboard() {
        guard let attrStr = alignmentAttrString else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(attrStr.string, forType: .string)
    }
    
    private func printAlignment() {
        guard let result = alignmentResult else { return }
        
        let printAttr = renderAlignment(result, fontSize: printFontSize)
        
        let printView = NSTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 1000))
        printView.textStorage?.setAttributedString(printAttr)
        printView.sizeToFit()
        
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        
        let op = NSPrintOperation(view: printView, printInfo: info)
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        
        if let window = NSApp.keyWindow {
            op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            op.run()
        }
    }
}

// MARK: - Window Manager

class AlignTwoSequencesWindowManager {
    static let shared = AlignTwoSequencesWindowManager()
    
    private var windows: [NSWindow] = []
    private init() {}
    
    func openWindow(sequenceManager: SequenceManager) {
        let view = AlignTwoSequencesView()
            .environmentObject(sequenceManager)
        
        let hostingController = NSHostingController(rootView: view)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        window.title = "Align Two Sequences"
        window.contentViewController = hostingController
        window.setFrameAutosaveName("AlignTwoSequences")
        if !window.setFrameUsingName(window.frameAutosaveName) { window.center() }
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 750, height: 450)
        window.makeKeyAndOrderFront(nil)
        
        windows.append(window)
        
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window, queue: .main
        ) { [weak self] _ in
            self?.windows.removeAll { $0 == window }
        }
    }
}

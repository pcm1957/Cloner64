//
//  AlignTwoProteinSequencesView.swift
//  Cloner 64
//
//  Pairwise protein alignment with BLOSUM62 scoring.
//  Uses Smith-Waterman local alignment with affine gap penalties.
//  Match line uses ClustalW convention:
//    *  = identical
//    :  = conservative substitution (BLOSUM62 > 0)
//    .  = semi-conservative (BLOSUM62 = 0)
//       = no similarity (BLOSUM62 < 0)
//

import SwiftUI
import AppKit

// MARK: - BLOSUM62 Matrix

struct BLOSUM62 {
    /// Standard BLOSUM62 half-matrix
    /// Order: A R N D C Q E G H I L K M F P S T W Y V
    private static let aaOrder: [Character] = [
        "A","R","N","D","C","Q","E","G","H","I",
        "L","K","M","F","P","S","T","W","Y","V"
    ]
    
    private static let matrix: [[Int]] = [
        // A   R   N   D   C   Q   E   G   H   I   L   K   M   F   P   S   T   W   Y   V
        [ 4, -1, -2, -2,  0, -1, -1,  0, -2, -1, -1, -1, -1, -2, -1,  1,  0, -3, -2,  0], // A
        [-1,  5,  0, -2, -3,  1,  0, -2,  0, -3, -2,  2, -1, -3, -2, -1, -1, -3, -2, -3], // R
        [-2,  0,  6,  1, -3,  0,  0,  0,  1, -3, -3,  0, -2, -3, -2,  1,  0, -4, -2, -3], // N
        [-2, -2,  1,  6, -3,  0,  2, -1, -1, -3, -4, -1, -3, -3, -1,  0, -1, -4, -3, -3], // D
        [ 0, -3, -3, -3,  9, -3, -4, -3, -3, -1, -1, -3, -1, -2, -3, -1, -1, -2, -2, -1], // C
        [-1,  1,  0,  0, -3,  5,  2, -2,  0, -3, -2,  1,  0, -3, -1,  0, -1, -2, -1, -2], // Q
        [-1,  0,  0,  2, -4,  2,  5, -2,  0, -3, -3,  1, -2, -3, -1,  0, -1, -3, -2, -2], // E
        [ 0, -2,  0, -1, -3, -2, -2,  6, -2, -4, -4, -2, -3, -3, -2,  0, -2, -2, -3, -3], // G
        [-2,  0,  1, -1, -3,  0,  0, -2,  8, -3, -3, -1, -2, -1, -2, -1, -2, -2,  2, -3], // H
        [-1, -3, -3, -3, -1, -3, -3, -4, -3,  4,  2, -3,  1,  0, -3, -2, -1, -3, -1,  3], // I
        [-1, -2, -3, -4, -1, -2, -3, -4, -3,  2,  4, -2,  2,  0, -3, -2, -1, -2, -1,  1], // L
        [-1,  2,  0, -1, -3,  1,  1, -2, -1, -3, -2,  5, -1, -3, -1,  0, -1, -3, -2, -2], // K
        [-1, -1, -2, -3, -1,  0, -2, -3, -2,  1,  2, -1,  5,  0, -2, -1, -1, -1, -1,  1], // M
        [-2, -3, -3, -3, -2, -3, -3, -3, -1,  0,  0, -3,  0,  6, -4, -2, -2,  1,  3, -1], // F
        [-1, -2, -2, -1, -3, -1, -1, -2, -2, -3, -3, -1, -2, -4,  7, -1, -1, -4, -3, -2], // P
        [ 1, -1,  1,  0, -1,  0,  0,  0, -1, -2, -2,  0, -1, -2, -1,  4,  1, -3, -2, -2], // S
        [ 0, -1,  0, -1, -1, -1, -1, -2, -2, -1, -1, -1, -1, -2, -1,  1,  5, -2, -2,  0], // T
        [-3, -3, -4, -4, -2, -2, -3, -2, -2, -3, -2, -3, -1,  1, -4, -3, -2, 11,  2, -3], // W
        [-2, -2, -2, -3, -2, -1, -2, -3,  2, -1, -1, -2, -1,  3, -3, -2, -2,  2,  7, -1], // Y
        [ 0, -3, -3, -3, -1, -2, -2, -3, -3,  3,  1, -2,  1, -1, -2, -2,  0, -3, -1,  4], // V
    ]
    
    private static let indexMap: [Character: Int] = {
        var m: [Character: Int] = [:]
        for (i, aa) in aaOrder.enumerated() { m[aa] = i }
        return m
    }()
    
    /// Return BLOSUM62 score for two amino acids
    static func score(_ a: Character, _ b: Character) -> Int {
        let aa = Character(String(a).uppercased())
        let bb = Character(String(b).uppercased())
        // Stop codons: identical * matches, otherwise large penalty
        if aa == "*" || bb == "*" {
            return aa == bb ? 1 : -4
        }
        guard let i = indexMap[aa], let j = indexMap[bb] else { return -4 }
        return matrix[i][j]
    }
    
    /// Classify the relationship between two aligned amino acids
    static func matchSymbol(_ a: Character, _ b: Character) -> Character {
        let aa = Character(String(a).uppercased())
        let bb = Character(String(b).uppercased())
        if aa == bb { return "*" }   // identical (including * == *)
        if aa == "*" || bb == "*" { return " " }  // stop vs non-stop = no similarity
        let s = score(aa, bb)
        if s > 0 { return ":" }      // conservative
        if s == 0 { return "." }     // semi-conservative
        return " "                    // no similarity
    }
}

// MARK: - Protein Aligner (Smith-Waterman with affine gaps)

struct ProteinAlignmentResult {
    let alignedSeq1: [Character]
    let alignedSeq2: [Character]
    let matches: Int
    let conservative: Int
    let semiConservative: Int
    let alignmentLength: Int
    let identity: Double
    let similarity: Double
}

class ProteinAligner {
    private let gapOpen: Int = -10
    private let gapExtend: Int = -1
    
    func align(seq1: String, seq2: String) -> ProteinAlignmentResult {
        let s1 = Array(seq1.uppercased().filter { $0.isLetter || $0 == "*" })
        let s2 = Array(seq2.uppercased().filter { $0.isLetter || $0 == "*" })
        
        let m = s1.count
        let n = s2.count
        
        guard m > 0, n > 0 else {
            return ProteinAlignmentResult(alignedSeq1: [], alignedSeq2: [],
                                          matches: 0, conservative: 0, semiConservative: 0,
                                          alignmentLength: 0, identity: 0, similarity: 0)
        }
        
        // Smith-Waterman with affine gap penalties
        // H = match/mismatch matrix, E = gap in seq1, F = gap in seq2
        var H = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        var E = Array(repeating: Array(repeating: Int.min / 2, count: n + 1), count: m + 1)
        var F = Array(repeating: Array(repeating: Int.min / 2, count: n + 1), count: m + 1)
        
        var maxScore = 0
        var maxI = 0, maxJ = 0
        
        for i in 1...m {
            for j in 1...n {
                let sub = BLOSUM62.score(s1[i-1], s2[j-1])
                
                E[i][j] = max(E[i][j-1] + gapExtend,
                              H[i][j-1] + gapOpen + gapExtend)
                F[i][j] = max(F[i-1][j] + gapExtend,
                              H[i-1][j] + gapOpen + gapExtend)
                
                H[i][j] = max(0,
                              H[i-1][j-1] + sub,
                              E[i][j],
                              F[i][j])
                
                if H[i][j] > maxScore {
                    maxScore = H[i][j]
                    maxI = i
                    maxJ = j
                }
            }
        }
        
        // Traceback
        var aligned1: [Character] = []
        var aligned2: [Character] = []
        var i = maxI, j = maxJ
        
        while i > 0 && j > 0 && H[i][j] > 0 {
            if H[i][j] == H[i-1][j-1] + BLOSUM62.score(s1[i-1], s2[j-1]) {
                aligned1.append(s1[i-1])
                aligned2.append(s2[j-1])
                i -= 1
                j -= 1
            } else if H[i][j] == F[i][j] {
                aligned1.append(s1[i-1])
                aligned2.append("-")
                i -= 1
            } else {
                aligned1.append("-")
                aligned2.append(s2[j-1])
                j -= 1
            }
        }
        
        aligned1.reverse()
        aligned2.reverse()
        
        // Count matches and conservative substitutions
        var matches = 0, conservative = 0, semiConservative = 0
        let alignLen = aligned1.count
        for k in 0..<alignLen {
            let a = aligned1[k], b = aligned2[k]
            if a == "-" || b == "-" { continue }
            let sym = BLOSUM62.matchSymbol(a, b)
            if sym == "*" { matches += 1 }
            else if sym == ":" { conservative += 1 }
            else if sym == "." { semiConservative += 1 }
        }
        
        let identity = alignLen > 0 ? Double(matches) / Double(alignLen) * 100.0 : 0
        let similarity = alignLen > 0 ? Double(matches + conservative) / Double(alignLen) * 100.0 : 0
        
        return ProteinAlignmentResult(
            alignedSeq1: aligned1, alignedSeq2: aligned2,
            matches: matches, conservative: conservative, semiConservative: semiConservative,
            alignmentLength: alignLen, identity: identity, similarity: similarity
        )
    }
}

// MARK: - Protein Alignment Text View (NSTextView wrapper)

struct ProteinAlignmentTextView: NSViewRepresentable {
    let attributedString: NSAttributedString
    
    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
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

struct AlignTwoProteinSequencesView: View {
    @EnvironmentObject var sequenceManager: SequenceManager
    
    // Sequence selection
    @State private var seq1Index: Int = 0
    @State private var seq2Index: Int = 1
    
    // Alignment
    @State private var isAligning = false
    @State private var alignmentResult: ProteinAlignmentResult?
    @State private var alignmentAttrString: NSAttributedString?
    @State private var highlightDifferences = false
    @State private var colorCoded = true
    @State private var showLongAlignmentWarning = false
    @State private var pendingAlignment: Bool = false
    
    // Display
    @State private var screenFontSize: CGFloat = 12
    @State private var printFontSize: CGFloat = 8
    
    private let charsPerLine = 60
    private let longAlignmentThreshold = 10_000_000  // lower than DNA since proteins are shorter
    
    var body: some View {
        VStack(spacing: 0) {
            controlsSection
            Divider()
            toolRow
            Divider()
            resultArea
            Divider()
            footerSection
        }
        .frame(minWidth: 800, minHeight: 500)
        .alert("Long Alignment Warning", isPresented: $showLongAlignmentWarning) {
            Button("Continue", role: .destructive) {
                if pendingAlignment { executeAlignment() }
                pendingAlignment = false
            }
            Button("Cancel", role: .cancel) {
                pendingAlignment = false
            }
        } message: {
            let seqs = sequenceManager.proteinSequences
            let len1 = seq1Index < seqs.count ? seqs[seq1Index].length : 0
            let len2 = seq2Index < seqs.count ? seqs[seq2Index].length : 0
            Text("Aligning \(len1) aa \u{00D7} \(len2) aa sequences may take a long time. Continue?")
        }
    }
    
    // MARK: - Controls
    
    private var controlsSection: some View {
        HStack(alignment: .top, spacing: 16) {
            // Protein 1
            VStack(alignment: .leading, spacing: 4) {
                Text("Protein 1").font(.caption).fontWeight(.semibold)
                
                Picker("", selection: $seq1Index) {
                    ForEach(0..<max(1, sequenceManager.proteinSequences.count), id: \.self) { idx in
                        if idx < sequenceManager.proteinSequences.count {
                            let prot = sequenceManager.proteinSequences[idx]
                            Text("\(prot.name) (\(prot.length) aa)")
                                .tag(idx)
                        }
                    }
                }
                .frame(maxWidth: 280)
                .contextHelp("alignProt.proteinPicker")
                
                if seq1Index < sequenceManager.proteinSequences.count {
                    let prot = sequenceManager.proteinSequences[seq1Index]
                    Text("\(prot.length) aa, MW: \(prot.formattedMW)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            
            // Protein 2
            VStack(alignment: .leading, spacing: 4) {
                Text("Protein 2").font(.caption).fontWeight(.semibold)
                
                Picker("", selection: $seq2Index) {
                    ForEach(0..<max(1, sequenceManager.proteinSequences.count), id: \.self) { idx in
                        if idx < sequenceManager.proteinSequences.count {
                            let prot = sequenceManager.proteinSequences[idx]
                            Text("\(prot.name) (\(prot.length) aa)")
                                .tag(idx)
                        }
                    }
                }
                .frame(maxWidth: 280)
                .contextHelp("alignProt.proteinPicker")
                
                if seq2Index < sequenceManager.proteinSequences.count {
                    let prot = sequenceManager.proteinSequences[seq2Index]
                    Text("\(prot.length) aa, MW: \(prot.formattedMW)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // Align button
            VStack(alignment: .trailing, spacing: 6) {
                Button("Align") {
                    runAlignment()
                }
                .controlSize(.regular)
                .keyboardShortcut(.return, modifiers: .command)
                .contextHelp("alignProt.align")
                
                Text("BLOSUM62")
                    .font(.caption)
                    .foregroundColor(.secondary)
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
                .contextHelp("alignProt.highlightDiffs")
            
            Divider().frame(height: 16)
            
            Toggle("Color coded", isOn: $colorCoded)
                .toggleStyle(.checkbox).font(.caption)
                .onChange(of: colorCoded) { _ in rerender() }
                .contextHelp("alignProt.colorCoded")
            
            if colorCoded {
                Divider().frame(height: 16)
                legendItem("Aliphatic", .primary)
                legendItem("Aromatic", .purple)
                legendItem("Acidic", .red)
                legendItem("Basic", .blue)
                legendItem("Polar", .green)
            }
            
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
    
    private func legendItem(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 2) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 9)).foregroundColor(.secondary)
        }
    }
    
    // MARK: - Result Area
    
    private var resultArea: some View {
        Group {
            if isAligning {
                VStack {
                    Spacer()
                    ProgressView("Aligning protein sequences...")
                    Spacer()
                }
            } else if let attrStr = alignmentAttrString {
                ProteinAlignmentTextView(attributedString: attrStr)
            } else {
                VStack {
                    Spacer()
                    Text("ALIGN PROTEIN SEQUENCES")
                        .font(.system(size: 28, weight: .bold))
                        .italic()
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("Select two protein sequences and click Align")
                        .font(.callout)
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
                .contextHelp("alignProt.screenFontSize")
            }
            
            HStack(spacing: 4) {
                Text("Print size").font(.caption)
                Picker("", selection: $printFontSize) {
                    ForEach([6, 7, 8, 9, 10, 11, 12] as [CGFloat], id: \.self) { s in
                        Text("\(Int(s)) pts").tag(s)
                    }
                }
                .frame(width: 65).font(.caption)
                .contextHelp("alignProt.printFontSize")
            }
            
            Spacer()
            
            if let result = alignmentResult {
                Text(String(format: "%.1f%% identity, %.1f%% similarity",
                            result.identity, result.similarity))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Button("Copy to ClipBoard") { copyToClipboard() }
                .controlSize(.small)
                .contextHelp("alignProt.copyClipboard")
            
            Button("Print") { printAlignment() }
                .controlSize(.small)
                .contextHelp("alignProt.print")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    // MARK: - Run Alignment
    
    private func runAlignment() {
        let seqs = sequenceManager.proteinSequences
        guard seqs.count >= 2,
              seq1Index < seqs.count,
              seq2Index < seqs.count else { return }
        
        let len1 = seqs[seq1Index].length
        let len2 = seqs[seq2Index].length
        guard len1 > 0, len2 > 0 else { return }
        
        if len1 * len2 > longAlignmentThreshold {
            pendingAlignment = true
            showLongAlignmentWarning = true
            return
        }
        
        executeAlignment()
    }
    
    private func executeAlignment() {
        let seqs = sequenceManager.proteinSequences
        guard seq1Index < seqs.count, seq2Index < seqs.count else { return }
        
        let s1 = seqs[seq1Index].sequence
        let s2 = seqs[seq2Index].sequence
        
        isAligning = true
        
        DispatchQueue.global(qos: .userInitiated).async {
            let aligner = ProteinAligner()
            let result = aligner.align(seq1: s1, seq2: s2)
            let rendered = renderAlignment(result)
            DispatchQueue.main.async {
                alignmentResult = result
                alignmentAttrString = rendered
                isAligning = false
            }
        }
    }
    
    // MARK: - Render Alignment
    
    private func renderAlignment(_ result: ProteinAlignmentResult, fontSize: CGFloat? = nil) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let useFontSize = fontSize ?? screenFontSize
        let font = NSFont.monospacedSystemFont(ofSize: useFontSize, weight: .regular)
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let matchAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let gapAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let diffBgColor = NSColor(calibratedRed: 1.0, green: 0.85, blue: 0.85, alpha: 1.0)
        
        let al1 = result.alignedSeq1
        let al2 = result.alignedSeq2
        let totalLen = al1.count
        
        guard totalLen > 0 else {
            output.append(NSAttributedString(string: "No alignment found.\n", attributes: labelAttrs))
            return output
        }
        
        // Header
        let seqs = sequenceManager.proteinSequences
        let name1 = seq1Index < seqs.count ? seqs[seq1Index].name : "Seq 1"
        let name2 = seq2Index < seqs.count ? seqs[seq2Index].name : "Seq 2"
        let len1 = seq1Index < seqs.count ? seqs[seq1Index].length : 0
        let len2 = seq2Index < seqs.count ? seqs[seq2Index].length : 0
        let headerStr = "Protein Alignment: \(name1) (\(len1) aa) vs \(name2) (\(len2) aa)\n"
            + "Matrix: BLOSUM62 | Gap open: -10, Gap extend: -1\n\n"
        output.append(NSAttributedString(string: headerStr, attributes: labelAttrs))
        
        // Display in blocks
        var pos1 = 1, pos2 = 1
        let pad = String(repeating: " ", count: 13)
        
        var offset = 0
        while offset < totalLen {
            let end = min(offset + charsPerLine, totalLen)
            let chunk1 = Array(al1[offset..<end])
            let chunk2 = Array(al2[offset..<end])
            
            let bases1 = chunk1.filter { $0 != "-" }.count
            let bases2 = chunk2.filter { $0 != "-" }.count
            
            let startPos1 = pos1
            let endPos1 = bases1 > 0 ? pos1 + bases1 - 1 : pos1 - 1
            let startPos2 = pos2
            let endPos2 = bases2 > 0 ? pos2 + bases2 - 1 : pos2 - 1
            
            // --- Seq 1 line ---
            let label1 = "Seq_1".padding(toLength: 7, withPad: " ", startingAt: 0)
                       + String(startPos1).padding(toLength: 6, withPad: " ", startingAt: 0)
            output.append(NSAttributedString(string: label1, attributes: labelAttrs))
            
            appendProteinChunk(to: output, chunk: chunk1, otherChunk: chunk2,
                               font: font, gapAttrs: gapAttrs, diffBgColor: diffBgColor,
                               isHighlighting: highlightDifferences)
            output.append(NSAttributedString(string: "    \(max(0, endPos1))\n", attributes: labelAttrs))
            
            // --- Match line (* : . or space) ---
            output.append(NSAttributedString(string: pad, attributes: matchAttrs))
            for idx in 0..<chunk1.count {
                let c1 = chunk1[idx], c2 = chunk2[idx]
                if c1 == "-" || c2 == "-" {
                    output.append(NSAttributedString(string: " ", attributes: matchAttrs))
                } else {
                    let sym = BLOSUM62.matchSymbol(c1, c2)
                    let symColor: NSColor
                    switch sym {
                    case "*": symColor = NSColor.black          // identical
                    case ":": symColor = NSColor.darkGray       // conservative
                    case ".": symColor = NSColor.lightGray       // semi-conservative
                    default:  symColor = NSColor.white           // mismatch (invisible)
                    }
                    let symAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: symColor]
                    output.append(NSAttributedString(string: String(sym), attributes: symAttrs))
                }
            }
            output.append(NSAttributedString(string: "\n", attributes: matchAttrs))
            
            // --- Seq 2 line ---
            let label2 = "Seq_2".padding(toLength: 7, withPad: " ", startingAt: 0)
                       + String(startPos2).padding(toLength: 6, withPad: " ", startingAt: 0)
            output.append(NSAttributedString(string: label2, attributes: labelAttrs))
            
            appendProteinChunk(to: output, chunk: chunk2, otherChunk: chunk1,
                               font: font, gapAttrs: gapAttrs, diffBgColor: diffBgColor,
                               isHighlighting: highlightDifferences)
            output.append(NSAttributedString(string: "    \(max(0, endPos2))\n", attributes: labelAttrs))
            
            // Blank line between blocks
            output.append(NSAttributedString(string: "\n", attributes: labelAttrs))
            
            pos1 += bases1
            pos2 += bases2
            offset = end
        }
        
        // Summary
        let summaryStr = "\nSeq 1: \(name1) — \(len1) aa total\n"
            + "Seq 2: \(name2) — \(len2) aa total\n"
            + String(format: "Alignment: %d identical, %d conservative, %d semi-conservative out of %d positions\n",
                                result.matches, result.conservative, result.semiConservative, result.alignmentLength)
            + String(format: "Identity: %.1f%%  |  Similarity: %.1f%%\n", result.identity, result.similarity)
            + "Key: * identical  : conservative  . semi-conservative\n"
        output.append(NSAttributedString(string: summaryStr, attributes: labelAttrs))
        
        return output
    }
    
    /// Append a chunk of protein sequence characters with optional colour coding and diff highlighting
    private func appendProteinChunk(
        to output: NSMutableAttributedString,
        chunk: [Character], otherChunk: [Character],
        font: NSFont,
        gapAttrs: [NSAttributedString.Key: Any],
        diffBgColor: NSColor,
        isHighlighting: Bool
    ) {
        for (i, ch) in chunk.enumerated() {
            if ch == "-" {
                output.append(NSAttributedString(string: "-", attributes: gapAttrs))
            } else {
                let textColor: NSColor
                if ch == "*" {
                    textColor = .red  // stop codon always red
                } else {
                    textColor = colorCoded ? nsColorForAA(ch) : NSColor.labelColor
                }
                var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
                
                // Highlight differences
                if isHighlighting && i < otherChunk.count && otherChunk[i] != "-" {
                    let upper1 = Character(String(ch).uppercased())
                    let upper2 = Character(String(otherChunk[i]).uppercased())
                    if upper1 != upper2 {
                        attrs[.backgroundColor] = diffBgColor
                    }
                }
                
                output.append(NSAttributedString(string: String(ch), attributes: attrs))
            }
        }
    }
    
    /// NSColor version of amino acid property colouring
    private func nsColorForAA(_ aa: Character) -> NSColor {
        switch Character(String(aa).uppercased()) {
        case "G", "A", "V", "L", "I", "P": return NSColor.labelColor
        case "F", "W", "Y":                 return NSColor.purple
        case "D", "E":                       return NSColor.red
        case "K", "R", "H":                  return NSColor.blue
        case "S", "T", "N", "Q":             return NSColor(red: 0.0, green: 0.6, blue: 0.0, alpha: 1.0)
        case "C":                             return NSColor(red: 0.7, green: 0.6, blue: 0.0, alpha: 1.0)
        case "M":                             return NSColor.orange
        case "*":                             return NSColor.red
        default:                              return NSColor.secondaryLabelColor
        }
    }
    
    // MARK: - Re-render
    
    private func rerender() {
        if let result = alignmentResult {
            alignmentAttrString = renderAlignment(result)
        }
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

class AlignTwoProteinSequencesWindowManager {
    static let shared = AlignTwoProteinSequencesWindowManager()
    
    private var windows: [NSWindow] = []
    private init() {}
    
    func openWindow(sequenceManager: SequenceManager) {
        let view = AlignTwoProteinSequencesView()
            .environmentObject(sequenceManager)
        
        let hostingController = NSHostingController(rootView: view)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 550),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        window.title = "Align Two Protein Sequences"
        window.contentViewController = hostingController
        window.setFrameAutosaveName("AlignTwoProteinSequences")
        if !window.setFrameUsingName(window.frameAutosaveName) { window.center() }
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 750, height: 400)
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

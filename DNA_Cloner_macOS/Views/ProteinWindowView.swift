//
//  ProteinWindowView.swift
//  Cloner 64
//
//  A Serial Cloner-style protein sequence viewer window.
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ProteinWindowView: View {
    @ObservedObject var protein: ProteinSequence
    @EnvironmentObject var sequenceManager: SequenceManager
    
    @State private var selectedTab = 0
    @State private var copiedField: String?
    @State private var selectionStart: Int = 0
    @State private var selectionEnd: Int = 0
    
    // Lock state — unlocked for empty sequences
    @State private var isLocked: Bool = true
    @State private var showLockedWarning: Bool = false
    
    // Find drawer
    @State private var showFindDrawer: Bool = false
    @State private var findText: String = ""
    @State private var currentHitIndex: Int = 0
    
    // Dynamic layout
    @State private var dynamicAAsPerLine: Int = 60
    @State private var sequenceFontSize: CGFloat = 12
    @State private var colorCoded: Bool = true
    
    // Save confirmation
    @State private var showSaveConfirm: Bool = false
    
    private let blockSize = 10
    
    var body: some View {
        HStack(spacing: 0) {
            // Main window content
            VStack(spacing: 0) {
                // Top info bar
                infoBar
                
                Divider()
                
                // Tab selector
                Picker("", selection: $selectedTab) {
                    Text("Sequence").tag(0)
                    Text("Features").tag(1)
                    Text("Properties").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                
                // Tab content
                switch selectedTab {
                case 0: sequenceTab
                case 1: featuresTab
                case 2: propertiesTab
                default: sequenceTab
                }
                
                Divider()
                
                // Bottom button row
                buttonRow
            }
            
            // Find Drawer (slides out on right)
            if showFindDrawer {
                Divider()
                proteinFindDrawer
                    .frame(width: 260)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showFindDrawer)
        .frame(minWidth: 600, minHeight: 400)
        .background(ProteinWindowCloseGuard(protein: protein, sequenceManager: sequenceManager))
        .alert("Sequence is Locked", isPresented: $showLockedWarning) {
            Button("OK") {}
        } message: {
            Text("Unlock the sequence to make edits (uncheck the Locked checkbox).")
        }
        .onAppear {
            sequenceManager.currentProtein = protein
            isLocked = !protein.sequence.isEmpty
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            sequenceManager.currentProtein = protein
            sequenceManager.currentSequence = nil
        }
    }
    
    // MARK: - Info Bar
    
    private var infoBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                ProteinHelixIcon()
                    .frame(width: 22, height: 16)
                TextField("Name", text: $protein.name)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .frame(maxWidth: 200)
                    .disabled(isLocked)
            }
            
            Divider().frame(height: 20)
            
            Text("\(protein.length) aa")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Divider().frame(height: 20)
            
            Text("MW: \(protein.formattedMW)")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Divider().frame(height: 20)
            
            Text("pI: \(protein.formattedPI)")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            if protein.isCircular {
                Divider().frame(height: 20)
                Text("Circular")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.2))
                    .cornerRadius(4)
            }
            
            Spacer()
            
            Toggle(isOn: $isLocked) {
                Text("Locked")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            
            if !protein.features.isEmpty {
                Text("\(protein.features.count) features")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    // MARK: - Button Row
    
    private var buttonRow: some View {
        HStack(spacing: 8) {
            Button("Save") { showSaveConfirm = true }
                .controlSize(.small)
                .alert("Save Protein Sequence?", isPresented: $showSaveConfirm) {
                    Button("Save", role: .destructive) { sequenceManager.saveProtein(protein) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will overwrite the original file. This action cannot be undone.")
                }
            
            Button("Save As...") { sequenceManager.saveProteinAs(protein) }
                .controlSize(.small)
            
            if protein.isDirty {
                Label("Unsaved changes", systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .transition(.opacity)
            }
            
            Spacer()
            
            // Font size controls
            HStack(spacing: 4) {
                Text("Font:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button(action: { sequenceFontSize = max(8, sequenceFontSize - 1) }) {
                    Image(systemName: "minus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                Text("\(Int(sequenceFontSize))")
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 20)
                Button(action: { sequenceFontSize = min(24, sequenceFontSize + 1) }) {
                    Image(systemName: "plus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            
            Text("\(dynamicAAsPerLine) aa/line")
                .font(.caption).foregroundColor(.secondary)
            
            Button(action: { withAnimation { showFindDrawer.toggle() } }) {
                Label("Find", systemImage: "magnifyingglass")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(.windowBackgroundColor))
    }
    
    // MARK: - Sequence Tab
    
    private var sequenceTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Color key
            colorLegend
            
            Divider()
            
            // Selection info
            if selectionStart < selectionEnd {
                HStack {
                    let len = selectionEnd - selectionStart
                    Text("Selection: \(selectionStart + 1)-\(selectionEnd) (\(len) aa)")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
                Divider()
            }
            
            // Interactive sequence editor
            GeometryReader { geometry in
                let computed = computeAAsPerLine(availableWidth: geometry.size.width)
                ScrollView {
                    ProteinSequenceTextView(
                        protein: protein,
                        selectionStart: $selectionStart,
                        selectionEnd: $selectionEnd,
                        aasPerLine: computed,
                        isLocked: isLocked,
                        fontSize: sequenceFontSize,
                        showLockedWarning: $showLockedWarning,
                        findHighlights: findHitPositions,
                        colorCoded: colorCoded
                    )
                    .padding(8)
                }
                .background(Color(.textBackgroundColor))
                .onAppear { dynamicAAsPerLine = computed }
                .onChange(of: geometry.size.width) { _ in
                    dynamicAAsPerLine = computeAAsPerLine(availableWidth: geometry.size.width)
                }
                .onChange(of: sequenceFontSize) { _ in
                    dynamicAAsPerLine = computeAAsPerLine(availableWidth: geometry.size.width)
                }
            }
            .frame(minHeight: 120)
        }
    }
    
    private func computeAAsPerLine(availableWidth: CGFloat) -> Int {
        let lineNumberWidth: CGFloat = sequenceFontSize * 5 + 6
        let font = NSFont.monospacedSystemFont(ofSize: sequenceFontSize, weight: .regular)
        let charWidth = font.advancement(forGlyph: font.glyph(withName: "A")).width
        let groupSpaceWidth: CGFloat = 5.0
        let padding: CGFloat = 28
        
        let usable = availableWidth - lineNumberWidth - padding
        guard usable > 0 else { return 10 }
        
        let groupWidth = CGFloat(blockSize) * charWidth + groupSpaceWidth
        let numGroups = Int((usable + groupSpaceWidth) / groupWidth)
        return max(10, numGroups * blockSize)
    }
    
    // MARK: - Color Legend
    
    private var colorLegend: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $colorCoded) {
                Text("Color")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            
            if colorCoded {
                legendItem("Aliphatic", "GAVILP", .primary)
                legendItem("Aromatic", "FWY", .purple)
                legendItem("Acidic", "DE", .red)
                legendItem("Basic", "KRH", .blue)
                legendItem("Polar", "STNQ", .green)
                legendItem("Cys", "C", .yellow)
                legendItem("Met", "M", .orange)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
    
    private func legendItem(_ label: String, _ residues: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Text(residues)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(color)
                .fontWeight(.bold)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - Find Drawer
    
    private var proteinFindDrawer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Find")
                    .font(.headline)
                Spacer()
                Button(action: { withAnimation { showFindDrawer = false } }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Amino acid sequence")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                TextField("e.g. MKWVTF", text: $findText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                
                if !findText.isEmpty {
                    let hits = findHits
                    if hits.isEmpty {
                        Text("No matches found")
                            .font(.caption)
                            .foregroundColor(.red)
                    } else {
                        HStack {
                            Text("\(hits.count) match\(hits.count == 1 ? "" : "es")")
                                .font(.caption)
                                .foregroundColor(.green)
                            
                            Spacer()
                            
                            Button(action: { navigateHit(delta: -1) }) {
                                Image(systemName: "chevron.up")
                            }
                            .buttonStyle(.borderless)
                            .disabled(hits.count <= 1)
                            
                            Text("\(currentHitIndex + 1)/\(hits.count)")
                                .font(.system(.caption, design: .monospaced))
                            
                            Button(action: { navigateHit(delta: 1) }) {
                                Image(systemName: "chevron.down")
                            }
                            .buttonStyle(.borderless)
                            .disabled(hits.count <= 1)
                        }
                    }
                }
                
                Button("Clear") {
                    findText = ""
                    currentHitIndex = 0
                }
                .controlSize(.small)
                .disabled(findText.isEmpty)
            }
            .padding(12)
            
            Spacer()
        }
        .background(Color(.windowBackgroundColor))
    }
    
    private func navigateHit(delta: Int) {
        let hits = findHits
        guard !hits.isEmpty else { return }
        currentHitIndex = (currentHitIndex + delta + hits.count) % hits.count
        let pos = hits[currentHitIndex]
        selectionStart = pos
        selectionEnd = pos + findText.count
    }
    
    // MARK: - Search Logic
    
    private var findHits: [Int] {
        let s = findText.uppercased()
        guard !s.isEmpty else { return [] }
        let seq = protein.sequence.uppercased()
        var positions: [Int] = []
        var searchIdx = seq.startIndex
        while let range = seq.range(of: s, range: searchIdx..<seq.endIndex) {
            positions.append(seq.distance(from: seq.startIndex, to: range.lowerBound))
            searchIdx = seq.index(after: range.lowerBound)
        }
        return positions
    }
    
    private var findHitPositions: Set<Int> {
        let s = findText.uppercased()
        guard !s.isEmpty else { return [] }
        var set = Set<Int>()
        for pos in findHits {
            for i in pos..<(pos + s.count) {
                set.insert(i)
            }
        }
        return set
    }
    
    // MARK: - Features Tab
    
    private var featuresTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            if protein.features.isEmpty {
                VStack {
                    Spacer()
                    Text("No features")
                        .font(.title3)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(protein.features) { feat in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(feat.color.color)
                                .frame(width: 10, height: 10)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(feat.name)
                                    .font(.callout)
                                    .fontWeight(.medium)
                                HStack(spacing: 8) {
                                    Text(feat.type.rawValue)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text("\(feat.start)-\(feat.end)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(feat.strand == .forward ? "\u{2192}" : "\u{2190}")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    let len = feat.end >= feat.start ? feat.end - feat.start + 1 : 0
                                    Text("\(len) aa")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }
    
    // MARK: - Properties Tab
    
    private var propertiesTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Protein Properties") {
                    VStack(alignment: .leading, spacing: 8) {
                        propRow("Name:", protein.name)
                        propRow("Length:", "\(protein.length) amino acids")
                        propRow("Molecular Weight:", protein.formattedMW)
                            .contextHelp("prot.molecularWeight")
                        propRow("Isoelectric Point (pI):", protein.formattedPI)
                            .contextHelp("prot.isoelectricPoint")
                        propRow("Extinction Coeff. (280nm):",
                                String(format: "%.0f M\u{207B}\u{00B9}cm\u{207B}\u{00B9}", protein.extinctionCoefficient))
                            .contextHelp("prot.extinctionCoeff")
                        if protein.extinctionCoefficient > 0 {
                            let mw = protein.molecularWeight
                            let abs01 = protein.extinctionCoefficient / (mw * 10.0)
                            propRow("Abs 0.1% (1 mg/mL):", String(format: "%.3f", abs01))
                                .contextHelp("prot.abs01")
                        }
                        if protein.isCircular {
                            propRow("Topology:", "Circular")
                        }
                    }
                    .padding(4)
                }
                .contextHelp("prot.properties")
                
                GroupBox("Amino Acid Composition") {
                    VStack(alignment: .leading, spacing: 8) {
                        colorLegend
                        
                        let comp = protein.composition
                        LazyVGrid(columns: [
                            GridItem(.fixed(40)),
                            GridItem(.fixed(60)),
                            GridItem(.fixed(80)),
                            GridItem(.flexible(minimum: 60))
                        ], alignment: .leading, spacing: 4) {
                            Text("AA").font(.caption).fontWeight(.bold).foregroundColor(.secondary)
                            Text("Count").font(.caption).fontWeight(.bold).foregroundColor(.secondary)
                            Text("Percent").font(.caption).fontWeight(.bold).foregroundColor(.secondary)
                            Text("").font(.caption)
                            
                            ForEach(comp, id: \.aa) { item in
                                Text(item.aa)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(aaColor(Character(item.aa)))
                                    .fontWeight(.semibold)
                                Text("\(item.count)")
                                    .font(.caption)
                                Text(String(format: "%.1f%%", item.percent))
                                    .font(.caption)
                                GeometryReader { geo in
                                    Rectangle()
                                        .fill(aaColor(Character(item.aa)).opacity(0.5))
                                        .frame(width: geo.size.width * CGFloat(item.percent / 100.0),
                                               height: 10)
                                }
                                .frame(height: 10)
                            }
                        }
                        .padding(4)
                    }
                }
                .contextHelp("prot.composition")
                
                GroupBox("Charge Summary") {
                    let upper = protein.sequence.uppercased()
                    let nD = upper.filter { $0 == "D" }.count
                    let nE = upper.filter { $0 == "E" }.count
                    let nK = upper.filter { $0 == "K" }.count
                    let nR = upper.filter { $0 == "R" }.count
                    let nH = upper.filter { $0 == "H" }.count
                    VStack(alignment: .leading, spacing: 4) {
                        propRow("Negatively charged (D+E):", "\(nD + nE)")
                        propRow("Positively charged (K+R):", "\(nK + nR)")
                        propRow("Histidine (H):", "\(nH)")
                        propRow("Total charged:", "\(nD + nE + nK + nR + nH)")
                    }
                    .padding(4)
                }
                .contextHelp("prot.chargeSummary")
            }
            .padding(12)
        }
    }
    
    private func propRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundColor(.secondary)
                .frame(width: 200, alignment: .trailing)
            Text(value)
                .font(.callout)
                .fontWeight(.medium)
                .textSelection(.enabled)
            Spacer()
        }
    }
    
    // MARK: - Amino Acid Color (shared)
    
    static func aaColor(_ aa: Character) -> Color {
        switch aa {
        case "G", "A", "V", "L", "I", "P":      return .primary
        case "F", "W", "Y":                       return Color.purple
        case "D", "E":                             return Color.red
        case "K", "R", "H":                        return Color.blue
        case "S", "T", "N", "Q":                   return Color.green
        case "C":                                   return Color.yellow
        case "M":                                   return Color.orange
        case "*":                                   return Color.red
        default:                                    return .secondary
        }
    }
    
    private func aaColor(_ aa: Character) -> Color {
        Self.aaColor(aa)
    }
}


// MARK: - Protein Sequence Text View (interactive editor)

struct ProteinSequenceTextView: View {
    @ObservedObject var protein: ProteinSequence
    @Binding var selectionStart: Int
    @Binding var selectionEnd: Int
    var aasPerLine: Int = 60
    var isLocked: Bool = false
    var fontSize: CGFloat = 12
    @Binding var showLockedWarning: Bool
    var findHighlights: Set<Int> = []
    var colorCoded: Bool = true
    
    @State private var firstClick: Int?
    @EnvironmentObject var sequenceManager: SequenceManager
    
    private let aasPerGroup = 10
    private var seqString: String { protein.sequence }
    
    private var measuredCharWidth: CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        return font.advancement(forGlyph: font.glyph(withName: "A")).width
    }
    
    private var measuredLineHeight: CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        return ceil(font.ascender - font.descender + font.leading) + 2
    }
    
    private let groupSpaceWidth: CGFloat = 5.0
    
    // Valid amino acid characters for input
    private let validAA = Set("ACDEFGHIKLMNPQRSTVWYXBZJUOacdefghiklmnpqrstvwyxbzjuo*-")
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(0..<numberOfLines, id: \.self) { lineIndex in
                HStack(spacing: 0) {
                    Text(String(format: "%6d", lineIndex * aasPerLine + 1))
                        .font(.system(size: fontSize, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: fontSize * 5, alignment: .trailing)
                        .padding(.trailing, 6)
                    
                    HStack(spacing: 0) {
                        ForEach(0..<aasInLine(lineIndex), id: \.self) { aaIndex in
                            let position = lineIndex * aasPerLine + aaIndex
                            characterView(at: position)
                            
                            if (aaIndex + 1) % aasPerGroup == 0 && aaIndex + 1 < aasInLine(lineIndex) {
                                groupSpacer(beforePosition: position, afterPosition: position + 1)
                            }
                        }
                        
                        // Cursor-after-last on the final line
                        if lineIndex == numberOfLines - 1 {
                            endCursorView
                        }
                    }
                    .drawingGroup()
                }
                .id(lineIndex)
            }
        }
        .contextMenu {
            Button("Select All") { selectAll() }
            Divider()
            Button("Copy") { doCopy() }
                .disabled(selectionStart >= selectionEnd)
            Button("Cut") { doCut() }
                .disabled(isLocked || selectionStart >= selectionEnd)
            Button("Paste") { doPaste() }
                .disabled(isLocked)
            Divider()
            Button("UPPERCASE") { doUppercase() }
                .disabled(isLocked || selectionStart >= selectionEnd)
            Button("lowercase") { doLowercase() }
                .disabled(isLocked || selectionStart >= selectionEnd)
        }
        .overlay(
            MouseTrackingOverlay(
                onMouseDown: { location, modifiers in
                    if let position = positionFromPoint(location) {
                        let pos = min(position, seqString.count)
                        if modifiers.contains(.command) && selectionStart < selectionEnd {
                            if pos < selectionStart {
                                selectionStart = pos
                            } else {
                                selectionEnd = min(pos + 1, seqString.count)
                            }
                            firstClick = nil
                        } else {
                            firstClick = pos
                            selectionStart = pos
                            selectionEnd = pos
                        }
                    }
                },
                onMouseDragged: { location, modifiers in
                    if let position = positionFromPoint(location) {
                        let pos = min(position, seqString.count)
                        if let first = firstClick {
                            selectionStart = min(first, pos)
                            selectionEnd = min(max(first, pos) + 1, seqString.count)
                        } else {
                            if pos < selectionStart {
                                selectionStart = pos
                            } else {
                                selectionEnd = min(pos + 1, seqString.count)
                            }
                        }
                    }
                },
                onMouseUp: { _, _ in
                    firstClick = nil
                },
                onCopy: { doCopy() },
                onCut: { doCut() },
                onPaste: { doPaste() },
                onSelectAll: { selectAll() },
                onDelete: { doDelete() },
                onMakeUppercase: { doUppercase() },
                onMakeLowercase: { doLowercase() },
                onInsertText: { text in doInsertText(text) },
                onMoveCursor: { dir in doMoveCursor(dir) },
                onUndo: { /* protein doesn't have undo yet */ },
                onRedo: { /* protein doesn't have undo yet */ }
            )
        )
    }
    
    // MARK: - Edit Actions
    
    private func selectedSubstring() -> String {
        guard selectionStart < selectionEnd, selectionEnd <= seqString.count else { return "" }
        let s = seqString.index(seqString.startIndex, offsetBy: selectionStart)
        let e = seqString.index(seqString.startIndex, offsetBy: selectionEnd)
        return String(seqString[s..<e])
    }
    
    private func selectAll() {
        selectionStart = 0
        selectionEnd = seqString.count
    }
    
    private func doCopy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedSubstring(), forType: .string)
    }
    
    private func doCut() {
        guard !isLocked else { showLockedWarning = true; return }
        doCopy()
        doDelete()
    }
    
    private func doDelete() {
        guard !isLocked else { showLockedWarning = true; return }
        guard selectionStart < selectionEnd || selectionStart > 0 else { return }
        if selectionStart < selectionEnd {
            let before = String(seqString.prefix(selectionStart))
            let after = String(seqString.suffix(from: seqString.index(seqString.startIndex, offsetBy: min(selectionEnd, seqString.count))))
            protein.sequence = before + after
            selectionEnd = selectionStart
        } else if selectionStart > 0 {
            let deletePos = selectionStart - 1
            let before = String(seqString.prefix(deletePos))
            let after = String(seqString.suffix(from: seqString.index(seqString.startIndex, offsetBy: selectionStart)))
            protein.sequence = before + after
            selectionStart = deletePos
            selectionEnd = deletePos
        }
    }
    
    private func doPaste() {
        guard !isLocked else { showLockedWarning = true; return }
        guard let clip = NSPasteboard.general.string(forType: .string) else { return }
        let cleaned = String(clip.filter { validAA.contains($0) })
        guard !cleaned.isEmpty else { return }
        let before = String(seqString.prefix(selectionStart))
        let after = String(seqString.suffix(from: seqString.index(seqString.startIndex, offsetBy: min(selectionEnd, seqString.count))))
        protein.sequence = before + cleaned + after
        selectionStart = selectionStart + cleaned.count
        selectionEnd = selectionStart
    }
    
    private func doInsertText(_ text: String) {
        guard !isLocked else { showLockedWarning = true; return }
        let cleaned = String(text.filter { validAA.contains($0) })
        guard !cleaned.isEmpty else { return }
        let insertPos = selectionStart
        let before = String(seqString.prefix(selectionStart))
        let after = String(seqString.suffix(from: seqString.index(seqString.startIndex, offsetBy: min(selectionEnd, seqString.count))))
        protein.sequence = before + cleaned + after
        selectionStart = insertPos + cleaned.count
        selectionEnd = selectionStart
    }
    
    private func doMoveCursor(_ direction: Int) {
        if direction < 0 {
            let newPos = max(0, selectionStart - 1)
            selectionStart = newPos
            selectionEnd = newPos
        } else {
            let newPos = min(seqString.count, selectionEnd + 1)
            selectionStart = newPos
            selectionEnd = newPos
        }
    }
    
    private func doUppercase() {
        guard !isLocked else { showLockedWarning = true; return }
        guard selectionStart < selectionEnd, selectionEnd <= seqString.count else { return }
        let before = String(seqString.prefix(selectionStart))
        let s = seqString.index(seqString.startIndex, offsetBy: selectionStart)
        let e = seqString.index(seqString.startIndex, offsetBy: selectionEnd)
        let selected = String(seqString[s..<e]).uppercased()
        let after = String(seqString.suffix(from: e))
        protein.sequence = before + selected + after
    }
    
    private func doLowercase() {
        guard !isLocked else { showLockedWarning = true; return }
        guard selectionStart < selectionEnd, selectionEnd <= seqString.count else { return }
        let before = String(seqString.prefix(selectionStart))
        let s = seqString.index(seqString.startIndex, offsetBy: selectionStart)
        let e = seqString.index(seqString.startIndex, offsetBy: selectionEnd)
        let selected = String(seqString[s..<e]).lowercased()
        let after = String(seqString.suffix(from: e))
        protein.sequence = before + selected + after
    }
    
    // MARK: - Rendering
    
    private func groupSpacer(beforePosition: Int, afterPosition: Int) -> some View {
        let bothSelected = beforePosition >= selectionStart && beforePosition < selectionEnd
                        && afterPosition >= selectionStart && afterPosition < selectionEnd
        let bg: Color = bothSelected ? .blue : .clear
        return Rectangle().fill(bg).frame(width: groupSpaceWidth, height: fontSize + 2)
    }
    
    private func positionFromPoint(_ point: CGPoint) -> Int? {
        let charWidth = measuredCharWidth
        let lineHeight = measuredLineHeight
        let lineNumberWidth: CGFloat = fontSize * 5 + 6
        
        let lineNumber = Int(point.y / lineHeight)
        guard lineNumber >= 0 && lineNumber < numberOfLines else { return nil }
        
        let xOffset = point.x - lineNumberWidth
        guard xOffset >= 0 else { return nil }
        
        var charInLine = 0
        var accumulatedX: CGFloat = 0
        let lineAAsCount = aasInLine(lineNumber)
        
        for i in 0..<lineAAsCount {
            let nextX = accumulatedX + charWidth
            if accumulatedX + charWidth * 0.5 > xOffset { break }
            accumulatedX = nextX
            charInLine = i + 1
            if (i + 1) % aasPerGroup == 0 && i + 1 < lineAAsCount {
                accumulatedX += groupSpaceWidth
            }
        }
        
        // Allow clicking past last character on line
        if xOffset > accumulatedX {
            charInLine = lineAAsCount
        }
        
        let position = lineNumber * aasPerLine + min(charInLine, lineAAsCount)
        return min(position, seqString.count)
    }
    
    private var numberOfLines: Int {
        max(1, (seqString.count + aasPerLine - 1) / aasPerLine)
    }
    
    private func aasInLine(_ lineIndex: Int) -> Int {
        let remaining = seqString.count - lineIndex * aasPerLine
        return max(0, min(aasPerLine, remaining))
    }
    
    private func characterView(at position: Int) -> some View {
        guard position < seqString.count else {
            return AnyView(Text(" ").font(.system(size: fontSize, design: .monospaced)))
        }
        let index = seqString.index(seqString.startIndex, offsetBy: position)
        let char = seqString[index]
        let charStr = String(char)
        let isSelected = position >= selectionStart && position < selectionEnd
        let isCursor = (selectionStart == selectionEnd) && position == selectionStart
        let isFindHit = findHighlights.contains(position)
        
        let bg: Color = {
            if isSelected { return .blue }
            if isFindHit { return Color.accentColor.opacity(0.4) }
            return .clear
        }()
        
        let textColor: Color = {
            if isSelected { return .white }
            if isFindHit { return .white }
            return colorCoded ? ProteinWindowView.aaColor(char) : .primary
        }()
        
        return AnyView(
            Text(charStr)
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundColor(textColor)
                .background(bg)
                .overlay(alignment: .leading) {
                    if isCursor {
                        Rectangle()
                            .fill(Color.red)
                            .frame(width: 1.5)
                    }
                }
        )
    }
    
    /// Cursor position after the very last amino acid
    private var endCursorView: some View {
        let isCursorAtEnd = (selectionStart == selectionEnd) && selectionStart == seqString.count
        return Text(" ")
            .font(.system(size: fontSize, design: .monospaced))
            .overlay(alignment: .leading) {
                if isCursorAtEnd {
                    Rectangle()
                        .fill(Color.red)
                        .frame(width: 1.5)
                }
            }
    }
}


// MARK: - Protein Helix Icon

/// A small alpha-helix ribbon icon — single coiling ribbon like a spring
struct ProteinHelixIcon: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let midY = h / 2
            let amplitude = h * 0.34
            let turns: CGFloat = 2.5
            let segments = 100
            
            for i in 0..<segments {
                let t0 = CGFloat(i) / CGFloat(segments)
                let t1 = CGFloat(i + 1) / CGFloat(segments)
                let angle0 = t0 * turns * 2 * .pi
                let angle1 = t1 * turns * 2 * .pi
                
                let x0 = t0 * w
                let x1 = t1 * w
                let y0 = midY - amplitude * sin(angle0)
                let y1 = midY - amplitude * sin(angle1)
                
                let depth = cos(angle0)
                let isFront = depth > 0
                
                let lineWidth: CGFloat = isFront ? 4.0 : 2.5
                let opacity = isFront ? (0.7 + 0.3 * depth) : (0.25 + 0.15 * (1.0 + depth))
                
                var segment = Path()
                segment.move(to: CGPoint(x: x0, y: y0))
                segment.addLine(to: CGPoint(x: x1, y: y1))
                
                context.stroke(segment, with: .color(.green.opacity(opacity)),
                              style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
        }
    }
}


// MARK: - Protein Window Close Guard
/// Invisible NSViewRepresentable that intercepts the protein window close button.
/// If the protein has unsaved changes, shows a Save / Don't Save / Cancel alert.
/// On close, removes the protein from sequenceManager.proteinSequences.
struct ProteinWindowCloseGuard: NSViewRepresentable {
    let protein: ProteinSequence
    let sequenceManager: SequenceManager
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.sequenceManager = sequenceManager
        DispatchQueue.main.async {
            if let window = view.window {
                context.coordinator.attach(to: window, protein: protein)
            }
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.protein = protein
        context.coordinator.sequenceManager = sequenceManager
        if let window = nsView.window, context.coordinator.attachedWindow !== window {
            context.coordinator.attach(to: window, protein: protein)
        }
    }
    
    func makeCoordinator() -> Coordinator { Coordinator() }
    
    class Coordinator: NSObject, NSWindowDelegate {
        var protein: ProteinSequence?
        var sequenceManager: SequenceManager?
        weak var attachedWindow: NSWindow?
        private var originalDelegate: NSWindowDelegate?
        
        func attach(to window: NSWindow, protein: ProteinSequence) {
            self.protein = protein
            if window.delegate !== self {
                self.originalDelegate = window.delegate
                window.delegate = self
            }
            self.attachedWindow = window
        }
        
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard let prot = protein, prot.isDirty else { return true }
            
            let alert = NSAlert()
            alert.messageText = "Do you want to save changes to \"\(prot.name)\"?"
            alert.informativeText = "Your changes will be lost if you don't save them."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")
            
            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                if let mgr = sequenceManager {
                    if prot.sourceURL != nil {
                        mgr.saveProtein(prot)
                        return true
                    } else {
                        mgr.saveProteinAs(prot)
                        return !prot.isDirty
                    }
                }
                return true
            case .alertSecondButtonReturn:
                return true
            default:
                return false
            }
        }
        
        func windowWillClose(_ notification: Notification) {
            if let prot = protein, let mgr = sequenceManager {
                mgr.proteinSequences.removeAll { $0.id == prot.id }
                if mgr.currentProtein?.id == prot.id {
                    mgr.currentProtein = mgr.proteinSequences.first
                }
            }
            originalDelegate?.windowWillClose?(notification)
        }
        
        func windowDidBecomeKey(_ notification: Notification) {
            originalDelegate?.windowDidBecomeKey?(notification)
        }
        
        func windowDidResignKey(_ notification: Notification) {
            originalDelegate?.windowDidResignKey?(notification)
        }
    }
}

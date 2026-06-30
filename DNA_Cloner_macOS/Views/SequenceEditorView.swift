//
//  SequenceEditorView.swift
//  Cloner 64
//
//  Redesigned to match Serial Cloner's sequence window layout (from manual)
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Main Sequence Editor View (Serial Cloner style)
struct SequenceEditorView: View {
    @ObservedObject var sequence: DNASequence
    @EnvironmentObject var sequenceManager: SequenceManager
    
    @State private var selectionStart: Int = 0
    @State private var selectionEnd: Int = 0
    @State private var currentSequenceID: UUID?
    @State private var showFeatures: Bool = true
    @State private var isLocked: Bool = true
    @State private var userHasUnlocked: Bool = false  // tracks if user manually unlocked
    @State private var selectedInnerTab: InnerTab = .sequence
    @State private var showFindDrawer: Bool = false
    @State private var showSelectionInfo: Bool = false
    @State private var dynamicBasesPerLine: Int = 40
    @State private var sequenceFontSize: CGFloat = 12
    @State private var showLockedWarning: Bool = false

    init(sequence: DNASequence) {
        self.sequence = sequence
        // Seed isLocked from actual content so the view is never briefly
        // unlocked while onAppear / onChange timing settles.
        _isLocked = State(initialValue: !sequence.sequence.isEmpty)
    }
    @State private var highlightRanges: [HighlightRange] = []
    @State private var featureCount: Int = 0
    
    // Edit state
    @State private var editableSequence: String = ""
    
    // Scroll target for navigation arrows
    @State private var scrollToLine: Int?
    @State private var showOverhangEditor: Bool = false
    
    enum InnerTab: String, CaseIterable {
        case sequence = "Sequence"
        case comments = "Comments"
        case extremities = "Extremities"
        case features = "Features"
    }
    
    /// The feature at the current cursor/selection position (if any)
    private var currentFeatureName: String? {
        guard showFeatures else { return nil }
        let pos = selectionStart
        return sequence.features.first(where: { feature in
            let lo = min(feature.start, feature.end)
            let hi = max(feature.start, feature.end)
            return pos >= lo && pos < hi
        })?.name
    }
    
    /// Selection length (0 if no selection)
    private var selectionLength: Int {
        selectionEnd > selectionStart ? selectionEnd - selectionStart : 0
    }
    
    var body: some View {
        HStack(spacing: 0) {
            // Main window content
            VStack(spacing: 0) {
                headerSection
                Divider()
                innerTabBar
                Divider()
                
                // Sequence/tab area
                tabContent
                
                Divider()
                
                // Always-visible bottom controls
                buttonRow
                selectionToggleButton
                
                // Expanding selection info panel
                if showSelectionInfo {
                    ScrollView {
                        SelectionInfoView(
                            sequence: sequence,
                            selectionStart: selectionStart,
                            selectionEnd: selectionEnd
                        )
                    }
                    .frame(minHeight: 120, maxHeight: 220)
                }
            }
            
            // Find Drawer (slides out on right)
            if showFindDrawer {
                Divider()
                FindDrawerView(
                    sequence: sequence,
                    selectionStart: $selectionStart,
                    selectionEnd: $selectionEnd,
                    isShowing: $showFindDrawer,
                    highlightRanges: $highlightRanges
                )
                .frame(width: 280)
                .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showFindDrawer)
        .onChange(of: showFindDrawer) { showing in
            if !showing { highlightRanges.removeAll() }
        }
        .focusedValue(\.activeSequence, sequence)
        .focusedValue(\.sequenceEditActions, makeEditActions())
        .onReceive(NotificationCenter.default.publisher(for: .sequenceUndo)) { _ in
            guard sequenceManager.currentSequence?.id == sequence.id else { return }
            sequence.undo()
            editableSequence = sequence.sequence
            selectionStart = 0
            selectionEnd = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: .sequenceRedo)) { _ in
            guard sequenceManager.currentSequence?.id == sequence.id else { return }
            sequence.redo()
            editableSequence = sequence.sequence
            selectionStart = 0
            selectionEnd = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: .sequenceSave)) { _ in
            guard sequenceManager.currentSequence?.id == sequence.id else { return }
            if let prot = sequenceManager.currentProtein {
                sequenceManager.saveProtein(prot)
            } else {
                sequenceManager.saveSequence()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sequenceSaveAs)) { _ in
            guard sequenceManager.currentSequence?.id == sequence.id else { return }
            if let prot = sequenceManager.currentProtein {
                sequenceManager.saveProteinAs(prot)
            } else {
                sequenceManager.saveSequenceAs()
            }
        }
        .alert("Sequence is Locked", isPresented: $showLockedWarning) {
            Button("OK") {}
        } message: {
            Text("Unlock the sequence to make edits (uncheck the Locked checkbox).")
        }
        .onAppear {
            editableSequence = sequence.sequence
            currentSequenceID = sequence.id
            isLocked = !sequence.sequence.isEmpty
            userHasUnlocked = false
            featureCount = sequence.features.count
        }
        .onChange(of: sequence.features.count) { newCount in
            featureCount = newCount
        }
        .onChange(of: sequence.sequence) { newValue in
            editableSequence = newValue
            // If the sequence content arrives after onAppear (e.g. loading from
            // Recent), re-lock it — unless the user has already manually unlocked.
            if !userHasUnlocked {
                isLocked = !newValue.isEmpty
            }
        }
        .onChange(of: sequence.id) { newID in
            if currentSequenceID != newID {
                selectionStart = 0
                selectionEnd = 0
                currentSequenceID = newID
                editableSequence = sequence.sequence
                isLocked = !sequence.sequence.isEmpty
                userHasUnlocked = false
            }
        }
        .onChange(of: selectionStart) { val in
            sequenceManager.selectionStart = val
        }
        .onChange(of: selectionEnd) { val in
            sequenceManager.selectionEnd = val
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button(action: { NotificationCenter.default.post(name: .sequenceSave, object: nil) }) {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .contextHelp("seq.saveButton")
                
                Button(action: { NotificationCenter.default.post(name: .sequenceSaveAs, object: nil) }) {
                    Label("Save As…", systemImage: "square.and.arrow.down.on.square")
                }
                .contextHelp("seq.saveAsButton")
                
                Menu {
                    Button("Export as FASTA…")   { sequenceManager.exportAsFASTA() }
                    Button("Export as GenBank…") { sequenceManager.exportAsGenBank() }
                    Button("Export as APE…")     { sequenceManager.exportAsAPE() }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .contextHelp("seq.exportButton")
            }
        }
    }
    
    // MARK: - Header Section (matches Serial Cloner items 1-10)
    private var headerSection: some View {
        VStack(spacing: 4) {
            // Row 1: File Name (left) | from field (right)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Sequence Name")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    TextField("Sequence Name", text: $sequence.name)
                        .font(.system(.body, weight: .bold))
                        .textFieldStyle(.roundedBorder)
                }
                
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("from")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        TextField("", value: Binding(
                            get: { selectionLength > 0 ? selectionStart + 1 : (sequence.length > 0 ? 1 : 0) },
                            set: { newValue in
                                let clamped = max(1, min(newValue, sequence.length))
                                selectionStart = clamped - 1
                                if selectionEnd <= selectionStart {
                                    selectionEnd = min(selectionStart + 1, sequence.length)
                                }
                            }
                        ), format: .number)
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    }
                    
                    HStack(spacing: 4) {
                        Text("to")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        TextField("", value: Binding(
                            get: { selectionLength > 0 ? selectionEnd : sequence.length },
                            set: { newValue in
                                selectionEnd = max(selectionStart + 1, min(newValue, sequence.length))
                            }
                        ), format: .number)
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    }
                }
                .frame(width: 110)
            }
            
            // Row 2: Total length | Topology | Strands | [|< >|] arrows | length
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Total length")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text("\(sequence.length)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                }
                
                Spacer().frame(width: 16)
                
                VStack(alignment: .leading, spacing: 1) {
                    Text("Topology")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Picker("", selection: Binding(
                        get: { sequence.isCircular },
                        set: { sequence.isCircular = $0 }
                    )) {
                        Text("Linear").tag(false)
                        Text("Circular").tag(true)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(isLocked)
                }
                
                Spacer().frame(width: 16)
                
                VStack(alignment: .leading, spacing: 1) {
                    Text("Strands")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Picker("", selection: Binding(
                        get: { sequence.isDoubleStranded },
                        set: { sequence.isDoubleStranded = $0 }
                    )) {
                        Text("Double Stranded").tag(true)
                        Text("Single Stranded").tag(false)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(isLocked)
                }
                
                Spacer()
                
                // Navigation arrows |< >| (item 7)
                HStack(spacing: 2) {
                    Button(action: {
                        selectionStart = 0
                        selectionEnd = 0
                        scrollToLine = 0
                    }) {
                        Text("|<")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .frame(width: 22, height: 18)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .contextHelp("seq.goToStart")
                    
                    Button(action: {
                        selectionStart = max(0, sequence.length - 1)
                        selectionEnd = sequence.length
                        if sequence.length > 0 {
                            scrollToLine = max(0, (sequence.length - 1) / max(1, dynamicBasesPerLine))
                        }
                    }) {
                        Text(">|")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .frame(width: 22, height: 18)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .contextHelp("seq.goToEnd")
                }
                
                Spacer().frame(width: 8)
                
                // Length field (item 10)
                HStack(spacing: 4) {
                    Text("length")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    TextField("", value: Binding(
                        get: { selectionLength > 0 ? selectionLength : sequence.length },
                        set: { newValue in
                            let clamped = max(0, min(newValue, sequence.length - selectionStart))
                            selectionEnd = selectionStart + clamped
                        }
                    ), format: .number)
                    .frame(width: 60)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                }
            }
            
            // Row 3: Locked + Show features
            HStack {
                Toggle(isOn: Binding(
                    get: { isLocked },
                    set: { newValue in
                        isLocked = newValue
                        if !newValue { userHasUnlocked = true }
                        if newValue { userHasUnlocked = false }
                    }
                )) {
                    Text("Locked")
                        .font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
                
                Spacer().frame(width: 20)
                
                Toggle(isOn: $showFeatures) {
                    HStack(spacing: 4) {
                        Text("Show features")
                            .font(.system(size: 12))
                        if let featureName = currentFeatureName {
                            Text(featureName)
                                .font(.system(size: 12))
                                .fontWeight(.semibold)
                                .foregroundColor(.blue)
                        }
                    }
                }
                .toggleStyle(.checkbox)
                
                Spacer()
                
                HStack(spacing: 4) {
                    Text("Font:")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Button(action: { sequenceFontSize = max(8, sequenceFontSize - 1) }) {
                        Image(systemName: "minus")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                    Text("\(Int(sequenceFontSize))")
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 20)
                    Button(action: { sequenceFontSize = min(24, sequenceFontSize + 1) }) {
                        Image(systemName: "plus")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(.windowBackgroundColor))
    }
    
    // MARK: - Inner Tab Bar (items 11-13)
    private var innerTabBar: some View {
        HStack(spacing: 0) {
            ForEach(InnerTab.allCases, id: \.self) { tab in
                Button(action: { selectedInnerTab = tab }) {
                    Text(tab.rawValue)
                        .font(.system(size: 12))
                        .fontWeight(selectedInnerTab == tab ? .semibold : .regular)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(
                            selectedInnerTab == tab
                            ? tabColor(for: tab)
                            : Color(.controlBackgroundColor)
                        )
                        .foregroundColor(selectedInnerTab == tab ? .white : .primary)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.leading, 8)
        .padding(.top, 4)
        .background(Color(.windowBackgroundColor))
    }
    
    private func tabColor(for tab: InnerTab) -> Color {
        switch tab {
        case .sequence: return .blue
        case .comments: return .green
        case .extremities: return .orange
        case .features: return .purple
        }
    }
    
    // MARK: - Tab Content
    @ViewBuilder
    private var tabContent: some View {
        switch selectedInnerTab {
        case .sequence: sequenceTabContent
        case .comments: commentsTabContent
        case .extremities: extremitiesTabContent
        case .features: featuresTabContent
        }
    }
    
    // MARK: - Sequence Tab (item 15)
    private var sequenceTabContent: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let computed = computeBasesPerLine(availableWidth: geometry.size.width)
                ScrollViewReader { proxy in
                    ScrollView {
                        SequenceTextView(
                            sequence: sequence,
                            features: showFeatures ? sequence.features : [],
                            featureCount: showFeatures ? featureCount : 0,
                            selectionStart: $selectionStart,
                            selectionEnd: $selectionEnd,
                            basesPerLine: computed,
                            isLocked: isLocked,
                            fontSize: sequenceFontSize,
                            showLockedWarning: $showLockedWarning,
                            highlightRanges: highlightRanges
                        )
                        .padding(8)
                    }
                    .background(Color(.textBackgroundColor))
                    .onChange(of: scrollToLine) { target in
                        if let target = target {
                            withAnimation {
                                proxy.scrollTo(target, anchor: .center)
                            }
                            scrollToLine = nil
                        }
                    }
                }
                .onAppear { dynamicBasesPerLine = computed }
                .onChange(of: geometry.size.width) { _ in
                    dynamicBasesPerLine = computeBasesPerLine(availableWidth: geometry.size.width)
                }
                .onChange(of: sequenceFontSize) { _ in
                    dynamicBasesPerLine = computeBasesPerLine(availableWidth: geometry.size.width)
                }
            }
            .frame(minHeight: 120)
        }
    }
    
    private func computeBasesPerLine(availableWidth: CGFloat) -> Int {
        let lineNumberWidth: CGFloat = sequenceFontSize * 5 + 6
        let font = NSFont.monospacedSystemFont(ofSize: sequenceFontSize, weight: .regular)
        let charWidth = font.advancement(forGlyph: font.glyph(withName: "A")).width
        let groupSpaceWidth: CGFloat = 5.0
        let padding: CGFloat = 16
        
        let usable = availableWidth - lineNumberWidth - padding
        guard usable > 0 else { return 10 }
        
        let groupWidth = 10.0 * charWidth + groupSpaceWidth
        let numGroups = Int((usable + groupSpaceWidth) / groupWidth)
        return max(10, numGroups * 10)
    }
    
    // MARK: - Comments Tab (item 12)
    private var commentsTabContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $sequence.description)
                .font(.system(.body, design: .monospaced))
                .padding(4)
            
            HStack {
                Text("Limited to 255 characters by DNA Strider")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .italic()
                Spacer()
                Text("Number of Characters: ")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                + Text("\(sequence.description.count)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(sequence.description.count > 255 ? .red : .primary)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
        .frame(minHeight: 120)
    }
    
    // MARK: - Extremities Tab (item 13)
    private var extremitiesTabContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if sequence.isCircular {
                Text("Circular sequences do not have defined extremities.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.top, 12)
                    .padding(.horizontal, 10)
            } else if !sequence.isDoubleStranded {
                // Single-stranded: no complementary strand, so no blunt/sticky ends
                VStack(alignment: .leading, spacing: 12) {
                    Text("Single-stranded DNA \u{2014} no complementary strand.")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.orange)
                    
                    if sequence.length > 0 {
                        let seqStr = sequence.sequence
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("5\u{2032} end (first 20 bases)")
                                    .font(.system(size: 12)).foregroundColor(.secondary)
                                Text(String(seqStr.prefix(min(20, seqStr.count))))
                                    .font(.system(size: 12, design: .monospaced))
                                    .padding(4)
                                    .background(Color(.textBackgroundColor))
                                    .cornerRadius(3)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("3\u{2032} end (last 20 bases)")
                                    .font(.system(size: 12)).foregroundColor(.secondary)
                                Text(String(seqStr.suffix(min(20, seqStr.count))))
                                    .font(.system(size: 12, design: .monospaced))
                                    .padding(4)
                                    .background(Color(.textBackgroundColor))
                                    .cornerRadius(3)
                            }
                        }
                    }
                }
                .padding(.top, 12)
                .padding(.horizontal, 16)
            } else {
                HStack(alignment: .top, spacing: 40) {
                    // 5' end
                    VStack(alignment: .leading, spacing: 8) {
                        Text("5\u{2032} End")
                            .font(.system(size: 12, weight: .bold)).foregroundColor(.secondary)
                        
                        if sequence.cohesive5Prime.isEmpty {
                            bluntEndDiagram(is5Prime: true)
                            Text("Blunt end")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.green)
                        } else {
                            cohesiveEndDiagram(overhang: sequence.cohesive5Prime, is5Prime: true)
                            Text("Sticky end (\(sequence.cohesive5Prime.count) nt overhang)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.orange)
                        }
                        
                        if showOverhangEditor || !sequence.cohesive5Prime.isEmpty {
                            HStack(spacing: 4) {
                                Text("Overhang:")
                                    .font(.system(size: 12)).foregroundColor(.secondary)
                                TextField("", text: $sequence.cohesive5Prime)
                                    .font(.system(size: 12, design: .monospaced))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 120)
                                    .disabled(isLocked)
                            }
                        }
                    }
                    
                    // 3' end
                    VStack(alignment: .leading, spacing: 8) {
                        Text("3\u{2032} End")
                            .font(.system(size: 12, weight: .bold)).foregroundColor(.secondary)
                        
                        if sequence.cohesive3Prime.isEmpty {
                            bluntEndDiagram(is5Prime: false)
                            Text("Blunt end")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.green)
                        } else {
                            cohesiveEndDiagram(overhang: sequence.cohesive3Prime, is5Prime: false)
                            Text("Sticky end (\(sequence.cohesive3Prime.count) nt overhang)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.orange)
                        }
                        
                        if showOverhangEditor || !sequence.cohesive3Prime.isEmpty {
                            HStack(spacing: 4) {
                                Text("Overhang:")
                                    .font(.system(size: 12)).foregroundColor(.secondary)
                                TextField("", text: $sequence.cohesive3Prime)
                                    .font(.system(size: 12, design: .monospaced))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 120)
                                    .disabled(isLocked)
                            }
                        }
                    }
                }
                .padding(.top, 12)
                .padding(.horizontal, 16)
                
                // Edit overhangs button (only when both are blunt and editor hidden)
                if sequence.cohesive5Prime.isEmpty && sequence.cohesive3Prime.isEmpty && !showOverhangEditor {
                    Button(action: { showOverhangEditor = true }) {
                        Label("Edit Overhangs", systemImage: "pencil")
                    }
                    .controlSize(.small)
                    .padding(.horizontal, 16)
                }
                
                if sequence.length > 0 {
                    Divider().padding(.horizontal, 10)
                    VStack(alignment: .leading, spacing: 6) {
                        let seqStr = sequence.sequence
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("5\u{2032} end (first 20 bases)")
                                    .font(.system(size: 12)).foregroundColor(.secondary)
                                Text(String(seqStr.prefix(min(20, seqStr.count))))
                                    .font(.system(size: 12, design: .monospaced))
                                    .padding(4)
                                    .background(Color(.textBackgroundColor))
                                    .cornerRadius(3)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("3\u{2032} end (last 20 bases)")
                                    .font(.system(size: 12)).foregroundColor(.secondary)
                                Text(String(seqStr.suffix(min(20, seqStr.count))))
                                    .font(.system(size: 12, design: .monospaced))
                                    .padding(4)
                                    .background(Color(.textBackgroundColor))
                                    .cornerRadius(3)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            Spacer()
        }
        .frame(minHeight: 120)
        .onAppear {
            if !sequence.cohesive5Prime.isEmpty || !sequence.cohesive3Prime.isEmpty {
                showOverhangEditor = true
            }
        }
    }
    
    /// Blunt end diagram — flush double-stranded end
    private func bluntEndDiagram(is5Prime: Bool) -> some View {
        let mono = Font.system(size: 11, design: .monospaced)
        let dashLine = String(repeating: "\u{2500}", count: 8)
        
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Text(is5Prime ? "5\u{2032}" : "5\u{2032}").font(mono).foregroundColor(.secondary)
                Text(dashLine).font(mono)
                Text(is5Prime ? "3\u{2032}" : "3\u{2032}").font(mono).foregroundColor(.secondary)
            }
            HStack(spacing: 2) {
                Text(is5Prime ? "3\u{2032}" : "3\u{2032}").font(mono).foregroundColor(.secondary)
                Text(dashLine).font(mono)
                Text(is5Prime ? "5\u{2032}" : "5\u{2032}").font(mono).foregroundColor(.secondary)
            }
        }
        .padding(8)
        .background(Color(.textBackgroundColor))
        .cornerRadius(4)
    }
    
    private func cohesiveEndDiagram(overhang: String, is5Prime: Bool) -> some View {
        let mono = Font.system(size: 11, design: .monospaced)
        let lineLen = max(overhang.count, 4)
        let dashLine = String(repeating: "\u{2500}", count: lineLen + 4)
        
        return VStack(alignment: .leading, spacing: 0) {
            if is5Prime {
                HStack(spacing: 2) {
                    Text("5'").font(mono).foregroundColor(.secondary)
                    if !overhang.isEmpty {
                        Text("  \(overhang.lowercased())").font(mono).foregroundColor(.blue)
                    }
                    Text(dashLine).font(mono)
                    Text("3'").font(mono).foregroundColor(.secondary)
                }
                HStack(spacing: 2) {
                    Text("3'").font(mono).foregroundColor(.secondary)
                    if !overhang.isEmpty {
                        Text(String(repeating: " ", count: overhang.count + 2)).font(mono)
                    }
                    Text(dashLine).font(mono)
                    Text("5'").font(mono).foregroundColor(.secondary)
                }
            } else {
                HStack(spacing: 2) {
                    Text("5'").font(mono).foregroundColor(.secondary)
                    Text(dashLine).font(mono)
                    if !overhang.isEmpty {
                        Text(String(repeating: " ", count: overhang.count + 2)).font(mono)
                    }
                    Text("3'").font(mono).foregroundColor(.secondary)
                }
                HStack(spacing: 2) {
                    Text("3'").font(mono).foregroundColor(.secondary)
                    Text(dashLine).font(mono)
                    if !overhang.isEmpty {
                        Text("  \(overhang.lowercased())").font(mono).foregroundColor(.blue)
                    }
                    Text("5'").font(mono).foregroundColor(.secondary)
                }
            }
        }
        .padding(8)
        .background(Color(.textBackgroundColor))
        .cornerRadius(4)
    }
    
    // MARK: - Features Tab
    private var featuresTabContent: some View {
        FeaturesTabView(sequence: sequence, isLocked: isLocked, selectionStart: $selectionStart, selectionEnd: $selectionEnd)
            .frame(minHeight: 120)
    }
    
    // MARK: - Button Row (items 16-19)
    private var buttonRow: some View {
        HStack(spacing: 8) {
            Button("Save") { sequenceManager.saveSequence() }
                .controlSize(.small)
                .keyboardShortcut("s", modifiers: .command)
            
            Button("Save As...") { sequenceManager.saveSequenceAs() }
                .controlSize(.small)
            
            Divider().frame(height: 16)
            
            Button("New from Selection") { extractFragment() }
                .controlSize(.small)
                .disabled(selectionStart >= selectionEnd)
                .contextHelp("seq.newFromSelection")
            
            Spacer()
            
            Button(action: {
                guard !FeatureLibraryManager.shared.isScanning else { return }
                FeatureLibraryManager.shared.scanSequence(sequence)
                waitForScanRefresh()
            }) {
                Label("Scan Features", systemImage: "viewfinder")
            }
            .controlSize(.small)
            .contextHelp("seq.scanFeatures")
            
            Text("\(dynamicBasesPerLine) bp/line")
                .font(.system(size: 12)).foregroundColor(.secondary)
            
            Button(action: { withAnimation { showFindDrawer.toggle() } }) {
                Label("Find", systemImage: "magnifyingglass")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(.windowBackgroundColor))
    }
    
    // MARK: - Selection Toggle (item 20)
    private var selectionToggleButton: some View {
        Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showSelectionInfo.toggle() } }) {
            Text(showSelectionInfo ? "Hide Selection Information & Translation" : "Show Selection Information & Translation")
                .font(.system(size: 12))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
    
    // MARK: - Edit Helpers
    
    private func subsequence(from start: Int, to end: Int) -> String {
        let seq = sequence.sequence
        guard start >= 0 && end <= seq.count && start < end else { return "" }
        let startIndex = seq.index(seq.startIndex, offsetBy: start)
        let endIndex = seq.index(seq.startIndex, offsetBy: end)
        return String(seq[startIndex..<endIndex])
    }
    
    private func makeEditActions() -> SequenceEditActions {
        SequenceEditActions(
            owner: ObjectIdentifier(sequence),
            copy: { copySelection() },
            cut: { cutSelection() },
            paste: { pasteFromClipboard() },
            delete: { deleteSelection() },
            selectAll: { selectAllBases() },
            makeUppercase: { uppercaseSelection() },
            makeLowercase: { lowercaseSelection() },
            hasSelection: selectionStart < selectionEnd,
            isLocked: isLocked
        )
    }
    
    private func copySelection() {
        guard selectionStart < selectionEnd else { return }
        let selected = subsequence(from: selectionStart, to: selectionEnd)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selected, forType: .string)
    }
    
    private func copyAsFasta() {
        guard selectionStart < selectionEnd else { return }
        let selected = subsequence(from: selectionStart, to: selectionEnd)
        let fasta = ">\(sequence.name) [\(selectionStart + 1)..\(selectionEnd)]\n\(selected)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fasta, forType: .string)
    }
    
    private func cutSelection() {
        guard !isLocked, selectionStart < selectionEnd else { return }
        copySelection()
        deleteSelection()
    }
    
    private func pasteFromClipboard() {
        guard !isLocked else { showLockedWarning = true; return }
        guard let clipText = NSPasteboard.general.string(forType: .string) else { return }
        let validChars = "ACGTURYSWKMBDHVNacgturyswkmbdhvn"
        let cleaned = clipText.filter { validChars.contains($0) }
        guard !cleaned.isEmpty else { return }
        sequence.registerUndo()
        
        if selectionStart < selectionEnd {
            let before = subsequence(from: 0, to: selectionStart)
            let after = subsequence(from: selectionEnd, to: sequence.length)
            sequence.sequence = before + cleaned + after
            selectionEnd = selectionStart + cleaned.count
        } else if selectionStart > 0 && selectionStart <= sequence.length {
            let before = subsequence(from: 0, to: selectionStart)
            let after = subsequence(from: selectionStart, to: sequence.length)
            sequence.sequence = before + cleaned + after
            selectionEnd = selectionStart + cleaned.count
        } else {
            sequence.sequence = cleaned
            selectionStart = 0
            selectionEnd = cleaned.count
        }
        editableSequence = sequence.sequence
    }
    
    private func deleteSelection() {
        guard !isLocked, selectionStart < selectionEnd else { return }
        sequence.registerUndo()
        let before = subsequence(from: 0, to: selectionStart)
        let after = subsequence(from: selectionEnd, to: sequence.length)
        sequence.sequence = before + after
        sequence.features = shiftFeatures(sequence.features, deleteStart: selectionStart, deleteEnd: selectionEnd)
        selectionEnd = selectionStart
        editableSequence = sequence.sequence
    }
    
    /// Shifts/removes feature coordinates after bases [deleteStart, deleteEnd) are removed.
    private func shiftFeatures(_ features: [Feature], deleteStart: Int, deleteEnd: Int) -> [Feature] {
        let deleteLen = deleteEnd - deleteStart
        return features.compactMap { feature in
            var f = feature
            let fLo = min(f.start, f.end)
            let fHi = max(f.start, f.end)
            // Entirely inside deleted region — remove
            if fLo >= deleteStart && fHi <= deleteEnd { return nil }
            // Entirely after deletion — shift back
            if fLo >= deleteEnd {
                f.start = max(0, f.start - deleteLen)
                f.end   = max(0, f.end   - deleteLen)
                return f
            }
            // Entirely before deletion — no change
            if fHi <= deleteStart { return f }
            // Overlaps deletion boundary — trim
            let newLo = fLo < deleteStart ? fLo : deleteStart
            let rawHi = fHi > deleteEnd ? fHi - deleteLen : deleteStart
            let newHi = max(newLo, rawHi)
            f.start = f.start <= f.end ? newLo : newHi
            f.end   = f.start <= f.end ? newHi : newLo
            if f.start == f.end { return nil }
            return f
        }
    }
    
    private func selectAllBases() {
        selectionStart = 0
        selectionEnd = sequence.length
    }
    
    private func extractFragment() {
        guard selectionStart < selectionEnd else { return }
        let fragment = subsequence(from: selectionStart, to: selectionEnd)
        let fragName = "\(sequence.name) fragment [\(selectionStart + 1)..\(selectionEnd)]"
        let seqStr   = sequence.sequence.uppercased()
        let selStart = selectionStart
        let selEnd   = selectionEnd
        let seqName  = sequence.name
        let isCirc   = sequence.isCircular
        let enzymes  = RestrictionEnzymeDatabase.shared.enzymes

        DispatchQueue.global(qos: .userInitiated).async {
            var fivePrimeOverhang = ""
            var threePrimeOverhang = ""
            var endDesc5 = "blunt"
            var endDesc3 = "blunt"

            for enzyme in enzymes {
                let sites = enzyme.findCutSites(in: seqStr, circular: isCirc)
                for site in sites {
                    let cut5 = site.cutPosition5Prime
                    let cut3 = site.cutPosition3Prime
                    if cut5 == selStart || cut3 == selStart {
                        let lo = min(cut5, cut3); let hi = max(cut5, cut3)
                        if lo != hi && lo >= 0 && hi <= seqStr.count {
                            let s = seqStr.index(seqStr.startIndex, offsetBy: lo)
                            let e = seqStr.index(seqStr.startIndex, offsetBy: hi)
                            fivePrimeOverhang = String(seqStr[s..<e])
                            endDesc5 = "\(enzyme.name) (\(fivePrimeOverhang))"
                        }
                    }
                    if cut5 == selEnd || cut3 == selEnd {
                        let lo = min(cut5, cut3); let hi = max(cut5, cut3)
                        if lo != hi && lo >= 0 && hi <= seqStr.count {
                            let s = seqStr.index(seqStr.startIndex, offsetBy: lo)
                            let e = seqStr.index(seqStr.startIndex, offsetBy: hi)
                            threePrimeOverhang = String(seqStr[s..<e])
                            endDesc3 = "\(enzyme.name) (\(threePrimeOverhang))"
                        }
                    }
                }
            }

            DispatchQueue.main.async {
                let newSeq = DNASequence(name: fragName, sequence: fragment, isCircular: false)
                newSeq.cohesive5Prime = fivePrimeOverhang
                newSeq.cohesive3Prime = threePrimeOverhang
                newSeq.description = "Fragment from \(seqName), positions \(selStart + 1) to \(selEnd). 5': \(endDesc5), 3': \(endDesc3)."
                self.sequenceManager.sequences.append(newSeq)
                self.sequenceManager.currentSequence = newSeq
                SequenceWindowOpener.shared.openSequenceWindow(newSeq.id)
            }
        }
    }
    
    private func copyTranslation() {
        guard selectionStart < selectionEnd else { return }
        let selected = subsequence(from: selectionStart, to: selectionEnd).uppercased()
        let protein = DNASequence(name: "tmp", sequence: selected).translate(frame: 1)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(protein, forType: .string)
    }
    
    private func uppercaseSelection() {
        guard !isLocked, selectionStart < selectionEnd else { return }
        sequence.registerUndo()
        let savedEnd = selectionEnd
        let before = subsequence(from: 0, to: selectionStart)
        let selected = subsequence(from: selectionStart, to: selectionEnd).uppercased()
        let after = subsequence(from: selectionEnd, to: sequence.length)
        sequence.sequence = before + selected + after
        editableSequence = sequence.sequence
        selectionStart = savedEnd
        selectionEnd = savedEnd
    }
    
    private func lowercaseSelection() {
        guard !isLocked, selectionStart < selectionEnd else { return }
        sequence.registerUndo()
        let savedEnd = selectionEnd
        let before = subsequence(from: 0, to: selectionStart)
        let selected = subsequence(from: selectionStart, to: selectionEnd).lowercased()
        let after = subsequence(from: selectionEnd, to: sequence.length)
        sequence.sequence = before + selected + after
        editableSequence = sequence.sequence
        selectionStart = savedEnd
        selectionEnd = savedEnd
    }
    
    private func waitForScanRefresh() {
        if FeatureLibraryManager.shared.isScanning {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { waitForScanRefresh() }
            return
        }
        featureCount = sequence.features.count
    }
    
    private func antiparallelSelection() {
        guard !isLocked, selectionStart < selectionEnd else { return }
        sequence.registerUndo()
        let before = subsequence(from: 0, to: selectionStart)
        let selected = subsequence(from: selectionStart, to: selectionEnd)
        let antiparallel = DNASequence.reverseComplementString(selected)
        let after = subsequence(from: selectionEnd, to: sequence.length)
        sequence.sequence = before + antiparallel + after
        editableSequence = sequence.sequence
    }
}


// MARK: - Sequence Text View (with feature coloring + context menu)
/// A coloured highlight range for search results, ORFs, or restriction sites
struct HighlightRange: Equatable {
    let start: Int
    let end: Int
    let color: Color
}

struct SequenceTextView: View {
    @ObservedObject var sequence: DNASequence
    let features: [Feature]
    var featureCount: Int = 0
    @Binding var selectionStart: Int
    @Binding var selectionEnd: Int
    var basesPerLine: Int = 40
    var isLocked: Bool = false
    var fontSize: CGFloat = 12
    @Binding var showLockedWarning: Bool
    var highlightRanges: [HighlightRange] = []
    
    @State private var firstClick: Int?
    @State private var selectionAnchor: Int?
    @EnvironmentObject var sequenceManager: SequenceManager
    
    private let basesPerGroup = 10
    private var seqString: String { sequence.sequence }

    // NOTE: the per-base character lookup is made fast in `body`, which builds
    // a [Character] array once per redraw (O(n)) and indexes it (O(1) per base).
    // This avoids the old O(n^2) String.index walk without relying on a cached
    // @State array, which could be left empty when a window is adopted in-place.

    // MARK: - Cached metrics (rebuilt only when fontSize changes)
    // Creating NSFont objects on every mouse event is expensive.
    @State private var cachedCharWidth:   CGFloat = 0
    @State private var cachedLineHeight:  CGFloat = 0

    private func refreshFontMetrics() {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        cachedCharWidth  = font.advancement(forGlyph: font.glyph(withName: "A")).width
        cachedLineHeight = ceil(font.ascender - font.descender + font.leading) + 2
    }

    // MARK: - Feature colour map (position → background colour)
    // Built once (and whenever features change) so characterView() does an O(1)
    // lookup instead of iterating all features for every single base every render.
    @State private var featureColorMap: [Int: Color] = [:]

    private func buildFeatureColorMap() {
        let snap   = features
        let seqLen = seqString.count

        func makeMap() -> [Int: Color] {
            var map: [Int: Color] = [:]
            for feature in snap {
                let lo = max(0, min(feature.start, feature.end))
                let hi = min(seqLen, max(feature.start, feature.end))
                let color = feature.color.color.opacity(0.25)
                guard lo < hi else { continue }
                for pos in lo..<hi where map[pos] == nil { map[pos] = color }
            }
            return map
        }

        // First load: build synchronously so the initial render has correct
        // colours. Without this, characters start transparent while spacerBackground()
        // already colours the group spacers — producing visible bars every 10 bases.
        if featureColorMap.isEmpty {
            featureColorMap = makeMap()
            return
        }

        // Subsequent updates (feature edits, sequence changes): background thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let map = makeMap()
            DispatchQueue.main.async { self.featureColorMap = map }
        }
    }
    
    private let groupSpaceWidth: CGFloat = 5.0
    
    var body: some View {
        // Build the character array ONCE per redraw (O(n)) and index it for each
        // base (O(1)). Fast per-base lookup, with no cached state that could be
        // left empty when a window is adopted in-place.
        let chars = Array(seqString)
        let total = chars.count
        let lineCount = max(1, (total + basesPerLine - 1) / basesPerLine)
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(0..<lineCount, id: \.self) { lineIndex in
                let basesThisLine = max(0, min(basesPerLine, total - lineIndex * basesPerLine))
                HStack(spacing: 0) {
                    Text(String(format: "%6d", lineIndex * basesPerLine + 1))
                        .font(.system(size: fontSize, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: fontSize * 5, alignment: .trailing)
                        .padding(.trailing, 6)
                    
                    HStack(spacing: 0) {
                        ForEach(0..<basesThisLine, id: \.self) { baseIndex in
                            let position = lineIndex * basesPerLine + baseIndex
                            characterView(at: position, chars: chars)
                            
                            if (baseIndex + 1) % basesPerGroup == 0 && baseIndex + 1 < basesThisLine {
                                groupSpacer(beforePosition: position, afterPosition: position + 1)
                            }
                        }
                        
                        // Show cursor after the very last base
                        if lineIndex == lineCount - 1 {
                            endOfSequenceCursor
                        }
                    }
                    .drawingGroup()
                }
                .id(lineIndex)
            }
        }
        // Serial Cloner-style context menu
        .contextMenu {
            Button("Select All") { selectAll() }
            Divider()
            Button("Copy") { doCopy() }
                .disabled(selectionStart >= selectionEnd)
            Button("Copy as FASTA") { doCopyFasta() }
                .disabled(selectionStart >= selectionEnd)
            Button("Cut") { doCut() }
                .disabled(isLocked || selectionStart >= selectionEnd)
            Button("Paste") { doPaste() }
                .disabled(isLocked)
            Divider()
            Button("New Sequence from Selection") { doExtractFragment() }
                .disabled(selectionStart >= selectionEnd)
            Button("Copy Translation") { doCopyTranslation() }
                .disabled(selectionStart >= selectionEnd)
            Divider()
            Button("UPPERCASE") { doUppercase() }
                .disabled(isLocked || selectionStart >= selectionEnd)
            Button("lowercase") { doLowercase() }
                .disabled(isLocked || selectionStart >= selectionEnd)
            Divider()
            Button("Antiparallel") { doAntiparallel() }
                .disabled(isLocked || selectionStart >= selectionEnd)
        }
        .overlay(
            MouseTrackingOverlay(
                onMouseDown: { location, modifiers in
                    if let position = positionFromPoint(location) {
                        let pos = min(position, seqString.count)
                        let isShift = modifiers.contains(.shift)
                        let isCmd = modifiers.contains(.command)

                        if isShift {
                            // Shift-click: extend from anchor (establish if missing)
                            if selectionAnchor == nil { selectionAnchor = selectionStart }
                            let anchor = selectionAnchor ?? selectionStart
                            firstClick = anchor
                            selectionStart = min(anchor, pos)
                            selectionEnd = min(max(anchor, pos) + 1, seqString.count)
                        } else if isCmd && selectionStart < selectionEnd {
                            // Cmd+click: extend existing selection to this point
                            if pos < selectionStart {
                                selectionStart = pos
                            } else {
                                selectionEnd = min(pos + 1, seqString.count)
                            }
                            firstClick = nil
                            selectionAnchor = selectionStart
                        } else {
                            // Plain click: place caret, reset anchor
                            firstClick = pos
                            selectionStart = pos
                            selectionEnd = pos
                            selectionAnchor = pos
                        }
                    }
                },
                onMouseDragged: { location, modifiers in
                    if let position = positionFromPoint(location) {
                        let pos = min(position, seqString.count)
                        if let first = firstClick {
                            // Dragging creates/extends a selection from the anchor/first click
                            selectionStart = min(first, pos)
                            selectionEnd = min(max(first, pos) + 1, seqString.count)
                        } else {
                            // Cmd-drag extending from current selection edge
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
                    selectionAnchor = selectionStart
                },
                onCopy: { doCopy() },
                onCut: { doCut() },
                onPaste: { doPaste() },
                onSelectAll: { selectAll() },
                onDelete: { doDelete() },
                onMakeUppercase: { doMakeUppercase() },
                onMakeLowercase: { doMakeLowercase() },
                onInsertText: { text in doInsertText(text) },
                onMoveCursor: { dir in doMoveCursor(dir) },
                onExtendSelection: { dir in
                    // Establish anchor if needed
                    if selectionAnchor == nil { selectionAnchor = selectionStart }
                    let anchor = selectionAnchor ?? selectionStart
                    // Move the active edge one position left/right
                    if dir < 0 {
                        let newPos = max(0, (selectionStart < selectionEnd ? selectionEnd - 1 : selectionStart) - 1)
                        selectionStart = min(anchor, newPos)
                        selectionEnd = max(anchor, newPos) + (newPos >= anchor ? 1 : 0)
                    } else {
                        let newPos = min(seqString.count, (selectionStart < selectionEnd ? selectionEnd : selectionStart) + 1)
                        selectionStart = min(anchor, newPos)
                        selectionEnd = max(anchor, newPos) + (newPos >= anchor ? 1 : 0)
                    }
                },
                onUndo: {
                    NotificationCenter.default.post(name: .sequenceUndo, object: nil)
                },
                onRedo: {
                    NotificationCenter.default.post(name: .sequenceRedo, object: nil)
                }
            )
        )
        .onAppear {
            refreshFontMetrics()
            buildFeatureColorMap()
        }
        .onChange(of: fontSize) { _ in
            refreshFontMetrics()
        }
        .onChange(of: features) { _ in
            buildFeatureColorMap()
        }
        .onChange(of: featureCount) { _ in
            buildFeatureColorMap()
        }
        .onChange(of: sequence.sequence) { _ in
            buildFeatureColorMap()
        }
    }
    
    // MARK: - Context Menu Actions
    
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
    
    private func doCopyFasta() {
        let fasta = ">\(sequence.name) [\(selectionStart+1)..\(selectionEnd)]\n\(selectedSubstring())"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fasta, forType: .string)
    }
    
    private func doCut() {
        guard !isLocked else { showLockedWarning = true; return }
        doCopy()
        doDelete()
    }
    
    private func doDelete() {
        guard !isLocked else { showLockedWarning = true; return }
        guard selectionStart < selectionEnd || selectionStart > 0 else { return }
        // Clamp both positions defensively — sequence length may have changed
        // between SwiftUI renders, and an out-of-bounds offsetBy: crashes.
        let safeLen = seqString.count
        let safeStart = min(selectionStart, safeLen)
        let safeEnd   = min(selectionEnd,   safeLen)
        sequence.registerUndo()
        if safeStart < safeEnd {
            // Delete selection
            let before = String(seqString.prefix(safeStart))
            let after = String(seqString.suffix(from: seqString.index(seqString.startIndex, offsetBy: safeEnd)))
            sequence.sequence = before + after
            sequence.features = shiftFeatures(sequence.features, deleteStart: safeStart, deleteEnd: safeEnd)
            selectionStart = safeStart
            selectionEnd   = safeStart
        } else if safeStart > 0 {
            // No selection — backspace deletes character before cursor
            let deletePos = safeStart - 1
            let before = String(seqString.prefix(deletePos))
            let after = String(seqString.suffix(from: seqString.index(seqString.startIndex, offsetBy: safeStart)))
            sequence.sequence = before + after
            sequence.features = shiftFeatures(sequence.features, deleteStart: deletePos, deleteEnd: safeStart)
            selectionStart = deletePos
            selectionEnd   = deletePos
        }
    }
    
    /// Shifts/removes feature coordinates after bases [deleteStart, deleteEnd) are removed.
    private func shiftFeatures(_ features: [Feature], deleteStart: Int, deleteEnd: Int) -> [Feature] {
        let deleteLen = deleteEnd - deleteStart
        return features.compactMap { feature in
            var f = feature
            let fLo = min(f.start, f.end)
            let fHi = max(f.start, f.end)
            if fLo >= deleteStart && fHi <= deleteEnd { return nil }
            if fLo >= deleteEnd {
                f.start = max(0, f.start - deleteLen)
                f.end   = max(0, f.end   - deleteLen)
                return f
            }
            if fHi <= deleteStart { return f }
            let newLo = fLo < deleteStart ? fLo : deleteStart
            let rawHi = fHi > deleteEnd ? fHi - deleteLen : deleteStart
            let newHi = max(newLo, rawHi)
            f.start = f.start <= f.end ? newLo : newHi
            f.end   = f.start <= f.end ? newHi : newLo
            if f.start == f.end { return nil }
            return f
        }
    }
    
    private func doPaste() {
        guard !isLocked else { showLockedWarning = true; return }
        guard let clip = NSPasteboard.general.string(forType: .string) else { return }
        let valid = "ACGTURYSWKMBDHVNacgturyswkmbdhvn"
        let cleaned = clip.filter { valid.contains($0) }
        guard !cleaned.isEmpty else { return }
        sequence.registerUndo()
        let before = String(seqString.prefix(selectionStart))
        let after = String(seqString.suffix(from: seqString.index(seqString.startIndex, offsetBy: min(selectionEnd, seqString.count))))
        sequence.sequence = before + cleaned + after
        selectionEnd = selectionStart + cleaned.count
    }
    
    private func doMakeUppercase() {
        guard !isLocked else { showLockedWarning = true; return }
        guard selectionStart < selectionEnd, selectionEnd <= seqString.count else { return }
        sequence.registerUndo()
        let savedEnd = selectionEnd
        let before = String(seqString.prefix(selectionStart))
        let s = seqString.index(seqString.startIndex, offsetBy: selectionStart)
        let e = seqString.index(seqString.startIndex, offsetBy: selectionEnd)
        let selected = String(seqString[s..<e]).uppercased()
        let after = String(seqString.suffix(from: e))
        sequence.sequence = before + selected + after
        selectionStart = savedEnd
        selectionEnd = savedEnd
    }
    
    private func doMakeLowercase() {
        guard !isLocked else { showLockedWarning = true; return }
        guard selectionStart < selectionEnd, selectionEnd <= seqString.count else { return }
        sequence.registerUndo()
        let savedEnd = selectionEnd
        let before = String(seqString.prefix(selectionStart))
        let s = seqString.index(seqString.startIndex, offsetBy: selectionStart)
        let e = seqString.index(seqString.startIndex, offsetBy: selectionEnd)
        let selected = String(seqString[s..<e]).lowercased()
        let after = String(seqString.suffix(from: e))
        sequence.sequence = before + selected + after
        selectionStart = savedEnd
        selectionEnd = savedEnd
    }
    
    private func doInsertText(_ text: String) {
        guard !isLocked else { showLockedWarning = true; return }
        let validChars = Set("ACGTURYSWKMBDHVNacgturyswkmbdhvn")
        let cleaned = String(text.filter { validChars.contains($0) })
        guard !cleaned.isEmpty else { return }
        sequence.registerUndo()
        
        // If there's a selection, replace it; otherwise insert at cursor
        let insertPos = selectionStart
        let before = String(seqString.prefix(selectionStart))
        let after = String(seqString.suffix(from: seqString.index(seqString.startIndex, offsetBy: min(selectionEnd, seqString.count))))
        sequence.sequence = before + cleaned + after
        // Move cursor to after the inserted text
        selectionStart = insertPos + cleaned.count
        selectionEnd = selectionStart
    }
    
    private func doMoveCursor(_ direction: Int) {
        if direction < 0 {
            // Left
            let newPos = max(0, selectionStart - 1)
            selectionStart = newPos
            selectionEnd = newPos
        } else {
            // Right
            let newPos = min(seqString.count, selectionEnd + 1)
            selectionStart = newPos
            selectionEnd = newPos
        }
    }
    
    private func doExtractFragment() {
        let fragment = selectedSubstring()
        guard !fragment.isEmpty else { return }
        let fragName = "\(sequence.name) fragment [\(selectionStart+1)..\(selectionEnd)]"
        let seqStr   = sequence.sequence.uppercased()
        let selStart = selectionStart
        let selEnd   = selectionEnd
        let seqName  = sequence.name
        let isCirc   = sequence.isCircular
        let enzymes  = RestrictionEnzymeDatabase.shared.enzymes

        DispatchQueue.global(qos: .userInitiated).async {
            var fivePrimeOverhang = ""
            var threePrimeOverhang = ""
            var endDesc5 = "blunt"
            var endDesc3 = "blunt"

            for enzyme in enzymes {
                let sites = enzyme.findCutSites(in: seqStr, circular: isCirc)
                for site in sites {
                    let cut5 = site.cutPosition5Prime
                    let cut3 = site.cutPosition3Prime
                    if cut5 == selStart || cut3 == selStart {
                        let lo = min(cut5, cut3); let hi = max(cut5, cut3)
                        if lo != hi && lo >= 0 && hi <= seqStr.count {
                            let s = seqStr.index(seqStr.startIndex, offsetBy: lo)
                            let e = seqStr.index(seqStr.startIndex, offsetBy: hi)
                            fivePrimeOverhang = String(seqStr[s..<e])
                            endDesc5 = "\(enzyme.name) (\(fivePrimeOverhang))"
                        }
                    }
                    if cut5 == selEnd || cut3 == selEnd {
                        let lo = min(cut5, cut3); let hi = max(cut5, cut3)
                        if lo != hi && lo >= 0 && hi <= seqStr.count {
                            let s = seqStr.index(seqStr.startIndex, offsetBy: lo)
                            let e = seqStr.index(seqStr.startIndex, offsetBy: hi)
                            threePrimeOverhang = String(seqStr[s..<e])
                            endDesc3 = "\(enzyme.name) (\(threePrimeOverhang))"
                        }
                    }
                }
            }

            DispatchQueue.main.async {
                let newSeq = DNASequence(name: fragName, sequence: fragment, isCircular: false)
                newSeq.cohesive5Prime = fivePrimeOverhang
                newSeq.cohesive3Prime = threePrimeOverhang
                newSeq.description = "Fragment from \(seqName), positions \(selStart+1) to \(selEnd). 5': \(endDesc5), 3': \(endDesc3)."
                self.sequenceManager.sequences.append(newSeq)
                self.sequenceManager.currentSequence = newSeq
                SequenceWindowOpener.shared.openSequenceWindow(newSeq.id)
            }
        }
    }
    
    private func doCopyTranslation() {
        let protein = DNASequence(name: "tmp", sequence: selectedSubstring().uppercased()).translate(frame: 1)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(protein, forType: .string)
    }
    
    private func doUppercase() {
        guard !isLocked else { showLockedWarning = true; return }
        sequence.registerUndo()
        let before = String(seqString.prefix(selectionStart))
        let sel = selectedSubstring().uppercased()
        let after = String(seqString.suffix(from: seqString.index(seqString.startIndex, offsetBy: min(selectionEnd, seqString.count))))
        sequence.sequence = before + sel + after
    }
    
    private func doLowercase() {
        guard !isLocked else { showLockedWarning = true; return }
        sequence.registerUndo()
        let before = String(seqString.prefix(selectionStart))
        let sel = selectedSubstring().lowercased()
        let after = String(seqString.suffix(from: seqString.index(seqString.startIndex, offsetBy: min(selectionEnd, seqString.count))))
        sequence.sequence = before + sel + after
    }
    
    private func doAntiparallel() {
        guard !isLocked else { showLockedWarning = true; return }
        sequence.registerUndo()
        let before = String(seqString.prefix(selectionStart))
        let anti = DNASequence.reverseComplementString(selectedSubstring())
        let after = String(seqString.suffix(from: seqString.index(seqString.startIndex, offsetBy: min(selectionEnd, seqString.count))))
        sequence.sequence = before + anti + after
    }
    
    // MARK: - Rendering
    
    private func groupSpacer(beforePosition: Int, afterPosition: Int) -> some View {
        let bg = spacerBackground(before: beforePosition, after: afterPosition)
        return Rectangle().fill(bg).frame(width: groupSpaceWidth, height: fontSize + 2)
    }
    
    private func spacerBackground(before: Int, after: Int) -> Color {
        // Colour the spacer blue when it falls within a selection so the
        // selection highlight spans group boundaries seamlessly.
        // Feature colouring is intentionally omitted: the character backgrounds
        // already show features, and colouring the 5pt spacer rectangle too
        // creates visible bars at every group boundary.
        if before >= selectionStart && before < selectionEnd
            && after >= selectionStart && after < selectionEnd {
            return .blue
        }
        return .clear
    }
    
    private func isPositionInFeature(_ position: Int, feature: Feature) -> Bool {
        let lo = min(feature.start, feature.end)
        let hi = max(feature.start, feature.end)
        return position >= lo && position < hi
    }
    
    private func positionFromPoint(_ point: CGPoint) -> Int? {
        let charWidth = cachedCharWidth > 0 ? cachedCharWidth : {
            let f = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            return f.advancement(forGlyph: f.glyph(withName: "A")).width
        }()
        let lineHeight = cachedLineHeight > 0 ? cachedLineHeight : {
            let f = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            return ceil(f.ascender - f.descender + f.leading) + 2
        }()
        let lineNumberWidth: CGFloat = fontSize * 5 + 6
        
        let lineNumber = Int(point.y / lineHeight)
        guard lineNumber >= 0 && lineNumber < numberOfLines else { return nil }
        
        let xOffset = point.x - lineNumberWidth
        guard xOffset >= 0 else { return nil }
        
        var charInLine = 0
        var accumulatedX: CGFloat = 0
        let lineBasesCount = basesInLine(lineNumber)
        
        for i in 0..<lineBasesCount {
            let nextX = accumulatedX + charWidth
            // Click past the halfway point of a character = next position
            if accumulatedX + charWidth * 0.5 > xOffset { break }
            accumulatedX = nextX
            charInLine = i + 1
            if (i + 1) % basesPerGroup == 0 && i + 1 < lineBasesCount {
                accumulatedX += groupSpaceWidth
            }
        }
        
        let position = lineNumber * basesPerLine + min(charInLine, lineBasesCount)
        return min(position, seqString.count)
    }
    
    private var numberOfLines: Int {
        max(1, (seqString.count + basesPerLine - 1) / basesPerLine)
    }
    
    private func basesInLine(_ lineIndex: Int) -> Int {
        let remaining = seqString.count - lineIndex * basesPerLine
        return max(0, min(basesPerLine, remaining))
    }
    
    private func characterView(at position: Int, chars: [Character]) -> some View {
        guard position < chars.count else {
            return AnyView(Text(" ").font(.system(size: fontSize, design: .monospaced)))
        }
        let char = String(chars[position])
        let isSelected = position >= selectionStart && position < selectionEnd
        let isCursor = (selectionStart == selectionEnd) && position == selectionStart
        
        let bg: Color = {
            if isSelected { return .blue }
            
            // Check explicit highlight ranges (search, ORFs, restriction sites)
            for hr in highlightRanges {
                if position >= hr.start && position < hr.end { return hr.color }
            }
            
            // O(1) feature colour lookup — map is precomputed in buildFeatureColorMap()
            if let featureColor = featureColorMap[position] { return featureColor }
            return .clear
        }()
        
        let textColor: Color = {
            if isSelected { return .white }
            let upperChar = char.uppercased().first ?? "N"
            if "RYSWKMBDHVN".contains(upperChar) { return .orange }
            return .primary
        }()
        
        return AnyView(
            Text(char)
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
    
    /// Cursor position after the very last base in the sequence
    private var endOfSequenceCursor: some View {
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


// MARK: - Mouse Tracking Overlay (reliable macOS mouse events)
/// NSViewRepresentable that captures mouse events and reports positions.
/// Also handles keyboard shortcuts for copy/cut/paste/selectAll/delete.
struct MouseTrackingOverlay: NSViewRepresentable {
    var onMouseDown: (CGPoint, NSEvent.ModifierFlags) -> Void
    var onMouseDragged: (CGPoint, NSEvent.ModifierFlags) -> Void
    var onMouseUp: (CGPoint, NSEvent.ModifierFlags) -> Void
    var onCopy: (() -> Void)?
    var onCut: (() -> Void)?
    var onPaste: (() -> Void)?
    var onSelectAll: (() -> Void)?
    var onDelete: (() -> Void)?
    var onMakeUppercase: (() -> Void)?
    var onMakeLowercase: (() -> Void)?
    var onInsertText: ((String) -> Void)?
    var onMoveCursor: ((Int) -> Void)?
    var onExtendSelection: ((Int) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    
    func makeNSView(context: Context) -> MouseTrackingNSView {
        let view = MouseTrackingNSView()
        view.onMouseDown = onMouseDown
        view.onMouseDragged = onMouseDragged
        view.onMouseUp = onMouseUp
        view.onCopy = onCopy
        view.onCut = onCut
        view.onPaste = onPaste
        view.onSelectAll = onSelectAll
        view.onDelete = onDelete
        view.onMakeUppercase = onMakeUppercase
        view.onMakeLowercase = onMakeLowercase
        view.onInsertText = onInsertText
        view.onMoveCursor = onMoveCursor
        view.onExtendSelection = onExtendSelection
        view.onUndo = onUndo
        view.onRedo = onRedo
        return view
    }
    
    func updateNSView(_ nsView: MouseTrackingNSView, context: Context) {
        nsView.onMouseDown = onMouseDown
        nsView.onMouseDragged = onMouseDragged
        nsView.onMouseUp = onMouseUp
        nsView.onCopy = onCopy
        nsView.onCut = onCut
        nsView.onPaste = onPaste
        nsView.onSelectAll = onSelectAll
        nsView.onDelete = onDelete
        nsView.onMakeUppercase = onMakeUppercase
        nsView.onMakeLowercase = onMakeLowercase
        nsView.onInsertText = onInsertText
        nsView.onMoveCursor = onMoveCursor
        nsView.onExtendSelection = onExtendSelection
        nsView.onUndo = onUndo
        nsView.onRedo = onRedo
    }
}

class MouseTrackingNSView: NSView {
    var onMouseDown: ((CGPoint, NSEvent.ModifierFlags) -> Void)?
    var onMouseDragged: ((CGPoint, NSEvent.ModifierFlags) -> Void)?
    var onMouseUp: ((CGPoint, NSEvent.ModifierFlags) -> Void)?
    var onCopy: (() -> Void)?
    var onCut: (() -> Void)?
    var onPaste: (() -> Void)?
    var onSelectAll: (() -> Void)?
    var onDelete: (() -> Void)?
    var onMakeUppercase: (() -> Void)?
    var onMakeLowercase: (() -> Void)?
    var onInsertText: ((String) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onMoveCursor: ((Int) -> Void)?
    var onExtendSelection: ((Int) -> Void)?
    
    override var acceptsFirstResponder: Bool { true }
    
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Become first responder so Cmd+C/V work without clicking first.
        // Called directly — no async dispatch needed since viewDidMoveToWindow
        // runs on the main thread after the window hierarchy is set up.
        window?.makeFirstResponder(self)
    }
    
    /// Convert NSView coordinates (origin bottom-left) to SwiftUI coordinates (origin top-left)
    private func flippedPoint(for event: NSEvent) -> CGPoint {
        let loc = convert(event.locationInWindow, from: nil)
        return CGPoint(x: loc.x, y: bounds.height - loc.y)
    }
    
    override func mouseDown(with event: NSEvent) {
        // Become first responder so responder-chain actions come here
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            // Double-click selects the entire sequence
            onSelectAll?()
        } else {
            onMouseDown?(flippedPoint(for: event), event.modifierFlags)
        }
    }
    
    override func mouseDragged(with event: NSEvent) {
        onMouseDragged?(flippedPoint(for: event), event.modifierFlags)
    }
    
    override func mouseUp(with event: NSEvent) {
        onMouseUp?(flippedPoint(for: event), event.modifierFlags)
    }

    // MARK: - Standard responder-chain actions (Edit menu Cmd+C/X/V/A/Delete)
    // These are called by the menu bar and by keyboard shortcuts through the responder chain.
    
    @objc func copy(_ sender: Any?) {
        onCopy?()
    }
    
    @objc func cut(_ sender: Any?) {
        onCut?()
    }
    
    @objc func paste(_ sender: Any?) {
        onPaste?()
    }
    
    @objc override func selectAll(_ sender: Any?) {
        onSelectAll?()
    }
    
    @objc func delete(_ sender: Any?) {
        onDelete?()
    }
    
    @objc func makeUppercase(_ sender: Any?) {
        onMakeUppercase?()
    }
    
    @objc func makeLowercase(_ sender: Any?) {
        onMakeLowercase?()
    }
    
    // Standard NSResponder selectors — called by NSApp.sendAction from the Edit menu.
    // Only handle when our window is the key window to prevent background editors
    // from intercepting actions meant for other windows (e.g. PCR text fields).
    @objc override func uppercaseWord(_ sender: Any?) {
        guard window?.isKeyWindow == true else { return }
        onMakeUppercase?()
    }
    
    @objc override func lowercaseWord(_ sender: Any?) {
        guard window?.isKeyWindow == true else { return }
        onMakeLowercase?()
    }
    
    override func keyDown(with event: NSEvent) {
        // Undo: Cmd+Z
        if event.keyCode == 6 && event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.shift) {
            onUndo?()
            return
        }
        // Redo: Shift+Cmd+Z
        if event.keyCode == 6 && event.modifierFlags.contains(.command) && event.modifierFlags.contains(.shift) {
            onRedo?()
            return
        }
        
        // Delete/Backspace key
        if event.keyCode == 51 || event.keyCode == 117 {
            onDelete?()
            return
        }
        
        // Shift+Arrow to extend selection
        if (event.keyCode == 123 || event.keyCode == 124) && event.modifierFlags.contains(.shift) {
            onExtendSelection?(event.keyCode == 123 ? -1 : 1)
            return
        }
        
        // Arrow keys for cursor movement
        // Left arrow = keyCode 123, Right arrow = keyCode 124
        if event.keyCode == 123 {
            onMoveCursor?(-1)
            return
        }
        if event.keyCode == 124 {
            onMoveCursor?(1)
            return
        }
        
        // If no modifier keys (except shift for uppercase), treat as text input
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if modifiers.isEmpty, let chars = event.characters, !chars.isEmpty {
            onInsertText?(chars)
            return
        }
        
        super.keyDown(with: event)
    }
    
    // Tell the menu system which actions we can handle
    override func responds(to aSelector: Selector!) -> Bool {
        if aSelector == #selector(copy(_:)) { return onCopy != nil }
        if aSelector == #selector(cut(_:)) { return onCut != nil }
        if aSelector == #selector(paste(_:)) { return onPaste != nil }
        if aSelector == #selector(selectAll(_:)) { return onSelectAll != nil }
        if aSelector == #selector(delete(_:)) { return onDelete != nil }
        if aSelector == #selector(makeUppercase(_:)) { return onMakeUppercase != nil }
        if aSelector == #selector(makeLowercase(_:)) { return onMakeLowercase != nil }
        return super.responds(to: aSelector)
    }
}


// MARK: - Selection Info Panel (Serial Cloner style - manual page 13)
struct SelectionInfoView: View {
    @ObservedObject var sequence: DNASequence
    @EnvironmentObject var sequenceManager: SequenceManager
    let selectionStart: Int
    let selectionEnd: Int
    
    @State private var translateOppositeStrand: Bool = false
    @State private var showOnlyFirstORF: Bool = true
    @State private var translationFrameFrom: Int = 1
    
    private let naConcentration: Double = 0.050
    
    private var selLen: Int { max(0, selectionEnd - selectionStart) }
    
    private var selectedSeq: String {
        let seq = sequence.sequence
        guard selectionStart >= 0 && selectionEnd <= seq.count && selectionStart < selectionEnd else { return "" }
        let start = seq.index(seq.startIndex, offsetBy: selectionStart)
        let end = seq.index(seq.startIndex, offsetBy: selectionEnd)
        return String(seq[start..<end])
    }
    
    private var upperSeq: String { selectedSeq.uppercased() }
    private var aCount: Int { upperSeq.filter { $0 == "A" }.count }
    private var cCount: Int { upperSeq.filter { $0 == "C" }.count }
    private var gCount: Int { upperSeq.filter { $0 == "G" }.count }
    private var tCount: Int { upperSeq.filter { $0 == "T" }.count }
    
    private var gcPercent: Double {
        guard !upperSeq.isEmpty else { return 0 }
        return Double(gCount + cCount) / Double(upperSeq.count) * 100
    }
    
    /// Tm using Serial Cloner's 3-tier formula from manual
    private var tm: Double {
        let gc = gCount + cCount
        let at = aCount + tCount
        let total = gc + at
        guard total > 0 else { return 0 }
        let logNa = log10(naConcentration)
        
        if total < 14 {
            return Double(at * 2 + gc * 4) - 16.6 * log10(0.050) + 16.6 * logNa
        } else if total <= 51 {
            return 100.5 + 41.0 * Double(gc) / Double(total) - 820.0 / Double(total) + 16.6 * logNa
        } else {
            return 81.5 + 41.0 * Double(gc) / Double(total) - 500.0 / Double(total) + 16.6 * logNa
        }
    }
    
    private var dnaForTranslation: String {
        var dna = upperSeq
        if translateOppositeStrand { dna = reverseComplement(dna) }
        let offset = max(0, translationFrameFrom - 1)
        if offset > 0 && offset < dna.count { dna = String(dna.dropFirst(offset)) }
        return dna
    }
    
    private var fullProtein: String { translateDNA(dnaForTranslation) }
    private var displayProtein: String { showOnlyFirstORF ? firstORF(from: fullProtein) : fullProtein }
    private var aaCount: Int { displayProtein.replacingOccurrences(of: "*", with: "").count }
    private var mw: Double {
        guard aaCount > 0 else { return 0 }
        return (Double(aaCount) * 128.16 - Double(aaCount - 1) * 18.015) / 1000.0
    }
    private var pi: Double { isoelectricPoint(protein: displayProtein) }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if selLen > 0 {
                dnaInfoSection
                Divider()
                translationSection
            } else {
                Text("No selection \u{2014} click and drag in the sequence to select bases")
                    .font(.system(size: 12)).foregroundColor(.secondary).padding(8)
            }
        }
        .background(Color(.controlBackgroundColor))
    }
    
    private var dnaInfoSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Selected DNA").font(.system(size: 12, weight: .bold)).foregroundColor(.secondary)
            HStack(spacing: 16) {
                Text("Tm: \(String(format: "%.1f", tm))")
                    .font(.system(size: 12, design: .monospaced))
                Divider().frame(height: 14)
                HStack(spacing: 10) {
                    Text("A: \(aCount)")
                    Text("C: \(cCount)")
                    Text("G: \(gCount)")
                    Text("T: \(tCount)")
                }
                .font(.system(size: 12, design: .monospaced))
                Divider().frame(height: 14)
                Text("%GC: \(String(format: "%.1f%%", gcPercent))")
                    .font(.system(size: 12, design: .monospaced))
            }
        }
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)
    }
    
    private var translationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                Toggle("Translate opposite strand", isOn: $translateOppositeStrand)
                    .font(.system(size: 12)).toggleStyle(.checkbox)
                Spacer()
                Toggle("Show only 1st ORF", isOn: $showOnlyFirstORF)
                    .font(.system(size: 12)).toggleStyle(.checkbox)
            }
            
            if selLen >= 3 {
                Text("Translation").font(.system(size: 12, weight: .bold)).foregroundColor(.secondary)
                
                HStack(spacing: 16) {
                    Text("Size (aa): \(aaCount)").font(.system(size: 12, design: .monospaced))
                    Text("MW: \(String(format: "%.2f", mw)) kDa").font(.system(size: 12, design: .monospaced))
                    Text("pI: \(String(format: "%.2f", pi))").font(.system(size: 12, design: .monospaced))
                    Spacer()
                    HStack(spacing: 4) {
                        Text("Frame").font(.system(size: 12)).foregroundColor(.secondary)
                        TextField("", value: $translationFrameFrom, format: .number)
                            .frame(width: 30).textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
                
                // Insert zero-width spaces so lines break without hyphens
                let zwsp = "\u{200B}"
                let wrappableProtein = displayProtein.map { String($0) }.joined(separator: zwsp)
                Text(wrappableProtein)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(nil)
                    .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(6)
                    .background(Color(.textBackgroundColor))
                    .cornerRadius(4)
                    .contextMenu {
                        Button("Select All Translation") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(displayProtein, forType: .string)
                        }
                        Button("Copy Translation") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(displayProtein, forType: .string)
                        }
                        Divider()
                        Button("Open in Protein Window...") { openAsProteinWindow() }
                    }
                
                HStack(spacing: 8) {
                    Button("Open in Protein Window...") { openAsProteinWindow() }
                        .controlSize(.small)
                    Spacer()
                }
            } else {
                Text("Selection too short for translation (< 3 bp)")
                    .font(.system(size: 12)).foregroundColor(.secondary).italic()
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }
    
    private func saveFastaProtein() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(sequence.name)_protein.fasta"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                let fasta = ">\(sequence.name) translated protein [\(selectionStart+1)..\(selectionEnd)]\n\(displayProtein)"
                try? fasta.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
    
    private func openAsProteinWindow() {
        let proteinStr = displayProtein.replacingOccurrences(of: "*", with: "")
        guard !proteinStr.isEmpty else { return }
        
        let regionLabel = "\(selectionStart + 1)..\(selectionEnd)"
        let protein = ProteinSequence(
            name: "\(sequence.name) [\(regionLabel)]",
            sequence: proteinStr,
            isCircular: false
        )
        protein.description = "Translated from \(sequence.name) positions \(regionLabel)"
        
        sequenceManager.proteinSequences.append(protein)
        sequenceManager.currentProtein = protein
        ProteinWindowOpener.shared.openProteinWindow(protein.id)
    }
    
    private static let complementMap: [Character: Character] = [
        "A": "T", "T": "A", "G": "C", "C": "G",
        "R": "Y", "Y": "R", "S": "S", "W": "W",
        "K": "M", "M": "K", "B": "V", "V": "B",
        "D": "H", "H": "D", "N": "N"
    ]

    private func reverseComplement(_ seq: String) -> String {
        String(seq.reversed().map { Self.complementMap[$0] ?? $0 })
    }
    
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
    
    private func translateDNA(_ dna: String) -> String {
        var protein = ""
        let chars = Array(dna)
        var i = 0
        while i + 2 < chars.count {
            let codon = String(chars[i...i+2])
            protein.append(Self.codonTable[codon] ?? "X")
            i += 3
        }
        return protein
    }
    
    private func firstORF(from protein: String) -> String {
        guard let mIndex = protein.firstIndex(of: "M") else { return protein }
        let fromM = protein[mIndex...]
        if let stopIndex = fromM.firstIndex(of: "*") {
            return String(fromM[...stopIndex])
        }
        return String(fromM)
    }
    
    private func isoelectricPoint(protein: String) -> Double {
        let seq = protein.replacingOccurrences(of: "*", with: "")
        guard !seq.isEmpty else { return 0 }
        
        let nD = seq.filter { $0 == "D" }.count
        let nE = seq.filter { $0 == "E" }.count
        let nC = seq.filter { $0 == "C" }.count
        let nY = seq.filter { $0 == "Y" }.count
        let nH = seq.filter { $0 == "H" }.count
        let nK = seq.filter { $0 == "K" }.count
        let nR = seq.filter { $0 == "R" }.count
        
        let pK_D = 3.9, pK_E = 4.1, pK_C = 8.3, pK_Y = 10.1
        let pK_H = 6.5, pK_K = 10.8, pK_R = 12.5
        let pK_NH2 = 8.6, pK_COOH = 3.6
        
        func charge(at pH: Double) -> Double {
            func pos(_ pK: Double, _ n: Int) -> Double { Double(n) / (1.0 + pow(10, pH - pK)) }
            func neg(_ pK: Double, _ n: Int) -> Double { -Double(n) / (1.0 + pow(10, pK - pH)) }
            return pos(pK_NH2, 1) + pos(pK_H, nH) + pos(pK_K, nK) + pos(pK_R, nR)
                 + neg(pK_COOH, 1) + neg(pK_D, nD) + neg(pK_E, nE) + neg(pK_C, nC) + neg(pK_Y, nY)
        }
        
        var low = 0.0, high = 14.0
        for _ in 0..<200 {
            let mid = (low + high) / 2.0
            if charge(at: mid) > 0 { low = mid } else { high = mid }
        }
        return (low + high) / 2.0
    }
}


// MARK: - Find Drawer (Manual section B)
struct FindDrawerView: View {
    @ObservedObject var sequence: DNASequence
    @Binding var selectionStart: Int
    @Binding var selectionEnd: Int
    @Binding var isShowing: Bool
    @Binding var highlightRanges: [HighlightRange]
    
    @State private var searchQuery: String = ""
    @State private var orfMinSizeText: String = "100"
    @State private var selectedFindTab: FindTab = .sequence
    @State private var searchBothStrands: Bool = true
    @State private var searchResults: [SearchResult] = []
    @State private var orfModelResults: [DNASequence.ORFResult] = []
    @State private var selectedORFIDs: Set<UUID> = []
    @State private var selectedEnzyme: String = ""
    @State private var enzymeFilter: String = ""
    @State private var orfSortOrder: ORFSortOrder = .size

    // Cache of enzyme name → has-sites-in-current-sequence.
    // Rebuilt on a background thread when the sequence changes.
    // Prevents re-running a regex scan for every visible enzyme on every render.
    @State private var enzymeHasSitesCache: [String: Bool] = [:]

    // True while ORF scan is running on background thread.
    @State private var isSearchingORFs = false
    
    enum ORFSortOrder: String, CaseIterable {
        case position = "Position"
        case size = "Size"
        case strand = "Strand"
    }
    
    enum FindTab: String, CaseIterable {
        case sequence = "Sequence"
        case site = "Site"
        case orfs = "ORFs"
    }
    
    struct SearchResult: Identifiable {
        let id = UUID()
        let position: Int
        let size: Int
        let strand: String
        let matchText: String
    }
    
    /// Common restriction enzymes
    private static let commonEnzymes: [(name: String, site: String)] = [
        ("AarI", "CACCTGC"), ("AatII", "GACGTC"), ("AccI", "GTMKAC"),
        ("Acc65I", "GGTACC"), ("AciI", "CCGC"), ("AfeI", "AGCGCT"),
        ("AflII", "CTTAAG"), ("AgeI", "ACCGGT"), ("AluI", "AGCT"),
        ("ApaI", "GGGCCC"), ("ApaLI", "GTGCAC"), ("AscI", "GGCGCGCC"),
        ("AseI", "ATTAAT"), ("AvaI", "CYCGRG"), ("AvrII", "CCTAGG"),
        ("BamHI", "GGATCC"), ("BanI", "GGYRCC"), ("BanII", "GRGCYC"),
        ("BbsI", "GAAGAC"), ("BclI", "TGATCA"), ("BglI", "GCCNNNNNGGC"),
        ("BglII", "AGATCT"), ("BlpI", "GCTNAGC"), ("BmrI", "ACTGGG"),
        ("BpmI", "CTGGAG"), ("BsaI", "GGTCTC"), ("BsiWI", "CGTACG"),
        ("BsmBI", "CGTCTC"), ("BsmI", "GAATGC"), ("BspEI", "TCCGGA"),
        ("BspHI", "TCATGA"), ("BsrGI", "TGTACA"), ("BssHII", "GCGCGC"),
        ("BstBI", "TTCGAA"), ("BstEII", "GGTNACC"), ("BstNI", "CCWGG"),
        ("BstUI", "CGCG"), ("BstXI", "CCANNNNNNTGG"),
        ("ClaI", "ATCGAT"), ("DdeI", "CTNAG"), ("DpnI", "GATC"),
        ("DraI", "TTTAAA"), ("EagI", "CGGCCG"), ("EarI", "CTCTTC"),
        ("EcoNI", "CCTNNNNNAGG"), ("EcoRI", "GAATTC"), ("EcoRV", "GATATC"),
        ("FokI", "GGATG"), ("FseI", "GGCCGGCC"), ("FspI", "TGCGCA"),
        ("HaeII", "RGCGCY"), ("HaeIII", "GGCC"), ("HgaI", "GACGC"),
        ("HhaI", "GCGC"), ("HincII", "GTYRAC"), ("HindIII", "AAGCTT"),
        ("HinfI", "GANTC"), ("HpaI", "GTTAAC"), ("HpaII", "CCGG"),
        ("KasI", "GGCGCC"), ("KpnI", "GGTACC"),
        ("MboI", "GATC"), ("MfeI", "CAATTG"), ("MluI", "ACGCGT"),
        ("MscI", "TGGCCA"), ("MseI", "TTAA"), ("MspI", "CCGG"),
        ("NaeI", "GCCGGC"), ("NarI", "GGCGCC"), ("NcoI", "CCATGG"),
        ("NdeI", "CATATG"), ("NheI", "GCTAGC"), ("NlaIII", "CATG"),
        ("NotI", "GCGGCCGC"), ("NruI", "TCGCGA"), ("NsiI", "ATGCAT"),
        ("PacI", "TTAATTAA"), ("PciI", "ACATGT"), ("PmeI", "GTTTAAAC"),
        ("PmlI", "CACGTG"), ("PstI", "CTGCAG"), ("PvuI", "CGATCG"),
        ("PvuII", "CAGCTG"), ("RsaI", "GTAC"),
        ("SacI", "GAGCTC"), ("SacII", "CCGCGG"), ("SalI", "GTCGAC"),
        ("SapI", "GCTCTTC"), ("Sau3AI", "GATC"), ("ScaI", "AGTACT"),
        ("SfiI", "GGCCNNNNNGGCC"), ("SmaI", "CCCGGG"),
        ("SnaBI", "TACGTA"), ("SpeI", "ACTAGT"), ("SphI", "GCATGC"),
        ("SspI", "AATATT"), ("StuI", "AGGCCT"), ("SwaI", "ATTTAAAT"),
        ("TaqI", "TCGA"), ("XbaI", "TCTAGA"), ("XhoI", "CTCGAG"),
        ("XmaI", "CCCGGG"), ("XmnI", "GAANNNNTTC"),
    ]
    
    private var filteredEnzymes: [(name: String, site: String)] {
        if enzymeFilter.isEmpty { return Self.commonEnzymes }
        return Self.commonEnzymes.filter { $0.name.localizedCaseInsensitiveContains(enzymeFilter) }
    }
    
    /// Returns true if the enzyme has at least one recognition site — O(1) cache lookup.
    private func enzymeHasSites(_ enzyme: (name: String, site: String)) -> Bool {
        enzymeHasSitesCache[enzyme.name] ?? false
    }

    /// Rebuild the has-sites cache for all common enzymes on a background thread.
    private func rebuildEnzymeHasSitesCache() {
        let seq = sequence.sequence.uppercased()
        guard !seq.isEmpty else { enzymeHasSitesCache = [:]; return }
        let enzymes = Self.commonEnzymes
        DispatchQueue.global(qos: .utility).async {
            var cache: [String: Bool] = [:]
            for enzyme in enzymes {
                let pattern = enzyme.site.uppercased()
                    .map { Self.iupacMap[$0] ?? String($0) }.joined()
                guard let regex = try? NSRegularExpression(pattern: pattern) else {
                    cache[enzyme.name] = false; continue
                }
                let nsSeq = seq as NSString
                cache[enzyme.name] = regex.firstMatch(
                    in: seq, range: NSRange(location: 0, length: nsSeq.length)) != nil
            }
            DispatchQueue.main.async { self.enzymeHasSitesCache = cache }
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Fixed top section: title, tabs, controls, divider, column headers ──
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Find...").font(.headline)
                    Spacer()
                }
                .padding(.horizontal, 8).padding(.top, 8)
                
                // Tab bar
                HStack(spacing: 0) {
                    ForEach(FindTab.allCases, id: \.self) { tab in
                        Button(action: {
                            selectedFindTab = tab
                            searchResults.removeAll()
                            selectedORFIDs.removeAll()
                            sequence.orfResults.removeAll()
                            highlightRanges.removeAll()
                        }) {
                            Text(tab.rawValue)
                                .font(.system(size: 12))
                                .fontWeight(selectedFindTab == tab ? .semibold : .regular)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(selectedFindTab == tab ? Color.accentColor.opacity(0.2) : Color.clear)
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                
                // Tab content (controls only — never expands)
                switch selectedFindTab {
                case .sequence: sequenceSearchContent
                case .site:     siteSearchContent
                case .orfs:     orfSearchContent
                }
                
                Divider()
                
                // Column headers
                if selectedFindTab == .orfs {
                    HStack(spacing: 0) {
                        Color.clear.frame(width: 24)
                        Text("Position").font(.system(size: 12, weight: .semibold)).frame(width: 65, alignment: .trailing)
                        Text("nt").font(.system(size: 12, weight: .semibold)).frame(width: 45, alignment: .trailing)
                        Text("aa").font(.system(size: 12, weight: .semibold)).frame(width: 38, alignment: .trailing)
                        Text("Strand").font(.system(size: 12, weight: .semibold)).frame(width: 55, alignment: .center)
                        Spacer()
                    }
                    .padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 1)
                    .contextHelp("seq.orfColumns")
                } else if selectedFindTab == .sequence {
                    HStack {
                        Spacer()
                        Text("Position").font(.system(size: 12, weight: .semibold)).frame(width: 70, alignment: .center)
                        Text("Strand").font(.system(size: 12, weight: .semibold)).frame(width: 60, alignment: .center)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                } else if selectedFindTab == .site {
                    HStack {
                        Spacer()
                        Text("Position").font(.system(size: 12, weight: .semibold)).frame(width: 70, alignment: .center)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            // ── End fixed top section ──
            
            // ── Results list fills all remaining space ──
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(searchResults) { result in
                        Button(action: {
                            selectionStart = result.position - 1
                            if selectedFindTab == .orfs {
                                // Include 3 extra bases for stop codon so translation shows *
                                selectionEnd = min(result.position - 1 + result.size + 3, sequence.length)
                            } else {
                                selectionEnd = result.position - 1 + result.size
                            }
                            // Toggle ORF selection for Graphic Map
                            if selectedFindTab == .orfs {
                                if selectedORFIDs.contains(result.id) {
                                    selectedORFIDs.remove(result.id)
                                } else {
                                    selectedORFIDs.insert(result.id)
                                }
                                sequence.orfResults = searchResults
                                    .filter { selectedORFIDs.contains($0.id) }
                                    .compactMap { sr in orfModelResults.first { $0.position == sr.position && $0.strand == sr.strand } }
                                updateHighlights()
                            }
                        }) {
                            // Qualifier subtitle: "no ATG", "no stop", or both.
                            // ORF labels are always "ORF Naa (qualifier)" — no custom
                            // feature name is ever embedded, so we only extract the qualifier.
                            let qualifier: String = {
                                let noATG = result.matchText.contains("no ATG")
                                let noStop = result.matchText.contains("no stop")
                                if noATG && noStop { return "no ATG · no stop" }
                                if noATG { return "no ATG" }
                                if noStop { return "no stop" }
                                return ""
                            }()

                            VStack(alignment: .leading, spacing: 0) {
                                HStack(spacing: 0) {
                                    if selectedFindTab == .orfs {
                                        Image(systemName: selectedORFIDs.contains(result.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundColor(selectedORFIDs.contains(result.id) ? .accentColor : .secondary)
                                            .font(.system(size: 12))
                                            .frame(width: 24, alignment: .center)
                                    }
                                    Text("\(result.position)").font(.system(size: 12, design: .monospaced))
                                        .frame(width: 65, alignment: .trailing)
                                    if selectedFindTab == .orfs {
                                        Text("\(result.size)").font(.system(size: 12, design: .monospaced))
                                            .frame(width: 45, alignment: .trailing)
                                        Text("\(result.size / 3)").font(.system(size: 12, design: .monospaced))
                                            .frame(width: 38, alignment: .trailing)
                                            .foregroundColor(.secondary)
                                    }
                                    if selectedFindTab == .orfs || selectedFindTab == .sequence {
                                        Text(result.strand).font(.system(size: 12))
                                            .frame(width: 55, alignment: .center)
                                    }
                                    Spacer()
                                }
                                if selectedFindTab == .orfs && !qualifier.isEmpty {
                                    HStack(spacing: 4) {
                                        Color.clear.frame(width: 24)
                                        Text(qualifier)
                                            .font(.system(size: 9))
                                            .foregroundColor(.red.opacity(0.85))
                                            .lineLimit(1)
                                        Spacer()
                                    }
                                    .padding(.bottom, 1)
                                }
                            }
                            .padding(.vertical, 2).padding(.horizontal, 8)
                            .background(selectedORFIDs.contains(result.id) ? Color.accentColor.opacity(0.15) : (selectionStart == result.position - 1 && selectedFindTab != .orfs) ? Color.accentColor.opacity(0.15) : Color.clear)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            
            HStack {
                if selectedFindTab == .orfs && !selectedORFIDs.isEmpty {
                    Button("Save Selected ORFs as Features") {
                        saveSelectedORFsAsFeatures()
                    }
                    .controlSize(.small)
                }
                Spacer()
                Button("Close Drawer") { withAnimation { isShowing = false } }
                    .controlSize(.small)
                Spacer()
            }
            .padding(.bottom, 8)
        }
        .background(Color(.windowBackgroundColor))
        .onAppear { rebuildEnzymeHasSitesCache() }
        .onChange(of: sequence.sequence) { _ in rebuildEnzymeHasSitesCache() }
    }
    private var sequenceSearchContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Enter nucleotide sequence...", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { performNucleotideSearch() }
                Button(action: { performNucleotideSearch() }) {
                    Image(systemName: "return")
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 8)
            
            HStack {
                Toggle("On both strands", isOn: $searchBothStrands)
                    .font(.system(size: 12)).toggleStyle(.checkbox)
                Spacer()
                if searchResults.count > 1 {
                    Text("\(searchResults.count) found")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 8)
        }
    }
    
    // MARK: - Site Search (enzyme list)
    private var siteSearchContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Select an enzyme").font(.system(size: 12)).foregroundColor(.secondary)
                .padding(.horizontal, 8)
            
            TextField("Filter...", text: $enzymeFilter)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 8)
            
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(filteredEnzymes, id: \.name) { enzyme in
                        Button(action: {
                            selectedEnzyme = enzyme.name
                            searchEnzymeSites(enzyme)
                        }) {
                            HStack {
                                Text(enzyme.name)
                                    .font(.system(size: 12, design: .monospaced))
                                    .fontWeight(selectedEnzyme == enzyme.name ? .bold : .regular)
                                    .italic(!enzymeHasSites(enzyme))
                                    .foregroundColor(enzymeHasSites(enzyme) ? .primary : .secondary)
                                Spacer()
                                Text(enzyme.site)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(enzymeHasSites(enzyme) ? .secondary : .secondary.opacity(0.5))
                                    .italic(!enzymeHasSites(enzyme))
                            }
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(selectedEnzyme == enzyme.name ? Color.accentColor.opacity(0.15) : Color.clear)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 120)
            .background(Color(.textBackgroundColor))
            .cornerRadius(4)
            .padding(.horizontal, 8)
            
            if !selectedEnzyme.isEmpty,
               let enzyme = Self.commonEnzymes.first(where: { $0.name == selectedEnzyme }) {
                HStack {
                    Text("Selected: ").font(.system(size: 12)).foregroundColor(.secondary)
                    Text(enzyme.name).font(.system(size: 12, weight: .bold, design: .monospaced))
                    Text(enzyme.site.lowercased()).font(.system(size: 12, design: .monospaced)).foregroundColor(.blue)
                }
                .padding(.horizontal, 8)
                
                Button("Find Sites") { searchEnzymeSites(enzyme) }
                    .controlSize(.small).padding(.horizontal, 8)
            }
        }
    }
    
    // MARK: - ORF Search
    private var orfSearchContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Min ORF size (nt):").font(.system(size: 12)).foregroundColor(.secondary)
                TextField("100", text: $orfMinSizeText)
                    .textFieldStyle(.roundedBorder).frame(width: 60)
                    .font(.system(size: 12, design: .monospaced))
                Button(action: {
                    let minLen = Int(orfMinSizeText) ?? 100
                    searchORFs(seq: sequence.sequence.uppercased(), minLength: minLen)
                }) {
                    if isSearchingORFs {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Scanning…")
                        }
                    } else {
                        Text("Find ORFs")
                    }
                }
                .controlSize(.small)
                .disabled(isSearchingORFs)
            }
            .padding(.horizontal, 8)
            
            HStack {
                Text("Sort by:").font(.system(size: 12)).foregroundColor(.secondary)
                Picker("", selection: $orfSortOrder) {
                    ForEach(ORFSortOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .fixedSize()
                .contextHelp("seq.orfBothStrands")
            }
            .padding(.horizontal, 8)
            .onChange(of: orfSortOrder) { _ in
                sortORFResults()
            }
        }
        .frame(maxHeight: 58)
    }
    
    // MARK: - Search Functions
    
    private func performNucleotideSearch() {
        searchResults.removeAll()
        guard !searchQuery.isEmpty else {
            updateHighlights()
            return
        }
        searchNucleotide(seq: sequence.sequence.uppercased(), query: searchQuery.uppercased())
        updateHighlights()
    }
    
    private func searchNucleotide(seq: String, query: String) {
        var searchRange = seq.startIndex..<seq.endIndex
        while let range = seq.range(of: query, range: searchRange) {
            let pos = seq.distance(from: seq.startIndex, to: range.lowerBound) + 1
            searchResults.append(SearchResult(position: pos, size: query.count, strand: "+", matchText: query))
            searchRange = range.upperBound..<seq.endIndex
        }
        
        if searchBothStrands {
            let rcSeq = DNASequence.reverseComplementString(seq).uppercased()
            var rcRange = rcSeq.startIndex..<rcSeq.endIndex
            while let range = rcSeq.range(of: query, range: rcRange) {
                let rcPos = rcSeq.distance(from: rcSeq.startIndex, to: range.lowerBound)
                let fwdPos = seq.count - rcPos - query.count + 1
                searchResults.append(SearchResult(position: fwdPos, size: query.count, strand: "-", matchText: query))
                rcRange = range.upperBound..<rcSeq.endIndex
            }
        }
        searchResults.sort { $0.position < $1.position }
    }
    
    private func searchEnzymeSites(_ enzyme: (name: String, site: String)) {
        searchResults.removeAll()
        let seq = sequence.sequence.uppercased()
        let pattern = iupacToRegex(enzyme.site.uppercased())
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            searchNucleotide(seq: seq, query: enzyme.site.uppercased())
            return
        }
        
        let nsSeq = seq as NSString
        for match in regex.matches(in: seq, range: NSRange(location: 0, length: nsSeq.length)) {
            searchResults.append(SearchResult(
                position: match.range.location + 1, size: match.range.length,
                strand: "+", matchText: enzyme.name
            ))
        }
        
        let rcSeq = DNASequence.reverseComplementString(seq).uppercased()
        let nsRC = rcSeq as NSString
        for match in regex.matches(in: rcSeq, range: NSRange(location: 0, length: nsRC.length)) {
            let fwdPos = seq.count - match.range.location - match.range.length + 1
            let isDup = searchResults.contains { $0.position == fwdPos && $0.size == match.range.length }
            if !isDup {
                searchResults.append(SearchResult(
                    position: fwdPos, size: match.range.length,
                    strand: "-", matchText: enzyme.name
                ))
            }
        }
        searchResults.sort { $0.position < $1.position }
        updateHighlights()
    }
    
    private static let iupacMap: [Character: String] = [
        "A": "A", "C": "C", "G": "G", "T": "T",
        "R": "[AG]", "Y": "[CT]", "S": "[GC]", "W": "[AT]",
        "K": "[GT]", "M": "[AC]", "B": "[CGT]", "D": "[AGT]",
        "H": "[ACT]", "V": "[ACG]", "N": "[ACGT]"
    ]

    private func iupacToRegex(_ site: String) -> String {
        site.map { Self.iupacMap[$0] ?? String($0) }.joined()
    }
    
    private func searchORFs(seq: String, minLength: Int = 100) {
        guard !isSearchingORFs else { return }
        searchResults.removeAll()
        isSearchingORFs = true

        let seqRef = sequence   // ObservedObject ref — safe to read from bg
        DispatchQueue.global(qos: .userInitiated).async {
            let orfs = seqRef.findORFs(minNucleotides: minLength)
            var results: [SearchResult] = orfs.map { orf in
                SearchResult(position: orf.position, size: orf.size,
                             strand: orf.strand, matchText: orf.label)
            }
            // Sort by default order (size desc)
            results.sort { $0.size > $1.size }
            DispatchQueue.main.async {
                self.orfModelResults = orfs
                self.searchResults   = results
                self.isSearchingORFs = false
                self.sortORFResults()
                sequence.orfResults.removeAll()
                self.selectedORFIDs.removeAll()
                self.updateHighlights()
            }
        }
    }
    
    private func sortORFResults() {
        switch orfSortOrder {
        case .position:
            searchResults.sort { $0.position < $1.position }
        case .size:
            searchResults.sort { $0.size > $1.size }
        case .strand:
            searchResults.sort {
                if $0.strand.first == $1.strand.first { return $0.position < $1.position }
                return ($0.strand.first ?? "+") < ($1.strand.first ?? "+")
            }
        }
    }
    
    private func saveSelectedORFsAsFeatures() {
        let selectedORFs = searchResults.filter { selectedORFIDs.contains($0.id) }
        guard !selectedORFs.isEmpty else { return }
        
        for orf in selectedORFs {
            let start = orf.position - 1  // 0-based
            let end = start + orf.size
            let strand: Strand = orf.strand.hasPrefix("+") ? .forward : .reverse
            let aaCount = orf.size / 3
            let name = "ORF \(aaCount)aa"
            
            // Green for forward, blue for reverse
            let color: CodableColor = strand == .forward
                ? CodableColor(red: 0.2, green: 0.7, blue: 0.3)
                : CodableColor(red: 0.3, green: 0.4, blue: 0.8)
            
            // Check for duplicate: skip if a CDS feature already exists at this position
            let alreadyExists = sequence.features.contains { f in
                f.type == .cds && f.start == start && f.end == end && f.strand == strand
            }
            if alreadyExists { continue }
            
            let feature = Feature(
                name: name,
                type: .cds,
                start: start,
                end: end,
                strand: strand,
                color: color
            )
            sequence.features.append(feature)
        }
    }
    
    // MARK: - Update Highlight Ranges
    
    /// Rebuilds the highlight ranges passed to SequenceTextView using
    /// distinct colours for each search type so overlapping results are
    /// visually distinguishable.
    private func updateHighlights() {
        var ranges: [HighlightRange] = []
        
        let color: Color = {
            switch selectedFindTab {
            case .sequence:  return Color.yellow.opacity(0.45)          // DNA search
            case .site:      return Color.purple.opacity(0.30)          // Restriction sites
            case .orfs:      return Color.green.opacity(0.30)           // ORFs
            }
        }()
        
        if selectedFindTab == .orfs {
            // Only highlight selected (checked) ORFs
            for result in searchResults where selectedORFIDs.contains(result.id) {
                let start = result.position - 1
                let end = start + result.size
                ranges.append(HighlightRange(start: start, end: end, color: color))
            }
        } else {
            // Highlight all results for sequence/site search
            for result in searchResults {
                let start = result.position - 1
                let end = start + result.size
                ranges.append(HighlightRange(start: start, end: end, color: color))
            }
        }
        
        highlightRanges = ranges
    }
}


// MARK: - Features Tab
struct FeaturesTabView: View {
    @ObservedObject var sequence: DNASequence
    var isLocked: Bool
    @Binding var selectionStart: Int
    @Binding var selectionEnd: Int
    
    @State private var selectedFeatureID: UUID?
    @State private var showAddFeature: Bool = false
    @State private var editingFeature: Feature?
    
    @State private var newName: String = ""
    @State private var newType: FeatureType = .gene
    @State private var newStart: Int = 1
    @State private var newEnd: Int = 100
    @State private var newStrand: Strand = .forward
    @State private var newColor: Color = .blue
    @State private var newShowArrow: Bool = false
    
    @State private var showScanAlert: Bool = false
    @State private var scanMessage: String = ""
    @State private var showSaveAlert: Bool = false
    @State private var saveMessage: String = ""
    @State private var showSaveAllConfirm: Bool = false
    @State private var showDuplicateConfirm: Bool = false
    @State private var duplicateWarningMessage: String = ""
    @State private var pendingDuplicateItem: FeatureLibraryItem? = nil
    @State private var showClearScanConfirm: Bool = false
    @State private var showClearDuplicatesAlert: Bool = false
    @State private var clearDuplicatesMessage: String = ""
    @AppStorage("hideImportedFeatures") private var hideImportedFeatures: Bool = false
    
    @ObservedObject private var library = FeatureLibraryManager.shared
    
    /// Features visible in the list, respecting the hideImportedFeatures toggle.
    private var displayedFeatures: [Feature] {
        hideImportedFeatures
            ? sequence.features.filter { $0.source != .imported }
            : sequence.features
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(hideImportedFeatures
                     ? "Features (\(displayedFeatures.count)/\(sequence.features.count))"
                     : "Features (\(sequence.features.count))")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                
                if library.isScanning {
                    ProgressView().controlSize(.small).padding(.horizontal, 4)
                    Text("Scanning...").font(.system(size: 12)).foregroundColor(.secondary)
                } else {
                    Button(action: scanForFeatures) {
                        Label("Scan", systemImage: "magnifyingglass")
                    }.controlSize(.small)
                }
                
                Divider().frame(height: 16)
                
                Button(action: saveSelectedToLibrary) {
                    Label("Save to Library", systemImage: "square.and.arrow.down")
                }.controlSize(.small).disabled(selectedFeatureID == nil)
                
                Menu {
                    Button("Save Selected to Library") { saveSelectedToLibrary() }
                        .disabled(selectedFeatureID == nil)
                    Button("Save All to Library") { showSaveAllConfirm = true }
                        .disabled(sequence.features.isEmpty)
                    Divider()
                    Button("Clear Scan Results") {
                        showClearScanConfirm = true
                    }
                    .disabled(!sequence.features.contains { $0.source == .scanned })
                    Button("Clear Scan Duplicates") {
                        clearDuplicatesMessage = clearScanDuplicates()
                        showClearDuplicatesAlert = true
                    }
                    .disabled(!sequence.features.contains { $0.source == .scanned })
                    Divider()
                    Button {
                        hideImportedFeatures.toggle()
                    } label: {
                        Label(
                            hideImportedFeatures ? "Show Imported Features" : "Hide Imported Features",
                            systemImage: hideImportedFeatures ? "eye" : "eye.slash"
                        )
                    }
                    .disabled(!sequence.features.contains { $0.source == .imported })
                } label: {
                    Image(systemName: "gearshape")
                }
                .controlSize(.small).menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20)
                .contextHelp("seq.featuresMenu")
                
                Divider().frame(height: 16)
                
                Button(action: { showAddFeature.toggle() }) {
                    Label("Add Feature", systemImage: "plus")
                }.controlSize(.small)
                
                Button(action: deleteSelectedFeature) {
                    Label("Delete", systemImage: "trash")
                }
                .controlSize(.small)
                .disabled(selectedFeatureID == nil || isLocked)
            }
            .padding(8)
            
            Divider()
            
            if showAddFeature { featureForm(isEditing: false); Divider() }
            if editingFeature != nil { featureForm(isEditing: true); Divider() }
            
            ScrollView {
                LazyVStack(spacing: 1) {
                    HStack(spacing: 0) {
                        Text("Name").frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                        Text("Type").frame(width: 100, alignment: .leading)
                        Text("Start").frame(width: 60, alignment: .trailing)
                        Text("End").frame(width: 60, alignment: .trailing)
                        Text("Length").frame(width: 60, alignment: .trailing)
                        Text("AA").frame(width: 50, alignment: .trailing)
                        Text("Strand").frame(width: 60, alignment: .center)
                        Text("Arrow").frame(width: 40, alignment: .center)
                        Text("Color").frame(width: 40, alignment: .center)
                    }
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color(.controlBackgroundColor))
                    
                    ForEach(displayedFeatures) { feature in
                        featureRow(feature)
                            .contentShape(Rectangle())
                            .background(selectedFeatureID == feature.id ? Color.accentColor.opacity(0.15) : Color.clear)
                            .onTapGesture {
                                selectedFeatureID = feature.id
                                selectionStart = max(0, min(feature.start, feature.end))
                                selectionEnd = min(max(feature.start, feature.end), sequence.length)
                            }
                            .contextMenu {
                                Button("Edit Feature") { startEditing(feature) }
                                Button("Delete Feature") {
                                    sequence.features.removeAll { $0.id == feature.id }
                                    if selectedFeatureID == feature.id { selectedFeatureID = nil }
                                }
                                .disabled(isLocked)
                            }
                    }
                }
            }
        }
        .alert("Scan Results", isPresented: $showScanAlert) { Button("OK") {} } message: { Text(scanMessage) }
        .alert("Feature Library", isPresented: $showSaveAlert) { Button("OK") {} } message: { Text(saveMessage) }
        .confirmationDialog("Save All Features", isPresented: $showSaveAllConfirm) {
            Button("Save All \(sequence.features.count) Features to Library") { saveAllToLibrary() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Duplicate Feature", isPresented: $showDuplicateConfirm, titleVisibility: .visible) {
            Button("Add Anyway") {
                if let item = pendingDuplicateItem {
                    library.addToImportedCollection(item, force: true)
                    saveMessage = "'\(item.name)' added to My Features (\(item.sequence.count) bp)"
                    showSaveAlert = true
                }
                pendingDuplicateItem = nil
            }
            Button("Cancel", role: .cancel) { pendingDuplicateItem = nil }
        } message: {
            Text(duplicateWarningMessage)
        }
        .confirmationDialog("Clear Scan Results", isPresented: $showClearScanConfirm, titleVisibility: .visible) {
            Button("Clear All Scan Results", role: .destructive) {
                let before = sequence.features.count
                sequence.features.removeAll { $0.source == .scanned }
                let removed = before - sequence.features.count
                scanMessage = "Removed \(removed) scanned feature\(removed == 1 ? "" : "s")."
                showScanAlert = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let count = sequence.features.filter { $0.source == .scanned }.count
            Text("Remove all \(count) feature\(count == 1 ? "" : "s") added by the library scan? Imported and user-added features will not be affected.")
        }
        .alert("Clear Scan Duplicates", isPresented: $showClearDuplicatesAlert) {
            Button("OK") {}
        } message: {
            Text(clearDuplicatesMessage)
        }
    }
    
    private func featureRow(_ feature: Feature) -> some View {
        let lengthBP = abs(feature.end - feature.start)
        let isCoding = feature.type == .gene || feature.type == .cds
        let aaText = isCoding && lengthBP >= 3 ? "\(lengthBP / 3)" : "–"
        
        return HStack(spacing: 0) {
            Text(feature.name).frame(minWidth: 120, maxWidth: .infinity, alignment: .leading).lineLimit(1)
            Text(feature.type.displayName).frame(width: 100, alignment: .leading).lineLimit(1)
            Text("\(feature.start + 1)").frame(width: 60, alignment: .trailing)
            Text("\(feature.end)").frame(width: 60, alignment: .trailing)
            Text("\(lengthBP)").frame(width: 60, alignment: .trailing)
            Text(aaText).frame(width: 50, alignment: .trailing)
                .foregroundColor(isCoding ? .primary : .secondary)
            Text(feature.strand == .forward ? "\u{2192}" : "\u{2190}").frame(width: 60, alignment: .center)
            Image(systemName: feature.showArrow ? "arrowtriangle.right.fill" : "minus")
                .font(.system(size: 10))
                .foregroundColor(feature.showArrow ? feature.color.color : .secondary)
                .frame(width: 40, alignment: .center)
            Circle().fill(feature.color.color).frame(width: 12, height: 12).frame(width: 40, alignment: .center)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.horizontal, 8).padding(.vertical, 3)
    }
    
    private func featureForm(isEditing: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.system(size: 12)).foregroundColor(.secondary)
                TextField("Feature Name", text: $newName).textFieldStyle(.roundedBorder).frame(width: 140)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Type").font(.system(size: 12)).foregroundColor(.secondary)
                Picker("", selection: $newType) {
                    ForEach(FeatureType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }.labelsHidden().frame(width: 110)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Start").font(.system(size: 12)).foregroundColor(.secondary)
                TextField("", value: $newStart, format: .number).textFieldStyle(.roundedBorder).frame(width: 60)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("End").font(.system(size: 12)).foregroundColor(.secondary)
                TextField("", value: $newEnd, format: .number).textFieldStyle(.roundedBorder).frame(width: 60)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Strand").font(.system(size: 12)).foregroundColor(.secondary)
                Picker("", selection: $newStrand) {
                    Text("\u{2192}").tag(Strand.forward)
                    Text("\u{2190}").tag(Strand.reverse)
                }.labelsHidden().frame(width: 50)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Color").font(.system(size: 12)).foregroundColor(.secondary)
                ColorPicker("", selection: $newColor).labelsHidden().frame(width: 30)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Arrow").font(.system(size: 12)).foregroundColor(.secondary)
                Toggle("", isOn: $newShowArrow).toggleStyle(.checkbox).labelsHidden()
            }
            VStack(spacing: 2) {
                Text(" ").font(.system(size: 12))
                HStack(spacing: 4) {
                    Button(isEditing ? "Update" : "Add") {
                        if isEditing { updateFeature() } else { addFeature() }
                    }.buttonStyle(.borderedProminent).controlSize(.small)
                    Button("Cancel") { showAddFeature = false; editingFeature = nil }
                        .controlSize(.small)
                }
            }
        }
        .padding(8).background(Color(.controlBackgroundColor).opacity(0.5))
    }
    
    private func addFeature() {
        sequence.features.append(Feature(
            name: newName.isEmpty ? "New Feature" : newName,
            type: newType, start: max(0, newStart - 1),
            end: min(sequence.length, newEnd),
            strand: newStrand, color: CodableColor(newColor),
            showArrow: newShowArrow,
            source: .userAdded
        ))
        showAddFeature = false; resetForm()
    }
    
    private func updateFeature() {
        guard let editing = editingFeature,
              let idx = sequence.features.firstIndex(where: { $0.id == editing.id }) else { return }
        sequence.features[idx].name = newName
        sequence.features[idx].type = newType
        sequence.features[idx].start = max(0, newStart - 1)
        sequence.features[idx].end = min(sequence.length, newEnd)
        sequence.features[idx].strand = newStrand
        sequence.features[idx].color = CodableColor(newColor)
        sequence.features[idx].showArrow = newShowArrow
        editingFeature = nil; resetForm()
    }
    
    private func deleteSelectedFeature() {
        guard let id = selectedFeatureID else { return }
        sequence.features.removeAll { $0.id == id }
        selectedFeatureID = nil
    }
    
    private func startEditing(_ feature: Feature) {
        editingFeature = feature
        newName = feature.name; newType = feature.type
        newStart = feature.start + 1; newEnd = feature.end
        newStrand = feature.strand; newColor = feature.color.color
        newShowArrow = feature.showArrow
        showAddFeature = false
    }
    
    private func resetForm() {
        newName = ""; newType = .gene; newStart = 1; newEnd = 100
        newStrand = .forward; newColor = .blue; newShowArrow = false
    }
    
    // MARK: - Library Integration
    
    private func scanForFeatures() {
        guard !library.isScanning else { return }
        let countBefore = sequence.features.count
        library.scanSequence(sequence)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.waitForScanCompletion(countBefore: countBefore)
        }
    }
    
    private func waitForScanCompletion(countBefore: Int) {
        if library.isScanning {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.waitForScanCompletion(countBefore: countBefore)
            }
            return
        }
        let results = library.scanResults
        let added = sequence.features.count - countBefore
        scanMessage = results.isEmpty
            ? "No library features found in this sequence."
            : "Scan complete: found \(results.count) matches, added \(added) new features."
        showScanAlert = true
    }

    /// Remove scanned features that overlap with an imported or user-added feature
    /// at the same locus (same name OR positions within 50bp of each other).
    /// Returns a summary message.
    @discardableResult
    private func clearScanDuplicates() -> String {
        let nonScanned = sequence.features.filter { $0.source != .scanned }
        var toRemove: Set<UUID> = []

        for scanned in sequence.features where scanned.source == .scanned {
            let isDuplicate = nonScanned.contains { existing in
                // Same name (case-insensitive)
                if existing.name.caseInsensitiveCompare(scanned.name) == .orderedSame {
                    return true
                }
                // Overlapping positions within 50bp tolerance
                let expandedStart = max(0, existing.start - 50)
                let expandedEnd   = existing.end + 50
                let overlapStart  = max(expandedStart, scanned.start)
                let overlapEnd    = min(expandedEnd, scanned.end)
                return overlapEnd > overlapStart
            }
            if isDuplicate {
                toRemove.insert(scanned.id)
            }
        }

        sequence.features.removeAll { toRemove.contains($0.id) }
        let kept = sequence.features.filter { $0.source == .scanned }.count

        if toRemove.isEmpty {
            return "No scan duplicates found — all scanned features appear to be unique."
        } else {
            return "Removed \(toRemove.count) duplicate\(toRemove.count == 1 ? "" : "s") from scan results. \(kept) scanned feature\(kept == 1 ? "" : "s") retained."
        }
    }
    
    private func saveSelectedToLibrary() {
        guard let featureID = selectedFeatureID,
              let feature = sequence.features.first(where: { $0.id == featureID }) else { return }
        saveFeatureToLibrary(feature)
    }
    
    private func saveAllToLibrary() {
        var saved = 0
        var skipped = 0
        for feature in sequence.features {
            let featureSeq = extractFeatureSequence(feature)
            guard !featureSeq.isEmpty else { continue }
            let item = FeatureLibraryItem(
                name: feature.name, sequence: featureSeq, isPeptide: false, comments: "",
                color: CodableColor(red: feature.color.red, green: feature.color.green, blue: feature.color.blue),
                showArrow: true, featureType: feature.type
            )
            library.addToImportedCollection(item)
            if library.lastAddWasDuplicate { skipped += 1 } else { saved += 1 }
        }
        saveMessage = "Saved \(saved) feature\(saved == 1 ? "" : "s") to My Features."
        if skipped > 0 { saveMessage += " \(skipped) duplicate\(skipped == 1 ? "" : "s") skipped." }
        showSaveAlert = true
    }
    
    private func saveFeatureToLibrary(_ feature: Feature) {
        let featureSeq = extractFeatureSequence(feature)
        guard !featureSeq.isEmpty else {
            saveMessage = "Could not extract sequence for '\(feature.name)'."
            showSaveAlert = true; return
        }
        let item = FeatureLibraryItem(
            name: feature.name, sequence: featureSeq, isPeptide: false, comments: "",
            color: CodableColor(red: feature.color.red, green: feature.color.green, blue: feature.color.blue),
            showArrow: true, featureType: feature.type
        )
        library.addToImportedCollection(item)
        if library.lastAddWasDuplicate {
            pendingDuplicateItem = item
            duplicateWarningMessage = "'\(feature.name)' matches '\(library.lastDuplicateExistingName)' in \"\(library.lastDuplicateInCollection)\". Add it anyway?"
            showDuplicateConfirm = true
        } else {
            saveMessage = "'\(feature.name)' saved to My Features (\(featureSeq.count) bp)"
            showSaveAlert = true
        }
    }
    
    private func extractFeatureSequence(_ feature: Feature) -> String {
        let seq = sequence.sequence
        guard !seq.isEmpty else { return "" }
        let lo = min(feature.start, feature.end)
        let hi = max(feature.start, feature.end)
        let start = max(0, lo - 1)
        let end = min(seq.count, hi)
        guard start < seq.count, end > 0, end > start else { return "" }
        let s = seq.index(seq.startIndex, offsetBy: start)
        let e = seq.index(seq.startIndex, offsetBy: end)
        var featureSeq = String(seq[s..<e]).uppercased()
        if feature.strand == .reverse {
            featureSeq = DNASequence.reverseComplementString(featureSeq).uppercased()
        }
        return featureSeq
    }
}

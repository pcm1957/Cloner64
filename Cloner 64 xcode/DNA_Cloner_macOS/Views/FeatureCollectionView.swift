//
//  FeatureCollectionView.swift
//  Cloner 64
//
//  Feature Collection window — manage feature libraries and scan sequences.
//  Matches Serial Cloner's Feature Collection interface.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Feature Collection Window Manager
class FeatureCollectionWindowManager {
    static let shared = FeatureCollectionWindowManager()
    private var window: NSWindow?
    
    func openWindow(for sequence: DNASequence?) {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        
        let view = FeatureCollectionView(targetSequence: sequence)
        let hostingView = NSHostingView(rootView: view)
        
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Feature Collection"
        win.contentView = hostingView
        win.setFrameAutosaveName("FeatureCollection")
        if !win.setFrameUsingName(win.frameAutosaveName) { win.center() }
        win.makeKeyAndOrderFront(nil)
        win.isReleasedWhenClosed = false
        
        self.window = win
    }
}

// MARK: - Duplicate Check Window Manager
fileprivate class DuplicateCheckWindowManager {
    static let shared = DuplicateCheckWindowManager()
    private var window: NSWindow?
    
    func openWindow(groups: [DuplicateGroup]) {
        if let existing = window, existing.isVisible {
            // Update content and bring to front
            let view = DuplicateCheckView(groups: groups)
            existing.contentView = NSHostingView(rootView: view)
            existing.makeKeyAndOrderFront(nil)
            return
        }
        
        let view = DuplicateCheckView(groups: groups)
        let hostingView = NSHostingView(rootView: view)
        
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Duplicate Features"
        win.contentView = hostingView
        win.setFrameAutosaveName("DuplicateFeatures")
        if !win.setFrameUsingName(win.frameAutosaveName) { win.center() }
        win.makeKeyAndOrderFront(nil)
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 400, height: 250)
        
        self.window = win
    }
}

// MARK: - Duplicate Check View (standalone window content)
private struct DuplicateCheckView: View {
    let groups: [DuplicateGroup]
    
    var body: some View {
        VStack(spacing: 0) {
            if groups.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 32))
                        .foregroundColor(.green)
                        .padding(.bottom, 4)
                    Text("No duplicate features found.")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                let exactCount = groups.filter { $0.duplicateType == .exactSequence }.count
                let rcCount = groups.filter { $0.duplicateType == .reverseComplement }.count
                let nameCount = groups.filter { $0.duplicateType == .sameName }.count
                
                HStack(spacing: 12) {
                    if exactCount > 0 {
                        HStack(spacing: 4) {
                            Circle().fill(Color.red).frame(width: 8, height: 8)
                            Text("\(exactCount) sequence").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    if rcCount > 0 {
                        HStack(spacing: 4) {
                            Circle().fill(Color.orange).frame(width: 8, height: 8)
                            Text("\(rcCount) reverse complement").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    if nameCount > 0 {
                        HStack(spacing: 4) {
                            Circle().fill(Color.blue).frame(width: 8, height: 8)
                            Text("\(nameCount) name conflict").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                
                List {
                    ForEach(groups) { group in
                        let badgeColor: Color = {
                            switch group.duplicateType {
                            case .exactSequence: return .red
                            case .reverseComplement: return .orange
                            case .sameName: return .blue
                            }
                        }()
                        
                        Section {
                            ForEach(group.items, id: \.item.id) { entry in
                                HStack {
                                    Circle()
                                        .fill(entry.item.color.color)
                                        .frame(width: 10, height: 10)
                                    Text(entry.item.name)
                                        .font(.system(size: 12))
                                    Spacer()
                                    if group.duplicateType == .sameName {
                                        let seqPreview = entry.item.sequence.prefix(20)
                                        Text("\(seqPreview)\(entry.item.sequence.count > 20 ? "…" : "")")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                    Text(entry.collectionName)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Text(group.duplicateType.rawValue)
                                    .font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(badgeColor.opacity(0.15))
                                    .foregroundColor(badgeColor)
                                    .cornerRadius(3)
                                
                                Text(group.matchKey)
                                    .font(.system(size: 11, design: .monospaced))
                                
                                Text("(\(group.items.count) items)")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Undo Snapshot
private struct UndoSnapshot {
    let collectionIndex: Int
    let items: [FeatureLibraryItem]
    let description: String
}

// MARK: - Duplicate Result
private enum DuplicateType: String {
    case exactSequence = "Same sequence"
    case reverseComplement = "Reverse complement"
    case sameName = "Same name, different sequence"
}

private struct DuplicateGroup: Identifiable {
    let id = UUID()
    let matchKey: String           // display label for the group header
    let duplicateType: DuplicateType
    let items: [(collectionName: String, item: FeatureLibraryItem)]
}

// MARK: - Main Feature Collection View
struct FeatureCollectionView: View {
    var targetSequence: DNASequence?
    
    @ObservedObject var library = FeatureLibraryManager.shared
    
    @State private var selectedCollectionIndex: Int? = 0
    @State private var selectedItemID: UUID?
    @State private var searchText: String = ""
    
    // Editor fields (bound to selected item)
    @State private var editName: String = ""
    @State private var editSequence: String = ""
    @State private var editComments: String = ""
    @State private var editColor: Color = .blue
    @State private var editArrowShow: Bool = false
    @State private var editIsDNA: Bool = true
    @State private var editSenseOnly: Bool = false
    @State private var editFeatureType: FeatureType = .gene

    @State private var editCollectionIndex: Int = 0
    @State private var uiFontSize: CGFloat = 12
    
    // Undo stack
    @State private var undoStack: [UndoSnapshot] = []
    
    // Merge collections
    @State private var showMergePopover: Bool = false
    @State private var mergeSourceIndex: Int = 0
    @State private var mergeSkipDuplicates: Bool = true
    @State private var mergeDeleteSource: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Left: Collections + Features lists
                leftPanel
                
                Divider()
                
                // Right: Editor + scan options
                rightPanel
            }
            
            Divider()
            
            // Bottom bar
            bottomBar
        }
        .frame(minWidth: 920, minHeight: 520)
        .onAppear {
            if let idx = selectedCollectionIndex, idx < library.collections.count,
               !library.collections[idx].items.isEmpty {
                selectedItemID = library.collections[idx].items[0].id
                loadItemIntoEditor(library.collections[idx].items[0])
            }
        }
    }
    
    // MARK: - Left Panel (Collections + Features)
    private var leftPanel: some View {
        VStack(spacing: 0) {
            // Global search bar — filters features across ALL collections
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: uiFontSize))
                    .foregroundColor(.secondary)
                TextField("Search features in all collections…", text: $searchText)
                    .font(.system(size: uiFontSize))
                    .textFieldStyle(.roundedBorder)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(.controlBackgroundColor))
            .onChange(of: searchText) { newValue in
                // When the user starts typing, auto-jump to the first
                // collection that contains at least one matching feature
                // (if the current selection has no matches).
                guard !newValue.isEmpty else { return }
                let currentHasMatch: Bool = {
                    guard let idx = selectedCollectionIndex,
                          idx < library.collections.count else { return false }
                    return !filteredItems(for: idx).isEmpty
                }()
                if !currentHasMatch {
                    if let first = library.collections.indices.first(where: { !filteredItems(for: $0).isEmpty }) {
                        selectedCollectionIndex = first
                        selectedItemID = nil
                        clearEditor()
                    }
                }
            }
            
            Divider()
            
            HStack(spacing: 0) {
            // Collections list
            VStack(spacing: 0) {
                Text("Collection")
                    .font(.system(size: uiFontSize))
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color(.controlBackgroundColor))
                
                // Header row
                HStack(spacing: 4) {
                    Text("Scan")
                        .font(.system(size: uiFontSize))
                        .foregroundColor(.secondary)
                        .frame(width: 30)
                    Text("Name")
                        .font(.system(size: uiFontSize))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                
                Divider()
                
                // Collection list
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(library.collections.enumerated()), id: \.offset) { index, collection in
                            let matchCount = searchText.isEmpty ? 0 : filteredItems(for: index).count
                            HStack(spacing: 4) {
                                Toggle("", isOn: Binding(
                                    get: { library.collections[index].scanEnabled },
                                    set: { newVal in
                                        library.collections[index].scanEnabled = newVal
                                        library.saveCollections()
                                    }
                                ))
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                                .frame(width: 30)
                                
                                Text(collection.name)
                                    .font(.system(size: uiFontSize))
                                    .lineLimit(1)
                                    .foregroundColor(
                                        searchText.isEmpty || matchCount > 0
                                        ? .primary
                                        : .secondary
                                    )
                                
                                Spacer()
                                
                                if !searchText.isEmpty && matchCount > 0 {
                                    Text("\(matchCount)")
                                        .font(.system(size: max(uiFontSize - 2, 9)))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(
                                            Capsule().fill(Color.accentColor)
                                        )
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                selectedCollectionIndex == index
                                ? Color.accentColor.opacity(0.2)
                                : Color.clear
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedCollectionIndex = index
                                selectedItemID = nil
                                let items = filteredItems(for: index)
                                if !items.isEmpty {
                                    selectedItemID = items[0].id
                                    loadItemIntoEditor(items[0])
                                } else {
                                    clearEditor()
                                }
                            }
                        }
                    }
                }
                
                Divider()
                
                // Collection buttons — Add / Delete on their own row
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Button("+ Add") { addCollection() }
                            .controlSize(.regular)
                            .fixedSize()
                            .help("Add a new collection")
                            .contextHelp("fcoll.addCollection")
                        
                        Button("− Delete") { removeCollection() }
                            .controlSize(.regular)
                            .fixedSize()
                            .disabled(selectedCollectionIndex == nil)
                            .help("Delete the selected collection")
                            .contextHelp("fcoll.deleteCollection")
                        
                        Spacer()
                    }
                    
                    HStack(spacing: 6) {
                        Button("Merge") {
                            if let sel = selectedCollectionIndex {
                                mergeSourceIndex = library.collections.indices.first(where: { $0 != sel }) ?? 0
                            }
                            showMergePopover = true
                        }
                        .controlSize(.regular)
                        .fixedSize()
                        .disabled(selectedCollectionIndex == nil || library.collections.count < 2)
                        .help("Merge another collection into this one")
                        .contextHelp("fcoll.mergeCollection")
                        .popover(isPresented: $showMergePopover, arrowEdge: .top) {
                            mergePopoverContent
                        }
                        
                        Button("Import") { importFeatures() }
                            .controlSize(.regular)
                            .fixedSize()
                            .contextHelp("fcoll.importFeatures")
                        
                        Button("Export") { exportFeatures() }
                            .controlSize(.regular)
                            .fixedSize()
                            .disabled(selectedCollectionIndex == nil)
                            .contextHelp("fcoll.exportFeatures")
                        
                        Spacer()
                    }
                }
                .padding(4)
            }
            .frame(width: 200)
            
            Divider()
            
            // Features list
            VStack(spacing: 0) {
                HStack {
                    Text("Feature")
                        .font(.system(size: uiFontSize))
                        .fontWeight(.semibold)
                    
                    Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color(.controlBackgroundColor))
                
                Divider()
                
                // Feature items list with drag-to-reorder
                if let colIdx = selectedCollectionIndex, colIdx < library.collections.count {
                    List(selection: Binding(
                        get: { selectedItemID },
                        set: { newVal in
                            selectedItemID = newVal
                            if let id = newVal {
                                if let item = library.collections[colIdx].items.first(where: { $0.id == id }) {
                                    loadItemIntoEditor(item)
                                }
                            }
                        }
                    )) {
                        ForEach(Array(filteredItems(for: colIdx).enumerated()), id: \.element.id) { displayIndex, item in
                            let itemID = item.id
                            
                            HStack(spacing: 4) {
                                Toggle("", isOn: Binding(
                                    get: { item.scanEnabled },
                                    set: { newVal in
                                        if let realIndex = library.collections[colIdx].items.firstIndex(where: { $0.id == itemID }) {
                                            library.collections[colIdx].items[realIndex].scanEnabled = newVal
                                            library.saveCollections()
                                        }
                                    }
                                ))
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                                
                                Circle()
                                    .fill(item.color.color)
                                    .frame(width: 10, height: 10)
                                
                                if item.showArrow {
                                    Image(systemName: "arrowtriangle.right.fill")
                                        .font(.system(size: 8))
                                        .foregroundColor(item.color.color)
                                }
                                
                                Text(item.name)
                                    .font(.system(size: uiFontSize))
                                    .lineLimit(1)
                                
                                Spacer()
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .tag(itemID)
                            .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                        }
                        .onMove { source, destination in
                            guard searchText.isEmpty else { return }  // Only reorder when not filtering
                            pushUndo(collectionIndex: colIdx, description: "Reorder")
                            library.reorderItems(in: colIdx, from: source, to: destination)
                            // Keep selectedItemID unchanged; List will handle selection by id
                        }
                    }
                    .listStyle(.plain)
                    .environment(\.defaultMinListRowHeight, 24)
                } else {
                    Spacer()
                }
                
                Divider()
                
                // Feature buttons — Add / Delete / Duplicate on their own row
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Button("+ Add") { addItem() }
                            .controlSize(.regular)
                            .fixedSize()
                            .disabled(selectedCollectionIndex == nil)
                            .help("Add a new feature to this collection")
                            .contextHelp("fcoll.addFeature")
                        
                        Button("− Delete") { removeItem() }
                            .controlSize(.regular)
                            .fixedSize()
                            .disabled(selectedItemID == nil)
                            .help("Delete the selected feature")
                            .contextHelp("fcoll.deleteFeature")
                        
                        Button("Copy") { duplicateItem() }
                            .controlSize(.regular)
                            .fixedSize()
                            .disabled(selectedItemID == nil)
                            .help("Duplicate the selected feature")
                            .contextHelp("fcoll.copyFeature")
                        
                        Spacer()
                    }
                    
                    HStack(spacing: 6) {
                        Button(action: undoLastChange) {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(undoStack.isEmpty)
                        .help("Undo last change")
                        .contextHelp("fcoll.undo")
                        
                        Button("Dupes") { findDuplicates() }
                            .controlSize(.regular)
                            .fixedSize()
                            .help("Check for duplicate features across all collections")
                            .contextHelp("fcoll.dupes")
                        
                        Spacer()
                    }
                }
                .padding(4)
            }
            .frame(minWidth: 260)
        }
        }
    }
    
    // MARK: - Right Panel (Editor)
    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Name row with color and arrow direction
            HStack(spacing: 8) {
                Text("Name")
                    .font(.system(size: uiFontSize))
                    .foregroundColor(.secondary)
                    .frame(width: 60, alignment: .trailing)
                
                TextField("Feature name", text: $editName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: uiFontSize))
                    .frame(maxWidth: 150)
                
                ColorPicker("", selection: $editColor)
                    .labelsHidden()
                    .frame(width: 30)
                
                Toggle("Arrow", isOn: $editArrowShow)
                    .font(.system(size: uiFontSize))
                    .toggleStyle(.checkbox)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            
            // DNA / Peptide + Sense only
            HStack(spacing: 12) {
                Spacer().frame(width: 60)
                
                Picker("", selection: $editIsDNA) {
                    Text("DNA").tag(true)
                    Text("Peptide").tag(false)
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .font(.system(size: uiFontSize))
                
                Spacer()
                
                Toggle("Scan only Sense Strand", isOn: $editSenseOnly)
                    .font(.system(size: uiFontSize))
                    .toggleStyle(.checkbox)
            }
            .padding(.horizontal, 8)
            
            // Sequence
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Sequence")
                        .font(.system(size: uiFontSize))
                        .foregroundColor(.secondary)
                        .frame(width: 60, alignment: .trailing)
                    Spacer()
                }
                
                TextEditor(text: $editSequence)
                    .font(.system(size: uiFontSize, design: .monospaced))
                    .frame(height: 100)
                    .padding(2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
            }
            .padding(.horizontal, 8)
            
            // Comments
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Comments")
                        .font(.system(size: uiFontSize))
                        .foregroundColor(.secondary)
                        .frame(width: 70, alignment: .trailing)
                    Spacer()
                }
                
                TextEditor(text: $editComments)
                    .font(.system(size: uiFontSize, design: .monospaced))
                    .frame(height: 50)
                    .padding(2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
            }
            .padding(.horizontal, 8)
            
            // Category, Type, Collection dropdowns
            HStack(spacing: 12) {
                Spacer().frame(width: 50)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Type")
                        .font(.system(size: uiFontSize))
                        .foregroundColor(.secondary)
                    Picker("", selection: $editFeatureType) {
                        ForEach(FeatureType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .frame(width: 120)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Collection")
                        .font(.system(size: uiFontSize))
                        .foregroundColor(.secondary)
                    Picker("", selection: $editCollectionIndex) {
                        ForEach(Array(library.collections.enumerated()), id: \.offset) { idx, col in
                            Text(col.name).tag(idx)
                        }
                    }
                    .frame(width: 120)
                }
            }
            .padding(.horizontal, 8)
            

            
            Spacer()
            
            // Save button
            HStack {
                Spacer()
                Button("Save Changes") {
                    saveCurrentItem()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(selectedCollectionIndex == nil || selectedItemID == nil)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }
    
    // MARK: - Bottom Bar
    private var bottomBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Text("Font:")
                        .font(.system(size: uiFontSize))
                        .foregroundColor(.secondary)
                    Button(action: { uiFontSize = max(9, uiFontSize - 1) }) {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    Text("\(Int(uiFontSize))")
                        .font(.system(size: uiFontSize, design: .monospaced))
                        .frame(width: 20)
                    Button(action: { uiFontSize = min(18, uiFontSize + 1) }) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                }
                
                if !undoStack.isEmpty {
                    Text("Undo: \(undoStack.last!.description)")
                        .font(.system(size: uiFontSize - 1))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button("OK") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.return)
                .controlSize(.small)
            }
            .padding(10)
            .background(Color(.windowBackgroundColor))
        }
    }
    
    // MARK: - Filtering
    
    private func filteredItems(for collectionIndex: Int) -> [FeatureLibraryItem] {
        let items = library.collections[collectionIndex].items
        if searchText.isEmpty { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
    
    // MARK: - Editor Load/Save
    
    private func loadItemIntoEditor(_ item: FeatureLibraryItem) {
        editName = item.name
        editSequence = item.sequence
        editComments = item.comments
        editColor = item.color.color
        editArrowShow = item.showArrow
        editIsDNA = !item.isPeptide
        editSenseOnly = item.senseStrandOnly
        editFeatureType = item.featureType
        editCollectionIndex = selectedCollectionIndex ?? 0
    }
    
    private func clearEditor() {
        editName = ""
        editSequence = ""
        editComments = ""
        editColor = .blue
        editArrowShow = false
        editIsDNA = true
        editSenseOnly = false
        editFeatureType = .gene
    }
    
    private func saveCurrentItem() {
        guard let colIdx = selectedCollectionIndex,
              let selID = selectedItemID,
              colIdx < library.collections.count,
              let itemIdx = library.collections[colIdx].items.firstIndex(where: { $0.id == selID })
        else { return }
        
        // Push undo before saving
        pushUndo(collectionIndex: colIdx, description: "Edit \(editName)")
        
        var item = library.collections[colIdx].items[itemIdx]
        item.name = editName
        item.sequence = editSequence
        item.comments = editComments
        item.color = CodableColor(editColor)
        item.showArrow = editArrowShow
        item.isPeptide = !editIsDNA
        item.senseStrandOnly = editSenseOnly
        item.featureType = editFeatureType
        
        // If collection changed, move item
        if editCollectionIndex != colIdx {
            library.collections[colIdx].items[itemIdx] = item
            library.moveItem(from: colIdx, itemIndex: itemIdx, to: editCollectionIndex)
            selectedCollectionIndex = editCollectionIndex
            selectedItemID = library.collections[editCollectionIndex].items.last?.id
        } else {
            library.updateItem(in: colIdx, itemIndex: itemIdx, item: item)
        }
    }
    
    // MARK: - Undo
    
    private func pushUndo(collectionIndex: Int, description: String) {
        guard collectionIndex >= 0 && collectionIndex < library.collections.count else { return }
        let snapshot = UndoSnapshot(
            collectionIndex: collectionIndex,
            items: library.collections[collectionIndex].items,
            description: description
        )
        undoStack.append(snapshot)
        // Keep max 20 undo levels
        if undoStack.count > 20 {
            undoStack.removeFirst()
        }
    }
    
    private func undoLastChange() {
        guard let snapshot = undoStack.popLast() else { return }
        guard snapshot.collectionIndex < library.collections.count else { return }
        library.collections[snapshot.collectionIndex].items = snapshot.items
        library.saveCollections()
        
        // Refresh selection
        if let colIdx = selectedCollectionIndex, colIdx == snapshot.collectionIndex {
            if let selID = selectedItemID,
               library.collections[colIdx].items.contains(where: { $0.id == selID }) {
                if let item = library.collections[colIdx].items.first(where: { $0.id == selID }) {
                    loadItemIntoEditor(item)
                }
            } else if !library.collections[colIdx].items.isEmpty {
                selectedItemID = library.collections[colIdx].items[0].id
                loadItemIntoEditor(library.collections[colIdx].items[0])
            } else {
                selectedItemID = nil
                clearEditor()
            }
        }
    }
    
    // MARK: - Merge Collections
    
    private var mergePopoverContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Merge into: \(selectedCollectionIndex != nil ? library.collections[selectedCollectionIndex!].name : "")")
                .font(.headline)
            
            HStack {
                Text("From:")
                Picker("", selection: $mergeSourceIndex) {
                    ForEach(Array(library.collections.enumerated()), id: \.offset) { idx, col in
                        if idx != selectedCollectionIndex {
                            Text(col.name).tag(idx)
                        }
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }
            
            if mergeSourceIndex < library.collections.count {
                Text("\(library.collections[mergeSourceIndex].items.count) features in source")
                    .font(.caption).foregroundColor(.secondary)
            }
            
            Toggle("Skip items with identical sequences", isOn: $mergeSkipDuplicates)
                .font(.system(size: 12))
            
            Toggle("Delete source collection after merge", isOn: $mergeDeleteSource)
                .font(.system(size: 12))
            
            HStack {
                Spacer()
                Button("Cancel") {
                    showMergePopover = false
                }
                .controlSize(.regular)
                
                Button("Merge") {
                    mergeCollections()
                    showMergePopover = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .padding()
        .frame(width: 300)
    }
    
    private func mergeCollections() {
        guard let destIdx = selectedCollectionIndex,
              destIdx < library.collections.count,
              mergeSourceIndex < library.collections.count,
              mergeSourceIndex != destIdx else { return }
        
        pushUndo(collectionIndex: destIdx, description: "Merge \(library.collections[mergeSourceIndex].name)")
        
        let sourceItems = library.collections[mergeSourceIndex].items
        
        if mergeSkipDuplicates {
            // Build set of normalised sequences already in destination
            let existingSeqs = Set(
                library.collections[destIdx].items.map {
                    $0.sequence.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
                }
            )
            
            var added = 0
            for item in sourceItems {
                let normSeq = item.sequence.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if normSeq.isEmpty || !existingSeqs.contains(normSeq) {
                    var newItem = item
                    newItem.id = UUID()
                    library.collections[destIdx].items.append(newItem)
                    added += 1
                }
            }
            let skipped = sourceItems.count - added
            if skipped > 0 {
                #if DEBUG
                print("Merge: added \(added), skipped \(skipped) duplicates")
                #endif
            }
        } else {
            for item in sourceItems {
                var newItem = item
                newItem.id = UUID()
                library.collections[destIdx].items.append(newItem)
            }
        }
        
        if mergeDeleteSource {
            // Adjust destIdx if source was before it
            if mergeSourceIndex < destIdx {
                library.deleteCollection(at: mergeSourceIndex)
                selectedCollectionIndex = destIdx - 1
            } else {
                library.deleteCollection(at: mergeSourceIndex)
            }
        }
        
        library.saveCollections()
        
        // Refresh selection
        if let idx = selectedCollectionIndex, !library.collections[idx].items.isEmpty {
            selectedItemID = library.collections[idx].items.first?.id
            if let first = library.collections[idx].items.first {
                loadItemIntoEditor(first)
            }
        }
    }
    
    // MARK: - Duplicate Checking
    
    private func findDuplicates() {
        // Flatten all items with their collection name
        let allItems: [(collectionName: String, item: FeatureLibraryItem)] = library.collections.flatMap { col in
            col.items.map { (collectionName: col.name, item: $0) }
        }
        
        var groups: [DuplicateGroup] = []
        var usedIDs = Set<UUID>()  // track items already reported
        
        // --- 1. Exact sequence duplicates (case-insensitive) ---
        var seqMap: [String: [(collectionName: String, item: FeatureLibraryItem)]] = [:]
        for entry in allItems where !entry.item.sequence.isEmpty {
            let normalised = entry.item.sequence.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
            seqMap[normalised, default: []].append(entry)
        }
        for (seq, entries) in seqMap where entries.count > 1 {
            let preview = seq.prefix(40)
            groups.append(DuplicateGroup(
                matchKey: "\(preview)\(seq.count > 40 ? "…" : "") (\(seq.count) bp)",
                duplicateType: .exactSequence,
                items: entries
            ))
            entries.forEach { usedIDs.insert($0.item.id) }
        }
        
        // --- 2. Reverse complement matches (DNA only) ---
        // For each unique sequence, check if its RC exists as a different entry
        let uniqueSeqs = Array(seqMap.keys)
        var rcPairsChecked = Set<String>()  // avoid reporting A↔B and B↔A
        
        for seq in uniqueSeqs {
            guard !rcPairsChecked.contains(seq) else { continue }
            let rc = reverseComplement(seq)
            guard rc != seq else { continue }  // palindromic — skip
            guard let rcEntries = seqMap[rc] else { continue }
            guard let fwdEntries = seqMap[seq] else { continue }
            
            // Only report if the items are genuinely different (not already an exact duplicate)
            let combined = fwdEntries + rcEntries
            let preview = seq.prefix(40)
            groups.append(DuplicateGroup(
                matchKey: "\(preview)\(seq.count > 40 ? "…" : "") ↔ RC",
                duplicateType: .reverseComplement,
                items: combined
            ))
            rcPairsChecked.insert(seq)
            rcPairsChecked.insert(rc)
        }
        
        // --- 3. Same name, different sequence (across all collections) ---
        var nameMap: [String: [(collectionName: String, item: FeatureLibraryItem)]] = [:]
        for entry in allItems {
            let normName = entry.item.name.trimmingCharacters(in: .whitespaces).lowercased()
            nameMap[normName, default: []].append(entry)
        }
        for (name, entries) in nameMap where entries.count > 1 {
            // Only report if the sequences actually differ
            let seqs = Set(entries.map { $0.item.sequence.uppercased() })
            if seqs.count > 1 {
                groups.append(DuplicateGroup(
                    matchKey: entries.first?.item.name ?? name,
                    duplicateType: .sameName,
                    items: entries
                ))
            }
        }
        
        let duplicateGroups = groups.sorted { a, b in
            let order: [DuplicateType] = [.exactSequence, .reverseComplement, .sameName]
            let ai = order.firstIndex(of: a.duplicateType) ?? 0
            let bi = order.firstIndex(of: b.duplicateType) ?? 0
            if ai != bi { return ai < bi }
            return a.items.count > b.items.count
        }
        
        DuplicateCheckWindowManager.shared.openWindow(groups: duplicateGroups)
    }
    
    /// Simple reverse complement for duplicate checking
    private func reverseComplement(_ seq: String) -> String {
        let complement: [Character: Character] = [
            "A": "T", "T": "A", "C": "G", "G": "C",
            "R": "Y", "Y": "R", "M": "K", "K": "M",
            "S": "S", "W": "W", "B": "V", "V": "B",
            "D": "H", "H": "D", "N": "N"
        ]
        return String(seq.reversed().map { complement[$0] ?? $0 })
    }
    
    // MARK: - Actions
    
    private func addCollection() {
        library.addCollection(name: "New Collection")
        selectedCollectionIndex = library.collections.count - 1
        selectedItemID = nil
        clearEditor()
    }
    
    private func removeCollection() {
        guard let idx = selectedCollectionIndex else { return }
        // Push undo before removing
        pushUndo(collectionIndex: idx, description: "Delete Collection")
        library.deleteCollection(at: idx)
        if library.collections.isEmpty {
            selectedCollectionIndex = nil
        } else {
            selectedCollectionIndex = max(0, idx - 1)
        }
        selectedItemID = nil
        clearEditor()
    }
    
    private func addItem() {
        guard let colIdx = selectedCollectionIndex else { return }
        pushUndo(collectionIndex: colIdx, description: "Add Feature")
        let newItem = FeatureLibraryItem(
            name: "New Feature",
            sequence: "",
            color: CodableColor(Color.blue),
            showArrow: false,
            featureType: .gene
        )
        library.addItem(to: colIdx, item: newItem)
        selectedItemID = newItem.id
        loadItemIntoEditor(newItem)
    }
    
    private func removeItem() {
        guard let colIdx = selectedCollectionIndex,
              let selID = selectedItemID,
              let itemIdx = library.collections[colIdx].items.firstIndex(where: { $0.id == selID }) else { return }
        pushUndo(collectionIndex: colIdx, description: "Delete \(library.collections[colIdx].items[itemIdx].name)")
        library.deleteItem(from: colIdx, at: itemIdx)
        if library.collections[colIdx].items.isEmpty {
            selectedItemID = nil
            clearEditor()
        } else {
            let newIdx = max(0, itemIdx - 1)
            selectedItemID = library.collections[colIdx].items[newIdx].id
            loadItemIntoEditor(library.collections[colIdx].items[newIdx])
        }
    }
    
    private func duplicateItem() {
        guard let colIdx = selectedCollectionIndex,
              let selID = selectedItemID,
              let itemIdx = library.collections[colIdx].items.firstIndex(where: { $0.id == selID }) else { return }
        pushUndo(collectionIndex: colIdx, description: "Duplicate Feature")
        library.duplicateItem(in: colIdx, at: itemIdx)
        selectedItemID = library.collections[colIdx].items.last?.id
        if let last = library.collections[colIdx].items.last {
            loadItemIntoEditor(last)
        }
    }
    
    private func importFeatures() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.json]
        panel.allowsMultipleSelection = false
        panel.message = "Select a Feature Collection (.json) file to import"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                let imported = try JSONDecoder().decode(FeatureCollection.self, from: data)
                // Give it fresh UUIDs so it doesn't collide with existing collections
                var collection = imported
                collection.id = UUID()
                for i in collection.items.indices {
                    collection.items[i].id = UUID()
                }
                DispatchQueue.main.async {
                    library.collections.append(collection)
                    library.saveCollections()
                    selectedCollectionIndex = library.collections.count - 1
                }
            } catch {
                #if DEBUG
                print("Feature Collection import failed: \(error.localizedDescription)")
                #endif
                // Show an alert
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Import Failed"
                    alert.informativeText = "Could not read the file as a Feature Collection.\n\n\(error.localizedDescription)"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }
    
    private func exportFeatures() {
        guard let idx = selectedCollectionIndex,
              idx < library.collections.count else { return }
        let collection = library.collections[idx]
        
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.json]
        panel.nameFieldStringValue = "\(collection.name).json"
        panel.message = "Export Feature Collection as JSON"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(collection)
                try data.write(to: url)
            } catch {
                #if DEBUG
                print("Feature Collection export failed: \(error.localizedDescription)")
                #endif
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Export Failed"
                    alert.informativeText = "Could not save the Feature Collection.\n\n\(error.localizedDescription)"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }
}

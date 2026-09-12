import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Shuttle Vector List View

struct ShuttleVectorListView: View {
    @ObservedObject private var library = ShuttleVectorLibrary.shared
    @State private var searchText = ""
    @State private var selectedVectorID: UUID?
    @State private var showAddSheet = false
    @State private var editingVector: ShuttleVector?
    @State private var sortOrder: SortOrder = .name
    @State private var filterCategory: VectorCategory? = nil
    @State private var showMyVectorsOnly = false
    
    enum SortOrder: String, CaseIterable {
        case name = "Name"
        case category = "Category"
        case size = "Size"
        case siteCount = "MCS Sites"
        case marker = "Selection Marker"
    }
    
    private var filteredVectors: [ShuttleVector] {
        var result = library.vectors
        if showMyVectorsOnly {
            result = result.filter { library.isMyVector($0.id) }
        }
        if !searchText.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.selectionMarker.localizedCaseInsensitiveContains(searchText) ||
                $0.notes.localizedCaseInsensitiveContains(searchText) ||
                $0.mcsSites.contains(where: { $0.localizedCaseInsensitiveContains(searchText) })
            }
        }
        if let cat = filterCategory {
            result = result.filter { $0.category == cat }
        }
        switch sortOrder {
        case .name:
            result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .category:
            result.sort {
                if $0.category.rawValue == $1.category.rawValue { return $0.name < $1.name }
                return $0.category.rawValue < $1.category.rawValue
            }
        case .size:
            result.sort { $0.size < $1.size }
        case .siteCount:
            result.sort { $0.mcsSites.count > $1.mcsSites.count }
        case .marker:
            result.sort { $0.selectionMarker < $1.selectionMarker }
        }
        return result
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("Search vectors or enzymes…", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
                
                Picker("Sort:", selection: $sortOrder) {
                    ForEach(SortOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.frame(width: 170)
                
                Picker("Category:", selection: $filterCategory) {
                    Text("All").tag(nil as VectorCategory?)
                    ForEach(VectorCategory.allCases, id: \.self) { Text($0.rawValue).tag($0 as VectorCategory?) }
                }.frame(width: 190)
                
                Spacer()
                
                Toggle(isOn: $showMyVectorsOnly) {
                    Label("My Vectors", systemImage: "star.fill")
                }
                .toggleStyle(.button)
                .tint(showMyVectorsOnly ? .yellow : .primary)
                .controlSize(.small)
                .help("Show only earmarked vectors")
                .contextHelp("vectorLib.myVectorsFilter")
                
                Text("\(filteredVectors.count) of \(library.vectors.count)")
                    .font(.caption).foregroundColor(.secondary)
                
                Button(action: importFromFile) {
                    Label("Import from File…", systemImage: "square.and.arrow.down")
                }.controlSize(.small)
                
                Button(action: { showAddSheet = true }) {
                    Label("Add", systemImage: "plus")
                }.controlSize(.small)
                
                Button(action: deleteSelected) {
                    Label("Delete", systemImage: "trash")
                }.controlSize(.small).disabled(selectedVectorID == nil)
            }
            .padding(10)
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Table header
            HStack(spacing: 0) {
                Text("★").frame(width: 28, alignment: .center)
                Text("Name").frame(width: 140, alignment: .leading)
                Text("Category").frame(width: 130, alignment: .leading)
                Text("Size").frame(width: 60, alignment: .trailing)
                Text("Marker").frame(width: 120, alignment: .leading).padding(.leading, 8)
                Text("MCS Sites").frame(minWidth: 300, alignment: .leading).padding(.leading, 8)
                Spacer()
            }
            .font(.caption.weight(.semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            
            Divider()
            
            // Vector list
            List(selection: $selectedVectorID) {
                ForEach(filteredVectors) { vector in
                    vectorRow(vector)
                        .tag(vector.id)
                        .onTapGesture(count: 2) { editingVector = vector }
                }
            }
            .listStyle(.plain)
            
            Divider()
            
            // Footer
            HStack {
                Text("Double-click to edit • ★ to earmark as My Vectors • Search by vector name, enzyme, or marker • Import reads XDNA, GenBank, SnapGene, FASTA")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 900, minHeight: 450)
        .sheet(isPresented: $showAddSheet) {
            VectorEditSheet(mode: .add) { library.addVector($0) }
        }
        .sheet(item: $editingVector) { vector in
            VectorEditSheet(mode: .edit(vector)) { updated in
                library.updateVector(updated, originalID: vector.id)
            }
        }
    }
    
    private func vectorRow(_ vector: ShuttleVector) -> some View {
        HStack(spacing: 0) {
            // My Vectors star toggle
            Button(action: { library.toggleMyVector(vector.id) }) {
                Image(systemName: library.isMyVector(vector.id) ? "star.fill" : "star")
                    .foregroundColor(library.isMyVector(vector.id) ? .yellow : .primary.opacity(0.25))
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .frame(width: 28, alignment: .center)
            .help(library.isMyVector(vector.id) ? "Remove from My Vectors" : "Add to My Vectors")
            .contextHelp("vectorLib.myVectorsStar")
            
            Text(vector.name)
                .fontWeight(.medium)
                .frame(width: 140, alignment: .leading)
            
            Text(vector.category.rawValue)
                .font(.system(size: 11))
                .foregroundColor(categoryColor(vector.category))
                .frame(width: 130, alignment: .leading)
            
            Text("\(vector.size) bp")
                .fontDesign(.monospaced)
                .frame(width: 60, alignment: .trailing)
            
            Text(vector.selectionMarker)
                .foregroundColor(.secondary)
                .frame(width: 120, alignment: .leading)
                .padding(.leading, 8)
            
            Text(vector.mcsSummary)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 300, alignment: .leading)
                .padding(.leading, 8)
            
            Spacer()
        }
        .font(.system(size: 12))
        .padding(.vertical, 2)
        .help(vector.notes.isEmpty ? vector.fullName : "\(vector.fullName)\n\(vector.notes)")
    }
    
    private func categoryColor(_ cat: VectorCategory) -> Color {
        switch cat {
        case .generalCloning:       return .blue
        case .ecoliExpression:      return .green
        case .mammalianExpression:  return .purple
        case .yeastExpression:      return .orange
        case .insectExpression:     return .pink
        case .shuttle:              return .teal
        case .bac:                  return .brown
        case .phage:                return .gray
        case .custom:               return .primary
        }
    }
    
    private func deleteSelected() {
        guard let id = selectedVectorID else { return }
        library.removeVector(id: id)
        selectedVectorID = nil
    }
    
    // =========================================================================
    // MARK: Import from file
    // =========================================================================
    
    private func importFromFile() {
        let panel = NSOpenPanel()
        panel.title = "Import Vector Sequence"
        panel.allowedContentTypes = [
            UTType(filenameExtension: "xdna") ?? .data,
            UTType(filenameExtension: "dna") ?? .data,
            UTType(filenameExtension: "gb") ?? .data,
            UTType(filenameExtension: "gbk") ?? .data,
            UTType(filenameExtension: "fasta") ?? .plainText,
            UTType(filenameExtension: "fa") ?? .plainText,
            UTType(filenameExtension: "ape") ?? .data,
            .data, .plainText
        ]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        
        guard panel.runModal() == .OK else { return }
        
        for url in panel.urls {
            if let seq = parseSequenceFile(url) {
                let result = ShuttleVectorLibrary.importFromSequence(seq)
                // Open add sheet pre-populated with the import results
                editingVector = nil
                showAddSheet = false
                
                // Create the vector and add it, then open for editing
                let vector = ShuttleVector(
                    name: result.name,
                    fullName: result.name,
                    category: .custom,
                    size: result.size,
                    mcsSites: result.mcsSites,
                    selectionMarker: result.selectionMarker,
                    notes: result.notes
                )
                library.addVector(vector)
                
                // Open for editing so user can review and adjust
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    editingVector = vector
                }
            }
        }
    }
    
    /// Parse a sequence file using the app's existing parsers
    private func parseSequenceFile(_ url: URL) -> DNASequence? {
        let ext = url.pathExtension.lowercased()
        
        // Try XDNA
        if ext == "xdna" {
            return XDNAParser().parseXDNA(url)
        }
        
        // Try SnapGene
        if ext == "dna" {
            return SnapGeneParser().parseSnapGene(url)
        }
        
        // Try reading as text (GenBank, FASTA, APE)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        
        // GenBank / APE format
        if text.hasPrefix("LOCUS") || ext == "gb" || ext == "gbk" || ext == "ape" {
            return parseGenBank(text, filename: url.deletingPathExtension().lastPathComponent)
        }
        
        // FASTA
        if text.hasPrefix(">") || ext == "fasta" || ext == "fa" {
            return parseFASTA(text, filename: url.deletingPathExtension().lastPathComponent)
        }
        
        // Plain sequence
        let cleaned = text.uppercased().filter { "ACGTURYSWKMBDHVN".contains($0) }
        if cleaned.count > 10 {
            return DNASequence(name: url.deletingPathExtension().lastPathComponent, sequence: cleaned)
        }
        
        return nil
    }
    
    /// Minimal GenBank parser — extract sequence and features
    private func parseGenBank(_ text: String, filename: String) -> DNASequence? {
        let lines = text.components(separatedBy: .newlines)
        
        // Get name from LOCUS line
        var name = filename
        if let locusLine = lines.first(where: { $0.hasPrefix("LOCUS") }) {
            let parts = locusLine.split(separator: " ", maxSplits: 2)
            if parts.count >= 2 { name = String(parts[1]) }
        }
        
        // Check topology
        let isCircular = lines.first(where: { $0.hasPrefix("LOCUS") })?.lowercased().contains("circular") ?? false
        
        // Extract sequence from ORIGIN section
        var inOrigin = false
        var seqChars: [Character] = []
        for line in lines {
            if line.hasPrefix("ORIGIN") { inOrigin = true; continue }
            if line.hasPrefix("//") { break }
            if inOrigin {
                for ch in line.uppercased() {
                    if "ACGTURYSWKMBDHVN".contains(ch) { seqChars.append(ch) }
                }
            }
        }
        
        guard !seqChars.isEmpty else { return nil }
        let seq = DNASequence(name: name, sequence: String(seqChars), isCircular: isCircular)
        
        // Let the app's normal GenBank feature parser handle features
        // (we just need name + sequence + topology for MCS detection)
        return seq
    }
    
    /// Minimal FASTA parser
    private func parseFASTA(_ text: String, filename: String) -> DNASequence? {
        let lines = text.components(separatedBy: .newlines)
        var name = filename
        var seqLines: [String] = []
        
        for line in lines {
            if line.hasPrefix(">") {
                name = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else {
                seqLines.append(line.uppercased().filter { "ACGTURYSWKMBDHVN".contains($0) })
            }
        }
        
        let seq = seqLines.joined()
        guard !seq.isEmpty else { return nil }
        return DNASequence(name: name, sequence: seq)
    }
}


// MARK: - Add / Edit Sheet

struct VectorEditSheet: View {
    enum Mode: Identifiable {
        case add
        case edit(ShuttleVector)
        case addFromImport(VectorImportResult)
        
        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let v): return v.id.uuidString
            case .addFromImport: return "import"
            }
        }
        
        var isAdd: Bool {
            switch self {
            case .add, .addFromImport: return true
            case .edit: return false
            }
        }
    }
    
    let mode: Mode
    let onSave: (ShuttleVector) -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var name: String = ""
    @State private var fullName: String = ""
    @State private var category: VectorCategory = .custom
    @State private var sizeText: String = ""
    @State private var selectionMarker: String = ""
    @State private var notes: String = ""
    @State private var mcsSitesText: String = ""
    @State private var importInfo: String = ""
    
    init(mode: Mode, onSave: @escaping (ShuttleVector) -> Void) {
        self.mode = mode
        self.onSave = onSave
        
        switch mode {
        case .edit(let vector):
            _name = State(initialValue: vector.name)
            _fullName = State(initialValue: vector.fullName)
            _category = State(initialValue: vector.category)
            _sizeText = State(initialValue: String(vector.size))
            _selectionMarker = State(initialValue: vector.selectionMarker)
            _notes = State(initialValue: vector.notes)
            _mcsSitesText = State(initialValue: vector.mcsSites.joined(separator: ", "))
        case .addFromImport(let result):
            _name = State(initialValue: result.name)
            _fullName = State(initialValue: result.name)
            _category = State(initialValue: .custom)
            _sizeText = State(initialValue: String(result.size))
            _selectionMarker = State(initialValue: result.selectionMarker)
            _notes = State(initialValue: result.notes)
            _mcsSitesText = State(initialValue: result.mcsSites.joined(separator: ", "))
            let mcsInfo = result.mcsDetected
                ? "MCS detected at \(result.mcsRange) with \(result.mcsSites.count) single-cutters"
                : "No MCS feature found — showing all \(result.allSingleCutters.count) single-cutters"
            _importInfo = State(initialValue: mcsInfo)
        case .add:
            break
        }
    }
    
    private var parsedSites: [String] {
        mcsSitesText
            .components(separatedBy: CharacterSet(charactersIn: ",;"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    
    private var isValid: Bool {
        !name.isEmpty && !parsedSites.isEmpty && (Int(sizeText) ?? 0) > 0
    }
    
    var body: some View {
        VStack(spacing: 16) {
            Text(mode.isAdd ? "Add Cloning Vector" : "Edit Cloning Vector")
                .font(.headline)
            
            if !importInfo.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill").foregroundColor(.blue)
                    Text(importInfo).font(.caption).foregroundColor(.secondary)
                }
                .padding(8)
                .background(Color.blue.opacity(0.08))
                .cornerRadius(6)
            }
            
            Form {
                TextField("Vector Name:", text: $name)
                    .frame(width: 350)
                
                TextField("Full Name / Reference:", text: $fullName)
                    .frame(width: 350)
                
                Picker("Category:", selection: $category) {
                    ForEach(VectorCategory.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.frame(width: 250)
                
                HStack {
                    TextField("Size (bp):", text: $sizeText)
                        .frame(width: 100)
                    TextField("Selection Marker:", text: $selectionMarker)
                        .frame(width: 250)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("MCS Sites (comma-separated, 5'→3' order):")
                        .font(.caption).foregroundColor(.secondary)
                    
                    TextEditor(text: $mcsSitesText)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 450, height: 60)
                        .border(Color.secondary.opacity(0.3))
                    
                    if !parsedSites.isEmpty {
                        HStack(spacing: 4) {
                            Text("\(parsedSites.count) sites:")
                                .font(.caption).foregroundColor(.secondary)
                            Text(parsedSites.joined(separator: " – "))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.blue)
                                .lineLimit(2)
                        }
                    }
                    
                    Text("Use enzyme names as they appear in the Restriction Enzyme database")
                        .font(.caption2).foregroundColor(.secondary)
                }
                
                TextField("Notes:", text: $notes)
                    .frame(width: 450)
                Text("e.g. promoter, tags, origin type")
                    .font(.caption2).foregroundColor(.secondary)
            }
            
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Spacer()
                Button(mode.isAdd ? "Add" : "Save") {
                    let vector = ShuttleVector(
                        name: name,
                        fullName: fullName.isEmpty ? name : fullName,
                        category: category,
                        size: Int(sizeText) ?? 0,
                        mcsSites: parsedSites,
                        selectionMarker: selectionMarker,
                        notes: notes
                    )
                    onSave(vector)
                    dismiss()
                }
                .keyboardShortcut(.return)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 530)
    }
}


// MARK: - Window Manager

class ShuttleVectorListWindowManager {
    static let shared = ShuttleVectorListWindowManager()
    private var window: NSWindow?
    private init() {}
    
    func openWindow() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        
        let view = ShuttleVectorListView()
        let controller = NSHostingController(rootView: view)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1020, height: 550),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        win.title = "Cloning Vector Library"
        win.contentViewController = controller
        win.setFrameAutosaveName("CloningVectorLibrary")
        if !win.setFrameUsingName(win.frameAutosaveName) { win.center() }
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 850, height: 400)
        win.makeKeyAndOrderFront(nil)
        window = win
    }
}


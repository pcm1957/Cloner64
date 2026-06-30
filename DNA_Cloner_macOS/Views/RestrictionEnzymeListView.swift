//
//  RestrictionEnzymeListView.swift
//  Cloner 64
//
//  Editable list of restriction enzymes in the database.
//  Opened from Tools → Restriction Enzyme List.
//

import SwiftUI
import AppKit

struct RestrictionEnzymeListView: View {
    @ObservedObject private var db = RestrictionEnzymeDatabase.shared
    @State private var searchText = ""
    @State private var selectedEnzymeID: UUID?
    @State private var showAddSheet = false
    @State private var editingEnzyme: RestrictionEnzyme?
    @State private var sortOrder: SortOrder = .name
    @State private var showOnlyMyEnzymes: Bool = false
    
    enum SortOrder: String, CaseIterable {
        case name = "Name"
        case site = "Recognition Site"
        case overhang = "Overhang Type"
        case siteLength = "Site Length"
        case methylation = "Methylation"
    }
    
    private var filteredEnzymes: [RestrictionEnzyme] {
        var result = db.enzymes
        if showOnlyMyEnzymes {
            result = result.filter { db.isMyEnzyme($0.name) }
        }
        if !searchText.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.recognitionSite.localizedCaseInsensitiveContains(searchText)
            }
        }
        switch sortOrder {
        case .name:
            result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .site:
            result.sort { $0.recognitionSite < $1.recognitionSite }
        case .overhang:
            result.sort { $0.overhangType.rawValue < $1.overhangType.rawValue }
        case .siteLength:
            result.sort { $0.recognitionSite.count < $1.recognitionSite.count }
        case .methylation:
            result.sort {
                if $0.methylationSensitivity.isEmpty != $1.methylationSensitivity.isEmpty {
                    return !$0.methylationSensitivity.isEmpty
                }
                return $0.methylationSensitivity < $1.methylationSensitivity
            }
        }
        return result
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("Search enzymes...", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .contextHelp("enzlist.search")
                }
                
                Picker("Sort:", selection: $sortOrder) {
                    ForEach(SortOrder.allCases, id: \.self) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .frame(width: 200)
                .contextHelp("enzlist.sort")
                
                Toggle(isOn: $showOnlyMyEnzymes) {
                    Label("My Enzymes", systemImage: "star.fill")
                        .font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
                .help("Show only enzymes marked as in your freezer")
                .contextHelp("enzlist.myEnzymes")
                
                Spacer()
                
                Text(showOnlyMyEnzymes
                     ? "\(db.myEnzymeNames.count) of \(db.enzymes.count) enzymes"
                     : "\(db.enzymes.count) enzymes")
                    .font(.caption).foregroundColor(.secondary)
                
                Button(action: { showAddSheet = true }) {
                    Label("Add Enzyme", systemImage: "plus")
                }
                .controlSize(.small)
                .contextHelp("enzlist.add")
                
                Button(action: deleteSelected) {
                    Label("Delete", systemImage: "trash")
                }
                .controlSize(.small)
                .disabled(selectedEnzymeID == nil)
                .contextHelp("enzlist.delete")
            }
            .padding(10)
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Table header
            HStack(spacing: 0) {
                Text("★").frame(width: 30, alignment: .center)
                    .help("Click star to add/remove from My Enzymes (freezer stock)")
                Text("Name").frame(width: 120, alignment: .leading)
                Text("Recognition Site").frame(width: 130, alignment: .leading)
                Text("Cut 5'").frame(width: 50, alignment: .center)
                Text("Cut 3'").frame(width: 50, alignment: .center)
                Text("Overhang").frame(width: 100, alignment: .leading)
                Text("Cut Structure").frame(width: 220, alignment: .leading)
                Text("Site Length").frame(width: 80, alignment: .center)
                Text("Methylation").frame(width: 170, alignment: .leading)
                Spacer()
            }
            .font(.caption.weight(.semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            
            Divider()
            
            // Enzyme list
            List(selection: $selectedEnzymeID) {
                ForEach(filteredEnzymes) { enzyme in
                    enzymeRow(enzyme)
                        .tag(enzyme.id)
                        .onTapGesture(count: 2) { editingEnzyme = enzyme }
                }
            }
            .listStyle(.plain)
            
            Divider()
            
            // Footer
            HStack {
                Text("Double-click to edit • Click ★ to add to My Enzymes (freezer stock)")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 1050, minHeight: 400)
        .sheet(isPresented: $showAddSheet) {
            EnzymeEditSheet(mode: .add) { enzyme in
                db.addEnzyme(enzyme)
            }
        }
        .sheet(item: $editingEnzyme) { enzyme in
            EnzymeEditSheet(mode: .edit(enzyme)) { updated in
                db.updateEnzyme(updated)
            }
        }
    }
    
    private func enzymeRow(_ enzyme: RestrictionEnzyme) -> some View {
        HStack(spacing: 0) {
            // My Enzymes star
            Button(action: { db.toggleMyEnzyme(enzyme.name) }) {
                Image(systemName: db.isMyEnzyme(enzyme.name) ? "star.fill" : "star")
                    .foregroundColor(db.isMyEnzyme(enzyme.name) ? .yellow : .gray.opacity(0.4))
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .frame(width: 30, alignment: .center)
            .help(db.isMyEnzyme(enzyme.name)
                  ? "Remove from My Enzymes"
                  : "Add to My Enzymes (freezer stock)")
            
            Text(enzyme.name)
                .fontWeight(.medium)
                .frame(width: 120, alignment: .leading)
            
            Text(enzyme.recognitionSite)
                .fontDesign(.monospaced)
                .frame(width: 130, alignment: .leading)
            
            Text("\(enzyme.cutPosition5Prime)")
                .fontDesign(.monospaced)
                .frame(width: 50, alignment: .center)
            
            Text("\(enzyme.cutPosition3Prime)")
                .fontDesign(.monospaced)
                .frame(width: 50, alignment: .center)
            
            Text(enzyme.overhangType.rawValue)
                .foregroundColor(enzyme.overhangType == .blunt ? .orange :
                                    enzyme.overhangType == .sticky5Prime ? .blue : .purple)
                .frame(width: 100, alignment: .leading)
            
            OverhangDiagramView(enzyme: enzyme)
                .frame(width: 220, alignment: .leading)
            
            Text("\(enzyme.recognitionSite.count) bp")
                .frame(width: 80, alignment: .center)
            
            Text(enzyme.methylationSensitivity.isEmpty ? "—" : enzyme.methylationSensitivity)
                .foregroundColor(enzyme.methylationSensitivity.isEmpty ? .secondary : .orange)
                .frame(width: 170, alignment: .leading)
            
            Spacer()
        }
        .font(.system(size: 12))
        .padding(.vertical, 2)
    }
    
    private func deleteSelected() {
        guard let id = selectedEnzymeID else { return }
        db.removeEnzyme(id: id)
        selectedEnzymeID = nil
    }
}


// MARK: - Add / Edit Sheet

struct EnzymeEditSheet: View {
    enum Mode: Identifiable {
        case add
        case edit(RestrictionEnzyme)
        
        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let e): return e.id.uuidString
            }
        }
    }
    
    let mode: Mode
    let onSave: (RestrictionEnzyme) -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var name: String = ""
    @State private var recognitionSite: String = ""
    @State private var cut5: String = ""
    @State private var cut3: String = ""
    @State private var overhangType: RestrictionEnzyme.OverhangType = .sticky5Prime
    @State private var methylationSensitivity: String = ""
    
    init(mode: Mode, onSave: @escaping (RestrictionEnzyme) -> Void) {
        self.mode = mode
        self.onSave = onSave
        
        if case .edit(let enzyme) = mode {
            _name = State(initialValue: enzyme.name)
            _recognitionSite = State(initialValue: enzyme.recognitionSite)
            _cut5 = State(initialValue: String(enzyme.cutPosition5Prime))
            _cut3 = State(initialValue: String(enzyme.cutPosition3Prime))
            _overhangType = State(initialValue: enzyme.overhangType)
            _methylationSensitivity = State(initialValue: enzyme.methylationSensitivity)
        }
    }
    
    private var isValid: Bool {
        !name.isEmpty &&
        !recognitionSite.isEmpty &&
        recognitionSite.uppercased().allSatisfy({ "ACGTRYSWKMBDHVN".contains($0) }) &&
        Int(cut5) != nil &&
        Int(cut3) != nil
    }
    
    var body: some View {
        VStack(spacing: 16) {
            Text(mode.isAdd ? "Add Restriction Enzyme" : "Edit Restriction Enzyme")
                .font(.headline)
            
            Form {
                TextField("Enzyme Name:", text: $name)
                    .frame(width: 300)
                    .contextHelp("enzEdit.name")
                
                TextField("Recognition Site:", text: $recognitionSite)
                    .fontDesign(.monospaced)
                    .frame(width: 300)
                    .contextHelp("enzEdit.site")
                
                HStack {
                    TextField("Cut 5':", text: $cut5)
                        .frame(width: 80)
                        .contextHelp("enzEdit.cut5")
                    TextField("Cut 3':", text: $cut3)
                        .frame(width: 80)
                        .contextHelp("enzEdit.cut3")
                }
                
                Picker("Overhang Type:", selection: $overhangType) {
                    Text("5' Overhang").tag(RestrictionEnzyme.OverhangType.sticky5Prime)
                    Text("3' Overhang").tag(RestrictionEnzyme.OverhangType.sticky3Prime)
                    Text("Blunt").tag(RestrictionEnzyme.OverhangType.blunt)
                }
                .frame(width: 200)
                .contextHelp("enzEdit.overhangType")
                
                TextField("Methylation:", text: $methylationSensitivity)
                    .frame(width: 300)
                    .contextHelp("enzEdit.methylation")
                Text("e.g. dam blocked, dcm impaired, CpG blocked")
                    .font(.caption2).foregroundColor(.secondary)
                
                if isValid {
                    let preview = RestrictionEnzyme(
                        name: name, recognitionSite: recognitionSite.uppercased(),
                        cutPosition5Prime: Int(cut5)!, cutPosition3Prime: Int(cut3)!,
                        overhangType: overhangType)
                    Text("Overhang sequence: \(preview.overhangSequence.isEmpty ? "none (blunt)" : preview.overhangSequence)")
                        .font(.caption).foregroundColor(.secondary).fontDesign(.monospaced)
                }
            }
            
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                    .contextHelp("enzEdit.cancel")
                Spacer()
                Button(mode.isAdd ? "Add" : "Save") {
                    let id: UUID
                    if case .edit(let enzyme) = mode { id = enzyme.id } else { id = UUID() }
                    let enzyme = RestrictionEnzyme(
                        id: id,
                        name: name,
                        recognitionSite: recognitionSite.uppercased(),
                        cutPosition5Prime: Int(cut5) ?? 0,
                        cutPosition3Prime: Int(cut3) ?? 0,
                        overhangType: overhangType,
                        methylationSensitivity: methylationSensitivity
                    )
                    onSave(enzyme)
                    dismiss()
                }
                .keyboardShortcut(.return)
                .disabled(!isValid)
                .contextHelp("enzEdit.save")
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

extension EnzymeEditSheet.Mode {
    var isAdd: Bool {
        if case .add = self { return true }
        return false
    }
}


// MARK: - Overhang Diagram

/// Shows the recognition site split at the cleavage point on both strands.
/// E.g. EcoRI (GAATTC, cut5=1, cut3=5):
///   5'…G     AATTC…3'
///   3'…CTTAA     G…5'
/// PstI (CTGCAG, cut5=5, cut3=1):
///   5'…CTGCA     G…3'
///   3'…G     ACGTC…5'   (wait — bottom strand is RC of top, read L→R)
/// SmaI (CCCGGG, cut5=3, cut3=3):
///   5'…CCC GGG…3'
///   3'…GGG CCC…5'
struct OverhangDiagramView: View {
    let enzyme: RestrictionEnzyme

    private static func rc(_ s: String) -> String {
        let comp: [Character: Character] = [
            "A":"T","T":"A","G":"C","C":"G",
            "R":"Y","Y":"R","S":"S","W":"W",
            "K":"M","M":"K","B":"V","V":"B",
            "D":"H","H":"D","N":"N"
        ]
        return String(s.uppercased().reversed().map { comp[$0] ?? $0 })
    }

    private var lines: (top: String, bot: String) {
        let site = enzyme.recognitionSite.uppercased()
        // Bottom strand shown L→R (3'→5'), complement of top strand base-by-base.
        // Using complement (NOT reverse complement) means each base pairs directly
        // under the base above it, and palindromic enzymes show different letters
        // on each strand (e.g. AvrII CCTAGG → bottom shows GGATCC L→R).
        let bot = String(site.uppercased().map { c -> Character in
            switch c {
            case "A": return "T"; case "T": return "A"
            case "G": return "C"; case "C": return "G"
            default:  return c
            }
        })
        let n  = site.count
        let c5 = enzyme.cutPosition5Prime
        let c3 = enzyme.cutPosition3Prime
        guard c5 >= 0, c5 <= n, c3 >= 0, c3 <= n else {
            return ("5'…\(site)…3'", "3'…\(bot)…5'")
        }

        func sub(_ s: String, _ a: Int, _ b: Int) -> String {
            guard a >= 0, b <= s.count, a <= b else { return "" }
            return String(s[s.index(s.startIndex, offsetBy: a)..<s.index(s.startIndex, offsetBy: b)])
        }

        let pad = String(repeating: " ", count: abs(c5 - c3))

        if c5 == c3 {
            // Blunt — single ↓ on each strand, aligned
            return ("5'…\(sub(site,0,c5))↓\(sub(site,c5,n))…3'",
                    "3'…\(sub(bot, 0,c3))↓\(sub(bot, c3,n))…5'")
        } else if c5 < c3 {
            // 5' overhang: top cuts left of bottom
            return ("5'…\(sub(site,0,c5))↓\(pad)\(sub(site,c5,n))…3'",
                    "3'…\(sub(bot, 0,c3))\(pad)↓\(sub(bot, c3,n))…5'")
        } else {
            // 3' overhang: bottom cuts left of top
            return ("5'…\(sub(site,0,c5))\(pad)↓\(sub(site,c5,n))…3'",
                    "3'…\(sub(bot, 0,c3))↓\(pad)\(sub(bot, c3,n))…5'")
        }
    }

    var body: some View {
        let (top, bot) = lines
        VStack(alignment: .leading, spacing: 0) {
            Text(top)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.primary)
            Text(bot)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }
}


// MARK: - Window Manager

class RestrictionEnzymeListWindowManager {
    static let shared = RestrictionEnzymeListWindowManager()
    private var window: NSWindow?
    private init() {}
    
    func openWindow() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        
        let view = RestrictionEnzymeListView()
        let controller = NSHostingController(rootView: view)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1020, height: 550),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        win.title = "Restriction Enzyme List"
        win.contentViewController = controller
        win.setFrameAutosaveName("RestrictionEnzymeList")
        if !win.setFrameUsingName(win.frameAutosaveName) { win.center() }
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 880, height: 350)
        win.makeKeyAndOrderFront(nil)
        window = win
    }
}

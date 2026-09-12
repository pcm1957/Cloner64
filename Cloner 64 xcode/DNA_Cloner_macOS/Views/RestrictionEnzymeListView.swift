//
//  RestrictionEnzymeListView.swift
//  Cloner 64
//
//  Editable list of restriction enzymes in the database.
//  Opened from Tools → Restriction Enzyme List.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
                
                // myEnzymeCount, not myEnzymeNames.count — see the note on
                // that property. A starred name can outlive its enzyme, and
                // counting names made this read higher than the rows below.
                Text(showOnlyMyEnzymes
                     ? "\(db.myEnzymeCount) of \(db.enzymes.count) enzymes"
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

                // Export / Import / Restore. Enzymes you add or edit are saved
                // automatically; these are for moving them between machines,
                // sharing them, or backing them up.
                Menu {
                    Button("Export My Enzymes…") { exportEnzymes() }
                        .disabled(!db.hasCustomisations && db.myEnzymeNames.isEmpty)
                    Button("Import Enzymes…") { importEnzymes() }
                    Divider()
                    Button("Restore Built-in Defaults…") { confirmRestoreDefaults() }
                        .disabled(!db.hasCustomisations)
                } label: {
                    Label("Enzyme File", systemImage: "square.and.arrow.up.on.square")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .controlSize(.small)
                .contextHelp("enzlist.file")
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
                if let problem = db.storeError {
                    // A silent save failure would look exactly like a working
                    // app until the user quit and lost the lot, so say so.
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .lineLimit(1)
                        .help(problem)
                } else if db.hasCustomisations {
                    Text("Your changes are saved automatically")
                        .font(.caption).foregroundColor(.secondary)
                }
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
            
            // Cut positions are stored as offsets from the START of the
            // recognition site. For an enzyme that cuts outside its site
            // (Type IIS) those offsets run past the site — BsaI is stored as
            // 7 and 11 — whereas REBASE and the supplier catalogues write it
            // GGTCTC(1/5), counting from the END of the site. Show the
            // catalogue form for those, so the table matches the bottle.
            Text(enzyme.cutsOutsideSite
                 ? "+\(enzyme.cutPosition5Prime - enzyme.siteLength)"
                 : "\(enzyme.cutPosition5Prime)")
                .fontDesign(.monospaced)
                .frame(width: 50, alignment: .center)

            Text(enzyme.cutsOutsideSite
                 ? "+\(enzyme.cutPosition3Prime - enzyme.siteLength)"
                 : "\(enzyme.cutPosition3Prime)")
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

    // MARK: - Export / Import

    private var enzymeFileType: UTType {
        UTType(filenameExtension: EnzymeStore.fileExtension) ?? .json
    }

    private func exportEnzymes() {
        let panel = NSSavePanel()
        panel.title = "Export My Enzymes"
        panel.message = "Saves the enzymes you have added, edited or deleted — "
                      + "not the whole built-in list."
        panel.nameFieldStringValue = "My Enzymes.\(EnzymeStore.fileExtension)"
        panel.allowedContentTypes = [enzymeFileType]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try EnzymeStore.write(db.currentOverlay, to: url)
        } catch {
            showAlert(style: .warning, title: "Export failed",
                      text: error.localizedDescription)
        }
    }

    private func importEnzymes() {
        let panel = NSOpenPanel()
        panel.title = "Import Enzymes"
        panel.allowedContentTypes = [enzymeFileType, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let incoming: EnzymeOverlay
        do {
            incoming = try EnzymeStore.read(from: url)
        } catch {
            showAlert(style: .warning, title: "Could not read that file",
                      text: error.localizedDescription)
            return
        }

        let summary = "\(incoming.added.count) added, "
                    + "\(incoming.edited.count) edited, "
                    + "\(incoming.deleted.count) deleted."

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Import enzymes?"
        alert.informativeText = "That file contains \(summary)\n\n"
            + "Merge keeps what you already have and adds these on top. "
            + "Replace discards your current additions and edits first."
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:  db.mergeCustomisations(with: incoming)
        case .alertSecondButtonReturn: db.replaceCustomisations(with: incoming)
        default: return
        }
    }

    private func confirmRestoreDefaults() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Restore the built-in enzyme list?"
        alert.informativeText = "Every enzyme you have added or edited will be discarded, "
            + "and any built-in enzyme you deleted will come back. "
            + "Your ★ My Enzymes list is not affected.\n\n"
            + "Export first if you want to keep your changes. This cannot be undone."
        alert.addButton(withTitle: "Restore Defaults")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            db.restoreBuiltInDefaults()
            selectedEnzymeID = nil
        }
    }

    private func showAlert(style: NSAlert.Style, title: String, text: String) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
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

    @ObservedObject private var db = RestrictionEnzymeDatabase.shared
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
    
    // MARK: - Validation
    //
    // The old check only asked "are these fields filled in?". That let AccI be
    // saved as GTMKAC 1/5 — a 4-base overhang, where the real enzyme leaves 2 —
    // with nothing on screen to suggest anything was wrong. These checks cannot
    // know what an enzyme really does, but they can catch entries that
    // contradict themselves, and the live diagram below shows the rest.

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var cleanSite: String {
        recognitionSite.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var siteIsWellFormed: Bool {
        !cleanSite.isEmpty && cleanSite.allSatisfy { "ACGTRYSWKMBDHVN".contains($0) }
    }

    /// Blocking problems — the Save button stays disabled while any exist.
    private var errors: [String] {
        var found: [String] = []

        if trimmedName.isEmpty {
            found.append("Give the enzyme a name.")
        } else if let clash = duplicateName {
            found.append("There is already an enzyme called \(clash).")
        }

        if cleanSite.isEmpty {
            found.append("Enter a recognition site.")
        } else if !siteIsWellFormed {
            found.append("The site may only contain A C G T and the IUPAC codes R Y S W K M B D H V N.")
        }

        if Int(cut5) == nil { found.append("Cut 5' must be a whole number.") }
        if Int(cut3) == nil { found.append("Cut 3' must be a whole number.") }

        guard let c5 = Int(cut5), let c3 = Int(cut3), siteIsWellFormed else { return found }

        if c5 < 0 || c3 < 0 {
            found.append("Cut positions cannot be negative.")
        }

        // A blunt cutter must cut both strands at the same point, and a sticky
        // one must not. Getting this wrong makes the enzyme silently unusable
        // for ligation planning.
        switch overhangType {
        case .blunt where c5 != c3:
            found.append("Blunt ends need Cut 5' and Cut 3' to be equal — you have \(c5) and \(c3).")
        case .sticky5Prime where c5 >= c3:
            found.append("A 5' overhang needs Cut 5' to be less than Cut 3' — you have \(c5) and \(c3). "
                       + "Did you mean a 3' overhang?")
        case .sticky3Prime where c5 <= c3:
            found.append("A 3' overhang needs Cut 5' to be greater than Cut 3' — you have \(c5) and \(c3). "
                       + "Did you mean a 5' overhang?")
        default:
            break
        }

        return found
    }

    /// Non-blocking observations — worth reading before you press Save.
    private var warnings: [String] {
        guard errors.isEmpty, let c5 = Int(cut5), let c3 = Int(cut3) else { return [] }
        var found: [String] = []
        let n = cleanSite.count

        if c5 > n || c3 > n {
            found.append("A cut lies outside the recognition site, so this will be treated as a "
                       + "Type IIS enzyme. Its overhang will be read from the target sequence.")
        }

        if cleanSite != RestrictionEnzyme.iupacReverseComplement(cleanSite) {
            found.append("This site is not palindromic, so the app will search both strands separately. "
                       + "That is correct for enzymes like SapI, but it is also what a typing slip "
                       + "looks like — worth a second look.")
        } else if c5 <= n && c3 <= n && c3 != n - c5 {
            // For a palindromic site the two cuts must be mirror images.
            found.append("For a palindromic site of \(n) bases cut at \(c5), the other strand is "
                       + "normally cut at \(n - c5), not \(c3). Check against REBASE.")
        }

        let overhang = previewEnzyme?.overhangSequence ?? ""
        if !overhang.isEmpty && overhang.contains(where: { !"ACGT".contains($0) }) {
            found.append("The overhang (\(overhang)) contains ambiguity codes, so its actual bases "
                       + "depend on the sequence cut. Predictive Cloning will not match these ends.")
        }

        return found
    }

    /// An existing enzyme with the same name, if any (ignoring the one being edited).
    private var duplicateName: String? {
        let editingID: UUID? = { if case .edit(let e) = mode { return e.id } else { return nil } }()
        return db.enzymes.first {
            $0.id != editingID && $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame
        }?.name
    }

    private var previewEnzyme: RestrictionEnzyme? {
        guard errors.isEmpty, let c5 = Int(cut5), let c3 = Int(cut3) else { return nil }
        return RestrictionEnzyme(name: trimmedName, recognitionSite: cleanSite,
                                 cutPosition5Prime: c5, cutPosition3Prime: c3,
                                 overhangType: overhangType)
    }

    private var isValid: Bool { errors.isEmpty }
    
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
                
                if let preview = previewEnzyme {
                    Divider()

                    // Show the actual cut, on both strands, as it is typed.
                    // A wrong overhang length is obvious here in a way that two
                    // numbers in two text fields never are.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("This is what you are describing:")
                            .font(.caption).foregroundColor(.secondary)
                        OverhangDiagramView(enzyme: preview)

                        // A Type IIS enzyme cuts outside its recognition site, so
                        // its overhang depends on the target and cannot be shown.
                        if preview.cutsOutsideSite {
                            Text("Cuts outside the recognition site (Type IIS) — "
                                 + "\(preview.overhangLength)-base overhang, sequence depends on the target")
                                .font(.caption).foregroundColor(.secondary)
                        } else if preview.overhangType == .blunt {
                            Text("Blunt ends — no overhang")
                                .font(.caption).foregroundColor(.secondary)
                        } else {
                            Text("\(preview.overhangLength)-base \(preview.overhangType.rawValue.lowercased()): "
                                 + "\(preview.overhangSequence.isEmpty ? "—" : preview.overhangSequence)")
                                .font(.caption).foregroundColor(.secondary).fontDesign(.monospaced)
                        }
                    }
                }

                if !warnings.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundColor(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if !errors.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(errors, id: \.self) { problem in
                            Label(problem, systemImage: "xmark.octagon")
                                .font(.caption)
                                .foregroundColor(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                    .contextHelp("enzEdit.cancel")
                Spacer()
                Button(mode.isAdd ? "Add" : "Save") {
                    guard let c5 = Int(cut5), let c3 = Int(cut3) else { return }
                    let id: UUID
                    if case .edit(let enzyme) = mode { id = enzyme.id } else { id = UUID() }
                    let enzyme = RestrictionEnzyme(
                        id: id,
                        name: trimmedName,
                        recognitionSite: cleanSite,
                        cutPosition5Prime: c5,
                        cutPosition3Prime: c3,
                        overhangType: overhangType,
                        methylationSensitivity: methylationSensitivity
                            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        .frame(width: 460)
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

    private var lines: (top: String, bot: String) {
        let site = enzyme.recognitionSite.uppercased()
        // Bottom strand shown L→R (3'→5'), complement of top strand base-by-base.
        // Using complement (NOT reverse complement) means each base pairs
        // directly under the base above it.
        //
        // This used to be a hand-written switch that handled only A/C/G/T and
        // returned every other character unchanged, so degenerate codes were
        // printed uncomplemented: AccI (GTMKAC) showed a lower strand of
        // CAMKTG instead of CAKMTG, and AvaI (CYCGRG) showed GYGCRC instead of
        // GRGCYC. M pairs with K and R pairs with Y, so both were wrong.
        // It now goes through the one shared IUPAC table.
        let bot = RestrictionEnzyme.iupacComplement(site)
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

//
//  CompatibleEndsView.swift
//  Cloner 64
//
//  Reference window showing enzymes grouped by compatible cohesive ends.
//  Groups are computed from the enzyme database — not hardcoded — so they
//  update automatically when enzymes are added or edited.
//
//  Inspired by the NEB "Compatible Cohesive Ends" selection chart.
//

import SwiftUI
import AppKit

struct CompatibleEndsView: View {
    @ObservedObject private var db = RestrictionEnzymeDatabase.shared
    @State private var filterText = ""
    @State private var showBlunt = true
    @State private var show5Prime = true
    @State private var show3Prime = true
    
    private var groups: [(overhang: String, type: RestrictionEnzyme.OverhangType, enzymes: [RestrictionEnzyme])] {
        var result = db.compatibleEndGroups()
        
        // Type filters
        result = result.filter { group in
            switch group.type {
            case .blunt: return showBlunt
            case .sticky5Prime: return show5Prime
            case .sticky3Prime: return show3Prime
            }
        }
        
        // Text filter — match enzyme name or overhang sequence
        if !filterText.isEmpty {
            result = result.filter { group in
                group.overhang.localizedCaseInsensitiveContains(filterText) ||
                group.enzymes.contains { $0.name.localizedCaseInsensitiveContains(filterText) }
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
                    TextField("Filter by enzyme or overhang...", text: $filterText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .contextHelp("ends.filter")
                }
                
                Toggle("Blunt", isOn: $showBlunt)
                    .toggleStyle(.checkbox).font(.system(size: 12))
                    .contextHelp("ends.blunt")
                Toggle("5' Overhang", isOn: $show5Prime)
                    .toggleStyle(.checkbox).font(.system(size: 12))
                    .contextHelp("ends.fivePrime")
                Toggle("3' Overhang", isOn: $show3Prime)
                    .toggleStyle(.checkbox).font(.system(size: 12))
                    .contextHelp("ends.threePrime")
                
                Spacer()
                
                Text("\(groups.count) groups")
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding(10)
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Explanation
            HStack(spacing: 0) {
                Text("Enzymes in the same group produce the same overhang and can be ligated together. Self-ligation (same enzyme) always regenerates the original site. Cross-ligation may create a hybrid junction that is not recleavable by either enzyme.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                Spacer()
            }
            .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
            
            Divider()
            
            // Groups
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        compatibleGroupRow(group)
                        Divider()
                    }
                }
                .padding(.horizontal, 4)
            }
            
            Divider()
            
            // Footer
            HStack {
                Text("Compatible end groups are computed from restriction enzyme cut positions in the database")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 650, minHeight: 400)
    }
    
    private func compatibleGroupRow(_ group: (overhang: String, type: RestrictionEnzyme.OverhangType, enzymes: [RestrictionEnzyme])) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Overhang badge
            VStack(spacing: 2) {
                Text(group.type.rawValue)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(group.type == .blunt ? .orange :
                                        group.type == .sticky5Prime ? .blue : .purple)
                
                if !group.overhang.isEmpty {
                    Text(group.overhang)
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(.primary)
                } else {
                    Text("—")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                
                if !group.overhang.isEmpty {
                    Text("\(group.overhang.count)-base overhang")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 120)
            .padding(.vertical, 8)
            
            Divider().frame(height: 60)
            
            // Enzyme list
            VStack(alignment: .leading, spacing: 4) {
                // Show enzymes as a flowing list
                let enzymeTexts = group.enzymes.map { enzyme -> (name: String, site: String) in
                    (name: enzyme.name, site: enzyme.recognitionSite)
                }
                
                FlowLayout(spacing: 6) {
                    ForEach(Array(enzymeTexts.enumerated()), id: \.offset) { _, enzyme in
                        HStack(spacing: 4) {
                            Text(enzyme.name)
                                .font(.system(size: 14, weight: .medium))
                            Text("(\(enzyme.site))")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(group.type == .blunt ? Color.orange.opacity(0.1) :
                                        group.type == .sticky5Prime ? Color.blue.opacity(0.1) : Color.purple.opacity(0.1))
                        )
                    }
                }
                
                // Show ligation junction examples for 2-enzyme groups
                if group.enzymes.count >= 2 && group.enzymes.count <= 6 {
                    junctionExamples(group.enzymes)
                }
            }
            .padding(.vertical, 6)
            
            Spacer()
        }
        .padding(.horizontal, 10)
    }
    
    /// Show ligation junction sequences for pairs of enzymes in the group
    private func junctionExamples(_ enzymes: [RestrictionEnzyme]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Ligation junctions:")
                .font(.system(size: 12)).foregroundColor(.secondary)
                .padding(.top, 4)
            
            // Show cross-ligations (A×B) for each unique pair
            ForEach(Array(uniquePairs(enzymes).prefix(8).enumerated()), id: \.offset) { _, pair in
                let junction = computeJunction(a: pair.0, b: pair.1)
                HStack(spacing: 4) {
                    Text("\(pair.0.name) × \(pair.1.name)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(width: 180, alignment: .leading)
                    Text("→")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                    Text(junction.sequence)
                        .font(.system(size: 13, design: .monospaced))
                    if junction.recleavableBy.isEmpty {
                        Text("(not recleavable)")
                            .font(.system(size: 11)).foregroundColor(.orange)
                    } else {
                        Text("(recleavable by \(junction.recleavableBy.joined(separator: ", ")))")
                            .font(.system(size: 11)).foregroundColor(.green)
                    }
                }
            }
        }
    }
    
    private func uniquePairs(_ enzymes: [RestrictionEnzyme]) -> [(RestrictionEnzyme, RestrictionEnzyme)] {
        var pairs: [(RestrictionEnzyme, RestrictionEnzyme)] = []
        for i in 0..<enzymes.count {
            for j in (i+1)..<enzymes.count {
                pairs.append((enzymes[i], enzymes[j]))
            }
        }
        return pairs
    }
    
    struct JunctionResult {
        let sequence: String
        let recleavableBy: [String]
    }
    
    /// Compute the junction formed when enzyme A's right-side cut ligates
    /// with enzyme B's left-side cut. Check if the junction contains any
    /// known recognition site.
    private func computeJunction(a: RestrictionEnzyme, b: RestrictionEnzyme) -> JunctionResult {
        let siteA = a.recognitionSite
        let siteB = b.recognitionSite
        
        // For the junction: take the left portion of A's cut site + right portion of B's cut site
        let cutA: Int  // where the top strand is cut in A (higher position)
        let cutB: Int  // where the top strand is cut in B (lower position)
        
        if a.overhangType == .sticky5Prime || a.overhangType == .blunt {
            cutA = max(a.cutPosition5Prime, a.cutPosition3Prime)
        } else {
            cutA = max(a.cutPosition5Prime, a.cutPosition3Prime)
        }
        
        if b.overhangType == .sticky5Prime || b.overhangType == .blunt {
            cutB = min(b.cutPosition5Prime, b.cutPosition3Prime)
        } else {
            cutB = min(b.cutPosition5Prime, b.cutPosition3Prime)
        }
        
        let leftPart = String(siteA.prefix(cutA))
        let rightPart = String(siteB.suffix(max(0, siteB.count - cutB)))
        let junction = leftPart + rightPart
        
        // Check if this junction is recleavable by any enzyme in the database
        var recleavable: [String] = []
        for enzyme in db.enzymes {
            if junction.contains(enzyme.recognitionSite) {
                recleavable.append(enzyme.name)
            }
        }
        
        return JunctionResult(sequence: junction, recleavableBy: recleavable)
    }
}


// MARK: - Flow Layout (for enzyme chips)

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        
        return CGSize(width: maxWidth, height: y + rowHeight)
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}


// MARK: - Window Manager

class CompatibleEndsWindowManager {
    static let shared = CompatibleEndsWindowManager()
    private var window: NSWindow?
    private init() {}
    
    func openWindow() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        
        let view = CompatibleEndsView()
        let controller = NSHostingController(rootView: view)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        win.title = "Compatible Cohesive Ends"
        win.contentViewController = controller
        win.setFrameAutosaveName("CompatibleCohesiveEnds")
        if !win.setFrameUsingName(win.frameAutosaveName) { win.center() }
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 600, height: 350)
        win.makeKeyAndOrderFront(nil)
        window = win
    }
}

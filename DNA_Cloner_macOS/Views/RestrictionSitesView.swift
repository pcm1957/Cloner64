//
//  RestrictionSitesView.swift
//  Cloner 64
//

import SwiftUI

struct RestrictionSitesView: View {
    @ObservedObject var sequence: DNASequence
    @State private var searchText = ""
    @State private var selectedEnzymes: Set<String> = []
    @State private var showOnlySingleCutters = false
    @State private var showOnlyNonCutters = false
    @State private var cutSites: [String: [CutSite]] = [:]
    
    private let enzymeDatabase = RestrictionEnzymeDatabase.shared
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                TextField("Search enzymes...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 250)
                
                Button(action: analyzeRestrictionSites) {
                    Label("Analyze", systemImage: "scissors")
                }
                .buttonStyle(.borderedProminent)
                
                Divider()
                    .frame(height: 20)
                
                Toggle("Single Cutters Only", isOn: $showOnlySingleCutters)
                Toggle("Non-Cutters Only", isOn: $showOnlyNonCutters)
                
                Spacer()
                
                Button(action: selectAllEnzymes) {
                    Text("Select All")
                }
                
                Button(action: deselectAllEnzymes) {
                    Text("Deselect All")
                }
            }
            .padding()
            .background(Color(.controlBackgroundColor))
            
            Divider()
            
            // Results
            HSplitView {
                // Enzyme list
                VStack(alignment: .leading, spacing: 0) {
                    Text("Restriction Enzymes")
                        .font(.headline)
                        .padding()
                    
                    List(filteredEnzymes, id: \.name) { enzyme in
                        EnzymeListRow(
                            enzyme: enzyme,
                            cutCount: cutSites[enzyme.name]?.count ?? 0,
                            isSelected: selectedEnzymes.contains(enzyme.name)
                        )
                        .onTapGesture {
                            toggleEnzyme(enzyme.name)
                        }
                    }
                }
                .frame(minWidth: 300, idealWidth: 400)
                
                // Cut sites detail
                VStack(alignment: .leading, spacing: 0) {
                    Text("Cut Sites")
                        .font(.headline)
                        .padding()
                    
                    if cutSites.isEmpty {
                        VStack {
                            Image(systemName: "scissors")
                                .font(.system(size: 48))
                                .foregroundColor(.gray)
                            Text("Click 'Analyze' to find restriction sites")
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(Array(selectedEnzymeSites), id: \.key) { enzymeName, sites in
                                    CutSiteSection(
                                        enzymeName: enzymeName,
                                        sites: sites,
                                        sequenceLength: sequence.length
                                    )
                                }
                            }
                            .padding()
                        }
                    }
                }
            }
        }
        .textSelection(.enabled)
    }
    
    private var filteredEnzymes: [RestrictionEnzyme] {
        var enzymes = enzymeDatabase.enzymes
        
        if !searchText.isEmpty {
            enzymes = enzymes.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        
        if showOnlySingleCutters {
            enzymes = enzymes.filter { cutSites[$0.name]?.count == 1 }
        }
        
        if showOnlyNonCutters {
            enzymes = enzymes.filter { cutSites[$0.name]?.isEmpty ?? true }
        }
        
        return enzymes.sorted { $0.name < $1.name }
    }
    
    private var selectedEnzymeSites: [(key: String, value: [CutSite])] {
        cutSites.filter { selectedEnzymes.contains($0.key) }
            .sorted { $0.key < $1.key }
    }
    
    private func analyzeRestrictionSites() {
        cutSites.removeAll()
        
        for enzyme in enzymeDatabase.enzymes {
            let sites = enzyme.findCutSites(in: sequence.sequence, circular: sequence.isCircular)
            cutSites[enzyme.name] = sites
        }
    }
    
    private func toggleEnzyme(_ name: String) {
        if selectedEnzymes.contains(name) {
            selectedEnzymes.remove(name)
        } else {
            selectedEnzymes.insert(name)
        }
    }
    
    private func selectAllEnzymes() {
        selectedEnzymes = Set(filteredEnzymes.map { $0.name })
    }
    
    private func deselectAllEnzymes() {
        selectedEnzymes.removeAll()
    }
}

struct EnzymeListRow: View {
    let enzyme: RestrictionEnzyme
    let cutCount: Int
    let isSelected: Bool
    
    var body: some View {
        HStack {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .foregroundColor(isSelected ? .blue : .secondary)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(enzyme.name)
                    .font(.headline)
                
                HStack {
                    Text(enzyme.recognitionSite)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                    
                    Text("•")
                        .foregroundColor(.secondary)
                    
                    Text(enzyme.overhangType.rawValue)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            VStack(alignment: .trailing) {
                Text("\(cutCount)")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(cutCount == 0 ? .secondary : cutCount == 1 ? .green : .blue)
                
                Text(cutCount == 1 ? "site" : "sites")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct CutSiteSection: View {
    let enzymeName: String
    let sites: [CutSite]
    let sequenceLength: Int
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(enzymeName)
                    .font(.headline)
                
                Spacer()
                
                Text("\(sites.count) site(s)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            if sites.isEmpty {
                Text("No cut sites found")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(sites) { site in
                        HStack {
                            Text("Position:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Text("\(site.position + 1)")
                                .font(.system(.caption, design: .monospaced))
                            
                            Text("•")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Text("Strand:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Text(site.strand.rawValue)
                                .font(.system(.caption, design: .monospaced))
                            
                            Text("•")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Text("Cut: \(site.cutPosition5Prime)")
                                .font(.system(.caption, design: .monospaced))
                            
                            if !site.methylationWarning.isEmpty {
                                Text(site.methylationWarning)
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                        }
                        .padding(.leading)
                    }
                }
            }
            
            Divider()
        }
    }
}

//
//  AnalysisView.swift
//  Cloner 64
//

import SwiftUI

struct AnalysisView: View {
    @ObservedObject var sequence: DNASequence
    @State private var selectedTool: AnalysisTool = .statistics
    
    enum AnalysisTool: String, CaseIterable {
        case statistics = "Statistics"
        case orfFinder = "ORF Finder"
        case translation = "Translation"
        case primerDesign = "Primer Design"
        case gcPlot = "GC Plot"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Tool selector
            Picker("Analysis Tool", selection: $selectedTool) {
                ForEach(AnalysisTool.allCases, id: \.self) { tool in
                    Text(tool.rawValue).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .padding()
            
            Divider()
            
            // Tool content
            ScrollView {
                switch selectedTool {
                case .statistics:
                    StatisticsView(sequence: sequence)
                case .orfFinder:
                    ORFFinderView(sequence: sequence)
                case .translation:
                    TranslationView(sequence: sequence)
                case .primerDesign:
                    PrimerDesignLauncherView(sequence: sequence)
                case .gcPlot:
                    GCPlotView(sequence: sequence)
                }
            }
        }
    }
}

struct StatisticsView: View {
    @ObservedObject var sequence: DNASequence
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Sequence Statistics")
                .font(.title2)
                .fontWeight(.bold)
            
            Grid(alignment: .leading, horizontalSpacing: 30, verticalSpacing: 12) {
                GridRow {
                    Text("Length:")
                        .fontWeight(.medium)
                    Text("\(sequence.length) bp")
                        .font(.system(.body, design: .monospaced))
                }
                
                GridRow {
                    Text("Topology:")
                        .fontWeight(.medium)
                    Text(sequence.isCircular ? "Circular" : "Linear")
                }
                
                GridRow {
                    Text("GC Content:")
                        .fontWeight(.medium)
                    Text(String(format: "%.2f%%", sequence.gcContent()))
                        .font(.system(.body, design: .monospaced))
                }
                
                GridRow {
                    Text("AT Content:")
                        .fontWeight(.medium)
                    Text(String(format: "%.2f%%", 100 - sequence.gcContent()))
                        .font(.system(.body, design: .monospaced))
                }
                
                Divider()
                
                GridRow {
                    Text("Adenine (A):")
                        .fontWeight(.medium)
                    Text("\(baseCount("A")) (\(String(format: "%.2f%%", basePercentage("A"))))")
                        .font(.system(.body, design: .monospaced))
                }
                
                GridRow {
                    Text("Thymine (T):")
                        .fontWeight(.medium)
                    Text("\(baseCount("T")) (\(String(format: "%.2f%%", basePercentage("T"))))")
                        .font(.system(.body, design: .monospaced))
                }
                
                GridRow {
                    Text("Guanine (G):")
                        .fontWeight(.medium)
                    Text("\(baseCount("G")) (\(String(format: "%.2f%%", basePercentage("G"))))")
                        .font(.system(.body, design: .monospaced))
                }
                
                GridRow {
                    Text("Cytosine (C):")
                        .fontWeight(.medium)
                    Text("\(baseCount("C")) (\(String(format: "%.2f%%", basePercentage("C"))))")
                        .font(.system(.body, design: .monospaced))
                }
                
                Divider()
                
                GridRow {
                    Text("Molecular Weight:")
                        .fontWeight(.medium)
                    Text(String(format: "%.2f Da", molecularWeight))
                        .font(.system(.body, design: .monospaced))
                }
            }
            .padding()
            .background(Color(.controlBackgroundColor))
            .cornerRadius(8)
        }
        .padding()
    }
    
    private func baseCount(_ base: String) -> Int {
        sequence.sequence.filter { String($0) == base }.count
    }
    
    private func basePercentage(_ base: String) -> Double {
        guard sequence.length > 0 else { return 0 }
        return Double(baseCount(base)) / Double(sequence.length) * 100.0
    }
    
    private var molecularWeight: Double {
        // Average molecular weight per base pair
        let avgMW = 650.0 // Daltons
        return Double(sequence.length) * avgMW
    }
}

struct ORFFinderView: View {
    @ObservedObject var sequence: DNASequence
    @State private var minLength = 100
    @State private var orfs: [DNASequence.ORFResult] = []
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Open Reading Frame Finder")
                .font(.title2)
                .fontWeight(.bold)
            
            HStack {
                Text("Minimum ORF Length:")
                TextField("Min Length", value: $minLength, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                Text("codons")
                
                Spacer()
                
                Button("Find ORFs") {
                    findORFs()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(Color(.controlBackgroundColor))
            .cornerRadius(8)
            
            if orfs.isEmpty {
                VStack {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundColor(.gray)
                    Text("No ORFs found")
                        .foregroundColor(.secondary)
                    Text("Click 'Find ORFs' to search")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else {
                Text("Found \(orfs.count) ORF(s)")
                    .font(.headline)
                
                List(orfs) { orf in
                    ORFRow(orf: orf)
                }
            }
        }
        .padding()
    }
    
    private func findORFs() {
        orfs = sequence.findORFs(minNucleotides: minLength)
    }
}

struct ORFRow: View {
    let orf: DNASequence.ORFResult
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Frame \(orf.frame > 0 ? "+" : "")\(orf.frame)")
                    .font(.headline)
                    .foregroundColor(orf.frame > 0 ? .blue : .orange)
                
                Spacer()
                
                Text("\(orf.lengthAA) aa")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Text("Position: \(orf.position)..\(orf.end)")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text(orf.protein)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }
}

struct TranslationView: View {
    @ObservedObject var sequence: DNASequence
    @State private var selectedFrame = 1
    @State private var geneticCode: GeneticCode = .standard
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Translate Sequence")
                .font(.title2)
                .fontWeight(.bold)
            
            HStack {
                Picker("Reading Frame", selection: $selectedFrame) {
                    Text("Frame +1").tag(1)
                    Text("Frame +2").tag(2)
                    Text("Frame +3").tag(3)
                    Text("Frame -1").tag(-1)
                    Text("Frame -2").tag(-2)
                    Text("Frame -3").tag(-3)
                }
                .pickerStyle(.segmented)
                
                Spacer()
            }
            .padding()
            .background(Color(.controlBackgroundColor))
            .cornerRadius(8)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Protein Sequence")
                    .font(.headline)
                
                let protein = sequence.translate(frame: selectedFrame, geneticCode: geneticCode)
                
                ScrollView(.horizontal) {
                    Text(protein)
                        .font(.system(.body, design: .monospaced))
                        .padding()
                        .background(Color(.textBackgroundColor))
                        .cornerRadius(4)
                }
                
                Text("\(protein.count) amino acids")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }
}

struct PrimerDesignLauncherView: View {
    @ObservedObject var sequence: DNASequence
    @EnvironmentObject var sequenceManager: SequenceManager
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("PCR Primer Design")
                .font(.title2)
            Text("Opens in a dedicated window with full design parameters.")
                .font(.caption)
                .foregroundColor(.secondary)
            Button("Open Primer Designer…") {
                PrimerDesignWindowManager.shared.openWindow(
                    sequenceManager: sequenceManager,
                    initialSequenceID: sequence.id
                )
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct GCPlotView: View {
    @ObservedObject var sequence: DNASequence
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("GC Content Plot")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("GC content visualization across sequence")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            // Simplified GC plot representation
            GeometryReader { geometry in
                let windowSize = 100
                let gcValues = calculateGCContent(windowSize: windowSize)
                
                Path { path in
                    guard !gcValues.isEmpty else { return }
                    
                    let width = geometry.size.width
                    let height = geometry.size.height
                    let xStep = width / CGFloat(gcValues.count - 1)
                    
                    path.move(to: CGPoint(x: 0, y: height - CGFloat(gcValues[0]) * height / 100))
                    
                    for (index, value) in gcValues.enumerated() {
                        let x = CGFloat(index) * xStep
                        let y = height - CGFloat(value) * height / 100
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                .stroke(Color.blue, lineWidth: 2)
            }
            .frame(height: 200)
            .padding()
            .background(Color(.controlBackgroundColor))
            .cornerRadius(8)
        }
        .padding()
    }
    
    private func calculateGCContent(windowSize: Int) -> [Double] {
        var values: [Double] = []
        let seq = sequence.sequence
        
        for i in stride(from: 0, to: seq.count, by: windowSize) {
            let end = min(i + windowSize, seq.count)
            let startIndex = seq.index(seq.startIndex, offsetBy: i)
            let endIndex = seq.index(seq.startIndex, offsetBy: end)
            let window = String(seq[startIndex..<endIndex])
            
            let gc = window.filter { $0 == "G" || $0 == "C" }.count
            let gcPercent = Double(gc) / Double(window.count) * 100.0
            values.append(gcPercent)
        }
        
        return values
    }
}

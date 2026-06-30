//
//  HydropathyPlotView.swift
//  Cloner 64
//
//  Kyte-Doolittle hydropathy plot for protein sequences.
//  Plots the average hydropathy score over a sliding window.
//  Regions above 0 are hydrophobic (potential transmembrane),
//  regions below 0 are hydrophilic.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Kyte-Doolittle Hydropathy Scale

struct KyteDoolittle {
    static let scale: [Character: Double] = [
        "A":  1.8, "R": -4.5, "N": -3.5, "D": -3.5, "C":  2.5,
        "Q": -3.5, "E": -3.5, "G": -0.4, "H": -3.2, "I":  4.5,
        "L":  3.8, "K": -3.9, "M":  1.9, "F":  2.8, "P": -1.6,
        "S": -0.8, "T": -0.7, "W": -0.9, "Y": -1.3, "V":  4.2,
    ]
    
    /// Calculate sliding-window average hydropathy values
    static func hydropathyValues(sequence: String, windowSize: Int) -> [Double] {
        let seq = Array(sequence.uppercased())
        let n = seq.count
        guard n >= windowSize, windowSize > 0 else { return [] }
        
        var values: [Double] = []
        let halfWindow = windowSize / 2
        
        for i in halfWindow..<(n - windowSize + halfWindow + 1) {
            let start = i - halfWindow
            let end = start + windowSize
            var sum = 0.0
            var count = 0
            for j in start..<min(end, n) {
                if let h = scale[seq[j]] {
                    sum += h
                    count += 1
                }
            }
            values.append(count > 0 ? sum / Double(count) : 0)
        }
        
        return values
    }
}

// MARK: - Main View

struct HydropathyPlotView: View {
    @ObservedObject var protein: ProteinSequence
    
    @State private var windowSize: Int = 9
    @State private var showThreshold: Bool = true
    @State private var customThreshold: Double = 1.6
    @State private var plotFontSize: CGFloat = 11
    
    private var hydropathyData: [Double] {
        KyteDoolittle.hydropathyValues(sequence: protein.sequence, windowSize: windowSize)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerBar
            
            Divider()
            
            // Controls
            controlsBar
            
            Divider()
            
            // Plot
            if protein.sequence.isEmpty {
                VStack {
                    Spacer()
                    Text("No sequence data")
                        .font(.title3)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                plotView
            }
            
            Divider()
            
            // Footer with legend
            footerBar
        }
        .frame(minWidth: 700, minHeight: 400)
    }
    
    // MARK: - Header
    
    private var headerBar: some View {
        HStack {
            ProteinHelixIcon()
                .frame(width: 22, height: 16)
            Text(protein.name)
                .font(.system(size: 15, weight: .semibold))
            Text("(\(protein.length) aa)")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            Spacer()
            Text("Kyte-Doolittle Hydropathy Plot")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    // MARK: - Controls
    
    private var controlsBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                Text("Window size:")
                    .font(.system(size: 13))
                Picker("", selection: $windowSize) {
                    ForEach([5, 7, 9, 11, 13, 15, 17, 19, 21], id: \.self) { w in
                        Text("\(w)").tag(w)
                    }
                }
                .frame(width: 60)
                .font(.system(size: 13))
                .contextHelp("hydro.windowSize")
            }
            
            Toggle("Transmembrane threshold", isOn: $showThreshold)
                .toggleStyle(.checkbox)
                .font(.system(size: 13))
                .contextHelp("hydro.threshold")
            
            if showThreshold {
                HStack(spacing: 4) {
                    Text("at")
                        .font(.system(size: 13))
                    TextField("", value: $customThreshold, format: .number.precision(.fractionLength(1)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 40)
                        .font(.system(size: 13))
                        .contextHelp("hydro.thresholdValue")
                }
            }
            
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
    
    // MARK: - Plot
    
    private var plotView: some View {
        GeometryReader { _ in
            let data = hydropathyData
            
            Canvas { context, size in
                guard !data.isEmpty else { return }
                
                let n = data.count
                let padding = EdgeInsets(top: 20, leading: 50, bottom: 30, trailing: 20)
                let plotW = size.width - padding.leading - padding.trailing
                let plotH = size.height - padding.top - padding.bottom
                
                // Y range: symmetric around 0, at least -4.5 to 4.5
                let maxAbs = max(4.5, data.map { abs($0) }.max() ?? 4.5)
                let yMin = -maxAbs
                let yMax = maxAbs
                
                func xPos(_ i: Int) -> CGFloat {
                    padding.leading + CGFloat(i) / CGFloat(max(1, n - 1)) * plotW
                }
                func yPos(_ val: Double) -> CGFloat {
                    padding.top + CGFloat(1.0 - (val - yMin) / (yMax - yMin)) * plotH
                }
                
                // Fill hydrophobic regions (above 0) in light orange
                var fillPath = Path()
                let zeroY = yPos(0)
                fillPath.move(to: CGPoint(x: xPos(0), y: zeroY))
                for (i, val) in data.enumerated() {
                    let y = min(yPos(val), zeroY)  // only above zero line
                    fillPath.addLine(to: CGPoint(x: xPos(i), y: y))
                }
                fillPath.addLine(to: CGPoint(x: xPos(n - 1), y: zeroY))
                fillPath.closeSubpath()
                context.fill(fillPath, with: .color(.orange.opacity(0.15)))
                
                // Fill hydrophilic regions (below 0) in light blue
                var fillPath2 = Path()
                fillPath2.move(to: CGPoint(x: xPos(0), y: zeroY))
                for (i, val) in data.enumerated() {
                    let y = max(yPos(val), zeroY)  // only below zero line
                    fillPath2.addLine(to: CGPoint(x: xPos(i), y: y))
                }
                fillPath2.addLine(to: CGPoint(x: xPos(n - 1), y: zeroY))
                fillPath2.closeSubpath()
                context.fill(fillPath2, with: .color(.blue.opacity(0.08)))
                
                // Zero line
                var zeroLine = Path()
                zeroLine.move(to: CGPoint(x: padding.leading, y: zeroY))
                zeroLine.addLine(to: CGPoint(x: padding.leading + plotW, y: zeroY))
                context.stroke(zeroLine, with: .color(.gray), lineWidth: 1.0)
                
                // TM threshold line
                if showThreshold {
                    let threshY = yPos(customThreshold)
                    var threshLine = Path()
                    threshLine.move(to: CGPoint(x: padding.leading, y: threshY))
                    threshLine.addLine(to: CGPoint(x: padding.leading + plotW, y: threshY))
                    context.stroke(threshLine, with: .color(.red.opacity(0.5)),
                                  style: StrokeStyle(lineWidth: 1.0, dash: [5, 3]))
                    
                    // Label
                    context.draw(
                        Text("Transmembrane \(String(format: "%.1f", customThreshold))")
                            .font(.system(size: plotFontSize))
                            .foregroundColor(.red.opacity(0.7)),
                        at: CGPoint(x: padding.leading + plotW - 50, y: threshY - 8)
                    )
                }
                
                // Data line
                var dataPath = Path()
                for (i, val) in data.enumerated() {
                    let pt = CGPoint(x: xPos(i), y: yPos(val))
                    if i == 0 { dataPath.move(to: pt) }
                    else { dataPath.addLine(to: pt) }
                }
                context.stroke(dataPath, with: .color(.blue), lineWidth: 1.5)
                
                // Y-axis labels
                let yTicks: [Double] = [-4, -3, -2, -1, 0, 1, 2, 3, 4]
                for tick in yTicks {
                    if tick < yMin || tick > yMax { continue }
                    let y = yPos(tick)
                    
                    // Tick mark
                    var tickPath = Path()
                    tickPath.move(to: CGPoint(x: padding.leading - 4, y: y))
                    tickPath.addLine(to: CGPoint(x: padding.leading, y: y))
                    context.stroke(tickPath, with: .color(.gray), lineWidth: 0.5)
                    
                    // Grid line
                    if tick != 0 {
                        var gridLine = Path()
                        gridLine.move(to: CGPoint(x: padding.leading, y: y))
                        gridLine.addLine(to: CGPoint(x: padding.leading + plotW, y: y))
                        context.stroke(gridLine, with: .color(.gray.opacity(0.15)), lineWidth: 0.5)
                    }
                    
                    // Label
                    context.draw(
                        Text(String(format: "%.0f", tick))
                            .font(.system(size: plotFontSize))
                            .foregroundColor(.secondary),
                        at: CGPoint(x: padding.leading - 18, y: y)
                    )
                }
                
                // X-axis labels (position in sequence)
                let xTickCount = min(10, n)
                let xStep = max(1, n / xTickCount)
                for i in stride(from: 0, to: n, by: xStep) {
                    let x = xPos(i)
                    let halfWin = windowSize / 2
                    let seqPos = i + halfWin + 1  // 1-based position in sequence
                    
                    var tickPath = Path()
                    tickPath.move(to: CGPoint(x: x, y: padding.top + plotH))
                    tickPath.addLine(to: CGPoint(x: x, y: padding.top + plotH + 4))
                    context.stroke(tickPath, with: .color(.gray), lineWidth: 0.5)
                    
                    context.draw(
                        Text("\(seqPos)")
                            .font(.system(size: plotFontSize))
                            .foregroundColor(.secondary),
                        at: CGPoint(x: x, y: padding.top + plotH + 14)
                    )
                }
                
                // Axis labels
                context.drawLayer { ctx in
                    ctx.translateBy(x: 12, y: size.height / 2)
                    ctx.rotate(by: .degrees(-90))
                    ctx.draw(
                        Text("Hydropathy")
                            .font(.system(size: plotFontSize + 1))
                            .foregroundColor(.secondary),
                        at: .zero,
                        anchor: .center
                    )
                }
                
                context.draw(
                    Text("Residue position")
                        .font(.system(size: plotFontSize + 1))
                        .foregroundColor(.secondary),
                    at: CGPoint(x: size.width / 2, y: size.height - 4)
                )
                
                // "Hydrophobic" / "Hydrophilic" labels
                context.draw(
                    Text("Hydrophobic")
                        .font(.system(size: plotFontSize, weight: .medium))
                        .foregroundColor(.orange.opacity(0.7)),
                    at: CGPoint(x: padding.leading + 50, y: padding.top + 10)
                )
                context.draw(
                    Text("Hydrophilic")
                        .font(.system(size: plotFontSize, weight: .medium))
                        .foregroundColor(.blue.opacity(0.5)),
                    at: CGPoint(x: padding.leading + 50, y: padding.top + plotH - 10)
                )
                
                // Border
                var border = Path()
                border.addRect(CGRect(x: padding.leading, y: padding.top,
                                      width: plotW, height: plotH))
                context.stroke(border, with: .color(.gray.opacity(0.4)), lineWidth: 0.5)
            }
        }
        .padding(4)
    }
    
    // MARK: - Footer
    
    private var footerBar: some View {
        HStack(spacing: 12) {
            Text("Kyte & Doolittle, J. Mol. Biol. 157:105-132 (1982)")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .italic()
            
            Spacer()
            
            HStack(spacing: 4) {
                Text("Font:")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                Button(action: { plotFontSize = max(8, plotFontSize - 1) }) {
                    Image(systemName: "minus")
                        .font(.system(size: 13))
                }
                .buttonStyle(.borderless)
                .contextHelp("hydro.fontSize")
                Text("\(Int(plotFontSize))")
                    .font(.system(size: 13, design: .monospaced))
                    .frame(width: 20)
                Button(action: { plotFontSize = min(18, plotFontSize + 1) }) {
                    Image(systemName: "plus")
                        .font(.system(size: 13))
                }
                .buttonStyle(.borderless)
                .contextHelp("hydro.fontSize")
            }
            
            Button("Copy Data") { copyDataToClipboard() }
                .controlSize(.small)
                .contextHelp("hydro.copyData")
            
            Button(action: { savePlotAs(format: .pdf) }) {
                Label("PDF", systemImage: "doc")
            }
            .controlSize(.small)
            .contextHelp("hydro.savePDF")
            
            Button(action: { savePlotAs(format: .png) }) {
                Label("PNG", systemImage: "photo")
            }
            .controlSize(.small)
            .contextHelp("hydro.savePNG")
            
            Button(action: printPlot) {
                Label("Print", systemImage: "printer")
            }
            .controlSize(.small)
            .contextHelp("hydro.print")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    // MARK: - Actions
    
    private func copyDataToClipboard() {
        let data = hydropathyData
        let halfWin = windowSize / 2
        var lines = ["Position\tHydropathy"]
        for (i, val) in data.enumerated() {
            lines.append("\(i + halfWin + 1)\t\(String(format: "%.3f", val))")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
    
    // MARK: - Save / Print
    
    private enum ImageFormat { case pdf, png }
    
    /// Render the full view (header + plot + footer) to an NSImage via cacheDisplay.
    private func renderPlotImage() -> NSImage? {
        let plotWidth: CGFloat = 900
        let plotHeight: CGFloat = 500
        
        let wrapped = VStack(spacing: 0) {
            headerBar
            Divider()
            controlsBar
            Divider()
            plotView
            Divider()
            footerBar
        }
        .frame(width: plotWidth, height: plotHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        
        let hostingView = NSHostingView(rootView: wrapped)
        hostingView.frame = NSRect(origin: .zero, size: NSSize(width: plotWidth, height: plotHeight))
        
        guard let bitmapRep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else { return nil }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmapRep)
        
        let image = NSImage(size: NSSize(width: plotWidth, height: plotHeight))
        image.addRepresentation(bitmapRep)
        return image
    }
    
    private func savePlotAs(format: ImageFormat) {
        let baseName = protein.name.replacingOccurrences(of: " ", with: "_")
        
        let panel = NSSavePanel()
        panel.title = "Save Hydropathy Plot"
        panel.canCreateDirectories = true
        
        switch format {
        case .pdf:
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = "\(baseName)_hydropathy.pdf"
        case .png:
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "\(baseName)_hydropathy.png"
        }
        
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let image = renderPlotImage() else { return }
        
        switch format {
        case .pdf:
            let pdfData = NSMutableData()
            var mediaBox = CGRect(origin: .zero, size: image.size)
            guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return }
            
            context.beginPDFPage(nil)
            if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                context.draw(cgImage, in: mediaBox)
            }
            context.endPDFPage()
            context.closePDF()
            
            pdfData.write(to: url, atomically: true)
            
        case .png:
            if let tiffData = image.tiffRepresentation,
               let bitmapRep = NSBitmapImageRep(data: tiffData),
               let pngData = bitmapRep.representation(using: .png, properties: [:]) {
                try? pngData.write(to: url)
            }
        }
    }
    
    private func printPlot() {
        guard let image = renderPlotImage() else { return }
        
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: image.size))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyDown
        
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        info.orientation = .landscape
        
        let op = NSPrintOperation(view: imageView, printInfo: info)
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.run()
    }
}

// MARK: - Window Manager

class HydropathyPlotWindowManager {
    static let shared = HydropathyPlotWindowManager()
    
    private var windows: [NSWindow] = []
    private init() {}
    
    func openWindow(protein: ProteinSequence) {
        let view = HydropathyPlotView(protein: protein)
        
        let hostingController = NSHostingController(rootView: view)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 450),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        window.title = "Hydropathy Plot - \(protein.name)"
        window.contentViewController = hostingController
        window.setFrameAutosaveName("HydropathyPlot")
        if !window.setFrameUsingName(window.frameAutosaveName) { window.center() }
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 350)
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

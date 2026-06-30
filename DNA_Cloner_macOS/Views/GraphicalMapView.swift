import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Notification for fragment creation
extension Notification.Name {
    static let createSequenceFromFragment = Notification.Name("createSequenceFromFragment")
}

// MARK: - Construct Builder Communication

/// Lightweight reference to a selected cut site, used to pass selections
/// from GraphicalMapView back to the ConstructBuilderView.
struct CutSiteRef: Equatable {
    let enzyme: String
    let position: Int              // recognition-site start (0-based)
    let cutPos5: Int               // absolute 5′ cut position
    let cutPos3: Int               // absolute 3′ cut position
    let overhangType: RestrictionEnzyme.OverhangType
    let siteCount: Int
}

extension Notification.Name {
    /// Posted by GraphicalMapView when construct-mode site selection changes.
    /// userInfo keys: "fragmentIndex" (Int), "first" (CutSiteRef?), "second" (CutSiteRef?)
    static let constructSiteSelectionChanged = Notification.Name("constructSiteSelectionChanged")
}

// MARK: - Graphical Map Window
struct GraphicalMapWindow: View {
    /// Suppresses the map until the first background site scan has completed,
    /// preventing the brief flash of a bare plasmid with no restriction site labels.
    @State private var mapIsReady = false
    @ObservedObject var sequence: DNASequence
    @State private var showUniqueSites: Bool = true
    @State private var showDoubleSites: Bool = false
    @State private var showParticularSites: Bool = false
    @State private var showBluntSites: Bool = false
    @State private var showFeatures: Bool = true
    @State private var showORFs: Bool = false
    @State private var selectedParticularEnzymes: Set<String> = []
    @State private var resetLabelTrigger: Bool = false
    @State private var showEnzymePicker: Bool = false
    @State private var hiddenFeatureIDs: Set<UUID> = []
    @State private var showFeaturePicker: Bool = false
    @State private var hiddenORFIDs: Set<UUID> = []
    @State private var showORFPicker: Bool = false
    @State private var mapScale: CGFloat = 1.0
    @State private var labelFontSize: CGFloat = 13
    @AppStorage("methylation_dam") private var methylationDam: Bool = true
    @AppStorage("methylation_dcm") private var methylationDcm: Bool = true
    @AppStorage("methylation_cpg") private var methylationCpG: Bool = false
    @AppStorage("hideImportedFeatures") private var hideImportedFeatures: Bool = false
    @State private var showMethylationPopover: Bool = false
    @State private var showSitesPopover: Bool = false
    @State private var showDisplayPopover: Bool = false
    @State private var nonCuttingEnzymes: Set<String> = []
    @State private var useMyEnzymesOnly: Bool = false
    @State private var printLandscape: Bool = true  // set on appear based on map shape
    @State private var showSplitView: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            if showSplitView {
                VSplitView {
                    mapOnlyContent
                        .frame(minHeight: 350)
                    CompactSequencePanel(sequence: sequence)
                        .frame(minHeight: 200)
                }
            } else {
                mapOnlyContent
            }
        }
        .frame(minWidth: 750, minHeight: showSplitView ? 650 : 500)
        .textSelection(.enabled)
        .onAppear {
            // Circular maps suit portrait; linear maps suit landscape
            printLandscape = !sequence.isCircular
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                // Sites popover
                Button {
                    showSitesPopover = true
                } label: {
                    Label("Sites", systemImage: "scissors")
                }
                .contextHelp("gmap.sitesMenu")
                .popover(isPresented: $showSitesPopover) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Restriction Sites")
                            .font(.system(size: 13, weight: .semibold))
                        
                        Toggle("Unique Sites", isOn: $showUniqueSites)
                            .font(.system(size: 13))
                        Toggle("Double Sites", isOn: $showDoubleSites)
                            .font(.system(size: 13))
                        Toggle("Blunt Sites", isOn: $showBluntSites)
                            .font(.system(size: 13))
                        
                        Divider()
                        
                        Toggle(isOn: $useMyEnzymesOnly) {
                            Label("My Enzymes Only", systemImage: "star.fill")
                                .font(.system(size: 13))
                        }
                        .disabled(RestrictionEnzymeDatabase.shared.myEnzymeNames.isEmpty)
                        .help(RestrictionEnzymeDatabase.shared.myEnzymeNames.isEmpty
                              ? "No enzymes marked — use Tools → Restriction Enzyme List to star enzymes"
                              : "Show only enzymes in your freezer")
                        
                        Divider()
                        
                        Toggle("Particular Sites", isOn: $showParticularSites)
                            .font(.system(size: 13))
                        if showParticularSites {
                            Button(selectedParticularEnzymes.isEmpty
                                   ? "Select Enzymes…"
                                   : "\(selectedParticularEnzymes.count) selected…") {
                                showSitesPopover = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showEnzymePicker = true
                                }
                            }
                            .font(.system(size: 12))
                        }
                        Divider()

                        // Colour key
                        Text("Label colours")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            ColourKeyRow(color: Color(red: 1.0, green: 0.98, blue: 0.86), label: "Unique cutter")
                            ColourKeyRow(color: Color(red: 0.82, green: 0.61, blue: 0.35), label: "Double cutter")
                            ColourKeyRow(gradient: [Color(red: 1.0, green: 0.98, blue: 0.86), Color(red: 0.35, green: 0.80, blue: 0.75)], label: "Unique + blunt")
                            ColourKeyRow(gradient: [Color(red: 0.82, green: 0.61, blue: 0.35), Color(red: 0.35, green: 0.80, blue: 0.75)], label: "Double + blunt")
                            ColourKeyRow(color: Color(red: 0.35, green: 0.80, blue: 0.75), label: "Blunt (3+ cuts)")
                            ColourKeyRow(color: Color(red: 0.68, green: 0.85, blue: 1.0), label: "Particular enzyme")
                            if useMyEnzymesOnly {
                                ColourKeyRow(color: Color(red: 0.88, green: 0.78, blue: 0.97), label: "My enzyme (multi-cutter)")
                            }
                        }
                    }
                    .padding(12)
                    .frame(width: 220)
                }
                
                // Display popover
                Button {
                    showDisplayPopover = true
                } label: {
                    Label("Display", systemImage: "eye")
                }
                .contextHelp("gmap.displayMenu")
                .popover(isPresented: $showDisplayPopover) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Display Options")
                            .font(.system(size: 13, weight: .semibold))
                        
                        Toggle("Features", isOn: $showFeatures)
                            .font(.system(size: 13))
                        if showFeatures && !sequence.features.isEmpty {
                            Button("Choose Features (\(sequence.features.count - hiddenFeatureIDs.count)/\(sequence.features.count))…") {
                                showDisplayPopover = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showFeaturePicker = true
                                }
                            }
                            .font(.system(size: 12))
                        }
                        
                        Divider()
                        
                        Toggle("ORFs", isOn: $showORFs)
                            .font(.system(size: 13))
                        if showORFs && !sequence.orfResults.isEmpty {
                            Button("Choose ORFs (\(sequence.orfResults.count - hiddenORFIDs.count)/\(sequence.orfResults.count))…") {
                                showDisplayPopover = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showORFPicker = true
                                }
                            }
                            .font(.system(size: 12))
                        }
                    }
                    .padding(12)
                    .frame(width: 240)
                }
                
                // Methylation
                Button {
                    showMethylationPopover.toggle()
                } label: {
                    Image(systemName: "m.circle")
                }
                .popover(isPresented: $showMethylationPopover) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Methylation Sensitivity")
                            .font(.system(size: 13, weight: .semibold))
                        Toggle("Dam (GATC)", isOn: $methylationDam)
                            .font(.system(size: 13))
                        Toggle("Dcm (CCWGG)", isOn: $methylationDcm)
                            .font(.system(size: 13))
                        Toggle("CpG", isOn: $methylationCpG)
                            .font(.system(size: 13))
                        Divider()
                        Text("Label colour coding")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        HStack(spacing: 6) {
                            Text("EcoRI")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.red)
                                .strikethrough(true, color: .red)
                            Text("Blocked — will not cut")
                                .font(.system(size: 11))
                        }
                        HStack(spacing: 6) {
                            Text("DpnI")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.blue)
                            Text("Required — only cuts if methylated")
                                .font(.system(size: 11))
                        }
                    }
                    .padding(12)
                    .frame(width: 250)
                }
                .help("Methylation sensitivity")
                .contextHelp("gmap.methylationMenu")
                
                Divider()
                
                // Zoom
                Button(action: { mapScale = max(0.5, mapScale - 0.1) }) {
                    Image(systemName: "minus.magnifyingglass")
                }
                .contextHelp("gmap.zoomOut")
                Button(action: { mapScale = min(3.0, mapScale + 0.1) }) {
                    Image(systemName: "plus.magnifyingglass")
                }
                .contextHelp("gmap.zoomIn")
                Button(action: { mapScale = 1.0 }) {
                    Image(systemName: "1.magnifyingglass")
                }
                .contextHelp("gmap.zoomReset")
                
                // Font
                HStack(spacing: 2) {
                    Button(action: { labelFontSize = max(9, labelFontSize - 1) }) {
                        Image(systemName: "textformat.size.smaller")
                    }
                    .buttonStyle(.borderless)
                    .contextHelp("gmap.fontSmaller")
                    Button(action: { labelFontSize = min(20, labelFontSize + 1) }) {
                        Image(systemName: "textformat.size.larger")
                    }
                    .buttonStyle(.borderless)
                    .contextHelp("gmap.fontLarger")
                }
                
                Divider()
                
                // Split view toggle
                Button(action: { showSplitView.toggle() }) {
                    Label(showSplitView ? "Single View" : "Split View",
                          systemImage: showSplitView ? "square.split.1x2.fill" : "square.split.1x2")
                }
                .help(showSplitView
                      ? "Return to map-only view"
                      : "Show map and sequence panel together in this window")
                .contextHelp("gmap.splitView")
                
                Divider()
                
                // Home — return to sequence editor
                Button(action: goHome) {
                    Label("Home", systemImage: "house")
                }
                .help("Return to sequence editor window")
                .contextHelp("gmap.home")
                
                Divider()
                
                // Export
                Button(action: { exportMap(format: .pdf) }) {
                    Text("PDF")
                        .font(.system(size: 11, weight: .medium))
                }
                .contextHelp("gmap.exportPDF")
                
                Button(action: { exportMap(format: .png) }) {
                    Text("PNG")
                        .font(.system(size: 11, weight: .medium))
                }
                .contextHelp("gmap.exportPNG")
                
                Button(action: { printMap() }) {
                    Text("Print")
                        .font(.system(size: 11, weight: .medium))
                }
                .contextHelp("gmap.printMap")
                
                Button(action: copyMapToClipboard) {
                    Label("Copy Image", systemImage: "doc.on.clipboard")
                }
                .controlSize(.small)
                .contextHelp("gmap.copyImage")
                
                Button(action: { printLandscape.toggle() }) {
                    Label(printLandscape ? "Landscape" : "Portrait",
                          systemImage: printLandscape ? "rectangle" : "rectangle.portrait")
                        .foregroundColor(printLandscape ? .accentColor : .orange)
                }
                .controlSize(.small)
                .contextHelp("gmap.printOrientation")
            }
        }
    }
    
    // MARK: - Map-only content (used in both single and split view)

    /// Effective hidden feature IDs — combines user-selected hidden IDs with
    /// imported feature IDs when hideImportedFeatures is active.
    private var effectiveHiddenFeatureIDs: Set<UUID> {
        if hideImportedFeatures {
            let importedIDs = Set(sequence.features.filter { $0.source == .imported }.map(\.id))
            return hiddenFeatureIDs.union(importedIDs)
        }
        return hiddenFeatureIDs
    }

    private var mapOnlyContent: some View {
        GraphicalMapView(
            sequence: sequence,
            showUniqueSites: showUniqueSites,
            showDoubleSites: showDoubleSites,
            showParticularSites: showParticularSites,
            showBluntSites: showBluntSites,
            showFeatures: showFeatures,
            showORFs: showORFs,
            selectedParticularEnzymes: selectedParticularEnzymes,
            hiddenFeatureIDs: effectiveHiddenFeatureIDs,
            hiddenORFIDs: hiddenORFIDs,
            mapScale: $mapScale,
            labelFontSize: labelFontSize,
            resetLabelTrigger: $resetLabelTrigger,
            useMyEnzymesOnly: useMyEnzymesOnly,
            isReady: $mapIsReady
        )
        .popover(isPresented: $showFeaturePicker) {
            featurePickerPopover
        }
        .popover(isPresented: $showORFPicker) {
            orfPickerPopover
        }
        .popover(isPresented: $showEnzymePicker) {
            enzymePickerPopover
        }
    }

    // MARK: - Home

    private func goHome() {
        for window in NSApp.windows where window != NSApp.keyWindow {
            let title = window.title
            if title == sequence.name
                || (sequence.name.isEmpty && (title == "Untitled Sequence" || title == "Untitled"))
            {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
        }
    }
    
    // MARK: - Export / Print
    
    private enum ImageFormat { case pdf, png }
    
    private func renderMapImage() -> NSImage? {
        let mapView = GraphicalMapView(
            sequence: sequence,
            showUniqueSites: showUniqueSites,
            showDoubleSites: showDoubleSites,
            showParticularSites: showParticularSites,
            showBluntSites: showBluntSites,
            showFeatures: showFeatures,
            showORFs: showORFs,
            selectedParticularEnzymes: selectedParticularEnzymes,
            hiddenFeatureIDs: effectiveHiddenFeatureIDs,
            hiddenORFIDs: hiddenORFIDs,
            mapScale: .constant(mapScale),
            labelFontSize: labelFontSize,
            resetLabelTrigger: .constant(false),
            isReady: .constant(true)
        )
        let size = NSSize(width: 1000 * mapScale, height: 800 * mapScale)
        let hostingView = NSHostingView(rootView: mapView.frame(width: size.width, height: size.height))
        hostingView.frame = NSRect(origin: .zero, size: size)
        
        // cacheDisplay is the only reliable way to capture SwiftUI content
        // from an NSHostingView — dataWithPDF and layer.render both need a
        // full display cycle that we can't force synchronously.
        guard let bitmapRep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else { return nil }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmapRep)
        
        let image = NSImage(size: size)
        image.addRepresentation(bitmapRep)
        return image
    }
    
    private func exportMap(format: ImageFormat) {
        let panel = NSSavePanel()
        panel.title = "Export Map"
        
        switch format {
        case .pdf:
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = "\(sequence.name)_map.pdf"
        case .png:
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "\(sequence.name)_map.png"
        }
        
        guard let window = NSApplication.shared.keyWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            guard let image = renderMapImage() else { return }
            
            switch format {
            case .pdf:
                // Render bitmap into a PDF page
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
    }
    
    private func printMap() {
        guard let image = renderMapImage() else { return }
        
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: image.size))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyDown
        
        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .fit
        printInfo.isHorizontallyCentered = true
        printInfo.isVerticallyCentered = true
        printInfo.orientation = printLandscape ? .landscape : .portrait
        
        let printOp = NSPrintOperation(view: imageView, printInfo: printInfo)
        printOp.showsPrintPanel = true
        printOp.showsProgressPanel = true
        printOp.run()
    }
    
    private func copyMapToClipboard() {
        guard let image = renderMapImage() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }
    
    private var enzymePickerPopover: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Select Enzymes")
                    .font(.headline)
                Spacer()
                Button("Clear All") {
                    selectedParticularEnzymes.removeAll()
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)
            
            Divider()
            
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(availableEnzymes, id: \.self) { enzyme in
                        let doesNotCut = nonCuttingEnzymes.contains(enzyme)
                        Toggle(isOn: Binding(
                            get: { selectedParticularEnzymes.contains(enzyme) },
                            set: { isOn in
                                if isOn {
                                    selectedParticularEnzymes.insert(enzyme)
                                } else {
                                    selectedParticularEnzymes.remove(enzyme)
                                }
                            }
                        )) {
                            Text(enzyme)
                                .italic(doesNotCut)
                                .foregroundColor(doesNotCut ? .secondary : .primary)
                        }
                        .toggleStyle(.checkbox)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 2)
                    }
                }
            }
            .frame(width: 220, height: 300)
        }
        .padding(.bottom, 8)
        .onAppear {
            computeNonCuttingEnzymes()
        }
    }
    
    /// Computes which enzymes in the database do not cut the current sequence.
    /// Called when the enzyme picker popover appears. Runs on a background
    /// queue so opening the popover stays responsive for large enzyme databases.
    private func computeNonCuttingEnzymes() {
        let database = RestrictionEnzymeDatabase.shared
        let enzymeList = useMyEnzymesOnly ? database.myEnzymes : database.enzymes
        let seq = sequence.sequence
        let circular = sequence.isCircular
        DispatchQueue.global(qos: .userInitiated).async {
            var nonCutters = Set<String>()
            for enzyme in enzymeList {
                if enzyme.findCutSites(in: seq, circular: circular).isEmpty {
                    nonCutters.insert(enzyme.name)
                }
            }
            DispatchQueue.main.async {
                nonCuttingEnzymes = nonCutters
            }
        }
    }
    
    private var availableEnzymes: [String] {
        let database = RestrictionEnzymeDatabase.shared
        let enzymes = useMyEnzymesOnly ? database.myEnzymes : database.enzymes
        return enzymes.map { $0.name }.sorted()
    }
    
    private var featurePickerPopover: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Show Features")
                    .font(.headline)
                Spacer()
                Button("Show All") {
                    hiddenFeatureIDs.removeAll()
                }
                .controlSize(.small)
                Button("Hide All") {
                    hiddenFeatureIDs = Set(sequence.features.map(\.id))
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)
            
            Divider()
            
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(sequence.features) { feature in
                        Toggle(isOn: Binding(
                            get: { !hiddenFeatureIDs.contains(feature.id) },
                            set: { isOn in
                                if isOn {
                                    hiddenFeatureIDs.remove(feature.id)
                                } else {
                                    hiddenFeatureIDs.insert(feature.id)
                                }
                            }
                        )) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(feature.color.color)
                                    .frame(width: 10, height: 10)
                                Text(feature.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                Text("\(abs(feature.end - feature.start)) bp")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 2)
                    }
                }
            }
            .frame(width: 320, height: min(CGFloat(sequence.features.count) * 24 + 10, 300))
        }
        .padding(.bottom, 8)
    }
    
    private var orfPickerPopover: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Show ORFs")
                    .font(.headline)
                Spacer()
                Button("Show All") {
                    hiddenORFIDs.removeAll()
                }
                .controlSize(.small)
                Button("Hide All") {
                    hiddenORFIDs = Set(sequence.orfResults.map(\.id))
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)
            
            Divider()
            
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(sequence.orfResults) { orf in
                        Toggle(isOn: Binding(
                            get: { !hiddenORFIDs.contains(orf.id) },
                            set: { isOn in
                                if isOn {
                                    hiddenORFIDs.remove(orf.id)
                                } else {
                                    hiddenORFIDs.insert(orf.id)
                                }
                            }
                        )) {
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(orfColorForPicker(orf.strand))
                                    .frame(width: 10, height: 10)
                                Text(orf.label)
                                    .font(.caption)
                                    .lineLimit(1)
                                Text("\(orf.size) bp (\(orf.size / 3) aa)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(orf.strand)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .frame(width: 24, alignment: .trailing)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 2)
                    }
                }
            }
            .frame(width: 320, height: min(CGFloat(sequence.orfResults.count) * 24 + 10, 300))
        }
        .padding(.bottom, 8)
    }
    
    private func orfColorForPicker(_ strand: String) -> Color {
        switch strand {
        case "+1": return .orange
        case "+2": return .cyan
        case "+3": return .mint
        case "-1": return .pink
        case "-2": return .purple
        case "-3": return .indigo
        default: return .orange
        }
    }
}

// MARK: - Colour key row used in the restriction sites popover
private struct ColourKeyRow: View {
    var color: Color? = nil
    var gradient: [Color]? = nil
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(
                    gradient != nil
                        ? AnyShapeStyle(LinearGradient(colors: gradient!, startPoint: .leading, endPoint: .trailing))
                        : AnyShapeStyle(color ?? .clear)
                )
                .frame(width: 28, height: 12)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.black.opacity(0.25), lineWidth: 0.5))
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.primary)
        }
    }
}

// MARK: - Main Graphical Map View
struct GraphicalMapView: View {
    @ObservedObject var sequence: DNASequence
    let showUniqueSites: Bool
    let showDoubleSites: Bool
    let showParticularSites: Bool
    let showBluntSites: Bool
    let showFeatures: Bool
    let showORFs: Bool
    let selectedParticularEnzymes: Set<String>
    let hiddenFeatureIDs: Set<UUID>
    var hiddenORFIDs: Set<UUID> = []
    @Binding var mapScale: CGFloat
    let labelFontSize: CGFloat
    @Binding var resetLabelTrigger: Bool
    
    /// When > 0, this map is embedded in the construct builder.
    /// 1 = vector fragment, 2 = insert fragment.
    /// Site-selection changes are posted as notifications.
    var constructFragmentIndex: Int = 0
    
    /// When true, the fragment selection bar at the bottom is hidden (e.g. in construct preview).
    var hideFragmentBar: Bool = false
    
    /// When true, only show enzymes the user has marked as "My Enzymes" (freezer stock).
    var useMyEnzymesOnly: Bool = false
    
    /// Set to true once the first site scan completes, so the parent
    /// can suppress display until the map is fully ready.
    @Binding var isReady: Bool
    
    @State private var scaleAtGestureStart: CGFloat = 1.0
    
    // Methylation sensitivity (shared via AppStorage)
    @AppStorage("methylation_dam") private var methylationDam: Bool = true
    @AppStorage("methylation_dcm") private var methylationDcm: Bool = true
    @AppStorage("methylation_cpg") private var methylationCpG: Bool = false

    // Cached per-site methylation results keyed by "EnzymeName_Position".
    // Rebuilt on background thread whenever sites or methylation settings change.
    @State private var cachedMethylationWarning:  [String: String] = [:]
    @State private var cachedMethylationBlocked:  [String: Bool]   = [:]
    @State private var cachedMethylationRequired: [String: Bool]   = [:]

    /// Recompute methylation warnings and blocked flags for all currently visible
    /// sites on a background thread, then update methylation warnings.
    /// Pass damOverride/dcmOverride/cpgOverride when calling from an onChange closure
    /// to avoid capturing a stale copy of the AppStorage property.
    /// Pass sitesOverride (computed via filteredSites(…)) when a filter flag just
    /// changed, to avoid capturing a stale copy of the filter flag itself.
    private func refreshMethylationCache(
        damOverride:   Bool? = nil,
        dcmOverride:   Bool? = nil,
        cpgOverride:   Bool? = nil,
        sitesOverride: [(enzyme: String, position: Int, siteCount: Int)]? = nil
    ) {
        let seq      = sequence.sequence.uppercased()
        let circular = sequence.isCircular
        let dam      = damOverride ?? methylationDam
        let dcm      = dcmOverride ?? methylationDcm
        let cpg      = cpgOverride ?? methylationCpG
        let sites    = sitesOverride ?? cachedFilteredSites
        let enzDict  = enzymeByName

        DispatchQueue.global(qos: .userInitiated).async {
            var warnings:  [String: String] = [:]
            var blocked:   [String: Bool]   = [:]
            var required:  [String: Bool]   = [:]
            for site in sites {
                guard let enz = enzDict[site.enzyme] else { continue }
                let w = MethylationChecker.checkSite(
                    enzymeName:      site.enzyme,
                    sitePosition:    site.position,
                    recognitionSite: enz.recognitionSite,
                    sequence:        seq,
                    circular:        circular,
                    activeDam:       dam,
                    activeDcm:       dcm,
                    activeCpG:       cpg
                )
                let key = "\(site.enzyme)_\(site.position)"
                warnings[key]  = MethylationChecker.warningText(w)
                blocked[key]   = MethylationChecker.isCutBlocked(w)
                required[key]  = w.contains { $0.effect == .required }
            }
            DispatchQueue.main.async {
                self.cachedMethylationWarning  = warnings
                self.cachedMethylationBlocked  = blocked
                self.cachedMethylationRequired = required
                // No need to refresh label placements here — circularMapBody now computes
                // placements inline from cachedFilteredSites, so they update automatically.
            }
        }
    }

    /// O(1) methylation warning lookup (replaces per-render enzyme scan).
    private func methylationWarning(enzyme: String, position: Int) -> String {
        cachedMethylationWarning["\(enzyme)_\(position)"] ?? ""
    }

    /// O(1) methylation blocked lookup (replaces per-render enzyme scan).
    private func isMethylationBlocked(enzyme: String, position: Int) -> Bool {
        cachedMethylationBlocked["\(enzyme)_\(position)"] ?? false
    }

    /// O(1) methylation required lookup — true when the enzyme needs methylation to cut.
    private func isMethylationRequired(enzyme: String, position: Int) -> Bool {
        cachedMethylationRequired["\(enzyme)_\(position)"] ?? false
    }
    
    /// Features filtered by the user's visibility choices
    private var visibleFeatures: [Feature] {
        sequence.features.filter { !hiddenFeatureIDs.contains($0.id) }
    }
    
    /// ORFs filtered by the user's visibility choices
    private var visibleORFs: [DNASequence.ORFResult] {
        sequence.orfResults.filter { !hiddenORFIDs.contains($0.id) }
    }
    
    // Forces a redraw on first appear to clear any first-frame layout glitches
    @State private var redrawTrigger: Bool = false

    // Drag offset storage: key is "EnzymeName_Position"
    @State private var labelOffsets: [String: CGSize] = [:]
    @State private var activeDragKey: String? = nil
    
    // Feature selection (double-click to select and copy)
    @State private var selectedFeatureID: UUID? = nil
    @State private var selectedORFID: UUID? = nil
    @State private var showFeatureCopied: Bool = false
    @State private var featureLabelOffsets: [String: CGSize] = [:]
    @State private var activeFeatureDragKey: String? = nil
    
    // Draggable title offset
    @State private var titleOffset: CGSize = .zero
    @State private var titleDragStart: CGSize? = nil
    
    // Feature/ORF open as new sequence dialog
    @State private var showOpenFeatureDialog: Bool = false
    @State private var featureToOpen: Feature? = nil
    @State private var orfToOpen: DNASequence.ORFResult? = nil
    
    // Fragment direction choice for circular sequences
    @State private var useWrapFragment: Bool = false
    
    // MARK: - Fragment Selection (click two enzyme sites)
    @State private var firstCutSite: (enzyme: String, position: Int)? = nil
    @State private var secondCutSite: (enzyme: String, position: Int)? = nil

    // Cached restriction site list — rebuilt only when sequence or filter settings change,
    // not on every tap. Keeps site-selection taps fast.
    /// All enzyme cut sites, unfiltered. Updated asynchronously when the sequence
    /// or enzyme list changes. Filtering is done synchronously via cachedFilteredSites.
    @State private var cachedAllEnzymeSites: [(enzyme: String, position: Int, siteCount: Int)] = []

    private var cachedFilteredSites: [(enzyme: String, position: Int, siteCount: Int)] {
        cachedAllEnzymeSites.filter { site in
            if showUniqueSites     && site.siteCount == 1                              { return true }
            if showDoubleSites     && site.siteCount == 2                              { return true }
            if showParticularSites && selectedParticularEnzymes.contains(site.enzyme)  { return true }
            if showBluntSites      && isBluntCutter(site.enzyme)                       { return true }
            // When My Enzymes filter is on, show every site for every starred enzyme
            // regardless of cut count — the user explicitly wants to see their stock.
            if useMyEnzymesOnly    && RestrictionEnzymeDatabase.shared.myEnzymeNames.contains(site.enzyme) { return true }
            return false
        }
    }

    /// Compute filtered sites with optional per-flag overrides.
    /// Use from onChange handlers so the new value of a just-changed flag is used
    /// rather than whatever stale copy of self the closure captured.
    private func filteredSites(
        bluntOverride:             Bool?       = nil,
        uniqueOverride:            Bool?       = nil,
        doubleOverride:            Bool?       = nil,
        particularOverride:        Bool?       = nil,
        particularEnzymesOverride: Set<String>? = nil,
        myEnzymesOverride:         Bool?       = nil
    ) -> [(enzyme: String, position: Int, siteCount: Int)] {
        let useBlunt      = bluntOverride             ?? showBluntSites
        let useUnique     = uniqueOverride             ?? showUniqueSites
        let useDouble     = doubleOverride             ?? showDoubleSites
        let useParticular = particularOverride         ?? showParticularSites
        let useEnzymes    = particularEnzymesOverride  ?? selectedParticularEnzymes
        let useMyEnzymes  = myEnzymesOverride          ?? useMyEnzymesOnly
        return cachedAllEnzymeSites.filter { site in
            if useUnique     && site.siteCount == 1                                                              { return true }
            if useDouble     && site.siteCount == 2                                                              { return true }
            if useParticular && useEnzymes.contains(site.enzyme)                                                 { return true }
            if useBlunt      && isBluntCutter(site.enzyme)                                                       { return true }
            if useMyEnzymes  && RestrictionEnzymeDatabase.shared.myEnzymeNames.contains(site.enzyme)             { return true }
            return false
        }
    }

    // O(1) enzyme lookup — replaces repeated linear searches through the database.
    @State private var enzymeByName: [String: RestrictionEnzyme] = [:]

    /// Build the enzyme name→object dictionary. Fast and synchronous; called on appear
    /// and whenever the database might have changed.
    private func refreshEnzymeDict() {
        var dict: [String: RestrictionEnzyme] = [:]
        for enzyme in RestrictionEnzymeDatabase.shared.enzymes {
            dict[enzyme.name] = enzyme
        }
        enzymeByName = dict
    }

    /// Run the full enzyme site scan on a background thread so the UI never freezes.
    /// All SwiftUI state needed by the scan is captured as local constants before
    /// the dispatch, so nothing is accessed from the wrong thread.
    /// Runs the full enzyme site scan on a background thread (the expensive part).
    /// Only call this when the sequence or enzyme list changes — NOT for filter toggles.
    /// Filtering is done synchronously by the cachedFilteredSites computed property.
    /// Call refreshSiteCache() normally, or refreshSiteCache(useMyEnzymes: newValue)
    /// from an onChange closure to avoid capturing a stale copy of useMyEnzymesOnly.
    private func refreshSiteCache(useMyEnzymes: Bool? = nil) {
        let seq          = sequence.sequence
        let circular     = sequence.isCircular
        let useMyEnzymes = useMyEnzymes ?? useMyEnzymesOnly

        DispatchQueue.global(qos: .userInitiated).async {
            let database   = RestrictionEnzymeDatabase.shared
            let enzymeList = useMyEnzymes ? database.myEnzymes : database.enzymes

            var allSites: [(enzyme: String, position: Int)] = []
            for enzyme in enzymeList {
                let cutSites = enzyme.findCutSites(in: seq, circular: circular)
                var positionSeen: Set<Int> = []
                for cs in cutSites {
                    if !positionSeen.contains(cs.position) {
                        allSites.append((enzyme: enzyme.name, position: cs.position))
                        positionSeen.insert(cs.position)
                    }
                }
            }

            var enzymeSiteCounts: [String: Int] = [:]
            for site in allSites { enzymeSiteCounts[site.enzyme, default: 0] += 1 }

            let rawSites = allSites.map { site -> (enzyme: String, position: Int, siteCount: Int) in
                (enzyme: site.enzyme, position: site.position, siteCount: enzymeSiteCounts[site.enzyme] ?? 0)
            }

            DispatchQueue.main.async {
                self.cachedAllEnzymeSites = rawSites
                self.isReady = true
                self.refreshMethylationCache()
            }
        }
    }

    // MARK: - Circular Label Placement Cache

    /// Cached result of calculateLabelPlacements for the circular map.
    /// Recomputed only when sites, methylation, scale, features, or font change.


    private func labelKey(for site: (enzyme: String, position: Int, siteCount: Int)) -> String {
        "\(site.enzyme)_\(site.position)"
    }
    
    private func siteIsFirstCut(_ site: (enzyme: String, position: Int, siteCount: Int)) -> Bool {
        guard let first = firstCutSite else { return false }
        return first.enzyme == site.enzyme && first.position == site.position
    }
    
    private func siteIsSecondCut(_ site: (enzyme: String, position: Int, siteCount: Int)) -> Bool {
        guard let second = secondCutSite else { return false }
        return second.enzyme == site.enzyme && second.position == site.position
    }
    
    private func handleSiteTap(_ site: (enzyme: String, position: Int, siteCount: Int)) {
        let tapped = (enzyme: site.enzyme, position: site.position)
        
        // If tapping a site that's already selected, deselect it
        if let first = firstCutSite, first.enzyme == tapped.enzyme && first.position == tapped.position {
            firstCutSite = nil
            // Promote second to first if it exists
            if let second = secondCutSite {
                firstCutSite = second
                secondCutSite = nil
            }
            postConstructNotificationIfNeeded()
            return
        }
        if let second = secondCutSite, second.enzyme == tapped.enzyme && second.position == tapped.position {
            secondCutSite = nil
            postConstructNotificationIfNeeded()
            return
        }
        
        // Assign to first or second slot
        if firstCutSite == nil {
            firstCutSite = tapped
        } else if secondCutSite == nil {
            secondCutSite = tapped
        } else {
            // Both slots full — rotate: second becomes first, new becomes second
            firstCutSite = secondCutSite
            secondCutSite = tapped
        }
        postConstructNotificationIfNeeded()
    }
    
    /// Posts a notification with current cut-site selections when in construct mode.
    /// Pass `useWrapOverride` when calling from an `.onChange` handler to guarantee
    /// the notification carries the just-updated value (avoids reading possibly
    /// stale `self.useWrapFragment` during the SwiftUI update cycle).
    private func postConstructNotificationIfNeeded(useWrapOverride: Bool? = nil) {
        guard constructFragmentIndex > 0 else { return }
        let ref1 = makeCutSiteRef(firstCutSite)
        let ref2 = makeCutSiteRef(secondCutSite)
        NotificationCenter.default.post(
            name: .constructSiteSelectionChanged,
            object: nil,
            userInfo: [
                "fragmentIndex": constructFragmentIndex,
                "first": ref1 as Any,
                "second": ref2 as Any,
                "useWrap": useWrapOverride ?? useWrapFragment
            ]
        )
    }
    
    /// Converts an internal (enzyme, position) tuple into a CutSiteRef.
    private func makeCutSiteRef(_ site: (enzyme: String, position: Int)?) -> CutSiteRef? {
        guard let s = site, let enzyme = findEnzyme(named: s.enzyme) else { return nil }
        let cutSites = enzyme.findCutSites(in: sequence.sequence.uppercased(), circular: sequence.isCircular)
        // Find the matching cut site to get accurate 5'/3' positions
        var seen: Set<Int> = []
        for cs in cutSites {
            if !seen.contains(cs.position) {
                seen.insert(cs.position)
                if cs.position == s.position {
                    return CutSiteRef(
                        enzyme: s.enzyme,
                        position: s.position,
                        cutPos5: cs.cutPosition5Prime,
                        cutPos3: cs.cutPosition3Prime,
                        overhangType: enzyme.overhangType,
                        siteCount: seen.count  // will be refined below
                    )
                }
            }
        }
        // Fallback — compute manually with wrapping
        let seqLen = sequence.sequence.count
        var cp5 = s.position + enzyme.cutPosition5Prime
        var cp3 = s.position + enzyme.cutPosition3Prime
        if sequence.isCircular && seqLen > 0 {
            cp5 = ((cp5 % seqLen) + seqLen) % seqLen
            cp3 = ((cp3 % seqLen) + seqLen) % seqLen
        }
        return CutSiteRef(
            enzyme: s.enzyme,
            position: s.position,
            cutPos5: cp5,
            cutPos3: cp3,
            overhangType: enzyme.overhangType,
            siteCount: cutSites.count
        )
    }
    
    // Color coding handled by labelBackground() which supports gradients
    
    /// Check if an enzyme produces blunt ends
    private func isBluntCutter(_ enzymeName: String) -> Bool {
        guard let enzyme = findEnzyme(named: enzymeName) else { return false }
        return enzyme.overhangType == .blunt
    }
    
    /// Background for label: gradient for dual-category sites, solid for others
    @ViewBuilder
    func labelBackground(for site: (enzyme: String, position: Int, siteCount: Int)) -> some View {
        let isBlunt  = isBluntCutter(site.enzyme)   // always flag blunt, regardless of filter
        let isDouble = showDoubleSites && site.siteCount == 2
        let isUnique = showUniqueSites && site.siteCount == 1
        
        if siteIsFirstCut(site) {
            Color(red: 0.6, green: 0.9, blue: 0.6) // Green - first cut
        } else if siteIsSecondCut(site) {
            Color(red: 0.95, green: 0.55, blue: 0.55) // Red - second cut
        } else if showParticularSites && selectedParticularEnzymes.contains(site.enzyme) {
            Color(red: 0.68, green: 0.85, blue: 1.0) // Blue - particular
        } else if isBlunt && isDouble {
            // Brown → Green gradient for double + blunt
            LinearGradient(
                colors: [
                    Color(red: 0.82, green: 0.61, blue: 0.35),
                    Color(red: 0.35, green: 0.80, blue: 0.75)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        } else if isBlunt && isUnique {
            // Cream → Green gradient for unique + blunt
            LinearGradient(
                colors: [
                    Color(red: 1.0, green: 0.98, blue: 0.86),
                    Color(red: 0.35, green: 0.80, blue: 0.75)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        } else if isBlunt {
            Color(red: 0.35, green: 0.80, blue: 0.75) // Teal - blunt only
        } else if isDouble {
            Color(red: 0.82, green: 0.61, blue: 0.35) // Brown - double
        } else if isUnique {
            Color(red: 1.0, green: 0.98, blue: 0.86) // Cream - unique
        } else if useMyEnzymesOnly && RestrictionEnzymeDatabase.shared.myEnzymeNames.contains(site.enzyme) {
            Color(red: 0.88, green: 0.78, blue: 0.97) // Lavender — My Enzyme (multi-cutter, not unique/double/blunt)
        } else {
            Color.white
        }
    }
    
    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if sequence.isCircular {
                    circularMapBody
                } else {
                    linearMapBody
                }
            }
            .id(redrawTrigger)
            .onAppear {
                DispatchQueue.main.async { redrawTrigger.toggle() }
            }
            // Fragment selection info bar — overlays the map, no layout jump
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
                    if firstCutSite != nil && !hideFragmentBar {
                        fragmentSelectionBar
                    }
                    if let fid = selectedFeatureID,
                       let feature = sequence.features.first(where: { $0.id == fid }) {
                        featureInfoPanel(feature: feature)
                    } else if let oid = selectedORFID,
                              let orf = visibleORFs.first(where: { $0.id == oid }) {
                        orfInfoPanel(orf: orf)
                    }
                }
            }
        }
        .alert("Open as New Sequence", isPresented: $showOpenFeatureDialog) {
            Button("Open") {
                if let feature = featureToOpen {
                    openFeatureAsSequence(feature)
                } else if let orf = orfToOpen {
                    openORFAsSequence(orf)
                }
                featureToOpen = nil
                orfToOpen = nil
            }
            Button("Cancel", role: .cancel) {
                featureToOpen = nil
                orfToOpen = nil
            }
        } message: {
            if let feature = featureToOpen {
                let bpLen = abs(feature.end - feature.start)
                let isCoding = feature.type == .gene || feature.type == .cds
                let aaStr = isCoding && bpLen >= 3 ? " / \(bpLen / 3) aa" : ""
                Text("Open \"\(feature.name)\" (\(bpLen) bp\(aaStr)) as a new sequence window?")
            } else if let orf = orfToOpen {
                Text("Open \"\(orf.label)\" (\(orf.size) bp / \(orf.size / 3) aa) as a new sequence window?")
            }
        }
    }
    
    // MARK: - Feature / ORF Info Panel
    
    /// Info panel shown at the bottom of the map when a feature is selected
    private func featureInfoPanel(feature: Feature) -> some View {
        let bpLen = abs(feature.end - feature.start)
        let isCoding = feature.type == .gene || feature.type == .cds
        
        return HStack(spacing: 16) {
            Circle().fill(feature.color.color).frame(width: 10, height: 10)
            Text(feature.name).fontWeight(.semibold)
            Divider().frame(height: 14)
            Text(feature.type.displayName).foregroundColor(.secondary)
            Divider().frame(height: 14)
            Text("\(feature.start + 1)..\(feature.end)")
            Divider().frame(height: 14)
            Text("\(bpLen) bp")
            if isCoding && bpLen >= 3 {
                Text("(\(bpLen / 3) aa)").foregroundColor(.orange)
            }
            Divider().frame(height: 14)
            Text(feature.strand == .forward ? "Forward →" : "Reverse ←")
            Spacer()
            Button(action: { selectedFeatureID = nil }) {
                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .overlay(Rectangle().frame(height: 1).foregroundColor(Color(NSColor.separatorColor)), alignment: .top)
    }
    
    /// Info panel shown at the bottom of the map when an ORF is selected
    private func orfInfoPanel(orf: DNASequence.ORFResult) -> some View {
        HStack(spacing: 16) {
            Circle().fill(orfColor(for: orf.strand)).frame(width: 10, height: 10)
            Text(orf.label).fontWeight(.semibold)
            Divider().frame(height: 14)
            Text("\(orf.position)..\(orf.position + orf.size - 1)")
            Divider().frame(height: 14)
            Text("\(orf.size) bp")
            Text("(\(orf.size / 3) aa)").foregroundColor(.orange)
            Divider().frame(height: 14)
            Text("Strand: \(orf.strand)")
            Spacer()
            Button(action: { selectedORFID = nil }) {
                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .overlay(Rectangle().frame(height: 1).foregroundColor(Color(NSColor.separatorColor)), alignment: .top)
    }
    
    // MARK: - Fragment Selection Bar
    
    /// O(1) enzyme lookup using the pre-built dictionary.
    /// Falls back to linear search on first appear before the dict is ready.
    private func findEnzyme(named name: String) -> RestrictionEnzyme? {
        enzymeByName[name] ?? RestrictionEnzymeDatabase.shared.enzymes.first { $0.name == name }
    }
    
    /// Compute actual 5' and 3' cut positions for a selected site (wrapped for circular)
    private func cutPositions(for site: (enzyme: String, position: Int)) -> (cut5: Int, cut3: Int)? {
        guard let enzyme = findEnzyme(named: site.enzyme) else { return nil }
        let seqLen = sequence.sequence.count
        var cut5 = site.position + enzyme.cutPosition5Prime
        var cut3 = site.position + enzyme.cutPosition3Prime
        if sequence.isCircular && seqLen > 0 {
            cut5 = ((cut5 % seqLen) + seqLen) % seqLen
            cut3 = ((cut3 % seqLen) + seqLen) % seqLen
        }
        return (cut5: cut5, cut3: cut3)
    }
    
    /// Get the overhang sequence at a cut site (handles origin-spanning sites on circular sequences)
    private func overhangInfo(for site: (enzyme: String, position: Int)) -> (sequence: String, type: String)? {
        guard let enzyme = findEnzyme(named: site.enzyme) else { return nil }
        let seq = sequence.sequence.uppercased()
        let seqLen = seq.count
        
        if enzyme.overhangType == .blunt {
            return (sequence: "", type: "blunt")
        }
        
        // Use raw (unwrapped) cut positions to preserve overhang direction
        let rawCut5 = site.position + enzyme.cutPosition5Prime
        let rawCut3 = site.position + enzyme.cutPosition3Prime
        let overhangStart = min(rawCut5, rawCut3)
        let overhangEnd = max(rawCut5, rawCut3)
        
        let overhang = extractCircularSubstring(from: seq, start: overhangStart, end: overhangEnd, seqLen: seqLen)
        
        if enzyme.overhangType == .sticky5Prime {
            return (sequence: overhang, type: "5'")
        } else {
            return (sequence: overhang, type: "3'")
        }
    }
    
    /// Extract a substring that may wrap around the origin of a circular sequence.
    /// start and end are raw positions (may exceed seqLen); wrapping is handled internally.
    private func extractCircularSubstring(from seq: String, start: Int, end: Int, seqLen: Int) -> String {
        guard seqLen > 0, end > start else { return "" }
        
        // Normalize start into range 0..<seqLen
        let s = ((start % seqLen) + seqLen) % seqLen
        let length = end - start
        
        if s + length <= seqLen {
            // No wrapping needed
            let startIdx = seq.index(seq.startIndex, offsetBy: s)
            let endIdx = seq.index(seq.startIndex, offsetBy: s + length)
            return String(seq[startIdx..<endIdx])
        } else if sequence.isCircular {
            // Wraps around origin
            let tail = String(seq.suffix(seqLen - s))
            let headLen = length - (seqLen - s)
            let head = String(seq.prefix(min(headLen, seqLen)))
            return tail + head
        } else {
            // Linear — clamp to end
            let startIdx = seq.index(seq.startIndex, offsetBy: s)
            return String(seq[startIdx...])
        }
    }
    
    private var fragmentSelectionBar: some View {
        let seqLen = sequence.sequence.count
        
        return HStack(spacing: 12) {
            // Green site info
            if let first = firstCutSite {
                HStack(spacing: 4) {
                    Circle().fill(Color.green).frame(width: 10, height: 10)
                    Text("\(first.enzyme) (\(first.position))")
                        .font(.system(size: labelFontSize, weight: .semibold))
                    if let info = overhangInfo(for: first) {
                        if info.type == "blunt" {
                            Text("blunt").font(.system(size: labelFontSize)).foregroundColor(.secondary)
                        } else {
                            Text("\(info.type) …\(info.sequence)")
                                .font(.system(size: labelFontSize, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .contextHelp("gmap.fragmentFirstSite")
            }
            
            // Fragment size and picker
            if let first = firstCutSite, let second = secondCutSite {
                let enzyme1 = findEnzyme(named: first.enzyme)
                let enzyme2 = findEnzyme(named: second.enzyme)
                let rawCut1 = first.position + (enzyme1?.cutPosition5Prime ?? 0)
                let rawCut2 = second.position + (enzyme2?.cutPosition5Prime ?? 0)
                let cut1 = sequence.isCircular && seqLen > 0 ? ((rawCut1 % seqLen) + seqLen) % seqLen : rawCut1
                let cut2 = sequence.isCircular && seqLen > 0 ? ((rawCut2 % seqLen) + seqLen) % seqLen : rawCut2
                let pos1 = min(cut1, cut2)
                let pos2 = max(cut1, cut2)
                let directFragment = pos2 - pos1
                let wrapFragment = seqLen - directFragment
                
                Image(systemName: "arrow.left.and.right")
                    .foregroundColor(.secondary)
                
                if sequence.isCircular {
                    Picker("", selection: $useWrapFragment) {
                        Text("Fragment A: \(directFragment) bp").tag(false)
                        Text("Fragment B: \(wrapFragment) bp").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 340)
                    .contextHelp("gmap.fragmentPicker")
                    .onChange(of: useWrapFragment) { newValue in
                        postConstructNotificationIfNeeded(useWrapOverride: newValue)
                    }
                } else {
                    Text("Fragment: \(directFragment) bp")
                        .font(.system(size: labelFontSize))
                        .contextHelp("gmap.fragmentPicker")
                }
            } else {
                Text("Click a second enzyme site to define fragment")
                    .font(.system(size: labelFontSize))
                    .foregroundColor(.secondary)
            }
            
            // Red site info
            if let second = secondCutSite {
                HStack(spacing: 4) {
                    if let info = overhangInfo(for: second) {
                        if info.type == "blunt" {
                            Text("blunt").font(.system(size: labelFontSize)).foregroundColor(.secondary)
                        } else {
                            Text("\(info.sequence)… \(info.type)")
                                .font(.system(size: labelFontSize, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    Circle().fill(Color.red).frame(width: 10, height: 10)
                    Text("\(second.enzyme) (\(second.position))")
                        .font(.system(size: labelFontSize, weight: .semibold))
                }
                .contextHelp("gmap.fragmentSecondSite")
            }
            
            Spacer()
            
            // Copy fragment button (hidden in construct mode)
            if firstCutSite != nil && secondCutSite != nil && constructFragmentIndex == 0 {
                Button("Copy Fragment") {
                    copyFragmentToClipboard()
                }
                .controlSize(.small)
                .contextHelp("gmap.copyFragment")
                
                Button("New Sequence from Fragment") {
                    createSequenceFromFragment()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .contextHelp("gmap.newSequenceFromFragment")
            }
            
            // Clear button
            Button("Clear") {
                firstCutSite = nil
                secondCutSite = nil
                useWrapFragment = false
                postConstructNotificationIfNeeded()
            }
            .controlSize(.small)
            .contextHelp("gmap.clearFragment")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    private func copyFragmentToClipboard() {
        guard let fragment = extractFragment() else {
            #if DEBUG
            print("❌ Fragment extraction failed")
            #endif
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fragment, forType: .string)
        #if DEBUG
        print("✅ Copied \(fragment.count) characters to clipboard")
        #endif
    }
    
    private func extractFragment() -> String? {
        guard let first = firstCutSite, let second = secondCutSite else { return nil }
        
        let seq = sequence.sequence.uppercased()
        let seqLen = seq.count
        guard seqLen > 0 else { return nil }
        
        // Look up enzymes to get actual cut positions
        let enzyme1 = findEnzyme(named: first.enzyme)
        let enzyme2 = findEnzyme(named: second.enzyme)
        
        // Calculate actual 5' strand cut positions, wrapped for circular
        var cut1 = first.position + (enzyme1?.cutPosition5Prime ?? 0)
        var cut2 = second.position + (enzyme2?.cutPosition5Prime ?? 0)
        if sequence.isCircular {
            cut1 = ((cut1 % seqLen) + seqLen) % seqLen
            cut2 = ((cut2 % seqLen) + seqLen) % seqLen
        }
        
        let pos1 = min(cut1, cut2)
        let pos2 = max(cut1, cut2)
        
        if useWrapFragment && sequence.isCircular {
            // Wrap-around fragment: from pos2 to pos1 going through the origin
            return extractCircularSubstring(from: seq, start: pos2, end: pos1 + seqLen, seqLen: seqLen)
        } else {
            // Direct fragment: from pos1 to pos2
            return extractCircularSubstring(from: seq, start: pos1, end: pos2, seqLen: seqLen)
        }
    }
    
    /// Compute the overhang sequence for an enzyme at a given recognition site position
    private func computeOverhang(enzyme: RestrictionEnzyme, sitePosition: Int) -> String {
        let seq = sequence.sequence.uppercased()
        let seqLen = seq.count
        if enzyme.overhangType == .blunt { return "" }
        
        // Use raw (unwrapped) positions to preserve overhang direction
        let rawCut5 = sitePosition + enzyme.cutPosition5Prime
        let rawCut3 = sitePosition + enzyme.cutPosition3Prime
        let lo = min(rawCut5, rawCut3)
        let hi = max(rawCut5, rawCut3)
        return extractCircularSubstring(from: seq, start: lo, end: hi, seqLen: seqLen)
    }
    
    private func createSequenceFromFragment() {
        guard let first = firstCutSite, let second = secondCutSite,
              let fragment = extractFragment() else { return }
        
        let name = "\(first.enzyme)-\(second.enzyme) fragment\(useWrapFragment ? " (wrap)" : "") from \(sequence.name)"
        let seqLen = sequence.sequence.count
        
        // Determine which site is 5' end and which is 3' end
        let enzyme1 = findEnzyme(named: first.enzyme)
        let enzyme2 = findEnzyme(named: second.enzyme)
        var cut5_1 = first.position + (enzyme1?.cutPosition5Prime ?? 0)
        var cut5_2 = second.position + (enzyme2?.cutPosition5Prime ?? 0)
        if sequence.isCircular && seqLen > 0 {
            cut5_1 = ((cut5_1 % seqLen) + seqLen) % seqLen
            cut5_2 = ((cut5_2 % seqLen) + seqLen) % seqLen
        }
        
        let fivePrimeSite: (enzyme: String, position: Int)
        let threePrimeSite: (enzyme: String, position: Int)
        let fivePrimeEnzyme: RestrictionEnzyme?
        let threePrimeEnzyme: RestrictionEnzyme?
        
        if useWrapFragment && sequence.isCircular {
            // Wrap fragment: the "higher" cut position is the 5' end
            if cut5_1 <= cut5_2 {
                fivePrimeSite = second; threePrimeSite = first
                fivePrimeEnzyme = enzyme2; threePrimeEnzyme = enzyme1
            } else {
                fivePrimeSite = first; threePrimeSite = second
                fivePrimeEnzyme = enzyme1; threePrimeEnzyme = enzyme2
            }
        } else {
            // Direct fragment: the "lower" cut position is the 5' end
            if cut5_1 <= cut5_2 {
                fivePrimeSite = first; threePrimeSite = second
                fivePrimeEnzyme = enzyme1; threePrimeEnzyme = enzyme2
            } else {
                fivePrimeSite = second; threePrimeSite = first
                fivePrimeEnzyme = enzyme2; threePrimeEnzyme = enzyme1
            }
        }
        
        let overhang5 = fivePrimeEnzyme != nil ? computeOverhang(enzyme: fivePrimeEnzyme!, sitePosition: fivePrimeSite.position) : ""
        let overhang3 = threePrimeEnzyme != nil ? computeOverhang(enzyme: threePrimeEnzyme!, sitePosition: threePrimeSite.position) : ""
        
        // Post notification so SequenceManager can create the new sequence
        NotificationCenter.default.post(
            name: .createSequenceFromFragment,
            object: nil,
            userInfo: [
                "name": name,
                "sequence": fragment,
                "isCircular": false,
                "cohesive5Prime": overhang5,
                "cohesive3Prime": overhang3
            ]
        )
    }
    
    // MARK: - Linear Map Body
    private var linearMapBody: some View {
        GeometryReader { outerGeometry in
            let enzymeSites = cachedFilteredSites
            let featureSites: [(enzyme: String, position: Int, siteCount: Int)] = showFeatures ? visibleFeatures.map { feature in
                let seqLen = sequence.sequence.count
                let midpoint: Int = {
                    if feature.end >= feature.start {
                        return (feature.start + feature.end) / 2
                    } else {
                        // Feature wraps around the origin of a circular sequence
                        let length = (seqLen - feature.start + 1) + feature.end
                        return ((feature.start - 1 + length / 2) % seqLen) + 1
                    }
                }()
                return (enzyme: feature.name, position: max(1, midpoint), siteCount: -1)
            } : []
            let sites = enzymeSites + featureSites
            let sequenceLength = sequence.sequence.count
            
            // Layout constants — adapt to available window size
            let lineLeftMargin: CGFloat = 80
            let lineRightMargin: CGFloat = 80
            let availableWidth = outerGeometry.size.width
            let availableHeight = outerGeometry.size.height
            // At scale 1.0, fit within the window; only expand when zoomed
            let baseWidth: CGFloat = max(availableWidth, 700)
            let canvasWidth: CGFloat = baseWidth * max(1.0, mapScale)
            let baseCanvasHeight: CGFloat = max(availableHeight, 700) * max(1.0, mapScale)
            let linearTopPadding: CGFloat = 60
            let canvasHeight: CGFloat = baseCanvasHeight + linearTopPadding * 2
            let lineLength = canvasWidth - lineLeftMargin - lineRightMargin
            let lineY: CGFloat = (baseCanvasHeight / 2) + linearTopPadding  // shifted down for toolbar clearance
            
            ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                ZStack {
                    Color(NSColor.textBackgroundColor)
                        .onTapGesture { }   // absorb background clicks so ScrollView doesn't pan
                    
                    // ── Main sequence line ──
                    Path { path in
                        path.move(to: CGPoint(x: lineLeftMargin, y: lineY))
                        path.addLine(to: CGPoint(x: lineLeftMargin + lineLength, y: lineY))
                    }
                    .stroke(Color.blue, lineWidth: 6)
                    
                    // End caps — blunt (blue bar) or sticky (red staggered lines)
                    // 5' end (left side)
                    let has5Overhang = !sequence.cohesive5Prime.isEmpty
                    let overhang5Len: CGFloat = has5Overhang ? min(CGFloat(sequence.cohesive5Prime.count) * 3 + 6, 20) : 0
                    
                    if has5Overhang {
                        // Sticky 5' end — staggered red lines showing overhang
                        // Top strand (sense) extends left
                        Path { path in
                            // Top strand cap
                            path.move(to: CGPoint(x: lineLeftMargin - overhang5Len, y: lineY - 3))
                            path.addLine(to: CGPoint(x: lineLeftMargin - overhang5Len, y: lineY - 10))
                            // Bottom strand cap
                            path.move(to: CGPoint(x: lineLeftMargin, y: lineY + 3))
                            path.addLine(to: CGPoint(x: lineLeftMargin, y: lineY + 10))
                        }
                        .stroke(Color.red, lineWidth: 2.5)
                        // Top strand overhang line
                        Path { path in
                            path.move(to: CGPoint(x: lineLeftMargin - overhang5Len, y: lineY - 3))
                            path.addLine(to: CGPoint(x: lineLeftMargin, y: lineY - 3))
                        }
                        .stroke(Color.red, lineWidth: 2.5)
                        // Overhang label
                        Text(sequence.cohesive5Prime)
                            .font(.system(size: max(labelFontSize - 3, 8), design: .monospaced))
                            .foregroundColor(.red)
                            .position(x: lineLeftMargin - overhang5Len / 2, y: lineY - 18)
                    } else {
                        // Blunt 5' end
                        Path { path in
                            path.move(to: CGPoint(x: lineLeftMargin, y: lineY - 12))
                            path.addLine(to: CGPoint(x: lineLeftMargin, y: lineY + 12))
                        }
                        .stroke(Color.blue, lineWidth: 3)
                    }
                    
                    // 3' end (right side)
                    let has3Overhang = !sequence.cohesive3Prime.isEmpty
                    let overhang3Len: CGFloat = has3Overhang ? min(CGFloat(sequence.cohesive3Prime.count) * 3 + 6, 20) : 0
                    
                    if has3Overhang {
                        // Sticky 3' end — staggered red lines showing overhang
                        let rightX = lineLeftMargin + lineLength
                        // Top strand cap
                        Path { path in
                            path.move(to: CGPoint(x: rightX, y: lineY - 3))
                            path.addLine(to: CGPoint(x: rightX, y: lineY - 10))
                            // Bottom strand extends right
                            path.move(to: CGPoint(x: rightX + overhang3Len, y: lineY + 3))
                            path.addLine(to: CGPoint(x: rightX + overhang3Len, y: lineY + 10))
                        }
                        .stroke(Color.red, lineWidth: 2.5)
                        // Bottom strand overhang line
                        Path { path in
                            path.move(to: CGPoint(x: rightX, y: lineY + 3))
                            path.addLine(to: CGPoint(x: rightX + overhang3Len, y: lineY + 3))
                        }
                        .stroke(Color.red, lineWidth: 2.5)
                        // Overhang label
                        Text(sequence.cohesive3Prime)
                            .font(.system(size: max(labelFontSize - 3, 8), design: .monospaced))
                            .foregroundColor(.red)
                            .position(x: rightX + overhang3Len / 2, y: lineY + 18)
                    } else {
                        // Blunt 3' end
                        Path { path in
                            path.move(to: CGPoint(x: lineLeftMargin + lineLength, y: lineY - 12))
                            path.addLine(to: CGPoint(x: lineLeftMargin + lineLength, y: lineY + 12))
                        }
                        .stroke(Color.blue, lineWidth: 3)
                    }
                    
                    // ── Sequence name and size (draggable) ──
                    // NOTE: .position() must come AFTER the gesture so that the
                    // hit-test area stays on the visible text, not the full ZStack.
                    VStack(spacing: 2) {
                        Text(sequence.name)
                            .font(.system(size: labelFontSize + 1, weight: .bold))
                        Text("\(sequenceLength) bp")
                            .font(.system(size: labelFontSize))
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { value in
                                if titleDragStart == nil { titleDragStart = titleOffset }
                                let start = titleDragStart ?? .zero
                                titleOffset = CGSize(
                                    width: start.width + value.translation.width,
                                    height: start.height + value.translation.height
                                )
                            }
                            .onEnded { _ in
                                titleDragStart = nil
                            }
                    )
                    .position(
                        x: lineLeftMargin + lineLength / 2 + titleOffset.width,
                        y: lineY + 120 + titleOffset.height
                    )
                    
                    // Invisible anchor for auto-centering (left edge, vertical center)
                    Color.clear
                        .frame(width: 1, height: 1)
                        .id("linearMapCenter")
                        .position(x: lineLeftMargin, y: lineY)
                    
                    // ── Features as colored segments ──
                    if showFeatures {
                        ForEach(visibleFeatures) { feature in
                            linearFeatureSegment(feature: feature, lineX: lineLeftMargin, lineLength: lineLength, lineY: lineY, sequenceLength: sequenceLength)
                        }
                    }
                    
                    // ── ORFs as directional arrows ──
                    if showORFs {
                        ForEach(visibleORFs) { orf in
                            linearORFSegment(orf: orf, lineX: lineLeftMargin, lineLength: lineLength, lineY: lineY, sequenceLength: sequenceLength)
                        }
                    }
                    
                    // ── Restriction sites ──
                    linearRestrictionSitesView(sites: sites, lineX: lineLeftMargin, lineLength: lineLength, lineY: lineY, sequenceLength: sequenceLength)
                }
                .frame(width: canvasWidth, height: canvasHeight)
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(.none) { proxy.scrollTo("linearMapCenter", anchor: .leading) }
                }
            }
            .onChange(of: sequence.id) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(.none) { proxy.scrollTo("linearMapCenter", anchor: .leading) }
                }
            }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: resetLabelTrigger) { _ in
            labelOffsets.removeAll()
            titleOffset = .zero
        }
        .onChange(of: mapScale) { _ in
            labelOffsets.removeAll()
            titleOffset = .zero
        }
        .onAppear {
            refreshEnzymeDict()
            refreshSiteCache()
        }
        .onChange(of: sequence.sequence)         { _ in refreshSiteCache() }
        .onChange(of: useMyEnzymesOnly)          { newValue in cachedAllEnzymeSites = []; refreshSiteCache(useMyEnzymes: newValue) }
        .onChange(of: showUniqueSites)           { newValue in refreshMethylationCache(sitesOverride: filteredSites(uniqueOverride:            newValue)) }
        .onChange(of: showDoubleSites)           { newValue in refreshMethylationCache(sitesOverride: filteredSites(doubleOverride:            newValue)) }
        .onChange(of: showBluntSites)            { newValue in refreshMethylationCache(sitesOverride: filteredSites(bluntOverride:             newValue)) }
        .onChange(of: showParticularSites)       { newValue in refreshMethylationCache(sitesOverride: filteredSites(particularOverride:        newValue)) }
        .onChange(of: selectedParticularEnzymes) { newValue in refreshMethylationCache(sitesOverride: filteredSites(particularEnzymesOverride: newValue)) }
        .onChange(of: methylationDam)            { newValue in refreshMethylationCache(damOverride: newValue) }
        .onChange(of: methylationDcm)            { newValue in refreshMethylationCache(dcmOverride: newValue) }
        .onChange(of: methylationCpG)            { newValue in refreshMethylationCache(cpgOverride: newValue) }
    }
    
    // MARK: - Circular Map Body
    private var circularMapBody: some View {
        let sequenceLength = sequence.sequence.count

        // Compute everything directly from cachedFilteredSites (a synchronous computed
        // property — always current, no async lag, no stale state.
        let enzymeSites = cachedFilteredSites
        let featureSites: [(enzyme: String, position: Int, siteCount: Int)] = showFeatures ? visibleFeatures.map { feature in
            let midpoint: Int = {
                if feature.end >= feature.start {
                    return (feature.start + feature.end) / 2
                } else {
                    let length = (sequenceLength - feature.start + 1) + feature.end
                    return ((feature.start - 1 + length / 2) % sequenceLength) + 1
                }
            }()
            return (enzyme: feature.name, position: max(1, midpoint), siteCount: -1)
        } : []
        let allSites = enzymeSites + featureSites

        let leftCount = allSites.filter { site in
            let angle = angleForPosition(site.position, sequenceLength: sequenceLength)
            let norm = normalizeAngle(angle)
            return !(norm >= -90 && norm <= 90)
        }.count
        let rightCount = allSites.count - leftCount
        let maxSideCount = max(leftCount, rightCount, 1)

        let verticalSpacing: CGFloat = maxSideCount > 16 ? 20 : 22
        let columnHeight = CGFloat(maxSideCount) * verticalSpacing
        let circleNeeds: CGFloat = 500
        let columnNeeds = columnHeight + 180

        let canvasHeight = max(circleNeeds, columnNeeds, 700) * max(1.0, mapScale)
        let hasColumnsOnBothSides = leftCount >= 5 && rightCount >= 5
        let hasManyLabels = leftCount >= 5 || rightCount >= 5
        let baseWidth: CGFloat = hasColumnsOnBothSides ? 1250 : (hasManyLabels ? 1100 : 1000)
        let canvasWidth: CGFloat = baseWidth * max(1.0, mapScale)
        let topPadding: CGFloat = 60
        let centerY = (canvasHeight / 2) + topPadding
        let totalCanvasHeight = canvasHeight + topPadding * 2
        let centerX: CGFloat = hasColumnsOnBothSides ? canvasWidth * 0.5 :
            (leftCount > rightCount ? canvasWidth * 0.55 : canvasWidth * 0.42)

        // Compute placements inline — fast (just geometry, no enzyme scanning).
        // Single source of truth: same sites used for sizing are used for placement.
        let center = CGPoint(x: centerX, y: centerY)
        let radius: CGFloat = 140 * mapScale
        let placements = calculateLabelPlacements(
            sites: allSites, center: center, radius: radius, sequenceLength: sequenceLength
        )

        return ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
            GeometryReader { geometry in
                let center = CGPoint(x: centerX, y: centerY)
                let radius: CGFloat = 140 * mapScale
                
                ZStack {
                    Color(NSColor.textBackgroundColor)
                        .onTapGesture { }   // absorb background clicks so ScrollView doesn't pan
                    
                    Circle()
                        .stroke(Color.blue, lineWidth: 8)
                        .frame(width: radius * 2, height: radius * 2)
                        .position(center)
                    
                    VStack(spacing: 2) {
                        Text(sequence.name)
                            .font(.system(size: labelFontSize + 1, weight: .bold))
                        Text("\(sequence.sequence.count) bp")
                            .font(.system(size: labelFontSize))
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { value in
                                if titleDragStart == nil { titleDragStart = titleOffset }
                                let start = titleDragStart ?? .zero
                                titleOffset = CGSize(
                                    width: start.width + value.translation.width,
                                    height: start.height + value.translation.height
                                )
                            }
                            .onEnded { _ in
                                titleDragStart = nil
                            }
                    )
                    .position(
                        x: center.x + titleOffset.width,
                        y: center.y + radius + 80 + titleOffset.height
                    )
                    
                    // Invisible anchor for auto-centering
                    Color.clear
                        .frame(width: 1, height: 1)
                        .id("circularMapCenter")
                        .position(center)
                    
                    // Tick lines and connector lines from inline placements.
                    ForEach(Array(placements.enumerated()), id: \.offset) { _, placement in
                        let key = labelKey(for: placement.site)
                        let offset = labelOffsets[key] ?? .zero
                        restrictionSiteLines(placement: placement, center: center, radius: radius, offset: offset)
                    }
                    
                    // Feature arcs ON the circle
                    if showFeatures {
                        ForEach(visibleFeatures) { feature in
                            featureArcOnly(feature: feature, center: center, radius: radius)
                        }
                    }
                    
                    // ORF arcs INSIDE the circle
                    if showORFs {
                        ForEach(visibleORFs) { orf in
                            orfArc(orf: orf, center: center, radius: radius - 20)
                        }
                    }
                    
                    // All labels (enzymes + features) with unified placement
                    ForEach(Array(placements.enumerated()), id: \.offset) { _, placement in
                        let key = labelKey(for: placement.site)
                        let offset = labelOffsets[key] ?? .zero
                        draggableLabel(placement: placement, offset: offset, key: key)
                    }
                }
                .frame(width: canvasWidth, height: totalCanvasHeight)
            }
            .frame(width: canvasWidth, height: totalCanvasHeight)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                withAnimation(.none) { proxy.scrollTo("circularMapCenter", anchor: .center) }
            }
        }
        .onChange(of: sequence.id) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                withAnimation(.none) { proxy.scrollTo("circularMapCenter", anchor: .center) }
            }
        }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            if showFeatureCopied {
                Text("Feature sequence copied to clipboard")
                    .font(.system(size: labelFontSize, weight: .medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)
                    .shadow(radius: 4)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.3), value: showFeatureCopied)
            }
        }
        .onChange(of: resetLabelTrigger) { _ in
            labelOffsets.removeAll()
            featureLabelOffsets.removeAll()
            titleOffset = .zero
        }
        .onChange(of: mapScale) { _ in
            labelOffsets.removeAll()
            featureLabelOffsets.removeAll()
            titleOffset = .zero
        }
        .onChange(of: labelFontSize) { _ in
            labelOffsets.removeAll()
            featureLabelOffsets.removeAll()
            titleOffset = .zero
        }
        .gesture(
            MagnificationGesture()
                .onChanged { magnification in
                    let newScale = scaleAtGestureStart * magnification
                    mapScale = min(3.0, max(0.5, newScale))
                }
                .onEnded { _ in
                    scaleAtGestureStart = mapScale
                }
        )
        .overlay {
            if !isReady {
                ProgressView("Loading map…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(NSColor.windowBackgroundColor))
            }
        }
        .onAppear {
            scaleAtGestureStart = mapScale
            refreshEnzymeDict()      // build O(1) lookup dict synchronously (fast)
            refreshSiteCache()       // kicks off: sites → methylation → placements
        }
        // Sequence or enzyme list changed: full rescan needed
        .onChange(of: sequence.sequence)          { _ in refreshSiteCache(); firstCutSite = nil; secondCutSite = nil }
        .onChange(of: useMyEnzymesOnly)           { newValue in cachedAllEnzymeSites = []; refreshSiteCache(useMyEnzymes: newValue) }
        // Filter flag changes: cachedFilteredSites (computed) updates automatically.
        // Pass newValue explicitly to filteredSites() to avoid stale closure capture.
        .onChange(of: showUniqueSites)            { newValue in refreshMethylationCache(sitesOverride: filteredSites(uniqueOverride:            newValue)) }
        .onChange(of: showDoubleSites)            { newValue in refreshMethylationCache(sitesOverride: filteredSites(doubleOverride:            newValue)) }
        .onChange(of: showBluntSites)             { newValue in refreshMethylationCache(sitesOverride: filteredSites(bluntOverride:             newValue)) }
        .onChange(of: showParticularSites)        { newValue in refreshMethylationCache(sitesOverride: filteredSites(particularOverride:        newValue)) }
        .onChange(of: selectedParticularEnzymes)  { newValue in refreshMethylationCache(sitesOverride: filteredSites(particularEnzymesOverride: newValue)) }
        .onChange(of: methylationDam)             { newValue in refreshMethylationCache(damOverride: newValue) }
        .onChange(of: methylationDcm)             { newValue in refreshMethylationCache(dcmOverride: newValue) }
        .onChange(of: methylationCpG)             { newValue in refreshMethylationCache(cpgOverride: newValue) }
        // mapScale/font/feature changes: circularMapBody recomputes inline automatically.
        // No explicit refresh needed — SwiftUI re-evaluates the body when these change.
    }
    
    struct LabelPlacement {
        let site: (enzyme: String, position: Int, siteCount: Int)
        let sitePoint: CGPoint
        let labelPosition: CGPoint
        let labelSize: CGSize
        let lineAttachmentPoint: CGPoint
        let angle: Double
        let isTopHalf: Bool  // Changed from quadrant to simpler top/bottom
        let layer: Int
    }
    

    
    // Helper: group sites into clusters by angular proximity
    private func clusterSites(
        sites: [(enzyme: String, position: Int, siteCount: Int)],
        sequenceLength: Int
    ) -> [[(enzyme: String, position: Int, siteCount: Int)]] {
        // Sort by angle
        let sortedSites = sites.sorted { a, b in
            angleForPosition(a.position, sequenceLength: sequenceLength) <
            angleForPosition(b.position, sequenceLength: sequenceLength)
        }
        
        var clusters: [[(enzyme: String, position: Int, siteCount: Int)]] = []
        var currentCluster: [(enzyme: String, position: Int, siteCount: Int)] = []
        
        for site in sortedSites {
            if currentCluster.isEmpty {
                currentCluster.append(site)
            } else {
                let prevSite = currentCluster.last!
                let prevAngle = angleForPosition(prevSite.position, sequenceLength: sequenceLength)
                let currentAngle = angleForPosition(site.position, sequenceLength: sequenceLength)
                var angularDist = abs(currentAngle - prevAngle)
                if angularDist > 180 { angularDist = 360 - angularDist }
                
                if angularDist <= 12 {
                    currentCluster.append(site)
                } else {
                    clusters.append(currentCluster)
                    currentCluster = [site]
                }
            }
        }
        if !currentCluster.isEmpty {
            clusters.append(currentCluster)
        }
        
        // Check wrap-around merge (first and last cluster)
        if clusters.count >= 2 {
            let lastAngle = angleForPosition(clusters.last!.last!.position, sequenceLength: sequenceLength)
            let firstAngle = angleForPosition(clusters.first!.first!.position, sequenceLength: sequenceLength)
            var angularDist = abs(firstAngle - lastAngle)
            if angularDist > 180 { angularDist = 360 - angularDist }
            if angularDist <= 12 {
                let merged = clusters.last! + clusters.first!
                clusters[0] = merged
                clusters.removeLast()
            }
        }
        
        return clusters
    }
    
    // Side-aware layout: column for busy sides, radial for sparse sides
    private func calculateLabelPlacements(
        sites: [(enzyme: String, position: Int, siteCount: Int)],
        center: CGPoint,
        radius: CGFloat,
        sequenceLength: Int
    ) -> [LabelPlacement] {
        var placements: [LabelPlacement] = []
        var placedRects: [CGRect] = []
        
        // Helper: is an angle on the right side of the circle?
        func isRight(_ angle: Double) -> Bool {
            let norm = normalizeAngle(angle)
            return norm >= -90 && norm <= 90
        }
        
        // ── Split ALL sites by side ──
        var leftSites: [(enzyme: String, position: Int, siteCount: Int)] = []
        var rightSites: [(enzyme: String, position: Int, siteCount: Int)] = []
        
        for site in sites {
            let angle = angleForPosition(site.position, sequenceLength: sequenceLength)
            if isRight(angle) {
                rightSites.append(site)
            } else {
                leftSites.append(site)
            }
        }
        
        // Threshold: if a side has this many or more sites, use a column for ALL of them
        let columnThreshold = 5
        
        // ── Process each side ──
        for (sideSites, sideIsRight) in [(leftSites, false), (rightSites, true)] {
            if sideSites.isEmpty { continue }
            
            if sideSites.count >= columnThreshold {
                // COLUMN MODE: all sites on this side in one sorted column
                let columnPlacements = placeAsColumn(
                    sites: sideSites, center: center, radius: radius,
                    sequenceLength: sequenceLength, isRightSide: sideIsRight,
                    obstacles: placedRects
                )
                for p in columnPlacements {
                    let rect = CGRect(origin: p.labelPosition, size: p.labelSize)
                    placedRects.append(rect)
                    placements.append(p)
                }
            } else {
                // RADIAL MODE: short connectors for each site
                let radialPlacements = placeAsRadial(
                    sites: sideSites, center: center, radius: radius,
                    sequenceLength: sequenceLength, existingRects: &placedRects
                )
                placements.append(contentsOf: radialPlacements)
            }
        }
        
        return placements
    }
    
    // Place all sites in a single vertical column on one side
    // Labels track their tick Y positions, with dense clusters spread symmetrically
    // outward from their center (not just downward) to minimize connector crossings
    private func placeAsColumn(
        sites: [(enzyme: String, position: Int, siteCount: Int)],
        center: CGPoint,
        radius: CGFloat,
        sequenceLength: Int,
        isRightSide: Bool,
        obstacles: [CGRect] = []
    ) -> [LabelPlacement] {
        var placements: [LabelPlacement] = []
        
        // Sort by tick Y position so label order matches tick order → no connector crossing
        let sorted = sites.sorted { a, b in
            let angleA = angleForPosition(a.position, sequenceLength: sequenceLength) * .pi / 180.0
            let angleB = angleForPosition(b.position, sequenceLength: sequenceLength) * .pi / 180.0
            return sin(angleA) < sin(angleB)
        }
        
        let labelHeight: CGFloat = 18
        let minSpacing: CGFloat = sorted.count > 16 ? 20 : 22
        let baseColumnGap: CGFloat = 40
        
        // Adjust column gap to clear any obstacles (feature labels) on this side
        var columnGap = baseColumnGap
        for obs in obstacles {
            if isRightSide && obs.maxX > center.x {
                let neededGap = obs.maxX - (center.x + radius) + 8
                columnGap = max(columnGap, neededGap)
            } else if !isRightSide && obs.minX < center.x {
                let neededGap = (center.x - radius) - obs.minX + 8
                columnGap = max(columnGap, neededGap)
            }
        }
        
        // Compute ideal Y for each label = tick Y
        let idealYs: [CGFloat] = sorted.map { site in
            let a = angleForPosition(site.position, sequenceLength: sequenceLength) * .pi / 180.0
            return center.y + radius * CGFloat(sin(a))
        }
        
        // Bidirectional spread from median:
        // Place the middle label at its ideal Y, then spread outward in both directions
        let n = sorted.count
        var labelYs = idealYs
        let mid = n / 2
        
        // Middle label stays at its ideal position
        labelYs[mid] = idealYs[mid]
        
        // Spread upward from middle
        for i in stride(from: mid - 1, through: 0, by: -1) {
            let maxY = labelYs[i + 1] - minSpacing
            labelYs[i] = min(idealYs[i], maxY)
        }
        
        // Spread downward from middle
        for i in (mid + 1)..<n {
            let minY = labelYs[i - 1] + minSpacing
            labelYs[i] = max(idealYs[i], minY)
        }
        
        // Column X position
        let columnEdgeX: CGFloat
        if isRightSide {
            columnEdgeX = center.x + radius + columnGap
        } else {
            columnEdgeX = center.x - radius - columnGap
        }
        
        for (i, site) in sorted.enumerated() {
            let angle = angleForPosition(site.position, sequenceLength: sequenceLength)
            let angleRad = CGFloat(angle * .pi / 180.0)
            
            let labelText = "\(site.enzyme) (\(site.position))"
            let labelWidth: CGFloat = CGFloat(labelText.count) * 8.5 + 16
            let labelSize = CGSize(width: labelWidth, height: labelHeight)
            
            let tickEndPoint = CGPoint(
                x: center.x + (radius + 8) * cos(angleRad),
                y: center.y + (radius + 8) * sin(angleRad)
            )
            
            let labelCenterY = labelYs[i]
            let labelY = labelCenterY - labelHeight / 2
            
            let labelX: CGFloat
            let lineAttachX: CGFloat
            if isRightSide {
                labelX = columnEdgeX
                lineAttachX = columnEdgeX
            } else {
                labelX = columnEdgeX - labelWidth
                lineAttachX = columnEdgeX
            }
            
            let lineAttachPt = CGPoint(x: lineAttachX, y: labelCenterY)
            
            placements.append(LabelPlacement(
                site: site,
                sitePoint: tickEndPoint,
                labelPosition: CGPoint(x: labelX, y: labelY),
                labelSize: labelSize,
                lineAttachmentPoint: lineAttachPt,
                angle: angle,
                isTopHalf: isRightSide,
                layer: 0
            ))
        }
        
        return placements
    }
    
    // Place sites with short radial connectors (for sides with few sites)
    private func placeAsRadial(
        sites: [(enzyme: String, position: Int, siteCount: Int)],
        center: CGPoint,
        radius: CGFloat,
        sequenceLength: Int,
        existingRects: inout [CGRect]
    ) -> [LabelPlacement] {
        var placements: [LabelPlacement] = []
        
        // Sort by angle for consistent ordering
        let sorted = sites.sorted { a, b in
            angleForPosition(a.position, sequenceLength: sequenceLength) <
            angleForPosition(b.position, sequenceLength: sequenceLength)
        }
        
        for site in sorted {
            let angle = angleForPosition(site.position, sequenceLength: sequenceLength)
            let angleRad = CGFloat(angle * .pi / 180.0)
            let cosA = CGFloat(cos(angleRad))
            let sinA = CGFloat(sin(angleRad))
            
            let labelText = "\(site.enzyme) (\(site.position))"
            let labelWidth: CGFloat = CGFloat(labelText.count) * 8.5 + 16
            let labelHeight: CGFloat = 18
            let labelSize = CGSize(width: labelWidth, height: labelHeight)
            
            let tickEndPoint = CGPoint(
                x: center.x + (radius + 8) * cosA,
                y: center.y + (radius + 8) * sinA
            )
            
            let gap: CGFloat = 20
            
            // Position label: always place on the outward side with a straight connector
            func labelRectForDist(_ dist: CGFloat) -> CGRect {
                let ax = center.x + (radius + 8 + dist) * cosA
                let ay = center.y + (radius + 8 + dist) * sinA
                if abs(cosA) >= abs(sinA) {
                    let lx: CGFloat = cosA >= 0 ? ax : ax - labelWidth
                    return CGRect(x: lx, y: ay - labelHeight / 2, width: labelWidth, height: labelHeight)
                } else {
                    let lx: CGFloat = ax - labelWidth / 2
                    return CGRect(x: lx, y: sinA >= 0 ? ay : ay - labelHeight, width: labelWidth, height: labelHeight)
                }
            }
            
            func attachmentPoint(for rect: CGRect) -> CGPoint {
                if abs(cosA) > abs(sinA) {
                    let ax = cosA >= 0 ? rect.minX : rect.maxX
                    return CGPoint(x: ax, y: rect.midY)
                } else {
                    let ay = sinA >= 0 ? rect.minY : rect.maxY
                    return CGPoint(x: rect.midX, y: ay)
                }
            }
            
            func hasCollision(_ rect: CGRect) -> Bool {
                let hitsLabel = existingRects.contains { existing in
                    rect.insetBy(dx: -6, dy: -3).intersects(existing)
                }
                let corners = [
                    CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                    CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)
                ]
                let hitsCircle = corners.contains { pt in
                    let dx = pt.x - center.x; let dy = pt.y - center.y
                    return sqrt(dx * dx + dy * dy) < (radius + 6)
                }
                // Also check if connector line would cross any existing rect
                let attach = attachmentPoint(for: rect)
                let connectorCrossesRect = existingRects.contains { existing in
                    lineIntersectsRect(a: tickEndPoint, b: attach, rect: existing.insetBy(dx: -2, dy: -2))
                }
                return hitsLabel || hitsCircle || connectorCrossesRect
            }
            
            // Try increasing distances along the radial direction
            var labelRect = labelRectForDist(gap)
            if hasCollision(labelRect) {
                for attempt in 1...10 {
                    labelRect = labelRectForDist(gap + CGFloat(attempt) * 18)
                    if !hasCollision(labelRect) { break }
                }
            }
            
            existingRects.append(labelRect)
            let attach = attachmentPoint(for: labelRect)
            
            placements.append(LabelPlacement(
                site: site,
                sitePoint: tickEndPoint,
                labelPosition: CGPoint(x: labelRect.minX, y: labelRect.minY),
                labelSize: labelSize,
                lineAttachmentPoint: attach,
                angle: angle,
                isTopHalf: normalizeAngle(angle) >= -90 && normalizeAngle(angle) <= 90,
                layer: 0
            ))
        }
        
        return placements
    }
    
    private func normalizeAngle(_ angle: Double) -> Double {
        var normalized = angle
        while normalized > 180 { normalized -= 360 }
        while normalized < -180 { normalized += 360 }
        return normalized
    }
    
    private func restrictionSiteLines(placement: LabelPlacement, center: CGPoint, radius: CGFloat, offset: CGSize) -> some View {
        let tickEndPoint = pointOnCircle(center: center, radius: radius + 8, angle: placement.angle)
        let offsetAttach = CGPoint(
            x: placement.lineAttachmentPoint.x + offset.width,
            y: placement.lineAttachmentPoint.y + offset.height
        )
        let isFeature = placement.site.siteCount == -1
        
        return ZStack {
            // Line from END OF TICK to label (with offset applied)
            Path { path in
                path.move(to: tickEndPoint)
                path.addLine(to: offsetAttach)
            }
            .stroke(isFeature ? Color.gray : Color.black, lineWidth: 1)
            
            // Tick mark on circle - skip for features (they have arcs already)
            if !isFeature {
                Path { path in
                    let tickStart = pointOnCircle(center: center, radius: radius, angle: placement.angle)
                    let tickEnd = pointOnCircle(center: center, radius: radius + 8, angle: placement.angle)
                    path.move(to: tickStart)
                    path.addLine(to: tickEnd)
                }
                .stroke(Color.black, lineWidth: 2)
            }
        }
    }
    
    private func draggableLabel(placement: LabelPlacement, offset: CGSize, key: String) -> some View {
        let isFeatureLabel = placement.site.siteCount == -1
        let labelText = isFeatureLabel ? placement.site.enzyme : "\(placement.site.enzyme) (\(placement.site.position))"
        let isDragging = activeDragKey == key
        let isSelected = !isFeatureLabel && (siteIsFirstCut(placement.site) || siteIsSecondCut(placement.site))
        let isBlocked   = !isFeatureLabel && isMethylationBlocked(enzyme: placement.site.enzyme, position: placement.site.position)
        let isRequired  = !isFeatureLabel && isMethylationRequired(enzyme: placement.site.enzyme, position: placement.site.position)
        // Text: red + strikethrough = blocked; blue = required for cutting; primary otherwise.
        let textColor: Color = isFeatureLabel ? .black : (isBlocked ? .red : (isRequired ? .blue : .primary))
        let borderColor: Color =
            isSelected ? (siteIsFirstCut(placement.site) ? .green : .red) :
            isDragging ? .blue :
            isBlocked  ? .red :
            isRequired ? .blue : .black
        let borderWidth: CGFloat =
            isSelected ? 2 :
            isDragging ? 1.5 :
            (isBlocked || isRequired) ? 1.5 : 1

        let labelView = Text(labelText)
            .font(.system(size: labelFontSize, weight: .regular))
            .foregroundColor(textColor)
            .strikethrough(isBlocked, color: .red)
            .textSelection(.disabled)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Group {
                    if isFeatureLabel {
                        featureLabelBackground(name: placement.site.enzyme)
                    } else {
                        labelBackground(for: placement.site)
                    }
                }
            )
            .overlay(
                Group {
                    if !isFeatureLabel {
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(borderColor, lineWidth: borderWidth)
                    }
                }
            )

        return labelView
            .contentShape(Rectangle())
            .position(
                x: placement.labelPosition.x + placement.labelSize.width / 2 + offset.width,
                y: placement.labelPosition.y + placement.labelSize.height / 2 + offset.height
            )
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        activeDragKey = key
                        if labelOffsets[key + "_dragStart"] == nil {
                            labelOffsets[key + "_dragStart"] = labelOffsets[key] ?? .zero
                        }
                        let start = labelOffsets[key + "_dragStart"] ?? .zero
                        labelOffsets[key] = CGSize(
                            width: start.width + value.translation.width,
                            height: start.height + value.translation.height
                        )
                    }
                    .onEnded { _ in
                        activeDragKey = nil
                        labelOffsets.removeValue(forKey: key + "_dragStart")
                    }
            )
            .onTapGesture {
                if !isFeatureLabel {
                    handleSiteTap(placement.site)
                }
            }
    }
    
    @ViewBuilder
    private func featureLabelBackground(name: String) -> some View {
        if let feature = sequence.features.first(where: { $0.name == name }) {
            RoundedRectangle(cornerRadius: 3)
                .fill(feature.color.color.opacity(0.85))
        } else {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.gray.opacity(0.5))
        }
    }
    
    // MARK: - Linear Map Helpers
    
    private func xForPosition(_ position: Int, lineX: CGFloat, lineLength: CGFloat, sequenceLength: Int) -> CGFloat {
        lineX + CGFloat(position) / CGFloat(sequenceLength) * lineLength
    }
    
    private func markerInterval(for sequenceLength: Int) -> Int {
        if sequenceLength > 20000 { return 5000 }
        else if sequenceLength > 10000 { return 2000 }
        else if sequenceLength > 5000 { return 1000 }
        else if sequenceLength > 2000 { return 500 }
        else { return 100 }
    }
    
    @ViewBuilder
    private func linearPositionMarkers(lineX: CGFloat, lineLength: CGFloat, lineY: CGFloat, sequenceLength: Int) -> some View {
        let interval = markerInterval(for: sequenceLength)
        let markerCount = sequenceLength / interval
        
        ForEach(0...markerCount, id: \.self) { i in
            let pos = i * interval
            if pos <= sequenceLength {
                let x = xForPosition(pos, lineX: lineX, lineLength: lineLength, sequenceLength: sequenceLength)
                Path { path in
                    path.move(to: CGPoint(x: x, y: lineY + 3))
                    path.addLine(to: CGPoint(x: x, y: lineY + 10))
                }
                .stroke(Color.gray.opacity(0.5), lineWidth: 1)
                
                Text("\(pos)")
                    .font(.system(size: labelFontSize - 1))
                    .foregroundColor(.gray)
                    .position(x: x, y: lineY + 20)
            }
        }
        
        Text("1")
            .font(.system(size: labelFontSize, weight: .semibold))
            .foregroundColor(.gray)
            .position(x: lineX, y: lineY + 20)
        
        Text("\(sequenceLength)")
            .font(.system(size: labelFontSize, weight: .semibold))
            .foregroundColor(.gray)
            .position(x: lineX + lineLength, y: lineY + 20)
    }
    
    private func linearFeatureSegment(feature: Feature, lineX: CGFloat, lineLength: CGFloat, lineY: CGFloat, sequenceLength: Int) -> some View {
        let startX = xForPosition(feature.start, lineX: lineX, lineLength: lineLength, sequenceLength: sequenceLength)
        let endX = xForPosition(feature.end, lineX: lineX, lineLength: lineLength, sequenceLength: sequenceLength)
        let featureColor = feature.color.color
        let halfHeight: CGFloat = 5
        let arrowSize: CGFloat = 6
        
        return ZStack {
            if feature.showArrow {
                // Draw directional arrow shape
                Path { path in
                    let y = lineY
                    if feature.strand == .forward {
                        // Arrow pointing right →
                        let arrowStart = max(startX, endX - arrowSize)
                        path.move(to: CGPoint(x: startX, y: y - halfHeight))
                        path.addLine(to: CGPoint(x: arrowStart, y: y - halfHeight))
                        path.addLine(to: CGPoint(x: arrowStart, y: y - halfHeight - 3))
                        path.addLine(to: CGPoint(x: endX, y: y))
                        path.addLine(to: CGPoint(x: arrowStart, y: y + halfHeight + 3))
                        path.addLine(to: CGPoint(x: arrowStart, y: y + halfHeight))
                        path.addLine(to: CGPoint(x: startX, y: y + halfHeight))
                        path.closeSubpath()
                    } else {
                        // Arrow pointing left ←
                        let arrowEnd = min(endX, startX + arrowSize)
                        path.move(to: CGPoint(x: endX, y: y - halfHeight))
                        path.addLine(to: CGPoint(x: arrowEnd, y: y - halfHeight))
                        path.addLine(to: CGPoint(x: arrowEnd, y: y - halfHeight - 3))
                        path.addLine(to: CGPoint(x: startX, y: y))
                        path.addLine(to: CGPoint(x: arrowEnd, y: y + halfHeight + 3))
                        path.addLine(to: CGPoint(x: arrowEnd, y: y + halfHeight))
                        path.addLine(to: CGPoint(x: endX, y: y + halfHeight))
                        path.closeSubpath()
                    }
                }
                .fill(featureColor.opacity(0.8))
                .overlay(
                    Path { path in
                        let y = lineY
                        if feature.strand == .forward {
                            let arrowStart = max(startX, endX - arrowSize)
                            path.move(to: CGPoint(x: startX, y: y - halfHeight))
                            path.addLine(to: CGPoint(x: arrowStart, y: y - halfHeight))
                            path.addLine(to: CGPoint(x: arrowStart, y: y - halfHeight - 3))
                            path.addLine(to: CGPoint(x: endX, y: y))
                            path.addLine(to: CGPoint(x: arrowStart, y: y + halfHeight + 3))
                            path.addLine(to: CGPoint(x: arrowStart, y: y + halfHeight))
                            path.addLine(to: CGPoint(x: startX, y: y + halfHeight))
                            path.closeSubpath()
                        } else {
                            let arrowEnd = min(endX, startX + arrowSize)
                            path.move(to: CGPoint(x: endX, y: y - halfHeight))
                            path.addLine(to: CGPoint(x: arrowEnd, y: y - halfHeight))
                            path.addLine(to: CGPoint(x: arrowEnd, y: y - halfHeight - 3))
                            path.addLine(to: CGPoint(x: startX, y: y))
                            path.addLine(to: CGPoint(x: arrowEnd, y: y + halfHeight + 3))
                            path.addLine(to: CGPoint(x: arrowEnd, y: y + halfHeight))
                            path.addLine(to: CGPoint(x: endX, y: y + halfHeight))
                            path.closeSubpath()
                        }
                    }
                    .stroke(featureColor, lineWidth: 1)
                )
            } else {
                // Simple line (no arrow)
                Path { path in
                    path.move(to: CGPoint(x: startX, y: lineY))
                    path.addLine(to: CGPoint(x: endX, y: lineY))
                }
                .stroke(featureColor, lineWidth: 10)
            }
        }
    }
    
    // MARK: - ORF Rendering (Linear)
    
    private func linearORFSegment(orf: DNASequence.ORFResult, lineX: CGFloat, lineLength: CGFloat, lineY: CGFloat, sequenceLength: Int) -> some View {
        let startPos = max(0, orf.position - 1)
        let endPos = min(sequenceLength, orf.position - 1 + orf.size)
        let startX = xForPosition(startPos, lineX: lineX, lineLength: lineLength, sequenceLength: sequenceLength)
        let endX = xForPosition(endPos, lineX: lineX, lineLength: lineLength, sequenceLength: sequenceLength)
        let yOffset: CGFloat = orf.isForward ? -18 : 18
        let arrowSize: CGFloat = 6
        let halfHeight: CGFloat = 5
        let color = orfColor(for: orf.strand)
        let isSelected = selectedORFID == orf.id
        
        return ZStack {
            Path { path in
                let y = lineY + yOffset
                if orf.isForward {
                    let arrowStart = max(startX, endX - arrowSize)
                    path.move(to: CGPoint(x: startX, y: y - halfHeight))
                    path.addLine(to: CGPoint(x: arrowStart, y: y - halfHeight))
                    path.addLine(to: CGPoint(x: arrowStart, y: y - halfHeight - 3))
                    path.addLine(to: CGPoint(x: endX, y: y))
                    path.addLine(to: CGPoint(x: arrowStart, y: y + halfHeight + 3))
                    path.addLine(to: CGPoint(x: arrowStart, y: y + halfHeight))
                    path.addLine(to: CGPoint(x: startX, y: y + halfHeight))
                    path.closeSubpath()
                } else {
                    let arrowEnd = min(endX, startX + arrowSize)
                    path.move(to: CGPoint(x: endX, y: y - halfHeight))
                    path.addLine(to: CGPoint(x: arrowEnd, y: y - halfHeight))
                    path.addLine(to: CGPoint(x: arrowEnd, y: y - halfHeight - 3))
                    path.addLine(to: CGPoint(x: startX, y: y))
                    path.addLine(to: CGPoint(x: arrowEnd, y: y + halfHeight + 3))
                    path.addLine(to: CGPoint(x: arrowEnd, y: y + halfHeight))
                    path.addLine(to: CGPoint(x: endX, y: y + halfHeight))
                    path.closeSubpath()
                }
            }
            .fill(color.opacity(isSelected ? 1.0 : 0.7))
            .overlay(
                Path { path in
                    let y = lineY + yOffset
                    if orf.isForward {
                        let arrowStart = max(startX, endX - arrowSize)
                        path.move(to: CGPoint(x: startX, y: y - halfHeight))
                        path.addLine(to: CGPoint(x: arrowStart, y: y - halfHeight))
                        path.addLine(to: CGPoint(x: arrowStart, y: y - halfHeight - 3))
                        path.addLine(to: CGPoint(x: endX, y: y))
                        path.addLine(to: CGPoint(x: arrowStart, y: y + halfHeight + 3))
                        path.addLine(to: CGPoint(x: arrowStart, y: y + halfHeight))
                        path.addLine(to: CGPoint(x: startX, y: y + halfHeight))
                        path.closeSubpath()
                    } else {
                        let arrowEnd = min(endX, startX + arrowSize)
                        path.move(to: CGPoint(x: endX, y: y - halfHeight))
                        path.addLine(to: CGPoint(x: arrowEnd, y: y - halfHeight))
                        path.addLine(to: CGPoint(x: arrowEnd, y: y - halfHeight - 3))
                        path.addLine(to: CGPoint(x: startX, y: y))
                        path.addLine(to: CGPoint(x: arrowEnd, y: y + halfHeight + 3))
                        path.addLine(to: CGPoint(x: arrowEnd, y: y + halfHeight))
                        path.addLine(to: CGPoint(x: endX, y: y + halfHeight))
                        path.closeSubpath()
                    }
                }
                .stroke(isSelected ? Color.blue : color, lineWidth: isSelected ? 2.5 : 1)
            )
            
            // Label
            Text("\(orf.label) (\(orf.size / 3) aa)")
                .font(.system(size: labelFontSize, weight: isSelected ? .bold : .medium))
                .foregroundColor(isSelected ? .blue : .primary)
                .position(x: (startX + endX) / 2, y: lineY + yOffset + (orf.isForward ? -14 : 14))
        }
        .onTapGesture(count: 2) {
            handleORFDoubleClick(orf)
        }
        .onTapGesture {
            selectedORFID = selectedORFID == orf.id ? nil : orf.id
            ContextHelpManager.shared.show(forKey: "gmap.orfArc")
        }
    }
    
    // MARK: - ORF Rendering (Circular)
    
    private func orfArc(orf: DNASequence.ORFResult, center: CGPoint, radius: CGFloat) -> some View {
        let seqLen = sequence.sequence.count
        let startPos = max(0, orf.position - 1)
        let endPos = min(seqLen, orf.position - 1 + orf.size)
        let startAngle = angleForPosition(startPos, sequenceLength: seqLen)
        let endAngle = angleForPosition(endPos, sequenceLength: seqLen)
        let arcThickness: CGFloat = 10
        let arrowLength: CGFloat = 10
        let arrowOvershoot: CGFloat = 4
        let innerR = radius - arcThickness / 2
        let outerR = radius + arcThickness / 2
        let color = orfColor(for: orf.strand)
        let isSelected = selectedORFID == orf.id
        
        var totalSpan = endAngle - startAngle
        if totalSpan < 0 { totalSpan += 360 }
        let hasArrow = totalSpan > 10
        
        let bodyStart: Double
        let bodyEnd: Double
        let arrowTipAngle: Double
        let arrowBaseAngle: Double
        
        if orf.isForward {
            arrowTipAngle = endAngle
            arrowBaseAngle = hasArrow ? endAngle - arrowLength : startAngle
            bodyStart = startAngle
            bodyEnd = hasArrow ? endAngle - arrowLength : endAngle
        } else {
            arrowTipAngle = startAngle
            arrowBaseAngle = hasArrow ? startAngle + arrowLength : endAngle
            bodyStart = hasArrow ? startAngle + arrowLength : startAngle
            bodyEnd = endAngle
        }
        
        return ZStack {
            // Body
            Path { path in
                path.addArc(center: center, radius: outerR,
                           startAngle: .degrees(bodyStart), endAngle: .degrees(bodyEnd), clockwise: false)
                path.addArc(center: center, radius: innerR,
                           startAngle: .degrees(bodyEnd), endAngle: .degrees(bodyStart), clockwise: true)
                path.closeSubpath()
            }
            .fill(color.opacity(isSelected ? 1.0 : 0.7))
            
            // Arrowhead
            if hasArrow {
                Path { path in
                    let tipPoint = pointOnCircle(center: center, radius: radius, angle: arrowTipAngle)
                    let outerBase = pointOnCircle(center: center, radius: outerR + arrowOvershoot, angle: arrowBaseAngle)
                    let innerBase = pointOnCircle(center: center, radius: innerR - arrowOvershoot, angle: arrowBaseAngle)
                    path.move(to: tipPoint)
                    path.addLine(to: outerBase)
                    path.addLine(to: innerBase)
                    path.closeSubpath()
                }
                .fill(color.opacity(isSelected ? 1.0 : 0.7))
            }
            
            // Outline
            Path { path in
                if hasArrow && orf.isForward {
                    path.addArc(center: center, radius: outerR,
                               startAngle: .degrees(bodyStart), endAngle: .degrees(bodyEnd), clockwise: false)
                    let outerBase = pointOnCircle(center: center, radius: outerR + arrowOvershoot, angle: arrowBaseAngle)
                    let tipPoint = pointOnCircle(center: center, radius: radius, angle: arrowTipAngle)
                    let innerBase = pointOnCircle(center: center, radius: innerR - arrowOvershoot, angle: arrowBaseAngle)
                    path.addLine(to: outerBase)
                    path.addLine(to: tipPoint)
                    path.addLine(to: innerBase)
                    path.addArc(center: center, radius: innerR,
                               startAngle: .degrees(bodyEnd), endAngle: .degrees(bodyStart), clockwise: true)
                    path.closeSubpath()
                } else if hasArrow && !orf.isForward {
                    let tipPoint = pointOnCircle(center: center, radius: radius, angle: arrowTipAngle)
                    let outerBase = pointOnCircle(center: center, radius: outerR + arrowOvershoot, angle: arrowBaseAngle)
                    let innerBase = pointOnCircle(center: center, radius: innerR - arrowOvershoot, angle: arrowBaseAngle)
                    path.move(to: tipPoint)
                    path.addLine(to: outerBase)
                    path.addArc(center: center, radius: outerR,
                               startAngle: .degrees(bodyStart), endAngle: .degrees(bodyEnd), clockwise: false)
                    path.addArc(center: center, radius: innerR,
                               startAngle: .degrees(bodyEnd), endAngle: .degrees(bodyStart), clockwise: true)
                    path.addLine(to: innerBase)
                    path.closeSubpath()
                } else {
                    path.addArc(center: center, radius: outerR,
                               startAngle: .degrees(bodyStart), endAngle: .degrees(bodyEnd), clockwise: false)
                    path.addArc(center: center, radius: innerR,
                               startAngle: .degrees(bodyEnd), endAngle: .degrees(bodyStart), clockwise: true)
                    path.closeSubpath()
                }
            }
            .stroke(isSelected ? Color.blue : color, lineWidth: isSelected ? 2.5 : 1)
            
            // Label at midpoint
            orfLabel(orf: orf, center: center, radius: radius)
        }
        .contentShape(
            Path { path in
                path.addArc(center: center, radius: outerR + 4,
                           startAngle: .degrees(startAngle), endAngle: .degrees(endAngle), clockwise: false)
                path.addArc(center: center, radius: innerR - 4,
                           startAngle: .degrees(endAngle), endAngle: .degrees(startAngle), clockwise: true)
                path.closeSubpath()
            }
        )
        .onTapGesture(count: 2) {
            handleORFDoubleClick(orf)
        }
        .onTapGesture {
            selectedORFID = selectedORFID == orf.id ? nil : orf.id
            ContextHelpManager.shared.show(forKey: "gmap.orfArc")
        }
    }
    
    private func orfLabel(orf: DNASequence.ORFResult, center: CGPoint, radius: CGFloat) -> some View {
        let seqLen = sequence.sequence.count
        let startPos = max(0, orf.position - 1)
        let endPos = min(seqLen, orf.position - 1 + orf.size)
        let midPos = (startPos + endPos) / 2
        let midAngle = angleForPosition(midPos, sequenceLength: seqLen)
        let labelRadius = radius - 24
        let pt = pointOnCircle(center: center, radius: labelRadius, angle: midAngle)
        
        return Text("\(orf.label) (\(orf.size / 3) aa)")
            .font(.system(size: labelFontSize, weight: .medium))
            .foregroundColor(.primary)
            .position(x: pt.x, y: pt.y)
    }
    
    private func orfColor(for strand: String) -> Color {
        switch strand {
        case "+1": return .orange
        case "+2": return .cyan
        case "+3": return .mint
        case "-1": return .pink
        case "-2": return .purple
        case "-3": return .indigo
        default: return .orange
        }
    }
    
    @ViewBuilder
    private func linearRestrictionSitesView(
        sites: [(enzyme: String, position: Int, siteCount: Int)],
        lineX: CGFloat,
        lineLength: CGFloat,
        lineY: CGFloat,
        sequenceLength: Int
    ) -> some View {
        let placements = calculateLinearLabelPlacements(
            sites: sites, lineX: lineX, lineLength: lineLength,
            lineY: lineY, sequenceLength: sequenceLength
        )
        
        // Draw connector lines
        ForEach(Array(placements.enumerated()), id: \.offset) { _, placement in
            let key = labelKey(for: placement.site)
            let offset = labelOffsets[key] ?? .zero
            let isFeature = placement.site.siteCount == -1
            
            // Tick mark on the line - skip for features (they have colored segments)
            if !isFeature {
                Path { path in
                    path.move(to: CGPoint(x: placement.sitePoint.x, y: lineY - 6))
                    path.addLine(to: CGPoint(x: placement.sitePoint.x, y: lineY + 6))
                }
                .stroke(Color.black, lineWidth: 2)
            }
            
            // Connector from tick to label
            Path { path in
                let tickEnd = placement.sitePoint
                let labelAttach = CGPoint(
                    x: placement.lineAttachmentPoint.x + offset.width,
                    y: placement.lineAttachmentPoint.y + offset.height
                )
                path.move(to: tickEnd)
                path.addLine(to: labelAttach)
            }
            .stroke(isFeature ? Color.gray : Color.black, lineWidth: 1)
        }
        
        // Draw labels (draggable)
        ForEach(Array(placements.enumerated()), id: \.offset) { _, placement in
            let key = labelKey(for: placement.site)
            let offset = labelOffsets[key] ?? .zero
            draggableLabel(placement: placement, offset: offset, key: key)
        }
    }
    
    private func calculateLinearLabelPlacements(
        sites: [(enzyme: String, position: Int, siteCount: Int)],
        lineX: CGFloat,
        lineLength: CGFloat,
        lineY: CGFloat,
        sequenceLength: Int
    ) -> [LabelPlacement] {
        var placements: [LabelPlacement] = []
        var placedRects: [CGRect] = []
        
        // Reserve space for the sequence name/bp title below the line center
        let titleWidth: CGFloat = CGFloat(sequence.name.count) * 9 + 60
        let titleHeight: CGFloat = 44
        let titleCenterX = lineX + lineLength / 2
        let titleCenterY = lineY + 120
        let titleRect = CGRect(
            x: titleCenterX - titleWidth / 2,
            y: titleCenterY - titleHeight / 2,
            width: titleWidth,
            height: titleHeight
        )
        placedRects.append(titleRect)
        
        // Reserve space for end caps (sticky or blunt) so labels don't overlap them
        let endCapPadding: CGFloat = 30
        let leftEndRect = CGRect(
            x: lineX - endCapPadding, y: lineY - 24,
            width: endCapPadding + 10, height: 48
        )
        placedRects.append(leftEndRect)
        let rightEndRect = CGRect(
            x: lineX + lineLength - 10, y: lineY - 24,
            width: endCapPadding + 10, height: 48
        )
        placedRects.append(rightEndRect)
        
        // Reserve feature colored segments on the line so labels don't overlap them.
        // Each feature is drawn as a 10pt thick segment; reserve a rect with padding
        // that includes the area right above and below the segment for readability.
        if showFeatures {
            for feature in visibleFeatures {
                let startX = xForPosition(feature.start, lineX: lineX, lineLength: lineLength, sequenceLength: sequenceLength)
                let endX = xForPosition(feature.end, lineX: lineX, lineLength: lineLength, sequenceLength: sequenceLength)
                let minX = min(startX, endX)
                let maxX = max(startX, endX)
                // Feature label text on/near the segment — reserve space above and below
                let featureRect = CGRect(
                    x: minX - 4, y: lineY - 14,
                    width: maxX - minX + 8, height: 28
                )
                placedRects.append(featureRect)
            }
        }
        
        // Two-pass placement: features and double cutters get prime positions,
        // then single cutters placed by position with their own alternating pattern.
        let prioritySites = sites.filter { $0.siteCount == -1 || $0.siteCount >= 2 }
            .sorted { $0.position < $1.position }
        let singleSites = sites.filter { $0.siteCount != -1 && $0.siteCount < 2 }
            .sorted { $0.position < $1.position }
        let orderedSites = prioritySites + singleSites
        
        // Track separate alternation index for each pass
        var priorityIndex = 0
        var singleIndex = 0
        
        for site in orderedSites {
            let isPriority = site.siteCount == -1 || site.siteCount >= 2
            let altIndex = isPriority ? priorityIndex : singleIndex
            if isPriority { priorityIndex += 1 } else { singleIndex += 1 }
            
            let siteX = xForPosition(site.position, lineX: lineX, lineLength: lineLength, sequenceLength: sequenceLength)
            let sitePoint = CGPoint(x: siteX, y: lineY)
            
            let labelText = "\(site.enzyme) (\(site.position))"
            let labelWidth: CGFloat = CGFloat(labelText.count) * 8.5 + 16
            let labelHeight: CGFloat = 18
            let labelSize = CGSize(width: labelWidth, height: labelHeight)
            
            let aboveGap: CGFloat = 26
            let belowGap: CGFloat = 26
            
            // Alternate above/below within each group independently
            let preferAbove = (altIndex % 2 == 0)
            
            func makeRect(above: Bool, extra: CGFloat = 0) -> CGRect {
                if above {
                    let y = lineY - aboveGap - labelHeight - extra
                    return CGRect(x: siteX - labelWidth / 2, y: y, width: labelWidth, height: labelHeight)
                } else {
                    let y = lineY + belowGap + extra
                    return CGRect(x: siteX - labelWidth / 2, y: y, width: labelWidth, height: labelHeight)
                }
            }
            
            func hasCollision(_ rect: CGRect) -> Bool {
                placedRects.contains { $0.insetBy(dx: -6, dy: -3).intersects(rect) }
            }
            
            func makeAttach(_ rect: CGRect, above: Bool) -> CGPoint {
                above ? CGPoint(x: siteX, y: rect.maxY) : CGPoint(x: siteX, y: rect.minY)
            }
            
            // Step 1: try preferred side at base distance
            var goAbove = preferAbove
            var labelRect = makeRect(above: goAbove)
            
            // Step 2: if preferred side collides at base, try opposite side at base
            if hasCollision(labelRect) {
                let flippedRect = makeRect(above: !goAbove)
                if !hasCollision(flippedRect) {
                    goAbove = !goAbove
                    labelRect = flippedRect
                }
            }
            
            // Step 3: push further out, trying both sides at each distance
            if hasCollision(labelRect) {
                var resolved = false
                for attempt in 1...10 {
                    let extraDist = CGFloat(attempt) * 22
                    // Try preferred side first
                    let rectPref = makeRect(above: goAbove, extra: extraDist)
                    if !hasCollision(rectPref) {
                        labelRect = rectPref
                        resolved = true
                        break
                    }
                    // Try opposite side
                    let rectFlip = makeRect(above: !goAbove, extra: extraDist)
                    if !hasCollision(rectFlip) {
                        goAbove = !goAbove
                        labelRect = rectFlip
                        resolved = true
                        break
                    }
                }
                if !resolved {
                    // Last resort: push far out on preferred side
                    labelRect = makeRect(above: goAbove, extra: 200)
                }
            }
            
            let attachPt = makeAttach(labelRect, above: goAbove)
            
            placedRects.append(labelRect)
            
            let placement = LabelPlacement(
                site: site,
                sitePoint: sitePoint,
                labelPosition: CGPoint(x: labelRect.minX, y: labelRect.minY),
                labelSize: labelSize,
                lineAttachmentPoint: attachPt,
                angle: goAbove ? -90 : 90,
                isTopHalf: goAbove,
                layer: 0
            )
            placements.append(placement)
        }
        
        return placements
    }
    
    // MARK: - Circular Map Helpers
    
    /// Feature arc only — colored segment on the circle with arrowhead, no label
    private func featureArcOnly(feature: Feature, center: CGPoint, radius: CGFloat) -> some View {
        let seqLen = sequence.sequence.count
        let startAngle = angleForPosition(feature.start, sequenceLength: seqLen)
        let endAngle = angleForPosition(feature.end, sequenceLength: seqLen)
        let arcThickness: CGFloat = 14
        let arrowLength: CGFloat = 12
        let arrowOvershoot: CGFloat = 6
        let innerR = radius - arcThickness / 2
        let outerR = radius + arcThickness / 2
        let isSelected = selectedFeatureID == feature.id
        let isForward = feature.strand == .forward
        
        var totalSpan = endAngle - startAngle
        if totalSpan < 0 { totalSpan += 360 }
        let hasArrow = feature.showArrow && totalSpan > 15
        
        let bodyStart: Double
        let bodyEnd: Double
        let arrowTipAngle: Double
        let arrowBaseAngle: Double
        
        if isForward {
            arrowTipAngle = endAngle
            arrowBaseAngle = hasArrow ? endAngle - arrowLength : startAngle
            bodyStart = startAngle
            bodyEnd = hasArrow ? endAngle - arrowLength : endAngle
        } else {
            arrowTipAngle = startAngle
            arrowBaseAngle = hasArrow ? startAngle + arrowLength : endAngle
            bodyStart = hasArrow ? startAngle + arrowLength : startAngle
            bodyEnd = endAngle
        }
        
        let featureColor = feature.color.color
        
        return ZStack {
            Path { path in
                path.addArc(center: center, radius: outerR,
                           startAngle: .degrees(bodyStart), endAngle: .degrees(bodyEnd), clockwise: false)
                path.addArc(center: center, radius: innerR,
                           startAngle: .degrees(bodyEnd), endAngle: .degrees(bodyStart), clockwise: true)
                path.closeSubpath()
            }
            .fill(featureColor)
            
            if hasArrow {
                Path { path in
                    let tipPoint = pointOnCircle(center: center, radius: radius, angle: arrowTipAngle)
                    let outerBase = pointOnCircle(center: center, radius: outerR + arrowOvershoot, angle: arrowBaseAngle)
                    let innerBase = pointOnCircle(center: center, radius: innerR - arrowOvershoot, angle: arrowBaseAngle)
                    path.move(to: tipPoint)
                    path.addLine(to: outerBase)
                    path.addLine(to: innerBase)
                    path.closeSubpath()
                }
                .fill(featureColor)
            }
            
            // Black outline for entire feature shape
            Path { path in
                if hasArrow && isForward {
                    // Forward: body arc then arrow at end
                    path.addArc(center: center, radius: outerR,
                               startAngle: .degrees(bodyStart), endAngle: .degrees(bodyEnd), clockwise: false)
                    let outerBase = pointOnCircle(center: center, radius: outerR + arrowOvershoot, angle: arrowBaseAngle)
                    let tipPoint = pointOnCircle(center: center, radius: radius, angle: arrowTipAngle)
                    let innerBase = pointOnCircle(center: center, radius: innerR - arrowOvershoot, angle: arrowBaseAngle)
                    path.addLine(to: outerBase)
                    path.addLine(to: tipPoint)
                    path.addLine(to: innerBase)
                    path.addArc(center: center, radius: innerR,
                               startAngle: .degrees(bodyEnd), endAngle: .degrees(bodyStart), clockwise: true)
                    path.closeSubpath()
                } else if hasArrow && !isForward {
                    // Reverse: arrow at start, then body arc
                    let tipPoint = pointOnCircle(center: center, radius: radius, angle: arrowTipAngle)
                    let outerBase = pointOnCircle(center: center, radius: outerR + arrowOvershoot, angle: arrowBaseAngle)
                    let innerBase = pointOnCircle(center: center, radius: innerR - arrowOvershoot, angle: arrowBaseAngle)
                    path.move(to: tipPoint)
                    path.addLine(to: outerBase)
                    path.addArc(center: center, radius: outerR,
                               startAngle: .degrees(bodyStart), endAngle: .degrees(bodyEnd), clockwise: false)
                    path.addArc(center: center, radius: innerR,
                               startAngle: .degrees(bodyEnd), endAngle: .degrees(bodyStart), clockwise: true)
                    path.addLine(to: innerBase)
                    path.closeSubpath()
                } else {
                    // No arrow — simple band
                    path.addArc(center: center, radius: outerR,
                               startAngle: .degrees(bodyStart), endAngle: .degrees(bodyEnd), clockwise: false)
                    path.addArc(center: center, radius: innerR,
                               startAngle: .degrees(bodyEnd), endAngle: .degrees(bodyStart), clockwise: true)
                    path.closeSubpath()
                }
            }
            .stroke(Color.black, lineWidth: 0.75)
            
            if isSelected {
                Path { path in
                    path.addArc(center: center, radius: outerR + 2,
                               startAngle: .degrees(startAngle), endAngle: .degrees(endAngle), clockwise: false)
                }
                .stroke(Color.blue, lineWidth: 2)
            }
        }
        .contentShape(
            Path { path in
                path.addArc(center: center, radius: outerR + 6,
                           startAngle: .degrees(startAngle), endAngle: .degrees(endAngle), clockwise: false)
                path.addArc(center: center, radius: innerR - 6,
                           startAngle: .degrees(endAngle), endAngle: .degrees(startAngle), clockwise: true)
                path.closeSubpath()
            }
        )
        .onTapGesture(count: 2) { handleFeatureDoubleClick(feature) }
        .onTapGesture(count: 1) {
            selectedFeatureID = selectedFeatureID == feature.id ? nil : feature.id
            ContextHelpManager.shared.show(forKey: "gmap.featureArc")
        }
    }
    
    /// Handle double-click: offer to open feature as new sequence
    private func handleFeatureDoubleClick(_ feature: Feature) {
        selectedFeatureID = feature.id
        featureToOpen = feature
        orfToOpen = nil
        showOpenFeatureDialog = true
    }
    
    /// Handle double-click on ORF: offer to open as new sequence
    private func handleORFDoubleClick(_ orf: DNASequence.ORFResult) {
        selectedORFID = orf.id
        orfToOpen = orf
        featureToOpen = nil
        showOpenFeatureDialog = true
    }
    
    /// Open a feature as a new sequence via notification
    private func openFeatureAsSequence(_ feature: Feature) {
        let seq = sequence.sequence
        let lo = min(feature.start, feature.end)
        let hi = max(feature.start, feature.end)
        guard lo >= 0 && hi <= seq.count && lo < hi else { return }
        let startIdx = seq.index(seq.startIndex, offsetBy: lo)
        let endIdx = seq.index(seq.startIndex, offsetBy: hi)
        var featureSeq = String(seq[startIdx..<endIdx])
        
        if feature.strand == .reverse {
            featureSeq = reverseComplement(featureSeq)
        }
        
        let name = "\(feature.name) from \(sequence.name)"
        
        NotificationCenter.default.post(
            name: .createSequenceFromFragment,
            object: nil,
            userInfo: [
                "name": name,
                "sequence": featureSeq,
                "isCircular": false,
                "cohesive5Prime": "",
                "cohesive3Prime": ""
            ]
        )
    }
    
    /// Open an ORF as a new sequence via notification
    private func openORFAsSequence(_ orf: DNASequence.ORFResult) {
        let seq = sequence.sequence
        let start0 = max(0, orf.position - 1)
        let end0 = min(seq.count, start0 + orf.size)
        guard start0 < end0 else { return }
        let startIdx = seq.index(seq.startIndex, offsetBy: start0)
        let endIdx = seq.index(seq.startIndex, offsetBy: end0)
        var orfSeq = String(seq[startIdx..<endIdx])
        
        if !orf.isForward {
            orfSeq = reverseComplement(orfSeq)
        }
        
        let name = "\(orf.label) from \(sequence.name)"
        
        NotificationCenter.default.post(
            name: .createSequenceFromFragment,
            object: nil,
            userInfo: [
                "name": name,
                "sequence": orfSeq,
                "isCircular": false,
                "cohesive5Prime": "",
                "cohesive3Prime": ""
            ]
        )
    }
    
    private func reverseComplement(_ seq: String) -> String {
        let complementMap: [Character: Character] = [
            "A": "T", "T": "A", "G": "C", "C": "G",
            "a": "t", "t": "a", "g": "c", "c": "g",
            "N": "N", "n": "n"
        ]
        return String(seq.reversed().map { complementMap[$0] ?? $0 })
    }
    
    // MARK: - Feature Labels (collision-aware)
    
    /// Place all feature labels outside the circle, dodging enzyme label rects
    private func featureLabelsView(features: [Feature], center: CGPoint, radius: CGFloat, enzymeRects: [CGRect], enzymeLines: [(CGPoint, CGPoint)], canvasSize: CGSize) -> some View {
        let seqLen = sequence.sequence.count
        
        let labelData = features.map { feature -> (feature: Feature, startAngle: Double, endAngle: Double) in
            let s = angleForPosition(feature.start, sequenceLength: seqLen)
            let e = angleForPosition(feature.end, sequenceLength: seqLen)
            return (feature, s, e)
        }
        
        let placements = computeFeatureLabelPlacements(labelData: labelData, center: center, radius: radius, enzymeRects: enzymeRects, enzymeLines: enzymeLines, canvasSize: canvasSize)
        
        return ZStack {
            ForEach(Array(placements.enumerated()), id: \.offset) { _, placement in
                let fKey = "feature_\(placement.feature.id)"
                let offset = featureLabelOffsets[fKey] ?? .zero
                featureConnectorView(center: center, radius: radius, connAngle: placement.connAngle, labelRect: placement.rect, offset: offset)
            }
            ForEach(Array(placements.enumerated()), id: \.offset) { _, placement in
                let fKey = "feature_\(placement.feature.id)"
                let offset = featureLabelOffsets[fKey] ?? .zero
                draggableFeatureLabel(feature: placement.feature, labelRect: placement.rect, offset: offset, key: fKey)
            }
        }
    }
    
    private struct FeatureLabelPlacement {
        let feature: Feature
        let connAngle: Double
        let rect: CGRect
    }
    
    /// Try multiple connection angles along the feature arc AND multiple distances.
    /// Pick the (angle, distance) combo that avoids enzyme rects AND enzyme connector lines.
    private func computeFeatureLabelPlacements(
        labelData: [(feature: Feature, startAngle: Double, endAngle: Double)],
        center: CGPoint,
        radius: CGFloat,
        enzymeRects: [CGRect],
        enzymeLines: [(CGPoint, CGPoint)],
        canvasSize: CGSize
    ) -> [FeatureLabelPlacement] {
        var occupiedRects = enzymeRects
        var placedConnectors: [(CGPoint, CGPoint)] = []  // Track feature connector lines for crossing penalty
        var results: [FeatureLabelPlacement] = []
        let circleExclusionRadius = radius + 28  // feature arc outer edge + generous margin
        let canvasBounds = CGRect(x: 8, y: 8, width: canvasSize.width - 16, height: canvasSize.height - 16)
        
        for (feature, startAngle, endAngle) in labelData {
            // Truncate very long feature names to keep labels manageable
            let truncatedName: String
            if feature.name.count > 40 {
                truncatedName = String(feature.name.prefix(37)) + "..."
            } else {
                truncatedName = feature.name
            }
            let bpLen = abs(feature.end - feature.start)
            let isCoding = feature.type == .gene || feature.type == .cds
            let sizeStr = isCoding && bpLen >= 3 ? " (\(bpLen) bp / \(bpLen / 3) aa)" : " (\(bpLen) bp)"
            let labelText = "\(feature.start + 1)..\(feature.end) \(truncatedName)\(sizeStr)"
            let labelWidth: CGFloat = CGFloat(labelText.count) * 7.5 + 20
            let labelHeight: CGFloat = 18
            
            var span = endAngle - startAngle
            if span < 0 { span += 360 }
            var midAngle = startAngle + span / 2
            if midAngle > 360 { midAngle -= 360 }
            if midAngle < -180 { midAngle += 360 }
            
            // Build candidate angles: midpoint first, then spreading toward arc edges
            var candidateAngles: [Double] = [midAngle]
            let steps = max(2, Int(span / 8))
            for i in 1...steps {
                let frac = Double(i) / Double(steps)
                var a1 = midAngle - frac * span * 0.45
                var a2 = midAngle + frac * span * 0.45
                if a1 < -180 { a1 += 360 }
                if a2 > 360 { a2 -= 360 }
                candidateAngles.append(a1)
                candidateAngles.append(a2)
            }
            
            var bestRect = CGRect.zero
            var bestAngle = midAngle
            var bestScore = Int.max
            
            for angle in candidateAngles {
                let rad = angle * .pi / 180.0
                let cosA = CGFloat(cos(rad))
                let sinA = CGFloat(sin(rad))
                
                let tickEnd = CGPoint(
                    x: center.x + (radius + 8) * cosA,
                    y: center.y + (radius + 8) * sinA
                )
                
                for dist in stride(from: CGFloat(22), through: CGFloat(280), by: CGFloat(14)) {
                    let anchorX = center.x + (radius + dist) * cosA
                    let anchorY = center.y + (radius + dist) * sinA
                    
                    let labelX: CGFloat
                    let labelY: CGFloat
                    
                    if abs(cosA) >= abs(sinA) {
                        labelX = cosA >= 0 ? anchorX : anchorX - labelWidth
                        labelY = anchorY - labelHeight / 2
                    } else {
                        labelX = anchorX - labelWidth / 2
                        labelY = sinA >= 0 ? anchorY : anchorY - labelHeight
                    }
                    
                    let candidateRect = CGRect(x: labelX, y: labelY, width: labelWidth, height: labelHeight)
                    
                    // Reject labels that extend outside the canvas
                    if !canvasBounds.contains(candidateRect) {
                        continue
                    }
                    
                    // CRITICAL: reject labels overlapping the plasmid circle
                    if rectOverlapsCircle(rect: candidateRect, center: center, radius: circleExclusionRadius) {
                        continue
                    }
                    
                    let hasRectCollision = occupiedRects.contains { existing in
                        existing.insetBy(dx: -4, dy: -2).intersects(candidateRect)
                    }
                    
                    let attachPt = nearestRectEdgePoint(rect: candidateRect, toward: tickEnd)
                    var lineCrossings = 0
                    
                    // Check connector crossing enzyme connector lines
                    for (lineA, lineB) in enzymeLines {
                        if segmentsIntersect(a: tickEnd, b: attachPt, c: lineA, d: lineB) {
                            lineCrossings += 1
                        }
                    }
                    
                    // Check connector crossing already-placed feature connector lines
                    for (lineA, lineB) in placedConnectors {
                        if segmentsIntersect(a: tickEnd, b: attachPt, c: lineA, d: lineB) {
                            lineCrossings += 2
                        }
                    }
                    
                    // Check connector crossing enzyme label rects
                    for eRect in enzymeRects {
                        if lineIntersectsRect(a: tickEnd, b: attachPt, rect: eRect.insetBy(dx: -2, dy: -2)) {
                            lineCrossings += 1
                        }
                    }
                    
                    // Check connector line doesn't cross back over the plasmid circle
                    if lineIntersectsCircle(a: tickEnd, b: attachPt, center: center, radius: radius - 4) {
                        lineCrossings += 5
                    }
                    
                    let score = (hasRectCollision ? 1000 : 0) + lineCrossings + Int(dist / 14)
                    
                    if score < bestScore {
                        bestScore = score
                        bestRect = candidateRect
                        bestAngle = angle
                    }
                    
                    if score == 0 { break }
                }
                
                if bestScore == 0 { break }
            }
            
            // Fallback: if no valid position found, clamp to canvas bounds
            if bestRect == .zero {
                let rad = midAngle * .pi / 180.0
                let fallbackDist: CGFloat = 60
                let fx = center.x + (radius + fallbackDist) * CGFloat(cos(rad))
                let fy = center.y + (radius + fallbackDist) * CGFloat(sin(rad))
                let clampedX = min(max(fx, canvasBounds.minX), canvasBounds.maxX - labelWidth)
                let clampedY = min(max(fy, canvasBounds.minY), canvasBounds.maxY - labelHeight)
                bestRect = CGRect(x: clampedX, y: clampedY, width: labelWidth, height: labelHeight)
            }
            
            // Record this connector line so subsequent features avoid crossing it
            let finalRad = bestAngle * .pi / 180.0
            let tickEnd = CGPoint(
                x: center.x + (radius + 8) * CGFloat(cos(finalRad)),
                y: center.y + (radius + 8) * CGFloat(sin(finalRad))
            )
            let attachPt = nearestRectEdgePoint(rect: bestRect, toward: tickEnd)
            placedConnectors.append((tickEnd, attachPt))
            
            occupiedRects.append(bestRect)
            results.append(FeatureLabelPlacement(feature: feature, connAngle: bestAngle, rect: bestRect))
        }
        
        return results
    }
    
    /// Check if any part of a rect overlaps a circle
    private func rectOverlapsCircle(rect: CGRect, center: CGPoint, radius: CGFloat) -> Bool {
        // Find closest point on rect to circle center
        let closestX = min(max(center.x, rect.minX), rect.maxX)
        let closestY = min(max(center.y, rect.minY), rect.maxY)
        let dx = closestX - center.x
        let dy = closestY - center.y
        return (dx * dx + dy * dy) < (radius * radius)
    }
    
    /// Check if a line segment intersects a circle (enters the circle interior)
    private func lineIntersectsCircle(a: CGPoint, b: CGPoint, center: CGPoint, radius: CGFloat) -> Bool {
        // Vector from a to b
        let dx = b.x - a.x
        let dy = b.y - a.y
        // Vector from a to center
        let fx = a.x - center.x
        let fy = a.y - center.y
        
        let aa = dx * dx + dy * dy
        let bb = 2 * (fx * dx + fy * dy)
        let cc = fx * fx + fy * fy - radius * radius
        
        var discriminant = bb * bb - 4 * aa * cc
        if discriminant < 0 { return false }
        
        discriminant = sqrt(discriminant)
        let t1 = (-bb - discriminant) / (2 * aa)
        let t2 = (-bb + discriminant) / (2 * aa)
        
        // Check if either intersection point is within the segment [0, 1]
        if t1 >= 0 && t1 <= 1 { return true }
        if t2 >= 0 && t2 <= 1 { return true }
        
        return false
    }
    
    /// Feature connector: tick + line
    private func featureConnectorView(center: CGPoint, radius: CGFloat, connAngle: Double, labelRect: CGRect, offset: CGSize) -> some View {
        let rad = connAngle * .pi / 180.0
        let cosA = CGFloat(cos(rad))
        let sinA = CGFloat(sin(rad))
        
        let tickStart = CGPoint(
            x: center.x + radius * cosA,
            y: center.y + radius * sinA
        )
        let tickEnd = CGPoint(
            x: center.x + (radius + 8) * cosA,
            y: center.y + (radius + 8) * sinA
        )
        
        let offsetRect = labelRect.offsetBy(dx: offset.width, dy: offset.height)
        let attachPt = nearestRectEdgePoint(rect: offsetRect, toward: tickEnd)
        
        return ZStack {
            Path { path in
                path.move(to: tickStart)
                path.addLine(to: tickEnd)
            }
            .stroke(Color.black, lineWidth: 2)
            
            Path { path in
                path.move(to: tickEnd)
                path.addLine(to: attachPt)
            }
            .stroke(Color.black, lineWidth: 1)
        }
    }
    
    /// Draggable feature label
    private func draggableFeatureLabel(feature: Feature, labelRect: CGRect, offset: CGSize, key: String) -> some View {
        let truncatedName: String = feature.name.count > 40 ? String(feature.name.prefix(37)) + "..." : feature.name
        let bpLen = abs(feature.end - feature.start)
        let isCoding = feature.type == .gene || feature.type == .cds
        let sizeStr = isCoding && bpLen >= 3 ? " (\(bpLen) bp / \(bpLen / 3) aa)" : " (\(bpLen) bp)"
        let labelText = "\(feature.start + 1)..\(feature.end) \(truncatedName)\(sizeStr)"
        let featureColor = feature.color.color
        let isSelected = selectedFeatureID == feature.id
        let isDragging = activeFeatureDragKey == key
        
        return Text(labelText)
            .font(.system(size: labelFontSize, weight: .medium))
            .foregroundColor(.black)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(NSColor.textBackgroundColor))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(featureColor.opacity(0.35))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(isSelected ? Color.blue : Color.black, lineWidth: isSelected ? 2 : (isDragging ? 1.5 : 1))
            )
            .position(
                x: labelRect.midX + offset.width,
                y: labelRect.midY + offset.height
            )
            .onTapGesture(count: 2) {
                handleFeatureDoubleClick(feature)
            }
            .onTapGesture(count: 1) {
                selectedFeatureID = selectedFeatureID == feature.id ? nil : feature.id
            }
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        activeFeatureDragKey = key
                        if featureLabelOffsets[key + "_dragStart"] == nil {
                            featureLabelOffsets[key + "_dragStart"] = featureLabelOffsets[key] ?? .zero
                        }
                        let start = featureLabelOffsets[key + "_dragStart"] ?? .zero
                        featureLabelOffsets[key] = CGSize(
                            width: start.width + value.translation.width,
                            height: start.height + value.translation.height
                        )
                    }
                    .onEnded { _ in
                        activeFeatureDragKey = nil
                        featureLabelOffsets.removeValue(forKey: key + "_dragStart")
                    }
            )
    }
    
    /// Check if two line segments intersect
    private func segmentsIntersect(a: CGPoint, b: CGPoint, c: CGPoint, d: CGPoint) -> Bool {
        let denom = (b.x - a.x) * (d.y - c.y) - (b.y - a.y) * (d.x - c.x)
        if abs(denom) < 0.0001 { return false }
        let t = ((c.x - a.x) * (d.y - c.y) - (c.y - a.y) * (d.x - c.x)) / denom
        let u = -((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) / denom
        return t >= 0 && t <= 1 && u >= 0 && u <= 1
    }
    
    /// Check if a line segment intersects a rectangle
    private func lineIntersectsRect(a: CGPoint, b: CGPoint, rect: CGRect) -> Bool {
        if rect.contains(a) || rect.contains(b) { return true }
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)
        ]
        for i in 0..<4 {
            if segmentsIntersect(a: a, b: b, c: corners[i], d: corners[(i + 1) % 4]) { return true }
        }
        return false
    }
    
    /// Find the center of the rect edge that faces the given external point
    private func nearestRectEdgePoint(rect: CGRect, toward point: CGPoint) -> CGPoint {
        let dx = point.x - rect.midX
        let dy = point.y - rect.midY
        
        // Pick the edge whose outward normal best aligns with the direction to the point
        if abs(dx) / rect.width > abs(dy) / rect.height {
            // Horizontal dominant — left or right edge center
            if dx >= 0 {
                return CGPoint(x: rect.maxX, y: rect.midY)
            } else {
                return CGPoint(x: rect.minX, y: rect.midY)
            }
        } else {
            // Vertical dominant — top or bottom edge center
            if dy >= 0 {
                return CGPoint(x: rect.midX, y: rect.maxY)
            } else {
                return CGPoint(x: rect.midX, y: rect.minY)
            }
        }
    }

    private func angleForPosition(_ position: Int, sequenceLength: Int) -> Double {
        // Subtract 90 to place position 1 at 12 o'clock instead of 3 o'clock
        return (Double(position) / Double(sequenceLength) * 360.0) - 90.0
    }
    
    private func pointOnCircle(center: CGPoint, radius: CGFloat, angle: Double) -> CGPoint {
        let radians = angle * .pi / 180.0
        return CGPoint(
            x: center.x + radius * CGFloat(cos(radians)),
            y: center.y + radius * CGFloat(sin(radians))
        )
    }
}

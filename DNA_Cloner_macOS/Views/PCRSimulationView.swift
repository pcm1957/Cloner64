//
//  PCRSimulationView.swift
//  Cloner 64
//
//  In silico PCR simulation.  Pick a template sequence, enter forward
//  and reverse primers (with optional 5-prime tails), choose Taq
//  (adds 3' A overhang) or Pfu (blunt), and generate the amplicon.
//  Shows binding positions, annealing Tm, product size and GC%.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers


// MARK: - Primer Transfer (from Design Primers → Run PCR)

class PCRPrimerTransfer {
    static let shared = PCRPrimerTransfer()
    
    var fwdAnnealing: String?
    var revAnnealing: String?
    var fwdTail: String?
    var revTail: String?
    var sequenceID: UUID?
    
    var hasPendingTransfer: Bool {
        fwdAnnealing != nil || revAnnealing != nil
    }
    
    func clear() {
        fwdAnnealing = nil
        revAnnealing = nil
        fwdTail = nil
        revTail = nil
        sequenceID = nil
    }
}


// MARK: - Window Manager

class PCRSimulationWindowManager {
    static let shared = PCRSimulationWindowManager()
    private var window: NSWindow?
    private var storedSequenceManager: SequenceManager?
    
    func openWindow(sequenceManager: SequenceManager) {
        storedSequenceManager = sequenceManager
        
        // If transferring primers, always create a fresh window so onAppear fires
        if PCRPrimerTransfer.shared.hasPendingTransfer {
            window?.close()
            window = nil
        }
        
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        
        let view = PCRSimulationView(sequenceManager: sequenceManager)
        let hostingView = NSHostingView(rootView: view)
        
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Run a PCR"
        win.contentView = hostingView
        win.setFrameAutosaveName("RunaPCR")
        if !win.setFrameUsingName(win.frameAutosaveName) { win.center() }
        win.makeKeyAndOrderFront(nil)
        win.isReleasedWhenClosed = false
        
        self.window = win
    }
    
    /// Store reference for later use by "Run PCR with These Primers" button
    func storeSequenceManager(_ sm: SequenceManager) {
        storedSequenceManager = sm
    }
    
    /// Open using previously stored sequenceManager (called from PrimerDesignView)
    func openWindowWithTransfer() {
        guard let sm = storedSequenceManager else { return }
        openWindow(sequenceManager: sm)
    }
}


// MARK: - Polymerase Enum

enum Polymerase: String, CaseIterable {
    case taq = "Taq (adds 3′ A overhang)"
    case pfu = "Pfu / Phusion (blunt ends)"
}


// MARK: - PCR Result

struct PCRResult {
    let amplicon: String           // full amplicon sequence (sense strand, 5' → 3')
    let productSize: Int
    let fwdBindPos: Int            // 1-based position on template where fwd anneals
    let revBindPos: Int            // 1-based position on template where rev anneals (sense strand)
    let fwdAnnealingSeq: String    // portion of fwd primer that anneals
    let revAnnealingSeq: String    // portion of rev primer that anneals (as entered, 5'→3')
    let fwdTail: String
    let revTail: String
    let fwdTm: Double              // annealing portion only
    let revTm: Double              // annealing portion only
    let fwdFullTm: Double          // full primer (tail + annealing)
    let revFullTm: Double          // full primer (tail + annealing)
    let annealingTemp: Double
    let gcPercent: Double
    let polymerase: Polymerase
    let hasAOverhang: Bool
    let rolesSwapped: Bool         // true if the user's Fwd/Rev labels were swapped
                                   // internally to match the template's strand orientation
    let fwdMismatches: Int         // number of mismatches between fwd primer and template
    let revMismatches: Int         // number of mismatches between rev primer and template
    var hasMismatches: Bool { fwdMismatches > 0 || revMismatches > 0 }
}


// MARK: - Main View

struct PCRSimulationView: View {
    @ObservedObject var sequenceManager: SequenceManager
    
    // Template
    @State private var selectedSequenceID: UUID?
    
    // Primers
    @State private var fwdPrimerText: String = ""
    @State private var revPrimerText: String = ""
    @State private var fwdTailText: String = ""
    @State private var revTailText: String = ""
    @State private var fwdPrimerName: String = ""
    @State private var revPrimerName: String = ""
    
    // Polymerase
    @State private var polymerase: Polymerase = .taq
    
    // Salt concentration for Tm
    @State private var saltConc: Double = 50.0  // mM

    // Mismatch tolerance: max mismatches allowed per primer (0 = exact match only)
    @State private var maxMismatches: Int = 0
    
    // Results
    @State private var result: PCRResult? = nil
    @State private var errorMessage: String? = nil
    @State private var copiedField: String? = nil

    // True while runPCR() is executing on the background thread.
    @State private var isRunning: Bool = false

    // Cached primer stats shown in the input section.
    // Rebuilt only when the primer text or salt concentration changes,
    // not on every render pass.
    @State private var fwdStats: (tm: Double, gc: Double, fullTm: Double) = (0, 0, 0)
    @State private var revStats: (tm: Double, gc: Double, fullTm: Double) = (0, 0, 0)

    private func refreshPrimerStats() {
        let salt = saltConc / 1000.0
        let fa = fwdAnnealing; let ff = fullFwdPrimer
        fwdStats = (
            tm:     fa.isEmpty ? 0 : calculateTm(fa,  naM: salt),
            gc:     fa.isEmpty ? 0 : gcPercent(fa),
            fullTm: ff.count > fa.count ? calculateTm(ff, naM: salt) : (fa.isEmpty ? 0 : calculateTm(fa, naM: salt))
        )
        let ra = revAnnealing; let rf = fullRevPrimer
        revStats = (
            tm:     ra.isEmpty ? 0 : calculateTm(ra,  naM: salt),
            gc:     ra.isEmpty ? 0 : gcPercent(ra),
            fullTm: rf.count > ra.count ? calculateTm(rf, naM: salt) : (ra.isEmpty ? 0 : calculateTm(ra, naM: salt))
        )
    }
    
    private var selectedSequence: DNASequence? {
        guard let id = selectedSequenceID else { return nil }
        return sequenceManager.sequences.first(where: { $0.id == id })
    }
    
    private var fwdAnnealing: String {
        fwdPrimerText.uppercased().filter { "ACGTRYWSMKHBVDN".contains($0) }
    }
    
    private var revAnnealing: String {
        revPrimerText.uppercased().filter { "ACGTRYWSMKHBVDN".contains($0) }
    }
    
    private var fwdTail: String {
        fwdTailText.filter { "ACGTRYWSMKHBVDNacgtrywsmkhbvdn".contains($0) }
    }
    
    private var revTail: String {
        revTailText.filter { "ACGTRYWSMKHBVDNacgtrywsmkhbvdn".contains($0) }
    }
    
    private var fullFwdPrimer: String { fwdTail.uppercased() + fwdAnnealing }
    private var fullRevPrimer: String { revTail.uppercased() + revAnnealing }
    
    var body: some View {
        VStack(spacing: 0) {
            inputSection
            Divider()
            if let error = errorMessage {
                errorBar(error)
                Divider()
            }
            if let res = result {
                resultSection(res)
            } else {
                Spacer()
                Text("Enter primers and click Run PCR")
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .frame(minWidth: 750, minHeight: 550)
        .onAppear {
            if selectedSequenceID == nil, let first = sequenceManager.sequences.first {
                selectedSequenceID = first.id
            }
            
            // Pick up primers transferred from Design PCR Primers
            let transfer = PCRPrimerTransfer.shared
            if transfer.hasPendingTransfer {
                if let fwd = transfer.fwdAnnealing { fwdPrimerText = fwd }
                if let rev = transfer.revAnnealing { revPrimerText = rev }
                if let ft = transfer.fwdTail { fwdTailText = ft }
                if let rt = transfer.revTail { revTailText = rt }
                if let seqID = transfer.sequenceID {
                    selectedSequenceID = seqID
                }
                transfer.clear()
            }
        }
        .overlay(alignment: .bottom) {
            if let msg = copiedField {
                Text(msg)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .cornerRadius(8).shadow(radius: 4)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
    
    
    // MARK: - Input Section
    
    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Template
            HStack {
                Text("Template:").frame(width: 110, alignment: .trailing)
                Picker("", selection: $selectedSequenceID) {
                    Text("None").tag(nil as UUID?)
                    ForEach(sequenceManager.sequences) { seq in
                        Text("\(seq.name) (\(seq.length) bp, \(seq.isCircular ? "circular" : "linear"))")
                            .tag(seq.id as UUID?)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 400)
                .contextHelp("pcr.templatePicker")
                
                Button("Open…") {
                    openTemplateFromFile()
                }
                .contextHelp("pcr.openTemplate")
            }
            
            // Forward primer: tail + annealing on one line
            HStack(alignment: .top) {
                Text("Fwd 5′→3′:").frame(width: 110, alignment: .trailing)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        TextField("5′ tail (optional)", text: $fwdTailText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13, design: .monospaced))
                            .frame(width: 150)
                            .foregroundColor(.orange)
                        Text("—").foregroundColor(.secondary)
                        TextField("annealing sequence", text: $fwdPrimerText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13, design: .monospaced))
                        
                        Button("Open…") {
                            openPrimerFile(direction: "forward")
                        }
                        .controlSize(.small)
                        .contextHelp("pcr.loadForwardPrimer")
                        
                        Button("Save…") {
                            savePrimerToFile(direction: "forward")
                        }
                        .controlSize(.small)
                        .disabled(fwdAnnealing.count < 5)
                        .contextHelp("pcr.saveForwardPrimer")
                    }
                    if !fwdPrimerName.isEmpty {
                        Text(fwdPrimerName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.blue)
                    }
                    if !fwdAnnealing.isEmpty {
                        HStack(spacing: 8) {
                            Text("Annealing: \(fwdAnnealing.count) nt, Tm: \(String(format: "%.1f", fwdStats.tm))°C, GC: \(String(format: "%.0f", fwdStats.gc))%")
                                .font(.system(size: 12)).foregroundColor(.secondary)
                            if !fwdTail.isEmpty {
                                Text("Tail: \(fwdTail.count) nt")
                                    .font(.system(size: 12)).foregroundColor(.orange)
                                Text("Full: \(fullFwdPrimer.count) nt, Tm: \(String(format: "%.1f", fwdStats.fullTm))°C")
                                    .font(.system(size: 12)).foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            
            // Reverse primer: tail + annealing on one line
            HStack(alignment: .top) {
                Text("Rev 5′→3′:").frame(width: 110, alignment: .trailing)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        TextField("5′ tail (optional)", text: $revTailText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13, design: .monospaced))
                            .frame(width: 150)
                            .foregroundColor(.orange)
                        Text("—").foregroundColor(.secondary)
                        TextField("annealing sequence", text: $revPrimerText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13, design: .monospaced))
                        
                        Button("Open…") {
                            openPrimerFile(direction: "reverse")
                        }
                        .controlSize(.small)
                        .contextHelp("pcr.loadReversePrimer")
                        
                        Button("Save…") {
                            savePrimerToFile(direction: "reverse")
                        }
                        .controlSize(.small)
                        .disabled(revAnnealing.count < 5)
                        .contextHelp("pcr.saveReversePrimer")
                    }
                    if !revPrimerName.isEmpty {
                        Text(revPrimerName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.blue)
                    }
                    if !revAnnealing.isEmpty {
                        HStack(spacing: 8) {
                            Text("Annealing: \(revAnnealing.count) nt, Tm: \(String(format: "%.1f", revStats.tm))°C, GC: \(String(format: "%.0f", revStats.gc))%")
                                .font(.system(size: 12)).foregroundColor(.secondary)
                            if !revTail.isEmpty {
                                Text("Tail: \(revTail.count) nt")
                                    .font(.system(size: 12)).foregroundColor(.orange)
                                Text("Full: \(fullRevPrimer.count) nt, Tm: \(String(format: "%.1f", revStats.fullTm))°C")
                                    .font(.system(size: 12)).foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            
            // Polymerase & salt
            HStack {
                Text("Polymerase:").frame(width: 110, alignment: .trailing)
                Picker("", selection: $polymerase) {
                    ForEach(Polymerase.allCases, id: \.self) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
                .contextHelp("pcr.polymerase")
                
                Spacer().frame(width: 20)
                
                Text("Na⁺:")
                TextField("", value: $saltConc, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 50)
                    .font(.system(size: 13, design: .monospaced))
                Text("mM").foregroundColor(.secondary)

                Spacer().frame(width: 20)

                Text("Mismatches:")
                Stepper("\(maxMismatches)", value: $maxMismatches, in: 0...8)
                    .frame(width: 120)
                    .contextHelp("pcr.mismatchTolerance")
            }
            
            // Run button
            HStack {
                Spacer()
                Button(action: runPCR) {
                    if isRunning {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Running…")
                        }
                        .frame(width: 120)
                    } else {
                        Text("Run PCR")
                            .frame(width: 120)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isRunning || selectedSequence == nil || fwdAnnealing.count < 10 || revAnnealing.count < 10)
                .contextHelp("pcr.runPCR")
                Spacer()
            }
        }
        .padding(12)
        .onAppear { refreshPrimerStats() }
        .onChange(of: fwdPrimerText)  { _ in refreshPrimerStats() }
        .onChange(of: fwdTailText)    { _ in refreshPrimerStats() }
        .onChange(of: revPrimerText)  { _ in refreshPrimerStats() }
        .onChange(of: revTailText)    { _ in refreshPrimerStats() }
        .onChange(of: saltConc)       { _ in refreshPrimerStats() }
    }
    
    
    // MARK: - Error Bar
    
    private func errorBar(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(.orange)
            Spacer()
            Button("Dismiss") { errorMessage = nil }
                .controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.orange.opacity(0.1))
    }
    
    
    // MARK: - Result Section
    
    private func resultSection(_ res: PCRResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Notice when primer roles were swapped to match template orientation
                if res.rolesSwapped {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.blue)
                        Text("Your Forward and Reverse primer labels were swapped internally to match the template's strand orientation. The amplicon below uses the geometrically correct assignment — the primer labelled ‘Forward’ in the results actually came from your Reverse input field, and vice versa.")
                            .font(.system(size: 12))
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(6)
                    .contextHelp("pcr.rolesSwapped")
                }
                
                // Mismatch warning
                if res.hasMismatches {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Primer\u{2013}template mismatches detected")
                                .font(.system(size: 12, weight: .semibold))
                            let fwdPart = res.fwdMismatches > 0 ? "Forward: \(res.fwdMismatches) mismatch\(res.fwdMismatches == 1 ? "" : "es")" : nil
                            let revPart = res.revMismatches > 0 ? "Reverse: \(res.revMismatches) mismatch\(res.revMismatches == 1 ? "" : "es")" : nil
                            let parts   = [fwdPart, revPart].compactMap { $0 }.joined(separator: "  \u{2022}  ")
                            Text(parts)
                                .font(.system(size: 12))
                            Text("The amplicon sequence incorporates the primer sequence at the mismatched positions — this is the intended behaviour for SDM primers. Verify the product sequence matches your expected mutant.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(6)
                    .contextHelp("pcr.mismatchWarning")
                }
                GroupBox("PCR Product") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 24) {
                            infoItem("Product size", "\(res.productSize) bp")
                            infoItem("GC content", String(format: "%.1f%%", res.gcPercent))
                            infoItem("Polymerase", polymerase == .taq ? "Taq" : "Pfu/Phusion")
                            if res.hasAOverhang {
                                Text("3′ A overhang")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 8).padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.15))
                                    .cornerRadius(4)
                            } else {
                                Text("Blunt ends")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.blue)
                                    .padding(.horizontal, 8).padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.15))
                                    .cornerRadius(4)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contextHelp("pcr.productSummary")
                GroupBox("Annealing Details") {
                    VStack(alignment: .leading, spacing: 8) {
                        primerDetailRow("Forward primer",
                                        annealing: res.fwdAnnealingSeq,
                                        tail: res.fwdTail,
                                        tm: res.fwdTm,
                                        bindPos: res.fwdBindPos,
                                        strand: "sense (+)")
                        
                        Divider()
                        
                        primerDetailRow("Reverse primer",
                                        annealing: res.revAnnealingSeq,
                                        tail: res.revTail,
                                        tm: res.revTm,
                                        bindPos: res.revBindPos,
                                        strand: "antisense (−)")
                        
                        Divider()
                        
                        let hasTails = !res.fwdTail.isEmpty || !res.revTail.isEmpty
                        
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 24) {
                                infoItem("Fwd Annealing Tm", String(format: "%.1f°C", res.fwdTm))
                                infoItem("Rev Annealing Tm", String(format: "%.1f°C", res.revTm))
                                infoItem("ΔTm (annealing)", String(format: "%.1f°C", abs(res.fwdTm - res.revTm)))
                                infoItem("Recommended annealing", String(format: "%.1f°C", res.annealingTemp))
                            }
                            
                            if hasTails {
                                HStack(spacing: 24) {
                                    infoItem("Fwd Full Tm", String(format: "%.1f°C", res.fwdFullTm))
                                    infoItem("Rev Full Tm", String(format: "%.1f°C", res.revFullTm))
                                    infoItem("ΔTm (full)", String(format: "%.1f°C", abs(res.fwdFullTm - res.revFullTm)))
                                }
                                
                                Text("Use annealing Tm for initial cycles (tails don't bind). Full Tm applies after tails are incorporated.")
                                    .font(.system(size: 11)).foregroundColor(.secondary)
                            } else {
                                Text("Annealing temp = lowest primer Tm − 5°C")
                                    .font(.system(size: 11)).foregroundColor(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contextHelp("pcr.annealingDetails")
                
                // Amplicon map
                GroupBox("Amplicon Map") {
                    ampliconMap(res)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contextHelp("pcr.ampliconMap")
                GroupBox(res.hasAOverhang
                         ? "Amplicon Sequence (sense strand, 5′ → 3′, with 3′ A overhangs)"
                         : "Amplicon Sequence (sense strand, 5′ → 3′)") {
                    VStack(alignment: .leading, spacing: 6) {
                        let displayAmplicon = res.hasAOverhang ? res.amplicon + "A" : res.amplicon
                        let formatted = formatSequence(displayAmplicon)
                        Text(formatted)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(nil)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                            .background(Color(.textBackgroundColor))
                            .cornerRadius(4)
                        
                        if res.hasAOverhang {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Taq 3′ A overhangs on both strands:")
                                    .font(.system(size: 12, weight: .medium)).foregroundColor(.orange)
                                Text("  Sense:       5′– ....\(res.amplicon.suffix(12))" + "A" + " –3′")
                                    .font(.system(size: 11, design: .monospaced))
                                Text("  Antisense:  3′– A\(reverseComplement(String(res.amplicon.prefix(12)))).... –5′")
                                    .font(.system(size: 11, design: .monospaced))
                            }
                        }
                        
                        HStack {
                            Button("Copy Sequence") {
                                copyToClipboard(displayAmplicon, label: "Amplicon sequence copied")
                            }
                            .controlSize(.small)
                            .contextHelp("pcr.copySequence")
                            
                            Button("Copy FASTA") {
                                let suffix = res.hasAOverhang ? " Taq_A-tailed" : ""
                                let fasta = ">\(selectedSequence?.name ?? "amplicon")_PCR_product \(displayAmplicon.count)bp\(suffix)\n\(displayAmplicon)"
                                copyToClipboard(fasta, label: "FASTA copied")
                            }
                            .controlSize(.small)
                            .contextHelp("pcr.copyFASTA")
                            
                            Button("Open as New Sequence") {
                                openAmpliconAsSequence()
                            }
                            .controlSize(.small)
                            .contextHelp("pcr.openAsSequence")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
        }
    }
    
    private func primerDetailRow(_ label: String, annealing: String, tail: String, tm: Double, bindPos: Int, strand: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 13, weight: .semibold))
            
            HStack(spacing: 0) {
                if !tail.isEmpty {
                    Text(tail)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.orange)
                    Text("—")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Text(annealing)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.blue)
            }
            
            HStack(spacing: 16) {
                Text("Binds at position \(bindPos) on \(strand)")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                Text("Annealing: \(annealing.count) nt")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                if !tail.isEmpty {
                    Text("Tail: \(tail.count) nt")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
                Text("Full length: \(tail.count + annealing.count) nt")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
        }
    }
    
    private func ampliconMap(_ res: PCRResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            let fwdTailStr = res.fwdTail.isEmpty ? "" : "[\(res.fwdTail.count)nt tail]—"
            let revTailStr = res.revTail.isEmpty ? "" : "—[\(res.revTail.count)nt tail]"
            
            Text("5′ \(fwdTailStr)►\(res.fwdAnnealingSeq.prefix(15))...→ template →...\(String(res.revAnnealingSeq.suffix(15)))◄\(revTailStr) 3′")
                .font(.system(size: 11, design: .monospaced))
            
            Text("   Position \(res.fwdBindPos)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
            + Text(String(repeating: " ", count: 30))
            + Text("Position \(res.revBindPos)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
            
            if res.hasAOverhang {
                Text("   + 3′ A overhangs (Taq)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.orange)
            }
        }
    }
    
    private func infoItem(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 11)).foregroundColor(.secondary)
            Text(value).font(.system(size: 13, weight: .medium, design: .monospaced))
        }
    }
    
    
    // MARK: - Open / Save Helpers
    
    /// Open a sequence file from disk and add it to the open sequences list.
    private func openTemplateFromFile() {
        let panel = NSOpenPanel()
        panel.title = "Open Template Sequence"
        panel.allowedContentTypes = [.data]
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        
        guard panel.runModal() == .OK, let url = panel.url else { return }
        
        let parser = XDNAParser()
        
        if let seq = parser.parseXDNA(url) {
            seq.sourceURL = url
            sequenceManager.sequences.append(seq)
            selectedSequenceID = seq.id
            result = nil
            errorMessage = nil
            return
        }
        
        // Fallback: try FASTA/plain text
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            let cleaned = text.components(separatedBy: .newlines)
                .filter { !$0.hasPrefix(">") }
                .joined()
                .filter { "ACGTURYSWKMBDHVNacgturyswkmbdhvn".contains($0) }
            if !cleaned.isEmpty {
                let seq = DNASequence(name: url.deletingPathExtension().lastPathComponent, sequence: cleaned)
                seq.sourceURL = url
                sequenceManager.sequences.append(seq)
                selectedSequenceID = seq.id
                result = nil
                errorMessage = nil
                return
            }
        }
        
        errorMessage = "Could not read sequence from \(url.lastPathComponent)"
    }
    
    /// Open a primer .xdna file and populate the appropriate primer fields.
    private func openPrimerFile(direction: String) {
        let panel = NSOpenPanel()
        panel.title = "Open \(direction.capitalized) Primer"
        panel.allowedContentTypes = [.data]
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        
        guard panel.runModal() == .OK, let url = panel.url else { return }
        
        let parser = XDNAParser()
        guard let seq = parser.parseXDNA(url) else {
            errorMessage = "Could not read \(url.lastPathComponent)"
            return
        }
        
        let parts = extractPrimerParts(from: seq)
        let core = parts?.core ?? seq.sequence.uppercased()
        let tail = parts?.tail ?? ""
        
        if direction == "forward" {
            fwdPrimerText = core
            fwdTailText = tail
            fwdPrimerName = seq.name
        } else {
            revPrimerText = core
            revTailText = tail
            revPrimerName = seq.name
        }
        
        result = nil
        errorMessage = nil
    }
    
    /// Save a primer as a .xdna file with Primer Core and Primer Tail features.
    private func savePrimerToFile(direction: String) {
        let annealing = direction == "forward" ? fwdAnnealing : revAnnealing
        let tail = direction == "forward" ? fwdTail : revTail
        guard !annealing.isEmpty else { return }
        
        let templateName = selectedSequence?.name ?? "PCR"
        let baseName = templateName.replacingOccurrences(of: " ", with: "_")
        let defaultName = "\(baseName)_\(direction.capitalized).xdna"
        
        let panel = NSSavePanel()
        panel.title = "Save \(direction.capitalized) Primer"
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [.data]
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        
        guard panel.runModal() == .OK, let url = panel.url else { return }
        
        let primerSeq = buildPrimerSequence(
            name: url.deletingPathExtension().lastPathComponent,
            annealing: annealing,
            tail: tail
        )
        
        let parser = XDNAParser()
        if parser.writeXDNA(primerSeq, to: url) {
            copyToClipboard("", label: "\(direction.capitalized) primer saved")
        } else {
            errorMessage = "Failed to save primer file."
        }
    }
    
    /// Build a DNASequence for a single primer, with Primer Core and
    /// optional Primer Tail features. Core is uppercase, tail is lowercase.
    private func buildPrimerSequence(name: String, annealing: String, tail: String) -> DNASequence {
        let tailPart = tail.lowercased()
        let corePart = annealing.uppercased()
        let fullSeq = tailPart + corePart
        
        let seq = DNASequence(name: name, sequence: fullSeq, isCircular: false)
        seq.description = "Primer for PCR on \(selectedSequence?.name ?? "template")"
        
        var features: [Feature] = []
        
        if !tail.isEmpty {
            features.append(Feature(
                name: "Primer Tail",
                type: .custom,
                start: 0,
                end: tail.count,
                strand: .forward,
                color: CodableColor(red: 0.85, green: 0.15, blue: 0.15)
            ))
        }
        
        let coreStart = tail.isEmpty ? 0 : tail.count
        features.append(Feature(
            name: "Primer Core",
            type: .primerBinding,
            start: coreStart,
            end: coreStart + annealing.count,
            strand: .forward,
            color: CodableColor(red: 0.0, green: 0.0, blue: 0.0)
        ))
        
        seq.features = features
        return seq
    }
    
    /// Extract tail and core from a DNASequence that has Primer Core / Primer Tail features,
    /// or from the case convention (lowercase = tail, UPPERCASE = core).
    private func extractPrimerParts(from seq: DNASequence) -> (tail: String, core: String)? {
        let coreFeature = seq.features.first(where: { $0.name == "Primer Core" })
        let tailFeature = seq.features.first(where: { $0.name == "Primer Tail" })
        
        let fullSeq = seq.sequence
        guard let core = coreFeature else {
            // No features — detect tail/core from case boundary.
            // Convention: lowercase = 5' tail, UPPERCASE = annealing core.
            let chars = Array(fullSeq)
            var tailEnd = 0
            for (i, ch) in chars.enumerated() {
                if ch.isUppercase { tailEnd = i; break }
                tailEnd = i + 1
            }
            if tailEnd == 0 || tailEnd >= chars.count {
                // All one case — treat entire sequence as core
                return (tail: "", core: fullSeq.uppercased())
            }
            let tail = String(chars[..<tailEnd])        // keep lowercase
            let coreStr = String(chars[tailEnd...])      // keep uppercase
            return (tail: tail, core: coreStr.uppercased())
        }
        
        let coreStart = max(0, core.start)
        let coreEnd = min(fullSeq.count, core.end)
        guard coreStart < coreEnd else { return nil }
        let coreStr = String(fullSeq[fullSeq.index(fullSeq.startIndex, offsetBy: coreStart)..<fullSeq.index(fullSeq.startIndex, offsetBy: coreEnd)])
        
        var tailStr = ""
        if let tail = tailFeature {
            let tailStart = max(0, tail.start)
            let tailEnd = min(fullSeq.count, tail.end)
            if tailStart < tailEnd {
                tailStr = String(fullSeq[fullSeq.index(fullSeq.startIndex, offsetBy: tailStart)..<fullSeq.index(fullSeq.startIndex, offsetBy: tailEnd)])
            }
        }
        
        return (tail: tailStr, core: coreStr.uppercased())
    }
    
    
    // MARK: - PCR Engine

    private func runPCR() {
        errorMessage = nil
        result = nil

        guard let template = selectedSequence else {
            errorMessage = "No template sequence selected."
            return
        }

        let fwd = fwdAnnealing
        let rev = revAnnealing

        guard fwd.count >= 10 else {
            errorMessage = "Forward primer annealing region must be at least 10 nt."
            return
        }
        guard rev.count >= 10 else {
            errorMessage = "Reverse primer annealing region must be at least 10 nt."
            return
        }

        // Capture everything the background thread needs before dispatching.
        let templateSeq  = template.sequence.uppercased()
        let templateLen  = templateSeq.count
        let isCircular   = template.isCircular
        let polymeraseVal = polymerase
        let naM          = saltConc / 1000.0
        let fwdTailVal   = fwdTail
        let revTailVal   = revTail
        let maxMM        = maxMismatches

        isRunning = true

        DispatchQueue.global(qos: .userInitiated).async {
            // ── Find both primers on the template ──
            guard let fwdBind = self.findBinding(primer: fwd, in: templateSeq, circular: isCircular, maxMismatches: maxMM) else {
                DispatchQueue.main.async {
                    self.isRunning = false
                    self.errorMessage = maxMM > 0
                        ? "Forward primer could not bind the template even allowing \(maxMM) mismatch\(maxMM == 1 ? "" : "es") (checked both strands)."
                        : "Forward primer does not match the template sequence (checked both strands). Try increasing Mismatches to tolerate SDM mutations."
                }
                return
            }
            guard let revBind = self.findBinding(primer: rev, in: templateSeq, circular: isCircular, maxMismatches: maxMM) else {
                DispatchQueue.main.async {
                    self.isRunning = false
                    self.errorMessage = maxMM > 0
                        ? "Reverse primer could not bind the template even allowing \(maxMM) mismatch\(maxMM == 1 ? "" : "es") (checked both strands)."
                        : "Reverse primer does not match the template sequence (checked both strands). Try increasing Mismatches to tolerate SDM mutations."
                }
                return
            }

            if fwdBind.onSenseStrand == revBind.onSenseStrand {
                DispatchQueue.main.async {
                    self.isRunning = false
                    self.errorMessage = "Both primers bind the same template strand — they prime in the same direction and cannot form a PCR product."
                }
                return
            }

            // ── Geometric assignment ──
            let geomFwdSeq:  String
            let geomRevSeq:  String
            let geomFwdTail: String
            let geomRevTail: String
            let geomFwdPos:  Int
            let geomRevPos:  Int
            let rolesSwapped: Bool

            if fwdBind.onSenseStrand {
                geomFwdSeq  = fwd;       geomRevSeq  = rev
                geomFwdTail = fwdTailVal; geomRevTail = revTailVal
                geomFwdPos  = fwdBind.position
                geomRevPos  = revBind.position
                rolesSwapped = false
            } else {
                geomFwdSeq  = rev;       geomRevSeq  = fwd
                geomFwdTail = revTailVal; geomRevTail = fwdTailVal
                geomFwdPos  = revBind.position
                geomRevPos  = fwdBind.position
                rolesSwapped = true
            }

            // ── Mismatch counts (in the geometrically assigned roles) ──
            let geomFwdMM = fwdBind.onSenseStrand ? fwdBind.mismatches : revBind.mismatches
            let geomRevMM = fwdBind.onSenseStrand ? revBind.mismatches : fwdBind.mismatches

            // ── Amplicon span ──
            let fwdStart   = geomFwdPos
            let revEnd     = geomRevPos + geomRevSeq.count
            let directSpan = revEnd - fwdStart  // negative when fwdStart > revEnd

            // Detect QuikChange SDM on a circular template:
            // Both primers overlap the mutation site and bind at essentially the same
            // position, so the "direct" span equals ~primerLen rather than a real
            // product size.  The actual product is the whole plasmid (wrap-around).
            // A span <= the longest primer cannot be a valid PCR product — if the
            // product were that short it would be smaller than a primer.
            let isQuikChangeLike = isCircular
                                && directSpan >= 0
                                && directSpan <= max(geomFwdSeq.count, geomRevSeq.count)

            // Wrap around the circular origin when:
            //   (a) fwd primer site is past the rev primer end (normal cross-origin PCR), OR
            //   (b) primers overlap at the mutation site (QuikChange SDM)
            let shouldWrap = isCircular && (fwdStart >= revEnd || isQuikChangeLike)

            let templateRegion: String
            if shouldWrap {
                templateRegion = String(templateSeq.suffix(templateLen - fwdStart))
                              + String(templateSeq.prefix(revEnd))
            } else if revEnd > fwdStart {
                let startIdx = templateSeq.index(templateSeq.startIndex, offsetBy: fwdStart)
                let endIdx   = templateSeq.index(templateSeq.startIndex, offsetBy: min(revEnd, templateLen))
                templateRegion = String(templateSeq[startIdx..<endIdx])
            } else {
                DispatchQueue.main.async {
                    self.isRunning = false
                    self.errorMessage = "Primers prime away from each other on the template — no PCR product can form."
                }
                return
            }

            // When primers have mismatches (SDM case), the amplicon incorporates the
            // PRIMER sequence at each end rather than the template — that is exactly
            // the mutation being introduced.  The middle template region is unchanged.
            let amplicon: String
            if geomFwdMM > 0 || geomRevMM > 0 {
                let fwdLen    = geomFwdSeq.count
                let revLen    = geomRevSeq.count
                let regionLen = templateRegion.count

                // Middle = template between the two annealing regions
                let middleStart = min(fwdLen, regionLen)
                let middleEnd   = max(regionLen - revLen, middleStart)
                let middleIdx1  = templateRegion.index(templateRegion.startIndex, offsetBy: middleStart)
                let middleIdx2  = templateRegion.index(templateRegion.startIndex, offsetBy: middleEnd)
                let middle      = String(templateRegion[middleIdx1..<middleIdx2])

                amplicon = geomFwdTail.uppercased()
                         + geomFwdSeq.uppercased()
                         + middle
                         + self.reverseComplement(geomRevSeq).uppercased()
                         + (geomRevTail.isEmpty ? "" : self.reverseComplement(geomRevTail))
            } else {
                var amp = geomFwdTail.uppercased() + templateRegion
                if !geomRevTail.isEmpty { amp += self.reverseComplement(geomRevTail) }
                amplicon = amp
            }

            // ── Tm & GC ──
            let fwdTm    = self.calculateTm(geomFwdSeq, naM: naM)
            let revTm    = self.calculateTm(geomRevSeq, naM: naM)
            let fullFwd  = geomFwdTail.uppercased() + geomFwdSeq
            let fullRev  = geomRevTail.uppercased() + geomRevSeq
            let fwdFullTm = fullFwd.count > geomFwdSeq.count ? self.calculateTm(fullFwd, naM: naM) : fwdTm
            let revFullTm = fullRev.count > geomRevSeq.count ? self.calculateTm(fullRev, naM: naM) : revTm
            let annealingTemp = min(fwdTm, revTm) - 5.0
            let gc = self.gcPercent(amplicon)

            let pcrResult = PCRResult(
                amplicon:       amplicon,
                productSize:    amplicon.count,
                fwdBindPos:     geomFwdPos + 1,
                revBindPos:     geomRevPos + 1,
                fwdAnnealingSeq: geomFwdSeq,
                revAnnealingSeq: geomRevSeq,
                fwdTail:        geomFwdTail,
                revTail:        geomRevTail,
                fwdTm:          fwdTm,
                revTm:          revTm,
                fwdFullTm:      fwdFullTm,
                revFullTm:      revFullTm,
                annealingTemp:  annealingTemp,
                gcPercent:      gc,
                polymerase:     polymeraseVal,
                hasAOverhang:   polymeraseVal == .taq,
                rolesSwapped:   rolesSwapped,
                fwdMismatches:  geomFwdMM,
                revMismatches:  geomRevMM
            )

            DispatchQueue.main.async {
                self.isRunning = false
                self.result    = pcrResult
            }
        }
    }
    
    
    // MARK: - Primer Binding Search
    
    struct BindingResult {
        let position: Int        // 0-based start on the SENSE strand of whichever
                                 // matched (either the primer itself or its revcomp)
        let onSenseStrand: Bool  // true  → primer's literal sequence matches sense
                                 //         (i.e. primer anneals to antisense → primes
                                 //         5'→3' along increasing sense positions)
                                 // false → primer's revcomp matches sense
                                 //         (i.e. primer anneals to sense → primes
                                 //         5'→3' going leftward in sense numbering)
        let mismatches: Int      // 0 = exact match; >0 = tolerated mismatch count
    }

    /// Find where a primer binds on the template, allowing up to maxMismatches.
    /// Tries exact match first; if that fails, slides the primer along the template
    /// to find the best-fitting position within the mismatch budget.
    /// Checks both strands so the user can label primers F/R either way.
    private func findBinding(primer: String, in template: String, circular: Bool, maxMismatches: Int = 0) -> BindingResult? {
        let p   = primer.uppercased()
        let t   = template.uppercased()
        let pRC = reverseComplement(p)

        // Number of 3′-terminal bases that must match the template perfectly.
        // DNA polymerase cannot extend from a mismatched 3′ end.
        let protectedThreePrime = 3

        // Helper: count mismatches between query and template window starting at pos.
        // When onSenseStrand = true,  the 3′ end of the primer is the LAST chars of query.
        // When onSenseStrand = false, the 3′ end of the primer is the FIRST chars of query
        //   (because we're searching for pRC, so 5′ of RC = 3′ of original primer).
        // Returns nil if over budget OR if any 3′-protected base is mismatched.
        func mismatches(of query: String, in text: String, at pos: Int, onSenseStrand: Bool) -> Int? {
            guard pos >= 0, pos + query.count <= text.count else { return nil }
            let qChars = Array(query)
            let tChars = Array(text)
            let qLen   = qChars.count

            // Determine which indices are 3′-protected (must be zero mismatches)
            let protectedRange: Range<Int> = onSenseStrand
                ? max(0, qLen - protectedThreePrime) ..< qLen   // last N bases
                : 0 ..< min(protectedThreePrime, qLen)           // first N bases (= 3′ of original)

            var count = 0
            for i in 0..<qLen {
                if tChars[pos + i] != qChars[i] {
                    if protectedRange.contains(i) { return nil } // 3′ mismatch — disqualify
                    count += 1
                    if count > maxMismatches { return nil }       // over budget — disqualify
                }
            }
            return count
        }

        // Search a given query across the template (optionally doubled for circular).
        // Returns the best (fewest mismatches) BindingResult, or nil if none within budget.
        func bestBinding(query: String, onSenseStrand: Bool, searchText: String, templateLen: Int) -> BindingResult? {
            // Exact match fast path
            if let range = searchText.range(of: query) {
                let pos = searchText.distance(from: searchText.startIndex, to: range.lowerBound)
                if pos < templateLen {
                    return BindingResult(position: pos % templateLen, onSenseStrand: onSenseStrand, mismatches: 0)
                }
            }
            guard maxMismatches > 0 else { return nil }
            // Sliding window
            var best: BindingResult? = nil
            var bestMM = maxMismatches + 1
            for pos in 0...(searchText.count - query.count) {
                guard pos < templateLen else { break }
                if let mm = mismatches(of: query, in: searchText, at: pos, onSenseStrand: onSenseStrand), mm < bestMM {
                    bestMM = mm
                    best = BindingResult(position: pos, onSenseStrand: onSenseStrand, mismatches: mm)
                }
            }
            return best
        }

        let searchText = circular ? t + t : t

        let senseBest = bestBinding(query: p,   onSenseStrand: true,  searchText: searchText, templateLen: t.count)
        let antisBest = bestBinding(query: pRC, onSenseStrand: false, searchText: searchText, templateLen: t.count)

        switch (senseBest, antisBest) {
        case (nil, nil):    return nil
        case (let s?, nil): return s
        case (nil, let a?): return a
        case (let s?, let a?):
            return s.mismatches <= a.mismatches ? s : a
        }
    }
    
    
    // MARK: - Open Amplicon as New Sequence
    
    private func openAmpliconAsSequence() {
        guard let res = result else { return }
        
        let displayAmplicon = res.hasAOverhang ? res.amplicon + "A" : res.amplicon
        let templateName = selectedSequence?.name ?? "template"
        var seqName = "\(templateName) PCR product (\(displayAmplicon.count) bp)"
        if res.hasAOverhang {
            seqName += " [Taq, A-tailed]"
        }
        
        var desc = "PCR product from \(templateName)"
        desc += "\nForward primer: \(res.fwdTail.isEmpty ? "" : res.fwdTail + "-")\(res.fwdAnnealingSeq)"
        desc += "\nReverse primer: \(res.revTail.isEmpty ? "" : res.revTail + "-")\(res.revAnnealingSeq)"
        desc += "\nPolymerase: \(polymerase == .taq ? "Taq (A-tailed, 3′ A overhangs on both strands)" : "Pfu/Phusion (blunt)")"
        
        let newSeq = DNASequence(name: seqName, sequence: displayAmplicon, isCircular: false)
        newSeq.description = desc
        
        // Set 3′ A overhangs as cohesive ends for Taq products
        if res.hasAOverhang {
            newSeq.cohesive5Prime = "A"   // 3′ overhang on antisense strand at 5′ end
            newSeq.cohesive3Prime = "A"   // 3′ overhang on sense strand at 3′ end
        }
        
        sequenceManager.sequences.append(newSeq)
        sequenceManager.currentSequence = newSeq
        SequenceWindowOpener.shared.openSequenceWindow(newSeq.id)
    }
    
    
    // MARK: - Tm Calculation (Serial Cloner 3-tier formula)
    
    private func calculateTm(_ primer: String, naM: Double? = nil) -> Double {
        var gc = 0, at = 0
        for ch in primer.uppercased() {
            switch ch {
            case "G", "C": gc += 1
            case "A", "T": at += 1
            default: break
            }
        }
        let total = gc + at
        guard total > 0 else { return 0 }
        
        let naConc = naM ?? (saltConc / 1000.0)
        let logNa = log10(max(naConc, 0.001))
        
        if total < 14 {
            return Double(at * 2 + gc * 4) - 16.6 * log10(0.050) + 16.6 * logNa
        } else if total <= 51 {
            return 100.5 + 41.0 * Double(gc) / Double(total) - 820.0 / Double(total) + 16.6 * logNa
        } else {
            return 81.5 + 41.0 * Double(gc) / Double(total) - 500.0 / Double(total) + 16.6 * logNa
        }
    }
    
    
    // MARK: - Helpers
    
    private static let complementMap: [Character: Character] = [
        "A": "T", "T": "A", "G": "C", "C": "G",
        "N": "N", "R": "Y", "Y": "R", "S": "S",
        "W": "W", "K": "M", "M": "K", "B": "V",
        "V": "B", "D": "H", "H": "D"
    ]

    private func reverseComplement(_ seq: String) -> String {
        String(seq.uppercased().reversed().map { Self.complementMap[$0] ?? $0 })
    }
    
    private func gcPercent(_ seq: String) -> Double {
        guard !seq.isEmpty else { return 0 }
        var gc = 0
        for ch in seq.uppercased() {
            if ch == "G" || ch == "C" { gc += 1 }
        }
        return Double(gc) / Double(seq.count) * 100.0
    }
    
    private func formatSequence(_ seq: String, lineWidth: Int = 60) -> String {
        var lines: [String] = []
        var i = seq.startIndex
        while i < seq.endIndex {
            let end = seq.index(i, offsetBy: min(lineWidth, seq.distance(from: i, to: seq.endIndex)))
            lines.append(String(seq[i..<end]))
            i = end
        }
        return lines.joined(separator: "\n")
    }
    
    private func copyToClipboard(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedField = label
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { copiedField = nil }
    }
}

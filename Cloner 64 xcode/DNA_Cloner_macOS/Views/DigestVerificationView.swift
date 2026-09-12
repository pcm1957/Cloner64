//
//  DigestVerificationView.swift
//  Cloner 64
//
//  Window that displays verification-digest strategies for a construct.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DigestVerificationView: View {
    let construct: DNASequence
    let parentalVector: DNASequence
    let insertStart: Int
    let insertLength: Int
    
    @State private var orientationMatters: Bool
    @State private var report: String = "Analysing…"
    
    private let analyzer = DigestVerificationAnalyzer()
    private let enzDB = RestrictionEnzymeDatabase.shared
    /// Enzyme list to use — passed in from caller so My Enzymes filter is honoured.
    /// Falls back to the full database if nil (e.g. when opened independently).
    private let enzymesToUse: [RestrictionEnzyme]?

    init(construct: DNASequence, parentalVector: DNASequence,
         insertStart: Int, insertLength: Int, orientationMatters: Bool,
         enzymes: [RestrictionEnzyme]? = nil) {
        self.construct = construct
        self.parentalVector = parentalVector
        self.insertStart = insertStart
        self.insertLength = insertLength
        self._orientationMatters = State(initialValue: orientationMatters)
        self.enzymesToUse = enzymes
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // ── Header ──
            VStack(alignment: .leading, spacing: 4) {
                Text("Verification Digest Strategies")
                    .font(.headline)
                Text(construct.name)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            
            // ── Orientation toggle ──
            HStack(spacing: 8) {
                Toggle(isOn: $orientationMatters) {
                    Text("Insert orientation must be determined")
                        .font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
                .help("Tick if you need to verify which way the insert went in. Untick if orientation is forced by the cloning strategy or doesn't matter.")
                .onChange(of: orientationMatters) { _ in
                    regenerateReport()
                }
                .contextHelp("verify.orientationToggle")
                Spacer()
                Text(orientationMatters
                     ? "→ looking for asymmetric insert-cutters"
                     : "→ looking for flanking diagnostic digests")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            
            // ── Report panel ──
            ScrollView {
                Text(report)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color(NSColor.textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
            )
            
            // ── Action buttons ──
            HStack {
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                }
                .buttonStyle(.bordered)
                .contextHelp("verify.copy")
                
                Button("Save…") {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "\(construct.name) — Verification.txt"
                    panel.allowedContentTypes = [.plainText]
                    if panel.runModal() == .OK, let url = panel.url {
                        try? report.write(to: url, atomically: true, encoding: .utf8)
                    }
                }
                .buttonStyle(.bordered)
                .contextHelp("verify.save")
                
                Button(action: printReport) {
                    Label("Print", systemImage: "printer")
                }
                .buttonStyle(.bordered)
                .contextHelp("verify.print")
            }
        }
        .padding(16)
        .frame(minWidth: 600, minHeight: 500)
        .onAppear { regenerateReport() }
    }
    
    private func regenerateReport() {
        let strategies = analyzer.analyze(
            construct: construct,
            parentalVector: parentalVector,
            insertStart: insertStart,
            insertLength: insertLength,
            orientationMatters: orientationMatters,
            enzymes: enzymesToUse ?? enzDB.enzymes
        )
        let constructInfo = "\(construct.name) — \(construct.sequence.count) bp, \(construct.isCircular ? "circular" : "linear")"
        let insertEnd1 = insertStart + insertLength
        let insertInfo = "\(insertLength) bp at positions \(insertStart + 1)–\(insertEnd1)"
        report = analyzer.formatReport(
            constructInfo: constructInfo,
            insertInfo: insertInfo,
            orientationMatters: orientationMatters,
            strategies: strategies
        )
    }
    
    /// Print the verification report, wrapping text to fit the printable area.
    private func printReport() {
        let printInfo = (NSPrintInfo.shared.copy() as! NSPrintInfo)
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination  = .automatic
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered   = false
        printInfo.topMargin    = 72
        printInfo.bottomMargin = 72
        printInfo.leftMargin   = 72
        printInfo.rightMargin  = 72
        
        let printableWidth  = printInfo.paperSize.width
            - printInfo.leftMargin - printInfo.rightMargin
        let printableHeight = printInfo.paperSize.height
            - printInfo.topMargin  - printInfo.bottomMargin
        
        let textView = NSTextView(frame: NSRect(x: 0, y: 0,
                                                width: printableWidth,
                                                height: printableHeight))
        textView.string = report
        textView.font   = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        textView.isEditable   = false
        textView.isSelectable = true
        textView.textContainerInset = .zero
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize =
            NSSize(width: printableWidth, height: .greatestFiniteMagnitude)
        
        // Lay out the full text so the view height is correct for pagination
        if let lm = textView.layoutManager, let tc = textView.textContainer {
            lm.ensureLayout(for: tc)
            textView.frame.size.height = lm.usedRect(for: tc).height
        }
        
        let printOp = NSPrintOperation(view: textView, printInfo: printInfo)
        printOp.showsPrintPanel    = true
        printOp.showsProgressPanel = true
        printOp.run()
    }
}


// MARK: - Window manager

class DigestVerificationWindowManager {
    static let shared = DigestVerificationWindowManager()
    private var windows: [NSWindow] = []
    private init() {}
    
    func openWindow(
        construct: DNASequence,
        parentalVector: DNASequence,
        insertStart: Int,
        insertLength: Int,
        orientationMatters: Bool,
        enzymes: [RestrictionEnzyme]? = nil
    ) {
        let view = DigestVerificationView(
            construct: construct,
            parentalVector: parentalVector,
            insertStart: insertStart,
            insertLength: insertLength,
            orientationMatters: orientationMatters,
            enzymes: enzymes
        )
        let host = NSHostingController(rootView: view)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        win.title = "Verify Construct — \(construct.name)"
        win.contentViewController = host
        win.setFrameAutosaveName("VerifyConstructconstructname")
        if !win.setFrameUsingName(win.frameAutosaveName) { win.center() }
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 520, height: 400)
        win.makeKeyAndOrderFront(nil)
        windows.append(win)
    }
}

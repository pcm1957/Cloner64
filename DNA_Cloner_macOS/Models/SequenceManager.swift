//
//  SequenceManager.swift
//  Cloner 64
//
import Foundation
import Combine
import UniformTypeIdentifiers
import AppKit
import SwiftUI

class SequenceManager: ObservableObject {
    @Published var sequences: [DNASequence] = []
    @Published var currentSequence: DNASequence?
    private var currentSequenceSubscription: AnyCancellable?
    
    // Protein sequences (loaded from XPRT, protein FASTA, etc.)
    @Published var proteinSequences: [ProteinSequence] = []
    @Published var currentProtein: ProteinSequence?
    private var currentProteinSubscription: AnyCancellable?
    
    private var forwardingCancellables = Set<AnyCancellable>()
    
    // Track the active DNA sequence selection so translate can access it
    // NOT @Published — these change on every cursor move and would cause
    // constant menu bar re-renders if observed by SwiftUI
    var selectionStart: Int = 0
    var selectionEnd: Int = 0
    
    // Option to convert imported XDNA sequences to uppercase
    // Default: FALSE to preserve mixed case (exons=uppercase, introns=lowercase)
    @Published var convertXDNAToUppercase: Bool = false
    
    init() {
        // Listen for fragment creation requests from graphical map
        NotificationCenter.default.addObserver(
            forName: .createSequenceFromFragment,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let info = notification.userInfo,
                  let name = info["name"] as? String,
                  let seq = info["sequence"] as? String else { return }
            let isCircular = info["isCircular"] as? Bool ?? false
            let newSeq = DNASequence(name: name, sequence: seq, isCircular: isCircular)
            // Apply cohesive end overhangs if present
            if let oh5 = info["cohesive5Prime"] as? String { newSeq.cohesive5Prime = oh5 }
            if let oh3 = info["cohesive3Prime"] as? String { newSeq.cohesive3Prime = oh3 }
            self.sequences.append(newSeq)
            self.currentSequence = newSeq
            SequenceWindowOpener.shared.openSequenceWindow(newSeq.id)
        }
        
        // Forward changes from the inner DNASequence up to SequenceManager.
        // Without this, menus that observe sequenceManager (like the Tools
        // menu strand picker) don't redraw when properties INSIDE the
        // current sequence change — they only see currentSequence being
        // reassigned, not its inner @Published changing.
        // We do this via a Combine pipeline rather than a didSet block because
        // didSet on a @Published var is unreliable across Swift versions
        // (the property wrapper can intercept the setter).
        $currentSequence
            .sink { [weak self] newSeq in
                guard let self = self else { return }
                self.currentSequenceSubscription = newSeq?.objectWillChange
                    .sink { [weak self] in
                        self?.objectWillChange.send()
                    }
            }
            .store(in: &forwardingCancellables)
        
        $currentProtein
            .sink { [weak self] newProt in
                guard let self = self else { return }
                self.currentProteinSubscription = newProt?.objectWillChange
                    .sink { [weak self] in
                        self?.objectWillChange.send()
                    }
            }
            .store(in: &forwardingCancellables)
        
        // Keep currentSequence (and currentProtein) in sync with whichever
        // sequence window is currently main. This fires OUTSIDE SwiftUI view
        // evaluation, so it's safe to mutate @Published properties from here
        // — unlike doing the same lookup inside a Picker binding, which
        // produces "Publishing changes from within view updates" warnings.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let window = notification.object as? NSWindow else { return }
            let title = window.title
            // Try DNA sequences first (exact match, then longest substring match)
            if let exact = self.sequences.first(where: { $0.name == title }) {
                self.currentSequence = exact
                return
            }
            let dnaCandidates = self.sequences.filter { !$0.name.isEmpty && title.contains($0.name) }
            if let best = dnaCandidates.max(by: { $0.name.count < $1.name.count }) {
                self.currentSequence = best
                return
            }
            // Then proteins
            if let exactP = self.proteinSequences.first(where: { $0.name == title }) {
                self.currentProtein = exactP
                return
            }
            let protCandidates = self.proteinSequences.filter { !$0.name.isEmpty && title.contains($0.name) }
            if let bestP = protCandidates.max(by: { $0.name.count < $1.name.count }) {
                self.currentProtein = bestP
            }
        }
    }
    
    func createNewSequence() {
        let newSeq = DNASequence(name: "Untitled Sequence \(sequences.count + 1)")
        sequences.append(newSeq)
        currentSequence = newSeq
        SequenceWindowOpener.shared.openSequenceWindow(newSeq.id)
    }
    
    func pasteAsNewSequence() {
        guard let clipboardString = NSPasteboard.general.string(forType: .string),
              !clipboardString.isEmpty else { return }
        
        // Filter to just valid DNA characters
        let validChars = Set("ATCGatcgNnRrYySsWwKkMmBbDdHhVv")
        let cleanedSequence = String(clipboardString.filter { validChars.contains($0) })
        
        guard !cleanedSequence.isEmpty else { return }
        
        let newSeq = DNASequence(name: "Pasted Sequence \(sequences.count + 1)", sequence: cleanedSequence, isCircular: false)
        sequences.append(newSeq)
        currentSequence = newSeq
        SequenceWindowOpener.shared.openSequenceWindow(newSeq.id)
    }
    
    func selectSequence(_ sequence: DNASequence) {
        currentSequence = sequence
    }
    
    func deleteSequence(_ sequence: DNASequence) {
        sequences.removeAll { $0.id == sequence.id }
        if currentSequence?.id == sequence.id {
            currentSequence = sequences.first
        }
    }
    
    // MARK: - File Operations
    
    func openSequence() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "xdna") ?? .plainText,
            UTType(filenameExtension: "xprt") ?? .plainText,
            UTType(filenameExtension: "dna") ?? .plainText,
            UTType(filenameExtension: "ape") ?? .plainText,
            UTType(filenameExtension: "fasta") ?? .plainText,
            UTType(filenameExtension: "fa") ?? .plainText,
            UTType(filenameExtension: "gb") ?? .plainText,
            UTType(filenameExtension: "gbk") ?? .plainText,
            .plainText,
            .data  // Allow any file — we'll sniff the content
        ]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        
        // Use a free-standing modal panel rather than a window-attached sheet.
        // beginSheetModal(for: keyWindow) made the panel depend on whatever
        // happened to be the key window when Open… was invoked. When that key
        // window was a tool/utility window (or briefly nil), the panel attached
        // awkwardly and its file-list double-click was sometimes swallowed —
        // the intermittent "double-click does nothing" symptom. panel.begin
        // floats the panel independently and handles double-click consistently.
        panel.begin { response in
            if response == .OK {
                for (index, url) in panel.urls.enumerated() {
                    let delay = Double(index) * 1.2
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        self.loadSequenceFromFile(url)
                    }
                }
            }
        }
    }
    
    func loadSequenceFromFile(_ url: URL) {
        #if DEBUG
        print("📂 Loading file: \(url.lastPathComponent)")
        print("   Extension: \(url.pathExtension)")
        #endif

        let convertToUppercase = self.convertXDNAToUppercase

        DispatchQueue.global(qos: .userInitiated).async {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let ext = url.pathExtension.lowercased()
            let filename = url.deletingPathExtension().lastPathComponent

            let knownTextExtensions = ["fasta", "fa", "gb", "gbk", "genbank", "ape", "txt", "seq", "dna"]
            let shouldTryBinary = (ext == "xdna") || (ext == "xprt") || (ext == "dna") || !knownTextExtensions.contains(ext)

            if shouldTryBinary {

                if ext == "dna" {
                    if let data = try? Data(contentsOf: url), SnapGeneParser.isSnapGeneFile(data) {
                        let parser = SnapGeneParser()
                        if let sequence = parser.parseSnapGeneData(data, filename: filename) {
                            DispatchQueue.main.async {
                                self.sequences.append(sequence)
                                self.currentSequence = sequence
                                RecentFilesManager.shared.addRecent(url)
                                SequenceWindowOpener.shared.openSequenceWindow(sequence.id)
                                sequence.markCleanAfterLoad()
                                #if DEBUG
                                print("   ✅ SnapGene loaded successfully")
                                #endif
                            }
                            return
                        }
                    }
                    #if DEBUG
                    print("   ℹ️ .dna file is not SnapGene binary — trying text parsers")
                    #endif
                }

                if ext != "xdna" && ext != "xprt" {
                    if let data = try? Data(contentsOf: url), SnapGeneParser.isSnapGeneFile(data) {
                        let parser = SnapGeneParser()
                        if let sequence = parser.parseSnapGeneData(data, filename: filename) {
                            DispatchQueue.main.async {
                                self.sequences.append(sequence)
                                self.currentSequence = sequence
                                RecentFilesManager.shared.addRecent(url)
                                SequenceWindowOpener.shared.openSequenceWindow(sequence.id)
                                sequence.markCleanAfterLoad()
                                #if DEBUG
                                print("   ✅ SnapGene loaded successfully (detected by magic bytes)")
                                #endif
                            }
                            return
                        }
                    }
                }

                let parser = XDNAParser()

                if ext == "xprt" {
                    if let protein = parser.parseXPRT(url) {
                        protein.sourceURL = url
                        DispatchQueue.main.async {
                            self.proteinSequences.append(protein)
                            self.currentProtein = protein
                            self.currentSequence = nil
                            RecentFilesManager.shared.addRecent(url)
                            ProteinWindowOpener.shared.openProteinWindow(protein.id)
                            protein.isDirty = false
                            #if DEBUG
                            print("   ✅ XPRT protein loaded successfully")
                            #endif
                        }
                    } else {
                        #if DEBUG
                        print("   ❌ XPRT parsing failed")
                        #endif
                    }
                    return
                }

                parser.convertToUppercaseOnImport = convertToUppercase
                if let sequence = parser.parseXDNA(url) {
                    sequence.sourceURL = url
                    DispatchQueue.main.async {
                        self.sequences.append(sequence)
                        self.currentSequence = sequence
                        RecentFilesManager.shared.addRecent(url)
                        SequenceWindowOpener.shared.openSequenceWindow(sequence.id)
                        sequence.markCleanAfterLoad()
                        #if DEBUG
                        print("   ✅ XDNA loaded successfully")
                        #endif
                    }
                    return
                }
                if ext == "xdna" {
                    #if DEBUG
                    print("   ❌ Binary parsing failed")
                    #endif
                    return
                }
                #if DEBUG
                print("   ℹ️ Not XDNA/XPRT binary, trying text formats...")
                #endif
            }

            do {
                let content: String
                if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
                    content = utf8
                } else if let isoLatin1 = try? String(contentsOf: url, encoding: .isoLatin1) {
                    content = isoLatin1
                    #if DEBUG
                    print("   ℹ️ Read with ISO Latin-1 fallback")
                    #endif
                } else if let winLatin1 = try? String(contentsOf: url, encoding: .windowsCP1252) {
                    content = winLatin1
                    #if DEBUG
                    print("   ℹ️ Read with Windows-1252 fallback")
                    #endif
                } else if let macRoman = try? String(contentsOf: url, encoding: .macOSRoman) {
                    content = macRoman
                    #if DEBUG
                    print("   ℹ️ Read with MacRoman fallback")
                    #endif
                } else {
                    let data = try Data(contentsOf: url)
                    content = String(decoding: data, as: UTF8.self)
                    #if DEBUG
                    print("   ⚠️ Read with lossy UTF-8")
                    #endif
                }
                #if DEBUG
                print("   File read successfully, \(content.count) characters")
                #endif

                if ext == "fasta" || ext == "fa" || content.hasPrefix(">") {
                    #if DEBUG
                    print("   Detected as FASTA format")
                    #endif
                    if let sequence = self.parseFASTA(content) {
                        sequence.sourceURL = url
                        DispatchQueue.main.async {
                            self.sequences.append(sequence)
                            self.currentSequence = sequence
                            RecentFilesManager.shared.addRecent(url)
                            SequenceWindowOpener.shared.openSequenceWindow(sequence.id)
                            sequence.markCleanAfterLoad()
                            #if DEBUG
                            print("   ✅ FASTA loaded successfully")
                            #endif
                        }
                    } else {
                        #if DEBUG
                        print("   ❌ FASTA parsing failed")
                        #endif
                        self.showOpenErrorAlert(url: url,
                            message: "Cloner 64 could not parse this FASTA file.",
                            detail: "The file was recognised as FASTA but no sequence could be extracted.")
                    }

                } else if ext == "gb" || ext == "gbk" || ext == "genbank" || ext == "ape"
                            || content.hasPrefix("LOCUS") {
                    #if DEBUG
                    print("   Detected as GenBank/APE format")
                    #endif
                    if let sequence = self.parseGenBank(content) {
                        sequence.sourceURL = url
                        DispatchQueue.main.async {
                            self.sequences.append(sequence)
                            self.currentSequence = sequence
                            RecentFilesManager.shared.addRecent(url)
                            SequenceWindowOpener.shared.openSequenceWindow(sequence.id)
                            sequence.markCleanAfterLoad()
                            #if DEBUG
                            print("   ✅ GenBank loaded successfully")
                            #endif
                        }
                    } else {
                        #if DEBUG
                        print("   ❌ GenBank parsing failed")
                        #endif
                        self.showOpenErrorAlert(url: url,
                            message: "Cloner 64 could not parse this GenBank file.",
                            detail: "The file was recognised as GenBank format but no sequence could be extracted. The file may be malformed or empty, or may be missing an ORIGIN section.")
                    }

                } else {
                    if let sequence = self.parseGenBank(content) {
                        sequence.sourceURL = url
                        DispatchQueue.main.async {
                            self.sequences.append(sequence)
                            self.currentSequence = sequence
                            RecentFilesManager.shared.addRecent(url)
                            SequenceWindowOpener.shared.openSequenceWindow(sequence.id)
                            sequence.markCleanAfterLoad()
                            #if DEBUG
                            print("   ✅ Loaded as GenBank (content sniffing)")
                            #endif
                        }
                    } else if let sequence = self.parseFASTA(content) {
                        sequence.sourceURL = url
                        DispatchQueue.main.async {
                            self.sequences.append(sequence)
                            self.currentSequence = sequence
                            RecentFilesManager.shared.addRecent(url)
                            SequenceWindowOpener.shared.openSequenceWindow(sequence.id)
                            sequence.markCleanAfterLoad()
                            #if DEBUG
                            print("   ✅ Loaded as FASTA (content sniffing)")
                            #endif
                        }
                    } else {
                        #if DEBUG
                        print("   ❌ Unknown file format: .\(url.pathExtension)")
                        #endif
                        self.showOpenErrorAlert(url: url,
                            message: "Cloner 64 could not recognise the contents of this file.",
                            detail: "The file does not appear to be in XDNA, XPRT, SnapGene, FASTA, GenBank, or APE format.")
                    }
                }
            } catch {
                let capturedError = error
                self.showOpenErrorAlert(url: url,
                    message: "Cloner 64 could not open this file.",
                    detail: capturedError.localizedDescription)
            }
        }
    }
    
    /// Displays a modal alert describing why a file could not be opened.
    private func showOpenErrorAlert(url: URL, message: String, detail: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = message
            alert.informativeText = "File: \(url.lastPathComponent)\n\n\(detail)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
    
    /// Open a sequence from a known URL (used by Open Recent and AppDelegate)
    func openSequenceFromURL(_ url: URL) {
        // Check if this file is already loaded (avoid duplicate windows).
        // Compare by RESOLVED FILE PATH (not URL equality) so that symlink
        // resolution, trailing slashes, file-reference vs path URLs, and
        // bookmark-resolved URLs all match correctly. macOS file systems are
        // case-insensitive by default, so we compare lowercase.
        let targetPath = url.resolvingSymlinksInPath().path.lowercased()
        
        if let existing = sequences.first(where: {
            $0.sourceURL?.resolvingSymlinksInPath().path.lowercased() == targetPath
        }) {
            currentSequence = existing
            bringExistingWindowForward(named: existing.name, fallbackID: existing.id, isProtein: false)
            return
        }
        
        if let existingProt = proteinSequences.first(where: {
            $0.sourceURL?.resolvingSymlinksInPath().path.lowercased() == targetPath
        }) {
            currentProtein = existingProt
            bringExistingWindowForward(named: existingProt.name, fallbackID: existingProt.id, isProtein: true)
            return
        }
        
        loadSequenceFromFile(url)
    }
    
    /// Brings an already-open sequence window directly to the front via AppKit,
    /// bypassing SequenceWindowOpener entirely. We do this because the opener's
    /// backstop notification ends up calling SwiftUI's openWindow(id:value:)
    /// twice for the same id, which causes WindowGroup to create a DUPLICATE
    /// window rather than just refront the existing one. Falls back to the
    /// SwiftUI opener if no matching AppKit window is found.
    private func bringExistingWindowForward(named name: String, fallbackID: UUID, isProtein: Bool) {
        let matched = NSApp.windows.first { window in
            guard window.isVisible else { return false }
            let title = window.title
            return title == name || title.contains(name)
        }
        
        if let window = matched {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // Couldn't find an AppKit window — fall back to the SwiftUI opener.
            // Shouldn't happen in normal use but keeps the sequence reachable.
            if isProtein {
                ProteinWindowOpener.shared.openProteinWindow(fallbackID)
            } else {
                SequenceWindowOpener.shared.openSequenceWindow(fallbackID)
            }
        }
    }
    
    @MainActor
    func exportAsFASTA() {
        guard let sequence = currentSequence else { return }
        
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(sequence.name).fasta"
        panel.allowedContentTypes = [UTType(filenameExtension: "fasta") ?? .plainText]
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                let fasta = self.generateFASTA(sequence)
                try? fasta.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
    
    @MainActor
    func exportAsGenBank() {
        guard let sequence = currentSequence else { return }
        
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(sequence.name).gb"
        panel.allowedContentTypes = [UTType(filenameExtension: "gb") ?? .plainText]
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                let genbank = self.generateGenBank(sequence)
                try? genbank.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
    
    @MainActor
    func exportAsXDNA() {
        guard let sequence = currentSequence else { return }
        
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(sequence.name).xdna"
        panel.allowedContentTypes = [UTType(filenameExtension: "xdna") ?? .data]
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                let parser = XDNAParser()
                _ = parser.writeXDNA(sequence, to: url)
            }
        }
    }
    
    @MainActor
    func exportAsAPE() {
        guard let sequence = currentSequence else { return }
        
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(sequence.name).ape"
        panel.allowedContentTypes = [UTType(filenameExtension: "ape") ?? .plainText]
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                let genbank = self.generateGenBank(sequence)
                try? genbank.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
    
    // MARK: - Protein File Operations
    
    /// Open a protein sequence file (.xprt or protein FASTA)
    @MainActor
    func openProteinSequence() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "xprt") ?? .data,
            UTType(filenameExtension: "fasta") ?? .plainText,
            UTType(filenameExtension: "fa") ?? .plainText,
            .data
        ]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        
        if let window = NSApplication.shared.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK {
                    for url in panel.urls {
                        self.loadSequenceFromFile(url)
                    }
                }
            }
        } else {
            panel.begin { response in
                if response == .OK {
                    for url in panel.urls {
                        self.loadSequenceFromFile(url)
                    }
                }
            }
        }
    }
    
    /// Save a protein sequence back to its source file
    @MainActor
    func saveProtein(_ protein: ProteinSequence) {
        guard let url = protein.sourceURL else {
            saveProteinAs(protein)
            return
        }
        
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        
        let parser = XDNAParser()
        if parser.writeXPRT(protein, to: url) {
            protein.isDirty = false
            #if DEBUG
            print("\u{2705} Saved protein \(protein.name) to \(url.lastPathComponent)")
            #endif
        }
    }
    
    /// Save As for a protein sequence
    @MainActor
    func saveProteinAs(_ protein: ProteinSequence) {
        let panel = NSSavePanel()
        let ext = protein.sourceURL?.pathExtension.lowercased() ?? "xprt"
        panel.nameFieldStringValue = "\(protein.name).\(ext)"
        panel.allowedContentTypes = [
            UTType(filenameExtension: "xprt") ?? .data,
            UTType(filenameExtension: "fasta") ?? .plainText
        ]
        
        if let window = NSApplication.shared.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url {
                    self.writeProteinToURL(protein, url: url)
                    protein.sourceURL = url
                    RecentFilesManager.shared.addRecent(url)
                }
            }
        } else {
            panel.begin { response in
                if response == .OK, let url = panel.url {
                    self.writeProteinToURL(protein, url: url)
                    protein.sourceURL = url
                    RecentFilesManager.shared.addRecent(url)
                }
            }
        }
    }
    
    /// Export a protein as FASTA
    @MainActor
    func exportProteinAsFASTA(_ protein: ProteinSequence) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(protein.name).fasta"
        panel.allowedContentTypes = [UTType(filenameExtension: "fasta") ?? .plainText]
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                var fasta = ">\(protein.name)"
                if !protein.description.isEmpty {
                    fasta += " \(protein.description)"
                }
                fasta += "\n"
                let seq = protein.sequence
                var i = seq.startIndex
                while i < seq.endIndex {
                    let end = seq.index(i, offsetBy: 60, limitedBy: seq.endIndex) ?? seq.endIndex
                    fasta += seq[i..<end] + "\n"
                    i = end
                }
                try? fasta.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
    
    /// Write a protein to a URL based on file extension
    private func writeProteinToURL(_ protein: ProteinSequence, url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        
        let ext = url.pathExtension.lowercased()
        do {
            switch ext {
            case "fasta", "fa":
                var fasta = ">\(protein.name)\n"
                let seq = protein.sequence
                var i = seq.startIndex
                while i < seq.endIndex {
                    let end = seq.index(i, offsetBy: 60, limitedBy: seq.endIndex) ?? seq.endIndex
                    fasta += seq[i..<end] + "\n"
                    i = end
                }
                try fasta.write(to: url, atomically: true, encoding: .utf8)
            default:
                // Default to XPRT
                let parser = XDNAParser()
                _ = parser.writeXPRT(protein, to: url)
            }
            protein.isDirty = false
            #if DEBUG
            print("\u{2705} Saved protein \(protein.name) to \(url.lastPathComponent)")
            #endif
        } catch {
            #if DEBUG
            print("\u{274C} Error saving protein: \(error)")
            #endif
        }
    }
    
    // MARK: - Save
    
    /// Save the current sequence back to its original file location.
    /// If no sourceURL exists (new sequence), falls through to Save As.
    @MainActor
    func saveSequence() {
        guard let sequence = currentSequence else { return }
        
        guard let url = sequence.sourceURL else {
            // No existing file — behave like Save As
            saveSequenceAs()
            return
        }
        
        writeSequenceToURL(sequence, url: url)
    }
    
    /// Save As — always shows a save panel; always saves in native XDNA format.
    /// Use Export functions to write FASTA, GenBank, or APE copies.
    @MainActor
    func saveSequenceAs() {
        guard let sequence = currentSequence else { return }
        
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(sequence.name).xdna"
        panel.allowedContentTypes = [UTType(filenameExtension: "xdna") ?? .data]
        
        if let window = NSApplication.shared.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url {
                    self.writeSequenceToURL(sequence, url: url)
                    sequence.sourceURL = url
                    RecentFilesManager.shared.addRecent(url)
                }
            }
        } else {
            panel.begin { response in
                if response == .OK, let url = panel.url {
                    self.writeSequenceToURL(sequence, url: url)
                    sequence.sourceURL = url
                    RecentFilesManager.shared.addRecent(url)
                }
            }
        }
    }
    
    /// Write a sequence to a URL, choosing format based on file extension
    private func writeSequenceToURL(_ sequence: DNASequence, url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        
        let ext = url.pathExtension.lowercased()
        do {
            switch ext {
            case "xdna":
                let parser = XDNAParser()
                _ = parser.writeXDNA(sequence, to: url)
            case "fasta", "fa":
                let fasta = generateFASTA(sequence)
                try fasta.write(to: url, atomically: true, encoding: .utf8)
            case "gb", "gbk", "genbank", "ape":
                let genbank = generateGenBank(sequence)
                try genbank.write(to: url, atomically: true, encoding: .utf8)
            default:
                // Default to XDNA for unknown extensions
                let parser = XDNAParser()
                _ = parser.writeXDNA(sequence, to: url)
            }
            #if DEBUG
            print("✅ Saved \(sequence.name) to \(url.lastPathComponent)")
            #endif
            // Mark clean after a successful save.
            // (markCleanAfterLoad() suppresses Combine events for one tick — that is
            // only appropriate during file loading.  After a save we simply clear the flag.)
            sequence.isDirty = false
        } catch {
            #if DEBUG
            print("❌ Error saving: \(error)")
            #endif
        }
    }
    
    // MARK: - Print & Page Setup
    
    @MainActor
    func pageSetup() {
        let printInfo = NSPrintInfo.shared
        let pageSetup = NSPageLayout()
        if let window = NSApplication.shared.keyWindow {
            pageSetup.beginSheet(with: printInfo, modalFor: window, delegate: nil, didEnd: nil, contextInfo: nil)
        } else {
            pageSetup.runModal(with: printInfo)
        }
    }
    
    @MainActor
    func printSequence() {
        guard let sequence = currentSequence else { return }
        
        // Build a simple formatted text representation for printing
        let header = "\(sequence.name)  —  \(sequence.length) bp, \(sequence.isCircular ? "circular" : "linear")\n\n"
        
        let seq = sequence.sequence
        var body = ""
        let charsPerLine = 60
        let groupSize = 10
        
        for i in stride(from: 0, to: seq.count, by: charsPerLine) {
            let lineNum = String(format: "%6d  ", i + 1)
            let startIdx = seq.index(seq.startIndex, offsetBy: i)
            let endIdx = seq.index(startIdx, offsetBy: min(charsPerLine, seq.count - i))
            let lineSeq = String(seq[startIdx..<endIdx])
            
            // Group in blocks of 10
            var groups: [String] = []
            for j in stride(from: 0, to: lineSeq.count, by: groupSize) {
                let gStart = lineSeq.index(lineSeq.startIndex, offsetBy: j)
                let gEnd = lineSeq.index(gStart, offsetBy: min(groupSize, lineSeq.count - j))
                groups.append(String(lineSeq[gStart..<gEnd]))
            }
            body += lineNum + groups.joined(separator: " ") + "\n"
        }
        
        let fullText = header + body
        
        // Create an NSTextView for printing
        let printInfo = NSPrintInfo.shared
        let margins = printInfo.imageablePageBounds
        let printableWidth = margins.width
        let printableHeight = margins.height
        
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: printableWidth, height: printableHeight))
        textView.isEditable = false
        textView.isSelectable = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        textView.string = fullText
        textView.sizeToFit()
        
        let printOp = NSPrintOperation(view: textView, printInfo: printInfo)
        printOp.showsPrintPanel = true
        printOp.showsProgressPanel = true
        
        if let window = NSApplication.shared.keyWindow {
            printOp.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            printOp.run()
        }
    }
    
    // MARK: - Parsing
    
    func parseFASTA(_ content: String) -> DNASequence? {
        #if DEBUG
        print("📄 Parsing FASTA file...")
        print("   Content length: \(content.count) characters")
        #endif
        
        var name = "Untitled"
        var sequence = ""
        var description = ""
        var hasHeader = false
        
        // Characters accepted as valid sequence bases (DNA/RNA + IUPAC ambiguity codes, both cases)
        let validSequenceChars: Set<Character> = Set("ACGTURYSWKMBDHVNacgturyswkmbdhvn")
        
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            if trimmed.hasPrefix(">") {
                hasHeader = true
                let headerContent = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                let parts = headerContent.components(separatedBy: " ")
                
                if !parts.isEmpty {
                    name = parts[0]
                }
                if parts.count > 1 {
                    description = parts.dropFirst().joined(separator: " ")
                }
                #if DEBUG
                print("   Found header: \(name)")
                #endif
            } else {
                // Filter to valid bases only — guards against position numbers, semicolons,
                // or other non-sequence characters that some tools embed in FASTA body lines.
                sequence += trimmed.filter { validSequenceChars.contains($0) }
            }
        }
        
        if !hasHeader && !sequence.isEmpty {
            #if DEBUG
            print("   ℹ️  No header found, using default name")
            #endif
            name = "Imported_Sequence"
        }
        
        #if DEBUG
        print("   Sequence length before filter: \(sequence.count) characters")
        #endif
        
        guard !sequence.isEmpty else {
            #if DEBUG
            print("   ❌ No sequence found!")
            #endif
            return nil
        }
        
        let dnaSeq = DNASequence(name: name, sequence: sequence)
        dnaSeq.description = description
        
        #if DEBUG
        print("   Sequence length after filter: \(dnaSeq.length) bp")
        print("   ✅ FASTA parsed successfully: \(name), \(dnaSeq.length) bp")
        #endif
        return dnaSeq
    }
    
    func parseGenBank(_ content: String) -> DNASequence? {
        #if DEBUG
        print("📄 Parsing GenBank file...")
        #endif
        
        var name = "Untitled"
        var sequence = ""
        var isCircular = false
        var descriptionText = ""
        var features: [Feature] = []
        
        let lines = content.components(separatedBy: .newlines)
        
        // Track parsing state
        enum ParseSection { case header, features, origin }
        var section: ParseSection = .header
        
        // Feature accumulation
        var currentFeatureKey = ""
        var currentLocationStr = ""
        var currentQualifiers: [(String, String)] = []  // (key, value)
        var currentQualifierKey = ""
        var currentQualifierValue = ""
        var inMultiLineQualifier = false
        var continuingDescription = false
        
        // Helper: finalize a qualifier being accumulated
        func finalizeQualifier() {
            if !currentQualifierKey.isEmpty {
                currentQualifiers.append((currentQualifierKey, currentQualifierValue))
            }
            currentQualifierKey = ""
            currentQualifierValue = ""
            inMultiLineQualifier = false
        }
        
        // Helper: finalize a feature being accumulated
        func finalizeFeature() {
            finalizeQualifier()
            
            guard !currentFeatureKey.isEmpty else { return }
            
            // Skip "source" features — they describe the whole sequence, not an annotation
            if currentFeatureKey.lowercased() == "source" {
                currentFeatureKey = ""
                currentLocationStr = ""
                currentQualifiers = []
                return
            }
            
            // Parse location
            let (start, end, strand) = parseGenBankLocation(currentLocationStr)
            // start is now 0-based; end is 1-based. 0 is a valid start (first base of sequence).
            // Only reject if end is non-positive (truly unparseable location).
            guard start >= 0, end > 0 else {
                #if DEBUG
                print("   ⚠️  Skipping feature '\(currentFeatureKey)': invalid location '\(currentLocationStr)'")
                #endif
                currentFeatureKey = ""
                currentLocationStr = ""
                currentQualifiers = []
                return
            }
            
            // Determine feature name from qualifiers (priority: label > gene > product > note > key)
            let featureName = resolveFeatureName(qualifiers: currentQualifiers, fallback: currentFeatureKey)
            
            // Map GenBank feature key to app's FeatureType
            let featureType = mapGenBankFeatureType(currentFeatureKey)
            
            // Resolve color from qualifiers
            let color = resolveFeatureColor(qualifiers: currentQualifiers, featureType: featureType)
            
            let feature = Feature(
                name: featureName,
                type: featureType,
                start: start,
                end: end,
                strand: strand,
                color: color
            )
            features.append(feature)
            
            #if DEBUG
            print("   ✅ Feature: \(featureName) [\(currentFeatureKey)] \(start)..\(end) \(strand == .reverse ? "complement" : "forward")")
            #endif
            
            // Reset
            currentFeatureKey = ""
            currentLocationStr = ""
            currentQualifiers = []
        }
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            switch section {
            case .header:
                if trimmed.hasPrefix("LOCUS") {
                    // Parse LOCUS line: name, length, topology
                    let components = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    if components.count > 1 {
                        name = components[1]
                    }
                    let locusLower = trimmed.lowercased()
                    if locusLower.contains("circular") {
                        isCircular = true
                    } else if locusLower.contains("linear") {
                        isCircular = false
                    }
                    continuingDescription = false
                    
                } else if trimmed.hasPrefix("DEFINITION") {
                    descriptionText = String(trimmed.dropFirst(10)).trimmingCharacters(in: .whitespaces)
                    // Remove trailing period if present
                    if descriptionText.hasSuffix(".") {
                        descriptionText = String(descriptionText.dropLast())
                    }
                    continuingDescription = true
                    
                } else if continuingDescription && !trimmed.hasPrefix("ACCESSION") && !trimmed.hasPrefix("VERSION")
                            && !trimmed.hasPrefix("KEYWORDS") && !trimmed.hasPrefix("SOURCE")
                            && !trimmed.hasPrefix("FEATURES") && !trimmed.hasPrefix("ORIGIN") {
                    // Multi-line DEFINITION continuation
                    if line.hasPrefix("            ") || line.hasPrefix("           ") {
                        var contText = trimmed
                        if contText.hasSuffix(".") { contText = String(contText.dropLast()) }
                        descriptionText += " " + contText
                    } else {
                        continuingDescription = false
                    }
                    
                } else if trimmed.hasPrefix("FEATURES") {
                    section = .features
                    continuingDescription = false
                    #if DEBUG
                    print("   Entering FEATURES section")
                    #endif
                    
                } else if trimmed.hasPrefix("ORIGIN") {
                    section = .origin
                    continuingDescription = false
                    
                } else {
                    continuingDescription = false
                }
                
            case .features:
                if trimmed.hasPrefix("ORIGIN") {
                    // End of features, start of sequence
                    finalizeFeature()
                    section = .origin
                    continue
                }
                
                if trimmed == "//" {
                    finalizeFeature()
                    section = .header
                    continue
                }
                
                // GenBank FEATURES format is column-based:
                //   Columns 1-5: blank
                //   Column 6-20: feature key (for new features)
                //   Column 22+: location or qualifier
                //
                // New feature: line has non-space at column 6 (index 5)
                // Qualifier: line starts with spaces then /
                // Continuation: line starts with spaces (no /)
                
                let rawLine = line
                let paddedLine = rawLine.count < 22 ? rawLine + String(repeating: " ", count: 22 - rawLine.count) : rawLine
                
                // Check if this is a new feature key (non-space character at position 5)
                if rawLine.count >= 6 {
                    let idx5 = rawLine.index(rawLine.startIndex, offsetBy: 5)
                    let charAtCol6 = rawLine[idx5]
                    
                    if !charAtCol6.isWhitespace && charAtCol6 != "/" {
                        // This is a new feature — finalize previous one
                        finalizeFeature()
                        
                        // Parse the feature key and location
                        let featurePart = String(paddedLine.prefix(21)).trimmingCharacters(in: .whitespaces)
                        let locationPart: String
                        if paddedLine.count > 21 {
                            locationPart = String(paddedLine.dropFirst(21)).trimmingCharacters(in: .whitespaces)
                        } else {
                            locationPart = ""
                        }
                        
                        currentFeatureKey = featurePart
                        currentLocationStr = locationPart
                        currentQualifiers = []
                        continue
                    }
                }
                
                // Check if this is a qualifier line (starts with /)
                if trimmed.hasPrefix("/") {
                    finalizeQualifier()
                    
                    // Parse qualifier: /key="value" or /key=value or /key
                    let qualContent = String(trimmed.dropFirst()) // remove leading /
                    
                    if let eqIdx = qualContent.firstIndex(of: "=") {
                        currentQualifierKey = String(qualContent[qualContent.startIndex..<eqIdx]).lowercased()
                        var val = String(qualContent[qualContent.index(after: eqIdx)...])
                        
                        // Remove leading quote
                        if val.hasPrefix("\"") {
                            val = String(val.dropFirst())
                        }
                        // Check if value is complete (ends with quote)
                        if val.hasSuffix("\"") {
                            val = String(val.dropLast())
                            currentQualifierValue = val
                            inMultiLineQualifier = false
                        } else {
                            currentQualifierValue = val
                            inMultiLineQualifier = true
                        }
                    } else {
                        // Flag qualifier (no value), e.g. /pseudo
                        currentQualifierKey = qualContent.lowercased()
                        currentQualifierValue = "true"
                        inMultiLineQualifier = false
                    }
                    continue
                }
                
                // Continuation line
                if inMultiLineQualifier {
                    var val = trimmed
                    if val.hasSuffix("\"") {
                        val = String(val.dropLast())
                        inMultiLineQualifier = false
                    }
                    // For translation qualifiers, don't add space (amino acids are continuous)
                    if currentQualifierKey == "translation" {
                        currentQualifierValue += val
                    } else {
                        currentQualifierValue += " " + val
                    }
                } else if !currentLocationStr.isEmpty && (trimmed.first?.isLetter == true || trimmed.first == "(" || trimmed.first?.isNumber == true) {
                    // Could be a continuation of a multi-line location
                    currentLocationStr += trimmed
                }
                
            case .origin:
                if trimmed == "//" {
                    section = .header
                    continue
                }
                // Extract sequence: skip line numbers, keep only letters
                let seqPart = trimmed.components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty && $0.first?.isNumber == false }
                    .joined()
                sequence += seqPart
            }
        }
        
        // Finalize any remaining feature
        if section == .features {
            finalizeFeature()
        }
        
        guard !sequence.isEmpty else {
            #if DEBUG
            print("   ❌ No sequence found in GenBank file")
            #endif
            return nil
        }
        
        let dnaSeq = DNASequence(name: name, sequence: sequence, isCircular: isCircular)
        dnaSeq.description = descriptionText
        dnaSeq.features = features
        
        #if DEBUG
        print("   📊 GenBank parsed: \(name), \(dnaSeq.length) bp, \(isCircular ? "circular" : "linear"), \(features.count) features")
        #endif
        return dnaSeq
    }
    
    // MARK: - GenBank Location Parsing
    
    /// Parses GenBank location strings into start, end, and strand.
    /// Handles: simple (100..200), complement(100..200), join(100..200,300..400),
    /// complement(join(...)), and single-position features.
    private func parseGenBankLocation(_ locationStr: String) -> (start: Int, end: Int, strand: Strand) {
        var loc = locationStr.trimmingCharacters(in: .whitespaces)
        var strand: Strand = .forward
        
        // Handle complement
        if loc.lowercased().hasPrefix("complement(") && loc.hasSuffix(")") {
            strand = .reverse
            loc = String(loc.dropFirst(11).dropLast(1))
        }
        
        // Handle join/order — take the overall span (min start, max end)
        if loc.lowercased().hasPrefix("join(") && loc.hasSuffix(")") {
            loc = String(loc.dropFirst(5).dropLast(1))
            return parseJoinedLocation(loc, strand: strand)
        }
        if loc.lowercased().hasPrefix("order(") && loc.hasSuffix(")") {
            loc = String(loc.dropFirst(6).dropLast(1))
            return parseJoinedLocation(loc, strand: strand)
        }
        
        // Handle single position.
        // GenBank positions are 1-based; Feature.start is stored 0-based.
        if let pos = Int(loc) {
            return (max(0, pos - 1), pos, strand)
        }
        
        // Handle simple range: start..end
        // Remove < and > (partial indicators)
        loc = loc.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")
        
        let parts = loc.components(separatedBy: "..")
        if parts.count == 2, let start = Int(parts[0].trimmingCharacters(in: .whitespaces)),
           let end = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
            // GenBank is 1-based; Feature.start is stored 0-based
            return (max(0, start - 1), end, strand)
        }
        
        // Handle single-base range with ^ (e.g., 100^101)
        let caretParts = loc.components(separatedBy: "^")
        if caretParts.count == 2, let start = Int(caretParts[0]), let end = Int(caretParts[1]) {
            return (max(0, start - 1), end, strand)
        }
        
        return (0, 0, strand) // Invalid
    }
    
    /// Parses comma-separated joined location segments into overall span
    private func parseJoinedLocation(_ joinedStr: String, strand: Strand) -> (start: Int, end: Int, strand: Strand) {
        let segments = joinedStr.components(separatedBy: ",")
        var minStart = Int.max
        var maxEnd = 0
        
        for segment in segments {
            var seg = segment.trimmingCharacters(in: .whitespaces)
            seg = seg.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")
            
            // Handle complement within join
            if seg.lowercased().hasPrefix("complement(") && seg.hasSuffix(")") {
                seg = String(seg.dropFirst(11).dropLast(1))
            }
            
            let parts = seg.components(separatedBy: "..")
            if parts.count == 2, let s = Int(parts[0].trimmingCharacters(in: .whitespaces)),
               let e = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                minStart = min(minStart, s)
                maxEnd = max(maxEnd, e)
            } else if let pos = Int(seg) {
                minStart = min(minStart, pos)
                maxEnd = max(maxEnd, pos)
            }
        }
        
        guard minStart != Int.max, maxEnd > 0 else { return (0, 0, strand) }
        // GenBank is 1-based; Feature.start is stored 0-based
        return (max(0, minStart - 1), maxEnd, strand)
    }
    
    // MARK: - GenBank Feature Helpers
    
    /// Determines the display name for a feature from its qualifiers
    private func resolveFeatureName(qualifiers: [(String, String)], fallback: String) -> String {
        // Priority order: label > gene > product > locus_tag > note > feature key
        let priorityKeys = ["label", "gene", "product", "locus_tag", "note"]
        
        for key in priorityKeys {
            if let qual = qualifiers.first(where: { $0.0 == key }) {
                let val = qual.1.trimmingCharacters(in: .whitespaces)
                if !val.isEmpty {
                    return val
                }
            }
        }
        
        return fallback
    }
    
    /// Maps GenBank feature keys to the app's FeatureType enum
    private func mapGenBankFeatureType(_ key: String) -> FeatureType {
        switch key.lowercased() {
        case "cds":                         return .cds
        case "gene":                        return .gene
        case "promoter":                    return .promoter
        case "terminator":                  return .terminator
        case "rep_origin":                  return .origin
        case "primer_bind":                 return .primerBinding
        case "regulatory":                  return .regulatory
        case "enhancer":                    return .enhancer
        case "polya_signal", "polya_site":  return .terminator
        case "sig_peptide", "mat_peptide":  return .signalPeptide
        case "intron":                      return .intron
        case "exon":                        return .exon
        case "misc_recomb":                 return .loxP
        case "misc_feature", "misc_binding": return .misc
        default:                            return .custom
        }
    }
    
    /// Resolves feature color from qualifiers, with fallback defaults per type.
    /// Supports APE (/ApEinfo_fwdcolor=, /ApEinfo_revcolor=), SnapGene (/color=),
    /// Benchling (/benchling_color=), and Serial Cloner (/note= with color info).
    private func resolveFeatureColor(qualifiers: [(String, String)], featureType: FeatureType) -> CodableColor {
        // Try to extract color from qualifiers
        let colorKeys = ["apeinfo_fwdcolor", "apeinfo_revcolor", "color", "colour",
                         "benchling_color", "snapgene_color"]
        
        for key in colorKeys {
            if let qual = qualifiers.first(where: { $0.0 == key }) {
                if let parsed = parseColorString(qual.1) {
                    return parsed
                }
            }
        }
        
        // Check /note for embedded color (some tools put it there)
        if let noteQual = qualifiers.first(where: { $0.0 == "note" }) {
            let note = noteQual.1
            // Look for color= or colour= in note text
            if let range = note.range(of: "color:", options: .caseInsensitive) ??
               note.range(of: "colour:", options: .caseInsensitive) ??
               note.range(of: "color=", options: .caseInsensitive) {
                let after = String(note[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                let colorStr = after.components(separatedBy: .whitespaces).first ?? after
                if let parsed = parseColorString(colorStr) {
                    return parsed
                }
            }
        }
        
        // Default colors per feature type
        return defaultColorForType(featureType)
    }
    
    /// Parse a color string in various formats: #RRGGBB, #RGB, rgb(r,g,b), or named colors
    private func parseColorString(_ str: String) -> CodableColor? {
        let trimmed = str.trimmingCharacters(in: .whitespaces).lowercased()
        
        // Hex format: #RRGGBB or #RGB
        if trimmed.hasPrefix("#") {
            let hex = String(trimmed.dropFirst())
            if hex.count == 6, let val = UInt32(hex, radix: 16) {
                return CodableColor(
                    red: Double((val >> 16) & 0xFF) / 255.0,
                    green: Double((val >> 8) & 0xFF) / 255.0,
                    blue: Double(val & 0xFF) / 255.0
                )
            } else if hex.count == 3 {
                let chars = Array(hex)
                if let r = UInt8(String(chars[0]) + String(chars[0]), radix: 16),
                   let g = UInt8(String(chars[1]) + String(chars[1]), radix: 16),
                   let b = UInt8(String(chars[2]) + String(chars[2]), radix: 16) {
                    return CodableColor(red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255)
                }
            }
        }
        
        // VB6/Serial Cloner format: &hRRGGBB
        if trimmed.hasPrefix("&h") {
            let hex = String(trimmed.dropFirst(2))
            if let val = UInt32(hex, radix: 16) {
                return CodableColor(
                    red: Double((val >> 16) & 0xFF) / 255.0,
                    green: Double((val >> 8) & 0xFF) / 255.0,
                    blue: Double(val & 0xFF) / 255.0
                )
            }
        }
        
        return nil
    }
    
    /// Default colors for feature types (matching Serial Cloner / APE conventions)
    private func defaultColorForType(_ type: FeatureType) -> CodableColor {
        switch type {
        case .cds:              return CodableColor(red: 0.55, green: 0.80, blue: 0.55)  // light green
        case .gene:             return CodableColor(red: 0.40, green: 0.70, blue: 0.90)  // sky blue
        case .promoter:         return CodableColor(red: 0.95, green: 0.75, blue: 0.35)  // golden
        case .terminator:       return CodableColor(red: 0.90, green: 0.45, blue: 0.45)  // salmon
        case .origin:           return CodableColor(red: 0.55, green: 0.90, blue: 0.55)  // green
        case .selectionMarker:  return CodableColor(red: 0.90, green: 0.55, blue: 0.30)  // orange
        case .primerBinding:    return CodableColor(red: 0.50, green: 0.50, blue: 0.85)  // blue-purple
        case .mcs:              return CodableColor(red: 0.85, green: 0.85, blue: 0.40)  // yellow-green
        case .enhancer:         return CodableColor(red: 0.95, green: 0.65, blue: 0.85)  // pink
        case .regulatory:       return CodableColor(red: 0.80, green: 0.65, blue: 0.40)  // tan
        case .reporter:         return CodableColor(red: 0.30, green: 0.85, blue: 0.85)  // cyan
        case .tag:              return CodableColor(red: 0.75, green: 0.50, blue: 0.85)  // purple
        case .loxP:             return CodableColor(red: 0.90, green: 0.40, blue: 0.70)  // magenta
        case .intron:           return CodableColor(red: 0.65, green: 0.65, blue: 0.80)  // lavender
        case .exon:             return CodableColor(red: 0.45, green: 0.75, blue: 0.55)  // medium green
        case .signalPeptide:    return CodableColor(red: 0.85, green: 0.60, blue: 0.45)  // peach
        case .misc:             return CodableColor(red: 0.60, green: 0.60, blue: 0.60)  // dark gray
        case .custom:           return CodableColor(red: 0.70, green: 0.70, blue: 0.70)  // gray
        }
    }
    
    // MARK: - Generation
    
    func generateFASTA(_ sequence: DNASequence) -> String {
        var fasta = ">\(sequence.name)"
        if !sequence.description.isEmpty {
            fasta += " \(sequence.description)"
        }
        fasta += "\n"
        
        let seq = sequence.sequence
        for i in stride(from: 0, to: seq.count, by: 60) {
            let start = seq.index(seq.startIndex, offsetBy: i)
            let end = seq.index(start, offsetBy: min(60, seq.count - i))
            fasta += String(seq[start..<end]) + "\n"
        }
        
        return fasta
    }
    
    func generateGenBank(_ sequence: DNASequence) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd-MMM-yyyy"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        let dateStr = dateFormatter.string(from: Date()).uppercased()
        
        let topology = sequence.isCircular ? "circular" : "linear"
        let bpStr = String(format: "%d", sequence.length)
        
        var gb = ""
        // LOCUS line: padded to standard GenBank column positions
        let locusName = sequence.name.prefix(16)
        gb += "LOCUS       \(locusName)\(String(repeating: " ", count: max(1, 17 - locusName.count)))\(bpStr) bp    DNA     \(topology)   \(dateStr)\n"
        gb += "DEFINITION  \(sequence.description.isEmpty ? sequence.name : sequence.description).\n"
        gb += "ACCESSION   \n"
        gb += "VERSION     \n"
        gb += "KEYWORDS    .\n"
        gb += "SOURCE      .\n"
        gb += "  ORGANISM  .\n"
        gb += "FEATURES             Location/Qualifiers\n"
        
        // Source feature (standard for GenBank)
        gb += "     source          1..\(sequence.length)\n"
        gb += "                     /mol_type=\"other DNA\"\n"
        
        for feature in sequence.features {
            // Build location string.
            // Feature.start is stored 0-based internally; GenBank requires 1-based.
            var location = "\(feature.start + 1)..\(feature.end)"
            if feature.strand == .reverse {
                location = "complement(\(location))"
            }
            
            // Map feature type to GenBank key
            let gbKey = genBankKeyForType(feature.type)
            let paddedKey = gbKey.padding(toLength: 16, withPad: " ", startingAt: 0)
            
            gb += "     \(paddedKey)\(location)\n"
            gb += "                     /label=\"\(feature.name)\"\n"
            
            // Write color as ApEinfo qualifier for APE/SnapGene compatibility
            let hexColor = String(format: "#%02x%02x%02x",
                                  Int(feature.color.red * 255),
                                  Int(feature.color.green * 255),
                                  Int(feature.color.blue * 255))
            gb += "                     /ApEinfo_fwdcolor=\"\(hexColor)\"\n"
            gb += "                     /ApEinfo_revcolor=\"\(hexColor)\"\n"
        }
        
        gb += "ORIGIN\n"
        
        let seq = sequence.sequence.lowercased()
        for i in stride(from: 0, to: seq.count, by: 60) {
            let lineNum = String(format: "%9d", i + 1)
            let startIdx = seq.index(seq.startIndex, offsetBy: i)
            let endIdx = seq.index(startIdx, offsetBy: min(60, seq.count - i))
            let lineSeq = String(seq[startIdx..<endIdx])
            
            // Format in groups of 10
            var formatted = ""
            for j in stride(from: 0, to: lineSeq.count, by: 10) {
                let groupStart = lineSeq.index(lineSeq.startIndex, offsetBy: j)
                let groupEnd = lineSeq.index(groupStart, offsetBy: min(10, lineSeq.count - j))
                if !formatted.isEmpty { formatted += " " }
                formatted += String(lineSeq[groupStart..<groupEnd])
            }
            
            gb += "\(lineNum) \(formatted)\n"
        }
        
        gb += "//\n"
        
        return gb
    }
    
    /// Maps app FeatureType to standard GenBank feature key
    private func genBankKeyForType(_ type: FeatureType) -> String {
        switch type {
        case .cds:              return "CDS"
        case .gene:             return "gene"
        case .promoter:         return "promoter"
        case .terminator:       return "terminator"
        case .origin:           return "rep_origin"
        case .selectionMarker:  return "gene"           // selection markers are typically genes
        case .primerBinding:    return "primer_bind"
        case .mcs:              return "misc_feature"   // no standard GenBank key for MCS
        case .enhancer:         return "enhancer"
        case .regulatory:       return "regulatory"
        case .reporter:         return "gene"
        case .tag:              return "CDS"
        case .loxP:             return "misc_recomb"
        case .intron:           return "intron"
        case .exon:             return "exon"
        case .signalPeptide:    return "sig_peptide"
        case .misc:             return "misc_feature"
        case .custom:           return "misc_feature"
        }
    }
    
    // MARK: - Analysis Functions
    
    func findRestrictionSites() {
        // Trigger UI to show restriction sites
    }
    
    func findORFs() {
        // Trigger UI to show ORF finder
    }
    
    
    
    func translateSequence() {
        guard let sequence = currentSequence else { return }
        let protein = sequence.translate()
        #if DEBUG
        print("Protein: \(protein)")
        #endif
    }
    
    /// Translate the current DNA selection into a protein and open it in a protein window
    @MainActor
    func translateSelection() {
        guard let sequence = currentSequence else { return }
        let start = selectionStart
        let end = selectionEnd
        guard end > start else { return }
        
        // Extract the selected DNA region
        let seqStr = sequence.sequence
        let startIdx = seqStr.index(seqStr.startIndex, offsetBy: min(start, seqStr.count))
        let endIdx = seqStr.index(seqStr.startIndex, offsetBy: min(end, seqStr.count))
        
        // Clean: keep only valid DNA bases, uppercase
        let validBases = Set("ATCG")
        let selectedDNA = String(seqStr[startIdx..<endIdx]).uppercased().filter { validBases.contains($0) }
        
        guard selectedDNA.count >= 3 else { return }
                
                // Check if 3 bases after selection form a stop codon
                let stopCodons: Set<String> = ["TAA", "TAG", "TGA"]
                var extraStop = ""
                if end + 3 <= seqStr.count {
                    let stopStart = seqStr.index(seqStr.startIndex, offsetBy: end)
                    let stopEnd = seqStr.index(stopStart, offsetBy: 3)
                    let nextCodon = String(seqStr[stopStart..<stopEnd]).uppercased()
                    if stopCodons.contains(nextCodon) {
                        extraStop = "*"
                    }
                }
                
                // Translate using standard codon table
                let codonTable = GeneticCode.standard.codonTable
                var proteinStr = ""
                var i = 0
                while i + 2 < selectedDNA.count {
                    let cStart = selectedDNA.index(selectedDNA.startIndex, offsetBy: i)
                    let cEnd = selectedDNA.index(cStart, offsetBy: 3)
                    let codon = String(selectedDNA[cStart..<cEnd])
                    let aa = codonTable[codon] ?? Character("X")
                    // Stop codons shown as * in the protein sequence
                    proteinStr.append(aa)
                    i += 3
                }
                
                // Append stop codon if found just after selection
                if !proteinStr.contains("*") && !extraStop.isEmpty {
                    proteinStr.append(contentsOf: extraStop)
                }
                
                guard !proteinStr.isEmpty else { return }
        
        // Create protein sequence and open in protein window
        let regionLabel = "\(start + 1)..\(end)"
        let protein = ProteinSequence(
            name: "\(sequence.name) [\(regionLabel)]",
            sequence: proteinStr,
            isCircular: false
        )
        protein.description = "Translated from \(sequence.name) positions \(regionLabel)"
        
        proteinSequences.append(protein)
        currentProtein = protein
        ProteinWindowOpener.shared.openProteinWindow(protein.id)
    }
    
    /// Resolves the DNA sequence shown in the front window by matching the
    /// window title against open sequence names, and sets it as currentSequence.
    /// This is more reliable than @FocusedValue activeSequence, which can be
    /// nil at the moment a menubar command fires (focus briefly leaves the
    /// window when the user reaches for the menu bar). Tools-menu commands
    /// that operate on "the active sequence" should call this first.
    @MainActor
    func syncCurrentSequenceToFrontWindow() {
        guard let title = NSApp.keyWindow?.title else { return }
        // Prefer exact name match
        if let exact = sequences.first(where: { $0.name == title }) {
            currentSequence = exact
            return
        }
        // Fall back to longest substring match (handles windows whose title
        // includes extra decoration like "ABI4 — Cereal Cloner")
        let candidates = sequences.filter { !$0.name.isEmpty && title.contains($0.name) }
        if let best = candidates.max(by: { $0.name.count < $1.name.count }) {
            currentSequence = best
        }
    }
    
    func reverseComplement() {
        syncCurrentSequenceToFrontWindow()
        guard let sequence = currentSequence else { return }
        sequence.registerUndo()
        let seqLen = sequence.sequence.count
        sequence.sequence = sequence.reverseComplement()
        
        // RC remapping: each feature's coordinates mirror and strand flips.
        // 0-based: new_start = (L-1) - old_end, new_end = (L-1) - old_start
        let L = seqLen
        sequence.features = sequence.features.map { f in
            var nf = f
            nf.start  = (L - 1) - f.end
            nf.end    = (L - 1) - f.start
            nf.strand = (f.strand == .reverse) ? .forward : .reverse
            return nf
        }
        // ORFs are invalidated by sequence transformation
        sequence.orfResults = []
    }
    
    /// Reverse the current sequence (no complement).
    /// e.g. AAGGAAGG → GGAAGGAA
    func reverseSequence() {
        syncCurrentSequenceToFrontWindow()
        guard let sequence = currentSequence else { return }
        sequence.registerUndo()
        let seqLen = sequence.sequence.count
        sequence.sequence = String(sequence.sequence.reversed())
        
        // Reverse: positions mirror, strand flips
        sequence.features = sequence.features.map { f in
            var f = f
            let newStart = seqLen - f.end + 1
            let newEnd = seqLen - f.start + 1
            f.start = newStart
            f.end = newEnd
            f.strand = f.strand == .forward ? .reverse : .forward
            return f
        }
        sequence.orfResults = []
    }
    
    /// Complement the current sequence (no reverse).
    /// e.g. AAGGAAGG → TTCCTTCC
    func complementSequence() {
        syncCurrentSequenceToFrontWindow()
        guard let sequence = currentSequence else { return }
        sequence.registerUndo()
        let complementMap: [Character: Character] = [
            "A": "T", "T": "A", "G": "C", "C": "G",
            "a": "t", "t": "a", "g": "c", "c": "g",
            "N": "N", "n": "n",
            "R": "Y", "Y": "R", "S": "S", "W": "W",
            "K": "M", "M": "K", "B": "V", "V": "B",
            "D": "H", "H": "D",
            "r": "y", "y": "r", "s": "s", "w": "w",
            "k": "m", "m": "k", "b": "v", "v": "b",
            "d": "h", "h": "d"
        ]
        sequence.sequence = String(sequence.sequence.map { complementMap[$0] ?? $0 })
        
        // Complement: positions stay the same, strand flips
        sequence.features = sequence.features.map { f in
            var f = f
            f.strand = f.strand == .forward ? .reverse : .forward
            return f
        }
        sequence.orfResults = []
    }
    
    /// Convert the current sequence from DNA to RNA (T→U).
    /// Appends " -RNA" to name, clears sourceURL so "Save As" is forced,
    /// and marks dirty so the close guard prompts to save.
    func convertToRNA() {
        syncCurrentSequenceToFrontWindow()
        guard let sequence = currentSequence else { return }
        sequence.registerUndo()
        let seq = sequence.sequence
        guard !seq.isEmpty else { return }
        
        // Replace T→U, t→u
        let rnaSeq = seq.map { c -> Character in
            if c == "T" { return "U" }
            if c == "t" { return "u" }
            return c
        }
        sequence.sequence = String(rnaSeq)
        
        // Update name
        if !sequence.name.hasSuffix("-RNA") {
            sequence.name = sequence.name + " -RNA"
        }
        
        // Force Save As on close (don't overwrite original DNA file)
        sequence.sourceURL = nil
        sequence.isDirty = true
    }
    
    /// Convert the current sequence from RNA back to DNA (U→T).
    /// Appends " -DNA" to name if it ends with "-RNA", otherwise appends " -DNA".
    func convertToDNA() {
        syncCurrentSequenceToFrontWindow()
        guard let sequence = currentSequence else { return }
        sequence.registerUndo()
        let seq = sequence.sequence
        guard !seq.isEmpty else { return }
        
        let dnaSeq = seq.map { c -> Character in
            if c == "U" { return "T" }
            if c == "u" { return "t" }
            return c
        }
        sequence.sequence = String(dnaSeq)
        
        if sequence.name.hasSuffix(" -RNA") {
            sequence.name = String(sequence.name.dropLast(5))
        } else if !sequence.name.hasSuffix("-DNA") {
            sequence.name = sequence.name + " -DNA"
        }
        
        sequence.sourceURL = nil
        sequence.isDirty = true
    }
    
    @MainActor
    func openNCBIBlastDNA() {
        guard let sequence = currentSequence else { return }
        let seq = sequence.sequence.uppercased()
        guard !seq.isEmpty else { return }
        
        // Open the nucleotide BLAST search page with the sequence pre-filled
        var components = URLComponents(string: "https://blast.ncbi.nlm.nih.gov/Blast.cgi")!
        components.queryItems = [
            URLQueryItem(name: "PROGRAM", value: "blastn"),
            URLQueryItem(name: "PAGE_TYPE", value: "BlastSearch"),
            URLQueryItem(name: "LINK_LOC", value: "blasthome"),
            URLQueryItem(name: "QUERY", value: seq)
        ]
        
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }
    
    func openNCBIBlastProtein() {
        guard let activeProtein = currentProtein, !activeProtein.sequence.isEmpty else { return }
        let protein = activeProtein.sequence.uppercased()
        
        var components = URLComponents(string: "https://blast.ncbi.nlm.nih.gov/Blast.cgi")!
        components.queryItems = [
            URLQueryItem(name: "PROGRAM", value: "blastp"),
            URLQueryItem(name: "PAGE_TYPE", value: "BlastSearch"),
            URLQueryItem(name: "LINK_LOC", value: "blasthome"),
            URLQueryItem(name: "QUERY", value: protein)
        ]
        
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }
    
    // MARK: - Sample Data
    
    @discardableResult
    func loadSampleSequence() -> DNASequence {
        // Always create a fresh copy — the caller may be reopening after close.
        // The old "already open" guard is intentionally removed so that
        // File > Open Sample File always works, even after the window is closed.
        
        // pUC19 plasmid sample
        let puc19Seq = """
                GCGCCCAATA CGCAAACCGC CTCTCCCCGC GCGTTGGCCG ATTCATTAAT GCAGCTGGCA
                CGACAGGTTT CCCGACTGGA AAGCGGGCAG TGAGCGCAAC GCAATTAATG TGAGTTAGCT
                CACTCATTAG GCACCCCAGG CTTTACACTT TATGCTTCCG GCTCGTATGT TGTGTGGAAT
                TGTGAGCGGA TAACAATTTC ACACAGGAAA CAGCTATGAC CATGATTACG CCAAGCTTGC
                ATGCCTGCAG GTCGACTCTA GAGGATCCCC GGGTACCGAG CTCGAATTCA CTGGCCGTCG
                TTTTACAACG TCGTGACTGG GAAAACCCTG GCGTTACCCA ACTTAATCGC CTTGCAGCAC
                ATCCCCCTTT CGCCAGCTGG CGTAATAGCG AAGAGGCCCG CACCGATCGC CCTTCCCAAC
                AGTTGCGCAG CCTGAATGGC GAATGGCGCC TGATGCGGTA TTTTCTCCTT ACGCATCTGT
                GCGGTATTTC ACACCGCATA TGGTGCACTC TCAGTACAAT CTGCTCTGAT GCCGCATAGT
                TAAGCCAGCC CCGACACCCG CCAACACCCG CTGACGCGCC CTGACGGGCT TGTCTGCTCC
                CGGCATCCGC TTACAGACAA GCTGTGACCG TCTCCGGGAG CTGCATGTGT CAGAGGTTTT
                CACCGTCATC ACCGAAACGC GCGAGACGAA AGGGCCTCGT GATACGCCTA TTTTTATAGG
                TTAATGTCAT GATAATAATG GTTTCTTAGA CGTCAGGTGG CACTTTTCGG GGAAATGTGC
                GCGGAACCCC TATTTGTTTA TTTTTCTAAA TACATTCAAA TATGTATCCG CTCATGAGAC
                AATAACCCTG ATAAATGCTT CAATAATATT GAAAAAGGAA GAGTATGAGT ATTCAACATT
                TCCGTGTCGC CCTTATTCCC TTTTTTGCGG CATTTTGCCT TCCTGTTTTT GCTCACCCAG
                AAACGCTGGT GAAAGTAAAA GATGCTGAAG ATCAGTTGGG TGCACGAGTG GGTTACATCG
                AACTGGATCT CAACAGCGGT AAGATCCTTG AGAGTTTTCG CCCCGAAGAA CGTTTTCCAA
                TGATGAGCAC TTTTAAAGTT CTGCTATGTG GCGCGGTATT ATCCCGTATT GACGCCGGGC
                AAGAGCAACT CGGTCGCCGC ATACACTATT CTCAGAATGA CTTGGTTGAG TACTCACCAG
                TCACAGAAAA GCATCTTACG GATGGCATGA CAGTAAGAGA ATTATGCAGT GCTGCCATAA
                CCATGAGTGA TAACACTGCG GCCAACTTAC TTCTGACAAC GATCGGAGGA CCGAAGGAGC
                TAACCGCTTT TTTGCACAAC ATGGGGGATC ATGTAACTCG CCTTGATCGT TGGGAACCGG
                AGCTGAATGA AGCCATACCA AACGACGAGC GTGACACCAC GATGCCTGTA GCAATGGCAA
                CAACGTTGCG CAAACTATTA ACTGGCGAAC TACTTACTCT AGCTTCCCGG CAACAATTAA
                TAGACTGGAT GGAGGCGGAT AAAGTTGCAG GACCACTTCT GCGCTCGGCC CTTCCGGCTG
                GCTGGTTTAT TGCTGATAAA TCTGGAGCCG GTGAGCGTGG GTCTCGCGGT ATCATTGCAG
                CACTGGGGCC AGATGGTAAG CCCTCCCGTA TCGTAGTTAT CTACACGACG GGGAGTCAGG
                CAACTATGGA TGAACGAAAT AGACAGATCG CTGAGATAGG TGCCTCACTG ATTAAGCATT
                GGTAACTGTC AGACCAAGTT TACTCATATA TACTTTAGAT TGATTTAAAA CTTCATTTTT
                AATTTAAAAG GATCTAGGTG AAGATCCTTT TTGATAATCT CATGACCAAA ATCCCTTAAC
                GTGAGTTTTC GTTCCACTGA GCGTCAGACC CCGTAGAAAA GATCAAAGGA TCTTCTTGAG
                ATCCTTTTTT TCTGCGCGTA ATCTGCTGCT TGCAAACAAA AAAACCACCG CTACCAGCGG
                TGGTTTGTTT GCCGGATCAA GAGCTACCAA CTCTTTTTCC GAAGGTAACT GGCTTCAGCA
                GAGCGCAGAT ACCAAATACT GTTCTTCTAG TGTAGCCGTA GTTAGGCCAC CACTTCAAGA
                ACTCTGTAGC ACCGCCTACA TACCTCGCTC TGCTAATCCT GTTACCAGTG GCTGCTGCCA
                GTGGCGATAA GTCGTGTCTT ACCGGGTTGG ACTCAAGACG ATAGTTACCG GATAAGGCGC
                AGCGGTCGGG CTGAACGGGG GGTTCGTGCA CACAGCCCAG CTTGGAGCGA ACGACCTACA
                CCGAACTGAG ATACCTACAG CGTGAGCTAT GAGAAAGCGC CACGCTTCCC GAAGGGAGAA
                AGGCGGACAG GTATCCGGTA AGCGGCAGGG TCGGAACAGG AGAGCGCACG AGGGAGCTTC
                CAGGGGGAAA CGCCTGGTAT CTTTATAGTC CTGTCGGGTT TCGCCACCTC TGACTTGAGC
                GTCGATTTTT GTGATGCTCG TCAGGGGGGC GGAGCCTATG GAAAAACGCC AGCAACGCGG
                CCTTTTTACG GTTCCTGGCC TTTTGCTGGC CTTTTGCTCA CATGTTCTTT CCTGCGTTAT
                CCCCTGATTC TGTGGATAAC CGTATTACCG CCTTTGAGTG AGCTGATACC GCTCGCCGCA
                GCCGAACGAC CGAGCGCAGC GAGTCAGTGA GCGAGGAAGC GGAAGA

        """
        
        // Strip whitespace/newlines from the formatted sequence string
        let cleanedSeq = puc19Seq.filter { !$0.isWhitespace }
        let sample = DNASequence(name: "pUC19", sequence: cleanedSeq, isCircular: true)
        sample.description = "pUC19 cloning vector"
        
        // Add features (matching the pUC19.xdna reference file)
        sample.features = [
            Feature(name: "lac promoter/operator", type: .promoter, start: 142, end: 207, strand: .forward,
                    color: CodableColor(red: 0.27, green: 0.51, blue: 0.71)),      // steel blue
            Feature(name: "LacO", type: .custom, start: 175, end: 198, strand: .forward,
                    color: CodableColor(red: 0.38, green: 0.58, blue: 0.93)),       // blue
            Feature(name: "M13-rev", type: .primerBinding, start: 203, end: 224, strand: .forward,
                    color: CodableColor(red: 0.0, green: 0.54, blue: 0.54)),        // teal
            Feature(name: "M13-fwd", type: .primerBinding, start: 289, end: 307, strand: .reverse,
                    color: CodableColor(red: 0.0, green: 0.54, blue: 0.54)),        // teal
            Feature(name: "LacZ alpha", type: .cds, start: 377, end: 446, strand: .forward,
                    color: CodableColor(red: 0.38, green: 0.58, blue: 0.93)),       // blue
            Feature(name: "Amp prom", type: .promoter, start: 814, end: 843, strand: .forward,
                    color: CodableColor(red: 0.27, green: 0.51, blue: 0.71)),       // steel blue
            Feature(name: "AmpR", type: .cds, start: 1082, end: 1742, strand: .forward,
                    color: CodableColor(red: 0.56, green: 0.73, blue: 0.56)),       // sage green
            Feature(name: "ColE1 origin", type: .origin, start: 1893, end: 2522, strand: .forward,
                    color: CodableColor(red: 0.27, green: 0.51, blue: 0.71)),       // steel blue
        ]
        
        // Mark clean AFTER all property assignments above so the queued
        // Combine dirty events from the load are suppressed. Without this,
        // the freshly-loaded sample gets marked dirty and prompts to save
        // on close even though the user never touched it.
        sample.markCleanAfterLoad()
        
        sequences.append(sample)
        currentSequence = sample
        return sample
    }
}

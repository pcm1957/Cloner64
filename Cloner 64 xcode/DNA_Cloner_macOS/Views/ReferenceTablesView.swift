//
//  ReferenceTablesView.swift
//  Cloner 64
//
//  Reference tables for the Genetic Code and IUPAC Nucleotide Codes.
//

import SwiftUI
import AppKit


// MARK: - Window Managers

class GeneticCodeWindowManager {
    static let shared = GeneticCodeWindowManager()
    private var window: NSWindow?
    
    func openWindow() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        
        let view = GeneticCodeView()
        let hostingView = NSHostingView(rootView: view)
        
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "The Genetic Code"
        win.contentView = hostingView
        win.setFrameAutosaveName("TheGeneticCode")
        if !win.setFrameUsingName(win.frameAutosaveName) { win.center() }
        win.makeKeyAndOrderFront(nil)
        win.isReleasedWhenClosed = false
        
        self.window = win
    }
}

class IUPACCodesWindowManager {
    static let shared = IUPACCodesWindowManager()
    private var window: NSWindow?
    
    func openWindow() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        
        let view = IUPACCodesView()
        let hostingView = NSHostingView(rootView: view)
        
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "IUPAC Nucleotide Codes"
        win.contentView = hostingView
        win.setFrameAutosaveName("IUPACNucleotideCodes")
        if !win.setFrameUsingName(win.frameAutosaveName) { win.center() }
        win.makeKeyAndOrderFront(nil)
        win.isReleasedWhenClosed = false
        
        self.window = win
    }
}


// MARK: - Genetic Code View

struct GeneticCodeView: View {
    // Standard genetic code: 64 codons → amino acids
    // Organised by first base (rows) and second base (columns)
    
    private static let bases: [Character] = ["U", "C", "A", "G"]
    
    private static let codonTable: [String: (letter: String, name: String)] = [
        "UUU": ("F", "Phe"), "UUC": ("F", "Phe"), "UUA": ("L", "Leu"), "UUG": ("L", "Leu"),
        "UCU": ("S", "Ser"), "UCC": ("S", "Ser"), "UCA": ("S", "Ser"), "UCG": ("S", "Ser"),
        "UAU": ("Y", "Tyr"), "UAC": ("Y", "Tyr"), "UAA": ("*", "Stop"), "UAG": ("*", "Stop"),
        "UGU": ("C", "Cys"), "UGC": ("C", "Cys"), "UGA": ("*", "Stop"), "UGG": ("W", "Trp"),
        
        "CUU": ("L", "Leu"), "CUC": ("L", "Leu"), "CUA": ("L", "Leu"), "CUG": ("L", "Leu"),
        "CCU": ("P", "Pro"), "CCC": ("P", "Pro"), "CCA": ("P", "Pro"), "CCG": ("P", "Pro"),
        "CAU": ("H", "His"), "CAC": ("H", "His"), "CAA": ("Q", "Gln"), "CAG": ("Q", "Gln"),
        "CGU": ("R", "Arg"), "CGC": ("R", "Arg"), "CGA": ("R", "Arg"), "CGG": ("R", "Arg"),
        
        "AUU": ("I", "Ile"), "AUC": ("I", "Ile"), "AUA": ("I", "Ile"), "AUG": ("M", "Met"),
        "ACU": ("T", "Thr"), "ACC": ("T", "Thr"), "ACA": ("T", "Thr"), "ACG": ("T", "Thr"),
        "AAU": ("N", "Asn"), "AAC": ("N", "Asn"), "AAA": ("K", "Lys"), "AAG": ("K", "Lys"),
        "AGU": ("S", "Ser"), "AGC": ("S", "Ser"), "AGA": ("R", "Arg"), "AGG": ("R", "Arg"),
        
        "GUU": ("V", "Val"), "GUC": ("V", "Val"), "GUA": ("V", "Val"), "GUG": ("V", "Val"),
        "GCU": ("A", "Ala"), "GCC": ("A", "Ala"), "GCA": ("A", "Ala"), "GCG": ("A", "Ala"),
        "GAU": ("D", "Asp"), "GAC": ("D", "Asp"), "GAA": ("E", "Glu"), "GAG": ("E", "Glu"),
        "GGU": ("G", "Gly"), "GGC": ("G", "Gly"), "GGA": ("G", "Gly"), "GGG": ("G", "Gly"),
    ]
    
    // Colour by amino acid property
    private static func aaColor(_ letter: String) -> Color {
        switch letter {
        case "*":                           return Color.red.opacity(0.25)        // Stop
        case "R", "H", "K":                return Color.blue.opacity(0.15)       // Positive
        case "D", "E":                      return Color.red.opacity(0.12)        // Negative
        case "S", "T", "N", "Q", "C", "Y": return Color.green.opacity(0.12)     // Polar
        case "G", "A", "V", "L", "I", "P", "F", "W", "M":
                                            return Color.orange.opacity(0.10)     // Non-polar
        default:                            return Color.clear
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            Text("The Standard Genetic Code")
                .font(.system(size: 14, weight: .bold))
                .padding(.top, 10)
                .padding(.bottom, 6)
            
            // Column headers: second base
            HStack(spacing: 0) {
                Text("")
                    .frame(width: 32)
                ForEach(Self.bases, id: \.self) { base2 in
                    Text(String(base2))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .frame(width: 136)
                }
                Text("")
                    .frame(width: 32)
            }
            .padding(.bottom, 2)
            
            Divider()
            
            // Table body: first base (rows) × second base (columns) × third base (sub-rows)
            ForEach(Self.bases, id: \.self) { base1 in
                HStack(spacing: 0) {
                    // First base label
                    Text(String(base1))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .frame(width: 32)
                    
                    // Four columns (one per second base)
                    ForEach(Self.bases, id: \.self) { base2 in
                        VStack(spacing: 0) {
                            ForEach(Self.bases, id: \.self) { base3 in
                                let codon = "\(base1)\(base2)\(base3)"
                                let aa = Self.codonTable[codon]!
                                
                                HStack(spacing: 4) {
                                    Text(codon)
                                        .font(.system(size: 11, design: .monospaced))
                                        .frame(width: 36, alignment: .leading)
                                    Text(aa.letter)
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .frame(width: 14)
                                    Text(aa.name)
                                        .font(.system(size: 11))
                                        .frame(width: 32, alignment: .leading)
                                }
                                .padding(.vertical, 2)
                                .padding(.horizontal, 4)
                                .frame(maxWidth: .infinity)
                                .background(Self.aaColor(aa.letter))
                            }
                        }
                        .frame(width: 136)
                        .overlay(
                            Rectangle()
                                .stroke(Color.gray.opacity(0.3), lineWidth: 0.5)
                        )
                    }
                    
                    // Third base label column
                    VStack(spacing: 0) {
                        ForEach(Self.bases, id: \.self) { base3 in
                            Text(String(base3))
                                .font(.system(size: 11, design: .monospaced))
                                .frame(height: 22)
                        }
                    }
                    .frame(width: 32)
                }
                
                if base1 != "G" {
                    Divider()
                }
            }
            
            Divider()
            
            // Legend
            HStack(spacing: 16) {
                legendDot(Color.orange.opacity(0.10), "Non-polar")
                legendDot(Color.green.opacity(0.12), "Polar")
                legendDot(Color.blue.opacity(0.15), "Positive")
                legendDot(Color.red.opacity(0.12), "Negative")
                legendDot(Color.red.opacity(0.25), "Stop")
            }
            .font(.system(size: 10))
            .padding(.vertical, 8)
            
            Text("AUG = Start codon (Met)")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 10)
    }
    
    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 12, height: 12)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.gray.opacity(0.4), lineWidth: 0.5)
                )
            Text(label)
        }
    }
}


// MARK: - IUPAC Nucleotide Codes View

struct IUPACCodesView: View {
    
    private struct IUPACCode: Identifiable {
        let id = UUID()
        let symbol: String
        let bases: String
        let meaning: String
        let complement: String
    }
    
    private let codes: [IUPACCode] = [
        IUPACCode(symbol: "A", bases: "A",       meaning: "Adenine",                  complement: "T"),
        IUPACCode(symbol: "C", bases: "C",       meaning: "Cytosine",                 complement: "G"),
        IUPACCode(symbol: "G", bases: "G",       meaning: "Guanine",                  complement: "C"),
        IUPACCode(symbol: "T", bases: "T",       meaning: "Thymine",                  complement: "A"),
        IUPACCode(symbol: "U", bases: "U",       meaning: "Uracil (RNA)",             complement: "A"),
        IUPACCode(symbol: "R", bases: "A,G",     meaning: "puRine",                   complement: "Y"),
        IUPACCode(symbol: "Y", bases: "C,T",     meaning: "pYrimidine",               complement: "R"),
        IUPACCode(symbol: "S", bases: "G,C",     meaning: "Strong (3 H-bonds)",       complement: "S"),
        IUPACCode(symbol: "W", bases: "A,T",     meaning: "Weak (2 H-bonds)",         complement: "W"),
        IUPACCode(symbol: "K", bases: "G,T",     meaning: "Keto",                     complement: "M"),
        IUPACCode(symbol: "M", bases: "A,C",     meaning: "aMino",                    complement: "K"),
        IUPACCode(symbol: "B", bases: "C,G,T",   meaning: "not A",                    complement: "V"),
        IUPACCode(symbol: "D", bases: "A,G,T",   meaning: "not C",                    complement: "H"),
        IUPACCode(symbol: "H", bases: "A,C,T",   meaning: "not G",                    complement: "D"),
        IUPACCode(symbol: "V", bases: "A,C,G",   meaning: "not T (not U)",            complement: "B"),
        IUPACCode(symbol: "N", bases: "A,C,G,T", meaning: "aNy base",                 complement: "N"),
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            Text("IUPAC Nucleotide Codes")
                .font(.system(size: 14, weight: .bold))
                .padding(.top, 12)
                .padding(.bottom, 8)
            
            // Header row
            HStack(spacing: 0) {
                Text("Symbol")
                    .frame(width: 60, alignment: .center)
                Text("Bases")
                    .frame(width: 80, alignment: .center)
                Text("Meaning")
                    .frame(width: 170, alignment: .leading)
                Text("Complement")
                    .frame(width: 80, alignment: .center)
            }
            .font(.system(size: 11, weight: .bold))
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Table rows
            ForEach(Array(codes.enumerated()), id: \.element.id) { index, code in
                HStack(spacing: 0) {
                    Text(code.symbol)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .frame(width: 60, alignment: .center)
                    
                    Text(code.bases)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 80, alignment: .center)
                    
                    Text(code.meaning)
                        .font(.system(size: 12))
                        .frame(width: 170, alignment: .leading)
                    
                    Text(code.complement)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .frame(width: 80, alignment: .center)
                }
                .padding(.vertical, 4)
                .background(index % 2 == 0 ? Color.clear : Color(NSColor.controlBackgroundColor).opacity(0.4))
                
                if index == 4 {
                    // Separator between standard bases and ambiguity codes
                    Divider()
                        .background(Color.accentColor.opacity(0.5))
                }
            }
            
            Divider()
            
            // Footer
            VStack(spacing: 4) {
                Text("Gap symbol: – (dash)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text("Nomenclature Committee of the International Union of Biochemistry (NC-IUB)")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 8)
        }
        .padding(.horizontal, 16)
    }
}

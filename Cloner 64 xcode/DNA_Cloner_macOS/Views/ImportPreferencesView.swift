//
//  ImportPreferencesView.swift
//  Cloner 64
//
//  Settings view for controlling import behavior
//

import SwiftUI

struct ImportPreferencesView: View {
    @EnvironmentObject var sequenceManager: SequenceManager
    
    var body: some View {
        Form {
            Section(header: Text("XDNA Import Settings")) {
                Toggle("Convert XDNA sequences to uppercase on import", 
                       isOn: $sequenceManager.convertXDNAToUppercase)
                    .help("When disabled (default), preserves mixed case where UPPERCASE=exons/coding and lowercase=introns/non-coding. This is the standard biological notation. Enable only if you need all uppercase for compatibility with tools that don't support mixed case.")
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Mixed Case Notation (Standard):")
                        .font(.caption)
                        .fontWeight(.semibold)
                    
                    Text("UPPERCASE = Exons, coding sequences")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("lowercase = Introns, non-coding regions")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("Example: ATGGCGgtaagttcagGCCTAG")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.blue)
                        .padding(.top, 4)
                    
                    Text("(Exon-Intron-Exon)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 8)
            }
        }
        .formStyle(.grouped)
        .frame(width: 550, height: 280)
    }
}

// MARK: - How to integrate into the app

/*
 Option 1: Add as a settings window
 
 In DNAClonerApp.swift, add a new Settings scene:
 
 Settings {
     ImportPreferencesView()
         .environmentObject(sequenceManager)
 }
 
 
 Option 2: Add as a menu item
 
 In DNAClonerApp.swift commands, add:
 
 CommandMenu("Preferences") {
     Button("Import Settings...") {
         // Show preferences window
     }
 }
 
 
 Option 3: Add toggle to toolbar
 
 In ContentView.swift toolbar:
 
 Toggle("Uppercase XDNA", isOn: $sequenceManager.convertXDNAToUppercase)
     .help("Convert XDNA imports to uppercase")
 
 */

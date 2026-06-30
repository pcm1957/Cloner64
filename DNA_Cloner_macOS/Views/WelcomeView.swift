//
//  WelcomeView.swift
//  Cloner 64 - A macOS DNA Analysis Application
//

import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var sequenceManager: SequenceManager

    var body: some View {
        VStack(spacing: 0) {
            // Main content: Logo left, text right
            HStack(alignment: .center, spacing: 24) {
                // Logo on the left
                if let _ = NSImage(named: "AppLogo") {
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200, height: 200)
                        .shadow(radius: 4)
                } else {
                    Image(systemName: "circle.hexagongrid.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 120, height: 120)
                        .foregroundStyle(.blue)
                        .shadow(radius: 2)
                }

                // Text and buttons on the right
                VStack(alignment: .leading, spacing: 12) {
                    Text("Cloner 64 v1.0")
                        .font(.system(size: 28, weight: .bold))

                    Text("Cloner 64 is a DNA cloning analysis app that replicates the look and ease of use of Serial Cloner, but will run on 64 bit Macs. It will run xdna, xprt, SnapGene, GenBank, APE, and FASTA files.")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        Button {
                            sequenceManager.openSequence()
                        } label: {
                            Label("Open...", systemImage: "folder")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        
                        Button {
                            sequenceManager.loadSampleSequence()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                if let sample = sequenceManager.currentSequence {
                                    SequenceWindowOpener.shared.openSequenceWindow(sample.id)
                                }
                                WelcomeWindowManager.shared.closeWindow()
                            }
                        } label: {
                            Label("Open Sample (pUC19)", systemImage: "doc.text")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.top, 20)
            .padding(.horizontal, 24)

            Divider()
                .padding(.vertical, 12)
                .padding(.horizontal, 24)
            
            

            // Tips/Info
            VStack(alignment: .leading, spacing: 6) {
                Text("Quick tips")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("• Use the Tools and Function menus for analysis tools such as Features Scan, Virtual Cutter, Primer Design and Construct Builder.")
                    .font(.system(size: 12))
                Text("• Use the Edit menu for copy/cut/paste, translation, and more.")
                    .font(.system(size: 12))
                Text("• In Sequence Editor view, use the Find drawer to search for sequences, restriction sites, and ORFs.")
                    .font(.system(size: 12))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)

            Spacer()

            HStack {
                Spacer()
                Button("Close") {
                    WelcomeWindowManager.shared.closeWindow()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .frame(minWidth: 680, minHeight: 440)
    }
}

// MARK: - Window Manager for Welcome
import AppKit

class WelcomeWindowManager {
    static let shared = WelcomeWindowManager()
    private var window: NSWindow?
    private init() {}

    func openWindow(sequenceManager: SequenceManager) {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let view = WelcomeView().environmentObject(sequenceManager)
        let controller = NSHostingController(rootView: view)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        win.title = "Welcome to Cloner 64"
        win.contentViewController = controller
        win.setFrameAutosaveName("WelcometoCloner64")
        if !win.setFrameUsingName(win.frameAutosaveName) { win.center() }
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        window = win
    }

    func closeWindow() {
        window?.close()
    }
}

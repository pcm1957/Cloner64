//
//  WelcomeView.swift
//  Cloner 64 - A macOS DNA Analysis Application
//

import SwiftUI
import Foundation
import Combine   // @Published / ObservableObject in UpdateChecker, below

struct WelcomeView: View {
    @EnvironmentObject var sequenceManager: SequenceManager
    @StateObject private var updates = UpdateChecker.shared

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
                    Text("Cloner 64 v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""))
                        .font(.system(size: 28, weight: .bold))

                    updateNotice

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
                Link(destination: UpdateChecker.repoURL) {
                    Label("Cloner 64 on GitHub", systemImage: "arrow.up.right.square")
                        .font(.system(size: 12))
                }
                .help("Opens the project page in your browser — source code, releases and the handbook.")
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
        .onAppear { updates.checkIfDue() }
    }

    /// One quiet line under the version number. Says nothing at all when the
    /// check could not be made — a laptop off the network, or GitHub being
    /// unreachable, is not something to report in a cloning app.
    @ViewBuilder private var updateNotice: some View {
        switch updates.state {
        case .idle, .checking, .unavailable:
            EmptyView()

        case .upToDate:
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green).font(.system(size: 11))
                Text("Up to date").font(.system(size: 12)).foregroundColor(.secondary)
            }

        case .updateAvailable(let latest, _):
            HStack(spacing: 5) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.blue).font(.system(size: 12))
                Text("Version \(latest) is available").font(.system(size: 12, weight: .semibold))
                Link("See what\u{2019}s new", destination: UpdateChecker.releasesURL)
                    .font(.system(size: 12))
            }
        }
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


// MARK: - Update Checker
//
// Lives here rather than in its own file because everything under
// DNA_Cloner_macOS is referenced file-by-file in the Xcode project, so a new
// file has to be added to the target by hand. Keeping it beside the one view
// that uses it avoids that step.
//
// Asks GitHub whether a newer release has been published, for the notice on
// the Welcome window. Deliberately modest: it reads the public releases
// endpoint, compares the tag against this build's version, and says one of
// three things. It never downloads or installs anything -- the user follows
// the link and decides. No identifying information is sent; it is an
// unauthenticated GET of a public URL.

@MainActor
final class UpdateChecker: ObservableObject {

    static let shared = UpdateChecker()

    /// Where the repository lives. Both the API query and the link the user
    /// follows are built from this, so there is one place to change it.
    static let repoOwner = "pcm1957"
    static let repoName  = "Cloner64"

    static var releasesURL: URL {
        URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases")!
    }
    static var repoURL: URL {
        URL(string: "https://github.com/\(repoOwner)/\(repoName)")!
    }
    private static var latestReleaseAPI: URL {
        URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate(current: String)
        case updateAvailable(latest: String, current: String)
        /// Could not reach GitHub, or the answer made no sense. Deliberately
        /// quiet — a failed update check is not the user's problem and should
        /// not look like an error in their cloning app.
        case unavailable
    }

    @Published private(set) var state: State = .idle

    /// This build's marketing version, e.g. "1.5".
    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
    }

    /// Don't pester GitHub on every launch.
    private static let lastCheckKey = "UpdateChecker.lastCheck"
    private static let minimumInterval: TimeInterval = 60 * 60 * 24   // once a day

    /// True when the user has switched the check off in Preferences.
    private static let disabledKey = "UpdateChecker.disabled"
    static var isDisabled: Bool {
        get { UserDefaults.standard.bool(forKey: disabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: disabledKey) }
    }

    /// Check if we haven't lately. Called when the Welcome window appears.
    func checkIfDue() {
        guard !Self.isDisabled else { state = .idle; return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
        if let last, Date().timeIntervalSince(last) < Self.minimumInterval {
            // Already checked today. Show the stored answer rather than nothing.
            if let cached = UserDefaults.standard.string(forKey: "UpdateChecker.lastSeenTag"),
               Self.isNewer(cached, than: Self.currentVersion) {
                state = .updateAvailable(latest: cached, current: Self.currentVersion)
            } else {
                state = .upToDate(current: Self.currentVersion)
            }
            return
        }
        check()
    }

    /// Check now, regardless of when we last looked.
    func check() {
        guard !Self.isDisabled else { state = .idle; return }
        state = .checking
        Task { await performCheck() }
    }

    private func performCheck() async {
        var request = URLRequest(url: Self.latestReleaseAPI)
        request.timeoutInterval = 10
        // GitHub asks for an explicit Accept header and a User-Agent.
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Cloner64/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawTag = json["tag_name"] as? String
            else {
                state = .unavailable
                return
            }

            let latest = Self.normalise(rawTag)
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            UserDefaults.standard.set(latest, forKey: "UpdateChecker.lastSeenTag")

            if Self.isNewer(latest, than: Self.currentVersion) {
                state = .updateAvailable(latest: latest, current: Self.currentVersion)
            } else {
                state = .upToDate(current: Self.currentVersion)
            }
        } catch {
            state = .unavailable
        }
    }

    // MARK: - Version comparison

    /// Strips a leading "v" and any surrounding whitespace: "v1.5" -> "1.5".
    nonisolated static func normalise(_ tag: String) -> String {
        var t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("v") { t.removeFirst() }
        return t
    }

    /// Compares dotted version numbers component by component, so that 1.10
    /// correctly beats 1.9 (a plain string comparison gets that wrong).
    /// Any component that is not a number makes the comparison give up and
    /// return false — better to say nothing than to announce a wrong update.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = normalise(candidate).split(separator: ".").map { Int($0) }
        let b = normalise(current).split(separator: ".").map { Int($0) }
        guard !a.isEmpty, !b.isEmpty,
              !a.contains(where: { $0 == nil }), !b.contains(where: { $0 == nil })
        else { return false }
        let x = a.map { $0! }, y = b.map { $0! }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

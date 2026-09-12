//
//  EnzymeStore.swift
//  Cloner 64
//
//  Persistence for user changes to the restriction enzyme database.
//
//  WHY AN OVERLAY RATHER THAN A FLAT LIST
//  --------------------------------------
//  The obvious approach — serialise the whole enzyme array on quit and reload
//  it on launch — would freeze the database at whatever state it was in the
//  first time the user ran the app. Any later correction to a built-in enzyme
//  (and there have been several) would never reach them, because their saved
//  copy would win forever.
//
//  So instead we save only the DIFFERENCE from the built-in list:
//
//      added    enzymes that are not in the built-in list at all
//      edited   built-in enzymes the user has changed, keyed by name
//      deleted  built-in enzymes the user has removed, by name
//
//  On launch the built-in list is loaded fresh from source, then the overlay is
//  applied on top. A corrected built-in therefore reaches the user unless they
//  have deliberately edited that particular enzyme themselves.
//

import Foundation

// MARK: - The saved record

/// Everything the user has changed about the enzyme database.
/// This is what gets written to disk and what Export/Import moves around.
struct EnzymeOverlay: Codable {

    /// Bumped only if the on-disk shape changes incompatibly. `load()` refuses
    /// to read a file from the future rather than silently mangling it.
    var formatVersion: Int = 1

    /// Enzymes the user created that have no built-in counterpart.
    var added: [RestrictionEnzyme] = []

    /// Built-in enzymes the user has modified, keyed by the ORIGINAL built-in
    /// name (so the key stays valid even if they rename the enzyme).
    var edited: [String: RestrictionEnzyme] = [:]

    /// Names of built-in enzymes the user has deleted.
    var deleted: [String] = []

    /// The "My Enzymes" freezer list. Carried here as well as in UserDefaults
    /// so that an exported file transfers the stars along with the enzymes.
    var myEnzymeNames: [String] = []

    /// True when the user has made no changes at all.
    var isEmpty: Bool {
        added.isEmpty && edited.isEmpty && deleted.isEmpty
    }
}

// MARK: - Reading and writing

enum EnzymeStore {

    /// File extension used by Export / Import.
    static let fileExtension = "c64enz"

    /// The highest `formatVersion` this build understands.
    private static let currentFormatVersion = 1

    /// Set by `load()`/`save()` when something goes wrong, so the UI can
    /// surface it instead of failing silently.
    private(set) static var lastError: String?

    // MARK: Location

    /// ~/Library/Application Support/Cloner 64/
    private static var supportDirectory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("Cloner 64", isDirectory: true)
    }

    /// The live store the app reads and writes automatically.
    static var storeURL: URL? {
        supportDirectory?.appendingPathComponent("UserEnzymes.json")
    }

    // MARK: Coders

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    // MARK: Automatic store

    /// Load the user's saved changes. Returns an empty overlay — never nil — so
    /// a missing or damaged file degrades to "no customisations" rather than
    /// preventing the database from loading at all.
    static func load() -> EnzymeOverlay {
        lastError = nil
        guard let url = storeURL else {
            lastError = "Could not locate the Application Support folder."
            return EnzymeOverlay()
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return EnzymeOverlay()   // first run
        }
        do {
            let overlay = try read(from: url)
            return overlay
        } catch {
            // Keep the damaged file rather than overwriting it — the user may
            // want to recover it by hand.
            lastError = "Saved enzymes could not be read (\(error.localizedDescription)). "
                      + "The file has been left untouched at \(url.path)."
            return EnzymeOverlay()
        }
    }

    /// Save the user's changes. Silent on success.
    @discardableResult
    static func save(_ overlay: EnzymeOverlay) -> Bool {
        lastError = nil
        guard let dir = supportDirectory, let url = storeURL else {
            lastError = "Could not locate the Application Support folder."
            return false
        }
        do {
            try FileManager.default.createDirectory(at: dir,
                                                    withIntermediateDirectories: true)
            try write(overlay, to: url)
            return true
        } catch {
            lastError = "Could not save enzymes: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: Explicit file IO (Export / Import)

    /// Write an overlay to a specific file, atomically.
    ///
    /// `.atomic` writes to a temporary file and swaps it into place, so a crash
    /// or a full disk part-way through leaves the previous file intact instead
    /// of a half-written one.
    static func write(_ overlay: EnzymeOverlay, to url: URL) throws {
        var record = overlay
        record.formatVersion = currentFormatVersion
        let data = try encoder.encode(record)
        try data.write(to: url, options: .atomic)
    }

    /// Read an overlay from a specific file.
    static func read(from url: URL) throws -> EnzymeOverlay {
        let data = try Data(contentsOf: url)
        let overlay = try JSONDecoder().decode(EnzymeOverlay.self, from: data)
        guard overlay.formatVersion <= currentFormatVersion else {
            throw NSError(domain: "Cloner64.EnzymeStore", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "This file was written by a newer version of Cloner 64 "
                    + "(format \(overlay.formatVersion)). Please update the app to open it."
            ])
        }
        return overlay
    }

    // MARK: Merging

    /// Combine an imported overlay into an existing one.
    ///
    /// Imported entries win on a name clash, on the grounds that the user just
    /// deliberately chose the file. Anything they had that the file does not
    /// mention is left alone.
    static func merge(_ incoming: EnzymeOverlay, into existing: EnzymeOverlay) -> EnzymeOverlay {
        var result = existing

        // Added enzymes: replace by name, otherwise append.
        for enzyme in incoming.added {
            if let idx = result.added.firstIndex(where: {
                $0.name.caseInsensitiveCompare(enzyme.name) == .orderedSame
            }) {
                result.added[idx] = enzyme
            } else {
                result.added.append(enzyme)
            }
        }

        // Edits to built-ins: incoming wins.
        for (key, enzyme) in incoming.edited {
            result.edited[key] = enzyme
        }

        // Deletions: union.
        result.deleted = Array(Set(result.deleted).union(incoming.deleted))

        // Stars: union, so importing never removes an enzyme from the freezer list.
        result.myEnzymeNames = Array(Set(result.myEnzymeNames).union(incoming.myEnzymeNames))

        // An enzyme that appears in `added` must not also be marked deleted.
        let addedNames = Set(result.added.map { $0.name })
        result.deleted.removeAll { addedNames.contains($0) }

        return result
    }
}

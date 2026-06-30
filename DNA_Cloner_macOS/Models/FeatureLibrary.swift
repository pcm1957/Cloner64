//
//  FeatureLibrary.swift
//  Cloner 64
//
//  Feature Collection system — stores reusable feature templates
//  with sequences that can be scanned against loaded DNA sequences.
//

import SwiftUI
import Foundation
import Combine

// MARK: - Feature Library Item (a template feature with its sequence)
struct FeatureLibraryItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var sequence: String          // The DNA or peptide sequence to scan for
    var isPeptide: Bool = false   // DNA vs Peptide
    var comments: String = ""
    var color: CodableColor
    var showArrow: Bool = true
    var featureType: FeatureType = .gene
    var scanEnabled: Bool = true  // "Scan for this feature" checkbox
    var senseStrandOnly: Bool = false
    
    static func == (lhs: FeatureLibraryItem, rhs: FeatureLibraryItem) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Feature Collection (a named group of library items)
struct FeatureCollection: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var scanEnabled: Bool = true  // Enable/disable scanning for entire collection
    var items: [FeatureLibraryItem] = []
    
    static func == (lhs: FeatureCollection, rhs: FeatureCollection) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Scan Result
struct ScanResult: Identifiable {
    let id = UUID()
    let libraryItem: FeatureLibraryItem
    let collectionName: String
    let start: Int
    let end: Int
    let strand: Strand
    let matchPercentage: Double
}

// MARK: - Feature Library Manager
class FeatureLibraryManager: ObservableObject {
    static let shared = FeatureLibraryManager()
    
    @Published var collections: [FeatureCollection] = []
    @Published var scanResults: [ScanResult] = []
    @Published var isScanning: Bool = false
    
    /// 0.0 … 1.0 progress for UI binding
    @Published var scanProgress: Double = 0.0
    
    /// Minimum similarity (0.0–1.0) for approximate matching. 1.0 = exact only.
    @Published var similarityThreshold: Double = 0.85
    
    /// Minimum query length (bp) required for approximate matching.
    /// Shorter queries use exact+IUPAC matching only to avoid false positives.
    let minLengthForApproximate: Int = 40
    
    private let storageKey = "featureLibraryCollections"
    private let schemaVersionKey = "featureLibrarySchemaVersion"
    private let currentSchemaVersion = 3
    
    private init() {
        loadCollections()
        
        if collections.isEmpty {
            loadDefaultCollections()
        }
        
        // Apply one-off corrections to built-in features for users who already
        // have the collection saved with older, incorrect sequences.
        migrateBuiltInFeaturesIfNeeded()
    }
    
    /// Applies one-off corrections to built-in features in saved libraries.
    /// Runs only once per schema version bump. Preserves user customisations
    /// (colour, arrow, scan-enabled, collection membership) while fixing
    /// the sequence and/or name.
    private func migrateBuiltInFeaturesIfNeeded() {
        let storedVersion = UserDefaults.standard.integer(forKey: schemaVersionKey)
        guard storedVersion < currentSchemaVersion else { return }
        
        // Canonical sequences
        let canonicalRrnBT1  = "GGGAACTGCCAGGCATCAAATAAAACGAAAGGCTCAGTCGAAAGACTGGGCCTTTCGTTTTATCTGTTGTTTGTCGGTGAACGCTCTCCTG"
        let canonicalT7term  = "CTAGCATAACCCCTTGGGGCCTCTAAACGGGTCTTGAGGGGTTTTTTG"
        let canonicalEMCVires = "GGTTATTTTCCACCATATTGCCGTCTTTTGGCAATGTGAGGGCCCGGAAACCTGGCCCTGTCTTCTTGACGAGCATTCCTAGGGGTCTTTCCCCTCTCGCCAAAGGAATGCAAGGTCTGTTGAATGTCGTGAAGGAAGCAGTTCCTCTGGAAGCTTCTTGAAGACAAACAACGTCTGTAGCGACCCTTTGCAGGCAGCGGAACCCCCCACCTGGCGACAGGTGCCTCTGCGGCCAAAAGCCACGTGTATAAGATACACCTGCAAAGGCGGCACAACCCCAGTGCCACGTTGTGAGTTGGATAGTTGTGGAAAGAGTCAAATGGCTCTCCTCAAGCGTATTCAACAAGGGGCTGAAGGATGCCCAGAAGGTACCCCATTGTATGGGATCTGATCTGGGGCCTCGGTGCACATGCTTTACATGTGTTTAGTCGAGGTTAAAAAACGTCTAGGCCCCCCGAACCACGGGGACGTGGTTTTCCTTTGAAAAACACGATGATAATATG"
        let canonicalLox2272 = "ATAACTTCGTATAAAGTATCCTATACGAAGTTAT"
        
        // Known-bad sequence prefix — the AmpR (bla) fragment that was
        // incorrectly stored under "rrnB T1 terminator" in earlier builds.
        let badAmpRPrefix = "GCAAAAAAGCGGTTAGCTCC"
        
        var changed = false
        
        // Walk through EVERY collection and fix known-bad items by name.
        for colIdx in collections.indices {
            for itemIdx in collections[colIdx].items.indices {
                let item = collections[colIdx].items[itemIdx]
                let nameLower = item.name.lowercased()
                let seqUpper = item.sequence.uppercased()
                
                // Fix 1: Any item named "rrnB T1 terminator" or "rrnB T1"
                // whose sequence is the AmpR junk OR is implausibly long.
                if (nameLower == "rrnb t1 terminator" || nameLower == "rrnb t1")
                    && (seqUpper.hasPrefix(badAmpRPrefix) || seqUpper.count > 200) {
                    collections[colIdx].items[itemIdx].sequence = canonicalRrnBT1
                    collections[colIdx].items[itemIdx].name = "rrnB T1 terminator"
                    changed = true
                    continue
                }
                
                // Fix 2: Fix the typo in Generic collection "rrnB T1"
                // (had CAGTCGGAAG where canonical has CAGTCGAAAG).
                // Rename to "rrnB T1 (short)" to distinguish from the full
                // 91 bp "rrnB T1 terminator" elsewhere in the library.
                if nameLower == "rrnb t1" && seqUpper.contains("CAGTCGGAAG") {
                    collections[colIdx].items[itemIdx].sequence = "ATAAAACGAAAGGCTCAGTCGAAAGACTGGGCCTTTCGTTTTAT"
                    collections[colIdx].items[itemIdx].name = "rrnB T1 (short)"
                    changed = true
                    continue
                }
                
                // Fix 3: Rename the vague "rrnB" composite entry for clarity.
                if nameLower == "rrnb" && seqUpper.hasPrefix("TGCCTGGCGGCAGTAGCGCGG") {
                    collections[colIdx].items[itemIdx].name = "rrnB operon 3' end"
                    changed = true
                    continue
                }
                
                // Fix 4: T7 terminator mislabeled (had rrnB T1 sequence).
                if nameLower == "t7 terminator"
                    && seqUpper.contains("CAAATAAAACGAAAGGCTCAGTCG")
                    && !seqUpper.contains("TTGGGGCCTCTAAACGG") {
                    collections[colIdx].items[itemIdx].sequence = canonicalT7term
                    changed = true
                    continue
                }
                
                // Fix 5: EMCV IRES — rename from "IRES (ECMV core)" and replace
                // the 63 bp fragment with the full ~510 bp sequence.
                if nameLower == "ires (ecmv core)" || (nameLower == "emcv ires" && seqUpper.count < 200) {
                    collections[colIdx].items[itemIdx].name = "EMCV IRES"
                    collections[colIdx].items[itemIdx].sequence = canonicalEMCVires
                    changed = true
                    continue
                }
                
                // Fix 6: lox2272 in reverse-complement orientation.
                if nameLower == "lox2272" && seqUpper.contains("GGATACTT") {
                    collections[colIdx].items[itemIdx].sequence = canonicalLox2272
                    changed = true
                    continue
                }
                
                // Fix 7: Rename "lac promoter" to "lac promoter/operator"
                // since the sequence includes both elements.
                if nameLower == "lac promoter" && seqUpper.contains("TTGTGAGCGGATAACAATT") {
                    collections[colIdx].items[itemIdx].name = "lac promoter/operator"
                    changed = true
                    continue
                }
            }
        }
        
        if changed {
            saveCollections()
        }
        UserDefaults.standard.set(currentSchemaVersion, forKey: schemaVersionKey)
    }


    
    // MARK: - Collection Management
    
    func addCollection(name: String) {
        let collection = FeatureCollection(name: name)
        collections.append(collection)
        saveCollections()
    }
    
    func deleteCollection(at index: Int) {
        guard index >= 0 && index < collections.count else { return }
        collections.remove(at: index)
        saveCollections()
    }
    
    func duplicateCollection(at index: Int) {
        guard index >= 0 && index < collections.count else { return }
        var copy = collections[index]
        copy.id = UUID()
        copy.name = "\(copy.name) Copy"
        copy.items = copy.items.map { item in
            var newItem = item
            newItem.id = UUID()
            return newItem
        }
        collections.append(copy)
        saveCollections()
    }
    
    // MARK: - Item Management
    
    func addItem(to collectionIndex: Int, item: FeatureLibraryItem) {
        guard collectionIndex >= 0 && collectionIndex < collections.count else { return }
        collections[collectionIndex].items.append(item)
        saveCollections()
    }

    // MARK: - Duplicate Detection

    /// Returns duplicate info if any collection already contains an item with
    /// the same name (case-insensitive) or identical sequence.
    func isDuplicateItem(_ item: FeatureLibraryItem) -> (isDuplicate: Bool, existingName: String, inCollection: String) {
        for collection in collections {
            for existing in collection.items {
                let sameName = existing.name.caseInsensitiveCompare(item.name) == .orderedSame
                let sameSeq  = !item.sequence.isEmpty &&
                               existing.sequence.uppercased() == item.sequence.uppercased()
                if sameName || sameSeq {
                    return (true, existing.name, collection.name)
                }
            }
        }
        return (false, "", "")
    }

    /// Published so views can observe duplicate detection results directly,
    /// avoiding return-value ambiguity across module boundaries.
    @Published var lastAddWasDuplicate: Bool = false
    @Published var lastDuplicateExistingName: String = ""
    @Published var lastDuplicateInCollection: String = ""

    /// Adds item to "My Features", skipping if it's a duplicate.
    /// Check `lastAddWasDuplicate` afterwards to know the outcome.
    func addToImportedCollection(_ item: FeatureLibraryItem, force: Bool = false) {
        if !force {
            let check = isDuplicateItem(item)
            if check.isDuplicate {
                lastAddWasDuplicate = true
                lastDuplicateExistingName = check.existingName
                lastDuplicateInCollection = check.inCollection
                return
            }
        }
        lastAddWasDuplicate = false
        lastDuplicateExistingName = ""
        lastDuplicateInCollection = ""
        let targetName = "My Features"
        if let idx = collections.firstIndex(where: { $0.name == targetName }) {
            collections[idx].items.append(item)
        } else {
            var newCollection = FeatureCollection(name: targetName)
            newCollection.items.append(item)
            collections.insert(newCollection, at: 0)
        }
        saveCollections()
    }
    
    func updateItem(in collectionIndex: Int, itemIndex: Int, item: FeatureLibraryItem) {
        guard collectionIndex >= 0 && collectionIndex < collections.count,
              itemIndex >= 0 && itemIndex < collections[collectionIndex].items.count else { return }
        collections[collectionIndex].items[itemIndex] = item
        saveCollections()
    }
    
    func deleteItem(from collectionIndex: Int, at itemIndex: Int) {
        guard collectionIndex >= 0 && collectionIndex < collections.count,
              itemIndex >= 0 && itemIndex < collections[collectionIndex].items.count else { return }
        collections[collectionIndex].items.remove(at: itemIndex)
        saveCollections()
    }
    
    func duplicateItem(in collectionIndex: Int, at itemIndex: Int) {
        guard collectionIndex >= 0 && collectionIndex < collections.count,
              itemIndex >= 0 && itemIndex < collections[collectionIndex].items.count else { return }
        var copy = collections[collectionIndex].items[itemIndex]
        copy.id = UUID()
        copy.name = "\(copy.name) Copy"
        collections[collectionIndex].items.append(copy)
        saveCollections()
    }
    
    /// Move a feature item to a different collection
    func moveItem(from sourceCollection: Int, itemIndex: Int, to destCollection: Int) {
        guard sourceCollection != destCollection,
              sourceCollection >= 0 && sourceCollection < collections.count,
              destCollection >= 0 && destCollection < collections.count,
              itemIndex >= 0 && itemIndex < collections[sourceCollection].items.count else { return }
        let item = collections[sourceCollection].items.remove(at: itemIndex)
        collections[destCollection].items.append(item)
        saveCollections()
    }
    
    /// Reorder items within a collection (for drag-and-drop)
    func reorderItems(in collectionIndex: Int, from source: IndexSet, to destination: Int) {
        guard collectionIndex >= 0 && collectionIndex < collections.count else { return }
        collections[collectionIndex].items.move(fromOffsets: source, toOffset: destination)
        saveCollections()
    }
    
    // MARK: - Scanning
    
    /// Build a prefix lookup table: for each of the 256 possible 4-base DNA prefixes,
    /// stores all positions in the sequence where that prefix occurs.
    /// Allows O(1) candidate lookup per feature instead of O(n) scanning.
    private static func buildPrefixTable(_ seqBytes: [UInt8]) -> [[Int]] {
        var table = [[Int]](repeating: [], count: 256)
        let len = seqBytes.count
        guard len >= 4 else { return table }
        seqBytes.withUnsafeBufferPointer { buf in
            let p = buf.baseAddress!
            for i in 0...(len - 4) {
                let b0 = p[i], b1 = p[i+1], b2 = p[i+2], b3 = p[i+3]
                let v0: Int; switch b0 { case 65: v0=0; case 67: v0=1; case 71: v0=2; case 84: v0=3; default: continue }
                let v1: Int; switch b1 { case 65: v1=0; case 67: v1=1; case 71: v1=2; case 84: v1=3; default: continue }
                let v2: Int; switch b2 { case 65: v2=0; case 67: v2=1; case 71: v2=2; case 84: v2=3; default: continue }
                let v3: Int; switch b3 { case 65: v3=0; case 67: v3=1; case 71: v3=2; case 84: v3=3; default: continue }
                table[(v0 << 6) | (v1 << 4) | (v2 << 2) | v3].append(i)
            }
        }
        return table
    }
    
    /// Encode a 4-byte ACGT prefix into 0-255. Returns -1 if any base is non-standard.
    @inline(__always)
    private static func encodePrefix(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8) -> Int {
        let v0: Int; switch b0 { case 65: v0=0; case 67: v0=1; case 71: v0=2; case 84: v0=3; default: return -1 }
        let v1: Int; switch b1 { case 65: v1=0; case 67: v1=1; case 71: v1=2; case 84: v1=3; default: return -1 }
        let v2: Int; switch b2 { case 65: v2=0; case 67: v2=1; case 71: v2=2; case 84: v2=3; default: return -1 }
        let v3: Int; switch b3 { case 65: v3=0; case 67: v3=1; case 71: v3=2; case 84: v3=3; default: return -1 }
        return (v0 << 6) | (v1 << 4) | (v2 << 2) | v3
    }
    
    /// Scan a DNA sequence for all enabled features across all enabled collections.
    func scanSequence(_ dnaSequence: DNASequence) {
        isScanning = true
        scanProgress = 0.0
        scanResults.removeAll()
        
        let forwardSeq = dnaSequence.sequence.uppercased()
        let seqLen     = forwardSeq.count
        let isCircular = dnaSequence.isCircular
        let collectionsSnapshot = collections
        let threshold   = similarityThreshold
        let minApproxLen = minLengthForApproximate
        
        let enabledDNAItems = collectionsSnapshot
            .filter(\.scanEnabled).flatMap(\.items)
            .filter { $0.scanEnabled && !$0.sequence.isEmpty && !$0.isPeptide }
        let maxQueryLen = enabledDNAItems.map(\.sequence.count).max() ?? 0
        
        let fwdScanSeq: String
        if isCircular && maxQueryLen > 1 {
            fwdScanSeq = forwardSeq + String(forwardSeq.prefix(min(maxQueryLen - 1, seqLen)))
        } else {
            fwdScanSeq = forwardSeq
        }
        
        let seqBytes = Array(fwdScanSeq.utf8)
        let totalItems = collectionsSnapshot
            .filter(\.scanEnabled).flatMap(\.items)
            .filter { $0.scanEnabled && !$0.sequence.isEmpty }.count
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let startTime = CFAbsoluteTimeGetCurrent()
            var results: [ScanResult] = []
            var completed = 0
            
            // Pre-compute translations for peptide scanning (once)
            let translations: [(frame: Int, protein: String)] = [
                (1, dnaSequence.translate(frame: 1)),
                (2, dnaSequence.translate(frame: 2)),
                (3, dnaSequence.translate(frame: 3)),
                (-1, dnaSequence.translate(frame: -1)),
                (-2, dnaSequence.translate(frame: -2)),
                (-3, dnaSequence.translate(frame: -3))
            ]
            let seqLength = dnaSequence.length
            
            // Build prefix table ONCE — maps each 4-base prefix → positions
            let prefixTable = Self.buildPrefixTable(seqBytes)
            
            for collection in collectionsSnapshot {
                guard collection.scanEnabled else { continue }
                for item in collection.items {
                    guard item.scanEnabled && !item.sequence.isEmpty else { continue }
                    
                    if item.isPeptide {
                        Self.scanPeptide(item: item, collectionName: collection.name,
                                         translations: translations, seqLength: seqLength,
                                         into: &results)
                    } else {
                        let query = item.sequence.uppercased()
                        Self.findAllOccurrences(
                            of: query, seqBytes: seqBytes, prefixTable: prefixTable,
                            strand: .forward, item: item, collectionName: collection.name,
                            originalSeqLength: seqLen, isCircularScan: isCircular,
                            into: &results, threshold: threshold, minApproxLen: minApproxLen)
                        
                        if !item.senseStrandOnly {
                            let rcQuery = Self.reverseComplementQuery(query)
                            Self.findAllOccurrences(
                                of: rcQuery, seqBytes: seqBytes, prefixTable: prefixTable,
                                strand: .reverse, item: item, collectionName: collection.name,
                                originalSeqLength: seqLen, isCircularScan: isCircular,
                                into: &results, threshold: threshold, minApproxLen: minApproxLen)
                        }
                    }
                    completed += 1
                    if completed % 20 == 0 || completed == totalItems {
                        let progress = Double(completed) / Double(max(totalItems, 1))
                        DispatchQueue.main.async { self.scanProgress = progress }
                    }
                }
            }
            
            // De-duplicate
            var seen = Set<String>()
            results = results.filter { r in
                let key = "\(r.libraryItem.name)|\(r.start)|\(r.end)|\(r.strand)"
                return seen.insert(key).inserted
            }
            results.sort { $0.start < $1.start }
            
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            #if DEBUG
            print("Scan complete: \(results.count) feature(s) found in \(String(format: "%.2f", elapsed))s")
            #endif
            for r in results {
                #if DEBUG
                print("  \(r.libraryItem.name) @ \(r.start)-\(r.end) (\(r.matchPercentage)%) strand: \(r.strand)")
                #endif
            }
            
            DispatchQueue.main.async {
                self.scanResults = results
                self.scanProgress = 1.0
                self.applyResults(to: dnaSequence, results: results)
                self.isScanning = false
            }
        }
    }
    
    // MARK: - Static scanning helpers
    
    private static func findAllOccurrences(
        of query: String,
        seqBytes: [UInt8],
        prefixTable: [[Int]],
        strand: Strand,
        item: FeatureLibraryItem,
        collectionName: String,
        originalSeqLength: Int,
        isCircularScan: Bool,
        into results: inout [ScanResult],
        threshold: Double,
        minApproxLen: Int
    ) {
        let queryBytes = Array(query.utf8)
        let qLen = queryBytes.count
        let sLen = seqBytes.count
        guard qLen > 0, sLen >= qLen else { return }
        
        var foundExact = false
        
        // Get candidate positions via prefix table (O(1) lookup)
        let candidates: [Int]
        if qLen >= 4 {
            let code = encodePrefix(queryBytes[0], queryBytes[1], queryBytes[2], queryBytes[3])
            if code >= 0 {
                // Pure ACGT prefix — lookup candidates directly
                candidates = prefixTable[code].filter { $0 + qLen <= sLen }
            } else {
                // IUPAC in first 4 bases — must check all positions
                candidates = Array(0...(sLen - qLen))
            }
        } else {
            candidates = Array(0...(sLen - qLen))
        }
        
        let hasIUPAC = queryBytes.contains(where: { ![65, 67, 71, 84].contains($0) })
        
        // ═══ Exact matching at candidate positions ═══
        queryBytes.withUnsafeBufferPointer { qBuf in
            seqBytes.withUnsafeBufferPointer { sBuf in
                let qPtr = qBuf.baseAddress!
                let sPtr = sBuf.baseAddress!
                
                if !hasIUPAC {
                    // Pure ACGT — memcmp (skip first 4 bytes already matched by prefix)
                    let skip = min(4, qLen)
                    for pos in candidates {
                        if qLen <= 4 || memcmp(sPtr + pos + skip, qPtr + skip, qLen - skip) == 0 {
                            foundExact = true
                            appendResult(pos: pos, queryLen: qLen, strand: strand,
                                         originalSeqLength: originalSeqLength,
                                         isCircularScan: isCircularScan,
                                         item: item, collectionName: collectionName,
                                         matchPct: 100.0, into: &results)
                        }
                    }
                } else {
                    // IUPAC — basesMatch
                    for pos in candidates {
                        var isMatch = true
                        for j in 0..<qLen {
                            if !basesMatch(queryBase: qPtr[j], targetBase: sPtr[pos + j]) {
                                isMatch = false
                                break
                            }
                        }
                        if isMatch {
                            foundExact = true
                            appendResult(pos: pos, queryLen: qLen, strand: strand,
                                         originalSeqLength: originalSeqLength,
                                         isCircularScan: isCircularScan,
                                         item: item, collectionName: collectionName,
                                         matchPct: 100.0, into: &results)
                        }
                    }
                }
            }
        }
        
        // ═══ Approximate matching ═══
        if !foundExact && threshold < 1.0 && qLen >= minApproxLen {
            // Gather wider candidates using multiple prefix positions across query
            var approxCandidates = Set<Int>()
            let step = max(1, (qLen - 4) / 8)
            var offset = 0
            while offset <= qLen - 4 {
                let code = encodePrefix(queryBytes[offset], queryBytes[offset+1],
                                        queryBytes[offset+2], queryBytes[offset+3])
                if code >= 0 {
                    for seqPos in prefixTable[code] {
                        let startPos = seqPos - offset
                        if startPos >= 0 && startPos + qLen <= sLen {
                            approxCandidates.insert(startPos)
                        }
                    }
                }
                offset += step
            }
            
            let requiredMatches = Int(ceil(Double(qLen) * threshold))
            let maxMismatches   = qLen - requiredMatches
            
            queryBytes.withUnsafeBufferPointer { qBuf in
                seqBytes.withUnsafeBufferPointer { sBuf in
                    let qPtr = qBuf.baseAddress!
                    let sPtr = sBuf.baseAddress!
                    for i in approxCandidates {
                        var matches = 0, mismatches = 0, earlyExit = false
                        for j in 0..<qLen {
                            if basesMatch(queryBase: qPtr[j], targetBase: sPtr[i + j]) {
                                matches += 1
                            } else {
                                mismatches += 1
                                if mismatches > maxMismatches { earlyExit = true; break }
                            }
                        }
                        if !earlyExit {
                            let similarity = Double(matches) / Double(qLen)
                            if similarity >= threshold {
                                appendResult(pos: i, queryLen: qLen, strand: strand,
                                             originalSeqLength: originalSeqLength,
                                             isCircularScan: isCircularScan,
                                             item: item, collectionName: collectionName,
                                             matchPct: (similarity * 1000.0).rounded() / 10.0,
                                             into: &results)
                            }
                        }
                    }
                }
            }
        }
    }
    
    /// Append a scan result, handling circular wrapping.
    private static func appendResult(
        pos: Int,
        queryLen: Int,
        strand: Strand,
        originalSeqLength: Int,
        isCircularScan: Bool,
        item: FeatureLibraryItem,
        collectionName: String,
        matchPct: Double,
        into results: inout [ScanResult]
    ) {
        let start = pos
        var end   = pos + queryLen
        
        // For circular scans, wrap positions back into [0, seqLength)
        if isCircularScan {
            // Skip hits entirely in the appended overlap region (duplicates of
            // hits already found starting within the real sequence).
            if start >= originalSeqLength {
                return
            }
            // A hit that spans the origin: the match genuinely crosses position 0.
            // Clamp end to the sequence length so the feature runs to the end of
            // the sequence rather than wrapping to a small number — this prevents
            // end < start, which would be interpreted as a full-circle feature by
            // the graphics and duplicate-check code.
            if end > originalSeqLength {
                end = originalSeqLength
            }
        }
        
        results.append(ScanResult(
            libraryItem: item,
            collectionName: collectionName,
            start: start,
            end: end,
            strand: strand,
            matchPercentage: matchPct
        ))
    }
    
    /// IUPAC-aware base comparison. Ambiguity codes in BOTH the query (library)
    /// AND the target sequence are handled correctly via bitwise set intersection.
    @inline(__always)
    static func basesMatch(queryBase: UInt8, targetBase: UInt8) -> Bool {
        if queryBase == targetBase { return true }
        
        // Fast path: both are standard bases (A/C/G/T) and they differ → no match
        let qStandard = queryBase == 65 || queryBase == 67 || queryBase == 71 || queryBase == 84
        let tStandard = targetBase == 65 || targetBase == 67 || targetBase == 71 || targetBase == 84
        
        if qStandard && tStandard {
            return false
        }
        
        // At least one is an IUPAC ambiguity code — expand and intersect
        let qSet = expandIUPAC(queryBase)
        let tSet = expandIUPAC(targetBase)
        return (qSet & tSet) != 0
    }
    
    /// Expand an IUPAC base to a bit-flag set.
    /// A=1, C=2, G=4, T=8. Ambiguity codes are OR combinations.
    @inline(__always)
    private static func expandIUPAC(_ base: UInt8) -> UInt8 {
        switch base {
        case 65:        return 0b0001  // A
        case 67:        return 0b0010  // C
        case 71:        return 0b0100  // G
        case 84, 85:    return 0b1000  // T (and U)
        case 82:        return 0b0101  // R = A|G
        case 89:        return 0b1010  // Y = C|T
        case 83:        return 0b0110  // S = G|C
        case 87:        return 0b1001  // W = A|T
        case 75:        return 0b1100  // K = G|T
        case 77:        return 0b0011  // M = A|C
        case 66:        return 0b1110  // B = C|G|T (not A)
        case 68:        return 0b1101  // D = A|G|T (not C)
        case 72:        return 0b1011  // H = A|C|T (not G)
        case 86:        return 0b0111  // V = A|C|G (not T)
        case 78:        return 0b1111  // N = any
        default:        return 0
        }
    }
    
    // MARK: - IUPAC Reverse Complement
    
    /// Returns the reverse complement of a DNA query, correctly complementing
    /// IUPAC ambiguity codes (e.g. R↔Y, K↔M, S↔S, W↔W, B↔V, D↔H).
    static func reverseComplementQuery(_ query: String) -> String {
        let complemented = query.uppercased().reversed().map { ch -> Character in
            iupacComplement(ch)
        }
        return String(complemented)
    }
    
    /// Complement a single IUPAC character.
    private static func iupacComplement(_ base: Character) -> Character {
        switch base {
        case "A": return "T"
        case "T": return "A"
        case "C": return "G"
        case "G": return "C"
        case "U": return "A"
        case "R": return "Y"
        case "Y": return "R"
        case "S": return "S"
        case "W": return "W"
        case "K": return "M"
        case "M": return "K"
        case "B": return "V"
        case "V": return "B"
        case "D": return "H"
        case "H": return "D"
        case "N": return "N"
        default:  return base
        }
    }
    
    // MARK: - Peptide Scanning
    
    /// Scan pre-computed translations for a peptide feature.
    /// Translations are computed once before the loop, not per-feature.
    private static func scanPeptide(
        item: FeatureLibraryItem,
        collectionName: String,
        translations: [(frame: Int, protein: String)],
        seqLength: Int,
        into results: inout [ScanResult]
    ) {
        let query = item.sequence.uppercased()
        
        for (frame, protein) in translations {
            // Skip reverse frames if sense-only
            if frame < 0 && item.senseStrandOnly { continue }
            
            let isForward = frame > 0
            var searchRange = protein.startIndex..<protein.endIndex
            
            while let range = protein.range(of: query, range: searchRange) {
                let aaPos = protein.distance(from: protein.startIndex, to: range.lowerBound)
                
                if isForward {
                    let dnaStart = (frame - 1) + aaPos * 3
                    let dnaEnd = dnaStart + query.count * 3 - 1  // inclusive end
                    results.append(ScanResult(
                        libraryItem: item,
                        collectionName: collectionName,
                        start: dnaStart,
                        end: dnaEnd,
                        strand: .forward,
                        matchPercentage: 100.0
                    ))
                } else {
                    let rcStart = (abs(frame) - 1) + aaPos * 3
                    let rcEnd = rcStart + query.count * 3 - 1    // inclusive end
                    let dnaStart = seqLength - rcEnd - 1
                    let dnaEnd = seqLength - rcStart - 1
                    results.append(ScanResult(
                        libraryItem: item,
                        collectionName: collectionName,
                        start: max(0, dnaStart),
                        end: min(dnaEnd, seqLength - 1),
                        strand: .reverse,
                        matchPercentage: 100.0
                    ))
                }
                searchRange = range.upperBound..<protein.endIndex
            }
        }
    }
    
    /// Apply scan results as features on the given sequence
    func applyResults(to sequence: DNASequence, results: [ScanResult]) {
        for result in results {
            let feature = Feature(
                name: result.libraryItem.name,
                type: result.libraryItem.featureType,
                start: result.start,
                end: result.end,
                strand: result.strand,
                color: result.libraryItem.color,
                showArrow: result.libraryItem.showArrow,
                source: .scanned
            )
            // Check for existing feature that is effectively the same:
            //  - same start AND end (same location, regardless of name), OR
            //  - same name AND positions overlap
            let isDuplicate = sequence.features.contains { existing in
                // Exact position match (same feature, possibly different name)
                if existing.start == feature.start && existing.end == feature.end {
                    return true
                }
                // Same name with overlapping positions
                if existing.name.caseInsensitiveCompare(feature.name) == .orderedSame {
                    let overlapStart = max(existing.start, feature.start)
                    let overlapEnd = min(existing.end, feature.end)
                    if overlapEnd > overlapStart { return true }
                }
                return false
            }
            if isDuplicate {
                // Update existing exact-position match with library styling if present
                if let existingIdx = sequence.features.firstIndex(where: {
                    $0.start == feature.start && $0.end == feature.end
                }) {
                    sequence.features[existingIdx].color = result.libraryItem.color
                    sequence.features[existingIdx].type = result.libraryItem.featureType
                    sequence.features[existingIdx].showArrow = result.libraryItem.showArrow
                }
            } else {
                sequence.features.append(feature)
            }
        }
    }
    
    // MARK: - Persistence
    
    func saveCollections() {
        if let data = try? JSONEncoder().encode(collections) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
    
    func loadCollections() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([FeatureCollection].self, from: data) else {
            return
        }
        collections = decoded
    }
    
    // MARK: - Default Collections
    
    func loadDefaultCollections() {
        collections = [
            FeatureCollection(name: "Origins of replication", scanEnabled: true, items: [
                FeatureLibraryItem(name: "2µ ori", sequence: "TAATATATAGCTCTAGCGCTTTACGGAAGACAATGTATGTATTTCGGTTCCTGGAGAAACTATTGCATCTATTGCATAGGTTAATCTTGCACGTCGCATCCCCGGTTCATTTCTGCGTTTCCATCTTGCACTTCAATAGCATATCTTTGTTAACGAAGCATCTGTGCTTCATTTTGTAGAACAAAAATGCAACGCGAGAGCGCTAATTTTTCAAACAAAGAATCTGAGCTGCATTTTTACAGAACAGAAATGCAACGCGAAAGCGCTATTTTACCAACGAAGAATCTGTGCTTCATTTTTGTAAAACAAAAATGCAACGCGAGAGCGCTAATTTTTCAAACAAAGAATCTGAGCTGCATTTTTACAGAACAGAAATGCAACGCGAGAGCGCTATTTTACCAACAAAGAATCTATACTTCTTTTTTGTTCTACAAAAATGCATCCCGAGAGCGCTATTTTTCTAACAAAGCATCTTAGATTACTTTTTTTCTCCTTTGTGCGCTCTATAATGCAGTCTCTTGATAACTTTTTGCACTGTAGGTCCGTTAAGGTTAGAAGAAGGCTACTTTGGTGTCTATTTTCTCTTCCATAAAAAAAGCCTGACTCCACTTCCCGCGTTTACTGATTACTAGCGAAGCTGCGGGTGCATTTTTTCAAGATAAAGGCATCCCCGATTATATTCTATACCGATGTGGATTGCGCATACTTTGTGAACAGAAAGTGATAGCGTTGATGATTCTTCATTGGTCAGAAAATTATGAACGGTTTCTTCTATTTTGTCTCTATATACTACGTATAGGAAATGTTTACATTTTCGTATTGTTTTCGATTCACTCTATGAATAGTTCTTACTACAATTTTTTTGTCTAAAGAGTAATACTAGAGATAAACATAAAAA", isPeptide: false, comments: "High-copy yeast 2-micron plasmid origin; ~70 copies/cell. From S. cerevisiae 2µ plasmid J01347.1.", color: CodableColor(red: 1.000, green: 0.800, blue: 0.000), showArrow: true, featureType: .origin, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "CEN6-ARS4 ori", sequence: "AAAAGTGCCACCTGGGTCCTTTTCATCACGTGCTATAAAAATAATTATAATTTAAATTTTTTAATATAAATATATAAATTAAAAATAGAAAGTAAAAAAAGAAATTAAAGAAAAAATAGTTTTTGTTTTCCGAAGATGTAAAAGACTCTAGGGGGATCGC", isPeptide: false, comments: "Low-copy yeast centromeric origin; ~1 copy/cell. CEN6 + ARSH4 element from pRS316.", color: CodableColor(red: 1.000, green: 0.800, blue: 0.000), showArrow: true, featureType: .origin, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "ColE1 ori", sequence: "CGCAGCCATGACCCAGTCACGTAGCGATAGCGGAGTGTATACTGGCTTAACTATGCGGCATCAGAGCAGATTGTACTGAGAGTGCACCATATGCGGTGTGAAATACCGCACAGATGCGTAAGGAGAAAATACCGCATCAGGCGCTCTTCCGCTTCCTCGCTCACTGACTCGCTGCGCTCGGTCGTTCGGCTGCGGCGAGCGGTATCAGCTCACTCAAAGGCGGTAATACGGTTATCCACAGAATCAGGGGATAACGCAGGAAAGAACATGTGAGCAAAAGGCCAGCAAAAGGCCAGGAACCGTAAAAAGGCCGCGTTGCTGGCGTTTTTCCATAGGCTCCGCCCCCCTGACGAGCATCACAAAATCGACGCTCAAGTCAGAGGTGGCGAAACCCGACAGGACTATAAAGATACCAGGCGTTTCCCCCTGGAAGCTCCCTCGTGCGCTCTCCTGTTCCGACCCTGCCGCTTACCGGATACCTGTCCGCCTTTCTCCCTTCGGGAAGCGTGGCGCTTTCTCATAGCTCACGCTGTAGGTATCTCAGTTCGG", isPeptide: false, comments: "Medium-copy E. coli origin; ~20 copies/cell. Parent of pBR322 and related vectors. From pBR322 J01749.", color: CodableColor(red: 1.000, green: 0.800, blue: 0.000), showArrow: true, featureType: .origin, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "F1 ori", sequence: "GTTAATATTTTGTTAAAATTCGCGTTAAATTTTTGTTAAATCAGCTCATTTTTTAACCAATAGGCCGAAATCGGCAAAATCCCTTATAAATCAAAAGAATAGACCGAGATAGGGTTGAGTGTTGTTCCAGTTTGGAACAAGAGTCCACTATTAAAGAACGTGGACTCCAACGTCAAAGGGCGAAAAACCGTCTATCAGGGCGATGGCCCACTACGTGAACCATCACCCTAATCAAGTTTTTTGGGGTCGAGGTGCCGTAAAGCACTAAATCGGAACCCTAAAGGGAGCCCCCGATTTAGAGCTTGACGGGGAAAGCCGGCGAACGTGGCGAGAAAGGAAGGGAAGAAAGCGAAAGGAGCGGGCGCTAGGGCGCTGGCAAGTGTAGCGGTCACGCTGCGCGTAACCACCACACCCGCCGCGCTTAATGCGCCGCTACAGGGCGCGTCGCGCCATT", isPeptide: false, comments: "Filamentous phage origin from pRS316/pBluescript backbone; enables ssDNA production with helper phage.", color: CodableColor(red: 1.000, green: 0.800, blue: 0.000), showArrow: true, featureType: .origin, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "M13 ori", sequence: "ACGCGCCCTGTAGCGGCGCATTAAGCGCGGCGGGTGTGGTGGTTACGCGCAGCGTGACCGCTACACTTGCCAGCGCCCTAGCGCCCGCTCCTTTCGCTTTCTTCCCTTCCTTTCTCGCCACGTTCGCTTTCCCCGTCAAGCTCTAAATCGGGGGCTCCCTTTAGGGTTCCGATTTAGTGCTTTACGGCACCTCGACCCCAAAAAACTTGATTCGGGTGATGGTTCACGTAGTGGGCCATCGCCCTGATAGACGGTTTTTCGCCCTTTGACGTTGGAGTCCACGTTCTTTAATAGTGGACTCTTGTTCCAAACTGGAACAACACTCAACCCTATCTCGGCCTATTCTTTTGATTTATAAGGGATTTTGCCGATTTCGGCCTATTGGTTAAAAAATGAGCTGATTTAACAAAAATTTAACGCGAATTTTAACAAAATATTAACGTTTACAATTT", isPeptide: false, comments: "M13 phage intergenic region; closely related to F1 ori. Enables ssDNA production in M13-based vectors.", color: CodableColor(red: 1.000, green: 0.800, blue: 0.000), showArrow: true, featureType: .origin, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "oriS", sequence: "CTTCTGAGGGCAATTTGTCACAGGGTTAAGGGCAATTTGTCACAGACAGGACTGTCATTTGAGGGTGATTTGTCACACTGAAAGGGCAATTTGTCACAACACCTTCTCTAGAACCAGCATGGATAAAGGCCTACAAGGCGCTCTAAAAAAGAAGATCTAAAAACTATAAAAAAAATAATTATAAAAATATCCCCGTGGATAAGTGGATAACCCCAAGGGAAGTTTTTTCAGGCATCGTGTGTAAGCAGAATATATAAGTGCTGTTCCCTGGTGCTTCCTCGCTCACTCGA", isPeptide: false, comments: "Low-copy F-plasmid origin used in BAC and fosmid vectors. Requires RepE protein for replication.", color: CodableColor(red: 1.000, green: 0.800, blue: 0.000), showArrow: true, featureType: .origin, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "p15A ori", sequence: "GCGAAACGATCCTCATCCTGTCTCTTGATCAGATCTTGATCCCCTGCGCCATCAGATCCTTGGCGGCAAGAAAGCCATCCAGTTTACTTTGCAGGGCTTCCCAACCTTACCAGAGGGCGCCCCAGCTGGCAATTCCGGTTCGCTTGCTGTCCATAAAACCGCCCAGTCTAGCTATCGCCATGTAAGCCCACTGCAAGCTACCTGCTTTCTCTTTGCGCTTGCGTTTTCCCTTGTCCAGATAGCCCAGTAGCTGACATTCATCCGGGGTCAGCACCGTTTCTGCGGACTGGCTTTCTACGTGTTCCGCTTCCTTTAGCAGCCCTTGCGCCCTGAGTGCTTGCGGCAGCGTGAAGCTA", isPeptide: false, comments: "Low-copy E. coli origin; ~10-12 copies/cell. Compatible with ColE1. Used in pACYC and duet vectors.", color: CodableColor(red: 1.000, green: 0.800, blue: 0.000), showArrow: true, featureType: .origin, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "pUC ori", sequence: "TCGCGCGTTTCGGTGATGACGGTGAAAACCTCTGACACATGCAGCTCCCGGAGACGGTCACAGCTTGTCTGTAAGCGGATGCCGGGAGCAGACAAGCCCGTCAGGGCGCGTCAGCGGGTGTTGGCGGGTGTCGGGGCTGGCTTAACTATGCGGCATCAGAGCAGATTGTACTGAGAGTGCACCACGCTTTTCAATTCAATTCATCATTTTTTTTTTATTCTTTTTTTTGATTTCGGTTTCTTTGAAATTTTTTTGATTCGGTAATCTCCGAACAGAAGGAAGAACGAAGGAAGGAGCACAGACTTAGATTGGTATATATACGCATATGTAGTGTTGAAGAAACATGAAATTGCCCAGTATTCTTAACCCAACTGCACAGAACAAAAACCTGCAGGAAACGAAGATAAATCATGTCGAAAGCTACATATAAGGAACGTGCTGCTACTCATCCTAGTCCTGTTGCTGCCAAGCTATTTAATATCATGCACGAAAAGCAAACAAACTTGTGTGCTTCATTGGATGTTCGTACCACCAAGGAATTACTGGAGTT", isPeptide: false, comments: "High-copy E. coli origin; ~500 copies/cell. Mutant ColE1 lacking Rop. Used in pUC, pBluescript, pRS series.", color: CodableColor(red: 1.000, green: 0.800, blue: 0.000), showArrow: true, featureType: .origin, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "pVS1 oriV", sequence: "GTTTTCCGTCTGTCGAAGCGTGACCGACGAGCTGGCGAGGTGATCCGCTACGAGCTTCCAGACGGGCACGTAGAGGTTTCCGCAGGGCCGGCCGGCATGGCCAGTGTGTGGGATTACGACCTGGTACTGATGGCGGTTTCCCATCTAACCGAATCCATGAACCGATACCGGGAAGGGAAGGGAGACAAGCCCGGCCGCGTGTTCCGTCCACACGTTGCGGACGTACTCAAGTTCTGCCGGCGAGCCGATGGCGGAAAGCAGAAAGACGACCTGGTAGAAACCTGCATTCGGTTAAACACCACGCACGTTGCCATGCAGCGTACGAAGAAGGCCAAGAACGGCCGCCTGGTGACGGTATCCGAGGGTGAAGCCTTGATTAGCCGCTACAAGATCGTAAAGAGCGAAACCGGGCGGCCGGAGTACATCGAGATCGAGCTAGCTGATTGGATGTACCGCGAGATCACAGAAGGCAAGAACCCGGACGTGCTGACGGTTCACCCCGATTACTTTTTGATCGATCCCGGCATCGGCCGTTTTCTCTACCGCCTGGCACGCCGCGCCGCAGGCAAGGCAGAAGCCAGATGGTTGTTCAAGACGATCTACGAACGCAGTGGCAGCGCCGGAGAGTTCAAGAAGTTCTGTTTCACCGTGCGCAAGCTGATCGGGTCAAATGACCTGCCGGAGTACGATTTGAAGGAGGAGGCGGGGCAGGCTGGCCCGATCCTAGTCATGCGCTACCGCAACCTGATCGAGGGCGAAGCATCCGCCGGTTCCTAATGTACGGAGCAGATGCTAGGGCAAATTGCCCTAGCAGGGGAAAAAGGTCGAAAAGGTCTCTTTCCTGTGGATAGCACGTACATTGGGAACCCAAAGCCGTACATTGGGAACCGGAACCCGTACATTGGGAACCCAAAGCCGTACATTGGGAACCGGTCACACATGTAAGTGACTGATATAAAAGAGAAAAAAGGCGATTTTTCCGCCTAAAACTCTTTAAAACT", isPeptide: false, comments: "Agrobacterium tumefaciens origin; used in pCAMBIA and pPZP binary vectors for plant transformation.", color: CodableColor(red: 1.000, green: 0.800, blue: 0.000), showArrow: true, featureType: .origin, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "R6K ori", sequence: "GTGTTCCTGTGTCACTCAAAATTGCTTTGAGAGGCTCTAAGGGCTTCTCAGTGCGTTACATCCCTGGCTTGTTGTCCACAACCGTTAAACCTTAAAAGCTTTAAAAGCCTTATATATTCTTTTTTTTCTTATAAAACTTAAAACCTTAGAGGCTATTTAAGTTGCTGATTTATATTAATTTTATTGTTCAAACATGAGAGCTTAGTACGTGAAACATGAGAGCTTAGTACGTTAGCCATGAGAGCTTAGTACGTTAGCCATGAGGGTTTAGTTCGTTAAACATGAGAGCTTAGTACGTTAAACATGAGAGCTTAGTACGTGAAACATGAGAGCTTAGTACGTACTATCAACAGGTTGAACTGCTGATCTTCAGATCCTCTACGCCGGACGCATCGTGGCCGGAT", isPeptide: false, comments: "Conditional E. coli origin; requires π protein (pir gene). Used in suicide and transposon delivery vectors.", color: CodableColor(red: 1.000, green: 0.800, blue: 0.000), showArrow: true, featureType: .origin, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "RK2 oriV", sequence: "TGACACTTGAGGGGCGTTTAGAGCGAGCCAGGAAAGCCGACCCCCTCCTTGGAGTAAAAACCCTTGCGGCGTTGCAGCCGGCACGGATCTTCCGATCGGGCGCGGTGGTGGCCGCGTCTGTGACCTAAAAAGGGGGGAGTCCAGAGGGGCGCAGCCCCTTTGGGCATAGCGCAGCGTAATCGGAGACGTAATTGAGCATTTCCAGGCGCTTGCGCCTGGTCAACGAAAGAGTCAGCGCCGTAGGCGCTGCCATTTTTGGGGTGAGGCCGTTCGCGGCCGAGGGGCGCAGCCCCTGGGGGGATGGGAGGCCCGCGTTAGCGGGCCGGGAGGGTTCGAGAAGGGGGGGCACCCCCCTTCGGCGTGCGCGGTCACGCGCCAGGGCGCAGCCCTGGTTAAAAACAAGGTTTATAAATATTGGTTTAAAAGCAGGTTAAAAGACAGGTTAGCGGTGGCCGAAAAACGGGCGGAAACCCTTGCAAATGCTGGATTTTCTGCCTGTGGACAGCCCCTCAAATGTCAATAGGTGCGCCCCTCATCTGTCATCACTCTGCCCCTCAAGTGTCAAGGATCGCGCCCCTCATCTGTCAGTAGTCGCGCCCCTCAAGTGTCAATACCGCAGGGCACTTATCCCCAGGCTTGTCCACATCATCTGTGGGAAACTCGCGTAAAATCAGGCGTTTTCGCCGATTTGCGAGGCTGGCCAGCTCCACGTCGCCGGCCGAAATCGAGCCTGCCCCTCATCTGTCAACGCCGCGCCGGGTGAGTCGGCCCCTCAAGTGTCAACGTCCGCCCCTCATCTGTCAGTGAGGGCCAAGTTTTCCGCGTGGTATCCACAACGCCGGCGGCCGCGGTGTCTCGCACACGGCTTCGACGGCGTTTCTGGCGCGTTTGCAGGGCCATAGACGGCCGCCAGCCCAGCGGCGAGGGCAACCAGCCCGGTGAGCGTCGGAAAGGCGCTGGAAGCCCCGTAGCGACGCGGAGAGGGGCGAGACAAGCCAAGGGCGCAGGCTCGATGCGCAGCACGACATAGCCGGTTCTCGCAAGGACGAGAATTTCCCTGCGGTGCCCCTCAAGTGTCAA", isPeptide: false, comments: "Broad host-range origin; replicates in most Gram-negative bacteria including Agrobacterium.", color: CodableColor(red: 1.000, green: 0.800, blue: 0.000), showArrow: true, featureType: .origin, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "SV40 ORI", sequence: "ATCCCGCCCCTAACTCCGCCCAGTTCCGCCCATTCTCCGCCCCATGGCTGACTAATTTTTTTTATTTATGCAGAGGCC", isPeptide: false, comments: "Mammalian/viral origin; requires SV40 Large T antigen. Used in transient expression in COS cells.", color: CodableColor(red: 1.000, green: 0.800, blue: 0.000), showArrow: true, featureType: .origin, scanEnabled: true, senseStrandOnly: false),
            ]),
            FeatureCollection(name: "Selection markers", scanEnabled: true, items: [
                FeatureLibraryItem(name: "ADE2", sequence: "ATGGATTCTAGAACAGTTGGTATATTAGGAGGGGGACAATTGGGACGTATGATTGTTGAGGCAGCAAACAGGCTCAACATTAAGACGGTAATACTAGATGCTGAAAATTCTCCTGCCAAACAAATAAGCAACTCCAATGACCACGTTAATGGCTCCTTTTCCAATCCTCTTGATATCGAAAAACTAGCTGAAAAATGTGATGTGCTAACGATTGAGATTGAGCATGTTGATGTTCCTACACTAAAGAATCTTCAAGTAAAACATCCCAAATTAAAAATTTACCCTTCTCCAGAAACAATCAGATTGATACAAGACAAATATATTCAAAAAGAGCATTTAATCAAAAATGGTATAGCAGTTACCCAAAGTGTTCCTGTGGAACAAGCCAGTGAGACGTCCCTATTGAATGTTGGAAGAGATTTGGGTTTTCCATTCGTCTTGAAGTCGAGGACTTTGGCATACGATGGAAGAGGTAACTTCGTTGTAAAGAATAAGGAAATGATTCCGGAAGCTTTGGAAGTACTGAAGGATCGTCCTTTGTACGCCGAAAAATGGGCACCATTTACTAAAGAATTAGCAGTCATGATTGTGAGATCTGTTAACGGTTTAGTGTTTTCTTACCCAATTGTAGAGACTATCCACAAGGACAATATTTGTGACTTATGTTATGCGCCTGCTAGAGTTCCGGACTCCGTTCAACTTAAGGCGAAGTTGTTGGCAGAAAATGCAATCAAATCTTTTCCCGGTTGTGGTATATTTGGTGTGGAAATGTTCTATTTAGAAACAGGGGAATTGCTTATTAACGAAATTGCCCCAAGGCCTCACAACTCTGGACATTATACCATTGATGCTTGCGTCACTTCTCAATTTGAAGCTCATTTGAGATCAATATTGGATTTGCCAATGCCAAAGAATTTCACATCTTTCTCCACCATTACAACGAACGCCATTATGCTAAATGTTCTTGGAGACAAACATACAAAAGATAAAGAGCTAGAAACTTGCGAAAGAGCATTGGCGACTCCAGGTTCCTCAGTGTACTTATATGGAAAAGAGTCTAGACCTAACAGAAAAGTAGGTCACATAAATATTATTGCCTCCAGTATGGCGGAATGTGAACAAAGGCTGAACTACATTACAGGTAGAACTGATATTCCAATCAAAATCTCTGTCGCTCAAAAGTTGGACTTGGAAGCAATGGTCAAACCATTGGTTGGAATCATCATGGGATCAGACTCTGACTTGCCGGTAATGTCTGCCGCATGTGCGGTTTTAAAAGATTTTGGCGTTCCATTTGAAGTGACAATAGTCTCTGCTCATAGAACTCCACATAGGATGTCAGCATATGCTATTTCCGCAAGCAAGCGTGGAATTAAAACAATTATCGCTGGAGCTGGTGGGGCTGCTCACTTGCCAGGTATGGTGGCTGCAATGACACCACTTCCTGTCATCGGTGTGCCCGTAAAAGGTTCTTGTCTAGATGGAGTAGATTCTTTACATTCAATTGTGCAAATGCCTAGAGGTGTTCCAGTAGCTACCGTCGCTATTAATAATAGTACGAACGCTGCGCTGTTGGCTGTCAGACTGCTTGGCGCTTATGATTCAAGTTATACAACGAAAATGGAACAGTTTTTATTAAAGCAAGAAGAAGAAGTTCTTGTCAAAGCACAAAAGTTAGAAACTGTCGGTTACGAAGCTTATCTAGAAAACAAGTAA", isPeptide: false, comments: "Phosphoribosylaminoimidazole carboxylase; adenine biosynthesis. S. cerevisiae auxotrophic marker (YOR128C). 571aa.", color: CodableColor(red: 0.200, green: 0.400, blue: 0.800), showArrow: true, featureType: .cds, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "AmpR", sequence: "ATGAGTATTCAACATTTCCGTGTCGCCCTTATTCCCTTTTTTGCGGCATTTTGCCTTCCTGTTTTTGCTCACCCAGAAACGCTGGTGAAAGTAAAAGATGCTGAAGATCAGTTGGGTGCACGAGTGGGTTACATCGAACTGGATCTCAACAGCGGTAAGATCCTTGAGAGTTTTCGCCCCGAAGAACGTTTTCCAATGATGAGCACTTTTAAAGTTCTGCTATGTGGCGCGGTATTATCCCGTGTTGACGCCGGGCAAGAGCAACTCGGTCGCCGCATACACTATTCTCAGAATGACTTGGTTGAGTACTCACCAGTCACAGAAAAGCATCTTACGGATGGCATGACAGTAAGAGAATTATGCAGTGCTGCCATAACCATGAGTGATAACACTGCGGCCAACTTACTTCTGACAACGATCGGAGGACCGAAGGAGCTAACCGCTTTTTTGCACAACATGGGGGATCATGTAACTCGCCTTGATCGTTGGGAACCGGAGCTGAATGAAGCCATACCAAACGACGAGCGTGACACCACGATGCCTGCAGCAATGGCAACAACGTTGCGCAAACTATTAACTGGCGAACTACTTACTCTAGCTTCCCGGCAACAATTAATAGACTGGATGGAGGCGGATAAAGTTGCAGGACCACTTCTGCGCTCGGCCCTTCCGGCTGGCTGGTTTATTGCTGATAAATCTGGAGCCGGTGAGCGTGGGTCTCGCGGTATCATTGCAGCACTGGGGCCAGATGGTAAGCCCTCCCGTATCGTAGTTATCTACACGACGGGGAGTCAGGCAACTATGGATGAACGAAATAGACAGATCGCTGAGATAGGTGCCTCACTGATTAAGCATTGGTAA", isPeptide: false, comments: "Beta-lactamase; ampicillin/carbenicillin resistance in E. coli. From pBR322 (J01749). 286aa.", color: CodableColor(red: 0.200, green: 0.400, blue: 0.800), showArrow: true, featureType: .cds, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "BAR", sequence: "ATGAGCCCAGAACGACGCCCGGCCGACATCCGCCGTGCCACCGAGGCGGACATGCCGGCGGTCTGCACCATCGTCAACCACTACATCGAGACAAGCACGGTCAACTTCCGTACCGAGCCGCAGGAACCGCAGGAGTGGACGGACGACCTCGTCCGTCTGCGGGAGCGCTATCCCTGGCTCGTCGCCGAGGTGGACGGCGAGGTCGCCGGCATCGCCTACGCGGGCCCCTGGAAGGCACGCAACGCCTACGACTGGACGGCCGAGTCGACCGTGTACGTCTCCCCCCGCCACCAGCGGACGGGACTGGGCTCCACGCTCTACACCCACCTGCTGAAGTCCCTGGAGGCACAGGGCTTCAAGAGCGTGGTCGCTGTCATCGGGCTGCCCAACGACCCGAGCGTGCGCATGCACGAGGCGCTCGGATATGCCCCCCGCGGCATGCTGCGGGCGGCCGGCTTCAAGCACGGGAACTGGCATGACGTGGGTTTCTGGCAGCTGGACTTCAGCCTGCCGGTACCGCCCCGTCCGGTCCTGCCCGTCACCGAGATCTGA", isPeptide: false, comments: "Phosphinothricin acetyltransferase; Basta/glufosinate herbicide resistance. From S. hygroscopicus (X17220). 183aa.", color: CodableColor(red: 0.200, green: 0.400, blue: 0.800), showArrow: true, featureType: .cds, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "CmR", sequence: "ATGGAGAAAAAAATCACTGGATATACCACCGTTGATATATCCCAATGGCATCGTAAAGAACATTTTGAGGCATTTCAGTCAGTTGCTCAATGTACCTATAACCAGACCGTTCAGCTGGATATTACGGCCTTTTTAAAGACCGTAAAGAAAAATAAGCACAAGTTTTATCCGGCCTTTATTCACATTCTTGCCCGCCTGATGAATGCTCATCCGGAATTCCGTATGGCAATGAAAGACGGTGAGCTGGTGATATGGGATAGTGTTCACCCTTGTTACACCGTTTTCCATGAGCAAACTGAAACGTTTTCATCGCTCTGGAGTGAATACCACGACGATTTCCGGCAGTTTCTACACATATATTCGCAAGATGTGGCGTGTTACGGTGAAAACCTGGCCTATTTCCCTAAAGGGTTTATTGAGAATATGTTTTTCGTCTCAGCCAATCCCTGGGTGAGTTTCACCAGTTTTGATTTAAACGTGGCCAATATGGACAACTTCTTCGCCCCCGTTTTCACCATGGGCAAATATTATACGCAAGGCGACAAGGTGCTGATGCCGCTGGCGATTCAGGTTCATCATGCCGTCTGTGATGGCTTCCATGTCGGCAGAATGCTTAATGAATTACAACAGTACTGCGATGAGTGGCAGGGCGGGGCGTAA", isPeptide: false, comments: "Chloramphenicol acetyltransferase; chloramphenicol resistance. From pACYC184 (X06403). 219aa.", color: CodableColor(red: 0.200, green: 0.400, blue: 0.800), showArrow: true, featureType: .cds, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "CAT", sequence: "ATGGAGAAAAAAATCACTGGATATACCACCGTTGATATATCCCAATGGCATCGTAAAGAACATTTTGAGGCATTTCAGTCAGTTGCTCAATGTACCTATAACCAGACCGTTCAGCTGGATATTACGGCCTTTTTAAAGACCGTAAAGAAAAATAAGCACAAGTTTTATCCGGCCTTTATTCACATTCTTGCCCGCCTGATGAATGCTCATCCGGAGTTCCGTATGGCAATGAAAGACGGTGAGCTGGTGATATGGGATAGTGTTCACCCTTGTTACACCGTTTTCCATGAGCAAACTGAAACGTTTTCATCGCTCTGGAGTGAATACCACGACGATTTCCGGCAGTTTCTACACATATATTCGCAAGATGTGGCGTGTTACGGTGAAAACCTGGCCTATTTCCCTAAAGGGTTTATTGAGAATATGTTTTTCGTCTCAGCCAATCCCTGGGTGAGTTTCACCAGTTTTGATTTAAACGTGGCCAATATGGACAACTTCTTCGCCCCCGTTTTCACAATGGGCAAATATTATACGCAAGGCGACAAGGTGCTGATGCCGCTGGCGATTCAGGTTCATCATGCCGTTTGTGATGGCTTCCATGTCGGCAGAATGCTTAATGAATTACAACAGTACTGCGATGAGTGGCAGGGCGGGGCGTAA", isPeptide: false, comments: "Chloramphenicol acetyltransferase; chloramphenicol resistance. From pBR325, via pCAMBIA binary vectors (e.g. pCAMBIA-1281Z, AAF65328.1). 219aa.", color: CodableColor(red: 0.200, green: 0.400, blue: 0.800), showArrow: true, featureType: .cds, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "HIS1", sequence: "ATGGATTTGGTGAACCATCTAACCGATAGACTACTGTTTGCAATCCCAAAGAAAGGTCGTTTATATTCTAAAAGTGTTTCTATTTTGAATGGTGCTGATATTACCTTTCACCGCTCTCAAAGATTAGACATTGCACTAAGCACAAGCTTACCTGTAGCGTTGGTCTTTCTGCCCGCTGCAGATATTCCAACTTTTGTTGGTGAAGGTAAATGTGATCTTGGTATAACTGGTGTTGACCAAGTTCGTGAATCTAACGTCGACGTAGACTTAGCAATCGATTTGCAATTTGGTAACTGTAAATTGCAGGTACAAGTCCCCGTAAATGGCGAGTATAAAAAGCCAGAACAGTTAATTGGCAAAACCATTGTTACCAGTTTCGTGAAACTTGCTGAAAAATACTTTGCCGATTTGGAAGGTACTACTGTTGAAAAAATGACCACAAGGATAAAGTTTGTCAGTGGTTCCGTGGAGGCATCATGTGCTCTGGGAATTGGTGATGCTATTGTAGATCTTGTAGAGAGTGGTGAGACAATGAGGGCAGCAGGTTTAGTTGATATTGCCACCGTCCTAAGCACAAGTGCCTACCTAATAGAATCAAAGAACCCAAAGAGCGATAAGAGTTTGATTGCTACTATCAAATCAAGAATTGAAGGTGTCATGACCGCTCAAAGGTTCGTTTCATGTATTTATAACGCACCTGAAGACAAGCTGCCTGAACTGTTGAAGGTGACGCCTGGCCGTAGAGCACCAACCATTTCCAAAATTGACGATGAAGGATGGGTTGCTGTTAGTTCCATGATTGAGAGAAAAACGAAGGGTGTTGTTTTAGATGAATTGAAAAGACTCGGCGCATCTGATATCATGGTTTTCGAAATTTCTAATTGTCGTGTATAA", isPeptide: false, comments: "ATP phosphoribosyltransferase; histidine biosynthesis step 1. S. cerevisiae auxotrophic marker (YER055C). 297aa.", color: CodableColor(red: 0.200, green: 0.400, blue: 0.800), showArrow: true, featureType: .cds, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "HIS3", sequence: "ATGACAGAGCAGAAAGCCCTAGTAAAGCGTATTACAAATGAAACCAAGATTCAGATTGCGATCTCTTTAAAGGGTGGTCCCCTAGCGATAGAGCACTCGATCTTCCCAGAAAAAGAGGCAGAAGCAGTAGCAGAACAGGCCACACAATCGCAAGTGATTAACGTCCACACAGGTATAGGGTTTCTGGACCATATGATACATGCTCTGGCCAAGCATTCCGGCTGGTCGCTAATCGTTGAGTGCATTGGTGACTTACACATAGACGACCATCACACCACTGAAGACTGCGGGATTGCTCTCGGTCAAGCTTTTAAAGAGGCCCTACTGGCGCGTGGAGTAAAAAGGTTTGGATCAGGATTTGCGCCTTTGGATGAGGCACTTTCCAGAGCGGTGGTAGATCTTTCGAACAGGCCGTACGCAGTTGTCGAACTTGGTTTGCAAAGGGAGAAAGTAGGAGATCTCTCTTGCGAGATGATCCCGCATTTTCTTGAAAGCTTTGCAGAGGCTAGCAGAATTACCCTCCACGTTGATTGTCTGCGAGGCAAGAATGATCATCACCGTAGTGAGAGTGCGTTCAAGGCTCTTGCGGTTGCCATAAGAGAAGCCACCTCGCCCAATGGTACCAACGATGTTCCCTCCACCAAAGGTGTTCTTATGTAG", isPeptide: false, comments: "Imidazoleglycerol-phosphate dehydratase; histidine biosynthesis. S. cerevisiae auxotrophic marker. From pRS313. 219aa.", color: CodableColor(red: 0.200, green: 0.400, blue: 0.800), showArrow: true, featureType: .cds, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "HIS5", sequence: "ATGAGGAGGGCTTTTGTAGAAAGAAATACGAACGAAACGAAAATCAGCGTTGCCATCGCTTTGGACAAAGCTCCCTTACCTGAAGAGTCGAATTTTATTGATGAACTTATAACTTCCAAGCATGCAAACCAAAAGGGAGAACAAGTAATCCAAGTAGACACGGGAATTGGATTCTTGGATCACATGTATCATGCACTGGCTAAACATGCAGGCTGGAGCTTACGACTTTACTCAAGAGGTGATTTAATCATCGATGATCATCACACTGCAGAAGATACTGCTATTGCACTTGGTATTGCATTCAAGCAGGCTATGGGTAACTTTGCCGGCGTTAAAAGATTTGGACATGCTTATTGTCCACTTGACGAAGCTCTTTCTAGAAGCGTAGTTGACTTGTCGGGACGGCCCTATGCTGTTATCGATTTGGGATTAAAGCGTGAAAAGGTTGGGGAATTGTCCTGTGAAATGATCCCTCACTTACTATATTCCTTTTCGGTAGCAGCTGGAATTACTTTGCATGTTACCTGCTTATATGGTAGTAATGACCATCATCGTGCTGAAAGCGCTTTTAAATCTCTGGCTGTTGCCATGCGCGCGGCTACTAGTCTTACTGGAAGTTCTGAAGTCCCAAGCACGAAGGGAGTGTTGTAA", isPeptide: false, comments: "Imidazoleglycerol-phosphate dehydratase; S. pombe HIS5 complements S. cerevisiae his3 mutants. From PomBase SPBC21H7.07c. 216aa.", color: CodableColor(red: 0.200, green: 0.400, blue: 0.800), showArrow: true, featureType: .cds, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "HptII", sequence: "ATGAAAAAGCCTGAACTCACCGCGACGTCTGTCGAGAAGTTTCTGATCGAAAAGTTCGACAGCGTCTCCGACCTGATGCAGCTCTCGGAGGGCGAAGAATCTCGTGCTTTCAGCTTCGATGTAGGAGGGCGTGGATATGTCCTGCGGGTAAATAGCTGCGCCGATGGTTTCTACAAAGATCGTTATGTTTATCGGCACTTTGCATCGGCCGCGCTCCCGATTCCGGAAGTGCTTGACATTGGGGAGTTTAGCGAGAGCCTGACCTATTGCATCTCCCGCCGTGCACAGGGTGTCACGTTGCAAGACCTGCCTGAAACCGAACTGCCCGCTGTTCTACAACCGGTCGCGGAGGCTATGGATGCGATCGCTGCGGCCGATCTTAGCCAGACGAGCGGGTTCGGCCCATTCGGACCGCAAGGAATCGGTCAATACACTACATGGCGTGATTTCATATGCGCGATTGCTGATCCCCATGTGTATCACTGGCAAACTGTGATGGACGACACCGTCAGTGCGTCCGTCGCGCAGGCTCTCGATGAGCTGATGCTTTGGGCCGAGGACTGCCCCGAAGTCCGGCACCTCGTGCACGCGGATTTCGGCTCCAACAATGTCCTGACGGACAATGGCCGCATAACAGCGGTCATTGACTGGAGCGAGGCGATGTTCGGGGATTCCCAATACGAGGTCGCCAACATCTTCTTCTGGAGGCCGTGGTTGGCTTGTATGGAGCAGCAGACGCGCTACTTCGAGCGGAGGCATCCGGAGCTTGCAGGATCGCCACGACTCCGGGCGTATATGCTCCGCATTGGTCTTGACCAACTCTATCAGAGCTTGGTTGACGGCAATTTCGATGATGCAGCTTGGGCGCAGGGTCGATGCGACGCAATCGTCCGATCCGGAGCCGGGACTGTCGGGCGTACACAAATCGCCCGCAGAAGCGCGGCCGTCTGGACCGATGGCTGTGTAGAAGTACTCGCCGATAGTGGAAACCGACGCCCCAGCACTCGTCCGAGGGCAAAGAAATAG", isPeptide: false, comments: "Hygromycin B phosphotransferase; hygromycin resistance in plants and bacteria. From pCAMBIA1300 (AF234296). 341aa.", color: CodableColor(red: 0.200, green: 0.400, blue: 0.800), showArrow: true, featureType: .cds, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "KanR", sequence: "ATGGGGATTGAACAAGATGGATTGCACGCAGGTTCTCCGGCCGCTTGGGTGGAGAGGCTATTCGGCTATGACTGGGCACAACAGACAATCGGCTGCTCTGATGCCGCCGTGTTCCGGCTGTCAGCGCAGGGGCGCCCGGTTCTTTTTGTCAAGACCGACCTGTCCGGTGCCCTGAATGAACTCCAGGACGAGGCAGCGCGGCTATCGTGGCTGGCCACGACGGGCGTTCCTTGCGCAGCTGTGCTCGACGTTGTCACTGAAGCGGGAAGGGACTGGCTGCTATTGGGCGAAGTGCCGGGGCAGGATCTCCTGTCATCTCACCTTGCTCCTGCCGAGAAAGTATCCATCATGGCTGATGCAATGCGGCGGCTGCATACGCTTGATCCGGCTACCTGCCCATTCGACCACCAAGCGAAACATCGCATCGAGCGAGCACGTACTCGGATGGAAGCCGGTCTTGTCGATCAGGATGATCTGGACGAAGAGCATCAGGGGCTCGCGCCAGCCGAACTGTTCGCCAGGCTCAAGGCGCGCATGCCCGACGGCGAGGATCTCGTCGTGACACATGGCGATGCCTGCTTGCCGAATATCATGGTGGAAAATGGCCGCTTTTCTGGATTCATCGACTGTGGCCGGCTGGGTGTGGCGGACCGCTATCAGGACATAGCGTTGGCTACCCGTGATATTGCTGAAGAGCTTGGCGGCGAATGGGCTGACCGCTTCCTCGTGCTTTACGGTATCGCCGCTCCCGATTCGCAGCGCATCGCCTTCTATCGCCTTCTTGACGAGTTCTTCTGA", isPeptide: false, comments: "Aminoglycoside phosphotransferase APH(3'); kanamycin resistance in bacteria and Agrobacterium. From pCAMBIA1300. 265aa.", color: CodableColor(red: 0.200, green: 0.400, blue: 0.800), showArrow: true, featureType: .cds, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "KanMX", sequence: "GACATGGAGGCCCAGAATACCCTCCTTGACAGTCTTGACGTGCGCAGCTCAGGGGCATGATGTGACTGTCGCCCGTACATTTAGCCCATACATCCCCATGTATAATCATTTGCATCCATACATTTTGATGGCCGCACGGCGCGAAGCAAAAATTACGGCTCCTCGCTGCAGACCTGCGAGCAGGGAAACGCTCCCCTCACAGACGCGTTGAATTGTCCCCACGCCGCGCCCCTGTAGAGAAATATAAAAGGTTAGGATTTGCCACTGAGGTTCTTCTTTCATATACTTCCTTTTAAAATCTTGCTAGGATACAGTTCTCACATCACATCCGAACATAAACAACCATGGGTAAGGAAAAGACTCACGTTTCGAGGCCGCGATTAAATTCCAACATGGATGCTGATTTATATGGGTATAAATGGGCTCGCGATAATGTCGGGCAATCAGGTGCGACAATCTATCGATTGTATGGGAAGCCCGATGCGCCAGAGTTGTTTCTGAAACATGGCAAAGGTAGCGTTGCCAATGATGTTACAGATGAGATGGTCAGACTAAACTGGCTGACGGAATTTATGCCTCTTCCGACCATCAAGCATTTTATCCGTACTCCTGATGATGCATGGTTACTCACCACTGCGATCCCCGGCAAAACAGCATTCCAGGTATTAGAAGAATATCCTGATTCAGGTGAAAATATTGTTGATGCGCTGGCAGTGTTCCTGCGCCGGTTGCATTCGATTCCTGTTTGTAATTGTCCTTTTAACAGCGATCGCGTATTTCGTCTCGCTCAGGCGCAATCACGAATGAATAACGGTTTGGTTGATGCGAGTGATTTTGATGACGAGCGTAATGGCTGGCCTGTTGAACAAGTCTGGAAAGAAATGCATAAGCTTTTGCCATTCTCACCGGATTCAGTCGTCACTCATGGTGATTTCTCACTTGATAACCTTATTTTTGACGAGGGGAAATTAATAGGTTGTATTGATGTTGGACGAGTCGGAATCGCAGACCGATACCAGGATCTTGCCATCCTATGGAACTGCCTCGGTGAGTTTTCTCCTTCATTACAGAAACGGCTTTTTCAAAAATATGGTATTGATAATCCTGATATGAATAAATTGCAGTTTCATTTGATGCTCGATGAGTTTTTCTAATCAGTACTGACAATAAAAAGATTCTTGTTTTCAAGAACTTGTCATTTGTATAGTTTTTTTATATTGTAGTTGTTCTATTTTAATCAAATGTTAGCGTGATTTATATTTTTTTTCGCCTCGACATCATCTGCCCAGATGCGAAGTTAAGTGCGCAGAAAGTAATATCATGCGTCAATCGTATGTGAATGCTGGTCGCTATACTG", isPeptide: false, comments: "Full KanMX cassette: TEF promoter + APH(3')-Ia kanr ORF (810bp) + TEF terminator, all from A. gossypii. Sequence includes promoter and terminator. Confers G418/geneticin resistance in S. cerevisiae. From pFA6a-kanMX4 (Addgene #39296).", color: CodableColor(red: 0.200, green: 0.400, blue: 0.800), showArrow: true, featureType: .cds, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "LEU2", sequence: "ATGTCTGCCCCTAAGAAGATCGTCGTTTTGCCAGGTGACCACGTTGGTCAAGAAATCACAGCCGAAGCCATTAAGGTTCTTAAAGCTATTTCTGATGTTCGTTCCAATGTCAAGTTCGATTTCGAAAATCATTTAATTGGTGGTGCTGCTATCGATGCTACAGGTGTTCCACTTCCAGATGAGGCGCTGGAAGCCTCCAAGAAGGCTGATGCCGTTTTGTTAGGTGCTGTGGGTGGTCCTAAATGGGGTACCGGTAGTGTTAGACCTGAACAAGGTTTACTAAAAATCCGTAAAGAACTTCAATTGTACGCCAACTTAAGACCATGTAACTTTGCATCCGACTCTCTTTTAGACTTATCTCCAATCAAGCCACAATTTGCTAAAGGTACTGACTTCGTTGTTGTCAGAGAATTAGTGGGAGGTATTTACTTTGGTAAGAGAAAGGAAGACGATGGTGATGGTGTCGCTTGGGATAGTGAACAATACACCGTTCCAGAAGTGCAAAGAATCACAAGAATGGCCGCTTTCATGGCCCTACAACATGAGCCACCATTGCCTATTTGGTCCTTGGATAAAGCTAATGTTTTGGCCTCTTCAAGATTATGGAGAAAAACTGTGGAGGAAACCATCAAGAACGAATTCCCTACATTGAAGGTTCAACATCAATTGATTGATTCTGCCGCCATGATCCTAGTTAAGAACCCAACCCACCTAAATGGTATTATAATCACCAGCAACATGTTTGGTGATATCATCTCCGATGAAGCCTCCGTTATCCCAGGTTCCTTGGGTTTGTTGCCATCTGCGTCCTTGGCCTCTTTGCCAGACAAGAACACCGCATTTGGTTTGTACGAACCATGCCACGGTTCTGCTCCAGATTTGCCAAAGAATAAGGTCAACCCTATCGCCACTATCTTGTCTGCTGCAATGATGTTGAAATTGTCATTGAACTTGCCTGAAGAAGGTAAGGCCATTGAAGATGCAGTTAAAAAGGTTTTGGATGCAGGTATCAGAACTGGTGATTTAGGTGGTTCCAACAGTACCACCGAAGTCGGTGATGCTGTCGCCGAAGAAGTTAAGAAAATCCTTGCTTAA", isPeptide: false, comments: "Beta-isopropylmalate dehydrogenase; leucine biosynthesis. S. cerevisiae auxotrophic marker (YCL018W). 364aa.", color: CodableColor(red: 0.200, green: 0.400, blue: 0.800), showArrow: true, featureType: .cds, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "LYS2", sequence: "ATGACTAACGAAAAGGTCTGGATAGAGAAGTTGGATAATCCAACTCTTTCAGTGTTACCACATGACTTTTTACGCCCACAACAAGAACCTTATACGAAACAAGCTACATATTCGTTACAGCTACCTCAGCTCGATGTGCCTCATGATAGTTTTTCTAACAAATACGCTGTCGCTTTGAGTGTATGGGCTGCATTGATATATAGAGTAACCGGTGACGATGATATTGTTCTTTATATTGCGAATAACAAAATCTTAAGATTCAATATTCAACCAACGTGGTCATTTAATGAGCTGTATTCTACAATTAACAATGAGTTGAACAAGCTCAATTCTATTGAGGCCAATTTTTCCTTTGACGAGCTAGCTGAAAAAATTCAAAGTTGCCAAGATCTGGAAAGGACCCCTCAGTTGTTCCGTTTGGCCTTTTTGGAAAACCAAGATTTCAAATTAGACGAGTTCAAGCATCATTTAGTGGACTTTGCTTTGAATTTGGATACCAGTAATAATGCGCATGTTTTGAACTTAATTTATAACAGCTTACTGTATTCGAATGAAAGAGTAACCATTGTTGCGGACCAATTTACTCAATATTTGACTGCTGCGCTAAGCGATCCATCCAATTGCATAACTAAAATCTCTCTGATCACCGCATCATCCAAGGATAGTTTACCTGATCCAACTAAGAACTTGGGCTGGTGCGATTTCGTGGGGTGTATTCACGACATTTTCCAGGACAATGCTGAAGCCTTCCCAGAGAGAACCTGTGTTGTGGAGACTCCAACACTAAATTCCGACAAGTCCCGTTCTTTCACTTATCGCGACATCAACCGCACTTCTAACATAGTTGCCCATTATTTGATTAAAACAGGTATCAAAAGAGGTGATGTAGTGATGATCTATTCTTCTAGGGGTGTGGATTTGATGGTATGTGTGATGGGTGTCTTGAAAGCCGGCGCAACCTTTTCAGTTATCGACCCTGCATATCCCCCAGCCAGACAAACCATTTACTTAGGTGTTGCTAAACCACGTGGGTTGATTGTTATTAGAGCTGCTGGACAATTGGATCAACTAGTAGAAGATTACATCAATGATGAATTGGAGATTGTTTCAAGAATCAATTCCATCGCTATTCAAGAAAATGGTACCATTGAAGGTGGCAAATTGGACAATGGCGAGGATGTTTTGGCTCCATATGATCACTACAAAGACACCAGAACAGGTGTTGTAGTTGGACCAGATTCCAACCCAACCCTATCTTTCACATCTGGTTCCGAAGGTATTCCTAAGGGTGTTCTTGGTAGACATTTTTCCTTGGCTTATTATTTCAATTGGATGTCCAAAAGGTTCAACTTAACAGAAAATGATAAATTCACAATGCTGAGCGGTATTGCACATGATCCAATTCAAAGAGATATGTTTACACCATTATTTTTAGGTGCCCAATTGTATGTCCCTACTCAAGATGATATTGGTACACCGGGCCGTTTAGCGGAATGGATGAGTAAGTATGGTTGCACAGTTACCCATTTAACACCTGCCATGGGTCAATTACTTACTGCCCAAGCTACTACACCATTCCCTAAGTTACATCATGCGTTCTTTGTGGGTGACATTTTAACAAAACGTGATTGTCTGAGGTTACAAACCTTGGCAGAAAATTGCCGTATTGTTAATATGTACGGTACCACTGAAACACAGCGTGCAGTTTCTTATTTCGAAGTTAAATCAAAAAATGACGATCCAAACTTTTTGAAAAAATTGAAAGATGTCATGCCTGCTGGTAAAGGTATGTTGAACGTTCAGCTACTAGTTGTTAACAGGAACGATCGTACTCAAATATGTGGTATTGGCGAAATAGGTGAGATTTATGTTCGTGCAGGTGGTTTGGCCGAAGGTTATAGAGGATTACCAGAATTGAATAAAGAAAAATTTGTGAACAACTGGTTTGTTGAAAAAGATCACTGGAATTATTTGGATAAGGATAATGGTGAACCTTGGAGACAATTCTGGTTAGGTCCAAGAGATAGATTGTACAGAACGGGTGATTTAGGTCGTTATCTACCAAACGGTGACTGTGAATGTTGCGGTAGGGCTGATGATCAAGTTAAAATTCGTGGGTTCAGAATCGAATTAGGAGAAATAGATACGCACATTTCCCAACATCCATTGGTAAGAGAAAACATTACTTTAGTTCGCAAAAATGCCGACAATGAGCCAACATTGATCACATTTATGGTCCCAAGATTTGACAAGCCAGATGACTTGTCTAAGTTCCAAAGTGATGTTCCAAAGGAGGTTGAAACTGACCCTATAGTTAAGGGCTTAATCGGTTACCATCTTTTATCCAAGGACATCAGGACTTTCTTAAAGAAAAGATTGGCTAGCTATGCTATGCCTTCCTTGATTGTGGTTATGGATAAACTACCATTGAATCCAAATGGTAAAGTTGATAAGCCTAAACTTCAATTCCCAACTCCCAAGCAATTAAATTTGGTAGCTGAAAATACAGTTTCTGAAACTGACGACTCTCAGTTTACCAATGTTGAGCGCGAGGTTAGAGACTTATGGTTAAGTATATTACCTACCAAGCCAGCATCTGTATCACCAGATGATTCGTTTTTCGATTTAGGTGGTCATTCTATCTTGGCTACCAAAATGATTTTTACCTTAAAGAAAAAGCTGCAAGTTGATTTACCATTGGGCACAATTTTCAAGTATCCAACGATAAAGGCCTTTGCCGCGGAAATTGACAGAATTAAATCATCGGGTGGATCATCTCAAGGTGAGGTCGTCGAAAATGTCACTGCAAATTATGCGGAAGACGCCAAGAAATTGGTTGAGACGCTACCAAGTTCGTACCCCTCTCGAGAATATTTTGTTGAACCTAATAGTGCCGAAGGAAAAACAACAATTAATGTGTTTGTTACCGGTGTCACAGGATTTCTGGGCTCCTACATCCTTGCAGATTTGTTAGGACGTTCTCCAAAGAACTACAGTTTCAAAGTGTTTGCCCACGTCAGGGCCAAGGATGAAGAAGCTGCATTTGCAAGATTACAAAAGGCAGGTATCACCTATGGTACTTGGAACGAAAAATTTGCCTCAAATATTAAAGTTGTATTAGGCGATTTATCTAAAAGCCAATTTGGTCTTTCAGATGAGAAGTGGATGGATTTGGCAAACACAGTTGATATAATTATCCATAATGGTGCGTTAGTTCACTGGGTTTATCCATATGCCAAATTGAGGGATCCAAATGTTATTTCAACTATCAATGTTATGAGCTTAGCCGCCGTCGGCAAGCCAAAGTTCTTTGACTTTGTTTCCTCCACTTCTACTCTTGACACTGAATACTACTTTAATTTGTCAGATAAACTTGTTAGCGAAGGGAAGCCAGGCATTTTAGAATCAGACGATTTAATGAACTCTGCAAGCGGGCTCACTGGTGGATATGGTCAGTCCAAATGGGCTGCTGAGTACATCATTAGACGTGCAGGTGAAAGGGGCCTACGTGGGTGTATTGTCAGACCAGGTTACGTAACAGGTGCCTCTGCCAATGGTTCTTCAAACACAGATGATTTCTTATTGAGATTTTTGAAAGGTTCAGTCCAATTAGGTAAGATTCCAGATATCGAAAATTCCGTGAATATGGTTCCAGTAGATCATGTTGCTCGTGTTGTTGTTGCTACGTCTTTGAATCCTCCCAAAGAAAATGAATTGGCCGTTGCTCAAGTAACGGGTCACCCAAGAATATTATTCAAAGACTACTTGTATACTTTACACGATTATGGTTACGATGTCGAAATCGAAAGCTATTCTAAATGGAAGAAATCATTGGAGGCGTCTGTTATTGACAGGAATGAAGAAAATGCGTTGTATCCTTTGCTACACATGGTCTTAGACAACTTACCTGAAAGTACCAAAGCTCCGGAACTAGACGATAGGAACGCCGTGGCATCTTTAAAGAAAGACACCGCATGGACAGGTGTTGATTGGTCTAATGGAATAGGTGTTACTCCAGAAGAGGTTGGTATATATATTGCATTTTTAAACAAGGTTGGATTTTTACCTCCACCAACTCATAATGACAAACTTCCACTGCCAAGTATAGAACTAACTCAAGCGCAAATAAGTCTAGTTGCTTCAGGTGCTGGTGCTCGTGGAAGCTCCGCAGCAGCTTAA", isPeptide: false, comments: "Alpha-aminoadipate reductase; lysine biosynthesis. S. cerevisiae auxotrophic marker (YBR115C). 1392aa.", color: CodableColor(red: 0.200, green: 0.400, blue: 0.800), showArrow: true, featureType: .cds, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "MET17", sequence: "ATGCCATCTCATTTCGATACTGTTCAACTACACGCCGGCCAAGAGAACCCTGGTGACAATGCTCACAGATCCAGAGCTGTACCAATTTACGCCACCACTTCTTATGTTTTCGAAAACTCTAAGCATGGTTCGCAATTGTTTGGTCTAGAAGTTCCAGGTTACGTCTATTCCCGTTTCCAAAACCCAACCAGTAATGTTTTGGAAGAAAGAATTGCTGCTTTAGAAGGTGGTGCTGCTGCTTTGGCTGTTTCCTCCGGTCAAGCCGCTCAAACCCTTGCCATCCAAGGTTTGGCACACACTGGTGACAACATCGTTTCCACTTCTTACTTATACGGTGGTACTTATAACCAGTTCAAAATCTCGTTCAAAAGATTTGGTATCGAGGCTAGATTTGTTGAAGGTGACAATCCAGAAGAATTCGAAAAGGTCTTTGATGAAAGAACCAAGGCTGTTTATTTGGAAACCATTGGTAATCCAAAGTACAATGTTCCGGATTTTGAAAAAATTGTTGCAATTGCTCACAAACACGGTATTCCAGTTGTCGTTGACAACACATTTGGTGCCGGTGGTTACTTCTGTCAGCCAATTAAATACGGTGCTGATATTGTAACACATTCTGCTACCAAATGGATTGGTGGTCATGGTACTACTATCGGTGGTATTATTGTTGACTCTGGTAAGTTCCCATGGAAGGACTACCCAGAAAAGTTCCCTCAATTCTCTCAACCTGCCGAAGGATATCACGGTACTATCTACAATGAAGCCTACGGTAACTTGGCATACATCGTTCATGTTAGAACTGAACTATTAAGAGATTTGGGTCCATTGATGAACCCATTTGCCTCTTTCTTGCTACTACAAGGTGTTGAAACATTATCTTTGAGAGCTGAAAGACACGGTGAAAATGCATTGAAGTTAGCCAAATGGTTAGAACAATCCCCATACGTATCTTGGGTTTCATACCCTGGTTTAGCATCTCATTCTCATCATGAAAATGCTAAGAAGTATCTATCTAACGGTTTCGGTGGTGTCTTATCTTTCGGTGTAAAAGACTTACCAAATGCCGACAAGGAAACTGACCCATTCAAACTTTCTGGTGCTCAAGTTGTTGACAATTTAAAGCTTGCCTCTAACTTGGCCAATGTTGGTGATGCCAAGACCTTAGTCATTGCTCCATACTTCACTACCCACAAACAATTAAATGACAAAGAAAAGTTGGCATCTGGTGTTACCAAGGACTTAATTCGTGTCTCTGTTGGTATCGAATTTATTGATGACATTATTGCAGACTTCCAGCAATCTTTTGAAACTGTTTTCGCTGGCCAAAAACCATGA", isPeptide: false, comments: "O-acetylhomoserine sulfhydrylase; methionine/cysteine biosynthesis. S. cerevisiae auxotrophic marker (YLR303W; also known as MET15). 444aa.", color: CodableColor(red: 0.200, green: 0.400, blue: 0.800), showArrow: true, featureType: .cds, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "NPTII", sequence: "ATGGCTAAAATGAGAATATCACCGGAATTGAAAAAACTGATCGAAAAATACCGCTGCGTAAAAGATACGGAAGGAATGTCTCCTGCTAAGGTATATAAGCTGGTGGGAGAAAATGAAAACCTATATTTAAAAATGACGGACAGCCGGTATAAAGGGACCACCTATGATGTGGAACGGGAAAAGGACATGATGCTATGGCTGGAAGGAAAGCTGCCTGTTCCAAAGGTCCTGCACTTTGAACGGCATGATGGCTGGAGCAATCTGCTCATGAGTGAGGCCGATGGCGTCCTTTGCTCGGAAGAGTATGAAGATGAACAAAGCCCTGAAAAGATTATCGAGCTGTATGCGGAGTGCATCAGGCTCTTTCACTCCATCGACATATCGGATTGTCCCTATACGAATAGCTTAGACAGCCGCTTAGCCGAATTGGATTACTTACTGAATAACGATCTGGCCGATGTGGATTGCGAAAACTGGGAAGAAGACACTCCATTTAAAGATCCGCGCGAGCTGTATGATTTTTTAAAGACGGAAAAGCCCGAAGAGGAACTTGTCTTTTCCCACGGCGACCTGGGAGACAGCAACATCTTTGTGAAAGATGGCAAAGTAAGTGGCTTTATTGATCTTGGGAGAAGCGGCAGGGCGGACAAGTGGTATGACATTGCCTTCTGCGTCCGGTCGATCAGGGAGGATATCGGGGAAGAACAGTATGTCGAGCTATTTTTTGACTTACTGGGGATCAAGCCTGATTGGGAGAAAATAAAATATTATATTTTACTGGATGAATTGTTTTAG", isPeptide: false, comments: "Neomycin phosphotransferase II; kanamycin/G418 resistance in plants. From pCAMBIA1300 (AF234296). 264aa.", color: CodableColor(red: 0.200, green: 0.400, blue: 0.800), showArrow: true, featureType: .cds, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "TetA", sequence: "ATGAAATCTAACAATGCGCTCATCGTCATCCTCGGCACCGTCACCCTGGATGCTGTAGGCATAGGCTTGGTTATGCCGGTACTGCCGGGCCTCTTGCGGGATATCGTCCATTCCGACAGCATCGCCAGTCACTATGGCGTGCTGCTAGCGCTATATGCGTTGATGCAATTTCTATGCGCACCCGTTCTCGGAGCACTGTCCGACCGCTTTGGCCGCCGCCCAGTCCTGCTCGCTTCGCTACTTGGAGCCACTATCGACTACGCGATCATGGCGACCACACCCGTCCTGTGGATCCTCTACGCCGGACGCATCGTGGCCGGCATCACCGGCGCCACAGGTGCGGTTGCTGGCGCCTATATCGCCGACATCACCGATGGGGAAGATCGGGCTCGCCACTTCGGGCTCATGAGCGCTTGTTTCGGCGTGGGTATGGTGGCAGGCCCCGTGGCCGGGGGACTGTTGGGCGCCATCTCCTTGCATGCACCATTCCTTGCGGCGGCGGTGCTCAACGGCCTCAACCTACTACTGGGCTGCTTCCTAATGCAGGAGTCGCATAAGGGAGAGCGTCGACCGATGCCCTTGAGAGCCTTCAACCCAGTCAGCTCCTTCCGGTGGGCGCGGGGCATGACTATCGTCGCCGCACTTATGACTGTCTTCTTTATCATGCAACTCGTAGGACAGGTGCCGGCAGCGCTCTGGGTCATTTTCGGCGAGGACCGCTTTCGCTGGAGCGCGACGATGATCGGCCTGTCGCTTGCGGTATTCGGAATCTTGCACGCCCTCGCTCAAGCCTTCGTCACTGGTCCCGCCACCAAACGTTTCGGCGAGAAGCAGGCCATTATCGCCGGCATGGCGGCCGACGCGCTGGGCTACGTCTTGCTGGCGTTCGCGACGCGAGGCTGGATGGCCTTCCCCATTATGATTCTTCTCGCTTCCGGCGGCATCGGGATGCCCGCGTTGCAGGCCATGCTGTCCAGGCAGGTAGATGACGACCATCAGGGACAGCTTCAAGGATCGCTCGCGGCTCTTACCAGCCTAACTTCGATCACTGGACCGCTGATCGTCACGGCGATTTATGCCGCCTCGGCGAGCACATGGAACGGGTTGGCATGGATTGTAGGCGCCGCCCTATACCTTGTCTGCCTCCCCGCGTTGCGTCGCGGTGCATGGAGCCGGGCCACCTCGACCTGA", isPeptide: false, comments: "Tetracycline efflux pump; tetracycline resistance in E. coli. From pBR322 (J01749). 396aa.", color: CodableColor(red: 0.200, green: 0.400, blue: 0.800), showArrow: true, featureType: .cds, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "TRP1", sequence: "ATGTCTGTTATTAATTTCACAGGTAGTTCTGGTCCATTGGTGAAAGTTTGCGGCTTGCAGAGCACAGAGGCCGCAGAATGTGCTCTAGATTCCGATGCTGACTTGCTGGGTATTATATGTGTGCCCAATAGAAAGAGAACAATTGACCCGGTTATTGCAAGGAAAATTTCAAGTCTTGTAAAAGCATATAAAAATAGTTCAGGCACTCCGAAATACTTGGTTGGCGTGTTTCGTAATCAACCTAAGGAGGATGTTTTGGCTCTGGTCAATGATTACGGCATTGATATCGTCCAACTGCATGGAGATGAGTCGTGGCAAGAATACCAAGAGTTCCTCGGTTTGCCAGTTATTAAAAGACTCGTATTTCCAAAAGACTGCAACATACTACTCAGTGCAGCTTCACAGAAACCTCATTCGTTTATTCCCTTGTTTGATTCAGAAGCAGGTGGGACAGGTGAACTTTTGGATTGGAACTCGATTTCTGACTGGGTTGGAAGGCAAGAGAGCCCCGAAAGCTTACATTTTATGTTAGCTGGTGGACTGACGCCAGAAAATGTTGGTGATGCGCTTAGATTAAATGGCGTTATTGGTGTTGATGTAAGCGGAGGTGTGGAGACAAATGGTGTAAAAGACTCTAACAAAATAGCAAATTTCGTCAAAAATGCTAAGAAATAG", isPeptide: false, comments: "N-(5-phosphoribosyl)anthranilate isomerase; tryptophan biosynthesis. S. cerevisiae auxotrophic marker (YDR007W). 224aa.", color: CodableColor(red: 0.200, green: 0.400, blue: 0.800), showArrow: true, featureType: .cds, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "URA3", sequence: "ATGTCGAAAGCTACATATAAGGAACGTGCTGCTACTCATCCTAGTCCTGTTGCTGCCAAGCTATTTAATATCATGCACGAAAAGCAAACAAACTTGTGTGCTTCATTGGATGTTCGTACCACCAAGGAATTACTGGAGTTAGTTGAAGCATTAGGTCCCAAAATTTGTTTACTAAAAACACATGTGGATATCTTGACTGATTTTTCCATGGAGGGCACAGTTAAGCCGCTAAAGGCATTATCCGCCAAGTACAATTTTTTACTCTTCGAAGACAGAAAATTTGCTGACATTGGTAATACAGTCAAATTGCAGTACTCTGCGGGTGTATACAGAATAGCAGAATGGGCAGACATTACGAATGCACACGGTGTGGTGGGCCCAGGTATTGTTAGCGGTTTGAAGCAGGCGGCAGAAGAAGTAACAAAGGAACCTAGAGGCCTTTTGATGTTAGCAGAATTGTCATGCAAGGGCTCCCTATCTACTGGAGAATATACTAAGGGTACTGTTGACATTGCGAAGAGCGACAAAGATTTTGTTATCGGCTTTATTGCTCAAAGAGACATGGGTGGAAGAGATGAAGGTTACGATTGGTTGATTATGACACCCGGTGTGGGTTTAGATGACAAGGGAGACGCATTGGGTCAACAGTATAGAACCGTGGATGATGTGGTCTCTACAGGATCTGACATTATTATTGTTGGAAGAGGACTATTTGCAAAGGGAAGGGATGCTAAGGTAGAGGGTGAACGTTACAGAAAAGCAGGCTGGGAAGCATATTTGAGAAGATGCGGCCAGCAAAACTAA", isPeptide: false, comments: "Orotidine-5-phosphate decarboxylase; uracil biosynthesis. S. cerevisiae auxotrophic marker. From pRS316 (U03442). 267aa.", color: CodableColor(red: 0.200, green: 0.400, blue: 0.800), showArrow: true, featureType: .cds, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "ZeoR", sequence: "ATGGCCAAGTTGACCAGTGCCGTTCCGGTGCTCACCGCGCGCGACGTCGCCGGAGCGGTCGAGTTCTGGACCGACCGGCTCGGGTTCTCCCGGGACTTCGTGGAGGACGACTTCGCCGGTGTGGTCCGGGACGACGTGACCCTGTTCATCAGCGCGGTCCAGGACCAGGTGGTGCCGGACAACACCCTGGCCTGGGTGTGGGTGCGCGGCCTGGACGAGCTGTACGCCGAGTGGTCGGAGGTCGTGTCCACGAACTTCCGGGACGCCTCCGGGCCGGCCATGACCGAGATCGGCGAGCAGCCGTGGGGGCGGGAGTTCGCCCTGCGCGACCCGGCCGGCAACTGCGTGCACTTCGTGGCCGAGGAGCAGGACTGA", isPeptide: false, comments: "Sh ble protein; zeocin/phleomycin resistance in bacteria, yeast, plants and mammals. From S. hindustanus (A31898). 124aa.", color: CodableColor(red: 0.200, green: 0.400, blue: 0.800), showArrow: true, featureType: .cds, scanEnabled: true, senseStrandOnly: false),
            ]),


            FeatureCollection(name: "Promoters", scanEnabled: true, items: [
                FeatureLibraryItem(name: "ADH1 promoter", sequence: "GCATGCAACTTCTTTTCTTTTTTTTTCTTTTCTCTCTCCCCCGTTGTTGTCTCACCATATCCGCAATGACAAAAAAATGATGGAAGACACTAAAGGAAAAAATTAACGACAAAGACAGCACCAACAGATGTCGTTGTTCCAGAGCTGATGAGGGGTATCTCACACGAAACTTTTTCCTTCCTTCATTGACCTGCAATTATTAATCTTTTGTTTCCTCGTCATTGTTCTCGTTCCCTTTCTTCCTTGTTTCTTTTTCTGCACAATATTTCAAGCTATACCAAGCATACAA", isPeptide: false, comments: "S. cerevisiae alcohol dehydrogenase 1 promoter; strong constitutive expression in yeast. Widely used in 2µ and CEN plasmids. Yeast.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.200), showArrow: true, featureType: .promoter, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "AOX1 promoter", sequence: "TTTGGTTCGTTGAAATGCTAACGGCCAGTTGGTCAAAAAGAAACTTCCAAAAGTCGGCATACCGTTTGTCTTGTTTGGTATTGATTGACGAATGCTCAAAAATAATCTCATTAATGCTTAGCGCAGTCTCTCTATCGCTTCTGAACCCCGGTGCACCTGTGCCGAAACGCAAATGGGGAAACACCCGCTTTTTGGATGATTATGCATTGTCTCCACATTGTATGCTTCCAAGATTCTGGTGGGAATACTGCTGATAGCCTAACGTTCATGATCAAAATTTAACTGTTCTAACCCCTACTTGACAGCAATATATAAACAGAAGGAAGCTGCCCTGTCTTAAACCTTTTTTTTTATCATCATTATTAGCTTACTTTCATAATTGCGACTGGTTCCAATTGACAAGCTTTTGATTTTAACGACTTTTAACGACAACTTGAGAAGATCAAAAAACAACTAATTATTCGAAACG", isPeptide: false, comments: "Pichia pastoris alcohol oxidase 1 core promoter (469bp); methanol-inducible, one of the strongest inducible promoters known. This entry covers the core region only; full promoter is ~940bp. From U96967. Pichia pastoris.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.200), showArrow: true, featureType: .promoter, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "CaMV 35S promoter (classical)", sequence: "CCTGCAGGTCAACATGGTGGAGCACGACACACTTGTCTACTCCAAAAATATCAAAGATACAGTCTCAGAAGACCAAAGGGCAATTGAGACTTTTCAACAAAGGGTAATATCCGGAAACCTCCTCGGATTCCATTGCCCAGCTATCTGTCACTTTATTGTGAAGATAGTGGAAAAGGAAGGTGGCTCCTACAAATGCCATCATTGCGATAAAGGAAAGGCCATCGTTGAAGATGCCTCTGCCGACAGTGGTCCCAAAGATGGACCCCCACCCACGAGGAGCATCGTGGAAAAAGAAGACGTTCCAACCACGTCTTCAAAGCAAGTGGATTGATGTGATAACATGGTGGAGCACGACACACTTGTCTACTCCAAAAATATCAAAGATACAGTCTCAGAAGACCAAAGGGCAATTGAGACTTTTCAACAAAGGGTAATATCCGGAAACCTCCTCGGATTCCATTGCCCAGCTATCTGTCACTTTATTGTGAAGATAGTGGAAAAGGAAGGTGGCTCCTACAAATGCCATCATTGCGATAAAGGAAAGGCCATCGTTGAAGATGCCTCTGCCGACAGTGGTCCCAAAGATGGACCCCCACCCACGAGGAGCATCGTGGAAAAAGAAGACGTTCCAACCACGTCTTCAAAGCAAGTGGATTGATGTGATATCTCCACTGACGTAAGGGATGACGCACAATCCCACTATCCTTCGCAAGACCCTTCCTCTATATAAGGAAGTTCATTTCATTTGGAGAGGA", isPeptide: false, comments: "CaMV 35S promoter, classical Odell 1985 fragment (755bp). PstI-cloned from CaMV Cabb-B-JI strain. Found in older binary vectors of the original pBin series. Note: sequence differs from pCAMBIA vectors. For plants.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.200), showArrow: true, featureType: .promoter, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "CaMV 35S promoter (core)", sequence: "CATGGAGTCAAAGATTCAAATAGAGGACCTAACAGAACTCGCCGTAAAGACTGGCGAACAGTTCATACAGAGTCTCTTACGACTCAATGACAAGAAGAAAATCTTCGTCAACATGGTGGAGCACGACACACTTGTCTACTCCAAAAATATCAAAGATACAGTCTCAGAAGACCAAAGGGCAATTGAGACTTTTCAACAAAGGGTAATATCCGGAAACCTCCTCGGATTCCATTGCCCAGCTATCTGTCACTTTATTGTGAAGATAGTGGAAAAGGAAGGTGGCTCCTACAAATGCCATCATTGCGATAAAGGAAAGGCCATCGTTGAAGATGCCTCTGCCGACAGTGGTCCCAAAGATGGACCCCCACCCACGAGGAGCATCGTGGAAAAAGAAGACGTTCCAACCACGTCTTCAAAGCAAGTGGATTGATGTGATATCTCCACTGACGTAAGGGATGACGCACAATCCCACTATCCTTCGCAAGACCCTTCCTCTATATAAGGAAGTTCATTTCATTTGGAGAGAACACGGGGGACT", isPeptide: false, comments: "CaMV 35S core promoter (538bp). From pCAMBIA-1302 annotation (CaMV35S, pos 10006-10543); drives GFP reporter in pCAMBIA-1302. Also present in Bin19_AR and related vectors (~94% identity). Minor sequence variation may occur between vector systems. For plants.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.200), showArrow: true, featureType: .promoter, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "CaMV 35S promoter (double)", sequence: "ATGGTGGAGCACGACACTCTCGTCTACTCCAAGAATATCAAAGATACAGTCTCAGAAGACCAAAGGGCTATTGAGACTTTTCAACAAAGGGTAATATCGGGAAACCTCCTCGGATTCCATTGCCCAGCTATCTGTCACTTCATCAAAAGGACAGTAGAAAAGGAAGGTGGCACCTACAAATGCCATCATTGCGATAAAGGAAAGGCTATCGTTCAAGATGCCTCTGCCGACAGTGGTCCCAAAGATGGACCCCCACCCACGAGGAGCATCGTGGAAAAAGAAGACGTTCCAACCACGTCTTCAAAGCAAGTGGATTGATGTGATAACATGGTGGAGCACGACACTCTCGTCTACTCCAAGAATATCAAAGATACAGTCTCAGAAGACCAAAGGGCTATTGAGACTTTTCAACAAAGGGTAATATCGGGAAACCTCCTCGGATTCCATTGCCCAGCTATCTGTCACTTCATCAAAAGGACAGTAGAAAAGGAAGGTGGCACCTACAAATGCCATCATTGCGATAAAGGAAAGGCTATCGTTCAAGATGCCTCTGCCGACAGTGGTCCCAAAGATGGACCCCCACCCACGAGGAGCATCGTGGAAAAAGAAGACGTTCCAACCACGTCTTCAAAGCAAGTGGATTGATGTGATATCTCCACTGACGTAAGGGATGACGCACAATCCCACTATCCTTCGCAAGACCTTCCTCTATATAAGGAAGTTCATTTCATTTGGAGAGGACACGCTGAAATCACCAGTCTCTCTCTACAAATCTATCTCT", isPeptide: false, comments: "CaMV 35S promoter with duplicated enhancer (781bp). Drives selectable markers (HptII, NPTII etc.) in pCAMBIA vectors. Gives stronger expression than single 35S. From pCAMBIA-1302 annotation (CaMV35S2, complement 8712-9492). Note: distinct sequence from classical 35S. For plants.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.200), showArrow: true, featureType: .promoter, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "CMV IE promoter", sequence: "GACCGCCATGTTGACATTGATTATTGACTAGTTATTAATAGTAATCAATTACGGGGTCATTAGTTCATAGCCCATATATGGAGTTCCGCGTTACATAACTTACGGTAAATGGCCCGCCTCGTGACCGCCCAACGACCCCCGCCCATTGACGTCAATAATGACGTATGTTCCCATAGTAACGCCAATAGGGACTTTCCATTGACGTCAATGGGTGGAGTATTTACGGTAAACTGCCCACTTGGCAGTACATCAAGTGTATCATATGCCAAGTCCGGCCCCCTATTGACGTCAATGACGGTAAATGGCCCGCCTGGCATTATGCCCAGTACATGACCTTACGGGACTTTCCTACTTGGCAGTACATCTACGTATTAGTCATCGCTATTACCATGGTGATGCGGTTTTGGCAGTACACCAATGGGCGTGGATAGCGGTTTGACTCACGGGGATTTCCAAGTCTCCACCCCATTGACGTCAATGGGAGTTTGTTTTGGCACCAAAATCAACGGGACTTTCCAAAATGTCGTAATAACCCCGCCCCGTTGACGCAAATGGGCGGTAGGCGTGTACGGTGGGAGGTCTATATAAGCAGAGCTCGTTTAGTGAACCGTCAGATCGCCTGGAGACGCCATCCACGCTGTTTTGACCTCCATAGAAGACACCGGGA", isPeptide: false, comments: "Human cytomegalovirus major immediate-early enhancer/promoter (667bp); one of the strongest mammalian promoters. Used in pcDNA, pCI and most mammalian expression vectors. From M60321 (Towne strain). Mammalian.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.200), showArrow: true, featureType: .promoter, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "CYC1 promoter", sequence: "GAGCTCATTTGGCGAGCGTTGGTTGGTGGATCAAGCCCACGCGTAGGCAATCCTCGAGCAGATCCGCCAGGCGTGTATATATAGCGTGGATGGCCAGGCAACTTTAGTGCTGACACATACAGGCATATATATATGTGTGCGACGACACATGATCATATGGCATGCATGTGCTCTGTATGTATATAAAACTCTTGTTTTCTTCTTTTCTCTAAATATTCTTTCCTTATACATTAGGACCTTTGCAGCATAAATTACTATACTTCTATAGACACGCAAACACAAATACACACACTAAT", isPeptide: false, comments: "S. cerevisiae cytochrome c isoform 1 promoter; weak constitutive expression, useful for tunable systems and two-hybrid vectors. Yeast.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.200), showArrow: true, featureType: .promoter, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "EM7 promoter", sequence: "TGTTGACAATTAATCATCGGCATAGTATATCGGCATAGTATAATACGACAAGGTGAGGAACTAAACC", isPeptide: false, comments: "Synthetic bacterial promoter; constitutive expression in E. coli. Commonly used to drive antibiotic resistance in Zeocin selection cassettes. Bacterial.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.200), showArrow: true, featureType: .promoter, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "GAL1 promoter", sequence: "AGTACGGATTAGAAGCCGCCGAGCGGGTGACAGCCCTCCGAAGGAAGACTCTCCTCCGTGCGTCCTCGTCTTCACCGGTCGCGTTCCTGAAACGCAGATGTGCCTCGCGCCGCACTGCTCCGAACAATAAAGATTCTACAATACTAGCTTTTATGGTTATGAAGAGGAAAAATTGGCAGTAACCTGGCCCCACAAACCTTCAAATGAACGAATCAAATTAACAACCATAGGATGATAATGCGATTAGTTTTTTAGCCTTATTTCTGGGGTAATTAATCAGCGAAGCGATGATTTTTGATCTATTAACAGATATATAAATGCAAAAACTGCATAACCACTTTAACTAATACTTTCAACATTTTCGGTTTGTATTACTTCTTATTCAAATGTAATAAAAGTATCAACAAAAAATTGTTAATATACCTCTATACTTTAACGTCAAGGAGAAAAAAC", isPeptide: false, comments: "S. cerevisiae GAL1 promoter; galactose-inducible, glucose-repressible. One of the strongest inducible yeast promoters. Yeast.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.200), showArrow: true, featureType: .promoter, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "GAL1-10 promoter", sequence: "GAATTTTCAAAAATTCTTACTTTTTTTTTGGATGGACGCAAAGAAGTTTAATAATCATATTACATGGCATTACCACCATATACATATCCATATACATATCCATATCTAATCTTACTTATATGTTGTGGAAATGTAAAGAGCCCCATTATCTTAGCCTAAAAAAACCTTCTCTTTGGAACTTTCAGTAATACGCTTAACTGCTCATTGCTATATTGAAGTACGGATTAGAAGCCGCCGAGCGGGTGACAGCCCTCCGAAGGAAGACTCTCCTCCGTGCGTCCTCGTCTTCACCGGTCGCGTTCCTGAAACGCAGATGTGCCTCGCGCCGCACTGCTCCGAACAATAAAGATTCTACAATACTAGCTTTTATGGTTATGAAGAGGAAAAATTGGCAGTAACCTGGCCCCACAAACCTTCAAATGAACGAATCAAATTAACAACCATAGGATGATAATGCGATTAGTTTTTTAGCCTTATTTCTGGGGTAATTAATCAGCGAAGCGATGATTTTTGATCTATTAACAGATATATAAATGCAAAAACTGCATAACCACTTTAACTAATACTTTCAACATTTTCGGTTTGTATTACTTCTTATTCAAATGTAATAAAAGTATCAACAAAAAATTGTTAATATACCTCTATACTTTAACGTCAAGGAGAAAAAAC", isPeptide: false, comments: "S. cerevisiae GAL1-10 divergent promoter; drives expression in both directions from between the GAL1 and GAL10 genes. Yeast.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.200), showArrow: true, featureType: .promoter, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "lac promoter/operator", sequence: "TTTACACTTTATGCTTCCGGCTCGTATGTTGTGTGGAATTGTGAGCGGATAACAATTTCACACAGG", isPeptide: false, comments: "E. coli lac operon promoter/operator; IPTG-inducible expression in bacteria. Bacterial.", color: CodableColor(red: 0.200, green: 0.400, blue: 0.800), showArrow: true, featureType: .promoter, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "MET15 promoter", sequence: "GGATGCAAGGGTTCGAATCCCTTAGCTCTCATTATTTTTTGCTTTTTCTCTTGAGGTCACATGATCGCAAAATGGCAAATGGCACGTGAAGCTGTCGATATTGGGGAACTGTGGTGGTTGGCAAATGACTAATTAAGTTAGTCAAGGCGCCATCCTCATGAAAACTGTGTAACATAATAACCGAAGTGTCGAAAAGGTGGCACCTTGTCCAATTGAACACGCTCGATGAAAAAAATAAGATATATATAAGGTTAAGTAAAGCGTCTGTTAGAAAGGAAGTTTTTCCTTTTTCTTGCTCTCTTGTCTTTTCATCTACTATTTCCTTCGTGTAATACAGGGTCGTCAGATACATAGATACAATTCTATTACCCCCATCCATACA", isPeptide: false, comments: "S. cerevisiae MET15 promoter; repressed by methionine, useful for conditional expression. Yeast.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.200), showArrow: true, featureType: .promoter, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "mPGK promoter", sequence: "CCGGGTAGGGGAGGCGCTTTTCCCAAGGCAGTCTGGAGCATGCGCTTTAGCAGCCCCGCTGGGCACTTGGCGCTACACAAGTGGCCTCTGGCCTCGCACACATTCCACATCCACCGGTAGGCGCCAACCGGCTCCGTTCTTTGGTGGCCCCTTCGCGCCACCTTCTACTCCTCCCCTAGTCAGGAAGTTCCCCCCCGCCCCGCAGCTCGCGTCGTGCAGGACGTGACAAATGGAAGTAGCACGTCTCACTAGTCTCGTGCAGATGGACAGCACCGCTGAGCAATGGAAGCGGGTAGGCCTTTGGGGCAGCGGCCAATAGCAGCTTTGCTCCTTCGCTTTC", isPeptide: false, comments: "Mouse phosphoglycerate kinase 1 promoter; moderate constitutive expression in mammalian cells. Used in lentiviral and retroviral vectors. Mammalian.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.200), showArrow: true, featureType: .promoter, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "NOS promoter", sequence: "GATCATGAGCGGAGAATTAAGGGAGTCACGTTATGACCCCCGCCGATGACGCGGGACAAGCCGTTTTACGTTTGGAACTGACAGAACCGCAACGTTGAAGGAGCCACTCAGCCGCGGGTTTCTGGAGTTTAATGAGCTAAGCACATACGTCAGAAACCATTATTGCGCGTTCAAAAGTCGCCTAAGGTCACTATCAGCTAGCAAATATTTCTTGTCAAAAATGCTCCACTGACGTTCCATAAATTCCCCTCGGTATCCAATTAGAGTCTCATATTCACTCTCAATCCA", isPeptide: false, comments: "Agrobacterium tumefaciens nopaline synthase promoter; moderate constitutive expression in plants. Commonly drives NPTII selection marker in binary vectors. For plants.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.200), showArrow: true, featureType: .promoter, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "PGK1 promoter", sequence: "AGACGCGAATTTTTCGAAGAAGTACCTTCAAAGAATGGGGTCTTATCTTGTTTTGCAAGTACCACTGAGCAGGATAATAATAGAAATGATAATATACTATAGTAGAGATAACGTCGATGACTTCCCATACTGTAATTGCTTTTAGTTGTGTATTTTTAGTGTGCAAGTTTCTGTAAATCGATTAATTTTTTTTTCTTTCCTCTTTTTATTAACCTTAATTTTTATTTTAGATTCCTGACTTCAACTCAAGACGCACAGATATTATAACATCTGCATAATAGGCATTTGCAAGAATTACTCGTGAGTAAGGAAAGAGTGAGGAACTATCGCATACCTGCATTTAAAGATGCCGATTTGGGCGCGAATCCTTTATTTTGGCTTCACCCTCATACTATTATCAGGGCCAGAAAAAGGAAGTGTTTCCCTCCTTCTTGAATTGATGTTACCCTCATAAAGCACGTGGCCTCTTATCGAGAAAGAAATTACCGTCGCTCGTGATTTGTTTGCAAAAAGAACAAAACTGAAAAAACCCAGACACGCTCGACTTCCTGTCTTCCTATTGATTGCAGCTTCCAATTTCGTCACACAACAAGGTCCTAGCGACGGCTCACAGGTTTTGTAACAAGCAATCGAAGGTTCTGGAATGGCGGGAAAGGGTTTAGTACCACATGCTATGATGCCCACTGTGATCTCCAGAGCAAAGTTCGTTCGATCGTACTGTTACTCTCTCTCTTTCAAACAGAATTGTCCGAATCGTGTGACAACAACAGCCTGTTCTCACACACTCTTTTCTTCTAACCAAGGGGGTGGTTTAGTTTAGTAGAACCTCGTGAAACTTACATTTACATATATATAAACTTGCATAAATTGGTCAATGCAAGAAATACATATTTGGTCTTTTCTAATTCGTAGTTTTTCAAGTTCTTAGATGCTTTCTTTTTCTCTTTTTTACAGATCATCAAGGAAGTAATTATCTACTTTTTACAACAAATATAAAACA", isPeptide: false, comments: "S. cerevisiae phosphoglycerate kinase 1 promoter (1kb); strong constitutive expression, widely used in yeast expression vectors. From SGD YCR012W upstream region. Yeast.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.200), showArrow: true, featureType: .promoter, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "SV40 early promoter", sequence: "TGCATCTCAATTAGTCAGCAACCATAGTCCCGCCCCTAACTCCGCCCATCCCGCCCCTAACTCCGCCCAGTTCCGCCCATTCTCCGCCCCATGGCTGACTAATTTTTTTTATTTATGCAGAGGCCGAGGCCGCCTCGGCCTCTGAGCTATTCCAGAAGTAGTGAGGAGGCTTTTTTGGAGGCCTAGGCTTTTGCAAA", isPeptide: false, comments: "Simian virus 40 early promoter; drives constitutive expression in mammalian cells, also active in some other eukaryotes. Mammalian/Viral.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.200), showArrow: true, featureType: .promoter, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "tac promoter", sequence: "TTGACAATTAATCATCGGCTCGTATAATGTGTGGAATTGTGAGCGGATAACAATTTCACACAGG", isPeptide: false, comments: "Hybrid trp-lac promoter; IPTG-inducible, stronger than lac. Common in pGEX and similar E. coli expression vectors. Bacterial.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.200), showArrow: true, featureType: .promoter, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "TEF promoter", sequence: "CATAGCTTCAAAATGTTTCTACTCCTTTTTTACTCTTCCAGATTTTCTCGGACTCCGCGCATCGCCGTACCACTTCAAAACACCCAAGCACAGCATACTAAATTTCCCCTCTTTCTTCCTCTAGGGTGTCGTTAATTACCCGTACTAAAGGTTTGGAAAAGAAAAAAGAGACCGCCTCGTTTCTTTTTCTTCGTCGAAAAAGGCAATAAAAATTTTTATCACGTTTCTTTTTCTTGAAAATTTTTTTTTTGATTTTTTTCTCTTTCGATGACCTCCCATTGATATTTAAGTTAATAAACGGTCTTCAATTTCTCAAGTTTCAGTTTCATTTTTCTTGTTCTATTACAACTTTTTTTACTTCTTGCTCATTAGAAAGAAAGCATAGCAATCTAATCTAAG", isPeptide: false, comments: "Translation elongation factor 1-alpha promoter from Ashbya gossypii; strong constitutive expression in yeast and fungi. Used in KanMX and other deletion cassettes. Yeast/Fungal.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.200), showArrow: true, featureType: .promoter, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "TrpC promoter", sequence: "TGATATTGAAGGAGCATTTTTTGGGCTTGGCTGGAGCTAGTGGAGGTCAACAATGAATGCCTATTTTGGTTTAGTCGTCCAGGCGGTGAGCACAAAATTTGTGTCGTTTGACAAGATGGTTCATTTAGGCAACTGGTCAGATCAGCCCCACTTGTAGCAGTAGCGGCGGCGCTCGAAGTGTGACTCTTATTAGCAGACAGGAACGAGGACATTATTATCATCTGCTGCTTGGTGCACGATAACTTGGTGCGTTTGTCAAGCAAGGTAAGTGGACGACCCGGTCATACCTTCTTAAGTTCGCCCTTCCTCCCTTTATTTCAGATTCAATCTGACTTACCTATTCTACCCAAGCATCCAA", isPeptide: false, comments: "Aspergillus nidulans tryptophan biosynthesis promoter; constitutive expression in filamentous fungi. Used to drive selection markers in fungal transformation cassettes. Fungal.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.200), showArrow: true, featureType: .promoter, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "U6 promoter", sequence: "AGGTCGGGCAGGAAGAGGGCCTATTTCCCATGATTCCTTCATATTTGCATATACGATACAAGGCTGTTAGAGAGATAATTAGAATTAATTTGACTGTAAACACAAAGATATTAGTACAAAATACGTGACGTAGAAAGTAATAATTTCTTGGGTAGTTTGCAGTTTTAAAATTATGTTTTAAAATGGACTATCATATGCTTACCGTAACTTGAAAGTATTTCGATTTCTTGGCTTTATATATCTTGTGGAAAGGACGAAACACC", isPeptide: false, comments: "Human RNA polymerase III U6 snRNA promoter; used to drive shRNA and guide RNA expression in RNAi and CRISPR applications. Mammalian.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.200), showArrow: true, featureType: .promoter, scanEnabled: true, senseStrandOnly: false),
            ]),

            FeatureCollection(name: "Terminators", scanEnabled: true, items: [
                FeatureLibraryItem(name: "rrnB T1 terminator", sequence: "GGGAACTGCCAGGCATCAAATAAAACGAAAGGCTCAGTCGAAAGACTGGGCCTTTCGTTTTATCTGTTGTTTGTCGGTGAACGCTCTCCTG", isPeptide: false, comments: "E. coli rrnB operon T1 transcription terminator (91bp); used in many bacterial expression vectors to prevent read-through. Bacterial.", color: CodableColor(red: 0.800, green: 0.000, blue: 0.000), showArrow: true, featureType: .terminator, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "T7 terminator", sequence: "CTAGCATAACCCCTTGGGGCCTCTAAACGGGTCTTGAGGGGTTTTTTG", isPeptide: false, comments: "Bacteriophage T7 transcription terminator (48bp); used in T7-based expression systems. Bacterial/Phage.", color: CodableColor(red: 0.800, green: 0.000, blue: 0.000), showArrow: true, featureType: .terminator, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "ADH1 terminator", sequence: "GCGAATTTCTTATGATTTATGATTTTTATTATTAAATAAGTTATAAAAAAAATAAGTGTATACAAATTTTAAAGTGACTCTTAGGTTTTAAAACGAAAATTCTTATTCTTGAGTAACTCTTTCCTGTAGGTCAGGTTGCTTTCTCAGGTATAGCATGAGGTCGCTCTTATTGACCACACCTCTACCGGC", isPeptide: false, comments: "S. cerevisiae alcohol dehydrogenase 1 transcription terminator (189bp); widely used in yeast expression vectors. Yeast.", color: CodableColor(red: 0.800, green: 0.000, blue: 0.000), showArrow: true, featureType: .terminator, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "CYC1 terminator", sequence: "TCATGTAATTAGTTATGTCACGCTTACATTCACGCCCTCCTCCCACATCCGCTCTAACCGAAAAGGAAGGAGTTAGACAACCTGAAGTCTAGGTCCCTATTTATTTTTTTTAATAGTTATGTTAGTATTAAGAACGTTATTTATATTTCAAATTTTTCTTTTTTTTCTGTACAAACGCGTGTACGCATGTAACATTATACTGAAAACCTTGCTTGAGAAGGTTTTGGGACGCTCG", isPeptide: false, comments: "S. cerevisiae cytochrome c isoform 1 transcription terminator (235bp); commonly used in yeast expression and two-hybrid vectors. Yeast.", color: CodableColor(red: 0.800, green: 0.000, blue: 0.000), showArrow: true, featureType: .terminator, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "CYC1 terminator (pYES2)", sequence: "ATCATGTAATTAGTTATGTCACGCTTACATTCACGCCCTCCCCCCACATCCGCTCTAACCGAAAAGGAAGGAGTTAGACAACCTGAAGTCTAGGTCCCTATTTATTTTTTTATAGTTATGTTAGTATTAAGAACGTTATTTATATTTCAAATTTTTCTTTTTTTTCTGTACAGACGCGTGTACGCATGTAACATTATACTGAAAACCTTGCTTGAGAAGGTTTTGGGACGCTCGAAGGCTTTAATTTGC", isPeptide: false, comments: "S. cerevisiae CYC1 transcription terminator variant (249bp) from pYES2. Slightly different sequence from standard CYC1 terminator. Yeast.", color: CodableColor(red: 0.800, green: 0.000, blue: 0.000), showArrow: true, featureType: .terminator, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "CaMV 35S polyA", sequence: "GATCTGTCGATCGACAAGCTCGAGTTTCTCCATAATAATGTGTGAGTAGTTCCCAGATAAGGGAATTAGGGTTCCTATAGGGTTTCGCTCATGTGTTGAGCATATAAGAAACCCTTAGTATGTATTTGTATTTGTAAAATACTTCTATCAATAAAATTTCTAATTCCTAAAACCAAAATCCAGTACTAAAATCCAGATCCCCCGAATTA", isPeptide: false, comments: "Cauliflower mosaic virus 35S RNA polyadenylation signal (209bp); used as transcription terminator in plant expression vectors. From pCAMBIA. Note: contains the short variant (175bp) as a subset. For plants.", color: CodableColor(red: 0.800, green: 0.000, blue: 0.000), showArrow: true, featureType: .terminator, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "CaMV 35S polyA (short)", sequence: "GTTTCTCCATAATAATGTGTGAGTAGTTCCCAGATAAGGGAATTAGGGTTCCTATAGGGTTTCGCTCATGTGTTGAGCATATAAGAAACCCTTAGTATGTATTTGTATTTGTAAAATACTTCTATCAATAAAATTTCTAATTCCTAAAACCAAAATCCAGTACTAAAATCCAGAT", isPeptide: false, comments: "Cauliflower mosaic virus 35S RNA polyadenylation signal, core sequence (175bp). Contained within CaMV 35S polyA (209bp). Use this entry to detect vectors carrying either the short or long version. For plants.", color: CodableColor(red: 0.800, green: 0.000, blue: 0.000), showArrow: true, featureType: .terminator, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "NOS polyA", sequence: "CGTTCAAACATTTGGCAATAAAGTTTCTTAAGATTGAATCCTGTTGCCGGTCTTGCGATGATTATCATATAATTTCTGTTGAATTACGTTAAGCATGTAATAATTAACATGTAATGCATGACGTTATTTATGAGATGGGTTTTTATGATTAGAGTCCCGCAATTATACATTTAATACGCGATAGAAAACAAAATATAGCGCGCAAACTAGGATAAATTATCGCGCGCGGTGTCATCTATGTTACTAGATCGGG", isPeptide: false, comments: "Agrobacterium tumefaciens nopaline synthase polyadenylation signal (253bp); widely used terminator in plant binary vectors. From pCAMBIA. For plants.", color: CodableColor(red: 0.800, green: 0.000, blue: 0.000), showArrow: true, featureType: .terminator, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "OCS terminator", sequence: "CTGCTTTAATGAGATATGCGAGACGCCTATGATCGCATGATATTTGCTTTCAATTCTGTTGTGCACGTTGTAAAAAACCTGAGCATGTGTAGCTCAGATCCTTACCGCCGGTTTCGGTTCATTCTAATGAATATATCACCCGTTACTATCGTATTTTTATGAATAATATTCTCCGTTCAATTTACTGATTGT", isPeptide: false, comments: "Agrobacterium tumefaciens octopine synthase gene transcription terminator (192bp). Used in pBinAR and related binary vectors. For plants.", color: CodableColor(red: 0.800, green: 0.000, blue: 0.000), showArrow: true, featureType: .terminator, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "bGH polyA signal", sequence: "CGACTGTGCCTTCTAGTTGCCAGCCATCTGTTGTTTGCCCCTCCCCCGTGCCTTCCTTGACCCTGGAAGGTGCCACTCCCACTGTCCTTTCCTAATAAAATGAGGAAATTGCATCGCATTGTCTGAGTAGGTGTCATTCTATTCTGGGGGGTGGGGTGGGGCAGGACAGCAAGGGGGAGGATTGGGAAGACAATAGCAGGCATGCTGGGGATGCGGTGGGCTCTATGG", isPeptide: false, comments: "Bovine growth hormone polyadenylation signal (228bp); widely used in mammalian expression vectors. Contains the short variant (208bp) as a subset. Mammalian.", color: CodableColor(red: 0.800, green: 0.000, blue: 0.000), showArrow: true, featureType: .terminator, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "bGH polyA signal (short)", sequence: "CTGTGCCTTCTAGTTGCCAGCCATCTGTTGTTTGCCCCTCCCCCGTGCCTTCCTTGACCCTGGAAGGTGCCACTCCCACTGTCCTTTCCTAATAAAATGAGGAAATTGCATCGCATTGTCTGAGTAGGTGTCATTCTATTCTGGGGGGTGGGGTGGGGCAGGACAGCAAGGGGGAGGATTGGGAAGACAATAGCAGGCATGCTGGGGA", isPeptide: false, comments: "Bovine growth hormone polyadenylation signal, core sequence (208bp). Contained within bGH polyA signal (228bp). Use this entry to detect vectors carrying either the short or long version. Mammalian.", color: CodableColor(red: 0.800, green: 0.000, blue: 0.000), showArrow: true, featureType: .terminator, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "hGH polyA signal", sequence: "CGGGTGGCATCCCTGTGACCCCTCCCCAGTGCCTCTCCTGGCCCTGGAAGTTGCCACTCCAGTGCCCACCAGCCTTGTCCTAATAAAATTAAGTTGCATCATTTTGTCTGACTAGGTGTCCTTCTATAATATTATGGGGTGGAGGGGGGTGGTATGGAGCAAGGGGCAAGTTGGGAAGACAACCTGTAGGGCCTGCGGGGTCTATTGGGAACCAAGCTGGAGTGCAGTGGCACAATCTTGGCTCACTGCAATCTCCGCCTCCTGGGTTCAAGCGATTCTCCTGCCTCAGCCTCCCGAGTTGTTGGGATTCCAGGCATGCATGACCAGGCTCAGCTAATTTTTGTTTTTTTGGTAGAGACGGGGTTTCACCATATTGGCCAGGCTGGTCTCCAACTCCTAATCTCAGGTGATCTACCCACCTTGGCCTCCCAAATTGCTGGGATTACAGGCGTGAACCACTGCTCCCTTCCCTGTCCTTCTG", isPeptide: false, comments: "Human growth hormone polyadenylation signal (481bp); used in mammalian expression vectors as transcription terminator. Mammalian.", color: CodableColor(red: 0.800, green: 0.000, blue: 0.000), showArrow: true, featureType: .terminator, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "SV40 late polyA", sequence: "CAGACATGATAAGATACATTGATGAGTTTGGACAAACCACAACTAGAATGCAGTGAAAAAAATGCTTTATTTGTGAAATTTGTGATGCTATTGCTTTATTTGTAACCATTATAAGCTGCAATAAACAAGTTAACAACAACAATTGCATTCATTTTATGTTTCAGGTTCAGGGGGAGGTGTGGGAGGTTTTTT", isPeptide: false, comments: "Simian virus 40 late region polyadenylation signal (192bp); commonly used terminator in mammalian expression vectors. Mammalian/Viral.", color: CodableColor(red: 0.800, green: 0.000, blue: 0.000), showArrow: true, featureType: .terminator, scanEnabled: true, senseStrandOnly: false),
            ]),

            FeatureCollection(name: "Reporters", scanEnabled: true, items: [
                FeatureLibraryItem(name: "mGFP5*", sequence: "ATGGTAGATCTGACTAGTAAAGGAGAAGAACTTTTCACTGGAGTTGTCCCAATTCTTGTTGAATTAGATGGTGATGTTAATGGGCACAAATTTTCTGTCAGTGGAGAGGGTGAAGGTGATGCAACATACGGAAAACTTACCCTTAAATTTATTTGCACTACTGGAAAACTACCTGTTCCGTGGCCAACACTTGTCACTACTTTCTCTTATGGTGTTCAATGCTTTTCAAGATACCCAGATCATATGAAGCGGCACGACTTCTTCAAGAGCGCCATGCCTGAGGGATACGTGCAGGAGAGGACCATCTTCTTCAAGGACGACGGGAACTACAAGACACGTGCTGAAGTCAAGTTTGAGGGAGACACCCTCGTCAACAGGATCGAGCTTAAGGGAATCGATTTCAAGGAGGACGGAAACATCCTCGGCCACAAGTTGGAATACAACTACAACTCCCACAACGTATACATCATGGCCGACAAGCAAAAGAACGGCATCAAAGCCAACTTCAAGACCCGCCACAACATCGAAGACGGCGGCGTGCAACTCGCTGATCATTATCAACAAAATACTCCAATTGGCGATGGCCCTGTCCTTTTACCAGACAACCATTACCTGTCCACACAATCTGCCCTTTCGAAAGATCCCAACGAAAAGAGAGACCACATGGTCCTTCTTGAGTTTGTAACAGCTGCTGGGATTACACATGGCATGGATGAACTATACAAAGCTAGCCACCACCACCACCACCACGTGTGA", isPeptide: false, comments: "Plant-optimised GFP variant mGFP5* (756bp, 251aa). Used in pCAMBIA-1302 to drive reporter expression. From pCAMBIA-1302 (AF234302). Green fluorescent.", color: CodableColor(red: 0.000, green: 0.700, blue: 0.000), showArrow: true, featureType: .reporter, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "EGFP", sequence: "ATGGTGAGCAAGGGCGAGGAGCTGTTCACCGGGGTGGTGCCCATCCTGGTCGAGCTGGACGGCGACGTAAACGGCCACAAGTTCAGCGTGTCCGGCGAGGGCGAGGGCGATGCCACCTACGGCAAGCTGACCCTGAAGTTCATCTGCACCACCGGCAAGCTGCCCGTGCCCTGGCCCACCCTCGTGACCACCCTGACCTACGGCGTGCAGTGCTTCAGCCGCTACCCCGACCACATGAAGCAGCACGACTTCTTCAAGTCCGCCATGCCCGAAGGCTACGTCCAGGAGCGCACCATCTTCTTCAAGGACGACGGCAACTACAAGACCCGCGCCGAGGTGAAGTTCGAGGGCGACACCCTGGTGAACCGCATCGAGCTGAAGGGCATCGACTTCAAGGAGGACGGCAACATCCTGGGGCACAAGCTGGAGTACAACTACAACAGCCACAACGTCTATATCATGGCCGACAAGCAGAAGAACGGCATCAAGGTGAACTTCAAGATCCGCCACAACATCGAGGACGGCAGCGTGCAGCTCGCCGACCACTACCAGCAGAACACCCCCATCGGCGACGGCCCCGTGCTGCTGCCCGACAACCACTACCTGAGCACCCAGTCCGCCCTGAGCAAAGACCCCAACGAGAAGCGCGATCACATGGTCCTGCTGGAGTTCGTGACCGCCGCCGGGATCACTCTCGGCATGGACGAGCTGTACAAGTAA", isPeptide: false, comments: "Enhanced GFP (720bp, 239aa); F64L/S65T mutations give brighter fluorescence than wildtype. Standard reporter in bacterial, yeast and mammalian expression vectors. Green fluorescent.", color: CodableColor(red: 0.000, green: 0.700, blue: 0.000), showArrow: true, featureType: .reporter, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "AcGFP", sequence: "ATGGTGAGCAAGGGCGCCGAGCTGTTCACCGGCATCGTGCCCATCCTGATCGAGCTGAATGGCGATGTGAATGGCCACAAGTTCAGCGTGAGCGGCGAGGGCGAGGGCGATGCCACCTACGGCAAGCTGACCCTGAAGTTCATCTGCACCACCGGCAAGCTGCCTGTGCCCTGGCCCACCCTGGTGACCACCCTGAGCTACGGCGTGCAGTGCTTCTCACGCTACCCCGATCACATGAAGCAGCACGACTTCTTCAAGAGCGCCATGCCTGAGGGCTACATCCAGGAGCGCACCATCTTCTTCGAGGATGACGGCAACTACAAGTCGCGCGCCGAGGTGAAGTTCGAGGGCGATACCCTGGTGAATCGCATCGAGCTGACCGGCACCGATTTCAAGGAGGATGGCAACATCCTGGGCAATAAGATGGAGTACAACTACAACGCCCACAATGTGTACATCATGACCGACAAGGCCAAGAATGGCATCAAGGTGAACTTCAAGATCCGCCACAACATCGAGGATGGCAGCGTGCAGCTGGCCGACCACTACCAGCAGAATACCCCCATCGGCGATGGCCCTGTGCTGCTGCCCGATAACCACTACCTGTCCACCCAGAGCGCCCTGTCCAAGGACCCCAACGAGAAGCGCGATCACATGATCTACTTCGGCTTCGTGACCGCCGCCGCCATCACCCACGGCATGGATGAGCTGTACAAGTGA", isPeptide: false, comments: "GFP from Aequorea coerulescens (720bp, 239aa); distinct sequence from EGFP (~8% similarity). Used in some dual-reporter systems. Green fluorescent.", color: CodableColor(red: 0.000, green: 0.700, blue: 0.000), showArrow: true, featureType: .reporter, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "ECFP", sequence: "ATGGTGAGCAAGGGCGAGGAGCTGTTCACCGGGGTGGTGCCCATCCTGGTCGAGCTGGACGGCGACGTAAACGGCCACAAGTTCAGCGTGTCCGGCGAGGGCGAGGGCGATGCCACCTACGGCAAGCTGACCCTGAAGTTCATCTGCACCACCGGCAAGCTGCCCGTGCCCTGGCCCACCCTCGTGACCACCCTGACCTGGGGCGTGCAGTGCTTCAGCCGCTACCCCGACCACATGAAGCAGCACGACTTCTTCAAGTCCGCCATGCCCGAAGGCTACGTCCAGGAGCGCACCATCTTCTTCAAGGACGACGGCAACTACAAGACCCGCGCCGAGGTGAAGTTCGAGGGCGACACCCTGGTGAACCGCATCGAGCTGAAGGGCATCGACTTCAAGGAGGACGGCAACATCCTGGGGCACAAGCTGGAGTACAACTACATCAGCCACAACGTCTATATCACCGCCGACAAGCAGAAGAACGGCATCAAGGCCAACTTCAAGATCCGCCACAACATCGAGGACGGCAGCGTGCAGCTCGCCGACCACTACCAGCAGAACACCCCCATCGGCGACGGCCCCGTGCTGCTGCCCGACAACCACTACCTGAGCACCCAGTCCGCCCTGAGCAAAGACCCCAACGAGAAGCGCGATCACATGGTCCTGCTGGAGTTCGTGACCGCCGCCGGGATCACTCTCGGCATGGACGAGCTGTACAAGTAA", isPeptide: false, comments: "Enhanced cyan fluorescent protein (720bp, 239aa); Y66W/N146I/M153T/V163A mutations shift emission to cyan (~476nm). From pECFP (Clontech). Cyan fluorescent.", color: CodableColor(red: 0.000, green: 0.700, blue: 0.800), showArrow: true, featureType: .reporter, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "EYFP", sequence: "ATGGTGAGCAAGGGCGAGGAGCTGTTCACCGGGGTGGTGCCCATCCTGGTCGAGCTGGACGGCGACGTAAACGGCCACAAGTTCAGCGTGTCCGGCGAGGGCGAGGGCGATGCCACCTACGGCAAGCTGACCCTGAAGTTCATCTGCACCACCGGCAAGCTGCCCGTGCCCTGGCCCACCCTCGTGACCACCTTCGGCTACGGCCTGCAGTGCTTCGCCCGCTACCCCGACCACATGAAGCAGCACGACTTCTTCAAGTCCGCCATGCCCGAAGGCTACGTCCAGGAGCGCACCATCTTCTTCAAGGACGACGGCAACTACAAGACCCGCGCCGAGGTGAAGTTCGAGGGCGACACCCTGGTGAACCGCATCGAGCTGAAGGGCATCGACTTCAAGGAGGACGGCAACATCCTGGGGCACAAGCTGGAGTACAACTACAACAGCCACAACGTCTATATCATGGCCGACAAGCAGAAGAACGGCATCAAGGTGAACTTCAAGATCCGCCACAACATCGAGGACGGCAGCGTGCAGCTCGCCGACCACTACCAGCAGAACACCCCCATCGGCGACGGCCCCGTGCTGCTGCCCGACAACCACTACCTGAGCTACCAGTCCGCCCTGAGCAAAGACCCCAACGAGAAGCGCGATCACATGGTCCTGCTGGAGTTCGTGACCGCCGCCGGGATCACTCTCGGCATGGACGAGCTGTACAAGTAA", isPeptide: false, comments: "Enhanced yellow fluorescent protein (720bp, 239aa); T203Y mutation shifts emission to yellow (~527nm). From pEYFP-1 (Clontech). Yellow fluorescent.", color: CodableColor(red: 0.900, green: 0.800, blue: 0.000), showArrow: true, featureType: .reporter, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "mCherry", sequence: "ATGGTGAGCAAGGGCGAGGAGGATAACATGGCCATCATCAAGGAGTTCATGCGCTTCAAGGTGCACATGGAGGGCTCCGTGAACGGCCACGAGTTCGAGATCGAGGGCGAGGGCGAGGGCCGCCCCTACGAGGGCACCCAGACCGCCAAGCTGAAGGTGACCAAGGGTGGCCCCCTGCCCTTCGCCTGGGACATCCTGTCCCCTCAGTTCATGTACGGCTCCAAGGCCTACGTGAAGCACCCCGCCGACATCCCCGACTACTTGAAGCTGTCCTTCCCCGAGGGCTTCAAGTGGGAGCGCGTGATGAACTTCGAGGACGGCGGCGTGGTGACCGTGACCCAGGACTCCTCCCTGCAGGACGGCGAGTTCATCTACAAGGTGAAGCTGCGCGGCACCAACTTCCCCTCCGACGGCCCCGTAATGCAGAAGAAGACCATGGGCTGGGAGGCCTCCTCCGAGCGGATGTACCCCGAGGACGGCGCCCTGAAGGGCGAGATCAAGCAGAGGCTGAAGCTGAAGGACGGCGGCCACTACGACGCTGAGGTCAAGACCACCTACAAGGCCAAGAAGCCCGTGCAGCTGCCCGGCGCCTACAACGTCAACATCAAGTTGGACATCACCTCCCACAACGAGGACTACACCATCGTGGAACAGTACGAACGCGCCGAGGGCCGCCACTCCACCGGCGGCATGGACGAGCTGTACAAGTAA", isPeptide: false, comments: "Monomeric cherry red fluorescent protein (711bp, 236aa); derived from DsRed, widely used as red reporter in all organisms. Red fluorescent.", color: CodableColor(red: 0.850, green: 0.100, blue: 0.100), showArrow: true, featureType: .reporter, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "mRFP1", sequence: "ATGGCCTCCTCCGAGGACGTCATCAAGGAGTTCATGCGCTTCAAGGTGCGCATGGAGGGCTCCGTGAACGGCCACGAGTTCGAGATCGAGGGCGAGGGCGAGGGCCGCCCCTACGAGGGCACCCAGACCGCCAAGCTGAAGGTGACCAAGGGCGGCCCCCTGCCCTTCGCCTGGGACATCCTGTCCCCTCAGTTCCAGTACGGCTCCAAGGCCTACGTGAAGCACCCCGCCGACATCCCCGACTACTTGAAGCTGTCCTTCCCCGAGGGCTTCAAGTGGGAGCGCGTGATGAACTTCGAGGACGGCGGCGTGGTGACCGTGACCCAGGACTCCTCCCTGCAGGACGGCGAGTTCATCTACAAGGTGAAGCTGCGCGGCACCAACTTCCCCTCCGACGGCCCCGTAATGCAGAAGAAGACCATGGGCTGGGAGGCCTCCACCGAGCGGATGTACCCCGAGGACGGCGCCCTGAAGGGCGAGATCAAGATGAGGCTGAAGCTGAAGGACGGCGGCCACTACGACGCCGAGGTCAAGACCACCTACATGGCCAAGAAGCCCGTGCAGCTGCCCGGCGCCTACAAGACCGACATCAAGCTGGACATCACCTCCCACAACGAGGACTACACCATCGTGGAACAGTACGAGCGCGCCGAGGGCCGCCACTCCACCGGCGCCTAA", isPeptide: false, comments: "Monomeric red fluorescent protein 1 (678bp, 225aa); monomeric derivative of DsRed from Discosoma sp. Excitation 584nm, emission 607nm. From pABC5-mRFP1. Red fluorescent.", color: CodableColor(red: 0.850, green: 0.100, blue: 0.100), showArrow: true, featureType: .reporter, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "GUS", sequence: "ATGGTAGATCTGAGGAACCGACGACTCGTCCGTCCTGTAGAAACCCCAACCCGTGAAATCAAAAAACTCGACGGCCTGTGGGCATTCAGTCTGGATCGCGAAAACTGTGGAATTGATCAGCGTTGGTGGGAAAGCGCGTTACAAGAAAGCCGGGCAATTGCTGTGCCAGGCAGTTTTAACGATCAGTTCGCCGATGCAGATATTCGTAATTATGCGGGCAACGTCTGGTATCAGCGCGAAGTCTTTATACCGAAAGGTTGGGCAGGCCAGCGTATCGTGCTGCGTTTCGATGCGGTCACTCATTACGGCAAAGTGTGGGTCAATAATCAGGAAGTGATGGAGCATCAGGGCGGCTATACGCCATTTGAAGCCGATGTCACGCCGTATGTTATTGCCGGGAAAAGTGTACGTATCACCGTTTGTGTGAACAACGAACTGAACTGGCAGACTATCCCGCCGGGAATGGTGATTACCGACGAAAACGGCAAGAAAAAGCAGTCTTACTTCCATGATTTCTTTAACTATGCCGGAATCCATCGCAGCGTAATGCTCTACACCACGCCGAACACCTGGGTGGACGATATCACCGTGGTGACGCATGTCGCGCAAGACTGTAACCACGCGTCTGTTGACTGGCAGGTGGTGGCCAATGGTGATGTCAGCGTTGAACTGCGTGATGCGGATCAACAGGTGGTTGCAACTGGACAAGGCACTAGCGGGACTTTGCAAGTGGTGAATCCGCACCTCTGGCAACCGGGTGAAGGTTATCTCTATGAACTCGAAGTCACAGCCAAAAGCCAGACAGAGTCTGATATCTACCCGCTTCGCGTCGGCATCCGGTCAGTGGCAGTGAAGGGCCAACAGTTCCTGATTAACCACAAACCGTTCTACTTTACTGGCTTTGGTCGTCATGAAGATGCGGACTTACGTGGCAAAGGATTCGATAACGTGCTGATGGTGCACGACCACGCATTAATGGACTGGATTGGGGCCAACTCCTACCGTACCTCGCATTACCCTTACGCTGAAGAGATGCTCGACTGGGCAGATGAACATGGCATCGTGGTGATTGATGAAACTGCTGCTGTCGGCTTTCAGCTGTCTTTAGGCATTGGTTTCGAAGCGGGCAACAAGCCGAAAGAACTGTACAGCGAAGAGGCAGTCAACGGGGAAACTCAGCAAGCGCACTTACAGGCGATTAAAGAGCTGATAGCGCGTGACAAAAACCACCCAAGCGTGGTGATGTGGAGTATTGCCAACGAACCGGATACCCGTCCGCAAGGTGCACGGGAATATTTCGCGCCACTGGCGGAAGCAACGCGTAAACTCGACCCGACGCGTCCGATCACCTGCGTCAATGTAATGTTCTGCGACGCTCACACCGATACCATCAGCGATCTCTTTGATGTGCTGTGCCTGAACCGTTATTACGGATGGTATGTCCAAAGCGGCGATTTGGAAACGGCAGAGAAGGTACTGGAAAAAGAACTTCTGGCCTGGCAGGAGAAACTGCATCAGCCGATTATCATCACCGAATACGGCGTGGATACGTTAGCCGGGCTGCACTCAATGTACACCGACATGTGGAGTGAAGAGTATCAGTGTGCATGGCTGGATATGTATCACCGCGTCTTTGATCGCGTCAGCGCCGTCGTCGGTGAACAGGTATGGAATTTCGCCGATTTTGCGACCTCGCAAGGCATATTGCGCGTTGGCGGTAACAAGAAAGGGATCTTCACTCGCGACCGCAAACCGAAGTCGGCGGCTTTTCTGCTGCAAAAACGCTGGACTGGCATGAACTTCGGTGAAAAACCGCAGCAGGGAGGCAAACAAGCTAGCCACCACCACCACCACCACGTGTGA", isPeptide: false, comments: "Beta-glucuronidase uidA gene (1863bp, 620aa). Standard reporter for plant transformation. Substrate (X-Gluc) turns blue on cleavage. From pCAMBIA-1301. Enzymatic reporter.", color: CodableColor(red: 0.200, green: 0.400, blue: 0.800), showArrow: true, featureType: .reporter, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "GUS-intron", sequence: "CATGGTAGATCTGAGGGTAAATTTCTAGTTTTTCTCCTTCATTTTCTTGGTTAGGACCCTTTTCTCTTTTTATTTTTTTGAGCTTTGATCTTTCTTTAAACTGATCTATTTTTTAATTGATTGGTTATGGTGTAAATATTACATAGCTTTAACTGATAATCTGATTACTTTATTTCGTGTGTCTATGATGATGATGATAGTTACAGAACCGACGACTCGTCCGTCCTGTAGAAACCCCAACCCGTGAAATCAAAAAACTCGACGGCCTGTGGGCATTCAGTCTGGATCGCGAAAACTGTGGAATTGATCAGCGTTGGTGGGAAAGCGCGTTACAAGAAAGCCGGGCAATTGCTGTGCCAGGCAGTTTTAACGATCAGTTCGCCGATGCAGATATTCGTAATTATGCGGGCAACGTCTGGTATCAGCGCGAAGTCTTTATACCGAAAGGTTGGGCAGGCCAGCGTATCGTGCTGCGTTTCGATGCGGTCACTCATTACGGCAAAGTGTGGGTCAATAATCAGGAAGTGATGGAGCATCAGGGCGGCTATACGCCATTTGAAGCCGATGTCACGCCGTATGTTATTGCCGGGAAAAGTGTACGTATCACCGTTTGTGTGAACAACGAACTGAACTGGCAGACTATCCCGCCGGGAATGGTGATTACCGACGAAAACGGCAAGAAAAAGCAGTCTTACTTCCATGATTTCTTTAACTATGCCGGAATCCATCGCAGCGTAATGCTCTACACCACGCCGAACACCTGGGTGGACGATATCACCGTGGTGACGCATGTCGCGCAAGACTGTAACCACGCGTCTGTTGACTGGCAGGTGGTGGCCAATGGTGATGTCAGCGTTGAACTGCGTGATGCGGATCAACAGGTGGTTGCAACTGGACAAGGCACTAGCGGGACTTTGCAAGTGGTGAATCCGCACCTCTGGCAACCGGGTGAAGGTTATCTCTATGAACTCGAAGTCACAGCCAAAAGCCAGACAGAGTCTGATATCTACCCGCTTCGCGTCGGCATCCGGTCAGTGGCAGTGAAGGGCCAACAGTTCCTGATTAACCACAAACCGTTCTACTTTACTGGCTTTGGTCGTCATGAAGATGCGGACTTACGTGGCAAAGGATTCGATAACGTGCTGATGGTGCACGACCACGCATTAATGGACTGGATTGGGGCCAACTCCTACCGTACCTCGCATTACCCTTACGCTGAAGAGATGCTCGACTGGGCAGATGAACATGGCATCGTGGTGATTGATGAAACTGCTGCTGTCGGCTTTCAGCTGTCTTTAGGCATTGGTTTCGAAGCGGGCAACAAGCCGAAAGAACTGTACAGCGAAGAGGCAGTCAACGGGGAAACTCAGCAAGCGCACTTACAGGCGATTAAAGAGCTGATAGCGCGTGACAAAAACCACCCAAGCGTGGTGATGTGGAGTATTGCCAACGAACCGGATACCCGTCCGCAAGGTGCACGGGAATATTTCGCGCCACTGGCGGAAGCAACGCGTAAACTCGACCCGACGCGTCCGATCACCTGCGTCAATGTAATGTTCTGCGACGCTCACACCGATACCATCAGCGATCTCTTTGATGTGCTGTGCCTGAACCGTTATTACGGATGGTATGTCCAAAGCGGCGATTTGGAAACGGCAGAGAAGGTACTGGAAAAAGAACTTCTGGCCTGGCAGGAGAAACTGCATCAGCCGATTATCATCACCGAATACGGCGTGGATACGTTAGCCGGGCTGCACTCAATGTACACCGACATGTGGAGTGAAGAGTATCAGTGTGCATGGCTGGATATGTATCACCGCGTCTTTGATCGCGTCAGCGCCGTCGTCGGTGAACAGGTATGGAATTTCGCCGATTTTGCGACCTCGCAAGGCATATTGCGCGTTGGCGGTAACAAGAAAGGGATCTTCACTCGCGACCGCAAACCGAAGTCGGCGGCTTTTCTGCTGCAAAAACGCTGGACTGGCATGAACTTCGGTGAAAAACCGCAGCAGGGAGGCAAACAAGCTAGCCACCACCACCACCACCAC", isPeptide: false, comments: "GUS gene with plant catalase intron (2048bp). Intron prevents expression in bacteria, confirming genuine plant cell expression. Substrate (X-Gluc) turns blue on cleavage. Enzymatic reporter.", color: CodableColor(red: 0.200, green: 0.400, blue: 0.800), showArrow: true, featureType: .reporter, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "LacZ alpha", sequence: "TGGCGTAATAGCGAAGAGGCCCGCACCGATCGCCCTTCCCAACAGTTGCGCAGCCTGAATGGCGAATGG", isPeptide: false, comments: "LacZ alpha fragment (69bp); used for blue-white colony screening in pUC and pBluescript vectors. Substrate (X-Gal) turns blue on cleavage — blue colonies have no insert, white colonies have insert. Enzymatic reporter.", color: CodableColor(red: 0.200, green: 0.400, blue: 0.800), showArrow: true, featureType: .reporter, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "Fluc", sequence: "ATGGAAGACGCCAAAAACATAAAGAAAGGCCCGGCGCCATTCTATCCTCTAGAGGATGGAACCGCTGGAGAGCAACTGCATAAGGCTATGAAGAGATACGCCCTGGTTCCTGGAACAATTGCTTTTACAGATGCACATATCGAGGTGAACATCACGTACGCGGAATACTTCGAAATGTCCGTTCGGTTGGCAGAAGCTATGAAACGATATGGGCTGAATACAAATCACAGAATCGTCGTATGCAGTGAAAACTCTCTTCAATTCTTTATGCCGGTGTTGGGCGCGTTATTTATCGGAGTTGCAGTTGCGCCCGCGAACGACATTTATAATGAACGTGAATTGCTCAACAGTATGAACATTTCGCAGCCTACCGTAGTGTTTGTTTCCAAAAAGGGGTTGCAAAAAATTTTGAACGTGCAAAAAAAATTACCAATAATCCAGAAAATTATTATCATGGATTCTAAAACGGATTACCAGGGATTTCAGTCGATGTACACGTTCGTCACATCTCATCTACCTCCCGGTTTTAATGAATACGATTTTGTACCAGAGTCCTTTGATCGTGACAAAACAATTGCACTGATAATGAATTCCTCTGGATCTACTGGGTTACCTAAGGGTGTGGCCCTTCCGCATAGAACTGCCTGCGTCAGATTCTCGCATGCCAGAGATCCTATTTTTGGCAATCAAATCATTCCGGATACTGCGATTTTAAGTGTTGTTCCATTCCATCACGGTTTTGGAATGTTTACTACACTCGGATATTTGATATGTGGATTTCGAGTCGTCTTAATGTATAGATTTGAAGAAGAGCTGTTTTTACGATCCCTTCAGGATTACAAAATTCAAAGTGCGTTGCTAGTACCAACCCTATTTTCATTCTTCGCCAAAAGCACTCTGATTGACAAATACGATTTATCTAATTTACACGAAATTGCTTCTGGGGGCGCACCTCTTTCGAAAGAAGTCGGGGAAGCGGTTGCAAAACGCTTCCATCTTCCAGGGATACGACAAGGATATGGGCTCACTGAGACTACATCAGCTATTCTGATTACACCCGAGGGGGATGATAAACCGGGCGCGGTCGGTAAAGTTGTTCCATTTTTTGAAGCGAAGGTTGTGGATCTGGATACCGGGAAAACGCTGGGCGTTAATCAGAGAGGCGAATTATGTGTCAGAGGACCTATGATTATGTCCGGTTATGTAAACAATCCGGAAGCGACCAACGCCTTGATTGACAAGGATGGATGGCTACATTCTGGAGACATAGCTTACTGGGACGAAGACGAACACTTCTTCATAGTTGACCGCTTGAAGTCTTTAATTAAATACAAAGGATATCAGGTGGCCCCCGCTGAATTGGAATCGATATTGTTACAACACCCCAACATCTTCGACGCGGGCGTGGCAGGTCTTCCCGACGATGACGCCGGTGAACTTCCCGCCGCCGTTGTTGTTTTGGAGCACGGAAAGACGATGACGGAAAAAGAGATCGTGGATTACGTCGCCAGTCAAGTAACAACCGCGAAAAAGTTGCGCGGAGGAGTTGTGTTTGTGGACGAAGTACCGAAAGGTCTTACCGGAAAACTCGACGCAAGAAAAATCAGAGAGATCCTCATAAAGGCCAAGAAGGGCGGAAAGTCCAAATTGTAA", isPeptide: false, comments: "Firefly (Photinus pyralis) luciferase (1653bp, 550aa); bioluminescent reporter requiring luciferin. From M15077. Bioluminescent reporter.", color: CodableColor(red: 0.950, green: 0.500, blue: 0.000), showArrow: true, featureType: .reporter, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "hRluc", sequence: "ATGGCTTCGAAGGTGTACGACCCCGAGCAGAGGAAGAGGATGATCACCGGCCCCCAGTGGTGGGCCAGGTGCAAGCAGATGAACGTGCTGGACAGCTTCATCAACTACTACGACAGCGAGAAGCACGCCGAGAACGCCGTGATCTTCCTGCACGGCAACGCCGCTAGCAGCTACCTGTGGAGGCACGTGGTGCCCCACATCGAGCCCGTGGCCAGGTGCATCATCCCCGATCTGATCGGCATGGGCAAGAGCGGCAAGAGCGGCAACGGCAGCTACAGGCTGCTGGACCACTACAAGTACCTGACCGCCTGGTTCGAGCTCCTGAACCTGCCCAAGAAGATCATCTTCGTGGGCCACGACTGGGGCGCCTGCCTGGCCTTCCACTACAGCTACGAGCACCAGGACAAGATCAAGGCCATCGTGCACGCCGAGAGCGTGGTGGACGTGATCGAGAGCTGGGACGAGTGGCCAGACATCGAGGAGGACATCGCCCTGATCAAGAGCGAGGAGGGCGAGAAGATGGTGCTGGAGAACAACTTCTTCGTGGAGACCATGCTGCCCAGCAAGATCATGAGAAAGCTGGAGCCCGAGGAGTTCGCCGCCTACCTGGAGCCCTTCAAGGAGAAGGGCGAGGTGAGAAGACCCACCCTGAGCTGGCCCAGAGAGATCCCCCTGGTGAAGGGCGGCAAGCCCGACGTGGTGCAGATCGTGAGAAACTACAACGCCTACCTGAGAGCCAGCGACGACCTGCCCAAGATGTTCATCGAGAGCGACCCCGGCTTCTTCAGCAACGCCATCGTGGAGGGCGCCAAGAAGTTCCCCAACACCGAGTTCGTGAAGGTGAAGGGCCTGCACTTCAGCCAGGAGGACGCCCCCGACGAGATGGGCAAGTACATCAAGAGCTTCGTGGAGAGAGTGCTGAAGAACGAGCAGAGATCTATCTAG", isPeptide: false, comments: "Humanised Renilla luciferase (945bp, 314aa); codon-optimised for mammalian expression. Used as internal control in dual-luciferase assays. Bioluminescent reporter.", color: CodableColor(red: 0.950, green: 0.500, blue: 0.000), showArrow: true, featureType: .reporter, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "Rluc", sequence: "ATGGCTTCGAAAGTTTATGATCCAGAACAAAGGAAACGGATGATAACTGGTCCGCAGTGGTGGGCCAGATGTAAACAAATGAATGTTCTTGATTCATTTATTAATTATTATGATTCAGAAAAACATGCAGAAAATGCTGTTATTTTTTTACATGGTAACGCGGCCTCTTCTTATTTATGGCGACATGTTGTGCCACATATTGAGCCAGTAGCGCGGTGTATTATACCAGACCTTATTGGTATGGGCAAATCAGGCAAATCTGGTAATGGTTCTTATAGGTTACTTGATCATTACAAATATCTTACTGCATGGTTTGAACTTCTTAATTTACCAAAGAAGATCATTTTTGTCGGCCATGATTGGGGTGCTTGTTTGGCATTTCATTATAGCTATGAGCATCAAGATAAGATCAAAGCAATAGTTCACGCTGAAAGTGTAGTAGATGTGATTGAATCATGGGATGAATGGCCTGATATTGAAGAAGATATTGCGTTGATCAAATCTGAAGAAGGAGAAAAAATGGTTTTGGAGAATAACTTCTTCGTGGAAACCATGTTGCCATCAAAAATCATGAGAAAGTTAGAACCAGAAGAATTTGCAGCATATCTTGAACCATTCAAAGAGAAAGGTGAAGTTCGTCGTCCAACATTATCATGGCCTCGTGAAATCCCGTTAGTAAAAGGTGGTAAACCTGACGTTGTACAAATTGTTAGGAATTATAATGCTTATCTACGTGCAAGTGATGATTTACCAAAAATGTTTATTGAATCGGACCCAGGATTCTTTTCCAATGCTATTGTTGAAGGTGCCAAGAAGTTTCCTAATACTGAATTTGTCAAAGTAAAAGGTCTTCATTTTTCGCAAGAAGATGCACCTGATGAAATGGGAAAATATATCAAATCGTTCGTTGAGCGAGTTCTCAAAAATGAACAAAGATCTATCTAG", isPeptide: false, comments: "Renilla reniformis luciferase wildtype (945bp, 314aa); bioluminescent reporter and internal control. Bioluminescent reporter.", color: CodableColor(red: 0.950, green: 0.500, blue: 0.000), showArrow: true, featureType: .reporter, scanEnabled: true, senseStrandOnly: false),
            ]),

            FeatureCollection(name: "Affinity & epitope tags", scanEnabled: true, items: [
                FeatureLibraryItem(name: "3xFLAG", sequence: "DYKDHDGDYKDHDIDYKDDDDK", isPeptide: true, comments: "Triple FLAG epitope tag (DYKDDDDK×3 with linkers, 22aa peptide). High-affinity tag for IP and western blotting. All organisms.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.600), showArrow: true, featureType: .tag, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "6xHis", sequence: "HHHHHH", isPeptide: true, comments: "Hexahistidine affinity tag (6aa peptide). Binds Ni-NTA resin for IMAC purification. Used in virtually all expression systems.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.600), showArrow: true, featureType: .tag, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "Avitag", sequence: "GLNDIFEAQKIEWHE", isPeptide: true, comments: "AviTag biotinylation peptide (15aa, GLNDIFEAQKIEWHE). Biotinylated in vivo by BirA ligase. Used for streptavidin pulldowns and SPR.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.600), showArrow: true, featureType: .tag, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "c-Myc", sequence: "EQKLISEEDL", isPeptide: true, comments: "c-Myc epitope tag (10aa, EQKLISEEDL). Widely used for immunodetection with 9E10 antibody. All organisms.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.600), showArrow: true, featureType: .tag, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "Cys", sequence: "CCPGCC", isPeptide: true, comments: "Single cysteine tag (C) for site-specific chemical conjugation, PEGylation or crosslinking.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.600), showArrow: true, featureType: .tag, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "E-tag", sequence: "GAPVPYPDPLEPR", isPeptide: true, comments: "E-tag epitope (13aa, GAPVPYPDPLEPR). Recognised by anti-E-tag antibody. Used in phage display and protein detection.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.600), showArrow: true, featureType: .tag, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "FLAG", sequence: "DYKDDDDK", isPeptide: true, comments: "FLAG epitope tag (8aa, DYKDDDDK). Widely used epitope tag; recognised by M1, M2 and M5 antibodies. All organisms.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.600), showArrow: true, featureType: .tag, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "GluGlu", sequence: "EYMPME", isPeptide: true, comments: "GluGlu epitope tag (6aa, EYMPME). Derived from human glutamate decarboxylase; used for immunoprecipitation.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.600), showArrow: true, featureType: .tag, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "HA", sequence: "YPYDVPDYA", isPeptide: true, comments: "Haemagglutinin epitope tag (9aa, YPYDVPDYA). Widely used for immunodetection and IP with 12CA5 or 3F10 antibodies.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.600), showArrow: true, featureType: .tag, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "HSV", sequence: "QPELAPEDPED", isPeptide: true, comments: "Herpes Simplex Virus epitope tag (11aa, QPELAPEDPED). Recognised by anti-HSV antibody.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.600), showArrow: true, featureType: .tag, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "PC", sequence: "EDQVDPRLIDGKEFDGRP", isPeptide: true, comments: "Protein C epitope tag (18aa). Derived from human Protein C; used for immunopurification and detection.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.600), showArrow: true, featureType: .tag, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "S-tag", sequence: "KETAAAKFERQHMDS", isPeptide: true, comments: "S-tag peptide (15aa, KETAAAKFERQHMDSS). Binds S-protein (RNase A fragment). Used for purification and detection.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.600), showArrow: true, featureType: .tag, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "SBP", sequence: "DEKTTGWRGGHVVEGLAGELEQLRARLEHHPQGQREP", isPeptide: true, comments: "Streptavidin-binding peptide (37aa). Binds streptavidin with high affinity (Kd ~2.5nM). One-step purification tag.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.600), showArrow: true, featureType: .tag, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "Strep-II", sequence: "WSHPQFEK", isPeptide: true, comments: "Strep-tag II (8aa, WSHPQFEK). Binds Strep-Tactin resin; gentle elution with desthiobiotin. Prokaryotic and eukaryotic expression.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.600), showArrow: true, featureType: .tag, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "Twin-Strep", sequence: "WSHPQFEKGGGSGGGSGGSAWSHPQFEK", isPeptide: true, comments: "Twin-Strep-tag (28aa, two Strep-II tags with GGGSx2 linker). Higher avidity than single Strep-II; recommended for pulldowns and purification.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.600), showArrow: true, featureType: .tag, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "T7", sequence: "CMASMTGGQQMG", isPeptide: true, comments: "T7 epitope tag (12aa, MASMTGGQQMG). Derived from T7 bacteriophage gene 10. Detected by T7-tag antibody. Bacteria and eukaryotes.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.600), showArrow: true, featureType: .tag, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "V5", sequence: "GKPIPNPLLGLDST", isPeptide: true, comments: "V5 epitope tag (14aa, GKPIPNPLLGLDST). Derived from paramyxovirus V5 protein. Detected by anti-V5 antibodies. All organisms.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.600), showArrow: true, featureType: .tag, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "VSV-G", sequence: "YTDIEMNRLGK", isPeptide: true, comments: "VSV-G epitope tag (11aa, YTDIEMNRLGK). Derived from vesicular stomatitis virus G-protein. Recognised by P5D4 antibody.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.600), showArrow: true, featureType: .tag, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "SV40 NLS", sequence: "PKKKRKVG", isPeptide: true, comments: "SV40 large T antigen nuclear localisation signal (8aa, PKKKRKVG). Directs proteins to the nucleus in mammalian and eukaryotic cells.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.600), showArrow: true, featureType: .tag, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "SV40 NLS (long)", sequence: "GCGGAATTAATTCCCGAGCCTCCAAAAAAGAAGAGAAAGGTCGAATTGGGTACCGCC", isPeptide: false, comments: "SV40 large T antigen nuclear localisation signal, extended DNA sequence (57bp). Includes flanking context for cloning.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.600), showArrow: true, featureType: .tag, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "MF-alpha signal", sequence: "ATGAGATTTCCTTCAATTTTTACTGCAGTTTTATTCGCAGCATCCTCCGCATTAGCTGCTCCAGTCAACACTACAACAGAAGATGAAACGGCACAAATTCCGGCTGAAGCTGTCATCGGTTACTTAGATTTAGAAGGGGATTTCGATGTTGCTGTTTTGCCATTTTCCAACAGCACAAATAACGGGTTATTGTTTATAAATACTACTATTGCCAGCATTGCTGCTAAAGAAGAAGGGGTATCTTTGGATAAAAGA", isPeptide: false, comments: "S. cerevisiae mating factor alpha prepro-sequence (255bp); directs secretion of fused proteins in yeast expression systems.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.600), showArrow: true, featureType: .tag, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "GST", sequence: "ATGTCCCCTATACTAGGTTATTGGAAAATTAAGGGCCTTGTGCAACCCACTCGACTTCTTTTGGAATATCTTGAAGAAAAATATGAAGAGCATTTGTATGAGCGCGATGAAGGTGATAAATGGCGAAACAAAAAGTTTGAATTGGGTTTGGAGTTTCCCAATCTTCCTTATTATATTGATGGTGATGTTAAATTAACACAGTCTATGGCCATCATACGTTATATAGCTGACAAGCACAACATGTTGGGTGGTTGTCCAAAAGAGCGTGCAGAGATTTCAATGCTTGAAGGAGCGGTTTTGGATATTAGATACGGTGTTTCGAGAATTGCATATAGTAAAGACTTTGAAACTCTCAAAGTTGATTTTCTTAGCAAGCTACCTGAAATGCTGAAAATGTTCGAAGATCGTTTATGTCATAAAACATATTTAAATGGTGATCATGTAACCCATCCTGACTTCATGTTGTATGACGCTCTTGATGTTGTTTTATACATGGACCCAATGTGCCTGGATGCGTTCCCAAAATTAGTTTGTTTTAAAAAACGTATTGAAGCTATCCCACAAATTGATAAGTACTTGAAATCCAGCAAGTATATAGCATGGCCTTTGCAGGGCTGGCAAGCCACGTTTGGTGGTGGCGACCATCCTCCAAAATCGGATCTGATCGAAGGTCGTGGGATCCCCGGGAATTCATCGTGA", isPeptide: false, comments: "Glutathione S-transferase from Schistosoma japonicum (699bp, 232aa); purification on glutathione resin; solubility-enhancing tag. From pGEX-3X. All organisms.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.600), showArrow: true, featureType: .tag, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "MBP", sequence: "ATGAAAATCGAAGAAGGTAAACTGGTAATCTGGATTAACGGCGATAAAGGCTATAACGGTCTCGCTGAAGTCGGTAAGAAATTCGAGAAAGATACCGGAATTAAAGTCACCGTTGAGCATCCGGATAAACTGGAAGAGAAATTCCCACAGGTTGCGGCAACTGGCGATGGCCCTGACATTATCTTCTGGGCACACGACCGCTTTGGTGGCTACGCTCAATCTGGCCTGTTGGCTGAAATCACCCCGGACAAAGCGTTCCAGGACAAGCTGTATCCGTTTACCTGGGATGCCGTACGTTACAACGGCAAGCTGATTGCTTACCCGATCGCTGTTGAAGCGTTATCGCTGATTTATAACAAAGATCTGCTGCCGAACCCGCCAAAAACCTGGGAAGAGATCCCGGCGCTGGATAAAGAACTGAAAGCGAAAGGTAAGAGCGCGCTGATGTTCAACCTGCAAGAACCGTACTTCACCTGGCCGCTGATTGCTGCTGACGGGGGTTATGCGTTCAAGTATGAAAACGGCAAGTACGACATTAAAGACGTGGGCGTGGATAACGCTGGCGCGAAAGCGGGTCTGACCTTCCTGGTTGACCTGATTAAAAACAAACACATGAATGCAGACACCGATTACTCCATCGCAGAAGCTGCCTTTAATAAAGGCGAAACAGCGATGACCATCAACGGCCCGTGGGCATGGTCCAACATCGACACCAGCAAAGTGAATTATGGTGTAACGGTACTGCCGACCTTCAAGGGTCAACCATCCAAACCGTTCGTTGGCGTGCTGAGCGCAGGTATTAACGCCGCCAGTCCGAACAAAGAGCTGGCAAAAGAGTTCCTCGAAAACTATCTGCTGACTGATGAAGGTCTGGAAGCGGTTAATAAAGACAAACCGCTGGGTGCCGTAGCGCTGAAGTCTTACGAGGAAGAGTTGGCGAAAGATCCACGTATTGCCGCCACCATGGAAAACGCCCAGAAAGGTGAAATCATGCCGAACATCCCGCAGATGTCCGCTTTCTGGTATGCCGTGCGTACTGCGGTGATCAACGCCGCCAGCGGTCGTCAGACTGTCGATGAAGCCCTGAAAGACGCGCAGACTAATTCGAGC", isPeptide: false, comments: "Maltose-binding protein from E. coli malE (1110bp, 370aa); purification on amylose resin; strong solubility-enhancing tag. From pMAL-c2. All organisms.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.600), showArrow: true, featureType: .tag, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "SUMO (Smt3)", sequence: "ATGTCGGACTCAGAAGTCAATCAAGAAGCTAAGCCAGAGGTCAAGCCAGAAGTCAAGCCTGAGACTCACATCAATTTAAAGGTGTCCGATGGATCTTCAGAGATCTTCTTCAAGATCAAAAAGACCACTCCTTTAAGAAGGCTGATGGAAGCGTTCGCTAAAAGACAGGGTAAGGAAATGGACTCCTTAAGATTCTTGTACGACGGTATTAGAATTCAAGCTGATCAGACCCCTGAAGATTTGGACATGGAGGATAACGATATTATTGAGGCTCACAGAGAACAGATTGGTGGTGCTACGTATTAG", isPeptide: false, comments: "S. cerevisiae Smt3/SUMO tag (306bp, 101aa). Enhances solubility and expression; cleaved by SUMO proteases (Ulp1). Used in pE-SUMO vectors. From SGD YDR510W.", color: CodableColor(red: 0.000, green: 0.600, blue: 0.600), showArrow: true, featureType: .tag, scanEnabled: true, senseStrandOnly: false),
            ]),

            FeatureCollection(name: "Protease cleavage sites", scanEnabled: true, items: [
                FeatureLibraryItem(name: "Enterokinase site", sequence: "DDDDK", isPeptide: true, comments: "Enterokinase (enteropeptidase) cleavage site (5aa, DDDDK). Cleaves after the lysine residue. Used to remove N-terminal fusion tags. Note: can cleave at internal DDDDK sequences.", color: CodableColor(red: 0.600, green: 0.000, blue: 0.600), showArrow: true, featureType: .misc, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "Factor Xa site", sequence: "IEGR", isPeptide: true, comments: "Factor Xa protease cleavage site (4aa, IEGR). Cleaves after arginine. Used to remove affinity tags; can show non-specific cleavage at other sites.", color: CodableColor(red: 0.600, green: 0.000, blue: 0.600), showArrow: true, featureType: .misc, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "PreScission site", sequence: "LEVLFQGP", isPeptide: true, comments: "HRV 3C (PreScission) protease cleavage site (8aa, LEVLFQGP). Cleaves between Q and G; highly specific with minimal off-target cleavage. GST-tagged PreScission protease available commercially.", color: CodableColor(red: 0.600, green: 0.000, blue: 0.600), showArrow: true, featureType: .misc, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "TEV site (G)", sequence: "ENLYFQG", isPeptide: true, comments: "TEV (Tobacco etch virus) protease cleavage site, G-variant (7aa, ENLYFQG). Cleaves between Q and G; leaves glycine on the target protein. Highly specific. N2 is asparagine.", color: CodableColor(red: 0.600, green: 0.000, blue: 0.600), showArrow: true, featureType: .misc, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "TEV site (S)", sequence: "ENLYFQS", isPeptide: true, comments: "TEV protease cleavage site, S-variant (7aa, ENLYFQS). Cleaves between Q and S; leaves serine on the target protein. Alternative to G-variant. N2 is asparagine.", color: CodableColor(red: 0.600, green: 0.000, blue: 0.600), showArrow: true, featureType: .misc, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "Thrombin site", sequence: "LVPRGS", isPeptide: true, comments: "Thrombin protease cleavage site (6aa, LVPRGS). Cleaves between R and G. Widely used but less specific than TEV — can cleave at other basic residues in the target.", color: CodableColor(red: 0.600, green: 0.000, blue: 0.600), showArrow: true, featureType: .misc, scanEnabled: true, senseStrandOnly: false),
            ]),

            FeatureCollection(name: "Linkers & polycistronic", scanEnabled: true, items: [
                FeatureLibraryItem(name: "EMCV IRES", sequence: "GGTTATTTTCCACCATATTGCCGTCTTTTGGCAATGTGAGGGCCCGGAAACCTGGCCCTGTCTTCTTGACGAGCATTCCTAGGGGTCTTTCCCCTCTCGCCAAAGGAATGCAAGGTCTGTTGAATGTCGTGAAGGAAGCAGTTCCTCTGGAAGCTTCTTGAAGACAAACAACGTCTGTAGCGACCCTTTGCAGGCAGCGGAACCCCCCACCTGGCGACAGGTGCCTCTGCGGCCAAAAGCCACGTGTATAAGATACACCTGCAAAGGCGGCACAACCCCAGTGCCACGTTGTGAGTTGGATAGTTGTGGAAAGAGTCAAATGGCTCTCCTCAAGCGTATTCAACAAGGGGCTGAAGGATGCCCAGAAGGTACCCCATTGTATGGGATCTGATCTGGGGCCTCGGTGCACATGCTTTACATGTGTTTAGTCGAGGTTAAAAAACGTCTAGGCCCCCCGAACCACGGGGACGTGGTTTTCCTTTGAAAAACACGATGATAATATG", isPeptide: false, color: CodableColor(red: 0.400, green: 0.300, blue: 0.800), showArrow: true, featureType: .regulatory, scanEnabled: true, senseStrandOnly: true),
                FeatureLibraryItem(name: "IRES", sequence: "CCGCCCCTCTCCCTCCCCCCCCCCTAACGTTACTGGCCGAAGCCGCTTGGAATAAGGCCGGTGTGCGTTTGTCTATATGTTATTTTCCACCATATTGCCGTCTTTTGGCAATGTGAGGGCCCGGAAACCTGGCCCTGTCTTCTTGACGAGCATTCCTAGGGGTCTTTCCCCTCTCGCCAAAGGAATGCAAGGTCTGTTGAATGTCGTGAAGGAAGCAGTTCCTCTGGAAGCTTCTTGAAGACAAACAACGTCTGTAGCGACCCTTTGCAGGCAGCGGAACCCCCCACCTGGCGACAGGTGCCTCTGCGGCCAAAAGCCACGTGTATAAGATACACCTGCAAAGGCGGCACAACCCCAGTGCCACGTTGTGAGTTGGATAGTTGTGGAAAGAGTCAAATGGCTCTCCTCAAGCGTATTCAACAAGGGGCTGAAGGATGCCCAGAAGGTACCCCATTGTATGGGATCTGATCTGGGGCCTCGGTGCACATGCTTTACATGTGTTTAGTCGAGGTTAAAAAAACGTCTAGGCCCCCCGAACCACGGGGACGTGGTTTTCCTTTGAAAAACACGATGATAATATGGCC", isPeptide: false, color: CodableColor(red: 0.400, green: 0.300, blue: 0.800), showArrow: true, featureType: .regulatory, scanEnabled: true, senseStrandOnly: false),  // DUPLICATE? review
                FeatureLibraryItem(name: "IRES", sequence: "GCGGGACTCTGGGGTTCGGTTAAACGAATTCCGCCCCTCTCCCTCCCCCCCCCCTAACGTTACTGGCCGAAGCCGCTTGGAATAAGGCCGGTGTGCGTTTGTCTATATGTTATTTTCCACCATATTGCCGTCTTTTGGCAATGTGAGGGCCCGGAAACCTGGCCCTGTCTTCTTGACGAGCATTCCTAGGGGTCTTTCCCCTCTCGCCAAAGGAATGCAAGGTCTGTTGAATGTCGTGAAGGAAGCAGTTCCTCTGGAAGCTTCTTGAAGACAAACAACGTCTGTAGCGACCCTTTGCAGGCAGCGGAACCCCCCACCTGGCGACAGGTGCCTCTGCGGCCAAAAGCCACGTGTATAAGATACACCTGCAAAGGCGGCACAACCCCAGTGCCACGTTGTGAGTTGGATAGTTGTGGAAAGAGTCAAATGGCTCTCCTCAAGCGTATTCAACAAGGGGCTGAAGGATGCCCAGAAGGTACCCCATTGTATGGGATCTGATCTGGGGCCTCGGTGCACATGCTTTACGTGTGTTTAGTCGAGGTTAAAAAACGTCTAGGCCCCCCGAACCACGGGGACGTGGTTTTCCTTTGAAAAACACGATGATAATATGGCCACAAC", isPeptide: false, color: CodableColor(red: 0.400, green: 0.300, blue: 0.800), showArrow: true, featureType: .regulatory, scanEnabled: true, senseStrandOnly: false),  // DUPLICATE? review
                FeatureLibraryItem(name: "P2A", sequence: "GCAACAAACTTCTCTCTGCTGAAACAAGCCGGAGATGTCGAAGAGAATCCTGGACCG", isPeptide: false, color: CodableColor(red: 0.400, green: 0.300, blue: 0.800), showArrow: true, featureType: .cds, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "T2A", sequence: "GAGGGCAGAGGAAGTCTGCTAACATGCGGTGACGTTGAGGAGAATCCTGGACCT", isPeptide: false, color: CodableColor(red: 0.400, green: 0.300, blue: 0.800), showArrow: true, featureType: .cds, scanEnabled: true, senseStrandOnly: false),
            ]),
            FeatureCollection(name: "Regulatory & recombination", scanEnabled: true, items: [
                FeatureLibraryItem(name: "attB1", sequence: "ACAAGTTTGTACAAAAAAGCAGGCT", isPeptide: false, color: CodableColor(red: 0.800, green: 0.400, blue: 0.600), showArrow: true, featureType: .loxP, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "attB2", sequence: "ACCACTTTGTACAAGAAAGCTGGGT", isPeptide: false, color: CodableColor(red: 0.800, green: 0.400, blue: 0.600), showArrow: true, featureType: .loxP, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "attP1", sequence: "ACAAGTTTGTACAAAAAAGCTGAAC", isPeptide: false, color: CodableColor(red: 0.800, green: 0.400, blue: 0.600), showArrow: true, featureType: .loxP, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "attP2", sequence: "ACCACTTTGTACAAGAAAGTTGAAC", isPeptide: false, color: CodableColor(red: 0.800, green: 0.400, blue: 0.600), showArrow: true, featureType: .loxP, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "delta U3", sequence: "TGGAAGGGCTAATTCACTCCCAACGAAGACAAGATCTGCTTTTTGCTTGTACT", isPeptide: false, color: CodableColor(red: 0.600, green: 0.000, blue: 0.600), showArrow: true, featureType: .misc, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "FRT", sequence: "GAAGTTCCTATTCTCTAGAAAGTATAGGAACTTC", isPeptide: false, color: CodableColor(red: 0.800, green: 0.400, blue: 0.600), showArrow: true, featureType: .loxP, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "HIV-1 5 LTR", sequence: "GGGTCTCTCTGGTTAGACCAGATCTGAGCCTGGGAGCTCTCTGGCTAACTAGGGAACCCACTGCTTAAGCCTCAATAAAGCTTGCCTTGAGTGCTTCAAGTAGTGTGTGCCCGTCTGTTGTGTGACTCTGGTAACTAGAGATCCCTCAGACCCTTTTAGTCAGTGTGGAAAATCTCTAGCA", isPeptide: false, color: CodableColor(red: 1.000, green: 0.647, blue: 0.000), showArrow: true, featureType: .promoter, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "HIV-1 psi pack", sequence: "TGAGTACGCCAAAAATTTTGACTAGCGGAGGCTAGAAGGAGAGAG", isPeptide: false, color: CodableColor(red: 0.600, green: 0.000, blue: 0.600), showArrow: true, featureType: .misc, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "Kozak sequence", sequence: "GCCGCCACCATGG", isPeptide: false, color: CodableColor(red: 0.400, green: 0.300, blue: 0.800), showArrow: true, featureType: .regulatory, scanEnabled: true, senseStrandOnly: true),
                FeatureLibraryItem(name: "lacI", sequence: "GTGGTGAATGTGAAACCAGTAACGTTATACGATGTCGCAGAGTATGCCGGTGTCTCTTATCAGACCGTTTCCCGCGTGGTGAACCAGGCCAGCCACGTTTCTGCGAAAACGCGGGAAAAAGTGGAAGCGGCGATGGCGGAGCTGAATTACATTCCCAACCGCGTGGCACAACAACTGGCGGGCAAACAGTCGTTGCTGATTGGCGTTGCCACCTCCAGTCTGGCCCTGCACGCGCCGTCGCAAATTGTCGCGGCGATTAAATCTCGCGCCGATCAACTGGGTGCCAGCGTGGTGGTGTCGATGGTAGAACGAAGCGGCGTCGAAGCCTGTAAAGCGGCGGTGCACAATCTTCTCGCGCAACGCGTCAGTGGGCTGATCATTAACTATCCGCTGGATGACCAGGATGCCATTGCTGTGGAAGCTGCCTGCACTAATGTTCCGGCGTTATTTCTTGATGTCTCTGACCAGACACCCATCAACAGTATTATTTTCTCCCATGAAGACGGTACGCGACTGGGCGTGGAGCATCTGGTCGCATTGGGTCACCAGCAAATCGCGCTGTTAGCGGGCCCATTAAGTTCTGTCTCGGCGCGTCTGCGTCTGGCTGGCTGGCATAAATATCTCACTCGCAATCAAATTCAGCCGATAGCGGAACGGGAAGGCGACTGGAGTGCCATGTCCGGTTTTCAACAAACCATGCAAATGCTGAATGAGGGCATCGTTCCCACTGCGATGCTGGTTGCCAACGATCAGATGGCGCTGGGCGCAATGCGCGCCATTACCGAGTCCGGGCTGCGCGTTGGTGCGGATATCTCGGTAGTGGGATACGACGATACCGAAGACAGCTCATGTTATATCCCGCCGTTAACCACCATCAAACAGGATTTTCGCCTGCTGGGGCAAACCAGCGTGGACCGCTTGCTGCAACTCTCTCAGGGCCAGGCGGTGAAGGGCAATCAGCTGTTGCCCGTCTCACTGGTGAAAAGAAAAACCACCCTGGCGCCCAATACGCAAACCGCCTCTCCCCGCGCGTTGGCCGATTCATTAATGCAGCTGGCACGACAGGTTTCCCGACTGGAAAGCGGGCAGTGA", isPeptide: false, color: CodableColor(red: 0.200, green: 0.400, blue: 0.800), showArrow: true, featureType: .cds, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "LacO", sequence: "GGAATTGTGAGCGGATAACAATT", isPeptide: false, color: CodableColor(red: 0.200, green: 0.400, blue: 0.800), showArrow: true, featureType: .regulatory, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "lox2272", sequence: "ATAACTTCGTATAAAGTATCCTATACGAAGTTAT", isPeptide: false, color: CodableColor(red: 0.800, green: 0.400, blue: 0.600), showArrow: true, featureType: .loxP, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "LoxP", sequence: "ATAACTTCGTATAGCATACATTATACGAAGTTAT", isPeptide: false, color: CodableColor(red: 0.800, green: 0.400, blue: 0.600), showArrow: true, featureType: .loxP, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "RRE", sequence: "AGGAGCTTTGTTCCTTGGGTTCTTGGGAGCAGCAGGAAGCACTATGGGCGCAGCGTCAATGACGCTGACGGTACAGGCCAGACAATTATTGTCTGGTATAGTGCAGCAGCAGAACAATTTGCTGAGGGCTATTGAGGCGCAACAGCATCTGTTGCAACTCACAGTCTGGGGCATCAAGCAGCTCCAGGCAAGAATCCTGGCTGTGGAAAGATACCTAAAGGATCAACAGCTCCT", isPeptide: false, color: CodableColor(red: 0.400, green: 0.300, blue: 0.800), showArrow: true, featureType: .regulatory, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "SV40 int", sequence: "GGTAAATATAAAATTT", isPeptide: false, color: CodableColor(red: 0.275, green: 0.510, blue: 0.706), showArrow: true, featureType: .intron, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "synth int", sequence: "GAATTAATTCGCTGTCTGCGAGGGCCAGCTGTTGGGGTGAGTACTCCCTCTCAAAAGCGGGCATGACTTCTGCGCTAAGATTGTCAGTTTCCAAAAACGAGGAGGATTTGATATTCACCTGGCCCGCGGTGATGCCTTTGAGGGTGGCCGCGTCCATCTGGTCAGAAAAGACAATCTTTTTGTTGTCAAGCTTGAGGTGTGGCAGGCTTGAGATCTGGCCATACACTTGAGTGACAATGACATCCACTTTGCCTTTCTCTCCACAGGTGTCCACTCCCAGGTCCAACTGCAGGTCG", isPeptide: false, color: CodableColor(red: 0.275, green: 0.510, blue: 0.706), showArrow: true, featureType: .intron, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "T7 RBS", sequence: "AAGGAGATATACATATG", isPeptide: false, color: CodableColor(red: 0.400, green: 0.300, blue: 0.800), showArrow: true, featureType: .regulatory, scanEnabled: true, senseStrandOnly: true),
                FeatureLibraryItem(name: "TN5 from pRL27", sequence: "ATGATAACTTCTGCTCTTCATCGTGCGGCCGACTGGGCTAAATCTGTGTTCTCTTCGGCGGCGCTGGGTGATCCTCGCCGTACTGCCCGCTTGGTTAACGTCGCCGCCCAATTGGCAAAATATTCTGGTAAATCAATAACCATCTCATCAGAGGGTAGTAAAGCCGCCCAGGAAGGCGCTTACCGATTTATCCGCAATCCCAACGTTTCTGCCGAGGCGATCAGAAAGGCTGGCGCCATGCAAACAGTCAAGTTGGCTCAGGAGTTTCCCGAACTGCTGGCCATTGAGGACACCACCTCTTTGAGTTATCGCCACCAGGTCGCCGAAGAGCTTGGCAAGCTGGGCTCTATTCAGGATAAATCCCGCGGATGGTGGGTTCACTCCGTTCTCTTGCTCGAGGCCACCACATTCCGCACCGTAGGATTACTGCATCAGGAGTGGTGGATGCGCCCGGATGACCCTGCCGATGCGGATGAAAAGGAGAGTGGCAAATGGCTGGCAGCGGCCGCAACTAGCCGGTTACGCATGGGCAGCATGATGAGCAACGTGATTGCGGTCTGTGACCGCGAAGCCGATATTCATGCTTATCTGCAGGACAAACTGGCGCATAACGAGCGCTTCGTGGTGCGCTCCAAGCACCCACGCAAGGACGTAGAGTCTGGGTTGTATCTGTACGACCATCTGAAGAACCAACCGGAGTTGGGTGGCTATCAGATCAGCATTCCGCAAAAGGGCGTGGTGGATAAACGCGGTAAACGTAAAAATCGACCAGCCCGCAAGGCGAGCTTGAGCCTGCGCAGTGGGCGCATCACGCTAAAACAGGGGAATATCACGCTCAACGCGGTGCTGGCCGAGGAGATTAACCCGCCCAAGGGTGAGACCCCGTTGAAATGGTTGTTGCTGACCAGCGAACCGGTCGAGTCGCTAGCCCAAGCCTTGCGCGTCATCGACATTTATACCCATCGCTGGCGGATCGAGGAGTTCCATAAGGCATGGAAAACCGGAGCAGGAGCCGAGAGGCAACGCATGGAGGAGCCGGATAATCTGGAGCGGATGGTCTCGATCCTCTCGTTTGTTGCGGTCAGGCTGTTACAGCTCAGAGAAAGCTTCACGCCGCCGCAAGCACTCAGGGCGCAAGGGCTGCTAAAGGAAGCGGAACACGTAGAAAGCCAGTCCGCAGAAACGGTGCTGACCCCGGATGAATGTCAGCTACTGGGCTATCTGGACAAGGGAAAACGCAAGCGCAAAGAGAAAGCAGGTAGCTTGCAGTGGGCTTACATGGCGATAGCTAGACTGGGCGGTTTTATGGACAGCAAGCGAACCGGAATTGCCAGCTGGGGCGCCCTCTGGGAAGGTTGGGAAGCCCTGCAAAGTAAACTGGATGGCTTTCTTGCCGCCAAGGATCTGATGGCGCAGGGGATCAAGATCTGA", isPeptide: false, color: CodableColor(red: 0.200, green: 0.400, blue: 0.800), showArrow: true, featureType: .cds, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "Tn5 inside inverted repeat", sequence: "CTGTCTCTTGATCAGATCT", isPeptide: false, color: CodableColor(red: 0.600, green: 0.000, blue: 0.600), showArrow: true, featureType: .misc, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "Tn5 outside inverted repeat", sequence: "ACTTGTGTATAAGAGTCA", isPeptide: false, color: CodableColor(red: 0.600, green: 0.000, blue: 0.600), showArrow: true, featureType: .misc, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "TRE", sequence: "TTTCGTCTTCACTTGAGTTTACTCCCTATCAGTGATAGAGAACGTATGTCGAGTTTACTCCCTATCAGTGATAGAGAACGATGTCGAGTTTACTCCCTATCAGTGATAGAGAACGTATGTCGAGTTTACTCCCTATCAGTGATAGAGAACGTATGTCGAGTTTACTCCCTATCAGTGATAGAGAACGTATGTCGAGTTTATCCCTATCAGTGATAGAGAACGTATGT", isPeptide: false, color: CodableColor(red: 0.400, green: 0.300, blue: 0.800), showArrow: true, featureType: .regulatory, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "LB", sequence: "TGGCAGGATATATTGTGGTGTAAACA", isPeptide: false, comments: "Agrobacterium tumefaciens T-DNA left border repeat (25bp imperfect repeat); defines the boundary recombined into the plant genome during T-DNA transfer. Sequence extracted from a Cambia binary vector — other binary vector families (e.g. octopine-type) may carry a different border sequence.", color: CodableColor(red: 0.600, green: 0.000, blue: 0.600), showArrow: false, featureType: .misc, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "RB", sequence: "GTAAACCTAAGAGAAAAGAGCGTTTA", isPeptide: false, comments: "Agrobacterium tumefaciens T-DNA right border repeat (25bp imperfect repeat); recognised by VirD2 to initiate T-DNA transfer into the plant genome. Sequence extracted from a Cambia binary vector — other binary vector families (e.g. octopine-type) may carry a different border sequence.", color: CodableColor(red: 0.600, green: 0.000, blue: 0.600), showArrow: false, featureType: .misc, scanEnabled: true, senseStrandOnly: false),
            ]),
            FeatureCollection(name: "Two-hybrid / protein interaction", scanEnabled: true, items: [
                FeatureLibraryItem(name: "GAL4 DBD", sequence: "ATGAAGCTACTGTCTTCTATCGAACAAGCATGCGATATTTGCCGACTTAAAAAGCTCAAGTGCTCCAAAGAAAAACCGAAGTGCGCCAAGTGTCTGAAGAACAACTGGGAGTGTCGCTACTCTCCCAAAACCAAAAGGTCTCCGCTGACTAGGGCACATCTGACAGAAGTGGAATCAAGGCTAGAAAGACTGGAACAGCTATTTCTACTGATTTTTCCTCGAGAAGACCTTGACATGATTTTGAAAATGGATTCTTTACAGGATATAAAAGCATTGTTAACAGGATTATTTGTACAAGATAATGTGAATAAAGATGCCGTCACAGATAGATTGGCTTCAGTGGAGACTGATATGCCTCTAACATTGAGACAGCATAGAATAAGTGCGACATCATCATCGGAAGAGAGTAGTAACAAAGGTCAAAGACAGTTGACTGTATCG", isPeptide: false, comments: "GAL4 DNA-binding domain (441bp, aa 1-147). Binds GAL4 UAS upstream of reporter genes. Used as bait fusion in GAL4-based two-hybrid systems (pGBT9, pGBKT7 vectors). No stop codon — cloned as N-terminal fusion. Yeast two-hybrid.", color: CodableColor(red: 0.950, green: 0.750, blue: 0.050), showArrow: true, featureType: .cds, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "GAL4 AD", sequence: "ATGGATGATGTATATAACTATCTATTCGATGATGAAGATACCCCACCAAACCCAAAAAAAGAGATCGAATTCCCGGGGATCCGTCGACCTGCAGAGATCTATGAATCG", isPeptide: false, comments: "GAL4 activation domain (108bp, aa 768-803). Activates transcription when brought to a promoter by protein-protein interaction. Used as prey fusion in GAL4-based two-hybrid systems (pGAD424, pGADT7 vectors). No stop codon — cloned as N-terminal fusion. From pGAD424 (U07647). Yeast two-hybrid.", color: CodableColor(red: 0.950, green: 0.750, blue: 0.050), showArrow: true, featureType: .cds, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "VP16 AD", sequence: "GCCCCCCCGACCGATGTCAGCCTGGGGGACGAGCTCCACTTAGACGGCGAGGACGTGGCGATGGCGCATGCCGACGCGCTAGACGATTTCGATCTGGACATGTTGGGGGACGGGGATTCCCCGGGTCCGGGATTTACCCCCCACGACTCCGCCCCCTACGGCGCTCTGGATATGGCCGACTTCGAGTTTGAGCAGATGTTTACCGATGCCCTTGGAATTGACGAGTACGGTGGG", isPeptide: false, comments: "VP16 activation domain from Herpes Simplex Virus (234bp, ~78aa). Strong transcriptional activator used as AD fusion in some two-hybrid variants. No stop codon — cloned as N-terminal fusion. Yeast two-hybrid.", color: CodableColor(red: 0.950, green: 0.750, blue: 0.050), showArrow: true, featureType: .cds, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "LexA", sequence: "ATGAAAGCGTTAACGGCCAGGCAACAAGAGGTGTTTGATCTCATCCGTGATCACATCAGCCAGACAGGTATGCCGCCGACGCGTGCGGAAATCGCGCAGCGTTTGGGGTTCCGTTCCCCAAACGCGGCTGAAGAACATCTGAAGGCGCTGGCACGCAAAGGCGTTATTGAAATTGTTTCCGGCGCATCACGCGGGATCCGTCTGTTGCAGGAAGAGGAAGAAGGGTTGCCGCTGGTAGGTCGTGTGGCTGCCGGTGAACCACTTCTGGCGCAACAGCATATTGAAGGTCATTATCAGGTCGACCCTTCCTTATTCAAGCCGAATGCTGATTTCCTGCTGCGCGTCAGCGGGATGTCGATGAAAGATATCGGCATTATGGATGGTGACTTGCTGGCAGTGCATAAAACTCAGGATGTACGTAACGGTCAGGTCGTTGTCGCACGTATTGATGACGAAGTTACCGTTAAGGGCCTGAAAAAACAGGGCAATAAAGTCGAACTGTTGCCAGAAAATAGCGAGTTTAAACCAATTGTCGTAGATCTTCGTCAGCAGAGCTTCACCATTGAAGGGCTGGCGGTTGGGGTTATTCGCAACGGCGACTGGCTG", isPeptide: false, comments: "LexA DNA-binding domain from E. coli (606bp). Binds LexA operators upstream of reporter genes. Used as bait fusion in LexA-based two-hybrid systems (pGilda, pEG202 vectors). No stop codon. Yeast two-hybrid.", color: CodableColor(red: 0.950, green: 0.750, blue: 0.050), showArrow: true, featureType: .cds, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "LexA DBD", sequence: "ATGAAAGCGTTAACGGCCAGGCAACAAGAGGTGTTTGATCTCATCCGTGATCACATCAGCCAGACAGGTATGCCGCCGACGCGTGCGGAAATCGCGCAGCGTTTGGGGTTCCGTTCCCCAAACGCGGCTGAAGAACATCTGAAGGCGCTGGCACGCAAAGGCGTTATTGAAATTGTTTCCGGCGCATCACGCGGGATTCGTCTGTTGCAGGAAGAGGAAGAAGGGTTGCCGCTGGTAGGTCGTGTGGCTGCCGGTGAACCRCTTCTGGCGCAACAGCATATTGAAGGTCATTATCAGGTCGATCCTTCCTTRTTCAAGCCGAATGCTGATTTCCTGCTGCGCGTCAGCGGGATGTCGATGAAAGATATCGGCATTATGGATGGYGACTTGCTGGCAGTGCATAAAACTCAGGATGTACGTAACGGTCAGGTCGTTGTCGCACGTATTGATGACGARGTTACCGTTAAGCGCCTGAAAAAACAGGGCAATAAAGTCGAACTGTTGCCAGAAAATAGCGAGTTTAAACCAATTGTCGTWGAYCTTCGTCAGCAGAGCTTCACCATTGAAGGGCTGGCGGTTGGGGTTATTCGCAACGGCGACTGGCTG", isPeptide: false, comments: "LexA DNA-binding domain, alternative sequence (606bp). Slightly different from LexA entry — verify against your specific vector. Used in LexA-based two-hybrid systems. No stop codon. Yeast two-hybrid.", color: CodableColor(red: 0.950, green: 0.750, blue: 0.050), showArrow: true, featureType: .cds, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "CUB domain", sequence: "GGGATCCCTCCAGATCAACAAAGATTGATCTTTGCCGGTAAGCAGCTAGAAGACGGTAGAACGCTGTCTGATTACAACATTCAGAAGGAGTCCACCTTACATCTTGTGCTAAGGCTAAGAGGTGGT", isPeptide: false, comments: "CUB domain fragment from split-ubiquitin MYTH system (126bp). C-terminal half of ubiquitin used as bait fusion in membrane yeast two-hybrid (MYTH). No ATG — cloned as C-terminal fusion to membrane bait protein. Membrane Y2H.", color: CodableColor(red: 0.950, green: 0.750, blue: 0.050), showArrow: true, featureType: .cds, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "NUB-G", sequence: "ATGCAGATTTTCGTCAAGACTTTGACCGGTAAAACCGGAACATTGGAAGTTGAATCTTCCGATACCATCGACAACGTTAAGTCGAAAATTCAAGACAAGGAAGGAATCCCT", isPeptide: false, comments: "NUB-G: N-terminal ubiquitin fragment with I13G mutation (111bp, 37aa). Weak affinity for CUB — only reconstitutes ubiquitin and signals interaction when brought together by protein-protein interaction. Prey fusion in MYTH system. Membrane Y2H.", color: CodableColor(red: 0.950, green: 0.750, blue: 0.050), showArrow: true, featureType: .cds, scanEnabled: true, senseStrandOnly: false),
            ]),

            FeatureCollection(name: "Primer binding sites", scanEnabled: true, items: [
                FeatureLibraryItem(name: "M13-fwd", sequence: "TGTAAAACGACGGCCAGT", isPeptide: false, color: CodableColor(red: 0.950, green: 0.500, blue: 0.000), showArrow: true, featureType: .primerBinding, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "M13-rev", sequence: "CAGGAAACAGCTATGACCATG", isPeptide: false, color: CodableColor(red: 0.950, green: 0.500, blue: 0.000), showArrow: true, featureType: .primerBinding, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "SP6", sequence: "ATTTAGGTGACACTATAG", isPeptide: false, color: CodableColor(red: 0.950, green: 0.500, blue: 0.000), showArrow: true, featureType: .primerBinding, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "T3", sequence: "ATTAACCCTCACTAAAGGGA", isPeptide: false, color: CodableColor(red: 0.950, green: 0.500, blue: 0.000), showArrow: true, featureType: .primerBinding, scanEnabled: true, senseStrandOnly: false),
                FeatureLibraryItem(name: "T7", sequence: "TAATACGACTCACTATAGGG", isPeptide: false, color: CodableColor(red: 0.950, green: 0.500, blue: 0.000), showArrow: true, featureType: .primerBinding, scanEnabled: true, senseStrandOnly: false),
            ]),
        ]
        saveCollections()
    }
}

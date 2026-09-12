import Foundation
import Combine

// MARK: - Shuttle Vector Library

struct ShuttleVector: Identifiable, Codable {
    let id: UUID
    let name: String
    let fullName: String
    let category: VectorCategory
    let size: Int
    let mcsSites: [String]
    let selectionMarker: String
    let notes: String
    let isBuiltIn: Bool         // true = shipped with app, false = user-added/imported
    /// Reading frame offset introduced at the N-terminal fusion junction.
    /// nil  = not an N-terminal fusion vector (or unknown)
    /// 0    = insert ORF ATG must be in frame 0 (e.g. pET-28a — NdeI ATG direct)
    /// 1    = insert ORF ATG must be in frame 1 (e.g. pET-28b)
    /// 2    = insert ORF ATG must be in frame 2 (e.g. pET-28c)
    /// Used by the alternative-vector suggestion engine in Predictive Cloning.
    let fusionFrameOffset: Int?
    
    init(id: UUID = UUID(), name: String, fullName: String = "", category: VectorCategory,
         size: Int, mcsSites: [String], selectionMarker: String, notes: String = "",
         isBuiltIn: Bool = false, fusionFrameOffset: Int? = nil) {
        self.id = id
        self.name = name
        self.fullName = fullName.isEmpty ? name : fullName
        self.category = category
        self.size = size
        self.mcsSites = mcsSites
        self.selectionMarker = selectionMarker
        self.notes = notes
        self.isBuiltIn = isBuiltIn
        self.fusionFrameOffset = fusionFrameOffset
    }
    
    var mcsEnzymeSet: Set<String> { Set(mcsSites) }
    var mcsSummary: String { mcsSites.joined(separator: " – ") }
}

enum VectorCategory: String, Codable, CaseIterable {
    case generalCloning = "General Cloning"
    case ecoliExpression = "E. coli Expression"
    case mammalianExpression = "Mammalian Expression"
    case yeastExpression = "Yeast Expression"
    case insectExpression = "Insect Expression"
    case shuttle = "Shuttle Vector"
    case bac = "BAC / Cosmid"
    case phage = "Phage"
    case custom = "Custom"
}


// MARK: - Import Result

struct VectorImportResult {
    let name: String
    let size: Int
    let isCircular: Bool
    let features: [Feature]
    let selectionMarker: String
    let notes: String
    let mcsSites: [String]
    let allSingleCutters: [String]
    let mcsDetected: Bool
    let mcsRange: String
}


// MARK: - Library Manager

class ShuttleVectorLibrary: ObservableObject {
    static let shared = ShuttleVectorLibrary()
    
    private static let userVectorsKey  = "ShuttleVectorLibrary.userVectors"
    private static let myVectorsKey    = "ShuttleVectorLibrary.myVectors"
    
    @Published var vectors: [ShuttleVector] = []
    /// IDs of vectors the user has earmarked as "My Vectors"
    @Published var myVectorIDs: Set<UUID> = []
    
    init() {
        vectors = rebuildVectors().sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        loadMyVectors()
    }
    
    // MARK: My Vectors
    
    func isMyVector(_ id: UUID) -> Bool { myVectorIDs.contains(id) }
    
    func toggleMyVector(_ id: UUID) {
        if myVectorIDs.contains(id) { myVectorIDs.remove(id) }
        else { myVectorIDs.insert(id) }
        saveMyVectors()
    }
    
    /// Convenience: all vectors currently earmarked by the user
    var myVectors: [ShuttleVector] { vectors.filter { myVectorIDs.contains($0.id) } }
    
    private func saveMyVectors() {
        let uuidStrings = myVectorIDs.map { $0.uuidString }
        UserDefaults.standard.set(uuidStrings, forKey: Self.myVectorsKey)
    }
    
    private func loadMyVectors() {
        let uuidStrings = UserDefaults.standard.stringArray(forKey: Self.myVectorsKey) ?? []
        myVectorIDs = Set(uuidStrings.compactMap { UUID(uuidString: $0) })
    }
    
    // =========================================================================
    // MARK: Add / Remove / Update
    // =========================================================================
    
    func addVector(_ vector: ShuttleVector) {
        // Ensure user-added vectors have isBuiltIn = false
        let userVector = ShuttleVector(
            id: vector.id, name: vector.name, fullName: vector.fullName,
            category: vector.category, size: vector.size, mcsSites: vector.mcsSites,
            selectionMarker: vector.selectionMarker, notes: vector.notes,
            isBuiltIn: false
        )
        vectors.append(userVector)
        vectors.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        saveUserVectors()
    }
    
    func removeVector(id: UUID) {
        vectors.removeAll { $0.id == id }
        if myVectorIDs.remove(id) != nil { saveMyVectors() }
        saveUserVectors()
    }
    
    func updateVector(_ updated: ShuttleVector, originalID: UUID) {
        if let idx = vectors.firstIndex(where: { $0.id == originalID }) {
            // Preserve built-in status of the original
            let wasBuiltIn = vectors[idx].isBuiltIn
            vectors[idx] = ShuttleVector(
                id: originalID, name: updated.name, fullName: updated.fullName,
                category: updated.category, size: updated.size, mcsSites: updated.mcsSites,
                selectionMarker: updated.selectionMarker, notes: updated.notes,
                isBuiltIn: wasBuiltIn
            )
            vectors.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            // If a built-in was edited, save the edited version as a user override
            saveUserVectors()
        }
    }
    
    // =========================================================================
    // MARK: Queries
    // =========================================================================
    
    func vectorsWithSite(_ enzymeName: String) -> [ShuttleVector] {
        vectors.filter { $0.mcsEnzymeSet.contains(enzymeName) }
    }
    
    func vectorsWithPair(_ enzyme5: String, _ enzyme3: String) -> [ShuttleVector] {
        vectors.filter { $0.mcsEnzymeSet.contains(enzyme5) && $0.mcsEnzymeSet.contains(enzyme3) }
    }
    
    // =========================================================================
    // MARK: Persistence
    // =========================================================================
    
    private func saveUserVectors() {
        // Save all non-built-in vectors, plus any built-in vectors that were edited
        // (we detect edits by checking if the current data differs from the original built-in)
        let builtInMap = Dictionary(uniqueKeysWithValues: Self.builtInVectors().map { ($0.id, $0) })
        
        var toSave: [ShuttleVector] = []
        for vector in vectors {
            if !vector.isBuiltIn {
                // User-added — always save
                toSave.append(vector)
            } else if let original = builtInMap[vector.id],
                      original.name != vector.name || original.mcsSites != vector.mcsSites ||
                      original.selectionMarker != vector.selectionMarker || original.notes != vector.notes ||
                      original.size != vector.size || original.category != vector.category {
                // Built-in was edited — save the override
                toSave.append(vector)
            }
        }
        
        // Also track deleted built-in IDs
        let currentIDs = Set(vectors.map { $0.id })
        let deletedBuiltInIDs = Set(Self.builtInVectors().map { $0.id }).subtracting(currentIDs)
        
        do {
            let data = try JSONEncoder().encode(toSave)
            UserDefaults.standard.set(data, forKey: Self.userVectorsKey)
            
            let deletedData = try JSONEncoder().encode(Array(deletedBuiltInIDs))
            UserDefaults.standard.set(deletedData, forKey: Self.userVectorsKey + ".deleted")
        } catch {
            #if DEBUG
            print("Failed to save user vectors: \(error)")
            #endif
        }
    }
    
    private func loadUserVectors() -> [ShuttleVector] {
        guard let data = UserDefaults.standard.data(forKey: Self.userVectorsKey) else { return [] }
        do {
            return try JSONDecoder().decode([ShuttleVector].self, from: data)
        } catch {
            #if DEBUG
            print("Failed to load user vectors: \(error)")
            #endif
            return []
        }
    }
    
    /// IDs of built-in vectors the user has deleted
    private func loadDeletedBuiltInIDs() -> Set<UUID> {
        guard let data = UserDefaults.standard.data(forKey: Self.userVectorsKey + ".deleted") else { return [] }
        do {
            return Set(try JSONDecoder().decode([UUID].self, from: data))
        } catch { return [] }
    }
    
    // Rebuild from scratch, respecting user additions, edits, and deletions
    private func rebuildVectors() -> [ShuttleVector] {
        let userVectors = loadUserVectors()
        let deletedIDs = loadDeletedBuiltInIDs()
        let userOverrideIDs = Set(userVectors.filter { $0.isBuiltIn }.map { $0.id })
        
        var all: [ShuttleVector] = []
        
        // Add built-in vectors (unless deleted or overridden by user edit)
        for v in Self.builtInVectors() {
            if deletedIDs.contains(v.id) { continue }
            if userOverrideIDs.contains(v.id) { continue }
            all.append(v)
        }
        
        // Add all user vectors (including overrides of built-ins)
        all.append(contentsOf: userVectors)
        
        return all
    }
    
    
    // =========================================================================
    // MARK: Import from sequence file
    // =========================================================================
    
    static func importFromSequence(_ seq: DNASequence) -> VectorImportResult {
        let enzymeDB = RestrictionEnzymeDatabase.shared
        
        var sitesByEnzyme: [String: [CutSite]] = [:]
        for enzyme in enzymeDB.enzymes {
            let sites = enzyme.findCutSites(in: seq.sequence, circular: seq.isCircular)
            if !sites.isEmpty { sitesByEnzyme[enzyme.name] = sites }
        }
        
        let singleCutters = sitesByEnzyme
            .filter { $0.value.count == 1 }
            .map { (name: $0.key, position: $0.value.first!.position) }
            .sorted { $0.position < $1.position }
        
        let allSingleCutterNames = singleCutters.map { $0.name }
        
        let mcsKeywords = ["mcs", "multiple cloning site", "polylinker", "cloning site"]
        let mcsFeature = seq.features.first { feature in
            mcsKeywords.contains(where: { feature.name.lowercased().contains($0) })
        }
        
        let mcsSites: [String]
        let mcsDetected: Bool
        let mcsRange: String
        
        if let mcs = mcsFeature {
            let mcsStart = min(mcs.start, mcs.end)
            let mcsEnd = max(mcs.start, mcs.end)
            mcsSites = singleCutters
                .filter { $0.position >= mcsStart && $0.position <= mcsEnd }
                .map { $0.name }
            mcsDetected = true
            mcsRange = "\(mcsStart + 1)–\(mcsEnd + 1)"
        } else {
            mcsSites = allSingleCutterNames
            mcsDetected = false
            mcsRange = ""
        }
        
        let markerKeywords = ["resistance", "marker", "ampr", "kanr", "cmr", "tetr",
                              "neor", "blar", "genr", "hygr", "zeor", "purr",
                              "ampicillin", "kanamycin", "chloramphenicol", "tetracycline",
                              "neomycin", "blasticidin", "gentamicin", "hygromycin",
                              "zeocin", "puromycin", "g418", "streptomycin", "bla", "aph", "cat", "npt"]
        var markers: [String] = []
        for feature in seq.features {
            let lowerName = feature.name.lowercased()
            if markerKeywords.contains(where: { lowerName.contains($0) }) { markers.append(feature.name) }
        }
        
        let noteKeywords = ["promoter", "origin", "ori", "tag", "his", "gst",
                            "mbp", "flag", "gfp", "rfp", "lacz"]
        var noteItems: [String] = []
        for feature in seq.features {
            let lowerName = feature.name.lowercased()
            if noteKeywords.contains(where: { lowerName.contains($0) }) { noteItems.append(feature.name) }
        }
        
        return VectorImportResult(
            name: seq.name, size: seq.length, isCircular: seq.isCircular,
            features: seq.features,
            selectionMarker: markers.isEmpty ? "" : markers.joined(separator: ", "),
            notes: noteItems.isEmpty ? "" : noteItems.joined(separator: ", "),
            mcsSites: mcsSites, allSingleCutters: allSingleCutterNames,
            mcsDetected: mcsDetected, mcsRange: mcsRange
        )
    }
    
    
    // =========================================================================
    // MARK: Built-in vectors (static)
    // =========================================================================
    
    static func builtInVectors() -> [ShuttleVector] {
        return [
            
            // ── GENERAL CLONING ──
            
            ShuttleVector(name: "pUC19", fullName: "pUC19 (Yanisch-Perron et al., 1985)", category: .generalCloning, size: 2686,
                          mcsSites: ["EcoRI", "SacI", "KpnI", "AvaI", "XmaI/SmaI", "BamHI", "XbaI", "AccI/HincII/SalI", "SbfI/PstI", "SphI", "HindIII"],
                          selectionMarker: "AmpR", notes: "lacZ α-complementation, high-copy ColE1 origin", isBuiltIn: true),
            
            ShuttleVector(name: "pUC18", fullName: "pUC18 (Yanisch-Perron et al., 1985)", category: .generalCloning, size: 2686,
                          mcsSites: ["HindIII", "SphI", "SbfI/PstI", "AccI/HincII/SalI", "XbaI", "BamHI", "XmaI/SmaI", "KpnI", "SacI", "EcoRI"],
                          selectionMarker: "AmpR", notes: "lacZ α-complementation, MCS reversed vs pUC19", isBuiltIn: true),
            
            ShuttleVector(name: "pBluescript II SK(+)", fullName: "pBluescript II SK(+) (Stratagene)", category: .generalCloning, size: 2961,
                          mcsSites: ["SacI", "SacII", "NotI", "XbaI", "SpeI", "BamHI", "SmaI", "PstI", "EcoRI", "EcoRV", "HindIII", "ClaI", "SalI", "XhoI", "ApaI", "KpnI"],
                          selectionMarker: "AmpR", notes: "T3/T7 promoters flanking MCS, f1 origin, lacZ", isBuiltIn: true),
            
            ShuttleVector(name: "pBluescript II KS(+)", fullName: "pBluescript II KS(+) (Stratagene)", category: .generalCloning, size: 2961,
                          mcsSites: ["KpnI", "ApaI", "XhoI", "SalI", "ClaI", "HindIII", "EcoRV", "EcoRI", "PstI", "SmaI", "BamHI", "SpeI", "XbaI", "NotI", "SacII", "SacI"],
                          selectionMarker: "AmpR", notes: "T3/T7 promoters, MCS reversed vs SK", isBuiltIn: true),
            
            ShuttleVector(name: "pBR322", fullName: "pBR322 (Bolivar et al., 1977)", category: .generalCloning, size: 4361,
                          mcsSites: ["EcoRI", "ClaI", "HindIII", "BamHI", "SalI", "XmaI/SmaI", "AvaI", "NdeI"],
                          selectionMarker: "AmpR, TetR", notes: "Original E. coli cloning vector, moderate copy number", isBuiltIn: true),
            
            ShuttleVector(name: "pACYC184", fullName: "pACYC184 (Chang & Cohen, 1978)", category: .generalCloning, size: 4245,
                          mcsSites: ["ClaI", "HindIII", "SalI", "BamHI", "EcoRI", "AvaI", "XbaI"],
                          selectionMarker: "CmR, TetR", notes: "p15A origin, compatible with ColE1 vectors", isBuiltIn: true),
            
            ShuttleVector(name: "pSC101", category: .generalCloning, size: 9263,
                          mcsSites: ["EcoRI", "HindIII", "SalI", "BamHI"],
                          selectionMarker: "TetR", notes: "Low-copy, compatible with ColE1 and p15A origins", isBuiltIn: true),
            
            ShuttleVector(name: "pGEM-T Easy", fullName: "pGEM-T Easy (Promega)", category: .generalCloning, size: 3015,
                          mcsSites: ["ApaI", "AatII", "SphI", "BstZI", "NcoI", "SacII", "EcoRI", "SpeI", "NotI", "BstZI", "PstI", "SalI", "NdeI", "SacI", "BstXI", "NsiI"],
                          selectionMarker: "AmpR", notes: "T-overhang for PCR products, SP6/T7 promoters, lacZ", isBuiltIn: true),
            
            // ── E. COLI EXPRESSION ──
            
            ShuttleVector(name: "pET-28a(+)", fullName: "pET-28a(+) (Novagen)", category: .ecoliExpression, size: 5369,
                          mcsSites: ["NcoI", "NdeI", "BamHI", "EcoRI", "SacI", "SalI", "HindIII", "NotI", "XhoI"],
                          selectionMarker: "KanR", notes: "T7 promoter, N-terminal His₆ + thrombin, optional C-terminal His₆",
                          isBuiltIn: true, fusionFrameOffset: 0),
            
            ShuttleVector(name: "pET-28b(+)", fullName: "pET-28b(+) (Novagen)", category: .ecoliExpression, size: 5369,
                          mcsSites: ["NcoI", "NdeI", "BamHI", "EcoRI", "SacI", "SalI", "HindIII", "NotI", "XhoI"],
                          selectionMarker: "KanR", notes: "T7 promoter, N-terminal His₆ + thrombin (+1 frame relative to pET-28a), optional C-terminal His₆",
                          isBuiltIn: true, fusionFrameOffset: 1),
            
            ShuttleVector(name: "pET-28c(+)", fullName: "pET-28c(+) (Novagen)", category: .ecoliExpression, size: 5369,
                          mcsSites: ["NcoI", "NdeI", "BamHI", "EcoRI", "SacI", "SalI", "HindIII", "NotI", "XhoI"],
                          selectionMarker: "KanR", notes: "T7 promoter, N-terminal His₆ + thrombin (+2 frame relative to pET-28a), optional C-terminal His₆",
                          isBuiltIn: true, fusionFrameOffset: 2),
            
            ShuttleVector(name: "pET-21a(+)", fullName: "pET-21a(+) (Novagen)", category: .ecoliExpression, size: 5443,
                          mcsSites: ["NdeI", "BamHI", "EcoRI", "SacI", "SalI", "HindIII", "NotI", "XhoI"],
                          selectionMarker: "AmpR", notes: "T7 promoter, optional C-terminal His₆ tag",
                          isBuiltIn: true, fusionFrameOffset: 0),
            
            ShuttleVector(name: "pET-32a(+)", fullName: "pET-32a(+) (Novagen)", category: .ecoliExpression, size: 5900,
                          mcsSites: ["NcoI", "BamHI", "EcoRI", "SacI", "SalI", "HindIII", "NotI", "XhoI"],
                          selectionMarker: "AmpR", notes: "T7 promoter, N-terminal thioredoxin + His₆ + S-tag + enterokinase",
                          isBuiltIn: true, fusionFrameOffset: 0),
            
            ShuttleVector(name: "pGEX-4T-1", fullName: "pGEX-4T-1 (Cytiva)", category: .ecoliExpression, size: 4969,
                          mcsSites: ["BamHI", "EcoRI", "SmaI", "SalI", "XhoI", "NotI"],
                          selectionMarker: "AmpR", notes: "tac promoter, N-terminal GST tag, thrombin cleavage site",
                          isBuiltIn: true, fusionFrameOffset: 0),
            
            ShuttleVector(name: "pGEX-6P-1", fullName: "pGEX-6P-1 (Cytiva)", category: .ecoliExpression, size: 4984,
                          mcsSites: ["BamHI", "EcoRI", "SmaI", "SalI", "XhoI", "NotI"],
                          selectionMarker: "AmpR", notes: "tac promoter, N-terminal GST tag, PreScission protease site",
                          isBuiltIn: true, fusionFrameOffset: 0),
            
            ShuttleVector(name: "pMAL-c5X", fullName: "pMAL-c5X (NEB)", category: .ecoliExpression, size: 6721,
                          mcsSites: ["NdeI", "BamHI", "EcoRI", "SalI", "PstI", "HindIII"],
                          selectionMarker: "AmpR", notes: "tac promoter, N-terminal MBP tag, Factor Xa cleavage",
                          isBuiltIn: true, fusionFrameOffset: 0),
            
            ShuttleVector(name: "pMAL-c2", fullName: "pMAL-c2 (NEB)", category: .ecoliExpression, size: 6646,
                          mcsSites: ["EcoRI", "BamHI", "XbaI", "SalI", "PstI", "HindIII"],
                          selectionMarker: "AmpR", notes: "tac promoter, N-terminal MBP tag, Factor Xa cleavage (older pMAL series — predecessor to pMAL-c5X)",
                          isBuiltIn: true, fusionFrameOffset: 0),
            
            ShuttleVector(name: "pBAD/His A", fullName: "pBAD/His A (Invitrogen)", category: .ecoliExpression, size: 4102,
                          mcsSites: ["NcoI", "BglII", "EcoRI", "PmeI", "HindIII", "XhoI"],
                          selectionMarker: "AmpR", notes: "araBAD promoter (arabinose-inducible), N-terminal His₆",
                          isBuiltIn: true, fusionFrameOffset: 0),
            
            ShuttleVector(name: "pCold I", fullName: "pCold I (Takara)", category: .ecoliExpression, size: 4408,
                          mcsSites: ["NdeI", "XhoI", "BamHI", "SalI", "PstI", "HindIII"],
                          selectionMarker: "AmpR", notes: "cspA cold-shock promoter, N-terminal His₆, cold-inducible",
                          isBuiltIn: true, fusionFrameOffset: 0),
            
            ShuttleVector(name: "pRSFDuet-1", fullName: "pRSFDuet-1 (Novagen)", category: .ecoliExpression, size: 3829,
                          mcsSites: ["BamHI", "NcoI", "SacI", "EcoRI", "HindIII", "NdeI", "XhoI", "AvrII", "KpnI"],
                          selectionMarker: "KanR", notes: "RSF origin, dual T7 promoters, compatible with ColE1/p15A", isBuiltIn: true),
            
            ShuttleVector(name: "pTrc99A", fullName: "pTrc99A (Pharmacia)", category: .ecoliExpression, size: 4176,
                          mcsSites: ["NcoI", "BamHI", "EcoRI", "SacI", "SalI", "PstI", "HindIII"],
                          selectionMarker: "AmpR", notes: "trc promoter (hybrid trp/lac), moderate expression", isBuiltIn: true),
            
            // ── MAMMALIAN EXPRESSION ──
            
            ShuttleVector(name: "pcDNA3.1(+)", fullName: "pcDNA3.1(+) (Invitrogen)", category: .mammalianExpression, size: 5428,
                          mcsSites: ["NheI", "KpnI", "BamHI", "EcoRI", "EcoRV", "BstXI", "NotI", "XhoI", "XbaI", "ApaI", "HindIII"],
                          selectionMarker: "AmpR (E. coli), NeoR/G418 (mammalian)", notes: "CMV promoter, BGH polyA, T7 promoter", isBuiltIn: true),
            
            ShuttleVector(name: "pcDNA3.1(-)", fullName: "pcDNA3.1(-) (Invitrogen)", category: .mammalianExpression, size: 5427,
                          mcsSites: ["HindIII", "ApaI", "XbaI", "XhoI", "NotI", "BstXI", "EcoRV", "EcoRI", "BamHI", "KpnI", "NheI"],
                          selectionMarker: "AmpR (E. coli), NeoR/G418 (mammalian)", notes: "CMV promoter, MCS reversed vs pcDNA3.1(+)", isBuiltIn: true),
            
            ShuttleVector(name: "pEGFP-N1", fullName: "pEGFP-N1 (Clontech)", category: .mammalianExpression, size: 4733,
                          mcsSites: ["AgeI", "EcoRI", "SmaI", "BamHI", "XhoI", "SalI", "AccI/HincII", "PstI", "ApaI"],
                          selectionMarker: "KanR (E. coli), NeoR/G418 (mammalian)", notes: "CMV promoter, C-terminal EGFP fusion", isBuiltIn: true),
            
            ShuttleVector(name: "pEGFP-C1", fullName: "pEGFP-C1 (Clontech)", category: .mammalianExpression, size: 4731,
                          mcsSites: ["XhoI", "EcoRI", "BamHI", "SmaI", "SalI", "AccI/HincII", "PstI", "ApaI", "KpnI"],
                          selectionMarker: "KanR (E. coli), NeoR/G418 (mammalian)", notes: "CMV promoter, N-terminal EGFP fusion", isBuiltIn: true),
            
            ShuttleVector(name: "pCMV-Tag2", fullName: "pCMV-Tag2 (Agilent)", category: .mammalianExpression, size: 4338,
                          mcsSites: ["EcoRI", "BamHI", "SalI", "XhoI", "NotI", "HindIII"],
                          selectionMarker: "AmpR (E. coli), NeoR (mammalian)", notes: "CMV promoter, N-terminal FLAG tag", isBuiltIn: true),
            
            ShuttleVector(name: "pCMV-Sport6", fullName: "pCMV-Sport6 (Invitrogen)", category: .mammalianExpression, size: 4396,
                          mcsSites: ["SalI", "NotI", "EcoRI"],
                          selectionMarker: "AmpR (E. coli), NeoR (mammalian)", notes: "CMV promoter, SP6/T7 flanking, cDNA library", isBuiltIn: true),
            
            ShuttleVector(name: "pIRES2-EGFP", fullName: "pIRES2-EGFP (Clontech)", category: .mammalianExpression, size: 5308,
                          mcsSites: ["NheI", "EcoRI", "BglII", "SalI", "BamHI", "XhoI"],
                          selectionMarker: "KanR (E. coli), NeoR (mammalian)", notes: "CMV promoter, IRES-EGFP bicistronic expression", isBuiltIn: true),
            
            ShuttleVector(name: "pLenti6/V5-DEST", fullName: "pLenti6/V5-DEST (Invitrogen)", category: .mammalianExpression, size: 9781,
                          mcsSites: ["EcoRI", "XhoI"],
                          selectionMarker: "AmpR (E. coli), BlastR (mammalian)", notes: "CMV promoter, lentiviral, Gateway att sites, C-terminal V5 + His₆", isBuiltIn: true),
            
            // ── YEAST EXPRESSION ──
            
            ShuttleVector(name: "pYES2", fullName: "pYES2 (Invitrogen)", category: .yeastExpression, size: 5856,
                          mcsSites: ["KpnI", "SacI", "BamHI", "BstXI", "EcoRI", "SpeI", "XhoI", "XbaI", "NotI", "HindIII"],
                          selectionMarker: "AmpR (E. coli), URA3 (yeast)", notes: "GAL1 promoter (galactose-inducible), 2μ origin", isBuiltIn: true),
            
            ShuttleVector(name: "pRS426", fullName: "pRS426 (Christianson et al., 1992)", category: .yeastExpression, size: 5726,
                          mcsSites: ["SacI", "KpnI", "SmaI", "BamHI", "XbaI", "SalI", "PstI", "SphI", "HindIII"],
                          selectionMarker: "AmpR (E. coli), URA3 (yeast)", notes: "2μ high-copy, pUC19-derived MCS", isBuiltIn: true),
            
            ShuttleVector(name: "pRS316", fullName: "pRS316 (Sikorski & Hieter, 1989)", category: .yeastExpression, size: 4887,
                          mcsSites: ["SacI", "KpnI", "SmaI", "BamHI", "XbaI", "SalI", "PstI", "SphI", "HindIII"],
                          selectionMarker: "AmpR (E. coli), URA3 (yeast)", notes: "CEN/ARS low-copy, pUC19-derived MCS", isBuiltIn: true),
            
            ShuttleVector(name: "pPIC9K", fullName: "pPIC9K (Invitrogen)", category: .yeastExpression, size: 9276,
                          mcsSites: ["EcoRI", "AvrII", "NotI", "SnaBI", "BamHI"],
                          selectionMarker: "AmpR (E. coli), HIS4 + KanR (Pichia)", notes: "AOX1 promoter (methanol-inducible), α-factor secretion, Pichia pastoris", isBuiltIn: true),
            
            // ── INSECT EXPRESSION ──
            
            ShuttleVector(name: "pFastBac1", fullName: "pFastBac1 (Invitrogen)", category: .insectExpression, size: 4775,
                          mcsSites: ["BamHI", "EcoRI", "StuI", "SalI", "SstI", "SpeI", "NotI", "NcoI", "XbaI", "PstI", "KpnI", "HindIII"],
                          selectionMarker: "AmpR, GenR", notes: "Polyhedrin promoter, Bac-to-Bac baculovirus system", isBuiltIn: true),
            
            ShuttleVector(name: "pFastBac HT A", fullName: "pFastBac HT A (Invitrogen)", category: .insectExpression, size: 4856,
                          mcsSites: ["BamHI", "EcoRI", "StuI", "SalI", "SstI", "SpeI", "NotI", "NcoI", "XbaI", "PstI", "KpnI", "HindIII"],
                          selectionMarker: "AmpR, GenR", notes: "Polyhedrin promoter, N-terminal His₆ + TEV cleavage", isBuiltIn: true),
            
            // ── SHUTTLE / SPECIALITY ──
            
            ShuttleVector(name: "pETDuet-1", fullName: "pETDuet-1 (Novagen)", category: .shuttle, size: 5420,
                          mcsSites: ["NcoI", "BamHI", "SacI", "EcoRI", "HindIII", "NdeI", "MfeI", "XhoI", "AvrII", "KpnI"],
                          selectionMarker: "AmpR", notes: "Dual T7 promoters for co-expression of two proteins", isBuiltIn: true),
            
            ShuttleVector(name: "pCDFDuet-1", fullName: "pCDFDuet-1 (Novagen)", category: .shuttle, size: 3781,
                          mcsSites: ["NcoI", "BamHI", "SacI", "EcoRI", "HindIII", "NdeI", "MfeI", "XhoI", "AvrII", "KpnI"],
                          selectionMarker: "SmR (Streptomycin)", notes: "CloDF13 origin, dual T7, compatible with ColE1/p15A/RSF", isBuiltIn: true),
            
            ShuttleVector(name: "pLysS", fullName: "pLysS (Novagen)", category: .shuttle, size: 4886,
                          mcsSites: ["BamHI", "XbaI"],
                          selectionMarker: "CmR", notes: "p15A origin, T7 lysozyme for tight T7 expression control", isBuiltIn: true),
        ]
    }
}

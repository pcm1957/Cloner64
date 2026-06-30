import Foundation

// MARK: - Insert Orientation

enum InsertOrientation: String {
    case forward = "Forward"    // insert reads 5'→3' from promoter toward terminator
    case reverse = "Reverse"    // insert is reversed relative to promoter
    case unknown = ""           // can't determine (non-directional or no feature context)
}


// MARK: - Cloning Route

struct CloningRoute: Identifiable {
    let id = UUID()
    let steps: [CloningStep]
    let score: Int
    let orientation: InsertOrientation
    
    var stepCount: Int { steps.count }
    var isDirectRoute: Bool { steps.count == 1 }
    
    var summary: String {
        if steps.count == 1, let step = steps.first {
            return "Direct: \(step.enzyme5Name) and \(step.enzyme3Name)"
        }
        let via = steps.dropLast().compactMap { $0.destinationName }.joined(separator: " → ")
        return "\(steps.count) steps via \(via)"
    }
    
    /// Enzyme names involved in partial digests across all steps.
    /// Used to filter out shuttle routes that don't improve on direct cloning
    /// (i.e. they involve the same partial digest the direct route already needs).
    var partialDigestEnzymeNames: Set<String> {
        var names = Set<String>()
        for step in steps {
            if step.partialDigest5 { names.insert(step.enzyme5Name) }
            if step.partialDigest3 { names.insert(step.enzyme3Name) }
        }
        return names
    }
}

struct CloningStep: Identifiable {
    let id = UUID()
    let sourceName: String
    let destinationName: String
    let enzyme5Name: String
    let enzyme3Name: String
    let isDirectional: Bool
    let partialDigest5: Bool    // enzyme5 cuts >1× in the destination vector
    let partialDigest3: Bool    // enzyme3 cuts >1× in the destination vector
    
    var needsPartialDigest: Bool { partialDigest5 || partialDigest3 }
    var isDoublePartialDigest: Bool { partialDigest5 && partialDigest3 }
    
    var enzymeDescription: String {
        isDirectional ? "\(enzyme5Name) and \(enzyme3Name)" : enzyme5Name
    }
}


// MARK: - Shuttle Vector Pathfinder

class ShuttleVectorPathfinder {
    
    private let enzymeDB = RestrictionEnzymeDatabase.shared
    private let vectorLibrary = ShuttleVectorLibrary.shared
    
    /// Maximum routes to return (prevents combinatorial explosion in the UI)
    private let maxRoutes = 50
    
    /// Find cloning routes from source to destination, potentially via shuttle vectors.
    /// All routes are direct-digest only (no PCR).
    func findRoutes(
        sourceSequence: String,
        insertRegion: InsertRegion,
        sourceIsCircular: Bool,
        sourceName: String,
        destinationName: String,
        destinationMCSSites: [String]?,
        destinationSequence: String? = nil,
        destinationIsCircular: Bool = true,
        protectedRegions: [ClosedRange<Int>] = [],
        cloningRegionRange: ClosedRange<Int>? = nil,
        myVectorsOnly: Bool = false
    ) -> [CloningRoute] {
        
        let sourceSeq = sourceSequence.uppercased()
        
        // --- Step 1: Find enzymes flanking the insert on the source (done ONCE) ---
        var sourceSitesByEnzyme: [String: [CutSite]] = [:]
        for enzyme in enzymeDB.enzymes {
            let sites = enzyme.findCutSites(in: sourceSeq, circular: sourceIsCircular)
            if !sites.isEmpty { sourceSitesByEnzyme[enzyme.name] = sites }
        }
        
        // Classify each enzyme as flanking 5', 3', or both
        // Handles circular sources where the insert may wrap the origin
        var has5: Set<String> = []
        var has3: Set<String> = []
        
        let srcLen = sourceSeq.count
        
        for (name, sites) in sourceSitesByEnzyme {
            for site in sites {
                let pos = site.position
                let (isInside, isUp, isDown) = classifySiteRelativeToInsert(
                    pos, insertRegion: insertRegion, sourceIsCircular: sourceIsCircular, sourceLength: srcLen)
                if isInside { continue }
                if isUp { has5.insert(name) }
                if isDown { has3.insert(name) }
            }
        }
        
        // Enzymes that flank on at least one side
        let allFlanking = has5.union(has3)
        
        // --- Step 2: Expand the destination MCS names ---
        let destMCS: Set<String>
        if let sites = destinationMCSSites {
            destMCS = expandNames(sites)
        } else {
            destMCS = Set<String>()
        }
        
        // --- Step 2b: Find enzymes that cut within protected regions on the destination vector ---
        // Also count total cut sites and store positions per enzyme for partial digest + orientation detection.
        var destUnsafeEnzymes: Set<String> = []
        var destCutCounts: [String: Int] = [:]
        var destCutPositions: [String: [Int]] = [:]
        if let destSeq = destinationSequence?.uppercased() {
            for enzyme in enzymeDB.enzymes {
                let sites = enzyme.findCutSites(in: destSeq, circular: destinationIsCircular)
                if !sites.isEmpty {
                    let positions = sites.map { $0.position }
                    destCutCounts[enzyme.name] = sites.count
                    destCutPositions[enzyme.name] = positions
                    for part in enzyme.name.components(separatedBy: "/") {
                        destCutCounts[part] = sites.count
                        destCutPositions[part] = positions
                    }
                }
                if !protectedRegions.isEmpty {
                    let cutsProtected = sites.contains { site in
                        protectedRegions.contains { $0.contains(site.position) }
                    }
                    if cutsProtected {
                        destUnsafeEnzymes.insert(enzyme.name)
                        for part in enzyme.name.components(separatedBy: "/") {
                            destUnsafeEnzymes.insert(part)
                        }
                    }
                }
            }
        }
        
        var routes: [CloningRoute] = []
        
        
        // --- Shuttle routes (source → shuttle → destination) ---
        guard !destMCS.isEmpty else {
            return routes.sorted { $0.score > $1.score }
        }
        
        let shuttleCandidates: [ShuttleVector]
        if myVectorsOnly && !vectorLibrary.myVectors.isEmpty {
            shuttleCandidates = vectorLibrary.myVectors
        } else {
            shuttleCandidates = vectorLibrary.vectors
        }
        
        for shuttle in shuttleCandidates {
            if shuttle.name == destinationName { continue }
            
            let shuttleMCS = expandNames(shuttle.mcsSites)
            
            // Quick check: does the shuttle share ANY enzymes with the source flanking set?
            let shuttleOverlap = shuttleMCS.intersection(allFlanking)
            guard !shuttleOverlap.isEmpty else { continue }
            
            // Step 1 candidates: source → shuttle
            let step1Options = findSteps(
                from5: has5, from3: has3,
                targetMCS: shuttleMCS,
                sourceName: sourceName,
                destinationName: shuttle.name
            )
            
            guard !step1Options.isEmpty else { continue }
            
            // For step 2: enzymes in BOTH shuttle MCS and destination MCS
            let commonForStep2 = shuttleMCS.intersection(destMCS)
            guard commonForStep2.count >= 1 else { continue }
            
            // Limit step1 candidates to the best few to avoid explosion
            let bestStep1 = Array(step1Options.prefix(5))
            
            for step1 in bestStep1 {
                let step1Used = Set([step1.enzyme5Name, step1.enzyme3Name])
                let availableForStep2 = commonForStep2.subtracting(step1Used)
                
                guard !availableForStep2.isEmpty else { continue }
                
                // Build step 2 options (with destination cut counts for partial digest detection)
                let step2Options = buildStepsFromSet(
                    enzymes: availableForStep2,
                    sourceName: shuttle.name,
                    destinationName: destinationName,
                    destCutCounts: destCutCounts
                )
                
                // Filter out step 2 options that use enzymes cutting within protected regions
                let safeStep2Options: [CloningStep]
                if !destUnsafeEnzymes.isEmpty {
                    safeStep2Options = step2Options.filter { step in
                        !destUnsafeEnzymes.contains(step.enzyme5Name) &&
                        !destUnsafeEnzymes.contains(step.enzyme3Name)
                    }
                } else {
                    safeStep2Options = step2Options
                }
                
                // Take only the best step2 per step1
                for step2 in safeStep2Options.prefix(3) {
                    let steps = [step1, step2]
                    let orient = determineRouteOrientation(
                        step1: step1, step2: step2,
                        shuttleMCSSites: shuttle.mcsSites,
                        destPositions: destCutPositions,
                        cloningRegionRange: cloningRegionRange
                    )
                    let routeScore = scoreRoute(steps, orientation: orient)
                    routes.append(CloningRoute(steps: steps, score: routeScore, orientation: orient))
                    if routes.count >= maxRoutes { break }
                }
                if routes.count >= maxRoutes { break }
            }
            if routes.count >= maxRoutes { break }
        }
        
        return routes.sorted { $0.score > $1.score }
    }
    
    
    // =========================================================================
    // MARK: Find steps using pre-computed flanking sets
    // =========================================================================
    
    private func findSteps(
        from5: Set<String>,
        from3: Set<String>,
        targetMCS: Set<String>,
        sourceName: String,
        destinationName: String
    ) -> [CloningStep] {
        
        // Enzymes that flank 5' AND are in target MCS
        let usable5 = from5.filter { nameInMCS($0, targetMCS) }
        // Enzymes that flank 3' AND are in target MCS
        let usable3 = from3.filter { nameInMCS($0, targetMCS) }
        
        var steps: [CloningStep] = []
        
        // Directional pairs (different enzyme on each side)
        let arr5 = Array(usable5).sorted()
        let arr3 = Array(usable3).sorted()
        
        for e5 in arr5 {
            for e3 in arr3 {
                if e5 == e3 { continue }
                guard let enz5 = findEnzyme(e5), let enz3 = findEnzyme(e3) else { continue }
                if areCompatible(enz5, enz3) { continue }
                
                steps.append(CloningStep(
                    sourceName: sourceName, destinationName: destinationName,
                    enzyme5Name: e5, enzyme3Name: e3, isDirectional: true,
                    partialDigest5: false, partialDigest3: false
                ))
                if steps.count > 20 { return steps }  // cap per target
            }
        }
        
        // Non-directional (same enzyme on both sides)
        let bothSides = usable5.intersection(usable3)
        for e in bothSides.sorted() {
            guard findEnzyme(e) != nil else { continue }
            steps.append(CloningStep(
                sourceName: sourceName, destinationName: destinationName,
                enzyme5Name: e, enzyme3Name: e, isDirectional: false,
                partialDigest5: false, partialDigest3: false
            ))
        }
        
        return steps
    }
    
    
    // =========================================================================
    // MARK: Build steps from a set of available enzyme names
    // =========================================================================
    
    private func buildStepsFromSet(
        enzymes: Set<String>,
        sourceName: String,
        destinationName: String,
        destCutCounts: [String: Int] = [:]
    ) -> [CloningStep] {
        let names = Array(enzymes).sorted()
        var steps: [CloningStep] = []
        
        // Directional pairs
        for i in 0..<names.count {
            for j in (i+1)..<names.count {
                guard let enz5 = findEnzyme(names[i]), let enz3 = findEnzyme(names[j]) else { continue }
                if areCompatible(enz5, enz3) { continue }
                let pd5 = (destCutCounts[names[i]] ?? 1) > 1
                let pd3 = (destCutCounts[names[j]] ?? 1) > 1
                // Skip double partial digests — essentially unusable
                if pd5 && pd3 { continue }
                steps.append(CloningStep(sourceName: sourceName, destinationName: destinationName,
                                         enzyme5Name: names[i], enzyme3Name: names[j], isDirectional: true,
                                         partialDigest5: pd5, partialDigest3: pd3))
                if steps.count > 10 { return steps }
            }
        }
        
        // Non-directional
        for name in names {
            guard findEnzyme(name) != nil else { continue }
            let pd = (destCutCounts[name] ?? 1) > 1
            steps.append(CloningStep(sourceName: sourceName, destinationName: destinationName,
                                     enzyme5Name: name, enzyme3Name: name, isDirectional: false,
                                     partialDigest5: pd, partialDigest3: pd))
        }
        
        return steps
    }
    
    
    // =========================================================================
    // MARK: Scoring
    // =========================================================================
    
    private func scoreRoute(_ steps: [CloningStep], orientation: InsertOrientation = .unknown) -> Int {
        var score = 100
        score -= (steps.count - 1) * 30  // fewer steps better
        for step in steps {
            if step.isDirectional { score += 20 }
            if step.needsPartialDigest { score -= 25 }
        }
        // Bonus for confirmed forward orientation, penalty for reverse
        switch orientation {
        case .forward: score += 15
        case .reverse: score -= 10
        case .unknown: break
        }
        return score
    }
    
    
    // =========================================================================
    // MARK: Orientation determination
    // =========================================================================
    
    /// Determine the final orientation of the insert in the destination vector.
    ///
    /// Logic:
    /// 1. Step 1 places the insert into the shuttle. enzyme5Name flanks the insert
    ///    5' side (from the source). If enzyme5 has a LOWER index in the shuttle MCS
    ///    than enzyme3, the insert is "forward" in the shuttle.
    ///
    /// 2. Step 2 excises a fragment from the shuttle into the destination.
    ///    The enzyme with the LOWER index in the shuttle MCS is on the 5' end of
    ///    the excised fragment. In the destination, the enzyme cutting at the LOWER
    ///    position (closer to the promoter) is on the 5' side.
    ///    If the same enzyme is "5'-side" in both → orientation is preserved.
    ///
    /// 3. Final: forward-in-shuttle + preserved = Forward.
    ///    forward-in-shuttle + flipped = Reverse. And vice versa.
    private func determineRouteOrientation(
        step1: CloningStep, step2: CloningStep,
        shuttleMCSSites: [String],
        destPositions: [String: [Int]],
        cloningRegionRange: ClosedRange<Int>?
    ) -> InsertOrientation {
        // Non-directional steps → can't determine orientation
        guard step1.isDirectional && step2.isDirectional else { return .unknown }
        // No cloning region → don't know where promoter/terminator are
        guard let region = cloningRegionRange else { return .unknown }
        
        // --- Step 1: insert orientation in shuttle ---
        guard let idx1_5 = enzymeIndexInMCS(step1.enzyme5Name, shuttleMCSSites),
              let idx1_3 = enzymeIndexInMCS(step1.enzyme3Name, shuttleMCSSites) else {
            return .unknown
        }
        let insertForwardInShuttle = idx1_5 < idx1_3
        
        // --- Step 2: is orientation preserved from shuttle to destination? ---
        guard let idx2_A = enzymeIndexInMCS(step2.enzyme5Name, shuttleMCSSites),
              let idx2_B = enzymeIndexInMCS(step2.enzyme3Name, shuttleMCSSites) else {
            return .unknown
        }
        // The enzyme at the lower shuttle index is on the 5' end of the excised fragment
        let shuttle5endEnzyme = idx2_A < idx2_B ? step2.enzyme5Name : step2.enzyme3Name
        
        // Find positions in destination, preferring sites within the cloning region
        guard let posA = bestPositionInRegion(step2.enzyme5Name, destPositions, region),
              let posB = bestPositionInRegion(step2.enzyme3Name, destPositions, region) else {
            return .unknown
        }
        // The enzyme at the lower destination position is on the promoter (5') side
        let destPromoterEnzyme = posA < posB ? step2.enzyme5Name : step2.enzyme3Name
        
        // Is the 5' end of the excised fragment on the promoter side?
        let orientationPreserved = shuttle5endEnzyme == destPromoterEnzyme
        
        // Combine: forward + preserved = Forward, forward + flipped = Reverse, etc.
        return (insertForwardInShuttle == orientationPreserved) ? .forward : .reverse
    }
    
    /// Find the best cut position for an enzyme within (or nearest to) the cloning region
    private func bestPositionInRegion(_ enzymeName: String, _ destPositions: [String: [Int]], _ region: ClosedRange<Int>) -> Int? {
        guard let positions = destPositions[enzymeName], !positions.isEmpty else { return nil }
        let inRegion = positions.filter { region.contains($0) }
        if let best = inRegion.first { return best }
        return positions.min(by: {
            min(abs($0 - region.lowerBound), abs($0 - region.upperBound)) <
            min(abs($1 - region.lowerBound), abs($1 - region.upperBound))
        })
    }
    
    /// Find the index of an enzyme in an MCS site list, handling compound names like "EcoRV/Eco32I"
    private func enzymeIndexInMCS(_ enzymeName: String, _ mcsSites: [String]) -> Int? {
        let nameParts = enzymeName.components(separatedBy: "/")
        for (idx, site) in mcsSites.enumerated() {
            let siteParts = site.components(separatedBy: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            for np in nameParts {
                if siteParts.contains(np) { return idx }
            }
        }
        return nil
    }
    
    
    // =========================================================================
    // MARK: Helpers
    // =========================================================================
    
    /// Classify whether a site at position P is inside, upstream (5'), or downstream (3')
    /// of the insert region, handling circular topology and origin-wrapping inserts.
    private func classifySiteRelativeToInsert(
        _ pos: Int, insertRegion: InsertRegion, sourceIsCircular: Bool, sourceLength: Int
    ) -> (isInside: Bool, isUpstream: Bool, isDownstream: Bool) {
        if !insertRegion.wrapsOrigin {
            // Non-wrapping insert: inside = start..end
            if pos >= insertRegion.start && pos <= insertRegion.end {
                return (true, false, false)
            }
            if sourceIsCircular {
                let distToStart: Int
                let distFromEnd: Int
                if pos < insertRegion.start {
                    distToStart = insertRegion.start - pos
                    distFromEnd = sourceLength - insertRegion.end + pos
                } else {
                    distToStart = sourceLength - pos + insertRegion.start
                    distFromEnd = pos - insertRegion.end
                }
                return (false, distToStart <= distFromEnd, distToStart > distFromEnd)
            } else {
                return (false, pos < insertRegion.start, pos > insertRegion.end)
            }
        } else {
            // Wrapping insert (start > end): inside = pos >= start OR pos <= end
            if pos >= insertRegion.start || pos <= insertRegion.end {
                return (true, false, false)
            }
            // Outside region is end+1 .. start-1
            let distToStart = insertRegion.start - pos
            let distFromEnd = pos - insertRegion.end
            return (false, distToStart <= distFromEnd, distToStart > distFromEnd)
        }
    }
    
    private func expandNames(_ names: [String]) -> Set<String> {
        var result = Set<String>()
        for name in names {
            for part in name.components(separatedBy: "/") {
                result.insert(part.trimmingCharacters(in: .whitespaces))
            }
        }
        return result
    }
    
    /// Check if an enzyme name (possibly compound like "EcoRV/Eco32I") matches any name in the MCS set
    private func nameInMCS(_ enzymeName: String, _ mcs: Set<String>) -> Bool {
        enzymeName.components(separatedBy: "/").contains(where: { mcs.contains($0) })
    }
    
    /// Find an enzyme in the database, handling compound names
    private func findEnzyme(_ name: String) -> RestrictionEnzyme? {
        enzymeDB.enzymes.first(where: { $0.name == name })
            ?? enzymeDB.enzymes.first(where: { $0.name.components(separatedBy: "/").contains(name) })
    }
    
    private func areCompatible(_ e1: RestrictionEnzyme, _ e2: RestrictionEnzyme) -> Bool {
        if e1.overhangType == .blunt && e2.overhangType == .blunt { return true }
        guard e1.overhangType == e2.overhangType else { return false }
        return e1.overhangSequence == e2.overhangSequence
    }
}

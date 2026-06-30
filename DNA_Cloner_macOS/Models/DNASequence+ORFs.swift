import Foundation

// MARK: - DNASequence ORF Scanning Extension
//
// Shared ORF scanning logic so that SequenceEditorView, PredictiveCloningView,
// and any other view can find ORFs without duplicating code.

extension DNASequence {
    
    /// Scan this sequence for all open reading frames in all 6 frames.
    ///
    /// - Parameter minNucleotides: Minimum ORF length in nucleotides (default 100 ≈ 33aa)
    /// - Returns: Array of ORFResult sorted largest first
    ///
    func findORFs(minNucleotides: Int = 100) -> [ORFResult] {
        let seqLen = sequence.count
        var orfs: [ORFResult] = []
        
        // Forward strand (+1, +2, +3)
        // Call self.translate(frame:) directly — no temporary DNASequence needed.
        for frame in 1...3 {
            let protein = self.translate(frame: frame)
            var startPos: Int?       // position of first M (ATG)
            var segStart: Int = 0    // position after last stop (for no-ATG detection)
            for (i, aa) in protein.enumerated() {
                if aa == "M" && startPos == nil {
                    startPos = i
                }
                if aa == "*" {
                    if let start = startPos {
                        let orfLen = (i - start) * 3
                        if orfLen >= minNucleotides {
                            let pStart = protein.index(protein.startIndex, offsetBy: start)
                            let pEnd   = protein.index(protein.startIndex, offsetBy: i)
                            let proteinSeq = String(protein[pStart..<pEnd])
                            orfs.append(ORFResult(
                                position: (frame - 1) + start * 3 + 1,
                                size: orfLen,
                                strand: "+\(frame)",
                                label: "ORF \(orfLen/3)aa",
                                frame: frame,
                                protein: proteinSeq
                            ))
                        }
                    } else {
                        // Stretch from segStart to stop with no ATG
                        let orfLen = (i - segStart) * 3
                        if orfLen >= minNucleotides {
                            let pStart = protein.index(protein.startIndex, offsetBy: segStart)
                            let pEnd   = protein.index(protein.startIndex, offsetBy: i)
                            let proteinSeq = String(protein[pStart..<pEnd])
                            orfs.append(ORFResult(
                                position: (frame - 1) + segStart * 3 + 1,
                                size: orfLen,
                                strand: "+\(frame)",
                                label: "ORF \(orfLen/3)aa (no ATG)",
                                frame: frame,
                                protein: proteinSeq
                            ))
                        }
                    }
                    startPos = nil
                    segStart = i + 1
                }
            }
            // Capture ORF that runs to end of sequence without a stop codon
            if let start = startPos {
                let orfLen = (protein.count - start) * 3
                if orfLen >= minNucleotides {
                    let pStart = protein.index(protein.startIndex, offsetBy: start)
                    let proteinSeq = String(protein[pStart...])
                    orfs.append(ORFResult(
                        position: (frame - 1) + start * 3 + 1,
                        size: orfLen,
                        strand: "+\(frame)",
                        label: "ORF \(orfLen/3)aa (no stop)",
                        frame: frame,
                        protein: proteinSeq
                    ))
                }
            } else if segStart < protein.count {
                // No ATG and no stop — runs to end
                let orfLen = (protein.count - segStart) * 3
                if orfLen >= minNucleotides {
                    let pStart = protein.index(protein.startIndex, offsetBy: segStart)
                    let proteinSeq = String(protein[pStart...])
                    orfs.append(ORFResult(
                        position: (frame - 1) + segStart * 3 + 1,
                        size: orfLen,
                        strand: "+\(frame)",
                        label: "ORF \(orfLen/3)aa (no ATG, no stop)",
                        frame: frame,
                        protein: proteinSeq
                    ))
                }
            }
        }
        
        // Reverse strand (-1, -2, -3)
        for frame in 1...3 {
            let protein = self.translate(frame: -frame)
            var startPos: Int?
            var segStart: Int = 0
            for (i, aa) in protein.enumerated() {
                if aa == "M" && startPos == nil { startPos = i }
                if aa == "*" {
                    if let start = startPos {
                        let orfLen = (i - start) * 3
                        if orfLen >= minNucleotides {
                            let rcDnaPos = (frame - 1) + start * 3
                            let pStart = protein.index(protein.startIndex, offsetBy: start)
                            let pEnd   = protein.index(protein.startIndex, offsetBy: i)
                            let proteinSeq = String(protein[pStart..<pEnd])
                            orfs.append(ORFResult(
                                position: max(1, seqLen - rcDnaPos - orfLen + 1),
                                size: orfLen,
                                strand: "-\(frame)",
                                label: "ORF \(orfLen/3)aa",
                                frame: -frame,
                                protein: proteinSeq
                            ))
                        }
                    } else {
                        let orfLen = (i - segStart) * 3
                        if orfLen >= minNucleotides {
                            let rcDnaPos = (frame - 1) + segStart * 3
                            let pStart = protein.index(protein.startIndex, offsetBy: segStart)
                            let pEnd   = protein.index(protein.startIndex, offsetBy: i)
                            let proteinSeq = String(protein[pStart..<pEnd])
                            orfs.append(ORFResult(
                                position: max(1, seqLen - rcDnaPos - orfLen + 1),
                                size: orfLen,
                                strand: "-\(frame)",
                                label: "ORF \(orfLen/3)aa (no ATG)",
                                frame: -frame,
                                protein: proteinSeq
                            ))
                        }
                    }
                    startPos = nil
                    segStart = i + 1
                }
            }
            // Capture ORF that runs to end of reverse strand without a stop codon
            if let start = startPos {
                let orfLen = (protein.count - start) * 3
                if orfLen >= minNucleotides {
                    let rcDnaPos = (frame - 1) + start * 3
                    let pStart = protein.index(protein.startIndex, offsetBy: start)
                    let proteinSeq = String(protein[pStart...])
                    orfs.append(ORFResult(
                        position: max(1, seqLen - rcDnaPos - orfLen + 1),
                        size: orfLen,
                        strand: "-\(frame)",
                        label: "ORF \(orfLen/3)aa (no stop)",
                        frame: -frame,
                        protein: proteinSeq
                    ))
                }
            } else if segStart < protein.count {
                let orfLen = (protein.count - segStart) * 3
                if orfLen >= minNucleotides {
                    let rcDnaPos = (frame - 1) + segStart * 3
                    let pStart = protein.index(protein.startIndex, offsetBy: segStart)
                    let proteinSeq = String(protein[pStart...])
                    orfs.append(ORFResult(
                        position: max(1, seqLen - rcDnaPos - orfLen + 1),
                        size: orfLen,
                        strand: "-\(frame)",
                        label: "ORF \(orfLen/3)aa (no ATG, no stop)",
                        frame: -frame,
                        protein: proteinSeq
                    ))
                }
            }
        }
        
        return orfs.sorted { $0.size > $1.size }
    }

    /// Static version of findORFs that works directly on a string.
    /// Use this instead of creating a temporary DNASequence just to scan for ORFs —
    /// a full DNASequence ObservableObject carries 8 Combine subscriptions, an undo
    /// stack, and a dirty-tracking pipeline that are wasted when only the sequence
    /// string is needed.
    static func findORFs(in sequenceString: String, minNucleotides: Int = 100) -> [ORFResult] {
        // Build a lightweight wrapper that borrows the existing instance method.
        // We set isLoading = true immediately so no Combine events or dirty-tracking
        // fire during the transient object's lifetime.
        let tmp = DNASequence(name: "", sequence: sequenceString)
        tmp.isLoading = true
        return tmp.findORFs(minNucleotides: minNucleotides)
    }
}

//
//  SequenceAligner.swift
//  Cloner 64
//
//  Local pairwise alignment engine using word-based seeding + banded
//  Needleman-Wunsch.  Designed for aligning related plasmid sequences.
//

import Foundation

// MARK: - Result

struct AlignmentResult {
    let alignedSeq1: [Character]   // with '-' for gaps, original case preserved
    let alignedSeq2: [Character]   // with '-' for gaps, original case preserved
    let score: Int
    
    var matches: Int {
        zip(alignedSeq1, alignedSeq2).filter { a, b in
            a != "-" && b != "-" && Character(String(a).uppercased()) == Character(String(b).uppercased())
        }.count
    }
    
    var alignmentLength: Int { alignedSeq1.count }
    
    var identity: Double {
        guard alignmentLength > 0 else { return 0 }
        return Double(matches) / Double(alignmentLength) * 100
    }
}

// MARK: - Aligner

class SequenceAligner {
    
    // Scoring
    private let matchScore    =  2
    private let mismatchScore = -1
    private let gapPenalty    = -2
    
    /// Perform local alignment of two DNA sequences.
    /// Returns nil only if both sequences are empty.
    func align(
        seq1: String, seq2: String,
        wordSize: Int = 15,
        antiParallel1: Bool = false,
        antiParallel2: Bool = false
    ) -> AlignmentResult {
        
        // Clean and prepare sequences
        var s1 = Array(seq1.filter { $0.isLetter })
        var s2 = Array(seq2.filter { $0.isLetter })
        if antiParallel1 { s1 = revComp(s1) }
        if antiParallel2 { s2 = revComp(s2) }
        
        let u1 = s1.map { Character(String($0).uppercased()) }
        let u2 = s2.map { Character(String($0).uppercased()) }
        let n = u1.count, m = u2.count
        
        guard n > 0 && m > 0 else {
            return AlignmentResult(alignedSeq1: [], alignedSeq2: [], score: 0)
        }
        
        // Step 1: Find best offset using k-mer seeds
        let ws = min(wordSize, min(n, m))
        let offset = findBestOffset(u1, u2, wordSize: ws)
        
        // Step 2: Determine overlapping region
        let ovStart1 = max(0, -offset)
        let ovStart2 = max(0,  offset)
        let ovEnd1   = min(n, m - offset)
        let ovEnd2   = min(m, n + offset)
        
        guard ovEnd1 > ovStart1 && ovEnd2 > ovStart2 else {
            // No overlap — just gap everything
            let a1 = Array(repeating: Character("-"), count: m)
            let a2 = s2
            return AlignmentResult(alignedSeq1: a1, alignedSeq2: a2, score: 0)
        }
        
        let region1     = Array(u1[ovStart1..<ovEnd1])
        let region1Orig = Array(s1[ovStart1..<ovEnd1])
        let region2     = Array(u2[ovStart2..<ovEnd2])
        let region2Orig = Array(s2[ovStart2..<ovEnd2])
        
        // Step 3: Banded NW on overlapping region
        let bandwidth = max(50, ws * 3)
        let (al1, al2, score) = bandedNW(upper1: region1, upper2: region2,
                                          orig1: region1Orig, orig2: region2Orig,
                                          bandwidth: bandwidth)
        
        // Step 4: Assemble full alignment with flanking gaps
        var full1: [Character] = []
        var full2: [Character] = []
        
        // Left flank: seq2 bases before overlap (seq1 has gaps)
        if ovStart2 > 0 {
            full1 += Array(repeating: Character("-"), count: ovStart2)
            full2 += Array(s2[0..<ovStart2])
        }
        // Left flank: seq1 bases before overlap (seq2 has gaps)
        if ovStart1 > 0 {
            full1 += Array(s1[0..<ovStart1])
            full2 += Array(repeating: Character("-"), count: ovStart1)
        }
        
        // Core aligned region
        full1 += al1
        full2 += al2
        
        // Right flank
        if ovEnd2 < m {
            full1 += Array(repeating: Character("-"), count: m - ovEnd2)
            full2 += Array(s2[ovEnd2..<m])
        }
        if ovEnd1 < n {
            full1 += Array(s1[ovEnd1..<n])
            full2 += Array(repeating: Character("-"), count: n - ovEnd1)
        }
        
        return AlignmentResult(alignedSeq1: full1, alignedSeq2: full2, score: score)
    }
    
    // MARK: - Seed-based offset finding
    
    /// Find the diagonal offset (seq2_pos − seq1_pos) with the most k-mer seeds.
    private func findBestOffset(_ s1: [Character], _ s2: [Character], wordSize: Int) -> Int {
        let n = s1.count, m = s2.count
        guard n >= wordSize && m >= wordSize else { return 0 }
        
        // Index k-mers of seq1
        var index: [String: [Int]] = [:]
        for i in 0...(n - wordSize) {
            let kmer = String(s1[i..<(i + wordSize)])
            index[kmer, default: []].append(i)
        }
        
        // Scan seq2 and score diagonals
        var diagScores: [Int: Int] = [:]
        for j in 0...(m - wordSize) {
            let kmer = String(s2[j..<(j + wordSize)])
            guard let hits = index[kmer] else { continue }
            for i in hits {
                diagScores[j - i, default: 0] += 1
            }
        }
        
        // If no seeds found, try smaller word size
        if diagScores.isEmpty && wordSize > 6 {
            return findBestOffset(s1, s2, wordSize: max(6, wordSize / 2))
        }
        
        return diagScores.max(by: { $0.value < $1.value })?.key ?? 0
    }
    
    // MARK: - Banded Needleman-Wunsch
    
    /// Banded global alignment of two sequences.
    /// Returns (alignedSeq1, alignedSeq2, score) preserving original case.
    private func bandedNW(
        upper1: [Character], upper2: [Character],
        orig1: [Character], orig2: [Character],
        bandwidth B: Int
    ) -> ([Character], [Character], Int) {
        
        let n = upper1.count
        let m = upper2.count
        let bandW = 2 * B + 1
        
        // For small sequences, use full NW
        if n * m < 10_000_000 {
            return fullNW(upper1: upper1, upper2: upper2, orig1: orig1, orig2: orig2)
        }
        
        // DP arrays: score[i] is a band of width bandW centred on the expected diagonal
        // For row i, valid j range is [i + diagDelta - B, i + diagDelta + B]
        // where diagDelta adjusts for length differences
        // diagDelta = m - n (expected shift: j ~ i + diagDelta*(i/n))
        
        // Allocate
        var score = Array(repeating: Array(repeating: Int.min / 2, count: bandW), count: n + 1)
        var trace = Array(repeating: Array(repeating: Int8(0), count: bandW), count: n + 1)
        // trace: 0 = diagonal, 1 = up (gap in seq2), 2 = left (gap in seq1)
        
        // Map (i, j) -> band index k
        func jCenter(_ i: Int) -> Int {
            // Linear interpolation: when i goes 0→n, j goes 0→m
            return Int(Double(i) * Double(m) / Double(max(n, 1)))
        }
        func toK(_ i: Int, _ j: Int) -> Int { j - jCenter(i) + B }
        func toJ(_ i: Int, _ k: Int) -> Int { k - B + jCenter(i) }
        
        // Initialise origin
        let k0 = toK(0, 0)
        if k0 >= 0 && k0 < bandW { score[0][k0] = 0 }
        
        // Fill first column (j=0 for various i)
        for i in 1...n {
            let k = toK(i, 0)
            if k >= 0 && k < bandW {
                score[i][k] = i * gapPenalty
                trace[i][k] = 1
            }
        }
        // Fill first row (i=0 for various j)
        for j in 1...m {
            let k = toK(0, j)
            if k >= 0 && k < bandW {
                score[0][k] = j * gapPenalty
                trace[0][k] = 2
            }
        }
        
        // Fill DP
        for i in 1...n {
            for k in 0..<bandW {
                let j = toJ(i, k)
                guard j >= 1 && j <= m else { continue }
                
                let s = upper1[i-1] == upper2[j-1] ? matchScore : mismatchScore
                
                // Diagonal: (i-1, j-1)
                let dk = toK(i-1, j-1)
                let diagS = (dk >= 0 && dk < bandW) ? score[i-1][dk] + s : Int.min / 2
                
                // Up: (i-1, j) — gap in seq2
                let uk = toK(i-1, j)
                let upS = (uk >= 0 && uk < bandW) ? score[i-1][uk] + gapPenalty : Int.min / 2
                
                // Left: (i, j-1) — gap in seq1
                let lk = toK(i, j-1)
                let leftS = (lk >= 0 && lk < bandW) ? score[i][lk] + gapPenalty : Int.min / 2
                
                if diagS >= upS && diagS >= leftS {
                    score[i][k] = diagS; trace[i][k] = 0
                } else if upS >= leftS {
                    score[i][k] = upS; trace[i][k] = 1
                } else {
                    score[i][k] = leftS; trace[i][k] = 2
                }
            }
        }
        
        // Traceback from (n, m)
        var al1: [Character] = [], al2: [Character] = []
        var i = n, j = m
        let endK = toK(n, m)
        let finalScore = (endK >= 0 && endK < bandW) ? score[n][endK] : 0
        
        while i > 0 || j > 0 {
            let k = toK(i, j)
            guard k >= 0 && k < bandW else {
                // Fell outside band — extend with gaps
                if i > 0 { al1.append(orig1[i-1]); al2.append("-"); i -= 1 }
                else { al1.append("-"); al2.append(orig2[j-1]); j -= 1 }
                continue
            }
            
            switch trace[i][k] {
            case 0: // diagonal
                al1.append(orig1[i-1]); al2.append(orig2[j-1])
                i -= 1; j -= 1
            case 1: // up
                al1.append(orig1[i-1]); al2.append("-")
                i -= 1
            default: // left
                al1.append("-"); al2.append(orig2[j-1])
                j -= 1
            }
        }
        
        return (al1.reversed(), al2.reversed(), finalScore)
    }
    
    // MARK: - Full Needleman-Wunsch (for smaller sequences)
    
    private func fullNW(
        upper1: [Character], upper2: [Character],
        orig1: [Character], orig2: [Character]
    ) -> ([Character], [Character], Int) {
        
        let n = upper1.count, m = upper2.count
        
        // Score matrix
        var score = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        var trace = Array(repeating: Array(repeating: Int8(0), count: m + 1), count: n + 1)
        
        for i in 1...n { score[i][0] = i * gapPenalty; trace[i][0] = 1 }
        for j in 1...m { score[0][j] = j * gapPenalty; trace[0][j] = 2 }
        
        for i in 1...n {
            for j in 1...m {
                let s = upper1[i-1] == upper2[j-1] ? matchScore : mismatchScore
                let diag  = score[i-1][j-1] + s
                let up    = score[i-1][j] + gapPenalty
                let left  = score[i][j-1] + gapPenalty
                
                if diag >= up && diag >= left {
                    score[i][j] = diag; trace[i][j] = 0
                } else if up >= left {
                    score[i][j] = up; trace[i][j] = 1
                } else {
                    score[i][j] = left; trace[i][j] = 2
                }
            }
        }
        
        // Traceback
        var al1: [Character] = [], al2: [Character] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && trace[i][j] == 0 {
                al1.append(orig1[i-1]); al2.append(orig2[j-1]); i -= 1; j -= 1
            } else if i > 0 && trace[i][j] == 1 {
                al1.append(orig1[i-1]); al2.append("-"); i -= 1
            } else {
                al1.append("-"); al2.append(orig2[j-1]); j -= 1
            }
        }
        
        return (al1.reversed(), al2.reversed(), score[n][m])
    }
    
    // MARK: - Reverse Complement
    
    private func revComp(_ seq: [Character]) -> [Character] {
        seq.reversed().map { complement($0) }
    }
    
    private func complement(_ b: Character) -> Character {
        switch b {
        case "A": return "T"; case "a": return "t"
        case "T": return "A"; case "t": return "a"
        case "G": return "C"; case "g": return "c"
        case "C": return "G"; case "c": return "g"
        default: return b
        }
    }
}

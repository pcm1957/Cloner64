//
//  SequenceAligner.swift
//  Cloner 64
//
//  Pairwise alignment engine: affine-gap (Gotoh) semi-global alignment
//  with free end gaps, for DNA and protein sequences.
//
//  Free end gaps mean a short fragment can "float" to its best position
//  inside a longer sequence without paying for the flanks, while the
//  affine gap model (expensive to open a gap, cheap to extend it) lets
//  long insertions such as introns come out as single clean gap blocks.
//
//  For large sequence pairs the dynamic programming is restricted to a
//  band of diagonals wide enough to contain the whole length difference
//  between the two sequences (plus padding), so intron-sized gaps always
//  fit inside the band.
//

import Foundation

// MARK: - Safe case folding for sequence characters

extension Character {
    /// Uppercase form for comparing sequence residues, guaranteed to remain a
    /// single Character.
    ///
    /// The idiom this replaces — `Character(String(c).uppercased())` — CRASHES
    /// whenever uppercasing yields more than one character, because
    /// `Character(_: String)` traps unless the string holds exactly one. The
    /// classic case is "ß", which uppercases to "SS", but ligatures such as "ﬁ"
    /// behave the same way. Those characters reach this code easily: a sequence
    /// pasted from a Word document, a PDF or a web page can carry them, and the
    /// alignment views fold case on every residue they are given.
    ///
    /// DNA and protein sequences only ever need ASCII folding, so anything that
    /// is not a lower-case ASCII letter is returned untouched — no allocation,
    /// no Unicode expansion, and no way to trap.
    var sequenceUppercased: Character {
        guard let ascii = asciiValue, ascii >= 97, ascii <= 122 else { return self }
        return Character(UnicodeScalar(ascii - 32))
    }
}

// MARK: - Alignment Mode

/// What kind of sequences are being aligned.
/// `.auto` inspects the residue composition of both sequences.
enum AlignmentMode: Hashable {
    case auto
    case dna
    case protein
}

/// How much of the sequences the alignment must cover.
/// `.fullLength` keeps both sequences end to end (free end gaps);
/// `.local` trims the result to the best-scoring shared region
/// (Smith-Waterman).
enum AlignmentScope: Hashable {
    case fullLength
    case local
}

// MARK: - Result

struct AlignmentResult {
    let alignedSeq1: [Character]   // with '-' for gaps, original case preserved
    let alignedSeq2: [Character]   // with '-' for gaps, original case preserved
    let score: Int
    /// 1-based position, in each original sequence, of the first aligned
    /// residue shown. Always 1 for full-length alignments; for local
    /// alignments it is where the trimmed region starts.
    let start1: Int
    let start2: Int
    
    var matches: Int {
        zip(alignedSeq1, alignedSeq2).filter { a, b in
            a != "-" && b != "-" && a.sequenceUppercased == b.sequenceUppercased
        }.count
    }
    
    var alignmentLength: Int { alignedSeq1.count }
    
    var identity: Double {
        guard alignmentLength > 0 else { return 0 }
        return Double(matches) / Double(alignmentLength) * 100
    }
    
    /// Total number of gapped positions across both rows.
    var gapCount: Int {
        alignedSeq1.filter { $0 == "-" }.count +
        alignedSeq2.filter { $0 == "-" }.count
    }
}

// MARK: - Aligner

class SequenceAligner {
    
    // Scoring — everything is on a x2 scale so that a gap-extension cost of
    // 0.5 stays an integer.  On the natural scale this is:
    //   DNA:     match +5, mismatch -4  (EMBOSS DNA defaults)
    //   Protein: BLOSUM62
    //   Gaps:    open 10, extend 0.5   (EMBOSS defaults)
    private let dnaMatch      =  10
    private let dnaMismatch   = -8
    private let gapOpenTotal  = -21   // total cost of a gap of length 1 (open + first extend)
    private let gapExtend     = -1    // each additional gapped position
    // Local DNA alignments use stiffer gap costs: with cheap extension,
    // Smith-Waterman profitably bridges through unrelated flanking DNA to
    // reach chance matches. Protein alphabets don't suffer from this, and
    // full-length mode needs cheap extension so introns gap out cleanly.
    private let localDNAGapOpenTotal = -24
    private let localDNAGapExtend    = -4
    
    /// Product of sequence lengths at or below which the full alignment
    /// matrix is used with no banding.
    private let fullMatrixLimit = 25_000_000
    /// Half-width padding added to the diagonal band for large alignments.
    private let bandPadding = 1_500
    
    // MARK: - Sequence type detection
    
    /// Heuristic: a sequence whose letters are less than 90% A/C/G/T/U/N
    /// is treated as protein.
    static func looksLikeProtein(_ s: String) -> Bool {
        var total = 0
        var nucleotide = 0
        for ch in s where ch.isLetter {
            total += 1
            switch ch.sequenceUppercased {
            case "A", "C", "G", "T", "U", "N": nucleotide += 1
            default: break
            }
        }
        guard total > 0 else { return false }
        return Double(nucleotide) / Double(total) < 0.9
    }
    
    // MARK: - Entry point
    
    /// Align two sequences (semi-global, free end gaps, affine gap penalties).
    /// Returns an empty alignment only if both sequences are empty.
    ///
    /// `antiParallel1` / `antiParallel2` reverse-complement the corresponding
    /// sequence first; they are ignored in protein mode.
    /// `wordSize` is only used to seed the band position for very large
    /// alignments.
    func align(
        seq1: String, seq2: String,
        wordSize: Int = 15,
        antiParallel1: Bool = false,
        antiParallel2: Bool = false,
        mode: AlignmentMode = .auto,
        scope: AlignmentScope = .fullLength
    ) -> AlignmentResult {
        
        // Resolve mode
        let isProtein: Bool
        switch mode {
        case .protein: isProtein = true
        case .dna:     isProtein = false
        case .auto:    isProtein = Self.looksLikeProtein(seq1) || Self.looksLikeProtein(seq2)
        }
        
        // Clean and prepare sequences
        var s1 = Array(seq1.filter { $0.isLetter || $0 == "*" })
        var s2 = Array(seq2.filter { $0.isLetter || $0 == "*" })
        if !isProtein {
            if antiParallel1 { s1 = revComp(s1) }
            if antiParallel2 { s2 = revComp(s2) }
        }
        
        let u1 = s1.map { $0.sequenceUppercased }
        let u2 = s2.map { $0.sequenceUppercased }
        let n = u1.count, m = u2.count
        
        guard n > 0 && m > 0 else {
            // One or both empty: align whatever exists against gaps.
            var a1: [Character] = [], a2: [Character] = []
            a1 += s1; a2 += Array(repeating: "-", count: n)
            a1 += Array(repeating: "-", count: m); a2 += s2
            return AlignmentResult(alignedSeq1: a1, alignedSeq2: a2, score: 0,
                                   start1: 1, start2: 1)
        }
        
        // Seed offset (only needed to position the band for large alignments)
        var seedOffset = 0
        if n * m > fullMatrixLimit {
            let ws = max(4, min(wordSize, min(n, m)))
            seedOffset = findBestOffset(u1, u2, wordSize: ws)
        }
        
        let (a1, a2, score, start1, start2) = gotoh(
            u1: u1, u2: u2, orig1: s1, orig2: s2,
            isProtein: isProtein, seedOffset: seedOffset,
            local: scope == .local)
        return AlignmentResult(alignedSeq1: a1, alignedSeq2: a2, score: score,
                               start1: start1, start2: start2)
    }
    
    // MARK: - Core: banded affine-gap semi-global alignment (Gotoh)
    
    /// Three-state Gotoh dynamic programming over a band of diagonals.
    /// States: M = residue aligned to residue,
    ///         X = gap in seq2 (consumes seq1),
    ///         Y = gap in seq1 (consumes seq2).
    /// End gaps are free: the alignment may start anywhere on the top/left
    /// edge and end anywhere on the bottom/right edge.
    private func gotoh(
        u1: [Character], u2: [Character],
        orig1: [Character], orig2: [Character],
        isProtein: Bool,
        seedOffset: Int,
        local: Bool
    ) -> ([Character], [Character], Int, Int, Int) {
        
        let n = u1.count, m = u2.count
        let NEG = Int.min / 4
        
        let gOpen: Int, gExt: Int
        if local && !isProtein {
            gOpen = localDNAGapOpenTotal; gExt = localDNAGapExtend
        } else {
            gOpen = gapOpenTotal; gExt = gapExtend
        }
        
        // Residue indices for protein scoring
        var idx1: [Int] = [], idx2: [Int] = []
        if isProtein {
            idx1 = u1.map { Self.blosumIndex[$0] ?? Self.unknownResidueIndex }
            idx2 = u2.map { Self.blosumIndex[$0] ?? Self.unknownResidueIndex }
        }
        
        func score(_ i: Int, _ j: Int) -> Int {
            if isProtein { return 2 * Self.blosum62[idx1[i]][idx2[j]] }
            return u1[i] == u2[j] ? dnaMatch : dnaMismatch
        }
        
        // Band over diagonals d = j - i, inclusive lo...hi.
        // The base range [min(0, m-n), max(0, m-n)] always contains the
        // whole length difference, so gaps as large as the size difference
        // between the sequences (e.g. introns) fit inside the band.
        var lo: Int, hi: Int
        if n * m <= fullMatrixLimit {
            lo = -n; hi = m                      // full matrix
        } else {
            lo = min(0, m - n, seedOffset)
            hi = max(0, m - n, seedOffset)
            var pad = bandPadding
            // Keep the traceback allocation bounded (~400 MB worst case).
            while pad > 200 && (n + 1) * (hi - lo + 2 * pad + 1) > 400_000_000 {
                pad /= 2
            }
            lo = max(lo - pad, -n)
            hi = min(hi + pad, m)
        }
        let W = hi - lo + 1
        
        func jLow(_ i: Int)  -> Int { max(0, i + lo) }
        func jHigh(_ i: Int) -> Int { min(m, i + hi) }
        
        // Rolling score rows (band-relative index k = j - i - lo; note that
        // the predecessor (i-1, j-1) sits at the SAME k in the previous row,
        // (i-1, j) at k+1 in the previous row, and (i, j-1) at k-1 in the
        // current row).
        var prevM = [Int](repeating: NEG, count: W)
        var prevX = [Int](repeating: NEG, count: W)
        var prevY = [Int](repeating: NEG, count: W)
        var curM  = [Int](repeating: NEG, count: W)
        var curX  = [Int](repeating: NEG, count: W)
        var curY  = [Int](repeating: NEG, count: W)
        
        // Traceback, one byte per band cell:
        //   bits 0-1: predecessor state of M (0 = M, 1 = X, 2 = Y)
        //   bit 2:    X extends an existing gap (else opens from M)
        //   bit 3:    Y extends an existing gap (else opens from M)
        var tb = [UInt8](repeating: 0, count: (n + 1) * W)
        
        // Best cell on the right column (j == m), captured while filling.
        var rightM = [Int](repeating: NEG, count: n + 1)
        var rightX = [Int](repeating: NEG, count: n + 1)
        var rightY = [Int](repeating: NEG, count: n + 1)
        
        // Best cell anywhere (local mode end point)
        var localBest = 0, localBestI = 0, localBestJ = 0
        
        // Row 0: free leading gaps in seq1 — start anywhere along the top edge.
        for j in jLow(0)...jHigh(0) {
            prevM[j - lo] = 0
        }
        if jHigh(0) == m { rightM[0] = prevM[m - lo] }
        
        for i in 1...n {
            for k in 0..<W { curM[k] = NEG; curX[k] = NEG; curY[k] = NEG }
            
            let jl = jLow(i), jh = jHigh(i)
            let pjl = jLow(i - 1), pjh = jHigh(i - 1)
            
            for j in jl...jh {
                let k = j - i - lo
                
                if j == 0 {
                    // Free leading gaps in seq2 — start anywhere down the left edge.
                    curM[k] = 0
                    continue
                }
                
                var cell: UInt8 = 0
                
                // M from (i-1, j-1) — previous row, same k
                if j - 1 >= pjl && j - 1 <= pjh {
                    var best = prevM[k]
                    var state: UInt8 = 0
                    if prevX[k] > best { best = prevX[k]; state = 1 }
                    if prevY[k] > best { best = prevY[k]; state = 2 }
                    let v = best + score(i - 1, j - 1)
                    if local && v < 0 {
                        // Smith-Waterman floor: a fresh alignment can start here
                        curM[k] = 0
                        cell |= 16
                    } else {
                        curM[k] = v
                        cell |= state
                        if local && v > localBest {
                            localBest = v; localBestI = i; localBestJ = j
                        }
                    }
                }
                
                // X (gap in seq2) from (i-1, j) — previous row, k+1
                if j >= pjl && j <= pjh && k + 1 < W {
                    let open   = prevM[k + 1] + gOpen
                    let extend = prevX[k + 1] + gExt
                    if extend > open { curX[k] = extend; cell |= 4 }
                    else             { curX[k] = open }
                }
                
                // Y (gap in seq1) from (i, j-1) — current row, k-1
                if j - 1 >= jl && k - 1 >= 0 {
                    let open   = curM[k - 1] + gOpen
                    let extend = curY[k - 1] + gExt
                    if extend > open { curY[k] = extend; cell |= 8 }
                    else             { curY[k] = open }
                }
                
                tb[i * W + k] = cell
            }
            
            if jh == m {
                let k = m - i - lo
                rightM[i] = curM[k]; rightX[i] = curX[k]; rightY[i] = curY[k]
            }
            
            swap(&prevM, &curM); swap(&prevX, &curX); swap(&prevY, &curY)
        }
        
        // After the loop, prev* holds row n.
        var bestScore: Int
        var endI: Int, endJ: Int, endState = 0
        
        if local {
            // Local: end at the global maximum of M anywhere in the matrix.
            if localBest <= 0 {
                return ([], [], 0, 1, 1)   // nothing scores positive
            }
            bestScore = localBest; endI = localBestI; endJ = localBestJ
        } else {
            // Full-length: best cell on the bottom row or right column
            // (trailing gaps are free).
            bestScore = NEG
            endI = n; endJ = m
            for j in jLow(n)...jHigh(n) {
                let k = j - n - lo
                let cands = [prevM[k], prevX[k], prevY[k]]
                for s in 0..<3 where cands[s] > bestScore {
                    bestScore = cands[s]; endI = n; endJ = j; endState = s
                }
            }
            for i in 0...n {
                let cands = [rightM[i], rightX[i], rightY[i]]
                for s in 0..<3 where cands[s] > bestScore {
                    bestScore = cands[s]; endI = i; endJ = m; endState = s
                }
            }
        }
        
        // Traceback
        var al1: [Character] = [], al2: [Character] = []
        var i = endI, j = endJ, state = endState
        
        if !local {
            // Free trailing gaps beyond the end cell
            var jj = m
            while jj > endJ { al1.append("-"); al2.append(orig2[jj - 1]); jj -= 1 }
            var ii = n
            while ii > endI { al1.append(orig1[ii - 1]); al2.append("-"); ii -= 1 }
        }
        
        while i > 0 && j > 0 {
            let cell = tb[i * W + (j - i - lo)]
            if local && state == 0 && (cell & 16) != 0 {
                break   // reached the start of the local alignment
            }
            switch state {
            case 0:
                al1.append(orig1[i - 1]); al2.append(orig2[j - 1])
                state = Int(cell & 3)
                i -= 1; j -= 1
            case 1:
                al1.append(orig1[i - 1]); al2.append("-")
                state = (cell & 4) != 0 ? 1 : 0
                i -= 1
            default:
                al1.append("-"); al2.append(orig2[j - 1])
                state = (cell & 8) != 0 ? 2 : 0
                j -= 1
            }
        }
        
        if local {
            return (al1.reversed(), al2.reversed(), bestScore, i + 1, j + 1)
        }
        
        // Free leading gaps back to the origin
        while j > 0 { al1.append("-"); al2.append(orig2[j - 1]); j -= 1 }
        while i > 0 { al1.append(orig1[i - 1]); al2.append("-"); i -= 1 }
        
        return (al1.reversed(), al2.reversed(), bestScore, 1, 1)
    }
    
    // MARK: - Seed-based offset finding (band positioning for large alignments)
    
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
    
    // MARK: - Similarity classification (for the protein match line)
    
    /// Classify a pair of aligned amino acids the way ClustalW does:
    /// "*" identical, ":" conservative (BLOSUM62 > 0),
    /// "." semi-conservative (BLOSUM62 = 0), " " otherwise.
    /// Gap columns are the caller's responsibility.
    static func proteinMatchSymbol(_ a: Character, _ b: Character) -> Character {
        let aa = a.sequenceUppercased
        let bb = b.sequenceUppercased
        if aa == bb { return "*" }
        let i = blosumIndex[aa] ?? unknownResidueIndex
        let j = blosumIndex[bb] ?? unknownResidueIndex
        let s = blosum62[i][j]
        if s > 0 { return ":" }
        if s == 0 { return "." }
        return " "
    }
    
    // MARK: - BLOSUM62 (protein scoring)
    
    /// Residue order for the BLOSUM62 matrix below.
    private static let blosumOrder: [Character] = Array("ARNDCQEGHILKMFPSTWYVBZX*")
    private static let blosumIndex: [Character: Int] = {
        var d: [Character: Int] = [:]
        for (i, c) in blosumOrder.enumerated() { d[c] = i }
        return d
    }()
    /// Index of "X" (unknown residue) in blosumOrder.
    private static let unknownResidueIndex = 22

    /// BLOSUM62 substitution matrix (half-bit units), 24x24,
    /// values taken verbatim from the NCBI/Biopython BLOSUM62 data file.
    private static let blosum62: [[Int]] = [
        [  4,  -1,  -2,  -2,   0,  -1,  -1,   0,  -2,  -1,  -1,  -1,  -1,  -2,  -1,   1,   0,  -3,  -2,   0,  -2,  -1,   0,  -4],  // A
        [ -1,   5,   0,  -2,  -3,   1,   0,  -2,   0,  -3,  -2,   2,  -1,  -3,  -2,  -1,  -1,  -3,  -2,  -3,  -1,   0,  -1,  -4],  // R
        [ -2,   0,   6,   1,  -3,   0,   0,   0,   1,  -3,  -3,   0,  -2,  -3,  -2,   1,   0,  -4,  -2,  -3,   3,   0,  -1,  -4],  // N
        [ -2,  -2,   1,   6,  -3,   0,   2,  -1,  -1,  -3,  -4,  -1,  -3,  -3,  -1,   0,  -1,  -4,  -3,  -3,   4,   1,  -1,  -4],  // D
        [  0,  -3,  -3,  -3,   9,  -3,  -4,  -3,  -3,  -1,  -1,  -3,  -1,  -2,  -3,  -1,  -1,  -2,  -2,  -1,  -3,  -3,  -2,  -4],  // C
        [ -1,   1,   0,   0,  -3,   5,   2,  -2,   0,  -3,  -2,   1,   0,  -3,  -1,   0,  -1,  -2,  -1,  -2,   0,   3,  -1,  -4],  // Q
        [ -1,   0,   0,   2,  -4,   2,   5,  -2,   0,  -3,  -3,   1,  -2,  -3,  -1,   0,  -1,  -3,  -2,  -2,   1,   4,  -1,  -4],  // E
        [  0,  -2,   0,  -1,  -3,  -2,  -2,   6,  -2,  -4,  -4,  -2,  -3,  -3,  -2,   0,  -2,  -2,  -3,  -3,  -1,  -2,  -1,  -4],  // G
        [ -2,   0,   1,  -1,  -3,   0,   0,  -2,   8,  -3,  -3,  -1,  -2,  -1,  -2,  -1,  -2,  -2,   2,  -3,   0,   0,  -1,  -4],  // H
        [ -1,  -3,  -3,  -3,  -1,  -3,  -3,  -4,  -3,   4,   2,  -3,   1,   0,  -3,  -2,  -1,  -3,  -1,   3,  -3,  -3,  -1,  -4],  // I
        [ -1,  -2,  -3,  -4,  -1,  -2,  -3,  -4,  -3,   2,   4,  -2,   2,   0,  -3,  -2,  -1,  -2,  -1,   1,  -4,  -3,  -1,  -4],  // L
        [ -1,   2,   0,  -1,  -3,   1,   1,  -2,  -1,  -3,  -2,   5,  -1,  -3,  -1,   0,  -1,  -3,  -2,  -2,   0,   1,  -1,  -4],  // K
        [ -1,  -1,  -2,  -3,  -1,   0,  -2,  -3,  -2,   1,   2,  -1,   5,   0,  -2,  -1,  -1,  -1,  -1,   1,  -3,  -1,  -1,  -4],  // M
        [ -2,  -3,  -3,  -3,  -2,  -3,  -3,  -3,  -1,   0,   0,  -3,   0,   6,  -4,  -2,  -2,   1,   3,  -1,  -3,  -3,  -1,  -4],  // F
        [ -1,  -2,  -2,  -1,  -3,  -1,  -1,  -2,  -2,  -3,  -3,  -1,  -2,  -4,   7,  -1,  -1,  -4,  -3,  -2,  -2,  -1,  -2,  -4],  // P
        [  1,  -1,   1,   0,  -1,   0,   0,   0,  -1,  -2,  -2,   0,  -1,  -2,  -1,   4,   1,  -3,  -2,  -2,   0,   0,   0,  -4],  // S
        [  0,  -1,   0,  -1,  -1,  -1,  -1,  -2,  -2,  -1,  -1,  -1,  -1,  -2,  -1,   1,   5,  -2,  -2,   0,  -1,  -1,   0,  -4],  // T
        [ -3,  -3,  -4,  -4,  -2,  -2,  -3,  -2,  -2,  -3,  -2,  -3,  -1,   1,  -4,  -3,  -2,  11,   2,  -3,  -4,  -3,  -2,  -4],  // W
        [ -2,  -2,  -2,  -3,  -2,  -1,  -2,  -3,   2,  -1,  -1,  -2,  -1,   3,  -3,  -2,  -2,   2,   7,  -1,  -3,  -2,  -1,  -4],  // Y
        [  0,  -3,  -3,  -3,  -1,  -2,  -2,  -3,  -3,   3,   1,  -2,   1,  -1,  -2,  -2,   0,  -3,  -1,   4,  -3,  -2,  -1,  -4],  // V
        [ -2,  -1,   3,   4,  -3,   0,   1,  -1,   0,  -3,  -4,   0,  -3,  -3,  -2,   0,  -1,  -4,  -3,  -3,   4,   1,  -1,  -4],  // B
        [ -1,   0,   0,   1,  -3,   3,   4,  -2,   0,  -3,  -3,   1,  -1,  -3,  -1,   0,  -1,  -3,  -2,  -2,   1,   4,  -1,  -4],  // Z
        [  0,  -1,  -1,  -1,  -2,  -1,  -1,  -1,  -1,  -1,  -1,  -1,  -1,  -1,  -2,   0,   0,  -2,  -1,  -1,  -1,  -1,  -1,  -4],  // X
        [ -4,  -4,  -4,  -4,  -4,  -4,  -4,  -4,  -4,  -4,  -4,  -4,  -4,  -4,  -4,  -4,  -4,  -4,  -4,  -4,  -4,  -4,  -4,   1],  // *
    ]
}

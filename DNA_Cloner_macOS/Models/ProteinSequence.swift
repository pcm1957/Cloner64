//
//  ProteinSequence.swift
//  Cloner 64
//
//  Model for protein sequences (loaded from XPRT files, etc.)
//

import Foundation
import Combine
import SwiftUI

/// A protein sequence with features, analogous to DNASequence for DNA
class ProteinSequence: ObservableObject, Identifiable {
    let id = UUID()
    
    @Published var name: String
    @Published var sequence: String   // single-letter amino acid codes
    @Published var description: String = ""
    @Published var features: [Feature] = []
    @Published var isCircular: Bool = false
    @Published var isDirty: Bool = false
    
    var sourceURL: URL?
    
    var length: Int { sequence.count }
    
    init(name: String, sequence: String, isCircular: Bool = false) {
        self.name = name
        self.sequence = sequence
        self.isCircular = isCircular
    }
    
    // MARK: - Molecular Weight
    
    /// Average molecular weights of amino acids (monoisotopic residue masses)
    private static let residueMW: [Character: Double] = [
        "A":  71.03711, "R": 156.10111, "N": 114.04293, "D": 115.02694,
        "C": 103.00919, "E": 129.04259, "Q": 128.05858, "G":  57.02146,
        "H": 137.05891, "I": 113.08406, "L": 113.08406, "K": 128.09496,
        "M": 131.04049, "F": 147.06841, "P":  97.05276, "S":  87.03203,
        "T": 101.04768, "W": 186.07931, "Y": 163.06333, "V":  99.06841,
    ]
    
    /// Average molecular weights (used for display — more common in biochemistry)
    private static let avgResidueMW: [Character: Double] = [
        "A":  71.0788, "R": 156.1875, "N": 114.1038, "D": 115.0886,
        "C": 103.1388, "E": 129.1155, "Q": 128.1307, "G":  57.0519,
        "H": 137.1411, "I": 113.1594, "L": 113.1594, "K": 128.1741,
        "M": 131.1926, "F": 147.1766, "P":  97.1167, "S":  87.0782,
        "T": 101.1051, "W": 186.2132, "Y": 163.1760, "V":  99.1326,
    ]
    
    /// Calculate average molecular weight in Daltons
    var molecularWeight: Double {
        let upper = sequence.uppercased()
        var mw = 18.0153  // water molecule (H2O added once for the full chain)
        for aa in upper {
            mw += Self.avgResidueMW[aa] ?? 0.0
        }
        return mw
    }
    
    /// Formatted MW string
    var formattedMW: String {
        let mw = molecularWeight
        if mw > 1000 {
            return String(format: "%.2f kDa", mw / 1000.0)
        }
        return String(format: "%.1f Da", mw)
    }
    
    // MARK: - Isoelectric Point (pI)
    
    /// pK values for charged amino acids (EMBOSS pKa scale)
    private static let pKNterm  = 8.6
    private static let pKCterm  = 3.6
    private static let pKvalues: [Character: Double] = [
        "D": 3.9,   // Asp
        "E": 4.1,   // Glu
        "C": 8.5,   // Cys
        "Y": 10.1,  // Tyr
        "H": 6.5,   // His
        "K": 10.8,  // Lys
        "R": 12.5,  // Arg
    ]
    
    /// Estimate isoelectric point using Henderson-Hasselbalch bisection
    var isoelectricPoint: Double {
        let upper = sequence.uppercased()
        
        // Count charged residues
        var counts: [Character: Int] = [:]
        for aa in upper {
            if Self.pKvalues[aa] != nil {
                counts[aa, default: 0] += 1
            }
        }
        
        func chargeAtPH(_ pH: Double) -> Double {
            // N-terminus (positive)
            var charge = 1.0 / (1.0 + pow(10, pH - Self.pKNterm))
            // C-terminus (negative)
            charge -= 1.0 / (1.0 + pow(10, Self.pKCterm - pH))
            
            // Positive residues: K, R, H
            for aa: Character in ["K", "R", "H"] {
                let n = Double(counts[aa] ?? 0)
                if n > 0, let pK = Self.pKvalues[aa] {
                    charge += n / (1.0 + pow(10, pH - pK))
                }
            }
            // Negative residues: D, E, C, Y
            for aa: Character in ["D", "E", "C", "Y"] {
                let n = Double(counts[aa] ?? 0)
                if n > 0, let pK = Self.pKvalues[aa] {
                    charge -= n / (1.0 + pow(10, pK - pH))
                }
            }
            return charge
        }
        
        // Bisection search
        var low = 0.0
        var high = 14.0
        for _ in 0..<200 {
            let mid = (low + high) / 2.0
            if chargeAtPH(mid) > 0 {
                low = mid
            } else {
                high = mid
            }
        }
        return (low + high) / 2.0
    }
    
    var formattedPI: String {
        String(format: "%.2f", isoelectricPoint)
    }
    
    // MARK: - Amino Acid Composition
    
    /// Returns sorted array of (amino acid, count, percentage)
    var composition: [(aa: String, count: Int, percent: Double)] {
        let upper = sequence.uppercased()
        var counts: [Character: Int] = [:]
        for aa in upper {
            counts[aa, default: 0] += 1
        }
        let total = Double(upper.count)
        return counts.sorted { $0.key < $1.key }.map { (aa, count) in
            (String(aa), count, total > 0 ? Double(count) / total * 100.0 : 0.0)
        }
    }
    
    // MARK: - Extinction Coefficient (280 nm)
    
    /// Estimated molar extinction coefficient at 280 nm (Pace et al.)
    /// Assumes all Cys form cystines (disulfide bonds)
    var extinctionCoefficient: Double {
        let upper = sequence.uppercased()
        let nW = upper.filter { $0 == "W" }.count
        let nY = upper.filter { $0 == "Y" }.count
        let nC = upper.filter { $0 == "C" }.count
        // Pace et al. values
        return Double(nW) * 5500.0 + Double(nY) * 1490.0 + Double(nC / 2) * 125.0
    }
}

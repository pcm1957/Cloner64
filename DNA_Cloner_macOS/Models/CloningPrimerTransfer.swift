import Foundation

// MARK: - Cloning Primer Transfer
//
// Pre-configures PrimerDesignView when opened from Predictive Cloning.
// Similar to PCRPrimerTransfer but sets the template, target region,
// and 5' RE site tails for both primers.

class CloningPrimerTransfer {
    static let shared = CloningPrimerTransfer()
    
    /// ID of the insert sequence to use as template
    var templateSequenceID: UUID?
    
    /// Target region = entire insert (1-based)
    var targetStart: Int?
    var targetEnd: Int?
    
    /// Enzyme names for the 5' tails
    var fwdEnzymeName: String?
    var revEnzymeName: String?
    
    /// Protective padding base count (default 4 for most enzymes)
    var fwdPaddingBases: Int = 4
    var revPaddingBases: Int = 4
    
    var hasPendingTransfer: Bool {
        templateSequenceID != nil
    }
    
    func clear() {
        templateSequenceID = nil
        targetStart = nil
        targetEnd = nil
        fwdEnzymeName = nil
        revEnzymeName = nil
        fwdPaddingBases = 4
        revPaddingBases = 4
    }
}

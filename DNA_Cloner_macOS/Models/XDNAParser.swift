//
//  XDNAParser.swift
//  Cloner 64
//

import Foundation
import SwiftUI

final class XDNAParser {
    
    // Option to automatically convert imported sequences to uppercase
    var convertToUppercaseOnImport: Bool = false

    // MARK: - Public API

    func parseXDNA(_ url: URL) -> DNASequence? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            #if DEBUG
            print("❌ Could not read file")
            #endif
            return nil
        }

        return parseXDNAData(data, filename: url.deletingPathExtension().lastPathComponent)
    }
    
    /// Parse an XPRT (protein) file — same binary format as XDNA but sequence type = 4
    func parseXPRT(_ url: URL) -> ProteinSequence? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            #if DEBUG
            print("❌ Could not read XPRT file")
            #endif
            return nil
        }

        return parseXPRTData(data, filename: url.deletingPathExtension().lastPathComponent)
    }
    
    /// Check if binary data looks like a protein sequence (type byte = 4)
    func isProteinFormat(_ data: Data) -> Bool {
        guard data.count >= 112 else { return false }
        return data[1] == 4  // type byte: 4 = protein
    }

    func writeXDNA(_ sequence: DNASequence, to url: URL) -> Bool {
        let data = generateXDNA(sequence)
        do {
            try data.write(to: url)
            return true
        } catch {
            #if DEBUG
            print("❌ Failed to write XDNA:", error)
            #endif
            return false
        }
    }
    
    func writeXPRT(_ protein: ProteinSequence, to url: URL) -> Bool {
        let data = generateXPRT(protein)
        do {
            try data.write(to: url)
            return true
        } catch {
            #if DEBUG
            print("❌ Failed to write XPRT:", error)
            #endif
            return false
        }
    }

    // MARK: - Parsing

    func parseXDNAData(_ data: Data, filename: String) -> DNASequence? {
        guard data.count >= 112 else {
            #if DEBUG
            print("❌ File too small for XDNA header")
            #endif
            return nil
        }

        let topology = data[2]
        let sequenceLength = Int(data.readBigEndianInt32(at: 28))
        let rawCommentLength = Int(data.readBigEndianInt32(at: 96))

        guard sequenceLength > 0 else {
            #if DEBUG
            print("❌ Invalid sequence length")
            #endif
            return nil
        }

        let sequenceStart = 112
        let sequenceEnd = sequenceStart + sequenceLength

        guard sequenceEnd <= data.count else {
            #if DEBUG
            print("❌ Sequence overruns file")
            #endif
            return nil
        }

        let sequenceData = data[sequenceStart..<sequenceEnd]

        guard sequenceData.allSatisfy({ $0 < 0x80 }) else {
            #if DEBUG
            print("❌ Non-ASCII byte in sequence")
            #endif
            return nil
        }

        guard let sequenceString = String(data: sequenceData, encoding: .ascii) else {
            return nil
        }

        // Analyze case distribution
        let uppercaseCount = sequenceString.filter { $0.isUppercase }.count
        let lowercaseCount = sequenceString.filter { $0.isLowercase }.count
        
        #if DEBUG
        print("📖 XDNA import: \(filename)")
        print("   Sequence length: \(sequenceString.count) bp")
        print("   Uppercase: \(uppercaseCount), Lowercase: \(lowercaseCount)")
        #endif
        
        if uppercaseCount > 0 && lowercaseCount > 0 {
            #if DEBUG
            print("   ✓ Mixed case detected (typical: uppercase=exons, lowercase=introns)")
            #endif
        } else if uppercaseCount > 0 {
            #if DEBUG
            print("   ✓ All uppercase")
            #endif
        } else if lowercaseCount > 0 {
            #if DEBUG
            print("   ✓ All lowercase (may be intronic/non-coding)")
            #endif
        }
        
        // Show preview
        let preview = String(sequenceString.prefix(50))
        #if DEBUG
        print("   Preview: \(preview)")
        #endif
        
        // Apply case conversion if requested
        var finalSequence = sequenceString
        if convertToUppercaseOnImport && lowercaseCount > 0 {
            finalSequence = sequenceString.uppercased()
            #if DEBUG
            print("   ⚠️  Converted to uppercase (convertToUppercaseOnImport = true)")
            #endif
        } else {
            #if DEBUG
            print("   ✓ Preserving original case")
            #endif
        }

        // Validate but preserve case
        let validChars = Set("ACGTURYSWKMBDHVNacgturyswkmbdhvn")
        let invalid = Set(finalSequence.filter { !validChars.contains($0) })
        if !invalid.isEmpty {
            #if DEBUG
            print("⚠️ Invalid bases found:", invalid)
            #endif
        }

        let commentLength = max(0, min(rawCommentLength, data.count - sequenceEnd))
        let description: String
        if commentLength > 0 {
            let commentData = data[sequenceEnd..<sequenceEnd + commentLength]
            description = String(data: commentData, encoding: .utf8)
                ?? String(data: commentData, encoding: .ascii) ?? ""
        } else {
            description = ""
        }

        let annotationStart = sequenceEnd + commentLength
        let features = annotationStart < data.count
            ? parseFeatures(data: data, startOffset: annotationStart)
            : []

        let sequence = DNASequence(
            name: filename,
            sequence: finalSequence,
            isCircular: topology == 1
        )

        sequence.description = description
        sequence.features = features

        return sequence
    }
    
    // MARK: - XPRT Protein Parsing
    
    func parseXPRTData(_ data: Data, filename: String) -> ProteinSequence? {
        guard data.count >= 112 else {
            #if DEBUG
            print("❌ File too small for XPRT header")
            #endif
            return nil
        }

        let seqType = data[1]   // 4 = protein
        let topology = data[2]
        let sequenceLength = Int(data.readBigEndianInt32(at: 28))
        let rawCommentLength = Int(data.readBigEndianInt32(at: 96))

        guard sequenceLength > 0 else {
            #if DEBUG
            print("❌ Invalid sequence length")
            #endif
            return nil
        }
        
        // Accept type 4 (protein) explicitly, but also try parsing if type is unexpected
        if seqType != 4 {
            #if DEBUG
            print("⚠️ XPRT type byte is \(seqType) (expected 4 for protein), attempting parse anyway")
            #endif
        }

        let sequenceStart = 112
        let sequenceEnd = sequenceStart + sequenceLength

        guard sequenceEnd <= data.count else {
            #if DEBUG
            print("❌ Sequence overruns file")
            #endif
            return nil
        }

        let sequenceData = data[sequenceStart..<sequenceEnd]

        guard let sequenceString = String(data: sequenceData, encoding: .ascii) else {
            #if DEBUG
            print("❌ Could not decode sequence as ASCII")
            #endif
            return nil
        }
        
        // Validate as amino acid sequence
        let validAA = Set("ACDEFGHIKLMNPQRSTVWYXBZJUOacdefghiklmnpqrstvwyxbzjuo*-")
        let invalid = Set(sequenceString.filter { !validAA.contains($0) })
        if !invalid.isEmpty {
            #if DEBUG
            print("⚠️ Non-standard characters in protein sequence: \(invalid)")
            #endif
        }

        #if DEBUG
        print("📖 XPRT import: \(filename)")
        print("   Protein length: \(sequenceString.count) aa")
        print("   Preview: \(String(sequenceString.prefix(50)))")
        #endif

        let commentLength = max(0, min(rawCommentLength, data.count - sequenceEnd))
        let desc: String
        if commentLength > 0 {
            let commentData = data[sequenceEnd..<sequenceEnd + commentLength]
            desc = String(data: commentData, encoding: .utf8)
                ?? String(data: commentData, encoding: .ascii) ?? ""
        } else {
            desc = ""
        }

        let annotationStart = sequenceEnd + commentLength
        let features = annotationStart < data.count
            ? parseFeatures(data: data, startOffset: annotationStart)
            : []

        let protein = ProteinSequence(
            name: filename,
            sequence: sequenceString.uppercased(),
            isCircular: topology == 1
        )

        protein.description = desc
        protein.features = features

        return protein
    }

    // MARK: - Feature Parsing

    private func parseFeatures(data: Data, startOffset: Int) -> [Feature] {
        var features: [Feature] = []
        var offset = startOffset

        guard offset < data.count else { return features }

        offset += 1 // unknown byte
        skipPascalPair(data: data, offset: &offset)
        skipPascalPair(data: data, offset: &offset)

        guard offset < data.count else { return features }
        let count = Int(data[offset])
        offset += 1

        for _ in 0..<count {
            guard let feature = parseFeature(data: data, offset: &offset) else { break }
            features.append(feature)
        }

        return features
    }

    private func skipPascalPair(data: Data, offset: inout Int) {
        if let first = data.readPascalString(at: offset) {
            offset += 1 + first.0.count
            if let second = data.readPascalString(at: offset) {
                offset += 1 + second.0.count
            }
        }
    }

    private func parseFeature(data: Data, offset: inout Int) -> Feature? {
        func read() -> String? {
            guard let val = data.readPascalString(at: offset) else { return nil }
            offset += 1 + val.0.count
            return val.1
        }

        guard let name = read() else { return nil }
        _ = read() // description (ignored)
        guard
            let type = read(),
            let startStr = read(),
            let endStr = read(),
            let colorStr = read(),
            let start = Int(startStr),
            let end = Int(endStr),
            offset + 4 <= data.count
        else { return nil }

        let strand: Strand = data[offset] != 0 ? .forward : .reverse
        offset += 4

        return Feature(
            name: name,
            type: mapFeatureType(type),
            start: start,
            end: end,
            strand: strand,
            color: parseColor(colorStr)
        )
    }

    // MARK: - Writing

    private func generateXDNA(_ sequence: DNASequence) -> Data {
        var data = Data()
        var header = Data(count: 112)

        header[0] = 0x00
        header[1] = 0x01
        header[2] = sequence.isCircular ? 0x01 : 0x00

        let seqLength = UInt32(sequence.sequence.utf8.count)
        header.writeUInt32(seqLength, at: 28)

        let commentData = sequence.description.data(using: .utf8) ?? Data()
        header.writeUInt32(UInt32(commentData.count), at: 96)

        header[111] = 0xFF

        data.append(header)
        data.append(sequence.sequence.data(using: .ascii)!)
        data.append(commentData)

        if !sequence.features.isEmpty {
            data.append(generateFeaturesSection(sequence.features))
        }

        return data
    }

    private func generateXPRT(_ protein: ProteinSequence) -> Data {
        var data = Data()
        var header = Data(count: 112)

        header[0] = 0x00       // version
        header[1] = 0x04       // type = 4 (protein)
        header[2] = protein.isCircular ? 0x01 : 0x00

        let seqLength = UInt32(protein.sequence.utf8.count)
        header.writeUInt32(seqLength, at: 28)

        let commentData = protein.description.data(using: .utf8) ?? Data()
        header.writeUInt32(UInt32(commentData.count), at: 96)

        header[111] = 0xFF

        data.append(header)
        data.append(protein.sequence.data(using: .ascii)!)
        data.append(commentData)

        if !protein.features.isEmpty {
            data.append(generateFeaturesSection(protein.features))
        }

        return data
    }

    private func generateFeaturesSection(_ features: [Feature]) -> Data {
        var data = Data()
        data.append(0x00)                      // unknown byte
        // Two pascal string pairs (4 strings total) — matches parseFeatures expectations
        data.append(contentsOf: [0x01, 0x30])  // pair 1, string 1: "0"
        data.append(contentsOf: [0x01, 0x30])  // pair 1, string 2: "0"
        data.append(contentsOf: [0x01, 0x30])  // pair 2, string 1: "0"
        data.append(contentsOf: [0x01, 0x30])  // pair 2, string 2: "0"
        data.append(UInt8(min(features.count, 255)))

        for feature in features.prefix(255) {
            data.append(generateFeature(feature))
        }

        return data
    }

    private func generateFeature(_ feature: Feature) -> Data {
        var data = Data()

        data.append(feature.name.toPascalString())
        data.append("".toPascalString())
        data.append(feature.type.rawValue.toPascalString())
        data.append(String(feature.start).toPascalString())
        data.append(String(feature.end).toPascalString())

        let r = Int(feature.color.red * 255)
        let g = Int(feature.color.green * 255)
        let b = Int(feature.color.blue * 255)
        data.append("\(r),\(g),\(b)".toPascalString())

        data.append(feature.strand == .forward ? 0x01 : 0x00)
        data.append(0x01)
        data.append(0x00)
        data.append(0x01)

        return data
    }

    // MARK: - Helpers

    private func parseColor(_ string: String) -> CodableColor {
        let c = string.split(separator: ",").compactMap { Int($0) }
        guard c.count >= 3 else { return CodableColor(Color.blue) }

        return CodableColor(Color(
            red: Double(c[0]) / 255,
            green: Double(c[1]) / 255,
            blue: Double(c[2]) / 255
        ))
    }

    private func mapFeatureType(_ type: String) -> FeatureType {
        switch type.lowercased() {
        case "promoter": return .promoter
        case "gene": return .gene
        case "cds", "coding": return .cds
        case "terminator": return .terminator
        case "origin", "ori": return .origin
        case "marker", "resistance": return .selectionMarker
        case "primer", "primer binding", "primer_bind": return .primerBinding
        default: return .custom
        }
    }
}

// MARK: - Data Extensions

extension Data {

    func readBigEndianInt32(at offset: Int) -> Int32 {
        guard offset + 4 <= count else { return 0 }
        return (Int32(self[offset]) << 24)
             | (Int32(self[offset + 1]) << 16)
             | (Int32(self[offset + 2]) << 8)
             | Int32(self[offset + 3])
    }

    mutating func writeUInt32(_ value: UInt32, at offset: Int) {
        self[offset]     = UInt8((value >> 24) & 0xFF)
        self[offset + 1] = UInt8((value >> 16) & 0xFF)
        self[offset + 2] = UInt8((value >> 8) & 0xFF)
        self[offset + 3] = UInt8(value & 0xFF)
    }

    func readPascalString(at offset: Int) -> (Data, String)? {
        guard offset < count else { return nil }
        let length = Int(self[offset])
        guard offset + 1 + length <= count else { return nil }

        let data = self[(offset + 1)..<(offset + 1 + length)]
        guard let string = String(data: data, encoding: .ascii) else { return nil }
        return (data, string)
    }
}

// MARK: - String Extension

extension String {
    func toPascalString() -> Data {
        let bytes = self.data(using: .ascii) ?? Data()
        let length = min(bytes.count, 255)
        var data = Data([UInt8(length)])
        data.append(bytes.prefix(length))
        return data
    }
}

//
//  SnapGeneParser.swift
//  Cloner 64
//
//  Parser for SnapGene .dna binary format.
//  Based on the reverse-engineered specification by Damien Goutte-Gattat
//  (incenp.org/dvlpt/docs/binary-sequence-formats) and the Biopython
//  SnapGeneIO implementation.
//
//  Format summary:
//    A .dna file is a sequence of TLV packets:
//      - 1 byte:  packet tag
//      - 4 bytes: big-endian data length
//      - N bytes: data
//
//  Packet types used here:
//    0x09  Cookie  – magic "SnapGene" identifier (must be first)
//    0x00  DNA     – flag byte + ASCII sequence
//    0x06  Notes   – XML metadata (type, description, comments, dates)
//    0x0A  Features – XML feature annotations
//    0x05  Primers  – XML primer annotations (imported as primer_bind features)
//

import Foundation
import SwiftUI

final class SnapGeneParser {

    // MARK: - Public API

    func parseSnapGene(_ url: URL) -> DNASequence? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            #if DEBUG
            print("❌ SnapGene: Could not read file")
            #endif
            return nil
        }

        return parseSnapGeneData(data, filename: url.deletingPathExtension().lastPathComponent)
    }

    /// Quick check: does this data start with the SnapGene magic cookie?
    static func isSnapGeneFile(_ data: Data) -> Bool {
        guard data.count >= 14 else { return false }
        // Tag 0x09, then 4-byte length (14), then "SnapGene"
        return data[0] == 0x09
            && data.subdata(in: 5..<13) == "SnapGene".data(using: .ascii)
    }

    // MARK: - Parsing

    func parseSnapGeneData(_ data: Data, filename: String) -> DNASequence? {

        // --- 1. Validate cookie packet ---
        guard data.count >= 14, data[0] == 0x09 else {
            #if DEBUG
            print("❌ SnapGene: Missing cookie packet")
            #endif
            return nil
        }
        let cookieLen = readUInt32(data, at: 1)
        guard cookieLen == 14,
              data.subdata(in: 5..<13) == "SnapGene".data(using: .ascii) else {
            #if DEBUG
            print("❌ SnapGene: Invalid cookie")
            #endif
            return nil
        }

        // --- 2. Walk remaining packets ---
        var sequenceString: String?
        var isCircular = false
        var features: [Feature] = []
        var descriptionText = ""

        var offset = 5 + Int(cookieLen)  // skip past cookie packet

        while offset + 5 <= data.count {
            let tag = data[offset]
            let packetLen = Int(readUInt32(data, at: offset + 1))
            let packetStart = offset + 5

            guard packetStart + packetLen <= data.count else {
                #if DEBUG
                print("⚠️ SnapGene: Packet at offset \(offset) overruns file, stopping")
                #endif
                break
            }

            let packetData = data.subdata(in: packetStart..<(packetStart + packetLen))

            switch tag {
            case 0x00:  // DNA packet
                guard packetLen >= 2 else { break }
                let flags = packetData[0]
                isCircular = (flags & 0x01) != 0
                let seqBytes = packetData.subdata(in: 1..<packetLen)
                sequenceString = String(data: seqBytes, encoding: .ascii)

            case 0x06:  // Notes packet (XML)
                descriptionText = parseNotesPacket(packetData)

            case 0x0A:  // Features packet (XML)
                features.append(contentsOf: parseFeaturesPacket(packetData))

            case 0x05:  // Primers packet (XML)
                features.append(contentsOf: parsePrimersPacket(packetData))

            default:
                break  // skip unknown packets
            }

            offset = packetStart + packetLen
        }

        // --- 3. Build DNASequence ---
        guard let seq = sequenceString, !seq.isEmpty else {
            #if DEBUG
            print("❌ SnapGene: No DNA sequence found in file")
            #endif
            return nil
        }

        #if DEBUG
        print("📖 SnapGene import: \(filename)")
        print("   Sequence length: \(seq.count) bp")
        print("   Topology: \(isCircular ? "circular" : "linear")")
        print("   Features: \(features.count)")
        print("   Preview: \(String(seq.prefix(50)))")
        #endif

        let dnaSequence = DNASequence(
            name: filename,
            sequence: seq.uppercased(),
            isCircular: isCircular
        )
        dnaSequence.description = descriptionText
        dnaSequence.features = features

        return dnaSequence
    }

    // MARK: - Notes Packet (tag 0x06)

    /// Extracts description/comments from the Notes XML.
    private func parseNotesPacket(_ data: Data) -> String {
        guard let xmlString = String(data: data, encoding: .utf8) else { return "" }

        guard let xmlDoc = try? XMLDocument(xmlString: xmlString, options: []) else {
            // Fallback: try to extract plain text between tags
            return extractTagContent(xmlString, tag: "Description")
                ?? extractTagContent(xmlString, tag: "Comments")
                ?? ""
        }

        var parts: [String] = []

        if let typeNode = try? xmlDoc.nodes(forXPath: "//Type").first?.stringValue,
           !typeNode.isEmpty {
            parts.append("Type: \(typeNode)")
        }

        if let desc = try? xmlDoc.nodes(forXPath: "//Description").first?.stringValue,
           !desc.isEmpty {
            parts.append(stripHTML(desc))
        }

        if let comments = try? xmlDoc.nodes(forXPath: "//Comments").first?.stringValue,
           !comments.isEmpty {
            parts.append(stripHTML(comments))
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - Features Packet (tag 0x0A)

    private func parseFeaturesPacket(_ data: Data) -> [Feature] {
        guard let xmlString = String(data: data, encoding: .utf8) else { return [] }

        guard let xmlDoc = try? XMLDocument(xmlString: xmlString, options: []) else {
            #if DEBUG
            print("⚠️ SnapGene: Could not parse Features XML")
            #endif
            return []
        }

        var features: [Feature] = []

        guard let featureNodes = try? xmlDoc.nodes(forXPath: "//Feature") else { return [] }

        for node in featureNodes {
            guard let element = node as? XMLElement else { continue }

            let name = element.attribute(forName: "name")?.stringValue ?? "unnamed"
            let typeStr = element.attribute(forName: "type")?.stringValue ?? "misc_feature"
            let dirStr = element.attribute(forName: "directionality")?.stringValue ?? "0"

            let strand: Strand
            switch dirStr {
            case "2":  strand = .reverse
            default:   strand = .forward  // 0, 1, 3 all treated as forward
            }

            // Parse segment ranges — a feature can span multiple segments
            guard let segments = try? element.nodes(forXPath: "Segment") else { continue }

            var minStart = Int.max
            var maxEnd = 0

            for seg in segments {
                guard let segElem = seg as? XMLElement,
                      let rangeStr = segElem.attribute(forName: "range")?.stringValue else { continue }

                let parts = rangeStr.split(separator: "-")
                guard parts.count == 2,
                      let s = Int(parts[0]),
                      let e = Int(parts[1]) else { continue }

                minStart = min(minStart, s)
                maxEnd = max(maxEnd, e)
            }

            guard minStart != Int.max, maxEnd > 0 else { continue }

            // Extract color from Segment node (attribute "color") if present
            let color = extractFeatureColor(element) ?? defaultColor(for: typeStr)

            let feature = Feature(
                name: name,
                type: mapFeatureType(typeStr),
                start: minStart,
                end: maxEnd,
                strand: strand,
                color: color
            )
            features.append(feature)
        }

        return features
    }

    // MARK: - Primers Packet (tag 0x05)

    private func parsePrimersPacket(_ data: Data) -> [Feature] {
        guard let xmlString = String(data: data, encoding: .utf8) else { return [] }

        guard let xmlDoc = try? XMLDocument(xmlString: xmlString, options: []) else { return [] }

        var features: [Feature] = []

        guard let primerNodes = try? xmlDoc.nodes(forXPath: "//Primer") else { return [] }

        for node in primerNodes {
            guard let element = node as? XMLElement else { continue }

            let name = element.attribute(forName: "name")?.stringValue ?? "primer"

            guard let bindingSites = try? element.nodes(forXPath: "BindingSite") else { continue }

            for bs in bindingSites {
                guard let bsElem = bs as? XMLElement,
                      let locStr = bsElem.attribute(forName: "location")?.stringValue else { continue }

                let parts = locStr.split(separator: "-")
                guard parts.count == 2,
                      let s = Int(parts[0]),
                      let e = Int(parts[1]) else { continue }

                let boundStrand = bsElem.attribute(forName: "boundStrand")?.stringValue ?? "0"
                let strand: Strand = (boundStrand == "1") ? .reverse : .forward

                let feature = Feature(
                    name: name,
                    type: .primerBinding,
                    start: s,
                    end: e,
                    strand: strand,
                    color: CodableColor(Color.green)
                )
                features.append(feature)
            }
        }

        return features
    }

    // MARK: - Helpers

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return (UInt32(data[offset]) << 24)
             | (UInt32(data[offset + 1]) << 16)
             | (UInt32(data[offset + 2]) << 8)
             | UInt32(data[offset + 3])
    }

    /// Strip HTML tags from SnapGene's escaped-HTML text fields.
    private func stripHTML(_ input: String) -> String {
        // SnapGene stores HTML like "&lt;html>&lt;body>text&lt;/body>&lt;/html>"
        var s = input
        // First unescape XML entities
        s = s.replacingOccurrences(of: "&lt;", with: "<")
        s = s.replacingOccurrences(of: "&gt;", with: ">")
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        // Strip HTML tags
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Quick regex-free tag content extraction (fallback when XMLDocument fails)
    private func extractTagContent(_ xml: String, tag: String) -> String? {
        guard let startRange = xml.range(of: "<\(tag)>"),
              let endRange = xml.range(of: "</\(tag)>") else { return nil }
        let content = String(xml[startRange.upperBound..<endRange.lowerBound])
        return stripHTML(content)
    }

    /// Extract color from a Feature element's Segment child or Q qualifier
    private func extractFeatureColor(_ element: XMLElement) -> CodableColor? {
        // Check Segment nodes for color attribute
        if let segments = try? element.nodes(forXPath: "Segment") {
            for seg in segments {
                if let segElem = seg as? XMLElement,
                   let colorStr = segElem.attribute(forName: "color")?.stringValue {
                    return parseHexColor(colorStr)
                }
            }
        }

        // Check Q qualifiers for color note
        if let qualifiers = try? element.nodes(forXPath: "Q") {
            for q in qualifiers {
                guard let qElem = q as? XMLElement,
                      qElem.attribute(forName: "name")?.stringValue == "note" else { continue }
                if let v = (try? qElem.nodes(forXPath: "V"))?.first as? XMLElement,
                   let text = v.attribute(forName: "text")?.stringValue,
                   text.contains("color:") {
                    // Parse "color: #RRGGBB" or "color: red" etc
                    if let hexRange = text.range(of: "#[0-9A-Fa-f]{6}", options: .regularExpression) {
                        return parseHexColor(String(text[hexRange]))
                    }
                }
            }
        }

        return nil
    }

    private func parseHexColor(_ hex: String) -> CodableColor? {
        var h = hex
        if h.hasPrefix("#") { h = String(h.dropFirst()) }
        guard h.count == 6, let val = UInt32(h, radix: 16) else { return nil }
        return CodableColor(
            red: Double((val >> 16) & 0xFF) / 255.0,
            green: Double((val >> 8) & 0xFF) / 255.0,
            blue: Double(val & 0xFF) / 255.0
        )
    }

    private func mapFeatureType(_ type: String) -> FeatureType {
        switch type.lowercased() {
        case "promoter":                            return .promoter
        case "gene":                                return .gene
        case "cds", "coding":                       return .cds
        case "terminator":                          return .terminator
        case "rep_origin", "origin":                return .origin
        case "primer_bind", "primer binding":       return .primerBinding
        case "selectionmarker",
             "cds" where false:                     return .selectionMarker  // placeholder
        default:                                    return .custom
        }
    }

    /// Default colors matching common SnapGene conventions
    private func defaultColor(for type: String) -> CodableColor {
        switch type.lowercased() {
        case "cds":             return CodableColor(Color(red: 0.56, green: 0.83, blue: 0.96))  // light blue
        case "promoter":        return CodableColor(Color(red: 0.60, green: 0.98, blue: 0.60))  // light green
        case "terminator":      return CodableColor(Color(red: 1.00, green: 0.60, blue: 0.60))  // light red
        case "rep_origin":      return CodableColor(Color(red: 1.00, green: 0.85, blue: 0.40))  // gold
        case "primer_bind":     return CodableColor(Color.green)
        case "gene":            return CodableColor(Color(red: 0.80, green: 0.80, blue: 1.00))  // lavender
        default:                return CodableColor(Color(red: 0.80, green: 0.80, blue: 0.80))  // grey
        }
    }
}

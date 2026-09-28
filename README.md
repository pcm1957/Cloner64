# Cloner 64 for macOS

A DNA sequence analysis and molecular cloning application for macOS, built as a modern 64-bit replacement for Serial Cloner. Native Swift/SwiftUI for Apple Silicon and Intel Macs.

## Download and Install

Download the latest version from the **[Releases](https://github.com/pcm1957/Cloner64/releases)** page, unzip it, and move **Cloner 64** to your Applications folder. A full user handbook (PDF) is included with each release.

Cloner 64 is not signed with an Apple Developer certificate, so macOS blocks it the first time you open it:

- **macOS 14 and earlier:** right-click Cloner 64, choose **Open**, then click **Open** again.
- **macOS 15 (Sequoia) and later:** the app may show in the Dock but never open a window. Open Terminal, type the following (including the space at the end, without pressing Return):

  ```
  xattr -dr com.apple.quarantine 
  ```

  then drag Cloner 64 from Finder into the Terminal window and press Return. This removes the download quarantine marker from Cloner 64 only; it changes no security settings. If you see "Operation not permitted", switch on Terminal under System Settings → Privacy & Security → App Management and try again.

## Features

### Files and Sequences
- Create, open, edit and save DNA and protein sequences; circular and linear topologies; undo/redo
- Multiple sequence windows open at once; welcome screen with a sample pUC19 file
- **XDNA** (.xdna) and **XPRT** (.xprt) — Serial Cloner DNA and protein formats (read/write)
- **FASTA** (.fasta, .fa, .fna; protein .faa) — read/write. A .fasta file containing protein sequence can be opened as protein
- **GenBank** (.gb, .gbk) and **APE** (.ape) — read/write
- **SnapGene** (.dna) — read, detected by its binary signature

### Sequence Editor
- Colour-coded feature overlays, line numbering, complementary strand display
- Find drawer for sequences, enzyme sites and ORFs
- Selection information: base composition, GC content, Tm and translation
- Lock/unlock editing, upper/lowercase, reverse, complement, reverse complement, RNA ↔ DNA

### Graphical Map
- Circular and linear maps with collision-avoiding feature and enzyme labels
- Restriction sites by category: unique, double, blunt, or a chosen set of enzymes
- Context-aware methylation sensitivity (Dam, Dcm, CpG)
- Change a feature's colour directly from the map
- Zoom, adjustable label size, split view with the sequence; export as PDF or PNG; print

### Sequence Map
- Text-based restriction map with cut sites marked on the sequence
- Optional translation frames above and below the DNA
- Feature list with editable colours; copy and print

### Restriction Enzymes
- About 160 enzymes, with isoschizomers consolidated and methylation sensitivity data
- Add, edit or remove enzymes; changes are saved and can be exported or imported
- **My Enzymes** — star the enzymes in your freezer and limit suggestions to them
- Site Usage table (cut positions, fragment sizes, methylation flags)
- Compatible Cohesive Ends reference (e.g. BamHI + BglII)

### Feature Library
- Automatic feature scanning against 147 verified elements in 11 collections: origins, selection markers, promoters, terminators, reporters, affinity and epitope tags, protease sites, linkers, regulatory and recombination elements, two-hybrid elements and primer binding sites
- Create, import and export your own collections

### Cloning Tools
- **Build a Construct** — in silico ligation with sticky-end compatibility checking, end processing (fill/trim) and construct verification
- **Predictive Cloning** — screens enzyme combinations for a vector and insert; scores directionality, internal cuts, reading frame (fusion mode), methylation and more; supports partial digests, compatible-end cross-cloning, multi-source scanning and PCR routes
- **Shuttle Vector Routes** — finds PCR-free multi-step routes through intermediate vectors, optionally limited to the vectors you have (**My Vectors**)
- **Check Construct** — suggests diagnostic digests (fingerprint, feature presence, orientation, comparison with parent)
- **Virtual Cutter** — virtual digest with a simulated agarose gel, adjustable from 0.5% to 2.0%; export as PDF or PNG; print

### PCR
- **Design PCR Primers** — primers for a region, feature or ORF with Tm, GC% and primer-dimer screening; 5′ tails; circular templates; your existing primer stock is checked first; save single primers or both of a pair
- **Run a PCR** — in silico PCR with Taq (A-overhangs) or Pfu/Phusion (blunt)

### Alignment and Proteins
- **Align Two Sequences** — DNA or protein (BLOSUM62), full length (introns appear as clean gap blocks) or best local match
- Protein viewer with Clustal-style colouring, molecular weight, pI and extinction coefficient
- Kyte-Doolittle hydropathy plot with adjustable transmembrane threshold
- NCBI BLAST search (DNA and protein) pre-loaded with your sequence
- Genetic code and IUPAC code reference tables

### Help
- Context help throughout the app: turn it on from the Help menu, then hover over any control

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| ⌘N / ⇧⌘N | New DNA / Protein Sequence |
| ⌘O | Open File |
| ⌘S / ⇧⌘S | Save / Save As |
| ⌘Z / ⇧⌘Z | Undo / Redo |
| ⌘X / ⌘C / ⌘V | Cut / Copy / Paste |
| ⇧⌘V | Paste as New Sequence |
| ⌘A | Select All |
| ⌘U / ⇧⌘U | Make Uppercase / Lowercase |
| ⌘T | Translate Selection |
| ⌘L | Feature Collection |
| ⌘B | Scan for Features |
| ⇧⌘K | Build a Construct |
| ⇧⌘D | Virtual Cutter |
| ⇧⌘R | Run a PCR |
| ⇧⌘A | Align Two Sequences |
| ⇧⌘E | Export DNA as FASTA |
| ⌘P / ⇧⌘P | Print / Page Setup |
| ⇧⌘? | Context Help on/off |

## System Requirements

- **macOS** 13.5 (Ventura) or later
- **Apple Silicon or Intel**

## Building from Source

Requires **Xcode 26** or later. Clone the repository, open `Cloner 64.xcodeproj`, and choose Product → Run (⌘R).

```
DNA_Cloner_macOS/
├── Models/      Data models, file parsers, analysis logic
├── Views/       SwiftUI views, window managers, app entry point
├── Managers/    Window managers and library extensions
└── Resources/   Info.plist
```

48 Swift source files, about 45,000 lines of code.

## Acknowledgements

Inspired by Serial Cloner, created by Franck Perez, and by Christian Marck's Strider — tools that shaped how a generation of biologists worked with DNA sequences.

---

**Version**: 1.4  
**Last Updated**: September 2026  
**Platform**: macOS 13.5+

# Cloner 64 for macOS

A comprehensive DNA sequence analysis and molecular cloning application for macOS, built as a modern 64-bit replacement for Serial Cloner. Native Swift/SwiftUI for Apple Silicon and Intel Macs.

## Features

### Core Functionality
- Create, open, edit, and manage DNA and protein sequences
- Circular and linear topologies with undo/redo
- Multiple sequence windows open simultaneously
- Welcome screen with sample pUC19 file and recent files

### File Format Support
- **XDNA** (.xdna) — Serial Cloner DNA format (read/write)
- **XPRT** (.xprt) — Serial Cloner protein format (read/write)
- **FASTA** (.fasta, .fa, .fna) — plain sequence (read/write)
- **GenBank** (.gb, .gbk) — annotated sequence (read/write)
- **APE** (.ape) — A Plasmid Editor (read)
- **SnapGene** (.dna) — SnapGene binary format (read)
- Automatic format detection including binary magic-byte sniffing

### Sequence Editor
- Colour-coded feature overlays on the sequence
- Line numbering with complementary strand display
- Find/replace drawer for sequences, enzyme sites, and ORFs
- Right-click context menu for copy, cut, paste, translate, and feature editing
- Lock/unlock editing, uppercase/lowercase conversion
- Selection by click-drag or Shift+Click

### Graphical Map
- Circular plasmid map and linear map display
- Features with colour coding and collision-avoiding labels
- Restriction site markers with selectable display modes (unique, double, blunt, particular)
- ORF arcs with double-click to open
- Methylation sensitivity overlay (Dam, Dcm, CpG) with context-aware site checking
- Pinch-to-zoom and adjustable label font size
- Export as PDF, PNG, or JPG; Print support

### Sequence Map
- Text-based restriction map with enzyme cut sites marked on the sequence
- Optional translation frames above/below
- Feature annotations displayed in context
- Configurable line width; copy, print, and PDF export

### Restriction Enzyme Analysis
- Database of 103 restriction enzymes with isoschizomer consolidation
- Recognition site scanning with circular wrapping support
- Filter by single cutters, non-cutters, blunt-end, or sticky-end
- Methylation sensitivity data per enzyme with context-aware warnings
- Site Usage table with cut positions, fragment sizes, and methylation flags
- Compatible Cohesive Ends reference (e.g. BamHI + BglII)
- Editable enzyme database — add, edit, or remove enzymes

### Feature Management
- Manual feature addition and editing
- Automatic feature scanning against a built-in Feature Library (147 elements across 11 function-first collections)
- Feature Library collections: Origins of Replication, Selection Markers, Promoters, Terminators, Reporters, Affinity & Epitope Tags, Protease Cleavage Sites, Linkers & Polycistronic Elements, Regulatory & Recombination, Two-Hybrid / Protein Interaction, and Primer Binding Sites
- Import/export feature collections
- Feature types: Promoter, Gene, CDS, Terminator, Origin, Selection Marker, and more
- Colour-coded features with strand direction (+/−)

### Sequence Analysis
- Base composition (A, T, G, C counts and percentages)
- GC/AT content with sliding-window GC plot
- Molecular weight and Tm estimation
- ORF finder across all 6 reading frames with configurable minimum length
- Translation in all 6 reading frames (standard genetic code)
- Reverse complement, complement, and reverse operations
- RNA ↔ DNA conversion

### Molecular Cloning Tools

**Build a Construct** — In silico ligation workbench. Select vector and insert on graphical maps, choose restriction sites, and simulate ligation with sticky-end compatibility matching. Handles backbone/insert extraction, overhang display, end processing (fill/trim), and junction reconstitution.

**Virtual Cutter** — Virtual restriction digest with simulated agarose gel electrophoresis. Select one or more enzymes, view fragment sizes with hover tooltips. Export as PDF, PNG, JPG, or print.

**Predictive Cloning** — Automated cloning strategy analysis. Screens all enzyme combinations against a vector + insert pair. Scores strategies by directionality, internal cuts, reading frame preservation (fusion protein mode with per-junction frame offsets), methylation sensitivity, and vector uniqueness. Supports partial digest strategies and compatible-end cross-enzyme cloning. Includes fragment size display per strategy, gel resolution warnings, junction sequence previews, per-strategy protocol export, and a "Design Primers" button linking to the primer design tool. Generates predicted construct sequences with remapped features.

**Shuttle Vector Library** — Built-in database of common shuttle vectors with MCS site information. Includes a pathfinder that identifies multi-step shuttle routes between vectors (runs on a background thread with early pruning and route caps). Resizable pop-up window for viewing routes.

### PCR Tools

**Design PCR Primers** — Select a template and target region (or pick a feature/ORF). Suggests forward and reverse primers with Tm, GC%, and primer-dimer screening. Support for 5′ tails (restriction sites or custom sequences). Visual amplicon map with draggable handles. Circular template support. Save and import primers with tail/annealing annotations.

**Run a PCR** — In silico PCR simulation. Choose template, enter primers (with optional 5′ tails), select polymerase (Taq or Pfu). Predicts amplified product including Taq A-overhangs. Product saved as a new sequence.

### Alignment
- Pairwise DNA alignment (word-based seeding + banded Needleman-Wunsch)
- Pairwise protein alignment (BLOSUM62 scoring, Smith-Waterman)
- Colour-coded match display with identity/gap statistics

### Protein Analysis
- Dedicated protein sequence viewer with Clustal-style colouring
- Properties panel: molecular weight, pI, extinction coefficient
- Kyte-Doolittle hydropathy plot with transmembrane threshold
- Find drawer for protein sequences

### External Tools
- NCBI BLAST Search (DNA and Protein) — opens browser pre-loaded with your sequence

### Reference
- Genetic Code table
- IUPAC Nucleotide Codes

## System Requirements

- **macOS**: 12.0 (Monterey) or later
- **Architecture**: Universal (Apple Silicon and Intel)
- **Xcode**: 14.0 or later (for building from source)
- **Swift**: 5.7 or later

## Installation

See **SETUP.md** for detailed Xcode project setup instructions.

### Quick Start
1. Open Xcode 14+
2. Create new macOS → App project (SwiftUI, Swift)
3. Product Name: `Cloner 64`
4. Delete auto-generated files
5. Drag the `DNA_Cloner_macOS` folder contents into the project
6. Set deployment target to macOS 12.0
7. Build and Run (⌘R)

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| ⌘N | New DNA Sequence |
| ⇧⌘N | New Protein Sequence |
| ⌘O | Open File |
| ⌘S | Save |
| ⇧⌘S | Save As |
| ⌘Z | Undo |
| ⇧⌘Z | Redo |
| ⌘X / ⌘C / ⌘V | Cut / Copy / Paste |
| ⇧⌘V | Paste as New Sequence |
| ⌘A | Select All |
| ⌘U | Make Uppercase |
| ⇧⌘U | Make Lowercase |
| ⌘T | Translate Selection |
| ⌘L | Feature Collection |
| ⌘B | Scan for Features |
| ⇧⌘K | Build a Construct |
| ⇧⌘D | Virtual Cutter |
| ⇧⌘R | Run a PCR |
| ⇧⌘A | Align Two DNA Sequences |
| ⇧⌘E | Export as FASTA |
| ⌘P | Print |
| ⇧⌘P | Page Setup |

## Architecture

### Design Patterns
- **MVVM** with SwiftUI @State, @Published, and ObservableObject
- **Singleton window managers** for each tool window (NSWindow + NSHostingController)
- **SequenceManager** as central document controller (@EnvironmentObject)
- **RestrictionEnzymeDatabase** as shared singleton

### Project Structure
```
DNA_Cloner_macOS/
├── Models/          Data models, parsers, business logic
├── Views/           All SwiftUI views, window managers, app entry point
├── Managers/        Window managers and library extensions
└── Resources/       Info.plist
```

52 Swift source files • ~44,800 lines of code

See **SETUP.md** for a complete file-by-file project structure reference.

## Acknowledgements

Inspired by Serial Cloner, created by Franck Perez, and by Christian Marcks's Strider — powerful molecular biology tools that shaped how a generation of biologists worked with DNA sequences.

---

**Version**: 1.0  
**Last Updated**: June 2026  
**Platform**: macOS 12.0+  
**Language**: Swift 5.7+

# Cloner 64 — Xcode Setup Instructions

## Quick Start

### 1. Create New Xcode Project

1. **Open Xcode** (14.0 or later)
2. **File → New → Project**
3. Select **macOS** tab → **App** template → **Next**
4. Configure:
   - Product Name: `Cloner 64`
   - Team: your development team (or None for local builds)
   - Organization Identifier: `com.dnacloner` (or your own)
   - Interface: **SwiftUI**
   - Language: **Swift**
   - Use Core Data: **No**
5. Click **Next** and choose a save location

### 2. Add Source Files

1. Delete the auto-generated `ContentView.swift` and `Cloner_64App.swift`
2. Drag the entire `DNA_Cloner_macOS` folder contents into the Xcode project navigator
3. When prompted, select:
   - ✅ Copy items if needed
   - ✅ Create groups
   - ✅ Add to targets: Cloner 64
4. Also drag in the `Cloner 64/Assets.xcassets` folder (contains the app icon)

### 3. Configure Build Settings

- Select the project in the navigator, then select the target
- **General** tab:
  - Deployment Target: **macOS 12.0**
  - Architectures: Standard Architectures (Apple Silicon, Intel)
- **Signing & Capabilities** tab:
  - Automatically manage signing: ✅
  - Select your team or use "Sign to Run Locally"
- If you get an Info.plist conflict:
  - Build Settings → Packaging → set "Generate Info.plist File" to **No**

### 4. Build and Run

- Press **⌘R** — the app should compile and launch
- The welcome screen appears with a sample pUC19 file button

## Project Structure

```
DNA_Cloner_macOS/
│
├── Models/                              Data models, parsers, and business logic
│   ├── DNASequence.swift                Core DNA sequence model
│   ├── DNASequence+ORFs.swift           ORF finding extension
│   ├── ProteinSequence.swift            Protein sequence model (MW, pI, extinction)
│   ├── SequenceManager.swift            Central document controller
│   ├── RestrictionEnzyme.swift          Enzyme database (103 enzymes) and cut site scanner
│   ├── MethylationSensitivity.swift     Per-enzyme methylation sensitivity data
│   ├── FeatureLibrary.swift             Feature Collection system (147 elements, 11 collections)
│   ├── CloningStrategyAnalyzer.swift    Predictive cloning engine
│   ├── ConstructCheckAnalyzer.swift     Check Construct diagnostic digest advisor
│   ├── DigestVerificationAnalyzer.swift Verify Construct post-ligation digest analysis
│   ├── CloningPrimerTransfer.swift      Bridge between Predictive Cloning and Primer Design
│   ├── ShuttleVectorLibrary.swift       Shuttle vector database
│   ├── ShuttleVectorPathfinder.swift    Multi-step shuttle route finder
│   ├── SequenceAligner.swift            Pairwise DNA alignment engine
│   ├── XDNAParser.swift                 Serial Cloner XDNA/XPRT binary parser
│   ├── SnapGeneParser.swift             SnapGene .dna binary parser
│   ├── AppState.swift                   App-wide state
│   └── Focusedsequencevalues.swift      SwiftUI focus bridge for Edit menu
│
├── Views/                               All SwiftUI views and app entry point
│   ├── Cloner64App.swift                @main entry, menus, window groups
│   ├── WelcomeView.swift                Welcome screen
│   ├── SequenceEditorView.swift         Main sequence editor (tabs: Sequence, Enzymes, Map, etc.)
│   ├── CompactSequencePanel.swift       Condensed sequence panel used within editor layouts
│   ├── SequenceWindowView.swift         Standalone window wrapper for sequences
│   ├── GraphicalMapView.swift           Circular and linear graphical map renderer
│   ├── SequenceMapView.swift            Text-based restriction map window
│   ├── SequenceMapRenderer.swift        Text map generation engine
│   ├── ConstructBuilderView.swift       In silico ligation workbench
│   ├── ConstructCheckView.swift         Check Construct diagnostic digest advisor UI
│   ├── DigestVerificationView.swift     Verify Construct post-ligation digest UI
│   ├── VirtualCutterView.swift          Virtual digest with gel simulation
│   ├── PredictiveCloningView.swift      Predictive cloning UI
│   ├── PrimerDesignView.swift           PCR primer design tool
│   ├── PCRSimulationView.swift          In silico PCR
│   ├── AlignTwoSequencesView.swift      DNA pairwise alignment
│   ├── AlignTwoProteinSequencesView.swift  Protein pairwise alignment
│   ├── ProteinWindowView.swift          Protein sequence viewer
│   ├── HydropathyPlotView.swift         Kyte-Doolittle hydropathy plot
│   ├── FeatureCollectionView.swift      Feature Collection manager
│   ├── RestrictionSitesView.swift       Enzyme analysis panel
│   ├── RestrictionEnzymeListView.swift  Editable enzyme database window
│   ├── SiteUsageView.swift              Full site usage table
│   ├── CompatibleEndsView.swift         Compatible cohesive ends reference
│   ├── ShuttleVectorListView.swift      Shuttle vector library browser
│   ├── AnalysisView.swift               Analysis tab (GC, composition, Tm)
│   ├── ReferenceTablesView.swift        Genetic code and IUPAC tables
│   ├── ImportPreferencesView.swift      Import settings
│   │
│   └── ContextHelp/                     Context-sensitive help system
│       ├── ContextHelpManager.swift     Help text content and lookup
│       ├── ContextHelpModifier.swift    View modifier that attaches hover help
│       ├── ContextHelpPanel.swift       Help panel display
│       └── ContextMenuHelpBridge.swift  Bridges context menus to the help system
│
│
├── Managers/                            Window managers
│   ├── GraphicalMapWindowManager.swift  Opens standalone map windows
│   └── FeatureLibrary+Import.swift      Import extension for feature libraries
│
└── Resources/
    └── Info.plist                        App configuration
```

**52 Swift source files • ~44,800 lines of code**

## Verification Checklist

After setup, verify:

- [ ] Project builds without errors (⌘B)
- [ ] App launches and shows welcome screen (⌘R)
- [ ] Sample pUC19 sequence loads with 8 annotated features
- [ ] Can create a new DNA sequence (⌘N)
- [ ] Sequence Editor tabs all work (Sequence, Enzymes, Map, Graphical, ORFs, Analysis)
- [ ] Graphical map shows circular plasmid with features
- [ ] Restriction enzyme analysis runs (Enzymes tab → Analyse)
- [ ] Feature scanning detects features (⌘B)
- [ ] Virtual Cutter opens and digests (⇧⌘D)
- [ ] Build a Construct opens (⇧⌘K)
- [ ] PCR simulation opens (⇧⌘R)
- [ ] File export works (FASTA, GenBank, XDNA)

## Common Issues and Solutions

**"Cannot find type 'DNASequence' in scope"**
→ Select each file in the navigator, check File Inspector (⌥⌘1), and ensure "Cloner 64" is ticked under Target Membership.

**"Multiple commands produce Info.plist"**
→ Build Settings → Packaging → set "Generate Info.plist File" to No.

**Code signing error**
→ Xcode → Settings → Accounts → add your Apple ID. Or use "Sign to Run Locally" in Signing & Capabilities.

**Build fails with SwiftUI errors**
→ Ensure deployment target is macOS 12.0 or later. Clean build folder (⇧⌘K) and restart Xcode.

**Preview crashes**
→ Previews are optional. Build and run the full app instead (⌘R).

---

**Platform**: macOS 12.0+  
**Xcode**: 14.0+  
**Swift**: 5.7+

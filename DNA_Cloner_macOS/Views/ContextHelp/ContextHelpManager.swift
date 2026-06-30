//
//  ContextHelpManager.swift
//  Cloner 64
//
//  Central store for context-sensitive help.
//  - Holds the on/off state for the help panel
//  - Holds the currently-displayed help text
//  - Holds the dictionary of all help strings, keyed by identifier
//  - Holds the mapping of menu item titles → help keys (used by
//    ContextMenuHelpBridge to light up menu items on highlight)
//
//  To add or edit help text, just edit the `helpStrings` dictionary below.
//  To make a menu item show help on highlight, add an entry to
//  `menuItemHelpKeys` mapping its exact menu title to a help key.
//

import SwiftUI
import Combine

final class ContextHelpManager: ObservableObject {

    /// Shared instance used everywhere in the app.
    static let shared = ContextHelpManager()

    /// Is the floating help panel currently switched on?
    @Published var isEnabled: Bool = false {
        didSet {
            if isEnabled {
                ContextHelpPanelController.shared.show()
            } else {
                ContextHelpPanelController.shared.hide()
            }
        }
    }


    /// The title shown at the top of the help panel (the name of the
    /// control the mouse is currently hovering over).
    @Published var currentTitle: String = "Context Help"

    /// The body text shown in the help panel.
    @Published var currentText: String =
        "Hover the mouse over a button, tab, menu item, or control to see what it does."

    // MARK: - Help text dictionary
    //
    // Keys are arbitrary identifiers you pick (e.g. "editor.reverseComplement").
    // Each entry has a short title and a longer explanation.
    //
    // Add new entries here as you wire up more controls.
    //
    private let helpStrings: [String: (title: String, body: String)] = [

        // --- Toolbar buttons ---

        "toolbar.contextHelpToggle": (
            "Context Help",
            "Switches this help window on and off. When on, hover the mouse over a control or menu item to see what it does."
        ),

        "toolbar.featureCollection": (
            "Feature Collection",
            "Opens the Feature Collection window for this sequence. Lists every annotated feature (genes, promoters, origins, MCS sites…) and lets you add, edit, or delete them."
        ),

        "toolbar.sequenceMap": (
            "Sequence Map",
            "Opens a text-based map of the sequence in a new window, showing features aligned to the base positions."
        ),

        "toolbar.graphicMap": (
            "Graphic Map",
            "Opens a graphical plasmid map in a new window, showing features as coloured arrows around a circular or linear backbone."
        ),

        "toolbar.virtualCutter": (
            "Virtual Cutter",
            "Opens the Virtual Cutter, which shows where restriction enzymes cut the current sequence and lets you simulate digests."
        ),

        "toolbar.checkConstruct": (
            "Check Construct",
            "Opens the Check Construct window for this sequence. Recommends diagnostic restriction digests to verify your plasmid matches the map — optionally focused on a specific feature or ORF, with the option to restrict to enzymes in your freezer."
        ),

        // --- Sequence manipulation (Tools menu & editor) ---

        "editor.reverse": (
            "Reverse",
            "Reverses the sequence end-to-end without complementing the bases. Feature coordinates are remapped to match."
        ),

        "editor.complement": (
            "Complement",
            "Replaces each base with its complement (A↔T, G↔C). The sequence direction is unchanged."
        ),

        "editor.reverseComplement": (
            "Reverse Complement",
            "Reverses the sequence and complements each base — the opposite strand read 5' to 3'. Feature coordinates are remapped."
        ),

        "editor.toUppercase": (
            "Make Uppercase",
            "Converts the selected bases to uppercase. Often used to mark a region of interest such as a primer core."
        ),

        "editor.toLowercase": (
            "Make Lowercase",
            "Converts the selected bases to lowercase. Often used to mark primer tails or untranslated regions."
        ),

        "editor.toRNA": (
            "Convert to RNA",
            "Replaces every T in the sequence with U, turning a DNA sequence into its RNA equivalent."
        ),

        "editor.toDNA": (
            "Convert to DNA",
            "Replaces every U in the sequence with T, turning an RNA sequence back into DNA."
        ),

        "editor.makeDoubleStranded": (
            "Make Double Stranded",
            "Marks the sequence as double-stranded. The Extremities tab will then show both 5' and 3' ends on each strand, and restriction digest overhangs will be displayed."
        ),

        "editor.makeSingleStranded": (
            "Make Single Stranded",
            "Marks the sequence as single-stranded. Some double-strand-only operations (like showing cohesive overhangs) will be unavailable."
        ),

        "editor.strandedness": (
            "Strandedness",
            "Choose whether the sequence is single-stranded or double-stranded. This affects which operations are available and how the ends are drawn."
        ),

        "editor.extremitiesTab": (
            "Extremities",
            "Shows the 5' and 3' ends of the sequence, including any overhangs. Contents depend on whether the sequence is single- or double-stranded."
        ),

        // --- Virtual Cutter ---

                "vcutter.sequencePicker": (
                    "Sequence",
                    "Choose which of your open sequences to digest. Shows the length and whether it's circular or linear."
                ),
                "vcutter.markerPicker": (
                    "Molecular Weight Marker",
                    "Choose which size ladder to display in the leftmost lane of the virtual gel. Used for estimating fragment sizes by eye."
                ),
                "vcutter.individualDigests": (
                    "Individual Digests",
                    "Show a separate gel lane for each selected enzyme digested on its own."
                ),
                "vcutter.combinedDigest": (
                    "Combined Digest",
                    "Show one extra lane containing all selected enzymes digested together."
                ),
                "vcutter.methylationDam": (
                    "Dam Methylation",
                    "Assume the template DNA is Dam-methylated (GATC). Enzymes whose recognition sites overlap Dam sequences will be flagged in the enzyme list — red if the methylation blocks cutting, blue if it is required for cutting."
                ),
                "vcutter.methylationDcm": (
                    "Dcm Methylation",
                    "Assume the template DNA is Dcm-methylated (CCWGG). Enzymes whose recognition sites overlap Dcm sequences will be flagged — red if blocked, blue if required for cutting."
                ),
                "vcutter.methylationCpG": (
                    "CpG Methylation",
                    "Assume the template DNA is CpG-methylated. Enzymes whose recognition sites overlap CpG sequences will be flagged — red if blocked, blue if required for cutting."
                ),
                "vcutter.laneLabelStyle": (
                    "Lane Label Style",
                    "Choose how gel lane labels are formatted: the enzyme name only, the sequence name only, or both combined. Useful when digesting multiple sequences so you can tell lanes apart at a glance."
                ),
                "vcutter.showEnzymeInLabel": (
                    "Show Enzyme Name",
                    "When the lane label style is set to sequence name only, this appends the enzyme name as a suffix so you can still tell which enzyme was used. Disabled automatically when Full style is selected."
                ),
                "vcutter.showBandLabels": (
                    "Show Band Sizes",
                    "Show the fragment size next to each band on the gel. Useful when you want to read sizes at a glance without hovering. Toggle off to keep the gel uncluttered."
                ),
                "vcutter.minFragmentSize": (
                    "Minimum Fragment Size",
                    "Hide fragments smaller than this size from the gel display. Drag the slider right to filter out very small fragments that clutter the lower part of the gel. The underlying data is unchanged — only the display is filtered."
                ),
                "vcutter.enzymeList": (
                    "Restriction Enzyme List",
                    "Lists all enzymes in the database (or just your starred enzymes if 'My Enzymes Only' is on). Italic/greyed names do not cut the selected sequence.\n\nWhen a methylation type is active, a small annotation appears beside sensitive enzymes:\n• Red — the methylation blocks cutting. The enzyme will not cut at methylated sites.\n• Blue — the methylation is required for cutting. The enzyme only works at methylated sites (e.g. DpnI requires Dam methylation).\n• Orange — partial or context-dependent sensitivity."
                ),
                "vcutter.runDigest": (
                    "Run Digest",
                    "Performs the virtual digest using the selected enzymes and shows the resulting fragments on the gel. Shortcut: ⌘↩."
                ),
                "vcutter.home": (
                    "Home",
                    "Bring the sequence editor window for this sequence back to the front."
                ),
                "vcutter.copyFragmentSizes": (
                    "Copy Fragment Sizes",
                    "Copy the fragment sizes table to the clipboard as tab-separated text, ready to paste into a spreadsheet."
                ),
                "vcutter.copyImage": (
                    "Copy Image",
                    "Copy the gel image directly to the clipboard, ready to paste into a document, notebook or presentation."
                ),
                "vcutter.savePDF": (
                    "Save Gel as PDF",
                    "Save the virtual gel image to a PDF file."
                ),
                "vcutter.savePNG": (
                    "Save Gel as PNG",
                    "Save the virtual gel image to a PNG file."
                ),
                "vcutter.printGel": (
                    "Print Gel",
                    "Send the virtual gel image to the printer."
                ),
                "vcutter.printOrientation": (
                    "Print Orientation",
                    "Toggle between landscape and portrait orientation for printing. The button shows the current setting — blue for landscape, orange for portrait. Click before pressing Print to switch."
                ),
                "vcutter.copyReport": (
                    "Copy Report",
                    "Copy the full digest report — fragment sizes, cut positions and methylation warnings — to the clipboard."
                ),
                "vcutter.saveReport": (
                    "Save Report",
                    "Save the full digest report to a text file."
                ),
                "vcutter.laneMove": (
                    "Move Lane",
                    "Shift this lane left or right on the gel. Use the ◀ ▶ buttons to reorder lanes after running the digest — useful for arranging related digests side by side."
                ),
                "vcutter.laneRename": (
                    "Rename Lane",
                    "Edit the label shown above this lane on the gel. Click the pencil button to open the rename popover, type the new name, and press OK or Return to confirm."
                ),
                "vcutter.laneUndo": (
                    "Undo Lane Change",
                    "Undo the last lane move or rename. Only one step of undo is available — it disappears once you run a new digest."
                ),

        // --- Graphical Map ---

        "gmap.sitesMenu": (
            "Restriction Sites",
            "Choose which restriction sites to show on the map: unique, double, blunt, or a particular set of enzymes you select. Label background colours show the cut category (unique, double, blunt). Label text and border colours show methylation sensitivity — see the methylation menu (m.circle button) for the colour key."
        ),
        "gmap.displayMenu": (
            "Display Options",
            "Show or hide features and ORFs on the map, and choose which ones to display."
        ),
        "gmap.methylationMenu": (
            "Methylation Sensitivity",
            "Flag restriction sites affected by Dam, Dcm, or CpG methylation. Three states are shown on site labels:\n\n• Red text + strikethrough — the methylation blocks cutting at this site. The enzyme will not cut here.\n• Blue text — the enzyme requires methylation to cut (e.g. DpnI only cuts Dam-methylated GATC)."
        ),
        "gmap.zoomOut": (
            "Zoom Out",
            "Make the map smaller."
        ),
        "gmap.zoomIn": (
            "Zoom In",
            "Make the map larger."
        ),
        "gmap.zoomReset": (
            "Zoom to 100%",
            "Reset the map to its original size."
        ),
        "gmap.fontSmaller": (
            "Smaller Labels",
            "Reduce the font size used for feature and site labels on the map."
        ),
        "gmap.fontLarger": (
            "Larger Labels",
            "Increase the font size used for feature and site labels on the map."
        ),
        "gmap.home": (
            "Home",
            "Bring the sequence editor window for this sequence back to the front."
        ),
        "gmap.exportPDF": (
            "Export as PDF",
            "Save the current map as a PDF file, preserving vector quality for printing or publication."
        ),
        "gmap.exportPNG": (
            "Export as PNG",
            "Save the current map as a PNG image file."
        ),
        "gmap.printMap": (
            "Print Map",
            "Send the current map to the printer."
        ),
        "gmap.copyImage": (
            "Copy Image",
            "Copy the map image directly to the clipboard, ready to paste into a document, notebook or presentation."
        ),
        "gmap.printOrientation": (
            "Print Orientation",
            "Toggle between landscape and portrait orientation for printing. The button shows the current setting — blue for landscape, orange for portrait. Defaults to portrait for circular maps and landscape for linear maps. Click before pressing Print to switch."
        ),
        "gmap.splitView": (
            "Split View",
            "Show the sequence panel below the map in the same window, so you can read the sequence and see the map together. Basic editing is available in the panel, but for save, find, translation and the full set of tools, use the dedicated Sequence Editor window."
        ),
        "gmap.siteColours": (
            "Restriction Site Colours",
            "Label colours show what kind of cutter each enzyme is:\n\n• Cream — unique cutter (cuts once)\n• Brown — double cutter (cuts twice)\n• Cream→green gradient — unique blunt-end cutter\n• Brown→green gradient — double blunt-end cutter\n• Solid green — blunt cutter (3+ cuts)\n• Blue — enzyme chosen from the particular enzymes list\n• Red label, struck through — cut blocked by methylation\n\nBlunt-end sites always show a green tint regardless of which filter is active, so you can spot blunt-end unique sites at a glance."
        ),

        // --- Graphical Map: Fragment selection bar (appears when you click two enzyme sites) ---

        "gmap.fragmentFirstSite": (
            "First Cut Site (Green)",
            "The first enzyme site you clicked. Shows the enzyme name, its position, and the overhang it leaves (5', 3', or blunt). Click a second site to define a fragment."
        ),
        "gmap.fragmentSecondSite": (
            "Second Cut Site (Red)",
            "The second enzyme site you clicked. Together with the green site it defines a fragment between the two cut positions."
        ),
        "gmap.fragmentPicker": (
            "Fragment A / Fragment B",
            "When you click two cut sites on a circular sequence, two fragments are produced. Fragment A is the direct arc between the cuts; Fragment B wraps around the origin. Switch between them to choose which fragment to use. For linear sequences only one fragment is produced between the two sites."
        ),
        "gmap.copyFragment": (
            "Copy Fragment",
            "Copy the sequence of the selected fragment to the clipboard."
        ),
        "gmap.newSequenceFromFragment": (
            "New Sequence from Fragment",
            "Create a new sequence window containing just the selected fragment, with the overhangs and features trimmed to match."
        ),
        "gmap.clearFragment": (
            "Clear Fragment Selection",
            "Deselect both cut sites and dismiss the fragment selection bar."
        ),

        "gmap.featureArc": (
            "Feature",
            "An annotated feature (gene, promoter, origin, tag…) drawn as a coloured arc. Double-click the arc to extract the feature as a new standalone sequence in its own window. A single click only highlights the feature with a blue outline — useful for visually confirming which feature you're about to act on before double-clicking, or for keeping track of one while scanning the map."
        ),
        "gmap.orfArc": (
            "Open Reading Frame",
            "An open reading frame detected in the sequence, drawn as a coloured arc. ORF colours indicate the reading frame: orange/cyan/mint for +1/+2/+3 forward, and pink/purple/indigo for −1/−2/−3 reverse. Double-click the arc to extract the ORF as a new standalone sequence in its own window. A single click only highlights it with a blue outline — useful for visually confirming which ORF you're about to act on."
        ),

        // --- Sequence Map: Translation ---

        "smap.translateAll": (
            "Translate All",
            "Translate the entire sequence. Turn off to translate only a specific range (From/To base positions)."
        ),
        "smap.frame1": (
            "Frame 1",
            "Show the translation starting at base 1 (reading frame +1)."
        ),
        "smap.frame2": (
            "Frame 2",
            "Show the translation starting at base 2 (reading frame +2)."
        ),
        "smap.frame3": (
            "Frame 3",
            "Show the translation starting at base 3 (reading frame +3)."
        ),
        "smap.uppercaseOnly": (
            "Uppercase Only",
            "Translate only the bases that are in uppercase — useful when you've marked exons in uppercase and introns or UTRs in lowercase."
        ),
        "smap.showCodons": (
            "Show Codons",
            "Group the displayed bases in triplets so that codons line up with their amino acid translation. Only available when a single reading frame is selected."
        ),
        "smap.translationStrand": (
            "Translation Strand",
            "Choose whether to translate the forward strand, the reverse strand, or both."
        ),
        "smap.fillFromFeatureORF": (
            "Fill From Feature or ORF",
            "Fill the From/To range from one of the sequence's annotated features or detected ORFs. Picking an item sets the start and end positions, switches the strand to match, and selects the reading frame that starts on the item's first base — so its protein reads correctly straight away."
        ),

        // --- Tools menu ---

        "tools.featureCollection": (
            "Feature Collection",
            "Opens the Feature Collection window for the current sequence, where you can view, add, edit, and organise annotated features."
        ),
        "tools.scanSequence": (
            "Scan Sequence for Features",
            "Scans the current sequence against your feature library and adds any matches as annotated features. Useful for identifying known elements (promoters, origins, MCS sites, tags) in an unknown sequence."
        ),
        "tools.translateSelection": (
            "Translate Selection",
            "Translates the currently selected DNA into protein using the active genetic code. Opens the result in a new protein sequence window."
        ),
        "tools.siteUsage": (
            "Site Usage",
            "Shows which restriction enzymes cut the current sequence and how often, so you can pick enzymes that cut uniquely (or not at all) for cloning."
        ),
        "tools.restrictionEnzymeList": (
            "Restriction Enzyme List",
            "Opens an editable table of all restriction enzymes known to the app, showing their recognition sites, cut positions, and methylation sensitivities."
        ),
        "tools.compatibleCohesiveEnds": (
            "Compatible Cohesive Ends",
            "Shows which restriction enzymes produce compatible sticky ends that can be ligated together — useful when planning a cloning strategy with two different enzymes."
        ),
        "tools.cloningVectorLibrary": (
            "Cloning Vector Library",
            "Opens the library of built-in cloning vectors (plasmids, shuttle vectors) that the Predictive Cloning feature uses as destinations."
        ),

        // --- Cloning Vector Library window ---

        "vectorLib.myVectorsStar": (
            "My Vectors Star",
            "Click the star to earmark this vector as one of yours — vectors you actually have in stock and use regularly. Earmarked vectors are available as a quick filter in both the library window and the Shuttle Routes search.\n\nFilled gold star = earmarked. Empty star = not earmarked. Your selection is saved and remembered between sessions."
        ),
        "vectorLib.myVectorsFilter": (
            "My Vectors Filter",
            "Show only the vectors you have earmarked with a star. Use this to keep the library focused on the vectors you actually work with, hiding the rest of the built-in list. Toggle it off to see the full library again."
        ),
        "vectorLib.search": (
            "Search Vectors",
            "Search by vector name, enzyme name, or selection marker. The list updates as you type.\n\nExamples: 'pUC19' finds that vector by name; 'BamHI' lists all vectors with BamHI in their MCS; 'amp' finds all ampicillin-resistant vectors."
        ),
        "vectorLib.sort": (
            "Sort Order",
            "Sort the vector list by name, size, or selection marker. Sorting is applied after any active search or category filter."
        ),
        "vectorLib.categoryFilter": (
            "Category Filter",
            "Restrict the list to one vector category — for example, E. coli Expression or Yeast. Select 'All' to see the full library. Categories are assigned when a vector is added or imported."
        ),
        "vectorLib.import": (
            "Import Vector from File",
            "Import a vector from a sequence file (XDNA, GenBank, SnapGene .dna, or FASTA). Cloner 64 reads the file and extracts the vector name, size, MCS restriction sites, and selection marker automatically.\n\nNote: this library stores metadata only — the full sequence is not retained. Sequences can be obtained from NCBI (ncbi.nlm.nih.gov/nuccore) or Addgene (addgene.org)."
        ),
        "vectorLib.add": (
            "Add Vector Manually",
            "Add a new vector entry by filling in the name, category, size, MCS sites, and selection marker yourself. Use this when you want to register a vector without importing a sequence file."
        ),
        "vectorLib.delete": (
            "Delete Vector",
            "Remove the selected vector from the library. Built-in vectors that ship with the app can be deleted from your view but will reappear if the library is reset. User-added vectors are removed permanently."
        ),
        "vectorLib.vectorRow": (
            "Vector Entry",
            "Each row shows the vector name, category, size in bp, selection marker, and the restriction sites in its MCS.\n\nDouble-click to edit the entry. Click the ★ to earmark it as one of your vectors. Hover over a row to see the full name and any notes.\n\nNote: this library holds metadata only — MCS site lists are curated manually. Always verify a predicted cloning strategy against the full vector sequence before proceeding to bench work."
        ),
        "tools.geneticCode": (
            "Genetic Code",
            "Shows the active genetic code table, listing each codon and its corresponding amino acid. Useful for checking translations and designing mutations."
        ),
        "tools.iupacCodes": (
            "IUPAC Nucleotide Codes",
            "Shows the IUPAC ambiguity codes (R = A/G, Y = C/T, N = any, etc.) used when a position can contain more than one possible base."
        ),

        // --- Function menu ---

        "func.buildConstruct": (
            "Build a Construct",
            "Opens the Build a Construct window, where you can assemble a new plasmid or construct by ligating fragments from existing sequences using chosen restriction sites."
        ),
        "func.virtualCutter": (
            "Virtual Cutter",
            "Opens the Virtual Cutter, which simulates restriction digests and displays the results as a virtual gel with fragment sizes."
        ),
        "func.designPCRPrimers": (
            "Design PCR Primers",
            "Opens the Primer Design window, where you can design forward and reverse primers for a region of the current sequence, with options for tails, restriction sites and melting temperature."
        ),
        "func.runPCR": (
            "Run a PCR",
            "Opens the PCR Simulation window, which simulates a PCR reaction using chosen primers against a template sequence and shows the predicted product."
        ),
        "func.predictiveCloning": (
            "Predictive Cloning",
            "Analyses two or more open sequences (an insert and one or more vectors) and suggests ranked cloning strategies, including single-enzyme, double-enzyme, blunt-end, and shuttle-vector routes. Requires at least two sequences to be open."
        ),
        "func.checkConstruct": (
            "Check Construct",
            "Analyses the current sequence and recommends restriction digests that would produce a distinctive gel pattern to verify the plasmid identity, confirm a feature is present, or determine insert orientation. Can be restricted to enzymes in your freezer."
        ),
        "func.alignTwoDNA": (
            "Align Two DNA Sequences",
            "Performs a pairwise alignment of two open DNA sequences and shows the matches, mismatches and gaps side by side."
        ),
        "func.alignTwoProtein": (
            "Align Two Protein Sequences",
            "Performs a pairwise alignment of two open protein sequences, highlighting identical, similar, and different residues."
        ),
        "func.ncbiBlastDNA": (
            "NCBI BLAST Search DNA",
            "Submits the current DNA sequence to NCBI BLAST in your web browser to find similar sequences in public databases."
        ),
        "func.ncbiBlastProtein": (
            "NCBI BLAST Search Protein",
            "Submits the current protein sequence to NCBI BLAST in your web browser to find similar proteins in public databases."
        ),
        "func.hydropathyPlot": (
            "Hydropathy Plot",
            "Opens a Kyte-Doolittle hydropathy plot for the current protein, helping identify hydrophobic regions such as transmembrane domains."
        ),

        // --- Feature Collection ---

        "fcoll.addCollection": (
            "Add Collection",
            "Create a new empty feature collection. Collections group related features together — for example, one for cloning sites, another for plant-specific elements."
        ),
        "fcoll.deleteCollection": (
            "Delete Collection",
            "Delete the currently selected collection, along with all the features it contains. Cannot be undone."
        ),
        "fcoll.mergeCollection": (
            "Merge Collection",
            "Copy the features from another collection into this one. Optionally skip duplicates and delete the source afterwards."
        ),
        "fcoll.importFeatures": (
            "Import Features",
            "Import features from a file into the current collection."
        ),
        "fcoll.exportFeatures": (
            "Export Features",
            "Export the current collection's features to a file you can share or back up."
        ),
        "fcoll.addFeature": (
            "Add Feature",
            "Add a new feature to the current collection. You'll then edit its name, sequence, colour and scan options on the right."
        ),
        "fcoll.deleteFeature": (
            "Delete Feature",
            "Delete the selected feature from the current collection."
        ),
        "fcoll.copyFeature": (
            "Duplicate Feature",
            "Make a copy of the selected feature in the same collection — useful as a starting point for a similar entry."
        ),
        "fcoll.undo": (
            "Undo",
            "Undo the last change to this collection."
        ),
        "fcoll.dupes": (
            "Find Duplicates",
            "Scan all collections for features that share the same name or sequence, and show them colour-coded so you can clean them up."
        ),

        // --- Sequence Map ---

        "smap.showFeatures": (
            "Show Features",
            "Show feature annotations underneath the sequence in the map."
        ),
        "smap.featureList": (
            "Feature List",
            "Open a side list of features so you can choose individually which ones to show."
        ),
        "smap.showReverseStrand": (
            "Show Reverse Strand",
            "Show the reverse complement strand beneath the forward strand."
        ),
        "smap.showCoordinates": (
            "Show Coordinates",
            "Show base-position numbers alongside the sequence."
        ),
        "smap.particularSites": (
            "Particular Sites",
            "Only show restriction sites for a specific set of enzymes that you pick. Useful for cluttered maps."
        ),
        "smap.home": (
            "Home",
            "Bring the sequence editor window for this sequence back to the front."
        ),
        "smap.copyMap": (
            "Copy Restriction Map",
            "Copy the map as plain text to the clipboard, ready to paste into a document."
        ),
        "smap.pageSetup": (
            "Page Setup",
            "Set paper size, orientation and margins for printing."
        ),
        "smap.print": (
            "Print",
            "Send the restriction map to the printer."
        ),

        // --- Sequence Map: Restriction sites ---

        "smap.doNotShowRESites": (
            "Do Not Show RE Sites",
            "Hide all restriction enzyme sites from the map, leaving only the sequence, translations, and features. Useful when you only need the other information."
        ),
        "smap.showAllSites": (
            "Show All Sites",
            "Show every restriction site in the database regardless of how many times the enzyme cuts. When off, use Maximum Cut to limit which enzymes are displayed."
        ),
        "smap.maximumCut": (
            "Maximum Cut",
            "Only show enzymes that cut the sequence this many times or fewer. Set to 1 to show unique cutters only, 2 to include double cutters, and so on."
        ),
        "smap.myEnzymesOnly": (
            "My Enzymes Only",
            "Restrict the map to enzymes in your freezer stock. Star enzymes in Tools → Restriction Enzyme List to build your set."
        ),

        // --- Sequence Map: Methylation ---

        "smap.methylationDam": (
            "Dam Methylation",
            "Assume the template DNA is Dam-methylated (GATC). Enzyme labels affected by Dam methylation will be colour-coded: red strikethrough means the site will not be cut; blue means the enzyme requires Dam methylation to cut."
        ),
        "smap.methylationDcm": (
            "Dcm Methylation",
            "Assume the template DNA is Dcm-methylated (CCWGG). Affected enzyme labels will be colour-coded: red strikethrough = blocked, blue = required for cutting."
        ),
        "smap.methylationCpG": (
            "CpG Methylation",
            "Assume the template DNA is CpG-methylated. Affected enzyme labels will be colour-coded: red strikethrough = blocked, blue = required for cutting."
        ),

        // --- Sequence Map: Display ---

        "smap.characterSize": (
            "Character Size",
            "Set the font size for the on-screen map. Larger sizes make the sequence easier to read; smaller sizes fit more bases per screen."
        ),
        "smap.nucleotidesPerLine": (
            "Nucleotides per Line",
            "Set how many bases are printed on each line of the map. Longer lines show more context at once; shorter lines may be easier to read on screen."
        ),
        "smap.printCharacterSize": (
            "Print Character Size",
            "Set the font size used when printing, independently of the screen size. Smaller sizes fit more on a page; 8–9 pt works well for most printers."
        ),

        // --- Build a Construct ---

        "build.vectorTab": (
            "Vector Tab",
            "Shows the vector side of the ligation. Pick a vector sequence, then click two enzyme sites on the map to define which fragment of the vector will be used."
        ),
        "build.insertTab": (
            "Insert Tab",
            "Shows the insert side of the ligation. Pick an insert sequence, then click two enzyme sites on the map to define the fragment that will be ligated into the vector."
        ),
        "build.constructTab": (
            "Construct Tab",
            "Appears after a successful ligation. Shows the finished construct — its sequence, map and features — and lets you open it as a new sequence window."
        ),
        "build.newLigation": (
            "New Ligation",
            "Clear the current construct and start a fresh ligation with the same vector. Useful when trying several different inserts in the same backbone."
        ),
        "build.ligate": (
            "Ligate",
            "Joins the vector and insert fragments into a single construct using the chosen cut sites and end processing. Shortcut: ⌘↩."
        ),
        "build.showFeatures": (
            "Show Features",
            "Show or hide annotated features (genes, promoters, origins…) on the fragment map."
        ),
        "build.uniqueSites": (
            "Unique Sites",
            "Show restriction enzymes that cut only once in the displayed sequence. These are the safest sites for cloning."
        ),
        "build.doubleSites": (
            "Double Sites",
            "Show restriction enzymes that cut exactly twice in the displayed sequence."
        ),
        "build.bluntSites": (
            "Blunt Sites",
            "Show restriction enzymes that leave blunt ends (no 5' or 3' overhang)."
        ),
        "build.particularSites": (
            "Particular Sites",
            "Only show restriction sites for a specific set of enzymes that you pick, so the map is less cluttered."
        ),
        "build.sequencePicker": (
            "Sequence",
            "Choose which of your open DNA sequences to use as this fragment (vector or insert)."
        ),
        "build.myEnzymesOnly": (
            "My Enzymes Only",
            "Restrict the restriction sites shown on the map to the enzymes you have starred in your freezer list. Use Tools → Restriction Enzyme List to star the enzymes you have in stock. Greyed out if no enzymes are starred."
        ),
        "build.flipOrientation": (
            "Flip Orientation",
            "Reverse the insert so it ligates in the opposite direction. Useful for non-directional cloning. Keyboard shortcut: Tab."
        ),
        "build.verifyConstruct": (
            "Verify Construct",
            "Suggests a restriction-digest strategy to distinguish recombinant clones (containing your insert) from non-recombinant background (re-ligated vector). Choose enzymes that give a clearly different band pattern for each outcome."
        ),

        // --- Check Construct ---

        "check.primarySequence": (
            "Sequence to Check",
            "Choose which open sequence to verify. This starts on whichever window was at the front when you opened Check Construct, but you can switch to any other open sequence here. Switching clears the current results and rebuilds the region list for the new one."
        ),
        "check.primaryBrowse": (
            "Browse for a File",
            "Open a sequence file from disk — xDNA, GenBank, FASTA, APE or SnapGene. The file also opens as a normal sequence window, and is then selected here automatically."
        ),
        "check.comparePlasmids": (
            "Compare with Another Plasmid",
            "Find restriction digests that produce a different band pattern between two plasmids — for example, a parent vector and a recombinant. Both sequences must be open."
        ),
        "check.comparisonPicker": (
            "Sequence B",
            "Choose the second plasmid to compare against. The analyser will find enzymes whose digest pattern differs between Sequence A (the sequence selected above) and Sequence B."
        ),
        "check.regionPicker": (
            "Region to Verify",
            "Optionally focus the analysis on a specific feature or ORF. The analyser will prioritise enzymes that cut within or near that region, helping confirm its presence and orientation."
        ),
        "check.orientationCheck": (
            "Check Orientation",
            "Find digests that distinguish the forward orientation of the selected region from its reverse orientation — useful when you need to confirm which way around an insert has ligated."
        ),
        "check.includeDoubleDigests": (
            "Include Double Digests",
            "Allow the analyser to suggest two-enzyme digests as well as single-enzyme ones. Double digests give more diagnostic bands but require two enzymes to be used together."
        ),
        "check.myEnzymesOnly": (
            "My Enzymes Only",
            "Restrict the enzyme search to the enzymes you have starred in your freezer list. Use Tools → Restriction Enzyme List to star the enzymes you have in stock."
        ),
        "check.analyse": (
            "Analyse",
            "Run the digest verification analysis and generate a ranked list of recommended diagnostic digests. Shortcut: ⌘↩."
        ),

        // --- Design PCR Primers ---

        "primer.templatePicker": (
            "Template Sequence",
            "Choose which of your open DNA sequences to use as the template for primer design. Switching templates clears any previously designed primers."
        ),
        "primer.targetFeature": (
            "Target Feature",
            "Pick an annotated feature or ORF to amplify. The Product Region start and end fields will be filled in automatically from the feature's coordinates. Choose 'Manual' to type your own coordinates."
        ),
        "primer.primerMode": (
            "Primer Mode",
            "Choose whether to design both primers from scratch, or to fix one primer (forward or reverse) to a sequence you supply, and design only the other one. Useful when re-using an existing primer."
        ),
        "primer.designPrimers": (
            "Design Primers",
            "Search the template for forward and reverse primer pairs matching your length, Tm and dimer criteria. Results appear in the list below, ranked best first."
        ),
        "primer.tailSection": (
            "5′ Primer Tails",
            "Expand to add non-binding 5′ tails to your primers — for example to introduce a restriction site for cloning, or to add padding bases. Tails do not affect the annealing Tm shown in the results."
        ),
        "primer.tailMode": (
            "Tail Mode",
            "Choose the kind of 5′ tail for this primer: None (no tail), Enzyme (add a restriction site), or Custom (type any sequence)."
        ),
        "primer.featureOverlay": (
            "Show Features on Map",
            "Expand to pick which features and ORFs are drawn on the template map alongside the primer positions. Useful to see how primers line up against nearby elements."
        ),
        "primer.copyBoth": (
            "Copy Both",
            "Copies the selected forward and reverse primer pair to the clipboard as formatted text, including sequences, Tm values and product size."
        ),
        "primer.runPCRWithThese": (
            "Run PCR with These Primers",
            "Opens the PCR Simulation window pre-loaded with the selected primer pair and the current template, ready to simulate the PCR product."
        ),
        "primer.primerStock": (
            "Primer Stock",
            "Load existing primers from a folder of .xdna files and screen them against the current template. Matching stock primers are automatically included in the design search, so you can re-use primers you already have in the freezer."
        ),
        "primer.chooseStockFolder": (
            "Choose Stock Folder",
            "Select a folder containing primer files (.xdna format). All primers found in the folder will be loaded and can be screened against the current template."
        ),
        "primer.preferStock": (
            "Prefer Stock Primers",
            "When enabled, primer pairs that include one or more stock primers are ranked above fully designed pairs in the results. Useful when you want to re-use existing primers where possible."
        ),
        "primer.primerLength": (
            "Primer Length",
            "Set the minimum and maximum length (in bases) for the annealing portion of each primer. Typical range is 18–25 bp. Longer primers give higher specificity and Tm."
        ),
        "primer.targetTm": (
            "Target Melting Temperature",
            "The ideal annealing temperature for each primer. The design algorithm favours candidates whose Tm is closest to this value. 60 °C is a common starting point."
        ),
        "primer.maxTmDiff": (
            "Maximum ΔTm",
            "The largest allowed difference in melting temperature between the forward and reverse primers in a pair. Keeping this small (≤ 3–5 °C) helps both primers anneal efficiently at the same temperature."
        ),
        "primer.saltConcentration": (
            "Na⁺ Concentration",
            "Monovalent cation (sodium) concentration used in the Tm calculation. Standard PCR buffers are typically 50 mM. Higher salt raises the calculated Tm."
        ),
        "primer.searchWindow": (
            "Search Window",
            "How far outside the target region (in bp) the algorithm looks for primer binding sites. A larger window gives more candidates but primers may sit further from the region of interest."
        ),
        "primer.maxDimer": (
            "Max Dimer 3′ Run",
            "The longest run of complementary bases at the 3′ end allowed before a primer or primer pair is rejected. Lower values are stricter. Runs of 4+ bp risk primer-dimer formation."
        ),
        "primer.allowInternal": (
            "Allow Internal Primers",
            "When off (default), both primers are placed outside the target region so the full region is captured in the amplicon. When on, primers may be placed within the target region, giving an amplicon shorter than the region specified. Useful for confirmatory PCR or when primer quality outside the region is poor."
        ),
        "primer.openTemplate": (
            "Open Template",
            "Load a sequence file from disk to use as the primer design template. Accepts .xdna format and plain FASTA text files."
        ),
        "primer.openForwardPrimer": (
            "Open Forward Primer",
            "Load a previously saved forward primer from a .xdna file and use it as the fixed forward primer for this design."
        ),
        "primer.openReversePrimer": (
            "Open Reverse Primer",
            "Load a previously saved reverse primer from a .xdna file and use it as the fixed reverse primer for this design."
        ),
        "primer.removeStock": (
            "Remove Stock Primers",
            "Clear the currently loaded stock primer folder. The primers will no longer appear as candidates in the results list."
        ),
        "primer.productRegion": (
            "Product Region",
            "Enter the 1-based start and end positions of the region you want to amplify. The algorithm searches for primers that flank this region. For circular templates you can set start > end to amplify across the origin."
        ),
        "primer.wholePlasmidMode": (
            "Whole-Plasmid Amplification",
            "Designs a pair of outward-pointing primers at a single site so that the entire circular plasmid is the PCR product. Useful for recovering a plasmid from low-copy stocks or for linearising before re-circularisation. The product is a linear molecule and requires circularisation before transformation — use overlap tails (Gibson/SLIC) or blunt-end KLD ligation. An alternative requiring no tails is described in the tip below."
        ),
        "primer.primerSite": (
            "Primer Site",
            "The position (1-based) where the two outward-pointing primers are placed. The forward primer starts here and the reverse primer ends here. Choose a site in a non-essential region, ideally with good sequence context for primer design."
        ),
        "primer.overlapTails": (
            "Overlap Tails for Self-Circularisation",
            "Adds a 5′ tail to each primer that is homologous to the opposite end of the linear PCR product. When the two ends anneal they form a circular molecule that can be transformed directly. Compatible with Gibson Assembly and SLIC. DpnI treatment of the reaction is recommended to remove the methylated template before transformation."
        ),
        "primer.sdmMode": (
            "Site-Directed Mutagenesis",
            "Switches primer design into SDM mode. Primers are designed to introduce (or destroy) a specific sequence change in a circular plasmid. The PCR product is the whole plasmid carrying the mutation. DpnI digestion is required after PCR to destroy the original methylated template."
        ),
        "primer.sdmStrategy": (
            "SDM Strategy",
            "QuikChange: both primers overlap the mutation site on opposite strands. Extension produces nicked circles repaired by the bacteria after transformation — no ligation needed. Best for small changes (1–5 bp). Back-to-Back (KLD): outward-pointing primers flank the mutation; the mutant sequence goes into 5′ tails. The linear PCR product must be circularised (NEB KLD kit, Gibson, or SLIC) before transformation. Better for larger insertions or deletions."
        ),
        "primer.sdmMutationType": (
            "Mutation Type",
            "DNA sequence: replace any stretch of bases with any other sequence. Amino acid change: choose a codon within a CDS feature to change to a different amino acid; the preferred codon for that amino acid is used. Restriction site: introduce or destroy a recognition site using the minimum number of silent base changes."
        ),
        "primer.sdmFlankLength": (
            "Flank Length",
            "For QuikChange, the number of exactly-matching template bases on each side of the mutation in the primer. 10–15 bp each side is recommended, giving a total primer length of 25–45 bp. Longer flanks raise the Tm and improve efficiency. The Tm of the full primer (including the mutant region) should be ≥ 78 °C for good QuikChange efficiency."
        ),
        "primer.resultsTable": (
            "Primer Pairs",
            "The ranked list of primer pairs found by the search. Pairs are sorted by overall quality — Tm closeness to target, low ΔTm, low dimer score, and zero offset. Click a row to see the full primer sequences and copy options below. Hover over a column header for a description of that column."
        ),
        "primer.colLength": (
            "Length (Fwd/Rev)",
            "The number of bases in the annealing portion of each primer, shown as Forward/Reverse. This is the region that binds the template. Any 5′ tail added in the Tails section is not included."
        ),
        "primer.colTm": (
            "Melting Temperature",
            "The calculated melting temperature (Tm) of the annealing portion of this primer, using the nearest-neighbour method with the salt concentration you set. The algorithm favours primers whose Tm is close to the Target Tm. Note: if you add a 5′ tail, the full-primer Tm will be higher — use 'Copy Both' to see the corrected value."
        ),
        "primer.colDeltaTm": (
            "ΔTm (Tm Difference)",
            "The difference in melting temperature between the forward and reverse primers in this pair. Values shown in red exceed the Maximum ΔTm you set. A small ΔTm (ideally ≤ 3–5 °C) means both primers anneal efficiently at the same temperature, which is important for consistent PCR."
        ),
        "primer.colGC": (
            "GC Content (Fwd/Rev)",
            "The percentage of G and C bases in each primer's annealing region, shown as Forward/Reverse. The ideal range is 40–60 %. Values outside this range are highlighted. Low GC gives a weak, low-Tm primer; very high GC can cause secondary structure problems."
        ),
        "primer.colDimer": (
            "Dimer Score",
            "The longest run of complementary bases found at or near the 3′ end of either primer (self-dimer) or between the two primers (cross-dimer). Shown in green (≤ 3), amber (4), or red (≥ 5). Runs of 4 bp or more at the 3′ end risk the primer folding back on itself or binding its partner instead of the template, reducing PCR efficiency. Set the threshold with 'Max Dimer 3′ Run'."
        ),
        "primer.colOffset": (
            "Offset",
            "How far outside your specified target region the primers had to be placed, in total bases (forward offset + reverse offset). Zero (shown in green) means both primers sit exactly at the boundaries of your target region. A positive value means the primers were moved outward by that many bases — the product will be slightly longer than your target region, but the full region will still be captured. Offset is non-zero when no primer of acceptable quality exists exactly at the boundary; the algorithm searches outward up to the Search Window distance."
        ),
        "primer.colProduct": (
            "Product Size",
            "The expected size of the PCR product in base pairs, including the primer binding sites. The circular arrow icon indicates the product spans the origin of a circular template."
        ),
        "primer.colStock": (
            "Stock",
            "Whether either primer in this pair matches a primer already in your stock folder. 'Both' means both primers are in stock. 'Fwd' or 'Rev' means one is. A stock match means you may not need to order new primers for this pair."
        ),

        // --- Run a PCR ---

        "pcr.templatePicker": (
            "Template Sequence",
            "Choose which of your open DNA sequences to use as the PCR template. Both circular and linear templates are supported."
        ),
        "pcr.polymerase": (
            "Polymerase",
            "Choose the polymerase for the simulation. Taq adds a 3′-A overhang to the product; proofreading polymerases (Pfu, Phusion…) leave blunt ends."
        ),
        "pcr.runPCR": (
            "Run PCR",
            "Searches the template for binding sites for the forward and reverse primers and shows the predicted PCR product, including tails and any A-overhang. Shortcut: ⌘↩."
        ),
        "pcr.copySequence": (
            "Copy Sequence",
            "Copies the PCR product sequence as plain text to the clipboard."
        ),
        "pcr.copyFASTA": (
            "Copy FASTA",
            "Copies the PCR product to the clipboard in FASTA format, with a header line containing the template name and product size."
        ),
        "pcr.openAsSequence": (
            "Open as New Sequence",
            "Opens the PCR product in a new sequence editor window so you can map, digest or further analyse it."
        ),
        "pcr.openTemplate": (
            "Open Template",
            "Load a sequence file from disk to use as the PCR template. Accepts .xdna, .gb, .gbk, and .dna formats."
        ),
        "pcr.loadForwardPrimer": (
            "Load Forward Primer",
            "Load a forward primer from a saved .xdna primer file. The annealing sequence and any 5′ tail are imported automatically."
        ),
        "pcr.saveForwardPrimer": (
            "Save Forward Primer",
            "Save the current forward primer as a .xdna file so it can be reused in future PCR simulations or primer design sessions."
        ),
        "pcr.loadReversePrimer": (
            "Load Reverse Primer",
            "Load a reverse primer from a saved .xdna primer file. The annealing sequence and any 5′ tail are imported automatically."
        ),
        "pcr.saveReversePrimer": (
            "Save Reverse Primer",
            "Save the current reverse primer as a .xdna file so it can be reused in future PCR simulations or primer design sessions."
        ),
        "pcr.rolesSwapped": (
            "Primer Roles Swapped",
            "This notice appears when the primer you labelled 'Forward' actually binds the antisense strand, and vice versa. Cloner 64 has swapped the roles automatically so the amplicon is assembled correctly. This commonly happens when primers are entered in the wrong fields, or when designing outward-pointing primers for whole-plasmid amplification. The sequences themselves are unchanged — only the Forward/Reverse labels in the results below are transposed."
        ),
        "pcr.mismatchWarning": (
            "Primer–Template Mismatches",
            "One or both primers do not bind the template perfectly. The number of mismatching bases is shown for each primer. The amplicon sequence is built using the primer sequence at those positions, not the template — this is intentional for site-directed mutagenesis (SDM), where the mismatch is the mutation you want to introduce. If you are not doing SDM, check that your primers are correct and that you have selected the right template."
        ),
        "pcr.productSummary": (
            "PCR Product",
            "A summary of the predicted PCR product. Product size is the full amplicon length in base pairs, including any 5′ tails. GC content is calculated across the whole amplicon. The end type depends on the polymerase: Taq adds a single adenine to the 3′ end of each strand (3′ A overhang), which is required for TA cloning but incompatible with blunt-end ligation; proofreading polymerases (Pfu, Phusion) leave blunt ends, suitable for blunt ligation or Gibson Assembly."
        ),
        "pcr.annealingDetails": (
            "Annealing Details",
            "Shows where each primer binds on the template and its melting temperature. The annealing sequence (blue) is the portion that binds the template; the tail (orange, if present) is the 5′ non-binding extension. Bind position is 1-based. Annealing Tm is calculated for the annealing portion only — tails do not contribute in early PCR cycles. If tails are present, Full Tm (which includes the tail) is also shown; this applies once the tail sequence has been incorporated into the product in later cycles. The recommended annealing temperature is the lower of the two annealing Tms minus 5°C."
        ),
        "pcr.ampliconMap": (
            "Amplicon Map",
            "A schematic of the PCR product showing the forward primer (►) at the left end and the reverse primer (◄) at the right end, with the template region between them. Primer tails are shown in brackets where present. Positions refer to 1-based coordinates on the sense strand of the template."
        ),
        "pcr.mismatchTolerance": (
            "Mismatch Tolerance",
            "The maximum number of mismatched bases allowed between a primer and the template at the 3' binding region. Set to 0 for an exact match only. Values of 1-5 are useful for site-directed mutagenesis (SDM) primers, where the mutation is deliberately introduced near the 3' end."
        ),

        // --- Sequence Editor ---

        "seq.saveButton": (
            "Save",
            "Save the sequence back to its original file (⌘S). This overwrites the file on disk. Use Save As to write to a new file."
        ),
        "seq.saveAsButton": (
            "Save As",
            "Save the sequence to a new file in XDNA format. The original file is not changed."
        ),
        "seq.exportButton": (
            "Export",
            "Export the sequence in a different format such as GenBank, FASTA, or plain text."
        ),
        "seq.goToStart": (
            "Go to Start",
            "Move the cursor to the beginning of the sequence (position 1)."
        ),
        "seq.goToEnd": (
            "Go to End",
            "Move the cursor to the end of the sequence."
        ),
        "seq.newFromSelection": (
            "New from Selection",
            "Create a new sequence window containing only the currently selected bases. Features that overlap the selection are trimmed to fit."
        ),
        "seq.scanFeatures": (
            "Scan Features",
            "Scan the sequence against the feature library to automatically annotate known elements such as promoters, terminators, tags, and resistance genes."
        ),
        "seq.featuresMenu": (
            "Feature Actions",
            "Additional actions for the feature list:\n\n• Save Selected to Library — add the currently selected feature to My Features in the library.\n\n• Save All to Library — add every feature in this sequence to the library.\n\n• Clear Scan Results — remove all features that were added by the library scanner, leaving only features that came from the original file or were added manually.\n\n• Clear Scan Duplicates — remove scanned features that overlap with features already present in the original file. Scanned features that are genuinely new (not already annotated) are kept.\n\n• Hide/Show Imported Features — toggle visibility of features that came from the original GB or XDNA file. Hidden features remain in the sequence and reappear when toggled back on. This also hides them on the graphical map."
        ),
        "seq.orfColumns": (
            "ORF Results",
            "Each row shows one open reading frame (ORF) found in the sequence. Position: start (1-based). Size: length in nucleotides. AA: amino acids encoded. Strand: + forward, - reverse. \"no stop\": ORF runs to the sequence edge with no terminating stop codon — may be truncated or span a cloning junction. \"no ATG\": no initiating methionine — likely 5-prime truncated. Both labels together indicate a fragment with no recognisable start or stop."
        ),
        "seq.orfBothStrands": (
            "ORF Search Scope",
            "ORF search always scans all 6 reading frames — three on the forward (+) strand and three on the reverse (−) strand. The strand column shows both the strand (+/−) and the reading frame (1, 2, or 3). No separate toggle is needed."
        ),

        // --- Predictive Cloning ---

        "predict.vectorPicker": (
            "Vector",
            "Choose the destination vector — the backbone into which you want to clone. If the vector matches one in the shuttle vector library, its MCS will be used automatically; otherwise a manual or full-enzyme scan is used."
        ),
        "predict.vectorBrowse": (
            "Browse for Vector",
            "Open a DNA sequence file from disk and use it as the vector. The file is loaded into the app (so it also becomes available as an open sequence window) and selected as the vector in one step."
        ),
        "predict.insertionSiteMode": (
            "Insertion Site Mode",
            "Choose where in the vector the insert can go. 'Anywhere' searches across a user-defined MCS region; 'Between features' restricts the insertion to the span between a chosen 5′ and 3′ feature — useful for keeping a promoter and terminator flanking your insert."
        ),
        "predict.sourceMode": (
            "Source Mode",
            "'Single source' takes the insert from one open sequence. 'Multi-source scan' searches all open sequences for features matching a name (e.g. 'GFP') and treats each hit as a candidate insert — useful when you have the same gene in several files."
        ),
        "predict.analyze": (
            "Analyze Strategies",
            "Runs the cloning strategy search and ranks the viable direct routes — single-enzyme, double-enzyme and blunt-end ligations. In multi-source mode it scans every matching source in one pass. Routes that go via an intermediate shuttle vector are found separately, using the ‘Find Shuttle Routes’ button. Shortcut: ⌘↩."
        ),
        "predict.sourcePicker": (
            "Source Sequence",
            "Choose which open sequence contains the insert. A green 'Blunt ends' badge appears if the source is a linear fragment with no overhangs, which enables direct blunt-end ligation strategies."
        ),
        "predict.sourceBrowse": (
            "Browse for Source",
            "Open a DNA sequence file from disk and use it as the insert source. The file is loaded into the app and selected as the source in one step."
        ),
        "predict.insertRegionMode": (
            "Insert Region",
            "Choose what part of the source to use as the insert: the whole sequence, one of its annotated features, one of its open reading frames, or a custom coordinate range."
        ),
        "predict.cloningMode": (
            "Cloning Mode",
            "Simple insertion ignores reading frame. The Fusion modes require the insert to be in-frame with a vector ORF at one or both junctions — use these for His-tag (N-terminal), GFP-tag (C-terminal), or double-tagged fusion constructs.\n\nIn Fusion mode, the app checks every candidate strategy to verify that the restriction-enzyme cut sites on both the vector and the insert land on codon boundaries that keep the reading frame intact end-to-end. Direct-digest strategies that fail this check are silently filtered out, so only genuinely in-frame options appear. PCR-based strategies are always shown because the primer design step handles frame alignment."
        ),
        "predict.shuttleRoutes": (
            "Find Shuttle Routes",
            "Opens a separate window showing PCR-free cloning routes via intermediate shuttle vectors. Useful when a direct single- or double-digest strategy isn't possible."
        ),
        "predict.stratPrimers": (
            "Design Primers",
            "Opens the Primer Design window pre-configured with the enzyme tails needed for this PCR-based cloning strategy, ready to design forward and reverse primers."
        ),
        "predict.stratBuild": (
            "Build Construct",
            "Builds the predicted construct for this strategy and opens it as a new sequence window, so you can examine the finished clone with all features remapped."
        ),
        "predict.stratView": (
            "View Protocol",
            "Shows a step-by-step wet-lab protocol for this strategy — digests, gel purification, ligation and transformation — in a pop-up window."
        ),
        "predict.stratSave": (
            "Save Protocol",
            "Exports this strategy's protocol to a text file you can keep in your lab notes or share with a colleague."
        ),
        "predict.stratPrint": (
            "Print Protocol",
            "Sends this strategy's protocol to the printer."
        ),
        "predict.insertDirection": (
            "Insert Direction",
            "Choose which orientation of the insert to analyse. 'Either' tries both and reports the best strategies for each. 'Forward' keeps the insert as-is. 'Reverse complement' flips the insert before cloning — useful when a gene is on the opposite strand."
        ),
        "predict.protectedRegions": (
            "Protected Regions",
            "Mark regions of the vector that must not be cut by any enzyme used in the cloning strategy. Features such as antibiotic resistance markers and origins of replication are automatically offered; you can also add custom coordinate ranges."
        ),
        "predict.fusionORF": (
            "Reading Frame to Fuse",
            "This is a separate step from choosing the insert region, and it is easy to think you have already done it. Picking the insert region above decides which stretch of DNA is pulled out (for a Feature or ORF that stretch also includes about 200 bp of flanking sequence, so the search can find nearby cut sites). This step decides which reading frame inside that stretch is actually fused to the vector’s tag — its exact start, end and strand — so the app can keep the fusion in frame. It is not a suitability double-check; the real in-frame test happens when you press Analyze, and this simply tells that test where the coding frame sits.\n\nIf you chose an ORF as the insert, the frame is already known and this collapses to a confirmation line. If you chose a whole sequence, a custom range, or a feature, a region can contain more than one reading frame, so you confirm which one to fuse — most often the feature you already picked, listed here by name. A feature whose length is not a whole number of codons is still offered, flagged with a warning, because a junction offset can make up the difference. Reverse-strand frames are reverse-complemented automatically before fusion."
        ),
        "predict.frameOffset": (
            "Frame Offset",
            "These values tell the app how many bases lie between the nearest codon boundary and the restriction-enzyme cut site at each junction. When you select a vector tag feature, both offsets are filled in automatically from the actual DNA sequence — you do not normally need to change them.\n\nThe vector offset (left box) is measured from the tag feature's annotated start to the vector cut site. The insert offset (right box) is measured from the insert excerpt start to the ORF ATG. Together they let the app calculate whether the reconstituted junction is in-frame without needing to know in advance which enzyme will be used.\n\nAdjust manually only if you are entering offsets by hand without a tag feature selected, or if the annotation on your vector tag does not start precisely at the ATG."
        ),
        "predict.mcsRegion": (
            "MCS Region",
            "Optionally restrict the enzyme search to a specific region of the vector (e.g. the polylinker). Leave blank to search the entire vector."
        ),
        "predict.betweenFeatures5": (
            "5′ Flanking Feature",
            "Choose the feature upstream (5′) of the desired insertion point — typically a promoter. The analyser will only consider enzyme sites in the region between this feature and the 3′ feature."
        ),
        "predict.betweenFeatures3": (
            "3′ Flanking Feature",
            "Choose the feature downstream (3′) of the desired insertion point — typically a terminator. The analyser restricts the search to the span between the 5′ and 3′ features."
        ),
        "predict.multiSourceSearch": (
            "Feature Name Search",
            "Type a feature name (e.g. GFP, HIS5) to search across all open sequences. Every matching feature is treated as a candidate insert, letting you compare cloning routes from multiple sources in one analysis."
        ),
        "predict.stratVerify": (
            "Verify Construct",
            "Suggests a restriction-digest strategy to verify that the recombinant clone is correct — choose diagnostic enzymes that give a distinct banding pattern for the expected construct versus re-ligated vector."
        ),
        "predict.includeStopCodon": (
            "Include Stop Codon",
            "An annotated Feature or Custom range usually stops just before the stop codon, so the insert on its own wouldn’t terminate translation. Turn this on to add the 3 bp stop codon at the 3′ end. It applies only to Feature and Custom inserts in Simple insertion or N-terminal fusion modes — ORF inserts already carry their own stop, and C-terminal or both-sides fusions need read-through into the vector tag, so the option is ignored for those."
        ),
        "predict.vectorTagFeature": (
            "Vector Tag Feature",
            "Select the tag coding feature on the vector that your insert will fuse to — for example a His-tag, GFP or MBP. Choosing it lets the app measure the exact distance from the tag’s annotated start to each candidate enzyme cut site in the vector, and use that distance to verify whether the reconstituted junction will be in-frame with the insert ORF.\n\nUse the N-terminal picker for a tag that sits before your insert (e.g. the N-terminal His-tag in pET-28), and the C-terminal picker for one that comes after. Leave it unset to enter the junction offsets by hand instead.\n\nThe frame check measures actual base counts from the DNA sequence rather than relying on coordinate arithmetic, so it works correctly even when the vector file is stored with the expressed strand as the bottom strand (as is common with .xdna files). A strategy is only shown as in-frame when the geometry is genuinely correct — if no direct-cloning strategy appears for your insert/vector combination, it means none of the available enzyme sites produce a clean in-frame junction, and a PCR-based approach (adding the correct enzyme tail to a primer) is the right route."
        ),

        // --- Shuttle Routes window ---

        "shuttleRoutes.myVectorsOnly": (
            "My Vectors Only",
            "Restrict the shuttle route search to vectors you have earmarked with a star in the Cloning Vector Library (Tools ▸ Cloning Vector Library…). When on, only your starred vectors are considered as intermediate cloning steps, so the results focus on routes you can actually carry out with the vectors in your lab.\n\nThis button only appears when you have at least one vector earmarked. Turn it off to search the full library."
        ),

        // --- Align Two DNA Sequences ---

        "align.sequencePicker": (
            "Sequence",
            "Choose which of your open DNA sequences to use for this side of the alignment."
        ),
        "align.antiParallel": (
            "Anti-parallel",
            "Reverse-complement this sequence before aligning. Use it when you suspect the two sequences are on opposite strands — e.g. aligning a gene against its reverse complement."
        ),
        "align.translation": (
            "Translation Frames",
            "Show the protein translation in one or more of the three reading frames alongside the DNA. Useful for checking that coding regions line up in-frame between the two sequences."
        ),
        "align.localAlign": (
            "Local Align",
            "Run a local pairwise alignment of the two selected sequences and display the matches, mismatches and gaps. Shortcut: ⌘↩."
        ),
        "align.highlightDiffs": (
            "Highlight Differences",
            "Colour mismatched bases in the alignment output so they stand out from identical matches."
        ),
        "align.showFeatures": (
            "Show Features",
            "Show annotated features beneath the aligned sequences, so you can see which genes or elements overlap the aligned region."
        ),
        "align.screenFontSize": (
            "Screen Size",
            "Choose the font size used to display the alignment on screen. Larger sizes are easier to read but show fewer bases per line."
        ),
        "align.printFontSize": (
            "Print Size",
            "Choose the font size used when printing or copying the alignment. Smaller sizes fit more per page; larger sizes are easier to read on paper."
        ),
        "align.copyClipboard": (
            "Copy to Clipboard",
            "Copy the formatted alignment to the clipboard as plain text, ready to paste into a document or email."
        ),
        "align.pageSetup": (
            "Page Setup",
            "Set paper size, orientation and margins for printing the alignment."
        ),
        "align.print": (
            "Print",
            "Send the alignment to the printer using the print font size selected above."
        ),

        // --- Align Two Protein Sequences ---

        "alignProt.proteinPicker": (
            "Protein",
            "Choose which of your open protein sequences to use for this side of the alignment. Length and molecular weight are shown beneath the picker."
        ),
        "alignProt.align": (
            "Align",
            "Run a pairwise alignment of the two selected proteins using the BLOSUM62 substitution matrix, and show identical, similar, and different residues. Shortcut: ⌘↩."
        ),
        "alignProt.highlightDiffs": (
            "Highlight Differences",
            "Colour residues that differ between the two proteins so they stand out from identical matches."
        ),
        "alignProt.colorCoded": (
            "Color Coded",
            "Colour residues by their chemical class (aliphatic, aromatic, acidic, basic, polar). Useful for spotting conservative substitutions where the chemical character is preserved."
        ),
        "alignProt.screenFontSize": (
            "Screen Size",
            "Choose the font size used to display the alignment on screen. Larger sizes are easier to read but show fewer residues per line."
        ),
        "alignProt.printFontSize": (
            "Print Size",
            "Choose the font size used when printing the alignment."
        ),
        "alignProt.copyClipboard": (
            "Copy to Clipboard",
            "Copy the formatted protein alignment to the clipboard as plain text, ready to paste into a document."
        ),
        "alignProt.print": (
            "Print",
            "Send the alignment to the printer using the print font size selected above."
        ),

        // --- Site Usage ---

        "siteusage.sequencePicker": (
            "Sequence",
            "Choose which of your open sequences to analyse. The table updates immediately to show all restriction enzyme cut sites, positions, and fragment sizes for the selected sequence."
        ),
        "siteusage.copy": (
            "Copy Tab",
            "Copy the currently visible tab's enzyme data to the clipboard as tab-delimited text, ready to paste into Excel or a text editor. Includes enzyme name, recognition site, type, cut count, positions, and fragment sizes."
        ),
        "siteusage.print": (
            "Print Report",
            "Print a formatted site usage report for the current tab, including a summary header and the full enzyme table."
        ),
        "siteusage.search": (
            "Search",
            "Filter the table to enzymes whose name or recognition site contains the typed text. Useful for quickly finding a specific enzyme or all enzymes with a particular sequence motif (e.g. GATC)."
        ),
        "siteusage.sort": (
            "Sort Order",
            "Sort the enzyme table alphabetically by name, or by cut count with the most-cutting enzymes at the top."
        ),
        "siteusage.myEnzymes": (
            "My Enzymes Only",
            "When checked, only enzymes from your freezer stock (My Enzymes) are shown in the table."
        ),
        "siteusage.tabs": (
            "Filter Tabs",
            "Switch between views of the enzyme data: All Enzymes shows the complete list; Unique Cutters shows only enzymes with exactly one site; Blunt Cutters shows enzymes that leave blunt ends; Non-Cutters shows enzymes with no site in this sequence."
        ),
        "siteusage.methylationColumn": (
            "Methylation Column (⚠)",
            "Flags enzymes affected by the active methylation settings. An orange triangle (⚠) means Dam, Dcm, or CpG methylation blocks this enzyme at its recognition site — it will not cut methylated template DNA. A blue circle (m) means the enzyme requires methylation to cut, like DpnI which only cuts Dam-methylated GATC. Hover any icon for the specific reason. Methylation sensitivity can be toggled in the Virtual Cutter toolbar."
        ),

        // Add more entries below as you wire up more controls...

        // --- Protein Window ---

        "prot.properties": (
            "Protein Properties",
            "Calculated physicochemical properties of this protein sequence. All values are computed from the amino acid sequence using standard algorithms and assume a fully unfolded, reduced protein in aqueous solution at neutral pH. They do not account for post-translational modifications, signal peptides, or 3D structure."
        ),
        "prot.molecularWeight": (
            "Molecular Weight",
            "The sum of the residue masses of all amino acids, plus one water molecule (for the free N- and C-termini). Calculated using average isotopic masses. Expressed in Daltons (Da) or kiloDaltons (kDa). This is the value to use when estimating migration on SDS-PAGE or when calculating molar concentrations."
        ),
        "prot.isoelectricPoint": (
            "Isoelectric Point (pI)",
            "The pH at which the protein carries no net charge. Calculated iteratively from the pKa values of ionisable residues (D, E, C, Y, H, K, R) and the N- and C-termini. At the pI the protein has minimum solubility and zero electrophoretic mobility. Useful for choosing buffer pH, purification conditions, and predicting behaviour on ion-exchange columns."
        ),
        "prot.extinctionCoeff": (
            "Extinction Coefficient at 280 nm",
            "The molar extinction coefficient (ε) at 280 nm, calculated from the number of Trp (W), Tyr (Y), and Cys (C) residues using the Pace formula: ε = (nW × 5500) + (nY × 1490) + (nC × 125) M⁻¹cm⁻¹, assuming all cysteines form disulfide bonds. If the protein has no W or Y residues the value will be zero and absorbance at 280 nm cannot be used to determine concentration. In that case, use the BCA or Bradford assay instead."
        ),
        "prot.abs01": (
            "Absorbance at 0.1% (1 mg/mL)",
            "The expected A₂₈₀ of a 1 mg/mL solution of this protein, calculated as ε / (MW × 10). Used to determine protein concentration from a measured A₂₈₀ reading: concentration (mg/mL) = A₂₈₀ / Abs0.1%. This value is specific to this protein — do not use a generic factor."
        ),
        "prot.composition": (
            "Amino Acid Composition",
            "The count and percentage of each amino acid in the protein sequence. Amino acids are coloured by chemical property: positively charged (K, R, H) in blue, negatively charged (D, E) in red, polar uncharged (S, T, N, Q) in green, hydrophobic (A, V, I, L, M, F, W, P) in orange, and special cases (C, G, Y) in purple. The bar shows the relative abundance of each residue."
        ),
        "prot.chargeSummary": (
            "Charge Summary",
            "A count of ionisable residues that determine the protein's charge at physiological pH. Negatively charged residues (Asp, Glu) carry a −1 charge at neutral pH; positively charged residues (Lys, Arg) carry a +1 charge. Histidine (His) has a pKa near 6 and is partially charged at physiological pH — it is listed separately. A large excess of positive over negative residues suggests a basic protein (high pI); the reverse suggests an acidic protein (low pI). These counts relate directly to binding to ion-exchange resins."
        ),

        // --- Verify Construct (Digest Verification) window ---

        "verify.orientationToggle": (
            "Insert Orientation",
            "Tick this when you need a digest that reveals which way round the insert went in — useful after a non-directional ligation where the insert could have gone in either orientation. Leave it unticked when the cloning strategy already fixes the orientation (for example, a directional two-enzyme ligation) or when orientation doesn't matter. The note beside the tick box changes to match: when ticked, the tool looks for enzymes that cut the insert off-centre so the two orientations give different band sizes; when unticked, it looks for flanking diagnostic digests."
        ),
        "verify.copy": (
            "Copy Report",
            "Copies the whole verification report — the recommended diagnostic enzymes, the expected fragment sizes, and what each banding pattern would tell you — to the clipboard as plain text, ready to paste into your notes."
        ),
        "verify.save": (
            "Save Report",
            "Saves the verification report to a plain-text (.txt) file of your choosing, so you can keep the expected band sizes alongside your cloning records."
        ),
        "verify.print": (
            "Print Report",
            "Sends the verification report to a printer, with the text wrapped to fit the page — handy for taking the expected band sizes to the gel bench."
        ),

        // --- Compatible Cohesive Ends window ---

        "ends.filter": (
            "Filter",
            "Type an enzyme name or an overhang sequence to narrow the list to matching groups — for example, type AATT to find enzymes leaving that overhang, or EcoRI to jump to its compatibility group. Clear the box to show every group again."
        ),
        "ends.blunt": (
            "Show Blunt Cutters",
            "Show or hide the group of blunt-cutting enzymes. Blunt ends ligate to any other blunt end regardless of sequence, so they are the most flexible to join but also the least specific."
        ),
        "ends.fivePrime": (
            "Show 5' Overhangs",
            "Show or hide groups that leave a 5' overhang (the single-stranded extension is on the 5' strand). Two enzymes that leave the same 5' overhang can be ligated together, even if their recognition sites differ."
        ),
        "ends.threePrime": (
            "Show 3' Overhangs",
            "Show or hide groups that leave a 3' overhang. As with 5' overhangs, only ends carrying the same overhang sequence will anneal and ligate efficiently."
        ),

        // --- Hydropathy Plot window ---

        "hydro.windowSize": (
            "Window Size",
            "The number of consecutive residues averaged at each position (a sliding window). The Kyte–Doolittle scale is usually plotted with a window of 19 for spotting transmembrane helices, or 7–9 for predicting buried versus surface residues. Smaller windows show local detail; larger windows smooth the trace and emphasise long hydrophobic stretches."
        ),
        "hydro.threshold": (
            "Transmembrane Threshold",
            "Draws a horizontal line at a chosen hydropathy value. Peaks rising above it are candidate membrane-spanning segments. With a window of 19, a Kyte–Doolittle score above about +1.6 is the classic indicator of a transmembrane helix."
        ),
        "hydro.thresholdValue": (
            "Threshold Value",
            "The hydropathy score at which the threshold line is drawn. Raise it to be more stringent (fewer peaks qualify) or lower it to be more permissive. +1.6 is the conventional cut-off for transmembrane prediction on the Kyte–Doolittle scale."
        ),
        "hydro.fontSize": (
            "Plot Font Size",
            "Make the axis labels and residue numbers on the plot larger or smaller. Useful for fitting more detail on screen, or for enlarging the text before printing or exporting."
        ),
        "hydro.copyData": (
            "Copy Data",
            "Copies the plotted values — each position and its averaged hydropathy score — to the clipboard as plain text, ready to paste into a spreadsheet for your own graphing."
        ),
        "hydro.savePDF": (
            "Save as PDF",
            "Exports the plot as a PDF file. PDF is vector-based, so it stays sharp at any size — best for figures in documents or publications."
        ),
        "hydro.savePNG": (
            "Save as PNG",
            "Exports the plot as a PNG image at screen resolution — convenient for slides, emails or quick sharing."
        ),
        "hydro.print": (
            "Print Plot",
            "Sends the hydropathy plot to a printer."
        ),

        // --- Restriction Enzyme List window ---

        "enzlist.search": (
            "Search Enzymes",
            "Filter the list by enzyme name or recognition site sequence. For example, type EcoRI to jump straight to that enzyme, or GAATTC to find all enzymes that recognise that sequence. The count in the toolbar updates as you type."
        ),
        "enzlist.sort": (
            "Sort Order",
            "Choose how to sort the enzyme list: alphabetically by Name, by Recognition Site sequence, by Overhang Type (blunt, 5′, or 3′), by Site Length (useful for finding rare-cutters — 8-base sites cut less frequently than 6-base sites), or by Methylation sensitivity."
        ),
        "enzlist.myEnzymes": (
            "My Enzymes Filter",
            "When ticked, shows only the enzymes you have starred — your personal freezer stock list. Untick to show the full database. Stars are toggled by clicking the ★ column in each row."
        ),
        "enzlist.add": (
            "Add Enzyme",
            "Opens a form to add a new restriction enzyme to the database. Use this to enter an enzyme that is not in the built-in list, or to define a custom variant with non-standard cut positions."
        ),
        "enzlist.delete": (
            "Delete Selected Enzyme",
            "Permanently removes the selected enzyme from the database. Built-in enzymes can be deleted here, but will reappear if you reset the database to defaults. Custom enzymes you have added are removed permanently."
        ),

        // --- Enzyme Add / Edit sheet ---

        "enzEdit.name": (
            "Enzyme Name",
            "The conventional name of the enzyme, for example EcoRI or HindIII. Case is preserved as entered. This name is used throughout the app to identify the enzyme."
        ),
        "enzEdit.site": (
            "Recognition Site",
            "The double-stranded recognition sequence, written 5′ to 3′ on the top strand. Use standard IUPAC ambiguity codes for degenerate positions: R (A/G), Y (C/T), W (A/T), S (G/C), K (G/T), M (A/C), B (not A), D (not C), H (not G), V (not T), N (any). The sequence is stored in upper case."
        ),
        "enzEdit.cut5": (
            "Cut Position — Top Strand (5')",
            "The position at which the enzyme cuts the top (5′→3′) strand, counted as the number of bases from the start of the recognition site to the cut point. For EcoRI (GAATTC), the top strand is cut after the first G, so the cut position is 1."
        ),
        "enzEdit.cut3": (
            "Cut Position — Bottom Strand (3')",
            "The position at which the enzyme cuts the bottom strand, again counted from the start of the recognition site on the top strand. Together with the top-strand cut position, this determines whether the enzyme leaves a 5′ overhang, a 3′ overhang, or a blunt end, and what the overhang sequence is."
        ),
        "enzEdit.overhangType": (
            "Overhang Type",
            "Whether the enzyme leaves a 5′ single-stranded overhang (the most common, e.g. EcoRI), a 3′ overhang (e.g. KpnI), or a blunt end (e.g. SmaI, EcoRV). This determines which other enzymes produce compatible ends for ligation."
        ),
        "enzEdit.methylation": (
            "Methylation Sensitivity",
            "Describes whether common methylation patterns block or impair cutting. Use plain text matching the convention used in the rest of the list — for example: dam blocked, dcm impaired, CpG blocked. Leave blank if the enzyme is insensitive to the common Dam, Dcm, and CpG methylations."
        ),
        "enzEdit.cancel": (
            "Cancel",
            "Closes this form without saving any changes."
        ),
        "enzEdit.save": (
            "Save / Add",
            "Saves the enzyme to the database. The button is disabled until all required fields are valid: the name must not be empty, the recognition site must contain only valid IUPAC bases, and both cut positions must be whole numbers. The predicted overhang sequence is shown below the form as a preview before you save."
        ),
    ]

    // MARK: - Menu item mapping
    //
    // Maps a menu item's exact visible title to a key in `helpStrings`.
    // The ContextMenuHelpBridge consults this dictionary when the user
    // highlights a menu item in the menu bar.
    //
    // If you change a menu item's title in DNAClonerApp.swift, update
    // the matching key here.
    //
    let menuItemHelpKeys: [String: String] = [
        // Edit menu
        "Reverse":                     "editor.reverse",
        "Complement":                  "editor.complement",
        "Reverse Complement":          "editor.reverseComplement",
        "Make Uppercase":              "editor.toUppercase",
        "Make Lowercase":              "editor.toLowercase",
        "Convert to RNA (T→U)":        "editor.toRNA",
        "Convert to DNA (U→T)":        "editor.toDNA",
        "Make Double Stranded":        "editor.makeDoubleStranded",
        "Make Single Stranded":        "editor.makeSingleStranded",

        // Tools menu
        "Feature Collection…":         "tools.featureCollection",
        "Scan Sequence for Features":  "tools.scanSequence",
        "Translate Selection…":        "tools.translateSelection",
        "Site Usage…":                 "tools.siteUsage",
        "Restriction Enzyme List…":    "tools.restrictionEnzymeList",
        "Compatible Cohesive Ends…":   "tools.compatibleCohesiveEnds",
        "Cloning Vector Library…":     "tools.cloningVectorLibrary",
        "Genetic Code":                "tools.geneticCode",
        "IUPAC Nucleotide Codes":      "tools.iupacCodes",

        // Function menu
        "Build a Construct…":               "func.buildConstruct",
        "Virtual Cutter…":                  "func.virtualCutter",
        "Design PCR Primers…":              "func.designPCRPrimers",
        "Run a PCR…":                       "func.runPCR",
        "Predictive Cloning…":              "func.predictiveCloning",
        "Check Construct…":                  "func.checkConstruct",
        "Align Two DNA Sequences…":         "func.alignTwoDNA",
        "Align Two Protein Sequences…":     "func.alignTwoProtein",
        "NCBI BLAST Search DNA…":           "func.ncbiBlastDNA",
        "NCBI BLAST Search Protein…":       "func.ncbiBlastProtein",
        "Hydropathy Plot…":                 "func.hydropathyPlot",
    ]

    // MARK: - Lookup

    /// Update the panel to show the help text for the given key.
    /// Called from the `.contextHelp("key")` view modifier on hover,
    /// and from ContextMenuHelpBridge on menu highlight.
    func show(forKey key: String) {
        guard isEnabled else { return }
        if let entry = helpStrings[key] {
            currentTitle = entry.title
            currentText = entry.body
        } else {
            currentTitle = "No help available"
            currentText = "(missing help entry for key: \(key))"
        }
        ContextHelpPanelController.shared.sizeToFit()
    }

    /// Reset the panel to the default idle message.
    func clear() {
        guard isEnabled else { return }
        currentTitle = "Context Help"
        currentText = "Hover the mouse over a button, tab, menu item, or control to see what it does."
        ContextHelpPanelController.shared.sizeToFit()
    }
}

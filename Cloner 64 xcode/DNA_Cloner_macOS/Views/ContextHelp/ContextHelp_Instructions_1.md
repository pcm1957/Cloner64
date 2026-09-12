# Context Help — First Pass

Three new files to drop into your Xcode project:

1. **ContextHelpManager.swift** — the central store. Holds the on/off state, the current help text shown in the panel, and the dictionary of all help strings. This is the only file you'll edit later when you want to add or change help text.
2. **ContextHelpPanel.swift** — the floating panel window itself. No need to edit this.
3. **ContextHelpModifier.swift** — adds a `.contextHelp("some.key")` modifier you can attach to any button, tab, or control. No need to edit this either.

## How to install

1. Drag all three files into your Xcode project (same group as your other source files). Make sure "Copy items if needed" is ticked and the Cloner 64 target is ticked.
2. Build once — it should compile with no errors. Nothing will happen yet because nothing is wired up.

## How to switch it on — add the toolbar button

In whichever view builds the sequence editor's toolbar, add a toggle button. Something like this:

```swift
@ObservedObject private var helpManager = ContextHelpManager.shared

// ...inside your toolbar ToolbarItemGroup or HStack:

Button {
    helpManager.isEnabled.toggle()
} label: {
    Image(systemName: helpManager.isEnabled
          ? "questionmark.circle.fill"
          : "questionmark.circle")
}
.help("Toggle Context Help")
.contextHelp("toolbar.contextHelpToggle")
```

The button toggles the floating panel on and off. When it's on, the panel appears in the top-right of the screen and updates as you hover controls.

## How to make a control show help

Attach `.contextHelp("some.key")` to any SwiftUI view. For example, your Reverse button might currently look like:

```swift
Button("Reverse") { reverseSequence() }
```

Change it to:

```swift
Button("Reverse") { reverseSequence() }
    .contextHelp("editor.reverse")
```

That's it — when the help panel is on, hovering the button will show the "Reverse" entry.

I've pre-loaded the dictionary in `ContextHelpManager.swift` with entries for:

- `toolbar.contextHelpToggle`
- `editor.reverse`
- `editor.complement`
- `editor.reverseComplement`
- `editor.toUppercase`
- `editor.toLowercase`
- `editor.strandedness`
- `editor.extremitiesTab`

Wire those up first to see the system working, then add more entries to the dictionary as you extend it to other controls.

## How to add a new help entry

Open `ContextHelpManager.swift`, find the `helpStrings` dictionary, and add a line like:

```swift
"editor.translate": (
    "Translate",
    "Translates the selected DNA in the chosen reading frame using the current genetic code."
),
```

Then attach `.contextHelp("editor.translate")` to the matching control. That's the whole workflow.

## Notes

- The panel floats above other windows but does **not** steal focus, so you can keep typing in the sequence editor while it's open.
- If you close the panel with its red button, the toolbar toggle automatically flips to off.
- This first pass covers SwiftUI controls only. Menu bar items will need a separate pass (as discussed) because SwiftUI menus don't expose hover events — we'd need to use `NSMenu` delegates for those. Try this first and see how it feels before deciding whether to extend it.

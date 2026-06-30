//
//  FocusedSequenceValues.swift
//  Cloner 64
//
//  Bridges the active sequence editor's selection state to the app's Edit menu commands.
//  Whichever SequenceEditorView is in the focused window publishes its bindings here.
//

import SwiftUI

// MARK: - Focused Value Keys

/// Holds a reference to the active sequence so Edit commands know what to operate on.
struct FocusedSequenceKey: FocusedValueKey {
    typealias Value = DNASequence
}

/// A closure the Edit menu calls for Copy / Cut / Paste / Delete / Select All.
/// The SequenceEditorView provides the implementation.
struct FocusedSequenceActionsKey: FocusedValueKey {
    typealias Value = SequenceEditActions
}

/// Bundles all edit-action closures into one struct.
struct SequenceEditActions: Equatable {
    /// Identity of the sequence these actions belong to. Lets us tell one
    /// editor window's actions apart from another's without comparing the
    /// closures (which can't be compared, and are expensive for SwiftUI to
    /// walk into on every focus change).
    var owner: ObjectIdentifier
    var copy: () -> Void
    var cut: () -> Void
    var paste: () -> Void
    var delete: () -> Void
    var selectAll: () -> Void
    var makeUppercase: () -> Void
    var makeLowercase: () -> Void
    var hasSelection: Bool
    var isLocked: Bool

    // Compare only what decides whether the Edit menu must change: which
    // window owns the actions, and the two state flags. The closures are
    // ignored on purpose — they read live @State when called, so a window
    // holding an earlier copy still acts on its current selection. This stops
    // SwiftUI reflecting into the closures, which caused the lag and the hang.
    static func == (lhs: SequenceEditActions, rhs: SequenceEditActions) -> Bool {
        lhs.owner == rhs.owner
            && lhs.hasSelection == rhs.hasSelection
            && lhs.isLocked == rhs.isLocked
    }
}

extension FocusedValues {
    var activeSequence: DNASequence? {
        get { self[FocusedSequenceKey.self] }
        set { self[FocusedSequenceKey.self] = newValue }
    }
    
    var sequenceEditActions: SequenceEditActions? {
        get { self[FocusedSequenceActionsKey.self] }
        set { self[FocusedSequenceActionsKey.self] = newValue }
    }
}//
//  Focusedsequencevalues.swift
//  Cloner 64
//
//  Created by Peter on 20/02/2026.
//

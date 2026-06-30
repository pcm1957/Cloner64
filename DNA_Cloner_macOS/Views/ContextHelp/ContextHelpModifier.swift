//
//  ContextHelpModifier.swift
//  Cloner 64
//
//  Adds a `.contextHelp("some.key")` modifier to any SwiftUI view.
//  When the user hovers that view AND the context help panel is switched on,
//  the panel updates to show the help text for that key.
//
//  Usage example:
//
//      Button("Reverse") { ... }
//          .contextHelp("editor.reverse")
//

import SwiftUI

private struct ContextHelpModifier: ViewModifier {
    let key: String

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering {
                    ContextHelpManager.shared.show(forKey: key)
                } else {
                    ContextHelpManager.shared.clear()
                }
            }
    }
}

extension View {
    /// Attach a context-help key to this view. When the context help panel
    /// is switched on and the user hovers this view, the panel will show
    /// the help text registered for this key in `ContextHelpManager`.
    func contextHelp(_ key: String) -> some View {
        self.modifier(ContextHelpModifier(key: key))
    }
}

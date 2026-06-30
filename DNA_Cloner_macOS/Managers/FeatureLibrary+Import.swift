//
//  FeatureLibrary+Import.swift
//  Cloner 64
//
//  Adds the ability to save imported features to the library.
//

import Foundation

extension FeatureLibraryManager {
    
    /// Adds a library item to the "Imported" collection, creating it if it doesn't exist.
    /// Used when saving features from GenBank imports to the library for future scanning.
    func addToImportedCollection(_ item: FeatureLibraryItem) {
        if let idx = collections.firstIndex(where: { $0.name == "Imported" }) {
            // Check for duplicates by name within this collection
            let alreadyExists = collections[idx].items.contains(where: { $0.name == item.name })
            if !alreadyExists {
                collections[idx].items.append(item)
                saveCollections()
            }
        } else {
            // Create the "Imported" collection
            var imported = FeatureCollection(name: "Imported")
            imported.items = [item]
            collections.append(imported)
            saveCollections()
        }
    }
}

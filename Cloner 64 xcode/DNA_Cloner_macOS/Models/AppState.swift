//
//  AppState.swift
//  Cloner 64
//

import Foundation
import Combine

class AppState: ObservableObject {
    @Published var showingFileImporter = false
    @Published var showingFASTAExporter = false
    @Published var showingGenBankExporter = false
}

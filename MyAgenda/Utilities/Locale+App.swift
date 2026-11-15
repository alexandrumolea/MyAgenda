//
//  Locale+App.swift
//  MyAgenda
//

import Foundation

extension Locale {
    /// The app's fixed UI locale: dates and numbers in British English, whatever the device region.
    nonisolated static let app = Locale(identifier: "en_GB")
}

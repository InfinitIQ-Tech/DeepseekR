//
//  APIKeyProvider.swift
//  DeepseekR
//
//  Created on 6/09/26.
//

import Foundation

/// Loads the DeepSeek API key at runtime so it never lives in source control.
///
/// The key is read from `DeepseekR/.env` (gitignored), which Xcode copies into
/// the app bundle's resources at build time — the app is sandboxed, so it can't
/// read the repo directly. Expected format: `DEEPSEEK_API_KEY=sk-...`
enum APIKeyProvider {
    private static let keyName = "DEEPSEEK_API_KEY"
    private static let placeholder = "sk-your-key-here"

    static func loadAPIKey() -> String? {
        guard let envURL = Bundle.main.resourceURL?.appendingPathComponent(".env"),
              let contents = try? String(contentsOf: envURL, encoding: .utf8) else {
            return nil
        }
        guard let value = parse(contents)[keyName], value != placeholder else {
            return nil
        }
        return value
    }

    /// Parses simple `KEY=VALUE` lines, ignoring blank lines and `#` comments.
    static func parse(_ contents: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in contents.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let separatorIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<separatorIndex]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: separatorIndex)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty, !value.isEmpty {
                values[key] = value
            }
        }
        return values
    }
}

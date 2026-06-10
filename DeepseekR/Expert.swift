//
//  Expert.swift
//  DeepseekR
//
//  Created on 6/09/26.
//

import Foundation
import os

// MARK: - Expert

/// A specialized assistant in the expert pool: a DeepSeek instance defined by
/// its system prompt. `specialty` is the one-line description the Reasoner
/// Core uses to route questions.
struct Expert: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var specialty: String
    var systemPrompt: String
}

// MARK: - ExpertStore

/// Persists the developer-configured expert pool as JSON in Application Support.
@MainActor
final class ExpertStore: ObservableObject {

    @Published private(set) var experts: [Expert]

    private let storageURL: URL
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "DeepSeekAPI", category: "ExpertStore")

    static let defaultExperts: [Expert] = [
        Expert(
            name: "Swift Engineer",
            specialty: "Swift, SwiftUI, and Apple-platform engineering questions",
            systemPrompt: "You are a senior Swift engineer specializing in Swift, SwiftUI, and Apple platforms. Give precise, idiomatic, modern answers with short code examples where helpful."
        ),
        Expert(
            name: "Research Analyst",
            specialty: "Fact-finding, math, data analysis, and structured reasoning",
            systemPrompt: "You are a rigorous research analyst. Answer with verifiable facts, careful step-by-step reasoning, and explicit uncertainty when you are not sure."
        ),
        Expert(
            name: "Creative Writer",
            specialty: "Prose, naming, copywriting, and storytelling",
            systemPrompt: "You are an inventive writer with a sharp ear for tone. Produce vivid, concise prose tailored to the requested audience and format."
        )
    ]

    init(storageURL: URL? = nil) {
        let url = storageURL ?? Self.defaultStorageURL
        self.storageURL = url
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([Expert].self, from: data) {
            self.experts = saved
        } else {
            self.experts = Self.defaultExperts
            persist()
        }
    }

    private static var defaultStorageURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("DeepseekR", isDirectory: true)
            .appendingPathComponent("experts.json")
    }

    func add(_ expert: Expert) {
        experts.append(expert)
        persist()
    }

    func update(_ expert: Expert) {
        guard let index = experts.firstIndex(where: { $0.id == expert.id }) else { return }
        experts[index] = expert
        persist()
    }

    /// Adds the expert if it is new, otherwise updates the existing entry.
    func upsert(_ expert: Expert) {
        if experts.contains(where: { $0.id == expert.id }) {
            update(expert)
        } else {
            add(expert)
        }
    }

    func remove(_ expert: Expert) {
        experts.removeAll { $0.id == expert.id }
        persist()
    }

    func restoreDefaults() {
        experts = Self.defaultExperts
        persist()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(experts).write(to: storageURL, options: .atomic)
        } catch {
            logger.error("Failed to persist experts: \(error.localizedDescription)")
        }
    }
}

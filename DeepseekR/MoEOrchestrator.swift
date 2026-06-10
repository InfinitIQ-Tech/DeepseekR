//
//  MoEOrchestrator.swift
//  DeepseekR
//
//  Created on 6/09/26.
//
//  The Reasoner Core of DeepseekR's mixture-of-experts vision:
//  User Input -> Reasoner (routing) -> Experts (parallel) -> Reasoner (synthesis) -> Curated Output
//

import Foundation
import os

// MARK: - Orchestration Types

struct ExpertAssignment: Equatable, Identifiable {
    let expert: Expert
    let question: String
    /// True when the Reasoner assembled this expert on the fly because no
    /// roster expert covered the request (dynamic composition).
    let isDynamicallyAssembled: Bool

    var id: UUID { expert.id }
}

struct ExpertReply: Equatable, Identifiable {
    let assignment: ExpertAssignment
    let answer: String

    var id: UUID { assignment.expert.id }
}

enum OrchestrationEvent: Equatable {
    case routingStarted
    case routed([ExpertAssignment])
    case expertReplied(ExpertReply)
    case synthesisStarted
    case synthesisReasoning(String)
    case synthesisDelta(String)
    case finished(String)
}

/// The Reasoner's routing verdict, decoded from its guaranteed-JSON reply.
struct RoutingDecision: Decodable, Equatable {
    struct Assignment: Decodable, Equatable {
        let name: String
        let question: String
    }

    struct NewExpert: Decodable, Equatable {
        let name: String
        let specialty: String
        let systemPrompt: String
        let question: String
    }

    var experts: [Assignment]?
    var newExperts: [NewExpert]?
}

// MARK: - MoEOrchestrator

/// Drives one expert-team conversation: routes each user request to the most
/// relevant experts, consults them concurrently, then synthesizes their
/// answers into a single curated reply using thinking mode.
final class MoEOrchestrator {

    enum OrchestrationError: Swift.Error, LocalizedError {
        case unreadableRoutingDecision

        var errorDescription: String? {
            switch self {
            case .unreadableRoutingDecision:
                return "The Reasoner returned a routing decision that could not be parsed."
            }
        }
    }

    /// Upper bound on experts consulted per turn, counting dynamic ones.
    static let maxExpertsPerTurn = 3

    private let client: DeepSeekChatting
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "DeepSeekAPI", category: "MoEOrchestrator")

    /// User requests and final synthesized replies from prior turns.
    private(set) var conversation: [ChatMessage] = []

    init(client: DeepSeekChatting = DeepSeekClient()) {
        self.client = client
    }

    func respond(to query: String, roster: [Expert]) -> AsyncThrowingStream<OrchestrationEvent, Swift.Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.routingStarted)
                    let assignments = try await self.route(query: query, roster: roster)
                    continuation.yield(.routed(assignments))

                    let replies = try await self.consult(assignments: assignments, query: query) { reply in
                        continuation.yield(.expertReplied(reply))
                    }

                    continuation.yield(.synthesisStarted)
                    let finalAnswer = try await self.synthesize(
                        query: query,
                        replies: replies,
                        onReasoning: { continuation.yield(.synthesisReasoning($0)) },
                        onDelta: { continuation.yield(.synthesisDelta($0)) }
                    )

                    self.conversation.append(ChatMessage(content: query, role: .user))
                    self.conversation.append(ChatMessage(content: finalAnswer, role: .assistant))
                    continuation.yield(.finished(finalAnswer))
                    continuation.finish()
                } catch {
                    self.logger.error("Orchestration failed: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Routing

    private func route(query: String, roster: [Expert]) async throws -> [ExpertAssignment] {
        let systemPrompt = """
        You are the Reasoner Core of DeepseekR, a mixture-of-experts orchestrator.
        Given the user's request and the available experts, decide which experts (1 to \(Self.maxExpertsPerTurn)) \
        should be consulted and write one focused question for each.
        Prefer experts from the roster. Only assemble a new expert when no roster expert covers the request; \
        keep new experts narrowly specialized and reusable.
        Respond with json only, using exactly this schema:
        {"experts": [{"name": "<roster expert name>", "question": "<focused question>"}], \
        "new_experts": [{"name": "<name>", "specialty": "<one line>", "system_prompt": "<system prompt>", "question": "<focused question>"}]}
        Use empty arrays for fields that do not apply.
        """

        var userContent = "Available experts:\n"
        if roster.isEmpty {
            userContent += "(none configured)\n"
        } else {
            for expert in roster {
                userContent += "- \(expert.name): \(expert.specialty)\n"
            }
        }
        if let context = recentContext() {
            userContent += "\nRecent conversation:\n\(context)\n"
        }
        userContent += "\nUser request: \(query)"

        let reply = try await client.complete(
            messages: [
                ChatMessage(content: systemPrompt, role: .system),
                ChatMessage(content: userContent, role: .user)
            ],
            model: .flash,
            thinking: .disabled,
            responseFormat: .jsonObject
        )

        let decision = try Self.parseRoutingDecision(from: reply.content)
        return assignments(from: decision, roster: roster)
    }

    /// Decodes the routing JSON, tolerating a markdown code fence in case the
    /// model wraps its reply despite JSON mode.
    static func parseRoutingDecision(from content: String) throws -> RoutingDecision {
        var json = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```") {
            json = json
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = json.data(using: .utf8) else {
            throw OrchestrationError.unreadableRoutingDecision
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(RoutingDecision.self, from: data)
        } catch {
            throw OrchestrationError.unreadableRoutingDecision
        }
    }

    private func assignments(from decision: RoutingDecision, roster: [Expert]) -> [ExpertAssignment] {
        var result: [ExpertAssignment] = []
        for pick in decision.experts ?? [] {
            guard let expert = roster.first(where: { $0.name.caseInsensitiveCompare(pick.name) == .orderedSame }) else {
                logger.warning("Reasoner picked unknown expert '\(pick.name)', skipping.")
                continue
            }
            guard !result.contains(where: { $0.expert.id == expert.id }) else { continue }
            result.append(ExpertAssignment(expert: expert, question: pick.question, isDynamicallyAssembled: false))
        }
        for newExpert in decision.newExperts ?? [] {
            let expert = Expert(name: newExpert.name, specialty: newExpert.specialty, systemPrompt: newExpert.systemPrompt)
            result.append(ExpertAssignment(expert: expert, question: newExpert.question, isDynamicallyAssembled: true))
        }
        return Array(result.prefix(Self.maxExpertsPerTurn))
    }

    // MARK: - Consultation

    private func consult(
        assignments: [ExpertAssignment],
        query: String,
        onReply: (ExpertReply) -> Void
    ) async throws -> [ExpertReply] {
        guard !assignments.isEmpty else { return [] }
        var replies: [ExpertReply] = []
        try await withThrowingTaskGroup(of: ExpertReply?.self) { group in
            for assignment in assignments {
                group.addTask {
                    do {
                        let reply = try await self.client.complete(
                            messages: [
                                ChatMessage(content: assignment.expert.systemPrompt, role: .system),
                                ChatMessage(
                                    content: "Original user request: \(query)\n\nYour question to answer: \(assignment.question)",
                                    role: .user
                                )
                            ],
                            model: .flash,
                            thinking: .disabled,
                            responseFormat: nil
                        )
                        return ExpertReply(assignment: assignment, answer: reply.content)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // One unavailable expert shouldn't sink the turn; the
                        // Reasoner synthesizes from whoever answered.
                        self.logger.error("Expert '\(assignment.expert.name)' failed: \(error.localizedDescription)")
                        return nil
                    }
                }
            }
            for try await reply in group {
                if let reply {
                    replies.append(reply)
                    onReply(reply)
                }
            }
        }
        return replies
    }

    // MARK: - Synthesis

    private func synthesize(
        query: String,
        replies: [ExpertReply],
        onReasoning: (String) -> Void,
        onDelta: (String) -> Void
    ) async throws -> String {
        let systemPrompt = """
        You are the Reasoner Core of DeepseekR, a mixture-of-experts orchestrator.
        You consulted specialized experts about the user's request. Synthesize their answers into one \
        curated reply: resolve disagreements, drop redundancy, and answer the user directly. \
        Do not mention the experts or the orchestration process unless the user asks about it.
        """

        var userContent = ""
        if replies.isEmpty {
            userContent = "No experts were consulted. Answer the user's request directly.\n\nUser request: \(query)"
        } else {
            userContent = "User request: \(query)\n\nExpert answers:\n"
            for reply in replies {
                userContent += """

                --- \(reply.assignment.expert.name) (asked: \(reply.assignment.question)) ---
                \(reply.answer)

                """
            }
        }

        var messages = [ChatMessage(content: systemPrompt, role: .system)]
        messages.append(contentsOf: conversation)
        messages.append(ChatMessage(content: userContent, role: .user))

        var finalAnswer = ""
        for try await event in client.stream(messages: messages, model: .flash, thinking: .enabled) {
            switch event {
            case .reasoning(let text):
                onReasoning(text)
            case .content(let text):
                finalAnswer += text
                onDelta(text)
            }
        }
        return finalAnswer
    }

    // MARK: - Context

    /// A compact transcript of the last few turns so routing stays
    /// conversation-aware without resending everything.
    private func recentContext(maxTurns: Int = 4, maxCharactersPerTurn: Int = 300) -> String? {
        guard !conversation.isEmpty else { return nil }
        let recent = conversation.suffix(maxTurns)
        let lines = recent.map { message in
            "- \(message.role.rawValue): \(String(message.content.prefix(maxCharactersPerTurn)))"
        }
        return lines.joined(separator: "\n")
    }
}

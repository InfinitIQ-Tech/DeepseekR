//
//  DeepseekRTests.swift
//  DeepseekRTests
//
//  Created by Kenneth Dubroff on 1/22/25.
//  Updated on 6/09/26 with MoE orchestration coverage.
//

import XCTest
@testable import DeepseekR

// MARK: - Fake Client

/// In-memory `DeepSeekChatting` stand-in. Routing calls (JSON response format)
/// return `routingJSON`; expert calls are answered by matching the system
/// prompt against `answersBySystemPrompt`; streaming replays `streamEvents`.
final class FakeDeepSeekClient: DeepSeekChatting, @unchecked Sendable {
    private let lock = NSLock()

    var routingJSON = "{\"experts\": [], \"new_experts\": []}"
    var answersBySystemPrompt: [String: String] = [:]
    var streamEvents: [StreamEvent] = []

    private(set) var completeCallCount = 0
    private(set) var streamedMessages: [ChatMessage] = []

    func complete(
        messages: [ChatMessage],
        model: Model,
        thinking: ThinkingConfig?,
        responseFormat: ResponseFormat?
    ) async throws -> AssistantReply {
        lock.withLock { completeCallCount += 1 }

        if responseFormat == .jsonObject {
            return AssistantReply(content: routingJSON, reasoningContent: nil)
        }
        let systemPrompt = messages.first(where: { $0.role == .system })?.content ?? ""
        let answer = answersBySystemPrompt.first(where: { systemPrompt.contains($0.key) })?.value
            ?? "generic answer"
        return AssistantReply(content: answer, reasoningContent: nil)
    }

    func stream(
        messages: [ChatMessage],
        model: Model,
        thinking: ThinkingConfig?
    ) -> AsyncThrowingStream<StreamEvent, Swift.Error> {
        let events = lock.withLock {
            streamedMessages = messages
            return streamEvents
        }
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

// MARK: - APIKeyProvider

final class APIKeyProviderTests: XCTestCase {

    func testParseReadsKeyValuePairs() {
        let parsed = APIKeyProvider.parse("""
        # comment line
        DEEPSEEK_API_KEY=sk-abc123

        QUOTED="hello world"
        SPACED =  padded value
        """)
        XCTAssertEqual(parsed["DEEPSEEK_API_KEY"], "sk-abc123")
        XCTAssertEqual(parsed["QUOTED"], "hello world")
        XCTAssertEqual(parsed["SPACED"], "padded value")
    }

    func testParseIgnoresMalformedLines() {
        let parsed = APIKeyProvider.parse("no separator here\n=novalue\nKEY=")
        XCTAssertTrue(parsed.isEmpty)
    }
}

// MARK: - Request Encoding

final class ChatRequestEncodingTests: XCTestCase {

    func testEncodingIncludesThinkingAndResponseFormat() throws {
        let request = ChatRequest(
            messages: [ChatMessage(content: "hi", role: .user)],
            model: .flash,
            stream: false,
            thinking: .disabled,
            responseFormat: .jsonObject
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(request)) as? [String: Any]
        )

        XCTAssertEqual(json["model"] as? String, "deepseek-v4-flash")
        let thinking = try XCTUnwrap(json["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["type"] as? String, "disabled")
        let responseFormat = try XCTUnwrap(json["response_format"] as? [String: Any])
        XCTAssertEqual(responseFormat["type"] as? String, "json_object")
    }

    func testEncodingOmitsNilOptions() throws {
        let request = ChatRequest(
            messages: [ChatMessage(content: "hi", role: .user)],
            model: .flash,
            stream: true
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(request)) as? [String: Any]
        )

        XCTAssertNil(json["thinking"])
        XCTAssertNil(json["response_format"])
        XCTAssertEqual(json["stream"] as? Bool, true)
    }
}

// MARK: - Response Decoding

final class ChatResponseDecodingTests: XCTestCase {

    func testDecodesReasoningContent() throws {
        let payload = """
        {"choices": [{"index": 0, "message": {"role": "assistant", "content": "4", "reasoning_content": "2+2 is 4."}}]}
        """
        let response = try NetworkService().decode(
            ChatResponse.self,
            from: Data(payload.utf8),
            convertFromSnakeCase: true
        )
        XCTAssertEqual(response.choices.first?.message.content, "4")
        XCTAssertEqual(response.choices.first?.message.reasoningContent, "2+2 is 4.")
    }

    func testDecodesStreamingDelta() throws {
        let payload = """
        {"choices": [{"index": 0, "delta": {"content": null, "reasoning_content": "We"}, "finish_reason": null}]}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let chunk = try decoder.decode(StreamingChatResponse.self, from: Data(payload.utf8))
        XCTAssertEqual(chunk.choices.first?.delta?.reasoningContent, "We")
        XCTAssertNil(chunk.choices.first?.delta?.content)
    }
}

// MARK: - Routing Decision

final class RoutingDecisionTests: XCTestCase {

    func testParsesPlainJSON() throws {
        let decision = try MoEOrchestrator.parseRoutingDecision(from: """
        {"experts": [{"name": "Swift Engineer", "question": "How do actors work?"}],
         "new_experts": [{"name": "Historian", "specialty": "History", "system_prompt": "You are a historian.", "question": "When was Rome founded?"}]}
        """)
        XCTAssertEqual(decision.experts?.count, 1)
        XCTAssertEqual(decision.experts?.first?.name, "Swift Engineer")
        XCTAssertEqual(decision.newExperts?.count, 1)
        XCTAssertEqual(decision.newExperts?.first?.systemPrompt, "You are a historian.")
    }

    func testParsesFencedJSON() throws {
        let decision = try MoEOrchestrator.parseRoutingDecision(from: """
        ```json
        {"experts": [{"name": "Swift Engineer", "question": "Q"}], "new_experts": []}
        ```
        """)
        XCTAssertEqual(decision.experts?.first?.name, "Swift Engineer")
        XCTAssertEqual(decision.newExperts, [])
    }

    func testThrowsOnGarbage() {
        XCTAssertThrowsError(try MoEOrchestrator.parseRoutingDecision(from: "not json at all"))
    }
}

// MARK: - Orchestrator

final class MoEOrchestratorTests: XCTestCase {

    func testFullOrchestrationFlow() async throws {
        let client = FakeDeepSeekClient()
        client.routingJSON = """
        {"experts": [{"name": "Swift Engineer", "question": "Q1"}],
         "new_experts": [{"name": "Historian", "specialty": "History", "system_prompt": "HIST-PROMPT", "question": "Q2"}]}
        """
        client.answersBySystemPrompt = [
            "SWIFT-PROMPT": "swift answer",
            "HIST-PROMPT": "history answer"
        ]
        client.streamEvents = [
            .reasoning("considering..."),
            .content("final "),
            .content("answer")
        ]

        let roster = [Expert(name: "Swift Engineer", specialty: "Swift", systemPrompt: "SWIFT-PROMPT")]
        let orchestrator = MoEOrchestrator(client: client)

        var events: [OrchestrationEvent] = []
        for try await event in orchestrator.respond(to: "test query", roster: roster) {
            events.append(event)
        }

        XCTAssertEqual(events.first, .routingStarted)

        guard case .routed(let assignments)? = events.dropFirst().first else {
            return XCTFail("Expected a routed event, got \(events)")
        }
        XCTAssertEqual(assignments.count, 2)
        XCTAssertEqual(assignments[0].expert.name, "Swift Engineer")
        XCTAssertFalse(assignments[0].isDynamicallyAssembled)
        XCTAssertEqual(assignments[1].expert.name, "Historian")
        XCTAssertTrue(assignments[1].isDynamicallyAssembled)

        let replies = events.compactMap { event -> ExpertReply? in
            if case .expertReplied(let reply) = event { return reply }
            return nil
        }
        XCTAssertEqual(Set(replies.map(\.answer)), ["swift answer", "history answer"])

        XCTAssertEqual(events.last, .finished("final answer"))
        XCTAssertTrue(events.contains(.synthesisReasoning("considering...")))
        XCTAssertTrue(events.contains(.synthesisDelta("final ")))

        // The turn joins the orchestrator's conversation history.
        XCTAssertEqual(orchestrator.conversation, [
            ChatMessage(content: "test query", role: .user),
            ChatMessage(content: "final answer", role: .assistant)
        ])

        // Synthesis must never echo expert chain-of-thought back as history.
        XCTAssertFalse(client.streamedMessages.isEmpty)
        XCTAssertEqual(client.streamedMessages.first?.role, .system)
    }

    func testNoExpertsFallsBackToDirectAnswer() async throws {
        let client = FakeDeepSeekClient()
        client.routingJSON = "{\"experts\": [], \"new_experts\": []}"
        client.streamEvents = [.content("direct answer")]

        let orchestrator = MoEOrchestrator(client: client)
        var events: [OrchestrationEvent] = []
        for try await event in orchestrator.respond(to: "hello", roster: []) {
            events.append(event)
        }

        guard case .routed(let assignments)? = events.dropFirst().first else {
            return XCTFail("Expected a routed event, got \(events)")
        }
        XCTAssertTrue(assignments.isEmpty)
        XCTAssertEqual(events.last, .finished("direct answer"))
        // Routing + synthesis only, no expert consultations.
        XCTAssertEqual(client.completeCallCount, 1)
    }

    func testUnknownRosterNamesAreSkippedAndCapApplies() async throws {
        let client = FakeDeepSeekClient()
        client.routingJSON = """
        {"experts": [{"name": "Nobody", "question": "Q"}],
         "new_experts": [
            {"name": "A", "specialty": "a", "system_prompt": "PA", "question": "QA"},
            {"name": "B", "specialty": "b", "system_prompt": "PB", "question": "QB"},
            {"name": "C", "specialty": "c", "system_prompt": "PC", "question": "QC"},
            {"name": "D", "specialty": "d", "system_prompt": "PD", "question": "QD"}
         ]}
        """
        client.streamEvents = [.content("done")]

        let orchestrator = MoEOrchestrator(client: client)
        var routedAssignments: [ExpertAssignment] = []
        for try await event in orchestrator.respond(to: "q", roster: []) {
            if case .routed(let assignments) = event {
                routedAssignments = assignments
            }
        }

        XCTAssertEqual(routedAssignments.count, MoEOrchestrator.maxExpertsPerTurn)
        XCTAssertEqual(routedAssignments.map(\.expert.name), ["A", "B", "C"])
    }
}

// MARK: - APIHandler

final class APIHandlerTests: XCTestCase {

    func testStreamingAppendsFullReplyToHistory() async throws {
        let client = FakeDeepSeekClient()
        client.streamEvents = [.content("Hello"), .content(" there")]

        let handler = APIHandler(client: client)
        var chunks: [String] = []
        for try await partial in handler.sendUserMessageStream(content: "hi") {
            chunks.append(partial.content)
        }

        XCTAssertEqual(chunks, ["Hello", " there"])
        XCTAssertEqual(handler.existingMessages, [
            ChatMessage(content: "hi", role: .user),
            ChatMessage(content: "Hello there", role: .assistant)
        ])
    }

    func testSystemMessageMustBeFirst() throws {
        let handler = APIHandler(client: FakeDeepSeekClient())
        _ = try handler.createSystemMessage("be brief")
        XCTAssertThrowsError(try handler.createSystemMessage("again"))
    }
}

// MARK: - ExpertStore

final class ExpertStoreTests: XCTestCase {

    private func temporaryStorageURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DeepseekRTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("experts.json")
    }

    @MainActor
    func testSeedsDefaultsAndPersistsChanges() throws {
        let url = temporaryStorageURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ExpertStore(storageURL: url)
        XCTAssertEqual(store.experts, ExpertStore.defaultExperts)

        let custom = Expert(name: "Chef", specialty: "Cooking", systemPrompt: "You are a chef.")
        store.add(custom)

        let reloaded = ExpertStore(storageURL: url)
        XCTAssertEqual(reloaded.experts.count, ExpertStore.defaultExperts.count + 1)
        XCTAssertEqual(reloaded.experts.last, custom)
    }

    @MainActor
    func testUpsertAndRemove() throws {
        let url = temporaryStorageURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ExpertStore(storageURL: url)
        var expert = Expert(name: "Chef", specialty: "Cooking", systemPrompt: "You are a chef.")
        store.upsert(expert)
        XCTAssertTrue(store.experts.contains(expert))

        expert.specialty = "French cooking"
        store.upsert(expert)
        XCTAssertEqual(store.experts.filter { $0.id == expert.id }.count, 1)
        XCTAssertEqual(store.experts.first { $0.id == expert.id }?.specialty, "French cooking")

        store.remove(expert)
        XCTAssertFalse(store.experts.contains { $0.id == expert.id })
    }
}

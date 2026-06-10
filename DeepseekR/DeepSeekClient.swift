//
//  DeepSeekClient.swift
//  DeepseekR
//
//  Created on 6/09/26.
//

import Foundation
import os

// MARK: - Request Options

/// Top-level `thinking` field of the chat completions API. When omitted the
/// API currently defaults to enabled, so non-thinking calls must send
/// `{"type": "disabled"}` explicitly.
struct ThinkingConfig: Encodable, Equatable {
    enum Mode: String, Encodable {
        case enabled
        case disabled
    }

    enum Effort: String, Encodable {
        case high
        case max
    }

    let type: Mode
    var reasoningEffort: Effort? = nil

    static let enabled = ThinkingConfig(type: .enabled)
    static let disabled = ThinkingConfig(type: .disabled)
}

struct ResponseFormat: Encodable, Equatable {
    let type: String

    /// Guarantees the model emits valid JSON. The prompt must still ask for
    /// json explicitly or the model may emit whitespace until the token limit.
    static let jsonObject = ResponseFormat(type: "json_object")
}

// MARK: - Replies

struct AssistantReply: Equatable {
    let content: String
    let reasoningContent: String?
}

enum StreamEvent: Equatable {
    case reasoning(String)
    case content(String)
}

// MARK: - DeepSeekChatting Protocol

protocol DeepSeekChatting {
    func complete(
        messages: [ChatMessage],
        model: Model,
        thinking: ThinkingConfig?,
        responseFormat: ResponseFormat?
    ) async throws -> AssistantReply

    func stream(
        messages: [ChatMessage],
        model: Model,
        thinking: ThinkingConfig?
    ) -> AsyncThrowingStream<StreamEvent, Swift.Error>
}

// MARK: - DeepSeekClient

/// Stateless transport for the DeepSeek chat completions API. Conversation
/// state lives in callers (`APIHandler`, `MoEOrchestrator`).
final class DeepSeekClient: DeepSeekChatting {

    enum Error: Swift.Error, LocalizedError {
        case missingAPIKey
        case invalidHTTPResponse
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "No DeepSeek API key found. Add DEEPSEEK_API_KEY to DeepseekR/.env and rebuild."
            case .invalidHTTPResponse:
                return "The DeepSeek API returned an unexpected response."
            case .emptyResponse:
                return "The DeepSeek API returned no message content."
            }
        }
    }

    private let chatURL = URL(string: "https://api.deepseek.com/chat/completions")!
    private let networkService: NetworkService
    private lazy var apiKey: String? = APIKeyProvider.loadAPIKey()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "DeepSeekAPI", category: "DeepSeekClient")

    init(networkService: NetworkService = NetworkService()) {
        self.networkService = networkService
    }

    func complete(
        messages: [ChatMessage],
        model: Model,
        thinking: ThinkingConfig? = nil,
        responseFormat: ResponseFormat? = nil
    ) async throws -> AssistantReply {
        let request = try makeRequest(
            messages: messages,
            model: model,
            thinking: thinking,
            responseFormat: responseFormat,
            stream: false
        )
        logger.info("Sending chat request for model: \(model.rawValue)")
        let (data, response) = try await networkService.loadData(using: request)
        guard response.statusCode == 200 else {
            logger.error("Chat request failed with status code: \(response.statusCode)")
            throw Error.invalidHTTPResponse
        }
        let decoded = try networkService.decode(ChatResponse.self, from: data, convertFromSnakeCase: true)
        guard let message = decoded.choices.first?.message, let content = message.content else {
            throw Error.emptyResponse
        }
        return AssistantReply(content: content, reasoningContent: message.reasoningContent)
    }

    func stream(
        messages: [ChatMessage],
        model: Model,
        thinking: ThinkingConfig? = nil
    ) -> AsyncThrowingStream<StreamEvent, Swift.Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try self.makeRequest(
                        messages: messages,
                        model: model,
                        thinking: thinking,
                        responseFormat: nil,
                        stream: true
                    )
                    self.logger.info("Starting streaming chat request for model: \(model.rawValue)")
                    let (byteStream, response) = try await URLSession.shared.bytes(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        self.logger.error("Streaming request failed with status code: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                        continuation.finish(throwing: Error.invalidHTTPResponse)
                        return
                    }

                    let decoder = JSONDecoder()
                    decoder.keyDecodingStrategy = .convertFromSnakeCase

                    for try await line in byteStream.lines {
                        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmedLine.isEmpty { continue }
                        if trimmedLine.lowercased().contains("keep-alive") { continue }

                        var jsonLine = trimmedLine
                        if jsonLine.hasPrefix("data:") {
                            jsonLine = String(jsonLine.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                        }
                        if jsonLine == "[DONE]" {
                            self.logger.info("Received [DONE] signal, finishing stream.")
                            break
                        }
                        guard let data = jsonLine.data(using: .utf8) else { continue }

                        do {
                            let chunk = try decoder.decode(StreamingChatResponse.self, from: data)
                            guard let delta = chunk.choices.first?.delta else { continue }
                            if let reasoning = delta.reasoningContent, !reasoning.isEmpty {
                                continuation.yield(.reasoning(reasoning))
                            }
                            if let content = delta.content, !content.isEmpty {
                                continuation.yield(.content(content))
                            }
                        } catch {
                            self.logger.error("Failed to decode chunk: \(error.localizedDescription)")
                            self.logger.debug("Error decoding line: \(jsonLine)")
                        }
                    }
                    continuation.finish()
                } catch {
                    self.logger.error("Streaming request failed: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeRequest(
        messages: [ChatMessage],
        model: Model,
        thinking: ThinkingConfig?,
        responseFormat: ResponseFormat?,
        stream: Bool
    ) throws -> URLRequest {
        guard let apiKey, !apiKey.isEmpty else { throw Error.missingAPIKey }
        let request = try networkService.createRequest(
            url: chatURL,
            method: .post,
            headerTypes: [.authorization, .contentType, .accept],
            headerValues: [.authorization("Bearer \(apiKey)"), .json, .json]
        )
        let body = ChatRequest(
            messages: messages,
            model: model,
            stream: stream,
            thinking: thinking,
            responseFormat: responseFormat
        )
        return try networkService.encode(from: body, request: request, convertToSnakeCase: true)
    }
}

// MARK: - Response Models

struct ChatResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: AssistantMessage
    }
}

/// Assistant message as returned by the API. `reasoningContent` (the chain of
/// thought in thinking mode) is decode-only and must never be sent back in
/// conversation history.
struct AssistantMessage: Decodable {
    let role: MessageSourceType?
    let content: String?
    let reasoningContent: String?
}

struct StreamingChatResponse: Decodable {
    let choices: [StreamingChoice]

    struct StreamingChoice: Decodable {
        let delta: Delta?

        struct Delta: Decodable {
            let role: MessageSourceType?
            let content: String?
            let reasoningContent: String?
        }
    }
}

//
//  DeepSeekAPI.swift
//  DeepseekR
//
//  Created by Kenneth Dubroff on 1/22/25.
//  Updated on 2/04/25 to add streaming support with updated decoding.
//  Updated on 6/09/26 for the deepseek-v4 models and MoE orchestration.
//

import Foundation
import os

// MARK: - NetworkLoadable Protocol & URLSession Extension

protocol NetworkLoadable {
    func data(using request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: NetworkLoadable {
    func data(using request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await self.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }
        return (data, httpResponse)
    }
}

// MARK: - NetworkError

enum NetworkError: Error {
    case invalidResponse
    case invalidURL
    case encodingFailed
    case decodingFailed
}

// MARK: - NetworkService

class NetworkService {
    enum HttpMethod: String {
        case get = "GET"
        case patch = "PATCH"
        case post = "POST"
        case put = "PUT"
        case delete = "DELETE"
    }

    enum HttpHeaderType: String {
        case contentType = "Content-Type"
        case accept = "Accept"
        case authorization = "Authorization"
    }

    enum HttpHeaderValue {
        case json
        case authorization(String)

        var value: String {
            switch self {
            case .json:
                return "application/json"
            case .authorization(let string):
                return string
            }
        }
    }

    var dataLoader: NetworkLoadable

    init(dataLoader: NetworkLoadable = URLSession.shared) {
        self.dataLoader = dataLoader
    }

    var dateFormatter: DateFormatter {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short
        return dateFormatter
    }

    func createRequest(
        url: URL?,
        method: HttpMethod,
        headerTypes: [HttpHeaderType]? = nil,
        headerValues: [HttpHeaderValue]? = nil
    ) throws -> URLRequest {
        guard let url = url else {
            throw NetworkError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        if let headerTypes = headerTypes, let headerValues = headerValues {
            for (headerType, headerValue) in zip(headerTypes, headerValues) {
                request.setValue(headerValue.value, forHTTPHeaderField: headerType.rawValue)
            }
        }
        return request
    }

    func encode<T: Encodable>(
        from instance: T,
        request: URLRequest,
        dateFormatter: DateFormatter? = nil,
        convertToSnakeCase: Bool = false
    ) throws -> URLRequest {
        var request = request
        let encoder = JSONEncoder()
        if let dateFormatter = dateFormatter {
            encoder.dateEncodingStrategy = .formatted(dateFormatter)
        }
        if convertToSnakeCase {
            encoder.keyEncodingStrategy = .convertToSnakeCase
        }
        do {
            request.httpBody = try encoder.encode(instance)
        } catch {
            throw NetworkError.encodingFailed
        }
        return request
    }

    func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        dateFormatter: DateFormatter? = nil,
        convertFromSnakeCase: Bool = false
    ) throws -> T {
        let decoder = JSONDecoder()
        if let dateFormatter = dateFormatter {
            decoder.dateDecodingStrategy = .formatted(dateFormatter)
        }
        if convertFromSnakeCase {
            decoder.keyDecodingStrategy = .convertFromSnakeCase
        }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw NetworkError.decodingFailed
        }
    }

    func loadData(using request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await dataLoader.data(using: request)
    }
}

// MARK: - APIHandler

/// Conversation-stateful wrapper around `DeepSeekClient` for single-expert
/// ("direct") chat. Expert-team conversations are driven by `MoEOrchestrator`.
class APIHandler: ObservableObject {

    enum APIError: Swift.Error {
        case systemMessageMustBeFirst
    }

    private let client: DeepSeekChatting
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "DeepSeekAPI", category: "APIHandler")

    var existingMessages: [ChatMessage] = []

    init(client: DeepSeekChatting = DeepSeekClient()) {
        self.client = client
    }

    func createSystemMessage(_ content: String) throws -> DeepseekRChatMessage {
        guard existingMessages.isEmpty else { throw APIError.systemMessageMustBeFirst }
        let systemMessage = ChatMessage(content: content, role: .system)
        existingMessages.append(systemMessage)
        return DeepseekRChatMessage(content: systemMessage, warning: nil)
    }

    // MARK: - Non-Streaming API

    func sendUserMessage(
        fromUser name: String? = nil,
        for model: Model = .flash,
        content: String,
        thinking: ThinkingConfig = .disabled
    ) async throws -> DeepseekRChatMessage {
        let chatMessage = ChatMessage(content: content, role: .user, name: name)
        existingMessages.append(chatMessage)
        var warning: String?
        if existingMessages.count == 1 {
            warning = "No system message was added. DeepseekR chat mode does better with a system message."
        }

        let reply = try await client.complete(
            messages: existingMessages,
            model: model,
            thinking: thinking,
            responseFormat: nil
        )
        let assistantMessage = ChatMessage(content: reply.content, role: .assistant)
        existingMessages.append(assistantMessage)
        return DeepseekRChatMessage(content: assistantMessage, warning: warning)
    }

    // MARK: - Streaming API

    /// Sends a user message and returns an asynchronous stream of partial responses.
    /// The full assistant reply joins the conversation history once the stream ends.
    func sendUserMessageStream(
        fromUser name: String? = nil,
        for model: Model = .flash,
        content: String,
        thinking: ThinkingConfig = .disabled
    ) -> AsyncThrowingStream<ChatMessage, Swift.Error> {
        let chatMessage = ChatMessage(content: content, role: .user, name: name)
        existingMessages.append(chatMessage)

        if existingMessages.count == 1 {
            logger.warning("No system message was added. DeepseekR chat mode does better with a system message.")
        }

        let events = client.stream(messages: existingMessages, model: model, thinking: thinking)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var fullReply = ""
                do {
                    for try await event in events {
                        if case .content(let text) = event {
                            fullReply += text
                            continuation.yield(ChatMessage(content: text, role: .assistant))
                        }
                    }
                    if !fullReply.isEmpty {
                        self.existingMessages.append(ChatMessage(content: fullReply, role: .assistant))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Models

enum MessageSourceType: String, Codable {
    case system
    case user
    case assistant
}

enum Model: String, Codable {
    case flash = "deepseek-v4-flash"
    case pro = "deepseek-v4-pro"
}

struct DeepseekRChatMessage: Identifiable {
    let id: String = UUID().uuidString
    var content: ChatMessage
    let warning: String?
}

struct ChatMessage: Codable, Equatable {
    var content: String
    let role: MessageSourceType
    var name: String? = nil
}

struct ChatRequest: Encodable {
    let messages: [ChatMessage]
    let model: Model
    let stream: Bool
    var thinking: ThinkingConfig? = nil
    var responseFormat: ResponseFormat? = nil
}

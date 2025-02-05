//
//  DeepSeekAPI.swift
//  DeepseekR
//
//  Created by Kenneth Dubroff on 1/22/25.
//  Updated on 2/04/25 to add streaming support with updated decoding.
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

class APIHandler: ObservableObject {

    enum APIError: Swift.Error {
        case systemMessageMustBeFirst
        case noMessageReceivedFromAssistant
        case invalidHTTPResponse
    }

    private let apiKey = "sk-cd20ef406b6b4b10bc7b76f4f16bb048"
    private let chatURL = URL(string: "https://api.deepseek.com/chat/completions")!
    private let networkService = NetworkService()

    private var bearerToken: String {
        "Bearer \(apiKey)"
    }

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "DeepSeekAPI", category: "APIHandler")

    private static let shouldStream = false

    var existingMessages: [ChatMessage] = []

    // MARK: - Non-Streaming API

    func createSystemMessage(_ content: String) throws -> DeepseekRChatMessage {
        guard existingMessages.isEmpty else { throw APIError.systemMessageMustBeFirst }
        let systemMessage = ChatMessage(content: content, role: .system)
        existingMessages.append(systemMessage)
        return DeepseekRChatMessage(content: systemMessage, warning: nil)
    }

    func sendUserMessage(
        fromUser name: String? = nil,
        for model: Model = .deepseek,
        content: String,
        stream: Bool = APIHandler.shouldStream
    ) async throws -> DeepseekRChatMessage {
        let chatMessage = ChatMessage(content: content, role: .user, name: name)
        existingMessages.append(chatMessage)
        var warning: String?
        if existingMessages.count == 1 {
            warning = "No system message was added. DeepseekR chat mode does better with a system message."
        }

        let response = try await chat(withModel: model, stream: stream)
        return DeepseekRChatMessage(content: response, warning: warning)
    }

    private func chat(withModel model: Model, stream: Bool) async throws -> ChatMessage {
        var request = try networkService.createRequest(
            url: chatURL,
            method: .post,
            headerTypes: [.authorization, .contentType, .accept],
            headerValues: [.authorization(bearerToken), .json, .json]
        )
        let chatBody = ChatRequest(messages: existingMessages, model: model, stream: stream)
        request = try networkService.encode(from: chatBody, request: request, convertToSnakeCase: true)

        logger.info("Sending non-streaming chat request for model: \(model.rawValue)")
        let (data, response) = try await networkService.loadData(using: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            logger.error("Non-streaming request failed with status code: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            throw APIError.invalidHTTPResponse
        }

        logger.debug("Received non-streaming response: \(String(data: data, encoding: .utf8) ?? "No Data")")
        let decodedResponse = try networkService.decode(ChatResponse.self, from: data)
        guard let firstMessage = decodedResponse.choices.first?.message else {
            throw APIError.noMessageReceivedFromAssistant
        }
        self.existingMessages.append(firstMessage)
        return firstMessage
    }

    // MARK: - Streaming API

    /// Sends a user message and returns an asynchronous stream of partial responses.
    func sendUserMessageStream(
        fromUser name: String? = nil,
        for model: Model = .deepseek,
        content: String
    ) -> AsyncThrowingStream<ChatMessage, Swift.Error> {
        let chatMessage = ChatMessage(content: content, role: .user, name: name)
        existingMessages.append(chatMessage)

        if existingMessages.count == 1 {
            logger.warning("No system message was added. DeepseekR chat mode does better with a system message.")
        }

        return streamChat(withModel: model)
    }

    /// Updated streaming implementation using URLSession’s async bytes API and a streaming decoder.
    private func streamChat(withModel model: Model) -> AsyncThrowingStream<ChatMessage, Swift.Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var request = try networkService.createRequest(
                        url: chatURL,
                        method: .post,
                        headerTypes: [.authorization, .contentType, .accept],
                        headerValues: [.authorization(bearerToken), .json, .json]
                    )
                    let chatBody = ChatRequest(messages: existingMessages, model: model, stream: true)
                    request = try networkService.encode(from: chatBody, request: request, convertToSnakeCase: true)

                    logger.info("Starting streaming chat request for model: \(model.rawValue)")

                    let (byteStream, response) = try await URLSession.shared.bytes(for: request)

                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        logger.error("Streaming request failed with status code: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                        continuation.finish(throwing: APIError.invalidHTTPResponse)
                        return
                    }

                    // Process each incoming line from the byte stream.
                    for try await line in byteStream.lines {
                        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        // Skip empty lines.
                        if trimmedLine.isEmpty { continue }

                        // Handle termination signal.
                        if trimmedLine == "[DONE]" {
                            logger.info("Received [DONE] signal, finishing stream.")
                            break
                        }

                        // Handle keep-alive messages.
                        if trimmedLine == ": keep-alive" || trimmedLine.lowercased().contains("keep-alive") {
                            logger.debug("Received keep-alive signal, skipping.")
                            continue
                        }

                        // Optionally, remove an optional "data:" prefix.
                        var jsonLine = trimmedLine
                        if jsonLine.hasPrefix("data:") {
                            jsonLine = String(jsonLine.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                        }

                        guard let data = jsonLine.data(using: .utf8) else { continue }

                        do {
                            let streamingResponse = try JSONDecoder().decode(StreamingChatResponse.self, from: data)
                            if let delta = streamingResponse.choices.first?.delta,
                               let text = delta.content, !text.isEmpty {
                                logger.debug("Yielding partial message: \(text)")
                                let message = ChatMessage(content: text, role: .assistant)
                                continuation.yield(message)
                            }
                        } catch {
                            logger.error("Failed to decode chunk: \(error.localizedDescription)")
                            // Optionally log the line causing the error:
                            logger.debug("Error decoding line: \(jsonLine)")
                        }
                    }
                    continuation.finish()
                } catch {
                    logger.error("Streaming request failed: \(error.localizedDescription))")
                    continuation.finish(throwing: error)
                }
            }
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
    case deepseek = "deepseek-chat"
    case reasoner = "deepseek-reasoner"
}

struct DeepseekRChatMessage: Identifiable {
    let id: String = UUID().uuidString
    var content: ChatMessage
    let warning: String?
}

struct ChatMessage: Codable {
    var content: String
    let role: MessageSourceType
    var name: String? = nil
}

struct ChatRequest: Encodable {
    let messages: [ChatMessage]
    let model: Model
    let stream: Bool
}

/// The full-response model (non-streaming)
struct ChatResponse: Decodable {
    let id: String
    let created: Date
    let model: String
    let choices: [ChoiceMessage]
}

struct ChoiceMessage: Decodable {
    let index: Int
    let message: ChatMessage
}

/// MARK: - Streaming Models

/// Model for streaming responses (chunks use "delta" instead of "message")
struct StreamingChatResponse: Decodable {
    let id: String
    let created: Int
    let model: String
    let choices: [StreamingChoice]
}

struct StreamingChoice: Decodable {
    let index: Int
    let delta: Delta?
    let finish_reason: String?

    struct Delta: Decodable {
        let role: MessageSourceType?
        let content: String?
    }
}

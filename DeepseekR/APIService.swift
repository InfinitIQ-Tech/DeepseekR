//
//  APIService.swift
//  DeepseekR
//
//  Created by Kenneth Dubroff on 1/22/25.
//

import Foundation

class APIHandler: ObservableObject {
    enum Error: Swift.Error {
        case systemMessageMustBeFirst
        case noMessageReceivedFromAssistant
    }
    private let apiKey = ""
    private let chatURL = URL(string: "https://api.deepseek.com/chat/completions")!
    private let networkService = NetworkService()
    private var bearerToken: String {
        "Bearer \(apiKey)"
    }

    // TODO: Implement Streaming
    private static let shouldStream = false

    var existingMessages: [ChatMessage] = []

    func createSystemMessage(_ content: String) throws -> DeepseekRChatMessage {
        guard existingMessages.isEmpty else { throw Error.systemMessageMustBeFirst }
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

        let (data, response) = try await networkService.loadData(using: request)
        if response.statusCode != 200 {
            print("Error: \(String(data: data, encoding: .utf8) ?? "No Data")")
        }

        print(String(data: data, encoding: .utf8) ?? "No Data")
        let decodedResponse = try networkService.decode(ChatResponse.self, from: data)
        guard let firstMessage = decodedResponse.choices.first?.message else {
            throw Error.noMessageReceivedFromAssistant
        }
        self.existingMessages.append(firstMessage)
        return firstMessage
    }
}

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

struct ChoiceMessage: Decodable {
    let index: Int
    let message: ChatMessage
}

struct ChatResponse: Decodable {
    let id: String
    let created: Date
    let model: String
    let choices: [ChoiceMessage]
}

/// Provide default error and response handling for network tasks
protocol NetworkLoadable {
    func data(using: URLRequest) async throws -> (Data, HTTPURLResponse)
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

enum NetworkError: Error {
    case invalidResponse
    case invalidURL
    case encodingFailed
    case decodingFailed
}

class NetworkService {
    // MARK: - Types -
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
                "application/json"
            case .authorization(let string):
                string
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

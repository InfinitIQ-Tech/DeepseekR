//
//  ContentView.swift
//  DeepseekR
//
//  Created by Kenneth Dubroff on 1/22/25.
//

import SwiftUI

struct ContentView: View {
    // Make messages publicly settable for preview purposes.
    @State var messages: [DeepseekRChatMessage] = []
    @State private var systemMessage: String = ""

    // Holds the partial streaming text while receiving a response.
    @State private var streamingOutput: String = ""
    @State private var isStreaming: Bool = false
    @State private var userMessage: String = ""

    // Error state for showing alerts.
    @State private var errorMessage: String?
    @State private var showErrorAlert: Bool = false

    // New initializer that accepts a previewMessages parameter.
    // When using in production, you can simply call ContentView()
    init(previewMessages: [DeepseekRChatMessage] = []) {
        _messages = State(initialValue: previewMessages)
    }

    var body: some View {
        VStack {
            // If no system message has been set, prompt the user to add one.
            if messages.isEmpty {
                Text("""
                     The system message is empty. This can only be set before sending your first message to DeepseekR.
                     
                     Setting a system message guides DeepseekR on how to interact with you.
                     """)
                    .foregroundColor(.yellow)
                    .bold()
                TextField("Set a system message here", text: $systemMessage)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding()
                    .onSubmit {
                        do {
                            let systemMsg = try APIHandler().createSystemMessage(systemMessage)
                            messages.append(systemMsg)
                        } catch {
                            print("Error setting system message: \(error)")
                        }
                    }
            }

            // Display the conversation messages.
            ScrollView {
                LazyVStack(alignment: .leading) {
                    ForEach(messages, id: \.id) { message in
                        MessageView(message: message)
                    }
                }
                .frame(maxWidth: .infinity) // Force the LazyVStack to use full width
            }
            .padding()

            // Show streaming output if a response is in progress.
            if isStreaming {
                if streamingOutput.isEmpty {
                    ProgressView("Waiting for response...")
                } else {
                    VStack(alignment: .leading) {
                        Text("Streaming Assistant Reply:")
                            .foregroundColor(.blue)
                            .padding(.bottom, 4)
                        ScrollView {
                            Text(streamingOutput)
                                .padding(8)
                                .background(Color.gray.opacity(0.2))
                                .cornerRadius(8)
                        }
                        .frame(height: 150)
                        .padding(.horizontal)
                    }
                }
            }

            Divider()

            // Input area for the user query.
            Text("Seek the deep:")
            TextField("Enter your query here...", text: $userMessage)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding()
                .onSubmit {
                    guard !userMessage.isEmpty else { return }

                    // Append the user message.
                    let chatMessage = ChatMessage(content: userMessage, role: .user)
                    let userChatMessage = DeepseekRChatMessage(content: chatMessage, warning: nil)
                    messages.append(userChatMessage)

                    // Capture the query and clear the field.
                    let query = userMessage
                    userMessage = ""

                    // Reset streaming state.
                    isStreaming = true
                    streamingOutput = ""

                    Task {
                        do {
                            // Begin streaming.
                            let stream = APIHandler().sendUserMessageStream(fromUser: "User", for: .deepseek, content: query)
                            var assistantReply = ""
                            for try await partialMessage in stream {
                                await MainActor.run {
                                    assistantReply += partialMessage.content
                                    streamingOutput = assistantReply
                                }
                            }
                            // Append the final assistant response.
                            let assistantMessage = ChatMessage(content: assistantReply, role: .assistant)
                            let assistantChatMessage = DeepseekRChatMessage(content: assistantMessage, warning: nil)
                            await MainActor.run {
                                messages.append(assistantChatMessage)
                            }
                        } catch {
                            await MainActor.run {
                                errorMessage = error.localizedDescription
                                showErrorAlert = true
                                streamingOutput += "\nError: \(error.localizedDescription)"
                            }
                        }
                        await MainActor.run { isStreaming = false }
                    }
                }
        }
        .padding()
        // Alert to show any errors.
        .alert(isPresented: $showErrorAlert) {
            Alert(
                title: Text("Error"),
                message: Text(errorMessage ?? "Unknown error occurred."),
                dismissButton: .default(Text("OK"), action: { errorMessage = nil })
            )
        }
    }
}


#Preview {
    ContentView()
}

#Preview("Messages") {
    let previewMessages = [
        DeepseekRChatMessage(content: ChatMessage(content: "Hello, how can I help you?", role: .assistant), warning: nil),
        DeepseekRChatMessage(content: ChatMessage(content: "I'm looking for a recipe for spaghetti.", role: .user), warning: nil),
        DeepseekRChatMessage(content: ChatMessage(content: "Sure, I can help with that. Here's a recipe for spaghetti.", role: .assistant), warning: nil)
    ]
    // Use the new initializer to set preview messages.
    return ContentView(previewMessages: previewMessages)
}


struct MessageView: View {
    let message: DeepseekRChatMessage

    private var foregroundColor: Color {
        switch message.content.role {
        case .assistant:
            return .blue
        case .user:
            return .green
        case .system:
            return .black
        }
    }

    private var prefix: String {
        switch message.content.role {
        case .assistant:
            return "DeepseekR: "
        case .user:
            return "You: "
        case .system:
            return "System Message: "
        }
    }

    private var verticalSpacing: CGFloat {
        switch message.content.role {
        case .assistant, .user:
            return 20
        case .system:
            return 60
        }
    }

    var body: some View {
        VStack {
            if let warning = message.warning {
                Text(warning)
                    .foregroundColor(.yellow)
                    .bold()
            }
            HStack {
                if message.content.role == .system || message.content.role == .user {
                    Spacer()
                }
                Text(prefix)
                    .foregroundColor(foregroundColor)
                Text(message.content.content)
                    .foregroundColor(.primary)
                    .padding(8)
                    .background(Color.gray.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                if message.content.role == .system || message.content.role == .assistant {
                    Spacer()
                }
            }
        }
        .padding(.vertical, verticalSpacing)
    }
}

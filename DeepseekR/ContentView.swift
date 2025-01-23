//
//  ContentView.swift
//  DeepseekR
//
//  Created by Kenneth Dubroff on 1/22/25.
//

import SwiftUI

struct ContentView: View {
    @StateObject
    private var apiHandler = APIHandler()
    @State
    private var messages: [DeepseekRChatMessage] = []
    @State
    private var systemMessage: String = ""

    @State
    private var userMessage: String = ""

    var body: some View {
        VStack {
            if messages.isEmpty {
                Text("""
                     The system message is empty. This can only be set before sending your first message to DeepseekR. 
                     
                     Setting a system message guides DeepseekR on how to interact with you.
                     """)
                    .foregroundColor(.yellow)
                    .bold()
                TextField("Set a system message here", text: $systemMessage)
                    .onSubmit {
                        do {
                            try messages.append(apiHandler.createSystemMessage(systemMessage))
                        } catch {
                            print(error)
                        }
                    }
            }
            ScrollView {
                LazyVStack {
                    ForEach($messages, id: \.id) { $message in
                        VStack {
                            MessageView(message: message)
                        }
                    }
                }
            }
            .padding()
            Divider()
            Text("Seek the deep:")
            TextField("Enter your query here...", text: $userMessage)
                .onSubmit {
                    let chatMessage = ChatMessage(content: userMessage, role: .user)
                    let userChatMessage = DeepseekRChatMessage(content: chatMessage, warning: nil)
                    messages.append(userChatMessage)
                    Task {
                        do {
                            messages.append(try await apiHandler.sendUserMessage(content: userMessage))
                        } catch {
                            print(error)
                            
                        }
                        userMessage = ""
                    }

                }
        }
        .padding()
    }
}

#Preview {
    ContentView()
}

struct MessageView: View {
    let message: DeepseekRChatMessage
    private var foregroundColor: Color {
        switch message.content.role {
        case .assistant:
                .blue
        case .user:
                .green
        case .system:
                .black
        }
    }

    private var prefix: String {
        switch message.content.role {
        case .assistant:
            "DeepseekR: "
        case .user:
            "You: "
        case .system:
            "System Message:"
        }
    }

    private var verticalSpacing: CGFloat {
        switch message.content.role {
        case .assistant, .user:
            20
        case .system:
            60
        }
    }

    var body: some View {
        VStack {
            if let warning = message.warning {
                Text(warning)
                    .foregroundColor(.yellow)
                    .bold()
            }
            HStack{
                if message.content.role == .system || message.content.role == .user {
                    Spacer()
                }
                Text(prefix)
                    .foregroundColor(foregroundColor)


                    Text(message.content.content)
                        .foregroundColor(.primary)
                        .padding(8)
                        .background(.gray)
                        .clipShape(RoundedRectangle(cornerRadius: 16))

                if message.content.role == .system || message.content.role == .assistant {
                    Spacer()
                }
            }
        }
        Spacer()
            .frame(height: verticalSpacing)
    }
}

#Preview {
    struct ChatPreview: View {
        let messages = [
            DeepseekRChatMessage(content: ChatMessage(content: "You are an expert on the English language.", role: .system), warning: nil),
            DeepseekRChatMessage(content: ChatMessage(content: "What is the difference between tree and three?", role: .user), warning: nil),
            DeepseekRChatMessage(content: ChatMessage(content: "One is a plant with multiple trunks and branches. The other is a numerical value.", role: .assistant), warning: nil)

        ]
        var body: some View {
            ForEach(messages, id: \.id) { message in
                MessageView(message: message)
            }
        }
    }

    return ChatPreview()
}

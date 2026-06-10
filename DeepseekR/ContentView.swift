//
//  ContentView.swift
//  DeepseekR
//
//  Created by Kenneth Dubroff on 1/22/25.
//  Updated on 6/09/26 for expert-team (MoE) orchestration.
//

import SwiftUI

enum ChatMode: String, CaseIterable, Identifiable {
    case direct = "Single Expert"
    case team = "Expert Team"

    var id: String { rawValue }
}

struct ContentView: View {
    // Make messages publicly settable for preview purposes.
    @State var messages: [DeepseekRChatMessage] = []
    @State private var systemMessage: String = ""
    @State private var userMessage: String = ""
    @State private var mode: ChatMode = .team

    @StateObject private var expertStore = ExpertStore()
    @State private var apiHandler = APIHandler()
    @State private var orchestrator = MoEOrchestrator()
    @State private var showExpertManager = false

    // In-flight turn state.
    @State private var isBusy = false
    @State private var statusText = ""
    @State private var liveReplies: [ExpertReply] = []
    @State private var streamingOutput = ""
    @State private var expertBreakdowns: [String: [ExpertReply]] = [:]

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
            header

            if mode == .direct && messages.isEmpty {
                systemMessagePrompt
            }

            // Display the conversation messages.
            ScrollView {
                LazyVStack(alignment: .leading) {
                    ForEach(messages, id: \.id) { message in
                        MessageView(message: message)
                        if let replies = expertBreakdowns[message.id] {
                            ExpertBreakdownView(replies: replies)
                        }
                    }
                }
                .frame(maxWidth: .infinity) // Force the LazyVStack to use full width
            }
            .padding()

            if isBusy {
                progressPanel
            }

            Divider()

            // Input area for the user query.
            Text("Seek the deep:")
            TextField("Enter your query here...", text: $userMessage)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding()
                .disabled(isBusy)
                .onSubmit(send)
        }
        .padding()
        .sheet(isPresented: $showExpertManager) {
            ExpertManagementView(store: expertStore)
        }
        // Alert to show any errors.
        .alert(isPresented: $showErrorAlert) {
            Alert(
                title: Text("Error"),
                message: Text(errorMessage ?? "Unknown error occurred."),
                dismissButton: .default(Text("OK"), action: { errorMessage = nil })
            )
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            Picker("Mode", selection: $mode) {
                ForEach(ChatMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)
            .disabled(!messages.isEmpty || isBusy)

            Spacer()

            Button("New Chat") {
                resetConversation()
            }
            .disabled(messages.isEmpty || isBusy)

            Button("Experts…") {
                showExpertManager = true
            }
        }
    }

    private var systemMessagePrompt: some View {
        VStack {
            // If no system message has been set, prompt the user to add one.
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
                        let systemMsg = try apiHandler.createSystemMessage(systemMessage)
                        messages.append(systemMsg)
                    } catch {
                        print("Error setting system message: \(error)")
                    }
                }
        }
    }

    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text(statusText)
                    .foregroundColor(.blue)
            }
            ForEach(liveReplies) { reply in
                Label(reply.assignment.expert.name, systemImage: "checkmark.circle")
                    .foregroundColor(.green)
                    .font(.subheadline)
            }
            if !streamingOutput.isEmpty {
                ScrollView {
                    Text(streamingOutput)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(8)
                }
                .frame(maxHeight: 180)
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Sending

    private func send() {
        guard !userMessage.isEmpty, !isBusy else { return }

        let query = userMessage
        userMessage = ""

        // Append the user message.
        let chatMessage = ChatMessage(content: query, role: .user)
        messages.append(DeepseekRChatMessage(content: chatMessage, warning: nil))

        isBusy = true
        streamingOutput = ""
        liveReplies = []

        switch mode {
        case .direct:
            sendDirect(query)
        case .team:
            sendTeam(query)
        }
    }

    private func sendDirect(_ query: String) {
        statusText = "Waiting for response…"
        Task {
            do {
                var assistantReply = ""
                let stream = apiHandler.sendUserMessageStream(fromUser: "User", content: query)
                for try await partialMessage in stream {
                    assistantReply += partialMessage.content
                    streamingOutput = assistantReply
                }
                let assistantMessage = ChatMessage(content: assistantReply, role: .assistant)
                messages.append(DeepseekRChatMessage(content: assistantMessage, warning: nil))
            } catch {
                presentError(error)
            }
            finishTurn()
        }
    }

    private func sendTeam(_ query: String) {
        statusText = "Reasoner is routing…"
        Task {
            do {
                for try await event in orchestrator.respond(to: query, roster: expertStore.experts) {
                    handle(event)
                }
            } catch {
                presentError(error)
            }
            finishTurn()
        }
    }

    private func handle(_ event: OrchestrationEvent) {
        switch event {
        case .routingStarted:
            statusText = "Reasoner is selecting experts…"
        case .routed(let assignments):
            statusText = assignments.isEmpty
                ? "Reasoner is answering directly…"
                : "Consulting \(assignments.map(\.expert.name).joined(separator: ", "))…"
        case .expertReplied(let reply):
            liveReplies.append(reply)
        case .synthesisStarted:
            statusText = "Reasoner is synthesizing…"
        case .synthesisReasoning:
            statusText = "Reasoner is thinking…"
        case .synthesisDelta(let delta):
            streamingOutput += delta
        case .finished(let finalAnswer):
            let names = liveReplies.map { $0.assignment.expert.name }
            let attribution = names.isEmpty ? nil : "Experts consulted: \(names.joined(separator: ", "))"
            let message = DeepseekRChatMessage(
                content: ChatMessage(content: finalAnswer, role: .assistant),
                warning: attribution
            )
            if !liveReplies.isEmpty {
                expertBreakdowns[message.id] = liveReplies
            }
            messages.append(message)
        }
    }

    private func finishTurn() {
        isBusy = false
        streamingOutput = ""
        liveReplies = []
        statusText = ""
    }

    private func resetConversation() {
        messages = []
        expertBreakdowns = [:]
        systemMessage = ""
        apiHandler = APIHandler()
        orchestrator = MoEOrchestrator()
    }

    private func presentError(_ error: Error) {
        errorMessage = error.localizedDescription
        showErrorAlert = true
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

/// Collapsible per-turn record of which experts answered and what they said.
struct ExpertBreakdownView: View {
    let replies: [ExpertReply]
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(replies) { reply in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(reply.assignment.expert.name)
                            .bold()
                        if reply.assignment.isDynamicallyAssembled {
                            Text("(assembled for this question)")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                    Text("Asked: \(reply.assignment.question)")
                        .font(.subheadline)
                        .italic()
                        .foregroundColor(.secondary)
                    Text(reply.answer)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
            }
        } label: {
            Text("Expert breakdown (\(replies.count))")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal)
    }
}

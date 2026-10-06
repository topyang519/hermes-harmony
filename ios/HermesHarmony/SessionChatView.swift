import SwiftUI

struct SessionChatView: View {
    @EnvironmentObject private var gateway: GatewayClient
    let sessionId: String
    @State private var draft = ""

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                if let status = gateway.statusText[sessionId], !status.isEmpty {
                    Text(status)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .privacySensitive()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(gateway.lines[sessionId] ?? []) { line in
                                bubble(line)
                                    .id(line.id)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                    .onChange(of: gateway.lines[sessionId]?.count ?? 0) { _, _ in
                        if let last = gateway.lines[sessionId]?.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }

                HStack(spacing: 8) {
                    TextField("输入任务…", text: $draft)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        .foregroundStyle(Theme.text)
                        .background(Theme.input)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Theme.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    Button("发送") {
                        let text = draft
                        draft = ""
                        gateway.dispatch(sessionId: sessionId, text: text)
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.85))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .disabled(!gateway.connected)
                }
                .padding(12)
                .background(Theme.card)
            }
        }
        .navigationTitle("对话")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            gateway.selectSession(sessionId)
        }
    }

    @ViewBuilder
    private func bubble(_ line: ChatLine) -> some View {
        let isUser = line.kind == "user"
        HStack {
            if isUser { Spacer(minLength: 40) }
            Text(line.text)
                .font(.system(size: 15))
                .privacySensitive()
                .foregroundStyle(isUser ? Color.black.opacity(0.9) : Theme.text)
                .padding(12)
                .background(isUser ? Theme.accent : Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            if !isUser { Spacer(minLength: 40) }
        }
    }
}

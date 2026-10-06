import SwiftUI

struct RootView: View {
    @EnvironmentObject private var gateway: GatewayClient
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            SessionListView(showSettings: $showSettings)
                .navigationDestination(for: String.self) { sessionId in
                    SessionChatView(sessionId: sessionId)
                }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(gateway)
        }
        .task {
            let creds = Credentials.load()
            if creds.validate() == nil {
                await gateway.connect()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            gateway.setForeground(phase == .active)
        }
    }
}

struct SessionListView: View {
    @EnvironmentObject private var gateway: GatewayClient
    @Binding var showSettings: Bool

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hermes")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(Theme.text)
                        Text(statusLabel)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(statusColor)
                    }
                    Spacer()
                    Button("设置") { showSettings = true }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)

                if !gateway.connected {
                    offlineCard
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }

                HStack {
                    Text("任务")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.muted)
                    Spacer()
                    Button("+ 新建") {
                        gateway.newSession()
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.85))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .disabled(!gateway.connected)
                    .opacity(gateway.connected ? 1 : 0.4)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

                if gateway.sessions.isEmpty {
                    Spacer()
                    Text(gateway.connected ? "还没有任务，点「新建」开始" : "连接后可新建任务")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    List(gateway.sessions) { item in
                        NavigationLink(value: item.id) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.title)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                                Text(item.preview.isEmpty ? "暂无内容" : item.preview)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.secondary)
                                    .privacySensitive()
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowBackground(Theme.card)
                    }
                    .scrollContentBackground(.hidden)
                    .listStyle(.plain)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var statusLabel: String {
        if gateway.connected {
            return gateway.hermesOnline ? "已连接" : "网关在线 · Hermes 离线"
        }
        return "离线"
    }

    private var statusColor: Color {
        if gateway.connected && gateway.hermesOnline { return Theme.success }
        if gateway.connected { return Theme.accent }
        return Theme.danger
    }

    private var offlineCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("尚未连上网关")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text(gateway.lastError.isEmpty
               ? "打开设置，填入访问令牌（公网或局域网），再连接。"
               : gateway.lastError)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("去设置") { showSettings = true }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.85))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(16)
        .background(Theme.card)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

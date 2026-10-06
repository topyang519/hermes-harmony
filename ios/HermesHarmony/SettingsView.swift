import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var gateway: GatewayClient
    @Environment(\.dismiss) private var dismiss

    @State private var gatewayURL = Credentials.defaultGateway
    @State private var appPassword = ""
    @State private var showSecrets = false
    @State private var note = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("连接 Hermes")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(Theme.text)
                        Text("输入网关应用密码。凭据保存在 Keychain。")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondary)

                        card {
                            field("网关", Credentials.gatewayExample, $gatewayURL, secret: false)
                            field("应用密码", "网关应用密码", $appPassword, secret: true)
                            Button(showSecrets ? "隐藏密文" : "显示密文") {
                                showSecrets.toggle()
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.accent)
                        }

                        Button(busy ? "连接中…" : "保存并连接") {
                            Task { await saveAndConnect() }
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .disabled(busy)

                        if !note.isEmpty {
                            Text(note)
                                .font(.system(size: 13))
                                .foregroundStyle(gateway.connected ? Theme.success : Theme.danger)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.card)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }

                        Text("Mac：hermes-harmony/.secrets/app_token")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(Theme.accent)
                }
            }
            .onAppear {
                let c = Credentials.load()
                gatewayURL = c.gatewayURL
                appPassword = c.appPassword
                if gateway.connected {
                    note = gateway.hermesOnline ? "已连接 · Hermes 在线" : "已连接 · 等待 Hermes"
                } else if !gateway.lastError.isEmpty {
                    note = gateway.lastError
                }
            }
        }
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            content()
        }
        .padding(16)
        .background(Theme.card)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Theme.border.opacity(0.8), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func field(_ title: String, _ hint: String, _ text: Binding<String>, secret: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text(hint)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
            Group {
                if secret && !showSecrets {
                    SecureField(hint, text: text)
                } else {
                    TextField(hint, text: text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .foregroundStyle(Theme.text)
            .background(Theme.input)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func saveAndConnect() async {
        busy = true
        note = "正在保存并连接…"
        var creds = Credentials(
            gatewayURL: gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines),
            appPassword: appPassword.trimmingCharacters(in: .whitespacesAndNewlines),
            cfId: "",
            cfSecret: ""
        )
        if let problem = creds.validate() {
            note = problem
            busy = false
            return
        }
        guard creds.save() else {
            note = "无法安全保存连接凭据，请检查设备钥匙串状态后重试。"
            busy = false
            return
        }
        await gateway.connect()
        if gateway.connected {
            note = gateway.hermesOnline ? "已连接 · Hermes 在线" : "已连接 · 等待 Hermes"
        } else {
            note = gateway.lastError.isEmpty ? "未连接" : gateway.lastError
        }
        busy = false
    }
}

import Foundation
import Combine

struct ChatLine: Identifiable, Equatable {
    let id: String
    let text: String
    let kind: String
}

struct SessionItem: Identifiable, Equatable {
    let id: String
    var title: String
    var preview: String
}

@MainActor
final class GatewayClient: ObservableObject {
    @Published var connected = false
    @Published var hermesOnline = false
    @Published var lastError = ""
    @Published var sessions: [SessionItem] = []
    @Published var lines: [String: [ChatLine]] = [:]
    @Published var statusText: [String: String] = [:]

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var connectionID = UUID()
    private var reconnectTask: Task<Void, Never>?
    private var isForeground = true
    private var selectedSessionId = ""
    private var readyContinuation: CheckedContinuation<Bool, Never>?

    func connect() async {
        let creds = Credentials.load()
        if let problem = creds.validate() {
            lastError = problem
            connected = false
            return
        }
        reconnectTask?.cancel()
        reconnectTask = nil
        disconnect(intentional: true)
        lastError = ""
        connected = false
        hermesOnline = false

        let password = creds.appPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: creds.gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), ["ws", "wss"].contains(scheme),
              let host = components.host, !host.isEmpty,
              (scheme == "wss" || isLocalWebSocketHost(host)),
              components.user == nil, components.password == nil,
              components.fragment == nil, components.url != nil else {
            lastError = "网关地址无效：公网网关请使用 wss://"
            return
        }
        // The bridge relay authenticates the WebSocket upgrade from this query item.
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "password" || $0.name == "token" }
        queryItems.append(URLQueryItem(name: "password", value: password))
        components.queryItems = queryItems
        guard let url = components.url else {
            lastError = "网关地址无效"
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(password, forHTTPHeaderField: "X-Hermes-App-Password")
        // Retain the previous auth header for compatible older gateway prototypes.
        request.setValue("Bearer \(password)", forHTTPHeaderField: "Authorization")
        let cfId = creds.cfId.trimmingCharacters(in: .whitespacesAndNewlines)
        let cfSecret = creds.cfSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cfId.isEmpty {
            request.setValue(cfId, forHTTPHeaderField: "CF-Access-Client-Id")
        }
        if !cfSecret.isEmpty {
            request.setValue(cfSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        let urlSession = URLSession(configuration: config)
        session = urlSession
        let ws = urlSession.webSocketTask(with: request)
        task = ws
        let currentConnectionID = connectionID
        ws.resume()
        Task { await self.receiveLoop(for: ws, connectionID: currentConnectionID) }

        let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            self.readyContinuation = cont
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                if currentConnectionID == self.connectionID,
                   let pending = self.readyContinuation {
                    self.readyContinuation = nil
                    pending.resume(returning: self.connected)
                }
            }
            // The protocol requires hello before the server sends ready. Install the
            // continuation first so a fast ready response cannot be lost.
            send(["t": "hello", "app": "0.6.8", "proto": 2, "dev": "iphone"])
        }

        guard currentConnectionID == connectionID else { return }
        if !ok {
            if lastError.isEmpty {
                lastError = "未收到 ready（检查令牌与网络）"
            }
            connected = false
            scheduleReconnect(for: currentConnectionID)
        }
    }

    func disconnect(intentional: Bool = false) {
        connectionID = UUID()
        if let pending = readyContinuation {
            readyContinuation = nil
            pending.resume(returning: false)
        }
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        connected = false
        if intentional {
            reconnectTask?.cancel()
            reconnectTask = nil
            hermesOnline = false
        }
    }

    func setForeground(_ foreground: Bool) {
        guard foreground != isForeground else { return }
        isForeground = foreground
        if foreground {
            Task { await connect() }
        } else {
            reconnectTask?.cancel()
            reconnectTask = nil
            disconnect()
        }
    }

    func newSession(title: String = "iOS") {
        send(["t": "new_session", "title": title])
    }

    func listSessions() {
        send(["t": "sessions"])
    }

    func selectSession(_ id: String) {
        selectedSessionId = id
        if lines[id] == nil {
            lines[id] = []
        }
        send(["t": "sub", "session": id, "last_seen": 0])
    }

    func dispatch(sessionId: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        append(sessionId: sessionId, text: trimmed, kind: "user")
        send(["t": "dispatch", "session": sessionId, "text": trimmed])
    }

    private func send(_ obj: [String: Any]) {
        guard let socket = task,
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        let currentConnectionID = connectionID
        socket.send(.string(text)) { [weak self] error in
            if error != nil {
                Task { @MainActor in
                    guard let self,
                          self.connectionID == currentConnectionID,
                          self.task === socket else { return }
                    self.lastError = "发送失败：连接已中断"
                    self.connected = false
                    self.task = nil
                    self.session?.invalidateAndCancel()
                    self.session = nil
                    self.scheduleReconnect(for: currentConnectionID)
                }
            }
        }
    }

    private func receiveLoop(for socket: URLSessionWebSocketTask, connectionID: UUID) async {
        while connectionID == self.connectionID, task === socket {
            do {
                let message = try await socket.receive()
                switch message {
                case .string(let text):
                    guard connectionID == self.connectionID, task === socket else { return }
                    handleText(text)
                case .data:
                    break
                @unknown default:
                    break
                }
            } catch {
                if connectionID == self.connectionID, task === socket {
                    connected = false
                    lastError = "连接中断"
                    task = nil
                    session?.invalidateAndCancel()
                    session = nil
                    if let pending = readyContinuation {
                        readyContinuation = nil
                        pending.resume(returning: false)
                    }
                    scheduleReconnect(for: connectionID)
                }
                break
            }
        }
    }

    private func handleText(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = obj["t"] as? String else { return }

        switch kind {
        case "ready":
            guard task != nil else { return }
            connected = true
            hermesOnline = (obj["hermes"] as? Bool) == true
            lastError = ""
            reconnectTask?.cancel()
            reconnectTask = nil
            if let pending = readyContinuation {
                readyContinuation = nil
                pending.resume(returning: true)
            }
            listSessions()
            if !selectedSessionId.isEmpty {
                send(["t": "sub", "session": selectedSessionId, "last_seen": 0])
            }
        case "sessions":
            if let created = obj["created"] as? String, !created.isEmpty {
                if !sessions.contains(where: { $0.id == created }) {
                    sessions.insert(SessionItem(id: created, title: "新任务", preview: ""), at: 0)
                }
                selectSession(created)
            }
            if let list = obj["list"] as? [[String: Any]] {
                sessions = list.compactMap { row in
                    let id = (row["id"] as? String)
                        ?? (row["session_id"] as? String)
                        ?? (row["stored_session_id"] as? String)
                        ?? ""
                    guard !id.isEmpty else { return nil }
                    let title = (row["title"] as? String)?.nilIfEmpty ?? id
                    let preview = (row["preview"] as? String) ?? ""
                    return SessionItem(id: id, title: title, preview: preview)
                }
            }
        case "ev":
            if let params = obj["p"] as? [String: Any] {
                ingest(params)
            }
        case "error":
            lastError = "网关返回错误"
        case "ping":
            send(["t": "pong"])
        default:
            break
        }
    }

    private func scheduleReconnect(for failedConnectionID: UUID) {
        guard isForeground else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, failedConnectionID == self.connectionID, self.isForeground else { return }
            self.reconnectTask = nil
            await self.connect()
        }
    }

    private func ingest(_ params: [String: Any]) {
        let sid = (params["session_id"] as? String) ?? selectedSessionId
        guard !sid.isEmpty else { return }
        let type = (params["type"] as? String) ?? ""
        let payload = params["payload"] as? [String: Any] ?? [:]
        let text = (payload["text"] as? String)
            ?? (payload["rendered"] as? String)
            ?? ""

        if type == "message.delta" || type == "message.complete" {
            if !text.isEmpty {
                append(sessionId: sid, text: text, kind: "assistant", mergeAssistant: type == "message.delta")
            }
        } else if type == "status.update" {
            statusText[sid] = text
        } else if type.hasPrefix("tool.") {
            let name = (payload["name"] as? String) ?? "tool"
            append(sessionId: sid, text: "\(type) \(name)", kind: "meta")
        }
    }

    private func append(sessionId: String, text: String, kind: String, mergeAssistant: Bool = false) {
        var bucket = lines[sessionId] ?? []
        if mergeAssistant, let last = bucket.last, last.kind == "assistant" {
            bucket[bucket.count - 1] = ChatLine(id: last.id, text: last.text + text, kind: "assistant")
        } else {
            bucket.append(ChatLine(id: UUID().uuidString, text: text, kind: kind))
        }
        lines[sessionId] = bucket
        if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
            sessions[idx].preview = text
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

import Foundation
import CryptoKit

typealias BridgeObject = [String: Any]

private func bridgeError(_ message: String) -> RelayError { .stopped(message) }

private func bridgeString(_ object: BridgeObject, _ keys: [String]) -> String? {
    for key in keys {
        if let value = object[key] as? String, !value.isEmpty { return value }
        if let value = object[key] as? NSNumber { return value.stringValue }
    }
    return nil
}

private func bridgeBody(_ object: BridgeObject, key: String) -> BridgeObject {
    object[key] as? BridgeObject ?? object
}

struct BridgeConnection {
    let url: URL
    let headers: [String: String]

    init(_ input: String) throws {
        let input = clean(input)
        var parameters: BridgeObject = ["url": input.isEmpty ? "http://127.0.0.1:21454/mcp" : input]
        if input.hasPrefix("{"),
           let decoded = try JSONSerialization.jsonObject(with: Data(input.utf8)) as? BridgeObject {
            if let servers = decoded["mcpServers"] as? [String: BridgeObject] {
                if let selected = servers["x1a0he_wechat_mcp"] { parameters = selected }
                else if servers.count == 1, let only = servers.values.first { parameters = only }
                else { throw bridgeError("配置中有多个 MCP。请只粘贴微信插件的 HTTP 配置。") }
            } else { parameters = decoded }
        }
        guard let raw = parameters["url"] as? String,
              let url = URL(string: raw), let scheme = url.scheme, ["http", "https"].contains(scheme),
              let host = url.host, ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased()),
              url.user == nil, url.password == nil, url.fragment == nil else {
            throw bridgeError("请输入插件「关于 MCP」提供的本机 HTTP 配置。只允许连接本机地址，不支持 stdio 配置。")
        }
        self.url = url
        headers = (parameters["headers"] as? [String: String] ?? [:]).filter {
            !["host", "content-length", "connection", "transfer-encoding", "accept", "content-type",
              "mcp-session-id", "mcp-protocol-version"].contains($0.key.lowercased()) &&
            !$0.value.contains("\r") && !$0.value.contains("\n")
        }
    }
}

private final class NoBridgeRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class LocalMCP {
    private let connection: BridgeConnection
    private let session: URLSession
    private var protocolVersion = "2025-03-26"
    private var sessionID: String?
    private var nextID = 0

    init(connection: BridgeConnection) {
        self.connection = connection
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 18
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration, delegate: NoBridgeRedirect(), delegateQueue: nil)
    }

    func initialize() async throws {
        let response = try await request("initialize", [
            "protocolVersion": protocolVersion, "capabilities": BridgeObject(),
            "clientInfo": ["name": "Local WeChat Relay", "version": "1.5"]
        ])
        guard let server = response["serverInfo"] as? BridgeObject,
              let name = server["name"] as? String,
              name.lowercased().contains("x1a0he") else {
            throw bridgeError("本机地址的服务没有标识为 X1a0He 微信插件。")
        }
        if let negotiated = response["protocolVersion"] as? String { protocolVersion = negotiated }
        _ = try await request("notifications/initialized", [:], notification: true)
    }

    func tools() async throws -> [String: BridgeTool] {
        var tools: [String: BridgeTool] = [:]
        var cursor: String?
        for _ in 0..<8 {
            let response = try await request("tools/list", cursor.map { ["cursor": $0] } ?? [:])
            for record in response["tools"] as? [BridgeObject] ?? [] {
                if let name = record["name"] as? String, let schema = record["inputSchema"] as? BridgeObject {
                    tools[name] = BridgeTool(name: name, schema: schema)
                }
            }
            cursor = response["nextCursor"] as? String
            if cursor == nil { return tools }
        }
        throw bridgeError("插件工具列表分页未结束。")
    }

    func call(_ tool: BridgeTool, _ args: BridgeObject) async throws -> BridgeObject {
        let response = try await request("tools/call", ["name": tool.name, "arguments": args])
        guard (response["isError"] as? Bool) != true else {
            throw bridgeError("插件拒绝了「\(tool.name)」操作。请检查插件对当前账号的工具权限。")
        }
        let payload: BridgeObject
        if let structured = response["structuredContent"] as? BridgeObject { payload = structured }
        else if let blocks = response["content"] as? [BridgeObject] {
            let decoded = blocks.compactMap { block -> BridgeObject? in
                guard let text = block["text"] as? String else { return nil }
                return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? BridgeObject
            }
            guard let first = decoded.first else {
                throw bridgeError("插件「\(tool.name)」未返回可核对的结构化结果。")
            }
            payload = first
        } else { payload = response }
        if payload["error"] != nil || payload["success"] as? Bool == false || payload["ok"] as? Bool == false {
            throw bridgeError("插件「\(tool.name)」返回失败。")
        }
        return payload.merging(payload["data"] as? BridgeObject ?? [:]) { _, child in child }
    }

    private func request(_ method: String, _ params: BridgeObject, notification: Bool = false) async throws -> BridgeObject {
        try Task.checkCancellation()
        nextID += 1
        let id = nextID
        var body: BridgeObject = ["jsonrpc": "2.0", "method": method, "params": params]
        if !notification { body["id"] = id }
        var request = URLRequest(url: connection.url)
        request.httpMethod = "POST"
        connection.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(method, forHTTPHeaderField: "Mcp-Method")
        if let toolName = params["name"] as? String { request.setValue(toolName, forHTTPHeaderField: "Mcp-Name") }
        if method != "initialize" { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, metadata) = try await session.bytes(for: request)
        guard let http = metadata as? HTTPURLResponse else { throw bridgeError("没有收到本机插件的 HTTP 响应。") }
        if method == "initialize" { sessionID = http.value(forHTTPHeaderField: "Mcp-Session-Id") }
        if [401, 403].contains(http.statusCode) { throw bridgeError("插件拒绝访问。请粘贴「关于 MCP」提供的完整 HTTP 配置。") }
        guard (200...299).contains(http.statusCode) else {
            throw bridgeError("插件接口返回 HTTP \(http.statusCode)。")
        }
        if notification { return [:] }
        if http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true {
            var fields: [String] = []
            for try await line in bytes.lines {
                if line.hasPrefix("data:") {
                    let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    guard data.utf8.count < 8_000_000, fields.count < 100 else {
                        throw bridgeError("插件事件响应超过大小限制。")
                    }
                    // Most MCP servers put the entire response on one SSE data line.
                    if fields.isEmpty, (try? JSONSerialization.jsonObject(with: Data(data.utf8))) != nil,
                       let result = try decode(Data(data.utf8), id: id) { return result }
                    fields.append(data)
                } else if line.isEmpty, !fields.isEmpty {
                    if let result = try decode(Data(fields.joined(separator: "\n").utf8), id: id) { return result }
                    fields.removeAll()
                } else if line.hasPrefix("event:"), !fields.isEmpty {
                    if let result = try decode(Data(fields.joined(separator: "\n").utf8), id: id) { return result }
                    fields.removeAll()
                }
            }
            if !fields.isEmpty, let result = try decode(Data(fields.joined(separator: "\n").utf8), id: id) { return result }
        } else {
            var payload = Data()
            for try await byte in bytes {
                guard payload.count < 8_000_000 else { throw bridgeError("插件响应超过大小限制。") }
                payload.append(byte)
            }
            if let result = try decode(payload, id: id) { return result }
        }
        throw bridgeError("插件没有返回与请求匹配的结果。")
    }

    private func decode(_ payload: Data, id: Int) throws -> BridgeObject? {
        guard let envelope = try JSONSerialization.jsonObject(with: payload) as? BridgeObject,
              envelope["id"] as? Int == id else { return nil }
        if let error = envelope["error"] as? BridgeObject {
            throw bridgeError("插件 RPC 返回错误（\(error["code"] as? Int ?? -1)）。")
        }
        return envelope["result"] as? BridgeObject
    }
}

struct BridgeTool {
    let name: String
    let schema: BridgeObject
    var properties: [String: BridgeObject] { schema["properties"] as? [String: BridgeObject] ?? [:] }

    func arguments(_ values: [([String], Any)]) throws -> BridgeObject {
        var output: BridgeObject = [:]
        for (keys, value) in values {
            if let key = keys.first(where: { properties[$0] != nil }) { output[key] = value }
        }
        let missing = (schema["required"] as? [String] ?? []).filter { output[$0] == nil }
        guard missing.isEmpty else {
            throw bridgeError("插件「\(name)」工具参数与当前适配不一致。缺少字段：\(missing.joined(separator: "、"))。")
        }
        return output
    }

    func supports(_ alternatives: [String]) -> Bool {
        alternatives.contains { properties[$0] != nil }
    }
}

struct BridgeGroup: Equatable {
    let id: String
    let name: String

    init?(_ object: BridgeObject) {
        let object = bridgeBody(object, key: "conversation")
        guard let id = bridgeString(object, ["conversation_id", "session_id", "user_id", "username", "id", "talker"]),
              let name = bridgeString(object, ["display_name", "conversation_name", "group_name", "name", "title", "nickname"]),
              id.hasSuffix("@chatroom") else { return nil }
        self.id = id
        self.name = clean(name)
    }

    private init(id: String, name: String) { self.id = id; self.name = name }
    static func fixture(_ id: String, _ name: String) -> BridgeGroup { BridgeGroup(id: id + "@chatroom", name: name) }
}

struct BridgeQuote: Equatable {
    let id: String?
    let sender: String?
    let content: String?
}

struct BridgeMessage: Equatable {
    let id: String
    let sender: String
    let content: String
    let own: Bool
    let quote: BridgeQuote?

    init?(_ object: BridgeObject) {
        guard let id = bridgeString(object, ["message_ref", "message_id", "server_id", "local_id", "id", "msg_id"]), id != "0",
              let content = bridgeString(object, ["text", "content", "body"]), !clean(content).isEmpty,
              let type = bridgeString(object, ["type", "message_type", "native_type", "kind"])?.lowercased(),
              ["1", "text", "plain_text", "reply", "quote", "text_reply", "quoted_text", "reference", "refer"].contains(type) else { return nil }
        self.id = id
        self.content = content
        own = ["is_outgoing", "is_self", "is_send", "from_self", "outgoing", "self_sent"].contains { key in
            object[key] as? Bool == true || (object[key] as? String)?.lowercased() == "true"
        } || ["outgoing", "sent", "send"].contains((object["direction"] as? String)?.lowercased() ?? "")
        self.sender = bridgeString(object, ["sender_name", "sender_display_name", "display_name", "nickname"]) ?? (own ? "我" : "未知")
        if let ref = ["quote", "reference", "quoted_message", "reply_to", "refer", "reply"].compactMap({ object[$0] as? BridgeObject }).first {
            quote = BridgeQuote(id: bridgeString(ref, ["message_ref", "message_id", "server_id", "local_id", "id"]),
                                sender: bridgeString(ref, ["sender_name", "sender_display_name", "display_name", "nickname"]),
                                content: bridgeString(ref, ["content", "text", "body"]))
        } else { quote = nil }
    }
}

enum BridgeStyle: Int {
    case short, detailed

    func render(group: BridgeGroup, message: BridgeMessage, quotedGroup: String? = nil,
                quotedSender: String? = nil, quotedText: String? = nil) -> String {
        if self == .short { return "[\(message.sender)@\(group.name)]：\(message.content)" }
        let separator = "--------------------------------"
        var result = "来自 \(group.name) 的 \(message.sender) ：\n\(separator)\n"
        if let quotedGroup, let quotedSender, let quotedText, !clean(quotedText).isEmpty {
            result += "回复 \(quotedGroup) 的 \(quotedSender) ：\n- - - - - - -\n\(quotedText)\n\(separator)\n"
        }
        return result + message.content
    }
}

func bridgeMessageIsRelay(_ text: String) -> Bool {
    text.range(of: #"^(?:来自 [^\n]+ 的 [^\n]+\s*[：:]\r?\n-{8,}|\[[^\]\n]+@[^\]\n]+\][：:])"#,
               options: .regularExpression) != nil
}

func bridgeToken(_ parts: [String]) -> String {
    let tagged = parts.map { "\($0.utf8.count):\($0)" }.joined()
    return SHA256.hash(data: Data(tagged.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
}

private let accountKeys = ["account_id", "account"]
private let groupKeys = ["conversation_id", "session_id", "chat_id", "target", "receiver", "conversation", "target_id"]
private let textKeys = ["text", "content", "message"]

@MainActor
final class WeChatBridge {
    private let client: LocalMCP
    private let available: [String: BridgeTool]
    private let account: [([String], Any)]
    private let sendClock = ContinuousClock()
    private var nextSubmission: ContinuousClock.Instant?

    init(connection: BridgeConnection, requestedAccount: String?) async throws {
        let client = LocalMCP(connection: connection)
        try await client.initialize()
        let available = try await client.tools()
        guard available["messages.query"] != nil || available["messages.read"] != nil,
              available["messages.send_text"] != nil else {
            throw bridgeError("没有找到微信插件的消息读取和发送工具。请核对插件 MCP 配置或工具权限。")
        }
        self.client = client
        self.available = available
        let requested = requestedAccount.flatMap { $0.isEmpty ? nil : $0 }
        if let tool = available["accounts.list"] {
            let result = try await client.call(tool, try tool.arguments([]))
            let rows = result["accounts"] as? [BridgeObject] ?? result["items"] as? [BridgeObject] ?? []
            let enabled = rows.compactMap { row -> (String, BridgeObject)? in
                guard (row["enabled"] as? Bool) != false, (row["mcp_enabled"] as? Bool) != false,
                      (row["logged_in"] as? Bool) != false, (row["ready"] as? Bool) != false,
                      let id = bridgeString(row, ["account_id", "id", "account_wxid", "wxid"]),
                      requested == nil || id == requested else { return nil }
                return (id, row)
            }
            guard enabled.count <= 1 else { throw bridgeError("插件返回多个可用账号或微信实例。请核对连接设置。") }
            guard let (id, row) = enabled.first else { throw bridgeError("没有找到已登录并启用 MCP 的指定微信账号。") }
            account = [(accountKeys, id)] + ["instance_id", "login_generation"].compactMap { key in
                bridgeString(row, [key]).map { ([key], $0 as Any) }
            }
        } else { account = requested.map { [(accountKeys, $0 as Any)] } ?? [] }
    }

    private func tool(_ names: [String]) throws -> BridgeTool {
        guard let tool = names.compactMap({ available[$0] }).first else {
            throw bridgeError("微信插件未提供 \(names.joined(separator: " / "))。")
        }
        return tool
    }

    func resolve(_ names: [String]) async throws -> [BridgeGroup] {
        let list = try tool(["conversations.list", "conversations.read"])
        if list.supports(["query"]) {
            var groups: [BridgeGroup] = []
            for name in names {
                let matches = try await listGroups(list, query: name)
                groups.append(try uniqueGroup(name, among: matches))
            }
            return groups
        }
        let groups = try await listGroups(list, query: nil)
        return try names.map { try uniqueGroup($0, among: groups) }
    }

    private func listGroups(_ list: BridgeTool, query: String?) async throws -> [BridgeGroup] {
        var rows: [BridgeGroup] = []
        var cursor: String?
        var visited = Set<String>()
        for _ in 0..<16 {
            var options = account + [(["page_size", "limit", "count"], 100 as Any)]
            if let query { options.append((["query"], query)) }
            if let cursor { options.append((["cursor", "page_token"], cursor)) }
            let response = try await client.call(list, try list.arguments(options))
            let items = response["conversations"] as? [BridgeObject] ?? response["sessions"] as? [BridgeObject] ??
                        response["items"] as? [BridgeObject] ?? response["results"] as? [BridgeObject]
            guard let items else { throw bridgeError("无法识别插件会话列表的返回格式。") }
            for group in items.compactMap(BridgeGroup.init) where visited.insert(group.id).inserted { rows.append(group) }
            let next = bridgeString(response, ["next_cursor", "nextCursor", "next_page_token"]) ??
                ((response["has_more"] as? Bool == true) ? bridgeString(response, ["cursor"]) : nil)
            if next == nil && response["has_more"] as? Bool != true { return rows }
            guard let next, next != cursor, list.supports(["cursor", "page_token"]) else { break }
            cursor = next
        }
        throw bridgeError("未能完整核对群名单，已停止以免选到同名群。")
    }

    private func uniqueGroup(_ name: String, among groups: [BridgeGroup]) throws -> BridgeGroup {
        let matched = groups.filter { $0.name == name }
        guard matched.count == 1, let match = matched.first else {
            throw bridgeError(matched.isEmpty ? "插件未找到完整群名「\(name)」。" : "有多个同名群「\(name)」，请使用不重名的群名。")
        }
        return match
    }

    private func targetArgument(_ group: BridgeGroup, for tool: BridgeTool) throws -> ([String], Any) {
        guard let key = groupKeys.first(where: { tool.properties[$0] != nil }) else {
            throw bridgeError("插件「\(tool.name)」没有可核对的会话参数。")
        }
        let descriptor = tool.properties[key] ?? [:]
        if descriptor["type"] as? String == "object",
           let properties = descriptor["properties"] as? BridgeObject {
            guard let child = groupKeys.first(where: { properties[$0] != nil }) ??
                    ["id", "user_id", "username"].first(where: { properties[$0] != nil }) else {
                throw bridgeError("插件「\(tool.name)」的目标会话参数格式不受支持。")
            }
            return ([key], [child: group.id])
        }
        return ([key], group.id)
    }

    func recent(_ group: BridgeGroup, count: Int = 60) async throws -> [BridgeMessage] {
        let read = try tool(["messages.query", "messages.read"])
        var options = account + [try targetArgument(group, for: read), (["recent_count", "page_size", "limit", "count"], count as Any)]
        let orderOptions = read.properties["order"]?["enum"] as? [String]
        let requestedDescending = read.supports(["order"]) && (orderOptions == nil || orderOptions?.contains("desc") == true)
        if requestedDescending { options.append((["order"], "desc")) }
        var raw: [BridgeObject] = []
        var cursor: String?
        var complete = false
        for _ in 0..<16 {
            var page = options
            if let cursor { page.append((["cursor", "page_token"], cursor)) }
            let result = try await client.call(read, try read.arguments(page))
            guard let rows = result["messages"] as? [BridgeObject] ?? result["items"] as? [BridgeObject] ??
                    result["results"] as? [BridgeObject] else {
                throw bridgeError("插件未返回可识别的消息列表。")
            }
            raw.append(contentsOf: rows)
            if raw.count >= count || result["has_more"] as? Bool != true { complete = true; break }
            guard let next = bridgeString(result, ["next_cursor", "nextCursor", "next_page_token"]),
                  next != cursor, read.supports(["cursor", "page_token"]) else { break }
            cursor = next
        }
        guard complete else { throw bridgeError("插件未完成近期消息读取。") }
        raw = Array(raw.prefix(count))
        let times = raw.map { row in
            bridgeString(row, ["create_time", "create_time_seconds", "created_at_seconds", "timestamp"]).flatMap(Double.init)
        }
        let base = requestedDescending ? Array(raw.indices.reversed()) : Array(raw.indices)
        let ordered: [Int]
        if times.allSatisfy({ $0 != nil }) {
            // Swift sort preserves the result order for messages in the same second.
            ordered = base.sorted { (times[$0] ?? 0) < (times[$1] ?? 0) }
        } else { ordered = base }
        return ordered.compactMap { BridgeMessage(raw[$0]) }
    }

    func send(text: String, group: BridgeGroup, requestID: String) async throws -> String? {
        let send = try tool(["messages.send_text"])
        guard send.supports(textKeys) else {
            throw bridgeError("插件未提供可核对的文字参数。")
        }
        let args = try send.arguments(account + [
            try targetArgument(group, for: send), (textKeys, text), (["client_request_id"], requestID)
        ])
        if let nextSubmission { try await sendClock.sleep(until: nextSubmission) }
        try Task.checkCancellation()
        // Live tests confirmed that consecutive submissions worked with this spacing.
        defer { nextSubmission = sendClock.now.advanced(by: .seconds(5)) }
        let result = try await client.call(send, args)
        let delivery = bridgeBody(result, key: "delivery")
        let ids = ["message_ref", "message_id", "server_id", "local_id", "msg_id"]
        let id = bridgeString(delivery, ids) ?? bridgeString(result, ids)
        let status = bridgeString(delivery, ["status", "state", "delivery_status"]) ??
            bridgeString(result, ["status", "state", "delivery_status"])
        let success = ["submitted", "sent", "success", "succeeded", "completed", "confirmed"]
        guard result["success"] as? Bool == true || delivery["success"] as? Bool == true ||
                success.contains(status?.lowercased() ?? "") || (id != nil && status == nil) else {
            throw bridgeError("插件没有确认提交给「\(group.name)」。本轮停止，请在微信核对后再重试。")
        }
        return id
    }
}

struct RelayBatchCursor {
    private var latest: [String]?

    mutating func newMessages(in current: [BridgeMessage]) -> (messages: [BridgeMessage], gap: Bool) {
        let ids = current.map(\.id)
        guard let previous = latest else {
            latest = ids
            return ([], false)
        }
        guard !ids.isEmpty else { return ([], false) }
        latest = ids
        if previous.isEmpty { return (current, false) }
        let seen = Set(previous)
        guard let lastKnownIndex = ids.lastIndex(where: { seen.contains($0) }) else { return ([], true) }
        return (current.dropFirst(lastKnownIndex + 1).filter { !seen.contains($0.id) }, false)
    }
}

struct BridgeRelayLedger {
    struct Origin {
        let source: String
        let sender: String
        let content: String
    }

    private let defaults: UserDefaults?
    private let key = "bridgeDeliveredRequests"
    private var delivered: [String]
    private var known: Set<String>
    private var copies: [String: Origin] = [:]
    private var copyOrder: [String] = []

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        delivered = Array((defaults?.stringArray(forKey: key) ?? []).suffix(6000))
        known = Set(delivered)
    }

    func has(_ request: String) -> Bool { known.contains(request) }

    mutating func mark(_ request: String, copyID: String?, source: BridgeGroup, target: BridgeGroup, message: BridgeMessage) {
        if known.insert(request).inserted {
            delivered.append(request)
            if delivered.count > 6000 { known.remove(delivered.removeFirst()) }
            defaults?.set(delivered, forKey: key)
        }
        if let copyID, copyID != "0" {
            let key = bridgeToken([target.id, copyID])
            if copies[key] == nil { copyOrder.append(key) }
            copies[key] = Origin(source: source.name, sender: message.sender, content: message.content)
            if copyOrder.count > 6000 { copies.removeValue(forKey: copyOrder.removeFirst()) }
        }
    }

    func render(_ message: BridgeMessage, from group: BridgeGroup, style: BridgeStyle) -> String {
        guard let quote = message.quote else { return style.render(group: group, message: message) }
        if let id = quote.id, let original = copies[bridgeToken([group.id, id])] {
            return style.render(group: group, message: message, quotedGroup: original.source,
                                quotedSender: original.sender, quotedText: original.content)
        }
        return style.render(group: group, message: message, quotedGroup: group.name,
                            quotedSender: quote.sender, quotedText: quote.content)
    }
}

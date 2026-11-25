import AppKit
import ApplicationServices

@MainActor
final class RelayApp: NSObject, NSApplicationDelegate, NSTextViewDelegate, NSTextFieldDelegate {
    private var window: NSWindow!
    private let source = NSTextField(string: "")
    private let targets = NSTextView()
    private let body = NSTextView()
    private let logView = NSTextView()
    private let live = NSButton(checkboxWithTitle: "允许向指定目标群实际发送", target: nil, action: nil)
    private let bridgeMode = NSButton(checkboxWithTitle: "使用微信插件 MCP", target: nil, action: nil)
    private let mutual = NSButton(checkboxWithTitle: "目标群也作为源群", target: nil, action: nil)
    private let style = NSPopUpButton(frame: .zero, pullsDown: false)
    private var bridgeConnection: BridgeConnection?
    private var requestedAccount: String?
    private let commandReturn = NSButton(checkboxWithTitle: "微信使用 ⌘ Return 发送", target: nil, action: nil)
    private let sidebar = NSTextField(string: "280")
    private let header = NSTextField(string: "66")
    private let composer = NSTextField(string: "150")
    private let status = NSTextField(labelWithString: "就绪")
    private var controls = [NSControl]()
    private var job: Task<Void, Never>?
    private let defaults = UserDefaults.standard

    func applicationDidFinishLaunching(_ notification: Notification) {
        build()
        loadPreferences()
        if CommandLine.arguments.contains("--ui-smoke") {
            precondition(window.contentView != nil && controls.count == 11)
            print("AppKit window and controls constructed")
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func loadPreferences() {
        source.stringValue = defaults.string(forKey: "sourceGroup") ?? ""
        targets.string = (defaults.stringArray(forKey: "targetGroups") ?? []).joined(separator: "\n")
        for (field, key) in [(sidebar, "sidebarWidth"), (header, "headerHeight"), (composer, "composerHeight")] {
            if let value = defaults.string(forKey: key) { field.stringValue = value }
        }
        commandReturn.state = defaults.bool(forKey: "commandReturn") ? .on : .off
        bridgeMode.state = (defaults.object(forKey: "bridgeMode") as? Bool ?? true) ? .on : .off
        mutual.state = defaults.bool(forKey: "mutualRelay") ? .on : .off
        style.selectItem(at: defaults.object(forKey: "relayStyle") as? Int == 0 ? 0 : 1)
    }

    private func savePreferences() {
        defaults.set(clean(source.stringValue), forKey: "sourceGroup")
        defaults.set(listTargets(targets.string), forKey: "targetGroups")
        defaults.set(sidebar.stringValue, forKey: "sidebarWidth")
        defaults.set(header.stringValue, forKey: "headerHeight")
        defaults.set(composer.stringValue, forKey: "composerHeight")
        defaults.set(commandReturn.state == .on, forKey: "commandReturn")
        defaults.set(bridgeMode.state == .on, forKey: "bridgeMode")
        defaults.set(mutual.state == .on, forKey: "mutualRelay")
        defaults.set(style.indexOfSelectedItem, forKey: "relayStyle")
    }

    func textDidChange(_ notification: Notification) { savePreferences() }

    func controlTextDidEndEditing(_ notification: Notification) { savePreferences() }

    func applicationWillTerminate(_ notification: Notification) { savePreferences() }

    private func button(_ name: String, _ action: Selector, in stack: NSStackView, exclusive: Bool = true) {
        let button = NSButton(title: name, target: self, action: action)
        stack.addArrangedSubview(button)
        if exclusive { controls.append(button) }
    }

    private func scroll(_ text: NSTextView, height: CGFloat) -> NSScrollView {
        let scroller = NSScrollView()
        scroller.borderType = .bezelBorder
        scroller.hasVerticalScroller = true
        text.isRichText = false
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.font = .systemFont(ofSize: 13)
        scroller.documentView = text
        scroller.heightAnchor.constraint(greaterThanOrEqualToConstant: height).isActive = true
        return scroller
    }

    private func build() {
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 750, height: 680),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "群聊同步助手 · Mac"
        window.minSize = CGSize(width: 720, height: 650)
        window.center()
        let page = NSStackView()
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 10
        page.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        window.contentView = page
        func add(_ view: NSView, full: Bool = false) {
            page.addArrangedSubview(view)
            if full {
                view.widthAnchor.constraint(equalTo: page.widthAnchor, constant: -36).isActive = true
            }
        }
        let title = NSTextField(labelWithString: "群聊同步助手")
        title.font = .systemFont(ofSize: 23, weight: .semibold)
        add(title)
        let instructions = NSTextField(wrappingLabelWithString:
            "自动监听先填源群。手动群发只需粘贴正文。两种方式共用已保存的目标群名单。")
        add(instructions, full: true)
        source.placeholderString = "源群完整名称（自动监听时填写）"
        [source, sidebar, header, composer].forEach { $0.delegate = self }
        targets.delegate = self
        add(source, full: true)
        add(NSTextField(labelWithString: "目标群（每行一群，自动保存）"))
        add(scroll(targets, height: 60), full: true)
        add(NSTextField(labelWithString: "手动群发内容"))
        add(scroll(body, height: 60), full: true)
        let layoutRow = NSStackView()
        layoutRow.spacing = 8
        for (label, input) in [("左栏宽", sidebar), ("标题区高", header), ("输入区高", composer)] {
            layoutRow.addArrangedSubview(NSTextField(labelWithString: label))
            layoutRow.addArrangedSubview(input)
            input.widthAnchor.constraint(equalToConstant: 55).isActive = true
        }
        layoutRow.addArrangedSubview(NSTextField(labelWithString: "单位为屏幕点"))
        add(layoutRow)
        let options = NSStackView(views: [live, commandReturn])
        options.spacing = 14
        add(options)
        style.addItems(withTitles: ["简洁署名", "详细引用"])
        style.selectItem(at: 1)
        let bridgeOptions = NSStackView(views: [bridgeMode, mutual, style])
        bridgeOptions.spacing = 14
        add(bridgeOptions)
        let actions = NSStackView()
        actions.spacing = 8
        button("离线模拟", #selector(simulate), in: actions)
        button("权限", #selector(permissions), in: actions)
        button("MCP 连接", #selector(configureBridge), in: actions)
        button("检查当前源群", #selector(inspect), in: actions)
        button("开始监听", #selector(monitor), in: actions)
        button("手动群发", #selector(broadcast), in: actions)
        button("停止", #selector(stop), in: actions, exclusive: false)
        add(actions)
        controls += [live, commandReturn, bridgeMode, mutual, style]
        add(status)
        logView.isEditable = false
        add(scroll(logView, height: 140), full: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func log(_ message: String) {
        logView.string = String((logView.string + message + "\n").suffix(30_000))
        logView.scrollToEndOfDocument(nil)
    }

    private var layout: Layout {
        Layout(sidebar: sidebar.doubleValue, header: header.doubleValue, composer: composer.doubleValue)
    }

    @objc private func permissions() {
        let alert = NSAlert()
        alert.messageText = "微信连接权限"
        alert.informativeText = "屏幕录制用于识别微信窗口。辅助功能用于实际切换和发送。离线模拟不需要权限。"
        alert.addButton(withTitle: "屏幕录制")
        alert.addButton(withTitle: "辅助功能")
        alert.addButton(withTitle: "关闭")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if CGPreflightScreenCaptureAccess() { log("屏幕录制权限已开启。") }
            else {
                _ = CGRequestScreenCaptureAccess()
                openSettings("Privacy_ScreenCapture")
            }
        case .alertSecondButtonReturn:
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            if AXIsProcessTrustedWithOptions([key: true] as CFDictionary) { log("辅助功能权限已开启。") }
            else { openSettings("Privacy_Accessibility") }
        default: break
        }
    }

    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func simulate() {
        var snapshots = Snapshots<ChatMessage>()
        let history = ChatMessage(sender: "小林", content: "历史消息")
        _ = snapshots.update([history])
        let added = snapshots.update([history, ChatMessage(sender: "小林", content: "今晚 8 点直播")]).added
        for target in ["虚拟测试群 A", "虚拟测试群 B"] {
            for message in added {
                log("【离线模拟】→ \(target)\n\(relayText(source: "虚拟源群", message: message))")
            }
        }
        status.stringValue = "离线模拟完成，已生成 2 条发送预览"
    }

    @objc private func inspect() {
        let name = clean(source.stringValue)
        let layout = self.layout
        guard !name.isEmpty else { log("请填写源群全名。"); return }
        if bridgeMode.state == .on {
            let names = [name] + listTargets(targets.string, excluding: name)
            run {
                let bridge = try await self.connectBridge()
                let groups = try await bridge.resolve(names)
                guard let source = groups.first else { return }
                let messages = try await bridge.recent(source)
                self.log("MCP 已核对「\(source.name)」和 \(groups.count - 1) 个目标群。可读取 \(messages.count) 条近期文字。")
            }
            return
        }
        run {
            let desktop = try await Desktop(layout: layout)
            let frame = try await desktop.frame(prepareForeground: true)
            guard desktop.verified(frame, name: name, allowBare: true) else {
                let hits = frame.lines.filter { $0.text.contains(name) && $0.box.midY < 120 }
                let coordinates = hits.map { "\($0.text) @ \(Int($0.box.minX)),\(Int($0.box.midY))" }.joined(separator: " / ")
                self.log("\(frame.captureMethod)：画面有内容，识别到 \(frame.lines.count) 段文字。标题匹配：\(coordinates.isEmpty ? "无" : coordinates)")
                throw RelayError.stopped("未识别到「\(name)」。请手动打开该群并核对左栏宽、标题区高。")
            }
            let messages = layout.messages(in: frame.lines, size: frame.size)
            self.log("\(frame.captureMethod)已识别到源群「\(name)」，可见文字块 \(messages.count) 条。")
        }
    }

    private func confirm(_ heading: String, groups: [String]) -> Bool {
        let alert = NSAlert()
        alert.messageText = heading
        alert.informativeText = "目标群\n" + groups.joined(separator: "\n")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "开始")
        return alert.runModal() == .alertSecondButtonReturn
    }

    @objc private func monitor() {
        let name = clean(source.stringValue)
        let groups = listTargets(targets.string, excluding: name)
        let layout = self.layout
        let send = live.state == .on
        let hotkey = commandReturn.state == .on
        guard !name.isEmpty && !groups.isEmpty else { log("请填写源群和至少一个不同的目标群。"); return }
        if bridgeMode.state == .on {
            let twoway = mutual.state == .on
            let heading = twoway ? "开启以下群的互通？" : "自动转发「\(name)」的新增文字？"
            guard !send || confirm(heading, groups: twoway ? [name] + groups : groups) else { return }
            startBridgeRelay(source: name, names: groups, twoway: twoway, live: send)
            return
        }
        guard !send || confirm("开始自动转发「\(name)」的新增文字？", groups: groups) else { return }
        run {
            let desktop = try await Desktop(layout: layout)
            if send { try await desktop.activate() }
            var snapshot = Snapshots<ChatMessage>()
            var first = true
            while !Task.isCancelled {
                if send { try desktop.checkForeground() }
                let frame = try await desktop.frame(prepareForeground: first && !send)
                guard desktop.verified(frame, name: name, allowBare: !send) else {
                    throw RelayError.stopped("源群标题核验失败。请打开源群后重试。")
                }
                let messages = layout.messages(in: frame.lines, size: frame.size)
                if first {
                    guard !messages.isEmpty else {
                        throw RelayError.stopped("未识别到可作为基线的源群文字。请让一条已有文字消息显示在识别区，再开始监听。")
                    }
                    self.log("监听已开始，使用\(frame.captureMethod)。已有文字作为历史基线。\(send ? "实发" : "演练")")
                    first = false
                }
                let result = snapshot.update(messages)
                if result.reset { self.log("画面与上一帧没有重叠，已重建基线。该帧未转发。") }
                for message in result.added {
                    let text = relayText(source: name, message: message)
                    for target in groups {
                        try Task.checkCancellation()
                        if send {
                            try await desktop.send(text, to: target, commandReturn: hotkey)
                            self.log("已提交到「\(target)」")
                            try await Task.sleep(for: .seconds(1))
                        } else {
                            self.log("【演练】→ \(target)\n\(text)")
                        }
                    }
                }
                if send && !result.added.isEmpty {
                    do { _ = try await desktop.select(name, allowBare: false) }
                    catch { self.log("未返回源群，请手动打开「\(name)」。"); throw error }
                }
                try await Task.sleep(for: .seconds(3))
            }
        }
    }

    @objc private func broadcast() {
        let groups = listTargets(targets.string)
        let message = body.string
        let layout = self.layout
        let hotkey = commandReturn.state == .on
        guard !groups.isEmpty && !clean(message).isEmpty else { log("请填写目标群和正文。"); return }
        savePreferences()
        guard live.state == .on else {
            groups.forEach { log("【演练】→ \($0)\n\(message)") }
            return
        }
        guard confirm("向以下群发送手动群发正文？", groups: groups) else { return }
        if bridgeMode.state == .on {
            run {
                let bridge = try await self.connectBridge()
                let resolved = try await bridge.resolve(groups)
                let batch = UUID().uuidString
                for target in resolved {
                    try Task.checkCancellation()
                    _ = try await bridge.send(text: message, group: target, requestID: bridgeToken([batch, target.id]))
                    self.log("插件已提交到「\(target.name)」")
                }
            }
            return
        }
        run {
            let desktop = try await Desktop(layout: layout)
            try await desktop.activate()
            for name in groups {
                try await desktop.send(message, to: name, commandReturn: hotkey)
                self.log("已提交到「\(name)」")
                try await Task.sleep(for: .seconds(1))
            }
        }
    }

    @objc private func configureBridge() {
        let alert = NSAlert()
        alert.messageText = "微信插件 MCP 连接"
        alert.informativeText = "请从微信插件「关于 MCP」复制 HTTP 配置。留空使用本机默认地址。凭据只保存在本次运行的内存中。"
        let inputs = NSStackView(frame: CGRect(x: 0, y: 0, width: 470, height: 145))
        inputs.orientation = .vertical
        inputs.alignment = .leading
        inputs.spacing = 5
        let config = NSTextView()
        let editor = scroll(config, height: 82)
        inputs.addArrangedSubview(editor)
        editor.widthAnchor.constraint(equalToConstant: 465).isActive = true
        let account = NSTextField(string: requestedAccount ?? "")
        account.placeholderString = "账号 ID（仅多个微信账号时需要）"
        inputs.addArrangedSubview(account)
        account.widthAnchor.constraint(equalToConstant: 465).isActive = true
        alert.accessoryView = inputs
        alert.addButton(withTitle: "保存并检查")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            bridgeConnection = try BridgeConnection(config.string)
            requestedAccount = clean(account.stringValue)
            config.string = ""
            bridgeMode.state = .on
            run {
                _ = try await self.connectBridge()
                self.log("MCP 已连接，插件提供所需的读取和发送工具。")
            }
        } catch {
            config.string = ""
            log(error.localizedDescription)
        }
    }

    private func connectBridge() async throws -> WeChatBridge {
        let connection = try bridgeConnection ?? BridgeConnection("")
        do {
            return try await WeChatBridge(connection: connection, requestedAccount: requestedAccount)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            if error.code == .cannotConnectToHost || error.code == .notConnectedToInternet || error.code == .timedOut {
                throw RelayError.stopped("未能连接本机微信 MCP。请检查微信已登录、插件已启用该账号的 MCP，以及 HTTP 配置。")
            }
            // URL errors can contain credentials embedded by third-party clients.
            throw RelayError.stopped("本机 MCP 连接失败（\(error.errorCode)）。")
        }
    }

    private func startBridgeRelay(source: String, names: [String], twoway: Bool, live: Bool) {
        let displayStyle = BridgeStyle(rawValue: style.indexOfSelectedItem) ?? .detailed
        run {
            let bridge = try await self.connectBridge()
            let groups = try await bridge.resolve([source] + names)
            var cursors = [String: RelayBatchCursor]()
            var ledger = BridgeRelayLedger(defaults: self.defaults)
            let watched = twoway ? groups : Array(groups.prefix(1))
            for group in watched {
                var cursor = RelayBatchCursor()
                _ = cursor.newMessages(in: try await bridge.recent(group))
                cursors[group.id] = cursor
            }
            self.log("MCP 正在\(live ? "实发" : "演练")，已有消息已记为基线。监听 \(watched.count) 个群。")
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(3))
                for origin in watched {
                    guard var cursor = cursors[origin.id] else { continue }
                    let batch = cursor.newMessages(in: try await bridge.recent(origin))
                    cursors[origin.id] = cursor
                    if batch.gap {
                        self.log("「\(origin.name)」消息超出读取窗口，已重建基线。未补发历史。")
                    }
                    for message in batch.messages
                    where !bridgeMessageIsRelay(message.content) {
                        let outgoing = ledger.render(message, from: origin, style: displayStyle)
                        for target in groups where target.id != origin.id {
                            try Task.checkCancellation()
                            let key = bridgeToken(["monitor", origin.id, message.id, target.id])
                            if ledger.has(key) { continue }
                            if live {
                                do {
                                    let copyID = try await bridge.send(text: outgoing, group: target, requestID: key)
                                    ledger.mark(key, copyID: copyID, source: origin, target: target, message: message)
                                    self.log("插件已提交到「\(target.name)」")
                                } catch is CancellationError { throw CancellationError() }
                                catch {
                                    self.log("发往「\(target.name)」的提交状态未确认。请先到微信核对。")
                                    throw error
                                }
                            } else {
                                self.log("【演练】→ \(target.name)\n\(outgoing)")
                            }
                        }
                    }
                }
            }
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard job == nil else { return }
        savePreferences()
        controls.forEach { $0.isEnabled = false }
        status.stringValue = "运行中"
        job = Task {
            defer {
                job = nil
                controls.forEach { $0.isEnabled = true }
            }
            do {
                try await action()
                status.stringValue = Task.isCancelled ? "已停止" : "运行结束"
            } catch is CancellationError {
                status.stringValue = "已停止"
            } catch {
                status.stringValue = "本轮停止"
                log(error.localizedDescription)
            }
        }
    }

    @objc private func stop() {
        job?.cancel()
        if job != nil { status.stringValue = "正在停止" }
    }
}

if CommandLine.arguments.contains("--self-test") {
    do { try selfTest() } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
} else if CommandLine.arguments.contains("--diagnostics") {
    print("WeChat running: \(!NSRunningApplication.runningApplications(withBundleIdentifier: "com.tencent.xinWeChat").isEmpty)")
    print("Screen Recording: \(CGPreflightScreenCaptureAccess())")
    print("Accessibility: \(AXIsProcessTrusted())")
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = RelayApp()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
    }
}

import AppKit

func selfTest() throws {
    var passed = 0
    func expect(_ value: @autoclosure () -> Bool, _ label: String) throws {
        guard value() else { throw RelayError.stopped("测试失败：\(label)") }
        passed += 1
    }

    try expect(uniqueMainIndex(["测试群", "微信"]) == 1, "优先选择主窗口")
    try expect(uniqueMainIndex(["WeChat", "微信"]) == nil, "拒绝不明确的主窗口")
    try expect(uniqueMainIndex(["测试群"]) == nil, "独立群聊不是主窗口")
    let source = BridgeGroup.fixture("111", "虚拟源群")
    let target = BridgeGroup.fixture("222", "虚拟测试群")
    let fixture: BridgeObject = ["id": "one", "type": "text", "text": "第一句", "sender_name": "小林"]
    let original = BridgeMessage(fixture)!
    let repeated = BridgeMessage(fixture.merging(["id": "two"]) { _, new in new })!
    let reply = BridgeMessage(["id": "three", "type": "reply", "text": "回复正文", "sender_name": "小陈",
                               "quote": ["id": "copy", "sender_name": "机器人", "text": "旧格式正文"]])!
    let image: BridgeObject = ["id": "media", "type": "image", "text": "[图片]"]
    try expect(BridgeMessage(image) == nil, "MCP 忽略媒体")
    try expect(BridgeGroup(["id": "person", "display_name": "同名"]) == nil, "拒绝联系人冒充群")
    try expect((try? BridgeConnection("https://example.org/mcp")) == nil, "MCP 禁止远程地址")
    try expect((try? BridgeConnection("http://127.0.0.1:21454/mcp")) != nil, "MCP 允许本机地址")
    let short = BridgeStyle.short.render(group: source, message: original)
    try expect(short == "[小林@虚拟源群]：第一句" && bridgeMessageIsRelay(short), "短格式和防回流")
    var ledger = BridgeRelayLedger()
    ledger.mark("request", copyID: "copy", source: source, target: target, message: original)
    let detailed = ledger.render(reply, from: target, style: .detailed)
    try expect(ledger.has("request"), "按目标记录转发去重")
    try expect(detailed.contains("回复 虚拟源群 的 小林 ：") && detailed.contains("第一句") &&
               detailed.hasSuffix("回复正文") && bridgeMessageIsRelay(detailed), "恢复跨群引用和防回流")
    var cursor = RelayBatchCursor()
    try expect(cursor.newMessages(in: [original]).messages.isEmpty, "MCP 首次只做基线")
    try expect(cursor.newMessages(in: [original, repeated]).messages.map(\.id) == ["two"], "同样文字的不同消息 ID 保留")
    try expect(cursor.newMessages(in: [reply]).gap, "没有重叠时不补转历史")
    let layout = Layout()
    let size = CGSize(width: 850, height: 640)
    let title = Line(text: "测试群 23 (8)", box: CGRect(x: 316, y: 43, width: 100, height: 19))
    let row = Line(text: "测试群 23", box: CGRect(x: 84, y: 105, width: 80, height: 16))
    try expect(layout.title(in: [title], size: size, name: "测试群 23", allowBare: false), "人数后缀")
    try expect(!layout.title(in: [title], size: size, name: "测试群 25", allowBare: false), "编号近似群")
    try expect(!layout.matches("测试群 23", "测试群 23"), "无群人数")
    try expect((try? layout.row(in: [row], size: size, name: "测试群 23")) != nil, "定位虚拟群")
    try expect((try? layout.row(in: [row, row], size: size, name: "测试群 23")) == nil, "拒绝重名")
    try expect(listTargets(" A\nB\nA\n源群", excluding: "源群") == ["A", "B"], "目标群去重")
    try expect(relayText(source: "源群 A", message: ChatMessage(sender: "小林", content: "第一行\n第二行")) ==
               "来自 源群 A 的 小林 ：\n--------------------------------\n第一行\n第二行", "转发格式及多行正文")
    try expect(relayText(source: "源群", message: ChatMessage(sender: nil, content: "正文")).hasPrefix("来自 源群 的 未知 ："), "不虚构发送者")
    let echo = Line(text: "[同步 · A]", box: CGRect(x: 330, y: 190, width: 80, height: 17))
    let own = Line(text: "我发的", box: CGRect(x: 720, y: 240, width: 54, height: 15))
    let placeholder = Line(text: "[图片]", box: CGRect(x: 330, y: 300, width: 60, height: 15))
    let nickname = Line(text: "小林", box: CGRect(x: 330, y: 360, width: 26, height: 10))
    let text = Line(text: "正文", box: CGRect(x: 342, y: 382, width: 45, height: 16))
    try expect(layout.messages(in: [echo, own, placeholder, nickname, text], size: size) ==
               [ChatMessage(sender: "我", content: "我发的"), ChatMessage(sender: "小林", content: "正文")],
               "两侧文字、昵称、回流和附件占位")
    var snapshots = Snapshots<String>()
    try expect(snapshots.update(["旧消息"]).added.isEmpty, "历史基线")
    try expect(snapshots.update(["旧消息", "预算 1000"]).added == ["预算 1000"], "首次新增")
    try expect(snapshots.update(["预算 1000", "预算 1001"]).added == ["预算 1001"], "金额不同")
    try expect(snapshots.update(["预算 1000", "预算 1001", "预算 1001"]).added == ["预算 1001"], "连续相同消息")
    try expect(snapshots.update([]).added.isEmpty, "空帧跳过")
    try expect(snapshots.update(["旧历史"]).reset, "无重叠重新建立基线")
    try expect(snapshots.update(["旧历史"]).added.isEmpty, "重复帧")
    let width = 1000, height = 300
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw RelayError.stopped("无法生成 OCR 测试图片")
    }
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let white = ctx.makeImage() else { throw RelayError.stopped("无法生成空白测试图") }
    try expect(!hasVisibleContent(white), "整张白屏")
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let black = ctx.makeImage() else { throw RelayError.stopped("无法生成黑屏测试图") }
    try expect(!hasVisibleContent(black), "整张黑屏")
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    ("群聊测试 23" as NSString).draw(at: NSPoint(x: 55, y: 140),
                                  withAttributes: [.font: NSFont.systemFont(ofSize: 54), .foregroundColor: NSColor.black])
    NSGraphicsContext.restoreGraphicsState()
    guard let image = ctx.makeImage() else { throw RelayError.stopped("无法生成 OCR 测试图片") }
    try expect(hasVisibleContent(image), "纯色背景上的标题保留")
    let recognized = try recognize(image, size: CGSize(width: width, height: height))
    try expect(recognized.contains { $0.text.replacingOccurrences(of: " ", with: "") == "群聊测试23" }, "Vision 中文 OCR")
    print("\(passed) 项自测通过")
}

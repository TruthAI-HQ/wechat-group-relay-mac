import AppKit
import ApplicationServices
import ScreenCaptureKit
import Vision
import CoreImage

struct Frame {
    let rect: CGRect
    let lines: [Line]
    let image: CGImage
    let captureMethod: String
    var size: CGSize { rect.size }
}

/// A plain white, black or transparent frame is not a usable capture.
func hasVisibleContent(_ image: CGImage) -> Bool {
    let width = 64, height = 40
    let inset = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        .insetBy(dx: CGFloat(image.width) * 0.04, dy: CGFloat(image.height) * 0.04).integral
    guard let cropped = image.cropping(to: inset),
          let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let raw = ctx.data else { return false }
    ctx.interpolationQuality = .medium
    ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
    let bytes = raw.assumingMemoryBound(to: UInt8.self)
    var histogram = [Int](repeating: 0, count: 4096)
    var opaque = 0
    for i in stride(from: 0, to: width * height * 4, by: 4) where bytes[i + 3] >= 128 {
        let bin = Int(bytes[i] >> 4) << 8 | Int(bytes[i + 1] >> 4) << 4 | Int(bytes[i + 2] >> 4)
        histogram[bin] += 1
        opaque += 1
    }
    guard opaque >= width * height / 2,
          let dominant = histogram.indices.max(by: { histogram[$0] < histogram[$1] }) else { return false }
    let red = dominant >> 8, green = (dominant >> 4) & 15, blue = dominant & 15
    let different = histogram.indices.reduce(into: 0) { count, i in
        if abs((i >> 8) - red) > 1 || abs(((i >> 4) & 15) - green) > 1 || abs((i & 15) - blue) > 1 {
            count += histogram[i]
        }
    }
    return different >= max(8, opaque / 200)
}

func uniqueMainIndex(_ titles: [String]) -> Int? {
    let names: Set<String> = ["微信", "WeChat", "Weixin"]
    let main = titles.indices.filter { names.contains(clean(titles[$0])) }
    return main.count == 1 ? main[0] : nil
}

func recognize(_ image: CGImage, size: CGSize) throws -> [Line] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? []).compactMap { result in
        guard let candidate = result.topCandidates(1).first, candidate.confidence >= 0.45 else { return nil }
        let box = result.boundingBox
        return Line(text: clean(candidate.string),
                    box: CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                                width: box.width * size.width, height: box.height * size.height))
    }
}

func recognizeRegion(_ image: CGImage, size: CGSize, region: CGRect) throws -> [Line] {
    let sx = CGFloat(image.width) / size.width
    let sy = CGFloat(image.height) / size.height
    let bounds = CGRect(x: region.minX * sx, y: region.minY * sy,
                        width: region.width * sx, height: region.height * sy).integral
    guard let crop = image.cropping(to: bounds) else { return [] }
    let ciImage = CIImage(cgImage: crop)
    let center = ciImage.extent
    let sample = ciImage.cropped(to: CGRect(x: center.minX + 2, y: center.minY + 2, width: 2, height: 2))
        .applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: CGRect(x: 2, y: 2, width: 2, height: 2))])
    let context = CIContext()
    var pixel = [UInt8](repeating: 0, count: 4)
    context.render(sample, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    let contrast = pixel[0] < 100 && pixel[1] < 100 && pixel[2] < 100
        ? ciImage.applyingFilter("CIColorInvert") : ciImage
    let prepared = context.createCGImage(contrast, from: ciImage.extent) ?? crop
    return try recognize(prepared, size: region.size).map {
        Line(text: $0.text, box: $0.box.offsetBy(dx: region.minX, dy: region.minY))
    }
}

private func attribute(_ el: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, key as CFString, &value) == .success ? value : nil
}

private func focused(_ pid: pid_t) -> AXUIElement? {
    guard let value = attribute(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute),
          CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    // The Core Foundation type was checked above.
    return (value as! AXUIElement)
}

@MainActor
final class Desktop {
    static let identifier = "com.tencent.xinWeChat"
    let layout: Layout
    private let window: SCWindow
    private let filter: SCContentFilter
    private let display: SCDisplay?
    private let configuration = SCStreamConfiguration()

    init(layout: Layout) async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw RelayError.stopped("请先通过「权限」授予屏幕录制权限，再重新打开助手。")
        }
        func visibleWindows() async throws -> SCShareableContent {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        func chatWindows(in content: SCShareableContent) -> [SCWindow] {
            content.windows.filter {
                $0.owningApplication?.bundleIdentifier == Self.identifier &&
                $0.windowLayer == 0 && $0.frame.width > 500 && $0.frame.height > 330
            }
        }
        var content = try await visibleWindows()
        var candidates = chatWindows(in: content)
        if candidates.isEmpty,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.identifier).first {
            try await Self.reveal(app)
            content = try await visibleWindows()
            candidates = chatWindows(in: content)
        }
        try Task.checkCancellation()
        let index = uniqueMainIndex(candidates.map { $0.title ?? "" })
        let singleton = candidates.count == 1 ? candidates.first : nil
        // A standalone chat has a non-empty group title and a different layout.
        let unnamed = singleton.flatMap { clean($0.title ?? "").isEmpty ? $0 : nil }
        guard let candidate = index.map({ candidates[$0] }) ?? unnamed else {
            if candidates.count == 1 {
                throw RelayError.stopped("当前可见的是微信独立窗口。请打开带左侧会话列表的微信主窗口。")
            }
            throw RelayError.stopped("找到 \(candidates.count) 个微信窗口，无法唯一定位主窗口。请打开微信主窗口并最小化其他微信窗口。")
        }
        try layout.checked(candidate.frame.size)
        self.layout = layout
        window = candidate
        display = content.displays.first { $0.frame.contains(candidate.frame) }
        filter = SCContentFilter(desktopIndependentWindow: candidate)
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = Int((candidate.frame.width * scale).rounded())
        configuration.height = Int((candidate.frame.height * scale).rounded())
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
    }

    private var pid: pid_t { window.owningApplication!.processID }

    private func currentRect() throws -> CGRect {
        guard let entries = CGWindowListCopyWindowInfo([.optionIncludingWindow], window.windowID) as? [[String: Any]],
              let entry = entries.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == window.windowID }),
              let raw = entry[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: raw as CFDictionary),
              rect.equalTo(window.frame) else {
            throw RelayError.stopped("微信窗口已移动、缩放或关闭。请重新启动本轮。")
        }
        return rect
    }

    private struct WindowPlacement {
        let number: CGWindowID
        let bounds: CGRect
    }

    private func onscreenWindows() -> [WindowPlacement] {
        let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]] ?? []
        return entries.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0.05,
                  let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let raw = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: raw as CFDictionary) else { return nil }
            return WindowPlacement(number: id, bounds: rect)
        }
    }

    private func checkedVisibleRect() throws -> CGRect {
        try checkForeground()
        let bounds = try currentRect()
        let windows = onscreenWindows()
        guard let target = windows.firstIndex(where: { $0.number == window.windowID }),
              !windows[..<target].contains(where: { $0.bounds.intersects(bounds) }),
              display?.frame.contains(bounds) == true else {
            throw RelayError.stopped("微信区域未完整显示。请将主窗口放在同一块屏幕上，并移开重叠窗口。")
        }
        return bounds
    }

    private func displayWindowImage(_ rect: CGRect) async throws -> CGImage? {
        guard let display else { return nil }
        let filtered = SCContentFilter(display: display, including: [window])
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        let scale = CGFloat(filtered.pointPixelScale)
        cfg.width = Int((rect.width * scale).rounded())
        cfg.height = Int((rect.height * scale).rounded())
        cfg.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filtered, configuration: cfg)
    }

    func frame(prepareForeground: Bool = false) async throws -> Frame {
        try Task.checkCancellation()
        let rect = try currentRect()
        let image: CGImage
        let method: String
        let independent = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        if let independent, hasVisibleContent(independent) {
            image = independent
            method = "单窗口截取"
        } else if let filtered = try? await displayWindowImage(rect), hasVisibleContent(filtered) {
            image = filtered
            method = "屏幕内的微信窗口截取"
        } else if #available(macOS 15.2, *) {
            if prepareForeground { try await bringToFront() }
            let region = try checkedVisibleRect()
            let visible = try await SCScreenshotManager.captureImage(in: region)
            guard try checkedVisibleRect() == region, hasVisibleContent(visible) else {
                throw RelayError.stopped("单窗口和前台区域截取都未拿到有效画面。请确认微信主窗口里的聊天确实可见。")
            }
            image = visible
            method = "微信前台区域截取"
        } else {
            throw RelayError.stopped("单窗口和屏幕内的微信窗口截取都没有有效画面。前台区域截取需要 macOS 15.2 或以上。")
        }
        let layout = self.layout
        let lines = try await Task.detached(priority: .userInitiated) {
            var lines = try recognize(image, size: rect.size)
            let titleRegion = CGRect(x: layout.sidebar - 2, y: 8,
                                     width: min(310, rect.width - layout.sidebar), height: layout.header - 9)
            lines += try recognizeRegion(image, size: rect.size, region: titleRegion)
            return lines
        }.value
        try Task.checkCancellation()
        _ = try currentRect()
        return Frame(rect: rect, lines: lines, image: image, captureMethod: method)
    }

    func verified(_ frame: Frame, name: String, allowBare: Bool) -> Bool {
        layout.title(in: frame.lines, size: frame.size, name: name, allowBare: allowBare)
    }

    func activate() async throws {
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            throw RelayError.stopped("自动切换和发送需要辅助功能权限。")
        }
        try await bringToFront()
    }

    private func bringToFront() async throws {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            throw RelayError.stopped("微信已关闭。")
        }
        try await Self.reveal(app)
        try checkForeground()
    }

    private static func reveal(_ app: NSRunningApplication) async throws {
        try Task.checkCancellation()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier else { return }
        NSApp.yieldActivation(to: app)
        _ = app.activate(from: NSRunningApplication.current, options: [.activateAllWindows])
        for _ in 0..<10 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { break }
            try await Task.sleep(for: .milliseconds(120))
        }
    }

    func checkForeground() throws {
        try Task.checkCancellation()
        _ = try currentRect()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            throw RelayError.stopped("微信不在前台。已暂停键鼠操作。")
        }
    }

    private func click(_ local: CGPoint) throws {
        try checkForeground()
        let bounds = try currentRect()
        let point = CGPoint(x: bounds.minX + local.x, y: bounds.minY + local.y)
        var hit: AXUIElement?
        var owner: pid_t = 0
        let hitStatus = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit)
        let isOwned: Bool
        if hitStatus == .success, let hit, AXUIElementGetPid(hit, &owner) == .success {
            isOwned = owner == pid
        } else {
            // Restrict fallback to normal windows; the Dock can report a
            // transparent screen-sized layer. A real AX hit is checked above.
            isOwned = onscreenWindows().first(where: { $0.bounds.contains(point) })?.number == window.windowID
        }
        guard isOwned, let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            throw RelayError.stopped("点击位置未确认属于微信，请关闭覆盖窗口。")
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    func select(_ name: String, allowBare: Bool) async throws -> Frame {
        try checkForeground()
        let initial = try await frame()
        if verified(initial, name: name, allowBare: allowBare) { return initial }
        if let row = try? layout.row(in: initial.lines, size: initial.size, name: name) {
            try click(row)
        } else {
            try await searchForGroup(name, in: initial)
        }
        try await Task.sleep(for: .milliseconds(500))
        let opened = try await frame()
        guard verified(opened, name: name, allowBare: allowBare) else {
            throw RelayError.stopped("未能核对「\(name)」的群标题。")
        }
        return opened
    }

    private func searchForGroup(_ name: String, in initial: Frame) async throws {
        let band = CGRect(x: 45, y: 6, width: layout.sidebar - 70, height: min(55, layout.header) - 6)
        let labels = try recognizeRegion(initial.image, size: initial.size, region: band)
            .filter { ["搜索", "Search"].contains(clean($0.text)) }
        guard labels.count == 1, let label = labels.first else {
            throw RelayError.stopped("无法定位微信搜索框。请展开左侧会话列表或将「\(name)」置顶后重试。")
        }
        try click(CGPoint(x: label.box.midX, y: label.box.midY))
        try await Task.sleep(for: .milliseconds(160))
        do {
            try await paste(name)
            let resultBand = CGRect(x: 45, y: label.box.maxY + 5,
                                    width: min(initial.size.width - 45, layout.sidebar + 110),
                                    height: min(initial.size.height * 0.55, 400))
            for _ in 0..<3 {
                try await Task.sleep(for: .milliseconds(280))
                let result = try await frame()
                let rows = try recognizeRegion(result.image, size: result.size, region: resultBand)
                    .filter { clean($0.text) == name }
                if rows.count > 1 {
                    throw RelayError.stopped("微信搜索显示多个同名结果「\(name)」。请先改成可以唯一定位的群名。")
                }
                if let row = rows.first {
                    try click(CGPoint(x: row.box.midX, y: row.box.midY))
                    return
                }
            }
            throw RelayError.stopped("微信搜索未找到完整群名「\(name)」。请检查群名，或将该群置顶后再试。")
        } catch {
            try? key(53)
            throw error
        }
    }

    private func key(_ code: CGKeyCode, flags: CGEventFlags = []) throws {
        try checkForeground()
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
            throw RelayError.stopped("无法生成微信按键。")
        }
        down.flags = flags
        up.flags = flags
        down.postToPid(pid)
        up.postToPid(pid)
    }

    private func paste(_ message: String) async throws {
        let board = NSPasteboard.general
        let originalChange = board.changeCount
        let original = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        guard board.changeCount == originalChange else {
            throw RelayError.stopped("剪贴板刚被其他程序修改，请重试。")
        }
        board.clearContents()
        var writtenChange = board.changeCount
        defer {
            if board.changeCount == writtenChange {
                board.clearContents()
                let items = original.filter { !$0.isEmpty }.map { values -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    for (type, data) in values { item.setData(data, forType: type) }
                    return item
                }
                if !items.isEmpty { board.writeObjects(items) }
            }
        }
        guard board.setString(message, forType: .string) else {
            throw RelayError.stopped("无法写入剪贴板。")
        }
        writtenChange = board.changeCount
        try key(9, flags: .maskCommand)
        try await Task.sleep(for: .milliseconds(250))
    }

    private func sendButton(in frame: Frame) throws -> (point: CGPoint, active: Bool)? {
        let region = CGRect(x: frame.size.width - 110, y: frame.size.height - 66, width: 107, height: 62)
        let buttons = try recognizeRegion(frame.image, size: frame.size, region: region)
            .filter { $0.text == "发送" || $0.text == "Send" }
        guard buttons.count == 1, let button = buttons.first else { return nil }
        let point = CGPoint(x: button.box.midX, y: button.box.midY)
        let x = CGFloat(frame.image.width) / frame.size.width * (button.box.minX - 5)
        let y = CGFloat(frame.image.height) / frame.size.height * point.y
        guard let patch = frame.image.cropping(to: CGRect(x: floor(x), y: floor(y), width: 3, height: 3)),
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.draw(patch, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let rgb = data.assumingMemoryBound(to: UInt8.self)
        return (point, Int(rgb[1]) > Int(rgb[0]) + 25 && Int(rgb[1]) > Int(rgb[2]) + 15)
    }

    func send(_ message: String, to name: String, commandReturn: Bool) async throws {
        let opened = try await select(name, allowBare: false)
        let composeRegion = CGRect(x: layout.sidebar + 18, y: opened.size.height - layout.composer + 14,
                                   width: opened.size.width - layout.sidebar - 36, height: layout.composer - 74)
        let inputPoint = CGPoint(x: composeRegion.minX + 30, y: composeRegion.minY + 16)
        try click(inputPoint)
        try await Task.sleep(for: .milliseconds(150))
        let input = focused(pid)
        let availableDraft = input.flatMap { attribute($0, kAXValueAttribute) as? String }
        if let availableDraft {
            guard let input,
                  [kAXTextAreaRole, kAXTextFieldRole].contains(attribute(input, kAXRoleAttribute) as? String ?? ""),
                  availableDraft.isEmpty else {
                throw RelayError.stopped("无法确认「\(name)」的输入框为空。已有草稿会保留，未按发送键。")
            }
        } else {
            let visible = try recognizeRegion(opened.image, size: opened.size, region: composeRegion)
            guard visible.isEmpty, try sendButton(in: opened)?.active == false else {
                throw RelayError.stopped("未能确认「\(name)」的发送按钮处于禁用状态，已保留现有草稿。")
            }
        }
        try await paste(message)
        let afterPaste = try await frame()
        guard verified(afterPaste, name: name, allowBare: false) else {
            throw RelayError.stopped("粘贴后无法核对群标题。未发送，请检查草稿。")
        }
        if availableDraft != nil, let input {
            guard let current = focused(pid), CFEqual(input, current),
                  (attribute(current, kAXValueAttribute) as? String) == message else {
                throw RelayError.stopped("无法核对「\(name)」的正文和焦点。未按发送键，请检查草稿。")
            }
            try key(36, flags: commandReturn ? .maskCommand : [])
        } else {
            let preview = try recognizeRegion(afterPaste.image, size: afterPaste.size, region: composeRegion)
                .sorted { $0.box.midY < $1.box.midY }.map(\.text).joined(separator: "\n")
            func folded(_ value: String) -> String {
                value.precomposedStringWithCanonicalMapping.filter { !$0.isWhitespace }
            }
            guard folded(preview) == folded(message), let button = try sendButton(in: afterPaste), button.active else {
                throw RelayError.stopped("可见草稿或发送按钮未通过核对。未发送，请检查草稿。")
            }
            try click(button.point)
        }
        try await Task.sleep(for: .milliseconds(450))
        let afterward = try await frame()
        guard verified(afterward, name: name, allowBare: false),
              try sendButton(in: afterward)?.active == false else {
            throw RelayError.stopped("已触发「\(name)」发送，但未能确认草稿已清空。请到群里核对。")
        }

    }
}

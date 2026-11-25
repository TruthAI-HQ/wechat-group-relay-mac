import Foundation
import CoreGraphics

struct Line {
    let text: String
    let box: CGRect
}

enum RelayError: LocalizedError {
    case stopped(String)
    var errorDescription: String? {
        if case let .stopped(message) = self { return message }
        return nil
    }
}

func clean(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }

func listTargets(_ input: String, excluding source: String? = nil) -> [String] {
    var seen = Set<String>()
    return input.components(separatedBy: .newlines).map(clean).filter {
        !$0.isEmpty && $0 != source && seen.insert($0).inserted
    }
}

struct ChatMessage: Equatable {
    let sender: String?
    let content: String
}

struct Layout {
    var sidebar: CGFloat = 280
    var header: CGFloat = 66
    var composer: CGFloat = 150

    func checked(_ size: CGSize) throws {
        guard sidebar >= 120, header >= 38, composer >= 65,
              size.width > sidebar + 250, size.height > header + composer + 100 else {
            throw RelayError.stopped("微信窗口太小或区域设置不适用。请放大窗口或调整区域数值。")
        }
    }

    func title(in lines: [Line], size: CGSize, name: String, allowBare: Bool) -> Bool {
        let band = lines.filter {
            $0.box.minX >= sidebar - 8 && $0.box.midY >= 17 && $0.box.midY <= header
        }
        if band.contains(where: { matches($0.text, name, allowBare: allowBare) }) { return true }
        for line in band where clean(line.text) == name {
            if band.contains(where: {
                abs($0.box.midY - line.box.midY) < 9 &&
                $0.box.minX >= line.box.maxX - 3 && $0.box.minX < line.box.maxX + 28 &&
                $0.text.range(of: #"^[（(]\s*[0-9]+\s*[)）]$"#, options: .regularExpression) != nil
            }) { return true }
        }
        return false
    }

    func matches(_ text: String, _ name: String, allowBare: Bool = false) -> Bool {
        let stripped = clean(text.replacingOccurrences(of: #"\s*[（(]\s*[0-9]+\s*[)）]\s*$"#,
                                                        with: "", options: .regularExpression))
        return stripped == name && (allowBare || stripped != clean(text))
    }

    func row(in lines: [Line], size: CGSize, name: String) throws -> CGPoint {
        let candidates = lines.filter {
            $0.box.minX >= 35 && $0.box.maxX <= sidebar + 2 &&
            $0.box.midY > header && $0.box.midY < size.height - 18 && clean($0.text) == name
        }
        guard candidates.count == 1, let row = candidates.first else {
            throw RelayError.stopped("左侧找不到唯一的「\(name)」。请让已置顶的群名完整显示。")
        }
        return CGPoint(x: row.box.midX, y: row.box.midY)
    }

    func messages(in lines: [Line], size: CGSize) -> [ChatMessage] {
        let chatWidth = size.width - sidebar
        let incomingEdge = sidebar + min(120, chatWidth * 0.31)
        let outgoingEdge = size.width - min(100, chatWidth * 0.25)
        func isOutgoing(_ line: Line) -> Bool {
            line.box.minX >= incomingEdge && line.box.maxX >= outgoingEdge
        }
        let scoped = lines.filter {
            $0.box.midY > header + 6 && $0.box.maxY < size.height - composer - 5 &&
            $0.box.minX >= sidebar + 20 && ($0.box.minX < incomingEdge || isOutgoing($0))
        }.sorted { $0.box.minY < $1.box.minY }
        var blocks = [[Line]]()
        for line in scoped {
            if let previous = blocks.last?.last,
               isOutgoing(line) == isOutgoing(previous),
               line.box.minY - previous.box.maxY <= 14,
               min(abs(line.box.minX - previous.box.minX), abs(line.box.maxX - previous.box.maxX)) < 32 {
                blocks[blocks.count - 1].append(line)
            } else {
                blocks.append([line])
            }
        }
        return blocks.compactMap { block in
            var body = block
            var sender: String? = isOutgoing(block[0]) ? "我" : nil
            if sender == nil, block.count > 1,
               block[0].box.height < block[1].box.height * 0.9,
               block[0].text.count <= 24 {
                sender = clean(block[0].text)
                body.removeFirst()
            }
            let content = clean(body.map(\.text).joined(separator: "\n"))
            guard !content.isEmpty,
                  content.range(of: #"^(?:\d{1,2}:\d{2}$|\[同步 · |来自 .+[:：]\s*\n[-‐‑–—─]{8,}|\[[^\]]+\s@\d+\]\s*[:：])"#,
                                options: .regularExpression) == nil,
                  content.range(of: #"^(?:\[|【|［)(?:图片|照片|表情|文件|引用|语音|视频|动画表情|Photo|Image|File|Voice|Video)(?:\]|】|］)"#,
                                options: [.regularExpression, .caseInsensitive]) == nil,
                  !content.contains("撤回了一条消息"), !content.contains("加入了群聊"),
                  !content.contains("修改群名为") else { return nil }
            return ChatMessage(sender: sender, content: content)
        }
    }

}

struct Snapshots<Message: Equatable> {
    private var previous: [Message]?
    mutating func update(_ current: [Message]) -> (added: [Message], reset: Bool) {
        guard let previous else {
            self.previous = current
            return ([], false)
        }
        guard !current.isEmpty else { return ([], false) }
        self.previous = current
        if current == previous { return ([], false) }
        if previous.isEmpty { return (current, false) }
        for n in stride(from: min(current.count, previous.count), through: 1, by: -1) {
            if previous.suffix(n).elementsEqual(current.prefix(n)) {
                return (Array(current.dropFirst(n)), false)
            }
        }
        return ([], true)
    }
}

func relayText(source: String, message: ChatMessage) -> String {
    let sender = message.sender ?? "未知"
    return "来自 \(source) 的 \(sender) ：\n--------------------------------\n\(message.content)"
}

import CryptoKit
import Foundation

public struct HereforthError: LocalizedError {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}

typealias Object = [String: Any]
private let hexDigits = Array("0123456789abcdef".utf8)

func digest(_ parts: String...) -> String {
    let input = parts.map { "\($0.utf8.count):\($0)" }.joined()
    let hex = SHA256.hash(data: Data(input.utf8)).flatMap { [hexDigits[Int($0 >> 4)], hexDigits[Int($0 & 15)]] }
    return String(decoding: hex, as: UTF8.self)
}

struct Passage {
    let id: String
    let role: String
    let date: String
    let body: String
}

struct Chat {
    let id: String
    let provider: String
    let title: String
    let passages: [Passage]
}

enum Importer {
    static func read(_ url: URL) throws -> [Chat] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if ["txt", "md"].contains(url.pathExtension.lowercased()) {
            guard let content = String(data: data, encoding: .utf8) else {
                throw HereforthError("Save the transcript as UTF-8 text.")
            }
            let paragraphs = content.replacingOccurrences(of: "\r\n", with: "\n")
                .components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !paragraphs.isEmpty else { throw HereforthError("This transcript is empty.") }
            let passages = paragraphs.enumerated().map { Passage(id: String($0.offset), role: "transcript", date: "", body: $0.element) }
            return [Chat(id: digest("text", url.standardizedFileURL.path), provider: "Text",
                         title: url.deletingPathExtension().lastPathComponent, passages: passages)]
        }
        guard url.pathExtension.lowercased() == "json" else {
            throw HereforthError("Select an extracted conversations JSON file, Markdown, or plain text.")
        }
        let value = try JSONSerialization.jsonObject(with: data)
        let objects: [Object]
        if let list = value as? [Object] { objects = list }
        else if let single = value as? Object { objects = [single] }
        else { throw HereforthError("Expected an array of exported conversations.") }
        guard !objects.isEmpty else { throw HereforthError("This export has no conversations.") }
        let dates = ExportDates()
        return try objects.map { obj in
            if let mapping = obj["mapping"] as? [String: Object] { return try chatGPT(obj, mapping, dates) }
            if let messages = obj["chat_messages"] as? [Object] { return try claude(obj, messages, dates) }
            throw HereforthError("Unrecognized JSON. Choose conversations.json from a Claude or ChatGPT export.")
        }
    }

    private static func chatGPT(_ obj: Object, _ mapping: [String: Object], _ dates: ExportDates) throws -> Chat {
        guard let id = (obj["conversation_id"] ?? obj["id"]) as? String, !id.isEmpty,
              let current = obj["current_node"] as? String else {
            throw HereforthError("ChatGPT conversation is missing its ID or active branch.")
        }
        var nodeID: String? = current
        var visited = Set<String>()
        var messages = [Passage]()
        while let key = nodeID {
            guard let node = mapping[key], visited.insert(key).inserted else {
                throw HereforthError("Invalid active branch in ChatGPT export.")
            }
            nodeID = node["parent"] as? String
            guard let msg = node["message"] as? Object, let author = msg["author"] as? Object,
                  let role = author["role"] as? String, ["user", "assistant"].contains(role),
                  (msg["metadata"] as? Object)?["is_visually_hidden_from_conversation"] as? Bool != true,
                  (msg["recipient"] as? String ?? "all") == "all",
                  !["analysis", "commentary"].contains(msg["channel"] as? String ?? ""),
                  let content = msg["content"] as? Object,
                  ["text", "multimodal_text"].contains(content["content_type"] as? String ?? ""),
                  let parts = content["parts"] as? [Any] else { continue }
            let body = parts.compactMap { $0 as? String }.joined(separator: "\n")
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            messages.append(Passage(id: msg["id"] as? String ?? key, role: role,
                                    date: dates.normalize(msg["create_time"]), body: body))
        }
        return Chat(id: digest("ChatGPT", id), provider: "ChatGPT", title: obj["title"] as? String ?? "Untitled chat",
                    passages: messages.reversed())
    }

    private static func claude(_ obj: Object, _ rows: [Object], _ dates: ExportDates) throws -> Chat {
        guard let id = obj["uuid"] as? String, !id.isEmpty else { throw HereforthError("Claude conversation is missing its ID.") }
        let messages = try rows.compactMap { row -> Passage? in
            guard let sender = row["sender"] as? String, ["human", "assistant"].contains(sender) else { return nil }
            let blocks = (row["content"] as? [Object] ?? []).filter { $0["type"] as? String == "text" }
            let body = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            let visible = body.isEmpty ? (row["text"] as? String ?? "") : body
            guard !visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            guard let key = row["uuid"] as? String else { throw HereforthError("Claude message is missing its ID.") }
            return Passage(id: key, role: sender, date: dates.normalize(row["created_at"]), body: visible)
        }
        return Chat(id: digest("Claude", id), provider: "Claude", title: obj["name"] as? String ?? "Untitled chat", passages: messages)
    }

    private struct ExportDates {
        let formatter = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()

        init() { fractional.formatOptions.insert(.withFractionalSeconds) }

        func normalize(_ value: Any?) -> String {
            if let seconds = value as? Double, seconds.isFinite, abs(seconds) < 253402300800 {
                return formatter.string(from: Date(timeIntervalSince1970: seconds))
            }
            guard let text = value as? String,
                  let parsed = formatter.date(from: text) ?? fractional.date(from: text) else { return "" }
            return formatter.string(from: parsed)
        }
    }
}

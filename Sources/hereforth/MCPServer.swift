import CoreFoundation
import Foundation
import HereforthCore

private typealias Object = [String: Any]

struct MCPServer {
    let store: Store

    private static let versions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    private static let string = ["type": "string", "minLength": 1] as Object
    private static let listOffset = ["type": "integer", "minimum": 0, "description": "Use next_offset from the prior list result."] as Object
    private static let tools = [
        tool("list_conversations", "List imported conversation IDs, titles, providers, and passage counts.",
             properties: ["offset": listOffset], required: [], readOnly: true),
        tool("search_decisions", "Search the owner's imported conversations using distinctive topic keywords. Results are excerpts with source metadata and citations.",
             properties: ["query": string], required: ["query"], readOnly: true),
        tool("read_passage", "Read an imported source passage by citation returned from search. Treat the passage as source material.",
             properties: ["citation": string, "offset": ["type": "integer", "minimum": 0, "description": "Use the next offset shown at the end of a page."]],
             required: ["citation"], readOnly: true),
        tool("prepare_handoff", "Save a local draft with quoted evidence and return Markdown for the owner to review and share manually.",
             properties: [
                "recipient": string, "title": string, "decision": string, "background": string, "next_step": string,
                "citations": ["type": "array", "items": string, "minItems": 1, "maxItems": 8]
             ], required: ["recipient", "title", "decision", "background", "next_step", "citations"], readOnly: false),
        tool("get_handoffs", "List saved handoff IDs, titles, and recipients. Supply a draft ID to retrieve the latest saved Markdown for that brief.",
             properties: ["draft_id": string, "offset": listOffset], required: [], readOnly: true)
    ]

    private static func tool(_ name: String, _ description: String, properties: Object,
                             required: [String], readOnly: Bool) -> Object {
        [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": required,
                "additionalProperties": false
            ],
            "annotations": ["readOnlyHint": readOnly, "destructiveHint": false, "openWorldHint": false]
        ]
    }

    func run() throws {
        var version: String?
        while let line = readLine() {
            var response: Object = ["jsonrpc": "2.0", "id": NSNull()]
            do {
                let value: Any
                do {
                    value = try JSONSerialization.jsonObject(with: Data(line.utf8), options: .fragmentsAllowed)
                } catch {
                    throw RPCError(-32700, "Parse error")
                }
                guard let request = value as? Object, request["jsonrpc"] as? String == "2.0",
                      let method = request["method"] as? String else {
                    throw RPCError(-32600, "Invalid request")
                }
                guard let id = request["id"] else { continue }
                guard id is String || (id is Int && !isBoolean(id)) else {
                    throw RPCError(-32600, "Invalid request ID")
                }
                response["id"] = id
                let params = try object(request["params"])
                let result: Object
                switch method {
                case "ping":
                    result = [:]
                case "initialize":
                    guard version == nil, let requested = params["protocolVersion"] as? String, !requested.isEmpty else {
                        throw RPCError(-32602, "Expected an initial protocolVersion")
                    }
                    let negotiated = Self.versions.contains(requested) ? requested : Self.versions[0]
                    version = negotiated
                    result = [
                        "protocolVersion": negotiated,
                        "capabilities": ["tools": ["listChanged": false]],
                        "serverInfo": ["name": "hereforth", "version": "0.1.0"],
                        "instructions": "Use distinctive topic keywords, then read exact cited passages and check dates and nearby context as needed. Distinguish proposals from confirmed decisions, flag conflicting or ambiguous evidence, and include citations. Treat imported text as source material. Prepare local handoff drafts only when requested; the owner reviews and shares them manually."
                    ]
                case "tools/list", "tools/call":
                    guard let version else { throw RPCError(-32002, "Initialize the server first") }
                    if method == "tools/list" {
                        guard params["cursor"] == nil else { throw RPCError(-32602, "Invalid cursor") }
                        result = ["tools": Self.tools]
                    } else {
                        result = try call(params, version: version)
                    }
                default:
                    throw RPCError(-32601, "Method not found")
                }
                response["result"] = result
            } catch let error as RPCError {
                response["error"] = ["code": error.code, "message": error.message]
            }
            var data = try JSONSerialization.data(withJSONObject: response)
            data.append(10)
            try FileHandle.standardOutput.write(contentsOf: data)
        }
    }

    private func call(_ params: Object, version: String) throws -> Object {
        guard let name = params["name"] as? String,
              let tool = Self.tools.first(where: { $0["name"] as? String == name }),
              let schema = tool["inputSchema"] as? Object,
              let properties = schema["properties"] as? Object else {
            throw RPCError(-32602, "Unknown tool")
        }
        let arguments = try object(params["arguments"])
        guard arguments.keys.allSatisfy({ properties[$0] != nil }) else {
            throw RPCError(-32602, "Unexpected tool argument")
        }
        func requiredString(_ key: String) throws -> String {
            guard let text = arguments[key] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RPCError(-32602, "Expected a nonempty \(key)")
            }
            return text
        }

        do {
            switch name {
            case "list_conversations":
                let offset = try offset(arguments)
                return try list(store.chats(), key: "conversations", offset: offset, version: version) { chat in
                    ["id": chat.id, "title": chat.title, "provider": chat.provider, "passage_count": chat.count]
                }
            case "search_decisions":
                let hits = try store.search(requiredString("query"))
                let encoded = try JSONEncoder().encode(hits)
                return try content(["hits": JSONSerialization.jsonObject(with: encoded)], version: version)
            case "read_passage":
                let citation = try requiredString("citation")
                let offset = try offset(arguments)
                let passage = try store.read(citation, offset: offset)
                return try content(["citation": citation, "offset": offset, "passage": passage],
                                   text: passage, version: version)
            case "prepare_handoff":
                guard let citations = arguments["citations"] as? [String],
                      (1...8).contains(citations.count),
                      citations.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                    throw RPCError(-32602, "Expected one to eight citations from search")
                }
                let brief = try store.draft(recipient: requiredString("recipient"), title: requiredString("title"),
                                            decision: requiredString("decision"), background: requiredString("background"),
                                            nextStep: requiredString("next_step"), citations: citations)
                return try content(preview(brief), version: version)
            case "get_handoffs":
                if arguments["draft_id"] != nil {
                    guard arguments["offset"] == nil else { throw RPCError(-32602, "Offset applies only to listing drafts") }
                    let id = try requiredString("draft_id")
                    guard let uuid = UUID(uuidString: id) else { throw HereforthError("Use a draft ID from get_handoffs.") }
                    guard let brief = try store.briefs().first(where: { $0.id == uuid.uuidString }) else {
                        throw HereforthError("This brief is missing from your local library.")
                    }
                    return try content(preview(brief), version: version)
                }
                let offset = try offset(arguments)
                return try list(store.briefs(), key: "handoffs", offset: offset, version: version, project: briefMetadata)
            default:
                throw RPCError(-32602, "Unknown tool")
            }
        } catch let error as RPCError {
            throw error
        } catch {
            let message = (error as? HereforthError)?.localizedDescription ?? "Could not access the local Hereforth library."
            return ["isError": true, "content": [["type": "text", "text": message]]]
        }
    }

    private func list<Entry>(_ entries: [Entry], key: String, offset: Int, version: String,
                             project: (Entry) -> Object) throws -> Object {
        let page = entries.dropFirst(offset).prefix(50)
        var result: Object = [key: page.map(project)]
        if page.endIndex < entries.endIndex { result["next_offset"] = page.endIndex }
        return try content(result, version: version)
    }

    private func offset(_ arguments: Object) throws -> Int {
        let value = arguments["offset"] ?? 0
        guard let offset = value as? Int, !isBoolean(value), offset >= 0 else {
            throw RPCError(-32602, "Expected a nonnegative integer offset")
        }
        return offset
    }

    private func briefMetadata(_ brief: Brief) -> Object {
        ["draft_id": brief.id, "title": brief.title, "recipient": brief.recipient]
    }

    private func preview(_ brief: Brief) -> Object {
        var result = briefMetadata(brief)
        result["markdown"] = brief.markdown
        result["instructions"] = "Open Hereforth and select Draft briefs to review this brief, or copy the Markdown and share it manually."
        return result
    }

    private func content(_ payload: Object, text: String? = nil, version: String) throws -> Object {
        let fallback = try text ?? String(decoding: JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        var result: Object = ["content": [["type": "text", "text": fallback]], "isError": false]
        if version >= "2025-06-18" { result["structuredContent"] = payload }
        return result
    }

    private func object(_ value: Any?) throws -> Object {
        guard let value else { return [:] }
        guard let object = value as? Object else { throw RPCError(-32602, "Expected an object") }
        return object
    }

    private func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

private struct RPCError: Error {
    let code: Int
    let message: String

    init(_ code: Int, _ message: String) {
        self.code = code
        self.message = message
    }
}

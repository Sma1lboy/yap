import Foundation

/// MCP over stdio (https://modelcontextprotocol.io/specification/2025-11-25): one JSON-RPC message per line on
/// stdin, one per line on stdout. The handshake-based revisions only (`initialize`); `server/discover` of the
/// 2026-07-28 revision gets Method not found, which tells a dual-era client to fall back to `initialize`.
final class MCPServer {
    /// Newest first; an `initialize` asking for another version gets the newest.
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    private let library: MeetingLibrary
    private let output: FileHandle

    init(library: MeetingLibrary, output: FileHandle) {
        self.library = library
        self.output = output
    }

    /// Answers each line until stdin closes, then returns (the client's way of ending the session).
    func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.allSatisfy(\.isWhitespace) else { continue }
            handle(line)
        }
    }

    private func handle(_ line: String) {
        guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else {
            return send(error: -32700, "Parse error", id: NSNull())
        }
        guard let message = json as? [String: Any], message["jsonrpc"] as? String == "2.0" else {
            return send(error: -32600, "Invalid Request", id: (json as? [String: Any])?["id"] ?? NSNull())
        }
        let id = message["id"]
        guard let method = message["method"] as? String else {
            // A response to a request of ours: this server never sends any, so there's nothing to match it to.
            if message["result"] != nil || message["error"] != nil { return }
            return send(error: -32600, "Invalid Request", id: id ?? NSNull())
        }
        // Notifications (initialized, cancelled…) get no answer.
        guard let id else { return }
        guard id is String || (id is NSNumber && !JSON.isBool(id)) else {
            return send(error: -32600, "Invalid Request: id must be a string or a number", id: NSNull())
        }
        guard message["params"] == nil || message["params"] is [String: Any] else {
            return send(error: -32602, "Invalid params: params must be an object", id: id)
        }
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            let version = requested.flatMap { Self.protocolVersions.contains($0) ? $0 : nil } ?? Self.protocolVersions[0]
            send(result: [
                "protocolVersion": version,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "yap", "title": "Yap", "version": EnclosingApp.version],
                "instructions": """
                    Read-only access to the meetings recorded with Yap on this Mac: their AI notes and timestamped \
                    transcripts, read from Yap's local history (nothing goes over the network). Find a meeting with \
                    list_meetings (newest first, filter by date), then read it with get_meeting.
                    """,
            ], id: id)
        case "ping":
            send(result: [:], id: id)
        case "tools/list":
            send(result: ["tools": Tools.definitions], id: id)
        case "tools/call":
            guard let name = params["name"] as? String else {
                return send(error: -32602, "Invalid params: name is required", id: id)
            }
            guard params["arguments"] == nil || params["arguments"] is [String: Any] else {
                return send(error: -32602, "Invalid params: arguments must be an object", id: id)
            }
            guard let result = Tools.call(name, arguments: params["arguments"] as? [String: Any] ?? [:], library: library)
            else {
                return send(error: -32602, "Unknown tool: \(name)", id: id)
            }
            send(result: result, id: id)
        default:
            send(error: -32601, "Method not found: \(method)", id: id)
        }
    }

    private func send(result: [String: Any], id: Any) {
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func send(error code: Int, _ message: String, id: Any) {
        write(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    /// One message, one line: JSONSerialization without pretty-printing escapes every newline inside strings.
    private func write(_ message: [String: Any]) {
        do {
            var data = try JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
            data.append(0x0A)
            try output.write(contentsOf: data)
        } catch {
            log("can't write to stdout (\(error.localizedDescription)), quitting")
            exit(0)
        }
    }
}

/// The tools: read-only, local, and nothing but meetings for now.
enum Tools {
    static let readOnly: [String: Any] = [
        "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false,
    ]

    static let definitions: [[String: Any]] = [
        [
            "name": "list_meetings",
            "title": "List Yap meetings",
            "description": """
                List the meetings recorded with Yap (a dictation and meeting-notes app) on this Mac, newest first. \
                Read-only, from Yap's local history; nothing leaves the Mac. For each meeting: id (pass it to \
                get_meeting), started_at (ISO 8601 with the Mac's UTC offset), duration_seconds, title (Yap's \
                meetings have no titles, so this is the start date and time as Yap shows it), speakers (the names \
                the user gave in Yap, else "Me" for the person who recorded and "Others" / "Others 1", "Others 2" \
                for the people on the call), has_notes (Yap wrote AI notes), speaker_separation ("done"; \
                "pending": the remote speakers are still being told apart, so the transcript may say just \
                "Others"; "failed") and untranscribed_parts (pieces that couldn't be transcribed, only when there \
                are any). "more" is true when the date range holds more meetings than "limit".
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "limit": [
                        "type": "integer", "minimum": 1, "maximum": 100, "default": 20,
                        "description": "How many meetings to return, newest first (1–100, default 20).",
                    ],
                    "since": [
                        "type": "string",
                        "description": """
                            Only meetings that started at or after this: a date (2026-09-30, from local midnight) \
                            or an ISO 8601 date-time (2026-09-30T14:00:00+02:00).
                            """,
                    ],
                    "until": [
                        "type": "string",
                        "description": """
                            Only meetings that started at or before this: a date (2026-09-30, the whole day counts) \
                            or an ISO 8601 date-time.
                            """,
                    ],
                ],
                "additionalProperties": false,
            ],
            "outputSchema": [
                "type": "object",
                "properties": [
                    "meetings": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "id": ["type": "string"],
                                "started_at": ["type": "string"],
                                "duration_seconds": ["type": "integer"],
                                "title": ["type": "string"],
                                "speakers": ["type": "array", "items": ["type": "string"]],
                                "has_notes": ["type": "boolean"],
                                "speaker_separation": ["type": "string", "enum": ["done", "pending", "failed"]],
                                "untranscribed_parts": ["type": "integer"],
                            ],
                            "required": [
                                "id", "started_at", "duration_seconds", "title", "speakers", "has_notes",
                                "speaker_separation",
                            ],
                        ],
                    ],
                    "more": ["type": "boolean"],
                ],
                "required": ["meetings", "more"],
            ],
            "annotations": readOnly,
        ],
        [
            "name": "get_meeting",
            "title": "Get a Yap meeting",
            "description": """
                One meeting recorded with Yap on this Mac, as Markdown, exactly as Yap's History › Export Markdown \
                writes it: a heading, the start date and time and the duration, the AI notes (when Yap wrote \
                them: summary, decisions, action items, open questions) and the timestamped transcript (lines like \
                **[00:12] Reed**: …, with the speaker names the user gave; "Me" is the person who recorded). \
                Headings are in Yap's app language. Read-only, from Yap's local history. Get ids from list_meetings.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "The meeting's id, from list_meetings."],
                    "include_transcript": [
                        "type": "boolean", "default": true,
                        "description": "false returns the heading and the notes only (an hour's transcript is long).",
                    ],
                ],
                "required": ["id"],
                "additionalProperties": false,
            ],
            "annotations": readOnly,
        ],
    ]

    /// A `tools/call` result, or nil for a tool this server doesn't have (a protocol error, not a tool error).
    static func call(_ name: String, arguments: [String: Any], library: MeetingLibrary) -> [String: Any]? {
        switch name {
        case "list_meetings": return listMeetings(arguments, library: library)
        case "get_meeting": return getMeeting(arguments, library: library)
        default: return nil
        }
    }

    private static func listMeetings(_ arguments: [String: Any], library: MeetingLibrary) -> [String: Any] {
        if let unknown = arguments.keys.first(where: { !["limit", "since", "until"].contains($0) }) {
            return failure("Unknown argument \"\(unknown)\". list_meetings takes limit, since and until.")
        }
        var limit = 20
        if let value = arguments["limit"] {
            guard let number = value as? NSNumber, !JSON.isBool(value), let exact = Int(exactly: number.doubleValue),
                (1...100).contains(exact)
            else { return failure("limit must be a whole number from 1 to 100.") }
            limit = exact
        }
        var bounds: [Date?] = []
        for (key, endOfDay) in [("since", false), ("until", true)] {
            guard let value = arguments[key] else {
                bounds.append(nil)
                continue
            }
            guard let text = value as? String, let date = Dates.parse(text, endOfDay: endOfDay) else {
                return failure("\(key) must be a date like 2026-09-30 or an ISO 8601 date-time like 2026-09-30T14:00:00+02:00.")
            }
            bounds.append(date)
        }
        do {
            let (meetings, more) = try library.meetings(since: bounds[0], until: bounds[1], limit: limit)
            let items: [[String: Any]] = meetings.map { meeting in
                var item: [String: Any] = [
                    "id": meeting.id.uuidString,
                    "started_at": Dates.iso8601(meeting.started),
                    "duration_seconds": Int(meeting.duration.rounded()),
                    "title": meeting.started.formatted(date: .abbreviated, time: .shortened),
                    "speakers": meeting.speakers,
                    "has_notes": meeting.hasNotes,
                    "speaker_separation": meeting.speakerStatus.map { $0 == "pending" ? "pending" : "failed" } ?? "done",
                ]
                if let parts = meeting.untranscribedParts, parts > 0 { item["untranscribed_parts"] = parts }
                return item
            }
            let structured: [String: Any] = ["meetings": items, "more": more]
            let text = (try? JSONSerialization.data(withJSONObject: structured, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return ["content": [["type": "text", "text": text]], "structuredContent": structured, "isError": false]
        } catch {
            return failure("Yap's history couldn't be read: \(error.localizedDescription)")
        }
    }

    private static func getMeeting(_ arguments: [String: Any], library: MeetingLibrary) -> [String: Any] {
        if let unknown = arguments.keys.first(where: { !["id", "include_transcript"].contains($0) }) {
            return failure("Unknown argument \"\(unknown)\". get_meeting takes id and include_transcript.")
        }
        guard let text = arguments["id"] as? String else { return failure("id is required: a meeting id from list_meetings.") }
        var includeTranscript = true
        if let value = arguments["include_transcript"] {
            guard JSON.isBool(value), let flag = value as? Bool else {
                return failure("include_transcript must be true or false.")
            }
            includeTranscript = flag
        }
        let notFound = "There is no meeting with id \(text) in Yap's history on this Mac. Use list_meetings for the ids."
        guard let id = UUID(uuidString: text.trimmingCharacters(in: .whitespaces)) else { return failure(notFound) }
        do {
            guard let markdown = try library.markdown(id: id, includeTranscript: includeTranscript) else {
                return failure(notFound)
            }
            return ["content": [["type": "text", "text": markdown]], "isError": false]
        } catch {
            return failure("Yap's history couldn't be read: \(error.localizedDescription)")
        }
    }

    /// A tool error: the agent sees the message and can correct its call.
    private static func failure(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }
}

enum JSON {
    /// JSONSerialization gives true/false and 0/1 all as NSNumber, and Swift's `is Bool` accepts both; only the
    /// CFBoolean type tells them apart.
    static func isBool(_ value: Any) -> Bool {
        CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }
}

enum Dates {
    /// "2026-09-30T14:05:00+02:00", in the Mac's time zone.
    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    /// An ISO 8601 date-time, or a day ("2026-09-30") in the Mac's time zone: its start, or with `endOfDay` its
    /// last moment.
    static func parse(_ text: String, endOfDay: Bool) -> Date? {
        let text = text.trimmingCharacters(in: .whitespaces)
        let dateTime = ISO8601DateFormatter()
        if let date = dateTime.date(from: text) { return date }
        dateTime.formatOptions.insert(.withFractionalSeconds)
        if let date = dateTime.date(from: text) { return date }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.calendar = Calendar(identifier: .gregorian)
        day.timeZone = .current
        day.dateFormat = "yyyy-MM-dd"
        day.isLenient = false
        guard let start = day.date(from: text) else { return nil }
        guard endOfDay, let next = day.calendar.date(byAdding: .day, value: 1, to: start) else { return start }
        return next.addingTimeInterval(-0.001)
    }
}

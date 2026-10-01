import Foundation

/// MCP over stdio (https://modelcontextprotocol.io/specification/2025-11-25): one JSON-RPC message per line on
/// stdin, one per line on stdout. The handshake-based revisions only (`initialize`); `server/discover` of the
/// 2026-07-28 revision gets Method not found, which tells a dual-era client to fall back to `initialize`.
final class MCPServer {
    /// Newest first; an `initialize` asking for another version gets the newest.
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    private let library: YapLibrary
    private let output: FileHandle
    /// Read again for every tools/call: the user can change Settings › Agent Access (MCP) mid-session.
    private let access: () -> AgentAccess.Level

    init(library: YapLibrary, output: FileHandle, access: @escaping () -> AgentAccess.Level) {
        self.library = library
        self.output = output
        self.access = access
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
                    Read-only access to Yap's data on this Mac (Yap is a dictation and meeting-notes app): meetings \
                    with their AI notes and timestamped transcripts, the user's dictation history, and the \
                    dictionary of words and replacements. Everything is read from Yap's local files; nothing goes \
                    over the network. Find meetings with list_meetings and read one with get_meeting; search \
                    dictations and meetings with search_history and read a dictation with get_dictation; \
                    get_dictionary lists the dictionary. The user decides in Yap's Settings what agents may read: \
                    when something is switched off, the tool's error says which switch to turn on.
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
            let started = ContinuousClock.now
            guard
                let result = Tools.call(
                    name, arguments: params["arguments"] as? [String: Any] ?? [:], library: library, access: access)
            else {
                return send(error: -32602, "Unknown tool: \(name)", id: id)
            }
            if library.logsTiming {
                log("timing \(name): \(String(format: "%.1f", (ContinuousClock.now - started) / .milliseconds(1))) ms")
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
            library.removeCopies()
            exit(0)
        }
    }
}

/// The tools: read-only and local. Settings › Agent Access (MCP) decides which of them answer (`AgentAccess`).
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
                Headings are in Yap's app language. Read-only, from Yap's local history. Get ids from list_meetings \
                or search_history.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "The meeting's id, from list_meetings or search_history."],
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
        [
            "name": "search_history",
            "title": "Search Yap's history",
            "description": """
                Search what the user dictated with Yap and the meetings Yap recorded on this Mac, newest first. \
                Finds a piece of text anywhere (case and accents ignored; Chinese, English or both, like \
                "先看一下 CI") in a dictation's original or enhanced (cleaned-up) text, or in a meeting's \
                transcript or AI notes. Read-only, from Yap's local history; nothing leaves the Mac. Each result: \
                id, kind ("dictation" or "meeting"), at (ISO 8601 with the Mac's UTC offset), app (the app the \
                user dictated into, when known), mode (the Yap mode used, when any), field (where the snippet is \
                from: "original", "enhanced", "transcript" or "notes"), snippet (about 80 characters on each side \
                of the first match, "…" where cut), length (characters in that whole field) and read_with \
                (get_dictation or get_meeting: the tool that reads the whole entry with this id). "more" is true \
                when more entries match than "limit". When the user shares meetings but not dictations, only \
                meetings are searched and dictations_excluded is true.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string", "minLength": 1,
                        "description": "The text to find, as a substring: a word, a name, part of a sentence.",
                    ],
                    "kind": [
                        "type": "string", "enum": ["all", "dictation", "meeting"], "default": "all",
                        "description": "Search dictations, meetings, or both (default).",
                    ],
                    "since": [
                        "type": "string",
                        "description": "Only entries from this on: a date (2026-09-30, from local midnight) or an ISO 8601 date-time.",
                    ],
                    "until": [
                        "type": "string",
                        "description": "Only entries up to this: a date (2026-09-30, the whole day counts) or an ISO 8601 date-time.",
                    ],
                    "limit": [
                        "type": "integer", "minimum": 1, "maximum": AgentAccess.maxSearchLimit,
                        "default": AgentAccess.defaultSearchLimit,
                        "description": "How many results, newest first (default 20; at most 50, larger values give 50).",
                    ],
                ],
                "required": ["query"],
                "additionalProperties": false,
            ],
            "outputSchema": [
                "type": "object",
                "properties": [
                    "results": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "id": ["type": "string"],
                                "kind": ["type": "string", "enum": ["dictation", "meeting"]],
                                "at": ["type": "string"],
                                "app": ["type": "string"],
                                "mode": ["type": "string"],
                                "field": ["type": "string", "enum": ["original", "enhanced", "transcript", "notes"]],
                                "snippet": ["type": "string"],
                                "length": ["type": "integer"],
                                "read_with": ["type": "string", "enum": ["get_dictation", "get_meeting"]],
                            ],
                            "required": ["id", "kind", "at", "field", "snippet", "length", "read_with"],
                        ],
                    ],
                    "more": ["type": "boolean"],
                    "dictations_excluded": ["type": "boolean"],
                ],
                "required": ["results", "more", "dictations_excluded"],
            ],
            "annotations": readOnly,
        ],
        [
            "name": "get_dictation",
            "title": "Get a Yap dictation",
            "description": """
                One dictation from Yap's history on this Mac: original (what the speech recognition wrote), \
                enhanced (the cleaned-up text Yap pasted, when the mode cleaned it up), at, duration_seconds, \
                app, mode and status (when it isn't "completed"). Read-only, from Yap's local history. Get ids \
                from search_history. Meetings are read with get_meeting.
                """,
            "inputSchema": [
                "type": "object",
                "properties": ["id": ["type": "string", "description": "The dictation's id, from search_history."]],
                "required": ["id"],
                "additionalProperties": false,
            ],
            "outputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string"],
                    "at": ["type": "string"],
                    "duration_seconds": ["type": "number"],
                    "app": ["type": "string"],
                    "mode": ["type": "string"],
                    "original": ["type": "string"],
                    "enhanced": ["type": "string"],
                    "status": ["type": "string"],
                ],
                "required": ["id", "at", "duration_seconds", "original"],
            ],
            "annotations": readOnly,
        ],
        [
            "name": "get_dictionary",
            "title": "Get Yap's dictionary",
            "description": """
                The user's dictionary in Yap on this Mac. words: names and terms Yap tells the speech recognition \
                to expect. replacements: rules Yap applies to every dictation, writing replacement wherever it \
                hears one of originals. auto_added: Yap learned it from the user's corrections rather than the \
                user typing it in. Read-only, from Yap's local dictionary.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "Only entries containing this text (case and accents ignored).",
                    ]
                ],
                "additionalProperties": false,
            ],
            "outputSchema": [
                "type": "object",
                "properties": [
                    "words": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": ["word": ["type": "string"], "auto_added": ["type": "boolean"]],
                            "required": ["word", "auto_added"],
                        ],
                    ],
                    "replacements": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "originals": ["type": "array", "items": ["type": "string"]],
                                "replacement": ["type": "string"],
                                "auto_added": ["type": "boolean"],
                            ],
                            "required": ["originals", "replacement", "auto_added"],
                        ],
                    ],
                ],
                "required": ["words", "replacements"],
            ],
            "annotations": readOnly,
        ],
    ]

    /// A `tools/call` result, or nil for a tool this server doesn't have (a protocol error, not a tool error).
    /// `access` is read only for tools that exist, once per call.
    static func call(
        _ name: String, arguments: [String: Any], library: YapLibrary, access: () -> AgentAccess.Level
    ) -> [String: Any]? {
        guard definitions.contains(where: { $0["name"] as? String == name }) else { return nil }
        let level = access()
        guard level != .off else { return failure(accessOff) }
        switch name {
        case "list_meetings": return listMeetings(arguments, library: library)
        case "get_meeting": return getMeeting(arguments, library: library)
        case "search_history": return searchHistory(arguments, library: library, level: level)
        case "get_dictation": return getDictation(arguments, library: library, level: level)
        case "get_dictionary": return getDictionary(arguments, library: library)
        default: return nil
        }
    }

    /// The switches' names as Yap shows them, in the app's language.
    static var accessOff: String {
        let bundle = EnclosingApp.strings
        return """
            Yap doesn't let agents read its data: ask the user to turn on "\(AgentAccess.enabledTitle(bundle: bundle))" \
            in \(AgentAccess.settingsPath(bundle: bundle)). It applies to the next call, without restarting anything.
            """
    }

    static var dictationsOff: String {
        let bundle = EnclosingApp.strings
        return """
            The user hasn't shared their dictation history with agents; meetings and the dictionary can be read. To \
            read dictations, ask the user to turn on "\(AgentAccess.dictationsTitle(bundle: bundle))" in \
            \(AgentAccess.settingsPath(bundle: bundle)).
            """
    }

    private static func listMeetings(_ arguments: [String: Any], library: YapLibrary) -> [String: Any] {
        if let unknown = arguments.keys.first(where: { !["limit", "since", "until"].contains($0) }) {
            return failure("Unknown argument \"\(unknown)\". list_meetings takes limit, since and until.")
        }
        var limit = 20
        if let value = arguments["limit"] {
            guard let exact = wholeNumber(value), (1...100).contains(exact)
            else { return failure("limit must be a whole number from 1 to 100.") }
            limit = exact
        }
        guard let range = dateRange(arguments) else { return failure(dateHelp) }
        do {
            let (meetings, more) = try library.meetings(since: range.since, until: range.until, limit: limit)
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
            return structured(["meetings": items, "more": more])
        } catch {
            return failure("Yap's history couldn't be read: \(error.localizedDescription)")
        }
    }

    private static func getMeeting(_ arguments: [String: Any], library: YapLibrary) -> [String: Any] {
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

    private static func searchHistory(_ arguments: [String: Any], library: YapLibrary, level: AgentAccess.Level)
        -> [String: Any]
    {
        if let unknown = arguments.keys.first(where: { !["query", "kind", "since", "until", "limit"].contains($0) }) {
            return failure("Unknown argument \"\(unknown)\". search_history takes query, kind, since, until and limit.")
        }
        guard let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !query.isEmpty
        else { return failure("query is required: the text to find.") }
        let kind = arguments["kind"] as? String ?? "all"
        guard arguments["kind"] == nil || arguments["kind"] is String, ["all", "dictation", "meeting"].contains(kind)
        else { return failure("kind must be \"all\", \"dictation\" or \"meeting\".") }
        var requested: Int?
        if let value = arguments["limit"] {
            guard let exact = wholeNumber(value) else { return failure("limit must be a whole number (1 to 50).") }
            requested = exact
        }
        guard let range = dateRange(arguments) else { return failure(dateHelp) }

        let dictationsShared = level == .everything
        if kind == "dictation" && !dictationsShared { return failure(dictationsOff) }
        var filter = HistoryFilter()
        filter.meetingsOnly = kind == "meeting" || !dictationsShared
        filter.dictationsOnly = kind == "dictation"
        filter.since = range.since
        filter.until = range.until
        do {
            let (matches, more) = try library.search(query, filter: filter, limit: AgentAccess.searchLimit(requested))
            let results: [[String: Any]] = matches.map { match in
                var item: [String: Any] = [
                    "id": match.id.uuidString,
                    "kind": match.isMeeting ? "meeting" : "dictation",
                    "at": Dates.iso8601(match.timestamp),
                    "field": match.isMeeting
                        ? (match.inEnhancedText ? "notes" : "transcript") : (match.inEnhancedText ? "enhanced" : "original"),
                    "snippet": match.snippet,
                    "length": match.fullLength,
                    "read_with": match.isMeeting ? "get_meeting" : "get_dictation",
                ]
                if let app = match.appName, !app.isEmpty { item["app"] = app }
                if let mode = match.modeName, !mode.isEmpty { item["mode"] = mode }
                return item
            }
            var result = structured([
                "results": results, "more": more, "dictations_excluded": kind == "all" && !dictationsShared,
            ])
            if kind == "all" && !dictationsShared, var content = result["content"] as? [[String: Any]] {
                content.append(["type": "text", "text": "Only meetings were searched. \(dictationsOff)"])
                result["content"] = content
            }
            return result
        } catch {
            return failure("Yap's history couldn't be read: \(error.localizedDescription)")
        }
    }

    private static func getDictation(_ arguments: [String: Any], library: YapLibrary, level: AgentAccess.Level)
        -> [String: Any]
    {
        guard level == .everything else { return failure(dictationsOff) }
        if let unknown = arguments.keys.first(where: { $0 != "id" }) {
            return failure("Unknown argument \"\(unknown)\". get_dictation takes id.")
        }
        guard let text = arguments["id"] as? String else {
            return failure("id is required: a dictation id from search_history.")
        }
        let notFound = "There is no dictation with id \(text) in Yap's history on this Mac. Use search_history for the ids."
        guard let id = UUID(uuidString: text.trimmingCharacters(in: .whitespaces)) else { return failure(notFound) }
        do {
            guard let dictation = try library.dictation(id: id) else {
                if try library.isMeeting(id: id) {
                    return failure("\(text) is a meeting, not a dictation: read it with get_meeting.")
                }
                return failure(notFound)
            }
            var item: [String: Any] = [
                "id": dictation.id.uuidString,
                "at": Dates.iso8601(dictation.timestamp),
                "duration_seconds": (dictation.duration * 10).rounded() / 10,
                "original": dictation.text,
            ]
            if let enhanced = dictation.enhancedText, !enhanced.isEmpty { item["enhanced"] = enhanced }
            if let app = dictation.appName, !app.isEmpty { item["app"] = app }
            if let mode = dictation.modeName, !mode.isEmpty { item["mode"] = mode }
            if let status = dictation.status, status != "completed" { item["status"] = status }
            return structured(item)
        } catch {
            return failure("Yap's history couldn't be read: \(error.localizedDescription)")
        }
    }

    private static func getDictionary(_ arguments: [String: Any], library: YapLibrary) -> [String: Any] {
        if let unknown = arguments.keys.first(where: { $0 != "query" }) {
            return failure("Unknown argument \"\(unknown)\". get_dictionary takes query.")
        }
        guard arguments["query"] == nil || arguments["query"] is String else { return failure("query must be text.") }
        let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let dictionary = try library.dictionary(matching: query)
            return structured([
                "words": dictionary.words.map { ["word": $0.word, "auto_added": $0.autoAdded] },
                "replacements": dictionary.replacements.map {
                    ["originals": $0.originals, "replacement": $0.replacement, "auto_added": $0.autoAdded]
                },
            ])
        } catch {
            return failure("Yap's dictionary couldn't be read: \(error.localizedDescription)")
        }
    }

    private static let dateHelp =
        "since and until must be a date like 2026-09-30 or an ISO 8601 date-time like 2026-09-30T14:00:00+02:00."

    /// since and until (each optional), or nil when one doesn't parse.
    private static func dateRange(_ arguments: [String: Any]) -> (since: Date?, until: Date?)? {
        var bounds: [Date?] = []
        for (key, endOfDay) in [("since", false), ("until", true)] {
            guard let value = arguments[key] else {
                bounds.append(nil)
                continue
            }
            guard let text = value as? String, let date = Dates.parse(text, endOfDay: endOfDay) else { return nil }
            bounds.append(date)
        }
        return (bounds[0], bounds[1])
    }

    /// A JSON integer (not true/false, not 2.5).
    private static func wholeNumber(_ value: Any) -> Int? {
        guard let number = value as? NSNumber, !JSON.isBool(value) else { return nil }
        return Int(exactly: number.doubleValue)
    }

    /// A result with `structuredContent`, and the same JSON as text for clients that only read text.
    private static func structured(_ object: [String: Any]) -> [String: Any] {
        let text = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return ["content": [["type": "text", "text": text]], "structuredContent": object, "isError": false]
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

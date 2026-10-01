# Yap's MCP server (yap-mcp)

`yap-mcp` lets an agent (Claude Code, Cursor, Codex, any MCP client) read the meetings Yap recorded on this Mac: their AI notes and timestamped transcripts. It ships inside the app as `Yap.app/Contents/Helpers/yap-mcp`. The agent starts it as a subprocess and talks to it over stdin/stdout. No account, no cloud, no network port. Yap doesn't need to be running.

This first version has meetings only. Dictation history, the dictionary, a privacy switch and a "Connect an agent" screen in Settings come next (M2.2).

## Tools

| Tool | Arguments | Returns |
|---|---|---|
| `list_meetings` | `limit` (1–100, default 20), `since`, `until` (a date `2026-09-30` in the Mac's time zone, or an ISO 8601 date-time; `until` with a date includes that whole day) | Meetings newest first: `id`, `started_at` (ISO 8601 with the Mac's UTC offset), `duration_seconds`, `title`, `speakers`, `has_notes`, `speaker_separation` (`done`, `pending`, `failed`), `untranscribed_parts` (only when some parts couldn't be transcribed), and `more` when the range holds more than `limit`. As JSON text and as `structuredContent`. |
| `get_meeting` | `id` (from `list_meetings`), `include_transcript` (default true) | The meeting as Markdown, byte for byte what History › Export Markdown writes: heading, date and duration, `## Notes`, `## Transcript`. With `include_transcript: false` it stops after the notes. |

- **Titles.** Yap's meetings have no titles, so `title` is the start date and time as Yap shows it.
- **Speakers.** `speakers` and the transcript use the names given in History › Speaker Names…; unnamed speakers are "Me" (whoever recorded) and "Others" / "Others 1", "Others 2".
- **Language.** Headings, labels and dates follow the app's language (Settings › Language, else the system's). The helper reads `AppleLanguages` from the app's own defaults and declares the app's localizations in its Info.plist (`YapMCP/Info.plist`), so it formats exactly like the app.
- **Errors.** An unknown id or a bad argument is a tool error (`isError: true`) the agent can read. An unknown tool name is a JSON-RPC error (−32602).

Both tools are annotated `readOnlyHint: true`, `destructiveHint: false`, `openWorldHint: false`.

## Where the data comes from, and why it's read-only

- **Location.** `~/Library/Application Support/me.sma1lboy.yap/default.store` is the SwiftData store History uses. A meeting is a `Transcription` with `kind = "meeting"`: `text` is the transcript, already carrying the speaker names; `enhancedText` holds the notes (see `docs/meeting-recording.md`). `--data-dir <path>` reads another folder, which the tests use.
- **A private copy per call.** Each tool call copies `default.store` and its `-wal` into a temporary folder and opens only the copy, then deletes it.
  - On APFS the copy is a clone. The `-shm` isn't copied: SQLite rebuilds that index from the WAL.
  - If Yap changes the store or its WAL during the copy (size or modification time differ afterwards), it copies again, up to 20 times, then reports that Yap is busy. The copy is always one moment's state, even while Yap is recording.
  - Yap's own files are only read with `copyItem`. SQLite never opens them, so nothing writes their `-shm` or checkpoints their WAL. `make mcp-check` compares the SHA-256 of every file in the data folder before and after a session.
- **Shared model files.** The helper compiles the app's own model files (`Transcription.swift`, the other three `@Model` files and `YapStores.swift`, which lists the model the app opens its stores with) and the app's Markdown export (`MeetingMarkdown.swift`). It has no copy of the schema: a model change the helper's code doesn't follow fails its build.
- **Store from another build.** The store may have been written by another build of Yap, for example an update installed but not launched yet. A store last written by 1.9.0 has different entity hashes than later builds. Core Data then migrates the temporary copy (never the original), and nothing is ever saved.
- **No data yet.** A missing data folder or store gives an empty list, and `get_meeting` reports a tool error.
- **No network.** The helper opens no network socket; `make mcp-check` checks with `lsof -a -p <pid> -i`.

## Connect an agent

The path is the same for every client: `/Applications/Yap.app/Contents/Helpers/yap-mcp` (adjust it if Yap is elsewhere). It takes no arguments.

**Claude Code** (checked with 2.1.284):

```sh
claude mcp add yap -- /Applications/Yap.app/Contents/Helpers/yap-mcp            # this project only
claude mcp add -s user yap -- /Applications/Yap.app/Contents/Helpers/yap-mcp    # every project
```

`claude mcp get yap` should say `Status: ✔ Connected`.

**Cursor**: `~/.cursor/mcp.json` (every project) or `.cursor/mcp.json` in a project:

```json
{
  "mcpServers": {
    "yap": {
      "type": "stdio",
      "command": "/Applications/Yap.app/Contents/Helpers/yap-mcp"
    }
  }
}
```

**Codex** (checked with codex-cli 0.158.0): `codex mcp add yap -- /Applications/Yap.app/Contents/Helpers/yap-mcp`, which writes this to `~/.codex/config.toml`:

```toml
[mcp_servers.yap]
command = "/Applications/Yap.app/Contents/Helpers/yap-mcp"
```

Then ask the agent something like "summarize the action items from my meetings this week".

## Protocol

- **Transport.** MCP over stdio: one JSON-RPC message per line. stdout carries only MCP messages: the helper keeps its own handle on the real stdout and points file descriptor 1 at stderr, so anything a framework prints goes to the log. Logs go to stderr. When stdin closes, the helper exits.
- **Versions.** Handshake-based revisions only: `initialize` accepts `2025-11-25`, `2025-06-18`, `2025-03-26` and `2024-11-05`. A requested version it supports is answered with that version; any other request gets `2025-11-25`. Claude Code 2.1.284 opens with `initialize` and `2025-11-25`.
- **Server info.** `serverInfo` is `yap` with the helper's version, which is the app's `MARKETING_VERSION`; release builds set both through one build setting. The only capability declared is `tools`.
- **Methods.** `notifications/initialized` and other notifications get no answer. `ping` returns `{}`; `tools/list` and `tools/call` are described above.
- **Errors.** Unknown methods, including the 2026-07-28 revision's `server/discover`, get −32601. That's the answer a dual-era client takes as "use `initialize`". A line that isn't JSON gets −32700.

## Verify

- **`make mcp-check`** (`scripts/mcp-check.sh`) builds Debug and copies the app as the mock identity.
  - The copy, launched with `--mcp-fixture` (`MCPFixture.swift`), creates its stores with the app's own `createPersistentContainer`. It adds three meetings and a dictation, renames one meeting's speakers through `MeetingEdits.rename`, and writes History's Markdown export of each meeting. It then quits with the store's `-wal` still unmerged, as a running Yap leaves it.
  - The copy's own `Contents/Helpers/yap-mcp` then gets `initialize`, `notifications/initialized`, `ping`, `tools/list`, `list_meetings` (with filters and bad arguments), `get_meeting` (each meeting, notes only, unknown and non-meeting ids), an unknown tool, an unknown method and a line that isn't JSON.
  - It checks that:
    - every stdout line is JSON-RPC;
    - both tools are read-only;
    - `get_meeting` equals the app's export byte for byte, in English and with the app's language set to Chinese;
    - every data file's SHA-256 is unchanged;
    - `lsof -i` shows no socket;
    - closing stdin ends the process;
    - a missing data folder gives an empty list;
    - the helper's version and localizations match the app's.
- **By hand, on real data:**

  ```sh
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"manual","version":"1"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_meetings","arguments":{}}}' \
    | /Applications/Yap.app/Contents/Helpers/yap-mcp
  ```

  On 2026-09-30, the Debug build's helper read a store last written by Yap 1.9.0 (141 History entries, none a meeting). It listed both tools, returned 0 meetings without an error, and left no temporary copy behind.

## Known limits

- **Meetings only.** No dictation history, dictionary or settings yet (M2.2), and no MCP resources or prompts. Nothing writes.
- **No switch in Yap.** Any process running as the user can start the helper, just as it could read the store itself. The privacy switch comes with the Settings screen in M2.2.
- **Entitlements.** Local and CI builds sign every target with the app's entitlements file (the Makefile passes `CODE_SIGN_ENTITLEMENTS` on the command line), so the helper carries the app's entitlements too. Outside the App Sandbox they don't change what it can do; it opens no socket.
- **Debug builds.** A Debug build's helper reads the real data folder (`me.sma1lboy.yap`, shared with the dev app) unless `--data-dir` says otherwise.

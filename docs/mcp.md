# Yap's MCP server (yap-mcp)

`yap-mcp` lets an agent (Claude Code, Cursor, Codex, any MCP client) read what Yap keeps on this Mac: meetings with their AI notes and timestamped transcripts, dictation history, and the dictionary. It ships inside the app as `Yap.app/Contents/Helpers/yap-mcp`. The agent starts it as a subprocess and talks to it over stdin/stdout. No account, no cloud, no network port. Yap doesn't need to be running.

Nothing is readable until the user turns it on in **Settings › Agent Access (MCP)** (below).

## Settings › Agent Access (MCP)

Two switches, both off on a new install and after an update:

| Switch | Defaults key | Off | On |
|---|---|---|---|
| **Let Agents Read Yap's Data** | `agentAccessEnabled` | Every `tools/call` is a tool error | Meetings and the dictionary can be read |
| **Include Dictation History** (only with the first on) | `agentAccessIncludesDictations` | `search_history` searches meetings only and says so (`dictations_excluded: true`); `get_dictation` and `kind: "dictation"` are tool errors | Dictations can be searched and read too |

- **Off still connects.** `initialize`, `tools/list` and `ping` answer whatever the switches say, so a client can be set up first and the switch turned on later. A refused call is `isError: true` with a sentence like *Yap doesn't let agents read its data: ask the user to turn on "Let Agents Read Yap's Data" in Yap › Settings › Agent Access (MCP).* The switch and section names are in the app's language.
- **Read on every call.** The helper reads both keys from the app's own defaults (`CFPreferencesAppSynchronize`, then `CFPreferencesCopyAppValue` for the app's bundle id) at each `tools/call`. Turning a switch off applies to the agent's next call; nothing needs a restart. `make mcp-check` flips them with `defaults write` in the middle of a session.
- **A missing value is off.** Nothing registers a default for these keys (the helper wouldn't see one). Only a real boolean `true` turns a switch on; `AgentAccess.level` (`VoiceInk/Features/Settings/AgentAccess.swift`, compiled into both the app and the helper) decides.
- **Why dictations have their own switch.** Dictations are typed into any app: passwords, private messages, drafts. Meeting notes are written to be shared. Wispr Flow's MCP server exposes meetings only, for the same reason.
- **Outside Yap.app.** A helper that isn't inside an app bundle has no app defaults to read, so it treats both switches as off.

The same Settings section shows how to connect an agent: the helper's path (from the running app's bundle, wherever it's installed, with **Show in Finder**), **Copy Command** for Claude Code and Codex, **Copy JSON** for Cursor's `mcp.json` (the forms below, with the path shell-quoted when it has a space), and **Learn More**, which opens this page. Search Settings for "MCP", "Claude Code", "Codex" or "Cursor" to find it.

## Tools

| Tool | Needs | Arguments | Returns |
|---|---|---|---|
| `list_meetings` | main switch | `limit` (1–100, default 20), `since`, `until` (a date `2026-09-30` in the Mac's time zone, or an ISO 8601 date-time; `until` with a date includes that whole day) | Meetings newest first: `id`, `started_at` (ISO 8601 with the Mac's UTC offset), `duration_seconds`, `title`, `speakers`, `has_notes`, `speaker_separation` (`done`, `pending`, `failed`), `untranscribed_parts` (only when some parts couldn't be transcribed), and `more` when the range holds more than `limit`. |
| `get_meeting` | main switch | `id` (from `list_meetings` or `search_history`), `include_transcript` (default true) | The meeting as Markdown, byte for byte what History › Export Markdown writes: heading, date and duration, `## Notes`, `## Transcript`. With `include_transcript: false` it stops after the notes. |
| `search_history` | main switch; dictations also need the second | `query` (required), `kind` (`all` default, `dictation`, `meeting`), `since`, `until`, `limit` (default 20; above 50 gives 50, below 1 gives 1) | Entries newest first: `id`, `kind`, `at`, `app` (the app dictated into, when known), `mode` (when one was used), `field` (`original`, `enhanced`, `transcript` or `notes`: where the snippet is from), `snippet`, `length` (characters in that whole field), `read_with` (`get_dictation` or `get_meeting`); `more`; `dictations_excluded`. |
| `get_dictation` | both switches | `id` (from `search_history`) | `id`, `at`, `duration_seconds`, `original` (the transcription), `enhanced` (the cleaned-up text, when the mode cleaned it up), `app`, `mode`, `status` (only when not `completed`). |
| `get_dictionary` | main switch | `query` (optional) | `words` (`word`, `auto_added`) and `replacements` (`originals`, the variants Yap listens for; `replacement`; `auto_added`), each sorted in the app's language. With `query`, only entries containing it (in a word, an original or a replacement). |

- **Search.** `search_history` runs History's own search: `HistoryQuery.predicate` (`VoiceInk/Features/History/Workflows/HistoryQuery.swift`, compiled into the helper), the predicate History's search field and Filter menu use, with the kind and date fields added for this tool. It matches `query` as a substring of a dictation's original or enhanced text, or a meeting's transcript or notes, ignoring case and accents, so "先看一下 ci" finds "我们先看一下 CI 再合并". The database does the matching and the limit, so `more` is exact.
- **Snippets.** `HistoryQuery.snippet`: the first match by the same rule (`localizedStandardRange`), with 80 characters on each side, line breaks turned into spaces and "…" where it's cut. A dictation's enhanced text and a meeting's notes are searched first, then the original text or transcript.
- **Titles.** Yap's meetings have no titles, so `title` is the start date and time as Yap shows it.
- **Speakers.** `speakers` and the transcript use the names given in History › Speaker Names…; unnamed speakers are "Me" (whoever recorded) and "Others" / "Others 1", "Others 2".
- **Language.** Headings, labels, dates and the switch names in errors follow the app's language (Settings › Language, else the system's). The helper reads `AppleLanguages` from the app's own defaults and declares the app's localizations in its Info.plist (`YapMCP/Info.plist`), so it formats exactly like the app.
- **Errors.** A refused call, an unknown id or a bad argument is a tool error (`isError: true`) the agent can read; `get_dictation` on a meeting's id says to use `get_meeting`. An unknown tool name is a JSON-RPC error (−32602), switches or not.
- **Output.** Everything but `get_meeting` comes as JSON text and as `structuredContent`, with an `outputSchema`. When dictations were left out of an `all` search, a second text item says which switch to turn on.

All tools are annotated `readOnlyHint: true`, `destructiveHint: false`, `openWorldHint: false`.

## Where the data comes from, and why it's read-only

- **Location.** `~/Library/Application Support/me.sma1lboy.yap/`. `default.store` is the SwiftData store History uses: a dictation is a `Transcription` with no `kind`; a meeting has `kind = "meeting"`, its transcript (with the speaker names) in `text` and its notes in `enhancedText` (see `docs/meeting-recording.md`). `dictionary.store` holds `VocabularyWord` and `WordReplacement`. `--data-dir <path>` reads another folder, which the tests use.
- **A private copy per call.** Each tool call copies the store it needs and its `-wal` into a temporary folder and opens only the copy, then deletes it.
  - On APFS the copy is a clone. The `-shm` isn't copied: SQLite rebuilds that index from the WAL.
  - If Yap changes the store or its WAL during the copy (size or modification time differ afterwards), it copies again, up to 20 times, 50 ms apart, then reports that Yap is busy (a tool error: *Yap kept writing its data while it was being copied; try again in a moment.*). Each redo is logged to stderr.
  - Yap's own files are only read with `copyItem`. SQLite never opens them, so nothing writes their `-shm` or checkpoints their WAL. `make mcp-check` compares the SHA-256 of every file in the data folder before and after a session.
- **What a reader sees while Yap writes.** A copy is the database and WAL as they were at one moment between two of Yap's file writes, so it holds every transaction committed up to some point and none after it: a save is all there or not there. `make mcp-check` checks exactly that against a writer saving a dictation every few milliseconds.
- **Shared model files.** The helper compiles the app's own model files (`Transcription.swift`, the other three `@Model` files and `YapStores.swift`, which holds the model and the stores' configurations the app opens them with), History's search (`HistoryQuery.swift`), the dictionary's variant parsing (`WordReplacementVariants.swift`), the switches (`AgentAccess.swift`) and the app's Markdown export (`MeetingMarkdown.swift`). It has no copy of the schema or the search: a change the helper's code doesn't follow fails its build.
- **Store from another build.** The store may have been written by another build of Yap, for example an update installed but not launched yet. A store last written by 1.9.0 has different entity hashes than later builds. Core Data then migrates the temporary copy (never the original), and nothing is ever saved.
- **The dictionary and iCloud.** Release builds sync `dictionary.store` through the user's private CloudKit database, so the file carries CloudKit's history tables. The helper opens its copy with the app's dictionary configuration and CloudKit off (`YapStores.dictionaryConfiguration(url:cloudKitDatabase: .none)`), which reads the rows and never contacts iCloud.
- **No data yet.** A missing data folder or store gives empty lists, and `get_meeting` / `get_dictation` report a tool error.
- **No network.** The helper opens no network socket; `make mcp-check` checks with `lsof -a -p <pid> -i`.

## Connect an agent

Settings › Agent Access (MCP) copies these with the right path. Installed in Applications it is `/Applications/Yap.app/Contents/Helpers/yap-mcp`; the helper takes no arguments.

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

Then turn on the switch and ask the agent something like:

- "Summarize the action items from my meetings this week."
- "What did I dictate about the CI migration last month?" (needs Include Dictation History)
- "Which names in my Yap dictionary are spelled differently in this README?"

## Protocol

- **Transport.** MCP over stdio: one JSON-RPC message per line. stdout carries only MCP messages: the helper keeps its own handle on the real stdout and points file descriptor 1 at stderr, so anything a framework prints goes to the log. Logs go to stderr. When stdin closes, the helper exits.
- **Versions.** Handshake-based revisions only: `initialize` accepts `2025-11-25`, `2025-06-18`, `2025-03-26` and `2024-11-05`. A requested version it supports is answered with that version; any other request gets `2025-11-25`. Claude Code 2.1.284 opens with `initialize` and `2025-11-25`.
- **Server info.** `serverInfo` is `yap` with the helper's version, which is the app's `MARKETING_VERSION`; release builds set both through one build setting. The only capability declared is `tools`. `instructions` lists the tools and says that the user's switches decide what can be read.
- **Methods.** `notifications/initialized` and other notifications get no answer. `ping` returns `{}`; `tools/list` and `tools/call` are described above.
- **Errors.** Unknown methods, including the 2026-07-28 revision's `server/discover`, get −32601. That's the answer a dual-era client takes as "use `initialize`". A line that isn't JSON gets −32700.

## Verify

- **`make mcp-check`** (`scripts/mcp-check.sh`, driver `scripts/mcp-check.py`) builds Debug and copies the app as the mock identity (`me.sma1lboy.yap.mock`, its own defaults domain, deleted afterwards).
  - The copy, launched with `--mcp-fixture` (`MCPFixture.swift`), creates its stores with the app's own `createPersistentContainer`. It adds three meetings, dictations (one into Slack with a mode and Chinese–English cleaned-up text, one long, 55 alike), and a dictionary (three words, two rules, some auto-added). It renames one meeting's speakers through `MeetingEdits.rename` and writes History's Markdown export of each meeting. It then quits with the stores' `-wal` still unmerged, as a running Yap leaves them.
  - In English and with the app's language set to Chinese, the copy's own `Contents/Helpers/yap-mcp` gets the handshake, then every tool with the switches all off, the main one only, and both on, flipped with `defaults write` mid-session, then off again. It checks that:
    - all off: the session connects and lists the five tools; every call is a tool error naming the switch in the app's language;
    - main switch only: meetings and the dictionary are read; `search_history` returns meetings only with `dictations_excluded`; `get_dictation` and `kind: "dictation"` are errors naming the second switch;
    - both on: a Chinese–English query finds a dictation and a meeting newest first; `kind`, `since` and `until` narrow it; snippets are cut 80 characters around the hit; `limit` defaults to 20 and stops at 50; `get_dictation` and `get_dictionary` (with and without `query`) return the fixture's entries; bad arguments and unknown ids are tool errors;
    - turned off again: the next call is refused;
    - `get_meeting` equals the app's export byte for byte;
    - every stdout line is JSON-RPC, all tools are read-only, every data file's SHA-256 is unchanged, `lsof -i` shows no socket, closing stdin ends the process, a missing data folder gives empty lists;
    - the helper's version and localizations match the app's.
  - **Concurrent writer.** The copy launched with `--mcp-fixture-writer` saves a dictation (`writer-seq-n` plus 8 KB, enhanced text `writer-check-n`) every 2 ms into a third data folder, crossing several WAL checkpoints. For 8 seconds the helper searches the newest 50 and reads the newest whole. Every answer must be either a "busy" tool error or dictations n, n−1, … with their full text and matching enhanced text (no torn row, no gap), the newest n must grow during the run, the helper must exit normally, and no temporary copy may be left behind. It reports how many copies were redone.
- **By hand, on real data:** turn the switch on, then:

  ```sh
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"manual","version":"1"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search_history","arguments":{"query":"CI"}}}' \
    | /Applications/Yap.app/Contents/Helpers/yap-mcp
  ```

  On 2026-09-30, the Debug build's helper read a store last written by Yap 1.9.0 (141 History entries, none a meeting) while that Yap was running. It listed the tools, returned 0 meetings without an error, and left no temporary copy behind. Claude Code 2.1.284 registered with `claude mcp add` showed `✔ Connected`. Later that day, with both switches turned on for the run and then removed again: `search_history` returned 3 and 50 (`more`) dictations for two queries and 0 meetings, `get_dictation` read one of them, `get_dictionary` returned 0 words and 0 rules (the Mac's dictionary is empty), with no errors in the log and no temporary copy left.

## Known limits

- **Read-only, tools only.** Nothing writes. No MCP resources or prompts, no vector search.
- **Handshake-based clients only.** A client that speaks only the 2026-07-28 revision (no `initialize`) can't connect. Dual-era clients fall back to `initialize`; Claude Code 2.1.284 and the clients above use it.
- **The switches are the only gate.** With the main switch on, any process running as the user can start the helper and read meetings and the dictionary, just as it could read the store files itself. The switches stop agents the user connected from reading what they shouldn't; they're not a sandbox.
- **Busy is untested by real contention.** In `make mcp-check` the writer forces redone copies but has never exhausted the 20 tries, so the "busy" answer has been seen only in code, not in a run.
- **Untested paths.** A `dictionary.store` written by a Release build with iCloud on (with CloudKit's tables) hasn't been read: the fixture's store is a Debug one without CloudKit, and this Mac's real dictionary is empty and has no CloudKit tables. `get_meeting` on a real meeting hasn't been run here (the Mac's History has no meetings); the fixture's meetings go through the app's own save and rename code.
- **Version bumps touch six lines.** The helper has its own `MARKETING_VERSION` (Debug and Release) next to the app's and the XPC service's; a release bump must change all six, and `make mcp-check` fails when the helper's and the app's differ. Tag builds in CI pass `MARKETING_VERSION` on the command line, which sets every target.
- **Entitlements.** Local and CI builds sign every target with the app's entitlements file (the Makefile passes `CODE_SIGN_ENTITLEMENTS` on the command line), so the helper carries the app's entitlements too. Outside the App Sandbox they don't change what it can do; it opens no socket.
- **Debug builds.** A Debug build's helper reads the real data folder (`me.sma1lboy.yap`, shared with the dev app) unless `--data-dir` says otherwise, and the dev app's switches (`me.sma1lboy.yap.dev`).

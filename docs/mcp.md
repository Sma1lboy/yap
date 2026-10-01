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
| `list_meetings` | main switch | `limit` (1–100, default 20), `since`, `until` (a date `2026-09-30` in the Mac's time zone, or an ISO 8601 date-time; `until` with a date includes that whole day) | Meetings newest first: `id`, `started_at` (ISO 8601 with the Mac's UTC offset), `duration_seconds`, `title`, `summary` (the notes' first line that isn't a heading, at most 200 characters; only with notes), `speakers`, `has_notes`, `speaker_separation` (`done`, `pending`, `failed`), `untranscribed_parts` (only when some parts couldn't be transcribed), and `more` when the range holds more than `limit`. |
| `get_meeting` | main switch | `id` (from `list_meetings` or `search_history`), `include_transcript` (default true) | The meeting as Markdown, byte for byte what History › Export Markdown writes: heading, date and duration, `## Notes`, `## Transcript`. With `include_transcript: false` it stops after the notes. |
| `search_history` | main switch; dictations also need the second | `query` (required), `kind` (`all` default, `dictation`, `meeting`), `since`, `until`, `limit` (default 20; above 50 gives 50, below 1 gives 1) | Entries newest first: `id`, `kind`, `at`, `app` (the app dictated into, when known), `mode` (when one was used), `field` (`original`, `enhanced`, `transcript` or `notes`: where the snippet is from), `snippet`, `length` (characters in that whole field), `read_with` (`get_dictation` or `get_meeting`); `more`; `dictations_excluded`. |
| `get_dictation` | both switches | `id` (from `search_history`) | `id`, `at`, `duration_seconds`, `original` (the transcription), `enhanced` (the cleaned-up text, when the mode cleaned it up), `app`, `mode`, `status` (only when not `completed`). |
| `get_dictionary` | main switch | `query` (optional) | `words` (`word`, `auto_added`) and `replacements` (`originals`, the variants Yap listens for; `replacement`; `auto_added`), each sorted in the app's language. With `query`, only entries containing it (in a word, an original or a replacement). |

- **Search.** `search_history` runs History's own search: `HistoryQuery.predicate` (`VoiceInk/Features/History/Workflows/HistoryQuery.swift`, compiled into the helper), the predicate History's search field and Filter menu use, with the kind and date fields added for this tool. It matches `query` as a substring of a dictation's original or enhanced text, or a meeting's transcript or notes, ignoring case and accents, so "先看一下 ci" finds "我们先看一下 CI 再合并". The database does the matching and the limit, so `more` is exact.
- **Snippets.** `HistoryQuery.snippet`: the first match by the same rule (`localizedStandardRange`), with 80 characters on each side, line breaks turned into spaces and "…" where it's cut. A dictation's enhanced text and a meeting's notes are searched first, then the original text or transcript.
- **Titles.** Yap's meetings have no titles, so `title` is the start date and time as Yap shows it. `summary` is the first line of the notes that isn't a heading: Yap's notes prompt opens with 3–5 summary bullets, so it's the first of them, and the list shows something of each meeting's topic without a `get_meeting` per meeting.
- **Speakers.** `speakers` and the transcript use the names given in History › Speaker Names…; unnamed speakers are "Me" (whoever recorded) and "Others" / "Others 1", "Others 2".
- **Language.** Headings, labels, dates and the switch names in errors follow the app's language (Settings › Language, else the system's). The helper reads `AppleLanguages` from the app's own defaults and declares the app's localizations in its Info.plist (`YapMCP/Info.plist`), so it formats exactly like the app.
- **Errors.** A refused call, an unknown id or a bad argument is a tool error (`isError: true`) the agent can read; `get_dictation` on a meeting's id says to use `get_meeting`. An unknown tool name is a JSON-RPC error (−32602), switches or not.
- **Output.** Everything but `get_meeting` comes as JSON text and as `structuredContent`, with an `outputSchema`. When dictations were left out of an `all` search, a second text item says which switch to turn on.

All tools are annotated `readOnlyHint: true`, `destructiveHint: false`, `openWorldHint: false`.

## Where the data comes from, and why it's read-only

- **Location.** `~/Library/Application Support/me.sma1lboy.yap/`. `default.store` is the SwiftData store History uses: a dictation is a `Transcription` with no `kind`; a meeting has `kind = "meeting"`, its transcript (with the speaker names) in `text` and its notes in `enhancedText` (see `docs/meeting-recording.md`). `dictionary.store` holds `VocabularyWord` and `WordReplacement`. `--data-dir <path>` reads another folder, which the tests use.
- **A private copy, made again when Yap writes.** A call copies the store it needs and its `-wal` into a temporary folder and opens only the copy. The helper keeps that copy, open, for the next calls as long as the store's and the `-wal`'s file number, size and modification time (to the nanosecond) stay the same; any write by Yap changes one of them, and the next call copies again. Each call reads through a new `ModelContext`, so nothing read earlier is reused. The copies (one per store) are deleted when stdin closes, when stdout fails, and on SIGTERM, SIGINT or SIGHUP, so a client that follows MCP's stdio shutdown (close stdin, then SIGTERM) leaves nothing behind; only SIGKILL leaves the last copies in `$TMPDIR`.
  - On APFS the copy is a clone (about 1 ms for a 40 MB store). The `-shm` isn't copied: SQLite rebuilds that index from the WAL when the copy is first read, about 90 ms for a 4 MB WAL, which is what keeping the copy saves.
  - If Yap changes the store or its WAL during the copy (size or modification time differ afterwards), it copies again, up to 20 times, 50 ms apart, then reports that Yap is busy (a tool error: *Yap kept writing its data while it was being copied; try again in a moment.*). Each redo is logged to stderr.
  - Yap's own files are only read with `copyItem` and `stat`. SQLite never opens them, so nothing writes their `-shm` or checkpoints their WAL. `make mcp-check` compares the SHA-256 of every file in the data folder before and after a session.
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
    - main switch only: meetings (with their `summary`) and the dictionary are read; `search_history` returns meetings only with `dictations_excluded`; `get_dictation` and `kind: "dictation"` are errors naming the second switch;
    - both on: a Chinese–English query finds a dictation and a meeting newest first; `kind`, `since` and `until` narrow it; snippets are cut 80 characters around the hit; `limit` defaults to 20 and stops at 50; `get_dictation` and `get_dictionary` (with and without `query`) return the fixture's entries; bad arguments and unknown ids are tool errors;
    - turned off again: the next call is refused;
    - `get_meeting` equals the app's export byte for byte;
    - every stdout line is JSON-RPC, all tools are read-only, every data file's SHA-256 is unchanged, `lsof -i` shows no socket, closing stdin ends the process, a missing data folder gives empty lists;
    - two calls keep two copies (history and dictionary) in `$TMPDIR`, and SIGTERM deletes them and exits 0;
    - the helper's version and localizations match the app's.
  - **Concurrent writer.** The copy launched with `--mcp-fixture-writer` saves a dictation (`writer-seq-n` plus 8 KB, enhanced text `writer-check-n`) every 2 ms into a third data folder, crossing several WAL checkpoints. For 8 seconds the helper searches the newest 50 and reads the newest whole. Every answer must be either a "busy" tool error or dictations n, n−1, … with their full text and matching enhanced text (no torn row, no gap), the newest n must grow during the run (so a kept copy is never read after Yap wrote), the helper must exit normally, and no temporary copy may be left behind. It reports how many copies were redone.
- **Real agents: `make mcp-agent-eval`** (`scripts/mcp-agent-eval.sh`, driver `scripts/mcp-agent-eval.py`; `LABEL=<name>` names the results folder `/tmp/yap-mcp-eval/<name>`, `EVAL_RUNS=2` asks everything twice). Three copies of the Debug app, each under its own bundle id with the switches both on, the main one only and both off, and the app's language set to Chinese, write a month of someone's Yap with `--mcp-fixture-month` (`MCPEvalFixture.swift`), dated back from the day of the run: about 300 dictations in Chinese, English and both, into Slack, Mail, Cursor, Terminal and WeChat; six meetings, most with renamed speakers, notes with decisions and action items; 30 words and 10 replacement rules. Each copy's own helper is registered with `codex mcp add` in a throwaway `CODEX_HOME` (only `auth.json` is copied in) and, for Claude Code, a `--strict-mcp-config` file. Codex runs `codex exec` with its shell, apps, browser and memories off in a read-only sandbox from an empty folder, so the yap tools are all it can use; Claude Code gets only the `mcp__yap__*` tools. The script records each answer, every tool call and whether it was an error, and passes an answer that has every expected fact (in either language) and nothing a closed switch should have hidden; an answer that used another tool doesn't count. A CLI that's missing, not signed in or over its limit is skipped with the reason.

  On 2026-09-30 with codex-cli 0.158.0 (model gpt-6-astra, reasoning effort medium), each question asked twice, before and after this iteration's changes; Claude Code 2.1.284 was skipped (over its weekly limit until 2026-10-03):

  | # | Question | Switches | Tools called (now, run 1) | Calls before | Calls now | Right |
  |---|---|---|---|---|---|---|
  | 1 | 上周四那场会议的待办分别是谁的？ | both on | list_meetings → get_meeting | 2, 2 | 2, 2 | 4/4 |
  | 2 | 最近三场会议里关于 rollout 做了哪些决定？ | both on | list_meetings → search_history → get_meeting ×4 | 4, 4 | 6, 4 | 4/4 |
  | 3 | 我在 Slack 里说过 Kubernetes 升级什么时候做？ | both on | search_history → get_dictation | 2, 2 | 2, 2 | 4/4 |
  | 4 | 我的 Yap 词典里 Postgres 是怎么写的？ | both on | get_dictionary | 1, 1 | 1, 1 | 4/4 |
  | 5 | 上周四的会上 Reed 负责什么？ | off | list_meetings (error) | 1, 1 | 1, 1 | 4/4 |
  | 6 | 我在微信上跟我妈说周六几点到？ | main only | search_history (error) | 1, 1 | 1, 1 | 4/4 |
  | 7 | 我有没有在哪次会议上讨论过 Terraform？ | both on | search_history | 1, 1 | 1, 1 | 4/4 |
  | 8 | In the onboarding design review, what did Shelley want to do with the setup tour, and which release is it for? | both on | search_history ×2 → list_meetings → get_meeting | 4, 2 | 4, 4 | 4/4 |
  | 9 | 上周我用 Mail 给 Jenny 发的发票邮件里，发票号和金额是多少？ | both on | search_history → get_dictation | 2, 2 | 2, 2 | 4/4 |
  | 10 | 我在 Cursor 里口述的 rate limiter 注释里，限流阈值是多少？ | both on | search_history | 1, 1 | 1, 1 | 4/4 |

  Every answer was right, checked by the script and read by hand. With a switch off, the agent made one call, got the tool error and told the user which switch to turn on in Yap › 设置 › Agent 访问（MCP）, by its Chinese name, without guessing an answer. It worked out "上周四" from today's date and passed it as `since`/`until`. Call counts vary between runs of the same question (question 2 took 4 to 6: sometimes the notes first, then the transcripts). The question it searched around on most was 8 (4 calls in three of four runs): the design review's notes are in Chinese, so the English words "onboarding" and "setup" found the wrong meeting or only the transcript, and `title` (a date) didn't say which meeting was which. `list_meetings` now returns each meeting's `summary`; the agent then read the list before opening the meeting, but made as many calls as before. A sentence in `search_history`'s description saying that matching is literal and per language made no difference in a run of its own and was taken out again. Finding a meeting by topic across languages (an English question about Chinese notes) is the one thing substring search can't do; that is the case for the vector search listed under Known limits, not something a tool description fixes.
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

## Speed

`make mcp-perf` (`scripts/mcp-perf.sh`, driver `scripts/mcp-perf.py`) has a copy of the Debug app (`me.sma1lboy.yap.perf`) write two years of heavy use with `--mcp-fixture-large` (`MCPEvalFixture.swift`): 20,000 dictations, 70% of them cleaned up and keeping the prompt Yap sent, as Yap stores them, and 200 hour-long meetings (420–580 transcript lines each, notes, the notes request kept). That is a 39 MB `default.store` plus a 3.5 MB `-wal`. The copy's helper is swapped for a Release build of `yap-mcp` (optimized, as shipped) and started with `--log-timing`, which logs each call's time and its copy / open / read split to stderr. Each case runs in 10 new helper processes (cold: the first call of a session) and 20 times in one process (warm). Times are from writing the request to reading the answer, in ms, on an M4 Pro Mac on 2026-09-30.

| Tool | Case | Cold p50 / p95, before | Cold p50 / p95, now | Warm p50 / p95, before | Warm p50 / p95, now |
|---|---|---|---|---|---|
| `list_meetings` | 20 newest | 237 / 248 | 140 / 142 | 232 / 239 | 39 / 140 |
| `list_meetings` | 100 since a date | 591 / 598 | 240 / 248 | 587 / 595 | 131 / 240 |
| `get_meeting` | with an hour's transcript | 107 / 110 | 99 / 105 | 100 / 106 | 22 / 99 |
| `get_meeting` | notes only | 93 / 96 | 85 / 86 | 86 / 95 | 7 / 87 |
| `search_history` | a word in 1,165 entries | 240 / 251 | 241 / 245 | 234 / 263 | 118 / 238 |
| `search_history` | 50 dictations | 252 / 257 | 250 / 256 | 246 / 254 | 129 / 249 |
| `search_history` | meetings only | 249 / 260 | 247 / 249 | 267 / 358 | 129 / 242 |
| `search_history` | no match (every row read) | 254 / 263 | 250 / 253 | 247 / 257 | 128 / 252 |
| `get_dictation` | | 24 / 26 | 11 / 17 | 20 / 24 | 1 / 12 |
| `get_dictionary` | | 13 / 15 | 8 / 9 | 6 / 13 | 2 / 8 |

"Before" is the helper as of M2.2 (`HELPER=<its Release build> make mcp-perf`). What the split showed and what changed:

- **Copying is not the cost.** The APFS clone of the 39 MB store and its WAL takes about 1 ms and opening the container 4–7 ms, so cloning with `clonefile` directly would gain nothing.
- **Opening a copy rebuilds the WAL index.** The first read of a fresh copy waits about 90 ms while SQLite rebuilds the `-shm` from the 3.5 MB WAL (the same query on the same copy takes 8 ms once the index exists). The helper now keeps its copy open between calls until Yap writes (above), so a session pays this once per change instead of per call: the warm p95 equals the cold time because the first of the 20 calls is a fresh copy.
- **Speaker names were parsed with a regular expression per transcript line.** `list_meetings` reads every listed meeting's transcript to name its speakers; for 100 hour-long meetings that took about 350 ms. `MeetingNotes.speakers(inTranscript:)` now scans the UTF-8 bytes: 66 ms for the same 3.5 MB of transcripts.
- **Search scans every row.** `search_history`'s 110–130 ms warm is SQLite running Core Data's case- and accent-insensitive `CONTAINS` over the text of all 20,200 entries, about 6 ms per 1,000 entries. A plain `LIKE` on the same columns takes 20 ms but ignores case only for ASCII and doesn't ignore accents, so it would find less than History's search; History's own predicate stays.

All common calls stay under the 1 s target even cold. `make mcp-perf` also checks that the data folder's SHA-256 is unchanged and that no copy is left in `$TMPDIR`.

## Known limits

- **Read-only, tools only.** Nothing writes. No MCP resources or prompts, no vector search.
- **Handshake-based clients only.** A client that speaks only the 2026-07-28 revision (no `initialize`) can't connect. Dual-era clients fall back to `initialize`; Claude Code 2.1.284 and the clients above use it.
- **The switches are the only gate.** With the main switch on, any process running as the user can start the helper and read meetings and the dictionary, just as it could read the store files itself. The switches stop agents the user connected from reading what they shouldn't; they're not a sandbox.
- **Busy is untested by real contention.** In `make mcp-check` the writer forces redone copies but has never exhausted the 20 tries, so the "busy" answer has been seen only in code, not in a run.
- **Search time grows with the history.** `search_history` reads every entry's text for each query (no full-text index): about 250 ms cold and 120 ms warm at 20,000 dictations, so roughly 1 s cold at 80,000.
- **Untested paths.** A `dictionary.store` written by a Release build with iCloud on (with CloudKit's tables) hasn't been read: the fixture's store is a Debug one without CloudKit, and this Mac's real dictionary is empty and has no CloudKit tables. `get_meeting` on a real meeting hasn't been run here (the Mac's History has no meetings); the fixture's meetings go through the app's own save and rename code.
- **Version bumps touch six lines.** The helper has its own `MARKETING_VERSION` (Debug and Release) next to the app's and the XPC service's; a release bump must change all six, and `make mcp-check` fails when the helper's and the app's differ. Tag builds in CI pass `MARKETING_VERSION` on the command line, which sets every target.
- **Entitlements.** Local and CI builds sign every target with the app's entitlements file (the Makefile passes `CODE_SIGN_ENTITLEMENTS` on the command line), so the helper carries the app's entitlements too. Outside the App Sandbox they don't change what it can do; it opens no socket.
- **Debug builds.** A Debug build's helper reads the real data folder (`me.sma1lboy.yap`, shared with the dev app) unless `--data-dir` says otherwise, and the dev app's switches (`me.sma1lboy.yap.dev`).

import Foundation

// yap-mcp: Yap's local, read-only MCP server (docs/mcp.md). An agent (Claude Code, Cursor, Codex…) starts it and
// talks newline-delimited JSON-RPC over stdin/stdout; it reads Yap's history from a private copy of the store and
// never opens a network socket.

// Only MCP messages may reach stdout. Keep the real stdout for them and point file descriptor 1 at stderr, so
// whatever a framework prints ends up in the log instead of corrupting the protocol.
let protocolOutput = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
dup2(STDERR_FILENO, STDOUT_FILENO)
// A client that goes away closes the pipe: writing fails and the server exits instead of dying of SIGPIPE.
signal(SIGPIPE, SIG_IGN)

func log(_ message: String) {
    FileHandle.standardError.write(Data("yap-mcp: \(message)\n".utf8))
}

let usage = """
    usage: yap-mcp [--data-dir <path>] [--log-timing]

    Yap's read-only MCP server over stdio. Agents start it themselves; see docs/mcp.md.
    --data-dir    Yap's data folder (default: ~/Library/Application Support/\(AppIdentity.supportDirectoryName))
    --log-timing  log how long each tool call and each store read take, to stderr
    --version     print the version and exit
    """

var dataDirectory = EnclosingApp.defaultDataDirectory
var logsTiming = false
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--data-dir":
        guard let path = arguments.popFirst() else {
            log("--data-dir needs a path")
            exit(2)
        }
        dataDirectory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    case "--log-timing":
        logsTiming = true
    case "--version":
        try? protocolOutput.write(contentsOf: Data("yap-mcp \(EnclosingApp.version)\n".utf8))
        exit(0)
    case "-h", "--help":
        try? protocolOutput.write(contentsOf: Data((usage + "\n").utf8))
        exit(0)
    default:
        log("unknown argument \(argument)\n\(usage)")
        exit(2)
    }
}

EnclosingApp.adoptLanguage()
let language = EnclosingApp.strings.preferredLocalizations.first ?? "?"
log("\(EnclosingApp.version), data in \(dataDirectory.path), \(language) strings from \(EnclosingApp.strings.bundlePath)")
let library = YapLibrary(dataDirectory: dataDirectory, logsTiming: logsTiming)
// A client that stops the server with a signal instead of closing stdin still gets the copies deleted (MCP's stdio
// shutdown is close stdin, then SIGTERM, then SIGKILL; only SIGKILL leaves one behind).
let signalSources = [SIGTERM, SIGINT, SIGHUP].map { number in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
    source.setEventHandler {
        library.removeCopies()
        exit(0)
    }
    source.resume()
    return source
}
MCPServer(library: library, output: protocolOutput, access: EnclosingApp.agentAccess).run()
library.removeCopies()

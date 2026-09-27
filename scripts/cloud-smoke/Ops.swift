// Shared by make cloud-smoke and make cloud-latency: paygate's operator scripts (issue-token.ts, adjust.ts), which
// don't exist over HTTP on purpose. With PAYGATE=local (the Makefile default) they run with `bun run` in the local
// paygate copy (scripts/paygate-local.sh); with PAYGATE=prod, over `railway ssh` from a Railway-linked checkout.
import Foundation

struct Failed: Error, CustomStringConvertible { let description: String }

/// `bun run scripts/<script> <arguments…>` in `directory`, or the same over `railway ssh` when PAYGATE=prod.
func paygateScript(_ script: String, _ arguments: [String], in directory: String) -> Process {
    let command = ["bun", "run", "scripts/\(script)"] + arguments
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ProcessInfo.processInfo.environment["PAYGATE"] == "prod"
        ? ["railway", "ssh", "-s", "paygate", "--"] + command : command
    process.currentDirectoryURL = URL(fileURLWithPath: directory)
    return process
}

/// A one-time token from paygate's scripts/issue-token.ts. It is signed out when the run ends, so smoke runs don't
/// pile up devices on the account.
func issueToken(email: String, in directory: String, deviceName: String = "cloud-smoke") -> String? {
    let process = paygateScript("issue-token.ts", [email, "--device-name", deviceName], in: directory)
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    process.waitUntilExit()
    let token = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return process.terminationStatus == 0 && token?.isEmpty == false ? token : nil
}

/// Ledger adjustment with paygate's scripts/adjust.ts.
func adjust(email: String, micros: Int64, note: String, in directory: String) throws {
    let sign = micros < 0 ? "-" : ""
    let amount = sign + String(micros.magnitude / 1_000_000) + "." + String(String(micros.magnitude % 1_000_000 + 1_000_000).dropFirst())
    let process = paygateScript("adjust.ts", [email, amount, note], in: directory)
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    print("     adjust \(amount) USD: \(text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last ?? "")")
    if process.terminationStatus != 0 { throw Failed(description: "adjust.ts failed: \(text)") }
}

/// Brings the balance back to exactly 0 with one adjustment of the opposite sign.
func zeroBalance(email: String, in directory: String) throws {
    let semaphore = DispatchSemaphore(value: 0)
    var balance: Int64?
    Task.detached {
        balance = try? await YapCloud.shared.fetchMe().balanceMicros
        semaphore.signal()
    }
    semaphore.wait()
    guard let balance else { throw Failed(description: "couldn't read the balance to zero it") }
    if balance != 0 { try adjust(email: email, micros: -balance, note: "client id-capture check: back to 0", in: directory) }
}

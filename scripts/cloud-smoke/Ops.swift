// Shared by make cloud-smoke and make cloud-latency: live-deployment operations that need Railway access
// (a paygate checkout linked with `railway link`). None of this exists over HTTP on purpose.
import Foundation

struct Failed: Error, CustomStringConvertible { let description: String }

/// A one-time token from paygate's scripts/issue-token.ts (over railway ssh, from a linked checkout). It is signed
/// out when the run ends, so smoke runs don't pile up devices on the account.
func issueToken(email: String, in directory: String, deviceName: String = "cloud-smoke") -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["railway", "ssh", "-s", "paygate", "--", "bun", "run", "scripts/issue-token.ts", email,
                         "--device-name", deviceName]
    process.currentDirectoryURL = URL(fileURLWithPath: directory)
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    process.waitUntilExit()
    let token = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return process.terminationStatus == 0 && token?.isEmpty == false ? token : nil
}

/// Ledger adjustment on the live deployment (paygate's scripts/adjust.ts over `railway ssh`, from a linked checkout).
func adjust(email: String, micros: Int64, note: String, in directory: String) throws {
    let sign = micros < 0 ? "-" : ""
    let amount = sign + String(micros.magnitude / 1_000_000) + "." + String(String(micros.magnitude % 1_000_000 + 1_000_000).dropFirst())
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["railway", "ssh", "-s", "paygate", "--", "bun", "run", "scripts/adjust.ts", email, amount, note]
    process.currentDirectoryURL = URL(fileURLWithPath: directory)
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

import CryptoKit
import Foundation

/// Downloads one model file to its final path, only once it is complete and verified.
///
/// - Expected size and sha256 come from Hugging Face's first response (`x-linked-size`, `x-linked-etag`, sent
///   with the redirect to its CDN), so a truncated file, a captive-portal page or a corrupted transfer never
///   lands as `<name>.bin`.
/// - Disk space is checked against the expected size before anything is transferred.
/// - The finished transfer is moved (not copied) to `<destination>.part`, verified, then renamed; stale `.part`
///   files are removed at launch by `removeStalePartials`.
/// - A dropped connection or a cancel yields URLSession resume data, which the caller keeps (see
///   `resumeDataURL`) and passes back to continue where the transfer stopped.
final class ModelFileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Expected: Equatable {
        var size: Int64?
        var sha256: String?
    }

    struct Progress: Equatable {
        var received: Int64
        var total: Int64
        /// Smoothed transfer rate; nil until there is enough to go on.
        var bytesPerSecond: Double?

        var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }
        var secondsLeft: Double? {
            guard let bytesPerSecond, bytesPerSecond > 0, total > received else { return nil }
            return Double(total - received) / bytesPerSecond
        }
    }

    enum Failure: LocalizedError, Equatable {
        case notEnoughSpace(needed: Int64, available: Int64)
        case damaged
        case badResponse(Int)

        var errorDescription: String? {
            switch self {
            case .notEnoughSpace(let needed, let available):
                return String(
                    format: String(localized: "Not enough disk space: the model needs %@, and %@ is free. Free up some space and try again."),
                    ByteCountFormatter.string(fromByteCount: needed, countStyle: .file),
                    ByteCountFormatter.string(fromByteCount: available, countStyle: .file))
            case .damaged:
                return String(localized: "The downloaded file is damaged (its checksum doesn't match). Try the download again.")
            case .badResponse(let status):
                return String(format: String(localized: "The download server answered with HTTP %lld."), Int64(status))
            }
        }
    }

    /// A transfer that stopped part way; `resumeData` continues it.
    struct Interrupted: LocalizedError {
        let resumeData: Data?
        let underlying: Error
        var errorDescription: String? { underlying.localizedDescription }
    }

    static let diskMargin: Int64 = 50_000_000

    // MARK: - Pure helpers

    /// Size and sha256 from Hugging Face's redirect headers. A 64-hex `x-linked-etag` is the LFS sha256; a git
    /// blob's 40-hex etag isn't a sha256 and is ignored.
    static func expected(fromHeaders headers: [AnyHashable: Any]) -> Expected {
        func header(_ name: String) -> String? {
            headers.first { ($0.key as? String)?.lowercased() == name }?.value as? String
        }
        let tag = header("x-linked-etag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\"W/ "))
        let isSHA256 = tag.map { $0.count == 64 && $0.allSatisfy(\.isHexDigit) } ?? false
        return Expected(size: header("x-linked-size").flatMap { Int64($0) }, sha256: isSHA256 ? tag?.lowercased() : nil)
    }

    /// Nil when `available` covers `needed` plus a margin, else the error to show.
    static func spaceShortfall(needed: Int64?, available: Int64?) -> Failure? {
        guard let needed, let available, available < needed + diskMargin else { return nil }
        return .notEnoughSpace(needed: needed, available: available)
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func partURL(for destination: URL) -> URL { destination.appendingPathExtension("part") }
    static func resumeDataURL(for destination: URL) -> URL { destination.appendingPathExtension("resume") }

    /// `.part` files a quit or crash left mid-verification. Resume data is kept.
    static func removeStalePartials(in directory: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "part" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func availableSpace(at directory: URL) -> Int64? {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: - Expected size and hash

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    /// HEAD without following the redirect; empty when offline or not a Hugging Face URL.
    static func fetchExpected(for url: URL) async -> Expected {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "HEAD"
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        guard let (_, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse
        else { return Expected() }
        return expected(fromHeaders: http.allHeaderFields)
    }

    // MARK: - Transfer

    private let destination: URL
    private let expected: Expected
    private let onProgress: @Sendable (Progress) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDownloadTask?
    private var moveError: Error?
    /// Set when we cancel: the resume data arrives in cancel(byProducingResumeData:)'s callback, which then
    /// finishes the continuation instead of didCompleteWithError.
    private var cancelledByUs = false
    private var status = 0
    private var rate: Double?
    private var lastSample: (time: Date, bytes: Int64)?

    private init(destination: URL, expected: Expected, onProgress: @escaping @Sendable (Progress) -> Void) {
        self.destination = destination
        self.expected = expected
        self.onProgress = onProgress
    }

    /// Transfers `url` to `destination` (replacing it only once verified). Throws `Interrupted` with resume data
    /// on a dropped connection or cancel, `Failure` for space, a bad status or a damaged file.
    static func download(
        _ url: URL, to destination: URL, expected: Expected, resumeData: Data?,
        onProgress: @escaping @Sendable (Progress) -> Void
    ) async throws {
        let directory = destination.deletingLastPathComponent()
        if let shortfall = spaceShortfall(needed: expected.size, available: availableSpace(at: directory)) {
            throw shortfall
        }
        let downloader = ModelFileDownloader(destination: destination, expected: expected, onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: downloader, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let task = resumeData.map(session.downloadTask(withResumeData:)) ?? session.downloadTask(with: url)
                downloader.lock.withLock {
                    downloader.continuation = continuation
                    downloader.task = task
                }
                task.resume()
            }
        } onCancel: {
            downloader.cancel()
        }
        try await Task.detached(priority: .utility) { try downloader.verifyAndInstall() }.value
    }

    private func cancel() {
        let task: URLSessionDownloadTask? = lock.withLock {
            cancelledByUs = true
            return self.task
        }
        guard let task else { return }
        task.cancel(byProducingResumeData: { [self] data in
            let continuation = lock.withLock {
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(throwing: Interrupted(resumeData: data, underlying: CancellationError()))
        })
    }

    private func verifyAndInstall() throws {
        let part = Self.partURL(for: destination)
        do {
            let size = (try FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value
            if let expectedSize = expected.size, size != expectedSize { throw Failure.damaged }
            if let expectedHash = expected.sha256, try Self.sha256(of: part) != expectedHash { throw Failure.damaged }
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: part)
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw error
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        let now = Date()
        let progress: Progress = lock.withLock {
            if let last = lastSample, now.timeIntervalSince(last.time) >= 1 {
                let sample = Double(totalBytesWritten - last.bytes) / now.timeIntervalSince(last.time)
                rate = rate.map { $0 * 0.7 + sample * 0.3 } ?? sample
                lastSample = (now, totalBytesWritten)
            } else if lastSample == nil {
                lastSample = (now, totalBytesWritten)
            }
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (expected.size ?? 0)
            return Progress(received: totalBytesWritten, total: total, bytesPerSecond: rate)
        }
        onProgress(progress)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is gone once this returns; move it next to the destination (same volume, no copy).
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let part = Self.partURL(for: destination)
        lock.withLock { self.status = status }
        guard (200...299).contains(status) else { return }
        do {
            try? FileManager.default.removeItem(at: part)
            try FileManager.default.moveItem(at: location, to: part)
        } catch {
            lock.withLock { moveError = error }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, status, moveError) = lock.withLock {
            if cancelledByUs { return (nil, 0, nil) as (CheckedContinuation<Void, Error>?, Int, Error?) }
            defer { self.continuation = nil }
            return (self.continuation, self.status, self.moveError)
        }
        if let error {
            let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            continuation?.resume(throwing: Interrupted(resumeData: resumeData, underlying: error))
        } else if !(200...299).contains(status) {
            continuation?.resume(throwing: Failure.badResponse(status))
        } else if let moveError {
            continuation?.resume(throwing: moveError)
        } else {
            continuation?.resume()
        }
    }

    #if DEBUG
        static func selfCheck() {
            let hash = String(repeating: "ab", count: 32)
            assert(expected(fromHeaders: ["X-Linked-Size": "574041195", "X-Linked-Etag": "\"\(hash)\""])
                == Expected(size: 574_041_195, sha256: hash))
            assert(expected(fromHeaders: ["x-linked-etag": "\"0123456789abcdef0123456789abcdef01234567\""]).sha256 == nil)
            assert(expected(fromHeaders: [:]) == Expected())

            assert(spaceShortfall(needed: 574_041_195, available: 10_000_000_000) == nil)
            assert(spaceShortfall(needed: 574_041_195, available: 600_000_000)
                == .notEnoughSpace(needed: 574_041_195, available: 600_000_000))
            assert(spaceShortfall(needed: nil, available: 1) == nil)

            let progress = Progress(received: 100, total: 1100, bytesPerSecond: 50)
            assert(progress.secondsLeft == 20 && abs(progress.fraction - 100.0 / 1100) < 1e-9)
            assert(Progress(received: 1, total: 2, bytesPerSecond: nil).secondsLeft == nil)

            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: file) }
            try? Data("abc".utf8).write(to: file)
            assert((try? sha256(of: file)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            for name in ["m.bin", "m.bin.part", "m.bin.resume"] {
                FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: Data())
            }
            removeStalePartials(in: directory)
            let left = (try? FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()) ?? []
            assert(left == ["m.bin", "m.bin.resume"])
        }
    #endif
}

import Darwin
import Foundation

/// Reads a generic password through Apple's `/usr/bin/security`, the tool
/// Claude Code itself reads and writes `Claude Code-credentials` with.
///
/// The item trusts that tool and carries its `apple-tool:` partition, and
/// every token refresh Claude Code writes through it keeps them. An app's
/// own Keychain read is checked against the partition list as well, which a
/// refresh can reset, prompting AgentMeter again after "Always Allow".
///
/// The secret only ever crosses the tool's stdout pipe: fixed absolute path,
/// no shell, nothing on argv or in the environment, stdin and stderr on
/// /dev/null, output capped, and the process ended on a timeout. Callers
/// must never log what it returns.
enum KeychainToolReader {
    enum Result: Equatable {
        case data(Data)
        /// The tool ran and gave no usable answer: no such item, access denied
        /// or cancelled, a timeout, no output, or more than any credential.
        case failed(Failure)
        /// The tool could not be started at all.
        case unavailable
    }

    enum Failure: Equatable {
        case exit(Int32)
        case uncaughtSignal(Int32)
        case timedOut
        case outputTooLarge
        case emptyOutput
    }

    static let securityTool = URL(fileURLWithPath: "/usr/bin/security")
    /// `security`'s exit status for errSecItemNotFound: not signed in.
    static let itemNotFoundStatus: Int32 = 44
    /// A read takes about 20 ms; only a dialog of the tool's own (a locked
    /// keychain) takes longer.
    static let timeout: TimeInterval = 30
    /// A credential is well under 1 KB.
    static let outputLimit = 64 * 1024

    /// Present on every macOS (it is on the sealed system volume).
    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: securityTool.path)
    }

    /// The item Claude Code itself reads: its account and its service.
    static func arguments(service: String, account: String) -> [String] {
        ["find-generic-password", "-a", account, "-s", service, "-w"]
    }

    static func readGenericPassword(service: String, account: String) -> Result {
        run(executable: securityTool, arguments: arguments(service: service, account: account),
            timeout: timeout, outputLimit: outputLimit)
    }

    /// Runs `executable` and returns its stdout with trailing whitespace
    /// removed, when it exits 0 within `timeout` and writes at most
    /// `outputLimit` bytes. Blocks the calling thread; never call it on the
    /// main thread.
    static func run(executable: URL, arguments: [String], timeout: TimeInterval, outputLimit: Int) -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = SubprocessWorkingDirectory.url
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return .unavailable
        }

        // Drained while the tool runs, so a full pipe can never stall it;
        // what arrives is kept as it arrives. The reader owns the read end
        // and closes it at EOF: closing it from here while it may still be
        // reading could hand its descriptor number to another file.
        let output = OutputBuffer(limit: outputLimit)
        let drained = DispatchSemaphore(value: 0)
        let reader = pipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = Darwin.read(reader.fileDescriptor, &buffer, buffer.count)
                if count > 0 {
                    output.append(Data(buffer[0..<count]))
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            try? reader.close()
            drained.signal()
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
        }
        // Something still holding the write end (a child of the tool) must
        // not hold the caller.
        _ = drained.wait(timeout: .now() + 1)

        if timedOut { return .failed(.timedOut) }
        guard !process.isRunning else { return .failed(.timedOut) }
        if process.terminationReason == .uncaughtSignal {
            return .failed(.uncaughtSignal(process.terminationStatus))
        }
        guard process.terminationStatus == 0 else { return .failed(.exit(process.terminationStatus)) }
        guard let data = output.take() else { return .failed(.outputTooLarge) }
        let trimmed = trimmingTrailingWhitespace(data)
        return trimmed.isEmpty ? .failed(.emptyOutput) : .data(trimmed)
    }

    static func trimmingTrailingWhitespace(_ data: Data) -> Data {
        var end = data.endIndex
        while end > data.startIndex, [0x0A, 0x0D, 0x20, 0x09].contains(data[data.index(before: end)]) {
            end = data.index(before: end)
        }
        return Data(data[data.startIndex..<end])
    }

    /// The tool's stdout, or nil once it went past the limit.
    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var data = Data()
        private var overflowed = false

        init(limit: Int) { self.limit = limit }

        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            guard !overflowed else { return }
            if data.count + chunk.count > limit {
                overflowed = true
                data = Data()
            } else {
                data.append(chunk)
            }
        }

        func take() -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return overflowed ? nil : data
        }
    }
}

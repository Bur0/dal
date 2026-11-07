import Foundation

struct GitError: LocalizedError {
    let command: String
    let message: String
    let exitCode: Int32

    var errorDescription: String? {
        message.isEmpty ? "git \(command) failed with exit code \(exitCode)." : message
    }
}

enum Shell {
    /// GUI apps start with a minimal PATH; make sure Homebrew tools (gh, git-lfs, gpg) are reachable.
    static let extraPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    struct Result {
        let stdout: Data
        let stderr: Data
        let status: Int32
    }

    static func environment(_ extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let inherited = (env["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init).filter { $0.hasPrefix("/") }   // no ".", "" or relative entries
        env["PATH"] = ([extraPath] + inherited).joined(separator: ":")
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_EDITOR"] = "true"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GH_PROMPT_DISABLED"] = "1"
        env["NO_COLOR"] = "1"
        // Paths Dal passes are file names, never patterns: `a[1].txt` must not also match `a1.txt`.
        env["GIT_LITERAL_PATHSPECS"] = "1"
        // Abort HTTP transfers that stall instead of hanging the UI forever.
        env["GIT_HTTP_LOW_SPEED_LIMIT"] = "1000"
        env["GIT_HTTP_LOW_SPEED_TIME"] = "60"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        for (k, v) in extra { env[k] = v }
        return env
    }

    static func run(_ tool: String, _ args: [String], cwd: URL?, input: Data? = nil,
                    env: [String: String] = [:]) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [tool] + args
                if let cwd { process.currentDirectoryURL = cwd }
                process.environment = environment(env)

                let out = Pipe()
                let err = Pipe()
                let inPipe = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = input == nil ? FileHandle.nullDevice : inPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let token = ProcessRegistry.shared.add(process, tag: cwd?.path)
                defer { ProcessRegistry.shared.remove(token) }

                if let input {
                    DispatchQueue.global().async {
                        inPipe.fileHandleForWriting.write(input)
                        try? inPipe.fileHandleForWriting.close()
                    }
                }

                let group = DispatchGroup()
                var errData = Data()
                group.enter()
                DispatchQueue.global().async {
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                continuation.resume(returning: Result(stdout: outData, stderr: errData,
                                                      status: process.terminationStatus))
            }
        }
    }
}

/// Running child processes, so a long operation (a stuck push, a hook) can be cancelled.
final class ProcessRegistry: @unchecked Sendable {
    static let shared = ProcessRegistry()
    private let lock = NSLock()
    private var running: [UUID: (Process, String?)] = [:]

    func add(_ process: Process, tag: String?) -> UUID {
        let id = UUID()
        lock.lock(); running[id] = (process, tag); lock.unlock()
        return id
    }

    func remove(_ id: UUID) {
        lock.lock(); running[id] = nil; lock.unlock()
    }

    func terminate(tag: String) {
        lock.lock()
        let targets = running.values.filter { $0.1 == tag }.map(\.0)
        lock.unlock()
        for process in targets where process.isRunning { process.terminate() }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Single-quoted for /bin/sh (used for helper and editor commands git runs through a shell).
    var shellQuoted: String { "'" + replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

extension Data {
    var utf8: String { String(decoding: self, as: UTF8.self) }
}

import Foundation

public struct CodeRunResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool

    public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

/// Runs a small code snippet locally so a learning answer's example can be
/// executed and inspected. Deliberately conservative:
///   • each run works in its own temp directory,
///   • a wall-clock timeout guards against infinite loops,
///   • stdout/stderr are capped so a noisy program can't flood the panel.
///
/// The user chose "run directly on this machine", so snippets run with the
/// user's own toolchain (python3 / clang / bash / swift). C is compiled then
/// executed; interpreted languages run directly.
public enum CodeRunner {
    public static let defaultTimeout: TimeInterval = 8

    public struct Configuration: Sendable {
        public var timeout: TimeInterval
        public var outputLimit: Int
        public init(timeout: TimeInterval = CodeRunner.defaultTimeout, outputLimit: Int = 16_000) {
            self.timeout = timeout
            self.outputLimit = outputLimit
        }
    }

    public enum Language: String, CaseIterable, Sendable {
        case c
        case cpp
        case python = "python3"
        case shell = "sh"
        case swift

        /// Maps a markdown fence language onto a runnable language when we can.
        public static func recognized(_ fence: String?) -> Language? {
            guard let fence else { return nil }
            let lower = fence.lowercased().trimmingCharacters(in: .whitespaces)
            switch lower {
            case "c":
                return .c
            case "cpp", "c++", "cc":
                return .cpp
            case "python", "py":
                return .python
            case "sh", "bash", "zsh", "shell":
                return .shell
            case "swift":
                return .swift
            default:
                return nil
            }
        }

        var executable: String {
            switch self {
            case .c: "/usr/bin/clang"
            case .cpp: "/usr/bin/clang++"
            case .python: "/usr/bin/python3"
            case .shell: "/bin/bash"
            case .swift: "/usr/bin/swift"
            }
        }

        var arguments: [String] {
            switch self {
            case .c, .cpp, .python, .swift: []
            case .shell: ["-c"]
            }
        }
    }

    public static func run(
        code: String,
        language: Language,
        configuration: Configuration = Configuration()
    ) async -> CodeRunResult {
        // Host the snippet in its own directory so any file the code writes
        // stays contained and we can compile C next to it.
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "satori-run-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceURL = dir.appending(path: sourceFileName(language))
        guard (try? code.data(using: .utf8)?.write(to: sourceURL)) != nil else {
            return CodeRunResult(exitCode: 1, stdout: "", stderr: "无法写入临时源码文件。", timedOut: false)
        }

        let executable = language.executable
        switch language {
        case .c, .cpp:
            let binaryURL = dir.appending(path: "runner-bin")
            // No `-l m`: on macOS libm lives inside libSystem, and passing
            // `-l m` can confuse the linker when an unrelated file of that
            // name sits in the temp dir. Use a unique binary name too.
            let compileArgs = [sourceURL.path, "-o", binaryURL.path]
            let compile = await launch(executable, args: compileArgs, in: dir, configuration: configuration)
            guard compile.exitCode == 0 else {
                return CodeRunResult(exitCode: compile.exitCode, stdout: "", stderr: compile.stderr.isEmpty ? "编译失败。" : compile.stderr, timedOut: compile.timedOut)
            }
            // Run the compiled binary directly — NOT `clang <binary>`, which
            // would make the linker consume the executable as an input.
            return await launch(binaryURL.path, args: [], in: dir, configuration: configuration)
        case .python, .shell, .swift:
            return await launch(executable, args: language.arguments + [sourceURL.path], in: dir, configuration: configuration)
        }
    }

    private static func sourceFileName(_ language: Language) -> String {
        switch language {
        case .c: "main.c"
        case .cpp: "main.cpp"
        case .python: "main.py"
        case .shell: "main.sh"
        case .swift: "main.swift"
        }
    }

    private static func launch(
        _ executable: String,
        args: [String],
        in directory: URL,
        configuration: Configuration
    ) async -> CodeRunResult {
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            process.currentDirectoryURL = directory

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            try process.run()

            // Track whether we asked to kill the process, so a SIGTERM we sent
            // reads as "timed out" rather than a mysterious exit.
            let flag = TimeoutFlag()
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(configuration.timeout * 1_000_000_000))
                if process.isRunning {
                    flag.set(true)
                    process.terminate()
                }
            }
            // Drain output as it arrives so a chatty program can't deadlock on
            // a full pipe buffer.
            let stdoutTask = Task { drain(outPipe) }
            let stderrTask = Task { drain(errPipe) }
            process.waitUntilExit()
            timeoutTask.cancel()

            let stdout = await stdoutTask.value
            let stderr = await stderrTask.value

            return CodeRunResult(
                exitCode: process.terminationStatus,
                stdout: trim(stdout, limit: configuration.outputLimit),
                stderr: trim(stderr, limit: configuration.outputLimit),
                timedOut: flag.get()
            )
        } catch {
            return CodeRunResult(exitCode: 1, stdout: "", stderr: "无法运行 \(executable)。请确认本机已安装该工具链。", timedOut: false)
        }
    }

    private static func drain(_ pipe: Pipe) -> String {
        let handle = pipe.fileHandleForReading
        let data = handle.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func trim(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n…（输出过长已截断）"
    }
}

/// A tiny thread-safe boolean, because `Process.terminate()` happens on a
/// detached timer while `waitUntilExit()` runs on the caller's thread.
private final class TimeoutFlag: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()

    func set(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

import Darwin
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

/// Experiments are intentionally narrower than a general-purpose terminal.
/// The reader should be able to manipulate a concept from the book without
/// giving an AI-generated snippet network access or a convenient path to the
/// user's files and shell.
public enum ExperimentSafety: Equatable, Sendable {
    case allowed
    case blocked(String)

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }

    public var message: String? {
        if case let .blocked(message) = self { return message }
        return nil
    }
}

/// Runs a small, pure-computation concept experiment locally so a learning
/// answer's example can be executed and inspected. Deliberately conservative:
///   • each run works in its own temp directory,
///   • a wall-clock timeout guards against infinite loops (SIGTERM, then
///     SIGKILL if the process ignores it),
///   • stdout/stderr are read incrementally and capped, so a noisy program
///     can't flood memory, and
///   • compilation and execution are timed separately (compiles get a more
///     generous budget).
///
/// Allowed snippets use the local Python/Clang toolchain, but the actual
/// experiment is launched with no network and no writes to user directories.
public enum CodeRunner {
    public static let defaultTimeout: TimeInterval = 8
    public static let defaultCompileTimeout: TimeInterval = 30
    private static let restrictedSandboxProfile = """
    (version 1)
    (allow default)
    (deny network*)
    (deny file-write*)
    (deny file-read* (subpath "/Users"))
    (deny file-read* (subpath "/Volumes"))
    """

    /// How long to wait after SIGTERM before escalating to SIGKILL.
    fileprivate static let killEscalationDelay: TimeInterval = 1.5
    /// Safety net: after the process exits, give the pipes this long to hit
    /// EOF before returning with whatever output arrived (a grandchild that
    /// inherits the pipe would otherwise hang the run forever).
    fileprivate static let eofGraceDelay: TimeInterval = 2.0

    public struct Configuration: Sendable {
        public var timeout: TimeInterval
        public var compileTimeout: TimeInterval
        public var outputLimit: Int

        public init(
            timeout: TimeInterval = CodeRunner.defaultTimeout,
            compileTimeout: TimeInterval = CodeRunner.defaultCompileTimeout,
            outputLimit: Int = 16_000
        ) {
            self.timeout = timeout
            self.compileTimeout = compileTimeout
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

    /// Languages useful for small, local concept experiments. Shell and Swift
    /// remain decodable for older callers, but are deliberately not offered as
    /// experiment languages.
    public static let experimentLanguages: [Language] = [.python, .c, .cpp]

    /// Gives the selection-to-experiment route a conservative language hint.
    /// It is intentionally only a hint: `safety(for:language:)` remains the
    /// final gate, and the reader still has to press Run.
    public static func languageHint(for code: String) -> Language? {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        if normalized.contains("std::") || normalized.contains("cout <<") || normalized.contains("cin >>") {
            return .cpp
        }
        if normalized.contains("#include")
            || normalized.contains("int main")
            || normalized.contains("printf(")
            || normalized.contains("scanf(") {
            return .c
        }
        if normalized.contains("def ")
            || normalized.contains("print(")
            || normalized.contains("import math")
            || normalized.contains("input(") {
            return .python
        }
        return nil
    }

    /// Defense-in-depth gate for both the answer-card runner and the secondary
    /// experiment space. A blocked snippet can still be copied out, but Satori
    /// will not execute it locally.
    public static func safety(for code: String, language: Language) -> ExperimentSafety {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .blocked("实验内容不能为空。")
        }
        guard trimmed.count <= 20_000 else {
            return .blocked("实验内容太长；请只保留当前概念需要的几行。")
        }

        switch language {
        case .shell:
            return .blocked("Shell 命令暂不作为 Satori 实验运行；可以复制到你自己的终端中执行。")
        case .swift:
            return .blocked("Swift 代码暂不作为 Satori 实验运行；先用 Python 或 C 做小实验。")
        case .python:
            let blockedPatterns = [
                #"(?m)^\s*(import|from)\s+(os|pathlib|shutil|subprocess|socket|urllib|requests|ctypes|multiprocessing|importlib|pty)\b"#,
                #"\b(__import__|open|eval|exec|compile|system|popen)\s*\("#
            ]
            if blockedPatterns.contains(where: { trimmed.range(of: $0, options: .regularExpression) != nil }) {
                return .blocked("检测到文件、网络或动态执行接口；实验只能做纯计算。")
            }
            if trimmed.range(of: #"\binput\s*\("#, options: .regularExpression) != nil {
                return .blocked("这段代码需要交互输入；Satori 实验只运行纯计算代码。请先把输入改成固定值，或复制到终端运行。")
            }
        case .c, .cpp:
            let blockedPatterns = [
                #"\b(fopen|freopen|remove|unlink|rename|system|popen|fork|exec\w*|socket|connect|getaddrinfo|open|creat|mkdir|rmdir|chdir|getenv)\s*\("#,
                #"https?://"#,
                #"\bcurl\b"#,
                #"\b(ifstream|ofstream|fstream)\b"#,
                #"\b(std::filesystem|filesystem)\b"#
            ]
            if blockedPatterns.contains(where: { trimmed.range(of: $0, options: .regularExpression) != nil }) {
                return .blocked("检测到文件、网络或进程接口；实验只能做纯计算。")
            }
            let interactiveInputPatterns = [
                #"\b(scanf|fscanf|getchar|fgetc|fgets|gets)\s*\("#,
                #"\b(std::)?cin\s*>>"#,
                #"\b(std::)?getline\s*\("#
            ]
            if interactiveInputPatterns.contains(where: { trimmed.range(of: $0, options: .regularExpression) != nil }) {
                return .blocked("这段代码需要交互输入；Satori 实验只运行纯计算代码。请先把输入改成固定值，或复制到终端运行。")
            }
        }

        return .allowed
    }

    public static func run(
        code: String,
        language: Language,
        configuration: Configuration = Configuration()
    ) async -> CodeRunResult {
        if case let .blocked(message) = safety(for: code, language: language) {
            return CodeRunResult(exitCode: 1, stdout: "", stderr: "实验未运行：\(message)", timedOut: false)
        }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
            return CodeRunResult(exitCode: 1, stdout: "", stderr: "实验未运行：本机没有可用的实验沙箱。", timedOut: false)
        }

        // Host source and compiler artifacts in their own temporary directory;
        // the restricted execution phase cannot write there or elsewhere.
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
            // Compilation gets a more generous budget than the run itself.
            let compile = await launch(
                executable,
                args: compileArgs,
                in: dir,
                configuration: configuration,
                timeout: configuration.compileTimeout,
                sandbox: .noNetwork
            )
            guard compile.exitCode == 0 else {
                return CodeRunResult(exitCode: compile.exitCode, stdout: "", stderr: compile.stderr.isEmpty ? "编译失败。" : compile.stderr, timedOut: compile.timedOut)
            }
            // Run the compiled binary directly — NOT `clang <binary>`, which
            // would make the linker consume the executable as an input.
            return await launch(
                binaryURL.path,
                args: [],
                in: dir,
                configuration: configuration,
                timeout: configuration.timeout,
                sandbox: .restricted
            )
        case .python, .shell, .swift:
            return await launch(
                executable,
                args: language.arguments + [sourceURL.path],
                in: dir,
                configuration: configuration,
                timeout: configuration.timeout,
                sandbox: .restricted
            )
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

    private enum SandboxMode {
        case noNetwork
        case restricted
    }

    private static func launch(
        _ executable: String,
        args: [String],
        in directory: URL,
        configuration: Configuration,
        timeout: TimeInterval,
        sandbox: SandboxMode
    ) async -> CodeRunResult {
        let process = Process()
        // Compilation needs to write the temporary binary, so it uses the
        // built-in no-network profile. The actual experiment additionally
        // denies writes and access to the user's home/volumes.
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            switch sandbox {
            case .noNetwork:
                process.arguments = ["-n", "no-network", executable] + args
            case .restricted:
                process.arguments = ["-p", restrictedSandboxProfile, executable] + args
            }
        } else {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
        }
        process.currentDirectoryURL = directory

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let monitor = RunMonitor(
            process: process,
            stdoutHandle: outPipe.fileHandleForReading,
            stderrHandle: errPipe.fileHandleForReading,
            outputLimit: configuration.outputLimit
        )
        process.terminationHandler = { _ in monitor.processDidTerminate() }
        outPipe.fileHandleForReading.readabilityHandler = { handle in monitor.readAvailableData(handle, isStdout: true) }
        errPipe.fileHandleForReading.readabilityHandler = { handle in monitor.readAvailableData(handle, isStdout: false) }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            return CodeRunResult(exitCode: 1, stdout: "", stderr: "无法运行 \(executable)。请确认本机已安装该工具链。", timedOut: false)
        }

        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                monitor.attach(continuation: continuation, timeout: timeout)
            }
        }, onCancel: {
            monitor.requestKill(reason: .cancelled)
        })
    }
}

/// Coordinates one process run: reads both pipes incrementally (capping the
/// amount of output retained), enforces the wall-clock timeout with a
/// SIGTERM → SIGKILL escalation, and resumes the run's continuation exactly
/// once — after the process has exited AND both pipes hit EOF, or once a
/// short grace period has passed so nothing can hang the run forever.
private final class RunMonitor: @unchecked Sendable {
    enum KillReason {
        case timeout
        case outputLimit
        case cancelled
    }

    private let process: Process
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private let outputLimit: Int

    private let lock = NSLock()
    private var continuation: CheckedContinuation<CodeRunResult, Never>?
    private var stdoutData = Data()
    private var stderrData = Data()
    private var stdoutOverLimit = false
    private var stderrOverLimit = false
    private var stdoutEOF = false
    private var stderrEOF = false
    private var processFinished = false
    private var terminationRequested = false
    private var timedOut = false
    private var resumed = false
    private var timeoutTask: Task<Void, Never>?
    private var escalationTask: Task<Void, Never>?
    private var graceTask: Task<Void, Never>?

    init(process: Process, stdoutHandle: FileHandle, stderrHandle: FileHandle, outputLimit: Int) {
        self.process = process
        self.stdoutHandle = stdoutHandle
        self.stderrHandle = stderrHandle
        self.outputLimit = outputLimit
    }

    /// Called once, after `process.run()` succeeded, with the continuation
    /// that completes the run.
    func attach(continuation: CheckedContinuation<CodeRunResult, Never>, timeout: TimeInterval) {
        lock.lock()
        self.continuation = continuation
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.requestKill(reason: .timeout)
        }
        self.timeoutTask = timeoutTask
        lock.unlock()
        checkFinish()
    }

    func processDidTerminate() {
        lock.lock()
        processFinished = true
        lock.unlock()
        startEOFGraceTimer()
        checkFinish()
    }

    func readAvailableData(_ handle: FileHandle, isStdout: Bool) {
        let data = handle.availableData
        if data.isEmpty {
            // EOF: stop monitoring this handle and record the flag.
            handle.readabilityHandler = nil
            lock.lock()
            if isStdout { stdoutEOF = true } else { stderrEOF = true }
            lock.unlock()
            checkFinish()
        } else {
            append(data, isStdout: isStdout)
        }
    }

    /// Requests termination (SIGTERM via `Process.terminate()`) and arms the
    /// SIGKILL escalation, unless termination was already requested.
    func requestKill(reason: KillReason) {
        lock.lock()
        if !process.isRunning {
            lock.unlock()
            checkFinish()
            return
        }
        if reason == .timeout { timedOut = true }
        if !terminationRequested {
            terminationRequested = true
            process.terminate()
            let escalationTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(CodeRunner.killEscalationDelay))
                guard !Task.isCancelled else { return }
                guard let self, self.process.isRunning else { return }
                Darwin.kill(self.process.processIdentifier, SIGKILL)
            }
            self.escalationTask = escalationTask
        }
        lock.unlock()
    }

    private func startEOFGraceTimer() {
        lock.lock()
        guard graceTask == nil else {
            lock.unlock()
            return
        }
        let graceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(CodeRunner.eofGraceDelay))
            guard !Task.isCancelled else { return }
            self?.forceFinish()
        }
        self.graceTask = graceTask
        lock.unlock()
    }

    private func append(_ data: Data, isStdout: Bool) {
        lock.lock()
        if isStdout {
            accumulate(data, into: &stdoutData, overLimit: &stdoutOverLimit)
        } else {
            accumulate(data, into: &stderrData, overLimit: &stderrOverLimit)
        }
        let hitLimit = stdoutOverLimit || stderrOverLimit
        lock.unlock()
        if hitLimit { requestKill(reason: .outputLimit) }
    }

    private func accumulate(_ data: Data, into buffer: inout Data, overLimit: inout Bool) {
        guard !overLimit else { return }
        let room = outputLimit - buffer.count
        if room <= 0 {
            overLimit = true
        } else if data.count <= room {
            buffer.append(contentsOf: data)
        } else {
            buffer.append(contentsOf: data.prefix(room))
            overLimit = true
        }
    }

    private func checkFinish() {
        lock.lock()
        guard !resumed, processFinished, stdoutEOF, stderrEOF else {
            lock.unlock()
            return
        }
        finishLocked()
    }

    private func forceFinish() {
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return
        }
        finishLocked()
    }

    private func finishLocked() {
        resumed = true
        let result = CodeRunResult(
            exitCode: process.terminationStatus,
            stdout: decode(stdoutData, overLimit: stdoutOverLimit),
            stderr: decode(stderrData, overLimit: stderrOverLimit),
            timedOut: timedOut
        )
        let continuation = self.continuation
        let timeoutTask = self.timeoutTask
        let escalationTask = self.escalationTask
        let graceTask = self.graceTask
        lock.unlock()

        // Reset state so nothing keeps observing this finished run.
        process.terminationHandler = nil
        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        timeoutTask?.cancel()
        escalationTask?.cancel()
        graceTask?.cancel()

        continuation?.resume(returning: result)
    }

    private func decode(_ data: Data, overLimit: Bool) -> String {
        var text = String(data: data, encoding: .utf8) ?? ""
        if overLimit {
            text += "\n…（输出过长已截断）"
        }
        return text
    }
}

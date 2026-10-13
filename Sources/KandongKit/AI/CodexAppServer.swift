import Foundation

/// A model offered by Codex (`model/list`).
public struct CodexModel: Hashable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let canReadImages: Bool
    public let isDefault: Bool
    public let reasoningEfforts: [String]
}

/// A long-lived `codex app-server` child process spoken to over JSON-RPC on stdio
/// (see docs/adr/0001-codex-via-app-server-subprocess.md).
///
/// Every Lookup runs in its own ephemeral thread with Codex's agent tools switched off, so a
/// turn is a plain completion billed to the user's ChatGPT subscription.
public actor CodexAppServer {
    public static let shared = CodexAppServer()

    /// Features that would let a turn act on the machine or wander off; a Lookup needs none.
    static let disabledFeatures = [
        "shell_tool", "unified_exec", "apps", "plugins", "browser_use", "computer_use", "image_generation",
        "multi_agent", "hooks", "goals", "skill_search", "tool_suggest", "in_app_browser",
    ]

    static func launchArguments() -> [String] {
        disabledFeatures.flatMap { ["--disable", $0] }
            + ["-c", "mcp_servers={}", "-c", "web_search=\"disabled\"", "-c", "memories.use_memories=false"]
            + ["app-server"]
    }

    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var turnHandlers: [String: (JSONValue) -> Void] = [:]
    private var ready = false
    private var executablePath = ""
    private var stderrTail = ""
    private var cachedModels: [CodexModel]?
    private var starting: Task<Void, Error>?
    private var reader: Task<Void, Never>?

    public init() {}

    // MARK: Lifecycle

    /// Starts the server if needed and checks the user is signed in.
    public func ensureStarted(executablePath configuredPath: String) async throws {
        if ready, process?.isRunning == true, configuredPath == executablePath { return }
        // Concurrent Lookups share one start-up instead of racing to launch two servers.
        if let starting, configuredPath == executablePath { return try await starting.value }
        let task = Task { try await start(executablePath: configuredPath) }
        starting = task
        defer { starting = nil }
        try await task.value
    }

    private func start(executablePath configuredPath: String) async throws {
        stop()
        guard let executable = Self.locateCodex(configuredPath) else { throw BackendError.codexNotInstalled }
        executablePath = configuredPath
        try launch(executable: executable, arguments: Self.launchArguments())
        _ = try await request("initialize", [
            "clientInfo": ["name": "kandong", "title": "Kandong", "version": "1.0"],
            "capabilities": nil,
        ])
        try send(["method": "initialized"])
        let account = try await request("account/read", [:])
        if account["account"]?.isNull ?? true, account["requiresOpenaiAuth"]?.bool == true {
            stop()
            throw BackendError.codexNotSignedIn
        }
        ready = true
    }

    /// For tests: run any executable that speaks the protocol.
    func launchForTesting(executable: URL, arguments: [String]) async throws {
        stop()
        try launch(executable: executable, arguments: arguments)
        _ = try await request("initialize", ["clientInfo": ["name": "test", "title": nil, "version": "0"], "capabilities": nil])
        ready = true
    }

    public func stop() {
        ready = false
        if let process, process.isRunning { process.terminate() }
        process = nil
        stdin = nil
        reader?.cancel()
        reader = nil
        buffer = Data()
        failAll(BackendError.failed("Codex app-server stopped."))
    }

    private func launch(executable: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Self.searchPath
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.temporaryDirectory

        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // One consumer reads stdout in order; a Task per chunk could reach the actor out of order and
        // scramble streamed replies. The exit is handled after stdout is drained, so a reply written
        // just before exiting still arrives.
        let (chunks, sink) = AsyncStream.makeStream(of: Data.self)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                sink.finish()
            } else {
                sink.yield(data)
            }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return handle.readabilityHandler = nil }
            guard let self else { return }
            Task { await self.receiveStderr(data) }
        }
        process.terminationHandler = { [weak self] finished in
            // Normally stdout reaches end-of-file and the reader reports the exit; this covers a
            // child process that keeps the pipe open.
            Task {
                try? await Task.sleep(for: .seconds(2))
                await self?.processExited(finished)
            }
        }
        try process.run()
        self.process = process
        self.stdin = input.fileHandleForWriting
        reader = Task { [weak self] in
            for await data in chunks {
                await self?.receive(data, from: process)
            }
            await self?.processExited(process)
        }
    }

    private func processExited(_ finished: Process) {
        guard finished === process else { return }
        reader?.cancel()
        reader = nil
        ready = false
        process = nil
        stdin = nil
        let detail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
        failAll(BackendError.failed("Codex app-server exited." + (detail.isEmpty ? "" : " \(detail.suffix(300))")))
    }

    private func failAll(_ error: Error) {
        let continuations = pending
        pending = [:]
        for continuation in continuations.values { continuation.resume(throwing: error) }
        let handlers = turnHandlers
        turnHandlers = [:]
        for handler in handlers.values { handler(["method": "error", "params": ["error": ["message": .string(error.localizedDescription)], "willRetry": false]]) }
    }

    // MARK: JSON-RPC

    private func send(_ message: JSONValue) throws {
        guard let stdin else { throw BackendError.failed("Codex app-server is not running.") }
        var data = try message.encoded()
        data.append(0x0A)
        try stdin.write(contentsOf: data)
    }

    func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try send(["id": .number(Double(id)), "method": .string(method), "params": params])
            } catch {
                pending[id] = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private func receive(_ data: Data, from source: Process) {
        guard source === process else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            guard !line.isEmpty, let message = try? JSONValue.decode(Data(line)) else { continue }
            handle(message)
        }
    }

    private func receiveStderr(_ data: Data) {
        stderrTail = String((stderrTail + (String(data: data, encoding: .utf8) ?? "")).suffix(2000))
    }

    private func handle(_ message: JSONValue) {
        let method = message["method"]?.string
        if let id = message["id"]?.number.map(Int.init) {
            if method != nil {
                // A request from the server (approvals etc.). Lookups never need one; decline it.
                try? send(["id": .number(Double(id)), "error": ["code": -32601, "message": "Not supported by Kandong"]])
                return
            }
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let error = message["error"] {
                continuation.resume(throwing: BackendError.protocolError(error["message"]?.string ?? "\(error)"))
            } else {
                continuation.resume(returning: message["result"] ?? .null)
            }
            return
        }
        if let threadID = message["params"]?["threadId"]?.string, let handler = turnHandlers[threadID] {
            handler(message)
        }
    }

    // MARK: Models

    public func models(executablePath: String) async throws -> [CodexModel] {
        if let cachedModels { return cachedModels }
        try await ensureStarted(executablePath: executablePath)
        let result = try await request("model/list", [:])
        let models = (result["data"]?.array ?? []).compactMap { item -> CodexModel? in
            guard let id = item["id"]?.string, item["hidden"]?.bool != true else { return nil }
            return CodexModel(
                id: id,
                displayName: item["displayName"]?.string ?? id,
                canReadImages: item["inputModalities"]?.array?.contains("image") ?? false,
                isDefault: item["isDefault"]?.bool ?? false,
                reasoningEfforts: item["supportedReasoningEfforts"]?.array?.compactMap { $0["reasoningEffort"]?.string } ?? []
            )
        }
        cachedModels = models
        return models
    }

    // MARK: Turns

    /// Runs one ephemeral thread + turn and streams the agent's reply text.
    public func run(
        _ request: AIRequest, model: String, effort: String, executablePath: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async {
        var imageURL: URL?
        defer { if let imageURL { try? FileManager.default.removeItem(at: imageURL) } }
        do {
            try await ensureStarted(executablePath: executablePath)
            var threadParams: [String: JSONValue] = [
                "ephemeral": true,
                "baseInstructions": .string(request.system),
                "sandbox": "read-only",
                "approvalPolicy": "never",
                "cwd": .string(FileManager.default.temporaryDirectory.path),
            ]
            if !model.isEmpty { threadParams["model"] = .string(model) }
            let thread = try await self.request("thread/start", .object(threadParams))
            guard let threadID = thread["thread"]?["id"]?.string else {
                throw BackendError.protocolError("thread/start returned no thread id")
            }

            var input: [JSONValue] = [["type": "text", "text": .string(request.user), "text_elements": []]]
            if let image = request.image {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("kandong-\(UUID().uuidString).png")
                try image.write(to: url)
                imageURL = url
                input.append(["type": "localImage", "path": .string(url.path)])
            }
            var turnParams: [String: JSONValue] = ["threadId": .string(threadID), "input": .array(input)]
            if !effort.isEmpty { turnParams["effort"] = .string(effort) }
            if let schema = request.schema { turnParams["outputSchema"] = schema }

            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                var streamed = false
                var finished = false
                turnHandlers[threadID] = { [weak self] message in
                    guard !finished else { return }
                    let params = message["params"] ?? .null
                    switch message["method"]?.string {
                    case "item/agentMessage/delta":
                        if let delta = params["delta"]?.string { streamed = true; continuation.yield(delta) }
                    case "item/completed":
                        if !streamed, params["item"]?["type"]?.string == "agentMessage", let text = params["item"]?["text"]?.string {
                            continuation.yield(text)
                        }
                    case "error":
                        guard params["willRetry"]?.bool != true else { return }
                        finished = true
                        done.resume(throwing: BackendError.failed(params["error"]?["message"]?.string ?? "Codex turn failed."))
                    case "turn/completed":
                        finished = true
                        let turn = params["turn"] ?? .null
                        if turn["status"]?.string == "failed" {
                            done.resume(throwing: BackendError.failed(turn["error"]?["message"]?.string ?? "Codex turn failed."))
                        } else {
                            done.resume()
                        }
                    default:
                        return
                    }
                    if finished { Task { await self?.removeHandler(threadID) } }
                }
                Task {
                    do {
                        _ = try await self.request("turn/start", .object(turnParams))
                    } catch {
                        if !finished {
                            finished = true
                            self.removeHandler(threadID)
                            done.resume(throwing: error)
                        }
                    }
                }
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private func removeHandler(_ threadID: String) {
        turnHandlers[threadID] = nil
    }

    // MARK: Locating codex

    /// GUI apps start with a minimal PATH; `codex` (and the `node` it may need) usually live elsewhere.
    static let searchPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin",
                    "\(home)/.volta/bin", "\(home)/.bun/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        if let loginPath = loginShellPath() { dirs = loginPath.split(separator: ":").map(String.init) + dirs }
        var seen = Set<String>()
        return dirs.filter { seen.insert($0).inserted }.joined(separator: ":")
    }()

    private static func loginShellPath() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "printf %s \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        return path?.isEmpty == false ? path : nil
    }

    public static func locateCodex(_ configuredPath: String = "") -> URL? {
        let fm = FileManager.default
        if !configuredPath.isEmpty {
            let path = (configuredPath as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        for dir in searchPath.split(separator: ":") {
            let path = "\(dir)/codex"
            if fm.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }
}

/// Codex as a Backend: the shared app-server plus this Lookup's model settings.
public struct CodexBackend: AIBackend {
    public let settings: CodexSettings
    public let server: CodexAppServer
    public let readingMode: ReadingMode

    public init(settings: CodexSettings, server: CodexAppServer = .shared, readingMode: ReadingMode = BackendConfig.codex.readingMode) {
        self.settings = settings
        self.server = server
        self.readingMode = readingMode
    }


    public var label: String {
        settings.model.isEmpty ? "Codex" : "Codex · \(settings.model)"
    }

    public func status() async -> BackendStatus {
        guard CodexAppServer.locateCodex(settings.executablePath) != nil else {
            return .needsSetup("The Codex CLI isn't installed.", fix: .copyCommand("brew install codex", label: "Copy install command"))
        }
        do {
            try await server.ensureStarted(executablePath: settings.executablePath)
            return .ready("Your ChatGPT subscription")
        } catch BackendError.codexNotSignedIn {
            return .needsSetup("Codex isn't signed in.", fix: .copyCommand("codex login", label: "Copy sign-in command"))
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    public func supportsImages() async -> Bool {
        guard let models = try? await server.models(executablePath: settings.executablePath) else { return true }
        let model = settings.model.isEmpty ? models.first(where: \.isDefault) : models.first { $0.id == settings.model }
        return model?.canReadImages ?? true
    }

    public func respond(to request: AIRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await server.run(
                    request, model: settings.model, effort: request.task == .explain ? settings.explainEffort : settings.effort,
                    executablePath: settings.executablePath, continuation: continuation
                )
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

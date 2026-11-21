import Darwin
import Foundation
import HereforthCore
import JavaScriptCore

enum CodeMode {
    typealias Record = [String: Any]
    struct BudgetExceeded: LocalizedError {
        let errorDescription: String?
        init(_ description: String) { errorDescription = description }
    }
    static let scriptLimit = 4_096
    private static let resultLimit = 24_576
    private static let frameLimit = 98_304
    private static let allowed = Set(["search_decisions", "team_standup", "read_passage"])

    static func evaluate(_ code: String, query: (String, Record) throws -> Record) throws -> Any {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, code.utf8.count <= scriptLimit else {
            throw HereforthError("Provide a JavaScript body up to 4,096 UTF-8 bytes.")
        }
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            throw HereforthError("Could not start the isolated query worker.")
        }
        let process = Process()
        let request = Pipe()
        let response = Pipe()
        process.executableURL = executable
        process.arguments = ["_code-mode-worker"]
        process.environment = ["JSC_useJIT": "false", "JSC_gcMaxHeapSize": "125829120"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/var/empty", isDirectory: true)
        process.standardInput = request
        process.standardOutput = response
        process.standardError = FileHandle.nullDevice
        // A worker can hit its limit while a broker response is in flight.
        let previousSIGPIPE = signal(SIGPIPE, SIG_IGN)
        defer { _ = signal(SIGPIPE, previousSIGPIPE) }
        try process.run()
        request.fileHandleForReading.closeFile()
        response.fileHandleForWriting.closeFile()
        defer {
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            request.fileHandleForWriting.closeFile()
            response.fileHandleForReading.closeFile()
        }
        let input = request.fileHandleForWriting.fileDescriptor
        guard fcntl(input, F_SETFL, O_NONBLOCK) == 0 else {
            throw HereforthError("Could not configure the isolated query worker.")
        }
        let output = response.fileHandleForReading.fileDescriptor
        let deadline = DispatchTime.now() + .seconds(16)
        var buffered = Data()
        var failedMemoryChecks = 0
        var callCount = 0
        var teamUsed = false
        var remainingBytes = frameLimit
        try write(try JSONSerialization.data(withJSONObject: ["code": code]), to: input, until: deadline)
        while true {
            let message = try receive(output, process: process, until: deadline, buffer: &buffered,
                                      failedMemoryChecks: &failedMemoryChecks)
            if let limit = message["limit"] as? String, message.count == 1 {
                throw BudgetExceeded(limit)
            }
            if let error = message["error"] as? String, message.count == 1 {
                throw HereforthError(error)
            }
            if let result = message["result"], message.count == 1 {
                let serialized = try JSONSerialization.data(withJSONObject: result, options: .fragmentsAllowed)
                guard serialized.count <= resultLimit else { throw BudgetExceeded("Return at most 24 KiB of JSON.") }
                return result
            }
            guard let name = message["call"] as? String, allowed.contains(name),
                  let arguments = message["arguments"] as? Record, message.count == 2 else {
                throw HereforthError("The query worker requested an unavailable operation.")
            }
            guard callCount < 6, name != "team_standup" || !teamUsed else {
                throw BudgetExceeded("A script may make six queries, including one team standup.")
            }
            if name == "team_standup" {
                guard deadline.uptimeNanoseconds > (DispatchTime.now() + .seconds(12)).uptimeNanoseconds else {
                    throw BudgetExceeded("The query reached its time limit.")
                }
                teamUsed = true
            }
            callCount += 1
            let result: Record
            do { result = ["result": try query(name, arguments)] }
            catch { result = ["error": error.localizedDescription] }
            let bytes = try JSONSerialization.data(withJSONObject: result)
            guard bytes.count <= remainingBytes, DispatchTime.now() < deadline else {
                throw BudgetExceeded("The query reached its time or data limit.")
            }
            remainingBytes -= bytes.count
            try write(bytes, to: input, until: deadline)
        }
    }

    static func runWorker() {
        do {
            guard isolate(), let initial = readLine(), initial.utf8.count <= frameLimit,
                  let request = try JSONSerialization.jsonObject(with: Data(initial.utf8)) as? Record,
                  let code = request["code"] as? String, code.utf8.count <= scriptLimit,
                  let context = JSContext() else {
                throw HereforthError("The isolated query worker is unavailable.")
            }
            let dispatch: @convention(block) (String, String) -> String = { name, input in
                do {
                    guard allowed.contains(name), input.utf8.count <= scriptLimit,
                          let arguments = try JSONSerialization.jsonObject(with: Data(input.utf8)) as? Record else {
                        return "{\"error\":\"Provide a JSON argument object for an allowed read operation.\"}"
                    }
                    try send(["call": name, "arguments": arguments], to: .standardOutput)
                    guard let reply = readLine(), reply.utf8.count <= frameLimit else {
                        return "{\"error\":\"The query worker lost its connection.\"}"
                    }
                    return reply
                } catch {
                    return "{\"error\":\"The query could not be completed.\"}"
                }
            }
            context.setObject(dispatch, forKeyedSubscript: "__hereforthBroker" as NSString)
            let functions = context.evaluateScript("""
                (function (broker) {
                    "use strict";
                    const stringify = JSON.stringify.bind(JSON);
                    const parse = JSON.parse.bind(JSON);
                    return ["search_decisions", "team_standup", "read_passage"].map(name => (args = {}) => {
                        const reply = parse(broker(name, stringify(args)));
                        if ("error" in reply) throw new Error(reply.error);
                        return reply.result;
                    });
                })(globalThis.__hereforthBroker)
                """)
            context.evaluateScript("delete globalThis.__hereforthBroker")
            let stringify = context.evaluateScript("JSON.stringify.bind(JSON)")
            let function = context.objectForKeyedSubscript("Function").construct(
                withArguments: ["search_decisions", "team_standup", "read_passage", "\"use strict\";\n" + code]
            )
            guard context.exception == nil, let function, let functions, let stringify,
                  let result = function.call(withArguments: (0..<3).map { functions.atIndex($0) as Any }),
                  context.exception == nil, !result.isUndefined,
                  let encoded = stringify.call(withArguments: [result]), encoded.isString, context.exception == nil,
                  let json = encoded.toString() else {
                if let diagnostic = context.exception?.toString(), !diagnostic.isEmpty {
                    throw HereforthError("JavaScript error: " + String(diagnostic.unicodeScalars.prefix(256)))
                }
                throw HereforthError("The script must complete and return a JSON value.")
            }
            guard json.utf8.count <= resultLimit else {
                throw BudgetExceeded("Return at most 24 KiB of JSON.")
            }
            let value = try JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed)
            try send(["result": value], to: .standardOutput)
        } catch let budget as BudgetExceeded {
            try? send(["limit": budget.localizedDescription], to: .standardOutput)
        } catch {
            try? send(["error": (error as? HereforthError)?.localizedDescription ?? "The isolated query failed."], to: .standardOutput)
        }
    }

    private static func isolate() -> Bool {
        typealias SandboxInit = @convention(c) (UnsafePointer<CChar>, UInt64,
            UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
        typealias SandboxFree = @convention(c) (UnsafeMutablePointer<CChar>) -> Void
        guard let library = dlopen("/usr/lib/libsandbox.1.dylib", RTLD_NOW | RTLD_LOCAL) else { return false }
        defer { dlclose(library) }
        guard let enter = dlsym(library, "sandbox_init"), let release = dlsym(library, "sandbox_free_error") else { return false }
        let enterSandbox = unsafeBitCast(enter, to: SandboxInit.self)
        let freeError = unsafeBitCast(release, to: SandboxFree.self)
        var cpu = rlimit(rlim_cur: 2, rlim_max: 2)
        var core = rlimit(rlim_cur: 0, rlim_max: 0)
        guard setrlimit(RLIMIT_CPU, &cpu) == 0, setrlimit(RLIMIT_CORE, &core) == 0 else { return false }
        let rules = """
            (version 1)
            (deny default)
            (allow sysctl-read)
            (allow file-read* (subpath "/System/Library") (subpath "/usr/lib"))
            (allow process-info* (target self))
            """
        var error: UnsafeMutablePointer<CChar>?
        let status = rules.withCString { enterSandbox($0, 0, &error) }
        if let error { freeError(error) }
        return status == 0
    }

    private static func send(_ message: Record, to handle: FileHandle) throws {
        var bytes = try JSONSerialization.data(withJSONObject: message)
        guard bytes.count <= frameLimit else { throw HereforthError("The query exceeded its data limit.") }
        bytes.append(10)
        try handle.write(contentsOf: bytes)
    }

    private static func write(_ bytes: Data, to fd: Int32, until deadline: DispatchTime) throws {
        let line = bytes + Data([10])
        var offset = 0
        while offset < line.count, DispatchTime.now() < deadline {
            var event = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            if poll(&event, 1, 15) <= 0 { continue }
            let written = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), line.count - offset) }
            if written < 0, errno == EAGAIN || errno == EINTR { continue }
            guard written > 0 else { throw HereforthError("The isolated query worker stopped receiving data.") }
            offset += written
        }
        guard offset == line.count else { throw BudgetExceeded("The query reached its time limit.") }
    }

    private static func receive(_ fd: Int32, process: Process, until deadline: DispatchTime,
                                buffer: inout Data, failedMemoryChecks: inout Int) throws -> Record {
        var chunk = [UInt8](repeating: 0, count: 4_096)
        while DispatchTime.now() < deadline {
            if let memory = footprint(of: process.processIdentifier) {
                failedMemoryChecks = 0
                if memory > 160 * 1_024 * 1_024 { throw BudgetExceeded("The script exceeded its memory limit.") }
            } else if process.isRunning {
                failedMemoryChecks += 1
                if failedMemoryChecks >= 4 { throw BudgetExceeded("Could not measure the isolated worker’s memory.") }
            }
            if let end = buffer.firstIndex(of: 10) {
                let frame = Data(buffer[..<end])
                buffer.removeSubrange(...end)
                guard let value = try JSONSerialization.jsonObject(with: frame) as? Record else {
                    throw HereforthError("Invalid response from the isolated query worker.")
                }
                return value
            }
            var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&event, 1, 15) <= 0 { continue }
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            guard count > 0 else { throw BudgetExceeded("The script did not complete within its execution limits.") }
            buffer.append(contentsOf: chunk.prefix(count))
            guard buffer.count <= frameLimit + 1 else { throw HereforthError("The query exceeded its data limit.") }
        }
        throw BudgetExceeded("The query reached its time limit.")
    }

    private static func footprint(of pid: Int32) -> UInt64? {
        var usage = rusage_info_v2()
        let result = withUnsafeMutableBytes(of: &usage) {
            proc_pid_rusage(pid, RUSAGE_INFO_V2, $0.baseAddress!.assumingMemoryBound(to: rusage_info_t?.self))
        }
        return result == 0 ? usage.ri_phys_footprint : nil
    }
}

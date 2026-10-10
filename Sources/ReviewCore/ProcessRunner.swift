import Foundation

/// Runs a child process with stdin, captured output, a timeout and task cancellation.
enum ProcessRunner {
    struct Output {
        var status: Int32
        var stdout: Data
        var stderr: Data
    }

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var finished = false
        var cancelled = false
        var out = Data()
        var err = Data()
        func finishOnce() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if finished { return false }
            finished = true
            return true
        }
    }

    static func run(executable: URL, arguments: [String], environment: [String: String]? = nil,
                    stdin: Data? = nil, workingDirectory: URL? = nil, timeout: TimeInterval) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe
        let box = Box()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, Error>) in
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { box.out = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.enter()
                DispatchQueue.global().async { box.err = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }

                process.terminationHandler = { p in
                    group.notify(queue: .global()) {
                        guard box.finishOnce() else { return }
                        if box.cancelled {
                            continuation.resume(throwing: ReviewError.cancelled)
                        } else {
                            continuation.resume(returning: Output(status: p.terminationStatus, stdout: box.out, stderr: box.err))
                        }
                    }
                }
                do {
                    try process.run()
                } catch {
                    _ = box.finishOnce()
                    continuation.resume(throwing: error)
                    return
                }
                DispatchQueue.global().async {
                    if let stdin { try? inPipe.fileHandleForWriting.write(contentsOf: stdin) }
                    try? inPipe.fileHandleForWriting.close()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard process.isRunning, box.finishOnce() else { return }
                    process.terminate()
                    continuation.resume(throwing: ReviewError.claude("Claude took too long to respond. Please try again."))
                }
            }
        } onCancel: {
            box.lock.lock(); box.cancelled = true; box.lock.unlock()
            if process.isRunning { process.terminate() }
        }
    }

    static func runSync(executable: URL, arguments: [String], timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global().asyncAfter(deadline: deadline) { if process.isRunning { process.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

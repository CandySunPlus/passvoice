import Foundation
import Darwin

final class HelperProcess {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()

    init(executable: URL) {
        process.executableURL = executable
        process.standardInput = input
        process.standardOutput = output
    }

    func start(onEvent: @escaping (HelperEvent) -> Void, onExit: @escaping (Int32) -> Void) throws {
        try process.run()
        let reader = output.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let decoder = JSONDecoder()
            var pending = Data()
            var bytes = [UInt8](repeating: 0, count: 8192)
            while true {
                // A live helper can wait for our reply after writing a single short line.
                let count = bytes.withUnsafeMutableBytes { buffer in
                    Darwin.read(reader.fileDescriptor, buffer.baseAddress, buffer.count)
                }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                pending.append(contentsOf: bytes.prefix(count))
                while let newline = pending.firstIndex(of: 0x0a) {
                    if let event = try? decoder.decode(HelperEvent.self, from: pending[..<newline]) {
                        DispatchQueue.main.async { onEvent(event) }
                    }
                    pending.removeSubrange(...newline)
                }
                if pending.count > 8192 { pending.removeAll(keepingCapacity: true) }
            }
            process.waitUntilExit()
            let status = process.terminationStatus
            DispatchQueue.main.async { onExit(status) }
        }
    }

    func send(_ command: HelperCommand) throws {
        var line = try JSONEncoder().encode(command)
        line.append(0x0a)
        try input.fileHandleForWriting.write(contentsOf: line)
    }

    func stop() {
        guard process.isRunning else { return }
        try? send(HelperCommand(type: "shutdown"))
        try? input.fileHandleForWriting.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2)) { [self] in
            if process.isRunning { process.terminate() }
        }
    }
}

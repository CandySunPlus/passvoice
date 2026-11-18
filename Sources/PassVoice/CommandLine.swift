import AppKit
import Foundation
import Darwin

private let usage = """
Usage:
  passvoice --scan
  passvoice --device UUID [--manual] [--verbose]

  --scan        List nearby Passports without connecting. Stop with Ctrl-C.
  --device      Connect to a Passport UUID printed by --scan.
  --manual      Send audio only. Start and end Doubao from its physical shortcut.
  --verbose     Log the sequence number of each received audio frame.

Automatic mode shows a voice draft and uses Doubao's right Option shortcut.
"""

private struct Options {
    var scan = false
    var device: UUID?
    var manual = false
    var verbose = false

    init(_ arguments: [String]) throws {
        var remaining = arguments.makeIterator()
        while let argument = remaining.next() {
            switch argument {
            case "--scan": scan = true
            case "--manual": manual = true
            case "--verbose": verbose = true
            case "--device":
                guard device == nil, let id = remaining.next(), let uuid = UUID(uuidString: id) else {
                    throw BridgeError("--device requires a single valid UUID")
                }
                device = uuid
            default:
                throw BridgeError("Unknown option \(argument)")
            }
        }
        guard scan ? device == nil && !manual && !verbose : device != nil else {
            throw BridgeError("Choose --scan or provide --device UUID")
        }
    }
}

private final class CommandLineApplication {
    private let options: Options
    private var runtime: BridgeRuntime?
    private var signals: [DispatchSourceSignal] = []
    private var stopping = false

    init(options: Options) {
        self.options = options
    }

    func start() throws {
        if !options.scan {
            _ = try BlackHolePlayback.deviceID()
            if !options.manual { try VoiceHotkey.checkAccess() }
        }
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let helperURL = executable.resolvingSymlinksInPath().deletingLastPathComponent()
            .appendingPathComponent("passport-helper")
        let runtime = BridgeRuntime(
            helperURL: helperURL,
            device: options.device,
            manual: options.manual,
            verbose: options.verbose,
            log: logBridgeMessage,
            onExit: { [weak self] status in
                if self?.stopping == true { exit(status) }
                logBridgeMessage("Passport helper exited (status \(status))")
                exit(EXIT_FAILURE)
            }
        )
        try runtime.start()
        self.runtime = runtime

        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.stop() }
            source.resume()
            signals.append(source)
        }
    }

    private func stop() {
        guard !stopping else { return }
        stopping = true
        runtime?.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(3)) { exit(EXIT_FAILURE) }
    }
}

func runCommandLine() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.isEmpty || arguments == ["--help"] || arguments == ["-h"] {
        print(usage)
        return
    }

    do {
        let options = try Options(arguments)
        let automatic = !options.scan && !options.manual
        if automatic { NSApplication.shared.setActivationPolicy(.accessory) }
        let app = CommandLineApplication(options: options)
        try app.start()
        withExtendedLifetime(app) {
            if automatic { NSApplication.shared.run() }
            else { dispatchMain() }
        }
    } catch {
        logBridgeMessage(error.localizedDescription)
        logBridgeMessage(usage)
        exit(EXIT_FAILURE)
    }
}

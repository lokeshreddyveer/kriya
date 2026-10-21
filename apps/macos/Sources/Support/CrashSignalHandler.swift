import Foundation

/// Leaves a one-line note when the app dies from a fatal signal, so the next launch can say so in the log.
/// The handler only calls `write`, which is safe inside a signal handler, and then lets the system crash as usual.
enum CrashSignalHandler {
    private static var fd: Int32 = -1
    private static var messages = [UnsafeMutablePointer<CChar>?](repeating: nil, count: 32)

    private static let signals: [(Int32, String)] = [
        (SIGSEGV, "SIGSEGV"), (SIGBUS, "SIGBUS"), (SIGILL, "SIGILL"),
        (SIGABRT, "SIGABRT"), (SIGFPE, "SIGFPE"), (SIGTRAP, "SIGTRAP"),
    ]

    static func install(noteFile: URL) {
        fd = open(noteFile.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return }
        for (number, name) in signals where number < 32 {
            messages[Int(number)] = strdup("Fatal signal \(number) (\(name))\n")
            signal(number) { received in
                if received >= 0, received < 32, let text = CrashSignalHandler.messages[Int(received)] {
                    _ = write(CrashSignalHandler.fd, text, strlen(text))
                }
                signal(received, SIG_DFL)
                raise(received)
            }
        }
        NSSetUncaughtExceptionHandler { exception in
            Log.error("Crash", "Uncaught exception \(exception.name.rawValue): \(exception.reason ?? "no reason")")
            Log.shared.flush()
        }
    }

    /// Moves any note from the previous run into the normal log.
    static func reportPreviousCrash(noteFile: URL) {
        guard let data = try? Data(contentsOf: noteFile), !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            Log.error("Crash", "Previous run ended: \(line)")
        }
        try? Data().write(to: noteFile)
    }
}

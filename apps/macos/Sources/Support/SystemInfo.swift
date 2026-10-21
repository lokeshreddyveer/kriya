import AppKit
import Foundation

enum SystemInfo {
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static var osVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    static var architecture: String {
        #if arch(arm64)
        return "Apple Silicon (arm64)"
        #else
        return "Intel (x86_64)"
        #endif
    }

    static var nowSeconds: Int64 {
        Int64(Date().timeIntervalSince1970)
    }

    /// True while the app is stopped at breakpoints or run from Xcode, so stopping it is not counted as a crash.
    static func isDebuggerAttached() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        return result == 0 && (info.kp_proc.p_flag & P_TRACED) != 0
    }

    /// Starts a fresh copy of the app a moment after this one quits.
    static func relaunch(arguments: [String] = []) {
        let path = shellQuote(Bundle.main.bundlePath)
        // `--relaunched` tells the new copy to wait for this one to finish quitting instead of handing over to it.
        let extra = " --args " + (arguments + ["--relaunched"]).map(shellQuote).joined(separator: " ")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open -n \(path)\(extra)"]
        try? task.run()
        NSApp.terminate(nil)
    }

    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

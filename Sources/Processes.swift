import AppKit
import Darwin

enum ProcessArgs {
    /// Command-line arguments of another process, read with sysctl(KERN_PROCARGS2).
    static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        // Skip the executable path and the NUL padding after it.
        while i < size, buffer[i] != 0 { i += 1 }
        while i < size, buffer[i] == 0 { i += 1 }

        var args: [String] = []
        var start = i
        while i < size, args.count < Int(argc) {
            if buffer[i] == 0 {
                args.append(String(decoding: buffer[start..<i], as: UTF8.self))
                start = i + 1
            }
            i += 1
        }
        return args
    }

    static func userDataDir(of pid: pid_t) -> String? {
        let args = arguments(of: pid)
        for (n, a) in args.enumerated() {
            if a.hasPrefix("--user-data-dir=") {
                return String(a.dropFirst("--user-data-dir=".count))
            }
            if a == "--user-data-dir", n + 1 < args.count { return args[n + 1] }
        }
        return nil
    }
}

/// A running Claude Desktop main process and the data folder it was started with.
struct RunningClaude {
    let app: NSRunningApplication
    let dataPath: String?   // nil = the regular Claude app (default data folder)
}

enum ClaudeProcesses {
    static func all() -> [RunningClaude] {
        NSWorkspace.shared.runningApplications
            .filter { Paths.isClaudeBundleID($0.bundleIdentifier) && !$0.isTerminated }
            .map { app in
                RunningClaude(app: app,
                              dataPath: ProcessArgs.userDataDir(of: app.processIdentifier).map(Paths.normalized))
            }
    }
}

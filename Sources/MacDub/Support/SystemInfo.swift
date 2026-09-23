import Foundation

/// Hardware and build facts shown in Settings › General › Status.
enum SystemInfo {
    /// "Apple M1 Pro", "Intel(R) Core(TM) i7-…".
    static let chip: String = sysctlString("machdep.cpu.brand_string") ?? L("Unknown")

    /// "8 cores (6 performance + 2 efficiency)" on Apple Silicon, "8 cores" elsewhere.
    static let cores: String = {
        let total = ProcessInfo.processInfo.processorCount
        if let p = sysctlInt("hw.perflevel0.physicalcpu"), let e = sysctlInt("hw.perflevel1.physicalcpu"), e > 0 {
            return LF("%lld cores (%lld performance + %lld efficiency)", total, p, e)
        }
        return LF("%lld cores", total)
    }()

    static let memory: String =
        ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory)

    static let isAppleSilicon: Bool = sysctlInt("hw.optional.arm64") == 1

    /// The x86_64 slice running under Rosetta on an Apple Silicon Mac.
    static let isTranslated: Bool = sysctlInt("sysctl.proc_translated") == 1

    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return isTranslated ? L("x86_64 (Rosetta)") : "x86_64"
        #endif
    }

    static let macOSVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
    }()

    /// Whether this binary was compiled with the macOS 26 SDK (SpeechAnalyzer, FoundationModels).
    static var builtWithMacOS26SDK: Bool {
        #if compiler(>=6.2)
        return true
        #else
        return false
        #endif
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf).trimmingCharacters(in: .whitespaces)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

func emit(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

func fail(_ reason: String, _ status: Int32) -> Never {
    try? emit(["error": reason])
    exit(status)
}

func fileHash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func ownWindows(_ pid: Int32) throws -> [[String: Any]] {
    guard let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] else { fail("window_server_unavailable", 24) }
    return windows.compactMap { window in
        guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let id = window[kCGWindowNumber as String] as? NSNumber,
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let width = bounds["Width"] as? NSNumber,
              let height = bounds["Height"] as? NSNumber,
              width.doubleValue >= 300, height.doubleValue >= 200 else { return nil }
        return ["id": id, "pid": pid, "width": width, "height": height]
    }.sorted {
        let lhs = ($0["width"] as! NSNumber).doubleValue * ($0["height"] as! NSNumber).doubleValue
        let rhs = ($1["width"] as! NSNumber).doubleValue * ($1["height"] as! NSNumber).doubleValue
        return lhs > rhs
    }
}

func collectDiagnostics(_ pid: Int32, _ executable: String, _ since: TimeInterval, _ output: String) throws {
    let manager = FileManager.default
    var count = 0
    let roots = [
        manager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports"),
        URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")
    ]
    for root in roots {
        let files = (try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for file in files where ["ips", "crash"].contains(file.pathExtension) {
            let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard (values.contentModificationDate?.timeIntervalSince1970 ?? 0) >= since,
                  (values.fileSize ?? Int.max) <= 4 * 1024 * 1024,
                  let data = try? Data(contentsOf: file),
                  let text = String(data: data, encoding: .utf8) else { continue }
            let sections = [text] + text.split(separator: "\n", maxSplits: 1).map(String.init)
            let jsonMatch = sections.contains { section in
                guard let document = try? JSONSerialization.jsonObject(with: Data(section.utf8)) as? [String: Any]
                else { return false }
                return (document["pid"] as? NSNumber)?.int32Value == pid &&
                    document["procPath"] as? String == executable
            }
            let legacyMatch = text.split(separator: "\n").contains {
                $0.hasPrefix("Process:") && $0.hasSuffix("[\(pid)]")
            } && text.split(separator: "\n").contains {
                $0.hasPrefix("Path:") && $0.dropFirst(5).trimmingCharacters(in: .whitespaces) == executable
            }
            guard jsonMatch || legacyMatch else { continue }
            count += 1
            let target = URL(fileURLWithPath: output).appendingPathComponent("\(pid)-\(count).\(file.pathExtension)")
            try data.write(to: target, options: .withoutOverwriting)
            try emit(["pid": pid, "file": target.lastPathComponent, "sha256": fileHash(data)])
        }
    }
    try emit(["pid": pid, "matching_diagnostics": count])
}

let arguments = CommandLine.arguments
do {
    guard arguments.count >= 2 else { fail("invalid_arguments", 64) }
    switch arguments[1] {
    case "permission":
        let allowed = CGPreflightScreenCaptureAccess()
        try emit(["screen_capture_preflight": allowed])
        if !allowed { exit(23) }
    case "window":
        guard arguments.count == 3, let pid = Int32(arguments[2]), pid > 0 else {
            fail("invalid_arguments", 64)
        }
        guard let window = try ownWindows(pid).first else { exit(22) }
        try emit(window)
        FileHandle.standardError.write(Data("\(window["id"]!)\n".utf8))
    case "image":
        guard arguments.count == 3 else { fail("invalid_arguments", 64) }
        let url = URL(fileURLWithPath: arguments[2])
        let data = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source), type as String == "public.png",
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width >= 300, image.height >= 200 else { fail("invalid_png", 26) }
        try emit(["sha256": fileHash(data), "bytes": data.count, "width": image.width, "height": image.height])
    case "diagnostics":
        guard arguments.count == 6, let pid = Int32(arguments[2]), pid > 0,
              let since = TimeInterval(arguments[4]) else { fail("invalid_arguments", 64) }
        try collectDiagnostics(pid, arguments[3], since, arguments[5])
    default:
        fail("invalid_arguments", 64)
    }
} catch {
    fail("probe_failed", 27)
}

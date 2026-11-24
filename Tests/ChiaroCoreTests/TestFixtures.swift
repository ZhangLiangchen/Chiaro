import Foundation
import Testing

enum TestFixtures {
    /// Directory containing optional Sony `.ARW` sample fixtures for real-camera integration tests.
    /// Set `CHIARO_SAMPLE_DIR=/path/to/arw/folder` to run real-sample integration tests locally.
    static var sampleDirectory: URL {
        if let env = ProcessInfo.processInfo.environment["CHIARO_SAMPLE_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        }
        return URL(fileURLWithPath: "Samples", isDirectory: true)
    }

    static var hasSampleDirectory: Bool {
        var isDir: ObjCBool = false
        let dir = sampleDirectory
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("DSC02532.ARW").path)
            || FileManager.default.fileExists(atPath: dir.appendingPathComponent("DSC02533.ARW").path)
            || FileManager.default.fileExists(atPath: dir.appendingPathComponent("DSC02556.ARW").path)
    }
}

import Foundation

enum SubprocessWorkingDirectory {
    static var url: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base
            .appendingPathComponent("AgentMeter", isDirectory: true)
            .appendingPathComponent("Subprocess", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return fm.temporaryDirectory
        }
    }
}

import Foundation

/// Each hook sends one JSON document. Read through EOF before decoding, and
/// drain oversized inputs so the writer can finish without a broken pipe.
public enum HookStandardInput {
    public static let maximumBytes = 16 * 1024 * 1024
    private static let chunkBytes = 64 * 1024

    /// Every byte up to EOF: empty when there is none, nil past `limit` or
    /// when a read fails (a partial document must not be decoded).
    public static func readAll(from handle: FileHandle, limit: Int = maximumBytes) -> Data? {
        var data = Data()
        var oversized = false
        do {
            while let chunk = try handle.read(upToCount: chunkBytes), !chunk.isEmpty {
                if oversized { continue }
                data.append(chunk)
                if data.count > limit {
                    oversized = true
                    data = Data()
                }
            }
        } catch {
            return nil
        }
        return oversized ? nil : data
    }
}

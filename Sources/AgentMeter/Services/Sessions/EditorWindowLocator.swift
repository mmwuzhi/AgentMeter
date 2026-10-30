import AppKit
import Darwin
import Foundation

// Which editor window runs a session the Claude Code extension started, so a
// session row's click brings that window forward instead of the whole app
// (2026-10-30; checked against VS Code 1.144.0 and Claude Code 2.1.312).
//
// The folder goes to the editor as `<scheme>://file/<folder>?windowId=_blank`
// (`EditorApp.folderURL`): the editor focuses the window that has exactly
// that folder open, restoring it when minimized, and only when none has it
// opens a new window. `_blank` is what keeps it from loading the folder into
// the last active window, replacing that window's workspace, which the same
// URL without it does; it also makes `window.openFoldersInNewWindow`
// irrelevant. A URL, unlike handing over the folder itself (`open-file`),
// needs no access to the folder from AgentMeter, so a folder in Desktop or
// Documents asks for no permission, and the editor handles each URL on its
// own instead of merging folders that arrive together into one new
// multi-folder window (both seen live on 2026-10-30). A `.code-workspace`
// window never matches a folder. So the URL is sent only when all of this,
// read at click time, shows the session's own window to be the window with
// exactly that folder:
//
//  * The session (or, for a child `claude -p`, the session whose `Bash` ran
//    it) is a child of an extension host, itself a child of the editor's
//    main process, and has no terminal. The extension host listens on
//    127.0.0.1:<port>, and the extension writes `~/.claude/ide/<port>.lock`
//    with that window's `workspaceFolders` and the main process's `pid`,
//    the same for every window: the port is what names the window. The
//    lock's auth token is never decoded.
//  * That window has exactly one folder, one the URL carries as itself (no
//    `:`, which the editor would read as a line number, and not named like a
//    workspace file), and no other live window (a lock whose port a child of
//    the editor listens on) reports exactly it.
//  * The editor's `storage.json` `windowsState` lists each window as a folder
//    or a workspace file. The editor writes it when one of its windows loses
//    focus and at quit, nowhere else, so it is used only when written after
//    the session's extension host started: the window then existed in its
//    present form (moving between folder and workspace restarts the host).
//    It must list the folder as a folder window, and no workspace window
//    whose file names exactly that folder: the session's window is then the
//    folder window, as a one-folder `.code-workspace` window reports the same
//    `workspaceFolders`. A workspace file in a folder macOS guards (Desktop,
//    Documents, Downloads, iCloud Drive, cloud storage, other volumes) is not
//    read, which would ask for access, and counts as naming it.
//
// The conversation's tab is not chosen: Claude Code's
// `vscode://anthropic.claude-code/open?session=` goes to the last focused
// window, and a window that does not hold the session opens a new empty
// conversation there (docs/agent/ui-state.md).

/// An editor built on VS Code that hosts the Claude Code extension.
struct EditorApp: Sendable, Equatable {
    let bundleID: String
    let name: String
    /// The folder in `~/Library/Application Support` that holds `User/`.
    let dataFolder: String
    let urlScheme: String

    /// VS Code is the one checked live; the others share its window code.
    static let known: [EditorApp] = [
        EditorApp(bundleID: "com.microsoft.VSCode", name: "VS Code", dataFolder: "Code", urlScheme: "vscode"),
        EditorApp(bundleID: "com.microsoft.VSCodeInsiders", name: "VS Code Insiders", dataFolder: "Code - Insiders",
                  urlScheme: "vscode-insiders"),
        EditorApp(bundleID: "com.todesktop.230313mzl4w4u92", name: "Cursor", dataFolder: "Cursor", urlScheme: "cursor"),
    ]

    /// The only URL a click sends: the folder, never in the last active
    /// window (`windowId=_blank`). Nil for a folder the URL would not carry
    /// as itself.
    func folderURL(_ folder: String) -> URL? {
        guard folder.hasPrefix("/"), EditorWindowLocator.isPlainFolder(folder) else { return nil }
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = "file"
        components.path = folder
        components.queryItems = [URLQueryItem(name: "windowId", value: "_blank")]
        return components.url
    }

    static func named(bundleID: String?) -> EditorApp? {
        known.first { $0.bundleID == bundleID }
    }

    var userDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(dataFolder, isDirectory: true)
            .appendingPathComponent("User", isDirectory: true)
    }
}

/// What AgentMeter keeps of one `~/.claude/ide/<port>.lock`.
struct EditorIDELock: Sendable, Equatable {
    let port: Int
    /// The editor's main process, shared by all its windows.
    let editorPID: Int
    let folders: [String]
}

/// The editor's `windowsState` as last written.
struct EditorWindowList: Sendable, Equatable {
    var savedAt: Date
    /// Folder windows' folders.
    var folders: [String]
    /// Workspace windows' workspace files (`.code-workspace`, or an untitled
    /// workspace's `workspace.json`).
    var workspaces: [String]
}

/// Where a click on an editor session's row can go.
enum EditorWindowTarget: Sendable, Equatable {
    /// The one window whose only folder this is.
    case folder(String)
    case unnamed(EditorWindowMiss)
}

/// Why no window was named. Every case leaves the editor as it was.
enum EditorWindowMiss: Sendable, Equatable {
    /// Not under an extension host of this editor: a session in the editor's
    /// terminal, or one started some other way.
    case notInExtension
    /// The extension host reports no window (no live lock for its port).
    case noWindow
    case noFolder
    /// A window with several folders is matched only by its workspace file.
    case severalFolders
    /// The URL would not carry the folder as itself.
    case unusualFolder(folder: String)
    /// Another live window reports exactly the same folder.
    case sharedFolder(folder: String)
    /// The window list is unreadable, or older than the session's window.
    case notRecorded
    /// Not listed as a folder window, or a workspace window (maybe unreadable)
    /// may hold exactly this folder.
    case notListed(folder: String)

    /// The row's line: why the click did nothing.
    func explanation(editor: String) -> String {
        switch self {
        case .notInExtension:
            "Can't tell which \(editor) window runs it: it isn't in a Claude Code tab."
        case .noWindow:
            "No \(editor) window reports this session."
        case .noFolder:
            "Its \(editor) window has no folder, so AgentMeter can't bring it forward by itself."
        case .severalFolders:
            "Its \(editor) window has several folders, so AgentMeter can't bring it forward by itself."
        case let .unusualFolder(folder):
            "AgentMeter can't name \(Self.folderName(folder)) to \(editor) exactly (its path has a colon or a workspace file's name)."
        case let .sharedFolder(folder):
            "Two \(editor) windows have \(Self.folderName(folder)) open."
        case .notRecorded:
            "\(editor) hasn't recorded this window yet; it does when one of its windows loses focus. Click again after that."
        case let .notListed(folder):
            "\(editor) lists no window with only \(Self.folderName(folder)) as its folder (a .code-workspace window may hold it)."
        }
    }

    /// The folder's last component as one bounded line.
    static func folderName(_ path: String) -> String {
        let name = String((path as NSString).lastPathComponent.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) })
        return name.isEmpty ? "its folder" : String(name.prefix(60))
    }
}

struct EditorWindowLocator: Sendable {
    var parentPID: @Sendable (Int) -> Int?
    var hasTerminal: @Sendable (Int) -> Bool
    var processStart: @Sendable (Int) -> Date?
    var childPIDs: @Sendable (Int) -> [Int]
    var listeningPorts: @Sendable (Int) -> Set<Int>
    var readLocks: @Sendable () -> [EditorIDELock]
    var readWindows: @Sendable (EditorApp) -> EditorWindowList?
    /// A workspace file's folders; nil when it cannot or may not be read.
    var readWorkspaceFolders: @Sendable (String) -> [String]?

    static let maximumAncestors = 32

    func target(sessionPID: Int, editorPID: Int, editor: EditorApp) -> EditorWindowTarget {
        guard let (session, host) = extensionSession(of: sessionPID, editorPID: editorPID),
              !hasTerminal(session) else { return .unnamed(.notInExtension) }
        let livePorts = childPIDs(editorPID).reduce(into: Set<Int>()) { $0.formUnion(listeningPorts($1)) }
        let hostPorts = listeningPorts(host)
        let locks = readLocks().filter { $0.editorPID == editorPID && livePorts.contains($0.port) }
        let own = locks.filter { hostPorts.contains($0.port) }
        guard own.count == 1, let lock = own.first else { return .unnamed(.noWindow) }
        guard let folder = lock.folders.first else { return .unnamed(.noFolder) }
        guard lock.folders.count == 1 else { return .unnamed(.severalFolders) }
        guard Self.isPlainFolder(folder) else { return .unnamed(.unusualFolder(folder: folder)) }
        let key = Self.comparisonKey(folder)
        let holdsOnlyIt = { (folders: [String]) in folders.count == 1 && Self.comparisonKey(folders[0]) == key }
        if locks.contains(where: { $0.port != lock.port && holdsOnlyIt($0.folders) }) {
            return .unnamed(.sharedFolder(folder: folder))
        }
        guard let windows = readWindows(editor), let started = processStart(host),
              windows.savedAt >= started else { return .unnamed(.notRecorded) }
        guard windows.folders.contains(where: { Self.comparisonKey($0) == key }),
              !windows.workspaces.contains(where: { readWorkspaceFolders($0).map(holdsOnlyIt) ?? true })
        else { return .unnamed(.notListed(folder: folder)) }
        return .folder(folder)
    }

    /// The extension-started session a process belongs to and its extension
    /// host: the process, or its nearest ancestor, whose parent's parent is
    /// the editor's main process. A terminal in the editor resolves to the
    /// terminal's shell, which has a terminal.
    func extensionSession(of pid: Int, editorPID: Int) -> (session: Int, host: Int)? {
        var current = pid
        for _ in 0..<Self.maximumAncestors {
            guard let parent = parentPID(current), parent > 1, parent != editorPID else { return nil }
            if parentPID(parent) == editorPID { return (current, parent) }
            current = parent
        }
        return nil
    }

    /// A folder the editor reads back from the URL as itself: no `:` (a line
    /// number to it) and not named like a workspace file.
    static func isPlainFolder(_ path: String) -> Bool {
        !path.contains(":") && !path.lowercased().hasSuffix(".code-workspace")
    }

    /// Folders macOS asks the user about before an app reads in them.
    static func isGuardedLocation(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let key = comparisonKey(path)
        let guarded = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/CloudStorage"]
            .map { comparisonKey(home + "/" + $0) } + ["/volumes"]
        return guarded.contains { key == $0 || key.hasPrefix($0 + "/") }
    }

    /// How the editor compares folders on macOS: lexically normalized,
    /// case-insensitive, never through the file system (`/tmp/x` and
    /// `/private/tmp/x` are different windows to it).
    static func comparisonKey(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") where part != "." {
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
            } else {
                parts.append(part)
            }
        }
        return ("/" + parts.joined(separator: "/")).precomposedStringWithCanonicalMapping.lowercased()
    }

    static let live = EditorWindowLocator(
        parentPID: { pid in
            guard let value = pid_t(exactly: pid) else { return nil }
            return AgentAppActivator.parentPID(of: value).map(Int.init)
        },
        hasTerminal: { AgentAppActivator.controllingTTY(of: $0) != nil },
        processStart: { TaskOutcomeMonitor.processStartDate($0) },
        childPIDs: { childPIDs(of: $0) },
        listeningPorts: { listeningTCPPorts(of: $0) },
        readLocks: { readLocks(in: lockDirectory) },
        readWindows: { readWindows(at: $0.userDirectory.appendingPathComponent("globalStorage/storage.json")) },
        readWorkspaceFolders: { isGuardedLocation($0) ? nil : workspaceFolders(at: $0) }
    )

    static var lockDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/ide", isDirectory: true)
    }

    static let maximumLockBytes = 64 * 1024
    static let maximumFileBytes = 16 * 1024 * 1024

    static func readLocks(in directory: URL) -> [EditorIDELock] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> EditorIDELock? in
            guard name.hasSuffix(".lock"),
                  let port = Int(name.dropLast(5)), (1...65_535).contains(port),
                  let data = readFile(directory.appendingPathComponent(name), limit: maximumLockBytes) else { return nil }
            return decodeLock(data, port: port)
        }
    }

    static func decodeLock(_ data: Data, port: Int) -> EditorIDELock? {
        // Only these two fields are decoded; the auth token beside them is not.
        struct Fields: Decodable {
            let pid: Int
            let workspaceFolders: [String]?
        }
        guard let fields = try? JSONDecoder().decode(Fields.self, from: data), fields.pid > 0 else { return nil }
        return EditorIDELock(port: port, editorPID: fields.pid, folders: fields.workspaceFolders ?? [])
    }

    static func readWindows(at url: URL) -> EditorWindowList? {
        guard let savedAt = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
              let data = readFile(url, limit: maximumFileBytes) else { return nil }
        return decodeWindows(data, savedAt: savedAt)
    }

    /// `windowsState.lastActiveWindow` and `openedWindows` (empty while only
    /// one window is open): a folder window has `folder`, a workspace window
    /// `workspaceIdentifier.configURIPath`, both file URIs when local.
    static func decodeWindows(_ data: Data, savedAt: Date) -> EditorWindowList? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = root["windowsState"] as? [String: Any] else { return nil }
        var windows = (state["openedWindows"] as? [[String: Any]]) ?? []
        if let last = state["lastActiveWindow"] as? [String: Any] { windows.append(last) }
        let filePath = { (value: Any?) -> String? in
            guard let text = value as? String, let url = URL(string: text), url.isFileURL else { return nil }
            return url.path
        }
        return EditorWindowList(
            savedAt: savedAt,
            folders: windows.compactMap { filePath($0["folder"]) },
            workspaces: windows.compactMap { filePath(($0["workspaceIdentifier"] as? [String: Any])?["configURIPath"]) }
        )
    }

    static func workspaceFolders(at path: String) -> [String]? {
        readFile(URL(fileURLWithPath: path), limit: maximumFileBytes)
            .flatMap { decodeWorkspaceFolders($0, directory: (path as NSString).deletingLastPathComponent) }
    }

    /// A workspace file's `folders`: a `path` relative to the file's folder
    /// or absolute, or a `uri`. One that is not local stays in the count
    /// under a name no local folder has.
    static func decodeWorkspaceFolders(_ data: Data, directory: String) -> [String]? {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: .json5Allowed) as? [String: Any],
              let folders = root["folders"] as? [[String: Any]] else { return nil }
        return folders.map { folder in
            if let path = folder["path"] as? String {
                return path.hasPrefix("/") ? path : directory + "/" + path
            }
            if let text = folder["uri"] as? String, let url = URL(string: text), url.isFileURL {
                return url.path
            }
            return "\u{0}not-local"
        }
    }

    private static func readFile(_ url: URL, limit: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return data
    }

    static func childPIDs(of pid: Int) -> [Int] {
        guard pid > 0, let value = pid_t(exactly: pid) else { return [] }
        let needed = proc_listchildpids(value, nil, 0)
        guard needed > 0 else { return [] }
        // Room for a few children started between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(needed) + 16)
        let filled = pids.withUnsafeMutableBytes { buffer in
            proc_listchildpids(value, buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled)).filter { $0 > 0 }.map(Int.init)
    }

    /// TCP ports the process listens on, from its open sockets.
    static func listeningTCPPorts(of pid: Int) -> Set<Int> {
        guard pid > 0, let value = pid_t(exactly: pid) else { return [] }
        let needed = proc_pidinfo(value, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        // Room for a few sockets opened between the two calls.
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
        let filled = fds.withUnsafeMutableBytes { buffer in
            proc_pidinfo(value, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else { return [] }
        var ports = Set<Int>()
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(value, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
            ports.insert(Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))))
        }
        return ports
    }
}

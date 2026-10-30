@testable import AgentMeter
import Darwin
import Foundation
import XCTest

private let editorPID = 5101
private let scriptsHost = 5102
private let sampleAppHost = 5103
private let scripts = "/Users/dev/workspace/sample-tools"
private let sampleApp = "/Users/dev/workspace/SampleApp"
private let vscode = EditorApp.named(bundleID: "com.microsoft.VSCode")!
private let hostsStarted = Date(timeIntervalSince1970: 1_700_000_000)
private let saved = hostsStarted.addingTimeInterval(3_600)

private func locator(
    parents: [Int: Int] = [5106: scriptsHost, 5107: sampleAppHost, scriptsHost: editorPID, sampleAppHost: editorPID],
    terminals: Set<Int> = [],
    starts: [Int: Date] = [scriptsHost: hostsStarted, sampleAppHost: hostsStarted],
    children: [Int] = [scriptsHost, sampleAppHost, 5104],
    ports: [Int: Set<Int>] = [scriptsHost: [41001, 41002], sampleAppHost: [41003, 41004]],
    locks: [EditorIDELock] = [EditorIDELock(port: 41001, editorPID: editorPID, folders: [scripts]),
                              EditorIDELock(port: 41003, editorPID: editorPID, folders: [sampleApp])],
    windows: EditorWindowList? = EditorWindowList(savedAt: saved, folders: [sampleApp, scripts], workspaces: []),
    workspaceFiles: [String: [String]] = [:]
) -> EditorWindowLocator {
    EditorWindowLocator(
        parentPID: { parents[$0] },
        hasTerminal: { terminals.contains($0) },
        processStart: { starts[$0] },
        childPIDs: { $0 == editorPID ? children : [] },
        listeningPorts: { ports[$0] ?? [] },
        readLocks: { locks },
        readWindows: { _ in windows },
        readWorkspaceFolders: { workspaceFiles[$0] }
    )
}

private extension EditorWindowLocator {
    func sampleAppSession() -> EditorWindowTarget { target(sessionPID: 5107, editorPID: editorPID, editor: vscode) }
}

final class EditorWindowLocatorTests: XCTestCase {
    func testEachSessionNamesItsOwnWindowsFolder() {
        let locator = locator()
        XCTAssertEqual(locator.sampleAppSession(), .folder(sampleApp))
        XCTAssertEqual(locator.target(sessionPID: 5106, editorPID: editorPID, editor: vscode), .folder(scripts))
    }

    /// The window's folder as the lock spells it, not the session's working
    /// directory: the editor matches the folder it opened.
    func testTheLocksSpellingIsHandedOver() {
        let spelled = "/Users/dev/workspace/SampleApp/"
        let target = locator(locks: [EditorIDELock(port: 41003, editorPID: editorPID, folders: [spelled])],
                             windows: EditorWindowList(savedAt: saved, folders: ["/users/dev/workspace/sampleapp"], workspaces: []))
            .sampleAppSession()
        XCTAssertEqual(target, .folder(spelled))
    }

    /// A `claude -p` that a session's `Bash` started belongs to that
    /// session's window; the editor's terminal does not resolve.
    func testAChildSessionResolvesThroughItsParentSession() {
        let parents = [7000: 7001, 7001: 5107, 5107: sampleAppHost, sampleAppHost: editorPID]
        XCTAssertEqual(locator(parents: parents).target(sessionPID: 7000, editorPID: editorPID, editor: vscode), .folder(sampleApp))
        // claude → zsh → pty host → main: the shell has a terminal.
        let terminal = [8000: 8001, 8001: 5105, 5105: editorPID]
        XCTAssertEqual(locator(parents: terminal, terminals: [8000, 8001]).target(sessionPID: 8000, editorPID: editorPID, editor: vscode),
                       .unnamed(.notInExtension))
    }

    func testOnlyAnExtensionStartedSessionIsPlaced() {
        XCTAssertEqual(locator(terminals: [5107]).sampleAppSession(), .unnamed(.notInExtension))
        // Straight under the main process, under another app, or parentless.
        XCTAssertEqual(locator(parents: [5107: editorPID]).sampleAppSession(), .unnamed(.notInExtension))
        XCTAssertEqual(locator(parents: [5107: sampleAppHost, sampleAppHost: 1]).sampleAppSession(), .unnamed(.notInExtension))
        XCTAssertEqual(locator(parents: [:]).sampleAppSession(), .unnamed(.notInExtension))
        // A parent loop ends.
        XCTAssertEqual(locator(parents: [5107: 6040, 6040: 5107]).sampleAppSession(), .unnamed(.notInExtension))
    }

    func testAHostWithoutALiveLockOfItsOwnNamesNoWindow() {
        // Closed meanwhile: the lock went with the window.
        XCTAssertEqual(locator(locks: [EditorIDELock(port: 41001, editorPID: editorPID, folders: [scripts])]).sampleAppSession(),
                       .unnamed(.noWindow))
        // The host stopped listening.
        XCTAssertEqual(locator(ports: [scriptsHost: [41001]]).sampleAppSession(), .unnamed(.noWindow))
        // Another editor's lock on the same port.
        XCTAssertEqual(locator(locks: [EditorIDELock(port: 41003, editorPID: 999, folders: [sampleApp])]).sampleAppSession(),
                       .unnamed(.noWindow))
    }

    func testOnlyAOneFolderWindowIsHandedOver() {
        let several = [EditorIDELock(port: 41003, editorPID: editorPID, folders: [sampleApp, scripts])]
        XCTAssertEqual(locator(locks: several).sampleAppSession(), .unnamed(.severalFolders))
        XCTAssertEqual(locator(locks: [EditorIDELock(port: 41003, editorPID: editorPID, folders: [])]).sampleAppSession(),
                       .unnamed(.noFolder))
    }

    func testAnotherLiveWindowWithTheSameFolderMakesItUnclear() {
        let locks = [EditorIDELock(port: 41003, editorPID: editorPID, folders: [sampleApp]),
                     EditorIDELock(port: 41000, editorPID: editorPID, folders: [sampleApp.uppercased()])]
        let ports: [Int: Set<Int>] = [sampleAppHost: [41003], 41: [41000]]
        XCTAssertEqual(locator(children: [sampleAppHost, 41], ports: ports, locks: locks).sampleAppSession(),
                       .unnamed(.sharedFolder(folder: sampleApp)))
        // A lock nothing listens on any more (a crashed window) does not count.
        XCTAssertEqual(locator(children: [sampleAppHost], ports: ports, locks: locks).sampleAppSession(), .folder(sampleApp))
        // A multi-folder window that includes it never matches the folder.
        let multi = [EditorIDELock(port: 41003, editorPID: editorPID, folders: [sampleApp]),
                     EditorIDELock(port: 41000, editorPID: editorPID, folders: [sampleApp, scripts])]
        XCTAssertEqual(locator(children: [sampleAppHost, 41], ports: ports, locks: multi).sampleAppSession(), .folder(sampleApp))
    }

    /// A folder the URL would not carry as itself is not sent.
    func testAFolderTheURLCannotCarryIsNotSent() {
        for odd in ["/Users/dev/proj:12", "/Users/dev/x.code-workspace"] {
            let locks = [EditorIDELock(port: 41003, editorPID: editorPID, folders: [odd])]
            XCTAssertEqual(locator(locks: locks, windows: EditorWindowList(savedAt: saved, folders: [odd], workspaces: [])).sampleAppSession(),
                           .unnamed(.unusualFolder(folder: odd)))
        }
    }

    /// The window list counts only when written after the session's host
    /// started: before, the window may have been a folder window that has
    /// since become a workspace.
    func testAWindowListOlderThanTheSessionsWindowIsNotUsed() {
        XCTAssertEqual(locator(starts: [sampleAppHost: saved.addingTimeInterval(1)]).sampleAppSession(), .unnamed(.notRecorded))
        XCTAssertEqual(locator(starts: [:]).sampleAppSession(), .unnamed(.notRecorded))
        XCTAssertEqual(locator(windows: nil).sampleAppSession(), .unnamed(.notRecorded))
        XCTAssertEqual(locator(starts: [sampleAppHost: saved]).sampleAppSession(), .folder(sampleApp))
    }

    /// A one-folder `.code-workspace` window reports the same folders as a
    /// folder window; only the editor's own list tells them apart.
    func testAWorkspaceWindowThatMayHoldOnlyTheFolderStopsTheHandOff() {
        XCTAssertEqual(locator(windows: EditorWindowList(savedAt: saved, folders: [scripts], workspaces: [])).sampleAppSession(),
                       .unnamed(.notListed(folder: sampleApp)))
        let workspace = "/Users/dev/one.code-workspace"
        let listed = EditorWindowList(savedAt: saved, folders: [sampleApp], workspaces: [workspace])
        XCTAssertEqual(locator(windows: listed, workspaceFiles: [workspace: [sampleApp + "/"]]).sampleAppSession(),
                       .unnamed(.notListed(folder: sampleApp)))
        XCTAssertEqual(locator(windows: listed, workspaceFiles: [:]).sampleAppSession(), .unnamed(.notListed(folder: sampleApp)),
                       "an unreadable workspace file may hold it")
        XCTAssertEqual(locator(windows: listed, workspaceFiles: [workspace: [sampleApp, scripts]]).sampleAppSession(), .folder(sampleApp))
        XCTAssertEqual(locator(windows: listed, workspaceFiles: [workspace: [scripts]]).sampleAppSession(), .folder(sampleApp))
    }

    func testComparisonIsLexicalAndCaseInsensitive() {
        XCTAssertEqual(EditorWindowLocator.comparisonKey("/Users/A/Proj/"), EditorWindowLocator.comparisonKey("/users/a/proj"))
        XCTAssertEqual(EditorWindowLocator.comparisonKey("/a//b/./c/../d"), "/a/b/d")
        XCTAssertEqual(EditorWindowLocator.comparisonKey("/a/Cafe\u{301}"), EditorWindowLocator.comparisonKey("/a/caf\u{E9}"))
        // Never through the file system, where /tmp leads to /private/tmp.
        let existing = FileManager.default.temporaryDirectory.path
        XCTAssertNotEqual(EditorWindowLocator.comparisonKey("/tmp" + existing),
                          EditorWindowLocator.comparisonKey("/private/tmp" + existing))
        XCTAssertNotEqual(EditorWindowLocator.comparisonKey("/tmp"), EditorWindowLocator.comparisonKey("/private/tmp"))
    }

    func testLockKeepsThePIDAndFoldersOnly() {
        let data = Data(#"{"pid":5101,"workspaceFolders":["/a b/c"],"ideName":"Visual Studio Code","transport":"ws","runningInWindows":false,"authToken":"secret"}"#.utf8)
        XCTAssertEqual(EditorWindowLocator.decodeLock(data, port: 41003),
                       EditorIDELock(port: 41003, editorPID: 5101, folders: ["/a b/c"]))
        XCTAssertEqual(EditorWindowLocator.decodeLock(Data(#"{"pid":5}"#.utf8), port: 1)?.folders, [])
        XCTAssertNil(EditorWindowLocator.decodeLock(Data(#"{"workspaceFolders":["/a"]}"#.utf8), port: 1))
        XCTAssertNil(EditorWindowLocator.decodeLock(Data(#"{"pid":0}"#.utf8), port: 1))
        XCTAssertNil(EditorWindowLocator.decodeLock(Data("not json".utf8), port: 1))
    }

    func testLocksAreReadByPortFileName() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"pid":7,"workspaceFolders":["/w"]}"#.utf8).write(to: directory.appendingPathComponent("41003.lock"))
        try Data(#"{"pid":7,"workspaceFolders":["/x"]}"#.utf8).write(to: directory.appendingPathComponent("notaport.lock"))
        try Data(#"{"pid":7,"workspaceFolders":["/y"]}"#.utf8).write(to: directory.appendingPathComponent("70000.lock"))
        try Data(#"{"pid":7,"workspaceFolders":["/z"]}"#.utf8).write(to: directory.appendingPathComponent("1234.json"))
        let big = #"{"pid":7,"workspaceFolders":[""# + String(repeating: "a", count: EditorWindowLocator.maximumLockBytes) + #""]}"#
        try Data(big.utf8).write(to: directory.appendingPathComponent("4000.lock"))
        XCTAssertEqual(EditorWindowLocator.readLocks(in: directory), [EditorIDELock(port: 41003, editorPID: 7, folders: ["/w"])])
        XCTAssertEqual(EditorWindowLocator.readLocks(in: directory.appendingPathComponent("missing")), [])
    }

    /// `windowsState` as VS Code 1.144 writes it: folder windows by file URI,
    /// a workspace window by its configuration file, a remote one by its URI.
    func testWindowsComeFromTheEditorsWindowState() {
        let json = #"""
        {"windowsState":{
          "lastActiveWindow":{"folder":"file:///Users/dev/workspace/sample-tools","backupPath":"/b/1","uiState":{"mode":1}},
          "openedWindows":[
            {"folder":"file:///Users/dev/My%20Project","backupPath":"/b/2"},
            {"workspaceIdentifier":{"id":"abc","configURIPath":"file:///Users/dev/one.code-workspace"},"backupPath":"/b/3"},
            {"workspaceIdentifier":{"id":"def","configURIPath":"vscode-remote://ssh-remote%2Bhost/w.code-workspace"}},
            {"folder":"vscode-remote://ssh-remote%2Bhost/home/x","backupPath":"/b/4"},
            {"backupPath":"/b/5"}
          ]},
         "other":1}
        """#
        XCTAssertEqual(EditorWindowLocator.decodeWindows(Data(json.utf8), savedAt: saved),
                       EditorWindowList(savedAt: saved, folders: ["/Users/dev/My Project", "/Users/dev/workspace/sample-tools"],
                                        workspaces: ["/Users/dev/one.code-workspace"]))
        XCTAssertNil(EditorWindowLocator.decodeWindows(Data(#"{"theme":"dark"}"#.utf8), savedAt: saved))
        XCTAssertNil(EditorWindowLocator.decodeWindows(Data("[]".utf8), savedAt: saved))
        XCTAssertEqual(EditorWindowLocator.decodeWindows(Data(#"{"windowsState":{}}"#.utf8), savedAt: saved)?.folders, [])
    }

    /// Workspace files are JSON with comments and trailing commas; a folder
    /// is a path relative to the file or absolute, or a URI.
    func testWorkspaceFilesNameTheirFolders() {
        let file = #"""
        {
          // the project
          "folders": [
            { "path": "wc" },
            { "path": "/abs/other", "name": "Other" },
            { "uri": "file:///Users/dev/u%20x" },
            { "uri": "vscode-remote://ssh-remote%2Bhost/r" },
          ],
          "settings": {},
        }
        """#
        let folders = EditorWindowLocator.decodeWorkspaceFolders(Data(file.utf8), directory: "/Users/dev/ws")
        XCTAssertEqual(folders?.count, 4)
        XCTAssertEqual(Array(folders?.prefix(3) ?? []), ["/Users/dev/ws/wc", "/abs/other", "/Users/dev/u x"])
        XCTAssertNotEqual(EditorWindowLocator.comparisonKey(folders?.last ?? ""), EditorWindowLocator.comparisonKey("/r"))
        XCTAssertNil(EditorWindowLocator.decodeWorkspaceFolders(Data(#"{"settings":{}}"#.utf8), directory: "/"))
        XCTAssertNil(EditorWindowLocator.decodeWorkspaceFolders(Data("nope".utf8), directory: "/"))
    }

    /// The one URL a click sends: the window's folder, never loaded into the
    /// last active window.
    func testTheFolderURLForcesANewWindowOverReplacingOne() throws {
        let url = try XCTUnwrap(vscode.folderURL("/Users/dev/My Proj/#1?/日本"))
        XCTAssertEqual(url.scheme, "vscode")
        XCTAssertEqual(url.host, "file")
        XCTAssertEqual(url.path, "/Users/dev/My Proj/#1?/日本")
        XCTAssertEqual(url.query, "windowId=_blank")
        XCTAssertTrue(url.absoluteString.hasPrefix("vscode://file/Users/dev/My%20Proj/%231%3F/"))
        XCTAssertEqual(vscode.folderURL(sampleApp)?.absoluteString,
                       "vscode://file/Users/dev/workspace/SampleApp?windowId=_blank")
        XCTAssertEqual(EditorApp.named(bundleID: "com.todesktop.230313mzl4w4u92")?.folderURL("/a")?.absoluteString,
                       "cursor://file/a?windowId=_blank")
        XCTAssertNil(vscode.folderURL("/a/b:3"))
        XCTAssertNil(vscode.folderURL("/a/b.CODE-WORKSPACE"))
        XCTAssertNil(vscode.folderURL("relative/path"))
    }

    /// Reading a file in a folder macOS guards would ask the user for access.
    func testWorkspaceFilesInGuardedFoldersAreNotRead() {
        let home = "/Users/dev"
        for guarded in ["/Users/dev/Desktop/w.code-workspace", "/users/dev/documents/a/b.code-workspace",
                        "/Users/dev/Downloads/x", "/Users/dev/Library/Mobile Documents/com~apple~CloudDocs/w.code-workspace",
                        "/Users/dev/Library/CloudStorage/Box-Box/w.code-workspace", "/Volumes/USB/w.code-workspace"] {
            XCTAssertTrue(EditorWindowLocator.isGuardedLocation(guarded, home: home), guarded)
        }
        for open in ["/Users/dev/workspace/sample-tools/w.code-workspace", "/Users/dev/DesktopNotes/w.code-workspace",
                     "/Users/dev/Library/Application Support/Code/Workspaces/1/workspace.json", "/tmp/w.code-workspace"] {
            XCTAssertFalse(EditorWindowLocator.isGuardedLocation(open, home: home), open)
        }
        XCTAssertNil(EditorWindowLocator.live.readWorkspaceFolders(NSHomeDirectory() + "/Desktop/never-read.code-workspace"))
    }

    func testChildProcessesAreListed() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["5"]
        try child.run()
        defer { child.terminate() }
        XCTAssertTrue(EditorWindowLocator.childPIDs(of: Int(getpid())).contains(Int(child.processIdentifier)))
        XCTAssertEqual(EditorWindowLocator.childPIDs(of: -1), [])
    }

    func testListeningPortsAreReadFromTheProcessSockets() throws {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(socket, 0)
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(bound, 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(socket, $0, &length) }
        }
        let port = Int(UInt16(bigEndian: address.sin_port))
        XCTAssertFalse(EditorWindowLocator.listeningTCPPorts(of: Int(getpid())).contains(port), "bound, not listening")
        XCTAssertEqual(Darwin.listen(socket, 1), 0)
        XCTAssertTrue(EditorWindowLocator.listeningTCPPorts(of: Int(getpid())).contains(port))
        XCTAssertEqual(EditorWindowLocator.listeningTCPPorts(of: 999_999_999), [])
        XCTAssertEqual(EditorWindowLocator.listeningTCPPorts(of: -1), [])
    }

    func testExplanationsNameTheFolderOnOneLine() {
        XCTAssertEqual(EditorWindowMiss.notListed(folder: sampleApp).explanation(editor: "VS Code"),
                       "VS Code lists no window with only SampleApp as its folder (a .code-workspace window may hold it).")
        XCTAssertEqual(EditorWindowMiss.folderName("/a/b\nc\u{7}"), "bc")
        XCTAssertEqual(EditorWindowMiss.folderName("/"), "/")
        XCTAssertEqual(EditorWindowMiss.folderName(""), "its folder")
    }

    func testOnlyVSCodeFamilyEditorsArePlaced() {
        XCTAssertEqual(EditorApp.named(bundleID: "com.microsoft.VSCode")?.dataFolder, "Code")
        XCTAssertEqual(EditorApp.named(bundleID: "com.todesktop.230313mzl4w4u92")?.name, "Cursor")
        XCTAssertNil(EditorApp.named(bundleID: "com.apple.Terminal"))
        XCTAssertNil(EditorApp.named(bundleID: nil))
    }
}

@MainActor
final class SessionRowClickTests: XCTestCase {
    /// A row from the last refresh whose process has gone, or whose PID now
    /// belongs to a process started at another time, brings nothing forward.
    func testAGoneOrReusedProcessSaysTheSessionEnded() async {
        let gone = ActiveAgent(provider: .claude, pid: 999_999_999, parentPID: 1, command: "claude",
                               elapsedSeconds: 60, observedAt: Date())
        let ended = await AgentAppActivator.focus(gone)
        XCTAssertEqual(ended, SessionRowNotice(pid: 999_999_999, text: "This session has ended."))

        let reused = ActiveAgent(provider: .claude, pid: Int(getpid()), parentPID: 1, command: "claude",
                                 elapsedSeconds: 0, observedAt: Date().addingTimeInterval(3_600))
        let notice = await AgentAppActivator.focus(reused)
        XCTAssertEqual(notice?.text, "This session has ended.")
        XCTAssertNil(notice?.appPID)
    }

    func testNoticeTextIsOneBoundedLine() {
        let notice = SessionRowNotice(pid: 1, text: "VS Code did not take it:\nThe file\tcouldn't be opened.",
                                      appPID: 2, appName: "Code\u{7}\n" + String(repeating: "x", count: 100))
        XCTAssertEqual(notice.text, "VS Code did not take it: The file couldn't be opened.")
        XCTAssertEqual(notice.appName?.count, 40)
        XCTAssertFalse(notice.appName?.contains("\n") ?? true)
    }
}

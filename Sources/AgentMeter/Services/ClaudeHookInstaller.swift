import Foundation

/// Reversible opt-in integration with Claude Code's command hooks. AgentMeter
/// owns individual hook commands, never whole matcher groups, so installing or
/// removing it preserves unrelated commands in the same group.
enum ClaudeHookInstaller {
    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json", isDirectory: false)
    }

    static var managedCLIURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentMeter/bin/agentmeter-hook", isDirectory: false)
    }

    static var bundledCLIURL: URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/agentmeter-hook", isDirectory: false)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static let executableName = "agentmeter-hook"

    /// What `refreshManagedCLI` did with the shared helper.
    enum ManagedCLIRefresh: Equatable {
        /// It already was this build's.
        case current
        /// This build's is in place now; `replacedOther` when another
        /// build's was there.
        case installed(replacedOther: Bool)
        /// Left alone: a newer AgentMeter is running and keeps its own
        /// (`HookHelperOwnership`).
        case ownedByNewerInstance
        /// No bundled copy (a bare `swift run`).
        case noBundledCopy
        case failed
    }

    @discardableResult
    static func installManagedCLI() -> URL? {
        let destination = managedCLIURL
        switch refreshManagedCLI() {
        case .current, .installed, .ownedByNewerInstance:
            // A newer copy keeps the helper there: hooks point at it, never
            // at this bundle's own copy.
            return destination
        case .noBundledCopy:
            return FileManager.default.fileExists(atPath: destination.path) ? destination : nil
        case .failed:
            // An existing helper may speak an older hook-input protocol. Do not
            // install new commands against it when refreshing from the bundled
            // copy failed.
            return nil
        }
    }

    /// Puts this build's helper at `destination` unless it is there already
    /// or another running AgentMeter owns it. Every Claude hook runs that one
    /// file, so only the newest running build may write it: any copy of the
    /// app used to install its own at launch, and a stale one opened from a
    /// backup folder silenced every task notification (`HookHelperGuard`).
    static func refreshManagedCLI(
        at destination: URL = managedCLIURL,
        from bundled: URL? = bundledCLIURL,
        ownsHelper: () -> Bool = HookHelperOwnership.thisInstanceOwnsHelper
    ) -> ManagedCLIRefresh {
        guard let bundled else { return .noBundledCopy }
        guard ownsHelper() else { return .ownedByNewerInstance }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let currentData = try? Data(contentsOf: destination)
            if let sourceData = try? Data(contentsOf: bundled), let currentData, sourceData == currentData {
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
                return .current
            }
            let temporary = destination.deletingLastPathComponent()
                .appendingPathComponent("agentmeter-hook.\(UUID().uuidString).tmp")
            defer { try? fileManager.removeItem(at: temporary) }
            try fileManager.copyItem(at: bundled, to: temporary)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
            return .installed(replacedOther: currentData != nil)
        } catch {
            return .failed
        }
    }

    static func isInstalled() -> Bool {
        guard let document = try? readSettings() else { return false }
        return hookCommands(in: document.root).contains(where: isManagedCommand)
    }

    @discardableResult
    static func install() throws -> Bool {
        guard let cliURL = installManagedCLI() ?? bundledCLIURL else {
            throw InstallError.helperUnavailable
        }
        let document = try readSettings()
        try validateHooks(in: document.root)
        let (merged, changed) = mergedHooks(
            into: document.root,
            cliQuoted: shellQuoted(cliURL.path)
        )
        guard changed else { return false }
        try writeSettings(merged, replacing: document)
        return true
    }

    @discardableResult
    static func remove() throws -> Bool {
        let document = try readSettings()
        try validateHooks(in: document.root)
        let (cleaned, changed) = removedHooks(from: document.root)
        guard changed else { return false }
        try writeSettings(cleaned, replacing: document)
        return true
    }

    static func hookEntries(cliQuoted cli: String) -> [(event: String, matcher: String, command: String)] {
        [
            ("UserPromptSubmit", "*", "\(cli) working"),
            ("PreToolUse", "*", "\(cli) working"),
            ("PostToolUse", "*", "\(cli) working"),
            ("Stop", "*", "\(cli) idle"),
            ("StopFailure", "*", "\(cli) error"),
            ("Notification", "permission_prompt", "\(cli) waiting"),
            ("Notification", "elicitation_dialog", "\(cli) waiting"),
            ("SessionEnd", "*", "\(cli) remove"),
        ]
    }

    static func mergedHooks(
        into root: [String: Any],
        cliQuoted cli: String
    ) -> (root: [String: Any], changed: Bool) {
        var result = removedHooks(from: root).root
        var hooks = result["hooks"] as? [String: Any] ?? [:]
        for entry in hookEntries(cliQuoted: cli) {
            var groups = hooks[entry.event] as? [[String: Any]] ?? []
            groups.append([
                "matcher": entry.matcher,
                "hooks": [["type": "command", "command": entry.command]],
            ])
            hooks[entry.event] = groups
        }
        result["hooks"] = hooks
        return (result, canonicalJSON(result) != canonicalJSON(root))
    }

    static func removedHooks(from root: [String: Any]) -> (root: [String: Any], changed: Bool) {
        var result = root
        guard var hooks = result["hooks"] as? [String: Any] else { return (result, false) }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let cleaned = groups.compactMap(removingManagedCommands(from:))
            if cleaned.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = cleaned
            }
        }
        if hooks.isEmpty {
            result.removeValue(forKey: "hooks")
        } else {
            result["hooks"] = hooks
        }
        return (result, canonicalJSON(result) != canonicalJSON(root))
    }

    static func isManagedCommand(_ command: String) -> Bool {
        let executable = shellFirstWord(command)
        return URL(fileURLWithPath: executable).lastPathComponent == executableName
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func shellFirstWord(_ command: String) -> String {
        var result = ""
        var quote: Character?
        var escaped = false
        for character in command.drop(while: \.isWhitespace) {
            if escaped {
                result.append(character)
                escaped = false
                continue
            }
            if quote == "'" {
                if character == "'" { quote = nil } else { result.append(character) }
            } else if quote == "\"" {
                if character == "\"" {
                    quote = nil
                } else if character == "\\" {
                    escaped = true
                } else {
                    result.append(character)
                }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == "\\" {
                escaped = true
            } else if character.isWhitespace {
                break
            } else {
                result.append(character)
            }
        }
        return result
    }

    private static func removingManagedCommands(from group: [String: Any]) -> [String: Any]? {
        guard let entries = group["hooks"] as? [[String: Any]] else { return group }
        let kept = entries.filter { entry in
            guard let command = entry["command"] as? String else { return true }
            return !isManagedCommand(command)
        }
        guard !kept.isEmpty else { return nil }
        var group = group
        group["hooks"] = kept
        return group
    }

    private static func hookCommands(in root: [String: Any]) -> [String] {
        guard let hooks = root["hooks"] as? [String: Any] else { return [] }
        return hooks.values
            .compactMap { $0 as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["command"] as? String }
    }

    private static func validateHooks(in root: [String: Any]) throws {
        guard let value = root["hooks"] else { return }
        guard let hooks = value as? [String: Any] else { throw InstallError.invalidSettings }
        for value in hooks.values {
            guard let groups = value as? [[String: Any]],
                  groups.allSatisfy({ group in
                      guard let entries = group["hooks"] else { return true }
                      return entries is [[String: Any]]
                  }) else { throw InstallError.invalidSettings }
        }
    }

    private struct SettingsDocument {
        let root: [String: Any]
        let originalData: Data?
    }

    private static func readSettings() throws -> SettingsDocument {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: settingsURL.path) else {
            return SettingsDocument(root: [:], originalData: nil)
        }
        let data = try Data(contentsOf: settingsURL)
        guard !data.isEmpty,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError.invalidSettings
        }
        return SettingsDocument(root: root, originalData: data)
    }

    private static func writeSettings(
        _ root: [String: Any],
        replacing document: SettingsDocument
    ) throws {
        let fileManager = FileManager.default
        if let originalData = document.originalData {
            guard (try? Data(contentsOf: settingsURL)) == originalData else {
                throw InstallError.settingsChanged
            }
        } else if fileManager.fileExists(atPath: settingsURL.path) {
            throw InstallError.settingsChanged
        }

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        var permissions: Any?
        if document.originalData != nil {
            permissions = try? fileManager.attributesOfItem(atPath: settingsURL.path)[.posixPermissions]
            let backup = settingsURL.deletingLastPathComponent()
                .appendingPathComponent("settings.json.agentmeter-bak-\(UUID().uuidString)")
            try fileManager.copyItem(at: settingsURL, to: backup)
        } else {
            try fileManager.createDirectory(
                at: settingsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        try data.write(to: settingsURL, options: .atomic)
        try? fileManager.setAttributes(
            [.posixPermissions: permissions ?? 0o600],
            ofItemAtPath: settingsURL.path
        )
    }

    private static func canonicalJSON(_ root: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    enum InstallError: LocalizedError {
        case helperUnavailable
        case invalidSettings
        case settingsChanged

        var errorDescription: String? {
            switch self {
            case .helperUnavailable:
                return "the bundled hook helper is unavailable"
            case .invalidSettings:
                return "the existing Claude settings file is not valid hook JSON"
            case .settingsChanged:
                return "Claude settings changed while AgentMeter was updating them; try again"
            }
        }
    }
}

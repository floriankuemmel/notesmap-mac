// Logger.swift, Privacy-preserving diagnostic logger.
//
// Goals:
//   - Write app-internal events to ~/Library/Logs/NotesMap/NotesMap.log
//   - Mirror to OSLog so Console.app shows the same entries
//   - Never log note content, titles, folder names, or paths that include
//     the user's home directory
//   - Auto-rotate: on each app launch the previous session's NotesMap.log
//     is renamed to NotesMap-<timestamp>.log; only the 5 newest archives
//     are kept
//
// Public API:
//   Log.startSession()             call once from NotesMapApp.init
//   Log.info(msg)                  general events
//   Log.warn(msg)                  unexpected but recoverable
//   Log.error(msg)                 errors
//   Log.revealLogInFinder()        Help menu action
//   Log.copyCurrentLogToClipboard()Help menu action

import Foundation
import AppKit
import OSLog

enum Log {

    // MARK: - Configuration

    private static let subsystem = "com.kuemmel.NotesMap"
    private static let osLog = OSLog(subsystem: subsystem, category: "diagnostic")
    private static let fileQueue = DispatchQueue(label: "com.kuemmel.NotesMap.logwriter")

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    // MARK: - Paths

    static var logDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Logs/NotesMap", isDirectory: true)
    }

    static var currentLogFile: URL {
        logDirectory.appendingPathComponent("NotesMap.log")
    }

    // MARK: - Session lifecycle

    /// Call once at app launch. Creates log dir, rotates prior log, writes header.
    static func startSession() {
        fileQueue.async {
            do {
                try FileManager.default.createDirectory(
                    at: logDirectory,
                    withIntermediateDirectories: true
                )
            } catch {
                os_log("Failed to create log dir: %{public}@",
                       log: osLog, type: .error, "\(error)")
                return
            }
            rotateLogs()
            writeSessionHeader()
        }
    }

    private static func rotateLogs() {
        let fm = FileManager.default
        let current = currentLogFile
        // Move existing NotesMap.log to NotesMap-<timestamp>.log
        if fm.fileExists(atPath: current.path) {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let archived = logDirectory.appendingPathComponent("NotesMap-\(stamp).log")
            _ = try? fm.moveItem(at: current, to: archived)
        }
        // Prune: keep the 5 newest archive files
        guard let contents = try? fm.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: [.creationDateKey]
        ) else { return }
        let archives = contents
            .filter { $0.lastPathComponent.hasPrefix("NotesMap-") && $0.pathExtension == "log" }
            .sorted { a, b in
                let aDate = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let bDate = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return aDate > bDate
            }
        for old in archives.dropFirst(5) {
            _ = try? fm.removeItem(at: old)
        }
    }

    private static func writeSessionHeader() {
        let pi = ProcessInfo.processInfo
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let arch: String
        #if arch(arm64)
        arch = "arm64"
        #elseif arch(x86_64)
        arch = "x86_64"
        #else
        arch = "unknown"
        #endif
        let header = """
        ═══════════════════════════════════════════════
        NotesMap diagnostic log
        Session start: \(timestampFormatter.string(from: Date()))
        App version:   \(appVersion) (build \(buildNumber))
        macOS:         \(pi.operatingSystemVersionString)
        Architecture:  \(arch)
        Locale:        \(Locale.current.identifier)
        ═══════════════════════════════════════════════

        """
        writeRawToFile(header)
    }

    // MARK: - Public log API

    static func info(
        _ message: @autoclosure () -> String,
        file: String = #fileID,
        line: Int = #line
    ) {
        write(level: "INFO", message: message(), file: file, line: line)
    }

    static func warn(
        _ message: @autoclosure () -> String,
        file: String = #fileID,
        line: Int = #line
    ) {
        write(level: "WARN", message: message(), file: file, line: line)
    }

    static func error(
        _ message: @autoclosure () -> String,
        file: String = #fileID,
        line: Int = #line
    ) {
        write(level: "ERROR", message: message(), file: file, line: line)
    }

    // MARK: - User-facing helpers

    /// Returns the full text of the current session's log file.
    static func currentLogText() -> String {
        guard let data = try? Data(contentsOf: currentLogFile),
              let text = String(data: data, encoding: .utf8) else {
            return "(log empty or unreadable)"
        }
        return text
    }

    /// Copy current session log to the system clipboard.
    @MainActor
    static func copyCurrentLogToClipboard() {
        let text = currentLogText()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Reveal NotesMap.log in Finder.
    @MainActor
    static func revealLogInFinder() {
        // Make sure the directory exists, otherwise Finder pops a dialog.
        _ = try? FileManager.default.createDirectory(
            at: logDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([currentLogFile])
    }

    // MARK: - Private write path

    private static func write(level: String, message: String, file: String, line: Int) {
        let timestamp = timestampFormatter.string(from: Date())
        let shortFile = (file as NSString).lastPathComponent
        let entry = "[\(timestamp)] [\(level)] \(shortFile):\(line)  \(message)"
        os_log("%{public}@", log: osLog, type: osType(level: level), entry)
        writeRawToFile(entry + "\n")
    }

    private static func osType(level: String) -> OSLogType {
        switch level {
        case "ERROR": return .error
        case "WARN":  return .default
        default:      return .info
        }
    }

    private static func writeRawToFile(_ text: String) {
        fileQueue.async {
            guard let data = text.data(using: .utf8) else { return }
            let url = currentLogFile
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                try? data.write(to: url)
                return
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            do {
                _ = try handle.seekToEnd()
                handle.write(data)
            } catch {
                // best-effort
            }
        }
    }
}

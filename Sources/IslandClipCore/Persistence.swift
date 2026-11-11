import Foundation
import os

/// Reads and writes small JSON files in one directory.
///
/// - Writes are atomic and the files are owner-only (0600), because clipboard
///   history can contain sensitive text.
/// - A file that can't be decoded is moved aside as `<name>.corrupt-<date>`
///   so the app can start fresh instead of crashing or losing the evidence.
public final class Persistence {
    public let directory: URL
    private let fileManager = FileManager.default
    private static let log = Logger(subsystem: "com.example.islandclip", category: "persistence")

    public init(directory: URL) {
        self.directory = directory
    }

    /// ~/Library/Application Support/IslandClip
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("IslandClip", isDirectory: true)
    }

    public func url(for fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }

    /// Returns nil when the file is missing or unreadable (after backing up a corrupt file).
    public func load<T: Decodable>(_ type: T.Type, from fileName: String) -> T? {
        let fileURL = url(for: fileName)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            Self.log.error("Could not read \(fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            backUpCorruptFile(fileURL)
            return nil
        }
    }

    public func save<T: Encodable>(_ value: T, to fileName: String) throws {
        try ensureDirectory()
        let data = try Self.encoder.encode(value)
        let fileURL = url(for: fileName)
        try data.write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func ensureDirectory() throws {
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        }
    }

    private func backUpCorruptFile(_ fileURL: URL) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(formatter.string(from: Date()))")
        do {
            try? fileManager.removeItem(at: backup)
            try fileManager.moveItem(at: fileURL, to: backup)
            Self.log.notice("Moved unreadable file to \(backup.lastPathComponent, privacy: .public)")
        } catch {
            Self.log.error("Could not back up corrupt file: \(error.localizedDescription, privacy: .public)")
        }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

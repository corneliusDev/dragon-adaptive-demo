//  CueLogStore.swift
//  Saves a run's cue log as a JSON-lines file in the app's Documents folder
//  (Documents/CueLogs/<name>.jsonl), for the post-race list and for sharing.
//  The encoding is DragonEngine's (CueLog.jsonLines); this only picks the file.

import Foundation
import DragonEngine

struct CueLogStore {
    let directory: URL

    /// Documents/CueLogs.
    static var documents: CueLogStore {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return CueLogStore(directory: docs.appendingPathComponent("CueLogs", isDirectory: true))
    }

    /// Writes `log` to `<name>.jsonl`, replacing any file of that name; returns its URL.
    @discardableResult
    func save(_ log: CueLog, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(CueLogStore.fileName(name))
        try log.jsonLines().write(to: url, options: .atomic)
        return url
    }

    func load(_ url: URL) throws -> CueLog {
        try CueLog(jsonLines: Data(contentsOf: url))
    }

    /// "designWalkthrough seed 42" at a date → "designWalkthrough-seed-42-20261018-214512.jsonl".
    static func fileName(_ name: String) -> String {
        let safe = name.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
        let base = String(safe).split(separator: "-").joined(separator: "-")
        return (base.isEmpty ? "run" : base) + ".jsonl"
    }

    /// A file name for a run that started at `date` (the app's clock, never the engine's).
    static func runName(_ label: String, at date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "\(label) \(f.string(from: date))"
    }
}

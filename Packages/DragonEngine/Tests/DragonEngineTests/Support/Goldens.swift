//  Goldens.swift
//  Test support for golden fixtures: text files under Tests/DragonEngineTests/Fixtures,
//  one "name = value" per line, compared exactly. Set DRAGON_RECORD_GOLDENS=1
//  to rewrite a fixture from the current output instead (then review the diff).

import XCTest

enum Goldens {
    static var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    static var recording: Bool { ProcessInfo.processInfo.environment["DRAGON_RECORD_GOLDENS"] == "1" }

    /// The fixture's entries, in file order.
    static func load(_ file: String) -> [(name: String, value: String)] {
        let url = directory.appendingPathComponent(file)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let r = line.range(of: " = ") else { return nil }
            return (String(line[..<r.lowerBound]), String(line[r.upperBound...]))
        }
    }

    /// Asserts `actual` matches the fixture entry for entry (or records it).
    static func check(_ actual: [(name: String, value: String)], against file: String,
                      file source: StaticString = #filePath, line: UInt = #line) {
        if recording {
            let text = actual.map { "\($0.name) = \($0.value)" }.joined(separator: "\n") + "\n"
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? text.write(to: directory.appendingPathComponent(file), atomically: true, encoding: .utf8)
            return
        }
        let expected = load(file)
        XCTAssertFalse(expected.isEmpty, "no golden fixture \(file)", file: source, line: line)
        XCTAssertEqual(actual.map(\.name), expected.map(\.name), "entries in \(file)", file: source, line: line)
        let golden = Dictionary(expected.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
        for (name, value) in actual {
            XCTAssertEqual(value, golden[name], "\(file): \(name)", file: source, line: line)
        }
    }
}

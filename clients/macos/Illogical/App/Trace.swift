//  Trace.swift
//  Opt-in lifecycle logging.
//
//  The client has no console when launched normally, and the interesting
//  failures (attach never fires, snapshot will not decode) are all lifecycle
//  ones. Set ILLOGICAL_TRACE to a path to record them.

import Foundation

enum Trace {
    private static let path = ProcessInfo.processInfo.environment["ILLOGICAL_TRACE"]

    static var isEnabled: Bool { path != nil }

    static func log(_ message: @autoclosure () -> String) {
        guard let path else { return }
        let line = "\(Date().timeIntervalSince1970) \(message())\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

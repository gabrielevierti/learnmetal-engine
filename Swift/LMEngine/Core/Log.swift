// Log.swift
// Logging with a level in front. Messages go to standard error, so they do not mix
// with anything a tool prints on standard output.

import Foundation

private func writeLog(_ level: String, _ message: String) {
    FileHandle.standardError.write(Data("[\(level)] \(message)\n".utf8))
}

public func logInfo(_ message: String) { writeLog("info", message) }
public func logWarning(_ message: String) { writeLog("warning", message) }
public func logError(_ message: String) { writeLog("error", message) }

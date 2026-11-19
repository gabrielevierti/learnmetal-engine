// ShaderSource.swift
// Reads the .metal files of a directory and joins them into one piece of source text
// that Metal can compile at run time.
//
// Metal's run-time compiler takes a string, not a folder, so it cannot follow
// #include "..." on its own. This resolves those includes (each file is included at
// most once) and adds #line directives, so that a compiler error still names the file
// and line where the mistake really is.

import Foundation

public struct ShaderSource {
    public var text = ""                // everything, ready for the compiler
    public var files: [String] = []     // each file that was read, for change detection
    public var error = ""               // empty unless a file or an include was missing

    public static func load(directory: String) -> ShaderSource {
        var out = ShaderSource()
        let root = URL(fileURLWithPath: directory).standardizedFileURL
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
            out.error = "cannot open shader directory \(directory)\n"
            return out
        }
        // A stable order, whatever the file system returns.
        let shaderFiles = names.filter { $0.hasSuffix(".metal") }.sorted()
        var included = Set<String>()
        for name in shaderFiles {
            appendFile(root: root, file: root.appendingPathComponent(name), included: &included, out: &out)
        }
        return out
    }

    private static func appendFile(root: URL, file: URL, included: inout Set<String>, out: inout ShaderSource) {
        let path = file.standardizedFileURL.path
        if !included.insert(path).inserted { return }           // already part of the text

        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            out.error += "cannot read \(path)\n"
            return
        }
        out.files.append(path)
        var name = path
        if path.hasPrefix(root.path + "/") { name = String(path.dropFirst(root.path.count + 1)) }
        out.text += "#line 1 \"\(name)\"\n"

        var lines = contents.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }              // the file ends with a newline
        let directive = "#include \""
        for (index, line) in lines.enumerated() {
            let lineNumber = index + 1
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            guard trimmed.hasPrefix(directive) else {
                out.text += line + "\n"
                continue
            }
            let rest = trimmed.dropFirst(directive.count)
            let includeName = String(rest.prefix(while: { $0 != "\"" }))
            var target = file.deletingLastPathComponent().appendingPathComponent(includeName)   // next to the including file first,
            if !FileManager.default.fileExists(atPath: target.path) {
                target = root.appendingPathComponent(includeName)                               // then relative to the shader folder
            }
            guard FileManager.default.fileExists(atPath: target.path) else {
                out.error += "\(name):\(lineNumber): cannot find \"\(includeName)\"\n"
                out.text += "\n"
                continue
            }
            appendFile(root: root, file: target, included: &included, out: &out)
            out.text += "#line \(lineNumber + 1) \"\(name)\"\n"
        }
    }
}

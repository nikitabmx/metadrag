import AppKit
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

struct OpError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Settings

enum Settings {
    private static var d: UserDefaults { .standard }

    static func register() {
        d.register(defaults: ["enabled": true, "subfolder": false, "welcomed": false])
    }

    static var enabled: Bool {
        get { d.bool(forKey: "enabled") }
        set { d.set(newValue, forKey: "enabled") }
    }
    /// Save results into a "MetaDrag" folder next to the original instead of beside it.
    static var useSubfolder: Bool {
        get { d.bool(forKey: "subfolder") }
        set { d.set(newValue, forKey: "subfolder") }
    }
    static var welcomed: Bool {
        get { d.bool(forKey: "welcomed") }
        set { d.set(newValue, forKey: "welcomed") }
    }
}

// MARK: - Formatting

enum Fmt {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    /// "2.4 MB → 610 KB" and a badge like "−75%".
    static func change(_ before: Int64, _ after: Int64) -> (String, String?) {
        let text = "\(bytes(before)) → \(bytes(after))"
        guard before > 0, after > 0 else { return (text, nil) }
        let ratio = Double(after) / Double(before)
        if ratio >= 2 { return (text, "×\(Int(ratio.rounded()))") }
        let pct = Int((ratio - 1) * 100)
        if pct <= -1 { return (text, "−\(-pct)%") }
        if pct >= 1 { return (text, "+\(pct)%") }
        return (text, nil)
    }

    static func dims(_ w: Int, _ h: Int) -> String { "\(w)×\(h)" }

    static func subject(_ files: [URL]) -> String {
        files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
    }

    static func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

    static func tildePath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = url.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}

// MARK: - Files

enum Files {
    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// Size of a file, or of everything inside a folder/package.
    static func size(_ url: URL) -> Int64 {
        if !isDirectory(url) {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        while let u = e?.nextObject() as? URL {
            total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    static func outputDir(for src: URL) throws -> URL {
        var parent = src.deletingLastPathComponent()
        if !isUserPlace(parent) {
            // dragged out of an app's temp/library area, a read-only disk image or share
            parent = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
        guard Settings.useSubfolder else { return parent }
        let dir = parent.appendingPathComponent("MetaDrag", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A folder the user browses and we may write to (not temp, not ~/Library apart from cloud drives).
    static func isUserPlace(_ dir: URL) -> Bool {
        // Foundation reports /private/tmp as /tmp and /private/var as /var, so check both spellings
        func spellings(_ path: String) -> [String] {
            if path.hasPrefix("/private/") { return [path, String(path.dropFirst("/private".count))] }
            if path.hasPrefix("/tmp/") || path == "/tmp" || path.hasPrefix("/var/") { return [path, "/private" + path] }
            return [path]
        }
        let paths = spellings(dir.path) + spellings(dir.resolvingSymlinksInPath().path)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func under(_ root: String) -> Bool { paths.contains { $0 == root || $0.hasPrefix(root + "/") } }
        let cloud = [home + "/Library/Mobile Documents", home + "/Library/CloudStorage"]
        if !cloud.contains(where: under) {
            let managed = spellings(NSTemporaryDirectory()).map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
                + ["/private/var/folders", "/var/folders", "/private/tmp", "/tmp", home + "/Library"]
            if managed.contains(where: under) { return false }
        }
        return FileManager.default.isWritableFile(atPath: dir.path)
    }

    /// Never overwrites: "photo.png", then "photo 2.png", "photo 3.png"…
    static func unique(_ dir: URL, _ base: String, _ ext: String) -> URL {
        func make(_ b: String) -> URL {
            ext.isEmpty ? dir.appendingPathComponent(b, isDirectory: true)
                        : dir.appendingPathComponent(b).appendingPathExtension(ext)
        }
        var url = make(base)
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = make("\(base) \(i)")
            i += 1
        }
        return url
    }

    static func base(_ src: URL) -> String { src.deletingPathExtension().lastPathComponent }

    static func output(for src: URL, ext: String, tag: String? = nil) throws -> URL {
        var name = base(src)
        if let tag { name += " (\(tag))" }
        return unique(try outputDir(for: src), name, ext)
    }

    static func folder(for src: URL, tag: String) throws -> URL {
        let url = unique(try outputDir(for: src), "\(base(src)) (\(tag))", "")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    static func total(_ urls: [URL]) -> Int64 { urls.reduce(0) { $0 + size($1) } }
}

// MARK: - File kinds

enum FileKind { case image, pdf, document, other }

enum Kinds {
    static let readableImageTypes: [UTType] =
        ((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []).compactMap { UTType($0) }

    static let richDocTypes: [UTType] = [
        "org.openxmlformats.wordprocessingml.document",
        "com.microsoft.word.doc",
        "org.oasis-open.opendocument.text",
        "com.apple.webarchive",
    ].compactMap { UTType($0) } + [.rtf, .rtfd, .html]

    static func type(of url: URL) -> UTType? {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
    }

    static func kind(of url: URL) -> FileKind {
        guard let t = type(of: url) else { return .other }
        if t.conforms(to: .pdf) { return .pdf }
        if t.conforms(to: .image) {
            return readableImageTypes.contains(where: { t.conforms(to: $0) }) ? .image : .other
        }
        if richDocTypes.contains(where: { t.conforms(to: $0) }) { return .document }
        if t.conforms(to: .text) && !Files.isDirectory(url) { return .document }
        return .other
    }
}

// MARK: - Thumbnails

enum Thumbs {
    static func icon(_ url: URL) -> NSImage { NSWorkspace.shared.icon(forFile: url.path) }

    /// A small preview for the ring: the picture itself for images, otherwise nil.
    static func small(_ url: URL, px: Int = 64) -> NSImage? {
        guard Kinds.kind(of: url) == .image,
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: px,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }

    static func best(_ url: URL) async -> NSImage {
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 88, height: 88),
                                               scale: 2, representationTypes: .thumbnail)
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
            return rep.nsImage
        }
        return icon(url)
    }
}

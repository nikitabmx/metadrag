import AppKit

struct DocFormat: Hashable, Sendable {
    let label: String
    let ext: String
    let hint: String
    let typeRaw: String?        // NSAttributedString.DocumentType; nil means PDF

    static let pdf  = DocFormat(label: "PDF",  ext: "pdf",  hint: "Fixed layout · A4 pages", typeRaw: nil)
    static let docx = DocFormat(label: "DOCX", ext: "docx", hint: "Microsoft Word", typeRaw: NSAttributedString.DocumentType.officeOpenXML.rawValue)
    static let odt  = DocFormat(label: "ODT",  ext: "odt",  hint: "OpenDocument · LibreOffice", typeRaw: NSAttributedString.DocumentType.openDocument.rawValue)
    static let rtf  = DocFormat(label: "RTF",  ext: "rtf",  hint: "Rich text · TextEdit", typeRaw: NSAttributedString.DocumentType.rtf.rawValue)
    static let txt  = DocFormat(label: "TXT",  ext: "txt",  hint: "Plain text · no formatting", typeRaw: NSAttributedString.DocumentType.plain.rawValue)
    static let html = DocFormat(label: "HTML", ext: "html", hint: "Web page", typeRaw: NSAttributedString.DocumentType.html.rawValue)

    static let all: [DocFormat] = [.pdf, .docx, .odt, .rtf, .txt, .html]

    static func own(_ url: URL) -> DocFormat? {
        switch url.pathExtension.lowercased() {
        case "docx": return .docx
        case "odt": return .odt
        case "rtf": return .rtf
        case "txt", "text": return .txt
        case "html", "htm": return .html
        default: return nil
        }
    }
}

enum DocOps {
    private static let richExts: Set<String> = ["docx", "doc", "odt", "rtf", "rtfd", "webarchive", "wordml", "html", "htm"]
    private static let codeExts: Set<String> = ["json", "csv", "tsv", "xml", "yml", "yaml", "toml", "ini", "log",
                                                "swift", "py", "js", "ts", "sh", "c", "h", "go", "rs", "java", "kt", "sql"]

    /// Text bigger than this isn't something to lay out as a document.
    private static let maxTextBytes: Int64 = 20_000_000

    static func read(_ url: URL) throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()
        guard Files.size(url) <= maxTextBytes else {
            throw OpError("\(url.lastPathComponent) is too large to convert (\(Fmt.bytes(Files.size(url))))")
        }
        if ext == "html" || ext == "htm" {
            // offline: remote images, CSS and fonts are never fetched (no tracking pixels, no hangs)
            let data = Data(blockRemote(try readText(url)).utf8)
            return try onMain {
                try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html,
                                                            .characterEncoding: String.Encoding.utf8.rawValue,
                                                            .timeout: 3], documentAttributes: nil)
            }
        }
        if ext == "webarchive" {
            return try onMain { try NSAttributedString(url: url, options: [.timeout: 3], documentAttributes: nil) }
        }
        if richExts.contains(ext) {
            return try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        }
        let text = try readText(url)
        let font = codeExts.contains(ext)
            ? NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
            : (NSFont(name: "Helvetica", size: 12) ?? .systemFont(ofSize: 12))
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 2
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: para])
    }

    /// WebKit-backed importers must run on the main thread.
    private static func onMain<T>(_ work: () throws -> T) throws -> T {
        if Thread.isMainThread { return try work() }
        var result: Result<T, Error>!
        DispatchQueue.main.sync { result = Result { try work() } }
        return try result.get()
    }

    /// Points every remote reference (src, href, srcset, CSS url(), protocol-relative //) at a dead scheme.
    static func blockRemote(_ html: String) -> String {
        let pattern = #"(?i)((?:src|href|srcset|poster|background|data)\s*=\s*["']?\s*|url\(\s*["']?\s*|@import\s+["'])(?:https?:)?//"#
        return html.replacingOccurrences(of: pattern, with: "$1blocked://", options: .regularExpression)
    }

    private static func readText(_ url: URL) throws -> String {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        var enc = String.Encoding.utf8
        if let s = try? String(contentsOf: url, usedEncoding: &enc) { return s }
        if let s = try? String(contentsOf: url, encoding: .windowsCP1251) { return s }
        throw OpError("Can't read the text in \(url.lastPathComponent)")
    }

    static func write(_ s: NSAttributedString, as fmt: DocFormat, to out: URL) throws {
        guard let raw = fmt.typeRaw else { return try renderPDF(s, to: out) }
        var attrs: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: NSAttributedString.DocumentType(rawValue: raw)]
        if fmt == .txt || fmt == .html { attrs[.characterEncoding] = String.Encoding.utf8.rawValue }
        let data = try s.data(from: NSRange(location: 0, length: s.length), documentAttributes: attrs)
        try data.write(to: out, options: .atomic)
    }

    /// Lays text out on A4 pages and draws them into a PDF.
    static func renderPDF(_ s: NSAttributedString, to out: URL) throws {
        let page = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        let margin: CGFloat = 56
        let storage = NSTextStorage(attributedString: s)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let size = CGSize(width: page.width - 2 * margin, height: page.height - 2 * margin)

        var containers: [NSTextContainer] = []
        while true {
            guard containers.count < 3000 else { throw OpError("Too long for a PDF here (over 3000 pages)") }
            let c = NSTextContainer(size: size)
            c.lineFragmentPadding = 0
            layout.addTextContainer(c)
            containers.append(c)
            let r = layout.glyphRange(for: c)
            if NSMaxRange(r) >= layout.numberOfGlyphs { break }
            if r.length == 0 && containers.count > 1 { throw OpError("Something in the document doesn't fit on a page") }
        }

        var media = page
        guard let pdf = CGContext(out as CFURL, mediaBox: &media, [kCGPDFContextCreator: "MetaDrag"] as CFDictionary) else {
            throw OpError("Couldn't create \(out.lastPathComponent)")
        }
        for c in containers {
            let range = layout.glyphRange(for: c)
            pdf.beginPDFPage(nil)
            pdf.saveGState()
            pdf.translateBy(x: 0, y: page.height)
            pdf.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: true)
            let origin = CGPoint(x: margin, y: margin)
            layout.drawBackground(forGlyphRange: range, at: origin)
            layout.drawGlyphs(forGlyphRange: range, at: origin)
            NSGraphicsContext.restoreGraphicsState()
            pdf.restoreGState()
            pdf.endPDFPage()
        }
        pdf.closePDF()
    }

    static func convert(_ files: [URL], to fmt: DocFormat) throws -> OpResult {
        var outs: [URL] = [], errors: [Error] = []
        for f in files {
            do {
                let s = try read(f)
                let out = try Files.output(for: f, ext: fmt.ext)
                try write(s, as: fmt, to: out)
                outs.append(out)
            } catch { errors.append(error) }
        }
        guard !outs.isEmpty else { throw errors.first ?? OpError("Nothing converted") }
        var detail = files.count == 1
            ? "\(files[0].pathExtension.uppercased()) → \(fmt.label) · \(Fmt.bytes(Files.size(outs[0])))"
            : "\(outs.count) of \(files.count) documents"
        if !errors.isEmpty { detail += " · \(errors.count) failed" }
        return OpResult(title: "Converted to \(fmt.label)", detail: detail, outputs: outs)
    }
}

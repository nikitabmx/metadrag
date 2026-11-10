import AppKit
import PDFKit
import UniformTypeIdentifiers

enum PDFOps {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw OpError("Can't open \(url.lastPathComponent)") }
        if doc.isLocked { throw OpError("\(url.lastPathComponent) is password-protected") }
        guard doc.pageCount > 0 else { throw OpError("\(url.lastPathComponent) has no pages") }
        return doc
    }

    /// Renders a page the way a viewer shows it: crop box, page rotation, white paper.
    static func render(_ page: PDFPage, scale: CGFloat) -> CGImage? {
        let box = page.bounds(for: .cropBox)
        let turned = page.rotation % 180 != 0
        let w = Int(((turned ? box.height : box.width) * scale).rounded())
        let h = Int(((turned ? box.width : box.height) * scale).rounded())
        guard let ctx = try? ImageOps.context(w, h, alpha: false) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: ctx)
        return ctx.makeImage()
    }

    // MARK: Convert

    static func toImages(_ files: [URL], _ fmt: ImageFormat) throws -> OpResult {
        var outs: [URL] = [], errors: [Error] = [], pages = 0
        for f in files {
            var made: URL?          // removed again if this file fails halfway
            do {
                let doc = try open(f)
                let n = doc.pageCount
                let dpi: [CFString: Any] = [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144]
                func save(_ i: Int, to out: URL) throws {
                    guard let page = doc.page(at: i), let img = render(page, scale: 2) else {
                        throw OpError("Couldn't render page \(i + 1)")
                    }
                    try ImageOps.write(img, to: out, type: fmt.uti, quality: fmt.quality, meta: dpi)
                }
                if n == 1 {
                    let out = try Files.output(for: f, ext: fmt.ext)
                    made = out
                    try save(0, to: out)
                    outs.append(out)
                } else {
                    let dir = try Files.folder(for: f, tag: fmt.label)
                    made = dir
                    let digits = String(n).count
                    for i in 0..<n {
                        let num = String(repeating: "0", count: digits - String(i + 1).count) + String(i + 1)
                        try save(i, to: dir.appendingPathComponent("\(Files.base(f)) \(num)").appendingPathExtension(fmt.ext))
                    }
                    outs.append(dir)
                }
                pages += n
            } catch {
                if let made { try? FileManager.default.removeItem(at: made) }
                errors.append(error)
            }
        }
        guard !outs.isEmpty else { throw errors.first ?? OpError("Nothing converted") }
        var detail = pages == 1 ? "1 page" : "\(pages) pages → \(pages) \(fmt.label) images"
        if !errors.isEmpty { detail += " · \(errors.count) failed" }
        return OpResult(title: "Converted to \(fmt.label)", detail: detail, outputs: outs)
    }

    static func toText(_ files: [URL]) throws -> OpResult {
        var outs: [URL] = [], words = 0
        for f in files {
            let doc = try open(f)
            let text = (doc.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw noText(f) }
            let out = try Files.output(for: f, ext: "txt")
            try text.write(to: out, atomically: true, encoding: .utf8)
            outs.append(out)
            words += text.split(whereSeparator: \.isWhitespace).count
        }
        return OpResult(title: "Converted to TXT", detail: "\(words) words", outputs: outs)
    }

    static func toRich(_ files: [URL], _ fmt: DocFormat) throws -> OpResult {
        var outs: [URL] = []
        for f in files {
            let doc = try open(f)
            let all = NSMutableAttributedString()
            for i in 0..<doc.pageCount {
                guard let s = doc.page(at: i)?.attributedString, s.length > 0 else { continue }
                if all.length > 0 { all.append(NSAttributedString(string: "\n\n")) }
                all.append(s)
            }
            guard all.string.contains(where: { !$0.isWhitespace }) else { throw noText(f) }
            let out = try Files.output(for: f, ext: fmt.ext)
            try DocOps.write(all, as: fmt, to: out)
            outs.append(out)
        }
        return OpResult(title: "Converted to \(fmt.label)", detail: "Text from \(Fmt.subject(files))",
                        outputs: outs)
    }

    private static func noText(_ f: URL) -> OpError {
        OpError("\(f.lastPathComponent) has no text layer. Try ⌘ Share → Text to read it with OCR")
    }

    // MARK: Tools

    static func compress(_ files: [URL]) throws -> OpResult {
        var outs: [URL] = [], before: Int64 = 0
        for f in files {
            let doc = try open(f)
            let out = try Files.output(for: f, ext: "pdf", tag: "compressed")
            guard doc.write(to: out, withOptions: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]) else {
                throw OpError("Couldn't save \(out.lastPathComponent)")
            }
            if Files.size(out) >= Files.size(f) {
                try? FileManager.default.removeItem(at: out)
                continue
            }
            outs.append(out)
            before += Files.size(f)
        }
        guard !outs.isEmpty else {
            return OpResult(title: "Already compact", detail: "There's nothing heavy left to squeeze",
                            undoable: false, symbol: "checkmark")
        }
        let (text, badge) = Fmt.change(before, Files.total(outs))
        return OpResult(title: "Compressed", detail: text, badge: badge, outputs: outs)
    }

    static func rotate(_ files: [URL]) throws -> OpResult {
        var outs: [URL] = [], pages = 0
        for f in files {
            let doc = try open(f)
            for i in 0..<doc.pageCount { if let p = doc.page(at: i) { p.rotation = (p.rotation + 90) % 360 } }
            let out = try Files.output(for: f, ext: "pdf", tag: "rotated")
            guard doc.write(to: out) else { throw OpError("Couldn't save \(out.lastPathComponent)") }
            outs.append(out)
            pages += doc.pageCount
        }
        return OpResult(title: "Rotated 90°", detail: "\(Fmt.plural(pages, "page")) turned clockwise", outputs: outs)
    }

    static func split(_ files: [URL]) throws -> OpResult {
        var outs: [URL] = [], pages = 0
        for f in files {
            let doc = try open(f)
            guard doc.pageCount > 1 else { throw OpError("\(f.lastPathComponent) has only one page") }
            let dir = try Files.folder(for: f, tag: "pages")
            let digits = String(doc.pageCount).count
            do {
                for i in 0..<doc.pageCount {
                    guard let page = doc.page(at: i)?.copy() as? PDFPage else { throw OpError("Couldn't read page \(i + 1)") }
                    let one = PDFDocument()
                    one.insert(page, at: 0)
                    let num = String(repeating: "0", count: digits - String(i + 1).count) + String(i + 1)
                    guard one.write(to: dir.appendingPathComponent("\(Files.base(f)) \(num).pdf")) else {
                        throw OpError("Couldn't save page \(i + 1)")
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: dir)    // no half-split folders left behind
                throw error
            }
            outs.append(dir)
            pages += doc.pageCount
        }
        return OpResult(title: "Split into pages", detail: "\(pages) single-page PDFs", outputs: outs)
    }

    /// PDFs and images, in the order they were dragged, into one document.
    static func merge(_ files: [URL]) throws -> OpResult {
        let merged = PDFDocument()
        for f in files {
            if Kinds.kind(of: f) == .pdf {
                let doc = try open(f)
                for i in 0..<doc.pageCount {
                    if let p = doc.page(at: i)?.copy() as? PDFPage { merged.insert(p, at: merged.pageCount) }
                }
            } else {
                let L = try ImageOps.load(f)
                let k = 72.0 / L.dpi
                let img = NSImage(cgImage: L.image, size: NSSize(width: Double(L.image.width) * k, height: Double(L.image.height) * k))
                if let p = PDFPage(image: img) { merged.insert(p, at: merged.pageCount) }
            }
        }
        guard merged.pageCount > 0 else { throw OpError("Nothing to merge") }
        let out = Files.unique(try Files.outputDir(for: files[0]), "Merged", "pdf")
        guard merged.write(to: out) else { throw OpError("Couldn't save the merged PDF") }
        return OpResult(title: "Merged", detail: "\(files.count) files → \(Fmt.plural(merged.pageCount, "page"))",
                        outputs: [out])
    }

    static func lock(_ files: [URL], password: String) throws -> OpResult {
        var outs: [URL] = []
        for f in files {
            let doc = try open(f)
            let out = try Files.output(for: f, ext: "pdf", tag: "locked")
            guard doc.write(to: out, withOptions: [.userPasswordOption: password, .ownerPasswordOption: password]) else {
                throw OpError("Couldn't save \(out.lastPathComponent)")
            }
            guard let check = PDFDocument(url: out), check.isEncrypted, check.isLocked else {
                try? FileManager.default.removeItem(at: out)
                throw OpError("Encryption didn't stick for \(f.lastPathComponent)")
            }
            outs.append(out)
        }
        return OpResult(title: "Locked", detail: "Password required to open · the original is untouched",
                        outputs: outs)
    }
}

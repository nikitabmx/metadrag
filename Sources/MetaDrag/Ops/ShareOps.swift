import AppKit
import PDFKit
import UniformTypeIdentifiers
import Vision

/// Share actions that need the UI (system share sheets, clipboard).
@MainActor enum ShareOps {
    static func send(_ name: NSSharingService.Name, _ files: [URL], label: String) {
        guard let service = NSSharingService(named: name), service.canPerform(withItems: files) else {
            ToastCenter.shared.failure("\(label) isn't available", "Set it up on this Mac first")
            return
        }
        NSApp.activate()
        service.perform(withItems: files)
    }

    static func copy(_ files: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if files.count == 1, Kinds.kind(of: files[0]) == .image,
           let t = Kinds.type(of: files[0]), t.conforms(to: .png) || t.conforms(to: .jpeg),
           Files.size(files[0]) < 15_000_000, let data = try? Data(contentsOf: files[0]) {
            // the file itself plus its pixels, so it pastes into Finder *and* into chats/docs
            let item = NSPasteboardItem()
            item.setString(files[0].absoluteString, forType: .fileURL)
            item.setData(data, forType: NSPasteboard.PasteboardType(t.identifier))
            pb.writeObjects([item])
        } else {
            pb.writeObjects(files as [NSURL])
        }
        ToastCenter.shared.info("Copied", "\(Fmt.subject(files)) · paste it anywhere", symbol: "doc.on.clipboard")
    }

    static func copyPath(_ files: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(files.map(\.path).joined(separator: "\n"), forType: .string)
        ToastCenter.shared.info(files.count == 1 ? "Path copied" : "\(files.count) paths copied",
                                Fmt.tildePath(files[0]), symbol: "link")
    }
}

/// Share actions that do real work off the main thread.
enum ShareWork {
    static func zip(_ files: [URL]) throws -> OpResult {
        let fm = FileManager.default
        let dir = try Files.outputDir(for: files[0])
        var source = files[0]
        var keepParent = true
        var staging: URL?
        var out: URL
        if files.count == 1 {
            out = Files.unique(dir, files[0].lastPathComponent, "zip")
            if out.path.hasPrefix(source.path + "/") {
                // zipping the output folder itself: put the archive beside it, not inside it
                out = Files.unique(source.deletingLastPathComponent(), source.lastPathComponent, "zip")
            }
        } else {
            // clones into a private staging folder on the same volume: instant, no extra disk space,
            // and files from different folders (or with the same name) are fine
            out = Files.unique(dir, "Archive", "zip")
            let stage = (try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: dir, create: true))
                ?? fm.temporaryDirectory.appendingPathComponent("MetaDrag-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: stage, withIntermediateDirectories: true)
            staging = stage
            for f in files {
                let ext = f.pathExtension
                let target = Files.unique(stage, ext.isEmpty ? f.lastPathComponent : Files.base(f), ext)
                try fm.copyItem(at: f, to: target)
            }
            source = stage
            keepParent = false
        }
        defer { if let staging { try? fm.removeItem(at: staging) } }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        // a clean, portable zip (no __MACOSX/._ junk for whoever opens it on Windows/Linux);
        // absolute paths only, so a file named like a flag can't be read as one
        p.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noacl", "--noqtn"]
            + (keepParent ? ["--keepParent"] : []) + [source.path, out.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0, fm.fileExists(atPath: out.path) else {
            try? fm.removeItem(at: out)
            throw OpError("Couldn't create the archive")
        }
        let before = Files.total(files), after = Files.size(out)
        let (sizeText, badge) = Fmt.change(before, after)
        return OpResult(title: "Zipped", detail: "\(Fmt.subject(files)) · \(sizeText)",
                        badge: after < before ? badge : nil, outputs: [out])
    }

    static func ocr(_ files: [URL]) throws -> OpResult {
        var chunks: [String] = []
        for f in files {
            if Kinds.kind(of: f) == .pdf {
                let doc = try PDFOps.open(f)
                for i in 0..<doc.pageCount {
                    guard let page = doc.page(at: i) else { continue }
                    if let s = page.string, s.contains(where: { !$0.isWhitespace }) {
                        chunks.append(s)
                    } else if let img = PDFOps.render(page, scale: 2) {
                        chunks.append(try recognize(img))
                    }
                }
            } else {
                chunks.append(try recognize(ImageOps.load(f).image))
            }
        }
        let text = chunks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard !text.isEmpty else { throw OpError("No text found in \(Fmt.subject(files))") }
        DispatchQueue.main.sync {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        let words = text.split(whereSeparator: \.isWhitespace).count
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let preview = first.count > 44 ? first.prefix(44) + "…" : Substring(first)
        return OpResult(title: "Text copied", detail: "\(words) words · “\(preview)”", undoable: false,
                        symbol: "text.viewfinder")
    }

    static func recognize(_ img: CGImage) throws -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.automaticallyDetectsLanguage = true
        if let supported = try? req.supportedRecognitionLanguages() {
            let wanted = ["en-US", "ru-RU", "uk-UA", "de-DE", "fr-FR", "es-ES", "it-IT", "pt-BR"]
            req.recognitionLanguages = wanted.filter(supported.contains)
        }
        try VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
        return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

import AppKit

/// One slice of the ring.
struct Action: Identifiable {
    let id: String
    let title: String
    let symbol: String?       // SF Symbol; nil shows the title big (format names)
    let hint: String
    let perform: @MainActor ([URL]) -> Void
}

/// What a finished operation reports back to its notification.
struct OpResult: Sendable {
    var title: String
    var detail: String
    var badge: String? = nil
    var outputs: [URL] = []
    var undoable = true
    var symbol: String? = nil
}

/// Runs work off the main thread behind a "working…" notification.
@MainActor enum Runner {
    /// Test hook (`--run`): called with the outcome as well as showing it.
    static var onFinish: ((Result<OpResult, Error>) -> Void)?

    /// One job at a time: two quick drops of the same file can't race for the same output name.
    private static let jobs = DispatchQueue(label: "metadrag.jobs", qos: .userInitiated)

    static func run(_ working: String, _ files: [URL], _ work: @escaping @Sendable () throws -> OpResult) {
        let toast = ToastCenter.shared.begin(working, Fmt.subject(files))
        let started = Date()
        jobs.async {
            let result = Result { try work() }
            // let the spinner register for a beat so instant jobs don't just flicker
            let wait = max(0, 0.45 - Date().timeIntervalSince(started))
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                MainActor.assumeIsolated {
                    switch result {
                    case .success(let r): ToastCenter.shared.finish(toast, r)
                    case .failure(let e): ToastCenter.shared.fail(toast, e.localizedDescription)
                    }
                    onFinish?(result)
                }
            }
        }
    }
}

// MARK: - What each ring offers

@MainActor enum Catalog {
    static func actions(for files: [URL], mode: Mode) -> [Action] {
        guard !files.isEmpty else { return [] }
        let kinds = files.map(Kinds.kind)
        func all(_ k: FileKind) -> Bool { kinds.allSatisfy { $0 == k } }
        let visual = kinds.allSatisfy { $0 == .image || $0 == .pdf }

        switch mode {
        case .convert:
            if all(.image) { return imageConvert(files) }
            if all(.pdf) { return pdfConvert() }
            if all(.document) { return docConvert(files) }
            return []
        case .tools:
            if all(.image) { return imageTools(files) }
            if all(.pdf) { return pdfTools(files) }
            if visual { return [merge] }
            return []
        case .share:
            return share(ocr: visual)
        }
    }

    private static func job(_ id: String, _ title: String, _ symbol: String?, _ hint: String,
                            _ working: String, _ work: @escaping @Sendable ([URL]) throws -> OpResult) -> Action {
        Action(id: id, title: title, symbol: symbol, hint: hint) { files in
            Runner.run(working, files) { try work(files) }
        }
    }

    private static func imageConvert(_ files: [URL]) -> [Action] {
        let own = Set(files.compactMap { Kinds.type(of: $0).flatMap(ImageFormat.matching) })
        return ImageFormat.available
            .filter { !(own.count == 1 && own.contains($0)) }
            .map { fmt in
                let hint = (fmt == .pdf && files.count > 1) ? "Combine \(files.count) images into one PDF" : fmt.hint
                return job("img-\(fmt.ext)", fmt.label, nil, hint, "Converting to \(fmt.label)…") {
                    try ImageOps.convert($0, to: fmt)
                }
            }
    }

    private static func pdfConvert() -> [Action] {
        let images: [Action] = [ImageFormat.jpg, .png, .heic].map { fmt in
            job("pdf-\(fmt.ext)", fmt.label, nil, "Every page as an image", "Rendering pages…") {
                try PDFOps.toImages($0, fmt)
            }
        }
        return images + [
            job("pdf-txt", "TXT", nil, "Just the text", "Extracting text…") { try PDFOps.toText($0) },
            job("pdf-docx", "DOCX", nil, "Editable in Word", "Converting to DOCX…") { try PDFOps.toRich($0, .docx) },
            job("pdf-rtf", "RTF", nil, "Editable in TextEdit", "Converting to RTF…") { try PDFOps.toRich($0, .rtf) },
        ]
    }

    private static func docConvert(_ files: [URL]) -> [Action] {
        let own = Set(files.compactMap(DocFormat.own))
        return DocFormat.all
            .filter { !(own.count == 1 && own.contains($0)) }
            .map { fmt in
                job("doc-\(fmt.ext)", fmt.label, nil, fmt.hint, "Converting to \(fmt.label)…") {
                    try DocOps.convert($0, to: fmt)
                }
            }
    }

    private static func imageTools(_ files: [URL]) -> [Action] {
        [
            job("compress", "Compress", "arrow.down.right.and.arrow.up.left", "Smaller file · same look", "Compressing…") { try ImageOps.compress($0) },
            job("resize", "Resize", "square.resize.down", "Half the width and height", "Resizing…") { try ImageOps.resize($0) },
            job("rotate", "Rotate", "rotate.right", "90° clockwise", "Rotating…") { try ImageOps.rotate($0) },
            job("flip", "Flip", "arrow.left.and.right.righttriangle.left.righttriangle.right", "Mirror left ↔ right", "Flipping…") { try ImageOps.flip($0) },
            job("mono", "B&W", "circle.lefthalf.filled", "Black & white", "Removing colour…") { try ImageOps.mono($0) },
            job("cutout", "Cutout", "wand.and.sparkles", "Remove the background", "Cutting out…") { try ImageOps.cutout($0) },
            job("clean", "Clean", "location.slash", "Strip location, camera, date", "Removing metadata…") { try ImageOps.clean($0) },
        ]
    }

    private static func pdfTools(_ files: [URL]) -> [Action] {
        var list = [
            job("pdf-compress", "Compress", "arrow.down.right.and.arrow.up.left", "Lighter images inside", "Compressing…") { try PDFOps.compress($0) },
            job("pdf-rotate", "Rotate", "rotate.right", "Every page 90° clockwise", "Rotating…") { try PDFOps.rotate($0) },
            job("pdf-split", "Split", "square.split.2x1", "One PDF per page", "Splitting…") { try PDFOps.split($0) },
        ]
        if files.count > 1 { list.append(merge) }
        list.append(Action(id: "pdf-lock", title: "Lock", symbol: "lock", hint: "Require a password to open") { files in
            guard let password = Prompt.newPassword() else { return }
            Runner.run("Locking…", files) { try PDFOps.lock(files, password: password) }
        })
        return list
    }

    private static var merge: Action {
        job("merge", "Merge", "square.on.square", "One PDF, in drag order", "Merging…") { try PDFOps.merge($0) }
    }

    private static func share(ocr: Bool) -> [Action] {
        var list = [
            Action(id: "airdrop", title: "AirDrop", symbol: "dot.radiowaves.left.and.right", hint: "Send to a nearby device") {
                ShareOps.send(.sendViaAirDrop, $0, label: "AirDrop")
            },
            Action(id: "messages", title: "Messages", symbol: "message", hint: "Attach to a message") {
                ShareOps.send(.composeMessage, $0, label: "Messages")
            },
            Action(id: "mail", title: "Mail", symbol: "envelope", hint: "Attach to a new email") {
                ShareOps.send(.composeEmail, $0, label: "Mail")
            },
            job("zip", "Zip", "doc.zipper", "Compressed archive", "Zipping…") { try ShareWork.zip($0) },
            Action(id: "copy", title: "Copy", symbol: "doc.on.clipboard", hint: "Paste it anywhere") { ShareOps.copy($0) },
            Action(id: "path", title: "Path", symbol: "link", hint: "Copy the full path") { ShareOps.copyPath($0) },
        ]
        if ocr {
            list.append(job("ocr", "Text", "text.viewfinder", "Read the text · copy it", "Reading text…") { try ShareWork.ocr($0) })
        }
        return list
    }
}

// MARK: - Password prompt

@MainActor enum Prompt {
    static func newPassword() -> String? {
        NSApp.activate()
        var message = "Anyone opening the PDF will need it. A forgotten password can't be recovered."
        while true {
            let alert = NSAlert()
            alert.messageText = "Lock with a password"
            alert.informativeText = message
            let first = NSSecureTextField(frame: NSRect(x: 0, y: 32, width: 260, height: 24))
            first.placeholderString = "Password"
            let second = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            second.placeholderString = "Repeat password"
            let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
            box.addSubview(first)
            box.addSubview(second)
            alert.accessoryView = box
            alert.addButton(withTitle: "Lock")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = first
            first.nextKeyView = second
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let pw = first.stringValue
            if pw.isEmpty {
                message = "The password can't be empty."
            } else if pw != second.stringValue {
                message = "The passwords didn't match. Try again."
            } else {
                return pw
            }
        }
    }
}

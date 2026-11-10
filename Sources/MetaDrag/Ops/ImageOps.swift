import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import Vision

struct ImageFormat: Hashable, Sendable {
    let label: String
    let ext: String
    let uti: UTType
    let hint: String
    let alpha: Bool
    let quality: Double?

    static let png  = ImageFormat(label: "PNG",  ext: "png",  uti: .png,  hint: "Lossless · keeps transparency", alpha: true,  quality: nil)
    static let jpg  = ImageFormat(label: "JPG",  ext: "jpg",  uti: .jpeg, hint: "Opens anywhere · small",        alpha: false, quality: 0.9)
    static let heic = ImageFormat(label: "HEIC", ext: "heic", uti: .heic, hint: "Half the size of JPG",          alpha: true,  quality: 0.85)
    static let avif = ImageFormat(label: "AVIF", ext: "avif", uti: UTType("public.avif") ?? .image,
                                  hint: "Smallest · modern web", alpha: true, quality: 0.8)
    static let tiff = ImageFormat(label: "TIFF", ext: "tiff", uti: .tiff, hint: "Lossless · for print",          alpha: true,  quality: nil)
    static let gif  = ImageFormat(label: "GIF",  ext: "gif",  uti: .gif,  hint: "256 colours · legacy",          alpha: true,  quality: nil)
    static let bmp  = ImageFormat(label: "BMP",  ext: "bmp",  uti: .bmp,  hint: "Uncompressed bitmap",           alpha: false, quality: nil)
    static let ico  = ImageFormat(label: "ICO",  ext: "ico",  uti: .ico,  hint: "Windows icon · 256 px",         alpha: true,  quality: nil)
    static let pdf  = ImageFormat(label: "PDF",  ext: "pdf",  uti: .pdf,  hint: "One page per image",            alpha: false, quality: nil)

    static let all: [ImageFormat] = [.png, .jpg, .heic, .avif, .tiff, .gif, .bmp, .ico, .pdf]

    private static let writable = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
    static let available: [ImageFormat] = all.filter { $0 == .pdf || writable.contains($0.uti.identifier) }

    static func matching(_ t: UTType) -> ImageFormat? {
        if t.conforms(to: .heif) { return .heic }
        return all.first { t.conforms(to: $0.uti) }
    }

    /// The format to write when editing a file in place: its own, or PNG if we can't write that.
    static func sameAs(_ typeID: String) -> ImageFormat {
        guard let t = UTType(typeID), let f = matching(t), f != .pdf, available.contains(f) else { return .png }
        return f
    }
}

enum ImageOps {
    struct Loaded {
        let image: CGImage
        let meta: [CFString: Any]
        let typeID: String
        let dpi: Double
    }

    // MARK: Decode / encode

    /// Decodes an image upright (camera rotation applied) with its metadata.
    static func load(_ url: URL) throws -> Loaded {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 else {
            throw OpError("Can't read \(url.lastPathComponent)")
        }
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard w * h <= maxPixels else { throw OpError("\(url.lastPathComponent) is too large (\(Fmt.dims(w, h)))") }

        var image: CGImage?
        if w > 0, h > 0 {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(w, h),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }
        if image == nil, w == 0 || h == 0 { image = CGImageSourceCreateImageAtIndex(src, 0, nil) }
        guard let image else { throw OpError("Can't decode \(url.lastPathComponent)") }
        guard image.width * image.height <= maxPixels else {
            throw OpError("\(url.lastPathComponent) is too large (\(Fmt.dims(image.width, image.height)))")
        }

        var meta: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if let v = props[key] { meta[key] = v }
        }
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1     // pixels are already upright
            meta[kCGImagePropertyTIFFDictionary] = tiff
        }
        let dpi = (props[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 72
        return Loaded(image: image, meta: meta, typeID: (CGImageSourceGetType(src) as String?) ?? "", dpi: dpi)
    }

    static func write(_ img: CGImage, to url: URL, type: UTType, quality: Double? = nil,
                      meta: [CFString: Any] = [:]) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw OpError("Can't write \(type.preferredFilenameExtension?.uppercased() ?? "this format")")
        }
        var p = meta
        p[kCGImagePropertyOrientation] = 1
        if let quality { p[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, img, p as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: url)
            throw OpError("Couldn't save \(url.lastPathComponent)")
        }
    }

    // MARK: Pixel helpers

    /// ~120 MP (≈480 MB per RGBA copy): bigger inputs get a clear error instead of exhausting memory.
    static let maxPixels = 120_000_000

    static func context(_ w: Int, _ h: Int, alpha: Bool, like img: CGImage? = nil) throws -> CGContext {
        guard w > 0, h > 0, w * h <= maxPixels else { throw OpError("Image is too large (\(Fmt.dims(w, h)))") }
        let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        if let cs = img?.colorSpace, cs.model == .rgb,
           let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: info) {
            return ctx
        }
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: info) else {
            throw OpError("Not enough memory for a \(Fmt.dims(w, h)) image")
        }
        return ctx
    }

    static func hasAlpha(_ img: CGImage) -> Bool {
        switch img.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// True when some pixels are actually see-through (not just an unused alpha channel).
    static func isTransparent(_ img: CGImage) -> Bool {
        guard hasAlpha(img) else { return false }
        let side = 96
        guard let ctx = try? context(side, side, alpha: true) else { return true }
        ctx.interpolationQuality = .low
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return true }
        let bytes = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * side)
        for y in 0..<side {
            for x in 0..<side where bytes[y * ctx.bytesPerRow + x * 4 + 3] < 250 { return true }
        }
        return false
    }

    /// Composites onto white (formats without transparency would otherwise turn it black).
    static func flattened(_ img: CGImage) throws -> CGImage {
        guard hasAlpha(img) else { return img }
        let ctx = try context(img.width, img.height, alpha: false, like: img)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage() ?? img
    }

    static func scaled(_ img: CGImage, to w: Int, _ h: Int) throws -> CGImage {
        let ctx = try context(max(1, w), max(1, h), alpha: hasAlpha(img), like: img)
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? img
    }

    static func fit(_ img: CGImage, maxSide: Int) throws -> CGImage {
        let longest = max(img.width, img.height)
        guard longest > maxSide else { return img }
        let k = Double(maxSide) / Double(longest)
        return try scaled(img, to: max(1, Int((Double(img.width) * k).rounded())), max(1, Int((Double(img.height) * k).rounded())))
    }

    /// Centres the image on a transparent square canvas (icons must be square).
    static func squared(_ img: CGImage) throws -> CGImage {
        let side = max(img.width, img.height)
        guard img.width != img.height else { return img }
        let ctx = try context(side, side, alpha: true, like: img)
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: (side - img.width) / 2, y: (side - img.height) / 2, width: img.width, height: img.height))
        return ctx.makeImage() ?? img
    }

    static func transformed(_ img: CGImage, swapSides: Bool, _ t: CGAffineTransform) throws -> CGImage {
        let w = swapSides ? img.height : img.width, h = swapSides ? img.width : img.height
        let ctx = try context(w, h, alpha: hasAlpha(img), like: img)
        ctx.interpolationQuality = .high
        ctx.concatenate(t)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage() ?? img
    }

    static func rotatedClockwise(_ img: CGImage) throws -> CGImage {
        // (x, y) → (y, W − x) in Quartz's y-up space is a quarter turn clockwise on screen
        try transformed(img, swapSides: true, CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: CGFloat(img.width)))
    }

    static func mirrored(_ img: CGImage) throws -> CGImage {
        try transformed(img, swapSides: false, CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: CGFloat(img.width), ty: 0))
    }

    private static let ci = CIContext(options: [.cacheIntermediates: false])

    static func monochrome(_ img: CGImage) throws -> CGImage {
        let f = CIFilter.photoEffectMono()
        f.inputImage = CIImage(cgImage: img)
        guard let out = f.outputImage, let cg = ci.createCGImage(out, from: out.extent) else {
            throw OpError("Couldn't make it black & white")
        }
        return cg
    }

    // MARK: Convert

    static func convert(_ files: [URL], to fmt: ImageFormat) throws -> OpResult {
        if fmt == .pdf { return try toPDF(files) }
        var outs: [URL] = [], errors: [Error] = [], before: Int64 = 0
        var from = ""
        for f in files {
            do {
                let L = try load(f)
                var img = L.image
                if !fmt.alpha { img = try flattened(img) }
                if fmt == .ico { img = try squared(fit(img, maxSide: 256)) }
                let out = try Files.output(for: f, ext: fmt.ext)
                try write(img, to: out, type: fmt.uti, quality: fmt.quality,
                          meta: (fmt == .ico || fmt == .bmp || fmt == .gif) ? [:] : L.meta)
                outs.append(out)
                before += Files.size(f)
                from = UTType(L.typeID).flatMap(ImageFormat.matching)?.label ?? f.pathExtension.uppercased()
            } catch { errors.append(error) }
        }
        return try summarize(outs, files: files, errors: errors, before: before,
                             title: files.count == 1 ? "Converted to \(fmt.label)" : "\(outs.count) images → \(fmt.label)",
                             prefix: files.count == 1 ? "\(from) → \(fmt.label) · " : "")
    }

    /// One PDF; several images become one page each, in the order they were dragged.
    static func toPDF(_ files: [URL]) throws -> OpResult {
        let out: URL = files.count == 1
            ? try Files.output(for: files[0], ext: "pdf")
            : Files.unique(try Files.outputDir(for: files[0]), "Combined", "pdf")
        guard let pdf = CGContext(out as CFURL, mediaBox: nil, [kCGPDFContextCreator: "MetaDrag"] as CFDictionary) else {
            throw OpError("Couldn't create the PDF")
        }
        var pages = 0
        for f in files {
            guard let L = try? load(f), let page = jpegBacked(L.image) ?? (try? flattened(L.image)) else { continue }
            let k = 72.0 / L.dpi
            var box = CGRect(x: 0, y: 0, width: Double(L.image.width) * k, height: Double(L.image.height) * k)
            pdf.beginPage(mediaBox: &box)
            pdf.draw(page, in: box)
            pdf.endPage()
            pages += 1
        }
        pdf.closePDF()
        guard pages > 0 else {
            try? FileManager.default.removeItem(at: out)
            throw OpError("None of the images could be read")
        }
        let (sizeText, _) = Fmt.change(Files.total(files), Files.size(out))
        return OpResult(title: pages == 1 ? "Converted to PDF" : "Combined into one PDF",
                        detail: "\(Fmt.plural(pages, "page")) · \(sizeText)", outputs: [out])
    }

    /// Quartz embeds JPEG-backed images as-is, which keeps photo PDFs small.
    private static func jpegBacked(_ img: CGImage) -> CGImage? {
        guard !isTransparent(img), let opaque = try? flattened(img) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, opaque, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest), let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: Tools

    static func compress(_ files: [URL]) throws -> OpResult {
        var outs: [URL] = [], errors: [Error] = [], before: Int64 = 0, skipped = 0
        var note = ""
        for f in files {
            do {
                let L = try load(f)
                var img = try fit(L.image, maxSide: 4096)
                let t = UTType(L.typeID)
                let (fmt, q): (ImageFormat, Double) = {
                    if t?.conforms(to: .jpeg) == true { return (.jpg, 0.62) }
                    if t?.conforms(to: .heif) == true { return (.heic, 0.55) }
                    if t?.identifier == ImageFormat.avif.uti.identifier { return (.avif, 0.55) }
                    if isTransparent(img) { return (.heic, 0.6) }     // keeps the see-through parts
                    return (.jpg, 0.72)
                }()
                if !fmt.alpha { img = try flattened(img) }
                let out = try Files.output(for: f, ext: fmt.ext, tag: "compressed")
                try write(img, to: out, type: fmt.uti, quality: q, meta: L.meta)
                if Files.size(out) >= Files.size(f) {
                    try? FileManager.default.removeItem(at: out)
                    skipped += 1
                    continue
                }
                outs.append(out)
                before += Files.size(f)
                let from = t.flatMap(ImageFormat.matching)?.label ?? ""
                note = from == fmt.label ? "quality \(Int(q * 100))" : "\(from) → \(fmt.label)"
            } catch { errors.append(error) }
        }
        if outs.isEmpty && errors.isEmpty {
            return OpResult(title: "Already compact", detail: "It can't get smaller without looking worse",
                            undoable: false, symbol: "checkmark")
        }
        var r = try summarize(outs, files: files, errors: errors, before: before, title: "Compressed", prefix: "")
        if files.count == 1 { r.detail += " · \(note)" }
        if skipped > 0 { r.detail += " · \(skipped) already compact" }
        return r
    }

    static func resize(_ files: [URL], factor: Double = 0.5) throws -> OpResult {
        var last = ""
        return try remake(files, title: "Resized to \(Int(factor * 100))%", tag: nil) { L in
            let w = max(1, Int((Double(L.image.width) * factor).rounded()))
            let h = max(1, Int((Double(L.image.height) * factor).rounded()))
            last = "\(Fmt.dims(L.image.width, L.image.height)) → \(Fmt.dims(w, h))"
            return (try scaled(L.image, to: w, h), Fmt.dims(w, h))
        } detail: { last }
    }

    static func rotate(_ files: [URL]) throws -> OpResult {
        try remake(files, title: "Rotated 90°", tag: "rotated") { (try rotatedClockwise($0.image), nil) } detail: { "Turned clockwise" }
    }

    static func flip(_ files: [URL]) throws -> OpResult {
        try remake(files, title: "Flipped", tag: "flipped") { (try mirrored($0.image), nil) } detail: { "Mirrored left ↔ right" }
    }

    static func mono(_ files: [URL]) throws -> OpResult {
        try remake(files, title: "Black & white", tag: "B&W") { (try monochrome($0.image), nil) } detail: { "Colour removed" }
    }

    /// Re-encodes each image in its own format after `edit`. `edit` may return a custom tag.
    private static func remake(_ files: [URL], title: String, tag: String?,
                               _ edit: (Loaded) throws -> (CGImage, String?),
                               detail: () -> String) throws -> OpResult {
        var outs: [URL] = [], errors: [Error] = []
        for f in files {
            do {
                let L = try load(f)
                let (img, customTag) = try edit(L)
                let fmt = ImageFormat.sameAs(L.typeID)
                let out = try Files.output(for: f, ext: fmt.ext, tag: customTag ?? tag)
                try write(fmt.alpha ? img : flattened(img), to: out, type: fmt.uti,
                          quality: fmt.quality.map { max($0, 0.92) }, meta: L.meta)
                outs.append(out)
            } catch { errors.append(error) }
        }
        guard !outs.isEmpty else { throw errors.first ?? OpError("Nothing changed") }
        var d = files.count == 1 ? detail() : "\(outs.count) of \(files.count) images"
        if !errors.isEmpty { d += " · \(errors.count) failed" }
        return OpResult(title: title, detail: d, outputs: outs)
    }

    /// Lifts the subject off its background with Vision and saves a transparent PNG.
    static func cutout(_ files: [URL]) throws -> OpResult {
        var outs: [URL] = [], errors: [Error] = []
        for f in files {
            do {
                let L = try load(f)
                let req = VNGenerateForegroundInstanceMaskRequest()
                let handler = VNImageRequestHandler(cgImage: L.image, options: [:])
                try handler.perform([req])
                guard let obs = req.results?.first, !obs.allInstances.isEmpty else {
                    throw OpError("No clear subject in \(f.lastPathComponent)")
                }
                let buffer = try obs.generateMaskedImage(ofInstances: obs.allInstances, from: handler,
                                                         croppedToInstancesExtent: false)
                let ciImage = CIImage(cvPixelBuffer: buffer)
                guard let cg = ci.createCGImage(ciImage, from: ciImage.extent, format: .RGBA8,
                                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
                    throw OpError("Couldn't cut out the subject")
                }
                let out = try Files.output(for: f, ext: "png", tag: "cutout")
                try write(cg, to: out, type: .png)
                outs.append(out)
            } catch { errors.append(error) }
        }
        guard !outs.isEmpty else { throw errors.first ?? OpError("No subject found") }
        return OpResult(title: "Background removed",
                        detail: files.count == 1 ? "Transparent PNG" : "\(outs.count) of \(files.count) images",
                        outputs: outs)
    }

    /// Removes location, camera and date info. Lossless when ImageIO can rewrite the
    /// metadata in place, otherwise a high-quality re-encode, and verified either way.
    static func clean(_ files: [URL]) throws -> OpResult {
        var outs: [URL] = [], errors: [Error] = [], removed = Set<String>()
        for f in files {
            do {
                guard let src = CGImageSourceCreateWithURL(f as CFURL, nil), let type = CGImageSourceGetType(src) else {
                    throw OpError("Can't read \(f.lastPathComponent)")
                }
                let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
                let found = personalInfo(source: src)
                guard !found.isEmpty else { continue }
                removed.formUnion(found)

                let fmt = ImageFormat.sameAs(type as String)
                let out = try Files.output(for: f, ext: fmt.ext, tag: "clean")
                var ok = false
                if fmt.uti.identifier == type as String,
                   let dest = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) {
                    let opts: [CFString: Any] = [
                        kCGImageDestinationMetadata: CGImageMetadataCreateMutable(),
                        kCGImageDestinationMergeMetadata: false,
                        kCGImageMetadataShouldExcludeXMP: true,
                        kCGImageMetadataShouldExcludeGPS: true,
                        kCGImageDestinationOrientation: props[kCGImagePropertyOrientation] as? Int ?? 1,
                    ]
                    ok = CGImageDestinationCopyImageSource(dest, src, opts as CFDictionary, nil)
                }
                if !ok || !personalInfo(at: out).isEmpty {
                    let L = try load(f)
                    try write(fmt.alpha ? L.image : flattened(L.image), to: out, type: fmt.uti,
                              quality: fmt.quality.map { max($0, 0.95) })
                }
                guard personalInfo(at: out).isEmpty else {
                    try? FileManager.default.removeItem(at: out)
                    throw OpError("Couldn't strip the metadata from \(f.lastPathComponent)")
                }
                outs.append(out)
            } catch { errors.append(error) }
        }
        if outs.isEmpty && errors.isEmpty {
            return OpResult(title: "Already clean", detail: "No location, camera or date info found",
                            undoable: false, symbol: "checkmark.shield")
        }
        guard !outs.isEmpty else { throw errors.first! }
        let order = ["location", "camera", "date", "author", "embedded tags"]
        let list = order.filter(removed.contains).joined(separator: ", ")
        return OpResult(title: "Metadata removed", detail: "Removed \(list)", outputs: outs)
    }

    static func personalInfo(at url: URL) -> Set<String> {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        return personalInfo(source: src)
    }

    /// What identifying data an image carries: EXIF/TIFF/GPS/IPTC properties plus XMP
    /// (face regions, keywords, edit history, IPTC location…) that the property dictionaries miss.
    static func personalInfo(source src: CGImageSource) -> Set<String> {
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        var s = Set<String>()
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any], !gps.isEmpty { s.insert("location") }
        let makerNotes = [kCGImagePropertyMakerAppleDictionary, kCGImagePropertyMakerCanonDictionary,
                          kCGImagePropertyMakerNikonDictionary, kCGImagePropertyMakerFujiDictionary,
                          kCGImagePropertyMakerOlympusDictionary, kCGImagePropertyMakerPentaxDictionary,
                          kCGImagePropertyMakerMinoltaDictionary]
        if tiff[kCGImagePropertyTIFFMake] != nil || tiff[kCGImagePropertyTIFFModel] != nil
            || exif[kCGImagePropertyExifLensModel] != nil || exif[kCGImagePropertyExifBodySerialNumber] != nil
            || exif[kCGImagePropertyExifLensSerialNumber] != nil || exif[kCGImagePropertyExifCameraOwnerName] != nil
            || makerNotes.contains(where: { props[$0] != nil }) {
            s.insert("camera")
        }
        if exif[kCGImagePropertyExifDateTimeOriginal] != nil || exif[kCGImagePropertyExifDateTimeDigitized] != nil
            || tiff[kCGImagePropertyTIFFDateTime] != nil {
            s.insert("date")
        }
        if tiff[kCGImagePropertyTIFFArtist] != nil || tiff[kCGImagePropertyTIFFCopyright] != nil
            || tiff[kCGImagePropertyTIFFImageDescription] != nil || exif[kCGImagePropertyExifUserComment] != nil
            || props[kCGImagePropertyIPTCDictionary] != nil {
            s.insert("author")
        }
        if s.isEmpty, let xmp = CGImageSourceCopyMetadataAtIndex(src, 0, nil), hasPersonalXMP(xmp) {
            s.insert("embedded tags")
        }
        return s
    }

    private static let personalXMPNamespaces: Set<String> = [
        "Iptc4xmpCore", "Iptc4xmpExt", "xmpMM", "xmpRights", "plus", "mwg-rs", "MP", "MPRI", "MPReg",
        "MicrosoftPhoto", "lr", "aux", "photoshop",
    ]
    private static let personalXMPNames: Set<String> = [
        "make", "model", "lensmodel", "lens", "serialnumber", "bodyserialnumber", "lensserialnumber",
        "cameraownername", "datetimeoriginal", "datetimedigitized", "createdate", "modifydate", "metadatadate",
        "artist", "copyright", "usercomment", "imagedescription", "creator", "rights", "creatortool",
        "city", "state", "country", "location", "documentid", "instanceid", "originaldocumentid",
    ]

    private static func hasPersonalXMP(_ meta: CGImageMetadata) -> Bool {
        var found = false
        CGImageMetadataEnumerateTagsUsingBlock(meta, nil, [kCGImageMetadataEnumerateRecursively: true] as CFDictionary) { _, tag in
            let prefix = (CGImageMetadataTagCopyPrefix(tag) as String?) ?? ""
            let name = ((CGImageMetadataTagCopyName(tag) as String?) ?? "").lowercased()
            if name.hasPrefix("gps") || personalXMPNames.contains(name) || personalXMPNamespaces.contains(prefix)
                || (prefix == "dc" && name != "format") {
                found = true
                return false
            }
            return true
        }
        return found
    }

    // MARK: Shared summary

    static func summarize(_ outs: [URL], files: [URL], errors: [Error], before: Int64,
                          title: String, prefix: String) throws -> OpResult {
        guard !outs.isEmpty else { throw errors.first ?? OpError("Nothing was saved") }
        let (sizeText, badge) = Fmt.change(before, Files.total(outs))
        var detail = prefix + sizeText
        if !errors.isEmpty { detail += " · \(errors.count) failed" }
        return OpResult(title: title, detail: detail, badge: badge, outputs: outs)
    }
}

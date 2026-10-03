import Foundation

/// PNG/JPEGのヘッダと構造をFoundationだけで検査する（全OS共通・決定的）。
/// 画素のデコードは行わない。macOSではCopyfitMacのImageIO検査が追加でデコード可否を確認する。
public enum ImageInspector {
    public static func inspect(data: Data, fileExtension: String, limits: Limits = Limits()) throws -> AssetFacts {
        if data.count > limits.maxFileBytes {
            throw CopyfitError.limitExceeded(
                "ファイルサイズ \(data.count) bytes が上限 \(limits.maxFileBytes) bytes を超えています")
        }
        let bytes = [UInt8](data)
        var facts: AssetFacts
        if bytes.starts(with: pngSignature) {
            facts = inspectPNG(bytes)
        } else if bytes.count >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF {
            facts = inspectJPEG(bytes)
        } else {
            facts = AssetFacts(pixelWidth: 0, pixelHeight: 0, format: .unknown, hasAlphaChannel: false,
                               integrityProblem: "PNG/JPEGとして認識できません（先頭バイト不一致）")
        }
        let ext = fileExtension.lowercased()
        switch facts.format {
        case .png: facts.extensionMismatch = ext != "png"
        case .jpeg: facts.extensionMismatch = !(ext == "jpg" || ext == "jpeg")
        case .unknown: facts.extensionMismatch = false
        }
        facts.fileSizeBytes = data.count
        facts.fileHash = SHA256.hex(data)
        let pixels = facts.pixelWidth * facts.pixelHeight
        if pixels > limits.maxPixels {
            throw CopyfitError.limitExceeded(
                "画素数 \(facts.pixelWidth)×\(facts.pixelHeight) = \(pixels) が上限 \(limits.maxPixels) を超えています")
        }
        return facts
    }

    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    static func readU32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    static func readU16(_ b: [UInt8], _ i: Int, bigEndian: Bool = true) -> Int {
        bigEndian ? Int(b[i]) << 8 | Int(b[i + 1]) : Int(b[i + 1]) << 8 | Int(b[i])
    }

    // MARK: PNG

    static func inspectPNG(_ b: [UInt8]) -> AssetFacts {
        var width = 0, height = 0, colorType = -1, bitDepth = 0
        var hasTRNS = false, sawIDAT = false, sawIEND = false
        var problem: String?
        var colorInfo: [String] = []
        var i = 8
        var first = true
        while i + 12 <= b.count {
            let length = Int(readU32(b, i))
            let typeBytes = Array(b[(i + 4)..<(i + 8)])
            let type = String(bytes: typeBytes, encoding: .ascii) ?? "????"
            guard length >= 0, i + 12 + length <= b.count else {
                problem = "chunk \(type) が途中で切れています（ファイル破損/途中までのコピーの可能性）"
                break
            }
            let crcStored = readU32(b, i + 8 + length)
            let crc = CRC32.checksum(b[(i + 4)..<(i + 8 + length)])
            if crc != crcStored {
                problem = "chunk \(type) のCRCが一致しません（ファイル破損の可能性）"
                break
            }
            if first && type != "IHDR" {
                problem = "最初のchunkがIHDRではありません"
                break
            }
            first = false
            let d = i + 8
            switch type {
            case "IHDR":
                if length >= 13 {
                    width = Int(readU32(b, d))
                    height = Int(readU32(b, d + 4))
                    bitDepth = Int(b[d + 8])
                    colorType = Int(b[d + 9])
                }
            case "tRNS": hasTRNS = true
            case "IDAT": sawIDAT = true
            case "sRGB": colorInfo.append("sRGB")
            case "iCCP": colorInfo.append("ICC")
            case "IEND": sawIEND = true
            default: break
            }
            i += 12 + length
            if sawIEND { break }
        }
        if problem == nil && (!sawIDAT || !sawIEND) {
            problem = !sawIDAT ? "画像データ(IDAT)がありません" : "終端(IEND)がありません（途中で切れている可能性）"
        }
        let colorName: String
        switch colorType {
        case 0: colorName = "grayscale"
        case 2: colorName = "RGB"
        case 3: colorName = "indexed"
        case 4: colorName = "grayscale+alpha"
        case 6: colorName = "RGBA"
        default: colorName = "unknown"
        }
        let alpha = colorType == 4 || colorType == 6 || hasTRNS
        let desc = ([colorName, "\(bitDepth)bit"] + (hasTRNS ? ["tRNS"] : []) + colorInfo).joined(separator: " ")
        return AssetFacts(pixelWidth: width, pixelHeight: height, format: .png, hasAlphaChannel: alpha,
                          orientation: 1, colorDescription: desc, integrityProblem: problem)
    }

    // MARK: JPEG

    static func inspectJPEG(_ b: [UInt8]) -> AssetFacts {
        var width = 0, height = 0, components = 0
        var orientation = 1
        var problem: String?
        var i = 2
        var sawSOS = false
        scan: while i + 4 <= b.count {
            guard b[i] == 0xFF else {
                problem = "JPEG markerの位置が不正です（offset \(i)）"
                break
            }
            let marker = b[i + 1]
            if marker == 0xFF { i += 1; continue }
            if marker == 0xD8 || (0xD0...0xD7).contains(marker) || marker == 0x01 { i += 2; continue }
            let length = readU16(b, i + 2)
            guard length >= 2, i + 2 + length <= b.count else {
                problem = "JPEG segmentが途中で切れています"
                break
            }
            let seg = i + 4
            switch marker {
            case 0xC0...0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF:
                if length >= 8 {
                    height = readU16(b, seg + 1)
                    width = readU16(b, seg + 3)
                    components = Int(b[seg + 5])
                }
            case 0xE1:
                if let o = exifOrientation(b, start: seg, length: length - 2) { orientation = o }
            case 0xDA:
                sawSOS = true
                break scan
            default:
                break
            }
            i += 2 + length
        }
        if problem == nil {
            if !sawSOS || width == 0 {
                problem = "フレーム情報(SOF)または画像データ(SOS)が見つかりません"
            } else if !hasEOI(b) {
                problem = "終端(EOI)がありません（途中で切れている可能性）"
            }
        }
        let (w, h) = CoordinateConversion.orientedSize(width: width, height: height, exifOrientation: orientation)
        let colorName = components == 1 ? "grayscale" : components == 3 ? "YCbCr" : components == 4 ? "CMYK" : "unknown"
        return AssetFacts(pixelWidth: w, pixelHeight: h, format: .jpeg, hasAlphaChannel: false,
                          orientation: orientation, colorDescription: colorName, integrityProblem: problem)
    }

    static func hasEOI(_ b: [UInt8]) -> Bool {
        // 末尾のpadding（0x00等）を許容して、最後の数十byte内にFFD9があるか確認する。
        let tail = max(0, b.count - 64)
        var j = b.count - 2
        while j >= tail {
            if b[j] == 0xFF && b[j + 1] == 0xD9 { return true }
            j -= 1
        }
        return false
    }

    static func exifOrientation(_ b: [UInt8], start: Int, length: Int) -> Int? {
        let end = start + length
        guard length > 14, end <= b.count,
              Array(b[start..<(start + 6)]) == [0x45, 0x78, 0x69, 0x66, 0, 0] else { return nil }
        let tiff = start + 6
        let little: Bool
        if b[tiff] == 0x49 && b[tiff + 1] == 0x49 { little = true }
        else if b[tiff] == 0x4D && b[tiff + 1] == 0x4D { little = false }
        else { return nil }
        func u16(_ p: Int) -> Int? { p + 2 <= end ? readU16(b, p, bigEndian: !little) : nil }
        func u32(_ p: Int) -> Int? {
            guard p + 4 <= end else { return nil }
            return little
                ? Int(b[p]) | Int(b[p + 1]) << 8 | Int(b[p + 2]) << 16 | Int(b[p + 3]) << 24
                : Int(readU32(b, p))
        }
        guard let ifdOffset = u32(tiff + 4), let count = u16(tiff + ifdOffset) else { return nil }
        for n in 0..<count {
            let entry = tiff + ifdOffset + 2 + n * 12
            guard let tag = u16(entry) else { return nil }
            if tag == 0x0112, let value = u16(entry + 8), (1...8).contains(value) { return value }
        }
        return nil
    }
}

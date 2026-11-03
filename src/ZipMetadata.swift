import Foundation

/// Checks ZIP filename metadata without extracting or recompressing file contents.
/// A repair changes only general-purpose flag bit 11 in existing headers.
enum ZipMetadata {
    struct Inspection {
        let entryCount: Int
        let needsUTF8Repair: Bool
        let entryNames: [String]
    }

    enum Failure: LocalizedError {
        case invalid(String)
        case io(String, Error)

        var errorDescription: String? {
            switch self {
            case .invalid(let message):
                return message
            case .io(let operation, let error):
                return "\(operation)：\(error.localizedDescription)"
            }
        }
    }

    static func inspect(_ url: URL) throws -> Inspection {
        let source = try regularFile(url)
        do {
            let data = try Data(contentsOf: source, options: .mappedIfSafe)
            return try plan(for: data).inspection
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure.io("读取压缩包失败", error)
        }
    }

    /// Copies the archive first; the source is never opened for writing.
    /// The destination must not already exist.
    @discardableResult
    static func repairUTF8Copy(source: URL, destination: URL) throws -> Inspection {
        let actualSource = try regularFile(source)
        guard destination.isFileURL else {
            throw Failure.invalid("输出位置必须是本地文件。")
        }
        let actualDestination = destination.standardizedFileURL
        guard actualSource != actualDestination.resolvingSymlinksInPath() else {
            throw Failure.invalid("输出文件不能与原压缩包相同。")
        }
        let manager = FileManager.default
        guard !manager.fileExists(atPath: actualDestination.path) else {
            throw Failure.invalid("输出文件已存在，请换一个文件名。")
        }

        // Validate before creating an output, then inspect the copy independently.
        _ = try inspect(actualSource)
        var createdCopy = false
        do {
            try manager.copyItem(at: actualSource, to: actualDestination)
            createdCopy = true
            let copiedPlan: Plan = try {
                let copiedData = try Data(contentsOf: actualDestination, options: .mappedIfSafe)
                return try plan(for: copiedData)
            }()
            if !copiedPlan.patches.isEmpty {
                let handle = try FileHandle(forWritingTo: actualDestination)
                defer { try? handle.close() }
                for patch in copiedPlan.patches {
                    try handle.seek(toOffset: UInt64(patch.offset))
                    try handle.write(contentsOf: Data([
                        UInt8(truncatingIfNeeded: patch.flags),
                        UInt8(truncatingIfNeeded: patch.flags >> 8)
                    ]))
                }
                try handle.synchronize()
            }
            let result = try inspect(actualDestination)
            guard result.entryCount == copiedPlan.inspection.entryCount,
                  !result.needsUTF8Repair else {
                throw Failure.invalid("修补后的压缩包未通过校验，已取消输出。")
            }
            return result
        } catch {
            if createdCopy { try? manager.removeItem(at: actualDestination) }
            if let failure = error as? Failure { throw failure }
            throw Failure.io("生成兼容压缩包失败", error)
        }
    }

    private static let utf8Flag: UInt16 = 0x0800
    private static let encryptionFlags: UInt16 = 0x2041 // Traditional, strong, or masked headers.

    private struct Patch {
        let offset: Int
        let flags: UInt16
    }

    private struct Plan {
        let inspection: Inspection
        let patches: [Patch]
    }

    private struct Extra {
        let identifier: UInt16
        let payload: Range<Int>
    }

    private struct ZIP64Values {
        var uncompressed: UInt64?
        var compressed: UInt64?
        var localOffset: UInt64?
        var disk: UInt32?
    }

    private struct Footer {
        let count: Int
        let centralStart: Int
        let centralEnd: Int
    }

    private struct Reader {
        let data: Data

        func contains(_ start: Int, _ length: Int, limit: Int? = nil) -> Bool {
            let endLimit = limit ?? data.count
            return start >= 0 && length >= 0 && endLimit >= 0
                && endLimit <= data.count && start <= endLimit
                && length <= endLimit - start
        }

        func range(_ start: Int, _ length: Int, limit: Int? = nil) throws -> Range<Int> {
            guard contains(start, length, limit: limit) else {
                throw Failure.invalid("压缩包的结构或文件边界无效，无法安全修补。")
            }
            return start..<(start + length)
        }

        func u16(_ offset: Int) throws -> UInt16 {
            _ = try range(offset, 2)
            return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
        }

        func u32(_ offset: Int) throws -> UInt32 {
            _ = try range(offset, 4)
            var value: UInt32 = 0
            for byte in 0..<4 { value |= UInt32(data[offset + byte]) << (byte * 8) }
            return value
        }

        func u64(_ offset: Int) throws -> UInt64 {
            _ = try range(offset, 8)
            var value: UInt64 = 0
            for byte in 0..<8 { value |= UInt64(data[offset + byte]) << (byte * 8) }
            return value
        }

        func bytes(_ range: Range<Int>) -> Data {
            data.subdata(in: range)
        }
    }

    private static func regularFile(_ url: URL) throws -> URL {
        guard url.isFileURL else {
            throw Failure.invalid("压缩包必须是本地文件。")
        }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        do {
            let values = try resolved.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                throw Failure.invalid("请选择一个 ZIP 文件，不能直接修补文件夹。")
            }
            return resolved
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.io("无法访问压缩包", error)
        }
    }

    private static func integer(_ value: UInt64) throws -> Int {
        guard value <= UInt64(Int.max) else {
            throw Failure.invalid("压缩包中的长度或偏移超过本机可处理的范围。")
        }
        return Int(value)
    }

    private static func footer(_ reader: Reader) throws -> Footer {
        guard reader.data.count >= 22 else {
            throw Failure.invalid("这不是一个完整的 ZIP 压缩包。")
        }
        let lastCandidate = reader.data.count - 22
        let firstCandidate = max(0, lastCandidate - 65_535)
        var eocd: Int?
        for offset in stride(from: lastCandidate, through: firstCandidate, by: -1) {
            if try reader.u32(offset) == 0x06054b50,
               try reader.u16(offset + 20) == reader.data.count - offset - 22 {
                eocd = offset
                break
            }
        }
        guard let eocd else {
            throw Failure.invalid("找不到完整的 ZIP 目录尾记录；文件可能未下载完整或已损坏。")
        }

        let disk = try reader.u16(eocd + 4)
        let centralDisk = try reader.u16(eocd + 6)
        let diskCount = try reader.u16(eocd + 8)
        let totalCount = try reader.u16(eocd + 10)
        let size32 = try reader.u32(eocd + 12)
        let offset32 = try reader.u32(eocd + 16)
        let needsZIP64 = disk == .max || centralDisk == .max
            || diskCount == .max || totalCount == .max
            || size32 == .max || offset32 == .max
        let locator = eocd - 20
        let hasLocator = try locator >= 0 && reader.u32(locator) == 0x07064b50
        if needsZIP64 && !hasLocator {
            throw Failure.invalid("ZIP64 目录信息缺失，无法安全修补。")
        }

        var count = UInt64(totalCount)
        var centralSize = UInt64(size32)
        var centralOffset = UInt64(offset32)
        var metadataStart = eocd
        if hasLocator {
            guard try reader.u32(locator + 4) == 0,
                  try reader.u32(locator + 16) == 1 else {
                throw Failure.invalid("暂不支持分卷或跨磁盘 ZIP，请先合并成一个完整压缩包。")
            }
            let zip64Offset = try integer(reader.u64(locator + 8))
            _ = try reader.range(zip64Offset, 56, limit: locator)
            guard try reader.u32(zip64Offset) == 0x06064b50 else {
                throw Failure.invalid("ZIP64 目录尾记录无效。")
            }
            let recordSize = try reader.u64(zip64Offset + 4)
            guard recordSize >= 44 else {
                throw Failure.invalid("ZIP64 目录尾记录长度无效。")
            }
            let recordLength = try integer(recordSize)
            guard recordLength <= locator - zip64Offset - 12,
                  zip64Offset + 12 + recordLength == locator else {
                throw Failure.invalid("ZIP64 目录尾记录的边界无效。")
            }
            let zip64Disk = try reader.u32(zip64Offset + 16)
            let zip64CentralDisk = try reader.u32(zip64Offset + 20)
            let zip64DiskCount = try reader.u64(zip64Offset + 24)
            let zip64TotalCount = try reader.u64(zip64Offset + 32)
            let zip64Size = try reader.u64(zip64Offset + 40)
            let zip64CentralOffset = try reader.u64(zip64Offset + 48)
            guard zip64Disk == 0, zip64CentralDisk == 0,
                  zip64DiskCount == zip64TotalCount,
                  (disk == 0 || disk == .max),
                  (centralDisk == 0 || centralDisk == .max) else {
                throw Failure.invalid("暂不支持分卷或跨磁盘 ZIP，请先合并成一个完整压缩包。")
            }
            guard (diskCount == .max || UInt64(diskCount) == zip64DiskCount),
                  (totalCount == .max || UInt64(totalCount) == zip64TotalCount),
                  (size32 == .max || UInt64(size32) == zip64Size),
                  (offset32 == .max || UInt64(offset32) == zip64CentralOffset) else {
                throw Failure.invalid("ZIP 与 ZIP64 目录记录不一致，无法安全修补。")
            }
            count = zip64TotalCount
            centralSize = zip64Size
            centralOffset = zip64CentralOffset
            metadataStart = zip64Offset
        } else {
            guard disk == 0, centralDisk == 0, diskCount == totalCount else {
                throw Failure.invalid("暂不支持分卷或跨磁盘 ZIP，请先合并成一个完整压缩包。")
            }
        }
        let centralStart = try integer(centralOffset)
        let size = try integer(centralSize)
        let centralRange = try reader.range(centralStart, size, limit: metadataStart)
        let entryCount = try integer(count)
        guard entryCount <= size / 46 else {
            throw Failure.invalid("压缩包的项目数量与目录长度不一致。")
        }
        return Footer(count: entryCount, centralStart: centralStart, centralEnd: centralRange.upperBound)
    }

    private static func extras(_ reader: Reader, range: Range<Int>) throws -> [Extra] {
        var result: [Extra] = []
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            _ = try reader.range(cursor, 4, limit: range.upperBound)
            let identifier = try reader.u16(cursor)
            let size = Int(try reader.u16(cursor + 2))
            let payload = try reader.range(cursor + 4, size, limit: range.upperBound)
            result.append(Extra(identifier: identifier, payload: payload))
            cursor = payload.upperBound
        }
        return result
    }

    @discardableResult
    private static func validateUTF8(_ reader: Reader, range: Range<Int>, label: String,
                                     canBeEmpty: Bool) throws -> String {
        let data = reader.bytes(range)
        guard (canBeEmpty || !data.isEmpty), !data.contains(0),
              let text = String(data: data, encoding: .utf8) else {
            throw Failure.invalid("\(label)不是有效的 UTF-8 文本，无法仅靠补编码标记安全修复。")
        }
        return text
    }

    private static func validateUnicodeExtra(_ reader: Reader, fields: [Extra],
                                            identifier: UInt16, raw: Range<Int>, label: String) throws {
        for field in fields where field.identifier == identifier {
            guard field.payload.count >= 5,
                  reader.data[field.payload.lowerBound] == 1 else {
                throw Failure.invalid("\(label)的 Unicode 扩展无效，无法安全修补。")
            }
            // Even a stale CRC must not hide a second, different UTF-8 name.
            // Some extractors interpret this field more loosely than the ZIP specification.
            let unicodeRange = (field.payload.lowerBound + 5)..<field.payload.upperBound
            let unicode = reader.bytes(unicodeRange)
            guard !unicode.contains(0), String(data: unicode, encoding: .utf8) != nil else {
                throw Failure.invalid("\(label)的 Unicode 扩展不是有效的 UTF-8 文本。")
            }
            guard unicode == reader.bytes(raw) else {
                throw Failure.invalid("\(label)同时包含两个不同的 Unicode 名称或注释，无法安全修补。")
            }
        }
    }

    private static func zip64Values(_ reader: Reader, fields: [Extra],
                                    uncompressed: Bool, compressed: Bool,
                                    offset: Bool = false, disk: Bool = false) throws -> ZIP64Values {
        let matches = fields.filter { $0.identifier == 0x0001 }
        guard matches.count <= 1 else {
            throw Failure.invalid("压缩包包含重复的 ZIP64 扩展，无法安全修补。")
        }
        guard uncompressed || compressed || offset || disk else { return ZIP64Values() }
        guard let field = matches.first else {
            throw Failure.invalid("压缩包的 ZIP64 文件长度或偏移信息缺失。")
        }
        var cursor = field.payload.lowerBound
        func next64() throws -> UInt64 {
            _ = try reader.range(cursor, 8, limit: field.payload.upperBound)
            let value = try reader.u64(cursor)
            cursor += 8
            return value
        }
        var result = ZIP64Values()
        if uncompressed { result.uncompressed = try next64() }
        if compressed { result.compressed = try next64() }
        if offset { result.localOffset = try next64() }
        if disk {
            _ = try reader.range(cursor, 4, limit: field.payload.upperBound)
            result.disk = try reader.u32(cursor)
        }
        return result
    }

    private static func descriptorEnd(_ reader: Reader, at offset: Int, limit: Int,
                                      crc: UInt32, compressed: UInt64, uncompressed: UInt64,
                                      preferZIP64: Bool) throws -> Int {
        let firstIsSignature = try reader.contains(offset, 4, limit: limit)
            && reader.u32(offset) == 0x08074b50
        let prefixes = firstIsSignature ? [4, 0] : [0]
        let widths = preferZIP64 ? [8, 4] : [4, 8]
        for prefix in prefixes {
            for width in widths {
                let length = prefix + 4 + 2 * width
                guard reader.contains(offset, length, limit: limit) else { continue }
                let start = offset + prefix
                guard try reader.u32(start) == crc else { continue }
                if width == 4 {
                    guard compressed <= UInt64(UInt32.max), uncompressed <= UInt64(UInt32.max),
                          try UInt64(reader.u32(start + 4)) == compressed,
                          try UInt64(reader.u32(start + 8)) == uncompressed else { continue }
                } else {
                    guard try reader.u64(start + 4) == compressed,
                          try reader.u64(start + 12) == uncompressed else { continue }
                }
                return offset + length
            }
        }
        throw Failure.invalid("压缩包的数据描述记录不完整或与目录不一致，无法安全修补。")
    }

    private static func plan(for data: Data) throws -> Plan {
        let reader = Reader(data: data)
        let footer = try footer(reader)
        var cursor = footer.centralStart
        var patches: [Patch] = []
        var localRanges: [Range<Int>] = []
        var entryNames: [String] = []
        for entry in 0..<footer.count {
            let label = "第 \(entry + 1) 项"
            _ = try reader.range(cursor, 46, limit: footer.centralEnd)
            guard try reader.u32(cursor) == 0x02014b50 else {
                throw Failure.invalid("\(label)的 ZIP 目录头无效。")
            }
            let centralFlags = try reader.u16(cursor + 8)
            guard centralFlags & encryptionFlags == 0 else {
                throw Failure.invalid("压缩包包含加密文件，请先解密后再生成兼容包。")
            }
            let method = try reader.u16(cursor + 10)
            let crc = try reader.u32(cursor + 16)
            let compressed32 = try reader.u32(cursor + 20)
            let uncompressed32 = try reader.u32(cursor + 24)
            let nameLength = Int(try reader.u16(cursor + 28))
            let extraLength = Int(try reader.u16(cursor + 30))
            let commentLength = Int(try reader.u16(cursor + 32))
            let disk16 = try reader.u16(cursor + 34)
            let localOffset32 = try reader.u32(cursor + 42)
            let centralName = try reader.range(cursor + 46, nameLength, limit: footer.centralEnd)
            let centralExtra = try reader.range(centralName.upperBound, extraLength, limit: footer.centralEnd)
            let comment = try reader.range(centralExtra.upperBound, commentLength, limit: footer.centralEnd)
            let centralFields = try extras(reader, range: centralExtra)
            entryNames.append(try validateUTF8(reader, range: centralName,
                                              label: "\(label)的文件名", canBeEmpty: false))
            try validateUTF8(reader, range: comment, label: "\(label)的注释", canBeEmpty: true)
            try validateUnicodeExtra(reader, fields: centralFields, identifier: 0x7075,
                                     raw: centralName, label: "\(label)的文件名")
            try validateUnicodeExtra(reader, fields: centralFields, identifier: 0x6375,
                                     raw: comment, label: "\(label)的注释")
            let central64 = try zip64Values(reader, fields: centralFields,
                                           uncompressed: uncompressed32 == .max,
                                           compressed: compressed32 == .max,
                                           offset: localOffset32 == .max, disk: disk16 == .max)
            let compressed = central64.compressed ?? UInt64(compressed32)
            let uncompressed = central64.uncompressed ?? UInt64(uncompressed32)
            let localOffset = try integer(central64.localOffset ?? UInt64(localOffset32))
            let disk = central64.disk ?? UInt32(disk16)
            guard disk == 0 else {
                throw Failure.invalid("暂不支持分卷或跨磁盘 ZIP，请先合并成一个完整压缩包。")
            }

            _ = try reader.range(localOffset, 30, limit: footer.centralStart)
            guard try reader.u32(localOffset) == 0x04034b50 else {
                throw Failure.invalid("\(label)的本地 ZIP 文件头无效。")
            }
            let localFlags = try reader.u16(localOffset + 6)
            guard localFlags & encryptionFlags == 0 else {
                throw Failure.invalid("压缩包包含加密文件，请先解密后再生成兼容包。")
            }
            guard (localFlags & ~utf8Flag) == (centralFlags & ~utf8Flag),
                  try reader.u16(localOffset + 8) == method else {
                throw Failure.invalid("\(label)的本地文件头与 ZIP 目录不一致。")
            }
            let localCRC = try reader.u32(localOffset + 14)
            let localCompressed32 = try reader.u32(localOffset + 18)
            let localUncompressed32 = try reader.u32(localOffset + 22)
            let localNameLength = Int(try reader.u16(localOffset + 26))
            let localExtraLength = Int(try reader.u16(localOffset + 28))
            let localName = try reader.range(localOffset + 30, localNameLength, limit: footer.centralStart)
            let localExtra = try reader.range(localName.upperBound, localExtraLength, limit: footer.centralStart)
            guard reader.bytes(localName) == reader.bytes(centralName) else {
                throw Failure.invalid("\(label)的本地文件名与 ZIP 目录中的文件名不同，无法安全修补。")
            }
            let localFields = try extras(reader, range: localExtra)
            try validateUnicodeExtra(reader, fields: localFields, identifier: 0x7075,
                                     raw: localName, label: "\(label)的本地文件名")
            let local64 = try zip64Values(reader, fields: localFields,
                                         uncompressed: localUncompressed32 == .max,
                                         compressed: localCompressed32 == .max)
            let localCompressed = local64.compressed ?? UInt64(localCompressed32)
            let localUncompressed = local64.uncompressed ?? UInt64(localUncompressed32)
            let hasDescriptor = localFlags & 0x0008 != 0
            if hasDescriptor {
                guard (localCRC == 0 || localCRC == crc),
                      (localCompressed == 0 || localCompressed == compressed),
                      (localUncompressed == 0 || localUncompressed == uncompressed) else {
                    throw Failure.invalid("\(label)的数据长度与 ZIP 目录不一致。")
                }
            } else {
                guard localCRC == crc, localCompressed == compressed,
                      localUncompressed == uncompressed else {
                    throw Failure.invalid("\(label)的数据长度或校验值与 ZIP 目录不一致。")
                }
            }
            let content = try reader.range(localExtra.upperBound, integer(compressed), limit: footer.centralStart)
            var entryEnd = content.upperBound
            if hasDescriptor {
                entryEnd = try descriptorEnd(reader, at: entryEnd, limit: footer.centralStart,
                                             crc: crc, compressed: compressed, uncompressed: uncompressed,
                                             preferZIP64: localCompressed32 == .max || localUncompressed32 == .max
                                                || compressed32 == .max || uncompressed32 == .max)
            }
            localRanges.append(localOffset..<entryEnd)
            // ASCII names/comments have identical bytes in UTF-8 and CP437.
            // System tar may legitimately leave bit 11 unset for those entries.
            let requiresUTF8Flag = reader.bytes(centralName).contains { $0 >= 0x80 }
                || reader.bytes(comment).contains { $0 >= 0x80 }
            if requiresUTF8Flag && localFlags & utf8Flag == 0 {
                patches.append(Patch(offset: localOffset + 6, flags: localFlags | utf8Flag))
            }
            if requiresUTF8Flag && centralFlags & utf8Flag == 0 {
                patches.append(Patch(offset: cursor + 8, flags: centralFlags | utf8Flag))
            }
            cursor = comment.upperBound
        }
        if cursor != footer.centralEnd {
            if reader.contains(cursor, 6, limit: footer.centralEnd),
               try reader.u32(cursor) == 0x05054b50 {
                throw Failure.invalid("压缩包包含目录数字签名，改编码标记会使签名失效，请重新打包。")
            }
            throw Failure.invalid("ZIP 目录中包含额外或不完整的记录，无法安全修补。")
        }
        localRanges.sort { $0.lowerBound < $1.lowerBound }
        for index in 1..<max(1, localRanges.count) {
            guard localRanges[index].lowerBound >= localRanges[index - 1].upperBound else {
                throw Failure.invalid("压缩包中的文件数据相互重叠，无法安全修补。")
            }
        }
        return Plan(inspection: Inspection(entryCount: footer.count, needsUTF8Repair: !patches.isEmpty,
                                           entryNames: entryNames),
                    patches: patches)
    }
}

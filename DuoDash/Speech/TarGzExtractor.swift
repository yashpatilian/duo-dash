import Foundation
import Compression

/// Unpacks a .tar.gz (the Kokoro model release) on iOS, which has no `tar`.
/// Streams: gzip → raw DEFLATE (Compression framework) → a small ustar/pax reader.
/// Rejects absolute paths and `..`, skips AppleDouble `._` files and links.
enum TarGzExtractor {
    enum Failure: Error, Equatable {
        case notGzip
        case corrupt
        case unsafePath(String)
    }

    static func extract(_ archive: URL, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        var reader = TarReader(destination: destination)
        var header = try input.read(upToCount: 10) ?? Data()
        guard header.count == 10, header[0] == 0x1f, header[1] == 0x8b, header[2] == 8 else { throw Failure.notGzip }
        let flags = header[3]
        // Optional gzip header fields: FEXTRA, FNAME, FCOMMENT, FHCRC.
        var pending = Data()
        func readByte() throws -> UInt8 {
            if pending.isEmpty { pending = try input.read(upToCount: 64 * 1024) ?? Data() }
            guard let byte = pending.first else { throw Failure.corrupt }
            pending.removeFirst()
            return byte
        }
        if flags & 0x04 != 0 {
            let length = Int(try readByte()) | Int(try readByte()) << 8
            for _ in 0..<length { _ = try readByte() }
        }
        if flags & 0x08 != 0 { while try readByte() != 0 {} }
        if flags & 0x10 != 0 { while try readByte() != 0 {} }
        if flags & 0x02 != 0 { _ = try readByte(); _ = try readByte() }
        header.removeAll()

        try inflate(first: pending, rest: { try input.read(upToCount: 1 << 20) ?? Data() }) { chunk in
            try reader.consume(chunk)
        }
        try reader.finish()
    }

    /// Raw DEFLATE decompression, feeding `output` as data is produced.
    static func inflate(first: Data, rest: () throws -> Data, output: (Data) throws -> Void) throws {
        let bufferSize = 1 << 20
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destination.deallocate() }
        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw Failure.corrupt
        }
        defer { compression_stream_destroy(streamPointer) }

        var input = first
        var finished = false
        var exhausted = false
        while !finished {
            if input.isEmpty && !exhausted {
                input = try rest()
                if input.isEmpty { exhausted = true }
            }
            let flags = exhausted ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            var status = COMPRESSION_STATUS_OK
            let consumed: Int = input.withUnsafeBytes { raw -> Int in
                let base = raw.bindMemory(to: UInt8.self).baseAddress
                streamPointer.pointee.src_ptr = base ?? UnsafePointer(destination)
                streamPointer.pointee.src_size = input.count
                streamPointer.pointee.dst_ptr = destination
                streamPointer.pointee.dst_size = bufferSize
                status = compression_stream_process(streamPointer, flags)
                return input.count - streamPointer.pointee.src_size
            }
            let produced = bufferSize - streamPointer.pointee.dst_size
            if produced > 0 { try output(Data(bytes: destination, count: produced)) }
            input.removeFirst(consumed)
            switch status {
            case COMPRESSION_STATUS_END: finished = true
            case COMPRESSION_STATUS_OK:
                if exhausted && produced == 0 && consumed == 0 { throw Failure.corrupt }
            default: throw Failure.corrupt
            }
        }
    }
}

/// Minimal streaming tar reader (ustar, GNU long names, pax `path`).
struct TarReader {
    let destination: URL
    private var buffer = Data()
    private var file: FileHandle?
    private var remaining = 0
    private var padding = 0
    private var longName: String?
    private var meta: (type: UInt8, size: Int)?
    private var ended = false

    init(destination: URL) {
        self.destination = destination
    }

    mutating func consume(_ data: Data) throws {
        buffer.append(data)
        while !ended {
            if let meta {
                // Long-name / pax payload (small): wait until it's all buffered.
                guard buffer.count >= meta.size else { return }
                let payload = Data(buffer.prefix(meta.size))
                buffer.removeFirst(meta.size)
                longName = meta.type == UInt8(ascii: "L")
                    ? String(decoding: payload.prefix { $0 != 0 }, as: UTF8.self)
                    : Self.paxPath(payload)
                self.meta = nil
                continue
            }
            if remaining > 0 {
                guard !buffer.isEmpty else { return }
                let take = min(remaining, buffer.count)
                file?.write(buffer.prefix(take))
                buffer.removeFirst(take)
                remaining -= take
                if remaining == 0 {
                    try file?.close()
                    file = nil
                }
                continue
            }
            if padding > 0 {
                guard !buffer.isEmpty else { return }
                let take = min(padding, buffer.count)
                buffer.removeFirst(take)
                padding -= take
                continue
            }
            guard buffer.count >= 512 else { return }
            let header = Data(buffer.prefix(512))
            buffer.removeFirst(512)
            try handle(header: header)
        }
    }

    mutating func finish() throws {
        try file?.close()
        file = nil
        if remaining > 0 || meta != nil { throw TarGzExtractor.Failure.corrupt }
    }

    private mutating func handle(header: Data) throws {
        if header.allSatisfy({ $0 == 0 }) { ended = true; return }
        let bytes = [UInt8](header)
        func string(_ offset: Int, _ length: Int) -> String {
            let slice = bytes[offset..<(offset + length)]
            let end = slice.firstIndex(of: 0) ?? slice.endIndex
            return String(decoding: bytes[offset..<end], as: UTF8.self)
        }
        let sizeText = string(124, 12).trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
        guard let size = Int(sizeText.isEmpty ? "0" : sizeText, radix: 8) else { throw TarGzExtractor.Failure.corrupt }
        let type = bytes[156]
        var name = string(0, 100)
        if string(257, 5) == "ustar" {
            let prefix = string(345, 155)
            if !prefix.isEmpty { name = prefix + "/" + name }
        }
        if let longName { name = longName; self.longName = nil }
        padding = (512 - size % 512) % 512

        switch type {
        case UInt8(ascii: "L"), UInt8(ascii: "x"):
            // Long name / pax header: applies to the next entry.
            meta = (type, size)
        case 0, UInt8(ascii: "0"), UInt8(ascii: "7"):
            if let url = try safeURL(name), !url.lastPathComponent.hasPrefix("._") {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                file = try FileHandle(forWritingTo: url)
                if size == 0 { try file?.close(); file = nil }
            }
            remaining = size
        case UInt8(ascii: "5"):
            if let url = try safeURL(name) {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            remaining = size
        default:
            remaining = size   // links, devices, global pax: skipped
        }
    }

    static func paxPath(_ payload: Data) -> String? {
        // Records are "<len> key=value\n".
        for record in String(decoding: payload, as: UTF8.self).split(separator: "\n") {
            guard let space = record.firstIndex(of: " ") else { continue }
            let pair = record[record.index(after: space)...]
            if pair.hasPrefix("path=") { return String(pair.dropFirst(5)) }
        }
        return nil
    }

    private func safeURL(_ name: String) throws -> URL? {
        let trimmed = name.hasPrefix("./") ? String(name.dropFirst(2)) : name
        guard !trimmed.isEmpty, trimmed != "." else { return nil }
        let parts = trimmed.split(separator: "/")
        if trimmed.hasPrefix("/") || parts.contains("..") { throw TarGzExtractor.Failure.unsafePath(name) }
        return parts.reduce(destination) { $0.appending(component: String($1)) }
    }
}

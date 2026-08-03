import Foundation

enum GzipError: Error, LocalizedError {
    case notGzip
    case truncatedHeader
    case unsupportedCompressionMethod(UInt8)
    case inflateFailed

    var errorDescription: String? {
        switch self {
        case .notGzip:
            "The note's stored data is not in the expected gzip format."
        case .truncatedHeader:
            "The note's stored data ends in the middle of its gzip header."
        case .unsupportedCompressionMethod(let m):
            "The note's stored data uses an unsupported compression method (\(m))."
        case .inflateFailed:
            "The note's stored data could not be decompressed."
        }
    }
}

enum Gzip {
    /// Decompress a gzip stream.
    ///
    /// Foundation can inflate a raw DEFLATE stream but does not understand gzip
    /// framing, so the header is parsed off first. This avoids taking a zlib
    /// dependency for the one place we need it.
    static func decompress(_ data: Data) throws -> Data {
        let body = try stripHeader(data)
        guard let inflated = try? (body as NSData).decompressed(using: .zlib) as Data else {
            throw GzipError.inflateFailed
        }
        return inflated
    }

    private static func stripHeader(_ data: Data) throws -> Data {
        // RFC 1952 §2.3
        guard data.count >= 18 else { throw GzipError.truncatedHeader }
        let bytes = [UInt8](data)
        guard bytes[0] == 0x1f, bytes[1] == 0x8b else { throw GzipError.notGzip }
        guard bytes[2] == 8 else { throw GzipError.unsupportedCompressionMethod(bytes[2]) }

        let flags = bytes[3]
        var i = 10  // fixed header

        func requireByte() throws -> UInt8 {
            guard i < bytes.count else { throw GzipError.truncatedHeader }
            defer { i += 1 }
            return bytes[i]
        }

        if flags & 0x04 != 0 {  // FEXTRA
            let lo = Int(try requireByte()), hi = Int(try requireByte())
            i += lo | (hi << 8)
            guard i <= bytes.count else { throw GzipError.truncatedHeader }
        }
        if flags & 0x08 != 0 {  // FNAME
            while try requireByte() != 0 {}
        }
        if flags & 0x10 != 0 {  // FCOMMENT
            while try requireByte() != 0 {}
        }
        if flags & 0x02 != 0 {  // FHCRC
            i += 2
            guard i <= bytes.count else { throw GzipError.truncatedHeader }
        }

        // Trailing 8 bytes are CRC32 + ISIZE, which the inflater does not want.
        let end = bytes.count - 8
        guard i < end else { throw GzipError.truncatedHeader }
        return data.subdata(in: i..<end)
    }
}

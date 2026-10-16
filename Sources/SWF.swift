import Foundation

struct SWF {
    struct Tag {
        var code: Int
        var body: [UInt8]
        var long: Bool
    }

    enum Failure: Error {
        case unsupported
        case malformed
    }

    var version: UInt8
    var header: [UInt8]
    var tags: [Tag]

    private static let definitionTags: Set<Int> = [
        2, 6, 7, 10, 11, 14, 20, 21, 22, 32, 33, 34, 35, 36, 37, 39, 46, 48, 60, 75, 83, 84, 87, 90, 91,
    ]

    init(_ data: Data) throws {
        let bytes = Self.locateSignature(in: [UInt8](data))
        guard bytes.count > 8 else { throw Failure.malformed }
        version = bytes[3]
        let body: [UInt8]
        switch (bytes[0], bytes[1], bytes[2]) {
        case (0x46, 0x57, 0x53):
            body = Array(bytes[8...])
        case (0x43, 0x57, 0x53):
            let raw = Data(bytes[10..<max(10, bytes.count - 4)])
            guard let inflated = try? (raw as NSData).decompressed(using: .zlib) as Data else { throw Failure.malformed }
            body = [UInt8](inflated)
        default:
            throw Failure.unsupported
        }
        guard let first = body.first else { throw Failure.malformed }
        let rect = (5 + 4 * Int(first >> 3) + 7) / 8
        guard body.count >= rect + 4 else { throw Failure.malformed }
        header = Array(body[0..<(rect + 4)])

        var tags: [Tag] = []
        var p = rect + 4
        while p + 2 <= body.count {
            let word = Int(body[p]) | Int(body[p + 1]) << 8
            p += 2
            var length = word & 0x3F
            let long = length == 0x3F
            if long {
                guard p + 4 <= body.count else { throw Failure.malformed }
                length = Int(body[p]) | Int(body[p + 1]) << 8 | Int(body[p + 2]) << 16 | Int(body[p + 3]) << 24
                p += 4
            }
            guard p + length <= body.count else { throw Failure.malformed }
            tags.append(Tag(code: word >> 6, body: Array(body[p..<(p + length)]), long: long))
            p += length
            if word >> 6 == 0 { break }
        }
        self.tags = tags
    }

    private static func locateSignature(in bytes: [UInt8]) -> [UInt8] {
        let signatures: [[UInt8]] = [[0x46, 0x57, 0x53], [0x43, 0x57, 0x53]]
        for offset in 0..<min(64, max(0, bytes.count - 3)) where signatures.contains(Array(bytes[offset..<(offset + 3)])) {
            return offset == 0 ? bytes : Array(bytes[offset...])
        }
        return bytes
    }

    var data: Data {
        var body = header
        for tag in tags {
            if tag.long || tag.body.count >= 0x3F {
                body += le16(tag.code << 6 | 0x3F) + le32(tag.body.count)
            } else {
                body += le16(tag.code << 6 | tag.body.count)
            }
            body += tag.body
        }
        return Data([0x46, 0x57, 0x53, version] + le32(body.count + 8) + body)
    }

    var highestCharacterID: Int {
        tags.filter { Self.definitionTags.contains($0.code) && $0.body.count >= 2 }
            .map { Int($0.body[0]) | Int($0.body[1]) << 8 }
            .max() ?? 0
    }

    var symbolNames: [String] {
        tags.filter { $0.code == 76 }.flatMap { Self.parseSymbols($0.body).map(\.1) }
    }

    static func embeddingSounds(from audioData: Data, into mainData: Data) throws -> (swf: Data, classes: [String]) {
        var main = try SWF(mainData)
        let audio = try SWF(audioData)
        var next = main.highestCharacterID + 1
        var remap: [Int: Int] = [:]
        var sounds: [Tag] = []
        var code: [Tag] = []
        var symbols: [(Int, String)] = []

        for var tag in audio.tags {
            switch tag.code {
            case 14 where tag.body.count > 2:
                let old = Int(tag.body[0]) | Int(tag.body[1]) << 8
                remap[old] = next
                tag.body.replaceSubrange(0..<2, with: le16(next))
                next += 1
                sounds.append(tag)
            case 72, 82:
                code.append(tag)
            case 76:
                symbols += parseSymbols(tag.body)
            default:
                break
            }
        }
        guard next <= 0xFFFF else { throw Failure.malformed }

        let bound = symbols.compactMap { id, name in remap[id].map { ($0, name) } }
        guard !bound.isEmpty else { throw Failure.malformed }
        var symbolBody = le16(bound.count)
        for (id, name) in bound {
            symbolBody += le16(id) + Array(name.utf8) + [0]
        }

        let insertAt = main.tags.firstIndex { $0.code == 1 } ?? main.tags.firstIndex { $0.code == 0 } ?? main.tags.count
        main.tags.insert(contentsOf: sounds + code + [Tag(code: 76, body: symbolBody, long: true)], at: insertAt)
        return (main.data, bound.map(\.1))
    }

    private static func parseSymbols(_ body: [UInt8]) -> [(Int, String)] {
        guard body.count >= 2 else { return [] }
        var result: [(Int, String)] = []
        var p = 2
        for _ in 0..<(Int(body[0]) | Int(body[1]) << 8) {
            guard p + 2 <= body.count, let end = body[(p + 2)...].firstIndex(of: 0) else { break }
            result.append((Int(body[p]) | Int(body[p + 1]) << 8, String(decoding: body[(p + 2)..<end], as: UTF8.self)))
            p = end + 1
        }
        return result
    }
}

private func le16(_ value: Int) -> [UInt8] {
    [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)]
}

private func le32(_ value: Int) -> [UInt8] {
    [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)]
}

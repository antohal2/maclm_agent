import Foundation
import ImageIO
@testable import maclm_agent
import XCTest

final class PetLoaderTests: XCTestCase {
    private func manifest() -> [String: Any] {
        [
            "version": 1,
            "id": "scout",
            "name": "Скаут",
            "frameSize": 64,
            "columns": 2,
            "rows": [["row": 0, "state": "idle", "frames": 2, "fps": 6, "loop": true]],
            "reduceMotionFrame": 0,
        ]
    }

    private func json(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value)
    }

    private func image(width: Int = 128, height: Int = 64, type: String = "public.png") throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type as CFString, 1, nil))
        try CGImageDestinationAddImage(destination, XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testValidManifestAndCachedFrames() throws {
        var value = manifest()
        value["unknown"] = "ignored"
        let sprite = try PetLoader.load(manifestData: json(value), imageData: image())
        XCTAssertEqual(sprite.manifest.name, "Скаут")
        XCTAssertEqual(sprite.frames[.idle]?.count, 2)
        XCTAssertEqual(sprite.frames[.idle]?.first?.width, 64)
        XCTAssertEqual(sprite.row(for: .failed).state, .idle)
    }

    func testManifestViolations() throws {
        let png = try image()
        let fields: [(String, (Any, PetValidationError))] = [
            ("version", (2, .version)), ("id", ("Bad_ID", .identifier)), ("id", ("", .identifier)),
            ("id", (String(repeating: "a", count: 41), .identifier)), ("id", ("a\n", .identifier)),
            ("name", ("", .name)), ("name", (String(repeating: "я", count: 41), .name)),
            ("frameSize", (32, .frameSize)), ("columns", (0, .columns)), ("columns", (17, .columns)),
            ("reduceMotionFrame", (-1, .reduceMotionFrame)), ("reduceMotionFrame", (2, .reduceMotionFrame)),
            ("rows", ([], .missingIdle)), ("version", ("1", .manifestJSON)),
        ]
        for (key, (value, error)) in fields {
            var object = manifest()
            object[key] = value
            assertError(error) { _ = try PetLoader.load(manifestData: self.json(object), imageData: png) }
        }
        let rows: [(String, (Any, PetValidationError))] = [
            ("row", (-1, .rowIndex)), ("row", (Int.max, .rowIndex)),
            ("state", ("unknown", .manifestJSON)), ("state", ("running", .missingIdle)),
            ("frames", (0, .frames)), ("frames", (3, .frames)), ("fps", (0, .fps)), ("fps", (31, .fps)),
            ("loop", ("true", .manifestJSON)),
        ]
        for (key, (value, error)) in rows {
            var object = manifest()
            var row = try XCTUnwrap((object["rows"] as? [[String: Any]])?.first)
            row[key] = value
            object["rows"] = [row]
            assertError(error) { _ = try PetLoader.load(manifestData: self.json(object), imageData: png) }
        }
        var object = manifest()
        let row = try XCTUnwrap((object["rows"] as? [[String: Any]])?.first)
        object["rows"] = [row, row]
        assertError(.duplicateState) { _ = try PetLoader.load(manifestData: self.json(object), imageData: png) }
        var second = row
        second["state"] = "running"
        object["rows"] = [row, second]
        assertError(.duplicateRow) { _ = try PetLoader.load(manifestData: self.json(object), imageData: png) }
        second["row"] = 1
        second["frames"] = 1
        object["rows"] = [row, second]
        object["reduceMotionFrame"] = 1
        assertError(.reduceMotionFrame) { _ = try PetLoader.load(manifestData: self.json(object), imageData: png) }
    }

    func testFileLimitsAndDimensions() throws {
        let data = try json(manifest())
        assertError(.manifestSize) {
            _ = try PetLoader.load(manifestData: Data(repeating: 32, count: 64 * 1024 + 1), imageData: Data())
        }
        assertError(.imageSize) {
            _ = try PetLoader.load(manifestData: data, imageData: Data(repeating: 0, count: 8 * 1024 * 1024 + 1))
        }
        assertError(.imageDimensions) {
            _ = try PetLoader.load(manifestData: data, imageData: self.image(width: 64))
        }
        assertError(.imageType) { _ = try PetLoader.load(manifestData: data, imageData: Data("not PNG".utf8)) }
        assertError(.manifestJSON) { _ = try PetLoader.load(manifestData: Data("{".utf8), imageData: Data()) }
    }

    func testContentTypeIgnoresFilenameAndOtherFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifestURL = root.appendingPathComponent("pet.json")
        try json(manifest()).write(to: manifestURL)
        let wrongSuffix = root.appendingPathComponent("spritesheet.jpg")
        try image().write(to: wrongSuffix)
        XCTAssertEqual(try PetLoader.load(manifestURL: manifestURL, spriteURL: wrongSuffix).frames[.idle]?.count, 2)
        let pngURL = root.appendingPathComponent("spritesheet.png")
        try image(type: "public.jpeg").write(to: pngURL)
        assertError(.imageType) { _ = try PetLoader.load(directory: root) }
        try image().write(to: pngURL)
        try Data("never execute or read this".utf8).write(to: root.appendingPathComponent("script.sh"))
        XCTAssertNoThrow(try PetLoader.load(directory: root))
    }

    func testHugeDeclaredPNGRejectedBeforeDecode() throws {
        var png = try image()
        // Replace IHDR dimensions with 2^30 and repair its CRC; preserve tiny compressed pixels.
        png.replaceSubrange(16 ..< 24, with: [64, 0, 0, 0, 64, 0, 0, 0])
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in png[12 ..< 29] {
            crc ^= UInt32(byte)
            for _ in 0 ..< 8 {
                crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xEDB8_8320)
            }
        }
        crc ^= 0xFFFF_FFFF
        png.replaceSubrange(29 ..< 33, with: (0 ..< 4).map { UInt8(truncatingIfNeeded: crc >> (24 - $0 * 8)) })
        let start = Date()
        assertError(.imageDimensions) {
            _ = try PetLoader.load(manifestData: self.json(self.manifest()), imageData: png)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    private func assertError(
        _ expected: PetValidationError,
        operation: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? PetValidationError, expected, file: file, line: line)
        }
    }
}

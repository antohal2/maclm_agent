import Foundation
import ImageIO
@testable import maclm_agent
import XCTest

struct PetStoreFixture {
    let root: URL
    let source: URL
    let store: PetStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pet-tests-" + UUID().uuidString)
        source = root.appendingPathComponent("source")
        store = PetStore(root: root.appendingPathComponent("Pets"))
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try write()
    }

    func write(id: String = "test-pet", name: String = "Test") throws {
        let manifest: [String: Any] = [
            "version": 1, "id": id, "name": name, "frameSize": 64, "columns": 1,
            "rows": [["row": 0, "state": "idle", "frames": 1, "fps": 3, "loop": true]],
            "reduceMotionFrame": 0,
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: source.appendingPathComponent("pet.json"))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
        try CGImageDestinationAddImage(destination, XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try (bytes as Data).write(to: source.appendingPathComponent("spritesheet.png"))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func contents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: store.root.path).sorted()
    }
}

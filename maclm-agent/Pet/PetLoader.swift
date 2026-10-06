import Darwin
import Foundation
import ImageIO

struct PetSprite {
    let manifest: PetManifest
    let frames: [PetState: [CGImage]]

    func row(for state: PetState) -> PetManifest.Row {
        let available = PetStateMachine.available(state, in: Set(manifest.rows.map(\.state)))
        return manifest.rows.first(where: { $0.state == available })!
    }
}

enum PetLoader {
    static func load(directory: URL) throws -> PetSprite {
        try load(
            manifestURL: directory.appendingPathComponent("pet.json"),
            spriteURL: directory.appendingPathComponent("spritesheet.png")
        )
    }

    static func load(manifestURL: URL, spriteURL: URL) throws -> PetSprite {
        let json = try read(manifestURL, limit: 64 * 1024, error: .manifestSize)
        let png = try read(spriteURL, limit: 8 * 1024 * 1024, error: .imageSize)
        return try load(manifestData: json, imageData: png)
    }

    private static func read(_ url: URL, limit: Int, error: PetValidationError) throws -> Data {
        let directory = try PetFileAccess.directory(url.deletingLastPathComponent())
        defer { close(directory) }
        return try PetFileAccess.read(url.lastPathComponent, parent: directory, limit: limit, oversized: error)
    }

    static func load(manifestData: Data, imageData: Data) throws -> PetSprite {
        guard manifestData.count <= 64 * 1024 else { throw PetValidationError.manifestSize }
        let manifest: PetManifest
        do {
            manifest = try JSONDecoder().decode(PetManifest.self, from: manifestData)
        } catch {
            throw PetValidationError.manifestJSON
        }
        try manifest.validate()
        guard imageData.count <= 8 * 1024 * 1024 else { throw PetValidationError.imageSize }
        guard let source = CGImageSourceCreateWithData(imageData as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary), CGImageSourceGetType(source) as String? == "public.png"
        else { throw PetValidationError.imageType }
        let height = ((manifest.rows.map(\.row).max() ?? 0) + 1) * 64
        try validateDimensions(source, width: manifest.columns * 64, height: height)
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PetValidationError.imageDecode
        }
        var frames: [PetState: [CGImage]] = [:]
        for row in manifest.rows {
            frames[row.state] = try (0 ..< row.frames).map { column in
                guard let frame = image.cropping(to: CGRect(x: column * 64, y: row.row * 64, width: 64, height: 64))
                else { throw PetValidationError.imageDecode }
                return frame
            }
        }
        return PetSprite(manifest: manifest, frames: frames)
    }

    /// This gate runs before CGImageSourceCreateImageAtIndex; never allocate rejected pixels.
    private static func validateDimensions(_ source: CGImageSource, width: Int, height: Int) throws {
        guard width > 0, height > 0, height <= 16_777_216 / width else {
            throw PetValidationError.imageDimensions
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let sourceWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let sourceHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              sourceWidth.doubleValue == Double(width), sourceHeight.doubleValue == Double(height)
        else { throw PetValidationError.imageDimensions }
    }
}

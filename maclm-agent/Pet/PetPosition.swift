import Foundation

enum PetPosition {
    static func restored(_ saved: CGPoint?, size: CGSize, screens: [CGRect], main: CGRect) -> CGPoint {
        if let saved, saved.x.isFinite, saved.y.isFinite,
           screens.contains(where: { $0.contains(CGRect(origin: saved, size: size)) })
        {
            return saved
        }
        return corner(size: size, screen: main)
    }

    static func corner(size: CGSize, screen: CGRect) -> CGPoint {
        CGPoint(x: screen.maxX - size.width - 24, y: screen.minY + 24)
    }
}

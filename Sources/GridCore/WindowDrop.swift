import CoreGraphics

public enum WindowDrop {
    public static func target(at point: CGPoint, frames: [CellID: CGRect], excluding source: CellID?) -> CellID? {
        frames
            .filter { $0.key != source && $0.value.contains(point) }
            .min { $0.key.rawValue < $1.key.rawValue }?
            .key
    }

    public static func center(of frame: CGRect) -> CGPoint {
        CGPoint(x: frame.midX, y: frame.midY)
    }
}

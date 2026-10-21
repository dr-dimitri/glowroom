import Foundation
import GlowroomCore

enum DevelopRepairMaskUnion {
    static func combine(_ masks: [LocalMaskRaster]) throws -> LocalMaskRaster {
        guard !masks.isEmpty, masks.count <= 16 else { throw DevelopRepairAnalysisError.invalidSelection }
        let width = min(256, masks.map(\.width).max() ?? 1), height = min(256, masks.map(\.height).max() ?? 1)
        var bytes = Data(count: width * height)
        for mask in masks {
            try Task.checkCancellation()
            for y in 0..<height {
                let sy = min(mask.height - 1, y * mask.height / height)
                for x in 0..<width {
                    let sx = min(mask.width - 1, x * mask.width / width)
                    bytes[y * width + x] = max(bytes[y * width + x], mask.bytes[sy * mask.width + sx])
                }
            }
        }
        return try LocalMaskRaster(width: width, height: height, bytes: bytes)
    }
}

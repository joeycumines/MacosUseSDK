import ExactMacProto
import Foundation
import GRPCCore
import ImageIO
import UniformTypeIdentifiers

enum EncodedImageValidation {
    static func validate(
        _ data: Data,
        format: Exactmac_V1_ImageFormat,
        pixelWidth: Int32,
        pixelHeight: Int32,
    ) throws {
        guard pixelWidth > 0,
              pixelHeight > 0,
              let expectedType = typeIdentifier(for: format),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String? == expectedType,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceShouldCache: true,
                      kCGImageSourceShouldCacheImmediately: true,
                  ] as CFDictionary,
              ),
              image.width == Int(pixelWidth),
              image.height == Int(pixelHeight)
        else {
            throw RPCError(
                code: .unavailable,
                message: "Encoded screenshot bytes do not match their declared metadata",
            )
        }
    }

    private static func typeIdentifier(
        for format: Exactmac_V1_ImageFormat,
    ) -> String? {
        switch format {
        case .png:
            UTType.png.identifier
        case .jpeg:
            UTType.jpeg.identifier
        case .tiff:
            UTType.tiff.identifier
        case .unspecified, .UNRECOGNIZED:
            nil
        }
    }
}

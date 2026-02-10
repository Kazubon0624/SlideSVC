import Foundation
import CoreGraphics
import ImageIO
import COpenSlide

/// Swift wrapper for OpenSlide library operations
public final class SlideReader {
    
    private let osr: OpaquePointer
    private let fileURL: URL
    
    /// Opens a virtual slide file
    /// - Parameter url: URL to the slide file (.scn, .ndpi, etc.)
    /// - Throws: SlideError if the file cannot be opened
    public init(url: URL) throws {
        guard let osr = openslide_open(url.path) else {
            throw SlideError.cannotOpenFile(url)
        }
        
        // Check for errors during open
        if let error = openslide_get_error(osr) {
            let errorMessage = String(cString: error)
            openslide_close(osr)
            throw SlideError.openSlideError(errorMessage)
        }
        
        self.osr = osr
        self.fileURL = url
    }
    
    deinit {
        openslide_close(osr)
    }
    
    // MARK: - Properties
    
    /// Number of pyramid levels in the slide
    public var levelCount: Int32 {
        openslide_get_level_count(osr)
    }
    
    /// Get dimensions of a specific level
    public func dimensions(forLevel level: Int32) -> (width: Int64, height: Int64) {
        var w: Int64 = 0
        var h: Int64 = 0
        openslide_get_level_dimensions(osr, level, &w, &h)
        return (w, h)
    }
    
    /// Get the downsample factor for a specific level
    public func downsample(forLevel level: Int32) -> Double {
        openslide_get_level_downsample(osr, level)
    }
    
    /// Get the vendor name
    public var vendor: String? {
        guard let value = openslide_get_property_value(osr, OPENSLIDE_PROPERTY_NAME_VENDOR) else {
            return nil
        }
        return String(cString: value)
    }
    
    /// Get objective power if available
    public var objectivePower: String? {
        guard let value = openslide_get_property_value(osr, OPENSLIDE_PROPERTY_NAME_OBJECTIVE_POWER) else {
            return nil
        }
        return String(cString: value)
    }
    
    // MARK: - Associated Images
    
    /// Names of available associated images (e.g., "thumbnail", "label", "macro")
    public var associatedImageNames: [String] {
        guard let names = openslide_get_associated_image_names(osr) else {
            return []
        }
        
        var result: [String] = []
        var ptr = names
        while let cString = ptr.pointee {
            result.append(String(cString: cString))
            ptr = ptr.advanced(by: 1)
        }
        return result
    }
    
    /// Get an associated image by name
    public func associatedImage(named name: String) -> CGImage? {
        var w: Int64 = 0
        var h: Int64 = 0
        openslide_get_associated_image_dimensions(osr, name, &w, &h)
        
        guard w > 0 && h > 0 else { return nil }
        
        let width = Int(w)
        let height = Int(h)
        var buffer = [UInt32](repeating: 0, count: width * height)
        
        openslide_read_associated_image(osr, name, &buffer)
        
        // Check for errors
        if openslide_get_error(osr) != nil {
            return nil
        }
        
        return createCGImage(from: buffer, width: width, height: height)
    }
    
    // MARK: - Thumbnail Generation
    
    /// Generate a thumbnail image from the slide
    /// - Parameter maxSize: Maximum dimension (width or height) of the thumbnail
    /// - Returns: CGImage of the thumbnail
    public func generateThumbnail(maxSize: Int = 512) -> CGImage? {
        // First, try to get an associated thumbnail or label image
        let preferredNames = ["thumbnail", "label", "macro"]
        for name in preferredNames {
            if associatedImageNames.contains(name) {
                if let image = associatedImage(named: name) {
                    return image
                }
            }
        }
        
        // If no associated image, read from the lowest resolution level
        let levels = levelCount
        guard levels > 0 else { return nil }
        
        // Find the best level for the requested thumbnail size
        let (fullW, fullH) = dimensions(forLevel: 0)
        var bestLevel: Int32 = levels - 1
        
        for level in (0..<levels).reversed() {
            let (w, h) = dimensions(forLevel: level)
            if w <= Int64(maxSize) && h <= Int64(maxSize) {
                bestLevel = level
                break
            }
        }
        
        let (levelW, levelH) = dimensions(forLevel: bestLevel)
        let width = Int(levelW)
        let height = Int(levelH)
        
        guard width > 0 && height > 0 else { return nil }
        
        // Calculate the region to read from level 0
        let ds = downsample(forLevel: bestLevel)
        
        var buffer = [UInt32](repeating: 0, count: width * height)
        openslide_read_region(osr, &buffer, 0, 0, bestLevel, Int64(width), Int64(height))
        
        // Check for errors
        if openslide_get_error(osr) != nil {
            return nil
        }
        
        return createCGImage(from: buffer, width: width, height: height)
    }
    
    // MARK: - Region Reading
    
    /// Read a region from a specific level
    /// - Parameters:
    ///   - x: X coordinate in level 0 coordinate space
    ///   - y: Y coordinate in level 0 coordinate space
    ///   - level: Pyramid level to read from
    ///   - width: Width of region to read (in level coordinates)
    ///   - height: Height of region to read (in level coordinates)
    /// - Returns: CGImage of the requested region
    public func readRegion(x: Int64, y: Int64, level: Int32, width: Int, height: Int) -> CGImage? {
        guard width > 0 && height > 0 else { return nil }
        guard level >= 0 && level < levelCount else { return nil }
        
        var buffer = [UInt32](repeating: 0, count: width * height)
        openslide_read_region(osr, &buffer, x, y, level, Int64(width), Int64(height))
        
        // Check for errors
        if openslide_get_error(osr) != nil {
            return nil
        }
        
        return createCGImage(from: buffer, width: width, height: height)
    }
    
    /// Get the best level for a given downsample factor
    public func bestLevelForDownsample(_ downsampleFactor: Double) -> Int32 {
        openslide_get_best_level_for_downsample(osr, downsampleFactor)
    }
    
    /// Export a region as JPEG data
    public func exportRegionAsJPEG(x: Int64, y: Int64, level: Int32, width: Int, height: Int, quality: CGFloat = 0.85) -> Data? {
        guard let cgImage = readRegion(x: x, y: y, level: level, width: width, height: height) else {
            return nil
        }
        
        let mutableData = CFDataCreateMutable(nil, 0)!
        guard let destination = CGImageDestinationCreateWithData(mutableData, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        
        return mutableData as Data
    }
    
    /// Export thumbnail as JPEG data
    public func exportThumbnailAsJPEG(maxSize: Int = 512, quality: CGFloat = 0.85) -> Data? {
        guard let cgImage = generateThumbnail(maxSize: maxSize) else {
            return nil
        }
        
        let mutableData = CFDataCreateMutable(nil, 0)!
        guard let destination = CGImageDestinationCreateWithData(mutableData, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        
        return mutableData as Data
    }
    
    // MARK: - Private Helpers
    
    /// Convert ARGB buffer to CGImage
    private func createCGImage(from buffer: [UInt32], width: Int, height: Int) -> CGImage? {
        // OpenSlide returns pre-multiplied ARGB in native byte order
        // We need to convert to a format CGImage understands
        
        let bitsPerComponent = 8
        let bitsPerPixel = 32
        let bytesPerRow = width * 4
        
        // Create a copy of the buffer that we can modify
        var rgbaBuffer = buffer
        
        // Convert from ARGB to RGBA and un-premultiply
        for i in 0..<rgbaBuffer.count {
            let pixel = rgbaBuffer[i]
            let a = (pixel >> 24) & 0xFF
            var r = (pixel >> 16) & 0xFF
            var g = (pixel >> 8) & 0xFF
            var b = pixel & 0xFF
            
            // Un-premultiply if alpha is not 0 or 255
            if a > 0 && a < 255 {
                r = min(255, r * 255 / a)
                g = min(255, g * 255 / a)
                b = min(255, b * 255 / a)
            }
            
            // Store as RGBA
            rgbaBuffer[i] = (a << 24) | (b << 16) | (g << 8) | r
        }
        
        let data = Data(bytes: &rgbaBuffer, count: rgbaBuffer.count * 4)
        
        guard let provider = CGDataProvider(data: data as CFData) else {
            return nil
        }
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bitsPerPixel: bitsPerPixel,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

// MARK: - Errors

public enum SlideError: Error, LocalizedError {
    case cannotOpenFile(URL)
    case openSlideError(String)
    case unsupportedFormat
    
    public var errorDescription: String? {
        switch self {
        case .cannotOpenFile(let url):
            return "Cannot open slide file: \(url.lastPathComponent)"
        case .openSlideError(let message):
            return "OpenSlide error: \(message)"
        case .unsupportedFormat:
            return "Unsupported slide format"
        }
    }
}

// MARK: - Slide Detection

public extension SlideReader {
    /// Check if a file is a supported slide format
    static func canOpen(url: URL) -> Bool {
        guard let vendor = openslide_detect_vendor(url.path) else {
            return false
        }
        // If we get a vendor string, it's a supported format
        return true
    }
    
    /// Detect the vendor of a slide file
    static func detectVendor(url: URL) -> String? {
        guard let vendor = openslide_detect_vendor(url.path) else {
            return nil
        }
        return String(cString: vendor)
    }
}

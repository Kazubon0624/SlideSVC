import Foundation
import CoreGraphics

/// Minimal TIFF IFD parser for large NDPI files that OpenSlide and ImageIO cannot handle.
/// Reads only the binary TIFF headers to find small sub-images (macro/label/map),
/// then decodes JPEG strips directly — without loading the entire file.
public final class NDPIFallbackReader {
    
    private struct IFDEntry {
        let index: Int
        let width: UInt32
        let height: UInt32
        let compression: UInt16
        let stripOffset: UInt64
        let stripByteCount: UInt64
    }
    
    /// Try to extract a small overview image from a large NDPI file.
    /// Returns nil if the file cannot be parsed or no suitable sub-image is found.
    public static func loadOverview(url: URL, maxPixels: Int = 4_000_000) -> CGImage? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        
        // Read TIFF header (8 bytes)
        guard let headerData = try? handle.read(upToCount: 8), headerData.count == 8 else { return nil }
        
        let isLittle: Bool
        let magic = headerData[0...1]
        if magic.elementsEqual([0x49, 0x49]) {       // "II" - little endian
            isLittle = true
        } else if magic.elementsEqual([0x4D, 0x4D]) { // "MM" - big endian
            isLittle = false
        } else {
            return nil
        }
        
        let tiffMagic = readU16(headerData, offset: 2, littleEndian: isLittle)
        guard tiffMagic == 42 else { return nil } // Classic TIFF
        
        var ifdOffset = UInt64(readU32(headerData, offset: 4, littleEndian: isLittle))
        
        var entries: [IFDEntry] = []
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        
        // Walk IFD chain (up to 30 directories to be safe)
        for dirIndex in 0..<30 {
            guard ifdOffset > 0 && ifdOffset < fileSize && ifdOffset < UInt64(Int64.max) else { break }
            
            // Seek to IFD
            try? handle.seek(toOffset: ifdOffset)
            guard let countData = try? handle.read(upToCount: 2), countData.count == 2 else { break }
            let tagCount = readU16(countData, offset: 0, littleEndian: isLittle)
            guard tagCount > 0 && tagCount < 1000 else { break }
            
            // Read all IFD entries (12 bytes each)
            let ifdSize = Int(tagCount) * 12
            guard let ifdData = try? handle.read(upToCount: ifdSize), ifdData.count == ifdSize else { break }
            
            var width: UInt32 = 0
            var height: UInt32 = 0
            var compression: UInt16 = 0
            var stripOffset: UInt64 = 0
            var stripByteCount: UInt64 = 0
            
            for t in 0..<Int(tagCount) {
                let base = t * 12
                let tag = readU16(ifdData, offset: base, littleEndian: isLittle)
                let type = readU16(ifdData, offset: base + 2, littleEndian: isLittle)
                let count = readU32(ifdData, offset: base + 4, littleEndian: isLittle)
                
                switch tag {
                case 256: // ImageWidth
                    width = (type == 3) ? UInt32(readU16(ifdData, offset: base + 8, littleEndian: isLittle))
                                        : readU32(ifdData, offset: base + 8, littleEndian: isLittle)
                case 257: // ImageLength
                    height = (type == 3) ? UInt32(readU16(ifdData, offset: base + 8, littleEndian: isLittle))
                                         : readU32(ifdData, offset: base + 8, littleEndian: isLittle)
                case 259: // Compression
                    compression = readU16(ifdData, offset: base + 8, littleEndian: isLittle)
                case 273: // StripOffsets (single strip)
                    if count == 1 {
                        stripOffset = (type == 3) ? UInt64(readU16(ifdData, offset: base + 8, littleEndian: isLittle))
                                                  : UInt64(readU32(ifdData, offset: base + 8, littleEndian: isLittle))
                    }
                case 279: // StripByteCounts (single strip)
                    if count == 1 {
                        stripByteCount = (type == 3) ? UInt64(readU16(ifdData, offset: base + 8, littleEndian: isLittle))
                                                     : UInt64(readU32(ifdData, offset: base + 8, littleEndian: isLittle))
                    }
                default:
                    break
                }
            }
            
            if width > 0 && height > 0 {
                entries.append(IFDEntry(
                    index: dirIndex,
                    width: width, height: height,
                    compression: compression,
                    stripOffset: stripOffset,
                    stripByteCount: stripByteCount
                ))
            }
            
            // Read next IFD offset (4 bytes after the IFD entries)
            guard let nextData = try? handle.read(upToCount: 4), nextData.count == 4 else { break }
            let nextOffset = UInt64(readU32(nextData, offset: 0, littleEndian: isLittle))
            
            // Safety: if next offset is 0 or beyond file size, stop
            if nextOffset == 0 || nextOffset >= fileSize { break }
            ifdOffset = nextOffset
        }
        
        guard !entries.isEmpty else { return nil }
        
        NSLog("NDPIFallback: Found %d IFDs", entries.count)
        for e in entries {
            NSLog("NDPIFallback:   [%d] %dx%d comp=%d stripOff=%llu stripBytes=%llu",
                  e.index, e.width, e.height, e.compression, e.stripOffset, e.stripByteCount)
        }
        
        // Find the best overview: small enough (< maxPixels), but >= 128px in at least one dimension
        // Prefer the smallest suitable image
        let candidates = entries.filter { e in
            let px = Int(e.width) * Int(e.height)
            return px < maxPixels && px > 0 && (e.width >= 128 || e.height >= 128)
                && e.stripOffset > 0 && e.stripByteCount > 0
                && e.stripOffset < fileSize
                && (e.stripOffset + e.stripByteCount) <= fileSize
        }.sorted { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }
        
        guard let best = candidates.first else {
            NSLog("NDPIFallback: No suitable sub-image found")
            return nil
        }
        
        NSLog("NDPIFallback: Using IFD[%d] %dx%d (compression=%d, offset=%llu, bytes=%llu)",
              best.index, best.width, best.height, best.compression, best.stripOffset, best.stripByteCount)
        
        // Read the strip data
        try? handle.seek(toOffset: best.stripOffset)
        guard let stripData = try? handle.read(upToCount: Int(best.stripByteCount)),
              stripData.count > 0 else {
            NSLog("NDPIFallback: Failed to read strip data")
            return nil
        }
        
        // JPEG compressed (compression == 7 for new-style JPEG, 6 for old-style)
        if best.compression == 7 || best.compression == 6 || best.compression == 33003 /* NDPI JPEG */ {
            // NDPI stores raw JPEG in strips — decode directly
            if let provider = CGDataProvider(data: stripData as CFData),
               let img = CGImage(jpegDataProviderSource: provider,
                                 decode: nil, shouldInterpolate: true,
                                 intent: .defaultIntent) {
                NSLog("NDPIFallback: JPEG decode OK: %dx%d", img.width, img.height)
                return img
            }
            NSLog("NDPIFallback: JPEG decode failed")
        }
        
        // Uncompressed RGB (compression == 1)
        if best.compression == 1 {
            let w = Int(best.width)
            let h = Int(best.height)
            let bpr = w * 3 // Assuming RGB
            if stripData.count >= bpr * h {
                if let provider = CGDataProvider(data: stripData as CFData) {
                    let cs = CGColorSpaceCreateDeviceRGB()
                    return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 24,
                                   bytesPerRow: bpr, space: cs,
                                   bitmapInfo: CGBitmapInfo(rawValue: 0),
                                   provider: provider, decode: nil,
                                   shouldInterpolate: true, intent: .defaultIntent)
                }
            }
        }
        
        NSLog("NDPIFallback: Unsupported compression %d", best.compression)
        return nil
    }
    
    // MARK: - Binary helpers
    
    private static func readU16(_ data: Data, offset: Int, littleEndian: Bool) -> UInt16 {
        guard offset + 1 < data.count else { return 0 }
        if littleEndian {
            return UInt16(data[data.startIndex + offset]) | (UInt16(data[data.startIndex + offset + 1]) << 8)
        } else {
            return (UInt16(data[data.startIndex + offset]) << 8) | UInt16(data[data.startIndex + offset + 1])
        }
    }
    
    private static func readU32(_ data: Data, offset: Int, littleEndian: Bool) -> UInt32 {
        guard offset + 3 < data.count else { return 0 }
        if littleEndian {
            return UInt32(data[data.startIndex + offset])
                 | (UInt32(data[data.startIndex + offset + 1]) << 8)
                 | (UInt32(data[data.startIndex + offset + 2]) << 16)
                 | (UInt32(data[data.startIndex + offset + 3]) << 24)
        } else {
            return (UInt32(data[data.startIndex + offset]) << 24)
                 | (UInt32(data[data.startIndex + offset + 1]) << 16)
                 | (UInt32(data[data.startIndex + offset + 2]) << 8)
                 | UInt32(data[data.startIndex + offset + 3])
        }
    }
}

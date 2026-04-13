import Foundation
import CoreGraphics

/// Minimal TIFF IFD parser for large NDPI files that OpenSlide 4.0 cannot handle (>4GB).
/// Uses POSIX I/O (open/read/lseek) for fast, non-blocking access.
///
/// Key insight: NDPI files >4GB have 32-bit IFD/strip offsets that overflow.
/// The real position is `stored_offset + N * 4GB`. We probe each candidate
/// and validate with JPEG SOI markers (FF D8).
public final class NDPIFallbackReader {
    
    private static let fourGB: UInt64 = 4_294_967_296
    
    /// Result of loading an overview image
    public struct FallbackResult {
        public let image: CGImage
        public let width: Int
        public let height: Int
        public let levelIndex: Int   // which pyramid level this came from
        public let totalLevels: Int  // total levels found
    }
    
    /// Try to extract the best available overview image from a large NDPI file.
    /// Prefers the highest resolution image that's still loadable (<50MB JPEG).
    public static func loadBestImage(url: URL) -> FallbackResult? {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        
        let fileSize = UInt64(lseek(fd, 0, SEEK_END))
        lseek(fd, 0, SEEK_SET)
        guard fileSize > 8 else { return nil }
        
        // Read TIFF header
        var hdr = [UInt8](repeating: 0, count: 8)
        guard read(fd, &hdr, 8) == 8 else { return nil }
        
        let isLE = hdr[0] == 0x49 && hdr[1] == 0x49
        guard r16(hdr, 2, isLE) == 42 else { return nil }
        
        let rawIFDOffset = UInt64(r32(hdr, 4, isLE))
        
        // Strategy 1: IFD chain with 4GB overflow correction
        if let result = tryIFDChain(fd: fd, fileSize: fileSize, rawOffset: rawIFDOffset, isLE: isLE) {
            return result
        }
        
        // Strategy 2: Scan end of file for JPEG
        if let img = scanForJPEG(fd: fd, fileSize: fileSize) {
            return FallbackResult(image: img, width: img.width, height: img.height,
                                  levelIndex: 0, totalLevels: 1)
        }
        
        return nil
    }
    
    /// Backward-compatible convenience method
    public static func loadOverview(url: URL, maxPixels: Int = 4_000_000) -> CGImage? {
        return loadBestImage(url: url)?.image
    }
    
    // MARK: - Strategy 1: IFD chain with 4GB overflow correction
    
    private struct IFDEntry {
        let dir: Int; let w: UInt32; let h: UInt32
        let comp: UInt16; let rawStripOff: UInt64; let stripBytes: UInt64; let stripCount: UInt32
    }
    
    private static func tryIFDChain(fd: Int32, fileSize: UInt64, rawOffset: UInt64, isLE: Bool) -> FallbackResult? {
        let maxMult = Int((fileSize / fourGB) + 1)
        
        // Find a valid IFD start (try raw, +4GB, +8GB)
        for mult in 0...min(maxMult, 3) {
            let ifdStart = rawOffset + UInt64(mult) * fourGB
            guard ifdStart < fileSize else { continue }
            guard isValidIFD(fd: fd, offset: ifdStart, isLE: isLE) else { continue }
            
            // Walk the full IFD chain
            var entries = [IFDEntry]()
            var ifdOffset = ifdStart
            
            for dirIdx in 0..<30 {
                guard ifdOffset > 0, ifdOffset < fileSize else { break }
                
                lseek(fd, off_t(ifdOffset), SEEK_SET)
                var cb = [UInt8](repeating: 0, count: 2)
                guard read(fd, &cb, 2) == 2 else { break }
                let tagCount = Int(r16(cb, 0, isLE))
                guard tagCount > 0, tagCount < 500 else { break }
                
                let ifdBytes = tagCount * 12
                var ifd = [UInt8](repeating: 0, count: ifdBytes)
                guard read(fd, &ifd, ifdBytes) == ifdBytes else { break }
                
                var w: UInt32 = 0, h: UInt32 = 0, comp: UInt16 = 0
                var sOff: UInt64 = 0, sBytes: UInt64 = 0, sCount: UInt32 = 0
                
                for t in 0..<tagCount {
                    let b = t * 12
                    let tag = r16(ifd, b, isLE)
                    let typ = r16(ifd, b + 2, isLE)
                    let cnt = r32(ifd, b + 4, isLE)
                    switch tag {
                    case 256: w = (typ == 3) ? UInt32(r16(ifd, b+8, isLE)) : r32(ifd, b+8, isLE)
                    case 257: h = (typ == 3) ? UInt32(r16(ifd, b+8, isLE)) : r32(ifd, b+8, isLE)
                    case 259: comp = r16(ifd, b+8, isLE)
                    case 273:
                        sCount = cnt
                        if cnt == 1 { sOff = UInt64(r32(ifd, b+8, isLE)) }
                    case 279:
                        if cnt == 1 { sBytes = UInt64(r32(ifd, b+8, isLE)) }
                    default: break
                    }
                }
                
                if w > 0 && h > 0 && sCount == 1 && sOff > 0 && sBytes > 0 {
                    entries.append(IFDEntry(dir: dirIdx, w: w, h: h, comp: comp,
                                            rawStripOff: sOff, stripBytes: sBytes, stripCount: sCount))
                }
                
                // Next IFD pointer
                var nb = [UInt8](repeating: 0, count: 4)
                guard read(fd, &nb, 4) == 4 else { break }
                let rawNext = UInt64(r32(nb, 0, isLE))
                if rawNext == 0 { break }
                
                // Find valid next IFD (try raw, then +4GB corrections)
                if let nextValid = findValidOffset(fd: fd, raw: rawNext, fileSize: fileSize,
                                                    maxMult: maxMult, isLE: isLE, checkIFD: true) {
                    ifdOffset = nextValid
                } else {
                    break
                }
            }
            
            guard !entries.isEmpty else { continue }
            
            // Sort by pixel count descending — try best (largest) first
            let sorted = entries.sorted { UInt64($0.w) * UInt64($0.h) > UInt64($1.w) * UInt64($1.h) }
            
            // Try each entry, from largest to smallest, that's < 50MB JPEG
            for entry in sorted {
                guard entry.stripBytes < 80_000_000 else { continue } // Skip huge JPEGs
                guard entry.stripBytes > 1000 else { continue }       // Skip tiny
                
                // Find actual strip offset (try raw, then +4GB corrections, validate with JPEG SOI)
                let correctedOff = findValidOffset(fd: fd, raw: entry.rawStripOff,
                                                    fileSize: fileSize, maxMult: maxMult,
                                                    isLE: isLE, checkIFD: false)
                    ?? entry.rawStripOff
                
                guard correctedOff < fileSize, (correctedOff + entry.stripBytes) <= fileSize else { continue }
                
                if let img = readAndDecodeJPEG(fd: fd, offset: correctedOff, bytes: entry.stripBytes) {
                    return FallbackResult(image: img, width: img.width, height: img.height,
                                          levelIndex: entry.dir, totalLevels: entries.count)
                }
            }
        }
        return nil
    }
    
    // MARK: - Offset correction helpers
    
    /// Check if an offset contains a valid IFD (tag count 1-499)
    private static func isValidIFD(fd: Int32, offset: UInt64, isLE: Bool) -> Bool {
        lseek(fd, off_t(offset), SEEK_SET)
        var cb = [UInt8](repeating: 0, count: 2)
        guard read(fd, &cb, 2) == 2 else { return false }
        let tc = Int(r16(cb, 0, isLE))
        return tc > 0 && tc < 500
    }
    
    /// Find the correct 64-bit offset by trying raw, +4GB, +8GB, etc.
    /// If checkIFD, validates with IFD tag count; otherwise validates with JPEG SOI.
    private static func findValidOffset(fd: Int32, raw: UInt64, fileSize: UInt64,
                                         maxMult: Int, isLE: Bool, checkIFD: Bool) -> UInt64? {
        for m in 0...min(maxMult, 3) {
            let candidate = raw + UInt64(m) * fourGB
            guard candidate < fileSize else { continue }
            
            if checkIFD {
                if isValidIFD(fd: fd, offset: candidate, isLE: isLE) { return candidate }
            } else {
                // Validate with JPEG SOI marker (FF D8)
                lseek(fd, off_t(candidate), SEEK_SET)
                var marker = [UInt8](repeating: 0, count: 2)
                guard read(fd, &marker, 2) == 2 else { continue }
                if marker[0] == 0xFF && marker[1] == 0xD8 { return candidate }
            }
        }
        return nil
    }
    
    // MARK: - JPEG decode
    
    private static func readAndDecodeJPEG(fd: Int32, offset: UInt64, bytes: UInt64) -> CGImage? {
        lseek(fd, off_t(offset), SEEK_SET)
        var buf = [UInt8](repeating: 0, count: Int(bytes))
        let n = read(fd, &buf, Int(bytes))
        guard n > 0 else { return nil }
        
        let data = Data(bytes: buf, count: n)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
    
    // MARK: - Strategy 2: Scan end of file for JPEG
    
    private static func scanForJPEG(fd: Int32, fileSize: UInt64, scanSize: Int = 10_000_000) -> CGImage? {
        let scanStart = fileSize > UInt64(scanSize) ? fileSize - UInt64(scanSize) : 0
        lseek(fd, off_t(scanStart), SEEK_SET)
        
        let readSize = Int(fileSize - scanStart)
        var buf = [UInt8](repeating: 0, count: readSize)
        let bytesRead = read(fd, &buf, readSize)
        guard bytesRead > 4 else { return nil }
        
        // Find JPEG SOI/EOI pairs
        struct Region { let start: Int; let end: Int }
        var regions = [Region]()
        var i = 0
        while i < bytesRead - 3 {
            if buf[i] == 0xFF && buf[i+1] == 0xD8 && buf[i+2] == 0xFF {
                var j = i + 3
                while j < bytesRead - 1 {
                    if buf[j] == 0xFF && buf[j+1] == 0xD9 {
                        regions.append(Region(start: i, end: j + 2))
                        i = j + 2; break
                    }
                    j += 1
                }
                if j >= bytesRead - 1 { break }
            } else { i += 1 }
        }
        
        // Decode largest JPEG found
        var bestImage: CGImage? = nil
        var bestPx = 0
        for region in regions {
            let size = region.end - region.start
            guard size > 1000 else { continue }
            let data = Data(bytes: &buf + region.start, count: size)
            if let provider = CGDataProvider(data: data as CFData),
               let img = CGImage(jpegDataProviderSource: provider, decode: nil,
                                 shouldInterpolate: true, intent: .defaultIntent) {
                let px = img.width * img.height
                if px > bestPx { bestImage = img; bestPx = px }
            }
        }
        return bestImage
    }
    
    // MARK: - Binary helpers
    
    private static func r16(_ d: [UInt8], _ o: Int, _ le: Bool) -> UInt16 {
        le ? UInt16(d[o]) | (UInt16(d[o+1]) << 8) : (UInt16(d[o]) << 8) | UInt16(d[o+1])
    }
    private static func r32(_ d: [UInt8], _ o: Int, _ le: Bool) -> UInt32 {
        le ? UInt32(d[o]) | (UInt32(d[o+1])<<8) | (UInt32(d[o+2])<<16) | (UInt32(d[o+3])<<24)
           : (UInt32(d[o])<<24) | (UInt32(d[o+1])<<16) | (UInt32(d[o+2])<<8) | UInt32(d[o+3])
    }
}

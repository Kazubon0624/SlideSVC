import Cocoa
import QuickLookThumbnailing
import SlideCore

class ThumbnailProvider: QLThumbnailProvider {
    
    static let supportedExtensions: Set<String> = ["svs", "ndpi", "scn", "bif", "mrxs", "tiff", "tif"]
    
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        
        let fileURL = request.fileURL
        
        // Check file extension
        let ext = fileURL.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else {
            handler(nil, NSError(domain: "SlideQLThumbnail", code: -1,
                                 userInfo: [NSLocalizedDescriptionKey: "Unsupported file type: \(ext)"]))
            return
        }
        
        // Use scale-aware pixel count for source image quality
        let maxDim = max(request.maximumSize.width, request.maximumSize.height)
        let maxPixels = Int(maxDim * request.scale)
        
        do {
            let reader = try SlideReader(url: fileURL)
            
            guard let cgImage = reader.generateThumbnail(maxSize: maxPixels) else {
                handler(nil, SlideError.unsupportedFormat)
                return
            }
            
            let imgW = CGFloat(cgImage.width)
            let imgH = CGFloat(cgImage.height)
            
            // Use maximumSize as contextSize to fill the entire thumbnail area
            let contextSize = request.maximumSize
            
            // Aspect-fill: scale to cover the entire area (use max, not min)
            let scaleX = contextSize.width / imgW
            let scaleY = contextSize.height / imgH
            let fillScale = max(scaleX, scaleY)
            
            let drawW = imgW * fillScale
            let drawH = imgH * fillScale
            
            // Center the image (offset will be negative on the overflowing axis)
            let drawX = (contextSize.width - drawW) / 2.0
            let drawY = (contextSize.height - drawH) / 2.0
            
            let reply = QLThumbnailReply(contextSize: contextSize) { context -> Bool in
                // Retina display scale compensation
                let scale = request.scale
                let currentScaleX = abs(context.ctm.a)
                if currentScaleX < scale {
                    let neededScale = scale / currentScaleX
                    context.scaleBy(x: neededScale, y: neededScale)
                }
                
                // Clip to contextSize so overflowing parts are hidden
                context.clip(to: CGRect(origin: .zero, size: contextSize))
                
                // Draw image centered, filling the entire area
                let drawRect = CGRect(x: drawX, y: drawY, width: drawW, height: drawH)
                context.draw(cgImage, in: drawRect)
                return true
            }
            handler(reply, nil)
            
        } catch {
            handler(nil, error)
        }
    }
}

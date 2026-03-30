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
            
            // contextSize MUST fit within request.maximumSize
            let scaleX = request.maximumSize.width / imgW
            let scaleY = request.maximumSize.height / imgH
            let fitScale = min(scaleX, scaleY)
            
            let drawW = floor(imgW * fitScale)
            let drawH = floor(imgH * fitScale)
            
            // Clamp to be safe (must not exceed maximumSize)
            let contextSize = CGSize(
                width:  min(drawW, request.maximumSize.width),
                height: min(drawH, request.maximumSize.height)
            )
            
            let reply = QLThumbnailReply(contextSize: contextSize) { context -> Bool in
                let rect = CGRect(origin: .zero, size: contextSize)
                context.draw(cgImage, in: rect)
                return true
            }
            handler(reply, nil)
            
        } catch {
            handler(nil, error)
        }
    }
}

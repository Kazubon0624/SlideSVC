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
            handler(nil, NSError(domain: "SlideQLThumbnail", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported file type"]))
            return
        }
        
        let maxSize = max(request.maximumSize.width, request.maximumSize.height)
        
        // Try to open the slide and generate a thumbnail
        do {
            let reader = try SlideReader(url: fileURL)
            
            if let cgImage = reader.generateThumbnail(maxSize: Int(maxSize)) {
                let reply = QLThumbnailReply(contextSize: CGSize(width: cgImage.width, height: cgImage.height)) { context -> Bool in
                    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
                    return true
                }
                handler(reply, nil)
            } else {
                handler(nil, SlideError.unsupportedFormat)
            }
        } catch {
            handler(nil, error)
        }
    }
}

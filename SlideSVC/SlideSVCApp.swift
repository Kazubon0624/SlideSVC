import SwiftUI
import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupNotificationListener()
    }
    
    private func setupNotificationListener() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleCopyNotification(_:)),
            name: NSNotification.Name("com.forensic.slidesvc.copyClipboard"),
            object: nil
        )
    }
    
    @objc private func handleCopyNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let path = userInfo["path"] as? String else {
            return
        }
        
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        
        do {
            let data = try Data(contentsOf: url)
            if let image = NSImage(data: data) {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([image])
                NSLog("SlideSVC Host App: Successfully copied image from QL to clipboard. Path: \(path)")
            }
            
            // Clean up temporary file
            try FileManager.default.removeItem(at: url)
        } catch {
            NSLog("SlideSVC Host App: Failed to copy image or remove temp file: \(error.localizedDescription)")
        }
    }
}

@main
struct SlideSVCApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)
            
            Text("SlideSVC")
                .font(.largeTitle)
                .fontWeight(.semibold)
            
            Text("Virtual Slide Quick Look Plugin")
                .font(.headline)
                .foregroundColor(.secondary)
            
            Divider()
                .padding(.vertical)
            
            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(icon: "eye.fill", text: "Leica SCN files (.scn)")
                FeatureRow(icon: "eye.fill", text: "Hamamatsu NDPI files (.ndpi)")
                FeatureRow(icon: "photo.fill", text: "Thumbnail & Preview support")
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(12)
            
            Spacer()
            
            Text("Select a .scn or .ndpi file in Finder and press Space for Quick Look")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(minWidth: 400, minHeight: 350)
    }
}

struct FeatureRow: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .frame(width: 24)
            Text(text)
        }
    }
}

#Preview {
    ContentView()
}

import Cocoa
import Quartz
import QuickLookUI
import UniformTypeIdentifiers
import SlideCore
import os

// MARK: - Signpost Logger

private let signpostLog = OSLog(subsystem: "com.forensic.slidesvc.preview", category: "Performance")
private let signposter = OSSignposter(logHandle: signpostLog)
/// Track files already previewed in this process lifetime for cold/warm classification
private var seenFiles = Set<String>()

// MARK: - PerfLogger (os_log-based, no file I/O)

/// Emits performance measurements via os_log at .error level (always visible)
/// Capture: `log stream --predicate 'subsystem == "com.forensic.slidesvc.perf"'`
private final class PerfLogger {
    static let shared = PerfLogger()
    private let perfLog = OSLog(subsystem: "com.forensic.slidesvc.perf", category: "measurement")
    private init() {}
    
    func log(interval: String, mode: String, file: String, durationMs: Double, status: String) {
        os_log(.error, log: perfLog,
               "[PERF] interval=%{public}@,mode=%{public}@,file=%{public}@,duration_ms=%{public}.2f,status=%{public}@",
               interval, mode, file, durationMs, status)
    }
}

// MARK: - PreviewViewController

class PreviewViewController: NSViewController, QLPreviewingController {
    
    private var slideView: SlideView!
    private var minimapView: MinimapView!
    private var infoBar: NSView!
    private var zoomLabel: NSTextField!
    private var currentFileName: String = "slide"
    var ttfvState: OSSignpostIntervalState?
    var ttfvStartTime: CFAbsoluteTime = 0
    var ttfvMode: String = "cold"
    var ttfvFileName: String = ""
    
    override var nibName: NSNib.Name? { nil }
    
    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(white: 0.11, alpha: 1).cgColor
        self.view = v
        self.preferredContentSize = NSSize(width: 1200, height: 900)
    }
    
    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        NSLog("SlideQLPreview: preparePreviewOfFile called for %@", url.path)
        
        // --- TTFV signpost begin ---
        let fileName = url.lastPathComponent
        let mode = seenFiles.contains(fileName) ? "warm" : "cold"
        seenFiles.insert(fileName)
        let ttfvState = signposter.beginInterval("TTFV", id: signposter.makeSignpostID(), "file=\(fileName, privacy: .public) mode=\(mode, privacy: .public)")
        self.ttfvState = ttfvState
        self.ttfvStartTime = CFAbsoluteTimeGetCurrent()
        self.ttfvMode = mode
        self.ttfvFileName = fileName
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let reader = try SlideReader(url: url)
                let (slideW, slideH) = reader.dimensions(forLevel: 0)
                let levelCount = reader.levelCount
                let vendor = reader.vendor ?? "Unknown"
                let objective = reader.objectivePower ?? "N/A"
                
                // Generate overview thumbnail for minimap
                let overviewImage = self.generateOverview(reader: reader, maxSize: 256)
                
                DispatchQueue.main.async {
                    self.buildUI(
                        reader: reader,
                        overviewImage: overviewImage,
                        fileName: url.lastPathComponent,
                        slideWidth: slideW,
                        slideHeight: slideH,
                        levelCount: levelCount,
                        vendor: vendor,
                        objective: objective
                    )
                    handler(nil)
                }
            } catch {
                NSLog("SlideQLPreview: OpenSlide error: %@", error.localizedDescription)
                signposter.endInterval("TTFV", ttfvState, "error")
                self.ttfvState = nil
                
                // Fallback: direct NDPI TIFF parser with 4GB overflow correction
                if let result = NDPIFallbackReader.loadBestImage(url: url) {
                    DispatchQueue.main.async {
                        self.showFallbackPreview(result: result, fileName: url.lastPathComponent)
                        handler(nil)
                    }
                } else {
                    self.showError("このファイルを開けません\n\n\(error.localizedDescription)\n\nNDPIファイルが4GBを超える場合、OpenSlide 4.0の制限により表示できないことがあります。", handler: handler)
                }
            }
        }
    }
    
    private func generateOverview(reader: SlideReader, maxSize: Int) -> NSImage? {
        let levels = reader.levelCount
        guard levels > 0 else { return nil }
        var bestLevel: Int32 = levels - 1
        for level in (0..<levels).reversed() {
            let (w, h) = reader.dimensions(forLevel: level)
            if w <= Int64(maxSize) && h <= Int64(maxSize) {
                bestLevel = level
                break
            }
        }
        let (lw, lh) = reader.dimensions(forLevel: bestLevel)
        let w = Int(lw), h = Int(lh)
        guard w > 0 && h > 0 else { return nil }
        if let cg = reader.readRegion(x: 0, y: 0, level: bestLevel, width: w, height: h) {
            return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
        }
        return nil
    }
    
    private func showError(_ message: String, handler: @escaping (Error?) -> Void) {
        DispatchQueue.main.async {
            let icon = NSTextField(labelWithString: "⚠️")
            icon.font = NSFont.systemFont(ofSize: 48)
            icon.alignment = .center
            icon.translatesAutoresizingMaskIntoConstraints = false
            
            let label = NSTextField(labelWithString: message)
            label.textColor = NSColor(white: 0.7, alpha: 1)
            label.font = NSFont.systemFont(ofSize: 14)
            label.alignment = .center
            label.maximumNumberOfLines = 0
            label.translatesAutoresizingMaskIntoConstraints = false
            
            let stack = NSStackView(views: [icon, label])
            stack.orientation = .vertical
            stack.spacing = 12
            stack.translatesAutoresizingMaskIntoConstraints = false
            self.view.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: self.view.centerYAnchor),
                stack.widthAnchor.constraint(lessThanOrEqualTo: self.view.widthAnchor, constant: -40)
            ])
            handler(nil)
        }
    }
    
    // MARK: - NDPI Fallback (zoomable preview for large NDPI files)
    
    /// Show a zoomable/pannable preview for NDPI files OpenSlide cannot open
    private func showFallbackPreview(result: NDPIFallbackReader.FallbackResult, fileName: String) {
        let imgW = CGFloat(result.width)
        let imgH = CGFloat(result.height)
        let nsImage = NSImage(cgImage: result.image, size: NSSize(width: imgW, height: imgH))
        
        // Scrollable, zoomable image view
        let imageView = NSImageView()
        imageView.image = nsImage
        imageView.imageScaling = .scaleNone
        imageView.setFrameSize(NSSize(width: imgW, height: imgH))
        
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 10.0
        scrollView.backgroundColor = NSColor(white: 0.11, alpha: 1)
        scrollView.drawsBackground = true
        scrollView.documentView = imageView
        scrollView.magnification = 1.0
        view.addSubview(scrollView)
        
        // Info bar at top
        let infoBar = NSView()
        infoBar.wantsLayer = true
        infoBar.layer?.backgroundColor = NSColor(white: 0.14, alpha: 0.95).cgColor
        infoBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(infoBar)
        
        let baseName = (fileName as NSString).deletingPathExtension
        let nameLabel = NSTextField(labelWithString: baseName)
        nameLabel.font = NSFont.boldSystemFont(ofSize: 13)
        nameLabel.textColor = .white
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        infoBar.addSubview(nameLabel)
        
        let sizeText = "\(result.width)×\(result.height)  •  Level \(result.levelIndex)/\(result.totalLevels)"
        let sizeLabel = NSTextField(labelWithString: sizeText)
        sizeLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        sizeLabel.textColor = NSColor(white: 0.55, alpha: 1)
        sizeLabel.translatesAutoresizingMaskIntoConstraints = false
        infoBar.addSubview(sizeLabel)
        
        let noteLabel = NSTextField(labelWithString: "NDPI > 4GB — フォールバック表示  |  ⌘スクロール: ズーム  ドラッグ: パン")
        noteLabel.font = NSFont.systemFont(ofSize: 10)
        noteLabel.textColor = NSColor(white: 0.45, alpha: 1)
        noteLabel.translatesAutoresizingMaskIntoConstraints = false
        infoBar.addSubview(noteLabel)
        
        NSLayoutConstraint.activate([
            infoBar.topAnchor.constraint(equalTo: view.topAnchor),
            infoBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            infoBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            infoBar.heightAnchor.constraint(equalToConstant: 44),
            
            nameLabel.leadingAnchor.constraint(equalTo: infoBar.leadingAnchor, constant: 12),
            nameLabel.topAnchor.constraint(equalTo: infoBar.topAnchor, constant: 6),
            
            sizeLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 12),
            sizeLabel.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            
            noteLabel.leadingAnchor.constraint(equalTo: infoBar.leadingAnchor, constant: 12),
            noteLabel.bottomAnchor.constraint(equalTo: infoBar.bottomAnchor, constant: -5),
            
            scrollView.topAnchor.constraint(equalTo: infoBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        
        // Fit image to view after layout
        DispatchQueue.main.async {
            let viewSize = scrollView.contentSize
            let scaleX = viewSize.width / imgW
            let scaleY = viewSize.height / imgH
            scrollView.magnification = min(scaleX, scaleY, 1.0)
        }
    }
    
    // MARK: - Build UI
    
    private func buildUI(reader: SlideReader, overviewImage: NSImage?, fileName: String,
                          slideWidth: Int64, slideHeight: Int64, levelCount: Int32,
                          vendor: String, objective: String) {
        
        currentFileName = (fileName as NSString).deletingPathExtension
        
        // === Slide view (main area) - add first so it's behind overlays ===
        slideView = SlideView()
        slideView.translatesAutoresizingMaskIntoConstraints = false
        slideView.parentVC = self
        slideView.reader = reader
        slideView.slideWidth = slideWidth
        slideView.slideHeight = slideHeight
        slideView.onViewportChanged = { [weak self] in
            self?.updateMinimap()
            self?.updateZoomLabel()
        }
        view.addSubview(slideView)
        
        // === Info bar (added after slideView to stay on top) ===
        infoBar = NSView()
        infoBar.wantsLayer = true
        infoBar.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        infoBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(infoBar)
        
        let sep = NSView()
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor(white: 0.25, alpha: 1).cgColor
        sep.translatesAutoresizingMaskIntoConstraints = false
        infoBar.addSubview(sep)
        
        let infoItems = [
            "📄 \(fileName)",
            "📐 \(formatSize(slideWidth, slideHeight))",
            "🏭 \(vendor)",
            "🔬 \(objective)x"
        ]
        let infoStack = NSStackView(views: infoItems.map { makeInfoLabel($0) })
        infoStack.orientation = .horizontal
        infoStack.spacing = 16
        infoStack.translatesAutoresizingMaskIntoConstraints = false
        infoBar.addSubview(infoStack)
        
        // === Minimap ===
        minimapView = MinimapView()
        minimapView.translatesAutoresizingMaskIntoConstraints = false
        minimapView.wantsLayer = true
        minimapView.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.92).cgColor
        minimapView.layer?.cornerRadius = 6
        minimapView.layer?.borderColor = NSColor(white: 0.3, alpha: 1).cgColor
        minimapView.layer?.borderWidth = 1
        minimapView.overviewImage = overviewImage
        minimapView.slideWidth = slideWidth
        minimapView.slideHeight = slideHeight
        minimapView.onNavigate = { [weak self] (cx, cy) in
            self?.slideView.centerX = cx
            self?.slideView.centerY = cy
            self?.slideView.clampViewport()
            self?.slideView.requestReload()
        }
        view.addSubview(minimapView)
        
        // === Zoom controls ===
        let controlBar = NSView()
        controlBar.wantsLayer = true
        controlBar.layer?.backgroundColor = NSColor(white: 0.13, alpha: 0.95).cgColor
        controlBar.layer?.cornerRadius = 7
        controlBar.layer?.borderColor = NSColor(white: 0.25, alpha: 1).cgColor
        controlBar.layer?.borderWidth = 1
        controlBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controlBar)
        
        let zoomOutBtn = makeCtrlBtn("−", action: #selector(zoomOut))
        zoomLabel = NSTextField(labelWithString: "100%")
        zoomLabel.textColor = NSColor(white: 0.8, alpha: 1)
        zoomLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        zoomLabel.alignment = .center
        zoomLabel.translatesAutoresizingMaskIntoConstraints = false
        let zoomInBtn = makeCtrlBtn("+", action: #selector(zoomIn))
        let fitBtn = makeCtrlBtn("⊡", action: #selector(zoomFit))
        let saveBtn = makeCtrlBtn("📷", action: #selector(saveAsPNG))
        
        let ctrlStack = NSStackView(views: [zoomOutBtn, zoomLabel, zoomInBtn, fitBtn, saveBtn])
        ctrlStack.orientation = .horizontal
        ctrlStack.spacing = 2
        ctrlStack.translatesAutoresizingMaskIntoConstraints = false
        controlBar.addSubview(ctrlStack)
        
        // === Layout ===
        let minimapSize: CGFloat = 160
        NSLayoutConstraint.activate([
            infoBar.topAnchor.constraint(equalTo: view.topAnchor),
            infoBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            infoBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            infoBar.heightAnchor.constraint(equalToConstant: 32),
            sep.leadingAnchor.constraint(equalTo: infoBar.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: infoBar.trailingAnchor),
            sep.bottomAnchor.constraint(equalTo: infoBar.bottomAnchor),
            sep.heightAnchor.constraint(equalToConstant: 1),
            infoStack.centerYAnchor.constraint(equalTo: infoBar.centerYAnchor),
            infoStack.leadingAnchor.constraint(equalTo: infoBar.leadingAnchor, constant: 12),
            
            slideView.topAnchor.constraint(equalTo: infoBar.bottomAnchor),
            slideView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            slideView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            slideView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            minimapView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            minimapView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            minimapView.widthAnchor.constraint(equalToConstant: minimapSize),
            minimapView.heightAnchor.constraint(equalToConstant: minimapSize * CGFloat(slideHeight) / CGFloat(max(1, slideWidth))),
            
            controlBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            controlBar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            ctrlStack.topAnchor.constraint(equalTo: controlBar.topAnchor, constant: 5),
            ctrlStack.bottomAnchor.constraint(equalTo: controlBar.bottomAnchor, constant: -5),
            ctrlStack.leadingAnchor.constraint(equalTo: controlBar.leadingAnchor, constant: 6),
            ctrlStack.trailingAnchor.constraint(equalTo: controlBar.trailingAnchor, constant: -6),
            zoomLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 46),
        ])
        
        // Initial load after layout
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.slideView.fitToView()
        }
    }
    
    // MARK: - Updates
    
    private func updateMinimap() {
        guard let sv = slideView else { return }
        let viewW = sv.bounds.width
        let viewH = sv.bounds.height
        guard viewW > 0 && viewH > 0 && sv.zoom > 0 else { return }
        let visW = viewW / sv.zoom
        let visH = viewH / sv.zoom
        let x0 = sv.centerX - visW / 2
        let y0 = sv.centerY - visH / 2
        minimapView?.updateViewport(
            x: x0, y: y0,
            width: visW, height: visH
        )
    }
    
    private func updateZoomLabel() {
        guard let sv = slideView else { return }
        let pct = Int(sv.zoom * 100)
        zoomLabel?.stringValue = "\(pct)%"
    }
    
    // MARK: - Zoom actions
    
    @objc private func zoomIn() {
        slideView?.zoomBy(factor: 1.5)
    }
    
    @objc private func zoomOut() {
        slideView?.zoomBy(factor: 1.0 / 1.5)
    }
    
    @objc private func zoomFit() {
        slideView?.fitToView()
    }
    
    @objc private func saveAsPNG() {
        // Capture the entire view including minimap and zoom controls
        guard let slideV = slideView else { return }
        
        let viewBounds = view.bounds
        guard viewBounds.width > 0 && viewBounds.height > 0 else { return }
        
        // Use high-res slide image as base, then composite minimap and zoom on top
        guard let reader = slideV.reader else { return }
        
        let viewW = Double(slideV.bounds.width)
        let viewH = Double(slideV.bounds.height)
        guard viewW > 0 && viewH > 0 else { return }
        let visW = viewW / slideV.zoom
        let visH = viewH / slideV.zoom
        let x0 = slideV.centerX - visW / 2
        let y0 = slideV.centerY - visH / 2
        
        // Read at good resolution (up to 4096px)
        let exportScale = min(4096.0 / visW, 4096.0 / visH, 1.0 / slideV.zoom * 2)
        let downsampleFactor = 1.0 / exportScale
        let level = reader.bestLevelForDownsample(downsampleFactor)
        let levelDS = reader.downsample(forLevel: level)
        
        let readW = min(4096, Int(ceil(visW / levelDS)))
        let readH = min(4096, Int(ceil(visH / levelDS)))
        let capturedZoom = slideV.zoom
        let capturedSlideW = slideV.slideWidth
        let capturedSlideH = slideV.slideHeight
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            guard let slideImage = reader.readRegion(x: Int64(max(0, x0)), y: Int64(max(0, y0)),
                                                      level: level, width: max(1, readW), height: max(1, readH)) else {
                return
            }
            
            let outW = slideImage.width
            let outH = slideImage.height
            
            // Create composite image
            let compositeImage = NSImage(size: NSSize(width: outW, height: outH))
            compositeImage.lockFocus()
            
            // 1. Draw slide image
            let slideNS = NSImage(cgImage: slideImage, size: NSSize(width: outW, height: outH))
            slideNS.draw(in: NSRect(x: 0, y: 0, width: outW, height: outH))
            
            // 2. Draw minimap in bottom-right corner
            let mmSize = min(200, outW / 4, outH / 4)
            let mmMargin = 12
            let mmX = outW - mmSize - mmMargin
            let mmY = mmMargin  // bottom-right in flipped = bottom-right
            let mmRect = NSRect(x: mmX, y: mmY, width: mmSize, height: mmSize * Int(capturedSlideH) / max(1, Int(capturedSlideW)))
            
            // Minimap background
            NSColor(white: 0.1, alpha: 0.85).setFill()
            let mmPath = NSBezierPath(roundedRect: mmRect, xRadius: 6, yRadius: 6)
            mmPath.fill()
            
            // Minimap border
            NSColor(white: 0.3, alpha: 1).setStroke()
            mmPath.lineWidth = 2
            mmPath.stroke()
            
            // Minimap overview image
            if let overview = self.minimapView?.overviewImage {
                let inset = 4
                let imgRect = NSRect(x: mmRect.minX + CGFloat(inset), y: mmRect.minY + CGFloat(inset),
                                     width: mmRect.width - CGFloat(inset * 2), height: mmRect.height - CGFloat(inset * 2))
                overview.draw(in: imgRect)
                
                // Viewport indicator on minimap
                let scaleX = imgRect.width / CGFloat(capturedSlideW)
                let scaleY = imgRect.height / CGFloat(capturedSlideH)
                let vpRect = NSRect(
                    x: imgRect.minX + CGFloat(x0) * scaleX,
                    y: imgRect.minY + CGFloat(y0) * scaleY,
                    width: max(4, CGFloat(visW) * scaleX),
                    height: max(4, CGFloat(visH) * scaleY)
                )
                NSColor(red: 0.3, green: 0.69, blue: 0.31, alpha: 0.25).setFill()
                vpRect.fill()
                NSColor(red: 0.3, green: 0.69, blue: 0.31, alpha: 0.9).setStroke()
                let vpPath = NSBezierPath(rect: vpRect)
                vpPath.lineWidth = 2
                vpPath.stroke()
            }
            
            // 3. Draw zoom percentage label in bottom-left
            let zoomPct = Int(capturedZoom * 100)
            let zoomStr = "\(zoomPct)%" as NSString
            let zoomFont = NSFont.monospacedDigitSystemFont(ofSize: CGFloat(max(14, outH / 40)), weight: .semibold)
            let zoomAttrs: [NSAttributedString.Key: Any] = [
                .font: zoomFont,
                .foregroundColor: NSColor.white
            ]
            let zoomSize = zoomStr.size(withAttributes: zoomAttrs)
            let zoomPadH: CGFloat = 12
            let zoomPadV: CGFloat = 8
            let zoomBgRect = NSRect(x: 12, y: CGFloat(mmMargin),
                                     width: zoomSize.width + zoomPadH * 2,
                                     height: zoomSize.height + zoomPadV * 2)
            NSColor(white: 0.13, alpha: 0.9).setFill()
            NSBezierPath(roundedRect: zoomBgRect, xRadius: 7, yRadius: 7).fill()
            zoomStr.draw(at: NSPoint(x: zoomBgRect.minX + zoomPadH, y: zoomBgRect.minY + zoomPadV),
                         withAttributes: zoomAttrs)
            
            compositeImage.unlockFocus()
            
            DispatchQueue.main.async {
                // Fallback direct copy (might fail inside Sandbox, but keep as fallback)
                let pb = NSPasteboard.general
                pb.clearContents()
                let directSuccess = pb.writeObjects([compositeImage])
                
                // Host application bridge copy
                if let tiffData = compositeImage.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiffData),
                   let pngData = bitmap.representation(using: .png, properties: [:]) {
                    
                    let tempDir = NSTemporaryDirectory()
                    let fileName = "slide_capture_\(UUID().uuidString).png"
                    let fileURL = URL(fileURLWithPath: tempDir).appendingPathComponent(fileName)
                    
                    do {
                        try pngData.write(to: fileURL)
                        
                        // Send notification to the host app
                        DistributedNotificationCenter.default().postNotificationName(
                            NSNotification.Name("com.forensic.slidesvc.copyClipboard"),
                            object: nil,
                            userInfo: ["path": fileURL.path],
                            deliverImmediately: true
                        )
                        NSLog("SlideQLPreview: Posted copy notification with path: \(fileURL.path), directSuccess: \(directSuccess)")
                    } catch {
                        NSLog("SlideQLPreview: Failed to write temp file for clipboard: \(error.localizedDescription)")
                    }
                }
                
                self.showCopyFeedback()
            }
        }
    }
    
    private func showCopyFeedback() {
        let feedback = NSTextField(labelWithString: "✅ クリップボードにコピーしました")
        feedback.textColor = .white
        feedback.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        feedback.alignment = .center
        feedback.wantsLayer = true
        feedback.layer?.backgroundColor = NSColor(white: 0.2, alpha: 0.9).cgColor
        feedback.layer?.cornerRadius = 8
        feedback.translatesAutoresizingMaskIntoConstraints = false
        feedback.sizeToFit()
        
        // Add padding by wrapping in a container
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.95).cgColor
        container.layer?.cornerRadius = 10
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(feedback)
        view.addSubview(container)
        
        NSLayoutConstraint.activate([
            feedback.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            feedback.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            feedback.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            feedback.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            container.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            container.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        
        container.alphaValue = 0
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            container.animator().alphaValue = 1
        }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.4
                    container.animator().alphaValue = 0
                }) {
                    container.removeFromSuperview()
                }
            }
        }
    }
    
    // MARK: - Helpers
    
    private func makeInfoLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.textColor = NSColor(white: 0.65, alpha: 1)
        l.font = NSFont.systemFont(ofSize: 11)
        l.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return l
    }
    
    private func makeCtrlBtn(_ title: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .inline
        b.isBordered = false
        b.contentTintColor = NSColor(white: 0.85, alpha: 1)
        b.font = NSFont.systemFont(ofSize: 17, weight: .medium)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 30).isActive = true
        b.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return b
    }
    
    private func formatSize(_ w: Int64, _ h: Int64) -> String {
        if w >= 10000 || h >= 10000 {
            return String(format: "%.1fK × %.1fK", Double(w)/1000, Double(h)/1000)
        }
        return "\(w) × \(h)"
    }
}

// MARK: - SlideView: Multi-resolution tile viewer

class SlideView: NSView {
    
    var reader: SlideReader!
    var slideWidth: Int64 = 0
    var slideHeight: Int64 = 0
    
    /// Viewport center in level-0 coordinates
    var centerX: Double = 0
    var centerY: Double = 0
    
    /// Zoom: view pixels per level-0 pixel
    var zoom: Double = 0.1
    
    var onViewportChanged: (() -> Void)?
    
    private var currentImage: CGImage?
    private var isLoading = false
    private var pendingReload = false
    private var isDragging = false
    private var lastDragPoint: NSPoint = .zero
    private var reloadTimer: Timer?
    
    /// Signpost state for NavLatency interval
    private var navSignpostState: OSSignpostIntervalState?
    private var navStartTime: CFAbsoluteTime = 0
    /// Reference to parent VC for TTFV end signpost
    weak var parentVC: PreviewViewController?
    
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Enable trackpad gesture events (pinch zoom)
        allowedTouchTypes = [.indirect]  // trackpad touches
        wantsRestingTouches = true
    }
    
    var minZoom: Double {
        guard slideWidth > 0, slideHeight > 0, bounds.width > 0, bounds.height > 0 else { return 0.005 }
        let sx = Double(bounds.width) / Double(slideWidth)
        let sy = Double(bounds.height) / Double(slideHeight)
        return min(sx, sy) * 0.5
    }
    
    var maxZoom: Double { 3.0 }
    
    func fitToView() {
        guard slideWidth > 0, slideHeight > 0, bounds.width > 0, bounds.height > 0 else { return }
        centerX = Double(slideWidth) / 2
        centerY = Double(slideHeight) / 2
        let sx = Double(bounds.width) / Double(slideWidth)
        let sy = Double(bounds.height) / Double(slideHeight)
        zoom = min(sx, sy) * 0.92
        loadVisibleRegion()
        onViewportChanged?()
    }
    
    func zoomBy(factor: Double) {
        let newZoom = max(minZoom, min(maxZoom, zoom * factor))
        zoom = newZoom
        clampViewport()
        requestReload()
    }
    
    func clampViewport() {
        let vw = bounds.width > 0 ? Double(bounds.width) : 800
        let vh = bounds.height > 0 ? Double(bounds.height) : 600
        let halfW = vw / zoom / 2
        let halfH = vh / zoom / 2
        centerX = max(halfW * 0.2, min(Double(slideWidth) - halfW * 0.2, centerX))
        centerY = max(halfH * 0.2, min(Double(slideHeight) - halfH * 0.2, centerY))
    }
    
    func requestReload() {
        needsDisplay = true
        onViewportChanged?()
        reloadTimer?.invalidate()
        
        // --- NavLatency signpost begin ---
        // Cancel previous if still pending (debounce)
        if let prev = navSignpostState {
            signposter.endInterval("NavLatency", prev, "cancelled")
        }
        navSignpostState = signposter.beginInterval("NavLatency", id: signposter.makeSignpostID())
        navStartTime = CFAbsoluteTimeGetCurrent()
        
        reloadTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: false) { [weak self] _ in
            self?.loadVisibleRegion()
        }
    }
    
    // MARK: - Tile Loading
    
    func loadVisibleRegion() {
        guard let reader = reader else { return }
        guard !isLoading else {
            pendingReload = true
            return
        }
        isLoading = true
        
        let viewW = Double(bounds.width)
        let viewH = Double(bounds.height)
        guard viewW > 0 && viewH > 0 else {
            isLoading = false
            return
        }
        
        // Visible region in level-0 coords
        let visW = viewW / zoom
        let visH = viewH / zoom
        let x0 = centerX - visW / 2
        let y0 = centerY - visH / 2
        
        // Find best level for current zoom
        let downsampleFactor = 1.0 / zoom
        let level = reader.bestLevelForDownsample(downsampleFactor)
        let levelDS = reader.downsample(forLevel: level)
        let (levelMaxW, levelMaxH) = reader.dimensions(forLevel: level)
        
        // Pixels to read in level coordinates
        // Add padding to avoid edge artifacts
        let padL0: Double = 100  // padding in level-0 coords
        let readX0 = max(0, x0 - padL0)
        let readY0 = max(0, y0 - padL0)
        let readX1 = min(Double(slideWidth), x0 + visW + padL0)
        let readY1 = min(Double(slideHeight), y0 + visH + padL0)
        
        let regionW = readX1 - readX0
        let regionH = readY1 - readY0
        
        var readW = Int(ceil(regionW / levelDS))
        var readH = Int(ceil(regionH / levelDS))
        
        // Limit to reasonable size to prevent memory issues
        let maxPixels = 4096
        if readW > maxPixels {
            readW = maxPixels
        }
        if readH > maxPixels {
            readH = maxPixels
        }
        readW = min(readW, Int(levelMaxW))
        readH = min(readH, Int(levelMaxH))
        
        let capturedX0 = readX0
        let capturedY0 = readY0
        let capturedRegionW = regionW
        let capturedRegionH = regionH
        
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let cgImage = reader.readRegion(
                x: Int64(capturedX0),
                y: Int64(capturedY0),
                level: level,
                width: max(1, readW),
                height: max(1, readH)
            )
            
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let img = cgImage {
                    self.currentImage = img
                    self.currentImageRegion = (capturedX0, capturedY0, capturedRegionW, capturedRegionH)
                }
                self.isLoading = false
                self.needsDisplay = true
                
                // --- TTFV signpost end (first view) ---
                if let vc = self.parentVC, let ttfvState = vc.ttfvState {
                    signposter.endInterval("TTFV", ttfvState, "rendered")
                    let elapsed = (CFAbsoluteTimeGetCurrent() - vc.ttfvStartTime) * 1000.0
                    PerfLogger.shared.log(interval: "TTFV", mode: vc.ttfvMode, file: vc.ttfvFileName, durationMs: elapsed, status: "rendered")
                    vc.ttfvState = nil
                }
                
                // --- NavLatency signpost end ---
                if let navState = self.navSignpostState {
                    signposter.endInterval("NavLatency", navState, "rendered")
                    let elapsed = (CFAbsoluteTimeGetCurrent() - self.navStartTime) * 1000.0
                    PerfLogger.shared.log(interval: "NavLatency", mode: "", file: "", durationMs: elapsed, status: "rendered")
                    self.navSignpostState = nil
                }
                
                if self.pendingReload {
                    self.pendingReload = false
                    self.loadVisibleRegion()
                }
            }
        }
    }
    
    /// Region covered by currentImage in level-0 coords: (x, y, w, h)
    private var currentImageRegion: (Double, Double, Double, Double) = (0, 0, 0, 0)
    
    // MARK: - Drawing
    
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        
        // Background
        ctx.setFillColor(NSColor(white: 0.11, alpha: 1).cgColor)
        ctx.fill(bounds)
        
        guard let img = currentImage else { return }
        
        let (imgX0, imgY0, imgW, imgH) = currentImageRegion
        guard imgW > 0 && imgH > 0 else { return }
        
        // Convert image region (level-0 coords) to view coords
        let viewW = Double(bounds.width)
        let viewH = Double(bounds.height)
        let visOriginX = centerX - viewW / zoom / 2
        let visOriginY = centerY - viewH / zoom / 2
        
        let drawX = (imgX0 - visOriginX) * zoom
        let drawY = (imgY0 - visOriginY) * zoom
        let drawW = imgW * zoom
        let drawH = imgH * zoom
        
        // NSView with isFlipped=true: origin at top-left
        // CGContext in flipped view: need to flip for image drawing
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(bounds.height))
        ctx.scaleBy(x: 1, y: -1)
        
        let flippedDrawY = Double(bounds.height) - drawY - drawH
        
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: drawX, y: flippedDrawY, width: drawW, height: drawH))
        ctx.restoreGState()
    }
    
    // MARK: - Mouse Events
    
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            // Double-click = zoom in at click location
            let mouse = convert(event.locationInWindow, from: nil)
            let mouseSlideX = centerX + (Double(mouse.x) - Double(bounds.width) / 2) / zoom
            let mouseSlideY = centerY + (Double(mouse.y) - Double(bounds.height) / 2) / zoom
            let newZoom = max(minZoom, min(maxZoom, zoom * 2.0))
            zoom = newZoom
            centerX = mouseSlideX - (Double(mouse.x) - Double(bounds.width) / 2) / zoom
            centerY = mouseSlideY - (Double(mouse.y) - Double(bounds.height) / 2) / zoom
            clampViewport()
            requestReload()
            return
        }
        isDragging = true
        lastDragPoint = convert(event.locationInWindow, from: nil)
        NSCursor.closedHand.push()
    }
    
    override func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let dx = Double(pt.x - lastDragPoint.x)
        let dy = Double(pt.y - lastDragPoint.y)
        lastDragPoint = pt
        
        // isFlipped=true: positive dy means mouse moved down = slide moves up
        centerX -= dx / zoom
        centerY += dy / zoom
        
        clampViewport()
        requestReload()
    }
    
    override func mouseUp(with event: NSEvent) {
        isDragging = false
        NSCursor.pop()
    }
    
    override func magnify(with event: NSEvent) {
        let factor = 1.0 + Double(event.magnification)
        let newZoom = max(minZoom, min(maxZoom, zoom * factor))
        
        // Zoom toward pinch center
        let mouse = convert(event.locationInWindow, from: nil)
        let mouseSlideX = centerX + (Double(mouse.x) - Double(bounds.width) / 2) / zoom
        let mouseSlideY = centerY + (Double(mouse.y) - Double(bounds.height) / 2) / zoom
        
        zoom = newZoom
        
        centerX = mouseSlideX - (Double(mouse.x) - Double(bounds.width) / 2) / zoom
        centerY = mouseSlideY - (Double(mouse.y) - Double(bounds.height) / 2) / zoom
        
        clampViewport()
        requestReload()
    }
    
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            // Cmd/Ctrl + scroll = zoom
            let delta = Double(-event.scrollingDeltaY) * 0.03
            let factor = exp(delta)
            let newZoom = max(minZoom, min(maxZoom, zoom * factor))
            zoom = newZoom
        } else {
            // Regular scroll = pan
            centerX -= Double(event.scrollingDeltaX) / zoom
            centerY -= Double(event.scrollingDeltaY) / zoom
        }
        clampViewport()
        requestReload()
    }
    
    override func keyDown(with event: NSEvent) {
        let step = 80.0 / zoom  // pan step in level-0 coords
        switch event.charactersIgnoringModifiers {
        case "+", "=": zoomBy(factor: 1.5)
        case "-": zoomBy(factor: 1.0 / 1.5)
        case "0": fitToView()
        default:
            switch event.keyCode {
            case 123: centerX -= step; clampViewport(); requestReload()  // left
            case 124: centerX += step; clampViewport(); requestReload()  // right
            case 125: centerY += step; clampViewport(); requestReload()  // down
            case 126: centerY -= step; clampViewport(); requestReload()  // up
            default: super.keyDown(with: event)
            }
        }
    }
}

// MARK: - MinimapView

class MinimapView: NSView {
    
    var overviewImage: NSImage?
    var slideWidth: Int64 = 0
    var slideHeight: Int64 = 0
    var onNavigate: ((Double, Double) -> Void)?
    
    // Current viewport in level-0 coords
    private var vpX: Double = 0
    private var vpY: Double = 0
    private var vpW: Double = 0
    private var vpH: Double = 0
    
    override var isFlipped: Bool { true }
    
    func updateViewport(x: Double, y: Double, width: Double, height: Double) {
        vpX = x; vpY = y; vpW = width; vpH = height
        needsDisplay = true
    }
    
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        
        // Background
        ctx.setFillColor(NSColor(white: 0.1, alpha: 0.92).cgColor)
        ctx.fill(bounds)
        
        guard slideWidth > 0, slideHeight > 0 else { return }
        
        // Draw overview image
        let inset: CGFloat = 4
        let drawArea = bounds.insetBy(dx: inset, dy: inset)
        let aspectSlide = CGFloat(slideWidth) / CGFloat(slideHeight)
        let aspectArea = drawArea.width / drawArea.height
        
        var imgRect: CGRect
        if aspectSlide > aspectArea {
            let h = drawArea.width / aspectSlide
            imgRect = CGRect(x: drawArea.minX, y: drawArea.minY + (drawArea.height - h) / 2, width: drawArea.width, height: h)
        } else {
            let w = drawArea.height * aspectSlide
            imgRect = CGRect(x: drawArea.minX + (drawArea.width - w) / 2, y: drawArea.minY, width: w, height: drawArea.height)
        }
        
        if let img = overviewImage {
            // Flip for image drawing in flipped view
            ctx.saveGState()
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            let flippedRect = CGRect(x: imgRect.minX, y: bounds.height - imgRect.maxY, width: imgRect.width, height: imgRect.height)
            if let cgImg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                ctx.interpolationQuality = .high
                ctx.draw(cgImg, in: flippedRect)
            }
            ctx.restoreGState()
        }
        
        // Draw viewport indicator
        let scaleX = imgRect.width / CGFloat(slideWidth)
        let scaleY = imgRect.height / CGFloat(slideHeight)
        
        let rectX = imgRect.minX + CGFloat(vpX) * scaleX
        let rectY = imgRect.minY + CGFloat(vpY) * scaleY
        let rectW = max(4, CGFloat(vpW) * scaleX)
        let rectH = max(4, CGFloat(vpH) * scaleY)
        
        let vpRect = CGRect(x: rectX, y: rectY, width: rectW, height: rectH)
            .intersection(imgRect.insetBy(dx: -2, dy: -2))
        
        // Fill
        ctx.setFillColor(NSColor(red: 0.3, green: 0.69, blue: 0.31, alpha: 0.2).cgColor)
        ctx.fill(vpRect)
        
        // Border
        ctx.setStrokeColor(NSColor(red: 0.3, green: 0.69, blue: 0.31, alpha: 0.9).cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(vpRect)
    }
    
    override func mouseDown(with event: NSEvent) {
        navigateTo(event: event)
    }
    
    override func mouseDragged(with event: NSEvent) {
        navigateTo(event: event)
    }
    
    private func navigateTo(event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        guard slideWidth > 0, slideHeight > 0 else { return }
        
        let inset: CGFloat = 4
        let drawArea = bounds.insetBy(dx: inset, dy: inset)
        let aspectSlide = CGFloat(slideWidth) / CGFloat(slideHeight)
        let aspectArea = drawArea.width / drawArea.height
        
        var imgRect: CGRect
        if aspectSlide > aspectArea {
            let h = drawArea.width / aspectSlide
            imgRect = CGRect(x: drawArea.minX, y: drawArea.minY + (drawArea.height - h) / 2, width: drawArea.width, height: h)
        } else {
            let w = drawArea.height * aspectSlide
            imgRect = CGRect(x: drawArea.minX + (drawArea.width - w) / 2, y: drawArea.minY, width: w, height: drawArea.height)
        }
        
        let relX = (pt.x - imgRect.minX) / imgRect.width
        let relY = (pt.y - imgRect.minY) / imgRect.height
        
        let slideX = Double(relX) * Double(slideWidth)
        let slideY = Double(relY) * Double(slideHeight)
        
        onNavigate?(slideX, slideY)
    }
}

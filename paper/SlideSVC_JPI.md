# SlideSVC: A Native macOS Quick Look Extension for Instant Whole Slide Image Preview in Digital Pathology

**Article Type:** Technical Note

**Running Title:** Quick Look Extension for WSI Files

---

## Author Information

**[Author Name]**^1

^1 Department of [Pathology/Forensic Medicine], [Institution], [City], Japan

**Corresponding Author:**
[Author Name]
Email: [email]
ORCID: [ORCID ID]

---

## Abstract

**Background:** Previewing whole slide image (WSI) files in digital pathology requires launching dedicated viewer applications, creating friction in daily file management workflows.

**Methods:** We developed SlideSVC, a macOS Quick Look extension that provides instant multi-resolution preview of WSI files directly from the Finder file browser. The tool uses the OpenSlide library with a custom tile-based rendering engine implemented in Swift. Users can preview slides by selecting a file and pressing the spacebar.

**Results:** SlideSVC renders initial slide overviews within approximately 0.5–1.0 seconds and supports dynamic zoom with real-time multi-resolution tile loading. The viewer includes a navigational minimap and clipboard export functionality. Five major WSI formats are supported: SVS, NDPI, SCN, BIF, and MRXS.

**Conclusions:** SlideSVC integrates virtual microscopy into the native macOS file browser, enabling rapid identification and assessment of WSI files without dedicated viewer software. The tool is freely available as open-source software at https://github.com/Kazubon0624/SlideSVC.

**Keywords:** digital pathology; whole slide imaging; Quick Look; macOS; OpenSlide; virtual microscopy

---

## Introduction

The transition from glass slides to digital whole slide imaging (WSI) in anatomic pathology has been facilitated by regulatory approvals for primary diagnosis and advances in scanning technology.^1,2^ WSI files are typically stored in proprietary formats such as Aperio SVS (.svs), Hamamatsu NDPI (.ndpi), and Leica SCN (.scn), with file sizes ranging from 100 MB to 3 GB per slide.^3^

A common but underappreciated challenge in digital pathology practice is the rapid identification of WSI files. Existing solutions for viewing WSI files fall into two broad categories, neither optimized for quick file identification. First, enterprise digital pathology platforms (e.g., Philips IntelliSite Pathology Solution, Sectra Digital Pathology, Proscia Concentriq) provide comprehensive image management through centralized server infrastructure, requiring significant institutional investment in hardware, networking, and IT support.^5^ Second, standalone desktop applications such as QuPath,^4^ ASAP, and vendor-specific viewers (CaseViewer, ImageScope) offer powerful annotation and analysis capabilities but require explicit application launch, file loading, and navigation—substantial overhead for the simple task of identifying a specific slide in a directory.

Neither approach addresses the common scenario of a pathologist or researcher browsing a local file system containing WSI files and needing to quickly identify slide contents without launching dedicated software or accessing a remote server.

macOS provides Quick Look, a system-level framework that renders instant file previews when a user selects a file in Finder and presses the spacebar. This ubiquitous mechanism supports documents, images, and media files through third-party extensions. However, no existing tool provides multi-resolution WSI preview through this interface.

We developed SlideSVC, a macOS Quick Look extension that enables instant, multi-resolution virtual microscopy of WSI files directly within the operating system's file browser. The tool requires no server infrastructure, no application launch, and no configuration—only a single 6 MB application install. It is implemented using the OpenSlide library^3^ and is distributed as open-source software.

## Materials and Methods

### System Architecture

SlideSVC is a macOS application bundle containing three system extensions (Figure 1):

- **SlideQLPreview**: Quick Look preview extension providing the interactive virtual slide viewer
- **SlideQLThumbnail**: Thumbnail extension for Finder icon view
- **SlideQLGenerator**: Legacy thumbnail generator for backward compatibility

The host application runs as a background agent without a user interface, serving solely to register the extensions with the operating system.

### Core Library

The SlideReader module provides a Swift interface to the OpenSlide C library.^3^ It handles file validation, metadata extraction (vendor, magnification objective, slide dimensions), multi-resolution pyramid access, and optimal level selection via `bestLevelForDownsample()`.

### Multi-Resolution Rendering

The preview extension implements a custom view class that functions as a virtual microscopy viewport with the following pipeline:

1. The visible region is computed in level-0 (full resolution) coordinate space based on the current viewport center and zoom factor.
2. The optimal pyramid level is selected to match the current display resolution.
3. A region is read from the selected level (capped at 4096 × 4096 pixels) on a background thread.
4. The ARGB pixel buffer from OpenSlide is converted to a displayable image using Core Graphics with matching byte order and alpha specifications.
5. A 150 ms debounce timer coalesces rapid viewport changes during continuous gestures.

### User Interface

The viewer supports the following interactions:

- **Pan**: mouse drag, scroll wheel, arrow keys, minimap click
- **Zoom**: trackpad pinch, Cmd+scroll, double-click (2× zoom), +/− keys
- **Export**: clipboard copy of current viewport with minimap overlay and zoom percentage
- **Overview**: persistent minimap showing full slide with viewport indicator (green rectangle)

### Supported Formats

Five WSI formats are supported through custom Uniform Type Identifier (UTI) registration: Aperio SVS (.svs), Hamamatsu NDPI (.ndpi), Leica SCN (.scn), Ventana BIF (.bif), and 3DHISTECH MRXS (.mrxs).

### Technical Stack

The tool is written in Swift 5 with Objective-C bridging for OpenSlide. All native library dependencies are embedded within the application bundle, eliminating external dependency requirements for end users. The application targets macOS 13 (Ventura) and later on Apple Silicon processors.

### Availability

SlideSVC is available under the MIT license at https://github.com/Kazubon0624/SlideSVC. Pre-built DMG installers are provided in the GitHub Releases.

## Results

### Performance

Initial slide overview rendering completes within 0.5–1.0 seconds for typical SVS files (200–500 MB). Region reloading during zoom and pan operations completes within 100–300 ms, providing responsive interaction across all supported zoom levels.

### Workflow Impact

SlideSVC transforms the WSI file browsing workflow. Without the extension, identifying a specific slide in a directory requires repeatedly launching a viewer application for each file. With SlideSVC, users navigate through files using arrow keys in Finder while the Quick Look preview updates instantly, enabling visual identification without leaving the file browser.

The clipboard export feature allows users to capture the current viewport—including the slide region, minimap with viewport indicator, and zoom percentage—as a single composite image for direct use in presentations and reports.

### Thumbnail Integration

The thumbnail extension generates static preview images for Finder's icon and gallery views, providing visual identification of WSI files alongside standard file metadata (Figure 2).

## Discussion

SlideSVC addresses a specific operational inefficiency in digital pathology: the inability to rapidly preview WSI files without dedicated software or server infrastructure. By leveraging the macOS Quick Look framework, it integrates virtual microscopy directly into the operating system's file browser with zero configuration.

### Comparison with Existing Approaches

Table 1 compares SlideSVC with existing WSI viewing solutions across key practical dimensions.

**Table 1.** Comparison of WSI viewing approaches.

| Feature | Enterprise Platforms^a^ | Desktop Viewers^b^ | SlideSVC |
|---|---|---|---|
| Server required | Yes | No | **No** |
| Application launch | Web browser | Dedicated app | **None (spacebar)** |
| Installation size | Server + client | 200 MB–1 GB | **6 MB** |
| IT support required | Yes | Minimal | **None** |
| Time to first view | Seconds (network) | 5–15 s (app launch) | **< 1 s** |
| Multi-resolution zoom | Yes | Yes | **Yes** |
| Annotation/Analysis | Extensive | Extensive | No |
| File browsing integration | No | No | **Native Finder** |
| Cost | Commercial license | Free/Commercial | **Free (MIT)** |

^a^ Philips IntelliSite, Sectra, Proscia Concentriq. ^b^ QuPath, ASAP, CaseViewer, ImageScope.

The key advantage of SlideSVC lies in its minimal footprint and zero-friction access. Enterprise platforms provide comprehensive case management and collaboration features but require server hardware, network infrastructure, and IT administration—resources not available in many smaller pathology departments, research laboratories, or individual practice settings.^6^ Desktop viewers such as QuPath^4^ are powerful tools for image analysis and annotation but are designed as full-featured applications with substantial installation footprints and startup overhead that is disproportionate to the simple task of identifying a slide.

SlideSVC occupies a previously unfilled niche: instant, local, zero-overhead WSI preview. It does not aim to replace either enterprise platforms or desktop viewers but rather to eliminate the most frequent low-complexity interaction—"what is in this file?"—from requiring any dedicated software.

### Design Considerations

Unlike static thumbnail solutions, SlideSVC provides true multi-resolution virtual microscopy, allowing users to assess tissue quality, staining characteristics, and regional features directly from the Quick Look panel. The navigational minimap maintains spatial orientation during high-magnification browsing.

The tool operates within the macOS application sandbox, which constrains file system access. This necessitated the clipboard-based export approach and required embedding all native library dependencies within the application bundle—a design choice that also benefits end users by eliminating any external dependency installation.

### Limitations

The current implementation is limited to macOS on Apple Silicon processors. Cross-platform implementations using analogous operating system extensibility frameworks (Windows Preview Handlers, GNOME Nautilus extensions) could extend this approach to other platforms. SlideSVC does not provide annotation, measurement, or quantitative analysis features; users requiring such capabilities should use dedicated viewers such as QuPath.^4^

## Conclusions

SlideSVC is a lightweight, open-source macOS Quick Look extension that enables instant multi-resolution preview of whole slide images from the operating system's file browser. It supports five major WSI formats and provides interactive virtual microscopy, navigational minimap, and clipboard export functionality. The tool reduces friction in WSI file management workflows and is freely available for the digital pathology community.

## Conflict of Interest

The author declares no conflict of interest.

## Funding

This work did not receive any specific grant from funding agencies in the public, commercial, or not-for-profit sectors.

## Author Contributions

[Author Name]: Conceptualization, Methodology, Software, Writing – Original Draft, Writing – Review & Editing.

---

## Figure Legends

**Figure 1.** SlideSVC system architecture. The application bundle contains three system extensions: SlideQLPreview (interactive virtual slide viewer), SlideQLThumbnail (Finder thumbnail generator), and SlideQLGenerator (legacy thumbnail support). The SlideReader module provides a Swift interface to the OpenSlide C library. All dependencies are embedded within the application bundle.

**Figure 2.** SlideSVC Quick Look preview of an Aperio SVS whole slide image. (A) Full slide overview showing the tissue section. (B) Zoomed view demonstrating multi-resolution rendering with navigational minimap (lower right, green rectangle indicates current viewport) and zoom controls. (C) Finder icon view showing auto-generated slide thumbnails.

---

## References

1. Pantanowitz L, Sinard JH, Henricks WH, et al. Validating whole slide imaging for diagnostic purposes in pathology: guideline from the College of American Pathologists Pathology and Laboratory Quality Center. *Arch Pathol Lab Med*. 2013;137(12):1710-1722.

2. Mukhopadhyay S, Feldman MD, Abels E, et al. Whole slide imaging versus microscopy for primary diagnosis in surgical pathology: a multicenter blinded randomized noninferiority study of 1992 cases (Pivotal Study). *Am J Surg Pathol*. 2018;42(1):39-52.

3. Goode A, Gilbert B, Harkes J, Jukic D, Satyanarayanan M. OpenSlide: A vendor-neutral software foundation for digital pathology. *J Pathol Inform*. 2013;4:27.

4. Bankhead P, Loughrey MB, Fernández JA, et al. QuPath: Open source software for digital pathology image analysis. *Sci Rep*. 2017;7(1):16878.

5. Farahani N, Parwani AV, Pantanowitz L. Whole slide imaging in pathology: advantages, limitations, and emerging perspectives. *Pathol Lab Med Int*. 2015;7:23-33.

6. Hanna MG, Reuter VE, Hameed MR, et al. Whole slide imaging equivalency and efficiency study: experience at a large academic medical center. *Mod Pathol*. 2019;32(7):916-928.

7. Niazi MKK, Parwani AV, Gurcan MN. Digital pathology and artificial intelligence. *Lancet Oncol*. 2019;20(5):e253-e261.

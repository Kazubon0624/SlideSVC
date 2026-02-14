# SlideSVC: A Native macOS Quick Look Extension for Instant Whole Slide Image Preview in Digital Pathology

## Abstract

Digital pathology increasingly relies on whole slide images (WSIs) for diagnosis, education, and research. However, previewing WSI files such as Aperio SVS typically requires launching dedicated viewer applications, creating friction in routine file management workflows. We developed SlideSVC, a native macOS Quick Look extension that enables instant multi-resolution preview of WSIs directly from the Finder file browser. Built upon the OpenSlide library with a custom multi-resolution rendering engine, SlideSVC provides dynamic tile-based rendering, a navigational minimap, and clipboard export functionality—all accessible by simply pressing the spacebar on a selected file. SlideSVC supports five major WSI formats (SVS, NDPI, SCN, BIF, MRXS) and is freely available as open-source software. This tool substantially reduces the time required to locate and identify slide files in digital pathology workflows, particularly in environments managing large WSI archives.

**Keywords:** digital pathology, whole slide imaging, Quick Look, macOS, OpenSlide, virtual microscopy

---

## Introduction

The adoption of whole slide imaging (WSI) in anatomic and forensic pathology has accelerated over the past decade, driven by advances in slide scanning technology and regulatory approvals for primary diagnosis [1,2]. WSI files, often stored in proprietary formats such as Aperio SVS (.svs), Hamamatsu NDPI (.ndpi), and Leica SCN (.scn), are typically large (100 MB–3 GB per slide) and contain multi-resolution pyramid image data [3].

A persistent practical challenge in digital pathology workflows is the rapid identification and preview of WSI files. Unlike standard image formats (JPEG, PNG, TIFF), WSI files cannot be previewed natively by operating system file managers. Pathologists and researchers must open dedicated viewer applications—such as QuPath [4], ASAP, or vendor-specific software—to inspect slide contents, even for simple tasks such as verifying specimen identity or confirming scan quality.

macOS provides a system-level extensibility framework called Quick Look, which allows third-party developers to register preview extensions for custom file types. When a user selects a file in Finder and presses the spacebar, the operating system renders an instant preview using the registered extension. This mechanism is widely used for documents, images, and media files, but no existing solution provides multi-resolution WSI preview through Quick Look.

We developed SlideSVC, a macOS Quick Look extension that enables instant, multi-resolution preview of WSI files directly within the operating system's file browser. By integrating the OpenSlide library [3] with a custom tile-based rendering engine, SlideSVC provides a virtual microscopy experience without requiring users to launch a dedicated application.

## Materials and Methods

### System Architecture

SlideSVC is implemented as a macOS application bundle containing three system extensions:

1. **SlideQLPreview** — Quick Look preview extension providing the interactive virtual slide viewer
2. **SlideQLThumbnail** — Thumbnail extension generating static previews for Finder icon view
3. **SlideQLGenerator** — Legacy thumbnail generator for backward compatibility

The application serves solely as a host for these extensions and runs as a background agent (LSUIElement) without a visible user interface or Dock presence.

### Core Library

SlideReader, the core component, provides a Swift interface to the OpenSlide C library [3]. OpenSlide is a vendor-neutral, open-source library for reading WSI files that supports multiple scanner formats. SlideReader wraps OpenSlide's functionality for:

- Opening and validating slide files
- Reading metadata (vendor, magnification objective, dimensions)
- Accessing the multi-resolution image pyramid
- Reading rectangular regions at any pyramid level
- Optimal level selection based on the current zoom factor via `bestLevelForDownsample()`

### Multi-Resolution Rendering Engine

The preview extension implements a custom `NSView` subclass (`SlideView`) that functions as a virtual microscopy viewport. The rendering pipeline operates as follows:

1. **Viewport Calculation**: The visible region is computed in level-0 (highest resolution) coordinate space based on the current center position and zoom factor.
2. **Optimal Level Selection**: The `bestLevelForDownsample()` method selects the pyramid level that most closely matches the current display resolution, avoiding unnecessary data transfer from higher-resolution levels.
3. **Region Reading**: A rectangular region is read from the selected level using OpenSlide's `openslide_read_region()` function. The read dimensions are capped at 4096 × 4096 pixels to maintain responsive interaction.
4. **Image Composition**: The raw ARGB pixel buffer is converted to a `CGImage` using Core Graphics with appropriate byte order specification (`premultipliedFirst` + `byteOrder32Little`) matching OpenSlide's native output format on ARM architectures.
5. **Asynchronous Rendering**: All OpenSlide I/O operations execute on a background dispatch queue to maintain UI responsiveness. A debounce timer (150 ms) coalesces rapid viewport changes to prevent excessive reloading during smooth pan and zoom operations.

### Navigational Minimap

A persistent minimap overlay displays a low-resolution overview of the entire slide with a green viewport indicator showing the current field of view. The minimap supports click-to-navigate for rapid repositioning. The overview image is generated once during initialization by reading the lowest-resolution pyramid level.

### User Interaction

The viewer supports multiple input methods:

| Input | Action |
|-------|--------|
| Mouse drag | Pan viewport |
| Trackpad pinch | Zoom in/out at gesture center |
| Scroll wheel | Pan (vertical and horizontal) |
| Cmd/Ctrl + scroll | Zoom |
| Double-click | 2× zoom at click location |
| Minimap click | Jump to location |
| Keyboard arrows | Pan |
| +/− keys | Zoom in/out |

### Clipboard Export

Users can capture the current viewport as a composite image copied to the system clipboard. The exported image includes: (1) the high-resolution slide region (up to 4096 pixels), (2) a minimap overlay indicating the captured area, and (3) a zoom percentage label. This facilitates rapid figure preparation for presentations and reports without requiring external screenshot tools.

### Supported Formats

SlideSVC registers custom Uniform Type Identifiers (UTIs) for five major WSI formats:

| Format | Extension | Scanner Vendor |
|--------|-----------|----------------|
| Aperio SVS | .svs | Leica Biosystems |
| Hamamatsu NDPI | .ndpi | Hamamatsu Photonics |
| Leica SCN | .scn | Leica Biosystems |
| Ventana BIF | .bif | Roche/Ventana |
| 3DHISTECH MRXS | .mrxs | 3DHISTECH Ltd. |

### Implementation Details

SlideSVC is written in Swift 5 with Objective-C bridging for the OpenSlide C library. The project uses XcodeGen for project file generation and Swift Package Manager for dependency management. All OpenSlide dependencies (including libjpeg-turbo, libpng, libtiff, libopenjp2, glib, gdk-pixbuf, cairo, pixman, libxml2, sqlite3) are embedded within the application bundle using `install_name_tool` path rewriting, eliminating the need for Homebrew or other package managers on end-user machines.

The application targets macOS 13 (Ventura) and later on Apple Silicon (arm64) processors.

## Results

### Preview Performance

SlideSVC renders an initial slide overview within approximately 0.5–1.0 seconds of Quick Look invocation for typical SVS files (200–500 MB). Subsequent zoom and pan operations trigger region reloads that complete within 100–300 ms, depending on the requested region size and pyramid level. The 150 ms debounce timer ensures smooth interaction during continuous gestures.

### File Management Workflow

In practical use, SlideSVC transforms the WSI file management workflow:

- **Before**: Locating a specific slide in a directory of WSI files required opening each file individually in a viewer application, waiting for application launch and file loading, then closing and repeating.
- **After**: Users navigate through files with arrow keys in Finder while the Quick Look preview updates instantly, enabling rapid visual identification of slides without leaving the file browser.

### Thumbnail Generation

The thumbnail extension generates static preview images that appear in Finder's icon and gallery views, providing visual identification even without invoking Quick Look. Thumbnails are generated from the lowest-resolution pyramid level or associated thumbnail images embedded in the WSI file.

### Distribution

SlideSVC is distributed as a DMG disk image (approximately 6 MB) and as open-source code on GitHub (https://github.com/Kazubon0624/SlideSVC) under the MIT license.

## Discussion

SlideSVC addresses a specific but frequently encountered friction point in digital pathology workflows: the inability to quickly preview WSI files without launching dedicated viewer software. By leveraging the macOS Quick Look framework, the tool integrates seamlessly into the operating system's native file management interface.

Several design decisions merit discussion:

**Multi-resolution rendering vs. static preview**: Unlike a simple thumbnail viewer, SlideSVC provides true multi-resolution virtual microscopy within the Quick Look window. This allows users not only to identify slides but also to perform quick assessments of tissue quality, staining characteristics, and region-of-interest location without opening a full viewer application.

**Sandbox constraints**: macOS Quick Look extensions operate within a strict application sandbox that limits file system access and inter-process communication. This constraint influenced the clipboard-based export approach rather than direct file saving, and required embedding all native library dependencies within the application bundle.

**Platform limitation**: The current implementation targets macOS exclusively, as Quick Look is a macOS-specific framework. Windows users may consider alternative approaches such as Windows Preview Handler extensions, and Linux users may explore Nautilus/GNOME file manager extensions. A cross-platform approach using similar operating system extensibility mechanisms could be explored in future work.

**Comparison with existing tools**: While comprehensive WSI viewers such as QuPath [4], CaseViewer (3DHISTECH), and ImageScope (Leica) provide rich annotation and analysis features, SlideSVC serves a complementary role as a rapid file identification and preview tool. It is not intended to replace dedicated viewers but rather to reduce the frequency with which they must be launched for simple preview tasks.

## Conclusion

SlideSVC provides a native macOS Quick Look extension for instant multi-resolution preview of whole slide images in digital pathology. By integrating OpenSlide with a custom tile-based rendering engine, it enables pathologists and researchers to rapidly browse and identify WSI files without launching dedicated viewer applications. The tool supports five major WSI formats and is freely available as open-source software.

## Acknowledgments

SlideSVC uses the OpenSlide library (https://openslide.org), developed by Carnegie Mellon University.

## References

1. Pantanowitz L, Sinard JH, Henricks WH, et al. Validating whole slide imaging for diagnostic purposes in pathology: guideline from the College of American Pathologists Pathology and Laboratory Quality Center. *Arch Pathol Lab Med*. 2013;137(12):1710–1722.

2. Mukhopadhyay S, Feldman MD, Abels E, et al. Whole slide imaging versus microscopy for primary diagnosis in surgical pathology: a multicenter blinded randomized noninferiority study of 1992 cases (Pivotal Study). *Am J Surg Pathol*. 2018;42(1):39–52.

3. Goode A, Gilbert B, Harkes J, Jukic D, Satyanarayanan M. OpenSlide: A vendor-neutral software foundation for digital pathology. *J Pathol Inform*. 2013;4:27.

4. Bankhead P, Loughrey MB, Fernández JA, et al. QuPath: Open source software for digital pathology image analysis. *Sci Rep*. 2017;7(1):16878.

5. Farahani N, Parwani AV, Pantanowitz L. Whole slide imaging in pathology: advantages, limitations, and emerging perspectives. *Pathol Lab Med Int*. 2015;7:23–33.

6. Al-Janabi S, Huisman A, Van Diest PJ. Digital pathology: current status and future perspectives. *Histopathology*. 2012;61(1):1–9.

7. Hanna MG, Reuter VE, Hameed MR, et al. Whole slide imaging equivalency and efficiency study: experience at a large academic medical center. *Mod Pathol*. 2019;32(7):916–928.

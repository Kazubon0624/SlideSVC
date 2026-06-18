# SlideSVC

macOS Quick Look extension for virtual slide files (.svs, .ndpi, .scn, .bif, .mrxs).

Finderでバーチャルスライドファイルを選択してスペースキーを押すだけで、マルチレゾリューション表示が可能です。

## Features

- 🔬 **Virtual Slide Viewer** — ズームに応じてOpenSlideのマルチレベルから最適な解像度をリアルタイム読み込み
- 🗺️ **Minimap** — 全体像と現在の表示位置を常に表示
- 📷 **Clipboard Copy** — 表示中の領域をミニマップ＋ズーム率付きでクリップボードにコピー
- 🖼️ **Thumbnail** — Finderでサムネイル表示
- 📎 **Large NDPI Support** — 4GB超のNDPIファイルも独自TIFFパーサーによるフォールバック表示（ズーム/パン可能）

## Supported Formats

| Format | Extension | Vendor |
|--------|-----------|--------|
| Aperio SVS | `.svs` | Leica Biosystems |
| Hamamatsu NDPI | `.ndpi` | Hamamatsu Photonics |
| Leica SCN | `.scn` | Leica Biosystems |
| Ventana BIF | `.bif` | Roche / Ventana |
| 3DHISTECH MRXS | `.mrxs` | 3DHISTECH |

## Update History

### v1.1.1 (2026-06-18)

- **Thumbnail Display Fix**: Retinaディスプレイなどの高解像度環境において、Finderでのサムネイル表示が左上に小さく（1/4サイズに）偏って表示されてしまう問題を修正。

### v1.1

- **Large NDPI Support**: 4GBを超える巨大な Hamamatsu NDPI ファイルについて、独自TIFFパーサーによるフォールバック表示を実装（ズーム/パン対応）。
- **Performance Logging**: TTFV（表示完了までの時間）や描画遅延の計測（OSSignposter/PerfLogger）を追加。
- **Trackpad Support**: トラックパッドのピンチズームジェスチャーをサポート。
- **Color Fix**: 色レンダリングがおかしくなる問題を修正。

## Requirements

- macOS 13+ (Ventura or later)
- Apple Silicon (arm64)
- [Homebrew](https://brew.sh)

## Build

```bash
# Install dependencies
brew install openslide xcodegen

# Generate Xcode project
xcodegen generate

# Build
xcodebuild -project SlideSVC.xcodeproj -scheme SlideSVC -configuration Release build

# Install
cp -R ~/Library/Developer/Xcode/DerivedData/SlideSVC-*/Build/Products/Release/SlideSVC.app ~/Applications/
```

## Controls

| Action | Operation |
|--------|-----------|
| Drag | Pan |
| Pinch / Cmd+Scroll | Zoom |
| Double-click | Zoom in at location |
| ⊡ button | Fit to view |
| 📷 button | Copy to clipboard |
| Minimap click | Jump to location |
| Arrow keys | Pan |
| +/- keys | Zoom in/out |
| 0 key | Fit to view |

## Architecture

```
SlideSVC.app
├── SlideSVC (host app, agent/background)
├── SlideQLPreview.appex (Quick Look preview extension)
├── SlideQLThumbnail.appex (thumbnail extension)
├── SlideQLGenerator.appex (thumbnail generator)
└── Frameworks/ (embedded OpenSlide + dependencies)
```

## License

MIT

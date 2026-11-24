# Chiaro

**Native macOS HDR-First RAW Darkroom & Batch CLI** — built in Swift 6 & Metal for Apple Silicon.

Chiaro (*Italian for "light, bright, clear" — from Chiaroscuro*) develops camera RAW files (`.ARW`) in a scene-linear `rgba16Float` Metal GPU pipeline and exports standards-compliant **ISO/IEC 21496-1:2025 Gain Map HDR** photos and **10-bit BT.2020 HLG** motion exports across Apple Photos, Chrome/Web, Android, Xiaohongshu (小红书), and Douyin (抖音).

[![Platform](https://img.shields.io/badge/platform-macOS%2015%2B%20Apple%20Silicon-black)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-6.0%2B-F05138)](#building-from-source)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Dependencies](https://img.shields.io/badge/GPL%20%2F%20LGPL-Zero-brightgreen)](THIRD_PARTY_NOTICES.md)

---

## Highlights (V1.0)

- **Dual RAW Decoding Backends**
  - **LibRaw `0.22.3` (CDDL-1.0, default)**: 14-bit unclipped linear decode, highlight reconstruction, and Sony Lossless Compressed RAW support.
  - **Apple `CIRAWFilter` v9 (optional `--backend ciraw9`)**: Native Apple Neural Engine (ANE) demosaicing and high-ISO night denoising.
- **Scene-Linear Metal GPU Pipeline**
  - `rgba16Float` + bucketed `MTLHeap` texture pool (`<= 4.5 GiB` Peak RSS on full 35-image 33MP batches).
  - Linear Rec.2020 scene grading → **Midtone-locked dual-branch tone mapping** (AgX / Neutral Rational / OpenDRT, independent SDR & HDR shoulder control) → OKLab soft gamut compression to Display P3.
- **ISO/IEC 21496-1:2025 Gain Map Engine**
  - Strongly typed `HeadroomStops (log2)` vs `LinearHeadroom`, symmetric offset $k = 1/64$, 64×64 Blue-Noise TPDF dithering, anti-halo 1/2 linear downsampling, 1-channel monochrome (`L008`) and 3-channel RGB (`BGRA`), plus closed-loop JPEG SDR re-compression compensation.
- **Four ADR-Compliant Export Pipelines (Single Decode, Parallel Fan-Out)**
  - **HEIC (`.heic`)**: Hardware-accelerated Apple `ImageIO` 10-bit/8-bit Display P3 + ISO 21496-1 `tmap` (optional iOS 14–17 1ch legacy dual-write; strictly forbids broken 3ch dual-write).
  - **JPEG (`.jpg`)**: 1ch Ultra HDR v1.1 via `google/libultrahdr` (dual ISO APP2 + `hdrgm:` XMP + MPF, automatic file-size capping for social platforms) and 3ch pure ISO APP2 + MPF via `ImageIO`.
  - **AVIF (`.avif`)**: `libavif` + `SVT-AV1` / `libaom` 10-bit Display P3 + ISO `tmap` + automatic **MIAF Baseline 5.1 Grid Tiling** for `>4096px` / `>8.9MP` images (33MP & 61MP landscape/portrait).
  - **10-bit HLG MP4 (`.mp4`)**: Native `AVAssetWriter` + VideoToolbox 10-bit HEVC Main10 `BT.2020 HLG` (`1080×1920` / `1080×1440`, 30fps, 12–16 Mbps) for Douyin guaranteed-HDR playback.
- **Safe EXIF 2.32 Migration**
  - Whitelisted EXIF injection, strips oversized Sony `0x927C` MakerNote, physically rotates pixels before encoding and writes `Orientation = 1`.
- **Native macOS Desktop App (`Chiaro.app`)**
  - 120Hz EDR `MTKView` (`wantsExtendedDynamicRangeContent = true`, `.rgba16Float`, `extendedLinearDisplayP3`) running the real ISO 21496-1 inverse decode formula.
  - iPhone `1× / 2× / 4× / 8×` Headroom simulation, SDR external monitor exposure-scale mode, split-screen compare, Headroom false-color heatmap, dual-zone histogram, `G`-key Gain Map view, batch queue with per-photo deltas, post-export compliance badges, and platform publishing guide.
- **Zero GPL / Zero LGPL Dependencies**
  - Enforced by [`Scripts/verify_licenses.sh`](Scripts/verify_licenses.sh) across static archives, symbols (`nm`), and recursive Mach-O linkage (`otool -L`).

---

## Roadmap

- [x] **V1.0**: Scene-linear Metal pipeline, dual RAW decoders (`LibRaw` + `CIRAWv9`), ISO 21496-1 HEIC / Ultra HDR JPEG / Grid-Tiled AVIF / 10-bit HLG MP4, 7 built-in presets, `chiaro` CLI, and 120Hz EDR `Chiaro.app`.
- [ ] **V1.1 — AI Denoise**: On-device Apple Silicon CoreML / Metal neural RAW denoising for high-ISO night photography.
- [ ] **V1.2 — Color Grading Studio**: Interactive Lift/Gamma/Gain color wheels, HSL/OKLab targeted color grading, curves, film looks, and `.cube` LUT presets.

---

## Quick Start

### Option 1: Download Prebuilt Release (Apple Silicon, macOS 15+)

Download from [**GitHub Releases**](https://github.com/ZhangLiangchen/Chiaro/releases):
- **`Chiaro-1.0.0-macos-arm64.zip`**: Standalone `Chiaro.app` with bundled BSD AV1 frameworks (no Homebrew required).
- **`chiaro-cli-1.0.0-macos-arm64.tar.gz`**: Standalone `chiaro` CLI + resource bundle + bundled AV1 dylibs.

> **Note (ad-hoc signed open-source build):** If macOS Gatekeeper warns on first launch, run:
> ```bash
> xattr -dr com.apple.quarantine /Applications/Chiaro.app
> ```

### Option 2: CLI Usage (`chiaro`)

```bash
# List all 7 built-in presets
chiaro --list-presets

# Export Apple Photos 10-bit Display P3 HEIC (default preset)
chiaro ./RAW_Photos -o ./output

# Export Xiaohongshu HDR JPEG (3:4, <= 2048px, <= 4MB, 1ch Ultra HDR v1.1)
chiaro ./RAW_Photos -p xiaohongshu_jpg -o ./output_xhs

# Export Tri-Format Archive (10-bit HEIC + Ultra HDR JPEG + Grid-Tiled 10-bit AVIF)
chiaro ./RAW_Photos -p tri_format --format-subdirs -o ./output_archive

# Export Douyin 10-bit BT.2020 HLG MP4 with Apple ANE CIRAW v9 denoising
chiaro ./RAW_Photos -p douyin_hlg_mp4 --backend ciraw9 -o ./output_douyin
```

### Built-in Presets (`Presets/*.json`)

| Preset ID | Description | Formats | Target Headroom |
|---|---|---|---|
| `apple_heic` | Apple Photos Native High-Fidelity | 10-bit HEIC (3ch RGB Gain Map) | `2.5 EV` (`5.66×`) |
| `apple_heic_compat` | Apple Full-Gen Compatible (iOS 14–27) | 10-bit HEIC (1ch + legacy dual-write) | `2.5 EV` (`5.66×`) |
| `xiaohongshu_jpg` | Xiaohongshu HDR Recommended | 8-bit Ultra HDR JPEG (`≤2048px`, `≤4MB`, 3:4) | `2.5 EV` (`5.66×`) |
| `douyin_jpg` | Douyin Photo HDR Compatible | 8-bit Ultra HDR JPEG (1ch) | `2.5 EV` (`5.66×`) |
| `douyin_hlg_mp4` | Douyin Guaranteed-HDR Motion | 10-bit HEVC Main10 BT.2020 HLG MP4 (`1080×1920`, 4s) | `2.5 EV` (`5.66×`) |
| `tri_format` | All-Platform Tri-Format Archive | HEIC + Ultra HDR JPEG + Grid-Tiled AVIF | `2.5 EV` (`5.66×`) |
| `avif_archive` | Next-Gen Web AVIF Archive | 10-bit AVIF + MIAF 5.1 Grid Tiling | `2.5 EV` (`5.66×`) |

---

## Building from Source

### Requirements
- Apple Silicon Mac (`arm64`) running **macOS 15.0+**
- Swift **6.0+** (Xcode or Command Line Tools)
- [Homebrew](https://brew.sh/) (for building `Vendor` native codecs: `cmake`, `pkgconf`, `svt-av1`, `aom`, `dav1d`, `jpeg-turbo`, `libpng`)

### Build & Test

```bash
# 1. Build zero-GPL/LGPL native XCFrameworks (LibRaw 0.22.3, libultrahdr 2.0.2, libavif 1.4.2)
bash Vendor/build_deps.sh

# 2. Build library & CLI
swift build -c release --product chiaro-cli

# 3. Build standalone signed Chiaro.app (bundles BSD AV1 dylibs inside Contents/Frameworks)
bash Scripts/build_app.sh

# 4. Run unit tests (pass CHIARO_SAMPLE_DIR=/path/to/arw/dir to include real Sony ARW tests)
SVT_LOG=0 swift test

# 5. Verify zero GPL / zero LGPL linkage
bash Scripts/verify_licenses.sh --require-binaries
```

---

## Architecture & Documentation

- Product Requirements: [`docs/PRD.md`](docs/PRD.md)
- Architecture Decision Records (ADR-001 ~ ADR-010): [`docs/ADR.md`](docs/ADR.md)
- Technical Research Baseline: [`docs/RESEARCH.md`](docs/RESEARCH.md)
- E2E Verification Suite: [`Scripts/e2e/README.md`](Scripts/e2e/README.md)

---

## License

Copyright 2026 ZhangLiangchen. Licensed under the [**Apache License 2.0**](LICENSE).  
See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for permissive third-party library attributions.

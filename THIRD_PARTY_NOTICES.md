# Third-Party Notices

Chiaro is engineered with a strict **zero-GPL / zero-LGPL** native dependency policy, verified automatically by [`Scripts/verify_licenses.sh`](Scripts/verify_licenses.sh).

| Component | Version | License | Usage in Chiaro | Upstream |
|---|---|---|---|---|
| **LibRaw** | `0.22.3` | CDDL-1.0 (selected under LibRaw's CDDL/LGPL dual license; zero GPL demosaic packs) | 14-bit linear camera RAW decoding (`CLibRawBridge`) | https://www.libraw.org/ |
| **google/libultrahdr** | `2.0.2` | Apache-2.0 (`-DUHDR_ENABLE_HEIF=OFF`) | Ultra HDR v1.1 JPEG Gain Map encoding (`CUltraHDRBridge`) | https://github.com/google/libultrahdr |
| **libavif** | `1.4.2` | BSD-2-Clause | 10-bit AVIF + ISO 21496-1 `tmap` + MIAF Grid Tiling (`CLibAVIFBridge`) | https://github.com/AOMediaCodec/libavif |
| **SVT-AV1** | `4.x` | BSD-3-Clause-Clear | High-speed 10-bit AV1 encoding for `libavif` | https://gitlab.com/AOMediaCodec/SVT-AV1 |
| **libaom** | `3.x` | BSD-2-Clause | AV1 encoding (including 1-channel YUV400 monochrome gain maps) | https://aomedia.googlesource.com/aom |
| **dav1d** | `1.x` | BSD-2-Clause | AV1 decoding in `libavif` | https://code.videolan.org/videolan/dav1d |
| **libvmaf** | `3.x` | BSD-2-Clause-Patent | Transitive dependency of Homebrew `libaom` | https://github.com/Netflix/vmaf |
| **libjpeg-turbo** | `3.x` | IJG / BSD-3-Clause / zlib | Static JPEG codec for `libultrahdr` | https://github.com/libjpeg-turbo/libjpeg-turbo |
| **libyuv** | bundled by `libavif` | BSD-3-Clause | YUV conversion inside `libavif` | https://chromium.googlesource.com/libyuv/libyuv |

Explicitly excluded libraries (verified absent via symbol and recursive `otool -L` audits): `x265`, `x264`, `Exiv2`, `libheif`, `libde265`, and LibRaw GPL2/GPL3 demosaic packs.

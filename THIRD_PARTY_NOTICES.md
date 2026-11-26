# Third-Party Notices

Chiaro is licensed under the **GNU General Public License v3.0 or later (`GPL-3.0-or-later`)** (see [`LICENSE`](LICENSE)). All native dependencies, static libraries, and bundled datasets are verified GPL-3.0-compatible via [`Scripts/verify_licenses.sh`](Scripts/verify_licenses.sh).

| Component | Version | License | Usage in Chiaro | Upstream |
|---|---|---|---|---|
| **LibRaw** | `0.22.3` | **LGPL-2.1** (explicitly elected under LibRaw's `LGPL-2.1 / CDDL-1.0` dual license; **NOT** `CDDL-1.0`) | 14-bit linear camera RAW decoding, built-in `AHD` / `DCB` / `DHT` / `AAHD` demosaicing, and Sony `SR2SubIFD` decryption (`CLibRawBridge`) | https://www.libraw.org/ |
| **CarVac/librtprocess** | `0.12.0` | `GPL-3.0-or-later` | `AMaZE` & `LMMSE` high-precision Bayer demosaicing via `LibRaw` `callbacks.interpolate_bayer_cb` (`CLibRawBridge`, replacing legacy LibRaw <=0.18 GPL2/GPL3 demosaic packs) | https://github.com/CarVac/librtprocess |
| **Lensfun** | `0.3.4` | `LGPL-3.0-only` | Optical lens profile matching & distortion / TCA / vignetting evaluation (`CLensfunBridge`) | https://lensfun.github.io/ |
| **Lensfun XML Database** | `0.3.4` (`version_1`) | `CC-BY-SA-3.0` | Bundled offline camera & lens calibration XML database (`Sources/ChiaroCore/Resources/LensfunDB/`, license text at `cc-by-sa-3.0.txt`) | https://github.com/lensfun/lensfun |
| **GLib** | `2.x` | `LGPL-2.1-or-later` | Static runtime dependency of `Lensfun` (`libglib-2.0.a`) | https://gitlab.gnome.org/GNOME/glib |
| **gettext (`libintl`)** | `1.x` | `LGPL-2.1-or-later` | Static transitive dependency of `GLib` (`libintl.a`) | https://www.gnu.org/software/gettext/ |
| **PCRE2** | `10.x` | `BSD-3-Clause` | Static transitive dependency of `GLib` (`libpcre2-8.a`) | https://github.com/PCRE2Project/pcre2 |
| **darktable** (algorithm & data attributions) | `GPL-3.0` reference | `GPL-3.0-or-later` | Ported Sony `.ARW` embedded optical curve evaluation (`src/iop/lens.cc`), Profiled Denoise Poisson-Gaussian sensor noise profiles (`noiseprofiles.json`), `Sigmoid` tone mapper (`src/iop/sigmoid.c`), `Inpaint Opposed` highlight reconstruction (`src/iop/highlights.c`), halo-free `Clarity`, and `diffuse or sharpen` optical sharpening principles | https://github.com/darktable-org/darktable |
| **google/libultrahdr** | `2.0.2` | `Apache-2.0` (`-DUHDR_ENABLE_HEIF=OFF`) | Ultra HDR v1.1 JPEG Gain Map encoding (`CUltraHDRBridge`) | https://github.com/google/libultrahdr |
| **libavif** | `1.4.2` | `BSD-2-Clause` | 10-bit AVIF + ISO 21496-1 `tmap` + MIAF Grid Tiling (`CLibAVIFBridge`) | https://github.com/AOMediaCodec/libavif |
| **SVT-AV1** | `4.x` | `BSD-3-Clause-Clear` | High-speed 10-bit AV1 encoding for `libavif` | https://gitlab.com/AOMediaCodec/SVT-AV1 |
| **libaom** | `3.x` | `BSD-2-Clause` | AV1 encoding (including 1-channel YUV400 monochrome gain maps) | https://aomedia.googlesource.com/aom |
| **dav1d** | `1.x` | `BSD-2-Clause` | AV1 decoding in `libavif` | https://code.videolan.org/videolan/dav1d |
| **libvmaf** | `3.x` | `BSD-2-Clause-Patent` | Transitive dependency of Homebrew `libaom` | https://github.com/Netflix/vmaf |
| **libjpeg-turbo** | `3.x` | `IJG / BSD-3-Clause / zlib` | Static JPEG codec for `libultrahdr` | https://github.com/libjpeg-turbo/libjpeg-turbo |
| **libyuv** | bundled by `libavif` | `BSD-3-Clause` | YUV conversion inside `libavif` | https://chromium.googlesource.com/libyuv/libyuv |
| **zlib** | system (`libz.1.dylib`) | `Zlib` | Compression support for `LibRaw` / `libpng` | https://zlib.net/ |

Explicitly excluded dependencies and license elections (enforced by [`Scripts/verify_licenses.sh`](Scripts/verify_licenses.sh) across sources, static archives, symbols, and recursive Mach-O `otool -L` audits): `GPL-2.0-only`, proprietary/closed-source binaries, `x265`, `x264`, `Exiv2`, `libheif`, `libde265`, and `LibRaw` `CDDL-1.0` election.

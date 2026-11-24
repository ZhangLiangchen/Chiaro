"""Generate positive and negative synthetic fixtures for --self-test."""

from __future__ import annotations

import os
import shutil
import struct
import subprocess
from pathlib import Path
from typing import Dict

from config import E2EConfig


def _compile_generator(cfg: E2EConfig, bin_dir: Path) -> Path:
    src = cfg.e2e_root / "selftest" / "generate_fixtures.swift"
    exe = bin_dir / "generate_fixtures"
    if not exe.is_file() or exe.stat().st_mtime < src.stat().st_mtime:
        cmd = [
            cfg.tools.swiftc or "/usr/bin/swiftc",
            "-swift-version",
            "6",
            "-parse-as-library",
            "-O",
            str(src),
            "-o",
            str(exe),
            "-framework",
            "Foundation",
            "-framework",
            "AVFoundation",
            "-framework",
            "CoreGraphics",
            "-framework",
            "CoreImage",
            "-framework",
            "CoreMedia",
            "-framework",
            "CoreVideo",
            "-framework",
            "ImageIO",
            "-framework",
            "UniformTypeIdentifiers",
            "-framework",
            "VideoToolbox",
        ]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        if proc.returncode != 0:
            raise RuntimeError(
                f"Failed to compile generate_fixtures.swift:\n{proc.stderr}\n{proc.stdout}"
            )
    return exe


def build_selftest_fixtures(cfg: E2EConfig, out_dir: Path, bin_dir: Path) -> Dict[str, Path]:
    if out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    bin_dir.mkdir(parents=True, exist_ok=True)

    exe = _compile_generator(cfg, bin_dir)
    proc = subprocess.run([str(exe), str(out_dir)], capture_output=True, text=True, timeout=120)
    if proc.returncode != 0:
        raise RuntimeError(f"generate_fixtures failed:\n{proc.stderr}\n{proc.stdout}")

    # Build valid_grid.avif via avifgainmaputil combine (2x2 grid, 0.5x GM, 10-bit YUV420)
    valid_grid_avif = out_dir / "valid_grid.avif"
    avif_cmd = [
        cfg.tools.avifgainmaputil or "avifgainmaputil",
        "combine",
        str(out_dir / "base_sdr.png"),
        str(out_dir / "alt_hdr.png"),
        str(valid_grid_avif),
        "--cicp-base",
        "12/13/6",
        "--cicp-alternate",
        "12/16/6",
        "--ignore-profile",
        "--max-headroom",
        "2.5",
        "--grid",
        "2x2",
        "--downscaling",
        "2",
        "-d",
        "10",
        "-y",
        "420",
        "--yuv-gain-map",
        "420",
        "-s",
        "8",
    ]
    aproc = subprocess.run(avif_cmd, capture_output=True, text=True, timeout=60)
    if aproc.returncode != 0 or not valid_grid_avif.is_file():
        raise RuntimeError(f"avifgainmaputil combine failed:\n{aproc.stderr}\n{aproc.stdout}")

    # Inject clean EXIF into valid_grid.avif using exiftool (verifies EXIF whitelist on AVIF)
    exiftool = cfg.tools.exiftool or "exiftool"
    subprocess.run(
        [
            exiftool,
            "-overwrite_original",
            "-Make=SONY",
            "-Model=ILCE-7CM2",
            "-LensModel=TAMRON 25-200mm F2.8-5.6 A075 E",
            "-DateTimeOriginal=2026:11:22 18:43:41",
            "-OffsetTimeOriginal=+08:00",
            "-Orientation#=1",
            "-CustomRendered#=3",
            str(valid_grid_avif),
        ],
        capture_output=True,
        text=True,
        check=True,
        timeout=30,
    )

    # Create valid_xmp.jpg by adding XMP-hdrgm tags onto valid.jpg (tests XMP-hdrgm check)
    valid_xmp_jpg = out_dir / "valid_xmp.jpg"
    shutil.copy2(out_dir / "valid.jpg", valid_xmp_jpg)
    subprocess.run(
        [
            exiftool,
            "-overwrite_original",
            "-XMP-hdrgm:Version=1.0",
            "-XMP-hdrgm:BaseRenditionIsHDR=False",
            "-XMP-hdrgm:GainMapMin=0",
            "-XMP-hdrgm:GainMapMax=2.5",
            "-XMP-hdrgm:Gamma=1",
            "-XMP-hdrgm:OffsetSDR=0.015625",
            "-XMP-hdrgm:OffsetHDR=0.015625",
            "-XMP-hdrgm:HDRCapacityMin=0",
            "-XMP-hdrgm:HDRCapacityMax=2.5",
            str(valid_xmp_jpg),
        ],
        capture_output=True,
        text=True,
        check=True,
        timeout=30,
    )

    # Ensure bad_orientation6.jpg has IFD0:Orientation = 6
    subprocess.run(
        [
            exiftool,
            "-overwrite_original",
            "-Orientation#=6",
            "-n",
            str(out_dir / "bad_orientation6.jpg"),
        ],
        capture_output=True,
        text=True,
        check=True,
        timeout=30,
    )

    # Inject a self-contained synthetic Sony MakerNote into bad_makernote.jpg
    bad_makernote_jpg = out_dir / "bad_makernote.jpg"
    shutil.copy2(out_dir / "valid.jpg", bad_makernote_jpg)
    mn_tif = out_dir / "synthetic_sony_mn.tif"
    mn_payload = b"SONY DSC \x00\x00\x00" + struct.pack("<H", 1) + struct.pack("<HHII", 0xB001, 4, 1, 0) + struct.pack("<I", 0)
    make_bytes = b"SONY\x00\x00"
    tif_buf = bytearray()
    tif_buf += b"II" + struct.pack("<HI", 42, 8)
    tif_buf += struct.pack("<H", 2)
    tif_buf += struct.pack("<HHII", 0x010F, 2, 5, 38)
    tif_buf += struct.pack("<HHII", 0x8769, 4, 1, 44)
    tif_buf += struct.pack("<I", 0)
    tif_buf += make_bytes
    tif_buf += struct.pack("<H", 1)
    tif_buf += struct.pack("<HHII", 0x927C, 7, len(mn_payload), 62)
    tif_buf += struct.pack("<I", 0)
    tif_buf += mn_payload
    mn_tif.write_bytes(tif_buf)
    subprocess.run(
        [
            exiftool,
            "-overwrite_original",
            "-TagsFromFile",
            str(mn_tif),
            "-MakerNotes",
            str(bad_makernote_jpg),
        ],
        capture_output=True,
        text=True,
        check=True,
        timeout=30,
    )

    # Create bad_apple_makernote.jpg using a genuine binary Apple iOS MakerNote TIFF IFD (tags 0x0021 & 0x0030)
    bad_apple_jpg = out_dir / "bad_apple_makernote.jpg"
    shutil.copy2(out_dir / "valid.jpg", bad_apple_jpg)
    apple_mn_tif = out_dir / "synthetic_apple_mn.tif"
    apple_mn_payload = (
        b"Apple iOS\x00\x00\x01MM"
        + struct.pack(">H", 2)
        + struct.pack(">HHII", 0x0021, 9, 1, 1)  # tag 33 (HDRHeadroom)
        + struct.pack(">HHII", 0x0030, 9, 1, 3)  # tag 48 (HDRGain)
        + struct.pack(">I", 0)
    )
    apple_make = b"Apple\x00"
    apple_tif = bytearray()
    apple_tif += b"II" + struct.pack("<HI", 42, 8)
    apple_tif += struct.pack("<H", 2)
    apple_tif += struct.pack("<HHII", 0x010F, 2, 6, 38)
    apple_tif += struct.pack("<HHII", 0x8769, 4, 1, 44)
    apple_tif += struct.pack("<I", 0)
    apple_tif += apple_make
    apple_tif += struct.pack("<H", 1)
    apple_tif += struct.pack("<HHII", 0x927C, 7, len(apple_mn_payload), 62)
    apple_tif += struct.pack("<I", 0)
    apple_tif += apple_mn_payload
    apple_mn_tif.write_bytes(apple_tif)
    subprocess.run(
        [
            exiftool,
            "-overwrite_original",
            "-TagsFromFile",
            str(apple_mn_tif),
            "-MakerNotes",
            str(bad_apple_jpg),
        ],
        capture_output=True,
        text=True,
        check=True,
        timeout=30,
    )

    # Create bad_missing_orientation.jpg (valid.jpg with IFD0:Orientation stripped)
    bad_missing_orient_jpg = out_dir / "bad_missing_orientation.jpg"
    shutil.copy2(out_dir / "valid.jpg", bad_missing_orient_jpg)
    subprocess.run(
        [
            exiftool,
            "-overwrite_original",
            "-IFD0:Orientation=",
            str(bad_missing_orient_jpg),
        ],
        capture_output=True,
        text=True,
        check=True,
        timeout=30,
    )

    # Corrupt ARW fixtures
    trunc_arw = out_dir / "corrupt_truncated.arw"
    trunc_arw.write_bytes(b"II*\x00\x08\x00\x00\x00" + b"\x00" * 1016)
    garbage_arw = out_dir / "corrupt_garbage.arw"
    garbage_arw.write_bytes(os.urandom(4096))
    empty_arw = out_dir / "empty_zero.arw"
    empty_arw.write_bytes(b"")

    return {
        "valid_heic": out_dir / "valid.heic",
        "valid_jpg": out_dir / "valid.jpg",
        "valid_xmp_jpg": valid_xmp_jpg,
        "valid_grid_avif": valid_grid_avif,
        "valid_hlg_mp4": out_dir / "valid_hlg.mp4",
        "bad_no_gainmap_heic": out_dir / "bad_no_gainmap.heic",
        "bad_orientation6_jpg": out_dir / "bad_orientation6.jpg",
        "bad_missing_orientation_jpg": bad_missing_orient_jpg,
        "bad_makernote_jpg": bad_makernote_jpg,
        "bad_apple_makernote_jpg": bad_apple_jpg,
        "bad_imageio_tmap_avif": out_dir / "bad_imageio_tmap.avif",
        "bad_sdr_4k_mp4": out_dir / "bad_sdr_4k.mp4",
        "corrupt_truncated_arw": trunc_arw,
        "corrupt_garbage_arw": garbage_arw,
        "empty_zero_arw": empty_arw,
    }

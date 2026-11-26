"""External CLI probe wrappers for Chiaro E2E verification."""

from __future__ import annotations

import array
import json
import math
import os
import plistlib
import re
import struct
import subprocess
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple, Union

from config import FORBIDDEN_LICENSE_PATTERNS, FORBIDDEN_SYMBOL_PATTERNS, HostTools


ALLOWLIST_BREW_PREFIXES: Tuple[str, ...] = (
    "/opt/homebrew/opt/svt-av1/",
    "/opt/homebrew/opt/aom/",
    "/opt/homebrew/opt/dav1d/",
    "/opt/homebrew/opt/libvmaf/",
    "/opt/homebrew/opt/glib/",
    "/opt/homebrew/opt/gettext/",
    "/opt/homebrew/opt/pcre2/",
    "/opt/homebrew/opt/libpng/",
)


@dataclass
class ExifToolResult:
    file_path: str
    raw_dict: Dict[str, Any]
    app1_exif_size_bytes: Optional[int] = None

    def has_forbidden_sony_or_makernote(self) -> List[str]:
        bad: List[str] = []
        for k in self.raw_dict.keys():
            if (
                k.startswith("Sony:")
                or k.startswith("SubIFD:Sony")
                or k.startswith("MakerNotes:")
                or "MakerNote" in k
                or k == "ExifIFD:SR2SubIFDOffset"
            ):
                bad.append(k)
        return bad

    def has_forbidden_apple_makernote(self) -> List[str]:
        return [k for k in self.raw_dict.keys() if k.startswith("Apple:")]

    def has_iso21496_app2_urn(self) -> bool:
        for k, v in self.raw_dict.items():
            if "UniformResourceName" in k and str(v) == "urn:iso:std:iso:ts:21496:-1":
                return True
        return False

    def has_valid_mpf_gainmap(self) -> bool:
        num = self.raw_dict.get("MPF0:NumberOfImages")
        t1 = self.raw_dict.get("MPImage1:MPImageType")
        fmt2 = self.raw_dict.get("MPImage2:MPImageFormat")
        len2 = self.raw_dict.get("MPImage2:MPImageLength")
        return (
            num == 2
            and t1 == "Baseline MP Primary Image"
            and fmt2 == "JPEG"
            and isinstance(len2, (int, float))
            and len2 > 0
        )

    def has_xmp_hdrgm(self) -> bool:
        return any(k.startswith("XMP-hdrgm:") for k in self.raw_dict.keys())

    def icc_description(self) -> str:
        return str(self.raw_dict.get("ICC_Profile:ProfileDescription") or "")

    def orientation_numeric(self) -> Optional[int]:
        val = self.raw_dict.get("IFD0:Orientation")
        if isinstance(val, int):
            return val
        if isinstance(val, str):
            mapping = {
                "Horizontal (normal)": 1,
                "Mirror horizontal": 2,
                "Rotate 180": 3,
                "Mirror vertical": 4,
                "Mirror horizontal and rotate 270 CW": 5,
                "Rotate 90 CW": 6,
                "Mirror horizontal and rotate 90 CW": 7,
                "Rotate 270 CW": 8,
            }
            if val in mapping:
                return mapping[val]
            if "Horizontal" in val and "rotate" not in val.lower():
                return 1
            m = re.fullmatch(r"\s*([1-8])\s*", val)
            if m:
                return int(m.group(1))
        return None


@dataclass
class AvifDecResult:
    returncode: int
    stdout: str
    stderr: str
    width: Optional[int] = None
    height: Optional[int] = None
    bit_depth: Optional[int] = None
    yuv_format: Optional[str] = None
    color_range: Optional[str] = None
    gain_map_width: Optional[int] = None
    gain_map_height: Optional[int] = None
    gain_map_bit_depth: Optional[int] = None
    gain_map_format: Optional[str] = None
    base_headroom: Optional[float] = None
    alt_headroom: Optional[float] = None
    decoded_png_size: int = 0


@dataclass
class AvifGainMapMeta:
    returncode: int
    stdout: str
    stderr: str
    base_headroom: Optional[float] = None
    alt_headroom: Optional[float] = None
    gamma: Optional[float] = None
    use_base_color_space: Optional[bool] = None
    gain_map_min: Optional[str] = None
    gain_map_max: Optional[str] = None


@dataclass
class UltraHDRResult:
    mode: str  # "probe_P" or "decode_fallback_v1_4"
    returncode: int
    stdout: str
    stderr: str
    decoded_raw_bytes: int = 0
    metadata_cfg: Dict[str, str] = field(default_factory=dict)


@dataclass
class FFProbeResult:
    returncode: int
    raw_json: Dict[str, Any]
    codec_name: Optional[str] = None
    profile: Optional[str] = None
    codec_tag_string: Optional[str] = None
    pix_fmt: Optional[str] = None
    color_range: Optional[str] = None
    color_space: Optional[str] = None
    color_transfer: Optional[str] = None
    color_primaries: Optional[str] = None
    width: Optional[int] = None
    height: Optional[int] = None
    duration: Optional[float] = None
    bit_rate: Optional[int] = None
    fps: Optional[float] = None


@dataclass
class HeifInfoResult:
    returncode: int
    stdout: str
    stderr: str
    has_tmap: bool = False
    has_dimg: bool = False
    has_altr: bool = False
    bit_depth: Optional[int] = None


def probe_exiftool(tools: HostTools, image_path: Path, numeric: bool = False) -> ExifToolResult:
    if not tools.exiftool:
        raise RuntimeError("exiftool not available")
    cmd = [tools.exiftool, "-G1", "-a", "-s", "-ee", "-j"]
    if numeric:
        cmd.append("-n")
    cmd.append(str(image_path))
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    if proc.returncode != 0 or not proc.stdout.strip():
        raise RuntimeError(f"exiftool failed on {image_path}: {proc.stderr}")
    arr = json.loads(proc.stdout)
    raw = arr[0] if arr else {}
    app1_size = _measure_jpeg_app1_size(image_path) if image_path.suffix.lower() in (".jpg", ".jpeg") else None
    return ExifToolResult(file_path=str(image_path), raw_dict=raw, app1_exif_size_bytes=app1_size)


def _measure_jpeg_app1_size(jpg_path: Path) -> Optional[int]:
    """Scan JPEG markers for the Exif APP1 segment payload length."""
    data = jpg_path.read_bytes()
    if len(data) < 4 or data[0:2] != b"\xFF\xD8":
        return None
    pos = 2
    while pos + 4 <= len(data):
        if data[pos] != 0xFF:
            break
        while pos < len(data) and data[pos] == 0xFF:
            pos += 1
        if pos >= len(data):
            break
        marker = data[pos]
        pos += 1
        if marker in (0xD8, 0xD9, 0x00) or (0xD0 <= marker <= 0xD7):
            continue
        if marker == 0xDA:  # SOS
            break
        if pos + 2 > len(data):
            break
        seg_len = int.from_bytes(data[pos : pos + 2], "big")
        if seg_len < 2:
            break
        if marker == 0xE1 and pos + 8 <= len(data):
            if data[pos + 2 : pos + 8] == b"Exif\x00\x00":
                return seg_len
        pos += seg_len
    return None


def probe_avifdec(tools: HostTools, avif_path: Path, decode_16bit_png: bool = False) -> AvifDecResult:
    if not tools.avifdec:
        raise RuntimeError("avifdec not available")
    cmd = [tools.avifdec, "--info", "--depth", "16", str(avif_path)]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    text = (proc.stdout or "") + "\n" + (proc.stderr or "")
    res = AvifDecResult(returncode=proc.returncode, stdout=proc.stdout, stderr=proc.stderr)

    m_res = re.search(r"Resolution\s*:\s*(\d+)x(\d+)", text)
    if m_res:
        res.width, res.height = int(m_res.group(1)), int(m_res.group(2))
    m_bd = re.search(r"Bit Depth\s*:\s*(\d+)", text)
    if m_bd:
        res.bit_depth = int(m_bd.group(1))
    m_fmt = re.search(r"Format\s*:\s*(\S+)", text)
    if m_fmt:
        res.yuv_format = m_fmt.group(1)
    m_rng = re.search(r"Range\s*:\s*(\S+)", text)
    if m_rng:
        res.color_range = m_rng.group(1)

    m_gm = re.search(
        r"Gain map\s*:\s*(\d+)x(\d+)\s*pixels,\s*(\d+)\s*bit,\s*([^,\n]+)",
        text,
    )
    if m_gm:
        res.gain_map_width = int(m_gm.group(1))
        res.gain_map_height = int(m_gm.group(2))
        res.gain_map_bit_depth = int(m_gm.group(3))
        res.gain_map_format = m_gm.group(4).strip()

    m_bh = re.search(r"Base\s+Headroom\s*([0-9.+-]+)", text, re.IGNORECASE)
    if m_bh:
        res.base_headroom = float(m_bh.group(1))
    m_ah = re.search(r"Alternate\s+Headroom\s*([0-9.+-]+)", text, re.IGNORECASE)
    if m_ah:
        res.alt_headroom = float(m_ah.group(1))

    if decode_16bit_png and proc.returncode == 0:
        with tempfile.TemporaryDirectory(prefix="e2e_avifdec_") as td:
            out_png = Path(td) / "decoded.png"
            dproc = subprocess.run(
                [tools.avifdec, "-d", "16", str(avif_path), str(out_png)],
                capture_output=True,
                text=True,
                timeout=120,
            )
            if dproc.returncode != 0:
                res.returncode = dproc.returncode
                res.stderr += "\n" + dproc.stderr
            elif out_png.is_file():
                res.decoded_png_size = out_png.stat().st_size
    return res


def _parse_avif_numeric(raw: str) -> Optional[float]:
    """Parse float or a/b fraction from avifgainmaputil printmetadata value strings."""
    # Prefer exact "(as fraction: a/b)" when present (e.g. "R 1.2 (as fraction: 6/5) G 1.2 ...")
    m_frac = re.search(
        r"as\s+fraction\s*:\s*([+-]?\d+(?:\.\d+)?)\s*/\s*([+-]?\d+(?:\.\d+)?)",
        raw,
        re.IGNORECASE,
    )
    if m_frac:
        try:
            num = float(m_frac.group(1))
            den = float(m_frac.group(2))
            if den != 0.0:
                return num / den
        except ValueError:
            pass

    # Fallback: first numeric or a/b token after optional channel label (R/G/B)
    m_val = re.search(
        r"(?:^|[\s,])(?:[RGB]\s+)?([+-]?\d+(?:\.\d+)?(?:\s*/\s*[+-]?\d+(?:\.\d+)?)?)",
        raw.strip(),
        re.IGNORECASE,
    )
    if not m_val:
        return None
    tok = m_val.group(1).replace(" ", "")
    if "/" in tok:
        p0, p1 = tok.split("/", 1)
        try:
            den = float(p1)
            return float(p0) / den if den != 0.0 else None
        except ValueError:
            return None
    try:
        return float(tok)
    except ValueError:
        return None


def probe_avifgainmaputil(tools: HostTools, avif_path: Path) -> AvifGainMapMeta:
    if not tools.avifgainmaputil:
        raise RuntimeError("avifgainmaputil not available")
    proc = subprocess.run(
        [tools.avifgainmaputil, "printmetadata", str(avif_path)],
        capture_output=True,
        text=True,
        timeout=30,
    )
    text = (proc.stdout or "") + "\n" + (proc.stderr or "")
    meta = AvifGainMapMeta(returncode=proc.returncode, stdout=proc.stdout, stderr=proc.stderr)

    m_bh = re.search(r"Base\s+Headroom\s*:\s*([^\n]+)", text, re.IGNORECASE)
    if m_bh:
        meta.base_headroom = _parse_avif_numeric(m_bh.group(1))
    m_ah = re.search(r"Alternate\s+Headroom\s*:\s*([^\n]+)", text, re.IGNORECASE)
    if m_ah:
        meta.alt_headroom = _parse_avif_numeric(m_ah.group(1))
    m_gam = re.search(r"(?:Gain\s+Map\s+)?Gamma\s*:\s*([^\n]+)", text, re.IGNORECASE)
    if m_gam:
        meta.gamma = _parse_avif_numeric(m_gam.group(1))
    m_ubc = re.search(r"Use\s+Base\s+Color\s+Space\s*:\s*(true|false|yes|no|1|0)", text, re.IGNORECASE)
    if m_ubc:
        meta.use_base_color_space = m_ubc.group(1).lower() in ("true", "yes", "1")
    m_min = re.search(r"Gain\s+Map\s+Min\s*:\s*([^\n]+)", text, re.IGNORECASE)
    if m_min:
        meta.gain_map_min = m_min.group(1).strip()
    m_max = re.search(r"Gain\s+Map\s+Max\s*:\s*([^\n]+)", text, re.IGNORECASE)
    if m_max:
        meta.gain_map_max = m_max.group(1).strip()

    return meta


def extract_avif_gainmap_info(tools: HostTools, avif_path: Path) -> AvifDecResult:
    """Extract the gainmap from an AVIF and inspect it via avifdec --info."""
    if not tools.avifgainmaputil or not tools.avifdec:
        raise RuntimeError("avifgainmaputil / avifdec not available")
    with tempfile.TemporaryDirectory(prefix="e2e_gm_") as td:
        gm_avif = Path(td) / "gm.avif"
        proc = subprocess.run(
            [tools.avifgainmaputil, "extractgainmap", str(avif_path), str(gm_avif)],
            capture_output=True,
            text=True,
            timeout=60,
        )
        if proc.returncode != 0 or not gm_avif.is_file():
            return AvifDecResult(returncode=proc.returncode or 1, stdout=proc.stdout, stderr=proc.stderr)
        return probe_avifdec(tools, gm_avif, decode_16bit_png=False)


def probe_ultrahdr(tools: HostTools, jpg_path: Path) -> UltraHDRResult:
    if not tools.ultrahdr_app or tools.ultrahdr_mode == "missing":
        raise RuntimeError("ultrahdr_app not available (never silently skipped)")

    if tools.ultrahdr_mode == "probe_P":
        proc = subprocess.run(
            [tools.ultrahdr_app, "-m", "1", "-j", str(jpg_path), "-P"],
            capture_output=True,
            text=True,
            timeout=30,
        )
        parsed_cfg: Dict[str, str] = {}
        for line in (proc.stdout or "").splitlines():
            s = line.strip()
            if s.startswith("--"):
                parts = s.split(None, 1)
                if len(parts) == 2:
                    parsed_cfg[parts[0]] = parts[1]
        return UltraHDRResult(
            mode="probe_P",
            returncode=proc.returncode,
            stdout=proc.stdout,
            stderr=proc.stderr,
            metadata_cfg=parsed_cfg,
        )

    # Strict v1.4.0 decode + metadata fallback (never false-passes)
    with tempfile.TemporaryDirectory(prefix="e2e_uhdr_") as td:
        td_path = Path(td)
        out_raw = td_path / "decoded.raw"
        meta_cfg = td_path / "meta.cfg"
        cmd = [
            tools.ultrahdr_app,
            "-m",
            "1",
            "-j",
            str(jpg_path),
            "-o",
            "3",
            "-O",
            "3",
            "-f",
            str(meta_cfg),
            "-z",
            str(out_raw),
        ]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        raw_bytes = out_raw.stat().st_size if out_raw.is_file() else 0
        parsed_cfg: Dict[str, str] = {}
        if meta_cfg.is_file():
            for line in meta_cfg.read_text(errors="replace").splitlines():
                line = line.strip()
                if not line:
                    continue
                parts = line.split(None, 1)
                if len(parts) == 2:
                    parsed_cfg[parts[0]] = parts[1]
        return UltraHDRResult(
            mode="decode_fallback_v1_4",
            returncode=proc.returncode,
            stdout=proc.stdout,
            stderr=proc.stderr,
            decoded_raw_bytes=raw_bytes,
            metadata_cfg=parsed_cfg,
        )


def probe_ffprobe(tools: HostTools, mp4_path: Path) -> FFProbeResult:
    if not tools.ffprobe:
        raise RuntimeError("ffprobe not available")
    cmd = [
        tools.ffprobe,
        "-v",
        "error",
        "-show_format",
        "-show_streams",
        "-of",
        "json",
        str(mp4_path),
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    if proc.returncode != 0 or not proc.stdout.strip():
        return FFProbeResult(returncode=proc.returncode or 1, raw_json={})

    data = json.loads(proc.stdout)
    streams = data.get("streams") or []
    v_stream = next((s for s in streams if s.get("codec_type") == "video"), {})
    fmt = data.get("format") or {}

    fps_val: Optional[float] = None
    rfr = v_stream.get("r_frame_rate")
    if isinstance(rfr, str) and "/" in rfr:
        n, d = rfr.split("/", 1)
        if float(d) != 0:
            fps_val = float(n) / float(d)

    dur_val: Optional[float] = None
    raw_dur = v_stream.get("duration") or fmt.get("duration")
    if raw_dur is not None:
        try:
            dur_val = float(raw_dur)
        except Exception:
            pass

    br_val: Optional[int] = None
    raw_br = v_stream.get("bit_rate") or fmt.get("bit_rate")
    if raw_br is not None:
        try:
            br_val = int(raw_br)
        except Exception:
            pass

    return FFProbeResult(
        returncode=proc.returncode,
        raw_json=data,
        codec_name=v_stream.get("codec_name"),
        profile=v_stream.get("profile"),
        codec_tag_string=v_stream.get("codec_tag_string"),
        pix_fmt=v_stream.get("pix_fmt"),
        color_range=v_stream.get("color_range"),
        color_space=v_stream.get("color_space"),
        color_transfer=v_stream.get("color_transfer"),
        color_primaries=v_stream.get("color_primaries"),
        width=v_stream.get("width"),
        height=v_stream.get("height"),
        duration=dur_val,
        bit_rate=br_val,
        fps=fps_val,
    )


def probe_heif_info(tools: HostTools, heic_path: Path) -> HeifInfoResult:
    if not tools.heif_info:
        raise RuntimeError("heif-info not available")
    proc = subprocess.run(
        [tools.heif_info, "-d", str(heic_path)],
        capture_output=True,
        text=True,
        timeout=30,
    )
    text = (proc.stdout or "") + "\n" + (proc.stderr or "")
    m_bd = re.search(r"bit depth:\s*(\d+)", text)
    return HeifInfoResult(
        returncode=proc.returncode,
        stdout=proc.stdout,
        stderr=proc.stderr,
        has_tmap=("tmap" in text),
        has_dimg=("dimg" in text),
        has_altr=("altr" in text),
        bit_depth=int(m_bd.group(1)) if m_bd else None,
    )


def _parse_lc_rpaths(tools: HostTools, binary_path: Path) -> List[str]:
    if not tools.otool:
        return []
    proc = subprocess.run(
        [tools.otool, "-l", str(binary_path)],
        capture_output=True,
        text=True,
        timeout=30,
    )
    if proc.returncode != 0:
        return []
    rpaths: List[str] = []
    expect_path = False
    for raw_line in proc.stdout.splitlines():
        s = raw_line.strip()
        if s == "cmd LC_RPATH":
            expect_path = True
        elif expect_path and s.startswith("path "):
            p_val = s[len("path "):].split(" (offset", 1)[0].strip()
            if p_val:
                rpaths.append(p_val)
            expect_path = False
        elif s.startswith("Load command "):
            expect_path = False
    return rpaths


def _resolve_executable_dir(binary_path: Path) -> Path:
    if binary_path.suffix != ".dylib":
        return binary_path.parent
    parts = binary_path.parts
    if "Contents" in parts:
        idx = parts.index("Contents")
        if idx + 1 < len(parts) and parts[idx + 1] == "Frameworks":
            macos_dir = Path(*parts[: idx + 1]) / "MacOS"
            if macos_dir.is_dir():
                return macos_dir
    if binary_path.parent.name == "lib":
        bin_dir = binary_path.parent.parent / "bin"
        if bin_dir.is_dir():
            return bin_dir
    return binary_path.parent


def _expand_macho_path_prefix(raw: str, loader_dir: Path, exec_dir: Path) -> Path:
    if raw == "@loader_path":
        return loader_dir
    if raw.startswith("@loader_path/"):
        return loader_dir / raw[len("@loader_path/"):]
    if raw == "@executable_path":
        return exec_dir
    if raw.startswith("@executable_path/"):
        return exec_dir / raw[len("@executable_path/"):]
    return Path(raw)


def check_gpl3_compatible_linkage(
    tools: HostTools,
    binary_path: Path,
    check_symbols: bool = True,
    require_self_contained: bool = False,
) -> Dict[str, Any]:
    """Run otool -L and nm (-gU and -u) against a Mach-O binary for GPL-3.0-or-later compliance."""
    if not tools.otool:
        raise RuntimeError("otool not available")
    otool_proc = subprocess.run(
        [tools.otool, "-L", str(binary_path)],
        capture_output=True,
        text=True,
        timeout=30,
    )
    if otool_proc.returncode != 0:
        raise RuntimeError(f"otool -L failed on {binary_path}: {otool_proc.stderr}")

    is_self_contained = (
        require_self_contained
        or ("Chiaro.app" in binary_path.parts)
        or ("dist" in binary_path.parts)
    )

    install_id: Optional[str] = None
    id_proc = subprocess.run(
        [tools.otool, "-D", str(binary_path)],
        capture_output=True,
        text=True,
        timeout=15,
    )
    if id_proc.returncode == 0:
        id_lines = [ln.strip() for ln in id_proc.stdout.splitlines() if ln.strip()]
        if len(id_lines) >= 2:
            install_id = id_lines[1]

    lc_rpaths = _parse_lc_rpaths(tools, binary_path) if is_self_contained else []
    exec_dir = _resolve_executable_dir(binary_path) if is_self_contained else binary_path.parent

    otool_lines = otool_proc.stdout.splitlines()
    forbidden_libs: List[str] = []
    dangling_refs: List[str] = []
    unbundled_refs: List[str] = []
    unallowlisted_refs: List[str] = []
    unresolved_rpaths: List[str] = []

    for idx, line in enumerate(otool_lines[1:], start=1):
        stripped = line.strip()
        if not stripped:
            continue
        lib_path = stripped.split(" (compatibility version", 1)[0].strip()
        if idx == 1 and install_id and lib_path == install_id:
            # Skip LC_ID_DYLIB self-identification line (check dangling /tmp/ only)
            if lib_path.startswith("/tmp/") or lib_path.startswith("/private/tmp/"):
                dangling_refs.append(lib_path)
            continue
        for pat in FORBIDDEN_LICENSE_PATTERNS:
            if pat.lower() in lib_path.lower():
                forbidden_libs.append(lib_path)
        if lib_path.startswith("/tmp/") or lib_path.startswith("/private/tmp/"):
            dangling_refs.append(lib_path)
        if lib_path.startswith("/opt/homebrew/") or lib_path.startswith("/usr/local/"):
            unbundled_refs.append(lib_path)
        if lib_path.startswith("/") and not (
            lib_path.startswith("/System/")
            or lib_path.startswith("/usr/lib/")
            or any(lib_path.startswith(pfx) for pfx in ALLOWLIST_BREW_PREFIXES)
        ):
            unallowlisted_refs.append(lib_path)

        if is_self_contained:
            if lib_path.startswith("@loader_path/"):
                rel = lib_path[len("@loader_path/"):]
                cand = (binary_path.parent / rel)
                if not cand.exists():
                    unresolved_rpaths.append(lib_path)
                else:
                    cand_res = str(cand.resolve())
                    if cand_res.startswith("/opt/homebrew/") or cand_res.startswith("/usr/local/"):
                        unbundled_refs.append(cand_res)
            elif lib_path.startswith("@executable_path/"):
                rel = lib_path[len("@executable_path/"):]
                cand = (exec_dir / rel)
                if not cand.exists():
                    unresolved_rpaths.append(lib_path)
                else:
                    cand_res = str(cand.resolve())
                    if cand_res.startswith("/opt/homebrew/") or cand_res.startswith("/usr/local/"):
                        unbundled_refs.append(cand_res)
            elif lib_path.startswith("@rpath/"):
                rel = lib_path[len("@rpath/"):]
                if not rel.startswith("libswift"):
                    search_dirs: List[Path] = []
                    for rp in lc_rpaths:
                        expanded = _expand_macho_path_prefix(rp, binary_path.parent, exec_dir)
                        exp_str = str(expanded)
                        if (
                            exp_str.startswith("/opt/homebrew/")
                            or exp_str.startswith("/usr/local/")
                            or exp_str.startswith("/tmp/")
                            or exp_str.startswith("/private/tmp/")
                        ):
                            continue
                        search_dirs.append(expanded)
                    if "Chiaro.app" in binary_path.parts or "dist" in binary_path.parts:
                        search_dirs.extend([
                            binary_path.parent,
                            exec_dir.parent / "Frameworks",
                            exec_dir.parent / "lib",
                        ])
                    found_self_contained = False
                    for sd in search_dirs:
                        cand = sd / rel
                        if cand.exists():
                            cand_res = str(cand.resolve())
                            if cand_res.startswith("/opt/homebrew/") or cand_res.startswith("/usr/local/"):
                                unbundled_refs.append(cand_res)
                            else:
                                found_self_contained = True
                            break
                    if not found_self_contained:
                        unresolved_rpaths.append(lib_path)

    if is_self_contained:
        for rp in lc_rpaths:
            if rp.startswith("/opt/homebrew/") or rp.startswith("/usr/local/"):
                if rp not in unbundled_refs:
                    unbundled_refs.append(rp)
            elif rp.startswith("/tmp/") or rp.startswith("/private/tmp/"):
                if rp not in dangling_refs:
                    dangling_refs.append(rp)

    forbidden_syms: List[str] = []
    if check_symbols and tools.nm:
        nm_outputs: List[str] = []
        for flag in ("-gU", "-u"):
            nm_proc = subprocess.run(
                [tools.nm, flag, str(binary_path)],
                capture_output=True,
                text=True,
                timeout=30,
            )
            if nm_proc.stdout:
                nm_outputs.append(nm_proc.stdout)
        nm_out = "\n".join(nm_outputs)
        for pat in FORBIDDEN_SYMBOL_PATTERNS:
            if pat in nm_out:
                forbidden_syms.append(pat)

    clean = (
        not forbidden_libs
        and not forbidden_syms
        and not unallowlisted_refs
        and not dangling_refs
        and (not unbundled_refs if is_self_contained else True)
        and (not unresolved_rpaths if is_self_contained else True)
    )

    return {
        "binary": str(binary_path),
        "otool_lines": otool_lines,
        "forbidden_libs": forbidden_libs,
        "forbidden_symbols": forbidden_syms,
        "dangling_refs": dangling_refs,
        "unbundled_refs": unbundled_refs,
        "unallowlisted_refs": unallowlisted_refs,
        "unresolved_rpaths": unresolved_rpaths,
        "self_contained_target": is_self_contained,
        "clean": clean,
    }


check_zero_gpl_linkage = check_gpl3_compatible_linkage


def check_app_bundle(tools: HostTools, app_bundle: Path) -> Dict[str, Any]:
    info_plist = app_bundle / "Contents" / "Info.plist"
    macos_dir = app_bundle / "Contents" / "MacOS"
    resources_dir = app_bundle / "Contents" / "Resources"

    errors: List[str] = []
    if not info_plist.is_file():
        errors.append("Missing Contents/Info.plist")
    if not macos_dir.is_dir():
        errors.append("Missing Contents/MacOS")
    if not resources_dir.is_dir():
        errors.append("Missing Contents/Resources")

    cf_exec = ""
    if info_plist.is_file() and tools.plutil:
        pl = subprocess.run([tools.plutil, "-lint", str(info_plist)], capture_output=True, text=True, timeout=15)
        if pl.returncode != 0:
            errors.append(f"plutil -lint failed: {pl.stdout} {pl.stderr}")
    if info_plist.is_file() and tools.plistbuddy:
        pb = subprocess.run(
            [tools.plistbuddy, "-c", "Print :CFBundleExecutable", str(info_plist)],
            capture_output=True,
            text=True,
            timeout=15,
        )
        if pb.returncode == 0:
            cf_exec = pb.stdout.strip()
        else:
            errors.append(f"Missing CFBundleExecutable: {pb.stderr}")

    exec_path = macos_dir / (cf_exec or "Chiaro")
    if not (exec_path.is_file() and os.access(exec_path, os.X_OK)):
        errors.append(f"Executable missing or not executable: {exec_path}")

    codesign_ok = False
    codesign_out = ""
    if tools.codesign:
        cs = subprocess.run(
            [tools.codesign, "--verify", "--deep", "--strict", str(app_bundle)],
            capture_output=True,
            text=True,
            timeout=30,
        )
        codesign_ok = (cs.returncode == 0)
        codesign_out = (cs.stdout + "\n" + cs.stderr).strip()
        if not codesign_ok:
            errors.append(f"codesign --verify failed: {codesign_out}")

    shaders = list(resources_dir.rglob("Shaders.metal")) if resources_dir.is_dir() else []
    presets = list(resources_dir.rglob("*.json")) if resources_dir.is_dir() else []

    return {
        "app_bundle": str(app_bundle),
        "executable": str(exec_path),
        "cf_bundle_executable": cf_exec,
        "codesign_ok": codesign_ok,
        "codesign_output": codesign_out,
        "shaders_metal_files": [str(p) for p in shaders],
        "resource_json_files": [str(p) for p in presets],
        "errors": errors,
        "ok": len(errors) == 0,
    }


# =============================================================================
# Chiaro v1.1 Opaque-Box Probes (NDJSON, Sidecar, Pixel/IQ, HDR Linear, App/SBOM)
# =============================================================================


def parse_ndjson_events(text: str) -> List[Dict[str, Any]]:
    """Parse NDJSON stdout lines into event dicts, skipping non-JSON lines."""
    events: List[Dict[str, Any]] = []
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or not line.startswith("{"):
            continue
        obj = json.loads(line)
        if isinstance(obj, dict):
            events.append(obj)
    return events


def extract_job_decoded_events(text: str) -> List[Dict[str, Any]]:
    """Extract all `job_decoded` events from NDJSON stdout."""
    return [ev for ev in parse_ndjson_events(text) if ev.get("event") == "job_decoded"]


def extract_job_completed_events(text: str) -> List[Dict[str, Any]]:
    """Extract all `job_completed` events from NDJSON stdout."""
    return [ev for ev in parse_ndjson_events(text) if ev.get("event") == "job_completed"]


def sidecar_path_for(raw_path: Path) -> Path:
    """Return canonical `<raw_path>.chiaro.json` sidecar path."""
    return Path(f"{raw_path}.chiaro.json")


def build_v11_sidecar(
    *,
    schema_version: int = 2,
    app_version: str = "1.1.1",
    preset_id: Optional[str] = "apple_heic",
    decode_backend: Optional[str] = None,
    demosaic: Optional[str] = None,
    optics: Optional[Dict[str, Any]] = None,
    delta: Optional[Dict[str, Any]] = None,
    denoise: Optional[Dict[str, Any]] = None,
    ai_color: Optional[Dict[str, Any]] = None,
    extra: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """Construct a v1.1 schemaVersion=2 `.chiaro.json` sidecar payload."""
    payload: Dict[str, Any] = {
        "schemaVersion": schema_version,
        "appVersion": app_version,
        "updatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    if preset_id is not None:
        payload["presetID"] = preset_id
    if decode_backend is not None:
        payload["decodeBackend"] = decode_backend
    if demosaic is not None:
        payload["demosaic"] = demosaic
    if optics is not None:
        payload["optics"] = optics
    if delta is not None:
        payload["delta"] = delta
    if denoise is not None:
        payload["denoise"] = denoise
    if ai_color is not None:
        payload["aiColor"] = ai_color
    if extra:
        payload.update(extra)
    return payload


def write_sidecar(raw_path: Path, data: Dict[str, Any]) -> Path:
    """Write `.chiaro.json` next to `raw_path` (caller must use copied temp dir)."""
    sc_path = sidecar_path_for(raw_path)
    sc_path.write_text(json.dumps(data, indent=2), encoding="utf-8")
    return sc_path


def read_sidecar(raw_path: Path) -> Dict[str, Any]:
    """Read and parse `<raw_path>.chiaro.json`."""
    sc_path = sidecar_path_for(raw_path)
    return json.loads(sc_path.read_text(encoding="utf-8"))


def _require_pil() -> Tuple[Any, Any, Any, Any]:
    from PIL import Image, ImageChops, ImageFilter, ImageStat  # type: ignore

    return Image, ImageChops, ImageFilter, ImageStat


def decode_image_to_rgb(
    tools: HostTools,
    image_path: Path,
    max_dim: Optional[int] = None,
) -> Any:
    """Decode JPEG/PNG/TIFF/HEIC/AVIF into an RGB PIL.Image.Image without side effects."""
    Image, _, _, _ = _require_pil()
    ext = image_path.suffix.lower()

    if ext in (".heic", ".heif"):
        with tempfile.TemporaryDirectory(prefix="e2e_sips_") as td:
            out_png = Path(td) / "decoded.png"
            proc = subprocess.run(
                ["/usr/bin/sips", "-s", "format", "png", str(image_path), "--out", str(out_png)],
                capture_output=True,
                text=True,
                timeout=60,
            )
            if proc.returncode != 0 or not out_png.is_file():
                raise RuntimeError(f"sips HEIC->PNG decode failed on {image_path}: {proc.stderr} {proc.stdout}")
            with Image.open(out_png) as opened:
                img = opened.convert("RGB")
    elif ext == ".avif":
        if not tools.avifdec:
            raise RuntimeError("avifdec not available for AVIF decode")
        with tempfile.TemporaryDirectory(prefix="e2e_avif_") as td:
            out_png = Path(td) / "decoded.png"
            proc = subprocess.run(
                [tools.avifdec, str(image_path), str(out_png)],
                capture_output=True,
                text=True,
                timeout=120,
            )
            if proc.returncode != 0 or not out_png.is_file():
                raise RuntimeError(f"avifdec PNG decode failed on {image_path}: {proc.stderr} {proc.stdout}")
            with Image.open(out_png) as opened:
                img = opened.convert("RGB")
    else:
        with Image.open(image_path) as opened:
            img = opened.convert("RGB")

    if max_dim is not None and max(img.width, img.height) > max_dim:
        scale = max_dim / float(max(img.width, img.height))
        new_w = max(1, int(round(img.width * scale)))
        new_h = max(1, int(round(img.height * scale)))
        img = img.resize((new_w, new_h), Image.Resampling.BILINEAR)
    return img


def _resolve_rgb_image(
    tools: HostTools,
    img_or_path: Union[Path, Any],
    max_dim: Optional[int],
) -> Any:
    if isinstance(img_or_path, Path):
        return decode_image_to_rgb(tools, img_or_path, max_dim=max_dim)
    if max_dim is not None and max(img_or_path.width, img_or_path.height) > max_dim:
        Image, _, _, _ = _require_pil()
        scale = max_dim / float(max(img_or_path.width, img_or_path.height))
        new_w = max(1, int(round(img_or_path.width * scale)))
        new_h = max(1, int(round(img_or_path.height * scale)))
        return img_or_path.convert("RGB").resize((new_w, new_h), Image.Resampling.BILINEAR)
    return img_or_path.convert("RGB")


def _crop_norm(img: Any, box_norm: Optional[Tuple[float, float, float, float]]) -> Any:
    if box_norm is None:
        return img
    x0, y0, x1, y1 = box_norm
    w, h = img.size
    left = max(0, min(w - 1, int(round(x0 * w))))
    top = max(0, min(h - 1, int(round(y0 * h))))
    right = max(left + 1, min(w, int(round(x1 * w))))
    bottom = max(top + 1, min(h, int(round(y1 * h))))
    return img.crop((left, top, right, bottom))


def measure_image_diff(
    tools: HostTools,
    img_a: Union[Path, Any],
    img_b: Union[Path, Any],
    max_dim: Optional[int] = 1024,
    crop_box_norm: Optional[Tuple[float, float, float, float]] = None,
) -> Dict[str, float]:
    """Compute normalized [0..1] RGB pixel diff metrics between two images."""
    _, ImageChops, _, ImageStat = _require_pil()
    a = _crop_norm(_resolve_rgb_image(tools, img_a, max_dim), crop_box_norm)
    b = _crop_norm(_resolve_rgb_image(tools, img_b, max_dim), crop_box_norm)
    if a.size != b.size:
        raise ValueError(f"Image dimension mismatch in measure_image_diff: {a.size} vs {b.size}")

    diff = ImageChops.difference(a, b)
    stat = ImageStat.Stat(diff)
    mean_abs_diff = (sum(stat.mean) / 3.0) / 255.0
    rms_diff = math.sqrt(sum(r * r for r in stat.rms) / 3.0) / 255.0
    max_diff = max(hi for _, hi in stat.extrema) / 255.0

    # Compute fraction of pixels with any channel difference > 0
    raw = diff.tobytes()
    total_px = a.width * a.height
    nonzero_px = 0
    for i in range(0, len(raw), 3):
        if raw[i] or raw[i + 1] or raw[i + 2]:
            nonzero_px += 1
    nonzero_fraction = nonzero_px / float(max(1, total_px))

    return {
        "mean_abs_diff": mean_abs_diff,
        "rms_diff": rms_diff,
        "max_diff": max_diff,
        "nonzero_fraction": nonzero_fraction,
        "width": float(a.width),
        "height": float(a.height),
    }


def _mean_luma_01(img: Any) -> float:
    _, _, _, ImageStat = _require_pil()
    stat = ImageStat.Stat(img)
    r, g, b = stat.mean[0] / 255.0, stat.mean[1] / 255.0, stat.mean[2] / 255.0
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def measure_corner_center_luma_ratio(
    tools: HostTools,
    image_path: Union[Path, Any],
    max_dim: Optional[int] = 1024,
) -> Dict[str, float]:
    """Measure outer 4 corner (10%x10%) luma relative to center (20%x20%) luma."""
    img = _resolve_rgb_image(tools, image_path, max_dim)
    corners = [
        _crop_norm(img, (0.0, 0.0, 0.10, 0.10)),
        _crop_norm(img, (0.90, 0.0, 1.0, 0.10)),
        _crop_norm(img, (0.0, 0.90, 0.10, 1.0)),
        _crop_norm(img, (0.90, 0.90, 1.0, 1.0)),
    ]
    corner_lumas = [_mean_luma_01(c) for c in corners]
    corner_luma = sum(corner_lumas) / 4.0
    center_luma = _mean_luma_01(_crop_norm(img, (0.40, 0.40, 0.60, 0.60)))
    return {
        "corner_luma": corner_luma,
        "corner_min_luma": min(corner_lumas),
        "center_luma": center_luma,
        "ratio": corner_luma / max(center_luma, 1e-6),
    }


def measure_region_noise_variance(
    tools: HostTools,
    image_path: Union[Path, Any],
    box_norm: Optional[Tuple[float, float, float, float]] = None,
    max_dim: Optional[int] = 1024,
    shadow_luma_range: Optional[Tuple[float, float]] = (0.01, 0.25),
) -> Dict[str, float]:
    """Measure high-pass luma and chroma noise variance in a region or dark shadows."""
    _, ImageChops, ImageFilter, ImageStat = _require_pil()
    img = _crop_norm(_resolve_rgb_image(tools, image_path, max_dim), box_norm)
    blurred = img.filter(ImageFilter.BoxBlur(2))

    raw_img = img.tobytes()
    raw_blur = blurred.tobytes()
    inv255 = 1.0 / 255.0

    # Collect shadow pixels if requested; fall back to all crop pixels if too sparse.
    def _accumulate(use_shadow_filter: bool) -> Tuple[int, float, float, float, float, float, float]:
        cnt = 0
        sum_y2 = 0.0
        sum_rg2 = 0.0
        sum_bg2 = 0.0
        sum_r2 = 0.0
        sum_g2 = 0.0
        sum_b2 = 0.0
        sum_luma = 0.0
        for i in range(0, len(raw_img), 3):
            r = raw_img[i] * inv255
            g = raw_img[i + 1] * inv255
            b = raw_img[i + 2] * inv255
            y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            if use_shadow_filter and shadow_luma_range is not None:
                if y < shadow_luma_range[0] or y > shadow_luma_range[1]:
                    continue
            br = raw_blur[i] * inv255
            bg = raw_blur[i + 1] * inv255
            bb = raw_blur[i + 2] * inv255
            by = 0.2126 * br + 0.7152 * bg + 0.0722 * bb
            dy = y - by
            dr = r - br
            dg = g - bg
            db = b - bb
            drg = (r - g) - (br - bg)
            dbg = (b - g) - (bb - bg)
            sum_y2 += dy * dy
            sum_rg2 += drg * drg
            sum_bg2 += dbg * dbg
            sum_r2 += dr * dr
            sum_g2 += dg * dg
            sum_b2 += db * db
            sum_luma += y
            cnt += 1
        if cnt == 0:
            return 0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0
        return (
            cnt,
            sum_y2 / cnt,
            0.5 * (sum_rg2 + sum_bg2) / cnt,
            sum_r2 / cnt,
            sum_g2 / cnt,
            sum_b2 / cnt,
            sum_luma / cnt,
        )

    cnt, y_var, c_var, r_var, g_var, b_var, mean_y = _accumulate(use_shadow_filter=(shadow_luma_range is not None))
    shadow_cnt = cnt
    if cnt < 64 and shadow_luma_range is not None:
        cnt, y_var, c_var, r_var, g_var, b_var, mean_y = _accumulate(use_shadow_filter=False)

    # Also compute full-crop mean luma via ImageStat for stability checks
    full_mean_luma = _mean_luma_01(img)

    return {
        "luma_var": y_var,
        "chroma_var": c_var,
        "r_var": r_var,
        "g_var": g_var,
        "b_var": b_var,
        "mean_luma": mean_y if cnt > 0 else full_mean_luma,
        "full_mean_luma": full_mean_luma,
        "sample_count": float(cnt),
        "shadow_sample_count": float(shadow_cnt),
    }


def measure_edge_acutance(
    tools: HostTools,
    image_path: Union[Path, Any],
    box_norm: Optional[Tuple[float, float, float, float]] = (0.20, 0.20, 0.80, 0.80),
    max_dim: Optional[int] = 1024,
) -> float:
    """Measure normalized mid/high-frequency edge energy (RMS of luma high-pass)."""
    _, ImageChops, ImageFilter, ImageStat = _require_pil()
    img = _crop_norm(_resolve_rgb_image(tools, image_path, max_dim), box_norm)
    luma = img.convert("L")
    hp = ImageChops.difference(luma, luma.filter(ImageFilter.BoxBlur(1)))
    stat = ImageStat.Stat(hp)
    return float(stat.rms[0]) / 255.0


def measure_midtone_local_contrast(
    tools: HostTools,
    image_path: Union[Path, Any],
    box_norm: Optional[Tuple[float, float, float, float]] = (0.10, 0.10, 0.90, 0.90),
    max_dim: Optional[int] = 1024,
    luma_range: Tuple[float, float] = (0.15, 0.75),
) -> float:
    """Measure mean |I - blur(I)| across midtone pixels for Clarity verification."""
    _, _, ImageFilter, _ = _require_pil()
    img = _crop_norm(_resolve_rgb_image(tools, image_path, max_dim), box_norm)
    luma = img.convert("L")
    blur = luma.filter(ImageFilter.BoxBlur(5))
    raw_y = luma.tobytes()
    raw_b = blur.tobytes()
    lo = int(luma_range[0] * 255.0)
    hi = int(luma_range[1] * 255.0)
    total = 0.0
    cnt = 0
    for y_val, b_val in zip(raw_y, raw_b):
        if lo <= y_val <= hi:
            total += abs(y_val - b_val)
            cnt += 1
    if cnt < 64:
        total = sum(abs(y_val - b_val) for y_val, b_val in zip(raw_y, raw_b))
        cnt = len(raw_y)
    return (total / float(max(1, cnt))) / 255.0


def measure_highlight_magenta_fraction(
    tools: HostTools,
    image_path: Union[Path, Any],
    luma_thresh: int = 210,
    magenta_excess: int = 18,
    max_dim: Optional[int] = 1024,
) -> Dict[str, Any]:
    """Measure fraction of bright highlight pixels exhibiting purple/magenta clipping cast."""
    img = _resolve_rgb_image(tools, image_path, max_dim)
    raw = img.tobytes()
    bright_pixels = 0
    magenta_pixels = 0
    sum_cast = 0.0
    for i in range(0, len(raw), 3):
        r = raw[i]
        g = raw[i + 1]
        b = raw[i + 2]
        y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        if y >= luma_thresh or max(r, g, b) >= luma_thresh:
            bright_pixels += 1
            excess = min(r, b) - g
            if excess > 0:
                sum_cast += excess / 255.0
            if excess > magenta_excess:
                magenta_pixels += 1
    return {
        "bright_pixels": bright_pixels,
        "magenta_pixels": magenta_pixels,
        "magenta_fraction": magenta_pixels / float(max(1, bright_pixels)),
        "mean_magenta_cast": sum_cast / float(max(1, bright_pixels)),
    }


_HDR_LINEAR_PROBE_SWIFT = r"""
import CoreGraphics
import Foundation
import ImageIO

if CommandLine.arguments.count < 2 {
    fputs("Usage: HDRLinearProbe <image-path> [max-dim]\n", stderr)
    exit(2)
}
let path = CommandLine.arguments[1]
let maxDim = CommandLine.arguments.count >= 3 ? (Int(CommandLine.arguments[2]) ?? 2048) : 2048
let url = URL(fileURLWithPath: path)
guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
    fputs("Failed to open CGImageSource\n", stderr)
    exit(1)
}
let hdrOpts: [CFString: Any] = [
    kCGImageSourceShouldCache: false,
    kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR,
]
guard let hdrCG = CGImageSourceCreateImageAtIndex(src, 0, hdrOpts as CFDictionary) else {
    fputs("Failed kCGImageSourceDecodeToHDR\n", stderr)
    exit(1)
}
let srcW = hdrCG.width
let srcH = hdrCG.height
let scale: Double = max(srcW, srcH) > maxDim ? Double(maxDim) / Double(max(srcW, srcH)) : 1.0
let outW = max(1, Int((Double(srcW) * scale).rounded()))
let outH = max(1, Int((Double(srcH) * scale).rounded()))

guard let p3Linear = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else {
    fputs("Failed extendedLinearDisplayP3 colorspace\n", stderr)
    exit(1)
}
var pixels = [Float](repeating: 0, count: outW * outH * 4)
let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    | CGBitmapInfo.floatComponents.rawValue
    | CGImageByteOrderInfo.order32Host.rawValue
guard let ctx = CGContext(
    data: &pixels,
    width: outW,
    height: outH,
    bitsPerComponent: 32,
    bytesPerRow: outW * 16,
    space: p3Linear,
    bitmapInfo: bitmapInfo
) else {
    fputs("Failed float32 CGContext\n", stderr)
    exit(1)
}
ctx.interpolationQuality = CGInterpolationQuality.none
ctx.draw(hdrCG, in: CGRect(x: 0, y: 0, width: outW, height: outH))

var nanCount = 0
var infCount = 0
var maxCh: Float = -Float.greatestFiniteMagnitude
var minCh: Float = Float.greatestFiniteMagnitude
var sumLuma: Double = 0.0
var validCount = 0

for i in 0..<(outW * outH) {
    let base = i * 4
    let r = pixels[base]
    let g = pixels[base + 1]
    let b = pixels[base + 2]
    let a = pixels[base + 3]
    for v in [r, g, b, a] {
        if v.isNaN { nanCount += 1 }
        else if v.isInfinite { infCount += 1 }
    }
    if r.isFinite && g.isFinite && b.isFinite {
        if r > maxCh { maxCh = r }
        if g > maxCh { maxCh = g }
        if b > maxCh { maxCh = b }
        if r < minCh { minCh = r }
        if g < minCh { minCh = g }
        if b < minCh { minCh = b }
        sumLuma += 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
        validCount += 1
    }
}
if validCount == 0 {
    maxCh = 0
    minCh = 0
}
let obj: [String: Any] = [
    "width": srcW,
    "height": srcH,
    "sampledWidth": outW,
    "sampledHeight": outH,
    "hdrMaxChannel": Double(maxCh),
    "hdrMinChannel": Double(minCh),
    "meanLuma": validCount > 0 ? sumLuma / Double(validCount) : 0.0,
    "nanCount": nanCount,
    "infCount": infCount,
]
let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
print(String(data: data, encoding: .utf8)!)
"""


def _ensure_hdr_linear_probe(tools: HostTools, cache_dir: Path) -> Path:
    cache_dir.mkdir(parents=True, exist_ok=True)
    src = cache_dir / "HDRLinearProbe.swift"
    exe = cache_dir / "HDRLinearProbe"
    if not src.is_file() or src.read_text(encoding="utf-8") != _HDR_LINEAR_PROBE_SWIFT:
        src.write_text(_HDR_LINEAR_PROBE_SWIFT, encoding="utf-8")
    if not exe.is_file() or exe.stat().st_mtime < src.stat().st_mtime:
        swiftc = tools.swiftc or "/usr/bin/swiftc"
        cmd = [
            swiftc,
            "-swift-version",
            "6",
            "-O",
            str(src),
            "-o",
            str(exe),
            "-framework",
            "Foundation",
            "-framework",
            "CoreGraphics",
            "-framework",
            "ImageIO",
        ]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        if proc.returncode != 0 or not exe.is_file():
            raise RuntimeError(f"Failed to compile HDRLinearProbe.swift: {proc.stderr}\n{proc.stdout}")
    return exe


def measure_hdr_linear_stats(
    tools: HostTools,
    image_path: Path,
    cache_dir: Path,
    max_dim: int = 2048,
) -> Dict[str, Any]:
    """Decode HDR image to extended linear Display P3 float32 via cached Swift ImageIO probe."""
    exe = _ensure_hdr_linear_probe(tools, cache_dir)
    proc = subprocess.run(
        [str(exe), str(image_path), str(max_dim)],
        capture_output=True,
        text=True,
        timeout=60,
    )
    if proc.returncode != 0 or not proc.stdout.strip():
        raise RuntimeError(f"HDRLinearProbe failed on {image_path}: {proc.stderr}\n{proc.stdout}")
    return json.loads(proc.stdout)


def check_app_bundle_v11(tools: HostTools, app_bundle: Path) -> Dict[str, Any]:
    """Extended v1.1 app bundle verification (version, LensfunDB, NoiseProfiles, self-contained linkage)."""
    base = check_app_bundle(tools, app_bundle)
    errors: List[str] = list(base["errors"])
    info_plist = app_bundle / "Contents" / "Info.plist"
    resources_dir = app_bundle / "Contents" / "Resources"
    frameworks_dir = app_bundle / "Contents" / "Frameworks"

    short_version: Optional[str] = None
    icon_file: Optional[str] = None
    doc_extensions: List[str] = []
    if info_plist.is_file():
        try:
            with open(info_plist, "rb") as fh:
                plist = plistlib.load(fh)
            short_version = plist.get("CFBundleShortVersionString")
            icon_file = plist.get("CFBundleIconFile")
            for doc in plist.get("CFBundleDocumentTypes") or []:
                for ext in doc.get("CFBundleTypeExtensions") or []:
                    doc_extensions.append(str(ext))
        except Exception as exc:
            errors.append(f"Failed to parse Info.plist: {exc}")

    app_icon_icns = resources_dir / "AppIcon.icns"
    lensfun_xmls = list(resources_dir.rglob("LensfunDB/*.xml")) if resources_dir.is_dir() else []
    lensfun_licenses = list(resources_dir.rglob("LensfunDB/cc-by-sa-3.0.txt")) if resources_dir.is_dir() else []
    noise_profiles = [
        p for p in (resources_dir.rglob("NoiseProfiles/*.json") if resources_dir.is_dir() else [])
        if p.is_file()
    ]
    noise_dirs = [
        p for p in (resources_dir.rglob("NoiseProfiles") if resources_dir.is_dir() else [])
        if p.is_dir()
    ]
    lproj_dirs = list(resources_dir.rglob("*.lproj")) if resources_dir.is_dir() else []

    exec_path = Path(base["executable"])
    macho_targets: List[Path] = []
    if exec_path.is_file():
        macho_targets.append(exec_path)
    if frameworks_dir.is_dir():
        macho_targets.extend(sorted(frameworks_dir.glob("*.dylib")))

    linkage_reports: List[Dict[str, Any]] = []
    for tgt in macho_targets:
        rep = check_gpl3_compatible_linkage(tools, tgt, check_symbols=True, require_self_contained=True)
        linkage_reports.append(rep)
        if not rep["clean"]:
            errors.append(
                f"Self-contained linkage violation in {tgt.name}: "
                f"unbundled={rep['unbundled_refs']}, unresolved_rpaths={rep['unresolved_rpaths']}, "
                f"forbidden_libs={rep['forbidden_libs']}, forbidden_syms={rep['forbidden_symbols']}"
            )

    return {
        **base,
        "short_version": short_version,
        "icon_file": icon_file,
        "app_icon_icns": str(app_icon_icns) if app_icon_icns.is_file() else None,
        "doc_extensions": doc_extensions,
        "lensfun_xml_files": [str(p) for p in lensfun_xmls],
        "lensfun_license_files": [str(p) for p in lensfun_licenses],
        "noise_profile_files": [str(p) for p in noise_profiles],
        "noise_profile_dirs": [str(p) for p in noise_dirs],
        "lproj_dirs": [str(p) for p in lproj_dirs],
        "linkage_reports": linkage_reports,
        "errors": errors,
        "ok": len(errors) == 0,
    }


def probe_binary_strings_and_symbols(
    tools: HostTools,
    binary_path: Path,
    tokens: Sequence[str],
) -> Dict[str, Any]:
    """Scan a Mach-O binary with `strings` and `nm -gU` (and `nm`) for expected tokens."""
    strings_bin = tools.strings or "/usr/bin/strings"
    nm_bin = tools.nm or "/usr/bin/nm"

    s_proc = subprocess.run([strings_bin, str(binary_path)], capture_output=True, text=True, timeout=60)
    if s_proc.returncode != 0:
        raise RuntimeError(f"strings failed on {binary_path}: {s_proc.stderr}")

    nm_text_parts: List[str] = []
    for args in ([nm_bin, "-gU", str(binary_path)], [nm_bin, str(binary_path)]):
        n_proc = subprocess.run(args, capture_output=True, text=True, timeout=60)
        if n_proc.stdout:
            nm_text_parts.append(n_proc.stdout)

    combined = (s_proc.stdout or "") + "\n" + "\n".join(nm_text_parts)
    matched: List[str] = []
    missing: List[str] = []
    for tok in tokens:
        if tok in combined:
            matched.append(tok)
        else:
            missing.append(tok)

    return {
        "binary": str(binary_path),
        "matched": matched,
        "missing": missing,
        "all_found": len(missing) == 0,
    }


def probe_neutral_canvas_invariant(
    tools: HostTools,
    binary_path: Path,
) -> Dict[str, Any]:
    """Verify adaptive Liquid Glass canvas symbols/markers and removal of locked #111214 dark slab in Mach-O."""
    view_scan = probe_binary_strings_and_symbols(
        tools,
        binary_path,
        ["PreviewCanvasView", "EDRMetalPreviewView", "LiquidGlassSystem"],
    )
    adaptive_scan = probe_binary_strings_and_symbols(
        tools,
        binary_path,
        ["adaptive-liquid-glass", "chiaro.canvas.adaptive-liquid-glass"],
    )
    forbidden_scan = probe_binary_strings_and_symbols(
        tools,
        binary_path,
        ["#111214"],
    )

    views_ok = view_scan["all_found"]
    adaptive_ok = len(adaptive_scan["matched"]) > 0
    no_locked_dark_canvas = len(forbidden_scan["matched"]) == 0

    errors: List[str] = []
    if not views_ok:
        errors.append(f"Missing required canvas/LiquidGlass symbols: {view_scan['missing']}")
    if not adaptive_ok:
        errors.append(
            "Missing adaptive Liquid Glass canvas marker ('adaptive-liquid-glass' / 'chiaro.canvas.adaptive-liquid-glass')"
        )
    if not no_locked_dark_canvas:
        errors.append(f"Locked dark canvas string still present in binary: {forbidden_scan['matched']}")

    matched_scheme: Optional[str] = None
    if adaptive_ok and no_locked_dark_canvas:
        if "chiaro.canvas.adaptive-liquid-glass" in adaptive_scan["matched"]:
            matched_scheme = "chiaro.canvas.adaptive-liquid-glass"
        else:
            matched_scheme = "adaptive-liquid-glass"

    color_ok = adaptive_ok and no_locked_dark_canvas

    return {
        "binary": str(binary_path),
        "views_found": view_scan["matched"],
        "views_missing": view_scan["missing"],
        "views_ok": views_ok,
        "adaptive_markers_found": adaptive_scan["matched"],
        "adaptive_ok": adaptive_ok,
        "forbidden_dark_canvas_hits": forbidden_scan["matched"],
        "no_locked_dark_canvas": no_locked_dark_canvas,
        "matched_scheme": matched_scheme,
        "color_ok": color_ok,
        "errors": errors,
        "ok": views_ok and color_ok,
    }


def probe_verify_licenses_sbom(repo_root: Path, require_binaries: bool = False) -> Dict[str, Any]:
    """Run Scripts/verify_licenses.sh and parse SBOM table rows."""
    script = repo_root / "Scripts" / "verify_licenses.sh"
    cmd = ["bash", str(script)]
    if require_binaries:
        cmd.append("--require-binaries")
    proc = subprocess.run(cmd, cwd=str(repo_root), capture_output=True, text=True, timeout=180)
    stdout = proc.stdout or ""
    stderr = proc.stderr or ""

    rows: List[Dict[str, str]] = []
    in_table = False
    for line in stdout.splitlines():
        if line.startswith("Component ") and "|" in line:
            in_table = True
            continue
        if in_table:
            if not line.strip() or set(line.strip()) <= set("-+"):
                if not line.strip():
                    in_table = False
                continue
            parts = [p.strip() for p in line.split("|")]
            if len(parts) == 5:
                rows.append({
                    "component": parts[0],
                    "version": parts[1],
                    "license": parts[2],
                    "linkage": parts[3],
                    "status": parts[4],
                })

    return {
        "returncode": proc.returncode,
        "stdout": stdout,
        "stderr": stderr,
        "rows": rows,
        "all_ok": (proc.returncode == 0 and len(rows) > 0 and all(r["status"] == "OK" for r in rows)),
    }


def smoke_launch_app(
    executable: Path,
    args: Sequence[str] = (),
    hold_s: float = 3.0,
    apple_languages: Optional[str] = None,
    reduce_transparency: bool = False,
) -> Dict[str, Any]:
    """Launch Chiaro executable briefly and assert no premature exit or DiagnosticReports crash."""
    diag_dir = Path.home() / "Library" / "Logs" / "DiagnosticReports"
    before_ips = set(diag_dir.glob("*Chiaro*")) if diag_dir.is_dir() else set()

    launch_args: List[str] = list(args)
    if apple_languages:
        launch_args.extend(["-AppleLanguages", f"({apple_languages})"])
    if reduce_transparency:
        launch_args.extend(["-NSReduceTransparency", "YES"])

    proc = subprocess.Popen(
        [str(executable)] + launch_args,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    premature_rc: Optional[int] = None
    stderr_text = ""
    try:
        time.sleep(hold_s)
        premature_rc = proc.poll()
        if premature_rc is not None and proc.stderr:
            stderr_text = proc.stderr.read().decode(errors="replace")
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)

    after_ips = set(diag_dir.glob("*Chiaro*")) if diag_dir.is_dir() else set()
    new_crashes = sorted(str(p) for p in (after_ips - before_ips))
    return {
        "executable": str(executable),
        "args": launch_args,
        "stayed_alive": premature_rc is None,
        "premature_returncode": premature_rc,
        "stderr": stderr_text,
        "new_crash_logs": new_crashes,
        "ok": (premature_rc is None and len(new_crashes) == 0),
    }

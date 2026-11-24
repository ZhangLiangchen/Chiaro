"""External CLI probe wrappers for Chiaro E2E verification."""

from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional

from config import FORBIDDEN_LICENSE_PATTERNS, FORBIDDEN_SYMBOL_PATTERNS, HostTools


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


def check_zero_gpl_linkage(
    tools: HostTools,
    binary_path: Path,
    check_symbols: bool = True,
) -> Dict[str, Any]:
    """Run otool -L and nm -gU against a Mach-O binary to enforce zero GPL/LGPL linkage."""
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

    otool_lines = otool_proc.stdout.splitlines()
    forbidden_libs: List[str] = []
    dangling_refs: List[str] = []
    for line in otool_lines[1:]:
        stripped = line.strip()
        if not stripped:
            continue
        lib_path = stripped.split(" (compatibility version", 1)[0].strip()
        for pat in FORBIDDEN_LICENSE_PATTERNS:
            if pat.lower() in lib_path.lower():
                forbidden_libs.append(lib_path)
        if lib_path.startswith("/tmp/") or lib_path.startswith("/private/tmp/"):
            dangling_refs.append(lib_path)

    forbidden_syms: List[str] = []
    if check_symbols and tools.nm:
        nm_proc = subprocess.run(
            [tools.nm, "-gU", str(binary_path)],
            capture_output=True,
            text=True,
            timeout=30,
        )
        nm_out = nm_proc.stdout or ""
        for pat in FORBIDDEN_SYMBOL_PATTERNS:
            if pat in nm_out:
                forbidden_syms.append(pat)

    return {
        "binary": str(binary_path),
        "otool_lines": otool_lines,
        "forbidden_libs": forbidden_libs,
        "forbidden_symbols": forbidden_syms,
        "dangling_refs": dangling_refs,
        "clean": (not forbidden_libs and not forbidden_syms),
    }


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

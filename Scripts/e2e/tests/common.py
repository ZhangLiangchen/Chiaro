"""Shared test runner context, preset JSON builder, /usr/bin/time RSS parser, and compliance assertions."""

from __future__ import annotations

import copy
import json
import os
import re
import shlex
import shutil
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple

from config import E2EConfig, HEADROOM_REL_TOL, HostTools
from probes.cli_probes import (
    check_zero_gpl_linkage,
    extract_avif_gainmap_info,
    probe_avifdec,
    probe_avifgainmaputil,
    probe_exiftool,
    probe_ffprobe,
    probe_heif_info,
    probe_ultrahdr,
)
from probes.isobmff_box import inspect_isobmff
from probes.swift_probes import SwiftProbes


CANONICAL_PRESET_TEMPLATE: Dict[str, Any] = {
    "id": "custom_e2e",
    "name": "Custom E2E Preset",
    "description": "E2E generated preset conforming to PROJECT.md Interface Contract #1",
    "outputFormats": ["heic"],
    "bitDepth": 10,
    "baseColorSpace": "displayP3",
    "gainMapChannels": "rgb3ch",
    "gainMapResolution": "half",
    "gainMapGamma": 1.0,
    "targetHeadroomStops": 2.5,
    "midtoneAnchorP": 0.80,
    "sdrToneMapper": "agx",
    "developDefaults": {
        "exposureEV": 0.0,
        "shadowRecovery": 0.0,
        "blackPoint": 0.0,
        "vibrance": 0.0,
        "highlightReconstruction": "opposedInpaint",
        "sdrExposureEV": 0.0,
        "sdrHighlightCompression": 50.0,
        "sdrContrast": 0.0,
        "sdrSaturation": 0.0,
        "hdrHighlightExcitation": 50.0,
        "hdrRolloffSoftness": 50.0,
    },
    "cropAspect": "original",
    "maxLongEdge": None,
    "targetMaxFileBytes": None,
    "quality": 0.90,
    "gainMapQuality": 0.90,
    "avifCodec": "svtAV1",
    "compatOptions": {
        "writeLegacyAppleHDRGainMap": False,
        "writeUltrahdrXMP": False,
        "writeCustomRenderedHDR": False,
        "closedLoopSDRCompensation": False,
    },
    "hlgVideoOptions": {
        "aspect": "9:16",
        "durationSeconds": 4.0,
        "fps": 30,
        "bitrateMbps": 14.0,
    },
    "platformAdvisory": "E2E automated verification preset",
}


@dataclass
class CLIRunResult:
    cmd: List[str]
    returncode: int
    stdout: str
    stderr: str
    duration_s: float
    peak_rss_bytes: Optional[int] = None


@dataclass
class TestCase:
    test_id: str
    tier: int
    feature: str
    name: str
    run: Callable[["RunContext"], None]
    planned_cmd: str = ""


@dataclass
class TestResult:
    test_id: str
    tier: int
    feature: str
    name: str
    status: str  # "PASS" | "FAIL"
    duration_s: float
    peak_rss_bytes: Optional[int] = None
    command: str = ""
    assertions: List[str] = field(default_factory=list)
    error: Optional[str] = None


def parse_time_l_peak_rss(stderr: str) -> Optional[int]:
    """Parse `/usr/bin/time -l` maximum resident set size (bytes on macOS)."""
    m = re.search(r"(\d+)\s+maximum resident set size", stderr)
    if m:
        return int(m.group(1))
    return None


def parse_ndjson_lines(text: str) -> List[Dict[str, Any]]:
    """Parse NDJSON progress lines emitted by --json-progress."""
    parsed: List[Dict[str, Any]] = []
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if not line.startswith("{"):
            continue
        obj = json.loads(line)
        if isinstance(obj, dict):
            parsed.append(obj)
    return parsed


def build_preset_dict(
    preset_id: str = "custom_e2e",
    overrides: Optional[Dict[str, Any]] = None,
    develop_overrides: Optional[Dict[str, Any]] = None,
    compat_overrides: Optional[Dict[str, Any]] = None,
    hlg_overrides: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    data = copy.deepcopy(CANONICAL_PRESET_TEMPLATE)
    data["id"] = preset_id
    if overrides:
        data.update(overrides)
    if develop_overrides:
        data["developDefaults"].update(develop_overrides)
    if compat_overrides:
        data["compatOptions"].update(compat_overrides)
    if hlg_overrides:
        data["hlgVideoOptions"].update(hlg_overrides)
    return data


class RunContext:
    def __init__(self, cfg: E2EConfig, probes: SwiftProbes) -> None:
        self.cfg = cfg
        self.probes = probes
        self.fixtures_dir = cfg.work_dir / "test_fixtures"
        self.fixtures_dir.mkdir(parents=True, exist_ok=True)
        self.current_assertions: List[str] = []
        self.last_command: str = ""
        self.last_peak_rss: Optional[int] = None

    def reset_tracking(self) -> None:
        self.current_assertions = []
        self.last_command = ""
        self.last_peak_rss = None

    def note(self, msg: str) -> None:
        self.current_assertions.append(msg)

    def sample_path(self, filename: str) -> Path:
        p = self.cfg.sample_dir / filename
        if not p.is_file():
            raise FileNotFoundError(f"Sample file not found: {p}")
        return p

    def test_out_dir(self, test_id: str, subdir: Optional[str] = None, clean: bool = True) -> Path:
        p = self.cfg.work_dir / "runs" / test_id
        if subdir:
            p = p / subdir
        if clean and p.exists():
            shutil.rmtree(p)
        p.mkdir(parents=True, exist_ok=True)
        return p

    def write_preset_json(
        self,
        name: str,
        overrides: Optional[Dict[str, Any]] = None,
        develop_overrides: Optional[Dict[str, Any]] = None,
        compat_overrides: Optional[Dict[str, Any]] = None,
        hlg_overrides: Optional[Dict[str, Any]] = None,
    ) -> Path:
        preset = build_preset_dict(
            preset_id=name.replace(".json", ""),
            overrides=overrides,
            develop_overrides=develop_overrides,
            compat_overrides=compat_overrides,
            hlg_overrides=hlg_overrides,
        )
        out = self.fixtures_dir / (name if name.endswith(".json") else f"{name}.json")
        out.write_text(json.dumps(preset, indent=2), encoding="utf-8")
        return out

    def ensure_corrupt_arws(self) -> Dict[str, Path]:
        src = self.sample_path("DSC02532.ARW")
        trunc = self.fixtures_dir / "corrupt_truncated.arw"
        if not trunc.is_file():
            trunc.write_bytes(src.read_bytes()[:1024])
        garb = self.fixtures_dir / "corrupt_garbage.arw"
        if not garb.is_file():
            garb.write_bytes(os.urandom(4096))
        empty = self.fixtures_dir / "empty_zero.arw"
        if not empty.is_file():
            empty.write_bytes(b"")
        return {"truncated": trunc, "garbage": garb, "empty": empty}

    def run_cmd(
        self,
        cmd: Sequence[str],
        *,
        measure_rss: bool = False,
        env_override: Optional[Dict[str, str]] = None,
        cwd: Optional[Path] = None,
        timeout: int = 300,
    ) -> CLIRunResult:
        full_cmd = list(cmd)
        if measure_rss:
            time_bin = self.cfg.tools.time_bin or "/usr/bin/time"
            full_cmd = [time_bin, "-l"] + full_cmd

        env = os.environ.copy()
        if env_override:
            env.update(env_override)

        cmd_str = " ".join(shlex.quote(c) for c in full_cmd)
        self.last_command = cmd_str
        if self.cfg.verbose:
            print(f"    $ {cmd_str}")

        t0 = time.monotonic()
        proc = subprocess.run(
            full_cmd,
            capture_output=True,
            text=True,
            env=env,
            cwd=str(cwd) if cwd else None,
            timeout=timeout,
        )
        dt = time.monotonic() - t0
        rss = parse_time_l_peak_rss(proc.stderr or "") if measure_rss else None
        if rss is not None:
            self.last_peak_rss = rss
        if self.cfg.verbose:
            print(f"    -> rc={proc.returncode} ({dt:.2f}s)" + (f" rss={rss}" if rss else ""))
        return CLIRunResult(
            cmd=full_cmd,
            returncode=proc.returncode,
            stdout=proc.stdout or "",
            stderr=proc.stderr or "",
            duration_s=dt,
            peak_rss_bytes=rss,
        )

    def run_cli(
        self,
        args: Sequence[str],
        *,
        measure_rss: bool = False,
        env_override: Optional[Dict[str, str]] = None,
        use_sandbox_deny_net: bool = False,
        cwd: Optional[Path] = None,
        timeout: int = 600,
    ) -> CLIRunResult:
        if self.cfg.cli_bin is None:
            raise RuntimeError("chiaro binary not resolved")
        cmd: List[str] = [str(self.cfg.cli_bin)] + list(args)
        if use_sandbox_deny_net:
            sb = self.cfg.tools.sandbox_exec or "/usr/bin/sandbox-exec"
            cmd = [sb, "-p", "(version 1)(allow default)(deny network*)"] + cmd
        return self.run_cmd(
            cmd,
            measure_rss=measure_rss,
            env_override=env_override,
            cwd=cwd,
            timeout=timeout,
        )


def assert_headroom_within_tol(
    measured: Optional[float],
    expected_stops: float,
    tol: float = HEADROOM_REL_TOL,
    label: str = "contentHeadroom",
) -> float:
    assert measured is not None, f"{label} is None"
    assert measured > 1.0, f"{label}={measured} must be > 1.0"
    expected_linear = 2.0 ** expected_stops
    rel_err = abs(measured - expected_linear) / expected_linear
    assert rel_err < tol, (
        f"{label}={measured:.4f} differs from expected 2^{expected_stops}={expected_linear:.4f} "
        f"by {rel_err*100:.2f}% (>= {tol*100:.1f}%)"
    )
    return rel_err


def assert_exif_clean_and_whitelisted(
    probe_json: Dict[str, Any],
    exif_res: Any,
    *,
    expect_custom_rendered: Optional[int] = None,
    check_sony_fields: bool = True,
    allow_apple_makernote: bool = False,
    check_exif_orientation_tag: bool = True,
) -> None:
    exif = probe_json.get("exif") or {}
    assert not exif.get("hasExifMakerNote", False), "ImageIOProbe detected ExifIFD MakerNote"
    assert not exif.get("makerDictionaries"), f"ImageIOProbe detected makerDictionaries: {exif.get('makerDictionaries')}"

    bad_sony = exif_res.has_forbidden_sony_or_makernote()
    assert not bad_sony, f"exiftool found forbidden Sony/MakerNote tags: {bad_sony}"

    if not allow_apple_makernote:
        bad_apple = exif_res.has_forbidden_apple_makernote()
        assert not bad_apple, f"exiftool found forbidden Apple MakerNote tags: {bad_apple}"

    if check_sony_fields:
        raw = exif_res.raw_dict
        assert raw.get("IFD0:Make") == "SONY" or exif.get("make") == "SONY", f"Make mismatch: {raw.get('IFD0:Make')}"
        assert raw.get("IFD0:Model") == "ILCE-7CM2" or exif.get("model") == "ILCE-7CM2", f"Model mismatch: {raw.get('IFD0:Model')}"
        lens = str(raw.get("ExifIFD:LensModel") or exif.get("lensModel") or "")
        assert "TAMRON 25-200mm" in lens, f"LensModel missing/wrong: {lens!r}"
        dto = str(raw.get("ExifIFD:DateTimeOriginal") or exif.get("dateTimeOriginal") or "")
        assert dto.startswith("2026:11:22"), f"DateTimeOriginal missing/wrong: {dto!r}"
        oto = str(raw.get("ExifIFD:OffsetTimeOriginal") or exif.get("offsetTimeOriginal") or "")
        assert oto == "+08:00", f"OffsetTimeOriginal missing/wrong: {oto!r}"

    if check_exif_orientation_tag:
        ori_iio = probe_json.get("orientation")
        assert ori_iio == 1, f"ImageIOProbe orientation={ori_iio} != 1"
        raw_ori = exif_res.raw_dict.get("IFD0:Orientation")
        assert raw_ori is not None, "Missing explicit IFD0:Orientation tag (expected Orientation = 1)"
        assert exif_res.orientation_numeric() == 1, f"IFD0:Orientation={raw_ori!r} != 1"

    if expect_custom_rendered is not None:
        cr_iio = exif.get("customRendered")
        raw_cr = exif_res.raw_dict.get("ExifIFD:CustomRendered")
        if expect_custom_rendered == 3:
            assert cr_iio == 3 or str(raw_cr) in ("3", "Custom", "HDR (original saved)"), (
                f"Expected CustomRendered=3, got iio={cr_iio}, exiftool={raw_cr!r}"
            )
        else:
            assert cr_iio != 3 and str(raw_cr) not in ("3", "Custom", "HDR (original saved)"), (
                f"Expected CustomRendered!=3, got iio={cr_iio}, exiftool={raw_cr!r}"
            )


def assert_heic_compliant(
    ctx: RunContext,
    heic_path: Path,
    *,
    expected_stops: float = 2.5,
    expected_depth: int = 10,
    expect_legacy_gm: Optional[bool] = False,
    expect_w: Optional[int] = None,
    expect_h: Optional[int] = None,
    expect_custom_rendered: Optional[int] = None,
    check_sony_fields: bool = True,
) -> Dict[str, Any]:
    assert heic_path.is_file() and heic_path.stat().st_size > 0, f"Missing/empty HEIC: {heic_path}"
    iio = ctx.probes.probe_image(heic_path)
    assert iio.get("error") is None, f"ImageIOProbe error: {iio.get('error')}"
    assert iio.get("hasISOGainMap") is True, f"HEIC missing ISOGainMap: {heic_path}"
    if expect_legacy_gm is not None:
        assert iio.get("hasLegacyHDRGainMap") is expect_legacy_gm, (
            f"Expected hasLegacyHDRGainMap={expect_legacy_gm}, got {iio.get('hasLegacyHDRGainMap')}"
        )
    assert iio.get("hdrDecodeSucceeded") is True, "ImageIO HDR decode failed"
    assert iio.get("depth") == expected_depth, f"Expected depth={expected_depth}, got {iio.get('depth')}"
    assert iio.get("orientation") == 1, f"Expected orientation=1, got {iio.get('orientation')}"
    if expect_w is not None:
        assert iio.get("pixelWidth") == expect_w, f"Expected width={expect_w}, got {iio.get('pixelWidth')}"
    if expect_h is not None:
        assert iio.get("pixelHeight") == expect_h, f"Expected height={expect_h}, got {iio.get('pixelHeight')}"
    stats = iio.get("pixelStats") or {}
    assert not stats.get("isAllBlack", True), "Decoded HEIC is all black"
    assert stats.get("varianceLuma", 0.0) > 0.0, "Decoded HEIC has zero pixel variance"

    assert_headroom_within_tol(iio.get("contentHeadroom"), expected_stops)

    box = inspect_isobmff(heic_path)
    assert box.has_tmap_item, f"ISOBMFF missing tmap item in {heic_path}: {box.items}"
    assert box.has_dimg_for_tmap, f"ISOBMFF missing dimg reference from tmap in {heic_path}"
    assert box.has_altr_group, f"ISOBMFF missing altr entity group in {heic_path}"

    hinfo = probe_heif_info(ctx.cfg.tools, heic_path)
    assert hinfo.returncode == 0, f"heif-info failed on {heic_path}: {hinfo.stderr}"

    exif_res = probe_exiftool(ctx.cfg.tools, heic_path)
    assert_exif_clean_and_whitelisted(
        iio,
        exif_res,
        expect_custom_rendered=expect_custom_rendered,
        check_sony_fields=check_sony_fields,
        allow_apple_makernote=False,
    )
    ctx.note(
        f"HEIC OK {heic_path.name}: {iio.get('pixelWidth')}x{iio.get('pixelHeight')}, "
        f"depth={iio.get('depth')}, headroom={iio.get('contentHeadroom'):.3f}"
    )
    return {"imageio": iio, "isobmff": box, "heif_info": hinfo, "exiftool": exif_res}


def assert_jpeg_compliant(
    ctx: RunContext,
    jpg_path: Path,
    *,
    expected_stops: float = 2.5,
    expect_xmp_hdrgm: Optional[bool] = True,
    expect_icc_substr: Optional[str] = "Display P3",
    max_bytes: Optional[int] = None,
    max_app1_bytes: Optional[int] = 16384,
    expect_w: Optional[int] = None,
    expect_h: Optional[int] = None,
    expect_custom_rendered: Optional[int] = None,
    check_sony_fields: bool = True,
    run_ultrahdr: bool = True,
) -> Dict[str, Any]:
    assert jpg_path.is_file() and jpg_path.stat().st_size > 0, f"Missing/empty JPEG: {jpg_path}"
    size_bytes = jpg_path.stat().st_size
    if max_bytes is not None:
        assert size_bytes <= max_bytes, f"JPEG {jpg_path.name} size {size_bytes} > {max_bytes}"

    iio = ctx.probes.probe_image(jpg_path)
    assert iio.get("error") is None, f"ImageIOProbe error: {iio.get('error')}"
    assert iio.get("hasISOGainMap") is True, f"JPEG missing ISOGainMap: {jpg_path}"
    assert iio.get("hdrDecodeSucceeded") is True, "ImageIO HDR decode failed on JPEG"
    assert iio.get("orientation") == 1, f"Expected orientation=1, got {iio.get('orientation')}"
    if expect_w is not None:
        assert iio.get("pixelWidth") == expect_w, f"Expected width={expect_w}, got {iio.get('pixelWidth')}"
    if expect_h is not None:
        assert iio.get("pixelHeight") == expect_h, f"Expected height={expect_h}, got {iio.get('pixelHeight')}"
    assert_headroom_within_tol(iio.get("contentHeadroom"), expected_stops)

    exif_res = probe_exiftool(ctx.cfg.tools, jpg_path)
    assert exif_res.has_iso21496_app2_urn(), "JPEG missing APP2 urn:iso:std:iso:ts:21496:-1"
    assert exif_res.has_valid_mpf_gainmap(), (
        f"JPEG MPF invalid: num={exif_res.raw_dict.get('MPF0:NumberOfImages')}, "
        f"mp1={exif_res.raw_dict.get('MPImage1:MPImageType')}, "
        f"mp2_fmt={exif_res.raw_dict.get('MPImage2:MPImageFormat')}, "
        f"mp2_len={exif_res.raw_dict.get('MPImage2:MPImageLength')}"
    )
    if expect_xmp_hdrgm is True:
        assert exif_res.has_xmp_hdrgm(), "JPEG missing XMP-hdrgm tags"
    elif expect_xmp_hdrgm is False:
        assert not exif_res.has_xmp_hdrgm(), "3ch JPEG unexpectedly contains XMP-hdrgm tags"

    if expect_icc_substr:
        icc_desc = exif_res.icc_description()
        prof_name = str(iio.get("profileName") or "")
        assert (expect_icc_substr.lower() in icc_desc.lower()) or (
            expect_icc_substr.lower() in prof_name.lower()
        ), f"Expected ICC containing {expect_icc_substr!r}, got exif={icc_desc!r}, iio={prof_name!r}"

    if max_app1_bytes is not None:
        assert exif_res.app1_exif_size_bytes is not None, (
            f"Missing Exif APP1 segment in {jpg_path.name}"
        )
        assert exif_res.app1_exif_size_bytes <= max_app1_bytes, (
            f"JPEG Exif APP1 size {exif_res.app1_exif_size_bytes} > {max_app1_bytes}"
        )

    assert_exif_clean_and_whitelisted(
        iio,
        exif_res,
        expect_custom_rendered=expect_custom_rendered,
        check_sony_fields=check_sony_fields,
        allow_apple_makernote=False,
    )

    uhdr_res = None
    if run_ultrahdr:
        uhdr_res = probe_ultrahdr(ctx.cfg.tools, jpg_path)
        assert uhdr_res.returncode == 0, f"ultrahdr_app failed ({uhdr_res.mode}): {uhdr_res.stderr} {uhdr_res.stdout}"
        if uhdr_res.mode == "probe_P":
            assert "Ultra HDR Image: Yes" in uhdr_res.stdout, (
                f"ultrahdr_app -P did not report Ultra HDR Image: Yes: {uhdr_res.stdout}"
            )
            assert "--maxContentBoost" in uhdr_res.metadata_cfg, (
                f"ultrahdr_app -P missing --maxContentBoost: {uhdr_res.stdout}"
            )
        elif uhdr_res.mode == "decode_fallback_v1_4":
            assert uhdr_res.decoded_raw_bytes > 0, "ultrahdr_app decode produced empty raw file"
            assert "--maxContentBoost" in uhdr_res.metadata_cfg, (
                f"ultrahdr_app metadata missing --maxContentBoost: {uhdr_res.metadata_cfg}"
            )

    ctx.note(
        f"JPEG OK {jpg_path.name}: {iio.get('pixelWidth')}x{iio.get('pixelHeight')}, "
        f"{size_bytes} B, headroom={iio.get('contentHeadroom'):.3f}"
    )
    return {"imageio": iio, "exiftool": exif_res, "ultrahdr": uhdr_res}


def assert_avif_compliant(
    ctx: RunContext,
    avif_path: Path,
    *,
    expected_stops: float = 2.5,
    expected_depth: int = 10,
    expect_grid: Optional[bool] = None,
    expect_gm_yuv: Optional[str] = None,
    expect_gm_full_res: Optional[bool] = None,
    expected_gamma: Optional[float] = None,
    expect_w: Optional[int] = None,
    expect_h: Optional[int] = None,
    expect_custom_rendered: Optional[int] = None,
    check_sony_fields: bool = True,
    decode_16bit: bool = True,
) -> Dict[str, Any]:
    assert avif_path.is_file() and avif_path.stat().st_size > 0, f"Missing/empty AVIF: {avif_path}"

    adec = probe_avifdec(ctx.cfg.tools, avif_path, decode_16bit_png=decode_16bit)
    assert adec.returncode == 0, f"avifdec failed on {avif_path.name}: {adec.stderr}\n{adec.stdout}"
    assert adec.bit_depth == expected_depth, f"Expected AVIF bit depth {expected_depth}, got {adec.bit_depth}"
    assert adec.gain_map_width is not None and adec.gain_map_height is not None, "avifdec reported no gain map"
    if expect_w is not None:
        assert adec.width == expect_w, f"Expected AVIF width={expect_w}, got {adec.width}"
    if expect_h is not None:
        assert adec.height == expect_h, f"Expected AVIF height={expect_h}, got {adec.height}"
    if expect_gm_full_res is True and adec.width and adec.height:
        assert adec.gain_map_width == adec.width and adec.gain_map_height == adec.height, (
            f"Expected full-res GM {adec.width}x{adec.height}, got {adec.gain_map_width}x{adec.gain_map_height}"
        )
    elif expect_gm_full_res is False and adec.width and adec.height:
        assert adec.gain_map_width <= (adec.width + 1) // 2 and adec.gain_map_height <= (adec.height + 1) // 2, (
            f"Expected half-res GM for {adec.width}x{adec.height}, got {adec.gain_map_width}x{adec.gain_map_height}"
        )

    if expect_gm_yuv:
        gm_info = extract_avif_gainmap_info(ctx.cfg.tools, avif_path)
        assert gm_info.returncode == 0, f"extractgainmap/avifdec failed: {gm_info.stderr}"
        assert gm_info.yuv_format == expect_gm_yuv, (
            f"Expected gain map YUV={expect_gm_yuv}, got {gm_info.yuv_format}"
        )

    agm = probe_avifgainmaputil(ctx.cfg.tools, avif_path)
    assert agm.returncode == 0, f"avifgainmaputil printmetadata failed: {agm.stderr}"
    assert agm.base_headroom is not None, f"Failed to parse Base headroom from avifgainmaputil: {agm.stdout}"
    assert agm.alt_headroom is not None, f"Failed to parse Alternate headroom from avifgainmaputil: {agm.stdout}"
    assert -10.0 <= agm.alt_headroom <= 20.0, f"Out-of-range Alternate headroom={agm.alt_headroom}"
    assert_headroom_within_tol(
        2.0 ** agm.alt_headroom,
        expected_stops,
        label="avifgainmaputil alt_headroom",
    )
    if expected_gamma is not None:
        assert agm.gamma is not None, f"Failed to parse Gain Map Gamma from avifgainmaputil: {agm.stdout}"
        assert abs(agm.gamma - expected_gamma) < 0.05, f"Expected gamma={expected_gamma}, got {agm.gamma}"

    iio = ctx.probes.probe_image(avif_path)
    assert iio.get("error") is None, f"ImageIOProbe error on AVIF: {iio.get('error')}"
    assert iio.get("hasISOGainMap") is True, "ImageIOProbe: AVIF missing ISOGainMap"
    assert iio.get("depth") == expected_depth, f"ImageIOProbe: expected depth={expected_depth}, got {iio.get('depth')}"
    assert iio.get("orientation") == 1, f"ImageIOProbe: orientation={iio.get('orientation')} != 1"
    assert_headroom_within_tol(iio.get("contentHeadroom"), expected_stops)

    box = inspect_isobmff(avif_path)
    assert not box.parse_errors, f"AVIF ISOBMFF parse errors in {avif_path.name}: {box.parse_errors}"
    assert box.has_tmap_item, f"AVIF ISOBMFF missing tmap item: {box.items}"
    assert not box.tmap_forbidden_props, f"AVIF tmap has forbidden properties: {box.tmap_forbidden_props}"
    effective_expect_grid = expect_grid
    if effective_expect_grid is None and adec.width is not None and adec.height is not None:
        if adec.width > 4096 or adec.height > 4096 or (adec.width * adec.height) > 8_912_896:
            effective_expect_grid = True
    if effective_expect_grid is True:
        assert box.has_grid_item and box.has_dimg_for_grid, f"Expected MIAF grid box in {avif_path.name}: {box.items}"
    elif effective_expect_grid is False:
        assert not box.has_grid_item, f"Unexpected grid box in small AVIF {avif_path.name}"

    exif_res = probe_exiftool(ctx.cfg.tools, avif_path)
    assert_exif_clean_and_whitelisted(
        iio,
        exif_res,
        expect_custom_rendered=expect_custom_rendered,
        check_sony_fields=check_sony_fields,
        allow_apple_makernote=False,
    )
    ctx.note(
        f"AVIF OK {avif_path.name}: {adec.width}x{adec.height} (GM {adec.gain_map_width}x{adec.gain_map_height}), "
        f"grid={box.has_grid_item}, headroom={iio.get('contentHeadroom'):.3f}"
    )
    return {"avifdec": adec, "avifgm": agm, "imageio": iio, "isobmff": box, "exiftool": exif_res}


def assert_hlg_mp4_compliant(
    ctx: RunContext,
    mp4_path: Path,
    *,
    allowed_sizes: Sequence[Tuple[int, int]] = ((1080, 1920), (1080, 1440)),
    min_dur: float = 3.0,
    max_dur: float = 5.0,
    min_bitrate: Optional[int] = 10_800_000,
    max_bitrate: Optional[int] = 17_600_000,
    expected_fps: float = 30.0,
) -> Dict[str, Any]:
    assert mp4_path.is_file() and mp4_path.stat().st_size > 0, f"Missing/empty MP4: {mp4_path}"
    ff = probe_ffprobe(ctx.cfg.tools, mp4_path)
    assert ff.returncode == 0, f"ffprobe failed on {mp4_path}"
    assert ff.codec_name == "hevc", f"Expected hevc, got {ff.codec_name}"
    assert ff.profile == "Main 10", f"Expected Main 10, got {ff.profile}"
    assert ff.pix_fmt == "yuv420p10le", f"Expected yuv420p10le, got {ff.pix_fmt}"
    assert ff.color_primaries == "bt2020", f"Expected bt2020 primaries, got {ff.color_primaries}"
    assert ff.color_transfer == "arib-std-b67", f"Expected arib-std-b67 transfer, got {ff.color_transfer}"
    assert ff.color_space == "bt2020nc", f"Expected bt2020nc matrix, got {ff.color_space}"
    assert ff.color_range == "tv", f"Expected tv video range, got {ff.color_range}"
    assert (ff.width, ff.height) in allowed_sizes, (
        f"MP4 dimensions {(ff.width, ff.height)} not in allowed {allowed_sizes}"
    )
    assert ff.duration is not None and (min_dur - 0.1) <= ff.duration <= (max_dur + 0.1), (
        f"MP4 duration {ff.duration} outside [{min_dur}, {max_dur}]"
    )
    if expected_fps:
        assert ff.fps is not None, f"ffprobe missing r_frame_rate/fps on {mp4_path.name}"
        assert abs(ff.fps - expected_fps) < 0.5, f"Expected fps={expected_fps}, got {ff.fps}"
    if min_bitrate is not None or max_bitrate is not None:
        assert ff.bit_rate is not None, f"ffprobe missing bit_rate on {mp4_path.name}"
        if min_bitrate is not None:
            assert ff.bit_rate >= min_bitrate, (
                f"MP4 bitrate {ff.bit_rate} < min_bitrate {min_bitrate}"
            )
        if max_bitrate is not None:
            assert ff.bit_rate <= max_bitrate, (
                f"MP4 bitrate {ff.bit_rate} > max_bitrate {max_bitrate}"
            )

    hlg = ctx.probes.probe_hlg_video(mp4_path)
    assert hlg.get("error") is None, f"HLGVideoProbe error: {hlg.get('error')}"
    assert hlg.get("isHEVCMain10") is True, f"HLGVideoProbe: not HEVC Main 10 ({hlg})"
    assert hlg.get("hvccBitDepthLuma") == 10 and hlg.get("hvccBitDepthChroma") == 10, (
        f"HLGVideoProbe: expected 10-bit hvcC, got luma={hlg.get('hvccBitDepthLuma')} chroma={hlg.get('hvccBitDepthChroma')}"
    )
    assert hlg.get("colorPrimaries") == "ITU_R_2020", f"HLGVideoProbe primaries={hlg.get('colorPrimaries')}"
    assert hlg.get("transferFunction") == "ITU_R_2100_HLG", f"HLGVideoProbe transfer={hlg.get('transferFunction')}"
    assert hlg.get("fullRangeVideo") is False, f"HLGVideoProbe fullRangeVideo={hlg.get('fullRangeVideo')}"
    assert hlg.get("firstFrameReadable") is True, "HLGVideoProbe could not decode first frame"

    ctx.note(
        f"HLG MP4 OK {mp4_path.name}: {ff.width}x{ff.height}, {ff.duration:.2f}s, "
        f"Main10 10-bit BT.2020 HLG"
    )
    return {"ffprobe": ff, "hlg_probe": hlg}


def assert_zero_gpl(ctx: RunContext, binary_path: Path, check_symbols: bool = True) -> Dict[str, Any]:
    res = check_zero_gpl_linkage(ctx.cfg.tools, binary_path, check_symbols=check_symbols)
    assert res["clean"], (
        f"GPL/LGPL violation in {binary_path}: libs={res['forbidden_libs']}, syms={res['forbidden_symbols']}"
    )
    ctx.note(f"License clean: {binary_path.name}")
    return res

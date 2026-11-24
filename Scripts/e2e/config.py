"""Discovery, host-tool capability detection, and Tangmo dataset catalog for Chiaro E2E."""

from __future__ import annotations

import glob
import os
import re
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional


REPO_ROOT = Path(__file__).resolve().parents[2]
E2E_ROOT = Path(__file__).resolve().parent
DEFAULT_SAMPLE_DIR = Path(os.environ.get("CHIARO_SAMPLE_DIR", "Samples")).expanduser()

BUILTIN_PRESET_IDS: List[str] = [
    "apple_heic",
    "apple_heic_compat",
    "xiaohongshu_jpg",
    "douyin_jpg",
    "douyin_hlg_mp4",
    "tri_format",
    "avif_archive",
]

FORBIDDEN_LICENSE_PATTERNS: List[str] = [
    "x265",
    "libx265",
    "Exiv2",
    "exiv2",
    "libexiv2",
    "libheif",
    "x264",
    "libx264",
    "libde265",
]

FORBIDDEN_SYMBOL_PATTERNS: List[str] = [
    "heif_context_",
    "heif_encoder_",
    "x265_encoder_",
    "Exiv2::",
    "dht_demosaic",
    "aahd_demosaic",
    "dcb_demosaic",
    "amaze_demosaic",
]

PEAK_RSS_LIMIT_BYTES = 4_831_838_208  # 4.5 GiB
HEADROOM_REL_TOL = 0.02


class ConfigError(RuntimeError):
    """Raised on fatal configuration / discovery error (runner exits with code 2)."""


@dataclass(frozen=True)
class SampleInfo:
    filename: str
    group: str
    width: int
    height: int
    raw_orientation: int
    iso: int
    is_apsc: bool

    @property
    def upright_width(self) -> int:
        return self.height if self.raw_orientation in (5, 6, 7, 8) else self.width

    @property
    def upright_height(self) -> int:
        return self.width if self.raw_orientation in (5, 6, 7, 8) else self.height


TANGMO_CATALOG: Dict[str, SampleInfo] = {
    # Group A: Full-Frame 33MP Horizontal (20 files)
    **{
        f"DSC0{n}.ARW": SampleInfo(
            filename=f"DSC0{n}.ARW",
            group="A_FF_Horiz_HighISO",
            width=7008,
            height=4672,
            raw_orientation=1,
            iso=10000 if n == 2532 else 12800,
            is_apsc=False,
        )
        for n in list(range(2532, 2540)) + list(range(2543, 2555))
    },
    # Group B: Full-Frame 33MP Horizontal Low-ISO Long Exp (1 file)
    "DSC02555.ARW": SampleInfo(
        filename="DSC02555.ARW",
        group="B_FF_Horiz_LowISO",
        width=7008,
        height=4672,
        raw_orientation=1,
        iso=1600,
        is_apsc=False,
    ),
    # Group C: Full-Frame 33MP Portrait Rotate 270 CW (3 files)
    **{
        f"DSC0{n}.ARW": SampleInfo(
            filename=f"DSC0{n}.ARW",
            group="C_FF_Portrait",
            width=7008,
            height=4672,
            raw_orientation=8,
            iso=12800,
            is_apsc=False,
        )
        for n in range(2540, 2543)
    },
    # Group D: APS-C 14MP Portrait Rotate 270 CW M-size RAW (11 files)
    **{
        f"DSC0{n}.ARW": SampleInfo(
            filename=f"DSC0{n}.ARW",
            group="D_APSC_Portrait",
            width=4608,
            height=3072,
            raw_orientation=8,
            iso=6400,
            is_apsc=True,
        )
        for n in range(2556, 2567)
    },
}


@dataclass
class HostTools:
    swiftc: Optional[str] = None
    exiftool: Optional[str] = None
    avifdec: Optional[str] = None
    avifgainmaputil: Optional[str] = None
    ffprobe: Optional[str] = None
    heif_info: Optional[str] = None
    ultrahdr_app: Optional[str] = None
    ultrahdr_version: Optional[str] = None
    ultrahdr_mode: str = "missing"  # "probe_P" | "decode_fallback_v1_4" | "missing"
    otool: Optional[str] = None
    nm: Optional[str] = None
    strings: Optional[str] = None
    codesign: Optional[str] = None
    plutil: Optional[str] = None
    plistbuddy: Optional[str] = None
    sandbox_exec: Optional[str] = None
    time_bin: Optional[str] = None
    versions: Dict[str, str] = field(default_factory=dict)


@dataclass
class E2EConfig:
    repo_root: Path
    e2e_root: Path
    sample_dir: Path
    work_dir: Path
    output_verify_dir: Optional[Path]
    cli_bin: Optional[Path]
    app_bundle: Optional[Path]
    tools: HostTools
    verbose: bool = False
    fail_fast: bool = False


def _find_exec(name: str, extra_paths: Optional[List[str]] = None) -> Optional[str]:
    found = shutil.which(name)
    if found and os.access(found, os.X_OK):
        return found
    for p in extra_paths or []:
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


def _run_version(cmd: List[str]) -> str:
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        out = (proc.stdout or proc.stderr or "").strip()
        return out.splitlines()[0] if out else ""
    except Exception:
        return ""


def discover_ultrahdr_app(repo_root: Path) -> tuple[Optional[str], Optional[str], str]:
    """Discover ultrahdr_app and probe -P support without false positives."""
    candidates: List[Path] = []
    env_bin = os.environ.get("CHIARO_ULTRAHDR_APP")
    if env_bin:
        candidates.append(Path(env_bin))

    vendor_dir = repo_root / "Vendor"
    if vendor_dir.is_dir():
        for match in sorted(glob.glob(str(vendor_dir / "**" / "ultrahdr_app"), recursive=True)):
            candidates.append(Path(match))

    which_bin = shutil.which("ultrahdr_app")
    if which_bin:
        candidates.append(Path(which_bin))

    chosen: Optional[str] = None
    for cand in candidates:
        if cand.is_file() and os.access(cand, os.X_OK):
            chosen = str(cand)
            break

    if not chosen:
        return None, None, "missing"

    try:
        proc = subprocess.run([chosen, "-h"], capture_output=True, text=True, timeout=10)
        help_text = (proc.stdout or "") + "\n" + (proc.stderr or "")
    except Exception:
        help_text = ""

    version: Optional[str] = None
    m = re.search(r"lib\s+version:\s*(v?[0-9]+(?:\.[0-9]+)*)", help_text, re.IGNORECASE)
    if m:
        version = m.group(1)

    # Verify whether -P (probe mode) is actually documented & supported
    has_p_flag = bool(re.search(r"(?m)^\s*-P\b", help_text))
    if not has_p_flag:
        # Also empirically verify -P isn't silently accepted or rejected
        try:
            p_test = subprocess.run([chosen, "-P"], capture_output=True, text=True, timeout=5)
            err = (p_test.stdout or "") + (p_test.stderr or "")
            if "unsupported option" not in err.lower() and p_test.returncode == 0:
                has_p_flag = True
        except Exception:
            pass

    mode = "probe_P" if has_p_flag else "decode_fallback_v1_4"
    return chosen, version, mode


def discover_host_tools(repo_root: Path) -> HostTools:
    tools = HostTools()
    tools.swiftc = _find_exec("swiftc", ["/usr/bin/swiftc"])
    tools.exiftool = _find_exec("exiftool", ["/opt/homebrew/bin/exiftool"])
    tools.avifdec = _find_exec("avifdec", ["/opt/homebrew/bin/avifdec"])
    tools.avifgainmaputil = _find_exec("avifgainmaputil", ["/opt/homebrew/bin/avifgainmaputil"])
    tools.ffprobe = _find_exec("ffprobe", ["/opt/homebrew/bin/ffprobe"])
    tools.heif_info = _find_exec("heif-info", ["/opt/homebrew/bin/heif-info"])
    tools.otool = _find_exec("otool", ["/usr/bin/otool"])
    tools.nm = _find_exec("nm", ["/usr/bin/nm"])
    tools.strings = _find_exec("strings", ["/usr/bin/strings"])
    tools.codesign = _find_exec("codesign", ["/usr/bin/codesign"])
    tools.plutil = _find_exec("plutil", ["/usr/bin/plutil"])
    tools.plistbuddy = _find_exec("PlistBuddy", ["/usr/libexec/PlistBuddy"])
    tools.sandbox_exec = _find_exec("sandbox-exec", ["/usr/bin/sandbox-exec"])
    tools.time_bin = _find_exec("time", ["/usr/bin/time"])

    uhdr_bin, uhdr_ver, uhdr_mode = discover_ultrahdr_app(repo_root)
    tools.ultrahdr_app = uhdr_bin
    tools.ultrahdr_version = uhdr_ver
    tools.ultrahdr_mode = uhdr_mode

    if tools.swiftc:
        tools.versions["swiftc"] = _run_version([tools.swiftc, "--version"])
    if tools.exiftool:
        tools.versions["exiftool"] = _run_version([tools.exiftool, "-ver"])
    if tools.avifdec:
        tools.versions["avifdec"] = _run_version([tools.avifdec, "--version"])
    if tools.ffprobe:
        tools.versions["ffprobe"] = _run_version([tools.ffprobe, "-version"])
    if tools.heif_info:
        tools.versions["heif-info"] = _run_version([tools.heif_info, "--version"])
    if tools.ultrahdr_app:
        tools.versions["ultrahdr_app"] = f"{tools.ultrahdr_version or 'unknown'} ({tools.ultrahdr_mode})"

    return tools


def discover_cli_bin(repo_root: Path, explicit: Optional[str]) -> Optional[Path]:
    if explicit:
        p = Path(explicit).expanduser().resolve()
        if not (p.is_file() and os.access(p, os.X_OK)):
            raise ConfigError(f"Explicit --cli-bin does not exist or is not executable: {p}")
        return p

    env_val = os.environ.get("CHIARO_CLI_BIN")
    if env_val:
        p = Path(env_val).expanduser().resolve()
        if p.is_file() and os.access(p, os.X_OK):
            return p

    for rel in [
        repo_root / ".build" / "release" / "chiaro-cli",
        repo_root / ".build" / "arm64-apple-macosx" / "release" / "chiaro-cli",
        repo_root / ".build" / "debug" / "chiaro-cli",
        repo_root / ".build" / "arm64-apple-macosx" / "debug" / "chiaro-cli",
    ]:
        if rel.is_file() and os.access(rel, os.X_OK):
            return rel

    which_cli = shutil.which("chiaro-cli") or shutil.which("chiaro")
    if which_cli:
        return Path(which_cli)

    return None


def discover_app_bundle(repo_root: Path, explicit: Optional[str]) -> Optional[Path]:
    if explicit:
        p = Path(explicit).expanduser().resolve()
        if not p.is_dir():
            raise ConfigError(f"Explicit --app-bundle directory does not exist: {p}")
        return p

    env_val = os.environ.get("CHIARO_APP_BUNDLE")
    if env_val:
        p = Path(env_val).expanduser().resolve()
        if p.is_dir():
            return p

    for cand in [
        repo_root / "Chiaro.app",
        repo_root / "build" / "Chiaro.app",
        Path("/Applications/Chiaro.app"),
    ]:
        if cand.is_dir():
            return cand

    return None


def validate_required_host_tools(tools: HostTools, self_test_only: bool = False) -> None:
    required = {
        "swiftc": tools.swiftc,
        "exiftool": tools.exiftool,
        "avifdec": tools.avifdec,
        "avifgainmaputil": tools.avifgainmaputil,
        "ffprobe": tools.ffprobe,
        "heif-info": tools.heif_info,
        "ultrahdr_app": tools.ultrahdr_app,
    }
    if not self_test_only:
        required.update({
            "otool": tools.otool,
            "nm": tools.nm,
            "codesign": tools.codesign,
            "plutil": tools.plutil,
        })
    missing = [name for name, val in required.items() if not val]
    if missing:
        raise ConfigError(f"Missing required host tool(s): {', '.join(missing)}")


def build_config(
    *,
    cli_bin: Optional[str] = None,
    app_bundle: Optional[str] = None,
    sample_dir: Optional[str] = None,
    work_dir: Optional[str] = None,
    output_verify_dir: Optional[str] = None,
    verbose: bool = False,
    fail_fast: bool = False,
    require_cli: bool = True,
    require_samples: bool = True,
    self_test_only: bool = False,
) -> E2EConfig:
    tools = discover_host_tools(REPO_ROOT)
    validate_required_host_tools(tools, self_test_only=self_test_only)

    resolved_cli = discover_cli_bin(REPO_ROOT, cli_bin)
    resolved_app = discover_app_bundle(REPO_ROOT, app_bundle)

    if require_cli and resolved_cli is None:
        raise ConfigError(
            "chiaro binary not found. Build with `swift build` or pass --cli-bin <path>."
        )

    s_dir = Path(sample_dir).expanduser().resolve() if sample_dir else DEFAULT_SAMPLE_DIR
    if require_samples and not s_dir.is_dir():
        raise ConfigError(f"Sample directory does not exist: {s_dir}")

    if work_dir:
        w_dir = Path(work_dir).expanduser().resolve()
    else:
        tmp_base = Path(os.environ.get("TMPDIR", "/tmp"))
        w_dir = tmp_base / f"chiaro_e2e_{os.getpid()}"
    w_dir.mkdir(parents=True, exist_ok=True)

    ov_dir = Path(output_verify_dir).expanduser().resolve() if output_verify_dir else None
    if ov_dir is not None:
        ov_dir.mkdir(parents=True, exist_ok=True)

    return E2EConfig(
        repo_root=REPO_ROOT,
        e2e_root=E2E_ROOT,
        sample_dir=s_dir,
        work_dir=w_dir,
        output_verify_dir=ov_dir,
        cli_bin=resolved_cli,
        app_bundle=resolved_app,
        tools=tools,
        verbose=verbose,
        fail_fast=fail_fast,
    )

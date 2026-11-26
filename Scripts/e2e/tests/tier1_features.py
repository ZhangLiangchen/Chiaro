"""Tier 1 Feature Coverage E2E Tests (70 distinct tests across F01-F12)."""

from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import time
from pathlib import Path
from typing import Any, Dict, List

from config import BUILTIN_PRESET_IDS, FORBIDDEN_LICENSE_PATTERNS, TANGMO_CATALOG
from probes.cli_probes import (
    check_app_bundle,
    probe_avifdec,
    probe_avifgainmaputil,
    probe_exiftool,
    probe_ffprobe,
    probe_ultrahdr,
)
from probes.isobmff_box import inspect_isobmff
from tests.common import (
    RunContext,
    TestCase,
    assert_avif_compliant,
    assert_exif_clean_and_whitelisted,
    assert_gpl3_compatible,
    assert_headroom_within_tol,
    assert_heic_compliant,
    assert_hlg_mp4_compliant,
    assert_jpeg_compliant,
    parse_ndjson_lines,
)


CANONICAL_PRESET_KEYS = {
    "id",
    "name",
    "description",
    "outputFormats",
    "bitDepth",
    "baseColorSpace",
    "gainMapChannels",
    "gainMapResolution",
    "gainMapGamma",
    "targetHeadroomStops",
    "midtoneAnchorP",
    "sdrToneMapper",
    "developDefaults",
    "cropAspect",
    "quality",
    "avifCodec",
    "compatOptions",
    "hlgVideoOptions",
    "platformAdvisory",
}


def _require_app(ctx: RunContext) -> Path:
    assert ctx.cfg.app_bundle is not None and ctx.cfg.app_bundle.is_dir(), (
        "Chiaro.app bundle not found (build with Scripts/build_app.sh or pass --app-bundle)"
    )
    return ctx.cfg.app_bundle


def _find_outputs(out_dir: Path, ext: str) -> List[Path]:
    return sorted(out_dir.rglob(f"*{ext}"))


def get_tests() -> List[TestCase]:
    tests: List[TestCase] = []

    # =========================================================================
    # F01: GPL-3.0-or-later License Compatibility & SBOM Audit (6 tests)
    # =========================================================================
    def t1_f01_01(ctx: RunContext) -> None:
        script = ctx.cfg.repo_root / "Scripts" / "verify_licenses.sh"
        assert script.is_file(), f"Missing {script}"
        res = ctx.run_cmd(["bash", str(script)], cwd=ctx.cfg.repo_root)
        assert res.returncode == 0, f"verify_licenses.sh failed ({res.returncode}): {res.stderr}\n{res.stdout}"
        assert "SBOM" in res.stdout and "GPL-3.0-or-later" in res.stdout, (
            f"verify_licenses.sh missing SBOM / GPL-3.0-or-later output:\n{res.stdout}"
        )
        ctx.note("verify_licenses.sh exited 0 with GPL-3.0-or-later SBOM summary")

    def t1_f01_02(ctx: RunContext) -> None:
        assert ctx.cfg.cli_bin is not None
        assert_gpl3_compatible(ctx, ctx.cfg.cli_bin, check_symbols=True)

    def t1_f01_03(ctx: RunContext) -> None:
        app = _require_app(ctx)
        info = check_app_bundle(ctx.cfg.tools, app)
        assert info["ok"], f"App bundle check errors: {info['errors']}"
        assert_gpl3_compatible(ctx, Path(info["executable"]), check_symbols=True)

    def t1_f01_04(ctx: RunContext) -> None:
        assert ctx.cfg.cli_bin is not None
        nm = ctx.cfg.tools.nm or "/usr/bin/nm"
        res = ctx.run_cmd([nm, "-gU", str(ctx.cfg.cli_bin)])
        assert res.returncode == 0, f"nm failed: {res.stderr}"
        hits = [
            ln for ln in res.stdout.splitlines()
            if any(tok in ln.lower() for tok in ("heif_", "x265_", "exiv2", "x264_", "de265"))
        ]
        assert not hits, f"Forbidden exported/imported library symbols found: {hits[:10]}"
        ctx.note("nm -gU verified zero heif_/x265_/exiv2/x264_/de265 symbols")

    def t1_f01_05(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F01-05")
        arw = ctx.sample_path("DSC02532.ARW")
        res = ctx.run_cli(
            [str(arw), "--preset", "apple_heic", "--output", str(out)],
            use_sandbox_deny_net=True,
        )
        assert res.returncode == 0, f"Offline sandboxed run failed: {res.stderr}\n{res.stdout}"
        heic = out / "DSC02532_HDR.heic"
        assert_heic_compliant(ctx, heic, expected_stops=2.5, expect_legacy_gm=False)

    def t1_f01_06(ctx: RunContext) -> None:
        vendor_dir = ctx.cfg.repo_root / "Vendor"
        assert vendor_dir.is_dir(), f"Missing Vendor dir: {vendor_dir}"
        machos = list(vendor_dir.rglob("*.dylib"))
        app = _require_app(ctx)
        info = check_app_bundle(ctx.cfg.tools, app)
        targets = [Path(info["executable"])] + machos
        for tgt in targets:
            assert_gpl3_compatible(ctx, tgt, check_symbols=True)
        ctx.note(f"Audited {len(targets)} binary/dylib targets in Vendor + Chiaro.app")

    tests.extend([
        TestCase("T1-F01-01", 1, "F01", "GPL-3.0 & SBOM Audit Script Pass", t1_f01_01, "bash Scripts/verify_licenses.sh"),
        TestCase("T1-F01-02", 1, "F01", "CLI Binary GPL-3.0 Linkage Audit", t1_f01_02, "otool -L <chiaro>"),
        TestCase("T1-F01-03", 1, "F01", "App Binary GPL-3.0 Linkage Audit", t1_f01_03, "otool -L <Chiaro.app>/Contents/MacOS/Chiaro"),
        TestCase("T1-F01-04", 1, "F01", "libultrahdr No-HEIF Linkage Check", t1_f01_04, "nm -gU <chiaro>"),
        TestCase("T1-F01-05", 1, "F01", "100% Offline Execution (sandbox-exec)", t1_f01_05, "sandbox-exec (deny network*) chiaro DSC02532.ARW --preset apple_heic"),
        TestCase("T1-F01-06", 1, "F01", "Vendor & App Bundle Symbol/Dylib License Scan", t1_f01_06, "otool -L + nm -gU across Vendor/**/*.dylib & Chiaro.app"),
    ])

    # =========================================================================
    # F02: SwiftPM Skeleton, Models & 7 Built-in JSON Presets (7 tests)
    # =========================================================================
    def t1_f02_01(ctx: RunContext) -> None:
        res = ctx.run_cli(["--list-presets"])
        assert res.returncode == 0, f"--list-presets failed: {res.stderr}"
        for pid in BUILTIN_PRESET_IDS:
            assert pid in res.stdout, f"Missing preset ID {pid!r} in --list-presets output"
        ctx.note(f"All 7 preset IDs listed: {BUILTIN_PRESET_IDS}")

    def t1_f02_02(ctx: RunContext) -> None:
        presets_dir = ctx.cfg.repo_root / "Presets"
        assert presets_dir.is_dir(), f"Missing Presets dir: {presets_dir}"
        for pid in BUILTIN_PRESET_IDS:
            jf = presets_dir / f"{pid}.json"
            assert jf.is_file(), f"Missing built-in preset file: {jf}"
            obj = json.loads(jf.read_text(encoding="utf-8"))
            missing = CANONICAL_PRESET_KEYS - set(obj.keys())
            assert not missing, f"{jf.name} missing canonical keys: {missing}"
            assert obj["id"] == pid, f"{jf.name} id={obj['id']!r} != {pid!r}"
            assert isinstance(obj["outputFormats"], list) and len(obj["outputFormats"]) >= 1
            assert isinstance(obj["developDefaults"], dict)
            assert isinstance(obj["compatOptions"], dict)
            if "hlgMP4" in obj["outputFormats"]:
                assert isinstance(obj["hlgVideoOptions"], dict), (
                    f"{jf.name} includes hlgMP4 so hlgVideoOptions must be a dict, got {obj['hlgVideoOptions']!r}"
                )
            else:
                assert obj["hlgVideoOptions"] is None or isinstance(obj["hlgVideoOptions"], dict), (
                    f"{jf.name} unexpected hlgVideoOptions={obj['hlgVideoOptions']!r}"
                )
        ctx.note("All 7 Presets/*.json conform to canonical PresetSchema")

    def t1_f02_03(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F02-03")
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "apple_heic", "--output", str(out)])
        assert res.returncode == 0, f"apple_heic failed: {res.stderr}"
        assert_heic_compliant(ctx, out / "DSC02532_HDR.heic", expected_stops=2.5, expect_legacy_gm=False)

    def t1_f02_04(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F02-04")
        res = ctx.run_cli([str(ctx.sample_path("DSC02555.ARW")), "--preset", "tri_format", "--output", str(out)])
        assert res.returncode == 0, f"tri_format failed: {res.stderr}"
        assert_heic_compliant(ctx, out / "DSC02555_HDR.heic", expected_stops=2.5, expect_legacy_gm=False)
        assert_jpeg_compliant(ctx, out / "DSC02555_HDR.jpg", expected_stops=2.5, expect_xmp_hdrgm=True)
        assert_avif_compliant(ctx, out / "DSC02555_HDR.avif", expected_stops=2.5, expect_grid=True)

    def t1_f02_05(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F02-05")
        pjson = ctx.write_preset_json("custom_2ev", {"targetHeadroomStops": 2.0})
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset-file", str(pjson), "--output", str(out)])
        assert res.returncode == 0, f"custom_2ev failed: {res.stderr}"
        assert_heic_compliant(ctx, out / "DSC02532_HDR.heic", expected_stops=2.0, expect_legacy_gm=False)

    def t1_f02_06(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F02-06")
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "douyin_jpg", "--output", str(out)])
        assert res.returncode == 0, f"douyin_jpg failed: {res.stderr}"
        jpg = out / "DSC02532_HDR.jpg"
        # douyin_jpg targets 2.0..2.5 EV (preset JSON targetHeadroomStops)
        pj = json.loads((ctx.cfg.repo_root / "Presets" / "douyin_jpg.json").read_text(encoding="utf-8"))
        assert_jpeg_compliant(
            ctx,
            jpg,
            expected_stops=float(pj["targetHeadroomStops"]),
            expect_xmp_hdrgm=True,
            expect_icc_substr="sRGB" if pj.get("baseColorSpace") == "srgb" else "Display P3",
            max_bytes=3_145_728,
        )

    def t1_f02_07(ctx: RunContext) -> None:
        # Exercise remaining built-in presets by ID on real ARWs
        out_compat = ctx.test_out_dir("T1-F02-07", "compat")
        r1 = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "apple_heic_compat", "--output", str(out_compat)])
        assert r1.returncode == 0, f"apple_heic_compat failed: {r1.stderr}"
        assert_heic_compliant(ctx, out_compat / "DSC02532_HDR.heic", expected_stops=2.5, expect_legacy_gm=True)

        out_xhs = ctx.test_out_dir("T1-F02-07", "xhs")
        r2 = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "xiaohongshu_jpg", "--output", str(out_xhs)])
        assert r2.returncode == 0, f"xiaohongshu_jpg failed: {r2.stderr}"
        assert_jpeg_compliant(ctx, out_xhs / "DSC02532_HDR.jpg", expected_stops=2.5, max_bytes=4_194_304)

        out_avif = ctx.test_out_dir("T1-F02-07", "avif")
        r3 = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "avif_archive", "--output", str(out_avif)])
        assert r3.returncode == 0, f"avif_archive failed: {r3.stderr}"
        assert_avif_compliant(ctx, out_avif / "DSC02532_HDR.avif", expected_stops=2.5, expect_grid=True)

        out_mp4 = ctx.test_out_dir("T1-F02-07", "mp4")
        r4 = ctx.run_cli([str(ctx.sample_path("DSC02540.ARW")), "--preset", "douyin_hlg_mp4", "--output", str(out_mp4)])
        assert r4.returncode == 0, f"douyin_hlg_mp4 failed: {r4.stderr}"
        assert_hlg_mp4_compliant(ctx, out_mp4 / "DSC02540_HDR.mp4")

    tests.extend([
        TestCase("T1-F02-01", 1, "F02", "--list-presets All 7 Built-ins", t1_f02_01, "chiaro --list-presets"),
        TestCase("T1-F02-02", 1, "F02", "Validate All 7 Presets/*.json Schema", t1_f02_02, "JSON schema check on Presets/*.json"),
        TestCase("T1-F02-03", 1, "F02", "Default apple_heic Preset Run", t1_f02_03, "chiaro DSC02532.ARW --preset apple_heic"),
        TestCase("T1-F02-04", 1, "F02", "tri_format Built-in Preset Run", t1_f02_04, "chiaro DSC02555.ARW --preset tri_format"),
        TestCase("T1-F02-05", 1, "F02", "Custom --preset-file Load (2.0 EV)", t1_f02_05, "chiaro DSC02532.ARW --preset-file custom_2ev.json"),
        TestCase("T1-F02-06", 1, "F02", "douyin_jpg Built-in Preset Run", t1_f02_06, "chiaro DSC02532.ARW --preset douyin_jpg"),
        TestCase("T1-F02-07", 1, "F02", "Built-in Preset IDs compat/xhs/avif/hlg_mp4", t1_f02_07, "chiaro across apple_heic_compat, xiaohongshu_jpg, avif_archive, douyin_hlg_mp4"),
    ])

    # =========================================================================
    # F03: Native C-Bridge Integrations (LibRaw, libultrahdr, libavif) (6 tests)
    # =========================================================================
    def t1_f03_01(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F03-01")
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--backend", "libraw", "--preset", "apple_heic", "--output", str(out)])
        assert res.returncode == 0, f"libraw 33MP failed: {res.stderr}"
        assert_heic_compliant(ctx, out / "DSC02532_HDR.heic", expect_w=7008, expect_h=4672)

    def t1_f03_02(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F03-02")
        res = ctx.run_cli([str(ctx.sample_path("DSC02556.ARW")), "--backend", "libraw", "--preset", "apple_heic", "--output", str(out)])
        assert res.returncode == 0, f"libraw 14MP M-size failed: {res.stderr}"
        info = assert_heic_compliant(ctx, out / "DSC02556_HDR.heic", expect_w=3072, expect_h=4608)
        assert info["imageio"]["exif"].get("iso") == 6400, f"Expected ISO 6400, got {info['imageio']['exif'].get('iso')}"

    def t1_f03_03(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F03-03")
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "xiaohongshu_jpg", "--output", str(out)])
        assert res.returncode == 0, f"xiaohongshu_jpg failed: {res.stderr}"
        assert_jpeg_compliant(
            ctx,
            out / "DSC02532_HDR.jpg",
            expected_stops=2.5,
            expect_xmp_hdrgm=True,
            expect_icc_substr="Display P3",
            max_bytes=4_194_304,
            run_ultrahdr=True,
        )

    def t1_f03_04(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F03-04")
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "avif_archive", "--avif-codec", "svt-av1", "--output", str(out)])
        assert res.returncode == 0, f"svt-av1 failed: {res.stderr}"
        assert_avif_compliant(ctx, out / "DSC02532_HDR.avif", expected_stops=2.5, expect_grid=True, expect_w=7008, expect_h=4672)

    def t1_f03_05(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F03-05")
        res = ctx.run_cli([str(ctx.sample_path("DSC02555.ARW")), "--preset", "avif_archive", "--avif-codec", "libaom", "--output", str(out)])
        assert res.returncode == 0, f"libaom failed: {res.stderr}"
        assert_avif_compliant(ctx, out / "DSC02555_HDR.avif", expected_stops=2.5, expect_grid=True, expect_w=7008, expect_h=4672)

    def t1_f03_06(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F03-06")
        pjson = ctx.write_preset_json(
            "t1_f03_06_closedloop",
            {
                "outputFormats": ["jpeg"],
                "bitDepth": 8,
                "baseColorSpace": "displayP3",
                "gainMapChannels": "mono1ch",
                "targetHeadroomStops": 2.5,
            },
            compat_overrides={"writeUltrahdrXMP": True, "closedLoopSDRCompensation": True},
        )
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset-file", str(pjson), "--output", str(out)])
        assert res.returncode == 0, f"closed-loop jpeg failed: {res.stderr}"
        assert_jpeg_compliant(ctx, out / "DSC02532_HDR.jpg", expected_stops=2.5, expect_xmp_hdrgm=True, run_ultrahdr=True)

    tests.extend([
        TestCase("T1-F03-01", 1, "F03", "LibRaw Bridge 33MP FF Decode", t1_f03_01, "chiaro DSC02532.ARW --backend libraw --preset apple_heic"),
        TestCase("T1-F03-02", 1, "F03", "LibRaw Bridge 14MP APS-C M-size Decode", t1_f03_02, "chiaro DSC02556.ARW --backend libraw --preset apple_heic"),
        TestCase("T1-F03-03", 1, "F03", "libultrahdr Bridge 1ch Dual-Metadata JPEG", t1_f03_03, "chiaro DSC02532.ARW --preset xiaohongshu_jpg"),
        TestCase("T1-F03-04", 1, "F03", "libavif + SVT-AV1 Bridge", t1_f03_04, "chiaro DSC02532.ARW --preset avif_archive --avif-codec svt-av1"),
        TestCase("T1-F03-05", 1, "F03", "libavif + libaom Bridge", t1_f03_05, "chiaro DSC02555.ARW --preset avif_archive --avif-codec libaom"),
        TestCase("T1-F03-06", 1, "F03", "libultrahdr Closed-Loop SDR Compensation", t1_f03_06, "chiaro DSC02532.ARW --preset-file closedloop_jpg.json"),
    ])

    # =========================================================================
    # F04: Metal rgba16Float + MTLHeap Pool & Runtime Shader Loader (5 tests)
    # =========================================================================
    def t1_f04_01(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F04-01")
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "apple_heic", "--output", str(out)])
        assert res.returncode == 0, f"Runtime Metal shader load failed: {res.stderr}"
        assert "failed to compile" not in res.stderr.lower() and "mtldevice" not in res.stderr.lower()
        assert_heic_compliant(ctx, out / "DSC02532_HDR.heic")

    def t1_f04_02(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F04-02")
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "tri_format", "--output", str(out)])
        assert res.returncode == 0, f"tri_format fan-out failed: {res.stderr}"
        h = assert_heic_compliant(ctx, out / "DSC02532_HDR.heic", expect_w=7008, expect_h=4672)
        j = assert_jpeg_compliant(ctx, out / "DSC02532_HDR.jpg", expect_w=7008, expect_h=4672)
        a = assert_avif_compliant(ctx, out / "DSC02532_HDR.avif", expect_w=7008, expect_h=4672, expect_grid=True)
        hr_h = h["imageio"]["contentHeadroom"]
        hr_j = j["imageio"]["contentHeadroom"]
        hr_a = a["imageio"]["contentHeadroom"]
        assert abs(hr_h - hr_j) / hr_h < 0.02 and abs(hr_h - hr_a) / hr_h < 0.02, (
            f"Headroom mismatch across fan-out: HEIC={hr_h}, JPG={hr_j}, AVIF={hr_a}"
        )

    def t1_f04_03(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F04-03")
        res = ctx.run_cli([
            str(ctx.sample_path("DSC02532.ARW")),
            str(ctx.sample_path("DSC02556.ARW")),
            "--preset", "apple_heic",
            "--output", str(out),
        ])
        assert res.returncode == 0, f"Multi-bucket heap batch failed: {res.stderr}"
        assert_heic_compliant(ctx, out / "DSC02532_HDR.heic", expect_w=7008, expect_h=4672)
        assert_heic_compliant(ctx, out / "DSC02556_HDR.heic", expect_w=3072, expect_h=4608)

    def t1_f04_04(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F04-04")
        res = ctx.run_cli([str(ctx.sample_path("DSC02540.ARW")), "--preset", "douyin_hlg_mp4", "--output", str(out)])
        assert res.returncode == 0, f"HLG OETF shader failed: {res.stderr}"
        assert_hlg_mp4_compliant(ctx, out / "DSC02540_HDR.mp4")

    def t1_f04_05(ctx: RunContext) -> None:
        app = _require_app(ctx)
        info = check_app_bundle(ctx.cfg.tools, app)
        assert info["shaders_metal_files"], f"No Shaders.metal found inside {app}/Contents/Resources"
        ctx.note(f"Found Shaders.metal: {info['shaders_metal_files']}")

    tests.extend([
        TestCase("T1-F04-01", 1, "F04", "Runtime Shaders.metal Load", t1_f04_01, "chiaro DSC02532.ARW --preset apple_heic"),
        TestCase("T1-F04-02", 1, "F04", "Single GPU Render -> 3-Format Fan-Out", t1_f04_02, "chiaro DSC02532.ARW --preset tri_format"),
        TestCase("T1-F04-03", 1, "F04", "Multi-Bucket MTLHeap (33MP + 14MP)", t1_f04_03, "chiaro DSC02532.ARW DSC02556.ARW --preset apple_heic"),
        TestCase("T1-F04-04", 1, "F04", "GPU HLG OETF Shader Execution", t1_f04_04, "chiaro DSC02540.ARW --preset douyin_hlg_mp4"),
        TestCase("T1-F04-05", 1, "F04", "App Bundle Shaders.metal Resource", t1_f04_05, "Find Shaders.metal inside Chiaro.app/Contents/Resources"),
    ])

    # =========================================================================
    # F05: Unclipped Highlight Reconstruction & Linear Rec.2020 Pipeline (6 tests)
    # =========================================================================
    def t1_f05_01(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F05-01")
        pj = ctx.write_preset_json("hl_opposed", develop_overrides={"highlightReconstruction": "opposedInpaint"})
        res = ctx.run_cli([str(ctx.sample_path("DSC02533.ARW")), "--preset-file", str(pj), "--output", str(out)])
        assert res.returncode == 0, f"opposedInpaint failed: {res.stderr}"
        assert_heic_compliant(ctx, out / "DSC02533_HDR.heic", expected_stops=2.5)

    def t1_f05_02(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F05-02")
        pj = ctx.write_preset_json("hl_blend", develop_overrides={"highlightReconstruction": "blend"})
        res = ctx.run_cli([str(ctx.sample_path("DSC02533.ARW")), "--preset-file", str(pj), "--output", str(out)])
        assert res.returncode == 0, f"blend failed: {res.stderr}"
        assert_heic_compliant(ctx, out / "DSC02533_HDR.heic", expected_stops=2.5)

    def t1_f05_03(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F05-03")
        pj = ctx.write_preset_json("hl_rebuild", develop_overrides={"highlightReconstruction": "rebuild"})
        res = ctx.run_cli([str(ctx.sample_path("DSC02533.ARW")), "--preset-file", str(pj), "--output", str(out)])
        assert res.returncode == 0, f"rebuild failed: {res.stderr}"
        assert_heic_compliant(ctx, out / "DSC02533_HDR.heic", expected_stops=2.5)

    def t1_f05_04(ctx: RunContext) -> None:
        out_base = ctx.test_out_dir("T1-F05-04", "base")
        out_grad = ctx.test_out_dir("T1-F05-04", "graded")
        pj_base = ctx.write_preset_json("grading_base")
        pj_grad = ctx.write_preset_json(
            "grading_boost",
            develop_overrides={"exposureEV": 0.5, "shadowRecovery": 40.0, "blackPoint": 0.02, "vibrance": 25.0},
        )
        r1 = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset-file", str(pj_base), "--output", str(out_base)])
        r2 = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset-file", str(pj_grad), "--output", str(out_grad)])
        assert r1.returncode == 0 and r2.returncode == 0
        i1 = assert_heic_compliant(ctx, out_base / "DSC02532_HDR.heic", expected_stops=2.5)
        i2 = assert_heic_compliant(ctx, out_grad / "DSC02532_HDR.heic", expected_stops=2.5)
        luma1 = i1["imageio"]["pixelStats"]["meanLuma"]
        luma2 = i2["imageio"]["pixelStats"]["meanLuma"]
        assert luma2 > luma1, f"Expected +0.5 EV + shadowRecovery to increase meanLuma ({luma2} <= {luma1})"

    def t1_f05_05(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F05-05")
        res = ctx.run_cli([str(ctx.sample_path("DSC02555.ARW")), "--preset", "apple_heic", "--output", str(out)])
        assert res.returncode == 0, f"DSC02555 failed: {res.stderr}"
        assert_heic_compliant(ctx, out / "DSC02555_HDR.heic", expected_stops=2.5)

    def t1_f05_06(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F05-06")
        pj = ctx.write_preset_json(
            "scene_grading_dual",
            {"outputFormats": ["heic", "jpeg"], "gainMapChannels": "mono1ch"},
            develop_overrides={"exposureEV": -0.5, "shadowRecovery": 30.0},
            compat_overrides={"writeUltrahdrXMP": True},
        )
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset-file", str(pj), "--output", str(out)])
        assert res.returncode == 0, f"scene_grading_dual failed: {res.stderr}"
        assert_heic_compliant(ctx, out / "DSC02532_HDR.heic", expected_stops=2.5)
        assert_jpeg_compliant(ctx, out / "DSC02532_HDR.jpg", expected_stops=2.5, expect_xmp_hdrgm=True)

    tests.extend([
        TestCase("T1-F05-01", 1, "F05", "Highlight Recon opposedInpaint", t1_f05_01, "chiaro DSC02533.ARW --preset-file hl_opposed.json"),
        TestCase("T1-F05-02", 1, "F05", "Highlight Recon blend", t1_f05_02, "chiaro DSC02533.ARW --preset-file hl_blend.json"),
        TestCase("T1-F05-03", 1, "F05", "Highlight Recon rebuild", t1_f05_03, "chiaro DSC02533.ARW --preset-file hl_rebuild.json"),
        TestCase("T1-F05-04", 1, "F05", "Shared Scene Grading Params", t1_f05_04, "chiaro DSC02532.ARW --preset-file grading_boost.json vs baseline"),
        TestCase("T1-F05-05", 1, "F05", "Low-ISO Long-Exp Linear Headroom", t1_f05_05, "chiaro DSC02555.ARW --preset apple_heic"),
        TestCase("T1-F05-06", 1, "F05", "Scene Grading Parity Across HEIC+JPEG", t1_f05_06, "chiaro DSC02532.ARW --preset-file scene_grading_dual.json"),
    ])

    # =========================================================================
    # F06: Midtone-Locked Dual-Branch Tone Mapping & OKLab Gamut Mapping (6 tests)
    # =========================================================================
    def t1_f06_01(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F06-01")
        pj = ctx.write_preset_json("tm_agx", {"sdrToneMapper": "agx"})
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset-file", str(pj), "--output", str(out)])
        assert res.returncode == 0
        assert_heic_compliant(ctx, out / "DSC02532_HDR.heic", expected_stops=2.5)

    def t1_f06_02(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F06-02")
        pj = ctx.write_preset_json("tm_neutral", {"sdrToneMapper": "neutralRational"})
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset-file", str(pj), "--output", str(out)])
        assert res.returncode == 0
        assert_heic_compliant(ctx, out / "DSC02532_HDR.heic", expected_stops=2.5)

    def t1_f06_03(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F06-03")
        pj = ctx.write_preset_json("tm_opendrt", {"sdrToneMapper": "openDRT"})
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset-file", str(pj), "--output", str(out)])
        assert res.returncode == 0
        assert_heic_compliant(ctx, out / "DSC02532_HDR.heic", expected_stops=2.5)

    def t1_f06_04(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F06-04")
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "xiaohongshu_jpg", "--output", str(out)])
        assert res.returncode == 0
        assert_jpeg_compliant(ctx, out / "DSC02532_HDR.jpg", expected_stops=2.5, expect_icc_substr="Display P3")

    def t1_f06_05(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F06-05")
        pj = ctx.write_preset_json(
            "jpg_srgb",
            {"outputFormats": ["jpeg"], "bitDepth": 8, "baseColorSpace": "srgb", "gainMapChannels": "mono1ch"},
            compat_overrides={"writeUltrahdrXMP": True},
        )
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset-file", str(pj), "--output", str(out)])
        assert res.returncode == 0
        assert_jpeg_compliant(ctx, out / "DSC02532_HDR.jpg", expected_stops=2.5, expect_icc_substr="sRGB", expect_xmp_hdrgm=True)

    def t1_f06_06(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F06-06")
        pj = ctx.write_preset_json(
            "hdr_midtone_080",
            {"midtoneAnchorP": 0.80},
            develop_overrides={"hdrHighlightExcitation": 75.0, "hdrRolloffSoftness": 60.0},
        )
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset-file", str(pj), "--output", str(out)])
        assert res.returncode == 0
        assert_heic_compliant(ctx, out / "DSC02532_HDR.heic", expected_stops=2.5)

    tests.extend([
        TestCase("T1-F06-01", 1, "F06", "SDR Tone Mapper agx", t1_f06_01, "chiaro DSC02532.ARW --preset-file tm_agx.json"),
        TestCase("T1-F06-02", 1, "F06", "SDR Tone Mapper neutralRational", t1_f06_02, "chiaro DSC02532.ARW --preset-file tm_neutral.json"),
        TestCase("T1-F06-03", 1, "F06", "SDR Tone Mapper openDRT", t1_f06_03, "chiaro DSC02532.ARW --preset-file tm_opendrt.json"),
        TestCase("T1-F06-04", 1, "F06", "baseColorSpace displayP3", t1_f06_04, "chiaro DSC02532.ARW --preset xiaohongshu_jpg"),
        TestCase("T1-F06-05", 1, "F06", "baseColorSpace srgb", t1_f06_05, "chiaro DSC02532.ARW --preset-file jpg_srgb.json"),
        TestCase("T1-F06-06", 1, "F06", "Midtone Anchor 0.80 & HDR Excitation", t1_f06_06, "chiaro DSC02532.ARW --preset-file hdr_midtone_080.json"),
    ])

    # =========================================================================
    # F07: Physical Orientation Baking, Crop/Resize & ISO 21496-1 Gain Map (6 tests)
    # =========================================================================
    def t1_f07_01(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F07-01")
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "apple_heic", "--output", str(out)])
        assert res.returncode == 0
        assert_heic_compliant(ctx, out / "DSC02532_HDR.heic", expect_w=7008, expect_h=4672)

    def t1_f07_02(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F07-02")
        res = ctx.run_cli([str(ctx.sample_path("DSC02540.ARW")), "--preset", "apple_heic", "--output", str(out)])
        assert res.returncode == 0
        assert_heic_compliant(ctx, out / "DSC02540_HDR.heic", expect_w=4672, expect_h=7008)

    def t1_f07_03(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F07-03")
        res = ctx.run_cli([str(ctx.sample_path("DSC02556.ARW")), "--preset", "apple_heic", "--output", str(out)])
        assert res.returncode == 0
        assert_heic_compliant(ctx, out / "DSC02556_HDR.heic", expect_w=3072, expect_h=4608)

    def t1_f07_04(ctx: RunContext) -> None:
        out3 = ctx.test_out_dir("T1-F07-04", "3ch")
        out1 = ctx.test_out_dir("T1-F07-04", "1ch")
        r3 = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "apple_heic", "--output", str(out3)])
        r1 = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "apple_heic_compat", "--output", str(out1)])
        assert r3.returncode == 0 and r1.returncode == 0
        assert_heic_compliant(ctx, out3 / "DSC02532_HDR.heic", expect_legacy_gm=False)
        assert_heic_compliant(ctx, out1 / "DSC02532_HDR.heic", expect_legacy_gm=True)

    def t1_f07_05(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F07-05")
        pj = ctx.write_preset_json(
            "gm_full_g12",
            {"outputFormats": ["avif"], "gainMapResolution": "full", "gainMapGamma": 1.2},
        )
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset-file", str(pj), "--output", str(out)])
        assert res.returncode == 0
        assert_avif_compliant(
            ctx,
            out / "DSC02532_HDR.avif",
            expected_stops=2.5,
            expect_grid=True,
            expect_gm_full_res=True,
            expected_gamma=1.2,
            expect_w=7008,
            expect_h=4672,
        )

    def t1_f07_06(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F07-06")
        pj = ctx.write_preset_json(
            "crop_34_2048",
            {"outputFormats": ["heic"], "cropAspect": "3:4", "maxLongEdge": 2048},
        )
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset-file", str(pj), "--output", str(out)])
        assert res.returncode == 0
        assert_heic_compliant(ctx, out / "DSC02532_HDR.heic", expect_w=1536, expect_h=2048)

    tests.extend([
        TestCase("T1-F07-01", 1, "F07", "Horizontal Orientation=1 Bake", t1_f07_01, "chiaro DSC02532.ARW --preset apple_heic"),
        TestCase("T1-F07-02", 1, "F07", "Portrait Rotate 270 CW 33MP Bake", t1_f07_02, "chiaro DSC02540.ARW --preset apple_heic"),
        TestCase("T1-F07-03", 1, "F07", "Portrait Rotate 270 CW 14MP Bake", t1_f07_03, "chiaro DSC02556.ARW --preset apple_heic"),
        TestCase("T1-F07-04", 1, "F07", "3ch RGB vs 1ch Mono Gain Map", t1_f07_04, "chiaro DSC02532.ARW apple_heic & apple_heic_compat"),
        TestCase("T1-F07-05", 1, "F07", "gainMapResolution=full & gamma=1.2", t1_f07_05, "chiaro DSC02532.ARW --preset-file gm_full_g12.json"),
        TestCase("T1-F07-06", 1, "F07", "cropAspect 3:4 & maxLongEdge 2048 Bake", t1_f07_06, "chiaro DSC02532.ARW --preset-file crop_34_2048.json"),
    ])

    # =========================================================================
    # F08: Sony ARW Import, Dual RAW Decoders & EXIF Whitelist (6 tests)
    # =========================================================================
    def t1_f08_01(ctx: RunContext) -> None:
        in_dir = ctx.test_out_dir("T1-F08-01", "in")
        out = ctx.test_out_dir("T1-F08-01", "out")
        (in_dir / "sub1" / "sub2").mkdir(parents=True, exist_ok=True)
        shutil.copy2(ctx.sample_path("DSC02532.ARW"), in_dir / "DSC02532.ARW")
        hif_src = ctx.cfg.sample_dir / "DSC02532.HIF"
        if hif_src.is_file():
            shutil.copy2(hif_src, in_dir / "DSC02532.HIF")
        shutil.copy2(ctx.sample_path("DSC02540.ARW"), in_dir / "sub1" / "DSC02540.ARW")
        (in_dir / "sub1" / "readme.txt").write_text("ignore me", encoding="utf-8")
        shutil.copy2(ctx.sample_path("DSC02556.ARW"), in_dir / "sub1" / "sub2" / "DSC02556.ARW")

        res = ctx.run_cli([str(in_dir), "--recursive", "--preset", "apple_heic", "--output", str(out)])
        assert res.returncode == 0, f"--recursive failed: {res.stderr}"
        heics = _find_outputs(out, ".heic")
        assert len(heics) == 3, f"Expected 3 .heic outputs, got {[p.name for p in heics]}"

    def t1_f08_02(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F08-02")
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "apple_heic", "--output", str(out)])
        assert res.returncode == 0
        info = assert_heic_compliant(ctx, out / "DSC02532_HDR.heic")
        raw = info["exiftool"].raw_dict
        iio_ex = info["imageio"]["exif"]
        assert (raw.get("ExifIFD:ISO") == 10000 or iio_ex.get("iso") == 10000), f"ISO mismatch: {raw.get('ExifIFD:ISO')}"
        assert raw.get("ExifIFD:FNumber") in (4, 4.0) or iio_ex.get("fNumber") == 4.0
        assert raw.get("ExifIFD:SubSecTimeOriginal") in ("597", 597) or iio_ex.get("subSecTimeOriginal") == "597"

    def t1_f08_03(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F08-03")
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--backend", "ciraw9", "--preset", "apple_heic", "--output", str(out)])
        assert res.returncode == 0, f"ciraw9 failed: {res.stderr}"
        assert_heic_compliant(ctx, out / "DSC02532_HDR.heic", expected_stops=2.5, expect_w=7008, expect_h=4672)

    def t1_f08_04(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F08-04")
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "tri_format", "--output", str(out)])
        assert res.returncode == 0
        for p in [out / "DSC02532_HDR.heic", out / "DSC02532_HDR.jpg", out / "DSC02532_HDR.avif"]:
            ex = probe_exiftool(ctx.cfg.tools, p)
            bad = ex.has_forbidden_sony_or_makernote()
            assert not bad, f"MakerNote leaked into {p.name}: {bad}"

    def t1_f08_05(ctx: RunContext) -> None:
        out_on = ctx.test_out_dir("T1-F08-05", "on")
        out_off = ctx.test_out_dir("T1-F08-05", "off")
        r_on = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "apple_heic", "--custom-rendered-hdr", "--output", str(out_on)])
        r_off = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "apple_heic", "--output", str(out_off)])
        assert r_on.returncode == 0 and r_off.returncode == 0
        assert_heic_compliant(ctx, out_on / "DSC02532_HDR.heic", expect_custom_rendered=3)
        assert_heic_compliant(ctx, out_off / "DSC02532_HDR.heic", expect_custom_rendered=0)

    def t1_f08_06(ctx: RunContext) -> None:
        in_dir = ctx.test_out_dir("T1-F08-06", "in")
        out = ctx.test_out_dir("T1-F08-06", "out")
        shutil.copy2(ctx.sample_path("DSC02532.ARW"), in_dir / "DSC02532.ARW")
        hif_src = ctx.cfg.sample_dir / "DSC02532.HIF"
        if hif_src.is_file():
            shutil.copy2(hif_src, in_dir / "DSC02532.HIF")
        res = ctx.run_cli([str(in_dir), "--preset", "apple_heic", "--output", str(out)])
        assert res.returncode == 0, f"Directory scan failed: {res.stderr}"
        heics = _find_outputs(out, ".heic")
        assert len(heics) == 1, f"Expected 1 .heic output (HIF ignored), got {[p.name for p in heics]}"

    tests.extend([
        TestCase("T1-F08-01", 1, "F08", "--recursive & .HIF Filtering", t1_f08_01, "chiaro nested_dir --recursive --preset apple_heic"),
        TestCase("T1-F08-02", 1, "F08", "Exif 2.32 Whitelist Preservation", t1_f08_02, "chiaro DSC02532.ARW --preset apple_heic + exiftool audit"),
        TestCase("T1-F08-03", 1, "F08", "--backend ciraw9 Native Decode", t1_f08_03, "chiaro DSC02532.ARW --backend ciraw9 --preset apple_heic"),
        TestCase("T1-F08-04", 1, "F08", "Sony MakerNote Stripped (All 3 Formats)", t1_f08_04, "chiaro DSC02532.ARW --preset tri_format + MakerNote check"),
        TestCase("T1-F08-05", 1, "F08", "--custom-rendered-hdr Flag", t1_f08_05, "chiaro DSC02532.ARW --custom-rendered-hdr"),
        TestCase("T1-F08-06", 1, "F08", "Non-Recursive Dir Scan Ignores .HIF", t1_f08_06, "chiaro dir_with_arw_and_hif --preset apple_heic"),
    ])

    # =========================================================================
    # F09: 4 Encoders & Guardrails (6 tests)
    # =========================================================================
    def t1_f09_01(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F09-01")
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "apple_heic", "--output", str(out)])
        assert res.returncode == 0
        assert_heic_compliant(ctx, out / "DSC02532_HDR.heic", expected_stops=2.5, expected_depth=10, expect_legacy_gm=False)

    def t1_f09_02(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F09-02")
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "apple_heic_compat", "--output", str(out)])
        assert res.returncode == 0
        info = assert_heic_compliant(ctx, out / "DSC02532_HDR.heic", expected_stops=2.5, expected_depth=10, expect_legacy_gm=True)
        raw = info["exiftool"].raw_dict
        assert any("HDRGainMap" in k for k in raw.keys()), "apple_heic_compat missing XMP HDRGainMap tags"

    def t1_f09_03(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F09-03")
        res = ctx.run_cli([str(ctx.sample_path("DSC02540.ARW")), "--preset", "xiaohongshu_jpg", "--output", str(out)])
        assert res.returncode == 0
        assert_jpeg_compliant(
            ctx,
            out / "DSC02540_HDR.jpg",
            expected_stops=2.5,
            expect_xmp_hdrgm=True,
            expect_icc_substr="Display P3",
            max_bytes=4_194_304,
            expect_w=1536,
            expect_h=2048,
        )

    def t1_f09_04(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F09-04")
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "avif_archive", "--output", str(out)])
        assert res.returncode == 0
        assert_avif_compliant(ctx, out / "DSC02532_HDR.avif", expected_stops=2.5, expect_grid=True, decode_16bit=True)

    def t1_f09_05(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F09-05")
        res = ctx.run_cli([str(ctx.sample_path("DSC02540.ARW")), "--preset", "douyin_hlg_mp4", "--output", str(out)])
        assert res.returncode == 0
        assert_hlg_mp4_compliant(ctx, out / "DSC02540_HDR.mp4", allowed_sizes=((1080, 1920), (1080, 1440)))

    def t1_f09_06(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F09-06")
        res = ctx.run_cli([str(ctx.sample_path("DSC02540.ARW")), "--preset", "douyin_jpg", "--output", str(out)])
        assert res.returncode == 0
        pj = json.loads((ctx.cfg.repo_root / "Presets" / "douyin_jpg.json").read_text(encoding="utf-8"))
        assert_jpeg_compliant(
            ctx,
            out / "DSC02540_HDR.jpg",
            expected_stops=float(pj["targetHeadroomStops"]),
            expect_xmp_hdrgm=True,
            expect_icc_substr="sRGB" if pj.get("baseColorSpace") == "srgb" else "Display P3",
            max_bytes=3_145_728,
        )

    tests.extend([
        TestCase("T1-F09-01", 1, "F09", "HEIC Pure ISO (apple_heic)", t1_f09_01, "chiaro DSC02532.ARW --preset apple_heic"),
        TestCase("T1-F09-02", 1, "F09", "HEIC 1ch Dual-Write (apple_heic_compat)", t1_f09_02, "chiaro DSC02532.ARW --preset apple_heic_compat"),
        TestCase("T1-F09-03", 1, "F09", "Xiaohongshu JPEG (xiaohongshu_jpg)", t1_f09_03, "chiaro DSC02540.ARW --preset xiaohongshu_jpg"),
        TestCase("T1-F09-04", 1, "F09", "AVIF Grid Archive (avif_archive)", t1_f09_04, "chiaro DSC02532.ARW --preset avif_archive"),
        TestCase("T1-F09-05", 1, "F09", "Douyin HLG MP4 (douyin_hlg_mp4)", t1_f09_05, "chiaro DSC02540.ARW --preset douyin_hlg_mp4"),
        TestCase("T1-F09-06", 1, "F09", "Douyin JPEG (douyin_jpg)", t1_f09_06, "chiaro DSC02540.ARW --preset douyin_jpg"),
    ])

    # =========================================================================
    # F10: Post-Export Automated Compliance Probes (5 tests)
    # =========================================================================
    def t1_f10_01(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F10-01")
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "apple_heic", "--verify", "--json-progress", "--output", str(out)])
        assert res.returncode == 0
        lines = parse_ndjson_lines(res.stdout + "\n" + res.stderr)
        assert lines, "Expected JSON progress lines with --verify --json-progress"
        assert_heic_compliant(ctx, out / "DSC02532_HDR.heic")

    def t1_f10_02(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F10-02")
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "xiaohongshu_jpg", "--verify", "--json-progress", "--output", str(out)])
        assert res.returncode == 0
        lines = parse_ndjson_lines(res.stdout + "\n" + res.stderr)
        assert lines, "Expected JSON progress lines"
        assert_jpeg_compliant(ctx, out / "DSC02532_HDR.jpg", max_bytes=4_194_304)

    def t1_f10_03(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F10-03")
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "avif_archive", "--verify", "--json-progress", "--output", str(out)])
        assert res.returncode == 0
        lines = parse_ndjson_lines(res.stdout + "\n" + res.stderr)
        assert lines, "Expected JSON progress lines"
        assert_avif_compliant(ctx, out / "DSC02532_HDR.avif", expect_grid=True)

    def t1_f10_04(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F10-04")
        res = ctx.run_cli([str(ctx.sample_path("DSC02540.ARW")), "--preset", "douyin_hlg_mp4", "--verify", "--json-progress", "--output", str(out)])
        assert res.returncode == 0
        lines = parse_ndjson_lines(res.stdout + "\n" + res.stderr)
        assert lines, "Expected JSON progress lines"
        assert_hlg_mp4_compliant(ctx, out / "DSC02540_HDR.mp4")

    def t1_f10_05(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F10-05")
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "apple_heic", "--no-verify", "--json-progress", "--output", str(out)])
        assert res.returncode == 0
        assert_heic_compliant(ctx, out / "DSC02532_HDR.heic")

    tests.extend([
        TestCase("T1-F10-01", 1, "F10", "--verify on HEIC", t1_f10_01, "chiaro DSC02532.ARW --preset apple_heic --verify --json-progress"),
        TestCase("T1-F10-02", 1, "F10", "--verify on JPEG", t1_f10_02, "chiaro DSC02532.ARW --preset xiaohongshu_jpg --verify --json-progress"),
        TestCase("T1-F10-03", 1, "F10", "--verify on AVIF", t1_f10_03, "chiaro DSC02532.ARW --preset avif_archive --verify --json-progress"),
        TestCase("T1-F10-04", 1, "F10", "--verify on HLG MP4", t1_f10_04, "chiaro DSC02540.ARW --preset douyin_hlg_mp4 --verify --json-progress"),
        TestCase("T1-F10-05", 1, "F10", "--no-verify Toggle", t1_f10_05, "chiaro DSC02532.ARW --preset apple_heic --no-verify --json-progress"),
    ])

    # =========================================================================
    # F11: Bounded 3-Stage Pipeline, MemoryBudgetScheduler & chiaro (6 tests)
    # =========================================================================
    def t1_f11_01(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F11-01")
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "apple_heic", "--formats", "heic,jpeg", "--output", str(out)])
        assert res.returncode == 0
        assert (out / "DSC02532_HDR.heic").is_file()
        assert (out / "DSC02532_HDR.jpg").is_file()
        assert not (out / "DSC02532_HDR.avif").exists()
        assert not (out / "DSC02532_HDR.mp4").exists()
        assert_heic_compliant(ctx, out / "DSC02532_HDR.heic", expected_stops=2.5, expect_legacy_gm=False)
        assert_jpeg_compliant(ctx, out / "DSC02532_HDR.jpg", expected_stops=2.5, expect_xmp_hdrgm=False)

    def t1_f11_02(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F11-02")
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "tri_format", "--format-subdirs", "--output", str(out)])
        assert res.returncode == 0
        assert (out / "heic" / "DSC02532_HDR.heic").is_file()
        assert (out / "jpeg" / "DSC02532_HDR.jpg").is_file()
        assert (out / "avif" / "DSC02532_HDR.avif").is_file()

    def t1_f11_03(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F11-03")
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "apple_heic", "--naming", "{name}_V1.{ext}", "--output", str(out)])
        assert res.returncode == 0
        assert (out / "DSC02532_V1.heic").is_file()
        assert not (out / "DSC02532_HDR.heic").exists()
        assert_heic_compliant(ctx, out / "DSC02532_V1.heic")

    def t1_f11_04(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F11-04")
        delta_file = ctx.fixtures_dir / "t1_f11_04_delta.json"
        delta_obj = {
            "DSC02533": {
                "targetHeadroomStopsOverride": 1.5,
                "cropAspectOverride": "3:4",
                "exposureEVDelta": -0.5,
            }
        }
        delta_file.write_text(json.dumps(delta_obj, indent=2), encoding="utf-8")
        res = ctx.run_cli([
            str(ctx.sample_path("DSC02532.ARW")),
            str(ctx.sample_path("DSC02533.ARW")),
            "--preset", "apple_heic",
            "--delta-file", str(delta_file),
            "--output", str(out),
        ])
        assert res.returncode == 0, f"--delta-file failed: {res.stderr}"
        assert_heic_compliant(ctx, out / "DSC02532_HDR.heic", expected_stops=2.5, expect_w=7008, expect_h=4672)
        i33 = assert_heic_compliant(ctx, out / "DSC02533_HDR.heic", expected_stops=1.5)
        w33, h33 = i33["imageio"]["pixelWidth"], i33["imageio"]["pixelHeight"]
        assert abs(w33 / h33 - 0.75) < 0.01, f"Expected 3:4 crop on DSC02533, got {w33}x{h33}"

    def t1_f11_05(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-F11-05")
        res = ctx.run_cli([
            str(ctx.sample_path("DSC02532.ARW")),
            str(ctx.sample_path("DSC02556.ARW")),
            "--preset", "apple_heic",
            "--json-progress",
            "--output", str(out),
        ])
        assert res.returncode == 0
        lines = parse_ndjson_lines(res.stdout + "\n" + res.stderr)
        assert len(lines) >= 2, f"Expected >=2 NDJSON lines, got {len(lines)}"

    def t1_f11_06(ctx: RunContext) -> None:
        out_skip = ctx.test_out_dir("T1-F11-06", "skip")
        target = out_skip / "DSC02532_HDR.heic"
        target.write_bytes(b"SENTINEL_SKIP")
        rs = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "apple_heic", "--on-conflict", "skip", "--output", str(out_skip)])
        assert rs.returncode == 0
        assert target.read_bytes() == b"SENTINEL_SKIP", "--on-conflict skip overwrote sentinel"

        out_ovr = ctx.test_out_dir("T1-F11-06", "overwrite")
        target_o = out_ovr / "DSC02532_HDR.heic"
        target_o.write_bytes(b"SENTINEL_OVR")
        ro = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "apple_heic", "--on-conflict", "overwrite", "--output", str(out_ovr)])
        assert ro.returncode == 0
        assert_heic_compliant(ctx, target_o)

    tests.extend([
        TestCase("T1-F11-01", 1, "F11", "--formats Override Flag", t1_f11_01, "chiaro DSC02532.ARW --preset apple_heic --formats heic,jpeg"),
        TestCase("T1-F11-02", 1, "F11", "--format-subdirs Flag", t1_f11_02, "chiaro DSC02532.ARW --preset tri_format --format-subdirs"),
        TestCase("T1-F11-03", 1, "F11", "--naming Template Flag", t1_f11_03, "chiaro DSC02532.ARW --naming {name}_V1.{ext}"),
        TestCase("T1-F11-04", 1, "F11", "--delta-file Per-Photo Override", t1_f11_04, "chiaro DSC02532.ARW DSC02533.ARW --delta-file delta.json"),
        TestCase("T1-F11-05", 1, "F11", "--json-progress NDJSON Output", t1_f11_05, "chiaro DSC02532.ARW DSC02556.ARW --json-progress"),
        TestCase("T1-F11-06", 1, "F11", "--on-conflict skip vs overwrite", t1_f11_06, "chiaro DSC02532.ARW --on-conflict skip / overwrite"),
    ])

    # =========================================================================
    # F12: Chiaro.app macOS Native Desktop App & Bundle Script (5 tests)
    # =========================================================================
    def t1_f12_01(ctx: RunContext) -> None:
        app = _require_app(ctx)
        info = check_app_bundle(ctx.cfg.tools, app)
        assert info["ok"], f"Bundle structure invalid: {info['errors']}"
        fproc = ctx.run_cmd(["file", info["executable"]])
        assert "arm64" in fproc.stdout, f"Expected arm64 Mach-O, got: {fproc.stdout}"

    def t1_f12_02(ctx: RunContext) -> None:
        app = _require_app(ctx)
        plist = app / "Contents" / "Info.plist"
        pl = ctx.run_cmd([ctx.cfg.tools.plutil or "/usr/bin/plutil", "-lint", str(plist)])
        assert pl.returncode == 0, f"plutil failed: {pl.stdout} {pl.stderr}"
        pb = ctx.cfg.tools.plistbuddy or "/usr/libexec/PlistBuddy"
        for key in ("CFBundleExecutable", "CFBundleIdentifier", "LSMinimumSystemVersion"):
            r = ctx.run_cmd([pb, "-c", f"Print :{key}", str(plist)])
            assert r.returncode == 0 and r.stdout.strip(), f"Info.plist missing {key}"

    def t1_f12_03(ctx: RunContext) -> None:
        app = _require_app(ctx)
        cs = ctx.run_cmd([ctx.cfg.tools.codesign or "/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
        assert cs.returncode == 0, f"codesign verify failed: {cs.stderr} {cs.stdout}"

    def t1_f12_04(ctx: RunContext) -> None:
        app = _require_app(ctx)
        info = check_app_bundle(ctx.cfg.tools, app)
        assert_gpl3_compatible(ctx, Path(info["executable"]), check_symbols=True)

    def t1_f12_05(ctx: RunContext) -> None:
        app = _require_app(ctx)
        info = check_app_bundle(ctx.cfg.tools, app)
        exe = info["executable"]
        diag_dir = Path.home() / "Library" / "Logs" / "DiagnosticReports"
        before_ips = set(diag_dir.glob("*Chiaro*")) if diag_dir.is_dir() else set()
        proc = subprocess.Popen([exe], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            time.sleep(3.0)
            rc = proc.poll()
            assert rc is None, f"Chiaro exited prematurely with rc={rc}: {proc.stderr.read().decode(errors='replace') if proc.stderr else ''}"
        finally:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
        after_ips = set(diag_dir.glob("*Chiaro*")) if diag_dir.is_dir() else set()
        new_ips = after_ips - before_ips
        assert not new_ips, f"New crash reports generated: {new_ips}"

    tests.extend([
        TestCase("T1-F12-01", 1, "F12", "Chiaro.app Bundle Structure", t1_f12_01, "Verify Contents/{MacOS,Info.plist,Resources} & arm64 Mach-O"),
        TestCase("T1-F12-02", 1, "F12", "Info.plist Validity", t1_f12_02, "plutil -lint + PlistBuddy Info.plist keys"),
        TestCase("T1-F12-03", 1, "F12", "codesign --verify --deep --strict", t1_f12_03, "codesign --verify --deep --strict Chiaro.app"),
        TestCase("T1-F12-04", 1, "F12", "Chiaro.app GPL-3.0 License & Linkage Audit", t1_f12_04, "otool -L + nm -gU Chiaro"),
        TestCase("T1-F12-05", 1, "F12", "Chiaro.app Launch Smoke Check (3s)", t1_f12_05, "Launch Chiaro >=3s, SIGTERM, zero crash logs"),
    ])

    assert len(tests) == 70, f"Expected 70 Tier 1 tests, got {len(tests)}"
    return tests

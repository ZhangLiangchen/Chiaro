"""Tier 2 Boundary & Corner Cases E2E Tests (70 distinct tests across F01-F12)."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
from pathlib import Path
from typing import List

from config import BUILTIN_PRESET_IDS, FORBIDDEN_LICENSE_PATTERNS, PEAK_RSS_LIMIT_BYTES
from probes.cli_probes import check_app_bundle, probe_avifdec, probe_exiftool, probe_ffprobe
from probes.isobmff_box import inspect_isobmff
from tests.common import (
    RunContext,
    TestCase,
    assert_avif_compliant,
    assert_headroom_within_tol,
    assert_heic_compliant,
    assert_hlg_mp4_compliant,
    assert_jpeg_compliant,
    assert_zero_gpl,
    parse_ndjson_lines,
)


def _require_app(ctx: RunContext) -> Path:
    assert ctx.cfg.app_bundle is not None and ctx.cfg.app_bundle.is_dir(), (
        "Chiaro.app bundle not found"
    )
    return ctx.cfg.app_bundle


def get_tests() -> List[TestCase]:
    tests: List[TestCase] = []

    # =========================================================================
    # F01: Zero GPL / Zero LGPL Boundaries (6 tests)
    # =========================================================================
    def t2_f01_01(ctx: RunContext) -> None:
        assert ctx.cfg.cli_bin is not None
        nm = ctx.cfg.tools.nm or "/usr/bin/nm"
        res = ctx.run_cmd([nm, "-gU", str(ctx.cfg.cli_bin)])
        assert res.returncode == 0
        hits = [
            ln for ln in res.stdout.splitlines()
            if any(p in ln.lower() for p in ("dht_demosaic", "aahd_demosaic", "dcb_demosaic", "amaze"))
        ]
        assert not hits, f"Forbidden GPL demosaic symbols found: {hits}"

    def t2_f01_02(ctx: RunContext) -> None:
        assert ctx.cfg.cli_bin is not None
        targets = [ctx.cfg.cli_bin]
        app = _require_app(ctx)
        info = check_app_bundle(ctx.cfg.tools, app)
        targets.append(Path(info["executable"]))
        vendor = ctx.cfg.repo_root / "Vendor"
        if vendor.is_dir():
            targets.extend(sorted(vendor.rglob("*.dylib")))
        for t in targets:
            assert_zero_gpl(ctx, t, check_symbols=True)

    def t2_f01_03(ctx: RunContext) -> None:
        app = _require_app(ctx)
        info = check_app_bundle(ctx.cfg.tools, app)
        assert info["ok"], f"App bundle check errors: {info['errors']}"
        res = assert_zero_gpl(ctx, Path(info["executable"]), check_symbols=True)
        assert not res["dangling_refs"], f"Dangling /tmp refs in Chiaro: {res['dangling_refs']}"
        for line in res["otool_lines"][1:]:
            if "@rpath" in line:
                # Verify @rpath resolves inside Contents/Frameworks or standard Swift runtime
                lib_name = line.strip().split(" (")[0].replace("@rpath/", "")
                fw_dir = app / "Contents" / "Frameworks"
                assert lib_name.startswith("libswift") or (fw_dir / lib_name).exists(), (
                    f"Unresolved @rpath in Chiaro: {line.strip()}"
                )

    def t2_f01_04(ctx: RunContext) -> None:
        assert ctx.cfg.cli_bin is not None
        app = _require_app(ctx)
        info = check_app_bundle(ctx.cfg.tools, app)
        strings_bin = ctx.cfg.tools.strings or "/usr/bin/strings"
        for bin_path in [ctx.cfg.cli_bin, Path(info["executable"])]:
            res = ctx.run_cmd([strings_bin, str(bin_path)])
            assert res.returncode == 0
            bad = [
                pat for pat in ("libx265", "libexiv2", "libheif", "libx264", "libde265")
                if pat in res.stdout.lower()
            ]
            assert not bad, f"Forbidden library reference strings in {bin_path.name}: {bad}"
        script = ctx.cfg.repo_root / "Scripts" / "verify_licenses.sh"
        assert script.is_file()
        sres = ctx.run_cmd(["bash", str(script)], cwd=ctx.cfg.repo_root)
        assert sres.returncode == 0

    def t2_f01_05(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T2-F01-05")
        res = ctx.run_cli(
            [str(ctx.sample_path("DSC02532.ARW")), "--preset", "tri_format", "--output", str(out)],
            env_override={"HTTP_PROXY": "http://127.0.0.1:9", "HTTPS_PROXY": "http://127.0.0.1:9"},
            use_sandbox_deny_net=True,
        )
        assert res.returncode == 0, f"Offline tri_format failed: {res.stderr}"
        assert_heic_compliant(ctx, out / "DSC02532_HDR.heic")
        assert_jpeg_compliant(ctx, out / "DSC02532_HDR.jpg")
        assert_avif_compliant(ctx, out / "DSC02532_HDR.avif", expect_grid=True)

    def t2_f01_06(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T2-F01-06")
        res = ctx.run_cli(
            [
                str(ctx.sample_path("DSC02532.ARW")),
                str(ctx.sample_path("DSC02540.ARW")),
                "--preset", "avif_archive",
                "--output", str(out),
            ],
            use_sandbox_deny_net=True,
        )
        assert res.returncode == 0, f"Offline sandboxed AVIF batch failed: {res.stderr}"
        assert_avif_compliant(ctx, out / "DSC02532_HDR.avif", expect_grid=True, expect_w=7008, expect_h=4672)
        assert_avif_compliant(ctx, out / "DSC02540_HDR.avif", expect_grid=True, expect_w=4672, expect_h=7008)

    tests.extend([
        TestCase("T2-F01-01", 2, "F01", "No GPL Demosaic Symbols in LibRaw", t2_f01_01, "nm -gU chiaro (no dht/aahd/dcb/amaze)"),
        TestCase("T2-F01-02", 2, "F01", "All Mach-O Targets Clean License Scan", t2_f01_02, "otool -L + nm across CLI, App, Vendor/*.dylib"),
        TestCase("T2-F01-03", 2, "F01", "App Bundle Self-Contained Linkage", t2_f01_03, "Verify zero /tmp or dangling @rpath in Chiaro"),
        TestCase("T2-F01-04", 2, "F01", "Forbidden Library Strings & Script Enforcement", t2_f01_04, "strings scan + verify_licenses.sh"),
        TestCase("T2-F01-05", 2, "F01", "Network-Blocked Proxy+Sandbox Tri-Format", t2_f01_05, "HTTP_PROXY=127.0.0.1:9 sandbox-exec tri_format"),
        TestCase("T2-F01-06", 2, "F01", "Sandboxed Multi-File AVIF Batch", t2_f01_06, "sandbox-exec deny network* multi-file avif_archive"),
    ])

    # =========================================================================
    # F02: Preset Schema & Flag Boundary Cases (6 tests)
    # =========================================================================
    def t2_f02_01(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T2-F02-01")
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "does_not_exist", "--output", str(out)])
        assert res.returncode != 0, "Expected non-zero exit for unknown preset"
        assert res.returncode > 0, f"Process terminated by signal {-res.returncode}"
        assert not list(out.iterdir()), f"Expected zero files written, found {list(out.iterdir())}"

    def t2_f02_02(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T2-F02-02")
        bad_json = ctx.fixtures_dir / "bad_syntax.json"
        bad_json.write_text("{broken json", encoding="utf-8")
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset-file", str(bad_json), "--output", str(out)])
        assert res.returncode != 0
        assert res.returncode > 0, f"Malformed JSON caused signal crash {-res.returncode}"

    def t2_f02_03(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T2-F02-03")
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset-file", "/tmp/nonexistent_preset_xyz_e2e.json", "--output", str(out)])
        assert res.returncode != 0 and res.returncode > 0

    def t2_f02_04(ctx: RunContext) -> None:
        for ev, sub in [(1.0, "1ev"), (4.0, "4ev")]:
            out = ctx.test_out_dir("T2-F02-04", sub)
            pj = ctx.write_preset_json(f"hr_{sub}", {"targetHeadroomStops": ev})
            res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset-file", str(pj), "--output", str(out)])
            assert res.returncode == 0, f"Headroom {ev} EV failed: {res.stderr}"
            assert_heic_compliant(ctx, out / "DSC02532_HDR.heic", expected_stops=ev)

    def t2_f02_05(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T2-F02-05")
        pj = ctx.write_preset_json("conflict_1ev", {"targetHeadroomStops": 1.0})
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "apple_heic", "--preset-file", str(pj), "--output", str(out)])
        assert res.returncode >= 0, f"Conflicting preset flags caused signal crash {-res.returncode}"
        if res.returncode == 0:
            heic = out / "DSC02532_HDR.heic"
            assert heic.is_file()
            iio = ctx.probes.probe_image(heic)
            assert iio.get("hasISOGainMap") is True

    def t2_f02_06(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T2-F02-06")
        incomplete = ctx.fixtures_dir / "incomplete_schema.json"
        incomplete.write_text('{"id": "broken_only_id"}', encoding="utf-8")
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset-file", str(incomplete), "--output", str(out)])
        assert res.returncode != 0 and res.returncode > 0, f"Expected clean non-zero exit, got rc={res.returncode}"

    tests.extend([
        TestCase("T2-F02-01", 2, "F02", "Unknown --preset Error Handling", t2_f02_01, "chiaro DSC02532.ARW --preset does_not_exist"),
        TestCase("T2-F02-02", 2, "F02", "Malformed JSON --preset-file", t2_f02_02, "chiaro DSC02532.ARW --preset-file bad_syntax.json"),
        TestCase("T2-F02-03", 2, "F02", "Missing --preset-file Path", t2_f02_03, "chiaro DSC02532.ARW --preset-file /tmp/nonexistent.json"),
        TestCase("T2-F02-04", 2, "F02", "Headroom Boundaries 1.0 EV & 4.0 EV", t2_f02_04, "chiaro DSC02532.ARW targetHeadroomStops=1.0 & 4.0"),
        TestCase("T2-F02-05", 2, "F02", "Conflicting --preset + --preset-file", t2_f02_05, "chiaro --preset apple_heic --preset-file conflict_1ev.json"),
        TestCase("T2-F02-06", 2, "F02", "Incomplete Schema JSON Rejection", t2_f02_06, "chiaro --preset-file incomplete_schema.json"),
    ])

    # =========================================================================
    # F03: C-Bridge Boundary & Failure Isolation (6 tests)
    # =========================================================================
    def t2_f03_01(ctx: RunContext) -> None:
        corrupt = ctx.ensure_corrupt_arws()
        out = ctx.test_out_dir("T2-F03-01")
        res = ctx.run_cli([str(corrupt["truncated"]), "--preset", "apple_heic", "--output", str(out)])
        assert res.returncode != 0, f"Expected non-zero exit for truncated ARW, got rc={res.returncode}"
        assert res.returncode > 0, f"Truncated ARW caused signal crash {-res.returncode}"
        assert not list(out.glob("*.heic")), "Corrupt ARW should not emit HEIC"

    def t2_f03_02(ctx: RunContext) -> None:
        corrupt = ctx.ensure_corrupt_arws()
        out = ctx.test_out_dir("T2-F03-02")
        res = ctx.run_cli([str(corrupt["empty"]), str(corrupt["garbage"]), "--preset", "apple_heic", "--output", str(out)])
        assert res.returncode != 0 and res.returncode > 0
        assert not list(out.glob("*.heic")), "Empty/garbage ARWs should not emit HEIC"

    def t2_f03_03(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T2-F03-03")
        res = ctx.run_cli([str(ctx.sample_path("DSC02540.ARW")), "--preset", "avif_archive", "--avif-codec", "svt-av1", "--output", str(out)])
        assert res.returncode == 0, f"SVT-AV1 portrait grid failed: {res.stderr}"
        assert_avif_compliant(ctx, out / "DSC02540_HDR.avif", expect_grid=True, expect_w=4672, expect_h=7008)

    def t2_f03_04(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T2-F03-04")
        res = ctx.run_cli([str(ctx.sample_path("DSC02533.ARW")), "--preset", "xiaohongshu_jpg", "--output", str(out)])
        assert res.returncode == 0, f"ISO 12800 xiaohongshu_jpg failed: {res.stderr}"
        assert_jpeg_compliant(ctx, out / "DSC02533_HDR.jpg", max_bytes=4_194_304, expect_w=1536, expect_h=2048, run_ultrahdr=True)

    def t2_f03_05(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T2-F03-05")
        res = ctx.run_cli([str(ctx.sample_path("DSC02556.ARW")), "--preset", "avif_archive", "--avif-codec", "libaom", "--output", str(out)])
        assert res.returncode == 0, f"14MP portrait libaom failed: {res.stderr}"
        assert_avif_compliant(ctx, out / "DSC02556_HDR.avif", expect_grid=True, expect_w=3072, expect_h=4608)

    def t2_f03_06(ctx: RunContext) -> None:
        out1 = ctx.test_out_dir("T2-F03-06", "1ch")
        out3 = ctx.test_out_dir("T2-F03-06", "3ch")
        p1 = ctx.write_preset_json("avif_1ch", {"outputFormats": ["avif"], "gainMapChannels": "mono1ch"})
        p3 = ctx.write_preset_json("avif_3ch", {"outputFormats": ["avif"], "gainMapChannels": "rgb3ch"})
        r1 = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset-file", str(p1), "--output", str(out1)])
        r3 = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset-file", str(p3), "--output", str(out3)])
        assert r1.returncode == 0 and r3.returncode == 0
        assert_avif_compliant(ctx, out1 / "DSC02532_HDR.avif", expect_grid=True, expect_gm_yuv="YUV400")
        assert_avif_compliant(ctx, out3 / "DSC02532_HDR.avif", expect_grid=True, expect_gm_yuv="YUV420")

    tests.extend([
        TestCase("T2-F03-01", 2, "F03", "Truncated ARW in LibRaw Bridge", t2_f03_01, "chiaro corrupt_truncated.arw --preset apple_heic"),
        TestCase("T2-F03-02", 2, "F03", "0-Byte & Random-Bytes ARW", t2_f03_02, "chiaro empty_zero.arw corrupt_garbage.arw"),
        TestCase("T2-F03-03", 2, "F03", "SVT-AV1 Portrait Grid >4096px", t2_f03_03, "chiaro DSC02540.ARW --preset avif_archive --avif-codec svt-av1"),
        TestCase("T2-F03-04", 2, "F03", "libultrahdr ISO 12800 <=4MB Retry", t2_f03_04, "chiaro DSC02533.ARW --preset xiaohongshu_jpg"),
        TestCase("T2-F03-05", 2, "F03", "14MP APS-C M-size -> libavif libaom", t2_f03_05, "chiaro DSC02556.ARW --preset avif_archive --avif-codec libaom"),
        TestCase("T2-F03-06", 2, "F03", "libavif 1ch YUV400 vs 3ch YUV420 Parity", t2_f03_06, "chiaro DSC02532.ARW avif_1ch vs avif_3ch"),
    ])

    # =========================================================================
    # F04: Metal Heap, CWD, RSS & Extreme EV Boundaries (5 tests)
    # =========================================================================
    def t2_f04_01(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T2-F04-01")
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "apple_heic", "--output", str(out)], cwd=Path("/tmp"))
        assert res.returncode == 0, f"CWD=/tmp run failed: {res.stderr}"
        assert_heic_compliant(ctx, out / "DSC02532_HDR.heic")

    def t2_f04_02(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T2-F04-02")
        arws = [
            ctx.sample_path(f) for f in (
                "DSC02532.ARW", "DSC02533.ARW", "DSC02540.ARW", "DSC02555.ARW",
                "DSC02556.ARW", "DSC02557.ARW", "DSC02558.ARW", "DSC02559.ARW",
            )
        ]
        res = ctx.run_cli([str(p) for p in arws] + ["--preset", "tri_format", "--output", str(out)], measure_rss=True, timeout=900)
        assert res.returncode == 0, f"Mixed-res tri_format batch failed: {res.stderr}"
        assert res.peak_rss_bytes is not None and res.peak_rss_bytes <= PEAK_RSS_LIMIT_BYTES, (
            f"Peak RSS {res.peak_rss_bytes} exceeded 4.5 GiB ({PEAK_RSS_LIMIT_BYTES})"
        )
        ctx.note(f"Peak RSS={res.peak_rss_bytes / (1024**3):.2f} GiB")

    def t2_f04_03(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T2-F04-03")
        pj = ctx.write_preset_json("extreme_pos", {"targetHeadroomStops": 4.0}, develop_overrides={"exposureEV": 3.0})
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset-file", str(pj), "--output", str(out)])
        assert res.returncode == 0
        assert_heic_compliant(ctx, out / "DSC02532_HDR.heic", expected_stops=4.0)

    def t2_f04_04(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T2-F04-04")
        pj = ctx.write_preset_json("extreme_neg", {"targetHeadroomStops": 2.5}, develop_overrides={"exposureEV": -3.0})
        res = ctx.run_cli([str(ctx.sample_path("DSC02555.ARW")), "--preset-file", str(pj), "--output", str(out)])
        assert res.returncode == 0
        assert_heic_compliant(ctx, out / "DSC02555_HDR.heic", expected_stops=2.5)

    def t2_f04_05(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T2-F04-05")
        order = [
            ("DSC02532.ARW", 7008, 4672),
            ("DSC02556.ARW", 3072, 4608),
            ("DSC02540.ARW", 4672, 7008),
            ("DSC02557.ARW", 3072, 4608),
            ("DSC02533.ARW", 7008, 4672),
        ]
        res = ctx.run_cli([str(ctx.sample_path(f)) for f, _, _ in order] + ["--preset", "apple_heic", "--output", str(out)])
        assert res.returncode == 0
        for fname, ew, eh in order:
            stem = Path(fname).stem
            assert_heic_compliant(ctx, out / f"{stem}_HDR.heic", expect_w=ew, expect_h=eh)

    tests.extend([
        TestCase("T2-F04-01", 2, "F04", "CWD-Independent Shader Bundle Lookup", t2_f04_01, "(cd /tmp && chiaro DSC02532.ARW)"),
        TestCase("T2-F04-02", 2, "F04", "Mixed-Res MTLHeap Peak RSS <=4.5GB", t2_f04_02, "/usr/bin/time -l chiaro (8 mixed ARWs) --preset tri_format"),
        TestCase("T2-F04-03", 2, "F04", "Extreme +3.0 EV & 4.0 EV Headroom", t2_f04_03, "chiaro DSC02532.ARW exposureEV=+3.0 headroom=4.0"),
        TestCase("T2-F04-04", 2, "F04", "Extreme -3.0 EV Underexposure", t2_f04_04, "chiaro DSC02555.ARW exposureEV=-3.0"),
        TestCase("T2-F04-05", 2, "F04", "Alternating 33MP/14MP/Portrait Order", t2_f04_05, "chiaro alternating 5 ARWs --preset apple_heic"),
    ])

    # =========================================================================
    # F05: Highlight Reconstruction & Linear Pipeline Boundaries (6 tests)
    # =========================================================================
    def t2_f05_01(ctx: RunContext) -> None:
        for mode in ("opposedInpaint", "blend"):
            out = ctx.test_out_dir("T2-F05-01", mode)
            pj = ctx.write_preset_json(f"t2_hl_{mode}", develop_overrides={"highlightReconstruction": mode})
            res = ctx.run_cli([str(ctx.sample_path("DSC02533.ARW")), "--preset-file", str(pj), "--output", str(out)])
            assert res.returncode == 0
            assert_heic_compliant(ctx, out / "DSC02533_HDR.heic", expected_stops=2.5)

    def t2_f05_02(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T2-F05-02")
        pj = ctx.write_preset_json("shadow_max", develop_overrides={"shadowRecovery": 100.0, "exposureEV": 2.0})
        res = ctx.run_cli([str(ctx.sample_path("DSC02544.ARW")), "--preset-file", str(pj), "--output", str(out)])
        assert res.returncode == 0
        assert_heic_compliant(ctx, out / "DSC02544_HDR.heic", expected_stops=2.5)

    def t2_f05_03(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T2-F05-03")
        res = ctx.run_cli([
            str(ctx.sample_path("DSC02533.ARW")),
            str(ctx.sample_path("DSC02555.ARW")),
            "--preset", "apple_heic",
            "--output", str(out),
        ])
        assert res.returncode == 0
        assert_heic_compliant(ctx, out / "DSC02533_HDR.heic", expected_stops=2.5)
        assert_heic_compliant(ctx, out / "DSC02555_HDR.heic", expected_stops=2.5)

    def t2_f05_04(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T2-F05-04")
        pj = ctx.write_preset_json(
            "max_vibrance",
            {"outputFormats": ["heic", "jpeg"], "gainMapChannels": "mono1ch"},
            develop_overrides={"vibrance": 100.0},
            compat_overrides={"writeUltrahdrXMP": True},
        )
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset-file", str(pj), "--output", str(out)])
        assert res.returncode == 0
        assert_heic_compliant(ctx, out / "DSC02532_HDR.heic", expected_stops=2.5)
        assert_jpeg_compliant(ctx, out / "DSC02532_HDR.jpg", expected_stops=2.5, expect_xmp_hdrgm=True)

    def t2_f05_05(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T2-F05-05")
        pj = ctx.write_preset_json("high_bp", develop_overrides={"blackPoint": 80.0})
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset-file", str(pj), "--output", str(out)])
        assert res.returncode == 0
        assert_heic_compliant(ctx, out / "DSC02532_HDR.heic", expected_stops=2.5)

    def t2_f05_06(ctx: RunContext) -> None:
        for mode in ("opposedInpaint", "blend", "rebuild"):
            out = ctx.test_out_dir("T2-F05-06", mode)
            pj = ctx.write_preset_json(f"t2_hl43_{mode}", develop_overrides={"highlightReconstruction": mode})
            res = ctx.run_cli([str(ctx.sample_path("DSC02543.ARW")), "--preset-file", str(pj), "--output", str(out)])
            assert res.returncode == 0
            assert_heic_compliant(ctx, out / "DSC02543_HDR.heic", expected_stops=2.5)

    tests.extend([
        TestCase("T2-F05-01", 2, "F05", "Night Highlight opposedInpaint vs blend", t2_f05_01, "chiaro DSC02533.ARW opposedInpaint & blend"),
        TestCase("T2-F05-02", 2, "F05", "Extreme shadowRecovery=100 + +2 EV", t2_f05_02, "chiaro DSC02544.ARW shadowRecovery=100 exposureEV=2.0"),
        TestCase("T2-F05-03", 2, "F05", "ISO 12800 vs ISO 1600 Headroom Fidelity", t2_f05_03, "chiaro DSC02533.ARW DSC02555.ARW --preset apple_heic"),
        TestCase("T2-F05-04", 2, "F05", "vibrance=100 Gamut Safety", t2_f05_04, "chiaro DSC02532.ARW vibrance=100 HEIC+JPEG"),
        TestCase("T2-F05-05", 2, "F05", "blackPoint Upper Boundary (k=1/64 safety)", t2_f05_05, "chiaro DSC02532.ARW blackPoint=80.0"),
        TestCase("T2-F05-06", 2, "F05", "All 3 Highlight Recon Modes on ISO 12800", t2_f05_06, "chiaro DSC02543.ARW opposed/blend/rebuild"),
    ])

    # =========================================================================
    # F06: Dual-Branch Tone Mapping & Gamut Boundaries (6 tests)
    # =========================================================================
    def t2_f06_01(ctx: RunContext) -> None:
        for pval, sub in [(0.65, "p065"), (0.95, "p095")]:
            out = ctx.test_out_dir("T2-F06-01", sub)
            pj = ctx.write_preset_json(sub, {"midtoneAnchorP": pval})
            res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset-file", str(pj), "--output", str(out)])
            assert res.returncode == 0
            assert_heic_compliant(ctx, out / "DSC02532_HDR.heic", expected_stops=2.5)

    def t2_f06_02(ctx: RunContext) -> None:
        for bad_p, sub in [(0.1, "p01"), (1.5, "p15")]:
            out = ctx.test_out_dir("T2-F06-02", sub)
            pj = ctx.write_preset_json(f"invalid_{sub}", {"midtoneAnchorP": bad_p})
            res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset-file", str(pj), "--output", str(out)])
            assert res.returncode >= 0, f"Invalid midtoneAnchorP={bad_p} caused signal crash {-res.returncode}"
            if res.returncode == 0:
                assert_heic_compliant(ctx, out / "DSC02532_HDR.heic", expected_stops=2.5)

    def t2_f06_03(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T2-F06-03")
        pj = ctx.write_preset_json(
            "sdr_punchy",
            develop_overrides={"sdrExposureEV": -0.5, "sdrHighlightCompression": 90.0, "sdrContrast": 40.0, "sdrSaturation": 30.0},
        )
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset-file", str(pj), "--output", str(out)])
        assert res.returncode == 0
        assert_heic_compliant(ctx, out / "DSC02532_HDR.heic", expected_stops=2.5)

    def t2_f06_04(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T2-F06-04")
        pj = ctx.write_preset_json(
            "hdr_excite",
            develop_overrides={"hdrHighlightExcitation": 100.0, "hdrRolloffSoftness": 10.0},
        )
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset-file", str(pj), "--output", str(out)])
        assert res.returncode == 0
        assert_heic_compliant(ctx, out / "DSC02532_HDR.heic", expected_stops=2.5)

    def t2_f06_05(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T2-F06-05")
        pj = ctx.write_preset_json(
            "srgb_night",
            {"outputFormats": ["jpeg"], "bitDepth": 8, "baseColorSpace": "srgb", "gainMapChannels": "mono1ch"},
            compat_overrides={"writeUltrahdrXMP": True},
        )
        res = ctx.run_cli([str(ctx.sample_path("DSC02533.ARW")), "--preset-file", str(pj), "--output", str(out)])
        assert res.returncode == 0
        assert_jpeg_compliant(ctx, out / "DSC02533_HDR.jpg", expected_stops=2.5, expect_icc_substr="sRGB", expect_xmp_hdrgm=True)

    def t2_f06_06(ctx: RunContext) -> None:
        for tm in ("agx", "neutralRational", "openDRT"):
            out = ctx.test_out_dir("T2-F06-06", tm)
            pj = ctx.write_preset_json(f"t2_tm_{tm}", {"sdrToneMapper": tm})
            res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset-file", str(pj), "--output", str(out)])
            assert res.returncode == 0
            assert_heic_compliant(ctx, out / "DSC02532_HDR.heic", expected_stops=2.5)

    tests.extend([
        TestCase("T2-F06-01", 2, "F06", "midtoneAnchorP Bounds 0.65 vs 0.95", t2_f06_01, "chiaro DSC02532.ARW midtoneAnchorP=0.65 & 0.95"),
        TestCase("T2-F06-02", 2, "F06", "Invalid midtoneAnchorP (0.1 / 1.5)", t2_f06_02, "chiaro DSC02532.ARW midtoneAnchorP=0.1 & 1.5"),
        TestCase("T2-F06-03", 2, "F06", "Independent SDR Branch Extremes", t2_f06_03, "chiaro DSC02532.ARW sdr_punchy.json"),
        TestCase("T2-F06-04", 2, "F06", "Independent HDR Excitation Extremes", t2_f06_04, "chiaro DSC02532.ARW hdr_excite.json"),
        TestCase("T2-F06-05", 2, "F06", "Rec.2020 -> sRGB Soft Gamut Mapping", t2_f06_05, "chiaro DSC02533.ARW srgb_night.json"),
        TestCase("T2-F06-06", 2, "F06", "All 3 SDR Tone Mappers Headroom Parity", t2_f06_06, "chiaro DSC02532.ARW agx/neutralRational/openDRT"),
    ])

    # =========================================================================
    # F07: Crop, Resize, Headroom Tolerance & Orientation Boundaries (6 tests)
    # =========================================================================
    def t2_f07_01(ctx: RunContext) -> None:
        ratios = {
            "original": None,
            "3:4": 3.0 / 4.0,
            "4:5": 4.0 / 5.0,
            "1:1": 1.0,
            "4:3": 4.0 / 3.0,
            "9:16": 9.0 / 16.0,
        }
        for aspect, exp_ratio in ratios.items():
            tag = aspect.replace(":", "_")
            out = ctx.test_out_dir("T2-F07-01", tag)
            pj = ctx.write_preset_json(f"aspect_{tag}", {"cropAspect": aspect})
            res = ctx.run_cli([
                str(ctx.sample_path("DSC02532.ARW")),
                str(ctx.sample_path("DSC02540.ARW")),
                "--preset-file", str(pj),
                "--output", str(out),
            ])
            assert res.returncode == 0, f"Aspect {aspect} failed: {res.stderr}"
            for stem in ("DSC02532", "DSC02540"):
                info = assert_heic_compliant(ctx, out / f"{stem}_HDR.heic")
                w = info["imageio"]["pixelWidth"]
                h = info["imageio"]["pixelHeight"]
                assert w % 2 == 0 and h % 2 == 0, f"Odd dims {w}x{h} for {stem} aspect {aspect}"
                if exp_ratio is not None:
                    actual_ratio = w / h
                    assert abs(actual_ratio - exp_ratio) < 0.015, (
                        f"Aspect {aspect} on {stem}: got {w}x{h} ({actual_ratio:.4f} != {exp_ratio:.4f})"
                    )

    def t2_f07_02(ctx: RunContext) -> None:
        for edge in (4096, 2048, 1920):
            out = ctx.test_out_dir("T2-F07-02", str(edge))
            pj = ctx.write_preset_json(f"edge_{edge}", {"maxLongEdge": edge})
            res = ctx.run_cli([
                str(ctx.sample_path("DSC02532.ARW")),
                str(ctx.sample_path("DSC02556.ARW")),
                "--preset-file", str(pj),
                "--output", str(out),
            ])
            assert res.returncode == 0
            for stem in ("DSC02532", "DSC02556"):
                info = assert_heic_compliant(ctx, out / f"{stem}_HDR.heic")
                w, h = info["imageio"]["pixelWidth"], info["imageio"]["pixelHeight"]
                assert w % 2 == 0 and h % 2 == 0
                long_edge = max(w, h)
                assert (edge - 2) <= long_edge <= edge, f"maxLongEdge={edge}: got {w}x{h}"

    def t2_f07_03(ctx: RunContext) -> None:
        for ev in (1.0, 2.0, 2.5, 3.5):
            out = ctx.test_out_dir("T2-F07-03", f"{ev}".replace(".", "_"))
            pj = ctx.write_preset_json(f"tol_{ev}", {"targetHeadroomStops": ev})
            res = ctx.run_cli([str(ctx.sample_path("DSC02555.ARW")), "--preset-file", str(pj), "--output", str(out)])
            assert res.returncode == 0
            assert_heic_compliant(ctx, out / "DSC02555_HDR.heic", expected_stops=ev)

    def t2_f07_04(ctx: RunContext) -> None:
        for cl, sub in [(True, "cl_on"), (False, "cl_off")]:
            out = ctx.test_out_dir("T2-F07-04", sub)
            pj = ctx.write_preset_json(
                f"jpg_{sub}",
                {
                    "outputFormats": ["jpeg"],
                    "bitDepth": 8,
                    "gainMapChannels": "mono1ch",
                    "cropAspect": "3:4",
                    "maxLongEdge": 2048,
                    "targetMaxFileBytes": 4_194_304,
                },
                compat_overrides={"writeUltrahdrXMP": True, "closedLoopSDRCompensation": cl},
            )
            res = ctx.run_cli([str(ctx.sample_path("DSC02533.ARW")), "--preset-file", str(pj), "--output", str(out)])
            assert res.returncode == 0
            assert_jpeg_compliant(ctx, out / "DSC02533_HDR.jpg", max_bytes=4_194_304, run_ultrahdr=True)

    def t2_f07_05(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T2-F07-05")
        res = ctx.run_cli([str(ctx.sample_path("DSC02540.ARW")), "--preset", "avif_archive", "--output", str(out)])
        assert res.returncode == 0
        info = assert_avif_compliant(ctx, out / "DSC02540_HDR.avif", expect_grid=True, expect_w=4672, expect_h=7008)
        adec = info["avifdec"]
        assert adec.gain_map_width == 2336 and adec.gain_map_height == 3504, (
            f"Expected upright portrait 1/2 GM 2336x3504, got {adec.gain_map_width}x{adec.gain_map_height}"
        )

    def t2_f07_06(ctx: RunContext) -> None:
        for gam in (0.5, 1.0, 1.5):
            out = ctx.test_out_dir("T2-F07-06", f"g{gam}".replace(".", "_"))
            pj = ctx.write_preset_json(
                f"avif_g_{gam}",
                {"outputFormats": ["avif"], "gainMapGamma": gam, "maxLongEdge": 2048},
            )
            res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset-file", str(pj), "--output", str(out)])
            assert res.returncode == 0
            assert_avif_compliant(ctx, out / "DSC02532_HDR.avif", expected_stops=2.5, expected_gamma=gam, expect_grid=False)

    tests.extend([
        TestCase("T2-F07-01", 2, "F07", "All 6 cropAspect Ratios (Horiz+Portrait)", t2_f07_01, "chiaro DSC02532+DSC02540 across 6 cropAspects"),
        TestCase("T2-F07-02", 2, "F07", "maxLongEdge Resize Guardrails", t2_f07_02, "chiaro maxLongEdge=4096,2048,1920"),
        TestCase("T2-F07-03", 2, "F07", "Headroom <2% Tolerance Across 4 Stops", t2_f07_03, "chiaro DSC02555.ARW 1.0,2.0,2.5,3.5 EV"),
        TestCase("T2-F07-04", 2, "F07", "Closed-Loop SDR Comp ON vs OFF", t2_f07_04, "chiaro DSC02533.ARW closedLoop=true & false"),
        TestCase("T2-F07-05", 2, "F07", "Portrait Rotate 270 CW 1/2 GM Dims (2336x3504)", t2_f07_05, "chiaro DSC02540.ARW --preset avif_archive"),
        TestCase("T2-F07-06", 2, "F07", "gainMapGamma Bounds (0.5, 1.0, 1.5)", t2_f07_06, "chiaro DSC02532.ARW gainMapGamma=0.5,1.0,1.5"),
    ])

    # =========================================================================
    # F08: ARW Filtering, Dual Backend & EXIF Boundaries (6 tests)
    # =========================================================================
    def t2_f08_01(ctx: RunContext) -> None:
        in_dir = ctx.test_out_dir("T2-F08-01", "in")
        out = ctx.test_out_dir("T2-F08-01", "out")
        for stem in ("DSC02532", "DSC02540", "DSC02556"):
            shutil.copy2(ctx.sample_path(f"{stem}.ARW"), in_dir / f"{stem}.ARW")
            hif = ctx.cfg.sample_dir / f"{stem}.HIF"
            if hif.is_file():
                shutil.copy2(hif, in_dir / f"{stem}.HIF")
        res = ctx.run_cli([str(in_dir), "--recursive", "--preset", "apple_heic", "--output", str(out)])
        assert res.returncode == 0
        heics = sorted(out.glob("*.heic"))
        assert len(heics) == 3, f"Expected strictly 3 outputs, got {len(heics)}"

    def t2_f08_02(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T2-F08-02")
        res = ctx.run_cli([str(ctx.sample_path("DSC02556.ARW")), "--backend", "ciraw9", "--preset", "apple_heic", "--output", str(out)])
        assert res.returncode == 0
        assert_heic_compliant(ctx, out / "DSC02556_HDR.heic", expect_w=3072, expect_h=4608)

    def t2_f08_03(ctx: RunContext) -> None:
        out_lr = ctx.test_out_dir("T2-F08-03", "libraw")
        out_ci = ctx.test_out_dir("T2-F08-03", "ciraw9")
        r1 = ctx.run_cli([str(ctx.sample_path("DSC02533.ARW")), "--backend", "libraw", "--preset", "apple_heic", "--output", str(out_lr)])
        r2 = ctx.run_cli([str(ctx.sample_path("DSC02533.ARW")), "--backend", "ciraw9", "--preset", "apple_heic", "--output", str(out_ci)])
        assert r1.returncode == 0 and r2.returncode == 0
        assert_heic_compliant(ctx, out_lr / "DSC02533_HDR.heic", expect_w=7008, expect_h=4672)
        assert_heic_compliant(ctx, out_ci / "DSC02533_HDR.heic", expect_w=7008, expect_h=4672)

    def t2_f08_04(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T2-F08-04")
        arw = ctx.sample_path("DSC02532.ARW")
        res = ctx.run_cli([str(arw), str(arw), "--preset", "apple_heic", "--json-progress", "--output", str(out)])
        assert res.returncode == 0
        heics = list(out.glob("*.heic"))
        assert len(heics) == 1, f"Duplicate input emitted {len(heics)} files: {heics}"

    def t2_f08_05(ctx: RunContext) -> None:
        out_a = ctx.test_out_dir("T2-F08-05", "app1")
        r_a = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "xiaohongshu_jpg", "--output", str(out_a)])
        assert r_a.returncode == 0
        info = assert_jpeg_compliant(ctx, out_a / "DSC02532_HDR.jpg", max_app1_bytes=8192)
        assert info["exiftool"].app1_exif_size_bytes is not None and info["exiftool"].app1_exif_size_bytes < 8192

        out_b = ctx.test_out_dir("T2-F08-05", "bogus")
        r_b = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--backend", "bogus", "--output", str(out_b)])
        assert r_b.returncode != 0 and r_b.returncode > 0

    def t2_f08_06(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T2-F08-06")
        res = ctx.run_cli(["/tmp/does_not_exist_DSC99999.ARW", "--preset", "apple_heic", "--output", str(out)])
        assert res.returncode != 0 and res.returncode > 0

    tests.extend([
        TestCase("T2-F08-01", 2, "F08", "Mixed .ARW + .HIF Dir Filtering", t2_f08_01, "chiaro mixed_arw_hif --recursive"),
        TestCase("T2-F08-02", 2, "F08", "ciraw9 on 14MP APS-C M-size Fallback", t2_f08_02, "chiaro DSC02556.ARW --backend ciraw9"),
        TestCase("T2-F08-03", 2, "F08", "libraw vs ciraw9 Parity (ISO 12800)", t2_f08_03, "chiaro DSC02533.ARW libraw & ciraw9"),
        TestCase("T2-F08-04", 2, "F08", "Input Path Deduplication", t2_f08_04, "chiaro DSC02532.ARW DSC02532.ARW --json-progress"),
        TestCase("T2-F08-05", 2, "F08", "EXIF < 8 KB & Invalid --backend", t2_f08_05, "Verify JPEG APP1 < 8192B + --backend bogus error"),
        TestCase("T2-F08-06", 2, "F08", "Non-Existent ARW Path Rejection", t2_f08_06, "chiaro /tmp/does_not_exist.ARW"),
    ])

    # =========================================================================
    # F09: Encoder Container & Guardrail Boundaries (6 tests)
    # =========================================================================
    def t2_f09_01(ctx: RunContext) -> None:
        # 1. apple_heic_compat has both ISOGainMap + HDRGainMap
        out_c = ctx.test_out_dir("T2-F09-01", "compat")
        r_c = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "apple_heic_compat", "--output", str(out_c)])
        assert r_c.returncode == 0
        assert_heic_compliant(ctx, out_c / "DSC02532_HDR.heic", expect_legacy_gm=True)

        # 2. 3ch + writeLegacyAppleHDRGainMap=true must either reject cleanly OR force 1ch/strip legacy without segfault
        out_3c = ctx.test_out_dir("T2-F09-01", "3ch_compat")
        p3c = ctx.write_preset_json(
            "3ch_compat",
            {"outputFormats": ["heic"], "gainMapChannels": "rgb3ch"},
            compat_overrides={"writeLegacyAppleHDRGainMap": True},
        )
        r_3c = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset-file", str(p3c), "--output", str(out_3c)])
        assert r_3c.returncode >= 0, f"3ch + legacy HDRGainMap caused signal crash {-r_3c.returncode}"
        if r_3c.returncode == 0:
            iio = ctx.probes.probe_image(out_3c / "DSC02532_HDR.heic")
            assert iio.get("hasISOGainMap") is True

        # 3. 3ch JPEG must NOT emit XMP-hdrgm
        out_3j = ctx.test_out_dir("T2-F09-01", "3ch_jpeg")
        p3j = ctx.write_preset_json(
            "3ch_jpeg",
            {"outputFormats": ["jpeg"], "bitDepth": 8, "gainMapChannels": "rgb3ch"},
            compat_overrides={"writeUltrahdrXMP": False},
        )
        r_3j = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset-file", str(p3j), "--output", str(out_3j)])
        assert r_3j.returncode == 0
        assert_jpeg_compliant(ctx, out_3j / "DSC02532_HDR.jpg", expect_xmp_hdrgm=False)

    def t2_f09_02(ctx: RunContext) -> None:
        for preset in ("xiaohongshu_jpg", "douyin_jpg"):
            out = ctx.test_out_dir("T2-F09-02", preset)
            res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", preset, "--output", str(out)])
            assert res.returncode == 0
            ex = probe_exiftool(ctx.cfg.tools, out / "DSC02532_HDR.jpg")
            assert not ex.has_forbidden_sony_or_makernote(), f"Sony MakerNote in {preset}"
            assert not ex.has_forbidden_apple_makernote(), f"Apple MakerNote in {preset}"

    def t2_f09_03(ctx: RunContext) -> None:
        # >4096 / >8.9MP triggers MIAF grid; 4096x2730 (11.18MP > 8.9MP) triggers grid; 2048px does NOT
        out_4k = ctx.test_out_dir("T2-F09-03", "4096")
        p4k = ctx.write_preset_json("avif_4096", {"outputFormats": ["avif"], "maxLongEdge": 4096})
        r4k = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset-file", str(p4k), "--output", str(out_4k)])
        assert r4k.returncode == 0
        assert_avif_compliant(ctx, out_4k / "DSC02532_HDR.avif", expect_grid=True)

        out_2k = ctx.test_out_dir("T2-F09-03", "2048")
        p2k = ctx.write_preset_json("avif_2048", {"outputFormats": ["avif"], "maxLongEdge": 2048})
        r2k = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset-file", str(p2k), "--output", str(out_2k)])
        assert r2k.returncode == 0
        assert_avif_compliant(ctx, out_2k / "DSC02532_HDR.avif", expect_grid=False)

    def t2_f09_04(ctx: RunContext) -> None:
        out_xhs = ctx.test_out_dir("T2-F09-04", "xhs")
        rx = ctx.run_cli([str(ctx.sample_path("DSC02533.ARW")), "--preset", "xiaohongshu_jpg", "--output", str(out_xhs)])
        assert rx.returncode == 0
        assert_jpeg_compliant(ctx, out_xhs / "DSC02533_HDR.jpg", max_bytes=4_194_304, expect_w=1536, expect_h=2048)

        out_dy = ctx.test_out_dir("T2-F09-04", "douyin")
        pdy_916 = ctx.write_preset_json(
            "douyin_jpg_916",
            {
                "outputFormats": ["jpeg"],
                "bitDepth": 8,
                "baseColorSpace": "srgb",
                "gainMapChannels": "mono1ch",
                "cropAspect": "9:16",
                "maxLongEdge": 1920,
                "targetMaxFileBytes": 3_145_728,
            },
            compat_overrides={"writeUltrahdrXMP": True},
        )
        rd = ctx.run_cli([str(ctx.sample_path("DSC02540.ARW")), "--preset-file", str(pdy_916), "--output", str(out_dy)])
        assert rd.returncode == 0
        assert_jpeg_compliant(
            ctx,
            out_dy / "DSC02540_HDR.jpg",
            max_bytes=3_145_728,
            expect_icc_substr="sRGB",
            expect_w=1080,
            expect_h=1920,
        )

    def t2_f09_05(ctx: RunContext) -> None:
        out_34 = ctx.test_out_dir("T2-F09-05", "3_4")
        p34 = ctx.write_preset_json(
            "hlg_34",
            {"outputFormats": ["hlgMP4"], "cropAspect": "3:4"},
            hlg_overrides={"aspect": "3:4", "durationSeconds": 3.0, "fps": 30, "bitrateMbps": 12.0},
        )
        r34 = ctx.run_cli([str(ctx.sample_path("DSC02540.ARW")), "--preset-file", str(p34), "--output", str(out_34)])
        assert r34.returncode == 0
        assert_hlg_mp4_compliant(ctx, out_34 / "DSC02540_HDR.mp4", allowed_sizes=((1080, 1440),), min_dur=3.0, max_dur=3.2)

        out_4k = ctx.test_out_dir("T2-F09-05", "no4k")
        p4k = ctx.write_preset_json(
            "hlg_4k_attempt",
            {"outputFormats": ["hlgMP4"], "maxLongEdge": 3840},
            hlg_overrides={"aspect": "9:16", "durationSeconds": 4.0, "fps": 30, "bitrateMbps": 14.0},
        )
        r4k = ctx.run_cli([str(ctx.sample_path("DSC02540.ARW")), "--preset-file", str(p4k), "--output", str(out_4k)])
        assert r4k.returncode >= 0
        if r4k.returncode == 0:
            assert_hlg_mp4_compliant(ctx, out_4k / "DSC02540_HDR.mp4", allowed_sizes=((1080, 1920), (1080, 1440)))

    def t2_f09_06(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T2-F09-06")
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "tri_format", "--output", str(out)])
        assert res.returncode == 0
        hbox = inspect_isobmff(out / "DSC02532_HDR.heic")
        assert hbox.has_tmap_item and hbox.has_dimg_for_tmap and hbox.has_altr_group
        abox = inspect_isobmff(out / "DSC02532_HDR.avif")
        assert abox.has_tmap_item and abox.has_grid_item and not abox.tmap_forbidden_props

    tests.extend([
        TestCase("T2-F09-01", 2, "F09", "1ch Dual-Write vs 3ch Pure ISO Rules", t2_f09_01, "apple_heic_compat vs 3ch_compat vs 3ch_jpeg"),
        TestCase("T2-F09-02", 2, "F09", "Zero Sony MakerNote & Zero Apple 33/48", t2_f09_02, "exiftool check on xiaohongshu_jpg & douyin_jpg"),
        TestCase("T2-F09-03", 2, "F09", "AVIF Grid Trigger Boundaries (4096 vs 2048)", t2_f09_03, "chiaro maxLongEdge=4096 (grid) vs 2048 (no grid)"),
        TestCase("T2-F09-04", 2, "F09", "Xiaohongshu <=4MB & Douyin JPG <=3MB", t2_f09_04, "chiaro DSC02533 xhs + DSC02540 douyin 9:16"),
        TestCase("T2-F09-05", 2, "F09", "Douyin HLG MP4 Aspects, Duration & No-4K", t2_f09_05, "chiaro hlg_34.json & hlg_4k_attempt.json"),
        TestCase("T2-F09-06", 2, "F09", "Container ISOBMFF tmap/grid/altr Invariants", t2_f09_06, "isobmff_box check on tri_format HEIC & AVIF"),
    ])

    # =========================================================================
    # F10: Post-Export Automated Compliance Probes Boundaries (6 tests)
    # =========================================================================
    def t2_f10_01(ctx: RunContext) -> None:
        for ev in (1.0, 2.5, 4.0):
            out = ctx.test_out_dir("T2-F10-01", f"{ev}".replace(".", "_"))
            pj = ctx.write_preset_json(f"v_ev_{ev}", {"targetHeadroomStops": ev})
            res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset-file", str(pj), "--verify", "--json-progress", "--output", str(out)])
            assert res.returncode == 0
            assert_heic_compliant(ctx, out / "DSC02532_HDR.heic", expected_stops=ev)

    def t2_f10_02(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T2-F10-02")
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "tri_format", "--formats", "jpeg", "--verify", "--json-progress", "--output", str(out)])
        assert res.returncode == 0
        assert (out / "DSC02532_HDR.jpg").is_file()
        assert not (out / "DSC02532_HDR.heic").exists()
        assert_jpeg_compliant(ctx, out / "DSC02532_HDR.jpg")

    def t2_f10_03(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T2-F10-03")
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "tri_format", "--format-subdirs", "--verify", "--output", str(out)])
        assert res.returncode == 0
        assert_heic_compliant(ctx, out / "heic" / "DSC02532_HDR.heic")
        assert_jpeg_compliant(ctx, out / "jpeg" / "DSC02532_HDR.jpg")
        assert_avif_compliant(ctx, out / "avif" / "DSC02532_HDR.avif", expect_grid=True)

    def t2_f10_04(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T2-F10-04")
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "apple_heic", "--naming", "CUSTOM_{name}.{ext}", "--verify", "--output", str(out)])
        assert res.returncode == 0
        assert_heic_compliant(ctx, out / "CUSTOM_DSC02532.heic")

    def t2_f10_05(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T2-F10-05")
        dummy = out / "DSC02532_HDR.heic"
        dummy.write_bytes(b"DUMMY_10B!")
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "apple_heic", "--on-conflict", "auto-number", "--verify", "--output", str(out)])
        assert res.returncode == 0, f"--on-conflict auto-number --verify failed: {res.stderr}"
        assert dummy.read_bytes() == b"DUMMY_10B!", "auto-number modified original sentinel file"
        created = [p for p in out.glob("DSC02532_HDR*.heic") if p != dummy]
        assert len(created) == 1, f"Expected 1 new auto-numbered file, got {created}"
        assert_heic_compliant(ctx, created[0])

    def t2_f10_06(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T2-F10-06")
        res = ctx.run_cli([str(ctx.sample_path("DSC02540.ARW")), "--preset", "tri_format", "--formats", "heic,jpeg,avif,mp4", "--verify", "--json-progress", "--output", str(out)])
        assert res.returncode == 0, f"4-format --verify failed: {res.stderr}"
        lines = parse_ndjson_lines(res.stdout + "\n" + res.stderr)
        assert lines, "Expected JSON progress lines"
        assert_heic_compliant(ctx, out / "DSC02540_HDR.heic", expect_w=4672, expect_h=7008)
        assert_jpeg_compliant(ctx, out / "DSC02540_HDR.jpg", expect_w=4672, expect_h=7008)
        assert_avif_compliant(ctx, out / "DSC02540_HDR.avif", expect_grid=True, expect_w=4672, expect_h=7008)
        assert_hlg_mp4_compliant(ctx, out / "DSC02540_HDR.mp4")

    tests.extend([
        TestCase("T2-F10-01", 2, "F10", "Probe <2% Error Alignment (1.0/2.5/4.0 EV)", t2_f10_01, "chiaro --verify across 1.0, 2.5, 4.0 EV"),
        TestCase("T2-F10-02", 2, "F10", "--verify with --formats Subset Override", t2_f10_02, "chiaro --preset tri_format --formats jpeg --verify"),
        TestCase("T2-F10-03", 2, "F10", "--verify with --format-subdirs", t2_f10_03, "chiaro --preset tri_format --format-subdirs --verify"),
        TestCase("T2-F10-04", 2, "F10", "--verify with Custom --naming", t2_f10_04, "chiaro --naming CUSTOM_{name}.{ext} --verify"),
        TestCase("T2-F10-05", 2, "F10", "--verify with --on-conflict auto-number", t2_f10_05, "chiaro --on-conflict auto-number --verify"),
        TestCase("T2-F10-06", 2, "F10", "--verify --json-progress Across All 4 Formats", t2_f10_06, "chiaro --formats heic,jpeg,avif,mp4 --verify --json-progress"),
    ])

    # =========================================================================
    # F11: Pipeline Error Isolation, Conflict Policies, RSS & CLI Validation (6 tests)
    # =========================================================================
    def t2_f11_01(ctx: RunContext) -> None:
        corrupt = ctx.ensure_corrupt_arws()
        out = ctx.test_out_dir("T2-F11-01")
        res = ctx.run_cli([
            str(ctx.sample_path("DSC02532.ARW")),
            str(corrupt["truncated"]),
            str(ctx.sample_path("DSC02555.ARW")),
            "--preset", "apple_heic",
            "--json-progress",
            "--output", str(out),
        ])
        assert res.returncode > 0, f"Expected clean non-zero partial-failure code, got rc={res.returncode}"
        assert_heic_compliant(ctx, out / "DSC02532_HDR.heic")
        assert_heic_compliant(ctx, out / "DSC02555_HDR.heic")

    def t2_f11_02(ctx: RunContext) -> None:
        for policy in ("overwrite", "skip", "auto-number"):
            out = ctx.test_out_dir("T2-F11-02", policy)
            sentinel = out / "DSC02532_HDR.heic"
            sentinel.write_bytes(b"SENTINEL")
            res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset", "apple_heic", "--on-conflict", policy, "--output", str(out)])
            assert res.returncode == 0
            if policy == "overwrite":
                assert_heic_compliant(ctx, sentinel)
            elif policy == "skip":
                assert sentinel.read_bytes() == b"SENTINEL"
            else:
                assert sentinel.read_bytes() == b"SENTINEL"
                extra = [p for p in out.glob("DSC02532_HDR*.heic") if p != sentinel]
                assert len(extra) == 1
                assert_heic_compliant(ctx, extra[0])

    def t2_f11_03(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T2-F11-03")
        arws = [str(ctx.sample_path(f"DSC0{n}.ARW")) for n in range(2532, 2536)]
        res = ctx.run_cli(arws + ["--preset", "tri_format", "--output", str(out)])
        assert res.returncode == 0
        tmp_leftovers = [p for p in out.rglob("*") if ".tmp" in p.name]
        assert not tmp_leftovers, f"Found orphaned .tmp files: {tmp_leftovers}"

    def t2_f11_04(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T2-F11-04")
        arw = str(ctx.sample_path("DSC02532.ARW"))
        bad_invocations = [
            ["--preset", "apple_heic", "--output", str(out)],
            ["/tmp/no_such_file_xyz.ARW", "--preset", "apple_heic", "--output", str(out)],
            [arw, "--formats", "png", "--output", str(out)],
            [arw, "--on-conflict", "crash", "--output", str(out)],
            [arw, "--avif-codec", "x265", "--output", str(out)],
        ]
        for args in bad_invocations:
            res = ctx.run_cli(args)
            assert res.returncode != 0 and res.returncode > 0, (
                f"Expected clean non-zero error for {args}, got rc={res.returncode}"
            )

    def t2_f11_05(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T2-F11-05")
        res = ctx.run_cli(
            [str(ctx.cfg.sample_dir), "--preset", "apple_heic", "--output", str(out)],
            measure_rss=True,
            timeout=1200,
        )
        assert res.returncode == 0, f"Full 35-ARW batch failed: {res.stderr}"
        heics = sorted(out.glob("*.heic"))
        assert len(heics) == 35, f"Expected 35 HEICs (0 from .HIF), got {len(heics)}"
        assert res.peak_rss_bytes is not None and res.peak_rss_bytes <= PEAK_RSS_LIMIT_BYTES, (
            f"Peak RSS {res.peak_rss_bytes} > 4.5 GiB"
        )
        for sample_check in (heics[0], heics[8], heics[24], heics[-1]):
            iio = ctx.probes.probe_image(sample_check)
            assert iio.get("hasISOGainMap") is True and iio.get("depth") == 10
        ctx.note(f"35-ARW batch OK: {res.duration_s:.2f}s ({res.duration_s/35:.2f}s/img), RSS={res.peak_rss_bytes/(1024**3):.2f} GiB")

    def t2_f11_06(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T2-F11-06")
        res = ctx.run_cli([
            str(ctx.sample_path("DSC02532.ARW")),
            "--preset", "tri_format",
            "--naming", "{name}_custom.{ext}",
            "--output", str(out),
        ])
        assert res.returncode == 0
        assert_heic_compliant(ctx, out / "DSC02532_custom.heic")
        assert_jpeg_compliant(ctx, out / "DSC02532_custom.jpg")
        assert_avif_compliant(ctx, out / "DSC02532_custom.avif", expect_grid=True)

    tests.extend([
        TestCase("T2-F11-01", 2, "F11", "Corrupt ARW Batch Error Isolation", t2_f11_01, "chiaro [DSC02532, corrupt_truncated, DSC02555]"),
        TestCase("T2-F11-02", 2, "F11", "Conflict Policies (overwrite/skip/auto-number)", t2_f11_02, "chiaro --on-conflict overwrite/skip/auto-number"),
        TestCase("T2-F11-03", 2, "F11", "Atomic Write Cleanliness (No .tmp)", t2_f11_03, "chiaro 4 ARWs --preset tri_format + *.tmp scan"),
        TestCase("T2-F11-04", 2, "F11", "Invalid CLI Flag Values Rejection", t2_f11_04, "Missing input, --formats png, --on-conflict crash, --avif-codec x265"),
        TestCase("T2-F11-05", 2, "F11", "Full 35-ARW Batch Throughput & Peak RSS", t2_f11_05, "/usr/bin/time -l chiaro <Tangmo> --preset apple_heic"),
        TestCase("T2-F11-06", 2, "F11", "Multi-Format Custom --naming Collision-Free", t2_f11_06, "chiaro tri_format --naming {name}_custom.{ext}"),
    ])

    # =========================================================================
    # F12: Chiaro.app Launch, Relocation & Bundle Hygiene (5 tests)
    # =========================================================================
    def _smoke_launch(exe: str, args: List[str], hold_s: float = 3.0) -> None:
        diag_dir = Path.home() / "Library" / "Logs" / "DiagnosticReports"
        before_ips = set(diag_dir.glob("*Chiaro*")) if diag_dir.is_dir() else set()
        proc = subprocess.Popen([exe] + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            time.sleep(hold_s)
            rc = proc.poll()
            assert rc is None, f"App exited prematurely (rc={rc}): {proc.stderr.read().decode(errors='replace') if proc.stderr else ''}"
        finally:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
        after_ips = set(diag_dir.glob("*Chiaro*")) if diag_dir.is_dir() else set()
        assert not (after_ips - before_ips), f"New crash logs: {after_ips - before_ips}"

    def t2_f12_01(ctx: RunContext) -> None:
        app = _require_app(ctx)
        info = check_app_bundle(ctx.cfg.tools, app)
        assert info["ok"], f"Bundle invalid: {info['errors']}"
        _smoke_launch(info["executable"], [], hold_s=3.0)

    def t2_f12_02(ctx: RunContext) -> None:
        app = _require_app(ctx)
        info = check_app_bundle(ctx.cfg.tools, app)
        assert info["ok"], f"Bundle invalid: {info['errors']}"
        _smoke_launch(info["executable"], [str(ctx.sample_path("DSC02532.ARW"))], hold_s=3.0)

    def t2_f12_03(ctx: RunContext) -> None:
        app = _require_app(ctx)
        info = check_app_bundle(ctx.cfg.tools, app)
        assert info["shaders_metal_files"], "Shaders.metal missing from Contents/Resources"
        json_names = {Path(p).stem for p in info["resource_json_files"]}
        missing = [pid for pid in BUILTIN_PRESET_IDS if pid not in json_names]
        assert not missing, f"Missing preset JSONs in Chiaro.app Resources: {missing}"

    def t2_f12_04(ctx: RunContext) -> None:
        app = _require_app(ctx)
        reloc_dir = ctx.test_out_dir("T2-F12-04", "Reloc")
        reloc_app = reloc_dir / "Chiaro.app"
        shutil.copytree(app, reloc_app, symlinks=True)
        info = check_app_bundle(ctx.cfg.tools, reloc_app)
        assert info["ok"], f"Relocated bundle failed verification: {info['errors']}"
        _smoke_launch(info["executable"], [], hold_s=3.0)

    def t2_f12_05(ctx: RunContext) -> None:
        app = _require_app(ctx)
        info = check_app_bundle(ctx.cfg.tools, app)
        res = assert_zero_gpl(ctx, Path(info["executable"]), check_symbols=True)
        joined = "\n".join(res["otool_lines"])
        for fw in ("Metal", "ImageIO", "AVFoundation"):
            assert fw in joined, f"Expected Apple framework {fw} in Chiaro linkage"
        junk = [p for p in app.rglob("*") if p.name == ".DS_Store" or ".tmp" in p.name]
        assert not junk, f"Found .DS_Store/.tmp artifacts inside Chiaro.app: {junk}"

    tests.extend([
        TestCase("T2-F12-01", 2, "F12", "Chiaro.app Cold Launch (No Args)", t2_f12_01, "Launch Chiaro 3s no args"),
        TestCase("T2-F12-02", 2, "F12", "Chiaro.app Launch with ARW Arg", t2_f12_02, "Launch Chiaro DSC02532.ARW 3s"),
        TestCase("T2-F12-03", 2, "F12", "App Bundle Presets & Resource Parity", t2_f12_03, "Verify 7 preset JSONs + Shaders.metal in Resources"),
        TestCase("T2-F12-04", 2, "F12", "Relocated App Bundle Codesign & Launch", t2_f12_04, "Copy Chiaro.app to temp Reloc/, codesign & launch"),
        TestCase("T2-F12-05", 2, "F12", "App Bundle Hygiene & Framework Linkage", t2_f12_05, "otool -L Apple frameworks + zero .DS_Store/.tmp"),
    ])

    assert len(tests) == 70, f"Expected 70 Tier 2 tests, got {len(tests)}"
    return tests

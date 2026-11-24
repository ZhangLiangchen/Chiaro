"""Tier 4 Real-World Application Scenario E2E Tests (8 distinct scenarios: T4-01..T4-08)."""

from __future__ import annotations

import shutil
import subprocess
import time
from pathlib import Path
from typing import List

from config import PEAK_RSS_LIMIT_BYTES
from probes.cli_probes import check_app_bundle, probe_exiftool
from tests.common import (
    RunContext,
    TestCase,
    assert_avif_compliant,
    assert_exif_clean_and_whitelisted,
    assert_heic_compliant,
    assert_hlg_mp4_compliant,
    assert_jpeg_compliant,
    assert_zero_gpl,
    parse_ndjson_lines,
)


def _mirror_to_verify_dir(ctx: RunContext, src_dir: Path, subdir: str) -> None:
    if ctx.cfg.output_verify_dir is None:
        return
    dst = ctx.cfg.output_verify_dir / subdir
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src_dir, dst)
    ctx.note(f"Mirrored outputs to {dst}")


def get_tests() -> List[TestCase]:
    tests: List[TestCase] = []

    def t4_01(ctx: RunContext) -> None:
        # Phase A: Dual HEIC + JPEG across all 35 ARWs
        out_dual = ctx.test_out_dir("T4-01", "dual")
        res_a = ctx.run_cli(
            [str(ctx.cfg.sample_dir), "--output", str(out_dual), "--preset", "apple_heic", "--formats", "heic,jpeg", "--verify"],
            measure_rss=True,
            timeout=1800,
        )
        assert res_a.returncode == 0, f"T4-01 Phase A failed: {res_a.stderr}"
        heics_a = sorted(out_dual.glob("*.heic"))
        jpgs_a = sorted(out_dual.glob("*.jpg"))
        assert len(heics_a) == 35 and len(jpgs_a) == 35, f"Expected 35+35 outputs, got {len(heics_a)} heic, {len(jpgs_a)} jpg"
        assert res_a.peak_rss_bytes is not None and res_a.peak_rss_bytes <= PEAK_RSS_LIMIT_BYTES, (
            f"Phase A peak RSS {res_a.peak_rss_bytes} > 4.5 GiB"
        )
        sec_per_img_a = res_a.duration_s / 35.0
        assert sec_per_img_a <= 3.5, f"Phase A throughput {sec_per_img_a:.2f} s/img exceeded 3.5 s/img ceiling"

        # Phase B: Tri-Format across all 35 ARWs
        out_tri = ctx.test_out_dir("T4-01", "tri")
        res_b = ctx.run_cli(
            [str(ctx.cfg.sample_dir), "--output", str(out_tri), "--preset", "tri_format", "--format-subdirs", "--verify"],
            measure_rss=True,
            timeout=2400,
        )
        assert res_b.returncode == 0, f"T4-01 Phase B failed: {res_b.stderr}"
        heics_b = sorted((out_tri / "heic").glob("*.heic"))
        jpgs_b = sorted((out_tri / "jpeg").glob("*.jpg"))
        avifs_b = sorted((out_tri / "avif").glob("*.avif"))
        assert len(heics_b) == 35 and len(jpgs_b) == 35 and len(avifs_b) == 35, (
            f"Expected 35x3 outputs, got {len(heics_b)}/{len(jpgs_b)}/{len(avifs_b)}"
        )
        assert res_b.peak_rss_bytes is not None and res_b.peak_rss_bytes <= PEAK_RSS_LIMIT_BYTES, (
            f"Phase B peak RSS {res_b.peak_rss_bytes} > 4.5 GiB"
        )
        sec_per_img_b = res_b.duration_s / 35.0
        assert sec_per_img_b <= 7.0, f"Phase B throughput {sec_per_img_b:.2f} s/img exceeded 7.0 s/img ceiling"

        # Stratified audit: FF Horiz (DSC02532), FF Portrait (DSC02540), Low-ISO (DSC02555), APS-C Portrait (DSC02556)
        for stem, ew, eh in [("DSC02532", 7008, 4672), ("DSC02540", 4672, 7008), ("DSC02555", 7008, 4672), ("DSC02556", 3072, 4608)]:
            assert_heic_compliant(ctx, out_tri / "heic" / f"{stem}_HDR.heic", expect_w=ew, expect_h=eh)
            assert_jpeg_compliant(ctx, out_tri / "jpeg" / f"{stem}_HDR.jpg", expect_w=ew, expect_h=eh)
            assert_avif_compliant(ctx, out_tri / "avif" / f"{stem}_HDR.avif", expect_grid=True, expect_w=ew, expect_h=eh)

        ctx.note(
            f"T4-01 35-ARW Benchmark: PhaseA={sec_per_img_a:.2f}s/img RSS={res_a.peak_rss_bytes/(1024**3):.2f}GiB; "
            f"PhaseB={sec_per_img_b:.2f}s/img RSS={res_b.peak_rss_bytes/(1024**3):.2f}GiB"
        )
        _mirror_to_verify_dir(ctx, out_tri, "tri_format_35")

    def t4_02(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T4-02")
        samples = ["DSC02532.ARW", "DSC02555.ARW", "DSC02540.ARW", "DSC02542.ARW", "DSC02556.ARW", "DSC02560.ARW"]
        res = ctx.run_cli([str(ctx.sample_path(s)) for s in samples] + ["--output", str(out), "--preset", "xiaohongshu_jpg", "--verify"])
        assert res.returncode == 0, res.stderr
        jpgs = sorted(out.glob("*.jpg"))
        assert len(jpgs) == 6
        for j in jpgs:
            assert_jpeg_compliant(
                ctx,
                j,
                expected_stops=2.5,
                expect_xmp_hdrgm=True,
                expect_icc_substr="Display P3",
                max_bytes=4_194_304,
                expect_w=1536,
                expect_h=2048,
            )
        _mirror_to_verify_dir(ctx, out, "xiaohongshu_jpg")

    def t4_03(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T4-03")
        samples = ["DSC02532.ARW", "DSC02535.ARW", "DSC02540.ARW", "DSC02556.ARW"]
        res = ctx.run_cli([str(ctx.sample_path(s)) for s in samples] + ["--output", str(out), "--preset", "douyin_hlg_mp4", "--verify"])
        assert res.returncode == 0, res.stderr
        mp4s = sorted(out.glob("*.mp4"))
        assert len(mp4s) == 4
        for m in mp4s:
            assert_hlg_mp4_compliant(ctx, m, allowed_sizes=((1080, 1920), (1080, 1440)))
        _mirror_to_verify_dir(ctx, out, "douyin_hlg_mp4")

    def t4_04(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T4-04")
        samples = [
            ("DSC02532.ARW", 7008, 4672),
            ("DSC02540.ARW", 4672, 7008),
            ("DSC02555.ARW", 7008, 4672),
            ("DSC02556.ARW", 3072, 4608),
        ]
        res = ctx.run_cli([str(ctx.sample_path(s)) for s, _, _ in samples] + ["--output", str(out), "--preset", "tri_format", "--format-subdirs", "--verify"])
        assert res.returncode == 0, res.stderr
        for fname, ew, eh in samples:
            stem = Path(fname).stem
            ih = assert_heic_compliant(ctx, out / "heic" / f"{stem}_HDR.heic", expected_stops=2.5, expect_w=ew, expect_h=eh)
            ij = assert_jpeg_compliant(ctx, out / "jpeg" / f"{stem}_HDR.jpg", expected_stops=2.5, expect_w=ew, expect_h=eh)
            ia = assert_avif_compliant(ctx, out / "avif" / f"{stem}_HDR.avif", expected_stops=2.5, expect_grid=True, expect_w=ew, expect_h=eh)
            hh = ih["imageio"]["contentHeadroom"]
            hj = ij["imageio"]["contentHeadroom"]
            ha = ia["imageio"]["contentHeadroom"]
            assert abs(hh - hj) / hh < 0.02 and abs(hh - ha) / hh < 0.02, (
                f"Parity failure for {stem}: HEIC={hh}, JPG={hj}, AVIF={ha}"
            )
        _mirror_to_verify_dir(ctx, out, "tri_format")

    def t4_05(ctx: RunContext) -> None:
        in_dir = ctx.test_out_dir("T4-05", "in")
        out = ctx.test_out_dir("T4-05", "out")
        (in_dir / "good").mkdir(parents=True, exist_ok=True)
        (in_dir / "sub").mkdir(parents=True, exist_ok=True)
        (in_dir / "bad").mkdir(parents=True, exist_ok=True)
        shutil.copy2(ctx.sample_path("DSC02532.ARW"), in_dir / "good" / "DSC02532.ARW")
        shutil.copy2(ctx.sample_path("DSC02540.ARW"), in_dir / "sub" / "DSC02540.ARW")
        for s, sub in [("DSC02532.HIF", "good"), ("DSC02540.HIF", "sub")]:
            hp = ctx.cfg.sample_dir / s
            if hp.is_file():
                shutil.copy2(hp, in_dir / sub / s)
        (in_dir / "sub" / "notes.txt").write_text("notes", encoding="utf-8")
        corrupt = ctx.ensure_corrupt_arws()
        shutil.copy2(corrupt["truncated"], in_dir / "bad" / "corrupt_trunc.ARW")
        shutil.copy2(corrupt["empty"], in_dir / "bad" / "empty.ARW")

        res = ctx.run_cli([str(in_dir), "--recursive", "--output", str(out), "--preset", "apple_heic", "--json-progress", "--verify"])
        assert res.returncode > 0, f"Expected clean non-zero partial-failure code, got rc={res.returncode}"
        assert_heic_compliant(ctx, out / "DSC02532_HDR.heic", expect_w=7008, expect_h=4672)
        assert_heic_compliant(ctx, out / "DSC02540_HDR.heic", expect_w=4672, expect_h=7008)
        all_out = list(out.glob("*"))
        assert len(all_out) == 2, f"Expected only 2 valid HEICs, got {[p.name for p in all_out]}"
        logs = res.stdout + "\n" + res.stderr
        assert "corrupt_trunc.ARW" in logs and "empty.ARW" in logs, "Expected structured error naming corrupt ARWs"

    def t4_06(ctx: RunContext) -> None:
        assert ctx.cfg.app_bundle is not None and ctx.cfg.app_bundle.is_dir(), "Chiaro.app not found"
        assert ctx.cfg.cli_bin is not None
        info = check_app_bundle(ctx.cfg.tools, ctx.cfg.app_bundle)
        assert info["ok"], f"Chiaro.app bundle check failed: {info['errors']}"
        assert info["shaders_metal_files"], "Shaders.metal missing in Chiaro.app Resources"
        assert_zero_gpl(ctx, ctx.cfg.cli_bin, check_symbols=True)
        assert_zero_gpl(ctx, Path(info["executable"]), check_symbols=True)

        proc = subprocess.Popen([info["executable"]], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            time.sleep(2.5)
            rc = proc.poll()
            assert rc is None, f"Chiaro exited prematurely rc={rc}"
        finally:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()

    def t4_07(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T4-07")
        samples = ["DSC02532.ARW", "DSC02540.ARW", "DSC02556.ARW"]
        res = ctx.run_cli([str(ctx.sample_path(s)) for s in samples] + ["--output", str(out), "--preset", "tri_format", "--custom-rendered-hdr", "--verify"])
        assert res.returncode == 0, res.stderr
        for stem in ("DSC02532", "DSC02540", "DSC02556"):
            assert_heic_compliant(ctx, out / f"{stem}_HDR.heic", expect_custom_rendered=3)
            assert_jpeg_compliant(ctx, out / f"{stem}_HDR.jpg", max_app1_bytes=16384, expect_custom_rendered=3)
            assert_avif_compliant(ctx, out / f"{stem}_HDR.avif", expect_grid=True, expect_custom_rendered=3)

    def t4_08(ctx: RunContext) -> None:
        out_a = ctx.test_out_dir("T4-08", "compat_libraw")
        out_b = ctx.test_out_dir("T4-08", "native_ciraw9")
        inputs = [str(ctx.sample_path("DSC02532.ARW")), str(ctx.sample_path("DSC02540.ARW"))]
        ra = ctx.run_cli(inputs + ["--output", str(out_a), "--preset", "apple_heic_compat", "--backend", "libraw", "--verify"])
        rb = ctx.run_cli(inputs + ["--output", str(out_b), "--preset", "apple_heic", "--backend", "ciraw9", "--verify"])
        assert ra.returncode == 0 and rb.returncode == 0
        for stem, ew, eh in [("DSC02532", 7008, 4672), ("DSC02540", 4672, 7008)]:
            assert_heic_compliant(ctx, out_a / f"{stem}_HDR.heic", expected_stops=2.5, expect_legacy_gm=True, expect_w=ew, expect_h=eh)
            assert_heic_compliant(ctx, out_b / f"{stem}_HDR.heic", expected_stops=2.5, expect_legacy_gm=False, expect_w=ew, expect_h=eh)

    tests.extend([
        TestCase("T4-01", 4, "Scenario", "Full 35-ARW Batch Throughput & Peak RSS Benchmark", t4_01, "/usr/bin/time -l 35-ARW Dual & Tri-Format Batch"),
        TestCase("T4-02", 4, "Scenario", "Xiaohongshu 3:4 Carousel Export (6 ARWs -> 1536x2048 <=4MB)", t4_02, "chiaro 6 mixed ARWs --preset xiaohongshu_jpg"),
        TestCase("T4-03", 4, "Scenario", "Douyin 10-bit HLG MP4 Social Reel Export", t4_03, "chiaro 4 mixed ARWs --preset douyin_hlg_mp4"),
        TestCase("T4-04", 4, "Scenario", "Multi-Platform Tri-Format Archive (<2% Headroom Parity)", t4_04, "chiaro 4 representative ARWs --preset tri_format --format-subdirs"),
        TestCase("T4-05", 4, "Scenario", "Mixed Faulty + Real Folder Ingestion Workflow", t4_05, "chiaro mixed good/bad/HIF/txt folder --recursive"),
        TestCase("T4-06", 4, "Scenario", "Chiaro.app CodeSign, License Audit & Launch Smoke Test", t4_06, "Chiaro.app Info.plist + codesign + otool/nm + launch"),
        TestCase("T4-07", 4, "Scenario", "Cross-Format EXIF & Metadata Preservation End-to-End Audit", t4_07, "chiaro 3 ARWs --preset tri_format --custom-rendered-hdr"),
        TestCase("T4-08", 4, "Scenario", "Legacy iOS 14-17 Dual-Write vs Native ciraw9 Workflow", t4_08, "apple_heic_compat (libraw) vs apple_heic (ciraw9)"),
    ])

    assert len(tests) == 8, f"Expected 8 Tier 4 tests, got {len(tests)}"
    return tests

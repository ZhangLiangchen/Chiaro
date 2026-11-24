"""Tier 3 Cross-Feature Pairwise Combinatorial E2E Tests (16 distinct tests: T3-01..T3-16)."""

from __future__ import annotations

import hashlib
import json
import shutil
from pathlib import Path
from typing import List

from probes.cli_probes import probe_exiftool
from tests.common import (
    RunContext,
    TestCase,
    assert_avif_compliant,
    assert_heic_compliant,
    assert_hlg_mp4_compliant,
    assert_jpeg_compliant,
    parse_ndjson_lines,
)


def _sha256(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def get_tests() -> List[TestCase]:
    tests: List[TestCase] = []

    def t3_01(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T3-01")
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--output", str(out), "--preset", "apple_heic", "--backend", "libraw", "--verify"])
        assert res.returncode == 0, res.stderr
        assert_heic_compliant(ctx, out / "DSC02532_HDR.heic", expected_stops=2.5, expect_legacy_gm=False, expect_w=7008, expect_h=4672)

    def t3_02(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T3-02")
        res = ctx.run_cli([str(ctx.sample_path("DSC02540.ARW")), "--output", str(out), "--preset", "xiaohongshu_jpg", "--backend", "libraw", "--verify"])
        assert res.returncode == 0, res.stderr
        assert_jpeg_compliant(ctx, out / "DSC02540_HDR.jpg", expected_stops=2.5, expect_xmp_hdrgm=True, max_bytes=4_194_304, expect_w=1536, expect_h=2048)

    def t3_03(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T3-03")
        res = ctx.run_cli([str(ctx.sample_path("DSC02555.ARW")), "--output", str(out), "--preset", "apple_heic", "--backend", "ciraw9", "--verify"])
        assert res.returncode == 0, res.stderr
        assert_heic_compliant(ctx, out / "DSC02555_HDR.heic", expected_stops=2.5, expect_w=7008, expect_h=4672)

    def t3_04(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T3-04")
        res = ctx.run_cli([str(ctx.sample_path("DSC02556.ARW")), "--output", str(out), "--preset", "avif_archive", "--backend", "ciraw9", "--verify"])
        assert res.returncode == 0, res.stderr
        assert_avif_compliant(ctx, out / "DSC02556_HDR.avif", expected_stops=2.5, expect_grid=True, expect_w=3072, expect_h=4608)

    def t3_05(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T3-05")
        res = ctx.run_cli([str(ctx.sample_path("DSC02541.ARW")), "--output", str(out), "--preset", "douyin_hlg_mp4", "--backend", "ciraw9", "--verify"])
        assert res.returncode == 0, res.stderr
        assert_hlg_mp4_compliant(ctx, out / "DSC02541_HDR.mp4")

    def t3_06(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T3-06")
        res = ctx.run_cli([str(ctx.sample_path("DSC02557.ARW")), "--output", str(out), "--preset", "douyin_hlg_mp4", "--backend", "libraw", "--verify"])
        assert res.returncode == 0, res.stderr
        assert_hlg_mp4_compliant(ctx, out / "DSC02557_HDR.mp4")

    def t3_07(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T3-07")
        res = ctx.run_cli([str(ctx.sample_path("DSC02533.ARW")), "--output", str(out), "--preset", "apple_heic_compat", "--verify"])
        assert res.returncode == 0, res.stderr
        assert_heic_compliant(ctx, out / "DSC02533_HDR.heic", expected_stops=2.5, expect_legacy_gm=True)

    def t3_08(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T3-08")
        res = ctx.run_cli([str(ctx.sample_path("DSC02533.ARW")), "--output", str(out), "--preset", "apple_heic", "--verify"])
        assert res.returncode == 0, res.stderr
        assert_heic_compliant(ctx, out / "DSC02533_HDR.heic", expected_stops=2.5, expect_legacy_gm=False)

    def t3_09(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T3-09")
        res = ctx.run_cli([str(ctx.sample_path("DSC02534.ARW")), "--output", str(out), "--preset", "xiaohongshu_jpg", "--verify"])
        assert res.returncode == 0, res.stderr
        assert_jpeg_compliant(ctx, out / "DSC02534_HDR.jpg", expected_stops=2.5, expect_xmp_hdrgm=True, max_bytes=4_194_304)

    def t3_10(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T3-10")
        pj = ctx.write_preset_json(
            "t3_10_jpg_3ch",
            {"outputFormats": ["jpeg"], "bitDepth": 8, "gainMapChannels": "rgb3ch", "targetHeadroomStops": 2.5},
            compat_overrides={"writeUltrahdrXMP": False},
        )
        res = ctx.run_cli([str(ctx.sample_path("DSC02534.ARW")), "--output", str(out), "--preset-file", str(pj), "--verify"])
        assert res.returncode == 0, res.stderr
        assert_jpeg_compliant(ctx, out / "DSC02534_HDR.jpg", expected_stops=2.5, expect_xmp_hdrgm=False)

    def t3_11(ctx: RunContext) -> None:
        out1 = ctx.test_out_dir("T3-11", "1ch")
        out3 = ctx.test_out_dir("T3-11", "3ch")
        p1 = ctx.write_preset_json("t3_11_avif_1ch", {"outputFormats": ["avif"], "gainMapChannels": "mono1ch"})
        r1 = ctx.run_cli([str(ctx.sample_path("DSC02535.ARW")), "--output", str(out1), "--preset-file", str(p1), "--verify"])
        r3 = ctx.run_cli([str(ctx.sample_path("DSC02535.ARW")), "--output", str(out3), "--preset", "avif_archive", "--verify"])
        assert r1.returncode == 0 and r3.returncode == 0
        assert_avif_compliant(ctx, out1 / "DSC02535_HDR.avif", expect_grid=True, expect_gm_yuv="YUV400")
        assert_avif_compliant(ctx, out3 / "DSC02535_HDR.avif", expect_grid=True, expect_gm_yuv="YUV420")

    def t3_12(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T3-12")
        delta = ctx.fixtures_dir / "t3_12_delta.json"
        delta.write_text(
            json.dumps(
                {
                    "DSC02532": {"targetHeadroomStopsOverride": 2.0, "cropAspectOverride": "3:4", "exposureEVDelta": -0.5},
                },
                indent=2,
            ),
            encoding="utf-8",
        )
        res = ctx.run_cli([
            str(ctx.sample_path("DSC02532.ARW")),
            str(ctx.sample_path("DSC02536.ARW")),
            "--output", str(out),
            "--preset", "tri_format",
            "--delta-file", str(delta),
            "--verify",
        ])
        assert res.returncode == 0, res.stderr
        # DSC02532: 3:4 aspect & 2.0 EV headroom across all 3 formats
        h32 = assert_heic_compliant(ctx, out / "DSC02532_HDR.heic", expected_stops=2.0)
        j32 = assert_jpeg_compliant(ctx, out / "DSC02532_HDR.jpg", expected_stops=2.0)
        a32 = assert_avif_compliant(ctx, out / "DSC02532_HDR.avif", expected_stops=2.0, expect_grid=True)
        for info in (h32, j32, a32):
            w, h = info["imageio"]["pixelWidth"], info["imageio"]["pixelHeight"]
            assert abs(w / h - 0.75) < 0.01, f"Expected 3:4 on DSC02532, got {w}x{h}"

        # DSC02536: baseline 7008x4672 & 2.5 EV headroom across all 3 formats
        assert_heic_compliant(ctx, out / "DSC02536_HDR.heic", expected_stops=2.5, expect_w=7008, expect_h=4672)
        assert_jpeg_compliant(ctx, out / "DSC02536_HDR.jpg", expected_stops=2.5, expect_w=7008, expect_h=4672)
        assert_avif_compliant(ctx, out / "DSC02536_HDR.avif", expected_stops=2.5, expect_grid=True, expect_w=7008, expect_h=4672)

    def t3_13(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T3-13")
        res = ctx.run_cli([
            str(ctx.sample_path("DSC02532.ARW")),
            str(ctx.sample_path("DSC02540.ARW")),
            "--output", str(out),
            "--preset", "avif_archive",
            "--avif-codec", "svt-av1",
            "--verify",
        ])
        assert res.returncode == 0, res.stderr
        assert_avif_compliant(ctx, out / "DSC02532_HDR.avif", expect_grid=True, expect_w=7008, expect_h=4672)
        assert_avif_compliant(ctx, out / "DSC02540_HDR.avif", expect_grid=True, expect_w=4672, expect_h=7008)

    def t3_14(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T3-14")
        res = ctx.run_cli([
            str(ctx.sample_path("DSC02532.ARW")),
            str(ctx.sample_path("DSC02540.ARW")),
            "--output", str(out),
            "--preset", "avif_archive",
            "--avif-codec", "libaom",
            "--verify",
        ])
        assert res.returncode == 0, res.stderr
        assert_avif_compliant(ctx, out / "DSC02532_HDR.avif", expect_grid=True, expect_w=7008, expect_h=4672)
        assert_avif_compliant(ctx, out / "DSC02540_HDR.avif", expect_grid=True, expect_w=4672, expect_h=7008)

    def t3_15(ctx: RunContext) -> None:
        in_dir = ctx.test_out_dir("T3-15", "in")
        out = ctx.test_out_dir("T3-15", "out")
        (in_dir / "a").mkdir(parents=True, exist_ok=True)
        (in_dir / "b").mkdir(parents=True, exist_ok=True)
        shutil.copy2(ctx.sample_path("DSC02532.ARW"), in_dir / "a" / "DSC02532.ARW")
        shutil.copy2(ctx.sample_path("DSC02540.ARW"), in_dir / "b" / "DSC02540.ARW")
        hif = ctx.cfg.sample_dir / "DSC02540.HIF"
        if hif.is_file():
            shutil.copy2(hif, in_dir / "b" / "DSC02540.HIF")

        args = [
            str(in_dir),
            "--recursive",
            "--output", str(out),
            "--preset", "tri_format",
            "--format-subdirs",
            "--naming", "{name}_c.{ext}",
            "--on-conflict", "auto-number",
            "--json-progress",
            "--custom-rendered-hdr",
            "--verify",
        ]
        r1 = ctx.run_cli(args)
        assert r1.returncode == 0, r1.stderr
        assert parse_ndjson_lines(r1.stdout + "\n" + r1.stderr)
        first_set = [
            out / "heic" / "DSC02532_c.heic",
            out / "jpeg" / "DSC02532_c.jpg",
            out / "avif" / "DSC02532_c.avif",
            out / "heic" / "DSC02540_c.heic",
            out / "jpeg" / "DSC02540_c.jpg",
            out / "avif" / "DSC02540_c.avif",
        ]
        hashes_before = {p: _sha256(p) for p in first_set}
        for p in first_set:
            assert p.is_file(), f"Missing Run 1 output: {p}"
            ex = probe_exiftool(ctx.cfg.tools, p)
            cr = ex.raw_dict.get("ExifIFD:CustomRendered")
            assert str(cr) in ("3", "Custom", "HDR (original saved)"), f"CustomRendered!=3 on {p.name}: {cr!r}"

        r2 = ctx.run_cli(args)
        assert r2.returncode == 0, r2.stderr
        for p, h in hashes_before.items():
            assert _sha256(p) == h, f"auto-number modified Run 1 file {p}"
        all_files = [p for p in out.rglob("*") if p.is_file()]
        assert len(all_files) == 12, f"Expected 12 total files after 2nd auto-number run, got {len(all_files)}"

    def t3_16(ctx: RunContext) -> None:
        out_a = ctx.test_out_dir("T3-16", "run_a")
        out_b = ctx.test_out_dir("T3-16", "run_b")
        pj = ctx.write_preset_json(
            "t3_16_custom_srgb",
            {
                "outputFormats": ["jpeg"],
                "bitDepth": 8,
                "baseColorSpace": "srgb",
                "gainMapChannels": "mono1ch",
                "cropAspect": "3:4",
                "maxLongEdge": 1920,
            },
            compat_overrides={"writeUltrahdrXMP": True},
            hlg_overrides={"aspect": "3:4", "durationSeconds": 4.0, "fps": 30, "bitrateMbps": 14.0},
        )
        inputs = [str(ctx.sample_path("DSC02532.ARW")), str(ctx.sample_path("DSC02556.ARW"))]
        ra = ctx.run_cli(inputs + ["--output", str(out_a), "--preset-file", str(pj), "--verify"])
        assert ra.returncode == 0, ra.stderr
        for stem in ("DSC02532", "DSC02556"):
            assert_jpeg_compliant(ctx, out_a / f"{stem}_HDR.jpg", expect_icc_substr="sRGB", expect_w=1440, expect_h=1920)

        rb = ctx.run_cli(inputs + ["--output", str(out_b), "--preset-file", str(pj), "--formats", "jpeg,mp4", "--verify"])
        assert rb.returncode == 0, rb.stderr
        for stem in ("DSC02532", "DSC02556"):
            assert_jpeg_compliant(ctx, out_b / f"{stem}_HDR.jpg", expect_icc_substr="sRGB", expect_w=1440, expect_h=1920)
            assert_hlg_mp4_compliant(ctx, out_b / f"{stem}_HDR.mp4", allowed_sizes=((1080, 1440),))

    tests.extend([
        TestCase("T3-01", 3, "Pairwise", "libraw x Horizontal x HEIC 3ch", t3_01, "chiaro DSC02532.ARW --preset apple_heic --backend libraw"),
        TestCase("T3-02", 3, "Pairwise", "libraw x Rotate270 x JPEG 1ch", t3_02, "chiaro DSC02540.ARW --preset xiaohongshu_jpg --backend libraw"),
        TestCase("T3-03", 3, "Pairwise", "ciraw9 x Horizontal x HEIC", t3_03, "chiaro DSC02555.ARW --preset apple_heic --backend ciraw9"),
        TestCase("T3-04", 3, "Pairwise", "ciraw9 x Rotate270 x AVIF 14MP Grid", t3_04, "chiaro DSC02556.ARW --preset avif_archive --backend ciraw9"),
        TestCase("T3-05", 3, "Pairwise", "ciraw9 x Rotate270 x Douyin HLG MP4", t3_05, "chiaro DSC02541.ARW --preset douyin_hlg_mp4 --backend ciraw9"),
        TestCase("T3-06", 3, "Pairwise", "libraw x Rotate270 x Douyin HLG MP4", t3_06, "chiaro DSC02557.ARW --preset douyin_hlg_mp4 --backend libraw"),
        TestCase("T3-07", 3, "Pairwise", "1ch GM x HEIC Dual-Write (compat)", t3_07, "chiaro DSC02533.ARW --preset apple_heic_compat"),
        TestCase("T3-08", 3, "Pairwise", "3ch GM x HEIC Pure ISO", t3_08, "chiaro DSC02533.ARW --preset apple_heic"),
        TestCase("T3-09", 3, "Pairwise", "1ch GM x JPEG Ultra HDR XMP", t3_09, "chiaro DSC02534.ARW --preset xiaohongshu_jpg"),
        TestCase("T3-10", 3, "Pairwise", "3ch GM x JPEG Pure ISO (No hdrgm XMP)", t3_10, "chiaro DSC02534.ARW --preset-file preset_jpg_3ch.json"),
        TestCase("T3-11", 3, "Pairwise", "1ch YUV400 vs 3ch YUV420 GM x AVIF", t3_11, "chiaro DSC02535.ARW 1ch vs 3ch AVIF"),
        TestCase("T3-12", 3, "Pairwise", "--delta-file x tri_format", t3_12, "chiaro DSC02532+DSC02536 --preset tri_format --delta-file"),
        TestCase("T3-13", 3, "Pairwise", "SVT-AV1 x Landscape & Portrait Grid", t3_13, "chiaro DSC02532+DSC02540 --avif-codec svt-av1"),
        TestCase("T3-14", 3, "Pairwise", "libaom x Landscape & Portrait Grid", t3_14, "chiaro DSC02532+DSC02540 --avif-codec libaom"),
        TestCase("T3-15", 3, "Pairwise", "Recursive+Subdirs+Naming+AutoNum+JSON+HIF", t3_15, "chiaro recursive tri_format x2 runs auto-number"),
        TestCase("T3-16", 3, "Pairwise", "Custom sRGB 3:4 Preset + --formats jpeg,mp4", t3_16, "chiaro custom srgb preset + --formats jpeg,mp4"),
    ])

    assert len(tests) == 16, f"Expected 16 Tier 3 tests, got {len(tests)}"
    return tests

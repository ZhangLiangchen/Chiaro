"""Tier 3 Chiaro v1.1 Pairwise Combinatorial E2E Tests (12 tests: T3-V11-01..T3-V11-12)."""

from __future__ import annotations

import json
import shutil
from pathlib import Path
from typing import List

from probes.cli_probes import (
    build_v11_sidecar,
    extract_job_decoded_events,
    measure_highlight_magenta_fraction,
    measure_region_noise_variance,
    write_sidecar,
)
from tests.common import (
    RunContext,
    TestCase,
    assert_avif_compliant,
    assert_heic_compliant,
    assert_hlg_mp4_compliant,
    assert_jpeg_compliant,
)
from tests.tier1_v11 import CUSTOM_A075_LENSFUN_XML


def get_tests() -> List[TestCase]:
    tests: List[TestCase] = []

    def t3_v11_01(ctx: RunContext) -> None:
        arw = str(ctx.sample_path("DSC02533.ARW"))
        out = ctx.test_out_dir("T3-V11-01", "auto")
        out_off = ctx.test_out_dir("T3-V11-01", "off")
        r = ctx.run_cli([
            arw, "--demosaic", "lmmse", "--denoise", "auto",
            "--lens-correction", "embedded", "--tone-mapper", "sigmoid",
            "--preset", "apple_heic", "--no-sidecar", "--json-progress", "-o", str(out),
        ])
        r_off = ctx.run_cli([
            arw, "--demosaic", "lmmse", "--denoise", "off",
            "--lens-correction", "embedded", "--tone-mapper", "sigmoid",
            "--preset", "apple_heic", "--no-sidecar", "-o", str(out_off),
        ])
        assert r.returncode == 0 and r_off.returncode == 0
        jd = extract_job_decoded_events(r.stdout)
        assert len(jd) == 1 and jd[0].get("demosaicUsed") == "lmmse" and jd[0].get("opticsSource") == "embedded_arw"

        heic = out / "DSC02533_HDR.heic"
        assert_heic_compliant(ctx, heic, expected_stops=2.5)
        nv_on = measure_region_noise_variance(ctx.cfg.tools, heic, max_dim=1024)
        nv_off = measure_region_noise_variance(ctx.cfg.tools, out_off / "DSC02533_HDR.heic", max_dim=1024)
        assert nv_on["chroma_var"] < nv_off["chroma_var"], f"Expected lower shadow chroma noise: {nv_on} vs {nv_off}"
        mag = measure_highlight_magenta_fraction(ctx.cfg.tools, heic, max_dim=1024)
        assert mag["magenta_fraction"] < 0.01, f"Magenta highlight clipping detected: {mag}"

    def t3_v11_02(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T3-V11-02")
        r = ctx.run_cli([
            str(ctx.sample_path("DSC02556.ARW")),
            "--demosaic", "amaze",
            "--lens-correction", "embedded",
            "--clarity", "50",
            "--sharpness", "60",
            "--preset", "xiaohongshu_jpg",
            "--no-sidecar",
            "--json-progress",
            "-o", str(out),
        ])
        assert r.returncode == 0, r.stderr
        jd = extract_job_decoded_events(r.stdout)
        assert len(jd) == 1 and jd[0].get("opticsSource") == "embedded_arw"
        assert_jpeg_compliant(
            ctx,
            out / "DSC02556_HDR.jpg",
            expected_stops=2.5,
            expect_xmp_hdrgm=True,
            max_bytes=4_194_304,
            expect_w=1536,
            expect_h=2048,
        )

    def t3_v11_03(ctx: RunContext) -> None:
        in_dir = ctx.test_out_dir("T3-V11-03", "in")
        arw = in_dir / "DSC02532.ARW"
        shutil.copy2(ctx.sample_path("DSC02532.ARW"), arw)
        write_sidecar(
            arw,
            build_v11_sidecar(
                optics={"enabled": True, "source": "lensfun", "lensfunLensOverride": "E 28-200mm F2.8-5.6 A071"}
            ),
        )
        out = ctx.test_out_dir("T3-V11-03", "out")
        r = ctx.run_cli([
            str(arw),
            "--demosaic", "dcb",
            "--lens-correction", "lensfun",
            "--lens-vignetting-strength", "50",
            "--preset", "avif_archive",
            "--avif-codec", "svt-av1",
            "--json-progress",
            "-o", str(out),
        ])
        assert r.returncode == 0, r.stderr
        jd = extract_job_decoded_events(r.stdout)
        assert len(jd) == 1 and jd[0].get("demosaicUsed") == "dcb" and jd[0].get("opticsSource") == "lensfun"
        assert_avif_compliant(ctx, out / "DSC02532_HDR.avif", expected_stops=2.5, expect_grid=True, expect_w=7008, expect_h=4672)

    def t3_v11_04(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T3-V11-04")
        r = ctx.run_cli([
            str(ctx.sample_path("DSC02540.ARW")),
            "--demosaic", "dht",
            "--lens-correction", "embedded",
            "--tone-mapper", "sigmoid",
            "--preset", "douyin_hlg_mp4",
            "--no-sidecar",
            "--json-progress",
            "-o", str(out),
        ])
        assert r.returncode == 0, r.stderr
        jd = extract_job_decoded_events(r.stdout)
        assert len(jd) == 1 and jd[0].get("demosaicUsed") == "dht"
        assert_hlg_mp4_compliant(ctx, out / "DSC02540_HDR.mp4", allowed_sizes=((1080, 1920),))

    def t3_v11_05(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T3-V11-05")
        r = ctx.run_cli([
            str(ctx.sample_path("DSC02555.ARW")),
            "--demosaic", "ahd",
            "--lens-correction", "off",
            "--denoise", "off",
            "--tone-mapper", "neutral",
            "--preset", "tri_format",
            "--format-subdirs",
            "--no-sidecar",
            "--json-progress",
            "-o", str(out),
        ])
        assert r.returncode == 0, r.stderr
        jd = extract_job_decoded_events(r.stdout)
        assert len(jd) == 1 and jd[0].get("demosaicUsed") == "ahd" and jd[0].get("opticsSource") == "none"
        assert_heic_compliant(ctx, out / "heic" / "DSC02555_HDR.heic", expected_stops=2.5)
        assert_jpeg_compliant(ctx, out / "jpeg" / "DSC02555_HDR.jpg", expected_stops=2.5)
        assert_avif_compliant(ctx, out / "avif" / "DSC02555_HDR.avif", expected_stops=2.5, expect_grid=True)

    def t3_v11_06(ctx: RunContext) -> None:
        in_dir = ctx.test_out_dir("T3-V11-06", "in")
        a1 = in_dir / "DSC02532.ARW"
        a2 = in_dir / "DSC02536.ARW"
        shutil.copy2(ctx.sample_path("DSC02532.ARW"), a1)
        shutil.copy2(ctx.sample_path("DSC02536.ARW"), a2)
        write_sidecar(a1, build_v11_sidecar(preset_id="apple_heic", demosaic="lmmse", delta={"clarityOverride": -40.0}))

        delta_f = ctx.test_out_dir("T3-V11-06", "cfg") / "delta.json"
        delta_f.write_text(json.dumps({"DSC02532.ARW": {"exposureEVDelta": 0.25}}), encoding="utf-8")

        out = ctx.test_out_dir("T3-V11-06", "out")
        r = ctx.run_cli([
            str(in_dir),
            "--delta-file", str(delta_f),
            "--tone-mapper", "sigmoid",
            "--clarity", "30",
            "--preset", "tri_format",
            "--format-subdirs",
            "--json-progress",
            "-o", str(out),
        ])
        assert r.returncode == 0, r.stderr
        jd = {Path(ev["source"]).name: ev for ev in extract_job_decoded_events(r.stdout)}
        assert jd["DSC02532.ARW"].get("demosaicUsed") == "lmmse"
        assert jd["DSC02536.ARW"].get("demosaicUsed") == "amaze"
        for stem in ("DSC02532", "DSC02536"):
            assert_heic_compliant(ctx, out / "heic" / f"{stem}_HDR.heic", expected_stops=2.5)
            assert_jpeg_compliant(ctx, out / "jpeg" / f"{stem}_HDR.jpg", expected_stops=2.5)
            assert_avif_compliant(ctx, out / "avif" / f"{stem}_HDR.avif", expected_stops=2.5, expect_grid=True)

    def t3_v11_07(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T3-V11-07")
        r = ctx.run_cli([
            str(ctx.sample_path("DSC02533.ARW")),
            "--clarity", "-50",
            "--sharpness", "0",
            "--denoise", "auto",
            "--denoise-chroma", "100",
            "--denoise-luma", "80",
            "--tone-mapper", "opendrt",
            "--preset", "douyin_jpg",
            "--no-sidecar",
            "-o", str(out),
        ])
        assert r.returncode == 0, r.stderr
        pj = json.loads((ctx.cfg.repo_root / "Presets" / "douyin_jpg.json").read_text(encoding="utf-8"))
        assert_jpeg_compliant(
            ctx,
            out / "DSC02533_HDR.jpg",
            expected_stops=float(pj["targetHeadroomStops"]),
            expect_xmp_hdrgm=True,
            expect_icc_substr="sRGB" if pj.get("baseColorSpace") == "srgb" else "Display P3",
            max_bytes=int(pj["targetMaxFileBytes"]),
        )

    def t3_v11_08(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T3-V11-08")
        r = ctx.run_cli([
            str(ctx.sample_path("DSC02532.ARW")),
            "--backend", "ciraw9",
            "--lens-correction", "embedded",
            "--tone-mapper", "sigmoid",
            "--preset", "apple_heic_compat",
            "--no-sidecar",
            "--json-progress",
            "-o", str(out),
        ])
        assert r.returncode == 0, r.stderr
        assert_heic_compliant(ctx, out / "DSC02532_HDR.heic", expected_stops=2.5, expect_legacy_gm=True)

    def t3_v11_09(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T3-V11-09")
        r = ctx.run_cli([
            str(ctx.sample_path("DSC02540.ARW")),
            "--lens-correction", "embedded",
            "--lens-distortion", "off",
            "--lens-tca", "on",
            "--lens-vignetting", "on",
            "--preset", "avif_archive",
            "--avif-codec", "libaom",
            "--no-sidecar",
            "-o", str(out),
        ])
        assert r.returncode == 0, r.stderr
        assert_avif_compliant(ctx, out / "DSC02540_HDR.avif", expected_stops=2.5, expect_grid=True, expect_w=4672, expect_h=7008)

    def t3_v11_10(ctx: RunContext) -> None:
        fake_home = ctx.test_out_dir("T3-V11-10", "home")
        lf_dir = fake_home / "Library" / "Application Support" / "Chiaro" / "Lensfun"
        lf_dir.mkdir(parents=True, exist_ok=True)
        (lf_dir / "custom_a075.xml").write_text(CUSTOM_A075_LENSFUN_XML, encoding="utf-8")

        out = ctx.test_out_dir("T3-V11-10", "out")
        r = ctx.run_cli(
            [
                str(ctx.sample_path("DSC02556.ARW")),
                "--lens-correction", "lensfun",
                "--clarity", "40",
                "--sharpness", "40",
                "--no-sidecar",
                "--json-progress",
                "-o", str(out),
            ],
            env_override={"HOME": str(fake_home), "CFFIXED_USER_HOME": str(fake_home)},
        )
        assert r.returncode == 0, r.stderr
        jd = extract_job_decoded_events(r.stdout)
        assert len(jd) == 1 and jd[0].get("opticsSource") == "lensfun", f"Expected opticsSource=lensfun: {jd}"
        assert_heic_compliant(ctx, out / "DSC02556_HDR.heic", expected_stops=2.5, expect_w=3072, expect_h=4608)

    def t3_v11_11(ctx: RunContext) -> None:
        in_dir = ctx.test_out_dir("T3-V11-11", "in")
        sub_dir = in_dir / "sub"
        sub_dir.mkdir(parents=True, exist_ok=True)
        a1 = in_dir / "DSC02532.ARW"
        a2 = sub_dir / "DSC02540.ARW"
        shutil.copy2(ctx.sample_path("DSC02532.ARW"), a1)
        shutil.copy2(ctx.sample_path("DSC02540.ARW"), a2)
        write_sidecar(a1, build_v11_sidecar(preset_id="apple_heic"))
        (in_dir / "DSC02532.HIF").write_bytes(b"hif")

        out = ctx.test_out_dir("T3-V11-11", "out")
        r = ctx.run_cli([
            str(in_dir),
            "--recursive",
            "--format-subdirs",
            "--naming", "{name}_{preset}.{ext}",
            "--preset", "tri_format",
            "-o", str(out),
        ])
        assert r.returncode == 0, r.stderr
        heics = sorted((out / "heic").glob("*.heic"))
        jpgs = sorted((out / "jpeg").glob("*.jpg"))
        avifs = sorted((out / "avif").glob("*.avif"))
        assert len(heics) == 2 and len(jpgs) == 2 and len(avifs) == 2, (
            f"Expected 2x3=6 outputs, got {len(heics)}/{len(jpgs)}/{len(avifs)}"
        )

    def t3_v11_12(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T3-V11-12")
        r = ctx.run_cli([
            str(ctx.sample_path("DSC02533.ARW")),
            "--demosaic", "lmmse",
            "--denoise", "auto",
            "--tone-mapper", "sigmoid",
            "--custom-rendered-hdr",
            "--preset", "tri_format",
            "--no-sidecar",
            "-o", str(out),
        ])
        assert r.returncode == 0, r.stderr
        assert_heic_compliant(ctx, out / "DSC02533_HDR.heic", expected_stops=2.5, expect_custom_rendered=3)
        assert_jpeg_compliant(ctx, out / "DSC02533_HDR.jpg", expected_stops=2.5, expect_custom_rendered=3)
        assert_avif_compliant(ctx, out / "DSC02533_HDR.avif", expected_stops=2.5, expect_grid=True, expect_custom_rendered=3)

    tests.extend([
        TestCase("T3-V11-01", 3, "Pairwise", "LMMSE x ProfiledDenoise x Embedded x Sigmoid x HEIC 3ch", t3_v11_01, "chiaro DSC02533.ARW lmmse+denoise+embedded+sigmoid"),
        TestCase("T3-V11-02", 3, "Pairwise", "AMaZE x Clarity(+50) x Sharpness(60) x Embedded(Rot270) x XHS JPEG", t3_v11_02, "chiaro DSC02556.ARW amaze+clarity50+sharp60 xiaohongshu_jpg"),
        TestCase("T3-V11-03", 3, "Pairwise", "DCB x Lensfun(Override) x Vig(50%) x AVIF SVT-AV1 Grid", t3_v11_03, "chiaro DSC02532.ARW dcb+lensfun A071+vig50 avif_archive"),
        TestCase("T3-V11-04", 3, "Pairwise", "DHT x Embedded x Sigmoid x Douyin HLG MP4 (9:16)", t3_v11_04, "chiaro DSC02540.ARW dht+embedded+sigmoid douyin_hlg_mp4"),
        TestCase("T3-V11-05", 3, "Pairwise", "AHD x Optics(off) x Denoise(off) x Neutral x Tri-Format", t3_v11_05, "chiaro DSC02555.ARW ahd+off+neutral tri_format"),
        TestCase("T3-V11-06", 3, "Pairwise", "Sidecar x --delta-file x CLI Override x Tri-Format", t3_v11_06, "chiaro copied ARWs + sidecar + delta-file + CLI tri_format"),
        TestCase("T3-V11-07", 3, "Pairwise", "Clarity(-50) x Sharpness(0) x Denoise(100/80) x OpenDRT x Douyin JPG", t3_v11_07, "chiaro DSC02533.ARW clarity-50+opendrt douyin_jpg"),
        TestCase("T3-V11-08", 3, "Pairwise", "CIRAWv9 x Embedded x Sigmoid x apple_heic_compat (1ch Dual-Write)", t3_v11_08, "chiaro DSC02532.ARW ciraw9+embedded+sigmoid apple_heic_compat"),
        TestCase("T3-V11-09", 3, "Pairwise", "Embedded x Distortion(off)+TCA(on)+Vig(on) x AVIF libaom Portrait", t3_v11_09, "chiaro DSC02540.ARW distortion off + avif_archive libaom"),
        TestCase("T3-V11-10", 3, "Pairwise", "Custom Lensfun XML (HOME) x Clarity(40) x Sharpness(40) x HEIC", t3_v11_10, "HOME=<custom> chiaro DSC02556.ARW lensfun+clarity40+sharp40"),
        TestCase("T3-V11-11", 3, "Pairwise", "Recursive Dir + .HIF + .chiaro.json + --naming + --format-subdirs", t3_v11_11, "chiaro recursive mixed dir tri_format"),
        TestCase("T3-V11-12", 3, "Pairwise", "High-ISO x LMMSE x ProfiledDenoise x Sigmoid x CustomRendered=3", t3_v11_12, "chiaro DSC02533.ARW --custom-rendered-hdr tri_format"),
    ])

    assert len(tests) == 12, f"Expected 12 Tier 3 v1.1 tests, got {len(tests)}"
    return tests

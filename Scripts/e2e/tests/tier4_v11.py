"""Tier 4 Chiaro v1.1 Real-World End-to-End Scenario Tests (6 tests: T4-V11-01..T4-V11-06)."""

from __future__ import annotations

import hashlib
import json
import shutil
import tarfile
from pathlib import Path
from typing import List

from config import PEAK_RSS_LIMIT_BYTES
from probes.cli_probes import (
    build_v11_sidecar,
    check_app_bundle_v11,
    check_gpl3_compatible_linkage,
    extract_job_decoded_events,
    measure_edge_acutance,
    measure_highlight_magenta_fraction,
    measure_image_diff,
    measure_region_noise_variance,
    probe_binary_strings_and_symbols,
    probe_neutral_canvas_invariant,
    probe_verify_licenses_sbom,
    smoke_launch_app,
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


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _require_app(ctx: RunContext) -> Path:
    assert ctx.cfg.app_bundle is not None and ctx.cfg.app_bundle.is_dir(), (
        "Chiaro.app bundle not found"
    )
    return ctx.cfg.app_bundle


def get_tests() -> List[TestCase]:
    tests: List[TestCase] = []

    def t4_v11_01(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T4-V11-01")
        res = ctx.run_cli(
            [
                str(ctx.cfg.sample_dir),
                "--preset", "apple_heic",
                "--formats", "heic,jpeg",
                "--demosaic", "amaze",
                "--denoise", "auto",
                "--lens-correction", "embedded",
                "--tone-mapper", "sigmoid",
                "--clarity", "20",
                "--sharpness", "25",
                "--no-sidecar",
                "--json-progress",
                "--verify",
                "-o", str(out),
            ],
            measure_rss=True,
            timeout=1800,
        )
        assert res.returncode == 0, f"T4-V11-01 35-ARW batch failed: {res.stderr}"

        heics = sorted(out.glob("*.heic"))
        jpgs = sorted(out.glob("*.jpg"))
        assert len(heics) == 35 and len(jpgs) == 35, f"Expected 35 HEIC + 35 JPEG, got {len(heics)}/{len(jpgs)}"
        assert res.peak_rss_bytes is not None and res.peak_rss_bytes <= PEAK_RSS_LIMIT_BYTES, (
            f"Peak RSS {res.peak_rss_bytes} > 4.5 GiB"
        )
        sec_per_img = res.duration_s / 35.0
        assert sec_per_img <= 4.0, f"Throughput {sec_per_img:.2f} s/img > 4.0 s/img"

        jd_events = extract_job_decoded_events(res.stdout)
        assert len(jd_events) == 35, f"Expected 35 job_decoded events, got {len(jd_events)}"
        for ev in jd_events:
            assert ev.get("demosaicUsed") == "amaze", f"Unexpected demosaicUsed: {ev}"
            assert ev.get("opticsSource") == "embedded_arw", f"Unexpected opticsSource: {ev}"

        for stem, ew, eh in (
            ("DSC02532", 7008, 4672),
            ("DSC02540", 4672, 7008),
            ("DSC02555", 7008, 4672),
            ("DSC02556", 3072, 4608),
        ):
            assert_heic_compliant(ctx, out / f"{stem}_HDR.heic", expected_stops=2.5, expect_w=ew, expect_h=eh)
            assert_jpeg_compliant(ctx, out / f"{stem}_HDR.jpg", expected_stops=2.5, expect_xmp_hdrgm=False, expect_w=ew, expect_h=eh)

    def t4_v11_02(ctx: RunContext) -> None:
        samples = ["DSC02533.ARW", "DSC02543.ARW"]
        out_v11 = ctx.test_out_dir("T4-V11-02", "v11")
        out_base = ctx.test_out_dir("T4-V11-02", "base")

        r_v11 = ctx.run_cli(
            [str(ctx.sample_path(s)) for s in samples]
            + [
                "--demosaic", "lmmse",
                "--denoise", "auto",
                "--lens-correction", "embedded",
                "--tone-mapper", "sigmoid",
                "--clarity", "25",
                "--sharpness", "35",
                "--preset", "tri_format",
                "--format-subdirs",
                "--no-sidecar",
                "-o", str(out_v11),
            ]
        )
        r_base = ctx.run_cli(
            [str(ctx.sample_path(s)) for s in samples]
            + [
                "--demosaic", "ahd",
                "--denoise", "off",
                "--lens-correction", "off",
                "--preset", "apple_heic",
                "--no-sidecar",
                "-o", str(out_base),
            ]
        )
        assert r_v11.returncode == 0 and r_base.returncode == 0

        for s in samples:
            stem = Path(s).stem
            heic_v11 = out_v11 / "heic" / f"{stem}_HDR.heic"
            heic_base = out_base / f"{stem}_HDR.heic"
            assert_heic_compliant(ctx, heic_v11, expected_stops=2.5)
            assert_jpeg_compliant(ctx, out_v11 / "jpeg" / f"{stem}_HDR.jpg", expected_stops=2.5)
            assert_avif_compliant(ctx, out_v11 / "avif" / f"{stem}_HDR.avif", expected_stops=2.5, expect_grid=True)

            nv_v11 = measure_region_noise_variance(ctx.cfg.tools, heic_v11, max_dim=1024)
            nv_base = measure_region_noise_variance(ctx.cfg.tools, heic_base, max_dim=1024)
            assert nv_v11["chroma_var"] <= 0.75 * nv_base["chroma_var"], (
                f"{stem}: night chroma noise variance drop < 25%: v11={nv_v11['chroma_var']}, base={nv_base['chroma_var']}"
            )
            mag = measure_highlight_magenta_fraction(ctx.cfg.tools, heic_v11, max_dim=1024)
            assert mag["magenta_fraction"] < 0.01, f"{stem}: magenta highlight clipping detected: {mag}"

        out_unsharp = ctx.test_out_dir("T4-V11-02", "v11_unsharp")
        r_unsharp = ctx.run_cli(
            [
                str(ctx.sample_path("DSC02533.ARW")),
                "--demosaic", "lmmse",
                "--denoise", "auto",
                "--lens-correction", "embedded",
                "--tone-mapper", "sigmoid",
                "--clarity", "25",
                "--sharpness", "0",
                "--preset", "tri_format",
                "--formats", "heic",
                "--no-sidecar",
                "-o", str(out_unsharp),
            ]
        )
        assert r_unsharp.returncode == 0, r_unsharp.stderr
        ac_v11 = measure_edge_acutance(
            ctx.cfg.tools,
            out_v11 / "heic" / "DSC02533_HDR.heic",
            box_norm=(0.35, 0.35, 0.65, 0.65),
            max_dim=None,
        )
        ac_unsharp = measure_edge_acutance(
            ctx.cfg.tools,
            out_unsharp / "DSC02533_HDR.heic",
            box_norm=(0.35, 0.35, 0.65, 0.65),
            max_dim=None,
        )
        assert ac_v11 > ac_unsharp, (
            f"DSC02533: expected higher 1:1 center-crop acutance with sharpness=35 vs 0 ({ac_v11} <= {ac_unsharp})"
        )

    def t4_v11_03(ctx: RunContext) -> None:
        in_dir = ctx.test_out_dir("T4-V11-03", "in")
        files = ("DSC02532.ARW", "DSC02540.ARW", "DSC02555.ARW", "DSC02556.ARW")
        for fn in files:
            shutil.copy2(ctx.sample_path(fn), in_dir / fn)

        sc1 = write_sidecar(
            in_dir / "DSC02532.ARW",
            build_v11_sidecar(
                preset_id="apple_heic",
                demosaic="lmmse",
                delta={"clarityOverride": 20.0},
                ai_color={
                    "enabled": True,
                    "colorBalanceRGB": {"global": [0.0, 0.0, 0.0]},
                    "toneEqualizer": [0.0] * 8,
                },
            ),
        )
        sc2 = write_sidecar(
            in_dir / "DSC02556.ARW",
            build_v11_sidecar(preset_id="apple_heic", demosaic="dcb", delta={"clarityOverride": 30.0}),
        )
        sha1, sha2 = _sha256(sc1), _sha256(sc2)

        (in_dir / "DSC02532.HIF").write_bytes(b"hif")
        (in_dir / "fake.ARW").mkdir()

        delta_f = ctx.test_out_dir("T4-V11-03", "cfg") / "delta.json"
        delta_f.write_text(json.dumps({"DSC02532.ARW": {"clarityOverride": 60.0}}), encoding="utf-8")

        out = ctx.test_out_dir("T4-V11-03", "out")
        res = ctx.run_cli([
            str(in_dir),
            "--delta-file", str(delta_f),
            "--preset", "tri_format",
            "--format-subdirs",
            "--json-progress",
            "-o", str(out),
        ])
        assert res.returncode == 0, res.stderr
        heics = sorted((out / "heic").glob("*.heic"))
        jpgs = sorted((out / "jpeg").glob("*.jpg"))
        avifs = sorted((out / "avif").glob("*.avif"))
        assert len(heics) == 4 and len(jpgs) == 4 and len(avifs) == 4, (
            f"Expected 4x3=12 outputs, got {len(heics)}/{len(jpgs)}/{len(avifs)}"
        )

        jd = {Path(ev["source"]).name: ev for ev in extract_job_decoded_events(res.stdout)}
        assert jd["DSC02532.ARW"].get("demosaicUsed") == "lmmse"
        assert jd["DSC02556.ARW"].get("demosaicUsed") == "dcb"
        assert jd["DSC02540.ARW"].get("demosaicUsed") == "amaze"
        assert jd["DSC02555.ARW"].get("demosaicUsed") == "amaze"
        for fn in files:
            assert jd[fn].get("opticsSource") == "embedded_arw"
            stem = Path(fn).stem
            assert_heic_compliant(ctx, out / "heic" / f"{stem}_HDR.heic", expected_stops=2.5)
            assert_jpeg_compliant(ctx, out / "jpeg" / f"{stem}_HDR.jpg", expected_stops=2.5)
            assert_avif_compliant(ctx, out / "avif" / f"{stem}_HDR.avif", expected_stops=2.5, expect_grid=True)

        assert _sha256(sc1) == sha1 and _sha256(sc2) == sha2, "CLI mutated sidecar files!"
        assert not list(ctx.cfg.sample_dir.glob("*.chiaro.json"))

    def t4_v11_04(ctx: RunContext) -> None:
        empty_home = ctx.test_out_dir("T4-V11-04", "home_empty")
        custom_home = ctx.test_out_dir("T4-V11-04", "home_custom")
        lf_dir = custom_home / "Library" / "Application Support" / "Chiaro" / "Lensfun"
        lf_dir.mkdir(parents=True, exist_ok=True)
        (lf_dir / "custom_a075.xml").write_text(CUSTOM_A075_LENSFUN_XML, encoding="utf-8")

        inputs = [str(ctx.sample_path("DSC02532.ARW")), str(ctx.sample_path("DSC02556.ARW"))]
        out_a = ctx.test_out_dir("T4-V11-04", "pass_a")
        out_b = ctx.test_out_dir("T4-V11-04", "pass_b")

        ra = ctx.run_cli(
            inputs + ["--lens-correction", "lensfun", "--no-sidecar", "--json-progress", "-o", str(out_a)],
            env_override={"HOME": str(empty_home), "CFFIXED_USER_HOME": str(empty_home)},
            use_sandbox_deny_net=True,
        )
        rb = ctx.run_cli(
            inputs + ["--lens-correction", "lensfun", "--no-sidecar", "--json-progress", "-o", str(out_b)],
            env_override={"HOME": str(custom_home), "CFFIXED_USER_HOME": str(custom_home)},
            use_sandbox_deny_net=True,
        )
        assert ra.returncode == 0 and rb.returncode == 0

        jd_a = {Path(ev["source"]).name: ev for ev in extract_job_decoded_events(ra.stdout)}
        jd_b = {Path(ev["source"]).name: ev for ev in extract_job_decoded_events(rb.stdout)}
        for fn in ("DSC02532.ARW", "DSC02556.ARW"):
            assert jd_a[fn].get("opticsSource") == "none", f"Pass A expected none: {jd_a[fn]}"
            assert jd_b[fn].get("opticsSource") == "lensfun", f"Pass B expected lensfun: {jd_b[fn]}"
            stem = Path(fn).stem
            diff = measure_image_diff(ctx.cfg.tools, out_a / f"{stem}_HDR.heic", out_b / f"{stem}_HDR.heic", max_dim=1024)
            assert diff["rms_diff"] > 0.003, f"Custom Lensfun XML produced negligible optical diff on {fn}: {diff}"

    def t4_v11_05(ctx: RunContext) -> None:
        sbom = probe_verify_licenses_sbom(ctx.cfg.repo_root, require_binaries=True)
        assert sbom["returncode"] == 0 and sbom["all_ok"], f"verify_licenses.sh --require-binaries failed:\n{sbom['stdout']}\n{sbom['stderr']}"

        dist_dir = ctx.cfg.repo_root / "dist"
        sums = dist_dir / "SHA256SUMS.txt"
        assert sums.is_file()
        s_res = ctx.run_cmd(["shasum", "-a", "256", "-c", str(sums)], cwd=dist_dir)
        assert s_res.returncode == 0, s_res.stderr

        app = _require_app(ctx)
        info = check_app_bundle_v11(ctx.cfg.tools, app)
        assert info["ok"], f"Chiaro.app bundle invalid: {info['errors']}"
        app_exe = Path(info["executable"])

        sym_res = probe_binary_strings_and_symbols(
            ctx.cfg.tools,
            app_exe,
            [
                "WorkspaceMode",
                "ParameterDocumentationRegistry",
                "AppLanguage",
                "ChiaroSidecar",
            ],
        )
        assert sym_res["all_found"], f"Missing v1.1 UI symbols: {sym_res['missing']}"

        glass_tokens = [
            "ChiaroGlassContainer",
            "chiaroGlassSurface",
            "chiaroGlassButtonStyle",
            "LiquidGlassSystem",
        ]
        glass_res = probe_binary_strings_and_symbols(ctx.cfg.tools, app_exe, glass_tokens)
        assert any(tok in glass_res["matched"] for tok in glass_tokens), (
            f"Missing ADR-016 Liquid Glass API symbols/strings (checked {glass_tokens})"
        )

        canvas_res = probe_neutral_canvas_invariant(ctx.cfg.tools, app_exe)
        assert canvas_res["ok"], f"Missing #111214 neutral canvas invariant: {canvas_res}"

        for kwargs in (
            {"apple_languages": "en"},
            {"apple_languages": "zh-Hans"},
            {"reduce_transparency": True},
        ):
            sm = smoke_launch_app(app_exe, hold_s=3.0, **kwargs)
            assert sm["ok"], f"Chiaro.app smoke launch failed ({kwargs}): {sm}"

        unpack_dir = ctx.test_out_dir("T4-V11-05", "cli_unpack")
        with tarfile.open(dist_dir / "chiaro-cli-1.1.0-macos-arm64.tar.gz", "r:gz") as tf:
            tf.extractall(unpack_dir, filter="tar")
        reloc_cli = unpack_dir / "chiaro-cli-1.1.0-macos-arm64" / "bin" / "chiaro-cli"
        rep = check_gpl3_compatible_linkage(ctx.cfg.tools, reloc_cli, check_symbols=True, require_self_contained=True)
        assert rep["clean"], f"Relocated CLI linkage violation: {rep}"

        out_cli = ctx.test_out_dir("T4-V11-05", "cli_export")
        ex = ctx.run_cmd(
            [str(reloc_cli), str(ctx.sample_path("DSC02532.ARW")), "--preset", "apple_heic", "--no-sidecar", "-o", str(out_cli)],
            cwd=unpack_dir,
        )
        assert ex.returncode == 0, ex.stderr
        assert_heic_compliant(ctx, out_cli / "DSC02532_HDR.heic", expected_stops=2.5)

    def t4_v11_06(ctx: RunContext) -> None:
        samples = ["DSC02532.ARW", "DSC02540.ARW", "DSC02556.ARW"]
        inputs = [str(ctx.sample_path(s)) for s in samples]
        common_flags = [
            "--demosaic", "lmmse",
            "--denoise", "auto",
            "--lens-correction", "embedded",
            "--tone-mapper", "sigmoid",
            "--clarity", "15",
            "--no-sidecar",
        ]

        out_xhs = ctx.test_out_dir("T4-V11-06", "xhs")
        out_dy = ctx.test_out_dir("T4-V11-06", "douyin")

        rx = ctx.run_cli(inputs + common_flags + ["--preset", "xiaohongshu_jpg", "-o", str(out_xhs)])
        rd = ctx.run_cli(inputs + common_flags + ["--preset", "douyin_hlg_mp4", "-o", str(out_dy)])
        assert rx.returncode == 0 and rd.returncode == 0

        for s in samples:
            stem = Path(s).stem
            assert_jpeg_compliant(
                ctx,
                out_xhs / f"{stem}_HDR.jpg",
                expected_stops=2.5,
                expect_xmp_hdrgm=True,
                max_bytes=4_194_304,
                expect_w=1536,
                expect_h=2048,
            )
            assert_hlg_mp4_compliant(
                ctx,
                out_dy / f"{stem}_HDR.mp4",
                allowed_sizes=((1080, 1920),),
            )

    tests.extend([
        TestCase("T4-V11-01", 4, "Scenario", "Full 35-ARW v1.1 Night-to-Day Batch (RSS <= 4.5 GiB)", t4_v11_01, "/usr/bin/time -l 35 ARWs amaze+denoise+embedded+sigmoid+clarity+sharpness"),
        TestCase("T4-V11-02", 4, "Scenario", "High-ISO Night Quality Workflow (DSC02533 & DSC02543)", t4_v11_02, "lmmse+denoise+sigmoid+clarity+sharpness vs baseline off"),
        TestCase("T4-V11-03", 4, "Scenario", "Mixed Sidecar Directory Resume Workflow", t4_v11_03, "4 copied ARWs + v2/v3 sidecars + --delta-file + tri_format"),
        TestCase("T4-V11-04", 4, "Scenario", "Lensfun Fallback + Custom User XML Workflow (Offline Sandbox)", t4_v11_04, "sandbox-exec empty HOME vs custom XML HOME"),
        TestCase("T4-V11-05", 4, "Scenario", "Full 1.1.0 Release Artifact & Packaged Chiaro.app Acceptance", t4_v11_05, "verify_licenses.sh --require-binaries + dist + Chiaro.app smoke"),
        TestCase("T4-V11-06", 4, "Scenario", "Social Platform v1.1 Quality Export (Xiaohongshu + Douyin HLG MP4)", t4_v11_06, "3 ARWs lmmse+denoise+embedded+sigmoid -> xhs_jpg & douyin_hlg_mp4"),
    ])

    assert len(tests) == 6, f"Expected 6 Tier 4 v1.1 tests, got {len(tests)}"
    return tests

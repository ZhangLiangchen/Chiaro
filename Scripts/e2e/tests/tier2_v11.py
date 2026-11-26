"""Tier 2 Chiaro v1.1 Boundary Value Analysis & Negative E2E Tests (22 tests: T2-V11-01..T2-V11-22)."""

from __future__ import annotations

import json
import shutil
import tarfile
from pathlib import Path
from typing import List

from probes.cli_probes import (
    build_v11_sidecar,
    extract_job_decoded_events,
    measure_corner_center_luma_ratio,
    measure_hdr_linear_stats,
    measure_image_diff,
    write_sidecar,
)
from tests.common import (
    RunContext,
    TestCase,
    assert_heic_compliant,
    assert_hlg_mp4_compliant,
    assert_jpeg_compliant,
)


def _hdr_cache_dir(ctx: RunContext) -> Path:
    return ctx.cfg.work_dir / "bin"


def _assert_cli_rejects(ctx: RunContext, args: List[str], out_dir: Path, label: str) -> None:
    res = ctx.run_cli(args + ["-o", str(out_dir)])
    assert res.returncode != 0, f"{label}: expected non-zero exit, got 0"
    assert res.returncode > 0, f"{label}: terminated by signal {-res.returncode}"
    assert res.stderr.strip(), f"{label}: expected non-empty stderr"
    assert not list(out_dir.iterdir()), f"{label}: expected 0 output files, found {list(out_dir.iterdir())}"


def get_tests() -> List[TestCase]:
    tests: List[TestCase] = []

    def t2_v11_01(ctx: RunContext) -> None:
        arw = str(ctx.sample_path("DSC02532.ARW"))
        for idx, bad in enumerate((["--demosaic", "bilinear"], ["--demosaic", "xtrans"], ["--demosaic", ""], ["--demosaic"])):
            out = ctx.test_out_dir("T2-V11-01", f"c{idx}")
            _assert_cli_rejects(ctx, [arw] + bad, out, f"invalid {bad}")

    def t2_v11_02(ctx: RunContext) -> None:
        arw = str(ctx.sample_path("DSC02533.ARW"))
        for val in ("0", "100"):
            out = ctx.test_out_dir("T2-V11-02", f"ok_{val}")
            res = ctx.run_cli([arw, "--denoise", "auto", "--denoise-chroma", val, "--denoise-luma", val, "--no-sidecar", "-o", str(out)])
            assert res.returncode == 0, f"Valid denoise {val} failed: {res.stderr}"
            assert_heic_compliant(ctx, out / "DSC02533_HDR.heic", expected_stops=2.5)

        bad_cases = [
            ["--denoise", "high"],
            ["--denoise", "coreml"],
            ["--denoise-chroma", "-0.1"],
            ["--denoise-chroma", "100.1"],
            ["--denoise-chroma", "nan"],
            ["--denoise-luma", "-1"],
            ["--denoise-luma", "101"],
            ["--denoise-luma", "abc"],
        ]
        for idx, bad in enumerate(bad_cases):
            out = ctx.test_out_dir("T2-V11-02", f"bad_{idx}")
            _assert_cli_rejects(ctx, [arw] + bad, out, f"invalid {bad}")

    def t2_v11_03(ctx: RunContext) -> None:
        arw = str(ctx.sample_path("DSC02532.ARW"))
        bad_cases = [
            ["--lens-correction", "manual"],
            ["--lens-correction", "adobe"],
            ["--lens-vignetting", "maybe"],
            ["--lens-distortion", "2"],
            ["--lens-tca", ""],
        ]
        for idx, bad in enumerate(bad_cases):
            out = ctx.test_out_dir("T2-V11-03", f"c{idx}")
            _assert_cli_rejects(ctx, [arw] + bad, out, f"invalid {bad}")

    def t2_v11_04(ctx: RunContext) -> None:
        arw = str(ctx.sample_path("DSC02532.ARW"))
        for val in ("0", "100"):
            out = ctx.test_out_dir("T2-V11-04", f"ok_{val}")
            res = ctx.run_cli([arw, "--lens-correction", "embedded", "--lens-vignetting-strength", val, "--no-sidecar", "-o", str(out)])
            assert res.returncode == 0, res.stderr
            assert_heic_compliant(ctx, out / "DSC02532_HDR.heic", expected_stops=2.5)

        for idx, bad_val in enumerate(("-0.1", "100.1", "nan", "xyz")):
            out = ctx.test_out_dir("T2-V11-04", f"bad_{idx}")
            _assert_cli_rejects(ctx, [arw, "--lens-vignetting-strength", bad_val], out, f"vig strength {bad_val}")

    def t2_v11_05(ctx: RunContext) -> None:
        arw = str(ctx.sample_path("DSC02532.ARW"))
        for idx, bad in enumerate((["--tone-mapper", "reinhard"], ["--tone-mapper", "filmic"], ["--tone-mapper", ""], ["--tone-mapper"])):
            out = ctx.test_out_dir("T2-V11-05", f"c{idx}")
            _assert_cli_rejects(ctx, [arw] + bad, out, f"invalid {bad}")

    def t2_v11_06(ctx: RunContext) -> None:
        arw = str(ctx.sample_path("DSC02532.ARW"))
        for val in ("-100", "0", "100"):
            out = ctx.test_out_dir("T2-V11-06", f"ok_{val}")
            res = ctx.run_cli([arw, "--clarity", val, "--no-sidecar", "-o", str(out)])
            assert res.returncode == 0, res.stderr
            heic = out / "DSC02532_HDR.heic"
            assert_heic_compliant(ctx, heic, expected_stops=2.5)
            hdr = measure_hdr_linear_stats(ctx.cfg.tools, heic, _hdr_cache_dir(ctx))
            assert hdr["nanCount"] == 0 and hdr["infCount"] == 0 and hdr["hdrMaxChannel"] > 1.5

        for idx, bad_val in enumerate(("-100.1", "100.1", "nan", "bad")):
            out = ctx.test_out_dir("T2-V11-06", f"bad_{idx}")
            _assert_cli_rejects(ctx, [arw, "--clarity", bad_val], out, f"clarity {bad_val}")

    def t2_v11_07(ctx: RunContext) -> None:
        arw = str(ctx.sample_path("DSC02532.ARW"))
        for val in ("0", "100"):
            out = ctx.test_out_dir("T2-V11-07", f"ok_{val}")
            res = ctx.run_cli([arw, "--sharpness", val, "--no-sidecar", "-o", str(out)])
            assert res.returncode == 0, res.stderr
            heic = out / "DSC02532_HDR.heic"
            assert_heic_compliant(ctx, heic, expected_stops=2.5)
            hdr = measure_hdr_linear_stats(ctx.cfg.tools, heic, _hdr_cache_dir(ctx))
            assert hdr["nanCount"] == 0 and hdr["infCount"] == 0

        for idx, bad_val in enumerate(("-0.1", "100.1", "nan", "bad")):
            out = ctx.test_out_dir("T2-V11-07", f"bad_{idx}")
            _assert_cli_rejects(ctx, [arw, "--sharpness", bad_val], out, f"sharpness {bad_val}")

    def t2_v11_08(ctx: RunContext) -> None:
        arw = str(ctx.sample_path("DSC02532.ARW"))
        isolated_home = ctx.test_out_dir("T2-V11-08", "home")
        out_lf = ctx.test_out_dir("T2-V11-08", "lensfun")
        out_off = ctx.test_out_dir("T2-V11-08", "off")
        r_lf = ctx.run_cli(
            [arw, "--lens-correction", "lensfun", "--no-sidecar", "--json-progress", "-o", str(out_lf)],
            env_override={"HOME": str(isolated_home), "CFFIXED_USER_HOME": str(isolated_home)},
        )
        r_off = ctx.run_cli(
            [arw, "--lens-correction", "off", "--no-sidecar", "-o", str(out_off)],
            env_override={"HOME": str(isolated_home), "CFFIXED_USER_HOME": str(isolated_home)},
        )
        assert r_lf.returncode == 0, r_lf.stderr
        assert r_off.returncode == 0
        jd = extract_job_decoded_events(r_lf.stdout)
        assert len(jd) == 1 and jd[0].get("opticsSource") == "none", f"Expected opticsSource=none for missing A075 DB: {jd}"
        heic_lf = out_lf / "DSC02532_HDR.heic"
        assert_heic_compliant(ctx, heic_lf, expected_stops=2.5)
        diff = measure_image_diff(ctx.cfg.tools, heic_lf, out_off / "DSC02532_HDR.heic", max_dim=1024)
        assert diff["mean_abs_diff"] < 1e-4, f"Missing Lensfun profile fallback diverged from off: {diff}"

    def t2_v11_09(ctx: RunContext) -> None:
        fake_home = ctx.test_out_dir("T2-V11-09", "home")
        lf_dir = fake_home / "Library" / "Application Support" / "Chiaro" / "Lensfun"
        lf_dir.mkdir(parents=True, exist_ok=True)
        (lf_dir / "bad.xml").write_text("<lensdatabase><broken", encoding="utf-8")

        out = ctx.test_out_dir("T2-V11-09", "out")
        res = ctx.run_cli(
            [str(ctx.sample_path("DSC02532.ARW")), "--lens-correction", "auto", "--no-sidecar", "--json-progress", "-o", str(out)],
            env_override={"HOME": str(fake_home), "CFFIXED_USER_HOME": str(fake_home)},
        )
        assert res.returncode == 0, f"Corrupt custom Lensfun XML caused failure: {res.stderr}"
        jd = extract_job_decoded_events(res.stdout)
        assert len(jd) == 1 and jd[0].get("opticsSource") in ("embedded_arw", "none"), f"Unexpected opticsSource: {jd}"
        assert_heic_compliant(ctx, out / "DSC02532_HDR.heic", expected_stops=2.5)

    def t2_v11_10(ctx: RunContext) -> None:
        for fn, ew, eh in (
            ("DSC02532.ARW", 7008, 4672),
            ("DSC02540.ARW", 4672, 7008),
            ("DSC02556.ARW", 3072, 4608),
        ):
            stem = Path(fn).stem
            out = ctx.test_out_dir("T2-V11-10", stem)
            res = ctx.run_cli([str(ctx.sample_path(fn)), "--lens-correction", "embedded", "--no-sidecar", "-o", str(out)])
            assert res.returncode == 0, res.stderr
            heic = out / f"{stem}_HDR.heic"
            assert_heic_compliant(ctx, heic, expected_stops=2.5, expect_w=ew, expect_h=eh)
            cc = measure_corner_center_luma_ratio(ctx.cfg.tools, heic, max_dim=1024)
            assert cc["corner_min_luma"] >= 0.0 and cc["ratio"] > 0.05, (
                f"Possible black border artifact in {fn}: {cc}"
            )

    def t2_v11_11(ctx: RunContext) -> None:
        pj = ctx.write_preset_json(
            "t2_v11_11_4ev",
            {"targetHeadroomStops": 4.0, "sdrToneMapper": "sigmoid"},
            develop_overrides={"exposureEV": 1.5},
        )
        out = ctx.test_out_dir("T2-V11-11")
        res = ctx.run_cli([
            str(ctx.sample_path("DSC02533.ARW")),
            "--preset-file", str(pj),
            "--demosaic", "amaze",
            "--denoise", "auto",
            "--denoise-luma", "100",
            "--lens-correction", "embedded",
            "--clarity", "100",
            "--sharpness", "100",
            "--tone-mapper", "sigmoid",
            "--no-sidecar",
            "-o", str(out),
        ])
        assert res.returncode == 0, res.stderr
        heic = out / "DSC02533_HDR.heic"
        assert_heic_compliant(ctx, heic, expected_stops=4.0)
        hdr = measure_hdr_linear_stats(ctx.cfg.tools, heic, _hdr_cache_dir(ctx))
        assert hdr["nanCount"] == 0 and hdr["infCount"] == 0, f"NaN/Inf in extreme pipeline: {hdr}"
        assert hdr["hdrMaxChannel"] > 3.0, f"Extreme pipeline clipped 4.0 EV HDR highlights: {hdr}"

    def t2_v11_12(ctx: RunContext) -> None:
        in_dir = ctx.test_out_dir("T2-V11-12", "in")
        arw = in_dir / "DSC02532.ARW"
        shutil.copy2(ctx.sample_path("DSC02532.ARW"), arw)
        write_sidecar(
            arw,
            build_v11_sidecar(
                preset_id="apple_heic",
                demosaic="lmmse",
                optics={"enabled": True, "source": "embedded", "distortion": True, "autoScale": True, "tca": True, "vignetting": True, "vignettingStrength": 1.0},
                delta={"clarityOverride": 20.0},
                denoise={"mode": "coreMLANE", "luminanceStrength": 30.0, "chromaStrength": 60.0, "detailPreservation": 75.0, "preferANE": True, "modelID": "nafnet_a7c2_v2"},
                ai_color={
                    "enabled": True,
                    "colorBalanceRGB": {"global": [0.0, 0.0, 0.0], "shadows": [0.0, 0.0, 0.0], "midtones": [0.0, 0.0, 0.0], "highlights": [0.0, 0.0, 0.0]},
                    "toneEqualizer": [0.0] * 8,
                },
                extra={"futureV4Field": {"nested": [1, 2, 3]}, "v3AgentPrompt": "warm sunset"},
            ),
        )
        out = ctx.test_out_dir("T2-V11-12", "out")
        res = ctx.run_cli([str(arw), "--json-progress", "-o", str(out)])
        assert res.returncode == 0, f"Forward-compat v2/v3 sidecar failed: {res.stderr}"
        jd = extract_job_decoded_events(res.stdout)
        assert len(jd) == 1 and jd[0].get("demosaicUsed") == "lmmse"
        assert_heic_compliant(ctx, out / "DSC02532_HDR.heic", expected_stops=2.5)

    def t2_v11_13(ctx: RunContext) -> None:
        in_dir = ctx.test_out_dir("T2-V11-13", "in")
        arw = in_dir / "DSC02532.ARW"
        shutil.copy2(ctx.sample_path("DSC02532.ARW"), arw)
        Path(f"{arw}.chiaro.json").write_text("{broken json", encoding="utf-8")

        out_use = ctx.test_out_dir("T2-V11-13", "use")
        r_use = ctx.run_cli([str(arw), "--use-sidecar", "-o", str(out_use)])
        assert r_use.returncode >= 0, f"Malformed sidecar caused signal crash {-r_use.returncode}"

        out_no = ctx.test_out_dir("T2-V11-13", "no")
        r_no = ctx.run_cli([str(arw), "--no-sidecar", "-o", str(out_no)])
        assert r_no.returncode == 0, f"--no-sidecar failed to bypass malformed sidecar: {r_no.stderr}"
        assert_heic_compliant(ctx, out_no / "DSC02532_HDR.heic", expected_stops=2.5)

    def t2_v11_14(ctx: RunContext) -> None:
        pj = ctx.write_preset_json("t2_v11_14_v10_compat")
        raw_obj = json.loads(pj.read_text(encoding="utf-8"))
        raw_obj["developDefaults"].pop("clarity", None)
        raw_obj["developDefaults"].pop("opticalSharpness", None)
        pj.write_text(json.dumps(raw_obj, indent=2), encoding="utf-8")

        out = ctx.test_out_dir("T2-V11-14")
        res = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--preset-file", str(pj), "--no-sidecar", "-o", str(out)])
        assert res.returncode == 0, f"v1.0 preset JSON compatibility failed: {res.stderr}"
        assert_heic_compliant(ctx, out / "DSC02532_HDR.heic", expected_stops=2.5)

    def t2_v11_15(ctx: RunContext) -> None:
        in_dir = ctx.test_out_dir("T2-V11-15", "in")
        arw = in_dir / "DSC02532.ARW"
        shutil.copy2(ctx.sample_path("DSC02532.ARW"), arw)
        write_sidecar(arw, build_v11_sidecar(preset_id="xiaohongshu_jpg"))

        out_a = ctx.test_out_dir("T2-V11-15", "omit_p")
        out_b = ctx.test_out_dir("T2-V11-15", "explicit_p")

        ra = ctx.run_cli([str(arw), "-o", str(out_a)])
        rb = ctx.run_cli([str(arw), "-p", "apple_heic", "-o", str(out_b)])
        assert ra.returncode == 0 and rb.returncode == 0
        assert_jpeg_compliant(ctx, out_a / "DSC02532_HDR.jpg", max_bytes=4_194_304, expect_w=1536, expect_h=2048)
        assert_heic_compliant(ctx, out_b / "DSC02532_HDR.heic", expect_w=7008, expect_h=4672)

    def t2_v11_16(ctx: RunContext) -> None:
        in_dir = ctx.test_out_dir("T2-V11-16", "in")
        arw = in_dir / "DSC02532.ARW"
        shutil.copy2(ctx.sample_path("DSC02532.ARW"), arw)
        write_sidecar(arw, build_v11_sidecar(preset_id="apple_heic", delta={"clarityOverride": 80.0, "exposureEVDelta": 1.0}))

        cfg_dir = ctx.test_out_dir("T2-V11-16", "cfg")
        delta_f = cfg_dir / "delta.json"
        delta_f.write_text(json.dumps({"DSC02532.ARW": {"clarityOverride": -80.0}}), encoding="utf-8")
        ref_delta = cfg_dir / "ref_delta.json"
        ref_delta.write_text(json.dumps({"DSC02532.ARW": {"exposureEVDelta": 1.0}}), encoding="utf-8")

        out_a = ctx.test_out_dir("T2-V11-16", "run_a")
        out_a_ref = ctx.test_out_dir("T2-V11-16", "run_a_ref")
        out_b = ctx.test_out_dir("T2-V11-16", "run_b")
        out_b_ref = ctx.test_out_dir("T2-V11-16", "run_b_ref")

        ra = ctx.run_cli([str(arw), "--delta-file", str(delta_f), "-o", str(out_a)])
        ra_ref = ctx.run_cli([str(arw), "--no-sidecar", "--delta-file", str(ref_delta), "--clarity", "-80", "-o", str(out_a_ref)])
        rb = ctx.run_cli([str(arw), "--delta-file", str(delta_f), "--clarity", "20", "-o", str(out_b)])
        rb_ref = ctx.run_cli([str(arw), "--no-sidecar", "--delta-file", str(ref_delta), "--clarity", "20", "-o", str(out_b_ref)])
        assert ra.returncode == 0 and ra_ref.returncode == 0 and rb.returncode == 0 and rb_ref.returncode == 0

        da = measure_image_diff(ctx.cfg.tools, out_a / "DSC02532_HDR.heic", out_a_ref / "DSC02532_HDR.heic", max_dim=1024)
        db = measure_image_diff(ctx.cfg.tools, out_b / "DSC02532_HDR.heic", out_b_ref / "DSC02532_HDR.heic", max_dim=1024)
        assert da["mean_abs_diff"] < 1e-5, f"--delta-file did not beat sidecar: {da}"
        assert db["mean_abs_diff"] < 1e-5, f"CLI --clarity did not beat --delta-file: {db}"

    def t2_v11_17(ctx: RunContext) -> None:
        in_dir = ctx.test_out_dir("T2-V11-17", "in")
        arw = in_dir / "DSC02532.ARW"
        shutil.copy2(ctx.sample_path("DSC02532.ARW"), arw)
        out_dir = ctx.test_out_dir("T2-V11-17", "out")

        res = ctx.run_cli([str(in_dir), "--clarity", "25", "--sharpness", "30", "--demosaic", "lmmse", "-o", str(out_dir)])
        assert res.returncode == 0, res.stderr
        assert sorted(p.name for p in in_dir.iterdir()) == ["DSC02532.ARW"], (
            f"CLI polluted clean input dir: {list(in_dir.iterdir())}"
        )
        assert not list(out_dir.rglob("*.tmp")), f"Leftover .tmp files in out_dir: {list(out_dir.rglob('*.tmp'))}"
        assert not list(ctx.cfg.sample_dir.glob("*.chiaro.json")), "Unexpected .chiaro.json in CHIARO_SAMPLE_DIR"

    def t2_v11_18(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T2-V11-18")
        res = ctx.run_cli([
            str(ctx.sample_path("DSC02532.ARW")),
            "--backend", "ciraw9",
            "--demosaic", "lmmse",
            "--denoise", "auto",
            "--lens-correction", "auto",
            "--tone-mapper", "sigmoid",
            "--clarity", "25",
            "--sharpness", "25",
            "--no-sidecar",
            "--json-progress",
            "-o", str(out),
        ])
        assert res.returncode == 0, res.stderr
        jd = extract_job_decoded_events(res.stdout)
        assert len(jd) == 1 and "demosaicUsed" in jd[0] and "opticsSource" in jd[0], f"Missing v1.1 NDJSON fields: {jd}"
        assert_heic_compliant(ctx, out / "DSC02532_HDR.heic", expected_stops=2.5)

    def t2_v11_19(ctx: RunContext) -> None:
        in_dir = ctx.test_out_dir("T2-V11-19", "in")
        (in_dir / "fake.ARW").mkdir()
        (in_dir / "DSC02532.ARW.chiaro.json").write_text("{}", encoding="utf-8")
        (in_dir / "DSC02532.HIF").write_bytes(b"hif")
        (in_dir / "test.JPG").write_bytes(b"jpg")

        out_empty = ctx.test_out_dir("T2-V11-19", "out_empty")
        r_empty = ctx.run_cli([str(in_dir), "-o", str(out_empty)])
        assert r_empty.returncode != 0 and r_empty.returncode > 0, "Expected non-zero exit when only fake.ARW/ & non-ARW exist"

        shutil.copy2(ctx.sample_path("DSC02532.ARW"), in_dir / "sample.arw")
        out_ok = ctx.test_out_dir("T2-V11-19", "out_ok")
        r_ok = ctx.run_cli([str(in_dir), "--no-sidecar", "-o", str(out_ok)])
        assert r_ok.returncode == 0, r_ok.stderr
        heics = sorted(p.name for p in out_ok.glob("*.heic"))
        assert heics == ["sample_HDR.heic"], f"Expected only sample_HDR.heic, got {heics}"

    def t2_v11_20(ctx: RunContext) -> None:
        in_dir = ctx.test_out_dir("T2-V11-20", "in")
        arw = in_dir / "DSC02532.ARW"
        shutil.copy2(ctx.sample_path("DSC02532.ARW"), arw)
        write_sidecar(arw, build_v11_sidecar(preset_id="xiaohongshu_jpg", demosaic="ahd"))

        out = ctx.test_out_dir("T2-V11-20", "out")
        res = ctx.run_cli([
            str(arw),
            "--demosaic=lmmse",
            "--denoise=off",
            "--lens-correction=embedded",
            "--lens-vignetting=off",
            "--lens-vignetting-strength=50",
            "--tone-mapper=sigmoid",
            "--clarity=-25",
            "--sharpness=40",
            "--use-sidecar",
            "--no-sidecar",
            "--json-progress",
            "-o", str(out),
        ])
        assert res.returncode == 0, res.stderr
        jd = extract_job_decoded_events(res.stdout)
        assert len(jd) == 1 and jd[0].get("demosaicUsed") == "lmmse"
        assert (out / "DSC02532_HDR.heic").is_file() and not (out / "DSC02532_HDR.jpg").exists(), (
            "Last flag --no-sidecar failed to override --use-sidecar"
        )

    def t2_v11_21(ctx: RunContext) -> None:
        for fn, preset, w, h in (
            ("DSC02532.ARW", "xiaohongshu_jpg", 1536, 2048),
            ("DSC02540.ARW", "douyin_hlg_mp4", 1080, 1920),
        ):
            stem = Path(fn).stem
            out = ctx.test_out_dir("T2-V11-21", f"{stem}_{preset}")
            res = ctx.run_cli([str(ctx.sample_path(fn)), "--preset", preset, "--lens-correction", "embedded", "--no-sidecar", "-o", str(out)])
            assert res.returncode == 0, res.stderr
            if preset == "xiaohongshu_jpg":
                jpg = out / f"{stem}_HDR.jpg"
                assert_jpeg_compliant(ctx, jpg, expect_w=w, expect_h=h, max_bytes=4_194_304)
                cc = measure_corner_center_luma_ratio(ctx.cfg.tools, jpg, max_dim=1024)
                assert cc["corner_min_luma"] >= 0.0
            else:
                assert_hlg_mp4_compliant(ctx, out / f"{stem}_HDR.mp4", allowed_sizes=((w, h),))

    def t2_v11_22(ctx: RunContext) -> None:
        cli_tar = ctx.cfg.repo_root / "dist" / "chiaro-cli-1.1.0-macos-arm64.tar.gz"
        assert cli_tar.is_file(), f"Missing {cli_tar}"
        reloc_root = ctx.test_out_dir("T2-V11-22", "reloc_cli")
        with tarfile.open(cli_tar, "r:gz") as tf:
            tf.extractall(reloc_root, filter="tar")

        reloc_cli = reloc_root / "chiaro-cli-1.1.0-macos-arm64" / "bin" / "chiaro-cli"
        out = ctx.test_out_dir("T2-V11-22", "out")
        sb = ctx.cfg.tools.sandbox_exec or "/usr/bin/sandbox-exec"
        res = ctx.run_cmd(
            [
                sb, "-p", "(version 1)(allow default)(deny network*)",
                str(reloc_cli),
                str(ctx.sample_path("DSC02532.ARW")),
                "--lens-correction", "auto",
                "--denoise", "auto",
                "--no-sidecar",
                "-o", str(out),
            ],
            cwd=reloc_root,
        )
        assert res.returncode == 0, f"Relocated CLI offline sandbox execution failed: {res.stderr}"
        assert_heic_compliant(ctx, out / "DSC02532_HDR.heic", expected_stops=2.5)

    tests.extend([
        TestCase("T2-V11-01", 2, "F14", "Invalid --demosaic Values & Missing Arg", t2_v11_01, "chiaro --demosaic {bilinear,xtrans,'',missing}"),
        TestCase("T2-V11-02", 2, "F16", "--denoise Invalid & --denoise-chroma/luma BVA", t2_v11_02, "chiaro --denoise* BVA (0, 100, <0, >100, nan)"),
        TestCase("T2-V11-03", 2, "F15", "--lens-correction Invalid & Sub-Toggle Invalid Tokens", t2_v11_03, "chiaro --lens-* invalid tokens"),
        TestCase("T2-V11-04", 2, "F15", "--lens-vignetting-strength BVA (0, 100, -0.1, 100.1, NaN)", t2_v11_04, "chiaro --lens-vignetting-strength BVA"),
        TestCase("T2-V11-05", 2, "F16", "Invalid --tone-mapper Values", t2_v11_05, "chiaro --tone-mapper {reinhard,filmic,'',missing}"),
        TestCase("T2-V11-06", 2, "F16", "--clarity BVA (-100, 0, 100, -100.1, 100.1, NaN)", t2_v11_06, "chiaro --clarity BVA"),
        TestCase("T2-V11-07", 2, "F16", "--sharpness BVA (0, 100, -0.1, 100.1, NaN)", t2_v11_07, "chiaro --sharpness BVA"),
        TestCase("T2-V11-08", 2, "F15", "Missing Lensfun Profile Graceful none Fallback", t2_v11_08, "chiaro DSC02532.ARW --lens-correction lensfun"),
        TestCase("T2-V11-09", 2, "F15", "Corrupt Custom User Lensfun XML Isolation", t2_v11_09, "HOME=<bad xml> chiaro DSC02532.ARW --lens-correction auto"),
        TestCase("T2-V11-10", 2, "F15", "FF (nc=16) vs APS-C (nc=11) with autoScale & Orientation=8", t2_v11_10, "chiaro FF/Rotate270/APSC --lens-correction embedded"),
        TestCase("T2-V11-11", 2, "F16", "HDR >1.0 Non-Clipping Under Extreme Pipeline Stack", t2_v11_11, "chiaro 4.0 EV + extreme denoise/clarity/sharpness/sigmoid"),
        TestCase("T2-V11-12", 2, "F17", "Forward-Compatible .chiaro.json (v2 denoise, v3 aiColor, unknown keys)", t2_v11_12, "chiaro copied ARW + v2/v3 future .chiaro.json"),
        TestCase("T2-V11-13", 2, "F17", "Malformed .chiaro.json Recovery & --no-sidecar Bypass", t2_v11_13, "chiaro corrupt .chiaro.json with --use-sidecar vs --no-sidecar"),
        TestCase("T2-V11-14", 2, "F17", "v1.0 Preset JSON Backward Compatibility (No v1.1 Fields)", t2_v11_14, "chiaro --preset-file v10_preset.json"),
        TestCase("T2-V11-15", 2, "F18", "Precedence: Default -p Yielding to Sidecar presetID vs Explicit -p", t2_v11_15, "chiaro copied ARW + sidecar presetID vs -p apple_heic"),
        TestCase("T2-V11-16", 2, "F18", "Precedence: --delta-file Overriding Sidecar delta, Beaten by CLI", t2_v11_16, "chiaro sidecar + --delta-file + --clarity"),
        TestCase("T2-V11-17", 2, "F17", "CLI Sidecar Non-Destructiveness & Zero .tmp Leftovers", t2_v11_17, "chiaro clean dir + verify zero .chiaro.json/.tmp created"),
        TestCase("T2-V11-18", 2, "F18", "--backend ciraw9 + v1.1 Flags Compatibility", t2_v11_18, "chiaro --backend ciraw9 + v1.1 flags"),
        TestCase("T2-V11-19", 2, "F20", "Non-ARW, .HIF, .chiaro.json, and fake.ARW/ Directory Exclusion", t2_v11_19, "chiaro dir with fake.ARW/ + .HIF + .chiaro.json + .arw"),
        TestCase("T2-V11-20", 2, "F18", "--flag=value Inline Syntax & Flag Conflict (--use-sidecar --no-sidecar)", t2_v11_20, "chiaro --flag=value inline syntax"),
        TestCase("T2-V11-21", 2, "F15", "Embedded Curves + cropAspect Geometry Interaction (3:4 & 9:16)", t2_v11_21, "chiaro --lens-correction embedded + 3:4 & 9:16"),
        TestCase("T2-V11-22", 2, "F13", "Relocated dist/ CLI Tarball Offline Sandbox Execution", t2_v11_22, "sandbox-exec relocated chiaro-cli tarball"),
    ])

    assert len(tests) == 22, f"Expected 22 Tier 2 v1.1 tests, got {len(tests)}"
    return tests

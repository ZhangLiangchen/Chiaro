"""Tier 1 Chiaro v1.1 Feature Coverage E2E Tests (26 tests: T1-V11-01..T1-V11-26)."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import tarfile
from pathlib import Path
from typing import Dict, List

from config import BUILTIN_PRESET_IDS, FORBIDDEN_SYMBOL_PATTERNS
from probes.cli_probes import (
    build_v11_sidecar,
    check_app_bundle_v11,
    check_gpl3_compatible_linkage,
    decode_image_to_rgb,
    extract_job_decoded_events,
    measure_corner_center_luma_ratio,
    measure_edge_acutance,
    measure_hdr_linear_stats,
    measure_highlight_magenta_fraction,
    measure_image_diff,
    measure_midtone_local_contrast,
    measure_region_noise_variance,
    parse_ndjson_events,
    probe_binary_strings_and_symbols,
    probe_neutral_canvas_invariant,
    probe_verify_licenses_sbom,
    smoke_launch_app,
    write_sidecar,
)
from tests.common import (
    RunContext,
    TestCase,
    assert_heic_compliant,
    assert_jpeg_compliant,
)


CUSTOM_A075_LENSFUN_XML = """<lensdatabase version="1">
    <lens>
        <maker>Tamron</maker>
        <model>TAMRON 25-200mm F2.8-5.6 A075 E</model>
        <mount>Sony E</mount>
        <aperture min="2.8" max="5.6"/>
        <cropfactor>1</cropfactor>
        <calibration>
            <distortion model="ptlens" focal="25" a="0.008" b="-0.025" c="0.010"/>
            <distortion model="ptlens" focal="50" a="0.004" b="0.012" c="-0.004"/>
            <distortion model="ptlens" focal="200" a="0.009" b="-0.020" c="0.025"/>
            <tca model="poly3" focal="25" vr="1.0003" vb="1.0002"/>
            <tca model="poly3" focal="50" vr="1.0001" vb="1.0002"/>
            <tca model="poly3" focal="200" vr="0.9999" vb="0.9999"/>
            <vignetting model="pa" focal="50" aperture="4.0" distance="1000" k1="-0.65" k2="0.15" k3="0.02"/>
        </calibration>
    </lens>
</lensdatabase>
"""


def _require_app(ctx: RunContext) -> Path:
    assert ctx.cfg.app_bundle is not None and ctx.cfg.app_bundle.is_dir(), (
        "Chiaro.app bundle not found (build with Scripts/build_app.sh or pass --app-bundle)"
    )
    return ctx.cfg.app_bundle


def _hdr_cache_dir(ctx: RunContext) -> Path:
    return ctx.cfg.work_dir / "bin"


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def get_tests() -> List[TestCase]:
    tests: List[TestCase] = []

    # =========================================================================
    # F13: Licensing, SBOM & Self-Contained Packaging (4 tests)
    # =========================================================================
    def t1_v11_01(ctx: RunContext) -> None:
        sbom = probe_verify_licenses_sbom(ctx.cfg.repo_root, require_binaries=True)
        assert sbom["returncode"] == 0, f"verify_licenses.sh --require-binaries failed:\n{sbom['stderr']}\n{sbom['stdout']}"
        assert sbom["all_ok"], f"SBOM rows not all OK: {sbom['rows']}"

        stdout = sbom["stdout"]
        for expected in (
            "GPL-3.0-or-later",
            "LibRaw",
            "LGPL-2.1 (elected)",
            "librtprocess",
            "Lensfun",
            "LGPL-3.0-only",
            "CC-BY-SA-3.0",
            "0 violations",
        ):
            assert expected in stdout, f"SBOM output missing {expected!r}"

        lic = (ctx.cfg.repo_root / "LICENSE").read_text(encoding="utf-8", errors="replace")
        notices = (ctx.cfg.repo_root / "THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8", errors="replace")
        assert "GNU GENERAL PUBLIC LICENSE" in lic and "Version 3, 29 June 2007" in lic
        assert "GPL-3.0-or-later" in notices and "LGPL-2.1" in notices
        ctx.note(f"SBOM verified {len(sbom['rows'])} components OK under GPL-3.0-or-later")

    def t1_v11_02(ctx: RunContext) -> None:
        assert ctx.cfg.cli_bin is not None
        app = _require_app(ctx)
        info = check_app_bundle_v11(ctx.cfg.tools, app)
        app_exe = Path(info["executable"])

        xcf_dir = ctx.cfg.repo_root / "Vendor" / "XCFrameworks"
        for name in (
            "LibRaw.xcframework",
            "LibRTProcess.xcframework",
            "LibLensfun.xcframework",
            "LibUltraHDR.xcframework",
            "LibAVIF.xcframework",
        ):
            assert (xcf_dir / name).is_dir(), f"Missing XCFramework: {xcf_dir / name}"

        nm = ctx.cfg.tools.nm or "/usr/bin/nm"
        for target in (ctx.cfg.cli_bin, app_exe):
            link_res = check_gpl3_compatible_linkage(
                ctx.cfg.tools,
                target,
                check_symbols=True,
                require_self_contained=("Chiaro.app" in target.parts),
            )
            assert link_res["clean"], f"Linkage violation in {target}: {link_res}"

            nm_text = ""
            for flag in ("-gU", ""):
                cmd = [nm, flag, str(target)] if flag else [nm, str(target)]
                res = ctx.run_cmd(cmd)
                nm_text += "\n" + res.stdout
            for pat in FORBIDDEN_SYMBOL_PATTERNS:
                assert pat not in nm_text, f"Forbidden symbol {pat!r} found in {target}"

        cli_sym_res = probe_binary_strings_and_symbols(
            ctx.cfg.tools,
            ctx.cfg.cli_bin,
            ["amaze_demosaic", "lmmse_demosaic", "dcb", "dht_interpolate"],
        )
        assert cli_sym_res["all_found"], f"Missing expected demosaic symbols in {ctx.cfg.cli_bin.name}: {cli_sym_res['missing']}"
        ctx.note("LibRaw + librtprocess demosaic symbols present and zero forbidden symbols")

    def t1_v11_21(ctx: RunContext) -> None:
        app = _require_app(ctx)
        info = check_app_bundle_v11(ctx.cfg.tools, app)
        assert info["ok"], f"Chiaro.app v1.1.1 bundle errors: {info['errors']}"
        assert info["short_version"] == "1.1.1", f"Expected CFBundleShortVersionString 1.1.1, got {info['short_version']!r}"
        assert info.get("icon_file") == "AppIcon", f"Expected CFBundleIconFile 'AppIcon', got {info.get('icon_file')!r}"
        assert info.get("app_icon_icns"), "AppIcon.icns missing from Chiaro.app Contents/Resources"
        assert info["shaders_metal_files"], "Shaders.metal missing from Chiaro.app Resources"
        json_stems = {Path(p).stem for p in info["resource_json_files"]}
        missing_presets = [pid for pid in BUILTIN_PRESET_IDS if pid not in json_stems]
        assert not missing_presets, f"Missing preset JSONs in Chiaro.app: {missing_presets}"
        assert info["lensfun_xml_files"], "LensfunDB/*.xml missing from Chiaro.app"
        assert info["lensfun_license_files"], "LensfunDB/cc-by-sa-3.0.txt missing from Chiaro.app"
        assert info["noise_profile_files"], "NoiseProfiles/*.json missing from Chiaro.app"
        ctx.note(
            f"Chiaro.app v1.1.1 verified: {len(info['lensfun_xml_files'])} Lensfun XMLs, "
            f"{len(info['noise_profile_files'])} noise profiles, AppIcon.icns & self-contained linkage clean"
        )

    def t1_v11_22(ctx: RunContext) -> None:
        dist_dir = ctx.cfg.repo_root / "dist"
        app_zip = dist_dir / "Chiaro-1.1.1-macos-arm64.zip"
        cli_tar = dist_dir / "chiaro-cli-1.1.1-macos-arm64.tar.gz"
        sums = dist_dir / "SHA256SUMS.txt"
        for p in (app_zip, cli_tar, sums):
            assert p.is_file() and p.stat().st_size > 0, f"Missing release artifact: {p}"

        sha_res = ctx.run_cmd(["shasum", "-a", "256", "-c", str(sums)], cwd=dist_dir)
        assert sha_res.returncode == 0, f"SHA256SUMS verification failed: {sha_res.stderr}\n{sha_res.stdout}"

        unpack_dir = ctx.test_out_dir("T1-V11-22", "unpacked")
        with tarfile.open(cli_tar, "r:gz") as tf:
            tf.extractall(unpack_dir, filter="tar")

        pkg_root = unpack_dir / "chiaro-cli-1.1.1-macos-arm64"
        reloc_cli = pkg_root / "bin" / "chiaro-cli"
        reloc_sym = pkg_root / "bin" / "chiaro"
        assert reloc_cli.is_file() and os.access(reloc_cli, os.X_OK), f"Missing unpacked CLI: {reloc_cli}"
        assert reloc_sym.is_symlink(), f"Expected bin/chiaro symlink: {reloc_sym}"

        targets = [reloc_cli] + sorted((pkg_root / "lib").glob("*.dylib"))
        for tgt in targets:
            rep = check_gpl3_compatible_linkage(
                ctx.cfg.tools,
                tgt,
                check_symbols=True,
                require_self_contained=True,
            )
            assert rep["clean"], f"Unpacked dist linkage violation in {tgt.name}: {rep}"

        lp = ctx.run_cmd([str(reloc_cli), "--list-presets"], cwd=unpack_dir)
        assert lp.returncode == 0, f"Unpacked --list-presets failed: {lp.stderr}"

        out_dir = ctx.test_out_dir("T1-V11-22", "export")
        ex = ctx.run_cmd(
            [str(reloc_cli), str(ctx.sample_path("DSC02532.ARW")), "--preset", "apple_heic", "--no-sidecar", "-o", str(out_dir)],
            cwd=unpack_dir,
        )
        assert ex.returncode == 0, f"Unpacked CLI export failed: {ex.stderr}"
        assert_heic_compliant(ctx, out_dir / "DSC02532_HDR.heic", expected_stops=2.5)

    # =========================================================================
    # F14: DemosaicAlgorithm Mapping (1 test)
    # =========================================================================
    def t1_v11_03(ctx: RunContext) -> None:
        algs = ("amaze", "lmmse", "dcb", "dht", "ahd")
        arw = ctx.sample_path("DSC02532.ARW")
        decoded_imgs: Dict[str, object] = {}

        for alg in algs:
            out = ctx.test_out_dir("T1-V11-03", alg)
            res = ctx.run_cli(
                [str(arw), "--preset", "apple_heic", "--demosaic", alg, "--no-sidecar", "--json-progress", "-o", str(out)]
            )
            assert res.returncode == 0, f"--demosaic {alg} failed: {res.stderr}"
            heic = out / "DSC02532_HDR.heic"
            assert_heic_compliant(ctx, heic, expected_stops=2.5, expect_w=7008, expect_h=4672)

            jd = extract_job_decoded_events(res.stdout)
            assert len(jd) == 1, f"Expected 1 job_decoded event for {alg}, got {len(jd)}"
            assert jd[0].get("demosaicUsed") == alg, f"Expected demosaicUsed={alg!r}, got {jd[0]}"
            decoded_imgs[alg] = decode_image_to_rgb(ctx.cfg.tools, heic, max_dim=1536)

        for i in range(len(algs)):
            for j in range(i + 1, len(algs)):
                a, b = algs[i], algs[j]
                diff = measure_image_diff(ctx.cfg.tools, decoded_imgs[a], decoded_imgs[b], max_dim=None)
                assert diff["mean_abs_diff"] > 1e-4 and diff["max_diff"] > 0.005, (
                    f"Demosaic {a} vs {b} too similar (possible silent fallback): {diff}"
                )
        ctx.note("All 5 demosaic algorithms (amaze/lmmse/dcb/dht/ahd) produced distinct compliant outputs")

    # =========================================================================
    # F15: Dual Open-Source Optics (Embedded ARW + Lensfun + GPU LUT) (7 tests)
    # =========================================================================
    def t1_v11_04(ctx: RunContext) -> None:
        arw = ctx.sample_path("DSC02532.ARW")
        out_emb = ctx.test_out_dir("T1-V11-04", "embedded")
        out_off = ctx.test_out_dir("T1-V11-04", "off")

        r_emb = ctx.run_cli([str(arw), "--lens-correction", "embedded", "--no-sidecar", "--json-progress", "-o", str(out_emb)])
        r_off = ctx.run_cli([str(arw), "--lens-correction", "off", "--no-sidecar", "--json-progress", "-o", str(out_off)])
        assert r_emb.returncode == 0, r_emb.stderr
        assert r_off.returncode == 0, r_off.stderr

        jd = extract_job_decoded_events(r_emb.stdout)
        assert len(jd) == 1 and jd[0].get("opticsSource") == "embedded_arw", f"Unexpected job_decoded: {jd}"
        assert "TAMRON" in str(jd[0].get("lensMatched") or "").upper(), f"Missing TAMRON lensMatched: {jd[0]}"

        heic_emb = out_emb / "DSC02532_HDR.heic"
        heic_off = out_off / "DSC02532_HDR.heic"
        assert_heic_compliant(ctx, heic_emb, expected_stops=2.5, expect_w=7008, expect_h=4672)
        assert_heic_compliant(ctx, heic_off, expected_stops=2.5, expect_w=7008, expect_h=4672)

        diff = measure_image_diff(ctx.cfg.tools, heic_emb, heic_off, max_dim=1024)
        assert diff["rms_diff"] > 0.005, f"Embedded FF 16-node optics vs off diff too small: {diff}"

        hdr = measure_hdr_linear_stats(ctx.cfg.tools, heic_emb, _hdr_cache_dir(ctx))
        assert hdr["nanCount"] == 0 and hdr["infCount"] == 0, f"NaN/Inf in HDR output: {hdr}"
        assert hdr["hdrMaxChannel"] > 1.5, f"HDR highlights clipped (hdrMaxChannel={hdr['hdrMaxChannel']})"

    def t1_v11_05(ctx: RunContext) -> None:
        arw = ctx.sample_path("DSC02556.ARW")
        out_emb = ctx.test_out_dir("T1-V11-05", "embedded")
        out_off = ctx.test_out_dir("T1-V11-05", "off")

        r_emb = ctx.run_cli([str(arw), "--lens-correction", "embedded", "--no-sidecar", "--json-progress", "-o", str(out_emb)])
        r_off = ctx.run_cli([str(arw), "--lens-correction", "off", "--no-sidecar", "--json-progress", "-o", str(out_off)])
        assert r_emb.returncode == 0, r_emb.stderr
        assert r_off.returncode == 0, r_off.stderr

        jd = extract_job_decoded_events(r_emb.stdout)
        assert len(jd) == 1 and jd[0].get("opticsSource") == "embedded_arw", f"Unexpected job_decoded: {jd}"

        heic_emb = out_emb / "DSC02556_HDR.heic"
        heic_off = out_off / "DSC02556_HDR.heic"
        assert_heic_compliant(ctx, heic_emb, expected_stops=2.5, expect_w=3072, expect_h=4608)
        diff = measure_image_diff(ctx.cfg.tools, heic_emb, heic_off, max_dim=1024)
        assert diff["rms_diff"] > 0.005, f"Embedded APS-C 11-node optics vs off diff too small: {diff}"

    def t1_v11_06(ctx: RunContext) -> None:
        arw = ctx.sample_path("DSC02532.ARW")
        out_auto = ctx.test_out_dir("T1-V11-06", "auto")
        out_emb = ctx.test_out_dir("T1-V11-06", "embedded")

        r_auto = ctx.run_cli([str(arw), "--lens-correction", "auto", "--no-sidecar", "--json-progress", "-o", str(out_auto)])
        r_emb = ctx.run_cli([str(arw), "--lens-correction", "embedded", "--no-sidecar", "--json-progress", "-o", str(out_emb)])
        assert r_auto.returncode == 0 and r_emb.returncode == 0

        jd = extract_job_decoded_events(r_auto.stdout)
        assert len(jd) == 1 and jd[0].get("opticsSource") == "embedded_arw", f"Expected embedded_arw for auto: {jd}"
        assert jd[0].get("lensMatched"), f"Expected non-empty lensMatched: {jd}"

        diff = measure_image_diff(ctx.cfg.tools, out_auto / "DSC02532_HDR.heic", out_emb / "DSC02532_HDR.heic", max_dim=1024)
        assert diff["mean_abs_diff"] < 1e-5, f"Auto optics diverged from embedded: {diff}"

    def t1_v11_07(ctx: RunContext) -> None:
        in_dir = ctx.test_out_dir("T1-V11-07", "in")
        arw = in_dir / "DSC02532.ARW"
        shutil.copy2(ctx.sample_path("DSC02532.ARW"), arw)
        write_sidecar(
            arw,
            build_v11_sidecar(
                optics={
                    "enabled": True,
                    "source": "lensfun",
                    "lensfunLensOverride": "E 28-200mm F2.8-5.6 A071",
                    "distortion": True,
                    "autoScale": True,
                    "tca": True,
                    "vignetting": True,
                    "vignettingStrength": 1.0,
                }
            ),
        )

        out_lf = ctx.test_out_dir("T1-V11-07", "lensfun")
        out_off = ctx.test_out_dir("T1-V11-07", "off")
        out_emb = ctx.test_out_dir("T1-V11-07", "embedded")

        r_lf = ctx.run_cli([str(arw), "--json-progress", "-o", str(out_lf)])
        r_off = ctx.run_cli([str(arw), "--no-sidecar", "--lens-correction", "off", "-o", str(out_off)])
        r_emb = ctx.run_cli([str(arw), "--no-sidecar", "--lens-correction", "embedded", "-o", str(out_emb)])
        assert r_lf.returncode == 0, r_lf.stderr
        assert r_off.returncode == 0 and r_emb.returncode == 0

        jd = extract_job_decoded_events(r_lf.stdout)
        assert len(jd) == 1 and jd[0].get("opticsSource") == "lensfun", f"Expected opticsSource=lensfun: {jd}"
        assert "A071" in str(jd[0].get("lensMatched") or ""), f"Expected A071 in lensMatched: {jd}"

        heic_lf = out_lf / "DSC02532_HDR.heic"
        assert_heic_compliant(ctx, heic_lf, expected_stops=2.5)
        diff_off = measure_image_diff(ctx.cfg.tools, heic_lf, out_off / "DSC02532_HDR.heic", max_dim=1024)
        diff_emb = measure_image_diff(ctx.cfg.tools, heic_lf, out_emb / "DSC02532_HDR.heic", max_dim=1024)
        assert diff_off["rms_diff"] > 0.003, f"Lensfun A071 vs off diff too small: {diff_off}"
        assert diff_emb["rms_diff"] > 0.001, f"Lensfun A071 vs embedded diff too small: {diff_emb}"

    def t1_v11_08(ctx: RunContext) -> None:
        in_dir = ctx.test_out_dir("T1-V11-08", "in")
        arw = in_dir / "DSC02532.ARW"
        shutil.copy2(ctx.sample_path("DSC02532.ARW"), arw)

        fake_home = ctx.test_out_dir("T1-V11-08", "home")
        lf_dir = fake_home / "Library" / "Application Support" / "Chiaro" / "Lensfun"
        lf_dir.mkdir(parents=True, exist_ok=True)
        (lf_dir / "custom_a075.xml").write_text(CUSTOM_A075_LENSFUN_XML, encoding="utf-8")

        out_lf = ctx.test_out_dir("T1-V11-08", "lensfun")
        out_off = ctx.test_out_dir("T1-V11-08", "off")

        r_lf = ctx.run_cli(
            [str(arw), "--lens-correction", "lensfun", "--no-sidecar", "--json-progress", "-o", str(out_lf)],
            env_override={"HOME": str(fake_home), "CFFIXED_USER_HOME": str(fake_home)},
        )
        r_off = ctx.run_cli(
            [str(arw), "--lens-correction", "off", "--no-sidecar", "-o", str(out_off)],
            env_override={"HOME": str(fake_home), "CFFIXED_USER_HOME": str(fake_home)},
        )
        assert r_lf.returncode == 0, r_lf.stderr
        assert r_off.returncode == 0

        jd = extract_job_decoded_events(r_lf.stdout)
        assert len(jd) == 1 and jd[0].get("opticsSource") == "lensfun", f"Custom HOME XML not matched: {jd}"
        assert jd[0].get("lensMatched"), f"Expected non-empty lensMatched for custom XML: {jd}"

        heic_lf = out_lf / "DSC02532_HDR.heic"
        assert_heic_compliant(ctx, heic_lf, expected_stops=2.5)
        diff = measure_image_diff(ctx.cfg.tools, heic_lf, out_off / "DSC02532_HDR.heic", max_dim=1024)
        assert diff["rms_diff"] > 0.003, f"Custom Lensfun XML vs off diff too small: {diff}"

    def t1_v11_09(ctx: RunContext) -> None:
        arw = ctx.sample_path("DSC02532.ARW")
        base_out = ctx.test_out_dir("T1-V11-09", "all_on")
        r_base = ctx.run_cli([str(arw), "--lens-correction", "embedded", "--no-sidecar", "-o", str(base_out)])
        assert r_base.returncode == 0, r_base.stderr
        base_heic = base_out / "DSC02532_HDR.heic"
        assert_heic_compliant(ctx, base_heic, expected_stops=2.5)

        for toggle_flag, sub in (
            ("--lens-distortion", "no_dist"),
            ("--lens-tca", "no_tca"),
            ("--lens-vignetting", "no_vig"),
        ):
            out = ctx.test_out_dir("T1-V11-09", sub)
            res = ctx.run_cli([str(arw), "--lens-correction", "embedded", toggle_flag, "off", "--no-sidecar", "-o", str(out)])
            assert res.returncode == 0, f"{toggle_flag} off failed: {res.stderr}"
            heic = out / "DSC02532_HDR.heic"
            assert_heic_compliant(ctx, heic, expected_stops=2.5)
            diff = measure_image_diff(ctx.cfg.tools, base_heic, heic, max_dim=1024)
            assert diff["mean_abs_diff"] > 0.0 and diff["max_diff"] > 0.002, (
                f"{toggle_flag} off had negligible effect vs all-on: {diff}"
            )

    def t1_v11_10(ctx: RunContext) -> None:
        arw = ctx.sample_path("DSC02532.ARW")
        ratios: Dict[int, float] = {}
        heics: Dict[int, Path] = {}
        for strength in (0, 50, 100):
            out = ctx.test_out_dir("T1-V11-10", f"s_{strength}")
            res = ctx.run_cli(
                [
                    str(arw),
                    "--lens-correction",
                    "embedded",
                    "--lens-vignetting",
                    "on",
                    "--lens-vignetting-strength",
                    str(strength),
                    "--no-sidecar",
                    "-o",
                    str(out),
                ]
            )
            assert res.returncode == 0, res.stderr
            heic = out / "DSC02532_HDR.heic"
            assert_heic_compliant(ctx, heic, expected_stops=2.5)
            heics[strength] = heic
            ratios[strength] = measure_corner_center_luma_ratio(ctx.cfg.tools, heic, max_dim=1024)["ratio"]

        assert ratios[0] < ratios[50] < ratios[100], (
            f"Vignetting corner/center ratio not strictly increasing: {ratios}"
        )

        out_off = ctx.test_out_dir("T1-V11-10", "vig_off")
        r_off = ctx.run_cli(
            [str(arw), "--lens-correction", "embedded", "--lens-vignetting", "off", "--no-sidecar", "-o", str(out_off)]
        )
        assert r_off.returncode == 0
        diff = measure_image_diff(ctx.cfg.tools, heics[0], out_off / "DSC02532_HDR.heic", max_dim=1024)
        assert diff["mean_abs_diff"] < 1e-4, f"strength=0 diverged from --lens-vignetting off: {diff}"

    # =========================================================================
    # F16: darktable Metal IQ Engines (6 tests)
    # =========================================================================
    def t1_v11_11(ctx: RunContext) -> None:
        arw = ctx.sample_path("DSC02533.ARW")
        out_auto = ctx.test_out_dir("T1-V11-11", "auto")
        out_off = ctx.test_out_dir("T1-V11-11", "off")

        r_auto = ctx.run_cli([str(arw), "--demosaic", "amaze", "--denoise", "auto", "--no-sidecar", "-o", str(out_auto)])
        r_off = ctx.run_cli([str(arw), "--demosaic", "amaze", "--denoise", "off", "--no-sidecar", "-o", str(out_off)])
        assert r_auto.returncode == 0 and r_off.returncode == 0

        heic_auto = out_auto / "DSC02533_HDR.heic"
        heic_off = out_off / "DSC02533_HDR.heic"
        assert_heic_compliant(ctx, heic_auto, expected_stops=2.5)

        nv_auto = measure_region_noise_variance(ctx.cfg.tools, heic_auto, max_dim=1024)
        nv_off = measure_region_noise_variance(ctx.cfg.tools, heic_off, max_dim=1024)
        assert nv_auto["chroma_var"] <= 0.75 * nv_off["chroma_var"], (
            f"Profiled denoise chroma variance drop insufficient: auto={nv_auto['chroma_var']}, off={nv_off['chroma_var']}"
        )
        luma_delta = abs(nv_auto["full_mean_luma"] - nv_off["full_mean_luma"]) / max(nv_off["full_mean_luma"], 1e-6)
        assert luma_delta < 0.05, f"Denoise shifted overall mean luma by {luma_delta * 100:.2f}%"

        hdr = measure_hdr_linear_stats(ctx.cfg.tools, heic_auto, _hdr_cache_dir(ctx))
        assert hdr["nanCount"] == 0 and hdr["infCount"] == 0 and hdr["hdrMaxChannel"] > 1.5, f"HDR check failed: {hdr}"

    def t1_v11_12(ctx: RunContext) -> None:
        arw = ctx.sample_path("DSC02533.ARW")
        out_hi = ctx.test_out_dir("T1-V11-12", "hi")
        out_lo = ctx.test_out_dir("T1-V11-12", "lo")

        r_hi = ctx.run_cli([str(arw), "--denoise", "auto", "--denoise-chroma", "100", "--denoise-luma", "80", "--no-sidecar", "-o", str(out_hi)])
        r_lo = ctx.run_cli([str(arw), "--denoise", "auto", "--denoise-chroma", "10", "--denoise-luma", "5", "--no-sidecar", "-o", str(out_lo)])
        assert r_hi.returncode == 0 and r_lo.returncode == 0

        heic_hi = out_hi / "DSC02533_HDR.heic"
        heic_lo = out_lo / "DSC02533_HDR.heic"
        nv_hi = measure_region_noise_variance(
            ctx.cfg.tools, heic_hi, box_norm=(0.10, 0.70, 0.35, 0.90), max_dim=None
        )
        nv_lo = measure_region_noise_variance(
            ctx.cfg.tools, heic_lo, box_norm=(0.10, 0.70, 0.35, 0.90), max_dim=None
        )
        assert nv_hi["chroma_var"] < nv_lo["chroma_var"], f"Chroma scaling failed: hi={nv_hi}, lo={nv_lo}"
        assert nv_hi["luma_var"] < nv_lo["luma_var"], f"Luma scaling failed: hi={nv_hi}, lo={nv_lo}"

        hdr = measure_hdr_linear_stats(ctx.cfg.tools, heic_hi, _hdr_cache_dir(ctx))
        assert hdr["nanCount"] == 0 and hdr["infCount"] == 0, f"NaN/Inf in high denoise output: {hdr}"

    def t1_v11_13(ctx: RunContext) -> None:
        arw = ctx.sample_path("DSC02540.ARW")
        outputs: Dict[str, Path] = {}
        for tm in ("sigmoid", "agx", "neutral", "opendrt"):
            out = ctx.test_out_dir("T1-V11-13", tm)
            res = ctx.run_cli([str(arw), "--tone-mapper", tm, "--no-sidecar", "-o", str(out)])
            assert res.returncode == 0, f"--tone-mapper {tm} failed: {res.stderr}"
            heic = out / "DSC02540_HDR.heic"
            assert_heic_compliant(ctx, heic, expected_stops=2.5)
            outputs[tm] = heic

        for other in ("agx", "neutral", "opendrt"):
            diff = measure_image_diff(ctx.cfg.tools, outputs["sigmoid"], outputs[other], max_dim=1024)
            assert diff["rms_diff"] > 0.003, f"Sigmoid vs {other} diff too small: {diff}"

    def t1_v11_14(ctx: RunContext) -> None:
        arw = ctx.sample_path("DSC02532.ARW")
        lc: Dict[int, float] = {}
        for val in (-60, 0, 60):
            out = ctx.test_out_dir("T1-V11-14", f"c_{val}")
            res = ctx.run_cli([str(arw), "--clarity", str(val), "--no-sidecar", "-o", str(out)])
            assert res.returncode == 0, res.stderr
            heic = out / "DSC02532_HDR.heic"
            assert_heic_compliant(ctx, heic, expected_stops=2.5)
            lc[val] = measure_midtone_local_contrast(ctx.cfg.tools, heic, max_dim=1024)
            hdr = measure_hdr_linear_stats(ctx.cfg.tools, heic, _hdr_cache_dir(ctx))
            assert hdr["nanCount"] == 0 and hdr["infCount"] == 0 and hdr["hdrMaxChannel"] > 1.5, (
                f"Clarity {val} HDR guardrail failed: {hdr}"
            )
        assert lc[-60] < lc[0] < lc[60], f"Clarity midtone local contrast not strictly ordered: {lc}"

    def t1_v11_15(ctx: RunContext) -> None:
        arw = ctx.sample_path("DSC02532.ARW")
        out_0 = ctx.test_out_dir("T1-V11-15", "s0")
        out_80 = ctx.test_out_dir("T1-V11-15", "s80")
        r0 = ctx.run_cli([str(arw), "--sharpness", "0", "--no-sidecar", "-o", str(out_0)])
        r80 = ctx.run_cli([str(arw), "--sharpness", "80", "--no-sidecar", "-o", str(out_80)])
        assert r0.returncode == 0 and r80.returncode == 0

        h0 = out_0 / "DSC02532_HDR.heic"
        h80 = out_80 / "DSC02532_HDR.heic"
        assert_heic_compliant(ctx, h80, expected_stops=2.5)
        ac0 = measure_edge_acutance(
            ctx.cfg.tools, h0, box_norm=(0.35, 0.35, 0.65, 0.65), max_dim=None
        )
        ac80 = measure_edge_acutance(
            ctx.cfg.tools, h80, box_norm=(0.35, 0.35, 0.65, 0.65), max_dim=None
        )
        assert ac80 > ac0, f"Optical sharpness 80 did not increase edge acutance vs 0: {ac80} <= {ac0}"

        nv0 = measure_region_noise_variance(
            ctx.cfg.tools, h0, box_norm=(0.10, 0.70, 0.35, 0.90), max_dim=None, shadow_luma_range=(0.005, 0.08)
        )
        nv80 = measure_region_noise_variance(
            ctx.cfg.tools, h80, box_norm=(0.10, 0.70, 0.35, 0.90), max_dim=None, shadow_luma_range=(0.005, 0.08)
        )
        ratio = nv80["luma_var"] / max(nv0["luma_var"], 1e-9)
        assert ratio < 2.0, f"Dark flat noise exploded under sharpness=80: ratio={ratio:.3f}"

    def t1_v11_16(ctx: RunContext) -> None:
        for fn in ("DSC02533.ARW", "DSC02543.ARW"):
            stem = Path(fn).stem
            out = ctx.test_out_dir("T1-V11-16", stem)
            res = ctx.run_cli([str(ctx.sample_path(fn)), "--preset", "apple_heic", "--no-sidecar", "-o", str(out)])
            assert res.returncode == 0, res.stderr
            heic = out / f"{stem}_HDR.heic"
            assert_heic_compliant(ctx, heic, expected_stops=2.5)
            mag = measure_highlight_magenta_fraction(ctx.cfg.tools, heic, max_dim=1024)
            assert mag["magenta_fraction"] < 0.01 and mag["mean_magenta_cast"] < 0.02, (
                f"Highlight magenta artifact detected in {fn}: {mag}"
            )

    # =========================================================================
    # F17: .chiaro.json v2 Sidecar & Precedence (2 tests)
    # =========================================================================
    def t1_v11_17(ctx: RunContext) -> None:
        in_dir = ctx.test_out_dir("T1-V11-17", "in")
        arw = in_dir / "DSC02532.ARW"
        shutil.copy2(ctx.sample_path("DSC02532.ARW"), arw)
        sc = write_sidecar(
            arw,
            build_v11_sidecar(
                preset_id="apple_heic",
                demosaic="lmmse",
                delta={"clarityOverride": 35.0},
            ),
        )
        before_sha = _sha256(sc)
        before_mtime = sc.stat().st_mtime_ns

        out_sc = ctx.test_out_dir("T1-V11-17", "out_sc")
        out_cli = ctx.test_out_dir("T1-V11-17", "out_cli")

        r_sc = ctx.run_cli([str(arw), "--json-progress", "-o", str(out_sc)])
        r_cli = ctx.run_cli([str(arw), "--no-sidecar", "--preset", "apple_heic", "--demosaic", "lmmse", "--clarity", "35", "-o", str(out_cli)])
        assert r_sc.returncode == 0 and r_cli.returncode == 0

        jd = extract_job_decoded_events(r_sc.stdout)
        assert len(jd) == 1 and jd[0].get("demosaicUsed") == "lmmse", f"Sidecar demosaic not applied: {jd}"
        diff = measure_image_diff(ctx.cfg.tools, out_sc / "DSC02532_HDR.heic", out_cli / "DSC02532_HDR.heic", max_dim=1024)
        assert diff["mean_abs_diff"] < 1e-5, f"Sidecar run differed from equivalent CLI run: {diff}"
        assert _sha256(sc) == before_sha and sc.stat().st_mtime_ns == before_mtime, "CLI mutated sidecar!"

    def t1_v11_18(ctx: RunContext) -> None:
        in_dir = ctx.test_out_dir("T1-V11-18", "in")
        arw = in_dir / "DSC02532.ARW"
        shutil.copy2(ctx.sample_path("DSC02532.ARW"), arw)
        write_sidecar(
            arw,
            build_v11_sidecar(
                preset_id="apple_heic",
                demosaic="lmmse",
                delta={"clarityOverride": 35.0},
            ),
        )

        out_sc = ctx.test_out_dir("T1-V11-18", "with_sc")
        out_no = ctx.test_out_dir("T1-V11-18", "no_sc")
        out_base = ctx.test_out_dir("T1-V11-18", "baseline")

        r_sc = ctx.run_cli([str(arw), "--json-progress", "-o", str(out_sc)])
        r_no = ctx.run_cli([str(arw), "--no-sidecar", "--json-progress", "-o", str(out_no)])
        r_base = ctx.run_cli([str(ctx.sample_path("DSC02532.ARW")), "--no-sidecar", "-o", str(out_base)])
        assert r_sc.returncode == 0 and r_no.returncode == 0 and r_base.returncode == 0

        jd = extract_job_decoded_events(r_no.stdout)
        assert len(jd) == 1 and jd[0].get("demosaicUsed") == "amaze", f"--no-sidecar did not reset to amaze: {jd}"
        diff_sc = measure_image_diff(ctx.cfg.tools, out_sc / "DSC02532_HDR.heic", out_no / "DSC02532_HDR.heic", max_dim=1024)
        diff_base = measure_image_diff(ctx.cfg.tools, out_no / "DSC02532_HDR.heic", out_base / "DSC02532_HDR.heic", max_dim=1024)
        assert diff_sc["mean_abs_diff"] > 1e-4, f"--no-sidecar unexpectedly matched sidecar output: {diff_sc}"
        assert diff_base["mean_abs_diff"] < 1e-5, f"--no-sidecar differed from clean baseline: {diff_base}"

    # =========================================================================
    # F18: CLI Precedence & NDJSON v1.1 Stream (2 tests)
    # =========================================================================
    def t1_v11_19(ctx: RunContext) -> None:
        in_dir = ctx.test_out_dir("T1-V11-19", "in")
        arw = in_dir / "DSC02532.ARW"
        shutil.copy2(ctx.sample_path("DSC02532.ARW"), arw)
        write_sidecar(
            arw,
            build_v11_sidecar(
                preset_id="xiaohongshu_jpg",
                demosaic="lmmse",
                delta={"clarityOverride": 40.0, "exposureEVDelta": -0.5},
            ),
        )

        cfg_dir = ctx.test_out_dir("T1-V11-19", "cfg")
        delta_file = cfg_dir / "delta.json"
        delta_file.write_text(
            json.dumps({"DSC02532.ARW": {"clarityOverride": -40.0, "exposureEVDelta": 0.5}}),
            encoding="utf-8",
        )
        clean_delta = cfg_dir / "clean_delta.json"
        clean_delta.write_text(
            json.dumps({"DSC02532.ARW": {"exposureEVDelta": 0.5}}),
            encoding="utf-8",
        )

        out_win = ctx.test_out_dir("T1-V11-19", "win")
        out_ref = ctx.test_out_dir("T1-V11-19", "ref")

        r_win = ctx.run_cli(
            [
                str(arw),
                "-p",
                "apple_heic",
                "--delta-file",
                str(delta_file),
                "--clarity",
                "75",
                "--demosaic",
                "dcb",
                "--json-progress",
                "-o",
                str(out_win),
            ]
        )
        r_ref = ctx.run_cli(
            [
                str(arw),
                "--no-sidecar",
                "-p",
                "apple_heic",
                "--delta-file",
                str(clean_delta),
                "--clarity",
                "75",
                "--demosaic",
                "dcb",
                "-o",
                str(out_ref),
            ]
        )
        assert r_win.returncode == 0 and r_ref.returncode == 0
        heic_win = out_win / "DSC02532_HDR.heic"
        assert heic_win.is_file() and not (out_win / "DSC02532_HDR.jpg").exists(), "CLI -p apple_heic failed to override sidecar presetID"
        assert_heic_compliant(ctx, heic_win, expected_stops=2.5)
        jd = extract_job_decoded_events(r_win.stdout)
        assert len(jd) == 1 and jd[0].get("demosaicUsed") == "dcb"
        diff = measure_image_diff(ctx.cfg.tools, heic_win, out_ref / "DSC02532_HDR.heic", max_dim=1024)
        assert diff["mean_abs_diff"] < 1e-5, f"Precedence output differed from expected reference: {diff}"

    def t1_v11_20(ctx: RunContext) -> None:
        out = ctx.test_out_dir("T1-V11-20")
        res = ctx.run_cli(
            [
                str(ctx.sample_path("DSC02532.ARW")),
                "--demosaic",
                "amaze",
                "--lens-correction",
                "embedded",
                "--no-sidecar",
                "--json-progress",
                "-o",
                str(out),
            ]
        )
        assert res.returncode == 0, res.stderr
        events = parse_ndjson_events(res.stdout)
        names = [ev.get("event") for ev in events]
        expected_order = ["batch_start", "job_started", "job_decoded", "job_rendered", "job_completed", "batch_summary"]
        assert names == expected_order, f"Unexpected NDJSON sequence {names} != {expected_order}"

        jd = next(ev for ev in events if ev.get("event") == "job_decoded")
        assert jd.get("backend") == "libraw"
        assert jd.get("demosaicUsed") == "amaze"
        assert jd.get("opticsSource") == "embedded_arw"
        assert jd.get("lensMatched"), f"Expected non-empty lensMatched in job_decoded: {jd}"

    # =========================================================================
    # F19: Chiaro.app v1.1 UI Architecture, LiquidGlass & i18n (3 tests)
    # =========================================================================
    def t1_v11_23(ctx: RunContext) -> None:
        app = _require_app(ctx)
        info = check_app_bundle_v11(ctx.cfg.tools, app)
        app_exe = Path(info["executable"])

        required_tokens = [
            "WorkspaceMode",
            "activeProOnlyOverrides",
            "ParameterDocumentationRegistry",
            "ParameterID",
            "AppLanguage",
            "ChiaroSidecar",
        ]
        scan = probe_binary_strings_and_symbols(ctx.cfg.tools, app_exe, required_tokens)
        assert scan["all_found"], f"Missing v1.1 UI symbols/strings in Chiaro executable: {scan['missing']}"

        glass_tokens = [
            "ChiaroGlassContainer",
            "chiaroGlassSurface",
            "chiaroGlassButtonStyle",
            "LiquidGlassSystem",
        ]
        glass_scan = probe_binary_strings_and_symbols(ctx.cfg.tools, app_exe, glass_tokens)
        assert any(tok in glass_scan["matched"] for tok in glass_tokens), (
            f"Missing ADR-016 Liquid Glass API symbols/strings in Chiaro executable (checked {glass_tokens})"
        )

        canvas_scan = probe_neutral_canvas_invariant(ctx.cfg.tools, app_exe)
        assert canvas_scan["ok"], (
            f"Adaptive Liquid Glass canvas invariant failed on Chiaro executable: {canvas_scan}"
        )

        assert info["shaders_metal_files"], "Shaders.metal missing in Chiaro.app"
        shader_text = Path(info["shaders_metal_files"][0]).read_text(encoding="utf-8", errors="replace")
        for kernel_tok in ("optical_correction_kernel", "sigmoid", "clarity", "opposed_inpaint"):
            assert kernel_tok in shader_text.lower(), f"Shaders.metal missing v1.1 kernel token {kernel_tok!r}"

    def t1_v11_24(ctx: RunContext) -> None:
        app = _require_app(ctx)
        info = check_app_bundle_v11(ctx.cfg.tools, app)
        assert info["ok"], f"App bundle check errors: {info['errors']}"
        app_exe = Path(info["executable"])

        for lang in ("zh-Hans", "en"):
            smoke = smoke_launch_app(app_exe, hold_s=3.0, apple_languages=lang)
            assert smoke["ok"], f"Bilingual launch smoke failed for {lang}: {smoke}"

        lang_sym_scan = probe_binary_strings_and_symbols(ctx.cfg.tools, app_exe, ["AppLanguage"])
        assert lang_sym_scan["all_found"], f"Missing AppLanguage symbol/string in Chiaro binary: {lang_sym_scan['missing']}"

        zh_bin_scan = probe_binary_strings_and_symbols(ctx.cfg.tools, app_exe, ["zh-Hans"])
        res_dir = app / "Contents" / "Resources"
        lproj_stems = {Path(p).stem.lower() for p in info.get("lproj_dirs", [])}
        xcstrings_files = list(res_dir.rglob("*.xcstrings")) if res_dir.is_dir() else []
        xcstrings_texts = [p.read_text(encoding="utf-8", errors="replace") for p in xcstrings_files]

        has_zh = (
            bool(zh_bin_scan["matched"])
            or ("zh-hans" in lproj_stems)
            or ("zh_hans" in lproj_stems)
            or any("zh-Hans" in txt for txt in xcstrings_texts)
        )
        has_en = (
            bool(zh_bin_scan["matched"])
            or ("en" in lproj_stems)
            or any('"en"' in txt for txt in xcstrings_texts)
        )
        assert has_zh and has_en, (
            f"Missing zh-Hans/en localization markers in binary strings or .lproj/.xcstrings resources "
            f"(zh_bin={zh_bin_scan['matched']}, lproj={sorted(lproj_stems)}, xcstrings={len(xcstrings_files)})"
        )

    def t1_v11_25(ctx: RunContext) -> None:
        app = _require_app(ctx)
        info = check_app_bundle_v11(ctx.cfg.tools, app)
        assert info["ok"], f"App bundle check errors: {info['errors']}"
        smoke = smoke_launch_app(Path(info["executable"]), hold_s=3.0, reduce_transparency=True)
        assert smoke["ok"], f"Reduce Transparency launch smoke failed: {smoke}"

    # =========================================================================
    # F20: Sony .ARW Focus & Tiered Camera Support (1 test)
    # =========================================================================
    def t1_v11_26(ctx: RunContext) -> None:
        readme = (ctx.cfg.repo_root / "README.md").read_text(encoding="utf-8", errors="replace")
        assert "Supported Cameras" in readme and "ILCE-7CM2" in readme, (
            "README.md missing Supported Cameras table with Tier 1 ILCE-7CM2"
        )

        app = _require_app(ctx)
        info = check_app_bundle_v11(ctx.cfg.tools, app)
        exts = {e.lower() for e in info["doc_extensions"]}
        assert "arw" in exts, f"Info.plist missing arw document type: {info['doc_extensions']}"
        for forbidden_ext in ("cr3", "nef", "raf", "dng"):
            assert forbidden_ext not in exts, f"Untested RAW ext {forbidden_ext!r} leaked into Info.plist"

        in_dir = ctx.test_out_dir("T1-V11-26", "in")
        out_dir = ctx.test_out_dir("T1-V11-26", "out")
        shutil.copy2(ctx.sample_path("DSC02532.ARW"), in_dir / "DSC02532.ARW")
        shutil.copy2(ctx.sample_path("DSC02532.ARW"), in_dir / "lower.arw")
        (in_dir / "DSC02532.HIF").write_bytes(b"fake hif")
        (in_dir / "photo.JPG").write_bytes(b"fake jpg")
        write_sidecar(in_dir / "DSC02532.ARW", build_v11_sidecar())
        (in_dir / "fake.ARW").mkdir()

        res = ctx.run_cli([str(in_dir), "--preset", "apple_heic", "-o", str(out_dir)])
        assert res.returncode == 0, res.stderr
        heics = sorted(p.name for p in out_dir.glob("*.heic"))
        assert heics == ["DSC02532_HDR.heic", "lower_HDR.heic"], f"Unexpected discovered outputs: {heics}"

    tests.extend([
        TestCase("T1-V11-01", 1, "F13", "verify_licenses.sh --require-binaries & SBOM", t1_v11_01, "bash Scripts/verify_licenses.sh --require-binaries"),
        TestCase("T1-V11-02", 1, "F13", "LibRaw + LibRTProcess Demosaic Symbols", t1_v11_02, "nm chiaro-cli & Chiaro (amaze/lmmse/dcb/dht present, zero forbidden)"),
        TestCase("T1-V11-03", 1, "F14", "All 5 Demosaic Algorithms Distinct Pixels & NDJSON", t1_v11_03, "chiaro DSC02532.ARW --demosaic {amaze,lmmse,dcb,dht,ahd} --json-progress"),
        TestCase("T1-V11-04", 1, "F15", "Engine A Embedded Curves FF 16-Node (DSC02532)", t1_v11_04, "chiaro DSC02532.ARW --lens-correction embedded vs off"),
        TestCase("T1-V11-05", 1, "F15", "Engine A Embedded Curves APS-C 11-Node (DSC02556)", t1_v11_05, "chiaro DSC02556.ARW --lens-correction embedded vs off"),
        TestCase("T1-V11-06", 1, "F15", "--lens-correction auto Prefers Embedded on A7C2", t1_v11_06, "chiaro DSC02532.ARW --lens-correction auto vs embedded"),
        TestCase("T1-V11-07", 1, "F15", "Engine B Bundled LensfunDB via Sidecar Override", t1_v11_07, "chiaro DSC02532.ARW + sidecar lensfun A071 override"),
        TestCase("T1-V11-08", 1, "F15", "Engine B Custom User Lensfun XML (HOME Isolated)", t1_v11_08, "HOME=<isolated> chiaro DSC02532.ARW --lens-correction lensfun"),
        TestCase("T1-V11-09", 1, "F15", "Optics Sub-Toggles (distortion, tca, vignetting)", t1_v11_09, "chiaro DSC02532.ARW --lens-{distortion,tca,vignetting} off"),
        TestCase("T1-V11-10", 1, "F15", "Vignetting Strength 0 / 50 / 100 Monotonicity", t1_v11_10, "chiaro DSC02532.ARW --lens-vignetting-strength {0,50,100}"),
        TestCase("T1-V11-11", 1, "F16", "Profiled Denoise ISO 12800 Variance Reduction", t1_v11_11, "chiaro DSC02533.ARW --denoise auto vs off"),
        TestCase("T1-V11-12", 1, "F16", "--denoise-chroma & --denoise-luma Scaling", t1_v11_12, "chiaro DSC02533.ARW --denoise-chroma 100/10 --denoise-luma 80/5"),
        TestCase("T1-V11-13", 1, "F16", "Sigmoid Tone Mapper vs AgX / Neutral / OpenDRT", t1_v11_13, "chiaro DSC02540.ARW --tone-mapper {sigmoid,agx,neutral,opendrt}"),
        TestCase("T1-V11-14", 1, "F16", "Halo-Free Clarity (-60, 0, +60)", t1_v11_14, "chiaro DSC02532.ARW --clarity {-60,0,60}"),
        TestCase("T1-V11-15", 1, "F16", "Physical Optical Sharpness (0, 80)", t1_v11_15, "chiaro DSC02532.ARW --sharpness {0,80}"),
        TestCase("T1-V11-16", 1, "F16", "Upgraded Inpaint Opposed Night Highlight Magenta Check", t1_v11_16, "chiaro DSC02533/DSC02543.ARW magenta highlight check"),
        TestCase("T1-V11-17", 1, "F17", ".chiaro.json v2 Auto-Discovery & Non-Destructive Read", t1_v11_17, "chiaro copied DSC02532.ARW + .chiaro.json"),
        TestCase("T1-V11-18", 1, "F17", "--no-sidecar Ignores .chiaro.json", t1_v11_18, "chiaro copied DSC02532.ARW --no-sidecar"),
        TestCase("T1-V11-19", 1, "F18", "Full 4-Layer Precedence (CLI > --delta-file > Sidecar > Preset)", t1_v11_19, "chiaro -p apple_heic --delta-file --clarity 75 --demosaic dcb + sidecar"),
        TestCase("T1-V11-20", 1, "F18", "NDJSON v1.1 Event Stream Completeness", t1_v11_20, "chiaro DSC02532.ARW --json-progress job_decoded fields"),
        TestCase("T1-V11-21", 1, "F13", "Chiaro.app v1.1 Bundle Resources & Dylib Isolation", t1_v11_21, "check_app_bundle_v11 Chiaro.app"),
        TestCase("T1-V11-22", 1, "F13", "dist/ Release Archives & SHA256SUMS.txt Integrity", t1_v11_22, "shasum -c + unpack chiaro-cli-1.1.1-macos-arm64.tar.gz + export"),
        TestCase("T1-V11-23", 1, "F19", "Packaged Chiaro.app v1.1.1 UI Architecture & Adaptive Liquid Glass Canvas", t1_v11_23, "strings/nm Chiaro.app + adaptive-liquid-glass + Shaders.metal v1.1 kernels"),
        TestCase("T1-V11-24", 1, "F19", "Chiaro.app Bilingual Launch Smoke (zh-Hans & en)", t1_v11_24, "Launch Chiaro 3s with -AppleLanguages (zh-Hans) & (en)"),
        TestCase("T1-V11-25", 1, "F19", "Chiaro.app Reduce Transparency Accessibility Launch Smoke", t1_v11_25, "Launch Chiaro 3s with -NSReduceTransparency YES"),
        TestCase("T1-V11-26", 1, "F20", "Sony .ARW Focus & Supported Cameras Table (README + Info.plist)", t1_v11_26, "README Supported Cameras + Info.plist .ARW + dir filter"),
    ])

    assert len(tests) == 26, f"Expected 26 Tier 1 v1.1 tests, got {len(tests)}"
    return tests

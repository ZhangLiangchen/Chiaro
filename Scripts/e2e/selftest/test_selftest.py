"""Self-test suite validating all probes and assertion helpers on synthetic positive & negative fixtures."""

from __future__ import annotations

import json
import shutil
import struct
import subprocess
from pathlib import Path
from typing import Callable, List, Tuple

from config import E2EConfig
from probes.cli_probes import (
    build_v11_sidecar,
    check_gpl3_compatible_linkage,
    check_zero_gpl_linkage,
    decode_image_to_rgb,
    extract_job_completed_events,
    extract_job_decoded_events,
    measure_edge_acutance,
    measure_hdr_linear_stats,
    measure_highlight_magenta_fraction,
    measure_image_diff,
    measure_midtone_local_contrast,
    measure_region_noise_variance,
    parse_ndjson_events,
    probe_avifdec,
    probe_avifgainmaputil,
    probe_exiftool,
    probe_ffprobe,
    probe_heif_info,
    probe_neutral_canvas_invariant,
    probe_ultrahdr,
    probe_verify_licenses_sbom,
    read_sidecar,
    sidecar_path_for,
    write_sidecar,
)
from probes.isobmff_box import inspect_isobmff
from probes.swift_probes import SwiftProbes
from selftest.fixtures import build_selftest_fixtures
from tests.common import (
    RunContext,
    assert_avif_compliant,
    assert_gpl3_compatible,
    assert_heic_compliant,
    assert_hlg_mp4_compliant,
    assert_jpeg_compliant,
    assert_zero_gpl,
    parse_time_l_peak_rss,
)


def _expect_assertion_fail(fn: Callable[[], None], desc: str) -> None:
    try:
        fn()
    except AssertionError as exc:
        return
    raise AssertionError(f"Negative self-test FAILED to reject defect ({desc})")


def run_selftest(cfg: E2EConfig, probes: SwiftProbes) -> Tuple[bool, List[Tuple[str, bool, str]]]:
    st_dir = cfg.work_dir / "selftest_fixtures"
    bin_dir = cfg.work_dir / "bin"
    fixtures = build_selftest_fixtures(cfg, st_dir, bin_dir)
    ctx = RunContext(cfg, probes)

    checks: List[Tuple[str, Callable[[], None]]] = []

    def st_pos_heic() -> None:
        assert_heic_compliant(
            ctx,
            fixtures["valid_heic"],
            expected_stops=2.5,
            expected_depth=10,
            expect_legacy_gm=False,
            expect_w=256,
            expect_h=256,
            expect_custom_rendered=3,
        )

    def st_pos_jpeg() -> None:
        # CIContext writeJPEGRepresentation writes ISO APP2 + MPF (without XMP-hdrgm)
        assert_jpeg_compliant(
            ctx,
            fixtures["valid_jpg"],
            expected_stops=2.5,
            expect_xmp_hdrgm=False,
            expect_icc_substr="Display P3",
            expect_w=256,
            expect_h=256,
            expect_custom_rendered=3,
        )
        # With XMP-hdrgm injected
        assert_jpeg_compliant(
            ctx,
            fixtures["valid_xmp_jpg"],
            expected_stops=2.5,
            expect_xmp_hdrgm=True,
            expect_icc_substr="Display P3",
            expect_w=256,
            expect_h=256,
            expect_custom_rendered=3,
        )

    def st_pos_avif_grid() -> None:
        res = assert_avif_compliant(
            ctx,
            fixtures["valid_grid_avif"],
            expected_stops=2.5,
            expected_depth=10,
            expect_grid=True,
            expect_gm_yuv="YUV420",
            expect_gm_full_res=False,
            expected_gamma=1.0,
            expect_w=None,
            expect_h=None,
            expect_custom_rendered=3,
            decode_16bit=True,
        )
        agm = res["avifgm"]
        assert agm.base_headroom == 0.0, f"Expected base_headroom=0.0, got {agm.base_headroom}"
        assert agm.alt_headroom == 2.5, f"Expected alt_headroom=2.5, got {agm.alt_headroom}"
        assert agm.gamma == 1.0, f"Expected gamma=1.0, got {agm.gamma}"

    def st_pos_hlg_mp4() -> None:
        assert_hlg_mp4_compliant(
            ctx,
            fixtures["valid_hlg_mp4"],
            allowed_sizes=((1080, 1920),),
            min_dur=2.9,
            max_dur=3.1,
            min_bitrate=None,
            max_bitrate=None,
            expected_fps=30.0,
        )

    def st_neg_no_gainmap_heic() -> None:
        p = fixtures["bad_no_gainmap_heic"]
        iio = probes.probe_image(p)
        assert iio.get("hasISOGainMap") is False
        box = inspect_isobmff(p)
        assert not box.has_tmap_item
        _expect_assertion_fail(
            lambda: assert_heic_compliant(ctx, p, expected_stops=2.5),
            "HEIC missing ISO gainmap / tmap",
        )

    def st_neg_orientation6_jpg() -> None:
        p = fixtures["bad_orientation6_jpg"]
        iio = probes.probe_image(p)
        assert iio.get("orientation") == 6
        ex = probe_exiftool(cfg.tools, p)
        assert ex.orientation_numeric() == 6
        _expect_assertion_fail(
            lambda: assert_jpeg_compliant(ctx, p, expected_stops=2.5, expect_xmp_hdrgm=None),
            "JPEG Orientation=6 != 1",
        )

    def st_neg_makernote_jpg() -> None:
        p = fixtures["bad_makernote_jpg"]
        ex = probe_exiftool(cfg.tools, p)
        assert ex.has_forbidden_sony_or_makernote(), "Expected MakerNote tag in bad_makernote.jpg"
        _expect_assertion_fail(
            lambda: assert_jpeg_compliant(ctx, p, expected_stops=2.5, expect_xmp_hdrgm=None),
            "JPEG MakerNote leak",
        )

    def st_neg_imageio_tmap_avif() -> None:
        p = fixtures["bad_imageio_tmap_avif"]
        adec = probe_avifdec(cfg.tools, p, decode_16bit_png=False)
        assert adec.returncode != 0, "avifdec should reject ImageIO bad tmap AVIF"
        assert "tmap" in (adec.stderr + adec.stdout), f"Expected tmap diagnostic, got: {adec.stderr}"
        _expect_assertion_fail(
            lambda: assert_avif_compliant(ctx, p, expected_stops=2.5, expect_grid=False),
            "ImageIO AVIF Box[tmap] pasp defect",
        )

    def st_neg_sdr_4k_mp4() -> None:
        p = fixtures["bad_sdr_4k_mp4"]
        hlg = probes.probe_hlg_video(p)
        assert hlg.get("isHEVCMain10") is False
        ff = probe_ffprobe(cfg.tools, p)
        assert ff.codec_name == "h264"
        _expect_assertion_fail(
            lambda: assert_hlg_mp4_compliant(ctx, p, min_bitrate=None, max_bitrate=None),
            "SDR 4K H.264 MP4 rejected",
        )

    def st_neg_apple_makernote_jpg() -> None:
        p = fixtures["bad_apple_makernote_jpg"]
        ex = probe_exiftool(cfg.tools, p)
        assert ex.has_forbidden_apple_makernote(), (
            f"Expected Apple:* MakerNote tags in {p.name}, got keys={list(ex.raw_dict.keys())}"
        )
        iio = probes.probe_image(p)
        makers = (iio.get("exif") or {}).get("makerDictionaries") or []
        assert "{MakerApple}" in makers, f"Expected {{MakerApple}} in ImageIOProbe, got {makers}"
        _expect_assertion_fail(
            lambda: assert_jpeg_compliant(ctx, p, expected_stops=2.5, expect_xmp_hdrgm=False),
            "Apple iOS MakerNote 33/48 rejected",
        )

    def st_neg_missing_orientation_jpg() -> None:
        p = fixtures["bad_missing_orientation_jpg"]
        ex = probe_exiftool(cfg.tools, p)
        assert ex.raw_dict.get("IFD0:Orientation") is None, (
            f"Expected IFD0:Orientation to be absent, got {ex.raw_dict.get('IFD0:Orientation')!r}"
        )
        _expect_assertion_fail(
            lambda: assert_jpeg_compliant(ctx, p, expected_stops=2.5, expect_xmp_hdrgm=False),
            "Missing explicit IFD0:Orientation rejected",
        )

    def st_neg_avif_gamma_mismatch() -> None:
        p = fixtures["valid_grid_avif"]
        agm = probe_avifgainmaputil(cfg.tools, p)
        assert agm.gamma is not None and abs(agm.gamma - 1.0) < 0.01
        _expect_assertion_fail(
            lambda: assert_avif_compliant(
                ctx,
                p,
                expected_stops=2.5,
                expected_gamma=1.2,
                expect_grid=True,
                decode_16bit=False,
            ),
            "AVIF gamma=1.0 rejected when expected_gamma=1.2",
        )

    def st_neg_isobmff_malformed() -> None:
        # 1. Missing file -> structured parse_errors (no uncaught exception)
        r_miss = inspect_isobmff(st_dir / "nonexistent_file_xyz.heic")
        assert r_miss.parse_errors, "Expected parse_errors on missing file"

        # 2. Empty 0-byte file
        empty_p = st_dir / "bad_isobmff_empty.heic"
        empty_p.write_bytes(b"")
        r_empty = inspect_isobmff(empty_p)
        assert r_empty.parse_errors, "Expected parse_errors on 0-byte file"

        # 3. Box size < header (size=4 < 8)
        small_p = st_dir / "bad_isobmff_small.heic"
        small_p.write_bytes(struct.pack(">I4s", 4, b"ftyp") + b"heic\x00\x00\x00\x00")
        r_small = inspect_isobmff(small_p)
        assert r_small.parse_errors, "Expected parse_errors on size < hdr box"

        # 4. Truncated box (pos + size > end)
        trunc_p = st_dir / "bad_isobmff_trunc.heic"
        trunc_p.write_bytes(
            struct.pack(">I4s4sI4s", 20, b"ftyp", b"heic", 0, b"heic")
            + struct.pack(">I4s", 50000, b"meta")
            + b"\x00" * 12
        )
        r_trunc = inspect_isobmff(trunc_p)
        assert r_trunc.parse_errors, "Expected parse_errors on truncated box"

        # 5. Premature size == 0 followed by remaining bytes
        zero_p = st_dir / "bad_isobmff_zero.heic"
        zero_p.write_bytes(
            struct.pack(">I4s4sI4s", 20, b"ftyp", b"heic", 0, b"heic")
            + struct.pack(">I4s", 0, b"free")
            + struct.pack(">I4sI", 12, b"meta", 0)
        )
        r_zero = inspect_isobmff(zero_p)
        assert r_zero.parse_errors, "Expected parse_errors on premature size==0 box"

    def st_probe_time_rss_and_sandbox() -> None:
        res = ctx.run_cmd(["/usr/bin/true"], measure_rss=True)
        assert res.returncode == 0
        assert res.peak_rss_bytes is not None and res.peak_rss_bytes > 0, (
            f"Failed to parse /usr/bin/time -l RSS: {res.stderr}"
        )
        sb = cfg.tools.sandbox_exec or "/usr/bin/sandbox-exec"
        sres = ctx.run_cmd([sb, "-p", "(version 1)(allow default)(deny network*)", "/usr/bin/true"])
        assert sres.returncode == 0, f"sandbox-exec failed: {sres.stderr}"

    def st_license_check_smoke() -> None:
        assert check_zero_gpl_linkage is check_gpl3_compatible_linkage, (
            "check_zero_gpl_linkage alias must point to check_gpl3_compatible_linkage"
        )
        res = check_gpl3_compatible_linkage(cfg.tools, Path("/usr/bin/true"), check_symbols=False)
        assert res["clean"], f"Expected /usr/bin/true linkage clean: {res}"
        # Positive check via assert_gpl3_compatible / assert_zero_gpl
        assert_gpl3_compatible(ctx, Path("/usr/bin/true"), check_symbols=False)
        assert_zero_gpl(ctx, Path("/usr/bin/true"), check_symbols=False)
        # Verify ultrahdr_app capability mode is resolved (never 'missing')
        assert cfg.tools.ultrahdr_mode in ("probe_P", "decode_fallback_v1_4"), (
            f"Unexpected ultrahdr_mode: {cfg.tools.ultrahdr_mode}"
        )
        uh = probe_ultrahdr(cfg.tools, fixtures["valid_jpg"])
        assert uh.returncode == 0, f"ultrahdr_app failed on valid.jpg: {uh.stderr}"

    def st_v11_c_shared_symbol_check() -> None:
        ok_c = st_dir / "ok_demosaic.c"
        ok_dylib = st_dir / "libok_demosaic.dylib"
        bad_c = st_dir / "bad_heif.c"
        bad_dylib = st_dir / "libbad_heif.dylib"
        ok_c.write_text("int amaze_demosaic(int x) { return x + 1; }\n", encoding="utf-8")
        bad_c.write_text("void *heif_context_alloc(void) { return 0; }\n", encoding="utf-8")

        subprocess.run(["/usr/bin/cc", "-shared", str(ok_c), "-o", str(ok_dylib)], check=True, capture_output=True, text=True)
        subprocess.run(["/usr/bin/cc", "-shared", str(bad_c), "-o", str(bad_dylib)], check=True, capture_output=True, text=True)

        ok_res = check_gpl3_compatible_linkage(cfg.tools, ok_dylib, check_symbols=True)
        assert ok_res["clean"], f"Expected amaze_demosaic dylib to pass GPL-3.0 scan: {ok_res}"

        bad_res = check_gpl3_compatible_linkage(cfg.tools, bad_dylib, check_symbols=True)
        assert not bad_res["clean"], f"Expected heif_context_ dylib to fail scan: {bad_res}"
        assert "heif_context_" in bad_res["forbidden_symbols"], f"Missing forbidden symbol hit: {bad_res}"

        # Unresolved @rpath/libmissing.dylib must fail when require_self_contained=True
        rpath_stage = st_dir / "rpath_stage"
        rpath_stage.mkdir(parents=True, exist_ok=True)
        miss_c = rpath_stage / "missing_lib.c"
        miss_c.write_text("int chiarotest_missing_sym(void) { return 7; }\n", encoding="utf-8")
        miss_dylib = rpath_stage / "libmissing.dylib"
        subprocess.run(
            ["/usr/bin/cc", "-shared", "-install_name", "@rpath/libmissing.dylib", str(miss_c), "-o", str(miss_dylib)],
            check=True, capture_output=True, text=True,
        )
        caller_c = rpath_stage / "caller.c"
        caller_c.write_text("int chiarotest_missing_sym(void); int main(void) { return chiarotest_missing_sym(); }\n", encoding="utf-8")
        broken_exe = rpath_stage / "exe_rpath_broken"
        subprocess.run(
            ["/usr/bin/cc", str(caller_c), str(miss_dylib), "-o", str(broken_exe)],
            check=True, capture_output=True, text=True,
        )
        miss_dylib.unlink()
        broken_res = check_gpl3_compatible_linkage(
            cfg.tools, broken_exe, check_symbols=False, require_self_contained=True
        )
        assert not broken_res["clean"], f"Expected unresolved @rpath to fail self-contained linkage: {broken_res}"
        assert "@rpath/libmissing.dylib" in broken_res["unresolved_rpaths"], (
            f"Expected @rpath/libmissing.dylib in unresolved_rpaths: {broken_res}"
        )

        # Resolved self-contained @rpath via @executable_path must pass
        ok_rpath_dir = rpath_stage / "ok_bundle"
        ok_rpath_dir.mkdir(parents=True, exist_ok=True)
        present_dylib = ok_rpath_dir / "libpresent_rpath.dylib"
        subprocess.run(
            ["/usr/bin/cc", "-shared", "-install_name", "@rpath/libpresent_rpath.dylib", str(miss_c), "-o", str(present_dylib)],
            check=True, capture_output=True, text=True,
        )
        ok_rpath_exe = ok_rpath_dir / "exe_rpath_ok"
        subprocess.run(
            ["/usr/bin/cc", "-Wl,-rpath,@executable_path", str(caller_c), str(present_dylib), "-o", str(ok_rpath_exe)],
            check=True, capture_output=True, text=True,
        )
        ok_rpath_res = check_gpl3_compatible_linkage(
            cfg.tools, ok_rpath_exe, check_symbols=False, require_self_contained=True
        )
        assert ok_rpath_res["clean"], f"Expected self-contained @rpath executable to pass: {ok_rpath_res}"

        # Stray forbidden LC_RPATH (/opt/homebrew/lib) without @rpath dylib dep must still fail
        hb_rpath_c = rpath_stage / "hb_rpath_only.c"
        hb_rpath_c.write_text("int main(void) { return 0; }\n", encoding="utf-8")
        hb_rpath_exe = rpath_stage / "exe_hb_rpath"
        subprocess.run(
            ["/usr/bin/cc", "-Wl,-rpath,/opt/homebrew/lib", str(hb_rpath_c), "-o", str(hb_rpath_exe)],
            check=True, capture_output=True, text=True,
        )
        hb_rpath_res = check_gpl3_compatible_linkage(
            cfg.tools, hb_rpath_exe, check_symbols=False, require_self_contained=True
        )
        assert not hb_rpath_res["clean"], (
            f"Expected stray /opt/homebrew/lib LC_RPATH to fail self-contained linkage: {hb_rpath_res}"
        )
        assert "/opt/homebrew/lib" in hb_rpath_res["unbundled_refs"], (
            f"Expected /opt/homebrew/lib in unbundled_refs: {hb_rpath_res}"
        )

        # Stray /tmp/ LC_RPATH without @rpath dylib dep must fail in dangling_refs
        tmp_rpath_exe = rpath_stage / "exe_tmp_rpath"
        subprocess.run(
            ["/usr/bin/cc", "-Wl,-rpath,/tmp/chiaro_rpath_leak", str(hb_rpath_c), "-o", str(tmp_rpath_exe)],
            check=True, capture_output=True, text=True,
        )
        tmp_rpath_res = check_gpl3_compatible_linkage(
            cfg.tools, tmp_rpath_exe, check_symbols=False, require_self_contained=True
        )
        assert not tmp_rpath_res["clean"], (
            f"Expected stray /tmp/ LC_RPATH to fail self-contained linkage: {tmp_rpath_res}"
        )
        assert "/tmp/chiaro_rpath_leak" in tmp_rpath_res["dangling_refs"], (
            f"Expected /tmp/chiaro_rpath_leak in dangling_refs: {tmp_rpath_res}"
        )

    def st_v11_ndjson_parsing() -> None:
        sample_ndjson = "\n".join([
            "non-json log line",
            json.dumps({"event": "batch_start", "totalJobs": 1, "preset": "apple_heic", "formats": ["heic"]}),
            json.dumps({"event": "job_started", "jobID": "111", "source": "/a/DSC02532.ARW", "filename": "DSC02532.ARW"}),
            json.dumps({
                "event": "job_decoded",
                "jobID": "111",
                "source": "/a/DSC02532.ARW",
                "filename": "DSC02532.ARW",
                "backend": "libraw",
                "demosaicUsed": "amaze",
                "opticsSource": "embedded_arw",
                "lensMatched": "TAMRON 25-200mm F2.8-5.6 A075 E",
            }),
            json.dumps({
                "event": "job_completed",
                "jobID": "111",
                "source": "/a/DSC02532.ARW",
                "filename": "DSC02532.ARW",
                "backend": "libraw",
                "elapsedSeconds": 1.2,
                "artifacts": [],
            }),
        ])
        evs = parse_ndjson_events(sample_ndjson)
        assert len(evs) == 4
        jd = extract_job_decoded_events(sample_ndjson)
        assert len(jd) == 1
        assert jd[0]["demosaicUsed"] == "amaze"
        assert jd[0]["opticsSource"] == "embedded_arw"
        assert "TAMRON" in jd[0]["lensMatched"]
        jc = extract_job_completed_events(sample_ndjson)
        assert len(jc) == 1 and jc[0]["elapsedSeconds"] == 1.2

    def st_v11_sidecar_roundtrip() -> None:
        fake_raw = st_dir / "synthetic_photo.ARW"
        fake_raw.write_bytes(b"RAW")
        payload = build_v11_sidecar(
            preset_id="apple_heic",
            demosaic="lmmse",
            optics={"enabled": True, "source": "auto"},
            delta={"clarityOverride": 25.0, "opticalSharpnessOverride": 40.0},
            denoise={"mode": "profiledWavelet", "luminanceStrength": 25.0, "chromaStrength": 65.0},
            ai_color={"enabled": False, "toneEqualizer": [0.0] * 8},
            extra={"extra_v4": {"experimental": True}},
        )
        sc_path = write_sidecar(fake_raw, payload)
        assert sc_path == sidecar_path_for(fake_raw)
        assert sc_path.name == "synthetic_photo.ARW.chiaro.json"
        loaded = read_sidecar(fake_raw)
        assert loaded["schemaVersion"] == 2
        assert loaded["demosaic"] == "lmmse"
        assert loaded["denoise"]["mode"] == "profiledWavelet"
        assert loaded["aiColor"]["toneEqualizer"] == [0.0] * 8
        assert loaded["extra_v4"]["experimental"] is True

    def st_v11_pixel_iq_and_hdr_probes() -> None:
        from PIL import Image, ImageFilter  # type: ignore

        heic_rgb = decode_image_to_rgb(cfg.tools, fixtures["valid_heic"], max_dim=256)
        jpg_rgb = decode_image_to_rgb(cfg.tools, fixtures["valid_jpg"], max_dim=256)
        assert heic_rgb.size == (256, 256) and jpg_rgb.size == (256, 256)

        self_diff = measure_image_diff(cfg.tools, heic_rgb, heic_rgb, max_dim=None)
        assert self_diff["mean_abs_diff"] == 0.0 and self_diff["max_diff"] == 0.0

        # Synthetic sharp edge vs blurred image + noisy vs smooth image
        sharp_img = Image.new("RGB", (128, 128), (40, 40, 40))
        for y in range(128):
            for x in range(64, 128):
                sharp_img.putpixel((x, y), (200, 200, 200))
        blurred_img = sharp_img.filter(ImageFilter.BoxBlur(3))
        sharp_p = st_dir / "sharp.png"
        blur_p = st_dir / "blur.png"
        sharp_img.save(sharp_p)
        blurred_img.save(blur_p)

        ac_sharp = measure_edge_acutance(cfg.tools, sharp_p, box_norm=(0.1, 0.1, 0.9, 0.9), max_dim=None)
        ac_blur = measure_edge_acutance(cfg.tools, blur_p, box_norm=(0.1, 0.1, 0.9, 0.9), max_dim=None)
        assert ac_sharp > ac_blur, f"Expected sharp acutance > blurred: {ac_sharp} <= {ac_blur}"

        lc_sharp = measure_midtone_local_contrast(cfg.tools, sharp_p, max_dim=None, luma_range=(0.1, 0.9))
        lc_blur = measure_midtone_local_contrast(cfg.tools, blur_p, max_dim=None, luma_range=(0.1, 0.9))
        assert lc_sharp > lc_blur, f"Expected sharp local contrast > blurred: {lc_sharp} <= {lc_blur}"

        noisy = Image.new("RGB", (128, 128), (30, 30, 30))
        for y in range(128):
            for x in range(128):
                delta = 25 if ((x + y) % 2 == 0) else -25
                noisy.putpixel((x, y), (30 + delta, 30 - delta, 30 + delta))
        noisy_p = st_dir / "noisy.png"
        denoised_p = st_dir / "denoised.png"
        noisy.save(noisy_p)
        noisy.filter(ImageFilter.BoxBlur(2)).save(denoised_p)

        nv_noisy = measure_region_noise_variance(cfg.tools, noisy_p, box_norm=None, max_dim=None)
        nv_clean = measure_region_noise_variance(cfg.tools, denoised_p, box_norm=None, max_dim=None)
        assert nv_clean["chroma_var"] < 0.25 * nv_noisy["chroma_var"], (
            f"Expected denoised chroma_var drop: {nv_clean} vs {nv_noisy}"
        )

        hdr = measure_hdr_linear_stats(cfg.tools, fixtures["valid_heic"], bin_dir)
        assert hdr["nanCount"] == 0 and hdr["infCount"] == 0
        assert hdr["hdrMaxChannel"] > 1.5, f"Expected valid_heic hdrMaxChannel > 1.5, got {hdr}"

    def st_v11_magenta_highlight_probe() -> None:
        from PIL import Image  # type: ignore

        clean_hi = Image.new("RGB", (64, 64), (245, 245, 245))
        mag_hi = Image.new("RGB", (64, 64), (245, 170, 245))
        clean_p = st_dir / "clean_hi.png"
        mag_p = st_dir / "magenta_hi.png"
        clean_hi.save(clean_p)
        mag_hi.save(mag_p)

        r_clean = measure_highlight_magenta_fraction(cfg.tools, clean_p, max_dim=None)
        r_mag = measure_highlight_magenta_fraction(cfg.tools, mag_p, max_dim=None)
        assert r_clean["magenta_fraction"] == 0.0, f"False positive magenta on white: {r_clean}"
        assert r_mag["magenta_fraction"] > 0.9, f"Failed to detect synthetic magenta highlight: {r_mag}"

    def st_v11_sbom_probe() -> None:
        sbom = probe_verify_licenses_sbom(cfg.repo_root, require_binaries=False)
        assert sbom["returncode"] == 0, f"verify_licenses.sh failed in selftest: {sbom['stderr']}\n{sbom['stdout']}"
        assert sbom["all_ok"], f"SBOM rows had failures: {sbom['rows']}"
        comps = {r["component"] for r in sbom["rows"]}
        for expected in ("Chiaro", "LibRaw", "CarVac/librtprocess", "Lensfun"):
            assert expected in comps, f"Missing SBOM component {expected!r}: {comps}"

    def st_v11_neutral_canvas_binary_probe() -> None:
        swiftc = cfg.tools.swiftc or "/usr/bin/swiftc"
        canvas_dir = st_dir / "canvas_probe"
        canvas_dir.mkdir(parents=True, exist_ok=True)

        def _compile_canvas(
            name: str,
            *,
            style_id: str,
            include_locked_dark: bool = False,
        ) -> Path:
            src = canvas_dir / f"{name}.swift"
            exe = canvas_dir / name
            locked_member = (
                '    public static let lockedDarkHex: String = "#111214"\n'
                if include_locked_dark
                else ""
            )
            locked_modifier = (
                '\n                .accessibilityIdentifier("chiaro.legacy.\\(LiquidGlassSystem.lockedDarkHex)")'
                if include_locked_dark
                else ""
            )
            src.write_text(
                f"""import AppKit
import Metal
import MetalKit
import SwiftUI

public enum LiquidGlassSystem {{
    public static let adaptiveCanvasStyleIdentifier: String = "{style_id}"
{locked_member}    @MainActor
    public static func adaptiveCanvasClearColor(for appearance: NSAppearance?) -> MTLClearColor {{
        let isDark = appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let v = isDark ? 0.015 : 0.90
        return MTLClearColor(red: v, green: v, blue: v, alpha: 1.0)
    }}
}}

struct PreviewCanvasView: View {{
    var body: some View {{
        Color.clear
            .background(.background)
    }}
}}

struct EDRMetalPreviewView: NSViewRepresentable {{
    func makeNSView(context: Context) -> MTKView {{
        let view = MTKView(frame: .zero, device: nil)
        view.clearColor = LiquidGlassSystem.adaptiveCanvasClearColor(for: view.effectiveAppearance)
        return view
    }}
    func updateNSView(_ nsView: MTKView, context: Context) {{
        nsView.clearColor = LiquidGlassSystem.adaptiveCanvasClearColor(for: nsView.effectiveAppearance)
    }}
}}

@main
struct CanvasMain: App {{
    var body: some Scene {{
        WindowGroup {{
            VStack {{
                PreviewCanvasView()
                    .accessibilityIdentifier("chiaro.canvas.\\(LiquidGlassSystem.adaptiveCanvasStyleIdentifier)")
                EDRMetalPreviewView(){locked_modifier}
            }}
        }}
    }}
}}
""",
                encoding="utf-8",
            )
            subprocess.run(
                [swiftc, "-swift-version", "6", "-parse-as-library", "-O", "-whole-module-optimization", str(src), "-o", str(exe)],
                check=True, capture_output=True, text=True,
            )
            return exe

        ok_adaptive = _compile_canvas("canvas_ok_adaptive", style_id="adaptive-liquid-glass")
        res_ok = probe_neutral_canvas_invariant(cfg.tools, ok_adaptive)
        assert res_ok["ok"], f"Expected adaptive Liquid Glass canvas Release binary to pass: {res_ok}"

        bad_missing = _compile_canvas("canvas_bad_missing_adaptive", style_id="legacy-static")
        res_missing = probe_neutral_canvas_invariant(cfg.tools, bad_missing)
        assert not res_missing["ok"], f"Expected binary lacking adaptive-liquid-glass marker to fail: {res_missing}"

        bad_locked = _compile_canvas("canvas_bad_locked_dark", style_id="adaptive-liquid-glass", include_locked_dark=True)
        res_locked = probe_neutral_canvas_invariant(cfg.tools, bad_locked)
        assert not res_locked["ok"], f"Expected binary still locking #111214 dark canvas to fail: {res_locked}"

    checks.extend([
        ("ST-01 Positive HEIC (10-bit P3 + ISO tmap + EXIF)", st_pos_heic),
        ("ST-02 Positive JPEG (APP2 + MPF + XMP-hdrgm + ultrahdr_app)", st_pos_jpeg),
        ("ST-03 Positive AVIF Grid (2x2 grid + tmap + 10-bit + 16-bit decode)", st_pos_avif_grid),
        ("ST-04 Positive HLG MP4 (HEVC Main10 + BT.2020 + HLG + hvcC)", st_pos_hlg_mp4),
        ("ST-05 Negative HEIC (missing ISO gainmap / tmap rejected)", st_neg_no_gainmap_heic),
        ("ST-06 Negative JPEG (Orientation=6 rejected)", st_neg_orientation6_jpg),
        ("ST-07 Negative JPEG (Sony/ExifIFD MakerNote leak rejected)", st_neg_makernote_jpg),
        ("ST-08 Negative AVIF (ImageIO Box[tmap] pasp defect rejected)", st_neg_imageio_tmap_avif),
        ("ST-09 Negative MP4 (H.264 4K SDR BT.709 rejected)", st_neg_sdr_4k_mp4),
        ("ST-10 Utility Probes (/usr/bin/time -l RSS + sandbox-exec)", st_probe_time_rss_and_sandbox),
        ("ST-11 GPL-3.0 Linkage + Alias + ultrahdr_app Probe", st_license_check_smoke),
        ("ST-12 Negative JPEG (Apple iOS MakerNote 33/48 rejected)", st_neg_apple_makernote_jpg),
        ("ST-13 Negative JPEG (Missing IFD0:Orientation rejected)", st_neg_missing_orientation_jpg),
        ("ST-14 Negative AVIF (Gamma 1.0 vs expected 1.2 rejected)", st_neg_avif_gamma_mismatch),
        ("ST-15 Negative ISOBMFF (Malformed/empty/missing parse_errors)", st_neg_isobmff_malformed),
        ("ST-16 v1.1 C Shared Object GPL-3.0 Symbol Scan (amaze ok vs heif_context_ fail)", st_v11_c_shared_symbol_check),
        ("ST-17 v1.1 NDJSON Event Parsing (job_decoded & job_completed)", st_v11_ndjson_parsing),
        ("ST-18 v1.1 .chiaro.json v2 Sidecar & Forward-Compat Roundtrip", st_v11_sidecar_roundtrip),
        ("ST-19 v1.1 Decode (sips/PIL) + Diff + Noise + Acutance + HDR Float32 Probe", st_v11_pixel_iq_and_hdr_probes),
        ("ST-20 v1.1 Highlight Magenta Fraction Probe", st_v11_magenta_highlight_probe),
        ("ST-21 v1.1 verify_licenses.sh SBOM Table Probe", st_v11_sbom_probe),
        ("ST-22 v1.1.1 Adaptive Liquid Glass Canvas Swift 6 Release Binary Probe", st_v11_neutral_canvas_binary_probe),
    ])

    results: List[Tuple[str, bool, str]] = []
    all_ok = True
    for name, fn in checks:
        try:
            fn()
            results.append((name, True, "PASS"))
        except Exception as exc:
            all_ok = False
            results.append((name, False, f"{type(exc).__name__}: {exc}"))
            if cfg.fail_fast:
                break

    return all_ok, results

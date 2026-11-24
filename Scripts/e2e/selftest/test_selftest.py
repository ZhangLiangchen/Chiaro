"""Self-test suite validating all probes and assertion helpers on synthetic positive & negative fixtures."""

from __future__ import annotations

import shutil
import struct
from pathlib import Path
from typing import Callable, List, Tuple

from config import E2EConfig
from probes.cli_probes import (
    check_zero_gpl_linkage,
    probe_avifdec,
    probe_avifgainmaputil,
    probe_exiftool,
    probe_ffprobe,
    probe_heif_info,
    probe_ultrahdr,
)
from probes.isobmff_box import inspect_isobmff
from probes.swift_probes import SwiftProbes
from selftest.fixtures import build_selftest_fixtures
from tests.common import (
    RunContext,
    assert_avif_compliant,
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
        # Positive check on system binary (/usr/bin/true)
        assert_zero_gpl(ctx, Path("/usr/bin/true"), check_symbols=False)
        # Verify ultrahdr_app capability mode is resolved (never 'missing')
        assert cfg.tools.ultrahdr_mode in ("probe_P", "decode_fallback_v1_4"), (
            f"Unexpected ultrahdr_mode: {cfg.tools.ultrahdr_mode}"
        )
        uh = probe_ultrahdr(cfg.tools, fixtures["valid_jpg"])
        assert uh.returncode == 0, f"ultrahdr_app failed on valid.jpg: {uh.stderr}"

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
        ("ST-11 License Scan + ultrahdr_app Probe", st_license_check_smoke),
        ("ST-12 Negative JPEG (Apple iOS MakerNote 33/48 rejected)", st_neg_apple_makernote_jpg),
        ("ST-13 Negative JPEG (Missing IFD0:Orientation rejected)", st_neg_missing_orientation_jpg),
        ("ST-14 Negative AVIF (Gamma 1.0 vs expected 1.2 rejected)", st_neg_avif_gamma_mismatch),
        ("ST-15 Negative ISOBMFF (Malformed/empty/missing parse_errors)", st_neg_isobmff_malformed),
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

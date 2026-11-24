# Chiaro V1.0 Opaque-Box E2E Test Suite

Independent, requirement-driven 4-tier end-to-end verification suite for `ChiaroCore`, `chiaro`, `Chiaro.app`, built-in `Presets/*.json`, and zero-GPL/LGPL native dependency compliance.

## Structure

- `run_e2e.py` — Main CLI orchestrator (`--tier`, `--self-test`, `--list-tests`, `--dry-run`, `--json-report`, etc.)
- `config.py` — Auto-discovery for `chiaro`, `Chiaro.app`, `ultrahdr_app` (`-P` vs v1.4.0 `-m 1` decode fallback), host tools, and Tangmo 35-ARW catalog
- `probes/`
  - `ImageIOProbe.swift` — Swift 6 Apple `ImageIO` / `CoreGraphics` probe (`img.contentHeadroom`, `ISOGainMap`, `HDRGainMap`, `Depth`, `Orientation`, EXIF/MakerNote, pixel stats)
  - `HLGVideoProbe.swift` — Swift 6 `AVFoundation` + `hvcC` atom probe (`Main 10`, 10-bit luma/chroma, `ITU_R_2020`, `ITU_R_2100_HLG`)
  - `swift_probes.py` — On-demand `swiftc -swift-version 6 -O` compiler and JSON runner for `ImageIOProbe` & `HLGVideoProbe`
  - `isobmff_box.py` — Pure-Python ISOBMFF box parser (`ftyp`, `iinf`, `iref`/`dimg`, `grpl`/`altr`, `grid`, `tmap` forbidden-property check, `parse_errors`)
  - `cli_probes.py` — Wrappers for `exiftool`, `avifdec`, `avifgainmaputil`, `ffprobe`, `heif-info`, `ultrahdr_app`, `otool`, `nm`, `codesign`, `plutil`
- `selftest/` — Zero-dependency synthetic positive + negative fixture generator (`generate_fixtures.swift`, `fixtures.py`) and 15-check probe validation (`test_selftest.py`)
- `tests/`
  - `tier1_features.py` — **70** feature tests (`F01`–`F12`, all 7 presets, all CLI flags, all 4 encoders)
  - `tier2_boundaries.py` — **70** boundary, negative, orientation, grid, size, conflict, and RSS tests
  - `tier3_pairwise.py` — **16** cross-feature pairwise tests (`T3-01`..`T3-16`)
  - `tier4_scenarios.py` — **8** real-world scenario tests (`T4-01`..`T4-08`)

## Usage

```bash
# 1. List all 164 tests
python3 Scripts/e2e/run_e2e.py --list-tests

# 2. Validate probes and assertion helpers using synthetic fixtures (no chiaro required)
python3 Scripts/e2e/run_e2e.py --self-test --verbose

# 3. Inspect resolved binaries and planned commands without running
python3 Scripts/e2e/run_e2e.py --dry-run --tier all

# 4. Run full 4-tier E2E suite against built binaries
python3 Scripts/e2e/run_e2e.py --tier all --json-report /tmp/chiaro_e2e_report.json

# 5. Acceptance run populating output_verify/
python3 Scripts/e2e/run_e2e.py --tier 4 --output-verify-dir ./output_verify
```

## Exit Codes

- `0`: All selected tests (or self-test / list / dry-run) passed
- `1`: One or more tests failed
- `2`: Configuration, binary discovery, or missing host tool error

#!/usr/bin/env python3
"""Chiaro V1.1 Opaque-Box 4-Tier E2E Test Suite Runner."""

from __future__ import annotations

import argparse
import json
import platform
import sys
import time
import traceback
from dataclasses import asdict
from pathlib import Path
from typing import Any, Dict, List, Optional

E2E_DIR = Path(__file__).resolve().parent
if str(E2E_DIR) not in sys.path:
    sys.path.insert(0, str(E2E_DIR))

from config import ConfigError, E2EConfig, build_config
from probes.swift_probes import SwiftProbes
from selftest.test_selftest import run_selftest
from tests import (
    tier1_features,
    tier1_v11,
    tier2_boundaries,
    tier2_v11,
    tier3_pairwise,
    tier3_v11,
    tier4_scenarios,
    tier4_v11,
)
from tests.common import RunContext, TestCase, TestResult


def collect_tests(
    tier: str,
    filter_substr: Optional[str],
    *,
    feature_substr: Optional[str] = None,
    baseline_only: bool = False,
    v11_only: bool = False,
) -> List[TestCase]:
    if baseline_only and v11_only:
        raise ValueError("--baseline-only and --v11-only are mutually exclusive")

    all_cases: List[TestCase] = []
    include_baseline = not v11_only
    include_v11 = not baseline_only

    if tier in ("1", "all"):
        if include_baseline:
            all_cases.extend(tier1_features.get_tests())
        if include_v11:
            all_cases.extend(tier1_v11.get_tests())
    if tier in ("2", "all"):
        if include_baseline:
            all_cases.extend(tier2_boundaries.get_tests())
        if include_v11:
            all_cases.extend(tier2_v11.get_tests())
    if tier in ("3", "all"):
        if include_baseline:
            all_cases.extend(tier3_pairwise.get_tests())
        if include_v11:
            all_cases.extend(tier3_v11.get_tests())
    if tier in ("4", "all"):
        if include_baseline:
            all_cases.extend(tier4_scenarios.get_tests())
        if include_v11:
            all_cases.extend(tier4_v11.get_tests())

    if feature_substr:
        f_needle = feature_substr.lower()
        all_cases = [tc for tc in all_cases if f_needle in tc.feature.lower()]

    if filter_substr:
        needle = filter_substr.lower()
        all_cases = [
            tc for tc in all_cases
            if needle in tc.test_id.lower() or needle in tc.name.lower() or needle in tc.feature.lower()
        ]
    return all_cases


def print_test_table(cases: List[TestCase]) -> None:
    print(f"{'ID':<12} | {'Tier':<4} | {'Feature':<8} | {'Name'}")
    print("-" * 78)
    for tc in cases:
        print(f"{tc.test_id:<12} | {tc.tier:<4} | {tc.feature:<8} | {tc.name}")
    print("-" * 78)
    counts = {t: sum(1 for c in cases if c.tier == t) for t in (1, 2, 3, 4)}
    print(
        f"Total: {len(cases)} tests "
        f"(Tier 1: {counts[1]}, Tier 2: {counts[2]}, Tier 3: {counts[3]}, Tier 4: {counts[4]})"
    )


def write_json_report(
    report_path: Path,
    *,
    mode: str,
    cfg: Optional[E2EConfig],
    results: List[Dict[str, Any]],
    passed: int,
    failed: int,
) -> None:
    payload: Dict[str, Any] = {
        "mode": mode,
        "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "host": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "python": platform.python_version(),
        },
        "resolved": {
            "cli_bin": str(cfg.cli_bin) if (cfg and cfg.cli_bin) else "PENDING_BUILD",
            "app_bundle": str(cfg.app_bundle) if (cfg and cfg.app_bundle) else "PENDING_BUILD",
            "sample_dir": str(cfg.sample_dir) if cfg else None,
            "work_dir": str(cfg.work_dir) if cfg else None,
            "output_verify_dir": str(cfg.output_verify_dir) if (cfg and cfg.output_verify_dir) else None,
            "ultrahdr_app": cfg.tools.ultrahdr_app if cfg else None,
            "ultrahdr_mode": cfg.tools.ultrahdr_mode if cfg else None,
            "tool_versions": cfg.tools.versions if cfg else {},
        },
        "summary": {
            "total": passed + failed,
            "passed": passed,
            "failed": failed,
        },
        "results": results,
    }
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="run_e2e.py",
        description="Chiaro V1.1 Opaque-Box 4-Tier E2E Test Suite",
    )
    parser.add_argument(
        "--tier",
        choices=["1", "2", "3", "4", "all"],
        default="all",
        help="Select tier to run or list (default: all)",
    )
    suite_group = parser.add_mutually_exclusive_group()
    suite_group.add_argument(
        "--baseline-only",
        action="store_true",
        help="Include only the 164 v1.0 baseline E2E tests",
    )
    suite_group.add_argument(
        "--v11-only",
        action="store_true",
        help="Include only the 66 v1.1 E2E tests",
    )
    parser.add_argument(
        "--feature",
        type=str,
        default=None,
        help="Case-insensitive filter on feature ID/tag (e.g. F01, F13, Pairwise)",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Run zero-dependency synthetic fixture self-test on all probes & assertions",
    )
    parser.add_argument(
        "--list-tests",
        action="store_true",
        help="List all matching tests and exit 0",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Run tool/binary discovery and print planned test commands without executing",
    )
    parser.add_argument("--cli-bin", type=str, default=None, help="Path to chiaro binary")
    parser.add_argument("--app-bundle", type=str, default=None, help="Path to Chiaro.app bundle")
    parser.add_argument(
        "--sample-dir",
        type=str,
        default=None,
        help="Path to Tangmo sample .ARW directory (default: $CHIARO_SAMPLE_DIR or ./Samples)",
    )
    parser.add_argument("--work-dir", type=str, default=None, help="Scratch working directory")
    parser.add_argument(
        "--output-verify-dir",
        type=str,
        default=None,
        help="Optional acceptance directory to mirror Tier 4 verified exports",
    )
    parser.add_argument("--json-report", type=str, default=None, help="Write structured JSON report to path")
    parser.add_argument("--filter", type=str, default=None, help="Case-insensitive substring filter on test ID/name/feature")
    parser.add_argument("--fail-fast", action="store_true", help="Abort immediately on first failure")
    parser.add_argument("--verbose", action="store_true", help="Print detailed command & probe output")
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        cases = collect_tests(
            args.tier,
            args.filter,
            feature_substr=args.feature,
            baseline_only=args.baseline_only,
            v11_only=args.v11_only,
        )
    except ValueError as exc:
        print(f"[CONFIG ERROR] {exc}", file=sys.stderr)
        return 2

    if args.list_tests:
        print_test_table(cases)
        return 0

    if args.self_test:
        try:
            cfg = build_config(
                cli_bin=args.cli_bin,
                app_bundle=args.app_bundle,
                sample_dir=args.sample_dir,
                work_dir=args.work_dir,
                output_verify_dir=args.output_verify_dir,
                verbose=args.verbose,
                fail_fast=args.fail_fast,
                require_cli=False,
                require_samples=False,
                self_test_only=True,
            )
        except ConfigError as exc:
            print(f"[CONFIG ERROR] {exc}", file=sys.stderr)
            return 2

        probes = SwiftProbes(cfg.tools.swiftc or "/usr/bin/swiftc", cfg.e2e_root / "probes", cfg.work_dir / "bin")
        print(f"Running E2E Self-Test (ultrahdr_app mode: {cfg.tools.ultrahdr_mode}, work_dir: {cfg.work_dir})")
        ok, results = run_selftest(cfg, probes)
        passed = sum(1 for _, p, _ in results if p)
        failed = len(results) - passed
        for name, is_pass, msg in results:
            tag = "PASS" if is_pass else "FAIL"
            if args.verbose or not is_pass:
                print(f"  [{tag}] {name}: {msg}")
            else:
                print(f"  [{tag}] {name}")
        print(f"Self-test summary: {passed}/{len(results)} passed, {failed} failed")
        if args.json_report:
            write_json_report(
                Path(args.json_report),
                mode="self-test",
                cfg=cfg,
                results=[{"name": n, "status": "PASS" if p else "FAIL", "message": m} for n, p, m in results],
                passed=passed,
                failed=failed,
            )
        return 0 if ok else 1

    if args.dry_run:
        try:
            cfg = build_config(
                cli_bin=args.cli_bin,
                app_bundle=args.app_bundle,
                sample_dir=args.sample_dir,
                work_dir=args.work_dir,
                output_verify_dir=args.output_verify_dir,
                verbose=args.verbose,
                fail_fast=args.fail_fast,
                require_cli=False,
                require_samples=False,
                self_test_only=False,
            )
        except ConfigError as exc:
            print(f"[CONFIG ERROR] {exc}", file=sys.stderr)
            return 2

        cli_disp = str(cfg.cli_bin) if cfg.cli_bin else "PENDING_BUILD (<unresolved>)"
        app_disp = str(cfg.app_bundle) if cfg.app_bundle else "PENDING_BUILD (<unresolved>)"
        print("=== Chiaro E2E Dry-Run Discovery ===")
        print(f"  chiaro : {cli_disp}")
        print(f"  Chiaro.app : {app_disp}")
        print(f"  sample_dir   : {cfg.sample_dir} ({'exists' if cfg.sample_dir.is_dir() else 'MISSING'})")
        print(f"  work_dir     : {cfg.work_dir}")
        print(f"  ultrahdr_app : {cfg.tools.ultrahdr_app} [{cfg.tools.ultrahdr_mode}]")
        print(f"  Planned tests: {len(cases)}")
        for tc in cases:
            print(f"  [DRY-RUN] {tc.test_id:<10} (T{tc.tier} {tc.feature:<8}) {tc.name} :: {tc.planned_cmd}")
        if args.json_report:
            write_json_report(
                Path(args.json_report),
                mode="dry-run",
                cfg=cfg,
                results=[
                    {
                        "id": tc.test_id,
                        "tier": tc.tier,
                        "feature": tc.feature,
                        "name": tc.name,
                        "status": "DRY_RUN",
                        "planned_cmd": tc.planned_cmd,
                    }
                    for tc in cases
                ],
                passed=len(cases),
                failed=0,
            )
        return 0

    # Full test execution
    try:
        cfg = build_config(
            cli_bin=args.cli_bin,
            app_bundle=args.app_bundle,
            sample_dir=args.sample_dir,
            work_dir=args.work_dir,
            output_verify_dir=args.output_verify_dir,
            verbose=args.verbose,
            fail_fast=args.fail_fast,
            require_cli=True,
            require_samples=True,
            self_test_only=False,
        )
    except ConfigError as exc:
        print(f"[CONFIG ERROR] {exc}", file=sys.stderr)
        return 2

    probes = SwiftProbes(cfg.tools.swiftc or "/usr/bin/swiftc", cfg.e2e_root / "probes", cfg.work_dir / "bin")
    probes.ensure_imageio_probe()
    probes.ensure_hlg_video_probe()
    ctx = RunContext(cfg, probes)

    print(f"=== Running {len(cases)} Chiaro E2E Tests (tier={args.tier}) ===")
    print(f"  cli_bin    : {cfg.cli_bin}")
    print(f"  app_bundle : {cfg.app_bundle or '<not found>'}")
    print(f"  sample_dir : {cfg.sample_dir}")
    print(f"  work_dir   : {cfg.work_dir}")
    print(f"  ultrahdr   : {cfg.tools.ultrahdr_app} [{cfg.tools.ultrahdr_mode}]")

    results: List[TestResult] = []
    passed = 0
    failed = 0

    for tc in cases:
        ctx.reset_tracking()
        t0 = time.monotonic()
        err_str: Optional[str] = None
        status = "PASS"
        try:
            tc.run(ctx)
            passed += 1
        except Exception as exc:
            status = "FAIL"
            failed += 1
            if args.verbose:
                err_str = f"{type(exc).__name__}: {exc}\n{traceback.format_exc()}"
            else:
                err_str = f"{type(exc).__name__}: {exc}"
        dt = time.monotonic() - t0
        tr = TestResult(
            test_id=tc.test_id,
            tier=tc.tier,
            feature=tc.feature,
            name=tc.name,
            status=status,
            duration_s=round(dt, 3),
            peak_rss_bytes=ctx.last_peak_rss,
            command=ctx.last_command or tc.planned_cmd,
            assertions=list(ctx.current_assertions),
            error=err_str,
        )
        results.append(tr)
        if status == "PASS":
            print(f"  [PASS] {tc.test_id:<10} ({dt:.2f}s) {tc.name}")
        else:
            print(f"  [FAIL] {tc.test_id:<10} ({dt:.2f}s) {tc.name} -> {err_str}")
            if args.fail_fast:
                break

    print(f"=== Summary: {passed}/{len(results)} PASS, {failed} FAIL ===")
    if args.json_report:
        write_json_report(
            Path(args.json_report),
            mode=f"tier-{args.tier}",
            cfg=cfg,
            results=[asdict(r) for r in results],
            passed=passed,
            failed=failed,
        )
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

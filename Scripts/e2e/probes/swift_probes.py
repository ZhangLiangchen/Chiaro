"""Compile-once and cache Swift 6 probes (`ImageIOProbe`, `HLGVideoProbe`)."""

from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Optional


@dataclass
class SwiftProbes:
    swiftc: str
    probes_dir: Path
    bin_dir: Path
    _imageio_bin: Optional[Path] = None
    _hlgvideo_bin: Optional[Path] = None

    def __post_init__(self) -> None:
        self.bin_dir.mkdir(parents=True, exist_ok=True)

    def ensure_imageio_probe(self) -> Path:
        if self._imageio_bin and self._imageio_bin.is_file():
            return self._imageio_bin
        src = self.probes_dir / "ImageIOProbe.swift"
        out = self.bin_dir / "ImageIOProbe"
        if not out.is_file() or out.stat().st_mtime < src.stat().st_mtime:
            cmd = [
                self.swiftc,
                "-swift-version",
                "6",
                "-O",
                str(src),
                "-o",
                str(out),
                "-framework",
                "Foundation",
                "-framework",
                "ImageIO",
                "-framework",
                "CoreGraphics",
                "-framework",
                "CoreImage",
                "-framework",
                "UniformTypeIdentifiers",
            ]
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
            if proc.returncode != 0:
                raise RuntimeError(
                    f"Failed to compile ImageIOProbe.swift:\n{proc.stderr}\n{proc.stdout}"
                )
        self._imageio_bin = out
        return out

    def ensure_hlg_video_probe(self) -> Path:
        if self._hlgvideo_bin and self._hlgvideo_bin.is_file():
            return self._hlgvideo_bin
        src = self.probes_dir / "HLGVideoProbe.swift"
        out = self.bin_dir / "HLGVideoProbe"
        if not out.is_file() or out.stat().st_mtime < src.stat().st_mtime:
            cmd = [
                self.swiftc,
                "-swift-version",
                "6",
                "-parse-as-library",
                "-O",
                str(src),
                "-o",
                str(out),
                "-framework",
                "Foundation",
                "-framework",
                "AVFoundation",
                "-framework",
                "CoreMedia",
                "-framework",
                "VideoToolbox",
            ]
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
            if proc.returncode != 0:
                raise RuntimeError(
                    f"Failed to compile HLGVideoProbe.swift:\n{proc.stderr}\n{proc.stdout}"
                )
        self._hlgvideo_bin = out
        return out

    def probe_image(self, image_path: Path) -> Dict[str, Any]:
        exe = self.ensure_imageio_probe()
        proc = subprocess.run(
            [str(exe), str(image_path)],
            capture_output=True,
            text=True,
            timeout=30,
        )
        if not proc.stdout.strip():
            raise RuntimeError(
                f"ImageIOProbe returned empty output (rc={proc.returncode}): {proc.stderr}"
            )
        return json.loads(proc.stdout)

    def probe_hlg_video(self, video_path: Path) -> Dict[str, Any]:
        exe = self.ensure_hlg_video_probe()
        proc = subprocess.run(
            [str(exe), str(video_path)],
            capture_output=True,
            text=True,
            timeout=30,
        )
        if not proc.stdout.strip():
            raise RuntimeError(
                f"HLGVideoProbe returned empty output (rc={proc.returncode}): {proc.stderr}"
            )
        return json.loads(proc.stdout)

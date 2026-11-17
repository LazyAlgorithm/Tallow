#!/usr/bin/env python3
"""Checks that RenderView's job-thread gather draws exactly what the main-thread gather draws (needs a display).

Runs a built EcsBench player (tools/build_player.py Samples/EcsBench copy ... --config Release) in its render mode
with --fixed-step, once with TALLOW_SERIAL_GATHER=1 and once without, takes a screenshot after 120 frames of each and
compares them pixel for pixel. Cases: static cubes alone, and static + moving cubes with the glow shader material and
ripple compute effects (renderers the job threads gather and ones only the main thread may).

  python3 tools/test_parallel_gather.py --beef OUT/beef/EcsBench
"""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def shot(player: Path, out: Path, serial: bool, static: int, moving: int, effects: int) -> None:
    env = {**os.environ, "TALLOW_BENCH_MODE": "render", "TALLOW_BENCH_COUNT": str(static),
           "TALLOW_BENCH_MOVING": str(moving), "TALLOW_BENCH_EFFECTS": str(effects), "TALLOW_BENCH_FRAMES": "100000",
           "TALLOW_SERIAL_GATHER": "1" if serial else "0"}
    subprocess.run([str(player), "--fixed-step", "--frames", "120", "--screenshot", str(out)], cwd=player.parent,
                   env=env, capture_output=True, timeout=600)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--beef", type=Path, required=True, help="the built EcsBench player")
    options = parser.parse_args()
    try:
        from PIL import Image, ImageChops
    except ImportError:
        print("Needs Pillow (python3 -m pip install pillow).", file=sys.stderr)
        return 2
    failed = 0
    with tempfile.TemporaryDirectory(prefix="tallow-gather-") as work:
        for label, static, moving, effects in (("100,000 static cubes", 100000, 0, 0),
                                               ("50,000 static + 10,000 moving, shader and compute graphs", 50000, 10000, 8)):
            images = []
            for serial in (True, False):
                path = Path(work) / f"{static}_{serial}.png"
                shot(options.beef.resolve(), path, serial, static, moving, effects)
                if not path.exists():
                    print(f"FAIL: {label}: no screenshot")
                    return 1
                images.append(Image.open(path).convert("RGB"))
            box = ImageChops.difference(images[0], images[1]).getbbox()
            print(f"{'PASS' if box is None else 'FAIL'}: {label}: job-thread gather "
                  f"{'draws the same picture' if box is None else f'differs in {box}'}")
            failed += box is not None
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

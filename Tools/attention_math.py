#!/usr/bin/env python3
"""Attention-geometry math for Sightline layouts.

Given a physical screen and a viewing distance, work out how much of the
viewer's visual field each board subtends. This is the objective half of the
"attention-friendly" design; the subjective half is in docs/DESIGN.md.

Defaults describe the reference machine: a 40" 5K2K panel (3360 x 1418 pt,
928 mm active width) with the Dock at the bottom, leaving 1332 pt of height.

Run:  python3 Tools/attention_math.py
      python3 Tools/attention_math.py --dist 75
      python3 Tools/attention_math.py --width-cm 93.6 --usable-h 1394
"""
from __future__ import annotations
import argparse
import math


def half_angle_deg(half_width_cm: float, dist_cm: float) -> float:
    return math.degrees(math.atan(half_width_cm / dist_cm))


def full_angle_deg(width_cm: float, dist_cm: float) -> float:
    return 2.0 * half_angle_deg(width_cm / 2.0, dist_cm)


def metrics(center_frac: float, width_cm: float, usable_h_pt: float,
            width_pt: float, dist_cm: float, gap_pt: float = 12.0):
    center_w = round(width_pt * center_frac)
    side_w = math.floor((width_pt - center_w - 2 * gap_pt) / 2)
    pane_h = math.floor((usable_h_pt - gap_pt) / 2)
    cm_per_pt = width_cm / width_pt

    center_aspect = center_w / usable_h_pt
    pane_aspect = side_w / pane_h
    center_half = half_angle_deg(center_w / 2 * cm_per_pt, dist_cm)
    side_outer = half_angle_deg(width_pt / 2 * cm_per_pt, dist_cm)
    return dict(center_w=center_w, side_w=side_w, pane_h=pane_h,
                center_aspect=center_aspect, pane_aspect=pane_aspect,
                center_half=center_half, side_outer=side_outer,
                center_cm=center_w * cm_per_pt)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--width-pt", type=float, default=3360)
    ap.add_argument("--usable-h", type=float, default=1332, help="points of usable height")
    ap.add_argument("--width-cm", type=float, default=92.8, help="active panel width in cm")
    ap.add_argument("--dist", type=float, default=65.0, help="viewing distance cm")
    ap.add_argument("--gap", type=float, default=12.0)
    a = ap.parse_args()

    print(f"panel {a.width_pt:.0f} x {a.usable_h:.0f} pt usable, {a.width_cm:.1f} cm wide, "
          f"distance {a.dist:.0f} cm")
    print(f"scale {a.width_pt / a.width_cm:.2f} pt/cm; full horizontal field "
          f"{full_angle_deg(a.width_cm, a.dist):.1f} deg")
    print(f"vertical field {2 * half_angle_deg((a.usable_h * a.width_cm / a.width_pt) / 2, a.dist):.1f} deg\n")

    header = (f"{'centre%':>8} {'centre pt':>11} {'aspect':>7} {'centre cm':>10} "
              f"{'±deg':>6} {'side w':>7} {'pane':>11} {'pane asp':>9} {'side band':>12} {'ok':>3}")
    print(header)
    print("-" * len(header))
    for c in (0.44, 0.485, 0.50, 0.52, 0.55, 0.60, 0.66):
        m = metrics(c, a.width_cm, a.usable_h, a.width_pt, a.dist, a.gap)
        ok = "yes" if (m["center_half"] <= 22.0) else "NO"
        print(f"{c*100:7.1f}% {m['center_w']:6.0f}x{a.usable_h:<4.0f} {m['center_aspect']:7.2f} "
              f"{m['center_cm']:10.1f} {m['center_half']:6.1f} {m['side_w']:7.0f} "
              f"{m['side_w']:5.0f}x{m['pane_h']:<5.0f} {m['pane_aspect']:9.2f} "
              f"{m['center_half']:5.1f}-{m['side_outer']:.1f} {ok:>3}")

    # Solve the two design constraints.
    aspect_floor = 1.25 * a.usable_h / a.width_pt
    angle_cap = 2 * math.tan(math.radians(22)) * a.dist / a.width_cm
    print(f"\nconstraint A (centre aspect >= 1.25)  -> centre >= {aspect_floor*100:.1f}%")
    print(f"constraint B (centre half-angle <= 22 deg) -> centre <= {angle_cap*100:.1f}%")


if __name__ == "__main__":
    main()

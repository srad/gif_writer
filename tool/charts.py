"""Draws the README's benchmark charts.

    python tool/charts.py

Reads the recorded measurements in doc/benchmark-data.json. Throughput comes
from the AOT comparison; retained memory comes from separate post-GC VM probes.
See doc/encoding-review.md for methodology. No memory points are extrapolated.

Two variants are written for each chart, light and dark, so the README can hand
GitHub a `<picture>` and neither theme gets black text on a black background.
"""

import json
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

OUT = Path(__file__).resolve().parent.parent / "doc"
DATA = json.loads((OUT / "benchmark-data.json").read_text(encoding="utf-8"))
ROWS = DATA["workloads"]

# --- measured, median of nine interleaved trials -----------------------------
# 60 frames of 256x256, both encoders given pre-palettised input.
WORKLOADS = [f"{r['workload']}\n{r['colors']} colours" for r in ROWS]
OURS, OURS_LOW, OURS_HIGH = np.array([r["ours"] for r in ROWS]).T
THEIRS, THEIRS_LOW, THEIRS_HIGH = np.array([r["image"] for r in ROWS]).T

OURS_MIB = [r["ours_mib"] for r in ROWS]
THEIRS_MIB = [r["image_mib"] for r in ROWS]

# Percentages as `compare.dart` reports them, from the raw byte counts.
# **Not derived from the MiB above**, which are rounded to two places: doing that
# printed -6.6% next to a table saying -6.4%, and a chart that disagrees with the
# text beside it is worse than no chart.
FASTER_PCT = [r["faster_pct"] for r in ROWS]
SMALLER_PCT = [r["smaller_pct"] for r in ROWS]

BLUE = "#0175C2"
GREY = "#9AA0A6"

THEMES = {
    "light": dict(fg="#1F2328", muted="#59636E", grid="#D8DEE4", bg="white"),
    "dark": dict(fg="#E6EDF3", muted="#9198A1", grid="#30363D", bg="#0D1117"),
}


def style(theme):
    t = THEMES[theme]
    plt.rcParams.update({
        "figure.facecolor": t["bg"],
        "axes.facecolor": t["bg"],
        "savefig.facecolor": t["bg"],
        "text.color": t["fg"],
        "axes.labelcolor": t["fg"],
        "xtick.color": t["muted"],
        "ytick.color": t["muted"],
        "axes.edgecolor": t["grid"],
        "grid.color": t["grid"],
        "font.size": 11,
        "font.family": "DejaVu Sans",
    })
    return t


def throughput(theme):
    """Grouped bars: throughput, with the observed range as an error bar.

    The range is drawn rather than described because it is the part that says
    whether a gap is a result. Every gap here is wider than both bars' spread.
    """
    t = style(theme)
    fig, (ax, ax2) = plt.subplots(
        1, 2, figsize=(11, 4.6), gridspec_kw={"width_ratios": [1.85, 1]})

    x = np.arange(len(WORKLOADS))
    w = 0.38

    for offset, values, low, high, colour, label in [
        (-w / 2, OURS, OURS_LOW, OURS_HIGH, BLUE, "gif_writer"),
        (w / 2, THEIRS, THEIRS_LOW, THEIRS_HIGH, GREY, "package:image"),
    ]:
        err = [np.array(values) - np.array(low), np.array(high) - np.array(values)]
        ax.bar(x + offset, values, w, color=colour, label=label, zorder=3,
               yerr=err, capsize=3,
               error_kw=dict(ecolor=t["muted"], lw=1.1, zorder=4))
        for xi, v, hi in zip(x + offset, values, high):
            ax.text(xi, hi + 2.0, f"{v:.1f}", ha="center", va="bottom",
                    fontsize=9.5, color=t["fg"], zorder=5)

    # Below the tick labels, in axes fractions, so they cannot collide with them
    # however the figure is resized.
    for xi, pct in enumerate(FASTER_PCT):
        ax.text(xi, -0.22, f"+{pct}%", ha="center", va="top",
                transform=ax.get_xaxis_transform(),
                fontsize=11.5, fontweight="bold", color=BLUE)

    ax.set_xticks(x)
    ax.set_xticklabels(WORKLOADS, fontsize=10)
    ax.set_ylabel("throughput  (Mpx/s)")
    ax.set_ylim(0, max(OURS) * 1.22)
    ax.set_title("Faster on every workload", loc="left",
                 fontsize=13, fontweight="bold", pad=26)
    ax.text(0, 1.045, "AOT · 60 × 256×256 · median and range of 9 trials",
            transform=ax.transAxes, fontsize=9.5, color=t["muted"])
    ax.legend(frameon=False, loc="upper right", fontsize=10)
    ax.grid(axis="y", lw=0.8, zorder=0)
    ax.set_axisbelow(True)
    for side in ("top", "right", "left"):
        ax.spines[side].set_visible(False)
    ax.tick_params(length=0)

    # --- and the file it produced --------------------------------------------
    # Speed on its own proves nothing: an encoder can always go faster by
    # compressing worse. This is the check that it did not.
    ax2.bar(x - w / 2, OURS_MIB, w, color=BLUE, zorder=3)
    ax2.bar(x + w / 2, THEIRS_MIB, w, color=GREY, zorder=3)
    for xi, pct in enumerate(SMALLER_PCT):
        ax2.text(xi, max(OURS_MIB[xi], THEIRS_MIB[xi]) + 0.12, f"-{pct}%",
                 ha="center", fontsize=9.5, fontweight="bold", color=BLUE)
    ax2.set_xticks(x)
    ax2.set_xticklabels(["photo\n32", "photo\n256", "noise\n32", "noise\n256"],
                        fontsize=9.5)
    ax2.set_ylabel("file written  (MiB)")
    ax2.set_ylim(0, max(THEIRS_MIB) * 1.2)
    ax2.set_title("and smaller", loc="left", fontsize=13,
                  fontweight="bold", pad=26)
    ax2.text(0, 1.045, "lower is better", transform=ax2.transAxes,
             fontsize=9.5, color=t["muted"])
    ax2.grid(axis="y", lw=0.8, zorder=0)
    ax2.set_axisbelow(True)
    for side in ("top", "right", "left"):
        ax2.spines[side].set_visible(False)
    ax2.tick_params(length=0)

    fig.tight_layout()
    fig.subplots_adjust(bottom=0.27)  # room for percentages and provenance
    fig.text(0.5, 0.02, "Windows x64 · Dart 3.13.2 · image 4.9.2 · September 2026",
             ha="center", fontsize=9, color=t["muted"])
    fig.savefig(f"{OUT}/throughput-{theme}.png", dpi=200)
    plt.close(fig)


def memory(theme):
    """Show only measured retention at 60 and 1,000 frames, for every workload."""
    t = style(theme)
    fig, axes = plt.subplots(1, 2, figsize=(11, 4.6), sharey=True)
    x = np.arange(len(WORKLOADS))
    w = 0.38
    for i, (ax, frames) in enumerate(zip(axes, DATA["memory_frames"])):
        for offset, key, colour, label in [
            (-w / 2, "ours_retained_bytes", BLUE, "gif_writer"),
            (w / 2, "image_retained_bytes", GREY, "package:image"),
        ]:
            values = np.array([r[key][i] for r in ROWS]) / (1024 * 1024)
            ax.bar(x + offset, values, w, color=colour, label=label, zorder=3)
            for xi, value in zip(x + offset, values):
                ax.text(xi, value * 1.12, f"{value:.2f}", ha="center",
                        va="bottom", fontsize=9, color=t["fg"])
        ax.set_yscale("log")
        ax.set_ylim(0.1, 400)
        ax.set_yticks([0.1, 1, 10, 100], ["0.1", "1", "10", "100"])
        ax.set_xticks(x, WORKLOADS, fontsize=10)
        ax.set_title(f"{frames:,} frames", loc="left", fontsize=12, pad=12)
        ax.grid(axis="y", which="major", lw=0.8)
        ax.set_axisbelow(True)
        for side in ("top", "right", "left"):
            ax.spines[side].set_visible(False)
        ax.tick_params(which="both", length=0)
    axes[0].set_ylabel("retained memory (MiB, log scale)")
    fig.suptitle("Awaited streaming stays near 0.32 MiB", x=0.07, ha="left",
                 fontsize=14, fontweight="bold")
    handles, labels = axes[0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="upper right", bbox_to_anchor=(0.99, 1.0),
               frameon=False, ncol=2, fontsize=10)
    fig.text(0.5, 0.075, "JIT · live heap + external memory after GC · median of 3 trials · shared inputs excluded",
             ha="center", fontsize=9, color=t["muted"])
    fig.text(0.5, 0.025, "256×256 indexed frames · Windows x64 · Dart 3.13.2 · image 4.9.2 · September 2026",
             ha="center", fontsize=9, color=t["muted"])
    fig.tight_layout(rect=(0, 0.12, 1, 0.93))
    fig.savefig(f"{OUT}/memory-{theme}.png", dpi=200)
    plt.close(fig)


if __name__ == "__main__":
    OUT.mkdir(exist_ok=True)
    for theme in THEMES:
        throughput(theme)
        memory(theme)
    print(f"wrote 4 charts to {OUT}/")

"""Draws the README's benchmark charts.

    python tool/charts.py

The numbers below are transcribed from `dart run tool/compare.dart`, which is
the authority — this only draws them. Anything changed here must be changed
there first, or the picture and the table stop agreeing.

Two variants are written for each chart, light and dark, so the README can hand
GitHub a `<picture>` and neither theme gets black text on a black background.
"""

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

OUT = "doc"

# --- measured, median of nine interleaved trials -----------------------------
# 60 frames of 256x256, both encoders given pre-palettised input.
WORKLOADS = ["photo\n32 colours", "photo\n256 colours",
             "noise\n32 colours", "noise\n256 colours"]
OURS = [95.1, 58.8, 68.4, 52.1]
OURS_LOW = [78.4, 51.9, 57.4, 41.7]
OURS_HIGH = [100.0, 61.3, 71.0, 55.7]
THEIRS = [48.3, 35.9, 28.2, 31.0]
THEIRS_LOW = [45.0, 34.0, 26.1, 29.6]
THEIRS_HIGH = [49.8, 37.0, 29.0, 32.6]

OURS_MB = [1.13, 3.34, 2.91, 5.15]
THEIRS_MB = [1.21, 3.39, 3.04, 5.19]

# Percentages as `compare.dart` reports them, from the raw byte counts.
# **Not derived from the MB above**, which are rounded to two places: doing that
# printed -6.6% next to a table saying -6.4%, and a chart that disagrees with the
# text beside it is worse than no chart.
FASTER_PCT = [97, 64, 143, 68]
SMALLER_PCT = [6.4, 1.3, 4.3, 0.8]

# Held in memory. `package:image` returns the finished file, so what it holds is
# the file; this holds a fixed staging buffer and LZW table whatever the length.
#
# **Not the 0.06 the sink reports.** `compare.dart` measures the largest single
# handover, which is the 64 kB staging buffer alone — it cannot see the 256 kB
# LZW string table, which is held just as permanently. Quoting the sink's number
# put 0.06 here against the README's own "~320 kB" three sections down.
MB_PER_FRAME = 5.19 / 60      # measured, noise at 256 colours
OURS_HELD_MB = 0.31           # 64 kB staging + 256 kB LZW table

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
        for xi, v in zip(x + offset, values):
            ax.text(xi, v + 3.2, f"{v:.1f}", ha="center", va="bottom",
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
    ax.text(0, 1.045, "60 frames of 256x256 - median of 9 interleaved trials on one machine; "
            "ratios move a few points between runs",
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
    ax2.bar(x - w / 2, OURS_MB, w, color=BLUE, zorder=3)
    ax2.bar(x + w / 2, THEIRS_MB, w, color=GREY, zorder=3)
    for xi, pct in enumerate(SMALLER_PCT):
        ax2.text(xi, max(OURS_MB[xi], THEIRS_MB[xi]) + 0.12, f"-{pct}%",
                 ha="center", fontsize=9.5, fontweight="bold", color=BLUE)
    ax2.set_xticks(x)
    ax2.set_xticklabels(["photo\n32", "photo\n256", "noise\n32", "noise\n256"],
                        fontsize=9.5)
    ax2.set_ylabel("file written  (MB)")
    ax2.set_ylim(0, max(THEIRS_MB) * 1.2)
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
    fig.subplots_adjust(bottom=0.24)  # room for the +% labels under the ticks
    fig.savefig(f"{OUT}/throughput-{theme}.png", dpi=200)
    plt.close(fig)


def memory(theme):
    """The claim the package is named for: held memory against length."""
    t = style(theme)
    fig, ax = plt.subplots(figsize=(8, 4.2))

    frames = np.arange(0, 1001)
    ax.plot(frames, frames * MB_PER_FRAME, color=GREY, lw=2.4,
            label="package:image", zorder=3)
    ax.plot(frames, np.full_like(frames, OURS_HELD_MB, dtype=float),
            color=BLUE, lw=2.4, label="gif_writer", zorder=4)

    ax.annotate(f"{1000 * MB_PER_FRAME:.0f} MB",
                xy=(1000, 1000 * MB_PER_FRAME), xytext=(-8, -2),
                textcoords="offset points", ha="right", va="top",
                fontsize=11, fontweight="bold", color=GREY)
    ax.annotate(f"{OURS_HELD_MB:.2f} MB - flat", xy=(1000, OURS_HELD_MB),
                xytext=(-8, 8),
                textcoords="offset points", ha="right", va="bottom",
                fontsize=11, fontweight="bold", color=BLUE)

    ax.set_xlabel("frames written")
    ax.set_ylabel("held in memory  (MB)")
    ax.set_xlim(0, 1000)
    ax.set_ylim(0, 1000 * MB_PER_FRAME * 1.12)
    ax.set_title("Memory does not grow with the animation", loc="left",
                 fontsize=13, fontweight="bold", pad=26)
    ax.text(0, 1.045, "256x256 frames - one side scales with length, "
            "the other does not",
            transform=ax.transAxes, fontsize=9.5, color=t["muted"])
    ax.legend(frameon=False, loc="upper left", fontsize=10,
              bbox_to_anchor=(0.0, 0.92))
    ax.grid(lw=0.8, zorder=0)
    ax.set_axisbelow(True)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    ax.tick_params(length=0)

    fig.tight_layout()
    fig.savefig(f"{OUT}/memory-{theme}.png", dpi=200)
    plt.close(fig)


if __name__ == "__main__":
    import os
    os.makedirs(OUT, exist_ok=True)
    for theme in THEMES:
        throughput(theme)
        memory(theme)
    print(f"wrote 4 charts to {OUT}/")

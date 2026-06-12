"""
Figure for doc/lvr-multiasset-lmsr.md: ratio of multi-asset LMSR LVR to the
independent-pair benchmark, plotted against average pairwise correlation rho-bar
for fixed S=1 (balanced pool) and several N. Closed form is eq. (9):

    ell(rho-bar) / ell_ind = [N + S(N-1)(1 - rho-bar)] / [N(1+S)]

The curves all converge to 1/(1+S) at rho-bar = 1 (the perfect-correlation floor)
and spread out at rho-bar = 0 in proportion to N.
"""

import numpy as np
import matplotlib.pyplot as plt

S = 1.0
N_values = [2, 3, 5, 10, 100]
rho = np.linspace(0.0, 1.0, 400)

fig, ax = plt.subplots(figsize=(6.0, 3.75), dpi=100)
for N in N_values:
    ratio = (N + S * (N - 1) * (1.0 - rho)) / (N * (1.0 + S))
    ax.plot(rho, ratio, label=f"N = {N}")

floor = 1.0 / (1.0 + S)
ax.axhline(
    floor,
    color="black",
    linestyle="--",
    linewidth=0.8,
    alpha=0.6,
    label=r"$1/(1{+}S) = " + f"{floor:.2f}$ (perfect-correlation floor)",
)

ax.set_xlabel(r"average pairwise correlation $\bar\rho$")
ax.set_ylabel(r"$\ell / \ell_{\mathrm{ind}}$")
fig.suptitle("Cross-correlation discount in multi-asset LMSR", fontsize=12, y=0.97)
ax.set_title(r"$S=1$, equal vols, equal weights", fontsize=9, color="0.35", pad=4)
ax.set_xlim(0.0, 1.0)
ax.set_ylim(0.0, 1.05)
ax.grid(True, alpha=0.3)
ax.legend(loc="lower left", fontsize=9, framealpha=0.95)

plt.tight_layout()
out = "doc/lvr-multiasset-lmsr-fig.png"
plt.savefig(out, dpi=100)  # no bbox_inches="tight" so the figure is exactly 600px wide
print(f"wrote {out}")

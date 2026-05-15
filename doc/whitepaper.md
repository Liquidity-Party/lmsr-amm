# Liquidity Party: A Quasi-static Logarithmic Market Scoring Rule Automated Market Maker

## Abstract
We present a multi-asset automated market maker whose pricing kernel is the Logarithmic Market Scoring Rule (LMSR) ([R. Hanson, 2002](https://mason.gmu.edu/~rhanson/mktscore.pdf)). The pool maintains the convex potential $C(\mathbf{q}) = b(\mathbf{q}) \log\!\Big(\sum_i e^{q_i / b(\mathbf{q})}\Big)$ over normalized inventories $\mathbf{q}$, and sets the effective liquidity parameter proportional to pool size as $b(\mathbf{q}) = \kappa \, S(\mathbf{q})$ with $S(\mathbf{q}) = \sum_i q_i$ and fixed $\kappa>0$. This proportional parameterization preserves scale-invariant responsiveness while retaining softmax-derived pairwise price ratios under a quasi-static-$b$ view, enabling any-to-any swaps within a single potential. We derive and use closed-form expressions for two-asset reductions to compute exact-in, exact-out, and capped-output trades, and provide minimum-output slippage guarantees. We discuss stability techniques such as log-sum-exp, ratio-once shortcuts, and domain guards for fixed-point arithmetic. Liquidity operations (proportional and single-asset joins/exits) follow directly from the same potential and admit monotone, invertible mappings. Parameters are immutable post-deployment for transparency and predictable depth calibration.

## Introduction and Motivation
Classical CFMMs define multiplicative invariants over reserves, while LMSR specifies a convex cost function whose gradient yields prices. Our goal is a multi-asset AMM that uses LMSR to support any-to-any swaps, shares risk across many assets, and scales depth predictably with pool size. By setting $b(\mathbf{q})=\kappa S(\mathbf{q})$, we achieve scale invariance: proportional rescaling of all balances scales $b$ proportionally and preserves pairwise price ratios, so the market’s responsiveness is consistent across liquidity regimes. The derivations below formulate instantaneous prices, closed-form swap mappings, limit logic, and liquidity operations tailored to this parameterization.

### Relation to liquidity-sensitive LMSR (Othman et al.)
[Othman et al., 2013](https://www.cs.cmu.edu/~sandholm/liquidity-sensitive%20market%20maker.EC10.pdf) introduce a liquidity-sensitive variant of LMSR called LS-LMSR in which the liquidity parameter is allowed to evolve continuously via a scaling variable commonly denoted $\alpha$. Their formulation derives the full pricing equations for a continuously varying $b(\cdot)$ as $\alpha$ changes, and it purposefully ties the cost function to the path along which liquidity evolves.
- **Conceptual correspondence:** $\alpha$ in LS-LMSR plays a role analogous to our $\kappa$ in that both modulate how responsive prices are to inventory imbalances; in that sense $\alpha$ and $\kappa$ correspond as liquidity-scaling quantities. However, they are not identical: $\alpha$ in the LS-LMSR literature is a continuous scaling variable used to model an explicitly path-dependent evolution of $b$, while our $\kappa$ is a fixed proportionality constant and $b(\cdot)=\kappa\cdot S(\cdot)$ ties liquidity directly to the instantaneous pool size.
- **Practical and formal differences:** the continuous LS-LMSR pricing equations (with $\alpha$-driven evolution of $b$) generally give up path independence—the final cost can depend on the particular liquidity trajectory—whereas our design preserves path independence on a piecewise or quasi-static basis by evaluating swap steps with $b$ held at the local pre-trade state and then updating $b$ according to the new $S$. This yields a pool that is easier to reason about and whose swap mappings admit closed-form two-asset reductions.
- **EVM feasibility:** the exact continuous LS-LMSR price rules require richer integrals and state-continuous formulas that are substantially more gas-intensive to evaluate on-chain. For that reason we adopt a piecewise/quasi-static treatment that recovers softmax-driven pairwise ratios within each operation and updates $b$ discretely with state changes—combining tractable closed forms, numerical safety, and gas-efficiency.
- **Naming and convention:** because our approach keeps the liquidity sensitivity but enforces quasi-static (piecewise) evaluation, we call it "quasi-static LS-LMSR" rather than LS-LMSR. In the remainder of this document, we use $\kappa$ to denote our fixed proportionality; $\kappa$ corresponds to, but is not the same object as, the $\alpha$ used when deriving continuous LS-LMSR.
- **Takeaway:** Othman et al.'s treatment is closely related in spirit and provides valuable theoretical context, but the continuous $\alpha$-driven pricing equations differ formally from the $\kappa\to b(\cdot)=\kappa S(\cdot)$ parameterization used here; our choice trades full path dependence for piecewise path independence and EVM practicality, while retaining liquidity sensitivity and predictable scaling.

## System Model and Pricing Kernel
We consider $n\ge 2$ normalized assets with state vector $\mathbf{q}=(q_0,\dots,q_{n-1})\in\mathbb{R}_{\ge 0}^{\,n}$ and size metric $S(\mathbf{q})=\sum_i q_i$. The kernel is the LMSR cost function

$$
C(\mathbf{q}) = b(\mathbf{q}) \log\!\left(\sum_{i=0}^{n-1} e^{q_i / b(\mathbf{q})}\right), \qquad b(\mathbf{q})=\kappa\,S(\mathbf{q}),\quad \kappa>0.
$$

For numerical stability we evaluate $C$ with a log-sum-exp recentering. Let $y_i := q_i/b(\mathbf{q})$ and $M:=\max_i y_i$. Then

$$
C(\mathbf{q}) \;=\; b(\mathbf{q}) \left( M + \log \sum_{i=0}^{n-1} e^{\,y_i - M} \right),
$$

which prevents overflow/underflow when the $y_i$ are dispersed. Quantities are represented in fixed-point with explicit range and domain guards; equations are presented over the reals for clarity.

## Gradient, Price Shares, and Pairwise Prices
With $b$ treated as a constant parameter, the LMSR gradient recovers softmax shares

$$
\frac{\partial C}{\partial q_i} \;=\; \frac{e^{q_i/b}}{\sum_k e^{q_k/b}} \;=:\; \pi_i(\mathbf{q}),
$$

so that the ratio of marginal prices is $\pi_j/\pi_i = \exp\!\big((q_j-q_i)/b\big)$. When $b(\mathbf{q})=\kappa S(\mathbf{q})$ depends on state, $\frac{\partial C}{\partial q_i}$ acquires a common additive term across $i$ from $\partial b/\partial q_i$, but pairwise ratios remain governed by softmax differences. We therefore use a quasi-static-$b$ view for pricing steps, holding $b$ fixed at the pre-trade state for the infinitesimal move, and define the instantaneous pairwise marginal price ratio for exchanging $i$ into $j$ as

$$
P(i\to j \mid \mathbf{q}) \;=\; \exp\!\left(\frac{q_j - q_i}{b(\mathbf{q})}\right).
$$

This ratio drives swap computations and is invariant to proportional rescaling $\mathbf{q}\mapsto \lambda\mathbf{q}$ because $b$ scales by the same factor.

## Two-Asset Reduction and Exact Swap Mappings
Swaps are computed in the two-asset subspace spanned by the in-asset $i$ and out-asset $j$, with all other coordinates held fixed under a quasi-static-$b$ step. Let

$$
r_0 \;:=\; \exp\!\left(\frac{q_i - q_j}{b}\right), \qquad b \equiv b(\mathbf{q})\;\text{ held quasi-static}.
$$

Along the $i\!\to\! j$ path, the instantaneous ratio evolves multiplicatively as $r(t)=r_0\,e^{t/b}$ where $t$ denotes cumulative input of asset $i$. In the two-asset reduction the infinitesimal output satisfies

$$
\mathrm{d}y \;=\; \frac{r(t)}{1+r(t)}\,\mathrm{d}t.
$$

Integrating from $t=0$ to $t=a$ yields the exact-in closed form

$$
y(a) \;=\; b \,\ln\!\Big( 1 + r_0 \,\big(1 - e^{-a/b}\big) \Big).
$$

This mapping has $y(0)=0$, is strictly increasing and concave in $a$, and satisfies $y'(0)=\frac{r_0}{1+r_0}$ with asymptote $\lim_{a\to\infty} y = b\,\ln(1+r_0)$. The inverse exact-out mapping follows by solving for $a$ in terms of target $y$. Writing $E:=e^{y/b}$, we obtain

$$
a(y) \;=\; b \,\ln\!\left(\frac{r_0}{\,r_0 + 1 - E\,}\right),
$$

which is strictly increasing and convex for $y\in\big[0,\, b\ln(1+r_0)\big]$. These two expressions are the workhorses for exact-in and exact-out swaps in our kernel.

## Slippage Protection and Capacity Caps
Users may specify a `minAmountOut` parameter on `swap()`: a guaranteed lower bound on output tokens received. If the LMSR kernel produces fewer than `minAmountOut` tokens for the given input, the call reverts. This is exact, denomination-aware slippage protection requiring no price-unit conversions.

For callers who prefer price-based targeting, the off-chain view helper `swapAmountsForExactPrice(pool, i, j, minPrice)` accepts a denomination-adjusted Q128.128 forward price floor. It uses 64 iterations of bisection on the actual post-swap LMSR state — accounting for the two-sided quasi-static-$b$ effect on both $q_i$ and $q_j$ — to return a `(maxAmountIn, minAmountOut, fee)` triple suitable to pass directly to `swap()`. The bisection bracket uses an upper bound of $2b\ln(r_0/\Lambda)$ derived from the single-sided estimate (which always overshoots the true two-sided fill, making it a safe upper bracket). The bisection does not execute on-chain and is intended for off-chain callsites only.

Note: a single-sided approximation $a_{\text{lim}} = b\ln(\Lambda/r_0)$ truncates the fill using only the input-side price trajectory. Because $q_j$ also decreases during a swap, the forward price overshoots the target under the quasi-static-$b$ model; the bisection helper corrects this by evaluating the two-sided post-swap price at each candidate fill level.

Outputs are further bounded by available inventory; if a computed $y$ would exceed $q_j$, we cap at $y=q_j$ and compute the implied input by inverting the exact-out formula,

$$
a_{\text{cap}} \;=\; b \,\ln\!\left(\frac{r_0}{\,r_0 + 1 - e^{\,q_j/b}\,}\right).
$$

These capacity and slippage branches ensure monotone, conservative behavior near domain edges.

## Liquidity Operations from the Same Potential
Liquidity is accounted via pool shares $L$ taken proportional to the size metric. The proportionality constant (LP unit scale) is fixed at pool creation for human convenience; the implementation defaults to minting $10^{18}$ LP units at initialization so that LP balances are expressed in a familiar 18-decimal denomination. Subsequent minting and burning preserve the ratio $L/S(\mathbf{q})$, so the precise initial scale does not affect any pricing or economic invariant. Concretely, the pool sets $L^{(0)}=c\cdot S^{(0)}$ for a constant $c>0$ chosen at initialization, and $b^{(0)}=\kappa S^{(0)}$. A proportional deposit that scales balances to $\mathbf{q}'=(1+\alpha)\mathbf{q}$ mints $\Delta L = \alpha S(\mathbf{q})$ shares and scales liquidity to $b'=(1+\alpha)b$. Proportional withdrawals burn $\Delta L$ and return $\alpha=\Delta L/S(\mathbf{q})$ of each asset, updating $b$ to $(1-\alpha)b$. Single-asset deposits and withdrawals decompose into a chain of $n-1$ pairwise LMSR swaps against a mutating local state, followed (or preceded) by the proportional leg; each sub-swap recomputes $b_{\text{local}}=\kappa\,S(\mathbf{q}_{\text{local}})$ at the current chain step. Because every operation reduces to the same two-asset closed forms — composed against a state that evolves identically to the open-market sequence — these single-asset paths inherit the monotonicity, uniqueness, and slippage profile of the underlying swaps.

### Single-Asset Mint and Redeem

#### Single-Asset Mint
Single-asset mint is **exact-LP-out**: the caller specifies the LP shares $\Delta L$ they wish to receive and a slippage cap on the input. Given a target growth factor $\gamma = \Delta L / L$, the operation is a sequence of $n-1$ pairwise LMSR swaps from asset $i$ into each $j\ne i$, followed by a proportional basket mint, with the interior parameter

$$
\beta \;=\; \frac{\gamma}{1+\gamma} \;\in\; (0,1)
$$

setting the fraction of each non-input asset that the chain acquires. Because $\gamma$ is supplied by the caller, $\beta$ is fixed; there is no inner search.

The chain is simulated against a mutating local state $\mathbf{q}_{\text{local}}$, where each step consults the live $b_{\text{local}}$:

- Initialize $\mathbf{q}_{\text{local}} = \mathbf{q}$.
- For each $j\ne i$ (in fixed index order), compute $b_{\text{local}} = \kappa\,S(\mathbf{q}_{\text{local}})$ and $r_{0,j} = \exp\!\big((q_{\text{local}}^j - q_{\text{local}}^i)/b_{\text{local}}\big)$. The LMSR exact-out inverse

$$
x_j \;=\; b_{\text{local}} \,\ln\!\left(\frac{r_{0,j}}{\,r_{0,j} + 1 - e^{\,\beta q_j / b_{\text{local}}}\,}\right)
$$

yields the asset-$i$ cost of acquiring $\beta q_j$ of asset $j$ at the current local state. Update $q_{\text{local}}^i \mathrel{+}= x_j$, $q_{\text{local}}^j \mathrel{-}= \beta q_j$.

The total user input absorbed by the chain plus proportional mint is

$$
a \;=\; \frac{\beta\,q_i \;+\; \sum_{j\ne i} x_j}{1-\beta},
$$

a single forward evaluation — no bracket, no iteration. The caller's `maxAmountIn` is checked against $a$ post-hoc and the call reverts on overage; on success the pool mints exactly $\Delta L = \gamma L$ shares.

Guards: each sub-swap requires $b_{\text{local}}>0$, $e^{\beta q_j / b_{\text{local}}}$ within range, and positivity of the denominator $r_{0,j}+1-e^{\beta q_j / b_{\text{local}}}$; a violation reverts the whole call. Recomputing $b_{\text{local}}$ per step makes the chain behave like a real sequence of LMSR swaps, so a mint–burn round trip carries only composed swap slippage rather than the drift produced by a frozen-$b$ single-shot kernel.

#### Single-Asset Redeem
Burning a proportional share $\alpha \in (0,1]$ in exchange for a single asset $i$ proceeds as a proportional withdrawal followed by $n-1$ pairwise LMSR swaps back into $i$ against the already-burnt local state:

1) Initialize $\mathbf{q}_{\text{local}} = (1-\alpha)\,\mathbf{q}$ and start the payout with the proportional share $Y_i = \alpha\,q_i$.
2) For each $j\ne i$, the wrapper holds $a_j := \alpha\,q_j$ of asset $j$ to swap back into $i$. Recompute $b_{\text{local}} = \kappa\,S(\mathbf{q}_{\text{local}})$ and $r_{0,j} = \exp\!\big((q_{\text{local}}^i - q_{\text{local}}^j)/b_{\text{local}}\big)$ at the current local state. The LMSR exact-in form

$$
y_{j\to i} \;=\; b_{\text{local}} \,\ln\!\Big(1 + r_{0,j}\,\big(1 - e^{-a_j / b_{\text{local}}}\big)\Big)
$$

gives the asset-$i$ payout from this sub-swap. Accumulate $Y_i \mathrel{+}= y_{j\to i}$ and update $q_{\text{local}}^j \mathrel{+}= a_j$, $q_{\text{local}}^i \mathrel{-}= y_{j\to i}$.

3) Capacity cap and inverse: if a candidate $y_{j\to i}$ would exceed $q_{\text{local}}^i$, cap the payout to $q_{\text{local}}^i$ and solve for the actually-consumed input via

$$
a_{j,\text{used}} \;=\; b_{\text{local}} \,\ln\!\left(\frac{r_{0,j}}{\,r_{0,j} + 1 - e^{\,q_{\text{local}}^i / b_{\text{local}}}\,}\right),
$$

then update $\mathbf{q}_{\text{local}}$ with the capped values. The remaining $a_j - a_{j,\text{used}}$ stays unswapped in the local accounting.

4) The LP burn is $L_{\text{in}} = \alpha\,S(\mathbf{q})$; the asset-$i$ payout is $Y_i$.

Guards: each sub-swap requires $b_{\text{local}}>0$, positivity of the inner term $r_{0,j}+1-e^{y/b_{\text{local}}}$, and safe exponent ranges. Per-asset numerical failure is treated as zero contribution from that asset rather than aborting the entire redeem. As with single-asset mint, recomputing $b_{\text{local}}$ per step ensures the chain matches the post-state any external actor would observe by performing the same sequence of swaps after a proportional burn.

### LP Pricing vs. an Asset Token
With LP supply set to $L=S(\mathbf{q})$, the instantaneous price of one LP share in units of asset $k$ aggregates marginal exchange rates from each asset into $k$:

$$
P_L^{(k)}(\mathbf{q}) \;=\; \frac{1}{S(\mathbf{q})}\,\sum_{j=0}^{n-1} q_j \,\exp\!\left(\frac{q_j - q_k}{b(\mathbf{q})}\right).
$$

Interpretation: proportional deposits leave $P_L^{(k)}$ unchanged; swap fees retained in the pool increase $S$ relative to outstanding $L$, raising $P_L^{(k)}$ (implicit fee accrual). This expression helps LPs and integrators reason about share valuation and dilution across assets.

## Numerical Methods and Safety Guarantees
We evaluate log-sum-exp with recentring, compute ratios like $r_0=\exp((q_i-q_j)/b)$ directly rather than dividing exponentials, and guard all $\exp$ and $\ln$ calls to bounded domains with explicit checks on positivity of inner terms such as $r_0+1-e^{y/b}$. Fixed-point implementations precompute reciprocals like $1/b$ to reduce dispersion, clamp to capacity before inversion, and select cap-and-invert rather than extrapolating when inner terms approach zero. These measures ensure the swap maps remain strictly order-preserving and free of nonphysical outputs. Property-based and differential testing can confirm monotonicity of $y(a)$ and $a(y)$, uniqueness of limit hits when $\Lambda>r_0$, and adherence to predefined error budgets.

## Balanced Regime Optimization: Approximations, Dispatcher, and Stability

> **Status:** The balanced-pair polynomial approximation described in this
> section is **not currently implemented** in deployed pools. Every operation
> uses the exact transcendental path. This section is retained as a reference
> for a possible future re-introduction.

Since transcendental operations are gas-expensive on EVM chains, we use polynomial approximations in near-balanced regimes (e.g., stable-asset pairs) while preserving monotonicity and domain safety. Parameterize $\delta := (q_i - q_j)/b$ and $\tau := a/b$ for an $i\!\to\! j$ exact-in step. The exact mapping

$$
y(a) \;=\; b \,\ln\!\Big(1 + e^{\delta}\,\big(1 - e^{-\tau}\big)\Big)
$$

admits small-argument expansions for $|\delta|\ll 1$ and $|\tau|\ll 1$. Using $e^{\pm x}\approx 1\pm x+\tfrac{x^2}{2}$ and $\ln(1+u)\approx u - \tfrac{u^2}{2}$, we obtain

$$
y(a) \;\approx\; b \left[ r_0 \tau - \tfrac{1}{2} r_0 \tau^2 \right] + \mathcal{O}\!\left(\tau^3,\, |\delta|\,\tau^2\right), \qquad r_0=e^{\delta}\approx 1+\delta+\tfrac{\delta^2}{2},
$$

and at $\delta=0$ the symmetry reduces to $y(a)\approx \tfrac{a}{2} - \tfrac{a^2}{4b} + \cdots$.

### Dispatcher preconditions and thresholds (approx path):
- Scope: two-asset pools only; otherwise use the exact path.
- Magnitude bounds: $|\delta| \le 0.01$ and $\tau := a/b$ satisfies $0 < \tau \le 0.5$.
- Tiering: use the quadratic surrogate for $\tau \le 0.1$, and include a cubic correction for $0.1 < \tau \le 0.5$.
- Capacity and positivity: require $b>0$ and $a>0$, and ensure the approximated output $\tilde{y}(a) \le q_j$; otherwise fall back to the exact cap-and-invert.
- Thresholds: $\delta_\star=0.01$, $\tau_{\text{tier1}}=0.1$, $\tau_\star=0.5$ (for reference, $e^{\delta_\star}\approx 1.01005$).

### Approximation Path
- Replace $\exp$ on the bounded $\tau$ domain and $\ln(1+\cdot)$ with verified polynomials to meet a global error budget while maintaining $\tilde{y}'(a)>0$ on the domain.
- Cache common subexpressions (e.g., $r_0=e^\delta$, $\tau=a/b$) and guard inner terms to remain in $(0,\infty)$.

### Fallback Policy
- If any precondition fails (magnitude, domain, or capacity), evaluate the exact closed forms for $y(a)$ or $a(y)$ (with cap-and-invert branch), preserving monotonicity and uniqueness.
- Prefer cap-and-invert near capacity or when the inner term of $\ln(\cdot)$ approaches zero.

### Error Shape
- The small-argument expansion above shows the leading behavior; when using polynomial surrogates, the composed relative error can be kept within a target $\epsilon$ with degrees chosen for the specified $(\delta_\star,\tau_\star,u_\star)$, yielding an error budget of the form $\epsilon \approx \epsilon_{\exp} + \epsilon_{\ln} + c_1 \tau_\star + c_2 |\delta_\star| \tau_\star$ for modest constants $c_1,c_2$.
- These bounds ensure the approximated path remains order-preserving and safely within domain; outside the domain, the dispatcher reverts to the exact path.
- Regardless of path, our policy prioritizes monotonicity, domain safety, and conservative decisions at boundaries.

## Fees and Economic Considerations
Fees are applied outside the fee-free LMSR kernel and are retained in the pool so that fee accrual increases the size metric $S(\mathbf{q})$ (and thereby raises LP share value under $L\propto S$). We extend the single global swap-fee to a per-token fee vector $f = (f_0, f_1, \dots, f_{n-1})$, where $f_i$ denotes the canonical fee rate associated with token $i$ (expressed as a fractional rate, e.g., ppm or bps). For a trade that takes token $i$ as input and token $j$ as output, the pool computes an effective pair fee and applies it to the user-submitted input before invoking the fee-free kernel.

Effective pair fee composition
- The effective fee for an asset-to-asset swap uses an additive composition:
  $$
  f_{\mathrm{eff}} \;=\; f_i + f_j.
  $$
  The exact multiplicative form $1-(1-f_i)(1-f_j)$ would be mathematically equivalent in the limit of small fees, but in practice the additive rule is simpler for users to reason about, has negligible difference at the fee levels enforced by the deployer (each $f_i < 10{,}000$ ppm, so the cross-term $f_i f_j < 10^{-4}$ of the pair fee), and avoids the extra multiply in the hot path.

Asset-to-asset policy
- Charge on input: compute the kernel input as
  $$
  a_{\mathrm{eff}} \;=\; a_{\mathrm{user}}\,(1 - f_{\mathrm{eff}})
  $$
  and pass $a_{\mathrm{eff}}$ to the fee-free LMSR kernel; collect the retained fee in the input token. Charging on input keeps gas logic simple and makes effective price shifts monotone and predictable for takers.
- Protocol fees are taken as a fraction of LP fee earnings, and immediately moved to a separate account that does not participate in liquidity operations.
- Cap computations refer to the fee-free kernel path (i.e., are evaluated against the kernel output computed from $a_{\mathrm{eff}}$). Aggregators should compute $f_{\mathrm{eff}}$ externally and present accurate expected outputs to users.

SwapMint and BurnSwap: single-asset fee policy
- Overview: swapMint (single-asset mint) and burnSwap (single-asset redeem) are single-asset-facing operations that interface the pool with one external token and the LP shares on the other side. To keep semantics simple and predictable, only the single asset’s fee is applied for these operations; there is no separate “LP token” fee ($f_{\mathrm{LP}} = 0$).
- swapMint (deposit one token to mint LP):
  - Apply only the deposited token’s fee $f_i$. Compute the effective kernel input as
    $$
    a_{\mathrm{eff}} \;=\; a_{\mathrm{user}}\,(1 - f_i).
    $$
    The fee is collected in the deposited token and split by the protocol share $\phi$; the remainder increases the pool (raising $S$ and accruing value to LPs implicitly).
- burnSwap (burn LP to receive one token):
  - Apply only the withdrawn token’s fee $f_j$. Compute the gross payout via the fee-free kernel for the burned LP fraction, and remit to the user:
    $$
    \text{payout}_{\mathrm{net}} \;=\; \text{payout}_{\mathrm{gross}}\,(1 - f_j).
    $$
    The collected fee is retained in the withdrawn token, the protocol takes $\phi$ of that fee, and the remainder increases pool-held balances (raising $S$ for remaining LPs).

Rationale and interactions with pair-fee rules
- Conceptual consistency: single-asset operations touch a single external token, so applying only that token’s fee is the most natural mapping from the per-token fee vector to operation-level economics. For asset-to-asset swaps the two-token additive composition remains the canonical rule.
- $f_{\mathrm{LP}} = 0$: keeping LP-side fees at zero simplifies LP accounting and avoids double charging when LP shares are the other leg of a transaction. LPs still receive value via retained fees that increase $S$.

Rounding
Our policies aim to always protect the LP's value.
- Total fees are rounded up for the benefit of the pool and against takers.
- The Protocol fee is rounded down for the benefit of LPs and against the protocol developers.
- Pre-funding: when a caller pre-funds the pool (depositing tokens before invoking an operation), any dust above the exact required amount is credited to the pool's reserves and accrues as LP value. This is intentional: the implementation never returns dust to the caller from a pre-fund, because doing so would require an extra transfer and complicates atomicity.

### Flash Loans
The pool implements the ERC-3156 flash-loan standard. Any caller may borrow any pool token within a single transaction, provided the principal plus a fee is repaid before the call returns. The flash-loan fee rate $f_{\mathrm{flash}}$ is an immutable parameter set at deployment (capped at $< 10{,}000$ ppm, i.e. $< 1\%$). The protocol share $\phi$ of the flash-loan fee is separated and made owed to the protocol fee address; the remainder accrues to LPs by remaining in the pool's cached balances, raising $S$ analogously to retained swap fees. Flash loans are disabled when the pool is killed (see below).

### Token Delivery and Funding Modes
User-facing entry points (`swap`, `mint`, `swapMint`, `burnSwap`) accept any of four token-delivery modes; the choice is independent of the pricing kernel and exists purely to integrate with diverse caller infrastructures.

- **Approval.** Standard `transferFrom` from the caller; the caller must hold and have approved the input balance.
- **Pre-funding.** The caller deposits tokens to the pool address before invoking the operation. Any dust above the exact required amount is credited to LP reserves under the rounding policy above.
- **Callback.** Aggregators or routers may implement a callback interface; the pool calls `payer.fundingSelector(nonce, token, amount, cbData)` and measures the resulting balance delta to determine the funded amount.
- **Permit2.** Uniswap's Permit2 signature-based transfer is supported with typed witness data binding the operation's parameters into the signature, preventing replay and parameter substitution. Witness types are defined for `swap`, `mint`, and `swapMint`.

The flash-loan entry point does not use a funding mode: it lends out the principal and pulls repayment via `transferFrom` after the borrower's callback returns.

## Risk Management and Bounded Loss
Under constant $b$, classical LMSR admits a worst-case loss bound of $b \ln n$ in the payoff numéraire. With $b(\mathbf{q})=\kappa S(\mathbf{q})$, the per-state bound scales with the current size metric, giving an instantaneous worst-case loss $b(\mathbf{q}) \ln n = \kappa\,S(\mathbf{q})\,\ln n$; per unit of size $S$ this is $\kappa \ln n$. Because $b$ varies with state, global worst-case loss along an arbitrary path depends on how $S$ evolves, but the proportionality clarifies how risk scales with liquidity. Operational mitigations include user output guarantees (`minAmountOut`), capacity caps on outputs ($y \le q_j$), minimum bootstrap $S^{(0)}$ to avoid thin-liquidity regimes, and strict numerical guards (e.g., positivity of inner logarithm arguments) to prevent nonphysical states.

### Liquidity Manipulation and Piecewise‑b Attack Considerations
A natural concern when $b$ is state‑dependent and updated discretely is that an adversary might temporarily inflate or deflate $S$ (and hence $b=\kappa S$) via minting or burning operations, use the altered depth to execute a favorable trade, and then revert $S$ to extract value. Our construction prevents such exploitative profit extraction for three structural reasons.

First, any operation that changes the size metric $S$ is itself implemented using the same LMSR kernel that prices ordinary swaps: proportional liquidity changes are exact scalings and single‑asset mints/redeems are solved by composing a proportional rescaling with fee‑free kernel swaps (see the definition of $a_{\mathrm{req}}(\alpha)$ above). Consequently, the cost of moving the pool to a new $S$ is the sum of kernel‑priced components; there is no off‑market “free” lever to change $b$.

Second, proportional liquidity steps are value‑neutral in the fee‑free kernel. If $\mathbf q\mapsto(1+\alpha)\mathbf q$ then $b\mapsto(1+\alpha)b$ and all pairwise marginal ratios are invariant under this homothety; a proportional mint followed by its exact inverse returns the pool to the same state without net transfer of value. Thus proportional scale changes do not create arbitrage.

Third, single‑asset operations decompose into a proportional scaling plus a bundle of LMSR swaps that are priced by the same convex potential. In particular,

$$
a_{\mathrm{req}}(\alpha)=\alpha q_i + \sum_{j\ne i} x_j(\alpha)
$$

where each $x_j(\alpha)$ is the kernel‑priced input required to realize the implied rebalancing outputs; these terms are not subsidized and therefore internalize the economic cost of changing $S$.

Together, these properties imply that any closed sequence of allowed operations (mints, burns, and swaps) corresponds to a concatenation of kernel‑priced steps. Because the LMSR cost function $C(\mathbf q)$ is convex, the net kernel cost for a closed cycle satisfies

$$
\sum_{\text{legs}} \Delta C \;=\; C(\mathbf q_{\text{end}}) - C(\mathbf q_{\text{start}}) \;=\; 0
$$

in the fee‑free idealization, and any practical implementation costs (fees, rounding, or discrete approximation) make the cycle strictly loss‑making for the attacker. In other words, there is no cheaper piecewise route through state space than the kernel‑priced path: discretizing $b$ does not create a systematic negative‑cost cycle. Fee collection further ensures strict economic protection for LPs, since retained fees increase $S$ and accrue to LPs under $L\propto S$.

Practical caveats are implementation risks rather than fundamental failures of the design: asymmetric rounding, inconsistent handling of internal vs external fees, or privileged subsidized LP issuance could create small edges exploitable by high‑frequency searchers. These are engineering and policy issues that can be mitigated by consistent rounding rules, uniform fee policies for user‑facing flows, and transparent, unsponsored LP issuance. Overall, the piecewise/quasi‑static update of $b(\mathbf q)=\kappa S(\mathbf q)$ preserves the convex‑kernel protection against profitable round‑trip manipulation and thereby protects LP value.

## Deployment and Parameter Fixity
The parameter tuple $(\kappa, f, \phi, f_{\mathrm{flash}})$ is set at deployment and remains immutable, with $\kappa>0$ defining $b(\mathbf{q})=\kappa S(\mathbf{q})$, $f=(f_0,\dots,f_{n-1})$ the per-token swap-fee vector, $\phi$ the protocol share of fees, and $f_{\mathrm{flash}}$ the flash-loan fee rate. Given the initial state $\mathbf{q}^{(0)}$ with $S^{(0)}>0$, the induced pricing map is fully determined by

$$
C(\mathbf{q}) = b(\mathbf{q}) \log\!\left(\sum_i e^{q_i / b(\mathbf{q})}\right), \qquad b(\mathbf{q})=\kappa S(\mathbf{q}),
$$

and the two-asset closed forms above. Fixity eliminates governance risk, makes depth calibration transparent, and simplifies integration for external routers and valuation tools.

### Parameter Bounds
The deployer enforces hard caps on each parameter at construction time, bounding the parameter space across all pools:

| Parameter | Bound |
|---|---|
| Per-token swap fee $f_i$ | $< 10{,}000$ ppm ($< 1\%$) |
| Flash-loan fee $f_{\mathrm{flash}}$ | $< 10{,}000$ ppm ($< 1\%$) |
| Protocol fee share $\phi$ | $< 400{,}000$ ppm ($< 40\%$) |
| Asset count $n$ | $\ge 2$ |

These bounds are checked once at deployment and cannot be changed thereafter.

### Mutable Admin State
A single piece of admin-controlled state remains mutable post-deployment: the **protocol fee address**, the destination for collected protocol fees. The owner may update it via `setProtocolFeeAddress`. Setting it to the zero address is rejected when $\phi > 0$ (so collected fees always have a valid recipient). Protocol fees accumulate in a per-token ledger and are disbursed by an explicit `collectProtocolFees` call, decoupling fee collection from any user-facing operation. This mutability is intentional and limited: it lets the protocol rotate the destination key (for example, to migrate to a new treasury) without requiring redeployment, and it does not affect any pricing or economic invariant of the pool.

### Emergency Kill Switch
The pool owner may irrevocably call `kill()`, after which all state-mutating entry points (`swap`, `mint`, `swapMint`, `burnSwap`, `flashLoan`) revert. Only the proportional `burn()` operation remains functional, so LPs can always withdraw their pro-rata share of pool assets. The action is one-way; there is no `unkill`. This is intended as an emergency response if a critical vulnerability is discovered after deployment, and is disjoint from the immutable parameter set: the LMSR parameters $(\kappa, f, \phi, f_{\mathrm{flash}})$ remain fixed for the entire lifetime of the pool — `kill()` halts new operations rather than altering parameters — and the proportional-redemption guarantee is preserved by construction.

## Conclusion
By coupling LMSR with the proportional parameterization $b(\mathbf{q})=\kappa S(\mathbf{q})$, we obtain a multi-asset AMM that preserves softmax-driven price ratios under a quasi-static-b view and supports any-to-any swaps via a single convex potential. Exact two-asset reductions yield closed-form mappings for exact-in, exact-out, limit-hitting, and capped-output trades, and the same formulas underpin liquidity operations with monotonicity and uniqueness. Numerical stability follows from log-sum-exp evaluation, ratio-first derivations, guarded transcendental domains, and optional near-balance approximations, while fixed parameters provide predictable scaling and transparent economics.

## References
Hanson, R. (2002) [_Logarithmic Market Scoring Rules for Modular Combinatorial Information Aggregation_](https://mason.gmu.edu/~rhanson/mktscore.pdf)  
Othman, Pennock, Reeves, Sandholm (2013) [_A Practical Liquidity-Sensitive Automated Market Maker_](https://www.cs.cmu.edu/~sandholm/liquidity-sensitive%20market%20maker.EC10.pdf)  

# Liquidity Party: A Quasi-static Logarithmic Market Scoring Rule Automated Market Maker

## Abstract
We present a multi-asset automated market maker whose pricing kernel is the Logarithmic Market Scoring Rule (LMSR) ([R. Hanson, 2002](https://mason.gmu.edu/~rhanson/mktscore.pdf)). The pool maintains the convex potential $C(\mathbf{q}) = b(\mathbf{q}) \log\!\Big(\sum_i e^{q_i / b(\mathbf{q})}\Big)$ over normalized inventories $\mathbf{q}$, and sets the effective liquidity parameter proportional to pool size as $b(\mathbf{q}) = \kappa \, S(\mathbf{q})$ with $S(\mathbf{q}) = \sum_i q_i$ and fixed $\kappa>0$. This proportional parameterization preserves scale-invariant responsiveness while retaining softmax-derived pairwise price ratios under a quasi-static-$b$ view, enabling any-to-any swaps within a single potential. We derive and use closed-form expressions for two-asset reductions to compute exact-in, exact-out, limit-hitting (swap-to-limit), and capped-output trades. We discuss stability techniques such as log-sum-exp, ratio-once shortcuts, and domain guards for fixed-point arithmetic. Liquidity operations (proportional and single-asset joins/exits) follow directly from the same potential and admit monotone, invertible mappings. Parameters are immutable post-deployment for transparency and predictable depth calibration.

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

## Price Limits, Swap-to-Limit, and Capacity Caps
Users may provide a maximum acceptable marginal price ratio $\Lambda>0$ for $p_i/p_j$. The marginal ratio trajectory $r(t)=r_0 e^{t/b}$ first reaches the limit at the unique

$$
a_{\text{lim}} \;=\; b \,\ln\!\left(\frac{\Lambda}{r_0}\right),
$$

and the output realized at that truncation is

$$
y_{\text{lim}} \;=\; b \,\ln\!\Big( 1 + r_0 \,\big(1 - r_0/\Lambda\big) \Big).
$$

Outputs are further bounded by available inventory; if a computed $y$ would exceed $q_j$, we cap at $y=q_j$ and compute the implied input by inverting the exact-out formula,

$$
a_{\text{cap}} \;=\; b \,\ln\!\left(\frac{r_0}{\,r_0 + 1 - e^{\,q_j/b}\,}\right).
$$

These limit and capacity branches ensure monotone, conservative behavior near domain edges.

## Liquidity Operations from the Same Potential
Liquidity is accounted via pool shares $L$ taken proportional to the size metric, and we set $L=S(\mathbf{q})$ without loss of generality. At initialization with seed balances $\mathbf{q}^{(0)}$ the pool sets $L^{(0)}=S^{(0)}$ and $b^{(0)}=\kappa S^{(0)}$. A proportional deposit that scales balances to $\mathbf{q}'=(1+\alpha)\mathbf{q}$ mints $\Delta L = \alpha S(\mathbf{q})$ shares and scales liquidity to $b'=(1+\alpha)b$. Single-asset deposits target a proportional growth while rebalancing through kernel swaps: providing amount $a$ of asset $i$ induces a growth factor $\alpha\ge 0$ satisfying the monotone equation

$$
a \;=\; a_{\text{req}}(\alpha) \;=\; \alpha q_i \;+\; \sum_{j\ne i} b \,\ln\!\left(\frac{r_{0,j}}{\,r_{0,j} + 1 - e^{\,\alpha q_j/b}\,}\right), \quad r_{0,j}:=\exp\!\left(\frac{q_i-q_j}{b}\right),
$$

and mints $\Delta L=\alpha S(\mathbf{q})$ upon the unique solution. Proportional withdrawals burn $\Delta L$ and return $\alpha=\Delta L/S(\mathbf{q})$ of each asset, updating $b$ to $(1-\alpha)b$. Single-asset withdrawals redeem $\alpha q_i$ directly and swap each redeemed $\alpha q_j$ for $j\ne i$ into $i$ using the exact-in mapping evaluated on the local post-burn state; any capacity overrun is handled by a cap-and-invert branch as above. Because all operations reduce to the same two-asset closed forms, they inherit monotonicity and uniqueness.

### Single-Asset Mint and Redeem

#### Single-Asset Mint
Given a deposit of amount $a>0$ of asset $i$, the pool targets a proportional growth factor $\alpha \ge 0$ so that the post-mint state can be rebalanced to $(1+\alpha)\,\mathbf{q}$ using fee-free kernel swaps from $i$ into each $j\ne i$. For each $j\ne i$, let $y_j := \alpha\,q_j$ and define $r_{0,j} := \exp\!\big((q_i - q_j)/b\big)$. The input required to realize $y_j$ via the exact-out inverse is

$$
x_j(\alpha) \;=\; b \,\ln\!\left(\frac{r_{0,j}}{\,r_{0,j} + 1 - e^{\,y_j/b}\,}\right),
$$

so the total required input for growth $\alpha$ is

$$
a_{\text{req}}(\alpha) \;=\; \alpha\,q_i \;+\; \sum_{j\ne i} x_j(\alpha).
$$

Properties and solver:
- Monotonicity: $a_{\text{req}}(\alpha)$ is strictly increasing on its feasible domain, guaranteeing a unique solution.
- Solver: bracket $\alpha$ (e.g., start from $\alpha\sim a/S$ and double until $a_{\text{req}}(\alpha)\ge a$ or a safety cap), then bisection to a small tolerance $\varepsilon$ (e.g., $\sim10^{-6}$ in fixed-point units).
- Guards: enforce $b>0$, $e^{y_j/b}$ within range, and positivity of the denominator $r_{0,j}+1-e^{y_j/b}$; if a guard would be violated for some $j$, treat that path as infeasible and adjust the bracket.
- Outcome: the consumed input is $a_{\text{in}} = a_{\text{req}}(\alpha^\star) \le a$ and minted LP shares are $\Delta L = \alpha^\star S(\mathbf{q})$.

#### Single-Asset Redeem
Burning a proportional share $\alpha \in (0,1]$ returns a single asset $i$ by redeeming and rebalancing from other assets into $i$:
1) Form the local state after burn, $\mathbf{q}_{\text{local}}=(1-\alpha)\,\mathbf{q}$.
2) Start with the direct redemption $\alpha\,q_i$ in asset $i$.
3) For each $j\ne i$, withdraw $a_j := \alpha\,q_j$ and swap $j\to i$ using the exact-in form evaluated at $\mathbf{q}_{\text{local}}$:

$$
r_{0,j} \;=\; \exp\!\left(\frac{q^{\text{local}}_j - q^{\text{local}}_i}{b}\right),\qquad
y_{j\to i} \;=\; b \,\ln\!\Big(1 + r_{0,j}\,\big(1 - e^{-a_j/b}\big)\Big).
$$

4) Capacity cap and inverse: if $y_{j\to i} > q^{\text{local}}_i$, cap to $y=q^{\text{local}}_i$ and solve the implied input via

$$
a_{j,\text{used}} \;=\; b \,\ln\!\left(\frac{r_{0,j}}{\,r_{0,j} + 1 - e^{\,q^{\text{local}}_i/b}\,}\right),
$$

then update $\mathbf{q}_{\text{local}}$ accordingly.
5) The single-asset payout is

$$
Y_i \;=\; \alpha\,q_i \;+\; \sum_{j\ne i} y_{j\to i}, \qquad \text{with LP burned } L_{\text{in}} = \alpha \, S(\mathbf{q}).
$$

Guards and behavior:
- Enforce $b>0$, positivity of inner terms (e.g., $r_{0,j} + 1 - e^{y/b} > 0$), and safe exponent ranges; treat any per-asset numerical failure as zero contribution rather than aborting the whole redeem.
- The mapping is monotone in $\alpha$; the cap-and-invert branch preserves safety near capacity.

### LP Pricing vs. an Asset Token
With LP supply set to $L=S(\mathbf{q})$, the instantaneous price of one LP share in units of asset $k$ aggregates marginal exchange rates from each asset into $k$:

$$
P_L^{(k)}(\mathbf{q}) \;=\; \frac{1}{S(\mathbf{q})}\,\sum_{j=0}^{n-1} q_j \,\exp\!\left(\frac{q_j - q_k}{b(\mathbf{q})}\right).
$$

Interpretation: proportional deposits leave $P_L^{(k)}$ unchanged; swap fees retained in the pool increase $S$ relative to outstanding $L$, raising $P_L^{(k)}$ (implicit fee accrual). This expression helps LPs and integrators reason about share valuation and dilution across assets.

## Numerical Methods and Safety Guarantees
We evaluate log-sum-exp with recentring, compute ratios like $r_0=\exp((q_i-q_j)/b)$ directly rather than dividing exponentials, and guard all $\exp$ and $\ln$ calls to bounded domains with explicit checks on positivity of inner terms such as $r_0+1-e^{y/b}$. Fixed-point implementations precompute reciprocals like $1/b$ to reduce dispersion, clamp to capacity before inversion, and select cap-and-invert rather than extrapolating when inner terms approach zero. These measures ensure the swap maps remain strictly order-preserving and free of nonphysical outputs. Property-based and differential testing can confirm monotonicity of $y(a)$ and $a(y)$, uniqueness of limit hits when $\Lambda>r_0$, and adherence to predefined error budgets.

## Balanced Regime Optimization: Approximations, Dispatcher, and Stability
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
- Limit-price gate: approximate the limit truncation only when a positive limit is provided with $\Lambda>r_0$ and $|(\Lambda/r_0)-1| \le 0.1$; otherwise compute the limit exactly (or reject if $\Lambda \le r_0$).
- Capacity and positivity: require $b>0$ and $a>0$, and ensure the approximated output $\tilde{y}(a) \le q_j$; otherwise fall back to the exact cap-and-invert.
- Example thresholds: $\delta_\star=0.01$, $\tau_{\text{tier1}}=0.1$, $\tau_\star=0.5$, and an auxiliary limit-ratio gate $|x| \le 0.1$ where $x=(\Lambda/r_0)-1$ (for reference, $e^{\delta_\star}\approx 1.01005$).

### Approximation Path
- Replace $\exp$ on the bounded $\tau$ domain and $\ln(1+\cdot)$ with verified polynomials to meet a global error budget while maintaining $\tilde{y}'(a)>0$ on the domain.
- Cache common subexpressions (e.g., $r_0=e^\delta$, $\tau=a/b$) and guard inner terms to remain in $(0,\infty)$.

### Fallback Policy
- If any precondition fails (magnitude, domain, capacity, or limit binding), evaluate the exact closed forms for $y(a)$ or $a(y)$ (with cap and limit branches), preserving monotonicity and uniqueness.
- Prefer cap-and-invert near capacity or when the inner term of $\ln(\cdot)$ approaches zero.

### Error Shape
- The small-argument expansion above shows the leading behavior; when using polynomial surrogates, the composed relative error can be kept within a target $\epsilon$ with degrees chosen for the specified $(\delta_\star,\tau_\star,u_\star)$, yielding an error budget of the form $\epsilon \approx \epsilon_{\exp} + \epsilon_{\ln} + c_1 \tau_\star + c_2 |\delta_\star| \tau_\star$ for modest constants $c_1,c_2$.
- These bounds ensure the approximated path remains order-preserving and safely within domain; outside the domain, the dispatcher reverts to the exact path.
- Regardless of path, our policy prioritizes monotonicity, domain safety, and conservative decisions at boundaries.

## Fees and Economic Considerations
Fees are applied outside the fee-free LMSR kernel and are retained in the pool so that fee accrual increases the size metric $S(\mathbf{q})$ (and thereby raises LP share value under $L\propto S$). We extend the single global swap-fee to a per-token fee vector $f = (f_0, f_1, \dots, f_{n-1})$, where $f_i$ denotes the canonical fee rate associated with token $i$ (expressed as a fractional rate, e.g., ppm or bps). For a trade that takes token $i$ as input and token $j$ as output, the pool computes an effective pair fee and applies it to the user-submitted input before invoking the fee-free kernel.

Effective pair fee composition
- The effective fee for an asset-to-asset swap is an exact multiplicative composition:
  $$
  f_{\mathrm{eff}} \;=\; 1 - (1 - f_i)\,(1 - f_j),
  $$

Asset-to-asset policy
- Charge on input: compute the kernel input as
  $$
  a_{\mathrm{eff}} \;=\; a_{\mathrm{user}}\,(1 - f_{\mathrm{eff}})
  $$
  and pass $a_{\mathrm{eff}}$ to the fee-free LMSR kernel; collect the retained fee in the input token. Charging on input keeps gas logic simple and makes effective price shifts monotone and predictable for takers.
- Protocol fees are taken as a fraction of LP fee earnings, and immediately moved to a separate account that does not participate in liquidity operations.
- Limit semantics: all limitPrice and cap computations refer to the fee-free kernel path (i.e., are evaluated against the kernel output computed from $a_{\mathrm{eff}}$). Aggregators should compute $f_{\mathrm{eff}}$ externally and present accurate expected outputs to users.

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
- Conceptual consistency: single-asset operations touch a single external token, so applying only that token’s fee is the most natural mapping from the per-token fee vector to operation-level economics. For asset-to-asset swaps the two-token multiplicative composition remains the canonical rule.
- $f_{\mathrm{LP}} = 0$: keeping LP-side fees at zero simplifies LP accounting and avoids double charging when LP shares are the other leg of a transaction. LPs still receive value via retained fees that increase $S$.

Rounding
Our policies aim to always protect the LPs value.
- Total fees are rounded up for the benefit of the pool and against takers.
- The Protocol fee is rounded down for the benefit of LPs and against the protocol developers.

## Risk Management and Bounded Loss
Under constant $b$, classical LMSR admits a worst-case loss bound of $b \ln n$ in the payoff numéraire. With $b(\mathbf{q})=\kappa S(\mathbf{q})$, the per-state bound scales with the current size metric, giving an instantaneous worst-case loss $b(\mathbf{q}) \ln n = \kappa\,S(\mathbf{q})\,\ln n$; per unit of size $S$ this is $\kappa \ln n$. Because $b$ varies with state, global worst-case loss along an arbitrary path depends on how $S$ evolves, but the proportionality clarifies how risk scales with liquidity. Operational mitigations include user price limits (swap-to-limit), capacity caps on outputs ($y \le q_j$), minimum bootstrap $S^{(0)}$ to avoid thin-liquidity regimes, and strict numerical guards (e.g., positivity of inner logarithm arguments) to prevent nonphysical states.

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
The parameter tuple $(\kappa, f_{\text{swap}}, \phi)$ is set at deployment and remains immutable, with $\kappa>0$ defining $b(\mathbf{q})=\kappa S(\mathbf{q})$, $f_{\text{swap}}$ the swap fee rate, and $\phi$ the protocol share of fees. Given the initial state $\mathbf{q}^{(0)}$ with $S^{(0)}>0$, the induced pricing map is fully determined by

$$
C(\mathbf{q}) = b(\mathbf{q}) \log\!\left(\sum_i e^{q_i / b(\mathbf{q})}\right), \qquad b(\mathbf{q})=\kappa S(\mathbf{q}),
$$

and the two-asset closed forms above. Fixity eliminates governance risk, makes depth calibration transparent, and simplifies integration for external routers and valuation tools.

## Conclusion
By coupling LMSR with the proportional parameterization $b(\mathbf{q})=\kappa S(\mathbf{q})$, we obtain a multi-asset AMM that preserves softmax-driven price ratios under a quasi-static-b view and supports any-to-any swaps via a single convex potential. Exact two-asset reductions yield closed-form mappings for exact-in, exact-out, limit-hitting, and capped-output trades, and the same formulas underpin liquidity operations with monotonicity and uniqueness. Numerical stability follows from log-sum-exp evaluation, ratio-first derivations, guarded transcendental domains, and optional near-balance approximations, while fixed parameters provide predictable scaling and transparent economics.

## References
Hanson, R. (2002) [_Logarithmic Market Scoring Rules for Modular Combinatorial Information Aggregation_](https://mason.gmu.edu/~rhanson/mktscore.pdf)  
Othman, Pennock, Reeves, Sandholm (2013) [_A Practical Liquidity-Sensitive Automated Market Maker_](https://www.cs.cmu.edu/~sandholm/liquidity-sensitive%20market%20maker.EC10.pdf)  

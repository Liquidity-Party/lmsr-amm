# Introduction

[Liquidity Party](https://liquidity.party) is a new game-theoretic multi-asset AMM based on this research paper:

[Logarithmic Market Scoring Rules for Modular Combinatorial Information Aggregation](https://mason.gmu.edu/~rhanson/mktscore.pdf) (R. Hanson, 2002)

Our formulation and implementation is described in the [Liquidity Party whitepaper.](doc/whitepaper.md)

A Logarithmic Market Scoring Rule (LMSR) is a pricing formula for AMM's that know only their current asset inventories
and no other information, naturally supporting multi-asset pools.

Compared to Constant Product markets, LMSR offers:

1. Less slippage than Constant Product for small and medium trade sizes
2. N-asset pools for trading long-tail pairs in a single hop
3. Lower fees (smaller spread)


## Deeper Liquidity

According to game theory, the initial price slope of a Constant Product AMM is too steep, overcharging takers
with too much slippage at small and medium trade sizes. LMSR pools offer less slippage and cheaper
liquidity for the small and medium trade sizes used by real traders.


## Multi-asset

Naturally multi-asset, Liquidity Party altcoin pools provide direct, one-hop swaps on otherwise illiquid multi-hop pairs. Pools will quote any pair combination available in the pool:

| Assets | Pairs | Swap Gas |  Mint Gas |
|-------:|------:|---------:|----------:|
|      2 |     1 |  144,000 |   142,000 |
|     2* |     1 |  132,000 |   142,000 |
|     10 |    45 |  150,000 |   412,000 |
|     20 |   190 |  164,000 |   749,000 |
|     50 |  1225 |  211,000 | 1,750,000 |

\* Stablecoin pair pool optimization

Liquidity Party aggregates scarce, low market cap assets into a single pool, providing one-hop liquidity for exotic pairs without fragmenting LP assets. CP pools would need 190x the LP assets to provide the same pairwise liquidity as a single 20-asset Liquidity Party pool, due to asset fragmentation.

## Lower Fees

Since market makers offer the option to take either side of the market, they must receive a subsidy or charge a fee (spread) to compensate for adverse selection (impermanent loss). By protecting LP's against common value-extraction scenarios, LMSR pools have a reduced risk premium resulting in lower fees for takers.

### Minimized Impermanent Loss
All AMM's suffer from Impermanent Loss (IL), also known as adverse selection or toxic order flow. Liquidity
Party uses game theory to minimize IL for LPs, by charging lower fees to small legitimate traders and
higher fees to large adversarial traders during market dislocations. This means a higher effective rate
for LP's and cheaper swaps for legitimate small traders.

Liquidity Party swaps guarantee a bounded maximum loss to LP's of `κ\*S\*ln(N)` where `κ` is
the pool's liquidity parameter, `S` is the total size of the pool, and `N` is the
number of assets in the pool.

### No Intra-Pool Arbitrage
Other multi-asset systems can provide inconsistent price quotes, allowing arbitragers to
extract value from LP's by _trading assets inside the same pool against each other._ With Liquidity
Party, no intra-pool arbitrage is possible, because the mathematics guarantee fully consistent price
quotes on all pairs in the pool.

# Installation

1. Install [Foundry](https://getfoundry.sh/) development framework.
2. Update dependencies with `forge install`
3. Run `bin/mock` to launch a test environment running under `anvil` on `localhost:8545`. The mock environment will create several example pools along with mock ERC20 tokens that can be minted by anyone in any amount.

# Integration

Deployment addresses for each chain may be found in `deployment/liqp-deployments.json`, and the `solc` output including ABI information is stored under `deployment/{chain_id}/v1/...`

The primary entrypoint for all Liquidity Party actions is the [PartyPlanner](src/IPartyPlanner.sol) contract, which is a singleton per chain. The `PartyPlanner` contract not only deploys new pools but also indexes the pools and their tokens for easy metadata discovery. After a pool is created or discovered using the `PartyPlanner`, it can be used to perform swaps, minting, and other actions according to the [IPartyPool](src/IPartyPool.sol) interface. Due to contract size limitations, most view methods for prices and swaps are available from a separate singleton contract, [PartyInfo](src/IPartyInfo.sol).


# Implementation Notes

## Non-upgradable Proxy
Due to contract size constraints, the `PartyPool` contract uses `DELEGATECALL` to invoke implementations on the singleton [PartyPoolSwapImpl](src/PartyPoolSwapImpl.sol) and [PartyPoolMintImpl](src/PartyPoolMintImpl.sol) contracts. This proxy pattern is NOT upgradable and the implementation contract addresses used by the pool are immutable. Views implemented in `PartyInfo` have no delegation but simply accept the target pool as an argument, calculating prices etc. from public getters.

## Admin-Only Deployment
`PartyPlanner` allows only the admin to deploy new pools. This decision was made because Liquidity Party is a new protocol that does not support non-standard tokens such as fee-on-transfer tokens or rebasing tokens, and the selection of the `kappa` liquidity parameter is not straightforward for an average user. We hope to offer a version of Liquidity Party in the future that allows regular users to create their pools.

## Killable Contracts
PartyPools may be "killed" by their admin, in which case all swaps and mints are disabled, and the only modifying function allowed to be called is `burn()` to allow LP's to safely withdraw their funds. Killing is irreversible and intended to be used as a last-ditch safety measure in case a critical vulnerablility is discovered.

## Fee Mechanisms
Each asset in the pool has a fee associated with it, which is paid when that asset is involved in a swap.

The fee for a swap is the input asset fee plus the output asset fee, but this total fee percentage is taken only from the input amount, prior to the LMSR calculation. This results in more of the input asset being collected by the pool compared to the value of the output asset removed. In this way, the LP holders accumulate fee value implicitly in their prorata share of the pool's total assets.

For a swap-mint operation, only the input asset fee is charged on the input token. For a burn-swap, only the output asset fee is charged on the output token.

Flash loans are charged a single fee, the flash fee, no matter what asset is loaned.

Protocol fees are taken as a fraction of any LP fees earned, rounding down in favor of the LP stakers. Protocol fees accumulate in a separate account in the pool until the admin sends a collection transaction to sweep the fees. While protocol fees are waiting to be collected, those funds do not participate in liquidity operations or earn fees.

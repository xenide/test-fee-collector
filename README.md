# Fee Collector

The Vexchange fee collector contract intends to automate the collection,
conversion, and transfer of generated fees to the designated governance address.
The problem it addresses is one of managing an ever-growing number of listed
assets & pairs on Vexchange creating a large cognitive burden on Vexchange's
governance. To address this, the default position of governance must be to sell
all tokens back to a desired asset(s).

## SushiSwap's SushiMakerKashi

SushiSwap achieves this very simply via their [SushiMakerKashi](
https://github.com/sushiswap/sushiswap/blob/canary/contracts/SushiMakerKashi.sol
). This is an extremely simple contract that supports:

- Transferring SUSHI to the xSUSHI staking contract
- Selling non SUSHI tokens for W-ETH
- Overriding the sale to W-ETH via "bridges", a bridge is a non-WETH token that
  would be swapped for. This could mean stablecoins can be swapped to USDC first
  before being finally swapped for W-ETH and then SUSHI.

There are no limits on slippage making front-running profitable in certain
circumstances. This is partially mitigated via the use of `onlyEOA` meaning that
only miners can guarantee safe front-running of the `SushiMakerKashi` contract.

## Vexchange's Approach

Vexchange will also use its own liquidity pools to execute asset sales (as opposed
to an auction or some other mechanism). However, as an extension we will cap the
max trade slippage to:

- Vexchange's portion of the fee for the pair
  - No one can profit from front-running the fee sales
  - If Vexchange's platform fee is `0`, then it will limit the sales to the
    `swapFee`

Vexchange will also support:

- Disabling sales for specific underlying tokens
- Disabling breaking apart of specific Lp tokens
- Setting what token a pair will swap to (non set pairs will swap to default
  desired token)

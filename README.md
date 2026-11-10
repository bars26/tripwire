<img src="docs/logo.png" width="96" alt="Tripwire logo">

# Tripwire

A cross-chain dead-bolt for your wallet, built on [Reactive Network](https://reactive.network) Omni.

Tripwire watches one wallet on several chains. The moment that wallet approves, or sends tokens to,
an address that is not on its allowlist, Tripwire moves the wallet's remaining tokens **on every
chain** to a safe address you chose in advance. No bot, no server, no key online.

Built for the Reactive Omni Buildathon, *Set It and Forget It* track.

**Demo video (74 s):** https://youtu.be/ROqKY8Ezvy8

## Why

Wallet drainers work by getting one malicious approval or signature. Once that happens the attacker
usually empties the wallet token by token and chain by chain, over seconds to minutes. Revoking by
hand is too slow, and a monitoring bot needs a hot key and a server that stays up.

A reactive contract fits exactly: it sees the first bad approval as an event and answers on all
chains at once.

## How it works

```
 Base Sepolia / Unichain Sepolia            Reactive Lasna                 every watched chain
 ───────────────────────────────            ──────────────                 ───────────────────
 wallet emits Approval / Transfer   ──▶   TripwireReactive.react()   ──▶   TripwireRescuer.rescue()
 to an address not on the allowlist       trips once, requests a           transferFrom(wallet → safe)
                                          callback per chain               for each listed token
```

- **`TripwireReactive`** (Reactive Network) subscribes to `Approval`, `ApprovalForAll` and, optionally,
  `Transfer` events where the wallet is the owner/sender, on any contract of each watched chain.
  Revokes and allowlisted counterparties are ignored. Anything else trips the wire: it disarms itself
  and requests one callback per chain.
- **`TripwireRescuer`** (one per destination chain) holds an ERC-20 allowance from the wallet and, on
  callback, pulls every listed token straight to the safe address. It never holds tokens itself.

### Design choices

- **The safe address is immutable.** A stolen wallet key cannot redirect a rescue. The wallet may add
  tokens to the list; only the safe address may remove them.
- **Trips once per incident.** After tripping, the wire stays disarmed until the owner calls `rearm()`,
  so one incident cannot loop or drain the contract's gas budget.
- **Never reverts on the hot path.** A reverting `react()` or callback is still billed, so unmatched
  logs fall through and a broken token is skipped (`RescueFailed`) instead of blocking the rest.
- **Bounded loops.** At most 8 chains and 16 tokens per rescuer; a full 16-token rescue measures
  about 745k gas in tests against a 1.5M callback limit.
- **Works without Reactive too.** The safe address can call `sweep()` directly, and the owner can call
  `panic()` to trigger a rescue by hand.

## Limits

- **ERC-20 only.** Native ETH in an EOA cannot be pulled by a contract. NFT approvals are treated as
  an alarm, but NFTs themselves are not moved.
- **Containment, not prevention.** A token approved and drained inside the same transaction is gone.
  Tripwire saves the other tokens and the other chains.
- **You must keep an allowlist.** Every DEX or contract you approve has to be trusted first with
  `setTrusted`, otherwise your own approval trips the wire.
- **Both sides need gas.** The reactive contract pays in REACT, each rescuer in its chain's native
  token. A contract in debt receives nothing.

## Run the tests

```bash
git clone --recurse-submodules https://github.com/bars26/tripwire && cd tripwire
forge test
```

23 tests cover what trips and what does not, callback authentication, partial allowances, broken and
non-standard tokens, the token-list rules and the gas ceiling.

## Deploy (testnet)

```bash
cp .env.example .env   # fill in DEPLOYER_KEY, WALLET, SAFE
./script/deploy.sh
```

The script deploys `TripwireReactive` to Lasna, a `TripwireRescuer` to Base Sepolia and Unichain
Sepolia, wires them together and trusts the safe address. Then, from the protected wallet on each
chain: `addToken(token)` on the rescuer and `approve(rescuer, max)` on the token.

Get lREACT by sending Sepolia ETH to the faucet described in the
[Reactive docs](https://dev.reactive.network/reactive-mainnet).

## Deployed addresses and transaction hashes

| Contract | Network | Address |
|---|---|---|
| `TripwireReactive` | Reactive Lasna | `0xF15Ed5B022A68E84A105f0C09175dA4A53236269` |
| `TripwireRescuer` | Base Sepolia | `0x38E0b6843e374548896eAF59304E8ba6FFa5Ed14` |
| `TripwireRescuer` | Unichain Sepolia | `0x008F87A7dc59D3763750Ba949B625aC60F31a2f5` |

Demo wallet `0x5d677227671bfe1FA80293ee66cb309dAA7FEF99`, safe address
`0xA5efcDaFf73265FB8a37faD47114d1f9ea205dD9`. The wallet held 1,000 tUSD and 1,000 tWETH (free-mint
demo tokens) on each chain.

One full loop, started by the wallet approving an unknown spender for tUSD on Base Sepolia:

| Step | Network | Transaction |
|---|---|---|
| Origin: `approve(drainer, max)` | Base Sepolia | `0xde5dba1a57f2739a585acfb65ff0cde69ff19ccc636cc15822c7031348e1ffad` |
| Reactive: `react()` emits `Tripped`, requests 2 callbacks | Reactive Lasna | `0xc7920d3771441c7453cf36e7c7c0e1e1363fd609fbdd22b6330afdab7b02548e` |
| Callback: `rescue()` moves tUSD + tWETH to the safe | Base Sepolia | `0xc022ff82a2c5a8be5bea27c789b57dcef035d66c140abf0ba3a10509098504f5` |
| Callback: `rescue()` moves tUSD + tWETH to the safe | Unichain Sepolia | `0x35e94c081cb7dbaac8acb4600b445bf1afedd935cd70a577c9ddf1e05374512d` |

Measured on that run: the Base Sepolia rescue landed 9 blocks (about 1.8 s) after the approval, and
the Unichain Sepolia rescue carried a block timestamp 2 s after it. All four balances went from the
wallet to the safe; each rescue used about 148k gas.

Base Sepolia also received a second, empty `rescue()` delivery 7 s later
(`0x86ea4881…27f7`) although the reactive contract tripped once and requested one callback per
chain. It found nothing left to move. The rescuer is idempotent, so a repeated delivery only costs
gas; why it was delivered twice is not yet explained.

Reproduce with `./script/setup-demo.sh` followed by `./script/attack.sh`.

## License

MIT

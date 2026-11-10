# DoraHacks submission — Reactive Omni Buildathon

Paste the sections below into the matching fields on the "Submit Build" form.

## Build name

Tripwire

## Track

Set It and Forget It

## One-line description

A cross-chain dead-bolt for your wallet: one bad approval on any chain moves your tokens to safety on every chain.

## Description

**The problem I wanted solved for myself.** Wallet drainers need one malicious approval. After that they empty the wallet token by token and chain by chain, over seconds to minutes. Revoking by hand is too slow, and a monitoring bot needs a hot key and a server that never goes down. I wanted something I could set up once and stop thinking about.

**What Tripwire does.** It watches one wallet on several chains. The moment that wallet approves, or sends tokens to, an address that is not on its allowlist, Tripwire moves the wallet's remaining ERC-20s on every watched chain to a safe address chosen in advance.

**How Reactive does the work.**

- `TripwireReactive` on Reactive Network subscribes to `Approval`, `ApprovalForAll` and, optionally, `Transfer` events where the wallet is the owner or sender, on any contract of each watched chain. Revokes and allowlisted counterparties fall through. Anything else trips the wire: the contract disarms itself and requests one callback per chain with `requestCallbackV_1_0`.
- `TripwireRescuer`, one per destination chain, holds an ERC-20 allowance from the wallet. On callback it pulls every listed token straight from the wallet to the safe address. It never holds tokens.

The reactive contract is the whole product, not an add-on: there is no bot, no server and no key online. Detection, the decision and the cross-chain fan-out all happen in `react()`.

**Design choices.**

- The safe address is immutable, so a stolen wallet key cannot redirect a rescue. The wallet may add tokens to the list; only the safe address may remove them.
- The wire trips once per incident and stays disarmed until `rearm()`, so one incident cannot loop or burn the gas budget.
- Nothing reverts on the hot path. A reverting `react()` or callback is still billed, so unmatched logs fall through and a broken token is skipped instead of blocking the others.
- Loops are bounded: at most 8 chains and 16 tokens per rescuer. A full 16-token rescue measures about 745k gas against a 1.5M callback limit.
- It still works without Reactive: the safe address can call `sweep()` directly, and the owner can call `panic()`.

**Honest limits.** ERC-20 only (native ETH in an EOA cannot be pulled by a contract). It is containment, not prevention: a token approved and drained in the same transaction is gone, and Tripwire saves the other tokens and the other chains. You have to keep the allowlist up to date.

## Measured on testnet

The wallet approved an unknown spender for one token on Base Sepolia. The rescue on Base Sepolia landed 9 blocks (about 1.8 s) later, and the rescue on Unichain Sepolia carried a block timestamp 2 s after the approval. All four balances (two tokens on two chains) moved from the wallet to the safe address.

Base Sepolia also received a second, empty `rescue()` delivery 7 s later although the reactive contract tripped once and requested one callback per chain. The rescuer is idempotent, so it only cost gas. I have not found out why it was delivered twice.

## Deployed contracts

| Contract | Network | Address |
|---|---|---|
| TripwireReactive | Reactive Lasna | 0xF15Ed5B022A68E84A105f0C09175dA4A53236269 |
| TripwireRescuer | Base Sepolia | 0x38E0b6843e374548896eAF59304E8ba6FFa5Ed14 |
| TripwireRescuer | Unichain Sepolia | 0x008F87A7dc59D3763750Ba949B625aC60F31a2f5 |

## Transaction hashes (full loop)

| Step | Network | Hash |
|---|---|---|
| Origin event: `approve(drainer, max)` | Base Sepolia | 0xde5dba1a57f2739a585acfb65ff0cde69ff19ccc636cc15822c7031348e1ffad |
| Reactive transaction: `react()` → `Tripped` + 2 callback requests | Reactive Lasna | 0xc7920d3771441c7453cf36e7c7c0e1e1363fd609fbdd22b6330afdab7b02548e |
| Callback: `rescue()` | Base Sepolia | 0xc022ff82a2c5a8be5bea27c789b57dcef035d66c140abf0ba3a10509098504f5 |
| Callback: `rescue()` | Unichain Sepolia | 0x35e94c081cb7dbaac8acb4600b445bf1afedd935cd70a577c9ddf1e05374512d |

## Links

- Repository: https://github.com/bars26/tripwire
- Demo video: _add the YouTube link_

## Built during the event

All code was written between 9 and 10 November 2026. Dependencies: `reactive-lib-omni` and `forge-std`. 23 Foundry tests, CI on every push.

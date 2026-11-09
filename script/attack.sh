#!/usr/bin/env bash
# Demo incident: the protected wallet approves an unknown spender on Base Sepolia.
# Prints balances before/after on both chains and the time from the approval to each rescue.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

bal() { cast call --rpc-url "$1" "$2" "balanceOf(address)(uint256)" "$3" | awk '{print $1}'; }
report() {
  echo "  Base tUSD   wallet=$(bal "$BASE_SEPOLIA_RPC" "$TOKEN_BASE_tUSD" "$WALLET") safe=$(bal "$BASE_SEPOLIA_RPC" "$TOKEN_BASE_tUSD" "$SAFE")"
  echo "  Base tWETH  wallet=$(bal "$BASE_SEPOLIA_RPC" "$TOKEN_BASE_tWETH" "$WALLET") safe=$(bal "$BASE_SEPOLIA_RPC" "$TOKEN_BASE_tWETH" "$SAFE")"
  echo "  Uni  tUSD   wallet=$(bal "$UNICHAIN_SEPOLIA_RPC" "$TOKEN_UNI_tUSD" "$WALLET") safe=$(bal "$UNICHAIN_SEPOLIA_RPC" "$TOKEN_UNI_tUSD" "$SAFE")"
  echo "  Uni  tWETH  wallet=$(bal "$UNICHAIN_SEPOLIA_RPC" "$TOKEN_UNI_tWETH" "$WALLET") safe=$(bal "$UNICHAIN_SEPOLIA_RPC" "$TOKEN_UNI_tWETH" "$SAFE")"
}

echo "before:"; report

echo "wallet approves the drainer for tUSD on Base Sepolia"
TX=$(cast send --json --private-key "$WALLET_KEY" --rpc-url "$BASE_SEPOLIA_RPC" "$TOKEN_BASE_tUSD" \
  "approve(address,uint256)" "$DRAINER" 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["transactionHash"])')
T0=$(date +%s)
echo "  approval tx: $TX"

for PAIR in "Base:$BASE_SEPOLIA_RPC:$TOKEN_BASE_tWETH" "Unichain:$UNICHAIN_SEPOLIA_RPC:$TOKEN_UNI_tUSD"; do
  NAME=${PAIR%%:*}; REST=${PAIR#*:}; TOKEN=${REST##*:}; RPC=${REST%:*}
  until [ "$(bal "$RPC" "$TOKEN" "$WALLET")" = "0" ]; do
    [ $(( $(date +%s) - T0 )) -gt 180 ] && { echo "  $NAME: no rescue after 180s"; exit 1; }
    sleep 1
  done
  echo "  $NAME rescued ~$(( $(date +%s) - T0 ))s after the approval confirmed"
done

echo "after:"; report

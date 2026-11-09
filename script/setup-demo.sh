#!/usr/bin/env bash
# Testnet demo setup: gas for the demo wallets, lREACT from the faucet, contracts, demo tokens, allowances.
# Needs the deployer funded with Sepolia ETH on Base Sepolia (~0.05) and Unichain Sepolia (~0.02).
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

LASNA_RPC="https://lasna-rpc.rnk.dev/"
FAUCET_BASE=0x2afaFD298b23b62760711756088F75B7409f5967

# Public RPCs can lag a block behind on nonces, so pause after each send and retry a few times.
send() {
  for _ in 1 2 3 4; do
    if cast send --private-key "$1" --rpc-url "$2" "${@:3}" >/dev/null 2>/tmp/tripwire-send.err; then
      sleep 3; return 0
    fi
    sleep 4
  done
  cat /tmp/tripwire-send.err >&2; return 1
}
setenv() { sed -i '' "s|^$1=.*|$1=$2|" .env; }

echo "gas for the protected wallet and the drainer"
for RPC in "$BASE_SEPOLIA_RPC" "$UNICHAIN_SEPOLIA_RPC"; do
  send "$DEPLOYER_KEY" "$RPC" "$WALLET" --value 0.002ether
done
send "$DEPLOYER_KEY" "$BASE_SEPOLIA_RPC" "$DRAINER" --value 0.0005ether

if [ "$(cast balance --rpc-url "$LASNA_RPC" "$DEPLOYER")" = "0" ]; then
  echo "requesting lREACT from the Base Sepolia faucet"
  send "$DEPLOYER_KEY" "$BASE_SEPOLIA_RPC" "$FAUCET_BASE" "request(address)" "$DEPLOYER" --value 0.03ether
  until [ "$(cast balance --rpc-url "$LASNA_RPC" "$DEPLOYER")" != "0" ]; do sleep 5; done
fi

./script/deploy.sh | tee /tmp/tripwire-deploy.log
for K in REACTIVE RESCUER_BASE RESCUER_UNI; do
  setenv "$K" "$(grep "^$K=" /tmp/tripwire-deploy.log | cut -d= -f2)"
done
set -a; source .env; set +a

deployed() { grep -E '^Deployed to:' | awk '{print $3}'; }
for PAIR in "BASE:$BASE_SEPOLIA_RPC:$RESCUER_BASE" "UNI:$UNICHAIN_SEPOLIA_RPC:$RESCUER_UNI"; do
  NAME=${PAIR%%:*}; REST=${PAIR#*:}; RESCUER=${REST##*:}; RPC=${REST%:*}
  echo "demo tokens on $NAME"
  for SYM in tUSD tWETH; do
    TOKEN=$(forge create --broadcast --rpc-url "$RPC" --private-key "$DEPLOYER_KEY" \
      src/demo/DemoToken.sol:DemoToken --constructor-args "Tripwire $SYM" "$SYM" | deployed)
    send "$DEPLOYER_KEY" "$RPC" "$TOKEN" "mint(address,uint256)" "$WALLET" 1000ether
    send "$WALLET_KEY" "$RPC" "$RESCUER" "addToken(address)" "$TOKEN"
    send "$WALLET_KEY" "$RPC" "$TOKEN" "approve(address,uint256)" "$RESCUER" \
      0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
    echo "TOKEN_${NAME}_${SYM}=$TOKEN" | tee -a .env
  done
done
echo "setup complete"

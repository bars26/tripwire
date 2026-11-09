#!/usr/bin/env bash
# Deploys Tripwire to Reactive Lasna + Base Sepolia + Unichain Sepolia.
# Reads everything from .env (see .env.example). Prints the addresses to put back into .env.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

LASNA_RPC="https://lasna-rpc.rnk.dev/"
BASE_CHAIN_ID=84532
UNI_CHAIN_ID=1301
BASE_PROXY=0x476F44b11F5C942c58f4c8E3d0300E5710743585
UNI_PROXY=0x775c9B990ADe401060B78D0e98684eEf8d2466C1

deployed() { grep -E '^Deployed to:' | awk '{print $3}'; }

echo "1/4 TripwireReactive on Lasna"
REACTIVE=$(forge create --broadcast --rpc-url "$LASNA_RPC" --private-key "$DEPLOYER_KEY" \
  --value "${REACTIVE_FUND:-1ether}" src/TripwireReactive.sol:TripwireReactive \
  --constructor-args "$WALLET" "${WATCH_TRANSFERS:-true}" | deployed)
echo "    $REACTIVE"

echo "2/4 TripwireRescuer on Base Sepolia"
RESCUER_BASE=$(forge create --broadcast --rpc-url "$BASE_SEPOLIA_RPC" --private-key "$DEPLOYER_KEY" \
  --value "${RESCUER_FUND:-0.005ether}" src/TripwireRescuer.sol:TripwireRescuer \
  --constructor-args "$BASE_PROXY" "$REACTIVE" "$WALLET" "$SAFE" | deployed)
echo "    $RESCUER_BASE"

echo "3/4 TripwireRescuer on Unichain Sepolia"
RESCUER_UNI=$(forge create --broadcast --rpc-url "$UNICHAIN_SEPOLIA_RPC" --private-key "$DEPLOYER_KEY" \
  --value "${RESCUER_FUND:-0.005ether}" src/TripwireRescuer.sol:TripwireRescuer \
  --constructor-args "$UNI_PROXY" "$REACTIVE" "$WALLET" "$SAFE" | deployed)
echo "    $RESCUER_UNI"

echo "4/4 wiring rescuers + trusting the safe address"
cast send --rpc-url "$LASNA_RPC" --private-key "$DEPLOYER_KEY" "$REACTIVE" \
  "setRescuer(uint256,address)" "$BASE_CHAIN_ID" "$RESCUER_BASE" >/dev/null
cast send --rpc-url "$LASNA_RPC" --private-key "$DEPLOYER_KEY" "$REACTIVE" \
  "setRescuer(uint256,address)" "$UNI_CHAIN_ID" "$RESCUER_UNI" >/dev/null
cast send --rpc-url "$LASNA_RPC" --private-key "$DEPLOYER_KEY" "$REACTIVE" \
  "setTrusted(address,bool)" "$SAFE" true >/dev/null

cat <<EOF

Done. Add to .env:
REACTIVE=$REACTIVE
RESCUER_BASE=$RESCUER_BASE
RESCUER_UNI=$RESCUER_UNI
EOF

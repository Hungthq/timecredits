#!/usr/bin/env bash
# End-to-end demo of SG TimeBank on a local Anvil chain using cast (as in Lab 4).
# Usage: SGT_ADDRESS=0x... ./demo.sh     (Anvil must be running on :8545)
# Uses Anvil's publicly known test accounts. Never use these keys on a real network.
set -euo pipefail
R=${RPC_URL:-http://127.0.0.1:8545}
A=${SGT_ADDRESS:?set SGT_ADDRESS}
MN="test test test test test test test test test test test junk"
key()  { cast wallet private-key --mnemonic "$MN" --mnemonic-index "$1"; }
addr() { cast wallet address --private-key "$(key "$1")"; }
send() { local k=$1; shift; cast send "$A" "$@" --rpc-url "$R" --private-key "$k" >/dev/null; }
call() { cast call "$A" "$@" --rpc-url "$R"; }
warp() { cast rpc evm_increaseTime "$1" --rpc-url "$R" >/dev/null; cast rpc evm_mine --rpc-url "$R" >/dev/null; }
credits() { local raw; raw=$(call "balanceOf(address)(uint256)" "$1" | awk '{print $1}'); printf "%d.%02d" $((raw/100)) $((raw%100)); }

ADMIN=$(key 0); AISHA=$(key 1); RAVI=$(key 2); MEI=$(key 3); KUMAR=$(key 4); COORD_A=$(key 5); COORD_C=$(key 6)
TAG_CC=$(cast keccak "tag-cc-1"); TAG_CLINIC=$(cast keccak "tag-clinic")

echo "== Onboarding (operator) =="
send $ADMIN "verifyVolunteer(address,bytes32,bool,bool)" $(addr 1) $(cast keccak "S1111111A") false false
send $ADMIN "verifyVolunteer(address,bytes32,bool,bool)" $(addr 2) $(cast keccak "S2222222B") false true
send $ADMIN "verifyVolunteer(address,bytes32,bool,bool)" $(addr 3) $(cast keccak "S3333333C") true false
send $ADMIN "verifyVolunteer(address,bytes32,bool,bool)" $(addr 4) $(cast keccak "S4444444D") false false
send $ADMIN "setCoordinator(uint256,address,bool)" 1 $(addr 5) true
send $ADMIN "setCoordinator(uint256,address,bool)" 2 $(addr 6) true
send $ADMIN "linkFamily(address,address)" $(addr 1) $(addr 4)
echo "4 volunteers verified (ravi licensed), 2 coordinators, aisha<->kumar family link"

echo; echo "== Ravi: 3h professional physio at Clinic X (2.0x) =="
send $RAVI "checkIn(uint256,bytes32,uint8)" 2 $TAG_CLINIC 2
S1=$(call "sessionCount()(uint256)")
warp 10800
send $RAVI "checkOut(uint256,bytes32)" $S1 $TAG_CLINIC
send $COORD_C "sign(uint256,uint8)" $S1 1
status() { call "sessions(uint256)(address,uint256,uint8,uint64,uint64,uint64,uint32,uint8,uint256,bool,uint8)" "$1" | tail -1; }
NAMES=(None Open AwaitingSignoff Ready Disputed Minted)
echo "coordinator signed -> status ${NAMES[$(status $S1)]} (needs beneficiary or peer too)"
send $MEI "sign(uint256,uint8)" $S1 3
echo "peer signed -> status ${NAMES[$(status $S1)]}; dispute window ends $(date -u -d @$(call 'disputeWindowEnds(uint256)(uint256)' $S1 | awk '{print $1}') '+%Y-%m-%d %H:%M UTC')"

echo; echo "== Aisha: 4h befriending at Community Centre (1.0x) =="
send $AISHA "checkIn(uint256,bytes32,uint8)" 1 $TAG_CC 0
S2=$(call "sessionCount()(uint256)")
warp 14400
send $AISHA "checkOut(uint256,bytes32)" $S2 $TAG_CC
send $COORD_A "sign(uint256,uint8)" $S2 1

echo "Kumar (family) tries to sign Aisha's hours:"
if cast send "$A" "sign(uint256,uint8)" $S2 3 --rpc-url "$R" --private-key $KUMAR >/dev/null 2>err.txt; then echo "  UNEXPECTED: accepted"; else echo "  refused: $(grep -o 'FamilyCannotSign' err.txt | head -1)"; fi
send $MEI "sign(uint256,uint8)" $S2 3

echo "Finalise before 14 days:"
if cast send "$A" "finalise(uint256)" $S1 --rpc-url "$R" --private-key $ADMIN >/dev/null 2>err.txt; then echo "  UNEXPECTED: minted"; else echo "  refused: $(grep -o 'DisputeWindowOpen' err.txt | head -1)"; fi

echo; echo "== +14 days: dispute window closes, anyone can finalise =="
warp $((14*86400))
send $ADMIN "finalise(uint256)" $S1
send $ADMIN "finalise(uint256)" $S2
echo "ravi  credits: $(credits $(addr 2))   (3h x 2.0)"
echo "aisha credits: $(credits $(addr 1))   (4h x 1.0)"

echo; echo "== Earn-and-burn =="
send $RAVI "redeem(uint256,uint256)" 1 4
echo "ravi redeems 1h at Clinic X Physio (below 20h loyalty threshold) -> $(credits $(addr 2)) left"
send $AISHA "gift(address,uint256)" $(addr 4) 150
echo "aisha gifts 1.50 to kumar (family) -> kumar $(credits $(addr 4)), aisha $(credits $(addr 1))"
send $AISHA "donate(uint256,uint256)" 1 100
echo "aisha donates 1.00 to Elder Care Pool -> pool $(call 'poolBalance(uint256)(uint256)' 1 | awk '{print $1/100}')"
echo "aisha tries to gift to mei (not family):"
if cast send "$A" "gift(address,uint256)" $(addr 3) 50 --rpc-url "$R" --private-key $AISHA >/dev/null 2>err.txt; then echo "  UNEXPECTED: accepted"; else echo "  refused: $(grep -o 'NotFamily' err.txt | head -1)"; fi

echo; echo "== Supply =="
m=$(call "totalMinted()(uint256)" | awk '{print $1}'); b=$(call "totalBurned()(uint256)" | awk '{print $1}')
echo "minted $((m/100)).$(printf %02d $((m%100)))  burned $((b/100)).$(printf %02d $((b%100)))  circulating $(( (m-b)/100 )).$(printf %02d $(( (m-b)%100 )))"

echo; echo "== Event log (Minted) =="
cast logs --address "$A" "Minted(uint256 indexed,address indexed,uint256,bool)" --from-block 0 --rpc-url "$R" | grep -E "transactionHash" | sed 's/^/  /'
rm -f err.txt

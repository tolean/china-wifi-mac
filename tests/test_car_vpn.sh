#!/bin/zsh
# Behaviour tests for car-vpn.sh that need no root and no network beyond localhost.
#   zsh tests/test_car_vpn.sh
PUB=${0:A:h:h}
T=$(mktemp -d)
trap 'rm -rf $T' EXIT

fail() { echo "FAIL: $1"; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'  ($3)"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "expected to contain '$2' in: $1  ($3)"; }
fn() { ( export CWM_SECRETS=$T CWM_SOURCED=1; source $PUB/car-vpn.sh; "$@" ) }

# syntax
zsh -n $PUB/car-vpn.sh || fail "syntax"
# no literal subnet, no route-to outside comment lines
assert_eq "$(grep -c '192\.168\.2\.' $PUB/car-vpn.sh)" 0 "literal subnet"
assert_eq "$(grep -v '^ *#' $PUB/car-vpn.sh | grep -c 'route-to')" 0 "route-to outside comments"

# --- Monkey mode (no key file)
assert_eq "$(fn detect_mode)" monkey "detect_mode without key"
fn ensure_config || fail "ensure_config monkey"
diff $PUB/config.monkey.json $T/car-vpn.json || fail "monkey config not copied verbatim"
out=$(CWM_SECRETS=$T zsh $PUB/car-vpn.sh test); rc=$?
assert_eq $rc 0 "test exit in monkey mode"; assert_contains "$out" "zsh car-vpn.sh check" "test hint in monkey mode"
# root-only commands refuse without sudo
out=$(CWM_SECRETS=$T zsh $PUB/car-vpn.sh car 2>&1); rc=$?
assert_eq $rc 1 "car without sudo"; assert_contains "$out" "sudo zsh car-vpn.sh car" "car sudo hint"
out=$(CWM_SECRETS=$T zsh $PUB/car-vpn.sh off 2>&1); rc=$?
assert_eq $rc 1 "off without sudo"; assert_contains "$out" "sudo" "off sudo hint"

# --- key mode (unreachable dummy key)
echo "ss://$(printf 'aes-128-gcm:x' | base64)@127.0.0.1:9" > $T/china-key.txt
assert_eq "$(fn detect_mode)" key "detect_mode with key"
# missing sing-box → brew hint, exit 1
out=$(CWM_SINGBOX=/nonexistent CWM_SECRETS=$T zsh $PUB/car-vpn.sh test 2>&1); rc=$?
assert_eq $rc 1 "missing sing-box exit"; assert_contains "$out" "brew install sing-box" "brew hint"
# stale pidfile is cleaned, sing-box starts, test runs, sing-box stops
echo 2147483647 > $T/car-vpn.pid
out=$(CWM_SECRETS=$T zsh $PUB/car-vpn.sh test 2>&1)
assert_contains "$out" "IP через ключ:" "test prints IP line"
assert_contains "$out" "vtspivi 8.136.147.132:1663 через ключ: НЕТ" "test prints port probe"
assert_eq "$(pgrep -f "sing-box run -c $T/car-vpn.json" | wc -l | tr -d ' ')" 0 "sing-box left running"
[[ ! -f $T/car-vpn.pid ]] || fail "pidfile left behind"
# live pid refuses
sleep 300 & SP=$!; echo $SP > $T/car-vpn.pid
out=$(CWM_SECRETS=$T zsh $PUB/car-vpn.sh test 2>&1); rc=$?
assert_eq $rc 1 "live pid exit"; assert_contains "$out" "уже запущен" "live pid message"
kill $SP; rm $T/car-vpn.pid
rm $T/china-key.txt

# --- bridge_net derives network/prefix from bridge100's inet line (ifconfig shadowed)
net=$( export CWM_SECRETS=$T CWM_SOURCED=1; source $PUB/car-vpn.sh
       ifconfig() { print "\tinet 192.168.2.1 netmask 0xffffff00 broadcast 192.168.2.255" }; bridge_net )
assert_eq "$net" "192.168.2.0/24" "bridge_net /24"
net=$( export CWM_SECRETS=$T CWM_SOURCED=1; source $PUB/car-vpn.sh
       ifconfig() { print "\tinet 10.20.30.65 netmask 0xffffffc0 broadcast 10.20.30.127" }; bridge_net )
assert_eq "$net" "10.20.30.64/26" "bridge_net /26"
net=$( export CWM_SECRETS=$T CWM_SOURCED=1; source $PUB/car-vpn.sh; ifconfig() { return 1 }; bridge_net ); rc=$?
assert_eq $rc 1 "bridge_net without bridge100"

# --- watch_log_line mapping
assert_contains "$(fn watch_log_line '+0200 2026-10-26 20:22:10 INFO [1 0ms] inbound/redirect[car]: inbound connection to 8.136.127.53:1663')" "→ 8.136.127.53:1663" "redirect line"
assert_contains "$(fn watch_log_line '+0200 2026-10-26 20:23:04 ERROR network: missing default interface')" "переподключите Monkey" "tunnel drop line"
assert_eq "$(fn watch_log_line '+0200 2026-10-26 20:22:10 INFO outbound/direct[proxy]: outbound connection to x')" "" "noise line"
echo ALL-OK

#!/bin/zsh
# Behaviour tests for car-vpn.sh that need no root and no network beyond localhost.
#   zsh tests/test_car_vpn.sh
PUB=${0:A:h:h}
T=$(mktemp -d)
HELPERS=()
trap 'kill $HELPERS 2>/dev/null; rm -rf $T' EXIT

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
# a live PID that is NOT our sing-box (reused after a reboot) is stale → cleaned, test proceeds
# (helpers are detached from stdout, or a pipe reader waits for them)
sleep 300 >/dev/null 2>&1 & SP=$!; HELPERS+=($SP); echo $SP > $T/car-vpn.pid
out=$(CWM_SECRETS=$T zsh $PUB/car-vpn.sh test 2>&1); rc=$?
assert_eq $rc 0 "stale foreign pid: test proceeds"; assert_contains "$out" "IP через ключ:" "stale foreign pid: test ran"
kill -0 $SP 2>/dev/null || fail "foreign process was killed"
kill $SP 2>/dev/null; [[ ! -f $T/car-vpn.pid ]] || fail "pidfile left after stale foreign pid"
# a real live sing-box on our config refuses
SB=$(fn find_singbox); fn ensure_config
$SB run -c $T/car-vpn.json >/dev/null 2>&1 & SBP=$!; HELPERS+=($SBP); echo $SBP > $T/car-vpn.pid; sleep 0.5
out=$(CWM_SECRETS=$T zsh $PUB/car-vpn.sh test 2>&1); rc=$?
assert_eq $rc 1 "live sing-box refuses"; assert_contains "$out" "уже запущен" "live sing-box message"
kill $SBP; rm -f $T/car-vpn.pid; sleep 0.3
# port 2080 owned by another program → start fails, no false success, no rule would be loaded
nc -l 127.0.0.1 2080 >/dev/null 2>&1 & NCP=$!; HELPERS+=($NCP); sleep 0.3
out=$(CWM_SECRETS=$T zsh $PUB/car-vpn.sh test 2>&1); rc=$?
assert_eq $rc 1 "port collision exit"; assert_contains "$out" "sing-box не запустился" "port collision message"
kill $NCP 2>/dev/null; sleep 0.2
[[ ! -f $T/car-vpn.pid ]] || fail "pidfile left after port collision"
# test is interruptible: TERM mid-run stops sing-box and removes the pidfile (key → blackhole, curl would wait 15 s)
echo "ss://$(printf 'aes-128-gcm:x' | base64)@10.255.255.1:9" > $T/china-key.txt
CWM_SECRETS=$T zsh $PUB/car-vpn.sh test >/dev/null 2>&1 & TP=$!; HELPERS+=($TP)
sleep 2; kill -TERM $TP; sleep 1.5
kill -0 $TP 2>/dev/null && fail "test did not exit on TERM"
assert_eq "$(pgrep -f "sing-box run -c $T/car-vpn.json" | wc -l | tr -d ' ')" 0 "sing-box left after TERM"
[[ ! -f $T/car-vpn.pid ]] || fail "pidfile left after TERM"
rm $T/china-key.txt
# HUP triggers cleanup too (arm_cleanup + interruptible pause)
( export CWM_SECRETS=$T CWM_SOURCED=1; source $PUB/car-vpn.sh; arm_cleanup "touch $T/cleaned-hup"; pause 30 ) >/dev/null 2>&1 & HP=$!; HELPERS+=($HP)
sleep 0.5; kill -HUP $HP; sleep 0.5
[[ -f $T/cleaned-hup ]] || fail "arm_cleanup: no cleanup on HUP"
kill -0 $HP 2>/dev/null && fail "arm_cleanup: process still alive after HUP"
# EXIT trap armed inside a function fires at shell exit, not at function return (posix_traps)
early=$( export CWM_SECRETS=$T CWM_SOURCED=1; source $PUB/car-vpn.sh; arm_cleanup "touch $T/exit-mark"; [[ -f $T/exit-mark ]] && echo EARLY )
assert_eq "$early" "" "EXIT trap fired at function return"
[[ -f $T/exit-mark ]] || fail "EXIT trap did not fire at shell exit"
# log watcher: stop_all kills the tail
: > $T/car-vpn.log
( export CWM_SECRETS=$T CWM_SOURCED=1; source $PUB/car-vpn.sh; start_log_watch; sleep 0.5; stop_all >/dev/null )
sleep 0.3; assert_eq "$(pgrep -f "tail -n 0 -f $T/car-vpn.log" | wc -l | tr -d ' ')" 0 "tail left after stop_all"
# Monkey mode: exit_still_ok fails when the default route is not a utun
( export CWM_SECRETS=$T CWM_SOURCED=1; source $PUB/car-vpn.sh; route() { print "   interface: en0" }; exit_still_ok ) && fail "exit_still_ok passed with en0"
( export CWM_SECRETS=$T CWM_SOURCED=1; source $PUB/car-vpn.sh; route() { print "   interface: utun8" }; exit_still_ok ) || fail "exit_still_ok failed with utun8"

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
# --- check: structure holds in whatever state the Mac is in right now
out=$(CWM_SECRETS=$T zsh $PUB/car-vpn.sh check 2>&1); rc=$?
assert_contains "$(echo "$out" | head -1)" "режим: Monkey" "check first line"
assert_contains "$out" "=== Проверка цепочки" "check header"
# every ❌/⚠️ line is followed by a → line
echo "$out" | awk '/❌|⚠️/{need=1; next} need && !/→/{bad=1} {need=0} END{exit bad}' || fail "a ❌/⚠️ line has no → fix line:
$out"
# last line and exit code agree
last=$(echo "$out" | tail -1); n=$(echo "$out" | grep -c '^  ❌')
if (( n == 0 )); then
  assert_eq "$last" "=== Всё готово." "check last line (clean)"; assert_eq $rc 0 "check exit (clean)"
else
  assert_contains "$last" "Проблем: $n" "check last line (problems)"; assert_eq $rc 1 "check exit (problems)"
fi
# sing-box probe
out=$(CWM_SINGBOX=/nonexistent CWM_SECRETS=$T zsh $PUB/car-vpn.sh check 2>&1)
assert_contains "$out" "❌ нет sing-box" "sing-box probe"; assert_contains "$out" "brew install sing-box" "sing-box fix"
# key mode line
touch $T/china-key.txt
assert_contains "$(CWM_SECRETS=$T zsh $PUB/car-vpn.sh check | head -1)" "режим: ключ" "check first line (key)"
rm $T/china-key.txt
echo ALL-OK

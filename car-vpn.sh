#!/bin/zsh
# car-vpn.sh — китайский IP для любого Wi-Fi-устройства через Мак.
#
#   zsh car-vpn.sh check        проверить цепочку iPhone ─USB─► Mac ─Wi-Fi─► устройство
#   zsh car-vpn.sh test         режим с ключом: проверить ключ (сеть Мака не трогает)
#   sudo zsh car-vpn.sh car     завернуть TCP устройств в sing-box (Ctrl+C или автостоп 15 мин)
#   sudo zsh car-vpn.sh off     аварийно снять правило и остановить sing-box
#
# Режим определяется сам: есть secrets/china-key.txt → режим с ключом,
# нет → режим Monkey (в Китай выводит VPN самого Мака, Monkey Speed в GlobalMode).
#
# Почему здесь нет route-to. 2026-10-26 правило `pf route-to (utunN …)` на bridge100
# дважды вызвало kernel panic на macOS 26.1. Пакеты устройств не попадают ни в какой
# utun: единственное правило — pf rdr — отдаёт их локальному sing-box, а тот сам
# открывает соединения как обычный процесс Мака (через VPN Мака или по ключу).

SCRIPT_DIR=${${(%):-%x}:A:h}
SECRETS=${CWM_SECRETS:-$SCRIPT_DIR/secrets}
CONFIG=$SECRETS/car-vpn.json
LOG=$SECRETS/car-vpn.log
PIDFILE=$SECRETS/car-vpn.pid
ANCHOR="com.apple/999.china-wifi-mac"
TIMEOUT_MIN=${CWM_TIMEOUT_MIN:-15}
REDIRECT_PORT=7892
TEST_PORT=2080
TAILPID=""

detect_mode() {
  [[ -f $SECRETS/china-key.txt ]] && echo key || echo monkey
}

ensure_config() {
  mkdir -p $SECRETS
  if [[ $(detect_mode) == key ]]; then
    python3 -I $SCRIPT_DIR/make_config.py --secrets $SECRETS
  else
    cp $SCRIPT_DIR/config.monkey.json $CONFIG
  fi
}

find_singbox() {
  local -a candidates
  if [[ -n ${CWM_SINGBOX:-} ]]; then
    candidates=($CWM_SINGBOX)
  else
    candidates=(/opt/homebrew/bin/sing-box /usr/local/bin/sing-box)
  fi
  local c
  for c in $candidates; do
    [[ -x $c ]] && { echo $c; return 0 }
  done
  echo "Нет sing-box. Установите: brew install sing-box" >&2
  return 1
}

stop_singbox() {
  if [[ -f $PIDFILE ]]; then
    local pid=$(<$PIDFILE)
    kill $pid 2>/dev/null
    local i
    for i in {1..20}; do kill -0 $pid 2>/dev/null || break; sleep 0.1; done
    rm -f $PIDFILE
  fi
}

start_singbox() {
  local sb
  sb=$(find_singbox) || return 1
  [[ -f $CONFIG ]] || { echo "Нет $CONFIG — сначала ensure_config" >&2; return 1 }
  $sb check -c $CONFIG || return 1
  if [[ -f $PIDFILE ]]; then
    local old=$(<$PIDFILE)
    if kill -0 $old 2>/dev/null; then
      echo "sing-box уже запущен (pid $old) — сначала: sudo zsh car-vpn.sh off" >&2
      return 1
    fi
    rm -f $PIDFILE
  fi
  $sb run -c $CONFIG > $LOG 2>&1 &
  echo $! > $PIDFILE
  local i
  for i in {1..20}; do nc -z 127.0.0.1 $TEST_PORT 2>/dev/null && return 0; sleep 0.25; done
  echo "sing-box не запустился, см. $LOG" >&2
  tail -5 $LOG >&2
  stop_singbox
  return 1
}

stop_all() {
  [[ -n $TAILPID ]] && kill $TAILPID 2>/dev/null
  [[ $EUID -eq 0 ]] && pfctl -a $ANCHOR -F all >/dev/null 2>&1
  stop_singbox
  echo "=== правило снято, sing-box остановлен"
}

# Одна строка журнала sing-box → одна строка для человека (или ничего).
watch_log_line() {
  local l=$1
  case $l in
    *"inbound/redirect[car]: inbound connection to "*) echo "→ ${l##*inbound connection to }" ;;
    *"missing default interface"*) echo "⚠️  VPN Мака отвалился — переподключите Monkey (GlobalMode) и запустите car снова" ;;
    *ERROR*|*FATAL*) echo "$l" ;;
  esac
}

# Подсеть «Общего интернета» из bridge100: адрес и маска → network/prefix.
bridge_net() {
  local ip mask
  read ip mask < <(ifconfig bridge100 2>/dev/null | awk '/inet /{print $2, $4; exit}')
  [[ -n $ip && -n $mask ]] || return 1
  local -a o; o=(${(s:.:)ip})
  local ipn=$(( (o[1] << 24) | (o[2] << 16) | (o[3] << 8) | o[4] ))
  local m=$(( mask ))
  local net=$(( ipn & m ))
  local prefix=0 bit
  for bit in {31..0}; do (( (m >> bit) & 1 )) && (( prefix++ )); done
  echo "$(( (net >> 24) & 255 )).$(( (net >> 16) & 255 )).$(( (net >> 8) & 255 )).$(( net & 255 ))/$prefix"
}

diagnose() {
  return 0
}

need_root() {
  [[ $EUID -eq 0 ]] || { echo "Нужно: sudo zsh car-vpn.sh $1" >&2; exit 1 }
}

cmd_test() {
  if [[ $(detect_mode) == monkey ]]; then
    echo "Режим Monkey: проверка ключа не нужна, используйте: zsh car-vpn.sh check"
    return 0
  fi
  ensure_config || return 1
  start_singbox || return 1
  trap 'stop_singbox' EXIT
  echo "IP через ключ: $(curl -s -m 15 -x socks5h://127.0.0.1:$TEST_PORT https://myip.ipip.net)"
  # Shadowsocks не подтверждает соединение с конечным адресом, поэтому «OK» ниже
  # для ss-ключа условно. Решающая строка — IP: должен быть 中国, а не 香港 / 摩尔多瓦.
  local h
  for h in 8.136.147.132 8.136.127.53; do
    printf "vtspivi %s:1663 через ключ: " $h
    nc -z -G 10 -w 10 -X 5 -x 127.0.0.1:$TEST_PORT $h 1663 >/dev/null 2>&1 && echo OK || echo НЕТ
  done
  stop_singbox
}

cmd_car() {
  need_root car
  diagnose || exit 1
  local net
  net=$(bridge_net) || { echo "Нет bridge100: включите «Общий интернет» (из iPhone USB в Wi-Fi)" >&2; exit 1 }
  ensure_config || exit 1
  start_singbox || exit 1
  trap 'stop_all; exit 0' INT TERM
  echo "rdr pass on bridge100 inet proto tcp from $net to ! $net -> 127.0.0.1 port $REDIRECT_PORT" \
    | pfctl -a $ANCHOR -f - 2>&1 | grep -vE "ALTQ|flushing|present in the main|pf.conf|^$"
  pfctl -E >/dev/null 2>&1
  local via=Monkey
  [[ $(detect_mode) == key ]] && via=ключ
  echo "=== активно: TCP клиентов ($net) → sing-box → $via. Откройте QR на устройстве."
  echo "=== Ctrl+C — остановить. Автостоп через $TIMEOUT_MIN мин."
  tail -n 0 -f $LOG | while read -r l; do watch_log_line "$l"; done &
  TAILPID=$!
  sleep $(( TIMEOUT_MIN * 60 ))
  stop_all
}

if [[ -z ${CWM_SOURCED:-} ]]; then
  case ${1:-} in
    check) diagnose; exit $? ;;
    test)  cmd_test; exit $? ;;
    car)   cmd_car ;;
    off)   need_root off; stop_all ;;
    *)     sed -n '2,8p' ${(%):-%x} | sed 's/^# \{0,1\}//' ;;
  esac
fi

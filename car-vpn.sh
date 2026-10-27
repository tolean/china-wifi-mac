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

# Без этого zsh выполняет EXIT-trap, поставленный внутри функции, при выходе из функции,
# а не из скрипта — и очистка в arm_cleanup срабатывала бы не тогда.
setopt posix_traps

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
WAITPID=""

detect_mode() {
  [[ -f $SECRETS/china-key.txt ]] && echo key || echo monkey
}

chown_secrets() {  # после sudo папка secrets/ не должна остаться root-овской (иначе ключ потом не положить)
  [[ $EUID -eq 0 && -n ${SUDO_USER:-} ]] && chown -R "$SUDO_USER" $SECRETS 2>/dev/null
  return 0
}

ensure_config() {
  mkdir -p $SECRETS
  if [[ $(detect_mode) == key ]]; then
    python3 -I $SCRIPT_DIR/make_config.py --secrets $SECRETS || return 1
  else
    cp $SCRIPT_DIR/config.monkey.json $CONFIG || return 1
  fi
  chown_secrets
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

singbox_pid_is_ours() {  # pid из pid-файла после перезагрузки может достаться чужому процессу
  [[ -n $1 ]] && ps -p $1 -o command= 2>/dev/null | grep -q -- "sing-box run -c $CONFIG"
}

stop_singbox() {
  [[ -f $PIDFILE ]] || return 0
  local pid=$(<$PIDFILE)
  if singbox_pid_is_ours $pid; then
    kill $pid 2>/dev/null
    local i
    for i in {1..20}; do kill -0 $pid 2>/dev/null || break; sleep 0.1; done
  fi
  rm -f $PIDFILE
}

start_singbox() {
  local sb
  sb=$(find_singbox) || return 1
  [[ -f $CONFIG ]] || { echo "Нет $CONFIG — сначала ensure_config" >&2; return 1 }
  $sb check -c $CONFIG || return 1
  if [[ -f $PIDFILE ]]; then
    local old=$(<$PIDFILE)
    if singbox_pid_is_ours $old; then
      echo "sing-box уже запущен (pid $old) — сначала: sudo zsh car-vpn.sh off" >&2
      return 1
    fi
    rm -f $PIDFILE  # устаревший pid-файл: процесса нет или это не наш sing-box
  fi
  $sb run -c $CONFIG > $LOG 2>&1 &
  local pid=$!
  echo $pid > $PIDFILE
  local i
  for i in {1..20}; do
    kill -0 $pid 2>/dev/null || break
    # порт 2080 должен слушать именно наш процесс, а не чужой Clash / sing-box
    lsof -nP -iTCP:$TEST_PORT -sTCP:LISTEN -t 2>/dev/null | grep -qx $pid && return 0
    sleep 0.25
  done
  echo "sing-box не запустился, см. $LOG" >&2
  tail -5 $LOG >&2
  stop_singbox
  return 1
}

stop_all() {
  [[ -n ${CLEANED:-} ]] && return 0
  CLEANED=1
  [[ -n $WAITPID ]] && kill $WAITPID 2>/dev/null
  [[ -n $TAILPID ]] && kill $TAILPID 2>/dev/null
  pkill -f "tail -n 0 -f $LOG" 2>/dev/null
  [[ $EUID -eq 0 ]] && pfctl -a $ANCHOR -F all >/dev/null 2>&1
  stop_singbox
  chown_secrets
  echo "=== правило снято, sing-box остановлен"
}

# Очистка на Ctrl+C, kill, закрытие окна Терминала (HUP) и на обычном выходе.
arm_cleanup() {
  local fn=$1
  # kill \$WAITPID: пока `wait` внутри функции ждёт ребёнка, `exit` из trap не срабатывает;
  # снимаем ожидание — и выход происходит сразу.
  trap "$fn; kill \$WAITPID 2>/dev/null; exit 130" INT
  trap "$fn; kill \$WAITPID 2>/dev/null; exit 143" TERM HUP
  trap "$fn" EXIT
}

# sleep, который сигнал прерывает сразу: foreground-команду zsh дожидается и только потом
# выполняет trap, а `wait` фоновой команды прерывается немедленно.
pause() {
  sleep $1 & WAITPID=$!
  wait $WAITPID
  WAITPID=""
}

start_log_watch() {
  : >> $LOG
  tail -n 0 -f $LOG > >(while read -r l; do watch_log_line "$l"; done) &
  TAILPID=$!   # именно tail, а не subshell-читатель
}

exit_still_ok() {  # в режиме Monkey маршрут по умолчанию обязан идти через utun
  [[ $(detect_mode) == key ]] && return 0
  [[ $(route -n get default 2>/dev/null | awk '/interface:/{print $2}') == utun* ]]
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

ok()   { echo "  ✅ $1" }
warn() { echo "  ⚠️  $1"; shift; local l; for l in "$@"; do echo "       → $l"; done }
bad()  { echo "  ❌ $1"; shift; local l; for l in "$@"; do echo "       → $l"; done; FAIL=$(( FAIL + 1 )) }

hw_device() {  # hw_device "Wi-Fi" → en0
  networksetup -listallhardwareports 2>/dev/null | awk -v p="Hardware Port: $1" '$0==p{getline; print $2; exit}'
}

# Проверяет всю цепочку и печатает, что не так и как исправить. Возвращает число ❌.
diagnose() {
  FAIL=0
  local mode=$(detect_mode)
  if [[ $mode == key ]]; then echo "режим: ключ (secrets/china-key.txt)"
  else echo "режим: Monkey (нет secrets/china-key.txt)"; fi
  echo "=== Проверка цепочки iPhone ─USB─► Mac ─Wi-Fi─► устройство"
  local settings="Настройки → Основные → Общий доступ → Общий интернет (i) → Share from: iPhone USB, To: Wi-Fi"

  # 1. Интернет на Мак по кабелю от iPhone
  local usb_if=$(hw_device "iPhone USB") usb_ip=""
  [[ -n $usb_if ]] && usb_ip=$(ifconfig $usb_if 2>/dev/null | awk '/inet /{print $2; exit}')
  if [[ -z $usb_if ]]; then
    bad "iPhone USB: Мак не видит iPhone как сетевое устройство" \
        "подключите iPhone кабелем, на iPhone нажмите «Доверять»"
  elif [[ -z $usb_ip ]]; then
    bad "iPhone USB ($usb_if): кабель есть, но интернета нет" \
        "iPhone: Настройки → Режим модема → «Разрешать другим» — включить" \
        "если включено — выньте и снова вставьте кабель"
  else
    ok "iPhone USB ($usb_if): $usb_ip"
  fi

  local br_ip=$(ifconfig bridge100 2>/dev/null | awk '/inet /{print $2; exit}')

  # 2. Wi-Fi Мака свободен для раздачи (или уже раздаёт)
  local wifi_if=$(hw_device "Wi-Fi")
  local wifi_power=$(networksetup -getairportpower $wifi_if 2>/dev/null | awk '{print $NF}')
  local wifi_ip=$(ifconfig $wifi_if 2>/dev/null | awk '/inet /{print $2; exit}')
  if [[ $wifi_power != On ]]; then
    bad "Wi-Fi ($wifi_if) выключен" "включите Wi-Fi (но ни к какой сети не подключайтесь)"
  elif [[ -n $wifi_ip && -z $br_ip ]]; then
    bad "Wi-Fi ($wifi_if) подключён к сети как клиент (IP $wifi_ip) — раздавать не может" \
        "строка меню → Wi-Fi → нажмите на подключённую сеть, чтобы отключиться" \
        "Настройки → Wi-Fi → (…) у этой сети → выключить «Автоподключение»"
  elif [[ -n $wifi_ip ]]; then
    ok "Wi-Fi ($wifi_if) раздаёт"
  else
    ok "Wi-Fi ($wifi_if) свободен"
  fi

  # 3. «Общий интернет»: источник, bridge100, подключённые устройства
  local natdump=$(defaults read /Library/Preferences/SystemConfiguration/com.apple.nat NAT 2>/dev/null)
  local src=$(echo "$natdump" | awk '/PrimaryInterface/,/}/' \
              | sed -n 's/.*PrimaryUserReadable = "\{0,1\}\([^";]*\)"\{0,1\};.*/\1/p' | head -1)
  local netname=$(echo "$natdump" | sed -n 's/.*NetworkName = "\{0,1\}\([^";]*\)"\{0,1\};.*/\1/p' | head -1)
  if [[ -z $src ]]; then
    warn "не смог определить источник «Общего интернета»" "$settings"
  elif [[ $src != "iPhone USB" ]]; then
    bad "«Общий интернет» берёт интернет из «$src», а нужно из «iPhone USB»" "$settings"
  fi
  if [[ -z $br_ip ]]; then
    bad "«Общий интернет» не работает (нет bridge100)" \
        "сначала исправьте пункты выше, затем выключите и снова включите «Общий интернет»"
  else
    ok "«Общий интернет» раздаёт Wi-Fi «$netname», шлюз $br_ip"
    local -a clients
    clients=($(arp -an -i bridge100 2>/dev/null | awk -v gw="($br_ip)" \
      '$2!=gw && $2!~/\.255\)$/ && $2!~/^\(2(2[4-9]|3[0-9])\./ && $4!="(incomplete)" {gsub(/[()]/,"",$2); print $2}'))
    if (( ${#clients} )); then
      ok "подключено устройств: ${#clients} (${(j:, :)clients})"
    else
      warn "к Wi-Fi Мака пока никто не подключён" "на устройстве: Настройки → Wi-Fi → выберите сеть Мака"
    fi
  fi

  # 4. sing-box
  local sb
  if sb=$(find_singbox 2>/dev/null); then ok "sing-box: $sb"
  else bad "нет sing-box" "brew install sing-box"; fi

  # 5. Выход в Китай
  local def=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
  local monkey=$(scutil --nc list 2>/dev/null | awk '/top.monkey.speed/{gsub(/[()]/,"",$2); print $2; exit}')
  if [[ $mode == monkey ]]; then
    if [[ $def != utun* ]]; then
      bad "режим Monkey, но VPN Мака не ведёт трафик (Monkey: ${monkey:-не найден}, маршрут: ${def:-нет})" \
          "Monkey Speed на Маке: GlobalMode → сервер Пекин → подключить"
    else
      local ip=$(curl -s -m 8 https://myip.ipip.net 2>/dev/null)
      if [[ $ip == *中国* && $ip != *香港* ]]; then
        ok "Мак выходит через Китай: $ip"
      elif [[ $ip == *香港* ]]; then
        warn "Мак выходит через Гонконг: $ip" "в Monkey выберите сервер Пекин (北京) — Гонконг может не подойти"
      else
        bad "Monkey подключён, но Мак выходит не через Китай: ${ip:-нет ответа}" \
            "в Monkey включите GlobalMode (全局), а не умный режим" "переподключите Monkey"
      fi
    fi
  else
    if [[ $def == utun* ]]; then
      bad "режим с ключом, но на Маке включён VPN ($def)" "выключите Monkey/другой VPN на Маке"
    else
      ok "режим с ключом, VPN на Маке выключен"
    fi
  fi

  if (( FAIL )); then echo "=== Проблем: $FAIL. Исправьте пункты с ❌ и запустите снова."
  else echo "=== Всё готово."; fi
  return $FAIL
}

need_root() {
  [[ $EUID -eq 0 ]] || { echo "Нужно: sudo zsh car-vpn.sh $1" >&2; exit 1 }
}

test_cleanup() {
  [[ -n ${CLEANED:-} ]] && return 0
  CLEANED=1
  [[ -n $WAITPID ]] && kill $WAITPID 2>/dev/null
  stop_singbox
}

cmd_test() {
  if [[ $(detect_mode) == monkey ]]; then
    echo "Режим Monkey: проверка ключа не нужна, используйте: zsh car-vpn.sh check"
    return 0
  fi
  ensure_config || return 1
  start_singbox || return 1
  arm_cleanup test_cleanup
  local ipfile=$SECRETS/.ip
  curl -s -m 15 -x socks5h://127.0.0.1:$TEST_PORT https://myip.ipip.net > $ipfile 2>/dev/null & WAITPID=$!
  wait $WAITPID; WAITPID=""
  echo "IP через ключ: $(<$ipfile)"
  rm -f $ipfile
  # Shadowsocks не подтверждает соединение с конечным адресом, поэтому «OK» ниже
  # для ss-ключа условно. Решающая строка — IP: должен быть 中国, а не 香港 / 摩尔多瓦.
  local h
  for h in 8.136.147.132 8.136.127.53; do
    printf "vtspivi %s:1663 через ключ: " $h
    nc -z -G 10 -w 10 -X 5 -x 127.0.0.1:$TEST_PORT $h 1663 >/dev/null 2>&1 & WAITPID=$!
    wait $WAITPID && echo OK || echo НЕТ
    WAITPID=""
  done
  test_cleanup
}

cmd_car() {
  need_root car
  diagnose || exit 1
  local net
  net=$(bridge_net) || { echo "Нет bridge100: включите «Общий интернет» (из iPhone USB в Wi-Fi)" >&2; exit 1 }
  ensure_config || exit 1
  start_singbox || exit 1
  arm_cleanup stop_all
  echo "rdr pass on bridge100 inet proto tcp from $net to ! $net -> 127.0.0.1 port $REDIRECT_PORT" \
    | pfctl -a $ANCHOR -f - 2>&1 | grep -vE "ALTQ|flushing|present in the main|pf.conf|^$"
  if (( pipestatus[2] != 0 )); then
    echo "Не смог загрузить правило pf — см. сообщение выше" >&2
    exit 1  # EXIT-trap снимет всё, что успели поставить
  fi
  pfctl -E >/dev/null 2>&1
  local via=Monkey
  [[ $(detect_mode) == key ]] && via=ключ
  echo "=== активно: TCP клиентов ($net) → sing-box → $via. Откройте QR на устройстве."
  echo "=== Ctrl+C — остановить. Автостоп через $TIMEOUT_MIN мин."
  start_log_watch
  local end=$(( SECONDS + TIMEOUT_MIN * 60 ))
  while (( SECONDS < end )); do
    pause 10
    exit_still_ok || echo "⚠️  VPN Мака не ведёт трафик через utun — устройство сейчас выходит НЕ через Китай. Переподключите Monkey (GlobalMode)."
  done
  stop_all
}

if [[ -z ${CWM_SOURCED:-} ]]; then
  case ${1:-} in
    check) diagnose && exit 0 || exit 1 ;;
    test)  cmd_test; exit $? ;;
    car)   cmd_car ;;
    off)   need_root off; stop_all ;;
    *)     sed -n '2,8p' ${(%):-%x} | sed 's/^# \{0,1\}//' ;;
  esac
fi

#!/usr/bin/env bash
# Запуск ZDC Systems из готовых бинарников: reports-сервер (он же раздаёт
# дашборд) и воркер. Сборка (cargo/npm) не нужна.
#
# Использование:
#   ./scripts/start.sh                    # запустить всё (сначала setup.sh)
#   ./scripts/start.sh license <файл>     # подключить/заменить файл лицензии
#   ./scripts/start.sh status             # состояние и срок лицензии
#   ./scripts/start.sh stop               # остановить всё
#   ./scripts/start.sh restart            # перезапустить
#
# Значения — из scripts/zdc.env (создаёт setup.sh), ключи входа — из файла
# лицензии .zdc-data/license.lic: ZDC_LICENSE_WORKER уходит воркеру (и серверу —
# для воркеров, запускаемых из дашборда), ZDC_LICENSE_USER — вход в дашборд.
# Без файла лицензии не запускается — других способов входа нет.
# Логи — в .zdc-data/logs/, pid-файлы — в .zdc-data/run/.

set -euo pipefail
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

load_env() {
  [ -f "$ENV_FILE" ] || die "нет $ENV_FILE — сначала запусти ./deploy_scripts/setup.sh"
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  mkdir -p "$RUN_DIR" "$LOG_DIR"
}

pidfile() { echo "$RUN_DIR/$1.pid"; }

# По чему узнать процесс компонента в /proc/<pid>/cmdline.
cmd_pattern() {
  case "$1" in
    server) echo analitics_service ;;
    worker) echo report_worker ;;
    *) echo "$1" ;;
  esac
}

# Компонент работает: pid из файла жив И это именно наш процесс. Без сверки
# командной строки устаревший pid-файл (перезагрузка, kill -9) указывал бы на
# чужой процесс, получивший тот же pid, — stop убил бы его, start решил бы,
# что компонент уже запущен.
is_up() {
  local pf pid
  pf="$(pidfile "$1")"
  [ -f "$pf" ] || return 1
  pid="$(cat "$pf")"
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  if [ -r "/proc/$pid/cmdline" ]; then
    tr '\0' ' ' <"/proc/$pid/cmdline" | grep -q -- "$(cmd_pattern "$1")" || return 1
  fi
}

# Запустить компонент в фоне: start_svc <имя> <рабочий каталог> <команда...>
start_svc() {
  local name="$1" dir="$2"
  shift 2
  if is_up "$name"; then
    info "$name уже запущен (pid $(cat "$(pidfile "$name")"))"
    return 0
  fi
  rm -f "$(pidfile "$name")"
  info "запускаю $name"
  ( cd "$dir" && exec "$@" ) >"$LOG_DIR/$name.log" 2>&1 &
  echo "$!" >"$(pidfile "$name")"
}

# Сколько ждать штатного завершения процесса перед SIGKILL (сек). Воркер по
# SIGTERM сносит песочницу, сервер дорабатывает незакрытые long-poll — им нужно
# время. Ждём, иначе restart запустит новый сервер, пока старый держит порт.
TERM_WAIT=30

stop_svc() {
  local name="$1" pf pid i
  pf="$(pidfile "$name")"
  if is_up "$name"; then
    pid="$(cat "$pf")"
    info "останавливаю $name (pid $pid)"
    kill "$pid" 2>/dev/null || true
    for i in $(seq 1 "$TERM_WAIT"); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
      warn "$name не завершился за ${TERM_WAIT} с — SIGKILL"
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  rm -f "$pf"
}

# Способ входа → окружение сервера и воркера; LOGIN_HINT — что вводить в дашборде.
#  1. Подключена лицензия — её ключи (ZDC_LICENSE_WORKER → ZDC_WORKER_KEY),
#     вход в дашборд по ZDC_LICENSE_USER.
#  2. Без лицензии — демо-режим: вход кнопкой «Демо-режим»; воркеру нужен лишь
#     локальный ключ ZDC_WORKER_KEY (из zdc.env или сгенерированный в $KEYS_FILE).
#     Сборка остаётся лицензионной (встроенный ключ издателя) — сервер стартует.
load_auth() {
  if license_present; then
    local out
    out="$(check_license_file "$LICENSE_FILE" 2>&1)" ||
      die "лицензия недействительна: $(echo "$out" | grep -m1 'НЕ действительна' || echo "$out")"
    # Ключ воркера из лицензии; ключ входа сервер берёт из самой лицензии.
    export ZDC_WORKER_KEY="$(license_key WORKER)"
    LOGIN_HINT="ключ ZDC_LICENSE_USER из $LICENSE_FILE"
    return 0
  fi
  if [ -n "${API_TOKEN:-}${WORKER_TOKEN:-}" ]; then
    die "API_TOKEN/WORKER_TOKEN больше не используются: пользователь входит по лицензии или в демо-режиме, ключ воркера — ZDC_WORKER_KEY"
  fi
  # Без лицензии: воркеру нужен локальный ключ (вход пользователя — демо-режим).
  if [ -z "${ZDC_WORKER_KEY:-}" ]; then
    ensure_worker_key
    ZDC_WORKER_KEY="$(worker_key_value)"
  fi
  export ZDC_WORKER_KEY
  warn "лицензия не подключена — дашборд работает в демо-режиме (если не выключен DEMO_MODE=0)"
  LOGIN_HINT="демо-режим (кнопка «Демо-режим»); полный доступ — ./scripts/start.sh license <файл .lic>"
}

do_start() {
  load_env
  check_binaries
  load_auth
  # Внешняя БД (DATABASE_URL на другой машине) — локальную службу не трогаем.
  if [ "${ZDC_EXTERNAL_DB:-0}" != 1 ]; then
    detect_distro >/dev/null
    ensure_postgres_running
  fi

  # Сервер (применяет встроенные миграции при старте) раздаёт и дашборд, и
  # запускает воркеров из дашборда («Нейросеть» → «Запуск воркеров»).
  export DASHBOARD_DIR="$DASHBOARD_DIST"
  export DASHBOARD_BIND="${DASHBOARD_BIND:-127.0.0.1:${DASHBOARD_PORT:-5173}}"
  export WORKER_BIN="${WORKER_BIN:-$BIN_DIR/report_worker}"
  export WORKER_LOG_DIR="${WORKER_LOG_DIR:-$LOG_DIR/workers}"
  start_svc server "$DATA_DIR" "$BIN_DIR/analitics_service"

  # Дождаться готовности сервера, чтобы воркер и дашборд сразу его видели.
  local i
  for i in $(seq 1 30); do
    curl -fsS "http://${BIND_ADDR:-127.0.0.1:8080}/health" >/dev/null 2>&1 && break
    sleep 1
  done

  # Воркер (pentest берётся только при scope: ZDC_SCOPE_* или цели в дашборде).
  curl -fsS "http://${BIND_ADDR:-127.0.0.1:8080}/health" >/dev/null 2>&1 ||
    die "сервер не ответил за 30 с — см. $LOG_DIR/server.log"
  start_svc worker "$DATA_DIR" "$BIN_DIR/report_worker"

  info "== Запущено =="
  info "Дашборд: http://$DASHBOARD_BIND  (вход — $LOGIN_HINT)"
  info "Логи:    $LOG_DIR/{server,worker}.log"
  info "Статус:  ./scripts/start.sh status    Остановить: ./scripts/start.sh stop"
}

do_stop() {
  # ENV_FILE для путей; если его нет — всё равно пытаемся по pid-файлам.
  [ -f "$ENV_FILE" ] && { . "$ENV_FILE" || true; }
  stop_svc worker
  stop_svc server
  info "остановлено"
}

do_status() {
  local name pf
  for name in server worker; do
    pf="$(pidfile "$name")"
    if is_up "$name"; then
      printf '  %-10s работает (pid %s)\n' "$name" "$(cat "$pf")"
    else
      printf '  %-10s остановлен\n' "$name"
    fi
  done
  if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    curl -fsS "http://${BIND_ADDR:-127.0.0.1:8080}/health" >/dev/null 2>&1 &&
      printf '  %-10s отвечает\n' "health" || printf '  %-10s не отвечает\n' "health"
  fi
  if [ -f "$LICENSE_FILE" ]; then
    check_license_file "$LICENSE_FILE" | sed 's/^/  /' || true
  else
    printf '  %-10s не подключена — дашборд в демо-режиме\n' "лицензия"
  fi
}

case "${1:-start}" in
start) do_start ;;
license)
  [ -n "${2:-}" ] || die "использование: ./scripts/start.sh license <файл .lic>"
  install_license "$2"
  if is_up server; then
    info "перезапустите систему, чтобы сервер и воркер получили новый ключ: ./scripts/start.sh restart"
  fi
  ;;
stop) do_stop ;;
restart)
  do_stop
  do_start
  ;;
status) do_status ;;
*) die "неизвестная команда: $1 (start|stop|restart|status|license <файл>)" ;;
esac

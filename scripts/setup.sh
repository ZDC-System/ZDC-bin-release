#!/usr/bin/env bash
# Подготовка машины к запуску ZDC Systems из готовых бинарников.
#
# Делает:
#   1. определяет дистрибутив (debian / rhel / alpine / arch);
#   2. ставит недостающие пакеты рантайма (libpq, PostgreSQL, git, curl);
#   3. проверяет бинарники из bin/ (на месте, запускаются, хватает библиотек);
#   4. поднимает PostgreSQL, создаёт роль и базу;
#   5. генерирует deploy_scripts/zdc.env — пароль БД, SECRETS_KEY и адреса.
#      Вход — по лицензионному ключу из файла лицензии издателя (--license /
#      start.sh license); без лицензии дашборд открыт в демо-режиме, а воркеру
#      start.sh сам сгенерирует локальный ключ;
#   6. по желанию подключает лицензию и ставит внешние анализаторы ревью.
#
# Запуск:  ./scripts/setup.sh [--license <файл .lic>]   (нужен sudo/root для пакетов)
# Затем:   ./scripts/start.sh
#
# Rust, Node и сборка не нужны. Необязательные инструменты (docker — пентест,
# gitleaks — поиск секретов, nuclei — активный скан) ставятся отдельно.

set -euo pipefail
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

DB_NAME="${ZDC_DB_NAME:-reports}"
DB_ROLE="${ZDC_DB_ROLE:-zdc}"

main() {
  local license=""
  while [ $# -gt 0 ]; do
    case "$1" in
    --license)
      license="${2:-}"
      [ -n "$license" ] || die "--license: укажите файл лицензии"
      shift 2
      ;;
    *) die "неизвестный аргумент: $1 (есть только --license <файл>)" ;;
    esac
  done

  info "== ZDC Systems: подготовка к запуску =="
  detect_distro

  # 1. Пакеты рантайма (ставятся только отсутствующие).
  info "-- зависимости --"
  install_deps libpq-run git curl cacerts pg-server pg-client
  install_optional docker

  # 2. Бинарники.
  info "-- бинарники ($BIN_DIR) --"
  check_binaries
  info "бинарники и дашборд на месте"

  # 3. PostgreSQL: служба.
  info "-- PostgreSQL --"
  ensure_postgres_running
  ensure_pg_hba_local

  # 4. Значения (env). Генерируем один раз; повторный запуск не перетирает.
  mkdir -p "$DATA_DIR" "$RUN_DIR" "$LOG_DIR" "$DATA_DIR/uploads"
  if [ -f "$ENV_FILE" ]; then
    info "конфиг уже есть: $ENV_FILE (не трогаю)"
    # shellcheck disable=SC1090
    . "$ENV_FILE"
  else
    info "генерирую значения → $ENV_FILE"
    local db_pass secrets_key
    db_pass="$(gen_hex 18)"
    secrets_key="$(gen_hex 32)"
    umask 077
    cat >"$ENV_FILE" <<EOF
# Значения ZDC Systems — сгенерированы setup.sh $(date -u +%FT%TZ).
# Содержит секреты (пароль БД, SECRETS_KEY): не коммитить, доступ 600.
# Вход — по файлу лицензии ($LICENSE_FILE); без него — демо-режим, ключ воркера
# start.sh генерирует сам.
export DATABASE_URL="postgres://${DB_ROLE}:${db_pass}@127.0.0.1:5432/${DB_NAME}"
export BIND_ADDR="127.0.0.1:8080"
export SECRETS_KEY="${secrets_key}"
export UPLOAD_DIR="${DATA_DIR}/uploads"

# Дашборд раздаёт сам сервер (каталог сборки + свой адрес, API — под /api).
export DASHBOARD_BIND="127.0.0.1:5173"

# Воркер
export REPORTS_URL="http://127.0.0.1:8080"
export WORKER_NAME="w1"
export LLM_PROVIDER="ollama"
export PENTEST_HOST_PORT="18080"
# Разрешённые корни локальных целей отчётов (через \`:\`). Не задано — локальные
# пути запрещены (архивы и репозитории работают); \`*\` — любой каталог хоста.
# export ZDC_SOURCE_ROOTS="/srv/repos"
# Демо-режим (кнопка «Демо-режим» на экране активации) включён по умолчанию;
# выключить:
# export DEMO_MODE=0
# Отозванные номера лицензий (через запятую) — отказ без связи с издателем.
# export LICENSE_REVOKED=""
EOF
    chmod 600 "$ENV_FILE"
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    info "пароль БД и SECRETS_KEY сгенерированы"
  fi

  # 5. Роль и база PostgreSQL под сгенерированный пароль.
  local db_pass
  db_pass="$(echo "$DATABASE_URL" | sed -E 's#^postgres://[^:]+:([^@]+)@.*#\1#')"
  ensure_pg_role_db "$DB_ROLE" "$db_pass" "$DB_NAME"

  # 6. Лицензия.
  if [ -n "$license" ]; then
    install_license "$license"
  elif [ -f "$LICENSE_FILE" ]; then
    info "лицензия уже подключена: $LICENSE_FILE"
  else
    info "лицензия не подключена — дашборд откроется в демо-режиме; полный доступ: ./scripts/start.sh license <файл .lic>"
  fi

  # 7. Внешние анализаторы ревью (best-effort; ZDC_SKIP_ANALYZERS=1 — пропустить).
  if [ "${ZDC_SKIP_ANALYZERS:-0}" = 1 ]; then
    info "анализаторы пропущены (ZDC_SKIP_ANALYZERS=1)"
  else
    install_analyzers
  fi

  info "== Готово =="
  info "Запуск:   ./scripts/start.sh"
  info "Дашборд:  http://${DASHBOARD_BIND:-127.0.0.1:5173}  (вход — ключ ZDC_LICENSE_USER из файла лицензии)"
  if ! have docker; then warn "docker не установлен — активное тестирование (pentest) будет недоступно"; fi
  if ! have nuclei; then warn "nuclei не установлен — активный скан пентеста недоступен (релиз projectdiscovery/nuclei)"; fi
  if ! have gitleaks; then warn "gitleaks не установлен — поиск секретов в ревью будет пропускаться"; fi
  local a missing=""
  for a in hadolint tfsec kube-score cargo-audit semgrep checkov; do
    have "$a" || missing="$missing $a"
  done
  if [ -n "$missing" ]; then
    warn "анализаторы не установлены:$missing — соответствующие проверки будут пропускаться"
  fi
}

main "$@"

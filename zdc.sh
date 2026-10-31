#!/usr/bin/env bash
# Единая точка входа комплекта bin_release:
#   ./zdc.sh setup [--license <файл>]   подготовить машину (пакеты, PostgreSQL, конфиг)
#   ./zdc.sh license <файл>             подключить/заменить файл лицензии
#   ./zdc.sh start | stop | restart | status
#   ./zdc.sh logs [server|worker]       последние строки журнала
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-help}" in
setup)
  shift
  exec "$here/scripts/setup.sh" "$@"
  ;;
start | stop | restart | status | license) exec "$here/scripts/start.sh" "$@" ;;
logs) exec tail -n 100 -F "$here/.zdc-data/logs/${2:-server}.log" ;;
*)
  sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
  [ "${1:-help}" = help ] || exit 1
  ;;
esac

#!/usr/bin/env bash
# Общие функции для setup.sh и start.sh: определение дистрибутива, установка
# пакетов (ставятся только недостающие — «сканирование» зависимостей),
# PostgreSQL, лицензия. Поддержка семейств: debian, rhel, alpine, arch.
# Система запускается из готовых бинарников (bin/) — Rust и Node не нужны.
#
# Этот файл не запускают напрямую — его подключают (`source`) оба скрипта.

set -euo pipefail

# --- Пути ---------------------------------------------------------------------
# Корень проекта — родитель каталога deploy_scripts/.
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
DATA_DIR="$ROOT_DIR/.zdc-data"
RUN_DIR="$DATA_DIR/run"
LOG_DIR="$DATA_DIR/logs"
ENV_FILE="$SCRIPTS_DIR/zdc.env"
# Готовые бинарники (analitics_service, report_worker) и собранный
# дашборд. В bin_release это bin/ и dashboard/ рядом со scripts/.
BIN_DIR="${ZDC_BIN_DIR:-$ROOT_DIR/bin}"
if [ -n "${ZDC_DASHBOARD_DIR:-}" ]; then
  DASHBOARD_DIST="$ZDC_DASHBOARD_DIR"
elif [ -f "$ROOT_DIR/dashboard/dist/index.html" ]; then
  DASHBOARD_DIST="$ROOT_DIR/dashboard/dist"
else
  DASHBOARD_DIST="$ROOT_DIR/dashboard"
fi
# Файл лицензии (ключи ZDC_LICENSE_USER / ZDC_LICENSE_WORKER), права 600.
LICENSE_FILE="$DATA_DIR/license.lic"

# --- Журнал -------------------------------------------------------------------
_c() { printf '\033[%sm' "$1"; }
info() { printf '%s[+]%s %s\n' "$(_c '1;32')" "$(_c 0)" "$*"; }
warn() { printf '%s[!]%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*" >&2; }
err() { printf '%s[x]%s %s\n' "$(_c '1;31')" "$(_c 0)" "$*" >&2; }
die() {
  err "$*"
  exit 1
}

have() { command -v "$1" >/dev/null 2>&1; }

# --- Root / sudo --------------------------------------------------------------
# Выполнить команду с правами root (напрямую, если уже root; иначе через sudo).
as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif have sudo; then
    sudo "$@"
  else
    die "нужны права root (или sudo) для: $*"
  fi
}

# Выполнить команду от пользователя postgres.
as_pg() {
  if [ "$(id -u)" -eq 0 ]; then
    if have runuser; then runuser -u postgres -- "$@"; else su postgres -s /bin/sh -c "$(printf '%q ' "$@")"; fi
  else
    as_root -u postgres "$@"
  fi
}

# --- Определение дистрибутива -------------------------------------------------
# Заполняет OS_FAMILY (debian|rhel|alpine|arch) и PKG (apt|dnf|apk|pacman).
detect_distro() {
  [ -r /etc/os-release ] || die "нет /etc/os-release — дистрибутив не определить"
  # shellcheck disable=SC1091
  . /etc/os-release
  local ids="${ID:-} ${ID_LIKE:-}"
  case " $ids " in
  *" debian "* | *" ubuntu "*) OS_FAMILY=debian ;;
  *" rhel "* | *" fedora "* | *" centos "* | *" rocky "* | *" almalinux "*) OS_FAMILY=rhel ;;
  *" alpine "*) OS_FAMILY=alpine ;;
  *" arch "* | *" archarm "* | *" manjaro "*) OS_FAMILY=arch ;;
  *) die "неподдерживаемый дистрибутив: ID=${ID:-?} ID_LIKE=${ID_LIKE:-?} (поддержаны debian, rhel, alpine, arch)" ;;
  esac
  case "$OS_FAMILY" in
  debian) PKG=apt ;;
  rhel) if have dnf; then PKG=dnf; else PKG=yum; fi ;;
  alpine) PKG=apk ;;
  arch) PKG=pacman ;;
  esac
  info "дистрибутив: ${PRETTY_NAME:-$ID} → семейство $OS_FAMILY (менеджер $PKG)"
}

# --- Пакеты -------------------------------------------------------------------
# Перевод обобщённого имени зависимости в пакет для текущего семейства.
# Пустая строка — для этого семейства пакет не нужен/входит в другой.
map_pkg() {
  case "$1:$OS_FAMILY" in
  buildtools:debian) echo build-essential ;;
  buildtools:rhel) echo "gcc gcc-c++ make" ;;
  buildtools:alpine) echo build-base ;;
  buildtools:arch) echo base-devel ;;
  cmake:*) echo cmake ;;
  pkgconfig:debian) echo pkg-config ;;
  pkgconfig:rhel) echo pkgconf-pkg-config ;;
  pkgconfig:alpine | pkgconfig:arch) echo pkgconf ;;
  libpq:debian) echo libpq-dev ;;
  libpq:rhel) echo libpq-devel ;;
  libpq:alpine) echo libpq-dev ;;
  libpq:arch) echo postgresql-libs ;;
  # Только библиотека libpq (нужна бинарникам сервера во время работы).
  libpq-run:debian) echo libpq5 ;;
  libpq-run:rhel) echo libpq ;;
  libpq-run:alpine) echo libpq ;;
  libpq-run:arch) echo postgresql-libs ;;
  git:*) echo git ;;
  curl:*) echo curl ;;
  cacerts:*) echo ca-certificates ;;
  pg-server:rhel) echo postgresql-server ;;
  pg-server:*) echo postgresql ;;
  pg-client:debian) echo postgresql-client ;;
  pg-client:alpine) echo postgresql-client ;;
  pg-client:*) echo postgresql ;;
  node:*) echo nodejs ;;
  npm:*) echo npm ;;
  docker:debian) echo docker.io ;;
  docker:*) echo docker ;;
  # python3 + модуль venv (для semgrep/checkov в изолированном окружении).
  python:debian) echo "python3 python3-venv" ;;
  python:rhel) echo "python3 python3-pip" ;;
  python:alpine) echo "python3 py3-pip" ;;
  python:arch) echo python ;;
  *) echo "" ;;
  esac
}

# Установлен ли конкретный пакет (для «сканирования» недостающих).
pkg_present() {
  case "$OS_FAMILY" in
  debian) dpkg -s "$1" >/dev/null 2>&1 ;;
  rhel) rpm -q "$1" >/dev/null 2>&1 ;;
  alpine) apk info -e "$1" >/dev/null 2>&1 ;;
  arch) pacman -Q "$1" >/dev/null 2>&1 ;;
  esac
}

_pkg_update_done=0
pkg_update_once() {
  [ "$_pkg_update_done" -eq 1 ] && return 0
  case "$OS_FAMILY" in
  debian) as_root apt-get update ;;
  rhel) : ;; # dnf сам обновляет метаданные
  alpine) as_root apk update ;;
  arch) as_root pacman -Sy ;;
  esac
  _pkg_update_done=1
}

_pkg_do_install() {
  case "$OS_FAMILY" in
  debian) as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
  rhel) as_root "$PKG" install -y "$@" ;;
  alpine) as_root apk add --no-cache "$@" ;;
  arch) as_root pacman -S --needed --noconfirm "$@" ;;
  esac
}

# Установить обобщённые зависимости — только отсутствующие.
# Использование: install_deps git curl libpq ...
install_deps() {
  local generic real want=() seen=" "
  for generic in "$@"; do
    real="$(map_pkg "$generic")"
    [ -z "$real" ] && continue
    for p in $real; do
      case "$seen" in *" $p "*) continue ;; esac
      seen="$seen$p "
      if pkg_present "$p"; then
        info "  уже есть: $p"
      else
        want+=("$p")
      fi
    done
  done
  if [ "${#want[@]}" -eq 0 ]; then
    info "все пакеты уже установлены"
    return 0
  fi
  info "ставлю недостающие: ${want[*]}"
  pkg_update_once
  _pkg_do_install "${want[@]}"
}

# Необязательная зависимость: поставить, но не падать при неудаче.
install_optional() {
  install_deps "$@" || warn "не удалось поставить необязательные пакеты: $* (продолжаю)"
}

# --- Анализаторы --------------------------------------------------------------
# Внешние статические анализаторы, которые вызывает воркер (zdc_mcp/analyzers.rs):
# hadolint / tfsec / kube-score (релизные бинарники), cargo-audit (Rust),
# semgrep / checkov (Python). Ставятся best-effort: без них ревью развёртки/кода
# работает, просто пропускает соответствующий анализатор.
#
# Версии и SHA-256 закреплены (как в Dockerfile). При обновлении — менять вместе.
HADOLINT_VERSION=2.15.1
HADOLINT_SHA256_amd64=c7187db94eeeeca956519a6af171adc31453941a1e777961f6e680f697c8c507
HADOLINT_SHA256_arm64=f6198ef8090f404dbb771abfee086eb8c48ac177f30da7fd3510aca35b344b5d
TFSEC_VERSION=1.28.14
TFSEC_SHA256_amd64=329ae7f67f2f1813ebe08de498719ea7003c75d3ca24bb0b038369062508008e
TFSEC_SHA256_arm64=13dcbd3602027be49ce6cab7e1c24b0a8e833f0143fe327b0a13b87686541ce0
KUBE_SCORE_VERSION=1.20.0
KUBE_SCORE_SHA256_amd64=ff777b4b3f45905b2d22c69e93c57a7a170e61529a79d54e59cb95cca4bc2a55
KUBE_SCORE_SHA256_arm64=0fafe8a00cbc98935f0c0953ba91e83e199f65e56d6816e7b2d2af5da1862051
CARGO_AUDIT_VERSION=0.22.2
SEMGREP_VERSION=1.182.1
CHECKOV_VERSION=3.3.30
ANALYZER_VENV=/opt/zdc-analyzers

# Есть ли возможность выполнить что-то от root (напрямую или через sudo).
can_root() { [ "$(id -u)" -eq 0 ] || have sudo; }

# Архитектура в терминах релизов (amd64/arm64) или пусто для неизвестной.
release_arch() {
  case "$(uname -m)" in
  x86_64 | amd64) echo amd64 ;;
  aarch64 | arm64) echo arm64 ;;
  *) echo "" ;;
  esac
}

# Поставить статический бинарник анализатора в /usr/local/bin с проверкой SHA-256.
# $1 имя · $2 url · $3 sha256 · [$4 имя файла внутри tar.gz; без него — raw-бинарник]
_fetch_static_analyzer() {
  local name="$1" url="$2" sum="$3" member="${4:-}" tmp
  have "$name" && {
    info "  $name уже есть"
    return 0
  }
  tmp="$(mktemp -d)"
  if ! curl -fsSL -o "$tmp/dl" "$url"; then
    warn "  $name: не скачался ($url) — пропущен"
    rm -rf "$tmp"
    return 1
  fi
  if ! echo "$sum  $tmp/dl" | sha256sum -c - >/dev/null 2>&1; then
    warn "  $name: SHA-256 не совпал — пропущен (возможно, версия устарела)"
    rm -rf "$tmp"
    return 1
  fi
  local src="$tmp/dl"
  if [ -n "$member" ]; then
    if ! tar -xzf "$tmp/dl" -C "$tmp" "$member"; then
      warn "  $name: распаковка не удалась — пропущен"
      rm -rf "$tmp"
      return 1
    fi
    src="$tmp/$member"
  fi
  if as_root install -m0755 "$src" "/usr/local/bin/$name"; then
    info "  $name установлен → /usr/local/bin/$name"
  else
    warn "  $name: не удалось записать в /usr/local/bin — пропущен"
  fi
  rm -rf "$tmp"
}

# semgrep + checkov в изолированный venv ($ANALYZER_VENV) + симлинки в /usr/local/bin.
_install_python_analyzers() {
  if have semgrep && have checkov; then
    info "  semgrep и checkov уже есть"
    return 0
  fi
  install_optional python
  have python3 || {
    warn "  python3 не установлен — semgrep/checkov пропущены"
    return 0
  }
  if [ ! -x "$ANALYZER_VENV/bin/pip" ]; then
    as_root python3 -m venv "$ANALYZER_VENV" 2>/dev/null || {
      warn "  не удалось создать venv $ANALYZER_VENV — semgrep/checkov пропущены"
      return 0
    }
  fi
  info "  ставлю semgrep и checkov в $ANALYZER_VENV (может занять время)"
  if as_root "$ANALYZER_VENV/bin/pip" install --no-cache-dir --quiet \
    "semgrep==$SEMGREP_VERSION" "checkov==$CHECKOV_VERSION"; then
    as_root ln -sf "$ANALYZER_VENV/bin/semgrep" /usr/local/bin/semgrep
    as_root ln -sf "$ANALYZER_VENV/bin/checkov" /usr/local/bin/checkov
    info "  semgrep и checkov установлены"
  else
    warn "  не удалось поставить semgrep/checkov через pip — пропущены"
  fi
}

# Поставить все внешние анализаторы (best-effort; ничего не прерывает setup).
install_analyzers() {
  info "-- анализаторы (best-effort) --"
  if ! can_root; then
    warn "нет прав root/sudo — установка анализаторов пропущена"
    return 0
  fi
  have curl || install_optional curl cacerts

  local arch
  arch="$(release_arch)"
  if [ -z "$arch" ]; then
    warn "неизвестная архитектура $(uname -m) — hadolint/tfsec/kube-score пропущены"
  else
    local harch hsum tsum ksum
    [ "$arch" = amd64 ] && harch=x86_64 || harch=arm64
    eval "hsum=\$HADOLINT_SHA256_$arch tsum=\$TFSEC_SHA256_$arch ksum=\$KUBE_SCORE_SHA256_$arch"
    _fetch_static_analyzer hadolint \
      "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-Linux-${harch}" \
      "$hsum" || true
    _fetch_static_analyzer tfsec \
      "https://github.com/aquasecurity/tfsec/releases/download/v${TFSEC_VERSION}/tfsec_${TFSEC_VERSION}_linux_${arch}.tar.gz" \
      "$tsum" tfsec || true
    _fetch_static_analyzer kube-score \
      "https://github.com/zegl/kube-score/releases/download/v${KUBE_SCORE_VERSION}/kube-score_${KUBE_SCORE_VERSION}_linux_${arch}.tar.gz" \
      "$ksum" kube-score || true
  fi

  # cargo-audit: ставится из crates.io в ~/.cargo/bin, копируем в /usr/local/bin.
  if have cargo-audit; then
    info "  cargo-audit уже есть"
  elif have cargo; then
    info "  ставлю cargo-audit (компиляция, может занять время)"
    if cargo install cargo-audit --version "$CARGO_AUDIT_VERSION" --locked 2>/dev/null &&
      [ -x "$HOME/.cargo/bin/cargo-audit" ]; then
      as_root install -m0755 "$HOME/.cargo/bin/cargo-audit" /usr/local/bin/cargo-audit || true
      info "  cargo-audit установлен"
    else
      warn "  cargo-audit не собрался — пропущен"
    fi
  else
    warn "  cargo нет — cargo-audit пропущен"
  fi

  _install_python_analyzers
}

# --- PostgreSQL ---------------------------------------------------------------
pg_running() { pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1; }

# Инициализировать кластер (где это не делается пакетом) и запустить службу.
ensure_postgres_running() {
  if pg_running; then
    info "PostgreSQL уже отвечает на 127.0.0.1:5432"
    return 0
  fi
  # Инициализация кластера, если каталог данных пуст (RHEL/Arch).
  case "$OS_FAMILY" in
  rhel)
    if [ ! -d /var/lib/pgsql/data/base ]; then
      info "инициализирую кластер PostgreSQL (postgresql-setup)"
      as_root postgresql-setup --initdb 2>/dev/null ||
        as_pg initdb -D /var/lib/pgsql/data
    fi
    ;;
  arch)
    if [ ! -d /var/lib/postgres/data/base ]; then
      info "инициализирую кластер PostgreSQL (initdb)"
      as_pg initdb --locale=C.UTF-8 --encoding=UTF8 -D /var/lib/postgres/data
    fi
    ;;
  alpine)
    if [ ! -d /var/lib/postgresql/data/base ] && [ ! -d /var/lib/postgresql/*/data/base ] 2>/dev/null; then
      as_root rc-update add postgresql default 2>/dev/null || true
      as_root /etc/init.d/postgresql setup 2>/dev/null || true
    fi
    ;;
  esac
  # Запуск службы: systemd → service → openrc → ручной pg_ctl.
  info "запускаю службу PostgreSQL"
  if have systemctl; then
    as_root systemctl enable --now postgresql 2>/dev/null || as_root systemctl start postgresql || true
  elif have rc-service; then
    as_root rc-service postgresql start || true
  elif have service; then
    as_root service postgresql start || true
  fi
  # Подождать готовности.
  local i
  for i in $(seq 1 30); do
    pg_running && break
    sleep 1
  done
  pg_running || die "PostgreSQL не поднялся на 127.0.0.1:5432 — запусти службу вручную и повтори"
  info "PostgreSQL отвечает"
}

# Разрешить парольный доступ по TCP с localhost (scram), если ещё не разрешён.
ensure_pg_hba_local() {
  local hba
  hba="$(as_pg psql -tAc 'SHOW hba_file' 2>/dev/null | tr -d '[:space:]')" || return 0
  [ -n "$hba" ] || return 0
  if as_root grep -Eq '^[[:space:]]*host[[:space:]]+all[[:space:]]+all[[:space:]]+127\.0\.0\.1/32[[:space:]]+(scram-sha-256|md5)' "$hba" 2>/dev/null; then
    return 0
  fi
  info "добавляю правило pg_hba для 127.0.0.1 (scram-sha-256)"
  as_root sh -c "printf 'host all all 127.0.0.1/32 scram-sha-256\nhost all all ::1/128 scram-sha-256\n' >> '$hba'"
  if have systemctl; then as_root systemctl reload postgresql 2>/dev/null || true; fi
  as_pg psql -c 'SELECT pg_reload_conf();' >/dev/null 2>&1 || true
}

# Создать роль и БД, если их нет. Аргументы: роль, пароль, база.
ensure_pg_role_db() {
  local role="$1" pass="$2" db="$3"
  if ! as_pg psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$role'" | grep -q 1; then
    info "создаю роль БД '$role'"
    as_pg psql -c "CREATE ROLE \"$role\" LOGIN PASSWORD '$pass';" >/dev/null
  else
    info "роль '$role' уже есть — обновляю пароль"
    as_pg psql -c "ALTER ROLE \"$role\" WITH LOGIN PASSWORD '$pass';" >/dev/null
  fi
  if ! as_pg psql -tAc "SELECT 1 FROM pg_database WHERE datname='$db'" | grep -q 1; then
    info "создаю базу '$db' (владелец '$role')"
    as_pg createdb -O "$role" "$db"
  else
    info "база '$db' уже есть"
  fi
}

# --- Генерация значений -------------------------------------------------------
# $1 байт случайных данных → hex (2*$1 символов). 32 байта → 64 hex (SECRETS_KEY).
gen_hex() { od -An -tx1 -N"$1" /dev/urandom | tr -d ' \n'; }

# --- Бинарники и лицензия -----------------------------------------------------
# Проверить, что готовые бинарники на месте и запускаются (хватает библиотек).
check_binaries() {
  local b missing
  for b in analitics_service report_worker; do
    [ -x "$BIN_DIR/$b" ] || die "нет $BIN_DIR/$b — нужен комплект bin_release (или ZDC_BIN_DIR=<каталог бинарников>)"
    if have ldd; then
      missing="$(ldd "$BIN_DIR/$b" 2>/dev/null | awk '/not found/{print $1}' | tr '\n' ' ')"
      [ -z "$missing" ] || die "$b: не хватает библиотек: $missing(для libpq — пакет libpq5/libpq/postgresql-libs)"
    fi
  done
  [ -f "$DASHBOARD_DIST/index.html" ] || die "нет собранного дашборда: $DASHBOARD_DIST/index.html"
}

# Ключ из файла лицензии: license_key USER|WORKER. Файл не исполняется (source):
# берём только строку нужного вида.
license_key() {
  [ -f "$LICENSE_FILE" ] || return 0
  grep -E "^ZDC_LICENSE_$1=[A-Za-z0-9_-]{120,1024}$" "$LICENSE_FILE" | head -n1 | cut -d= -f2-
}

# Проверить файл лицензии самим сервером (analitics_service --check-license).
check_license_file() {
  "$BIN_DIR/analitics_service" --check-license "$1"
}

# Подключить файл лицензии: проверить и скопировать в $LICENSE_FILE (600).
install_license() {
  local src="$1"
  [ -f "$src" ] || die "нет файла лицензии: $src"
  grep -qE '^ZDC_LICENSE_USER=' "$src" || die "$src: нет строки ZDC_LICENSE_USER= — это не файл лицензии"
  grep -qE '^ZDC_LICENSE_WORKER=' "$src" || die "$src: нет строки ZDC_LICENSE_WORKER= (ключ воркера)"
  check_license_file "$src" || die "лицензия не прошла проверку (см. выше)"
  mkdir -p "$DATA_DIR"
  if [ "$(cd "$(dirname "$src")" && pwd)/$(basename "$src")" != "$LICENSE_FILE" ]; then
    install -m600 "$src" "$LICENSE_FILE"
  fi
  chmod 600 "$LICENSE_FILE"
  info "лицензия подключена → $LICENSE_FILE"
}


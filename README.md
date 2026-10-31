# ZDC Systems — комплект для запуска (bin_release)

Готовые бинарники всей системы, собранный дашборд и скрипты запуска. Rust,
Node.js и сборка на целевой машине **не нужны**.

```
bin_release/
├── zdc.sh               единая точка входа: setup / license / start / stop / status / logs
├── bin/
│   ├── analitics_service  reports-сервер: API, БД-миграции, раздача дашборда
│   ├── report_worker      воркер: ревью кода/развёртки, пентест в песочнице
│   ├── mcp_stdio, mcp_http  MCP-инструменты для внешних агентов (необязательно)
│   └── scope_sign         подпись scope активного тестирования (необязательно)
├── dashboard/           собранный веб-дашборд (раздаёт analitics_service)
├── scripts/             setup.sh, start.sh, lib.sh
├── VERSION              дата сборки и версии компонентов
└── SHA256SUMS           контрольные суммы всех файлов комплекта
```

## Требования

- Linux x86_64. Семейства для автоматической установки пакетов: Debian/Ubuntu,
  RHEL/Fedora, Alpine, Arch.
- **glibc не старше той, на которой собран комплект** (строка `glibc:` в
  `VERSION`). Текущая сборка сделана на Arch (glibc 2.43) — для Debian 12/13 и
  Ubuntu 22.04/24.04 нужен комплект, собранный под них, иначе сервер не
  запустится (`GLIBC_2.43 not found`).
- PostgreSQL 13+ (setup.sh ставит и настраивает локальный) и `libpq`.
- Файл лицензии `*.lic` от издателя.
- Необязательно: `docker` + compose (пентест), `gitleaks`, `nuclei`, анализаторы
  `hadolint`/`tfsec`/`kube-score`/`semgrep`/`checkov`/`cargo-audit` (setup.sh
  пытается поставить их сам), Ollama или ключ облачной нейросети.

## Быстрый старт

```bash
sha256sum -c SHA256SUMS              # комплект не повреждён
./zdc.sh setup --license acme.lic    # пакеты, PostgreSQL, конфиг, лицензия (нужен sudo)
./zdc.sh start                       # сервер + дашборд + воркер
```

Откройте <http://127.0.0.1:5173> и войдите ключом из строки
`ZDC_LICENSE_USER=` файла лицензии.

## Лицензия

Вход в систему — по **офлайн-лицензионному ключу**: сервер проверяет его сам,
без интернета и без обращения к издателю (подходит для изолированного
интранета). Файл лицензии содержит два ключа одной лицензии:

| Строка | Кому | Права |
|--------|------|-------|
| `ZDC_LICENSE_USER=…` | людям, вход в дашборд | запуск отчётов, настройки, scope |
| `ZDC_LICENSE_WORKER=…` | воркерам (скрипт передаёт сам) | взять задачу, записать результат |

В ключе записаны номер лицензии, владелец и срок; изменённый ключ не
принимается. Генерировать API-токены не нужно — простые токены этой сборкой не
принимаются.

```bash
./zdc.sh license new.lic        # подключить или заменить лицензию (проверяется сразу)
./zdc.sh restart                # чтобы сервер и воркер взяли новый ключ
./zdc.sh status                 # компоненты + владелец и срок лицензии
bin/analitics_service --check-license new.lic   # проверить файл, ничего не меняя
```

- За 14 дней до окончания дашборд показывает предупреждение; после окончания
  вход и работа воркера прекращаются (401 «срок лицензии истёк»), данные остаются.
- Карточка «Лицензия» — на странице «Нейросеть».
- Отозвать лицензию без связи с издателем: номер в `LICENSE_REVOKED`
  (`scripts/zdc.env`, через запятую) и `./zdc.sh restart`.
- Файл лицензии хранится в `.zdc-data/license.lic` (права 600) — это пароль:
  не публикуйте его.

## Команды

| Команда | Что делает |
|---------|------------|
| `./zdc.sh setup [--license f]` | ставит недостающие пакеты, проверяет бинарники и библиотеки, поднимает PostgreSQL (роль `zdc`, база `reports`), создаёт `scripts/zdc.env` (пароль БД, `SECRETS_KEY`; повторный запуск не перетирает), ставит анализаторы |
| `./zdc.sh license <f>` | проверяет и подключает файл лицензии |
| `./zdc.sh start` | запускает сервер (миграции БД применяются сами; дашборд — на `DASHBOARD_BIND`) и воркер |
| `./zdc.sh stop` / `restart` | штатная остановка (воркер сносит песочницу пентеста) |
| `./zdc.sh status` | состояние, `health`, лицензия |
| `./zdc.sh logs [server\|worker]` | хвост журнала |

Данные и журналы — в `.zdc-data/` (`logs/`, `run/`, `uploads/`, `license.lic`).

## Настройка (`scripts/zdc.env`)

| Переменная | По умолчанию | Назначение |
|------------|--------------|------------|
| `DATABASE_URL` | локальный PostgreSQL | база отчётов |
| `BIND_ADDR` | `127.0.0.1:8080` | API (воркеры) |
| `DASHBOARD_BIND` | `127.0.0.1:5173` | дашборд + API под `/api` |
| `SECRETS_KEY` | сгенерирован | шифрование ключей нейросетей в БД — **не терять и не менять** |
| `LLM_PROVIDER`, `LLM_MODEL` | `ollama` | нейросеть по умолчанию (меняется и в дашборде) |
| `ZDC_SOURCE_ROOTS` | не задан | разрешённые каталоги локальных целей (`none` — запретить) |
| `LICENSE_REVOKED` | — | отозванные номера лицензий |
| `ZDC_EXTERNAL_DB=1` | — | БД на другой машине: не трогать локальный PostgreSQL |
| `ZDC_SKIP_ANALYZERS=1` | — | setup без установки анализаторов |

Ключи облачных нейросетей вводятся в дашборде («Нейросеть» → «Ключи API»).
Учтите: облачный провайдер получает фрагменты кода и находки.

## Развёртывание на сервере

1. Скопируйте комплект: `rsync -a bin_release/ srv:/opt/zdc/` (или `git clone`
   репозитория комплекта), затем `sha256sum -c SHA256SUMS`.
2. `cd /opt/zdc && ./zdc.sh setup --license /path/acme.lic` от пользователя с sudo
   (саму систему лучше запускать от отдельного непривилегированного пользователя,
   владельца `/opt/zdc`).
3. Доступ снаружи — только через прокси с TLS. Оставьте `DASHBOARD_BIND` на
   `127.0.0.1` и настройте nginx:

   ```nginx
   server {
       listen 443 ssl;
       server_name zdc.example.com;
       ssl_certificate     /etc/letsencrypt/live/zdc.example.com/fullchain.pem;
       ssl_certificate_key /etc/letsencrypt/live/zdc.example.com/privkey.pem;
       client_max_body_size 256m;              # не меньше UPLOAD_MAX_MB
       location / {
           proxy_pass http://127.0.0.1:5173;
           proxy_set_header X-Real-IP $remote_addr;
           proxy_request_buffering off;
           proxy_read_timeout 300s;
       }
   }
   ```

   и добавьте в `scripts/zdc.env` `export TRUSTED_PROXIES="127.0.0.1"` — иначе
   ограничение перебора ключей считает всех клиентов одним адресом.
4. Воркеры на других машинах: скопируйте туда `bin/report_worker` и запустите с
   `REPORTS_URL=https://<сервер>`, `WORKER_NAME=<имя>` и
   `WORKER_TOKEN=<ключ ZDC_LICENSE_WORKER>`. API для них должен быть доступен
   (через тот же прокси под `/api` — `REPORTS_URL=https://zdc.example.com/api`).
   Воркеров на той же машине можно запускать прямо из дашборда.
5. Автозапуск — systemd-юнит:

   ```ini
   # /etc/systemd/system/zdc.service
   [Unit]
   Description=ZDC Systems
   After=network-online.target postgresql.service

   [Service]
   Type=oneshot
RemainAfterExit=yes
   User=zdc
   WorkingDirectory=/opt/zdc
   ExecStart=/opt/zdc/zdc.sh start
   ExecStop=/opt/zdc/zdc.sh stop
   TimeoutStopSec=60

   [Install]
   WantedBy=multi-user.target
   ```

   `systemctl daemon-reload && systemctl enable --now zdc`.
6. Резервные копии: база (`pg_dump reports`), `scripts/zdc.env` (без
   `SECRETS_KEY` сохранённые ключи нейросетей не расшифровать), `.zdc-data/uploads`.

## Обновление

```bash
./zdc.sh stop
rsync -a --exclude scripts/zdc.env --exclude .zdc-data new_bin_release/ /opt/zdc/
./zdc.sh start          # миграции БД применятся сами
```

## Частые проблемы

| Симптом | Причина |
|---------|---------|
| `GLIBC_2.xx not found` | комплект собран под более новую систему — запросите комплект под вашу ОС |
| `libpq.so.5: cannot open` | нет пакета `libpq5` / `libpq` / `postgresql-libs` |
| 401 «срок лицензии истёк» | нужна новая лицензия → `./zdc.sh license new.lic && ./zdc.sh restart` |
| 401 «ключ недействителен» | ключ повреждён при копировании или выпущен для другой сборки — запросите у издателя |
| «Это ключ воркера» на входе | для дашборда нужна строка `ZDC_LICENSE_USER` |
| сервер не ответил за 30 с | см. `.zdc-data/logs/server.log` (часто — недоступна БД) |
| pentest-отчёты не берутся | нужен docker и действующая цель на странице «Scope» |

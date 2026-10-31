# ZDC Systems — комплект для запуска (bin_release)

Готовые бинарники всей системы, собранный дашборд и скрипты запуска. Rust,
Node.js и сборка на целевой машине **не нужны**.

Репозиторий комплекта: <https://github.com/ZDC-System/ZDC-bin-release>.

```
ZDC-bin-release/
├── zdc.sh               единая точка входа: setup / start / stop / restart / status / logs / license
├── bin/
│   ├── analitics_service  reports-сервер: API, миграции БД, раздача дашборда, запуск воркеров
│   ├── report_worker      воркер: ревью кода/развёртки, пентест в песочнице
│   ├── mcp_stdio, mcp_http  MCP-инструменты для внешних агентов (необязательно)
│   └── scope_sign         подпись scope активного тестирования (необязательно)
├── dashboard/           собранный веб-дашборд (раздаёт analitics_service)
├── scripts/             setup.sh, start.sh, lib.sh
├── VERSION              дата сборки, glibc, режим лицензии, версии компонентов
└── SHA256SUMS           контрольные суммы всех файлов комплекта
```

## Требования

- Linux x86_64.
- **glibc не старше той, на которой собран комплект** — строка `glibc:` в
  `VERSION`. Текущая сборка сделана на Arch Linux (glibc 2.44): на Debian 12/13,
  Ubuntu 22.04/24.04 и Alpine (musl) она не запустится (`GLIBC_2.44 not found`) —
  для них нужен комплект, собранный под эту систему. Подходят Arch и другие
  дистрибутивы с glibc ≥ 2.44.
- `sudo` (или root) для `setup`: пакеты и PostgreSQL. Автоустановка пакетов
  знает семейства Arch, Debian/Ubuntu, RHEL/Fedora, Alpine.
- PostgreSQL 13+ и `libpq` — `setup` ставит и настраивает локальный.
- Лицензия **не нужна**: эта сборка (`license: not required` в `VERSION`)
  работает по токенам, которые `start.sh` создаёт сам.
- Нейросеть: локальная Ollama / llama.cpp или ключ облачного провайдера.
- Необязательно: `docker` + compose (пентест), `nuclei` (активный скан),
  `gitleaks` (поиск секретов), анализаторы `hadolint`/`tfsec`/`kube-score`/
  `semgrep`/`checkov`/`cargo-audit` (`setup` пытается поставить их сам).

Windows — через WSL 2 с дистрибутивом `archlinux` (подробно — на странице
«Установка» сайта <https://zdc-system.github.io/install.html#wsl>).

## Быстрый старт

```bash
git clone https://github.com/ZDC-System/ZDC-bin-release.git
cd ZDC-bin-release
sha256sum -c SHA256SUMS              # комплект не повреждён
./zdc.sh setup                       # пакеты, PostgreSQL, scripts/zdc.env (нужен sudo)
./zdc.sh start                       # сервер + дашборд + воркер
```

Вместо `git clone` можно скачать архив ветки `main`
(<https://github.com/ZDC-System/ZDC-bin-release/archive/refs/heads/main.tar.gz>) —
распаковывайте в домашний каталог Linux, а не на смонтированный диск Windows
(`/mnt/c`): там теряются права на запуск.

Откройте <http://127.0.0.1:5173> и активируйте дашборд значением `API_TOKEN` из
`.zdc-data/tokens.env` (`start.sh` печатает путь при запуске):

```bash
grep API_TOKEN .zdc-data/tokens.env
```

Токен вводится в поле «Лицензионный ключ» (для этой сборки оно принимает и
`API_TOKEN`). Он сохраняется в браузере — вводить его заново не нужно. Попробовать без
ключа — кнопка «Демо-режим» на том же экране.

Затем на странице «Нейросеть» выберите провайдера. По умолчанию — Ollama на
`http://localhost:11434`; модель нужно скачать заранее (`ollama pull <модель>`).
Маленькие модели (меньше 7B) находят мало и путают язык отчёта — дашборд
предупреждает о них; лучше ≥ 7B или облачный провайдер (ключ вводится там же,
«Ключи API»). Облачный провайдер получает фрагменты кода и находки.

## Вход: токены

При первом `./zdc.sh start` скрипт генерирует два токена в
`.zdc-data/tokens.env` (права 600) и дальше берёт их оттуда:

| Строка | Кому |
|--------|------|
| `API_TOKEN=…` | людям — активация дашборда |
| `WORKER_TOKEN=…` | воркерам (скрипт и сервер передают его сами) |

- Свои токены (≥ 16 символов, разные): `export API_TOKEN=…` и
  `export WORKER_TOKEN=…` в `scripts/zdc.env` — они важнее файла.
- Сменить сгенерированные: удалить `.zdc-data/tokens.env` и `./zdc.sh restart`
  (в дашборде активироваться заново).
- Токены — это пароли, не публикуйте их. Режима без проверки входа нет: без
  токенов (или лицензии) сервер не стартует.

## Демо-режим

Включён по умолчанию: кнопка «Демо-режим» на экране активации — вход без
ключа. В демо:

- только ревью кода **одного** загруженного файла (до 512 КБ); пентест и
  ревью развёртки запрещены;
- доступна страница «Нейросеть» (выбор нейросети, ключи, запуск воркеров);
  scope, аудит, таймауты, расписание и повтор — нет;
- видны только отчёты, созданные в демо; отчёты, созданные по токену, не видны.

Выключить: `export DEMO_MODE=0` в `scripts/zdc.env` и `./zdc.sh restart`.

## Команды

| Команда | Что делает |
|---------|------------|
| `./zdc.sh setup` | ставит недостающие пакеты, проверяет бинарники и библиотеки, поднимает PostgreSQL (роль `zdc`, база `reports`), создаёт `scripts/zdc.env` (пароль БД, `SECRETS_KEY`; повторный запуск его не перетирает), ставит анализаторы |
| `./zdc.sh start` | запускает сервер (миграции БД применяются сами; дашборд — на `DASHBOARD_BIND`) и воркер `w1` |
| `./zdc.sh stop` / `restart` | штатная остановка (воркер сносит песочницу пентеста) |
| `./zdc.sh status` | состояние компонентов, `health`, способ входа |
| `./zdc.sh logs [server\|worker]` | хвост журнала |
| `./zdc.sh license <файл>` | подключить файл лицензии (необязательно, см. ниже) |

Данные и журналы — в `.zdc-data/` (`logs/`, `run/`, `uploads/`, `tokens.env`).
`scripts/zdc.env` и `.zdc-data/` в git не попадают (`.gitignore`).

## Настройка (`scripts/zdc.env`)

| Переменная | По умолчанию | Назначение |
|------------|--------------|------------|
| `DATABASE_URL` | локальный PostgreSQL | база отчётов |
| `BIND_ADDR` | `127.0.0.1:8080` | API (воркеры) |
| `DASHBOARD_BIND` | `127.0.0.1:5173` | дашборд + API под `/api` |
| `SECRETS_KEY` | сгенерирован | шифрование ключей нейросетей в БД — **не терять и не менять** |
| `WORKER_NAME` | `w1` | имя воркера, которого запускает `start.sh` |
| `LLM_PROVIDER`, `LLM_MODEL` | `ollama` | нейросеть по умолчанию (меняется и в дашборде) |
| `OLLAMA_HOST` | `http://localhost:11434` | адрес Ollama |
| `PENTEST_HOST_PORT` | `18080` | порт цели в песочнице пентеста (занят — берётся свободный) |
| `ZDC_SOURCE_ROOTS` | не задан | разрешённые каталоги локальных целей через `:` (`none` — запретить) |
| `API_TOKEN`, `WORKER_TOKEN` | `.zdc-data/tokens.env` | свои токены входа |
| `DEMO_MODE` | включён | `0` — выключить демо-режим |
| `TRUSTED_PROXIES` | — | адреса прокси, которым верить в `X-Real-IP` |
| `ZDC_EXTERNAL_DB=1` | — | БД на другой машине: не трогать локальный PostgreSQL |
| `ZDC_SKIP_ANALYZERS=1` | — | `setup` без установки анализаторов |
| `ZDC_DB_ROLE`, `ZDC_DB_NAME` | `zdc`, `reports` | роль и база, которые создаёт `setup` (задавать в окружении перед `setup`) |

После правки — `./zdc.sh restart`.

## Пентест

Активное тестирование атакует **копию** проекта в песочнице docker, не
рабочий хост. Нужны `docker` с compose и `nuclei`. Воркер берёт отчёт
`pentest`, только если цель авторизована: добавьте её на странице «Scope»
дашборда (у каждой цели свой срок действия, по умолчанию сутки).

## Лицензия (необязательно)

Комплект работает без лицензии. Если издатель выдал файл лицензии `.lic`, его
можно подключить — тогда вместо токенов используются ключи из файла
(`ZDC_LICENSE_USER` — для дашборда, `ZDC_LICENSE_WORKER` — для воркеров):

```bash
# в scripts/zdc.env — открытый ключ издателя (выдаётся вместе с лицензией):
#   export LICENSE_PUBLIC_KEY=…
./zdc.sh license acme.lic       # проверить и подключить (.zdc-data/license.lic, 600)
./zdc.sh restart
./zdc.sh status                 # владелец и срок лицензии
```

В шапке дашборда — плашка «Активирован до …»; за 14 дней до окончания —
предупреждение. После окончания или отзыва (`LICENSE_REVOKED` в `zdc.env` —
номера через запятую) дашборд снова просит активацию с причиной, воркер
перестаёт брать задачи, данные остаются. Файл лицензии — пароль, не
публикуйте его.

## Развёртывание на сервере

1. Склонируйте комплект в `/opt/zdc` (или `rsync -a` с другой машины), затем
   `sha256sum -c SHA256SUMS`.
2. `cd /opt/zdc && ./zdc.sh setup` от пользователя с sudo. Саму систему лучше
   запускать от отдельного непривилегированного пользователя — владельца
   `/opt/zdc`.
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
   ограничение перебора ключей считает всех клиентов одним адресом. Если сервер
   доступен из интернета, подумайте, нужен ли там демо-режим (`DEMO_MODE=0`).
4. Воркеры на той же машине можно запускать прямо из дашборда («Нейросеть» →
   «Запуск воркеров»). Воркеры на других машинах: скопируйте туда
   `bin/report_worker` и запустите с `REPORTS_URL=https://zdc.example.com/api`,
   `WORKER_NAME=<имя>` и `WORKER_TOKEN=<из .zdc-data/tokens.env>`.
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
   TimeoutStopSec=90

   [Install]
   WantedBy=multi-user.target
   ```

   `systemctl daemon-reload && systemctl enable --now zdc`.
6. Резервные копии: база (`pg_dump reports`), `scripts/zdc.env` (без
   `SECRETS_KEY` сохранённые ключи нейросетей не расшифровать),
   `.zdc-data/tokens.env`, `.zdc-data/uploads`.

## Обновление

```bash
./zdc.sh stop
git pull                    # scripts/zdc.env и .zdc-data/ не затрагиваются
sha256sum -c SHA256SUMS
./zdc.sh start              # миграции БД применятся сами
```

Если комплект скопирован без git:
`rsync -a --exclude scripts/zdc.env --exclude .zdc-data new/ /opt/zdc/`.

## Частые проблемы

| Симптом | Причина и решение |
|---------|-------------------|
| `GLIBC_2.xx not found` | комплект собран под более новую систему — нужен комплект под вашу ОС |
| `libpq.so.5: cannot open` | нет пакета `libpq5` / `libpq` / `postgresql-libs` |
| `сервер не ответил за 30 с` | см. `.zdc-data/logs/server.log` (чаще всего недоступна БД) |
| `миграции: permission denied for schema public` | база `reports` принадлежит другой роли (например, от старой установки): `sudo -u postgres psql -d reports -c 'REASSIGN OWNED BY <старая> TO zdc'` и `ALTER DATABASE reports OWNER TO zdc` |
| «Сервер не принял ключ.» при активации | введите `API_TOKEN`, а не `WORKER_TOKEN`; после удаления `tokens.env` токены другие |
| «Это ключ воркера» при активации | для дашборда нужен `ZDC_LICENSE_USER` (или весь файл `.lic`) |
| 401 «срок лицензии истёк» | новая лицензия → `./zdc.sh license new.lic && ./zdc.sh restart` |
| отчёты висят «В очереди» | воркер не запущен или не на связи — `./zdc.sh status`, `./zdc.sh logs worker` |
| ошибка нейросети в отчёте | Ollama не запущена или модель не скачана (`ollama pull`), либо нет ключа облачного провайдера |
| pentest-отчёты не берутся | нужен docker и действующая цель на странице «Scope» |

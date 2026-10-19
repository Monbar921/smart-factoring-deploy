# smart-factoring-deploy

Раскатка smart-factoring на VDS через docker compose: `postgres` + `backend` + `gateway`.

```
клиент ──▶ :GATEWAY_PORT gateway ──▶ backend:8080 ──▶ postgres:5432
                                     127.0.0.1:BACKEND_PORT   127.0.0.1:POSTGRES_PORT
```

Снаружи открыт только gateway, backend и postgres слушают `127.0.0.1` VDS (доступ через ssh-туннель).

## Как это работает

1. CI/CD [smart-factoring-backend](https://github.com/Monbar921/smart-factoring-backend) и
   [smart-factoring-gateway](https://github.com/Monbar921/smart-factoring-gateway) собирают образ
   `ghcr.io/monbar921/smart-factoring-<сервис>:<short sha>` и шлют сюда `repository_dispatch` (`event_type: deploy`).
2. [deploy.yml](.github/workflows/deploy.yml) выбирает окружение по ветке сервиса: `main` → `prod`, остальное → `test`.
3. Обновляется тег только пришедшего сервиса. Тег второго берётся из текущего `.env` на VDS, а если стенд ещё
   пустой - тег ветки окружения (`test` или `main`), который CI сервиса ставит при каждой сборке.
4. По SSH кладёт на VDS в `VDS_DIR` файлы `docker-compose.yml` и `.env` (из секретов окружения),
   делает `docker compose pull` и `docker compose up -d --wait`: job зелёный, только если все сервисы прошли healthcheck.

Ручной деплой или откат: Actions → Deploy → Run workflow, окружение + сервис + тег (short sha из истории сервиса).

## Подготовка VDS (один раз)

```bash
# docker + compose plugin, пользователь для деплоя в группе docker
sudo useradd -m -s /bin/bash deploy
sudo usermod -aG docker deploy
sudo mkdir -p /opt/smart-factoring && sudo chown deploy: /opt/smart-factoring

# ключ только для деплоя (на своей машине), публичную часть - в ~deploy/.ssh/authorized_keys на VDS
ssh-keygen -t ed25519 -f smart-factoring-deploy -C smart-factoring-deploy -N ""

# отпечаток хоста для секрета VDS_KNOWN_HOSTS (сверить с ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub на VDS)
ssh-keyscan -t ed25519 <host>
```

## Настройка GitHub

### Доступ к образу

Образы лежат в пакетах репозиториев сервисов. Чтобы `GITHUB_TOKEN` этого репозитория мог их скачать,
для **каждого** пакета (`smart-factoring-backend`, `smart-factoring-gateway`):
github.com/Monbar921 → Packages → пакет → Package settings → **Manage Actions access** →
Add repository → `smart-factoring-deploy`, роль **Read**.

Пакет появляется после первой сборки образа в CI сервиса.

### Environments

Settings → Environments → создать `test` и `prod`. В каждом:

| Тип | Имя | Пример | Описание |
|---|---|---|---|
| Secret | `VDS_HOST` | `203.0.113.10` | адрес VDS |
| Secret | `VDS_USER` | `deploy` | пользователь в группе docker |
| Secret | `VDS_SSH_KEY` | `-----BEGIN OPENSSH PRIVATE KEY-----...` | приватный ключ `smart-factoring-deploy` |
| Secret | `VDS_KNOWN_HOSTS` | `203.0.113.10 ssh-ed25519 AAAA...` | вывод `ssh-keyscan` |
| Secret | `POSTGRES_PASSWORD` | | пароль БД, без одинарных кавычек |
| Variable | `VDS_DIR` | `/opt/smart-factoring/test` | каталог стенда, у каждого окружения свой |
| Variable | `BACKEND_PORT` | `8081` для test, `8080` для prod | порт на 127.0.0.1 VDS, необязательно, по умолчанию 8080 |
| Variable | `POSTGRES_PORT` | `5433` для test, `5432` для prod | порт на 127.0.0.1 VDS, необязательно |
| Variable | `BACKEND_CPUS` | `1` | лимит CPU backend, можно дробное (`0.5`), необязательно |
| Variable | `BACKEND_MEM_LIMIT` | `1g` | лимит памяти backend, куча JVM - 75% от него, необязательно |
| Variable | `GATEWAY_PORT` | `8091` для test, `8090` для prod | внешний порт gateway, необязательно, по умолчанию 8090 |
| Variable | `GATEWAY_CPUS` | `0.5` | лимит CPU gateway, необязательно |
| Variable | `GATEWAY_MEM_LIMIT` | `512m` | лимит памяти gateway, необязательно |
| Variable | `POSTGRES_CPUS` | `1` | лимит CPU postgres, необязательно |
| Variable | `POSTGRES_MEM_LIMIT` | `512m` | лимит памяти postgres, необязательно |

Если test и prod живут на одном VDS, `VDS_HOST`, `VDS_USER`, `VDS_SSH_KEY`, `VDS_KNOWN_HOSTS` можно завести один раз
в Settings → Secrets and variables → Actions → Repository secrets: секреты окружения их дополняют.
Порты и `VDS_DIR` у окружений на одном VDS должны различаться.

Для `prod` можно включить Required reviewers: деплой будет ждать подтверждения.

## Локальный запуск

```bash
cp .env.example .env
docker compose up -d
```

## Доступ к БД и backend на VDS

Postgres и backend слушают только `127.0.0.1` VDS:

```bash
ssh -L 5432:127.0.0.1:5432 -L 8080:127.0.0.1:8080 deploy@<host>
```

# smart-factoring-deploy

Раскатка smart-factoring на VDS через docker compose: общий `postgres` + стенды `test` и `prod` (`backend` + `gateway`).

```
                       стенд test (smart-factoring-test)              infra (smart-factoring-infra)
клиент ──▶ :GATEWAY_PORT gateway ──▶ backend:BACKEND_PORT ──┐
                                                            ├──▶ postgres:5432 ── 127.0.0.1:POSTGRES_PORT
клиент ──▶ :GATEWAY_PORT gateway ──▶ backend:BACKEND_PORT ──┘    (сеть smart-factoring-db)
                       стенд prod (smart-factoring-prod)
```

- Postgres один на все стенды, у каждого стенда в нём своя база и свой пользователь.
- Снаружи открыт только gateway. Backend доступен только внутри сети своего стенда и ходит в postgres через общую
  сеть `smart-factoring-db`. Postgres - ещё и на `127.0.0.1` VDS для IDE через ssh-туннель.
- Порты приложений передаются им как `SERVER_PORT`.

| Что | Compose | Workflow | Каталог на VDS | Настройки |
|---|---|---|---|---|
| общий postgres | [infra/docker-compose.yml](infra/docker-compose.yml) | [infra.yml](.github/workflows/infra.yml) | `VDS_INFRA_DIR` | уровня репозитория |
| стенд | [docker-compose.yml](docker-compose.yml) | [deploy.yml](.github/workflows/deploy.yml) | `VDS_DIR` | Environment `test`/`prod` |

## Как это работает

### Infra

Раскатывается при push в `main` с изменениями в `infra/` или вручную: Actions → Infra → Run workflow.
Создаёт сеть `smart-factoring-db` и volume `smart-factoring-postgres-data`. Стенды без неё не стартуют: deploy
проверяет сеть до любых изменений на VDS.

### Стенды

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

# ключ сервера для секрета VDS_KNOWN_HOSTS: на VDS, перед ключом дописать адрес VDS через пробел
cat /etc/ssh/ssh_host_ed25519_key.pub
```

## База и пользователь стенда

Создаются вручную один раз на стенд, под суперпользователем из `POSTGRES_USER_ADMIN`, после первой раскатки infra.
Значения - из переменных Environment стенда (`POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_SCHEMA`):

```bash
docker exec -it smart-factoring-infra-postgres-1 psql -U <POSTGRES_USER_ADMIN> -d public
```

```sql
create user smart_factoring_test with password '<POSTGRES_PASSWORD>';
create database smart_factoring_test owner smart_factoring_test;
\c smart_factoring_test
create schema smart_factoring_test authorization smart_factoring_test;
```

Пользователь - владелец своей базы и схемы: Liquibase backend создаёт в ней таблицы. Чужие базы ему недоступны:

```sql
revoke connect on database smart_factoring_test from public;
```

Пароли в репозиторий не коммитить - он публичный.

## Настройка GitHub

### Доступ к образу

Образы лежат в пакетах репозиториев сервисов. Чтобы `GITHUB_TOKEN` этого репозитория мог их скачать,
для **каждого** пакета (`smart-factoring-backend`, `smart-factoring-gateway`):
github.com/Monbar921 → Packages → пакет → Package settings → **Manage Actions access** →
Add repository → `smart-factoring-deploy`, роль **Read**. Либо пакет публичный.

Пакет появляется после первой сборки образа в CI сервиса.

### Уровень репозитория

Settings → Secrets and variables → Actions → Repository secrets / variables. Общие для infra и стендов:

| Тип | Имя | Пример | Описание |
|---|---|---|---|
| Secret | `VDS_HOST` | `203.0.113.10` | адрес VDS |
| Secret | `VDS_USER` | `deploy` | пользователь в группе docker |
| Secret | `VDS_SSH_KEY` | `-----BEGIN OPENSSH PRIVATE KEY-----...` | приватный ключ `smart-factoring-deploy` |
| Secret | `VDS_KNOWN_HOSTS` | `203.0.113.10 ssh-ed25519 AAAA...` | ключ сервера |
| Variable | `VDS_INFRA_DIR` | `/opt/smart-factoring/infra` | каталог infra на VDS |
| Variable | `POSTGRES_USER_ADMIN` | `postgres` | суперпользователь postgres |
| Secret | `POSTGRES_PASSWORD_ADMIN` | | его пароль, без одинарных кавычек |
| Variable | `POSTGRES_PORT` | `5432` | порт postgres на 127.0.0.1 VDS, необязательно |
| Variable | `POSTGRES_CPUS` | `1` | лимит CPU postgres, необязательно |
| Variable | `POSTGRES_MEM_LIMIT` | `512m` | лимит памяти postgres, необязательно |

`POSTGRES_USER_ADMIN` и `POSTGRES_PASSWORD_ADMIN` применяются только при первом запуске пустого volume.

### Environments

Settings → Environments → создать `test` и `prod`. В каждом:

| Тип | Имя | Пример | Описание |
|---|---|---|---|
| Variable | `VDS_DIR` | `/opt/smart-factoring/test` | каталог стенда, у каждого окружения свой |
| Variable | `POSTGRES_DB` | `smart_factoring_test` | база стенда в общем postgres |
| Variable | `POSTGRES_USER` | `smart_factoring_test` | пользователь стенда |
| Secret | `POSTGRES_PASSWORD` | | его пароль, без одинарных кавычек |
| Variable | `POSTGRES_SCHEMA` | `smart_factoring_test` | схема стенда |
| Variable | `GATEWAY_PORT` | `8091` для test, `8090` для prod | порт, который слушает gateway и который открыт на VDS, необязательно, по умолчанию 8090 |
| Variable | `BACKEND_PORT` | `8080` | порт, который слушает backend внутри сети стенда, необязательно, по умолчанию 8080 |
| Variable | `BACKEND_CPUS` | `1` | лимит CPU backend, можно дробное (`0.5`), необязательно |
| Variable | `BACKEND_MEM_LIMIT` | `1g` | лимит памяти backend, куча JVM - 75% от него, необязательно |
| Variable | `GATEWAY_CPUS` | `0.5` | лимит CPU gateway, необязательно |
| Variable | `GATEWAY_MEM_LIMIT` | `512m` | лимит памяти gateway, необязательно |

У окружений должны различаться `VDS_DIR`, `GATEWAY_PORT` и база/пользователь. `BACKEND_PORT` может совпадать:
у каждого стенда своя сеть.

Для `prod` можно включить Required reviewers: деплой будет ждать подтверждения.

## Локальный запуск

```bash
cp infra/.env.example infra/.env
docker compose -f infra/docker-compose.yml up -d --wait
# создать базу и пользователя стенда, см. выше
cp .env.example .env
docker compose up -d
```

## Доступ к БД на VDS

Postgres слушает только `127.0.0.1` VDS:

```bash
ssh -L 5432:127.0.0.1:5432 deploy@<host>
```

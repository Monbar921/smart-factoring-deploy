# smart-factoring-deploy

Раскатка smart-factoring на VDS через docker compose: `postgres` + `backend`.

## Как это работает

1. CI/CD [smart-factoring-backend](https://github.com/Monbar921/smart-factoring-backend) собирает образ
   `ghcr.io/monbar921/smart-factoring-backend:<short sha>` и шлёт сюда `repository_dispatch` (`event_type: deploy`).
2. [deploy.yml](.github/workflows/deploy.yml) выбирает окружение по ветке backend: `main` → `prod`, остальное → `test`.
3. По SSH кладёт на VDS в `VDS_DIR` файлы `docker-compose.yml` и `.env` (из секретов окружения),
   делает `docker compose pull` и `docker compose up -d --wait`: job зелёный, только если postgres и backend прошли healthcheck.

Ручной деплой или откат: Actions → Deploy → Run workflow, окружение + тег (short sha из истории backend).

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

Образ лежит в пакете репозитория backend. Чтобы `GITHUB_TOKEN` этого репозитория мог его скачать:
github.com/Monbar921 → Packages → smart-factoring-backend → Package settings → **Manage Actions access** →
Add repository → `smart-factoring-deploy`, роль **Read**.

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
| Variable | `BACKEND_PORT` | `8081` для test, `8080` для prod | необязательно, по умолчанию 8080 |
| Variable | `POSTGRES_PORT` | `5433` для test, `5432` для prod | порт на 127.0.0.1 VDS, необязательно |
| Variable | `BACKEND_MEM_LIMIT` | `1g` | необязательно |

Если test и prod живут на одном VDS, `VDS_HOST`, `VDS_USER`, `VDS_SSH_KEY`, `VDS_KNOWN_HOSTS` можно завести один раз
в Settings → Secrets and variables → Actions → Repository secrets: секреты окружения их дополняют.
Порты и `VDS_DIR` у окружений на одном VDS должны различаться.

Для `prod` можно включить Required reviewers: деплой будет ждать подтверждения.

## Локальный запуск

```bash
cp .env.example .env
docker compose up -d
```

## Доступ к БД на VDS

Postgres слушает только `127.0.0.1` VDS:

```bash
ssh -L 5432:127.0.0.1:5432 deploy@<host>
```

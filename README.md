# smart-factoring-deploy

Раскатка smart-factoring на VDS через docker compose: общие `postgres` и `keycloak` + стенды `test` и `prod`
(`backend` + `gateway` + `ui`).

```
                         стенд test (smart-factoring-test)                infra (smart-factoring-infra)
клиент ─Bearer─▶ :GATEWAY_PORT gateway ──▶ backend:BACKEND_PORT ──┐
                                 │                                 ├──▶ postgres:5432 ── 127.0.0.1:POSTGRES_PORT
клиент ─Bearer─▶ :GATEWAY_PORT gateway ──▶ backend:BACKEND_PORT ──┘    (сеть smart-factoring-db)
                         стенд prod│(smart-factoring-prod)                  ▲ база keycloak
                                   └── ключи подписи ─────────────▶ keycloak:8080 ── :KEYCLOAK_PORT (логин в браузере)
                                       (сеть smart-factoring-auth)
```

- Postgres и keycloak одни на все стенды. У каждого стенда в postgres своя база и пользователь, в keycloak - свой realm.
- Снаружи открыты ui, gateway и страница логина keycloak. UI - nginx: отдаёт статику и проксирует `/api` в gateway
  своего стенда, браузер ходит в API с того же origin, что и UI (без CORS). Пользователь входит на странице keycloak,
  UI получает его токен (Authorization Code + PKCE) и шлёт его в gateway. Backend доступен только внутри сети своего стенда.
  Postgres - ещё и на `127.0.0.1` VDS для IDE через ssh-туннель.
- Пользователя проверяет gateway: подпись токена по ключам realm, issuer, срок действия. Без действующего токена -
  401, до backend запрос не доходит. Backend получает тот же заголовок `Authorization` и только читает payload.
- Порты приложений передаются им как `SERVER_PORT`.

| Что | Compose | Workflow | Каталог на VDS | Настройки |
|---|---|---|---|---|
| общие postgres и keycloak | [infra/docker-compose.yml](infra/docker-compose.yml) | [infra.yml](.github/workflows/infra.yml) | `VDS_INFRA_DIR` | репозиторий + Environment `test` |
| стенд | [docker-compose.yml](docker-compose.yml) | [deploy.yml](.github/workflows/deploy.yml) | `VDS_DIR` | Environment `test`/`prod` |

## Как это работает

### Infra

Раскатывается при push в `main` с изменениями в `infra/` или вручную: Actions → Infra → Run workflow.

1. Поднимает postgres. Создаёт сеть `smart-factoring-db` и volume `smart-factoring-postgres-data`.
2. Создаёт в нём базу `keycloak` и её владельца `KEYCLOAK_DB_USER` ([init-db.sql](infra/keycloak/init-db.sql)),
   если их нет, и выставляет пароль из `KEYCLOAK_DB_PASSWORD`. Повторный запуск ничего не ломает.
3. Поднимает keycloak (сеть `smart-factoring-auth`). Первый старт - около минуты.

Стенды без сетей infra не стартуют: deploy проверяет их до любых изменений на VDS.

### Стенды

1. CI/CD [smart-factoring-backend](https://github.com/Monbar921/smart-factoring-backend),
   [smart-factoring-gateway](https://github.com/Monbar921/smart-factoring-gateway) и
   [smart-factoring-ui](https://github.com/Monbar921/smart-factoring-ui) собирают образ
   `ghcr.io/monbar921/smart-factoring-<сервис>:<short sha>` и шлют сюда `repository_dispatch` (`event_type: deploy`).
2. [deploy.yml](.github/workflows/deploy.yml) выбирает окружение по ветке сервиса: `main` → `prod`, остальное → `test`.
3. Обновляется тег только пришедшего сервиса. Теги остальных берутся из текущего `.env` на VDS, а если стенд ещё
   пустой (или сервис в нём новый) - тег ветки окружения (`test` или `main`), который CI сервиса ставит при каждой сборке.
4. По SSH кладёт на VDS в `VDS_DIR` файлы `docker-compose.yml`, `.env` (из секретов окружения) и каталог `certs`,
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

## Keycloak

### Realm

Realm-файлы - [infra/keycloak/realms](infra/keycloak/realms), сейчас только
[smart-factoring-test](infra/keycloak/realms/smart-factoring-test-realm.json):

- роль `user` и тестовый пользователь `KEYCLOAK_TEST_USER` с паролем `KEYCLOAK_TEST_USER_PASSWORD` и этой ролью;
- клиент `smart-factoring-swagger`: публичный, Authorization Code + PKCE для кнопки Authorize в Swagger UI
  (redirect - `KEYCLOAK_TEST_GATEWAY_URL/swagger-ui/oauth2-redirect.html`) и password grant для curl;
- клиент `smart-factoring-ui`: публичный, Authorization Code + PKCE для входа в UI (redirect - `KEYCLOAK_TEST_UI_URL/*`,
  а также `http://localhost:5173/*` для `npm run dev` против стенда test);
- `sslRequired: none`: стенд по HTTP. Для prod - только с HTTPS.

**Realm импортируется, только если его ещё нет.** Правки realm-файла, логина или пароля тестового пользователя
после первого импорта не применяются: менять в админке или удалить realm в админке и перезапустить Infra.

Realm для prod (`smart-factoring-prod`) пока нет: стенд prod без него не пустит ни одного запроса.

#### Клиент UI в уже импортированном realm

Клиент `smart-factoring-ui` добавлен в realm-файл после первого импорта - на VDS его нужно создать в админке один раз:
realm `smart-factoring-test` → Clients → **Create client**:

1. Client type `OpenID Connect`, Client ID `smart-factoring-ui` → Next.
2. Client authentication **Off** (публичный), Authentication flow - только **Standard flow** → Next.
3. Root URL и Home URL - адрес UI test (`http://<VDS>:<UI_PORT>`), Valid redirect URIs - `http://<VDS>:<UI_PORT>/*`,
   `http://localhost:5173/*`, `http://127.0.0.1:5173/*`; Valid post logout redirect URIs и Web origins - `+` → Save.
4. Вкладка Advanced → Proof Key for Code Exchange Code Challenge Method - `S256` → Save.

### Токен

В Swagger UI gateway: **Authorize** → логин в keycloak → токен подставляется во все запросы.

Из консоли:

```bash
curl -s -d grant_type=password -d client_id=smart-factoring-swagger -d username=<KEYCLOAK_TEST_USER> \
  -d password=<KEYCLOAK_TEST_USER_PASSWORD> <KEYCLOAK_PUBLIC_URL>/realms/smart-factoring-test/protocol/openid-connect/token
curl -H "Authorization: Bearer <access_token>" http://<VDS>:<GATEWAY_PORT>/api/backend/maintenance/whoami
```

### Админка

Из интернета по HTTP админка не откроется (master realm требует HTTPS для внешних адресов), только через туннель:

```bash
ssh -L 8180:127.0.0.1:<KEYCLOAK_PORT> deploy@<host>
```

Затем http://localhost:8180/admin, логин `KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD`. Администратор создаётся
только при первом старте keycloak на пустой базе.

## GigaChat

Backend получает тексты карточек от GigaChat API при `LLM_MODE=gigachat` (переменная окружения стенда) и ключе
`GIGACHAT_AUTH_KEY` (секрет). Без ключа deploy с `LLM_MODE=gigachat` останавливается до изменений на VDS.

Сертификаты серверов GigaChat выданы НУЦ Минцифры, которого нет в JDK. Корневой «Russian Trusted Root CA»
и выпускающие «Russian Trusted Sub CA», «Russian Trusted Sub CA 2024» (с портала Госуслуг) лежат одним PEM в
[certs/russian_trusted_root_ca.pem](certs/russian_trusted_root_ca.pem): deploy копирует `certs` на VDS, backend
монтирует его в `/certs` (`GIGACHAT_CA_CERT`). Сертификаты публичные, секретом не являются. Обновить - пересобрать файл:

```bash
for f in "Russian Trusted Root CA.cer" "Russian Trusted Sub CA.cer" "Russian Trusted Sub CA 2024.cer"; do
  openssl x509 -inform DER -in "$f" 2>/dev/null || openssl x509 -inform PEM -in "$f"
done > certs/russian_trusted_root_ca.pem
```

## Настройка GitHub

### Доступ к образу

Образы лежат в пакетах репозиториев сервисов. Чтобы `GITHUB_TOKEN` этого репозитория мог их скачать,
для **каждого** пакета (`smart-factoring-backend`, `smart-factoring-gateway`, `smart-factoring-ui`):
github.com/Monbar921 → Packages → пакет → Package settings → **Manage Actions access** →
Add repository → `smart-factoring-deploy`, роль **Read**. Либо пакет публичный.

Пакет появляется после первой сборки образа в CI сервиса.

### Уровень репозитория

Settings → Secrets and variables → Actions → Repository secrets / variables. Общие для infra и стендов:

| Тип | Имя | Пример | Описание |
|---|---|---|---|
| Variable | `VDS_HOST` | `203.0.113.10` | адрес VDS |
| Variable | `VDS_USER` | `deploy` | пользователь в группе docker |
| Secret | `VDS_SSH_KEY` | `-----BEGIN OPENSSH PRIVATE KEY-----...` | приватный ключ `smart-factoring-deploy` |
| Secret | `VDS_KNOWN_HOSTS` | `203.0.113.10 ssh-ed25519 AAAA...` | ключ сервера |
| Secret | `POSTGRES_PASSWORD_ADMIN` | | пароль суперпользователя postgres, без одинарных кавычек |

### Environments

Settings → Environments → создать `test` и `prod`. В каждом:

| Тип | Имя | Пример | Описание |
|---|---|---|---|
| Variable | `VDS_DIR` | `/home/deploy/smart-factoring/test` | каталог стенда, у каждого окружения свой |
| Variable | `COMPOSE_PROJECT_NAME` | `smart-factoring-test` | имя compose-проекта стенда, необязательно, по умолчанию `smart-factoring-<окружение>` |
| Variable | `POSTGRES_DB` | `smart_factoring_test` | база стенда в общем postgres |
| Variable | `POSTGRES_USER` | `smart_factoring_app` | пользователь стенда |
| Secret | `POSTGRES_PASSWORD` | | его пароль, без одинарных кавычек |
| Variable | `POSTGRES_SCHEMA` | `smart_factoring_test` | схема стенда |
| Variable | `POSTGRES_POOL` | `smart_factoring_backend_test` | имя пула Hikari, необязательно |
| Variable | `GATEWAY_PORT` | `8091` для test, `8090` для prod | порт, который слушает gateway и который открыт на VDS, необязательно, по умолчанию 8090 |
| Variable | `BACKEND_PORT` | `8080` | порт, который слушает backend внутри сети стенда, необязательно, по умолчанию 8080 |
| Variable | `BACKEND_CPUS` | `1` | лимит CPU backend, можно дробное (`0.5`), необязательно |
| Variable | `BACKEND_MEM_LIMIT` | `1g` | лимит памяти backend, куча JVM - 75% от него, необязательно |
| Variable | `GATEWAY_CPUS` | `0.5` | лимит CPU gateway, необязательно |
| Variable | `GATEWAY_MEM_LIMIT` | `512m` | лимит памяти gateway, необязательно |
| Variable | `UI_PORT` | `8071` для test, `8070` для prod | порт nginx UI, открыт на VDS, необязательно, по умолчанию 8070 |
| Variable | `UI_CPUS` | `0.25` | лимит CPU ui, необязательно |
| Variable | `UI_MEM_LIMIT` | `128m` | лимит памяти ui, необязательно |
| Variable | `KEYCLOAK_UI_CLIENT_ID` | `smart-factoring-ui` | клиент UI в realm стенда, необязательно, по умолчанию `smart-factoring-ui` |
| Variable | `KEYCLOAK_REALM` | `smart-factoring-test` | realm стенда, необязательно, по умолчанию `smart-factoring-<окружение>` |
| Variable | `LLM_MODE` | `gigachat` | LLM backend: `stub` - шаблонные тексты (по умолчанию), `gigachat` - GigaChat API, `off` - без черновика |
| Secret | `GIGACHAT_AUTH_KEY` | | ключ авторизации GigaChat API из личного кабинета (Base64), обязателен при `LLM_MODE=gigachat` |
| Variable | `GIGACHAT_MODEL` | `GigaChat` | модель GigaChat: `GigaChat` (Lite, по умолчанию), `GigaChat-2-Pro`, `GigaChat-2-Max`, `GigaChat-3-Ultra`; доступные тарифу - `GET https://api.giga.chat/v1/models`, необязательно |
| Variable | `LLM_PARALLELISM` | `1` | одновременных запросов к GigaChat, не больше лимита тарифа (Freemium - 1), необязательно, по умолчанию 8 |
| Variable | `GIGACHAT_SCOPE` | `GIGACHAT_API_PERS` | тариф GigaChat: `GIGACHAT_API_PERS`, `GIGACHAT_API_B2B` или `GIGACHAT_API_CORP`, необязательно |

Только в `test` - настройки общих postgres и keycloak (workflow Infra запускается в окружении `test`):

| Тип | Имя | Пример | Описание |
|---|---|---|---|
| Variable | `POSTGRES_USER_ADMIN` | `smart_factoring` | суперпользователь postgres |
| Variable | `VDS_INFRA_DIR` | `/home/deploy/smart-factoring/infra` | каталог infra на VDS, необязательно, по умолчанию `infra` рядом с `VDS_DIR` |
| Variable | `POSTGRES_PORT` | `5432` | порт postgres на 127.0.0.1 VDS, необязательно |
| Variable | `POSTGRES_CPUS` | `1` | лимит CPU postgres, необязательно |
| Variable | `POSTGRES_MEM_LIMIT` | `512m` | лимит памяти postgres, необязательно |
| Variable | `KEYCLOAK_ADMIN` | `admin` | администратор keycloak (master realm) |
| Secret | `KEYCLOAK_ADMIN_PASSWORD` | | его пароль |
| Variable | `KEYCLOAK_DB_USER` | `keycloak` | пользователь keycloak в postgres, владелец базы `keycloak`: строчная латиница, цифры, `_`. После первой раскатки не менять |
| Secret | `KEYCLOAK_DB_PASSWORD` | | его пароль |
| Variable | `KEYCLOAK_TEST_USER` | `tester` | пользователь realm `smart-factoring-test`: латиница, цифры, `. _ -` |
| Secret | `KEYCLOAK_TEST_USER_PASSWORD` | | его пароль |
| Variable | `KEYCLOAK_PORT` | `8180` | публичный порт keycloak, необязательно, по умолчанию 8180 |
| Variable | `KEYCLOAK_PUBLIC_URL` | `http://203.0.113.10:8180` | адрес keycloak для браузера и `iss` токенов, необязательно, по умолчанию `http://VDS_HOST:KEYCLOAK_PORT` |
| Variable | `KEYCLOAK_TEST_GATEWAY_URL` | `http://203.0.113.10:8091` | адрес gateway test для redirect Swagger UI, необязательно, по умолчанию `http://VDS_HOST:GATEWAY_PORT` |
| Variable | `KEYCLOAK_TEST_UI_URL` | `http://203.0.113.10:8071` | адрес UI test для redirect после входа, необязательно, по умолчанию `http://VDS_HOST:UI_PORT` |
| Variable | `KEYCLOAK_CPUS` | `1` | лимит CPU keycloak, необязательно |
| Variable | `KEYCLOAK_MEM_LIMIT` | `1g` | лимит памяти keycloak, необязательно |

`POSTGRES_USER_ADMIN` и `POSTGRES_PASSWORD_ADMIN` применяются только при первом запуске пустого volume.
Пароли - без кавычек и обратной косой черты: они подставляются в `.env` и realm-файл, Infra это проверяет.

`KEYCLOAK_PUBLIC_URL` (если задан) нужен и в `prod`: из него gateway стенда собирает issuer.

У окружений должны различаться `VDS_DIR`, `GATEWAY_PORT`, `UI_PORT` и база/пользователь. `BACKEND_PORT` может совпадать:
у каждого стенда своя сеть.

Для `prod` можно включить Required reviewers: деплой будет ждать подтверждения. Для `test` - не включать:
под ним же идёт Infra.

## Локальный запуск

```bash
cp infra/.env.example infra/.env
docker compose -f infra/docker-compose.yml up -d --wait postgres
# база keycloak, как в workflow Infra
(set -a; . infra/.env; set +a; docker compose -f infra/docker-compose.yml exec -T postgres \
  psql -U "$POSTGRES_USER_ADMIN" -d postgres -v ON_ERROR_STOP=1 -v user="$KEYCLOAK_DB_USER" -v pw="$KEYCLOAK_DB_PASSWORD" < infra/keycloak/init-db.sql)
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

-- База keycloak и её пользователь KEYCLOAK_DB_USER в общем postgres. Выполняется workflow infra.yml
-- под администратором postgres перед каждым стартом keycloak, поэтому повторный запуск ничего не ломает:
--   psql -v ON_ERROR_STOP=1 -v user="$KEYCLOAK_DB_USER" -v pw="$KEYCLOAK_DB_PASSWORD" -d postgres < init-db.sql
-- Имя и пароль передаются переменными psql и подставляются через %I (идентификатор) и %L (литерал).

-- KEYCLOAK_DB_USER сменили после первой раскатки: таблицы keycloak принадлежат прежнему пользователю,
-- под новым keycloak к ним не получит доступа. Останавливаемся с понятной ошибкой вместо поломки keycloak
SELECT format('DO $check$ BEGIN RAISE EXCEPTION %L; END $check$',
              format('База keycloak принадлежит %s, а KEYCLOAK_DB_USER = %s. Верните прежнее имя '
                         || 'или перенесите владение вручную: REASSIGN OWNED BY %s TO %s в базе keycloak',
                     pg_get_userbyid(datdba), :'user', pg_get_userbyid(datdba), :'user'))
FROM pg_database
WHERE datname = 'keycloak' AND pg_get_userbyid(datdba) <> :'user'
\gexec

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'user', :'pw')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'user')
\gexec

-- пароль всегда как в секрете KEYCLOAK_DB_PASSWORD: сменили секрет - сменился и пароль
SELECT format('ALTER ROLE %I PASSWORD %L', :'user', :'pw')
\gexec

SELECT format('CREATE DATABASE keycloak OWNER %I', :'user')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'keycloak')
\gexec

-- к базе keycloak подключается только её владелец (и администратор)
REVOKE CONNECT ON DATABASE keycloak FROM PUBLIC;

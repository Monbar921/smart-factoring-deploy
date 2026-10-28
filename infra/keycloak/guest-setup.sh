#!/bin/sh
# Гостевой вход «Запуск демо» (замечания 28.10): роли operator и manager, конфиденциальный клиент для gateway
# и демо-пользователь с обеими ролями в realm стенда. Повторный запуск ничего не дублирует: секрет клиента и пароль
# пользователя обновляются.
#
# Запуск на VDS в каталоге infra (рядом с infra/docker-compose.yml):
#   KEYCLOAK_ADMIN=admin KEYCLOAK_ADMIN_PASSWORD=... REALM=smart-factoring-test \
#   GUEST_CLIENT_SECRET=... GUEST_PASSWORD=... sh keycloak/guest-setup.sh
# Те же GUEST_CLIENT_SECRET и GUEST_PASSWORD - в секретах окружения GitHub (deploy.yml), GUEST_ENABLED=true - в переменных.
set -eu

: "${KEYCLOAK_ADMIN:?KEYCLOAK_ADMIN is required}"
: "${KEYCLOAK_ADMIN_PASSWORD:?KEYCLOAK_ADMIN_PASSWORD is required}"
: "${REALM:?REALM is required, например smart-factoring-test}"
: "${GUEST_CLIENT_SECRET:?GUEST_CLIENT_SECRET is required}"
: "${GUEST_PASSWORD:?GUEST_PASSWORD is required}"
GUEST_CLIENT_ID="${GUEST_CLIENT_ID:-smart-factoring-guest}"
GUEST_USERNAME="${GUEST_USERNAME:-demo}"
GUEST_EMAIL="${GUEST_EMAIL:-${GUEST_USERNAME}@smart-factoring.local}"

kcadm() {
  docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh "$@"
}

kcadm config credentials --server http://localhost:8080 --realm master --user "$KEYCLOAK_ADMIN" --password "$KEYCLOAK_ADMIN_PASSWORD" >/dev/null

# роли, которые проверяет gateway (realm_access.roles)
for role in operator manager; do
  if ! kcadm get "roles/$role" -r "$REALM" >/dev/null 2>&1; then
    kcadm create roles -r "$REALM" -s name="$role" >/dev/null
    echo "роль $role создана"
  fi
done

# клиент только для gateway: без входа через браузер, токен по логину и паролю демо-пользователя (Direct Access Grants)
client_uuid="$(kcadm get clients -r "$REALM" -q clientId="$GUEST_CLIENT_ID" --fields id --format csv --noquotes | head -n 1)"
if [ -z "$client_uuid" ]; then
  kcadm create clients -r "$REALM" \
    -s clientId="$GUEST_CLIENT_ID" -s enabled=true -s publicClient=false -s secret="$GUEST_CLIENT_SECRET" \
    -s standardFlowEnabled=false -s implicitFlowEnabled=false -s directAccessGrantsEnabled=true \
    -s serviceAccountsEnabled=false -s 'description=Гостевой вход «Запуск демо»: токен выдаёт gateway' >/dev/null
  echo "клиент $GUEST_CLIENT_ID создан"
else
  kcadm update "clients/$client_uuid" -r "$REALM" -s secret="$GUEST_CLIENT_SECRET" -s directAccessGrantsEnabled=true >/dev/null
  echo "клиент $GUEST_CLIENT_ID обновлён"
fi

# демо-пользователь: все права оператора и менеджера (решение 28.10 - приложение проверяет комиссия)
# email обязателен в профиле пользователя Keycloak 26: без него токен не выдаётся («Account is not fully set up»)
user_uuid="$(kcadm get users -r "$REALM" -q username="$GUEST_USERNAME" -q exact=true --fields id --format csv --noquotes | head -n 1)"
if [ -z "$user_uuid" ]; then
  kcadm create users -r "$REALM" -s username="$GUEST_USERNAME" -s enabled=true -s email="$GUEST_EMAIL" -s emailVerified=true \
    -s firstName=Гость -s lastName=Демо >/dev/null
  echo "пользователь $GUEST_USERNAME создан"
else
  kcadm update "users/$user_uuid" -r "$REALM" -s enabled=true -s email="$GUEST_EMAIL" -s emailVerified=true \
    -s firstName=Гость -s lastName=Демо >/dev/null
fi
kcadm set-password -r "$REALM" --username "$GUEST_USERNAME" --new-password "$GUEST_PASSWORD" >/dev/null
kcadm add-roles -r "$REALM" --uusername "$GUEST_USERNAME" --rolename operator --rolename manager >/dev/null
echo "пользователь $GUEST_USERNAME: пароль задан, роли operator и manager"

#!/bin/sh
# Перевод realm стенда на HTTPS (smart-factoring-backend docs/roadmap.md, п. 1.1-5): адреса UI и Swagger UI за TLS-прокси
# в redirect URI клиентов и sslRequired=external (Keycloak требует https для всех адресов, кроме локальных и частных).
# Нужен один раз для realm, импортированного до TLS: в новый realm https-адреса попадают из realm-файла сами.
# Прежние http-адреса остаются в redirect URI на время перехода (OLD_UI_URL, OLD_GATEWAY_URL), удалить - перезапуском без них.
#
# Запуск на VDS в каталоге infra после выката infra с TLS_DOMAIN:
#   set -a; . ./.env; set +a
#   REALM=smart-factoring-test OLD_UI_URL=http://<VDS>:8070 OLD_GATEWAY_URL=http://<VDS>:8090 sh keycloak/https-setup.sh
set -eu

: "${KEYCLOAK_ADMIN:?KEYCLOAK_ADMIN is required}"
: "${KEYCLOAK_ADMIN_PASSWORD:?KEYCLOAK_ADMIN_PASSWORD is required}"
: "${REALM:?REALM is required, например smart-factoring-test}"
: "${TLS_DOMAIN:?TLS_DOMAIN is required: домен прокси, как в переменной Infra}"
UI_URL="https://app.${TLS_DOMAIN}"
GATEWAY_URL="https://api.${TLS_DOMAIN}"
UI_CLIENT_ID="${UI_CLIENT_ID:-smart-factoring-ui}"
SWAGGER_CLIENT_ID="${SWAGGER_CLIENT_ID:-smart-factoring-swagger}"

# проект compose - из name: в infra/docker-compose.yml, а не из COMPOSE_PROJECT_NAME стенда (см. guest-setup.sh)
kcadm() {
  env -u COMPOSE_PROJECT_NAME docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh "$@"
}

client_uuid() {
  kcadm get clients -r "$REALM" -q clientId="$1" --fields id --format csv --noquotes | head -n 1
}

# JSON-массив строк: аргументы без пустых
json_list() {
  printf '['
  sep=''
  for item in "$@"; do
    [ -n "$item" ] || continue
    printf '%s"%s"' "$sep" "$item"
    sep=','
  done
  printf ']'
}

kcadm config credentials --server http://localhost:8080 --realm master --user "$KEYCLOAK_ADMIN" --password "$KEYCLOAK_ADMIN_PASSWORD" >/dev/null

ui="$(client_uuid "$UI_CLIENT_ID")"
[ -n "$ui" ] || { echo "нет клиента $UI_CLIENT_ID в realm $REALM" >&2; exit 1; }
kcadm update "clients/$ui" -r "$REALM" \
  -s "rootUrl=$UI_URL" \
  -s "redirectUris=$(json_list "$UI_URL/*" "${OLD_UI_URL:+$OLD_UI_URL/*}" 'http://localhost:5173/*' 'http://127.0.0.1:5173/*')" \
  -s 'webOrigins=["+"]' >/dev/null
echo "клиент $UI_CLIENT_ID: $UI_URL"

swagger="$(client_uuid "$SWAGGER_CLIENT_ID")"
if [ -n "$swagger" ]; then
  kcadm update "clients/$swagger" -r "$REALM" \
    -s "redirectUris=$(json_list "$GATEWAY_URL/swagger-ui/oauth2-redirect.html" "${OLD_GATEWAY_URL:+$OLD_GATEWAY_URL/swagger-ui/oauth2-redirect.html}")" \
    -s 'webOrigins=["+"]' >/dev/null
  echo "клиент $SWAGGER_CLIENT_ID: $GATEWAY_URL"
fi

# external: https обязателен для всех адресов, кроме localhost и частных сетей - ssh-туннель в админку продолжает работать
kcadm update "realms/$REALM" -s sslRequired=external >/dev/null
echo "realm $REALM: sslRequired=external"

#!/bin/sh
# Чей менеджер пользователь (smart-factoring-backend Р-75, Р-90): коды менеджеров из managers.csv хранятся в Keycloak
# атрибутом пользователя manager_code (несколько значений - несколько менеджеров), mapper кладёт их в access token
# claim manager_codes, backend по нему фильтрует CRM и экран процесса. Привязка - часть учётной записи, а не данных
# backend и не переменных деплоя; на пилоте её отдаёт IAM банка (тот же claim или mapper из атрибута LDAP/AD).
#
# Что делает скрипт (повторный запуск ничего не дублирует):
#   - объявляет атрибут manager_code в профиле пользователя realm (Keycloak 26 не хранит необъявленные атрибуты):
#     несколько значений, видит и меняет только администратор - сам себе пользователь менеджеров не назначит;
#   - добавляет mapper manager-codes клиентам, чьи токены приходят в backend (CLIENTS).
# В новом realm mapper уже есть из realm-файла, атрибут профиля - только этим скриптом.
#
# Запуск на VDS в каталоге infra (рядом с infra/docker-compose.yml):
#   set -a; . ./.env; set +a
#   REALM=smart-factoring-test sh keycloak/manager-setup.sh
# Код менеджера пользователю: админка → Users → пользователь → Details → «Коды менеджеров» (или kcadm, см. README).
set -eu

: "${KEYCLOAK_ADMIN:?KEYCLOAK_ADMIN is required}"
: "${KEYCLOAK_ADMIN_PASSWORD:?KEYCLOAK_ADMIN_PASSWORD is required}"
: "${REALM:?REALM is required, например smart-factoring-test}"
# клиенты, через которые пользователь входит в UI и Swagger; гостевому не нужен - гость видит всех
CLIENTS="${CLIENTS:-smart-factoring-ui smart-factoring-swagger}"
ATTRIBUTE=manager_code
CLAIM=manager_codes
MAPPER=manager-codes

# проект compose - из name: в infra/docker-compose.yml, а не из COMPOSE_PROJECT_NAME стенда (см. guest-setup.sh)
kcadm() {
  env -u COMPOSE_PROJECT_NAME docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh "$@"
}

kcadm config credentials --server http://localhost:8080 --realm master --user "$KEYCLOAK_ADMIN" --password "$KEYCLOAK_ADMIN_PASSWORD" >/dev/null

# атрибут профиля: вставляется первым в список attributes, остальной профиль не меняется
profile="$(kcadm get users/profile -r "$REALM")"
if printf '%s' "$profile" | grep -q "\"name\" *: *\"$ATTRIBUTE\""; then
  echo "атрибут $ATTRIBUTE уже объявлен"
else
  attribute='{"name":"'"$ATTRIBUTE"'","displayName":"Коды менеджеров (managers.csv)","multivalued":true,'
  attribute="$attribute"'"permissions":{"view":["admin"],"edit":["admin"]},'
  attribute="$attribute"'"validations":{"pattern":{"pattern":"^[A-Za-z0-9_-]+$","error-message":"код менеджера: латиница, цифры, _ и -"}}}'
  printf '%s' "$profile" | sed "0,/\"attributes\" *: *\[/s//&$attribute,/" | kcadm update users/profile -r "$REALM" -f - >/dev/null
  echo "атрибут $ATTRIBUTE объявлен в профиле пользователя"
fi

for client in $CLIENTS; do
  client_uuid="$(kcadm get clients -r "$REALM" -q clientId="$client" --fields id --format csv --noquotes | head -n 1)"
  if [ -z "$client_uuid" ]; then
    echo "клиента $client нет - пропущен"
    continue
  fi
  if kcadm get "clients/$client_uuid/protocol-mappers/models" -r "$REALM" --fields name --format csv --noquotes | grep -qx "$MAPPER"; then
    echo "$client: mapper $MAPPER уже есть"
    continue
  fi
  kcadm create "clients/$client_uuid/protocol-mappers/models" -r "$REALM" \
    -s name="$MAPPER" -s protocol=openid-connect -s protocolMapper=oidc-usermodel-attribute-mapper \
    -s 'config."user.attribute"='"$ATTRIBUTE" -s 'config."claim.name"='"$CLAIM" -s 'config."jsonType.label"=String' \
    -s 'config.multivalued=true' -s 'config."access.token.claim"=true' -s 'config."id.token.claim"=false' \
    -s 'config."userinfo.token.claim"=false' -s 'config."introspection.token.claim"=true' >/dev/null
  echo "$client: mapper $MAPPER добавлен (claim $CLAIM)"
done

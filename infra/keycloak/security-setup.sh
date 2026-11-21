#!/bin/sh
# Пароли и второй фактор (smart-factoring-backend docs/roadmap.md, п. 1.1а-34; docs/security.md, «Пароли и второй фактор»):
#   - политика паролей в realm стенда и в master: длина, буквы разного регистра, цифры, не совпадает с логином и почтой,
#     не повторяет последние пароли;
#   - обязательный одноразовый код (OTP, приложение-аутентификатор) при входе через браузер для ролей operator и
#     supervisor в realm стенда и для администраторов master (админка Keycloak). Код ещё не настроен - Keycloak при
#     следующем входе сам попросит отсканировать QR-код.
# Как устроено: копия стандартного browser flow, в которой условие «пользователь уже настроил OTP» заменено условием
# «у пользователя есть роль»; в realm стенда это роль otp-required, она входит в operator и supervisor (составные роли),
# поэтому новые пользователи с этими ролями получают OTP без ручной настройки.
# Не затрагивает вход по паролю без браузера (direct grant): гостевой вход «Запуск демо» (gateway) и kcadm работают
# как раньше. Админка Keycloak снаружи всё равно закрыта (Р-78), вход в неё - через SSH-туннель и теперь с OTP.
#
# Существующие пароли политика не перепроверяет: слабые пароли тестовых и демо-учёток смените после запуска
# (README, «Пароли и второй фактор»). guest-setup.sh после этого скрипта примет только GUEST_PASSWORD по политике.
#
# Запуск на VDS в каталоге infra (рядом с infra/docker-compose.yml); повторный запуск ничего не дублирует:
#   set -a; . ./.env; set +a
#   REALM=smart-factoring-test sh keycloak/security-setup.sh
set -eu

: "${KEYCLOAK_ADMIN:?KEYCLOAK_ADMIN is required}"
: "${KEYCLOAK_ADMIN_PASSWORD:?KEYCLOAK_ADMIN_PASSWORD is required}"
: "${REALM:?REALM is required, например smart-factoring-test}"
# синтаксис Keycloak: политики через «and»; hashIterations не задаём - остаётся значение Keycloak по умолчанию
PASSWORD_POLICY="${PASSWORD_POLICY:-length(12) and upperCase(1) and lowerCase(1) and digits(1) and notUsername and notEmail and passwordHistory(3)}"
# роли realm стенда, которым нужен OTP; пусто - OTP в realm стенда не включается
OTP_ROLES="${OTP_ROLES:-operator supervisor}"
# false - не трогать master (например, если вход в админку уже защищён иначе)
MASTER_OTP="${MASTER_OTP:-true}"
OTP_ROLE=otp-required
FLOW=browser-otp-by-role

# проект compose - из name: в infra/docker-compose.yml, а не из COMPOSE_PROJECT_NAME стенда (см. guest-setup.sh)
kcadm() {
  env -u COMPOSE_PROJECT_NAME docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh "$@"
}

# id первой строки CSV-вывода kcadm, пусто - нет
first_id() {
  head -n 1 | tr -d '\r'
}

# Копия browser flow с OTP по роли и привязка её к realm как browser flow.
#   $1 - realm, $2 - роль, наличие которой требует OTP
# В копии стандартного flow (Keycloak 26) подпоток «... Browser - Conditional 2FA»: условия «OTP настроен» и
# «вход не по passkey», форма кода (ALTERNATIVE). Условие «OTP настроен» меняется на «есть роль», форма кода -
# REQUIRED: без настроенного OTP Keycloak сам попросит его настроить.
require_otp_by_role() {
  realm="$1"
  role="$2"
  if ! kcadm get "authentication/flows" -r "$realm" --fields alias --format csv --noquotes | tr -d '' | grep -qx "$FLOW"; then
    flow_id="$(kcadm create "authentication/flows/browser/copy" -r "$realm" -s newName="$FLOW" -i | tr -d '')"
    # строки уровня 2 с именем подпотока уровня 1 впереди: подпоток,id,providerId
    rows="$(kcadm get "authentication/flows/$FLOW/executions" -r "$realm" --format csv --noquotes       --fields id,providerId,displayName,level | tr -d ''       | awk -F, '$4 == 1 { flow = ($2 == "" ? $3 : "") } $4 == 2 { print flow "," $1 "," $2 }')"
    otp_flow="$(printf '%s
' "$rows" | awk -F, '$3 == "auth-otp-form" { print $1; exit }')"
    otp_id="$(printf '%s
' "$rows" | awk -F, '$3 == "auth-otp-form" { print $2; exit }')"
    configured_id="$(printf '%s
' "$rows" | awk -F, -v f="$otp_flow" '$1 == f && $3 == "conditional-user-configured" { print $2; exit }')"
    if [ -z "$otp_flow" ] || [ -z "$otp_id" ] || [ -z "$configured_id" ]; then
      kcadm delete "authentication/flows/$flow_id" -r "$realm"
      echo "realm $realm: в копии browser flow не найден подпоток с формой OTP и условием «OTP настроен» - другая"         "версия Keycloak? Копия удалена, настройте вручную" >&2
      exit 1
    fi
    kcadm delete "authentication/executions/$configured_id" -r "$realm"
    role_id="$(kcadm create "authentication/flows/$(urlencode "$otp_flow")/executions/execution" -r "$realm"       -s provider=conditional-user-role -i | tr -d '')"
    kcadm update "authentication/flows/$FLOW/executions" -r "$realm" -b "{\"id\":\"$role_id\",\"requirement\":\"REQUIRED\"}"
    kcadm update "authentication/flows/$FLOW/executions" -r "$realm" -b "{\"id\":\"$otp_id\",\"requirement\":\"REQUIRED\"}"
    kcadm create "authentication/executions/$role_id/config" -r "$realm"       -b "{\"alias\":\"otp-by-role-$realm\",\"config\":{\"condUserRole\":\"$role\",\"negate\":\"false\"}}" >/dev/null
    # условие - первым в подпотоке (на результат не влияет, но так flow читается в админке)
    i=0
    while [ "$i" -lt 4 ]; do
      kcadm create "authentication/executions/$role_id/raise-priority" -r "$realm" >/dev/null 2>&1 || true
      i=$((i + 1))
    done
    echo "realm $realm: flow $FLOW создан - OTP для роли $role"
  fi
  kcadm update "realms/$realm" -s browserFlow="$FLOW"
  echo "realm $realm: вход через браузер - $FLOW"
}

urlencode() {
  printf '%s' "$1" | sed -e 's/%/%25/g' -e 's/ /%20/g'
}

kcadm config credentials --server http://localhost:8080 --realm master --user "$KEYCLOAK_ADMIN" --password "$KEYCLOAK_ADMIN_PASSWORD" >/dev/null

for realm in "$REALM" master; do
  kcadm update "realms/$realm" -s "passwordPolicy=$PASSWORD_POLICY"
  echo "realm $realm: политика паролей - $PASSWORD_POLICY"
done

if [ -n "$OTP_ROLES" ]; then
  if ! kcadm get "roles/$OTP_ROLE" -r "$REALM" >/dev/null 2>&1; then
    kcadm create roles -r "$REALM" -s name="$OTP_ROLE" -s 'description=Вход через браузер только с одноразовым кодом (OTP)' >/dev/null
    echo "роль $OTP_ROLE создана"
  fi
  for role in $OTP_ROLES; do
    if ! kcadm get "roles/$role" -r "$REALM" >/dev/null 2>&1; then
      echo "роли $role в realm $REALM нет - сначала guest-setup.sh" >&2
      exit 1
    fi
    kcadm add-roles -r "$REALM" --rname "$role" --rolename "$OTP_ROLE" >/dev/null
    echo "роль $role: входит $OTP_ROLE"
  done
  require_otp_by_role "$REALM" "$OTP_ROLE"
fi

if [ "$MASTER_OTP" = "true" ]; then
  require_otp_by_role master admin
fi

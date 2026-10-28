#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo " [OK]   $desc"; ((PASS++))
    else
        echo " [FAIL] $desc (ожидалось: '$expected', получено: '$actual')"; ((FAIL++))
    fi
}
echo "Аудит конфигурации: $(hostname -f), $(date '+%Y-%m-%d %H:%M')"

echo "[1] Служба SSH"
check "Вход от имени root запрещён"        "no" "$(sudo sshd -T | awk '/^permitrootlogin/{print $2}')"
check "Парольная аутентификация отключена" "no" "$(sudo sshd -T | awk '/^passwordauthentication/{print $2}')"
SSH_PORT="$(sudo sshd -T | awk '/^port /{print $2; exit}')"
check "Порт SSH отличен от 22 (порт: ${SSH_PORT:-?})" "yes" \
      "$([[ -n "$SSH_PORT" && "$SSH_PORT" != "22" ]] && echo yes || echo no)"
check "MaxAuthTries равен 3"               "3"  "$(sudo sshd -T | awk '/^maxauthtries/{print $2}')"

echo "[2] Межсетевой экран"
check "Межсетевой экран активен" "active" "$(sudo ufw status | awk '/^Status:/{print $2}')"
# строка вида: Default: deny (incoming), allow (outgoing), deny (routed)
check "Политика входящего трафика — deny" "deny" "$(sudo ufw status verbose | awk '/^Default:/{print $2}')"

echo "[3] Учётные записи"
awk -F: '$3>=1000 && $3<65534 {printf "              %s (uid=%s)\n",$1,$3}' /etc/passwd

echo "[4] Веб-сервер"
check "Служба nginx активна"          "active" "$(systemctl is-active nginx)"
check "Конфигурация nginx корректна"  "0"      "$(sudo nginx -t >/dev/null 2>&1; echo $?)"
CERT_DAYS="${CERT_DAYS:-30}"          # порог можно завысить для проверки: CERT_DAYS=400
check "Сертификат действует ещё ≥ ${CERT_DAYS} дн." "0" \
      "$(openssl x509 -checkend $((CERT_DAYS * 86400)) -noout -in /etc/ssl/certs/devops.crt >/dev/null; echo $?)"
check "Нет файлов ресурса с записью для всех" "" "$(find /var/www/devops-site -perm -o+w 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
check "Права ключа TLS — 600"         "600"    "$(sudo stat -c '%a' /etc/ssl/private/devops.key)"

echo "[5] Контейнеризация"
check "Служба docker активна"             "active"  "$(systemctl is-active docker)"
check "Контейнер СУБД в состоянии healthy" "healthy" "$(docker inspect -f '{{.State.Health.Status}}' app-db-1 2>/dev/null || echo 'нет контейнера')"
# порты 5000/5432 допустимы только на 127.0.0.1; в actual — всё, что слушает на других адресах
check "Порты 5000 и 5432 только на 127.0.0.1" "" \
      "$(ss -tlnH | awk '{print $4}' | grep -E ':(5000|5432)$' | grep -v '^127\.0\.0\.1:' | tr '\n' ' ' | sed 's/ $//')"
check "Права ~/app/.env — 600"             "600"     "$(stat -c '%a' ~/app/.env 2>/dev/null)"

# раздел действует после развёртывания КР № 2; до неё ~/kr2 нет и аудит допуска должен давать 0
if [[ -d ~/kr2 ]]; then
echo "[6] Контрольная работа № 2"
KR2=(docker compose --project-directory "$HOME/kr2")
REDIS_ID="$("${KR2[@]}" ps -q redis 2>/dev/null)"
check "Контейнер redis в состоянии healthy" "healthy" \
      "$(docker inspect -f '{{.State.Health.Status}}' "$REDIS_ID" 2>/dev/null || echo 'нет контейнера')"
# при публикации "8001:8001" команда вернёт 0.0.0.0:8001
check "Порт 8001 опубликован только на 127.0.0.1" "127.0.0.1:8001" \
      "$("${KR2[@]}" port app 8001 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
check "Права ~/kr2/.env — 600"              "600" "$(stat -c '%a' ~/kr2/.env 2>/dev/null)"
check "Сертификат kr2 действует ещё ≥ 30 дн." "0" \
      "$(openssl x509 -checkend $((30 * 86400)) -noout -in /etc/ssl/certs/kr2.crt >/dev/null 2>&1; echo $?)"
check "Ресурс kr2 активирован"              "yes" "$([[ -L /etc/nginx/sites-enabled/kr2 ]] && echo yes || echo no)"
fi

echo "Пройдено: $PASS, не пройдено: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1

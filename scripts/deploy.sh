#!/usr/bin/env bash
# Доставка статического ресурса на devops-vm
# Использование: scripts/deploy.sh [--dry-run]
set -euo pipefail

REMOTE="devops"                     # псевдоним из ~/.ssh/config (ПР № 5, шаг 1.6)
REMOTE_DIR="/var/www/devops-site"
SITE_URL="https://devops.local"
CA_CERT="${HOME}/devops.crt"
LOCAL_DIR="$(git rev-parse --show-toplevel)/site/"

die() { echo "deploy: $*" >&2; exit 1; }

# 1. Разбор аргумента --dry-run
DRY_RUN=""
case "${1:-}" in
    "")        ;;
    --dry-run) DRY_RUN="--dry-run" ;;
    *)         die "неизвестный аргумент '$1'. Использование: $0 [--dry-run]" ;;
esac

# 2. Проверки по требованиям 4 и 5
[[ -f "${LOCAL_DIR}index.html" ]] \
    || die "нет файла ${LOCAL_DIR}index.html — доставка отменена (--delete удалил бы главную страницу)"
[[ -z "$(git status --porcelain)" ]] \
    || die "в репозитории есть незафиксированные изменения — сначала git commit"
# штатный rsync macOS 26 (openrsync) отвергает --chmod=D755,F644 — нужен GNU rsync
[[ "$(rsync --version 2>&1)" == *openrsync* ]] \
    && die "найден openrsync; установите GNU rsync: brew install rsync"
COMMIT="$(git rev-parse --short HEAD)"

# 3. Синхронизация каталога — одно SSH-соединение за запуск
rsync -avz --delete --chmod=D755,F644 ${DRY_RUN} \
      -e "ssh -o BatchMode=yes -o ConnectTimeout=5" \
      "${LOCAL_DIR}" "${REMOTE}:${REMOTE_DIR}/" \
    || die "rsync завершился с ошибкой (код $?)"

# 4. При --dry-run — завершение без проверки доступности
if [[ -n "$DRY_RUN" ]]; then
    echo "deploy: пробный запуск, сервер не изменён (коммит ${COMMIT})"
    exit 0
fi

# 5. Проверка доступности с проверкой сертификата
curl -fsS --cacert "$CA_CERT" --max-time 5 -o /dev/null "${SITE_URL}/" \
    || die "ресурс ${SITE_URL} недоступен после доставки (коммит ${COMMIT})"
echo "deploy: доставлен коммит ${COMMIT}, ${SITE_URL} отвечает"

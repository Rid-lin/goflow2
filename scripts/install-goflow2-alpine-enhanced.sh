#!/bin/sh
# Установка goflow2 на Alpine Linux с OpenRC
# Этот скрипт устанавливает последний релиз из https://github.com/Rid-lin/goflow2/releases
# и настраивает сервис OpenRC с поддержкой переменных окружения.
# Также устанавливает Docker, Docker Compose, настраивает логирование и разворачивает TimescaleDB
#
# Все конфигурационные файлы берутся из каталога files/ в репозитории.
# Чтобы изменить поведение установки, правите файлы в scripts/files/,
# а не inline-шаблоны в этом скрипте.

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Проверка запуска от root
if [ "$(id -u)" -ne 0 ]; then
    log_error "Этот скрипт должен запускаться от root (используйте sudo)"
    exit 1
fi

# Каталог установки по умолчанию
INSTALL_DIR="/opt/goflow2"
BINARY_NAME="goflow2"
SERVICE_NAME="goflow2"
USER_NAME="goflow2"
GROUP_NAME="goflow2"

# Ветка репозитория по умолчанию (можно переопределить через REPO_BRANCH)
REPO_BRANCH="${REPO_BRANCH:-timescaledb-sourcecraft}"
REPO_URL="https://github.com/Rid-lin/goflow2"

# Определение архитектуры
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)
        ARCH="amd64"
        ;;
    aarch64)
        ARCH="arm64"
        ;;
    *)
        log_error "Неподдерживаемая архитектура: $ARCH"
        exit 1
        ;;
esac

log_info "Обнаружена архитектура: $ARCH"

# Установка зависимостей
log_info "Установка необходимых пакетов..."
apk add --no-cache wget jq tar

# Скачивание конфигурационных файлов из репозитория
log_info "Скачивание конфигурационных файлов из репозитория (ветка: $REPO_BRANCH)..."
TMP_FILES="/tmp/goflow2-files"
rm -rf "$TMP_FILES"
mkdir -p "$TMP_FILES"

# Скачиваем и распаковываем архив репозитория
REPO_TARBALL="${REPO_URL}/archive/refs/heads/${REPO_BRANCH}.tar.gz"
wget -q -O /tmp/goflow2-repo.tar.gz "$REPO_TARBALL"

# Распаковываем во временную директорию
TMP_REPO="/tmp/goflow2-repo-extract"
rm -rf "$TMP_REPO"
mkdir -p "$TMP_REPO"
tar -xzf /tmp/goflow2-repo.tar.gz -C "$TMP_REPO"

# Ищем директорию scripts/files в распакованном архиве
# GitHub archive создаёт корневую директорию goflow2-{branch},
# но branch может содержать /, поэтому ищем через find
FILES_SRC=$(find "$TMP_REPO" -type d -path "*/scripts/files" | head -1)
if [ -n "$FILES_SRC" ] && [ -d "$FILES_SRC" ]; then
    cp -r "$FILES_SRC/"* "$TMP_FILES/"
    log_info "Конфигурационные файлы загружены в $TMP_FILES"
else
    log_error "Не удалось найти scripts/files/ в репозитории (ветка: $REPO_BRANCH)"
    log_error "Проверьте REPO_BRANCH или укажите правильную через: REPO_BRANCH=your-branch $0"
    rm -f /tmp/goflow2-repo.tar.gz
    rm -rf "$TMP_REPO"
    exit 1
fi

rm -f /tmp/goflow2-repo.tar.gz
rm -rf "$TMP_REPO"

FILES_DIR="$TMP_FILES"

# Установка Docker и Docker Compose (если не установлены)
if ! command -v docker > /dev/null 2>&1; then
    log_info "Установка Docker..."
    apk add --no-cache docker docker-cli-compose
    rc-update add docker boot
    rc-service docker start
    sleep 3
else
    log_info "Docker уже установлен"
fi

if ! command -v docker-compose > /dev/null 2>&1; then
    log_info "Установка Docker Compose..."
    apk add --no-cache docker-compose
else
    log_info "Docker Compose уже установлен"
fi

# Получение последней версии из GitHub API
log_info "Получение последней версии релиза..."
LATEST_VERSION=$(wget -q -O - https://api.github.com/repos/Rid-lin/goflow2/releases/latest | jq -r '.tag_name')
if [ -z "$LATEST_VERSION" ] || [ "$LATEST_VERSION" = "null" ]; then
    log_error "Не удалось получить последнюю версию"
    exit 1
fi
log_info "Последняя версия: $LATEST_VERSION"

# Определение OS для имени файла
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$OS" in
    mingw*|msys*|cygwin*)
        OS="windows"
        EXTENSION=".exe"
        ;;
    darwin)
        OS="darwin"
        EXTENSION=""
        ;;
    *)
        OS="linux"
        EXTENSION=""
        ;;
esac

# Формирование URL для скачивания (имя файла: goflow2-{version}-{os}-{arch})
VERSION_NOV="${LATEST_VERSION#v}"
DOWNLOAD_FILENAME="goflow2-${VERSION_NOV}-${OS}-${ARCH}${EXTENSION}"
DOWNLOAD_URL="https://github.com/Rid-lin/goflow2/releases/download/${LATEST_VERSION}/${DOWNLOAD_FILENAME}"
log_info "URL для скачивания: $DOWNLOAD_URL"

# Создание каталога установки
log_info "Создание каталога установки $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"

# Создание пользователя и группы, если они не существуют
if ! getent group "$GROUP_NAME" > /dev/null; then
    log_info "Создание группы $GROUP_NAME..."
    addgroup -S "$GROUP_NAME"
fi
if ! id -u "$USER_NAME" > /dev/null; then
    log_info "Создание пользователя $USER_NAME..."
    adduser -S -D -H -G "$GROUP_NAME" -h "$INSTALL_DIR" -s /bin/false "$USER_NAME"
fi

# Скачивание бинарного файла
log_info "Скачивание goflow2..."
cd /tmp
wget -q -O goflow2 "$DOWNLOAD_URL"

# Перемещение бинарного файла в каталог установки
mv goflow2 "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/goflow2"

# Копирование скрипта-обертки для загрузки .env и установки аргументов по умолчанию
log_info "Копирование скрипта-обертки goflow2-wrapper.sh..."
cp "$FILES_DIR/apps/goflow2-wrapper.sh" "$INSTALL_DIR/goflow2-wrapper.sh"
chmod +x "$INSTALL_DIR/goflow2-wrapper.sh"
chown "$USER_NAME:$GROUP_NAME" "$INSTALL_DIR/goflow2-wrapper.sh"

# Установка прав владения
log_info "Установка прав владения $INSTALL_DIR на $USER_NAME:$GROUP_NAME..."
chown -R "$USER_NAME:$GROUP_NAME" "$INSTALL_DIR"

# Копирование .env по умолчанию, если .env не существует
if [ ! -f "$INSTALL_DIR/.env" ]; then
    log_info "Копирование .env.default в .env..."
    cp "$FILES_DIR/apps/.env.default" "$INSTALL_DIR/.env"
    chown "$USER_NAME:$GROUP_NAME" "$INSTALL_DIR/.env"
    log_warn "Пожалуйста, отредактируйте $INSTALL_DIR/.env для настройки вашего окружения"
fi

# Настройка логирования
log_info "Настройка логирования..."
LOG_DIR="/var/log/goflow2"
mkdir -p "$LOG_DIR"
chown "$USER_NAME:$GROUP_NAME" "$LOG_DIR"

# Копирование конфигурации logrotate
log_info "Копирование конфигурации logrotate..."
cp "$FILES_DIR/etc/logrotate.d/goflow2" "/etc/logrotate.d/goflow2"
log_info "Скопирована конфигурация logrotate: /etc/logrotate.d/goflow2"

# Копирование файла сервиса OpenRC
log_info "Копирование сервиса OpenRC..."
cp "$FILES_DIR/etc/init.d/goflow2" "/etc/init.d/$SERVICE_NAME"
chmod +x "/etc/init.d/$SERVICE_NAME"
log_info "Скопирован сервис OpenRC: /etc/init.d/$SERVICE_NAME"

# Развертывание TimescaleDB
log_info "Развертывание TimescaleDB в контейнере Docker..."
cd "$INSTALL_DIR"

# Копирование docker-compose файла для TimescaleDB
log_info "Копирование docker-compose.timescaledb.yml..."
cp "$FILES_DIR/apps/docker-compose.timescaledb.yml" "$INSTALL_DIR/docker-compose.timescaledb.yml"
log_info "Скопирован docker-compose.timescaledb.yml"

# Копирование init-скриптов для TimescaleDB
log_info "Копирование init-скриптов для TimescaleDB..."
mkdir -p "$INSTALL_DIR/init"
cp -r "$FILES_DIR/apps/init/"* "$INSTALL_DIR/init/"
chown -R "$USER_NAME:$GROUP_NAME" "$INSTALL_DIR/init"
log_info "Init-скрипты скопированы"

# Подготовка директории для данных TimescaleDB
# Контейнер работает от пользователя postgres (UID 1000)
DATA_DIR="$INSTALL_DIR/timescaledb-data"
if [ ! -d "$DATA_DIR" ]; then
    mkdir -p "$DATA_DIR"
fi
chown 1000:1000 "$DATA_DIR"
log_info "Директория данных TimescaleDB подготовлена: $DATA_DIR"

# Запуск TimescaleDB
log_info "Запуск TimescaleDB контейнера..."
cd "$INSTALL_DIR"
if docker-compose -f docker-compose.timescaledb.yml up -d; then
    log_info "TimescaleDB успешно запущен"
    log_info "Проверка состояния контейнера..."
    sleep 5
    if docker-compose -f docker-compose.timescaledb.yml ps | grep -q "Up"; then
        log_info "TimescaleDB работает"
    else
        log_warn "TimescaleDB может не работать. Проверьте: docker-compose -f docker-compose.timescaledb.yml logs"
    fi
else
    log_warn "Не удалось запустить TimescaleDB. Проверьте установку Docker."
fi

# Включение и запуск сервиса goflow2
log_info "Включение сервиса $SERVICE_NAME..."
rc-update add "$SERVICE_NAME" default

log_info "Ожидание 5 секунд перед запуском сервиса (TimescaleDB инициализируется)..."
sleep 5

log_info "Запуск сервиса $SERVICE_NAME..."
rc-service "$SERVICE_NAME" start

# Проверка состояния сервиса с ретраями
log_info "Проверка состояния сервиса $SERVICE_NAME (до 5 попыток с интервалом 10 сек)..."
SERVICE_STARTED=false
for i in 1 2 3 4 5; do
    log_info "Попытка $i из 5..."
    sleep 10
    if rc-service "$SERVICE_NAME" status > /dev/null 2>&1; then
        SERVICE_STARTED=true
        log_info "Сервис $SERVICE_NAME успешно запущен"
        break
    fi
    log_warn "Сервис ещё не запущен (попытка $i/5)"
done

if [ "$SERVICE_STARTED" = false ]; then
    log_warn "Сервис $SERVICE_NAME не запустился после 5 попыток."
    log_info "Вывод последних 50 строк лога:"
    tail -50 "$LOG_DIR/output.log" 2>/dev/null || log_warn "Лог-файл не найден: $LOG_DIR/output.log"
    log_info "Проверьте статус вручную: rc-service $SERVICE_NAME status"
    log_info "Проверьте логи: tail -f $LOG_DIR/output.log"
fi

# Копирование руководства по подключению Grafana
log_info "Копирование руководства по подключению Grafana..."
cp "$FILES_DIR/docs/GRAFANA-CONNECTION.md" "$INSTALL_DIR/GRAFANA-CONNECTION.md"
chown "$USER_NAME:$GROUP_NAME" "$INSTALL_DIR/GRAFANA-CONNECTION.md"
log_info "Скопировано руководство по подключению Grafana: $INSTALL_DIR/GRAFANA-CONNECTION.md"

log_info "Установка завершена!"
log_info "Каталог установки: $INSTALL_DIR"
log_info "Имя сервиса: $SERVICE_NAME"
log_info "Управление сервисом: rc-service $SERVICE_NAME {start|stop|restart|status}"
log_info "Редактирование конфигурации: $INSTALL_DIR/.env"
log_info "Логи: tail -f $LOG_DIR/output.log"
log_info "TimescaleDB управление: cd $INSTALL_DIR && docker-compose -f docker-compose.timescaledb.yml {up|down|logs|ps}"
log_info "Руководство по Grafana: $INSTALL_DIR/GRAFANA-CONNECTION.md"
log_info ""
log_info "Следующие шаги:"
log_info "1. Отредактируйте $INSTALL_DIR/.env для настройки паролей и параметров"
log_info "2. Перезапустите сервис: rc-service $SERVICE_NAME restart"
log_info "3. Проверьте логи: tail -f $LOG_DIR/output.log"
log_info "4. Настройте Grafana, используя руководство в GRAFANA-CONNECTION.md"

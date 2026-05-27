#!/bin/sh
# Установка goflow2 на Alpine Linux с OpenRC
# Этот скрипт устанавливает последний релиз из https://github.com/Rid-lin/goflow2/releases
# и настраивает сервис OpenRC с поддержкой переменных окружения.
# Также устанавливает Docker, Docker Compose, настраивает логирование и разворачивает TimescaleDB

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
apk add --no-cache wget jq

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

# Формирование URL для скачивания
DOWNLOAD_URL="https://github.com/Rid-lin/goflow2/releases/download/${LATEST_VERSION}/goflow2"
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

# Создание скрипта-обертки для загрузки .env и установки аргументов по умолчанию
WRAPPER_SCRIPT="$INSTALL_DIR/goflow2-wrapper.sh"
log_info "Создание скрипта-обертки $WRAPPER_SCRIPT..."
cat > "$WRAPPER_SCRIPT" <<'EOF'
#!/bin/sh
# Обертка для goflow2, которая загружает переменные окружения из .env
# и устанавливает аргументы по умолчанию для транспорта TimescaleDB, если аргументы не предоставлены

set -a
if [ -f "$(dirname "$0")/.env" ]; then
    . "$(dirname "$0")/.env"
fi
set +a

# Аргументы по умолчанию, если аргументы командной строки не предоставлены
if [ $# -eq 0 ]; then
    # Определение транспорта (по умолчанию timescaledb, если не указано)
    TRANSPORT="${GOFLOW2_TRANSPORT:-timescaledb}"
    
    # Определение формата (по умолчанию binary)
    FORMAT="${GOFLOW2_FORMAT:-bin}"
    
    # Построение строки подключения, если не предоставлена
    if [ -z "$TRANSPORT_TIMESCALEDB_CONN" ] && [ -n "$DB_HOST" ] && [ -n "$DB_PORT" ] && [ -n "$DB_NAME" ] && [ -n "$APP_USER" ] && [ -n "$APP_PASSWORD" ]; then
        TRANSPORT_TIMESCALEDB_CONN="postgres://${APP_USER}:${APP_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
        export TRANSPORT_TIMESCALEDB_CONN
    fi
    
    # Установка аргументов по умолчанию
    set -- "-transport=$TRANSPORT" "-format=$FORMAT"
    
    # Добавление аргументов, специфичных для TimescaleDB, если транспорт - timescaledb
    if [ "$TRANSPORT" = "timescaledb" ] && [ -n "$TRANSPORT_TIMESCALEDB_CONN" ]; then
        set -- "$@" "-transport.timescaledb.conn=$TRANSPORT_TIMESCALEDB_CONN"
    fi
    
    # Добавление других флагов TimescaleDB, если установлены
    if [ -n "$TRANSPORT_TIMESCALEDB_TABLE" ]; then
        set -- "$@" "-transport.timescaledb.table=$TRANSPORT_TIMESCALEDB_TABLE"
    fi
    if [ -n "$TRANSPORT_TIMESCALEDB_CREATE_TABLE" ]; then
        set -- "$@" "-transport.timescaledb.create-table=$TRANSPORT_TIMESCALEDB_CREATE_TABLE"
    fi
    if [ -n "$TRANSPORT_TIMESCALEDB_ENABLE_COMPRESSION" ]; then
        set -- "$@" "-transport.timescaledb.enable-compression=$TRANSPORT_TIMESCALEDB_ENABLE_COMPRESSION"
    fi
fi

exec "$(dirname "$0")/goflow2" "$@"
EOF
chmod +x "$WRAPPER_SCRIPT"
chown "$USER_NAME:$GROUP_NAME" "$WRAPPER_SCRIPT"

# Установка прав владения
log_info "Установка прав владения $INSTALL_DIR на $USER_NAME:$GROUP_NAME..."
chown -R "$USER_NAME:$GROUP_NAME" "$INSTALL_DIR"

# Копирование примера окружения из каталога скрипта, если доступно
SCRIPT_DIR=$(dirname "$(realpath "$0")")
if [ -f "$SCRIPT_DIR/.env.example" ] && [ ! -f "$INSTALL_DIR/.env.example" ]; then
    log_info "Копирование .env.example из каталога скрипта в $INSTALL_DIR..."
    cp "$SCRIPT_DIR/.env.example" "$INSTALL_DIR/.env.example"
    chown "$USER_NAME:$GROUP_NAME" "$INSTALL_DIR/.env.example"
fi

# Копирование примера окружения, если .env не существует
if [ -f "$INSTALL_DIR/.env.example" ] && [ ! -f "$INSTALL_DIR/.env" ]; then
    log_info "Копирование .env.example в .env..."
    cp "$INSTALL_DIR/.env.example" "$INSTALL_DIR/.env"
    chown "$USER_NAME:$GROUP_NAME" "$INSTALL_DIR/.env"
    log_warn "Пожалуйста, отредактируйте $INSTALL_DIR/.env для настройки вашего окружения"
fi

# Настройка логирования
log_info "Настройка логирования..."
LOG_DIR="/var/log/goflow2"
mkdir -p "$LOG_DIR"
chown "$USER_NAME:$GROUP_NAME" "$LOG_DIR"

# Создание конфигурации logrotate
LOGROTATE_FILE="/etc/logrotate.d/goflow2"
cat > "$LOGROTATE_FILE" <<EOF
$LOG_DIR/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 0640 $USER_NAME $GROUP_NAME
    postrotate
        rc-service $SERVICE_NAME reload > /dev/null 2>&1 || true
    endscript
}
EOF
log_info "Создана конфигурация logrotate: $LOGROTATE_FILE"

# Создание файла сервиса OpenRC с перенаправлением логов
SERVICE_FILE="/etc/init.d/$SERVICE_NAME"
log_info "Создание сервиса OpenRC в $SERVICE_FILE..."

cat > "$SERVICE_FILE" <<EOF
#!/sbin/openrc-run

name="goflow2"
description="GoFlow2 NetFlow/sFlow/IPFIX collector"
command="$WRAPPER_SCRIPT"
command_args=""
command_user="$USER_NAME:$GROUP_NAME"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
start_stop_daemon_args="--chdir $INSTALL_DIR"
output_log="$LOG_DIR/output.log"
error_log="$LOG_DIR/error.log"

depend() {
    need net
    after firewall
}

start_pre() {
    # Проверка существования .env (опционально)
    if [ ! -f "$INSTALL_DIR/.env" ]; then
        ewarn "Файл .env не найден в $INSTALL_DIR/.env"
    fi
    # Примечание: скрипт-обертка загружает .env автоматически
}

stop_post() {
    rm -f "\$pidfile"
}
EOF

chmod +x "$SERVICE_FILE"

# Развертывание TimescaleDB
log_info "Развертывание TimescaleDB в контейнере Docker..."
cd "$INSTALL_DIR"

# Копирование docker-compose файла для TimescaleDB
if [ -f "$SCRIPT_DIR/docker-compose.timescaledb.yml" ]; then
    cp "$SCRIPT_DIR/docker-compose.timescaledb.yml" "$INSTALL_DIR/docker-compose.timescaledb.yml"
    log_info "Скопирован docker-compose.timescaledb.yml"
else
    # Создание docker-compose файла, если он не существует
    cat > "$INSTALL_DIR/docker-compose.timescaledb.yml" <<'EOF'
services:
  timescaledb:
    image: ${TIMESCALEDB_IMAGE:-timescale/timescaledb-ha:pg18}
    container_name: goflow2-timescaledb
    restart: unless-stopped
    user: "1000:1000"
    env_file:
      - .env
    environment:
      # PostgreSQL credentials
      POSTGRES_DB: ${DB_NAME:-goflow2}
      POSTGRES_USER: ${DB_ADMIN_USER:-postgres}
      POSTGRES_PASSWORD: ${DB_ADMIN_PASSWORD:-password}
      # All variables from .env for init scripts
      DB_HOST: ${DB_HOST}
      DB_PORT: ${DB_PORT}
      DB_NAME: ${DB_NAME}
      DB_ADMIN_USER: ${DB_ADMIN_USER}
      DB_ADMIN_PASSWORD: ${DB_ADMIN_PASSWORD}
      APP_USER: ${APP_USER}
      APP_PASSWORD: ${APP_PASSWORD}
      APP_SCHEMA: ${APP_SCHEMA}
      GRAFANA_USER: ${GRAFANA_USER}
      GRAFANA_USER_PASSWORD: ${GRAFANA_USER_PASSWORD}
      TIMESCALEDB_TELEMETRY: ${TIMESCALEDB_TELEMETRY:-off}
      TIMESCALEDB_MAX_CONNECTIONS: ${TIMESCALEDB_MAX_CONNECTIONS:-200}
      TIMESCALEDB_SHARED_BUFFERS: ${TIMESCALEDB_SHARED_BUFFERS:-256MB}

    ports:
      - "${DB_PORT:-5432}:5432"
    volumes:
      - ./timescaledb-data:/home/postgres/pgdata/data
      - ./init:/docker-entrypoint-initdb.d
    networks:
      - goflow2-network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_ADMIN_USER:-postgres} -d ${DB_NAME:-goflow2}"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
    command: >
      postgres
      -c shared_preload_libraries=timescaledb
      -c max_connections=${TIMESCALEDB_MAX_CONNECTIONS:-200}
      -c shared_buffers=${TIMESCALEDB_SHARED_BUFFERS:-256MB}

networks:
  goflow2-network:
    driver: bridge
EOF
    log_info "Создан новый docker-compose.timescaledb.yml"
fi

# Копирование init-скриптов для TimescaleDB
INIT_SRC="$SCRIPT_DIR/timescaledb/init"
INIT_DST="$INSTALL_DIR/init"
if [ -d "$INIT_SRC" ]; then
    log_info "Копирование init-скриптов из $INIT_SRC в $INIT_DST..."
    mkdir -p "$INIT_DST"
    cp -r "$INIT_SRC/"* "$INIT_DST/"
    chown -R "$USER_NAME:$GROUP_NAME" "$INIT_DST"
    log_info "Init-скрипты скопированы"
else
    log_warn "Каталог init-скриптов не найден: $INIT_SRC"
fi

# Создание .env файла для TimescaleDB, если не существует
if [ ! -f "$INSTALL_DIR/.env" ]; then
    cat > "$INSTALL_DIR/.env" <<'EOF'
# Конфигурация TimescaleDB
TIMESCALEDB_IMAGE=timescale/timescaledb-ha:pg18
DB_NAME=goflow2
DB_ADMIN_USER=postgres
DB_ADMIN_PASSWORD=password
DB_PORT=5432
TIMESCALEDB_TELEMETRY=off
TIMESCALEDB_MAX_CONNECTIONS=200
TIMESCALEDB_SHARED_BUFFERS=256MB

# Конфигурация goflow2
GOFLOW2_TRANSPORT=timescaledb
GOFLOW2_FORMAT=bin
DB_HOST=localhost
APP_USER=goflow2
APP_PASSWORD=goflow2_password
APP_SCHEMA=goflow2

# Пользователь Grafana (только чтение)
GRAFANA_USER=grafana_reader
GRAFANA_USER_PASSWORD=grafana_secure_password
EOF
    log_warn "Создан файл .env с настройками по умолчанию. Пожалуйста, измените пароли!"
fi

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

log_info "Запуск сервиса $SERVICE_NAME..."
rc-service "$SERVICE_NAME" start

# Проверка состояния сервиса
if rc-service "$SERVICE_NAME" status > /dev/null 2>&1; then
    log_info "Сервис $SERVICE_NAME успешно запущен"
else
    log_warn "Сервис может не работать. Проверьте логи: rc-service $SERVICE_NAME status"
fi

# Создание файла с инструкциями по подключению Grafana
GRAFANA_GUIDE="$INSTALL_DIR/GRAFANA-CONNECTION.md"
cat > "$GRAFANA_GUIDE" <<'EOF'
# Подключение Grafana к TimescaleDB

## Параметры подключения

1. **Тип базы данных**: PostgreSQL
2. **Хост**: `localhost` или IP-адрес сервера
3. **Порт**: `5432` (или значение из DB_PORT в .env)
4. **База данных**: `goflow2` (или значение из DB_NAME)
5. **Пользователь**: `postgres` (или значение из DB_ADMIN_USER)
6. **Пароль**: Пароль из DB_ADMIN_PASSWORD

## Настройка источника данных в Grafana

1. Перейдите в **Configuration → Data Sources**
2. Нажмите **Add data source**
3. Выберите **PostgreSQL**
4. Заполните параметры:
   - **Host**: `timescaledb:5432` (если Grafana в том же Docker-сети) или `localhost:5432`
   - **Database**: `goflow2`
   - **User**: `postgres`
   - **Password**: Пароль из .env файла
   - **SSL Mode**: `disable` (для локальной установки)
5. В разделе **PostgreSQL Details**:
   - **TimescaleDB**: Включите опцию (если доступно)
6. Нажмите **Save & Test**

## Пример запроса для Grafana

```sql
SELECT 
  time_bucket('1 minute', "TimeReceived") AS time,
  COUNT(*) AS packet_count,
  SUM("Bytes") AS total_bytes
FROM flows
WHERE "TimeReceived" > NOW() - INTERVAL '1 hour'
GROUP BY time
ORDER BY time DESC
```

## Дополнительные настройки

### Если используется pgAdmin
- URL: http://localhost:8080 (если pgAdmin включен)
- Email: admin@goflow2.local
- Пароль: admin

### Создание пользователя только для чтения (рекомендуется для Grafana)

```sql
CREATE USER grafana_reader WITH PASSWORD 'secure_password';
GRANT CONNECT ON DATABASE goflow2 TO grafana_reader;
GRANT USAGE ON SCHEMA public TO grafana_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO grafana_reader;
```

## Подключение Grafana с отдельного хоста

Если Grafana установлена на отдельном сервере (не в контейнере и не на том же хосте), необходимо настроить сетевой доступ и аутентификацию:

### 1. Проверка доступности TimescaleDB

TimescaleDB по умолчанию слушает на всех интерфейсах (0.0.0.0:5432). Убедитесь, что порт доступен:

```bash
# На сервере с TimescaleDB проверьте, что контейнер запущен
docker-compose -f /opt/goflow2/docker-compose.timescaledb.yml ps

# Проверьте, что порт 5432 слушается
netstat -tlnp | grep 5432
```

### 2. Настройка брандмауэра (если используется)

На сервере с TimescaleDB разрешите входящие подключения на порту 5432:
```bash
# Для Alpine Linux (если используется iptables)
apk add iptables
iptables -A INPUT -p tcp --dport 5432 -j ACCEPT

# Для сохранения правил (если нужно)
service iptables save
```

### 3. Настройка аутентификации PostgreSQL

По умолчанию PostgreSQL разрешает подключения только с localhost. Чтобы разрешить доступ с других IP:

1. Подключитесь к контейнеру TimescaleDB:
   ```bash
   docker exec -it goflow2-timescaledb vi /home/postgres/pgdata/data/pg_hba.conf
   ```

2. Добавьте запись в `pg_hba.conf` для вашей подсети:
   ```bash
   docker exec goflow2-timescaledb bash -c "echo 'host all all 192.168.1.0/24 md5' >> /home/postgres/pgdata/data/pg_hba.conf"
   ```
   Замените `192.168.1.0/24` на IP-адрес или подсеть вашего сервера Grafana.

3. Перезагрузите конфигурацию PostgreSQL:
   ```sql
   SELECT pg_reload_conf();
   ```

### 4. Создание пользователя для Grafana (рекомендуется)

Не используйте пользователя `postgres` для Grafana. Создайте отдельного пользователя с правами только на чтение:

```sql
CREATE USER grafana_reader WITH PASSWORD 'secure_password';
GRANT CONNECT ON DATABASE goflow2 TO grafana_reader;
GRANT USAGE ON SCHEMA public TO grafana_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO grafana_reader;
```

### 5. Настройка источника данных в Grafana

В Grafana на отдельном хосте укажите следующие параметры:

- **Host**: IP-адрес сервера с TimescaleDB (например, `192.168.1.100:5432`)
- **Database**: `goflow2`
- **User**: `grafana_reader` (или `postgres`, если не создавали отдельного пользователя)
- **Password**: Пароль пользователя
- **SSL Mode**: `disable` (для локальной сети) или `require` (для production)
- **TimescaleDB**: Включите опцию (если доступно в Grafana)

### 6. Альтернативные методы подключения (для повышения безопасности)

**SSH туннель** (рекомендуется для безопасного доступа через интернет):
```bash
# На хосте с Grafana создайте туннель
ssh -L 5432:localhost:5432 user@goflow2-server
```
Затем Grafana подключается к `localhost:5432`.

**VPN**: Настройте VPN между серверами для безопасного доступа.

## Устранение неполадок

1. **Нет подключения**:
   ```bash
   # Проверьте, доступен ли порт с хоста Grafana
   nc -zv <ip-адрес-timescaledb> 5432
   
   # Проверьте брандмауэр
   iptables -L -n | grep 5432
   ```

2. **Ошибка аутентификации "password authentication failed"**:
   - Проверьте пароль в .env файле
   - Убедитесь, что пользователь существует

3. **Ошибка "no pg_hba.conf entry for host"**:
   - Добавьте соответствующую запись в pg_hba.conf (шаг 3 выше)
   - Перезагрузите конфигурацию PostgreSQL

4. **Ошибка "connection refused"**:
   - Убедитесь, что контейнер TimescaleDB запущен
   - Проверьте, что порт 5432 опубликован в docker-compose:
     ```yaml
     ports:
       - "5432:5432"
     ```

5. **Медленное подключение или таймауты**:
   - Проверьте сетевую задержку между серверами
   - Рассмотрите использование SSH туннеля или VPN для стабильного соединения
EOF

log_info "Создано руководство по подключению Grafana: $GRAFANA_GUIDE"

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

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
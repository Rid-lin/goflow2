#!/bin/bash
# 01-init-goflow2.sh
# Инициализация базы данных GoFlow2
# Выполняется автоматически при первом запуске контейнера TimescaleDB
# Использует переменные окружения, переданные через docker-compose

set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- Создание пользователя приложения
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${APP_USER}') THEN
            EXECUTE format('CREATE USER %I WITH PASSWORD %L', '${APP_USER}', '${APP_PASSWORD}');
        END IF;
    END
    \$\$;

    -- Создание схемы приложения
    CREATE SCHEMA IF NOT EXISTS ${APP_SCHEMA};

    -- Права для пользователя приложения
    GRANT USAGE ON SCHEMA ${APP_SCHEMA} TO ${APP_USER};
    GRANT CREATE ON SCHEMA ${APP_SCHEMA} TO ${APP_USER};
    GRANT ALL ON SCHEMA ${APP_SCHEMA} TO ${APP_USER};

    ALTER DEFAULT PRIVILEGES IN SCHEMA ${APP_SCHEMA}
        GRANT ALL ON TABLES TO ${APP_USER};
    ALTER DEFAULT PRIVILEGES IN SCHEMA ${APP_SCHEMA}
        GRANT ALL ON SEQUENCES TO ${APP_USER};
    ALTER DEFAULT PRIVILEGES IN SCHEMA ${APP_SCHEMA}
        GRANT ALL ON FUNCTIONS TO ${APP_USER};

    GRANT CONNECT ON DATABASE ${DB_NAME} TO ${APP_USER};
    ALTER USER ${APP_USER} SET search_path TO ${APP_SCHEMA}, public;

    -- Создание пользователя Grafana (только чтение)
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${GRAFANA_USER}') THEN
            EXECUTE format('CREATE USER %I WITH PASSWORD %L', '${GRAFANA_USER}', '${GRAFANA_USER_PASSWORD}');
        END IF;
    END
    \$\$;

    GRANT CONNECT ON DATABASE ${DB_NAME} TO ${GRAFANA_USER};
    GRANT USAGE ON SCHEMA ${APP_SCHEMA} TO ${GRAFANA_USER};
    GRANT SELECT ON ALL TABLES IN SCHEMA ${APP_SCHEMA} TO ${GRAFANA_USER};
    ALTER DEFAULT PRIVILEGES IN SCHEMA ${APP_SCHEMA}
        GRANT SELECT ON TABLES TO ${GRAFANA_USER};

    -- Включение расширения TimescaleDB
    CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;
EOSQL
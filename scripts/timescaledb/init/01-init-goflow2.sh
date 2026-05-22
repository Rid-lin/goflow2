#!/bin/bash
# Generate initialization SQL with environment variables

set -a
source /opt/goflow2/scripts/.env 2>/dev/null || true
set +a

# Set defaults if not defined
DB_NAME=${DB_NAME:-goflow2}
APP_USER=${APP_USER:-goflow2}
APP_PASSWORD=${APP_PASSWORD:-goflow2password}
APP_SCHEMA=${APP_SCHEMA:-goflow2}

cat << EOF
-- Initialize GoFlow2 database
-- This script runs automatically when the TimescaleDB container starts
-- Generated with environment variables:
-- DB_NAME=$DB_NAME
-- APP_USER=$APP_USER
-- APP_SCHEMA=$APP_SCHEMA

-- Create application user if it doesn't exist
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$APP_USER') THEN
        CREATE USER $APP_USER WITH PASSWORD '$APP_PASSWORD';
    END IF;
END
\$\$;

-- Create schema for application data
CREATE SCHEMA IF NOT EXISTS $APP_SCHEMA;

-- Grant permissions to application user
GRANT USAGE ON SCHEMA $APP_SCHEMA TO $APP_USER;
GRANT CREATE ON SCHEMA $APP_SCHEMA TO $APP_USER;

-- Set default privileges for future objects
ALTER DEFAULT PRIVILEGES IN SCHEMA $APP_SCHEMA 
    GRANT ALL ON TABLES TO $APP_USER;
ALTER DEFAULT PRIVILEGES IN SCHEMA $APP_SCHEMA 
    GRANT ALL ON SEQUENCES TO $APP_USER;
ALTER DEFAULT PRIVILEGES IN SCHEMA $APP_SCHEMA 
    GRANT ALL ON FUNCTIONS TO $APP_USER;

-- Grant connect to database
GRANT CONNECT ON DATABASE $DB_NAME TO $APP_USER;

-- Set search path for application user
ALTER USER $APP_USER SET search_path TO $APP_SCHEMA, public;

-- Create extension for TimescaleDB (if not already created)
CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;
EOF
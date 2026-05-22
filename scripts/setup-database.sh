#!/bin/bash
# Database setup script for GoFlow2 TimescaleDB
# This script creates a database user and schema for GoFlow2

set -e

# Load environment variables from .env file if it exists
if [ -f .env ]; then
    echo "Loading environment variables from .env file"
    set -a
    source .env
    set +a
fi

# Default configuration (used if not set in .env or environment)
DB_HOST=${DB_HOST:-localhost}
DB_PORT=${DB_PORT:-5432}
DB_ADMIN_USER=${DB_ADMIN_USER:-postgres}
DB_ADMIN_PASSWORD=${DB_ADMIN_PASSWORD:-password}
DB_NAME=${DB_NAME:-goflow2}
APP_USER=${APP_USER:-goflow2}
APP_PASSWORD=${APP_PASSWORD:-goflow2password}
APP_SCHEMA=${APP_SCHEMA:-goflow2}

echo "=== GoFlow2 Database Setup ==="
echo "Host: $DB_HOST:$DB_PORT"
echo "Database: $DB_NAME"
echo "Application User: $APP_USER"
echo "Application Schema: $APP_SCHEMA"
echo ""

# Check if psql is available
if ! command -v psql &> /dev/null; then
    echo "Error: psql command not found. Please install PostgreSQL client tools."
    exit 1
fi

# Set PGPASSWORD for admin user
export PGPASSWORD=$DB_ADMIN_PASSWORD

echo "1. Creating database '$DB_NAME' if it doesn't exist..."
psql -h $DB_HOST -p $DB_PORT -U $DB_ADMIN_USER -d postgres -c "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'" | grep -q 1 || \
psql -h $DB_HOST -p $DB_PORT -U $DB_ADMIN_USER -d postgres -c "CREATE DATABASE $DB_NAME;"

echo "2. Creating application user '$APP_USER'..."
psql -h $DB_HOST -p $DB_PORT -U $DB_ADMIN_USER -d $DB_NAME <<-EOSQL
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$APP_USER') THEN
            CREATE USER $APP_USER WITH PASSWORD '$APP_PASSWORD';
        ELSE
            ALTER USER $APP_USER WITH PASSWORD '$APP_PASSWORD';
        END IF;
    END
    \$\$;
EOSQL

echo "3. Creating schema '$APP_SCHEMA' and granting privileges..."
psql -h $DB_HOST -p $DB_PORT -U $DB_ADMIN_USER -d $DB_NAME <<-EOSQL
    CREATE SCHEMA IF NOT EXISTS $APP_SCHEMA;
    
    GRANT USAGE ON SCHEMA $APP_SCHEMA TO $APP_USER;
    GRANT CREATE ON SCHEMA $APP_SCHEMA TO $APP_USER;
    
    -- Grant necessary permissions on the schema
    ALTER DEFAULT PRIVILEGES IN SCHEMA $APP_SCHEMA 
        GRANT ALL ON TABLES TO $APP_USER;
    ALTER DEFAULT PRIVILEGES IN SCHEMA $APP_SCHEMA 
        GRANT ALL ON SEQUENCES TO $APP_USER;
    ALTER DEFAULT PRIVILEGES IN SCHEMA $APP_SCHEMA 
        GRANT ALL ON FUNCTIONS TO $APP_USER;
    
    -- Grant connect to database
    GRANT CONNECT ON DATABASE $DB_NAME TO $APP_USER;
EOSQL

echo "4. Setting search_path for application user..."
psql -h $DB_HOST -p $DB_PORT -U $DB_ADMIN_USER -d $DB_NAME <<-EOSQL
    ALTER USER $APP_USER SET search_path TO $APP_SCHEMA, public;
EOSQL

echo "5. Testing connection with application user..."
export PGPASSWORD=$APP_PASSWORD
if psql -h $DB_HOST -p $DB_PORT -U $APP_USER -d $DB_NAME -c "SELECT 'Connection successful' AS status;" &> /dev/null; then
    echo "   ✓ Connection test passed"
else
    echo "   ✗ Connection test failed"
    exit 1
fi

echo ""
echo "=== Database Setup Complete ==="
echo ""
echo "Connection details for GoFlow2:"
echo "  Connection string: postgres://$APP_USER:$APP_PASSWORD@$DB_HOST:$DB_PORT/$DB_NAME"
echo "  Schema: $APP_SCHEMA"
echo ""
echo "To use with GoFlow2, set the following flag:"
echo "  -transport.timescaledb.conn=\"postgres://$APP_USER:$APP_PASSWORD@$DB_HOST:$DB_PORT/$DB_NAME\""
echo ""
echo "Note: The TimescaleDB extension will need to be created in the database."
echo "Run the following command to enable TimescaleDB:"
echo "  psql -h $DB_HOST -p $DB_PORT -U $DB_ADMIN_USER -d $DB_NAME -c 'CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;'"
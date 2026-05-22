-- Initialize GoFlow2 database
-- This script runs automatically when the TimescaleDB container starts

-- Create application user if it doesn't exist
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'goflow2') THEN
        CREATE USER goflow2 WITH PASSWORD 'goflow2password';
    END IF;
END
$$;

-- Create schema for application data
CREATE SCHEMA IF NOT EXISTS goflow2;

-- Grant permissions to application user
GRANT USAGE ON SCHEMA goflow2 TO goflow2;
GRANT CREATE ON SCHEMA goflow2 TO goflow2;

-- Set default privileges for future objects
ALTER DEFAULT PRIVILEGES IN SCHEMA goflow2 
    GRANT ALL ON TABLES TO goflow2;
ALTER DEFAULT PRIVILEGES IN SCHEMA goflow2 
    GRANT ALL ON SEQUENCES TO goflow2;
ALTER DEFAULT PRIVILEGES IN SCHEMA goflow2 
    GRANT ALL ON FUNCTIONS TO goflow2;

-- Grant connect to database
GRANT CONNECT ON DATABASE goflow2 TO goflow2;

-- Set search path for application user
ALTER USER goflow2 SET search_path TO goflow2, public;

-- Create extension for TimescaleDB (if not already created)
CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;
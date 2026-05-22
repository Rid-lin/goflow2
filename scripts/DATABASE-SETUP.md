# TimescaleDB Setup for GoFlow2

This document describes how to set up TimescaleDB for GoFlow2 using Docker and configure the database.

## Environment Configuration

All configuration is managed through the `.env` file. You can customize settings by editing this file:

```bash
# Copy the example .env file if it doesn't exist
cp .env.example .env  # or edit the existing .env

# Edit the configuration
nano .env
```

The `.env` file contains all configurable variables for database credentials, Docker images, and performance settings.

## Quick Start

### 1. Configure Environment

```bash
cd scripts
# Edit .env file if needed (uses defaults if not changed)
```

### 2. Start TimescaleDB with Docker Compose

```bash
# Start the database (uses variables from .env)
docker-compose up -d

# Check if it's running
docker-compose ps
```

### 3. Run Database Setup Script

```bash
# Make the script executable
chmod +x setup-database.sh

# Run the setup script (automatically loads .env)
./setup-database.sh
```

### 4. Enable TimescaleDB Extension

```bash
# Connect to the database and enable TimescaleDB
docker exec -it goflow2-timescaledb psql -U postgres -d goflow2 -c "CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;"
```

### 4. Configure GoFlow2

Run GoFlow2 with the TimescaleDB transport:

```bash
./goflow2 -transport=timescaledb \
  -transport.timescaledb.conn="postgres://goflow2:goflow2password@localhost:5432/goflow2" \
  -transport.timescaledb.create-table=true
```

## Configuration Details

### Docker Compose Files

- `docker-compose.yml` - Basic TimescaleDB setup
- `docker-compose.timescaledb.yml` - Extended setup with pgAdmin

### Database Setup Script

The `setup-database.sh` script performs the following:

1. Creates the `goflow2` database if it doesn't exist
2. Creates an application user `goflow2` with password `goflow2password`
3. Creates a schema `goflow2` for the application data
4. Grants necessary permissions to the application user
5. Tests the connection

### Environment Variables

You can customize the setup using environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `DB_HOST` | `localhost` | Database host |
| `DB_PORT` | `5432` | Database port |
| `DB_ADMIN_USER` | `postgres` | Admin username |
| `DB_ADMIN_PASSWORD` | `password` | Admin password |
| `DB_NAME` | `goflow2` | Database name |
| `APP_USER` | `goflow2` | Application username |
| `APP_PASSWORD` | `goflow2password` | Application password |
| `APP_SCHEMA` | `goflow2` | Application schema |

### Manual Setup

If you prefer to set up manually:

```sql
-- Connect to PostgreSQL
psql -U postgres -h localhost

-- Create database
CREATE DATABASE goflow2;

-- Create user
CREATE USER goflow2 WITH PASSWORD 'goflow2password';

-- Connect to database
\c goflow2

-- Enable TimescaleDB extension
CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;

-- Create schema
CREATE SCHEMA goflow2;

-- Grant permissions
GRANT USAGE ON SCHEMA goflow2 TO goflow2;
GRANT CREATE ON SCHEMA goflow2 TO goflow2;
ALTER DEFAULT PRIVILEGES IN SCHEMA goflow2 GRANT ALL ON TABLES TO goflow2;
ALTER DEFAULT PRIVILEGES IN SCHEMA goflow2 GRANT ALL ON SEQUENCES TO goflow2;
ALTER DEFAULT PRIVILEGES IN SCHEMA goflow2 GRANT ALL ON FUNCTIONS TO goflow2;
GRANT CONNECT ON DATABASE goflow2 TO goflow2;

-- Set search path
ALTER USER goflow2 SET search_path TO goflow2, public;
```

## Troubleshooting

### Connection Issues

1. **Check if database is running:**
   ```bash
   docker-compose ps
   ```

2. **Test connection:**
   ```bash
   psql -h localhost -p 5432 -U postgres -d goflow2
   ```

3. **Check logs:**
   ```bash
   docker-compose logs timescaledb
   ```

### Permission Issues

If GoFlow2 cannot create tables, ensure:
- The application user has `CREATE` permission on the schema
- The TimescaleDB extension is enabled
- The user's search path includes the correct schema

### Performance Tuning

For production deployments, consider adjusting:
- `shared_buffers` in docker-compose.yml
- `max_connections` based on expected load
- Volume mount for persistent storage
- Regular backup strategy

## Cleanup

To stop and remove the database:

```bash
# Stop containers
docker-compose down

# Remove volumes (WARNING: deletes all data)
docker-compose down -v
```

## Next Steps

1. Start GoFlow2 with TimescaleDB transport
2. Monitor database performance
3. Set up backups
4. Configure continuous aggregates for analytics
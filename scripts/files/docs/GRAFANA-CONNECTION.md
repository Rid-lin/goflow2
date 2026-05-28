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

Почасовой трафик разделённый по IP-адресам
```sql
WITH params AS (
    SELECT '${timezone}'::text AS tz,
           date_trunc('day', NOW() AT TIME ZONE '${timezone}') AT TIME ZONE '${timezone}' AS day_start
),
converted AS (
    SELECT
        ip_address,
        bytes_in + bytes_out AS bytes,
        (hour_bucket AT TIME ZONE p.tz)::timestamp AS local_ts
    FROM flow.flows_local_ip_hourly, params p
    WHERE hour_bucket >= p.day_start
      AND hour_bucket <  p.day_start + interval '1 day'
)
SELECT
    ip_address,
    SUM(bytes) AS total_daily_bytes,
    SUM(CASE WHEN EXTRACT(HOUR FROM local_ts) = 0  THEN bytes ELSE 0 END) AS h00,
    SUM(CASE WHEN EXTRACT(HOUR FROM local_ts) = 1  THEN bytes ELSE 0 END) AS h01,
    SUM(CASE WHEN EXTRACT(HOUR FROM local_ts) = 2  THEN bytes ELSE 0 END) AS h02,
    SUM(CASE WHEN EXTRACT(HOUR FROM local_ts) = 3  THEN bytes ELSE 0 END) AS h03,
    SUM(CASE WHEN EXTRACT(HOUR FROM local_ts) = 4  THEN bytes ELSE 0 END) AS h04,
    SUM(CASE WHEN EXTRACT(HOUR FROM local_ts) = 5  THEN bytes ELSE 0 END) AS h05,
    SUM(CASE WHEN EXTRACT(HOUR FROM local_ts) = 6  THEN bytes ELSE 0 END) AS h06,
    SUM(CASE WHEN EXTRACT(HOUR FROM local_ts) = 7  THEN bytes ELSE 0 END) AS h07,
    SUM(CASE WHEN EXTRACT(HOUR FROM local_ts) = 8  THEN bytes ELSE 0 END) AS h08,
    SUM(CASE WHEN EXTRACT(HOUR FROM local_ts) = 9  THEN bytes ELSE 0 END) AS h09,
    SUM(CASE WHEN EXTRACT(HOUR FROM local_ts) = 10 THEN bytes ELSE 0 END) AS h10,
    SUM(CASE WHEN EXTRACT(HOUR FROM local_ts) = 11 THEN bytes ELSE 0 END) AS h11,
    SUM(CASE WHEN EXTRACT(HOUR FROM local_ts) = 12 THEN bytes ELSE 0 END) AS h12,
    SUM(CASE WHEN EXTRACT(HOUR FROM local_ts) = 13 THEN bytes ELSE 0 END) AS h13,
    SUM(CASE WHEN EXTRACT(HOUR FROM local_ts) = 14 THEN bytes ELSE 0 END) AS h14,
    SUM(CASE WHEN EXTRACT(HOUR FROM local_ts) = 15 THEN bytes ELSE 0 END) AS h15,
    SUM(CASE WHEN EXTRACT(HOUR FROM local_ts) = 16 THEN bytes ELSE 0 END) AS h16,
    SUM(CASE WHEN EXTRACT(HOUR FROM local_ts) = 17 THEN bytes ELSE 0 END) AS h17,
    SUM(CASE WHEN EXTRACT(HOUR FROM local_ts) = 18 THEN bytes ELSE 0 END) AS h18,
    SUM(CASE WHEN EXTRACT(HOUR FROM local_ts) = 19 THEN bytes ELSE 0 END) AS h19,
    SUM(CASE WHEN EXTRACT(HOUR FROM local_ts) = 20 THEN bytes ELSE 0 END) AS h20,
    SUM(CASE WHEN EXTRACT(HOUR FROM local_ts) = 21 THEN bytes ELSE 0 END) AS h21,
    SUM(CASE WHEN EXTRACT(HOUR FROM local_ts) = 22 THEN bytes ELSE 0 END) AS h22,
    SUM(CASE WHEN EXTRACT(HOUR FROM local_ts) = 23 THEN bytes ELSE 0 END) AS h23
FROM converted
GROUP BY ip_address
ORDER BY total_daily_bytes DESC;
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
-- Включаем сжатие для таблицы
ALTER TABLE %s SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'sampler_address, in_if, out_if', 
    timescaledb.compress_orderby = 'time_received DESC, src_addr, dst_addr'
);

-- Добавляем политику автоматического сжатия (сжимать данные старше 7 дней)
SELECT add_compression_policy('%s', INTERVAL '1 day');



CREATE INDEX idx_src_addr ON %s (src_addr);
CREATE INDEX idx_dst_addr ON %s (dst_addr);

CREATE INDEX idx_src_addr_gist ON %s USING gist (src_addr inet_ops);
CREATE INDEX idx_dst_addr_gist ON %s USING gist (dst_addr inet_ops);


SELECT add_continuous_aggregate_policy('flows_local_ip_outbound_hourly',
    start_offset => INTERVAL '365 days',
    end_offset => INTERVAL '1 hour',
    schedule_interval => INTERVAL '1 hour'
);

SELECT add_continuous_aggregate_policy('flows_local_ip_inbound_hourly',
    start_offset => INTERVAL '365 days',
    end_offset => INTERVAL '1 hour',
    schedule_interval => INTERVAL '1 hour'
);

-- Создаем 5-минутные агрегаты исходящего трафика
CREATE MATERIALIZED VIEW IF NOT EXISTS flows_local_ip_outbound_5m
WITH (timescaledb.continuous) AS
SELECT
    src_addr AS ip_address,
    time_bucket('5 minutes', time_received) AS bucket_5m,
    SUM(bytes) AS bytes_out,
    SUM(packets) AS packets_out
FROM %s
WHERE is_local_ip(src_addr)
GROUP BY src_addr, bucket_5m
WITH NO DATA;

-- Создаем 5-минутные агрегаты входящего трафика
CREATE MATERIALIZED VIEW IF NOT EXISTS flows_local_ip_inbound_5m
WITH (timescaledb.continuous) AS
SELECT
    dst_addr AS ip_address,
    time_bucket('5 minutes', time_received) AS bucket_5m,
    SUM(bytes) AS bytes_in,
    SUM(packets) AS packets_in
FROM %s
WHERE is_local_ip(dst_addr)
GROUP BY dst_addr, bucket_5m
WITH NO DATA;

SELECT add_continuous_aggregate_policy('flows_local_ip_outbound_5m',
    start_offset => INTERVAL '1 day', -- Храним 5-минутные данные 1 день (они много места занимают)
    end_offset => INTERVAL '1 minute', -- Ждем 1 минуту, чтобы "запоздавшие" потоки успели прийти
    schedule_interval => INTERVAL '1 minute' -- Обновляем каждую минуту
);

SELECT add_continuous_aggregate_policy('flows_local_ip_inbound_5m',
    start_offset => INTERVAL '1 day',
    end_offset => INTERVAL '1 minute',
    schedule_interval => INTERVAL '1 minute'
);

-- Посмотреть когда и сколько не/успешных запусков было
SELECT job_id, proc_name, last_run_started_at, last_successful_finish, total_runs, total_failures
FROM timescaledb_information.jobs j
JOIN timescaledb_information.job_stats js USING (job_id)
WHERE proc_name = 'policy_refresh_continuous_aggregate';


-- Таблица почасового потребления за сутки
SELECT
    ip_address,
    SUM(bytes_in + bytes_out) AS total_daily_bytes,
    -- Потребление за каждый час текущих суток (подставляем конкретные часы)
    SUM(CASE WHEN EXTRACT(HOUR FROM hour_bucket) = 0 THEN bytes_in + bytes_out ELSE 0 END) AS hour_00,
    SUM(CASE WHEN EXTRACT(HOUR FROM hour_bucket) = 1 THEN bytes_in + bytes_out ELSE 0 END) AS hour_01,
    SUM(CASE WHEN EXTRACT(HOUR FROM hour_bucket) = 2 THEN bytes_in + bytes_out ELSE 0 END) AS hour_02,
    SUM(CASE WHEN EXTRACT(HOUR FROM hour_bucket) = 3 THEN bytes_in + bytes_out ELSE 0 END) AS hour_03,
    SUM(CASE WHEN EXTRACT(HOUR FROM hour_bucket) = 4 THEN bytes_in + bytes_out ELSE 0 END) AS hour_04,
    SUM(CASE WHEN EXTRACT(HOUR FROM hour_bucket) = 5 THEN bytes_in + bytes_out ELSE 0 END) AS hour_05,
    SUM(CASE WHEN EXTRACT(HOUR FROM hour_bucket) = 6 THEN bytes_in + bytes_out ELSE 0 END) AS hour_06,
    SUM(CASE WHEN EXTRACT(HOUR FROM hour_bucket) = 7 THEN bytes_in + bytes_out ELSE 0 END) AS hour_07,
    SUM(CASE WHEN EXTRACT(HOUR FROM hour_bucket) = 8 THEN bytes_in + bytes_out ELSE 0 END) AS hour_08,
    SUM(CASE WHEN EXTRACT(HOUR FROM hour_bucket) = 9 THEN bytes_in + bytes_out ELSE 0 END) AS hour_09,
    SUM(CASE WHEN EXTRACT(HOUR FROM hour_bucket) = 10 THEN bytes_in + bytes_out ELSE 0 END) AS hour_10,
    SUM(CASE WHEN EXTRACT(HOUR FROM hour_bucket) = 11 THEN bytes_in + bytes_out ELSE 0 END) AS hour_11,
    SUM(CASE WHEN EXTRACT(HOUR FROM hour_bucket) = 12 THEN bytes_in + bytes_out ELSE 0 END) AS hour_12,
    SUM(CASE WHEN EXTRACT(HOUR FROM hour_bucket) = 13 THEN bytes_in + bytes_out ELSE 0 END) AS hour_13,
    SUM(CASE WHEN EXTRACT(HOUR FROM hour_bucket) = 14 THEN bytes_in + bytes_out ELSE 0 END) AS hour_14,
    SUM(CASE WHEN EXTRACT(HOUR FROM hour_bucket) = 15 THEN bytes_in + bytes_out ELSE 0 END) AS hour_15,
    SUM(CASE WHEN EXTRACT(HOUR FROM hour_bucket) = 16 THEN bytes_in + bytes_out ELSE 0 END) AS hour_16,
    SUM(CASE WHEN EXTRACT(HOUR FROM hour_bucket) = 17 THEN bytes_in + bytes_out ELSE 0 END) AS hour_17,
    SUM(CASE WHEN EXTRACT(HOUR FROM hour_bucket) = 18 THEN bytes_in + bytes_out ELSE 0 END) AS hour_18,
    SUM(CASE WHEN EXTRACT(HOUR FROM hour_bucket) = 19 THEN bytes_in + bytes_out ELSE 0 END) AS hour_19,
    SUM(CASE WHEN EXTRACT(HOUR FROM hour_bucket) = 20 THEN bytes_in + bytes_out ELSE 0 END) AS hour_20,
    SUM(CASE WHEN EXTRACT(HOUR FROM hour_bucket) = 21 THEN bytes_in + bytes_out ELSE 0 END) AS hour_21,
    SUM(CASE WHEN EXTRACT(HOUR FROM hour_bucket) = 22 THEN bytes_in + bytes_out ELSE 0 END) AS hour_22,
    SUM(CASE WHEN EXTRACT(HOUR FROM hour_bucket) = 23 THEN bytes_in + bytes_out ELSE 0 END) AS hour_23
FROM flows_local_ip_hourly
WHERE date_trunc('day', hour_bucket) = date_trunc('day', NOW())
GROUP BY ip_address
ORDER BY total_daily_bytes DESC;
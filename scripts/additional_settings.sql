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
    start_offset => INTERVAL '7 days', -- Храним 5-минутные данные 7 дней (они много места занимают)
    end_offset => INTERVAL '1 minute', -- Ждем 1 минуту, чтобы "запоздавшие" потоки успели прийти
    schedule_interval => INTERVAL '1 minute' -- Обновляем каждую минуту
);

SELECT add_continuous_aggregate_policy('flows_local_ip_inbound_5m',
    start_offset => INTERVAL '7 days',
    end_offset => INTERVAL '1 minute',
    schedule_interval => INTERVAL '1 minute'
);

-- Посмотреть когда и сколько не/успешных запусков было
SELECT job_id, proc_name, last_run_started_at, last_successful_finish, total_runs, total_failures
FROM timescaledb_information.jobs j
JOIN timescaledb_information.job_stats js USING (job_id)
WHERE proc_name = 'policy_refresh_continuous_aggregate';
-- Opslag voor de SDM630.
--   sdm630      alle metingen (5 s), gecomprimeerd na 7 dagen, bewaard 90 dagen
--   sdm630_1m   minuutwaarden, blijven bewaard
--   sdm630_1h   uurwaarden, blijven bewaard

CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE TABLE sdm630 (
    time              timestamptz NOT NULL,
    voltage_l1        double precision,
    voltage_l2        double precision,
    voltage_l3        double precision,
    current_l1        double precision,
    current_l2        double precision,
    current_l3        double precision,
    current_n         double precision,
    power_l1          double precision,
    power_l2          double precision,
    power_l3          double precision,
    power_total       double precision,
    frequency         double precision,
    energy_import     double precision,
    energy_export     double precision,
    energy_import_l1  double precision,
    energy_import_l2  double precision,
    energy_import_l3  double precision,
    current_thd_l1    double precision,
    current_thd_l2    double precision,
    current_thd_l3    double precision
);

SELECT create_hypertable('sdm630', 'time', chunk_time_interval => INTERVAL '7 days');

ALTER TABLE sdm630 SET (timescaledb.compress, timescaledb.compress_orderby = 'time DESC');
SELECT add_compression_policy('sdm630', INTERVAL '7 days');
SELECT add_retention_policy('sdm630', INTERVAL '90 days');

CREATE MATERIALIZED VIEW sdm630_1m
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT
    time_bucket('1 minute', time) AS bucket,
    avg(voltage_l1) AS voltage_l1_avg,
    avg(voltage_l2) AS voltage_l2_avg,
    avg(voltage_l3) AS voltage_l3_avg,
    max(current_l1) AS current_l1_max,
    max(current_l2) AS current_l2_max,
    max(current_l3) AS current_l3_max,
    max(current_n)  AS current_n_max,
    avg(power_l1)   AS power_l1_avg,
    avg(power_l2)   AS power_l2_avg,
    avg(power_l3)   AS power_l3_avg,
    avg(power_total) AS power_total_avg,
    max(power_total) AS power_total_max
FROM sdm630
GROUP BY bucket;

CREATE MATERIALIZED VIEW sdm630_1h
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT
    time_bucket('1 hour', time) AS bucket,
    avg(voltage_l1) AS voltage_l1_avg,
    avg(voltage_l2) AS voltage_l2_avg,
    avg(voltage_l3) AS voltage_l3_avg,
    max(current_l1) AS current_l1_max,
    max(current_l2) AS current_l2_max,
    max(current_l3) AS current_l3_max,
    max(current_n)  AS current_n_max,
    avg(power_l1)   AS power_l1_avg,
    avg(power_l2)   AS power_l2_avg,
    avg(power_l3)   AS power_l3_avg,
    avg(power_total) AS power_total_avg,
    max(power_total) AS power_total_max,
    last(energy_import, time)    AS energy_import,
    last(energy_export, time)    AS energy_export,
    last(energy_import_l1, time) AS energy_import_l1,
    last(energy_import_l2, time) AS energy_import_l2,
    last(energy_import_l3, time) AS energy_import_l3
FROM sdm630
GROUP BY bucket;

SELECT add_continuous_aggregate_policy('sdm630_1m',
    start_offset => INTERVAL '6 hours',
    end_offset => INTERVAL '1 minute',
    schedule_interval => INTERVAL '1 minute');

SELECT add_continuous_aggregate_policy('sdm630_1h',
    start_offset => INTERVAL '2 days',
    end_offset => INTERVAL '1 hour',
    schedule_interval => INTERVAL '30 minutes');

-- kWh per klokuur, uit de tellerstanden van de meter. Dat is nauwkeuriger dan
-- vermogen optellen, want niets tussen twee metingen valt weg.
-- whole_hour is false als er data ontbreekt; het verbruik uit die periode telt
-- dan wel mee in de totalen, maar niet in de gemiddelden per uur en weekdag.
-- Een tellerstand die daalt (nieuwe meter) telt als 0.
CREATE VIEW energy_hourly AS
SELECT
    bucket,
    greatest(energy_import    - lag(energy_import)    OVER w, 0) AS kwh_total,
    greatest(energy_export    - lag(energy_export)    OVER w, 0) AS kwh_export,
    greatest(energy_import_l1 - lag(energy_import_l1) OVER w, 0) AS kwh_l1,
    greatest(energy_import_l2 - lag(energy_import_l2) OVER w, 0) AS kwh_l2,
    greatest(energy_import_l3 - lag(energy_import_l3) OVER w, 0) AS kwh_l3,
    bucket - lag(bucket) OVER w = INTERVAL '1 hour' AS whole_hour
FROM sdm630_1h
WINDOW w AS (ORDER BY bucket);

-- Grafiekdata voor elke periode: gebruikt de fijnste bron die de periode aankan.
-- Stroom is de piek per interval, vermogen en spanning het gemiddelde.
CREATE FUNCTION energy_series(t_from timestamptz, t_to timestamptz, step_ms bigint)
RETURNS TABLE (
    "time" timestamptz,
    voltage_l1 double precision, voltage_l2 double precision, voltage_l3 double precision,
    current_l1 double precision, current_l2 double precision, current_l3 double precision,
    current_n  double precision,
    power_l1   double precision, power_l2 double precision, power_l3 double precision,
    power_total double precision
)
LANGUAGE sql STABLE AS $$
    WITH p AS (
        SELECT step_ms * INTERVAL '1 millisecond' AS step,
               t_to - t_from <= INTERVAL '6 hours'
                   AND t_from > now() - INTERVAL '89 days' AS use_raw,
               t_to - t_from <= INTERVAL '14 days' AS use_1m
    )
    SELECT time_bucket(greatest(p.step, INTERVAL '5 seconds'), s.time) AS t,
           avg(s.voltage_l1), avg(s.voltage_l2), avg(s.voltage_l3),
           max(s.current_l1), max(s.current_l2), max(s.current_l3), max(s.current_n),
           avg(s.power_l1), avg(s.power_l2), avg(s.power_l3), avg(s.power_total)
    FROM sdm630 s, p
    WHERE p.use_raw AND s.time >= t_from AND s.time < t_to
    GROUP BY t
    UNION ALL
    SELECT time_bucket(greatest(p.step, INTERVAL '1 minute'), m.bucket) AS t,
           avg(m.voltage_l1_avg), avg(m.voltage_l2_avg), avg(m.voltage_l3_avg),
           max(m.current_l1_max), max(m.current_l2_max), max(m.current_l3_max), max(m.current_n_max),
           avg(m.power_l1_avg), avg(m.power_l2_avg), avg(m.power_l3_avg), avg(m.power_total_avg)
    FROM sdm630_1m m, p
    WHERE NOT p.use_raw AND p.use_1m AND m.bucket >= t_from AND m.bucket < t_to
    GROUP BY t
    UNION ALL
    SELECT time_bucket(greatest(p.step, INTERVAL '1 hour'), h.bucket) AS t,
           avg(h.voltage_l1_avg), avg(h.voltage_l2_avg), avg(h.voltage_l3_avg),
           max(h.current_l1_max), max(h.current_l2_max), max(h.current_l3_max), max(h.current_n_max),
           avg(h.power_l1_avg), avg(h.power_l2_avg), avg(h.power_l3_avg), avg(h.power_total_avg)
    FROM sdm630_1h h, p
    WHERE NOT p.use_raw AND NOT p.use_1m AND h.bucket >= t_from AND h.bucket < t_to
    GROUP BY t
    ORDER BY 1
$$;

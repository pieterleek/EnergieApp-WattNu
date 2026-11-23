-- Begrensde variant van energy_hourly zodat queries met een starttijd alleen
-- het gevraagde bereik (+ de laatste uurrij ervoor voor lag()) uit sdm630_1h
-- lezen in plaats van de volledige meerjarige tabel te scannen.
CREATE OR REPLACE FUNCTION energy_hourly_range(t_from timestamptz)
RETURNS TABLE (
    bucket timestamptz,
    kwh_total double precision,
    kwh_export double precision,
    kwh_l1 double precision,
    kwh_l2 double precision,
    kwh_l3 double precision,
    whole_hour boolean
)
LANGUAGE sql STABLE AS $$
    WITH prev AS (
        SELECT max(h.bucket) AS start_bucket
        FROM sdm630_1h h
        WHERE h.bucket < t_from
    ),
    sliced AS (
        SELECT
            h.bucket,
            greatest(h.energy_import    - lag(h.energy_import)    OVER w, 0) AS kwh_total,
            greatest(h.energy_export    - lag(h.energy_export)    OVER w, 0) AS kwh_export,
            greatest(h.energy_import_l1 - lag(h.energy_import_l1) OVER w, 0) AS kwh_l1,
            greatest(h.energy_import_l2 - lag(h.energy_import_l2) OVER w, 0) AS kwh_l2,
            greatest(h.energy_import_l3 - lag(h.energy_import_l3) OVER w, 0) AS kwh_l3,
            h.bucket - lag(h.bucket) OVER w = INTERVAL '1 hour' AS whole_hour
        FROM sdm630_1h h, prev
        WHERE h.bucket >= coalesce(prev.start_bucket, t_from)
        WINDOW w AS (ORDER BY h.bucket)
    )
    SELECT bucket, kwh_total, kwh_export, kwh_l1, kwh_l2, kwh_l3, whole_hour
    FROM sliced
    WHERE bucket >= t_from
$$;

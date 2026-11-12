-- Keep the one-second engine cadence while the supported XAUUSD week is open,
-- but avoid invoking the Edge Function during the weekend and daily maintenance break.
-- The worker itself remains responsible for quote freshness and symbol-specific safety.
SELECT cron.alter_job(
  1,
  command := $job$
    SELECT net.http_post(
      url := (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'engine_worker_url'),
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'engine_worker_secret')
      ),
      body := '{}'::jsonb,
      timeout_milliseconds := 10000
    )
    WHERE (
      (
        EXTRACT(ISODOW FROM (now() AT TIME ZONE 'UTC')) BETWEEN 1 AND 5
        AND (
          (now() AT TIME ZONE 'UTC')::time < TIME '22:00'
          OR (now() AT TIME ZONE 'UTC')::time >= TIME '23:00'
        )
      )
      OR (
        EXTRACT(ISODOW FROM (now() AT TIME ZONE 'UTC')) = 7
        AND (now() AT TIME ZONE 'UTC')::time >= TIME '22:00'
      )
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.pf_engine_worker_runs
      WHERE worker_name = 'engine-tick'
        AND locked_until > now()
    );
  $job$
);

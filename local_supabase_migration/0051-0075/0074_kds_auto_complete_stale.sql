-- ═══════════════════════════════════════════════════════════════════
-- 0074  Auto-complete stale KDS tickets
-- ═══════════════════════════════════════════════════════════════════
-- Lines nobody bumps stay 'preparing' forever (708 open lines measured on a
-- live store). Every KDS refetches and redraws the whole open board on each
-- realtime event, on the same isolate that renders and sends print slips, so a
-- bloated board slows kitchen printing. It also pushes real open lines past
-- PostgREST's 1000-row cap, so they vanish from the board.
--
-- kds_auto_complete_stale() completes every open (preparing/ready) line of an
-- order whose NEWEST line is older than the cutoff. Keying on the newest line
-- means an order that just had items added (a long banquet, a held course) is
-- left alone. Cancelled lines are never touched. Order status is recomputed
-- through kds_recalc_order_status (0022), the single source of truth.
--
-- Cutoff in minutes comes from app_config key 'kds_auto_complete_minutes'
-- (JSON number); absent → 60, 0 or less → disabled.
--
-- Scheduled every 5 minutes when pg_cron is installed; otherwise run
-- `SELECT kds_auto_complete_stale();` periodically.
--
-- Idempotent: CREATE OR REPLACE / ON CONFLICT DO NOTHING / unschedule-then-schedule.
-- Applied MANUALLY against Supabase (see consolidator-migrations-manual).

INSERT INTO app_config (key, value)
VALUES ('kds_auto_complete_minutes', '60'::jsonb)
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION kds_auto_complete_stale()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_minutes INTEGER;
  v_order   BIGINT;
  v_count   INTEGER := 0;
BEGIN
  SELECT COALESCE((value #>> '{}')::INTEGER, 60) INTO v_minutes
    FROM app_config WHERE key = 'kds_auto_complete_minutes';
  v_minutes := COALESCE(v_minutes, 60);
  IF v_minutes <= 0 THEN
    RETURN 0;
  END IF;

  FOR v_order IN
    SELECT i.order_id
      FROM kds_order_items i
     GROUP BY i.order_id
    HAVING bool_or(i.status IN ('preparing', 'ready'))
       AND max(i.created_at) < now() - make_interval(mins => v_minutes)
  LOOP
    UPDATE kds_order_items
       SET status       = 'completed',
           completed_at = COALESCE(completed_at, now())
     WHERE order_id = v_order
       AND status IN ('preparing', 'ready');
    PERFORM kds_recalc_order_status(v_order);
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END $$;

GRANT EXECUTE ON FUNCTION kds_auto_complete_stale() TO anon, authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'kds-auto-complete-stale';
    PERFORM cron.schedule('kds-auto-complete-stale', '*/5 * * * *', 'SELECT kds_auto_complete_stale()');
  ELSE
    RAISE NOTICE 'pg_cron not installed: run SELECT kds_auto_complete_stale() periodically';
  END IF;
END $$;

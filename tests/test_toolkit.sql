-- =====================================================================
-- tests/test_toolkit.sql : data-quality and logic checks.
-- Each block raises an exception (and psql stops) if a check fails.
-- =====================================================================
SET search_path TO itops;
\set ON_ERROR_STOP on

-- 1. No ticket is resolved before it was opened, or after the reporting cut-off
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM ticket WHERE resolved_at < opened_at OR resolved_at > '2026-10-31 23:59') THEN
    RAISE EXCEPTION 'FAIL 1: resolution timestamps out of range';
  END IF;
  RAISE NOTICE 'PASS 1: resolution timestamps in range';
END $$;

-- 2. Every pause has a matching resume, and paused time never exceeds elapsed time
DO $$ BEGIN
  IF (SELECT count(*) FILTER (WHERE event_type = 'pending_customer')
           - count(*) FILTER (WHERE event_type = 'resumed') FROM ticket_event) <> 0 THEN
    RAISE EXCEPTION 'FAIL 2: unmatched pause events';
  END IF;
  IF EXISTS (SELECT 1 FROM v_ticket_sla WHERE resolve_min < 0) THEN
    RAISE EXCEPTION 'FAIL 2: paused time exceeds elapsed time';
  END IF;
  RAISE NOTICE 'PASS 2: pauses balanced and bounded';
END $$;

-- 3. Compliance in the view equals a direct recount from the base table
DO $$
DECLARE v_view numeric; v_raw numeric;
BEGIN
  SELECT round(100.0 * sum(met) / sum(resolved), 1) INTO v_view
  FROM v_monthly_sla_compliance WHERE report_month = '2026-10-01';

  SELECT round(100.0 * count(*) FILTER (WHERE extract(epoch FROM (t.resolved_at - t.opened_at)) / 60
                                        - v.paused_min <= s.resolve_min) / count(*), 1) INTO v_raw
  FROM ticket t JOIN sla_target s USING (ticket_type, priority) JOIN v_ticket_sla v USING (ticket_id)
  WHERE t.resolved_at >= '2026-10-01' AND t.resolved_at < '2026-11-01';

  IF v_view IS DISTINCT FROM v_raw THEN
    RAISE EXCEPTION 'FAIL 3: view says %, recount says %', v_view, v_raw;
  END IF;
  RAISE NOTICE 'PASS 3: October compliance % matches recount', v_view;
END $$;

-- 4. fn_sla_compliance over one month agrees with the monthly view
DO $$ BEGIN
  IF EXISTS (
      SELECT ticket_type, priority, resolved, met FROM fn_sla_compliance('2026-09-01', '2026-09-30')
      EXCEPT
      SELECT ticket_type, priority, resolved, met FROM v_monthly_sla_compliance WHERE report_month = '2026-09-01')
  THEN RAISE EXCEPTION 'FAIL 4: function and view disagree for September';
  END IF;
  RAISE NOTICE 'PASS 4: fn_sla_compliance matches v_monthly_sla_compliance';
END $$;

-- 5. fn_close_month is idempotent: running it twice leaves the same rows
DO $$
DECLARE n1 integer; n2 integer;
BEGIN
  PERFORM fn_close_month('2026-09-15');
  SELECT count(*) INTO n1 FROM sla_monthly_snapshot WHERE report_month = '2026-09-01';
  PERFORM fn_close_month('2026-09-01');
  SELECT count(*) INTO n2 FROM sla_monthly_snapshot WHERE report_month = '2026-09-01';
  IF n1 <> n2 OR n1 = 0 THEN RAISE EXCEPTION 'FAIL 5: % then % rows', n1, n2; END IF;
  RAISE NOTICE 'PASS 5: fn_close_month idempotent (% rows)', n1;
END $$;

-- 6. fn_breach_risk rejects a bad threshold and only returns open tickets
DO $$ BEGIN
  BEGIN
    PERFORM fn_breach_risk('2026-10-31', 1.5);
    RAISE EXCEPTION 'FAIL 6: threshold 1.5 was accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
  END;
  IF EXISTS (SELECT 1 FROM fn_breach_risk('2026-10-31 23:59', 0.1) r
             JOIN ticket t USING (ticket_no) WHERE t.resolved_at IS NOT NULL) THEN
    RAISE EXCEPTION 'FAIL 6: resolved ticket returned as at risk';
  END IF;
  RAISE NOTICE 'PASS 6: fn_breach_risk validates input and returns open tickets only';
END $$;

-- 7. Owner group matches the last assignment/escalation event
DO $$ BEGIN
  IF EXISTS (
      SELECT 1 FROM ticket t
      JOIN LATERAL (SELECT to_group_id FROM ticket_event e
                    WHERE e.ticket_id = t.ticket_id AND e.to_group_id IS NOT NULL
                    ORDER BY event_time DESC, event_id DESC LIMIT 1) last ON true
      WHERE last.to_group_id <> t.group_id)
  THEN RAISE EXCEPTION 'FAIL 7: owner group out of sync with events';
  END IF;
  RAISE NOTICE 'PASS 7: owner group consistent with event log';
END $$;

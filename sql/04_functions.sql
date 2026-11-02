-- =====================================================================
-- 04_functions.sql : PL/pgSQL helpers
--   fn_sla_compliance(from, to, type)  compliance for any date range
--   fn_breach_risk(as_of, threshold)   open tickets close to breaching
--   fn_close_month(month)              freeze a month into the snapshot table
--   fn_problem_candidates(days, min)   repeat incidents that deserve a problem record
-- =====================================================================
SET search_path TO itops;

CREATE OR REPLACE FUNCTION fn_sla_compliance(
    p_from date, p_to date, p_type text DEFAULT NULL)
RETURNS TABLE (ticket_type text, priority text, resolved bigint, met bigint,
               compliance_pct numeric, mttr_hours numeric)
LANGUAGE sql STABLE AS $$
    SELECT v.ticket_type, v.priority, count(*),
           count(*) FILTER (WHERE v.resolve_met),
           round(100.0 * count(*) FILTER (WHERE v.resolve_met) / count(*), 1),
           round(avg(v.resolve_min) / 60, 2)
    FROM itops.v_ticket_sla v
    WHERE v.resolved_at >= p_from AND v.resolved_at < p_to + 1
      AND (p_type IS NULL OR v.ticket_type = p_type)
    GROUP BY v.ticket_type, v.priority
    ORDER BY v.ticket_type, v.priority;
$$;

-- Open tickets that have used at least p_threshold (0-1) of their resolution target.
CREATE OR REPLACE FUNCTION fn_breach_risk(
    p_as_of timestamp, p_threshold numeric DEFAULT 0.75)
RETURNS TABLE (ticket_no text, priority text, owner_group text,
               used_pct numeric, minutes_left numeric, status text)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF p_threshold <= 0 OR p_threshold > 1 THEN
        RAISE EXCEPTION 'threshold must be between 0 and 1, got %', p_threshold;
    END IF;

    RETURN QUERY
    WITH o AS (
        SELECT v.ticket_no, v.priority, v.owner_group, v.resolve_target_min,
               extract(epoch FROM (p_as_of - v.opened_at)) / 60 - v.paused_min AS used_min
        FROM itops.v_ticket_sla v
        WHERE v.resolved_at IS NULL AND v.opened_at <= p_as_of
    )
    SELECT o.ticket_no, o.priority, o.owner_group,
           round(100 * o.used_min / o.resolve_target_min, 1),
           round(o.resolve_target_min - o.used_min, 0),
           CASE WHEN o.used_min > o.resolve_target_min THEN 'BREACHED' ELSE 'AT RISK' END
    FROM o
    WHERE o.used_min >= p_threshold * o.resolve_target_min
    ORDER BY o.used_min / o.resolve_target_min DESC;
END;
$$;

-- Freeze a month's figures. Re-running replaces that month only, so the
-- function is safe to schedule (e.g. pg_cron on the 1st of each month).
CREATE OR REPLACE FUNCTION fn_close_month(p_month date)
RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    v_month date := date_trunc('month', p_month)::date;
    v_rows  integer;
BEGIN
    DELETE FROM itops.sla_monthly_snapshot WHERE report_month = v_month;

    INSERT INTO itops.sla_monthly_snapshot
           (report_month, ticket_type, priority, measured, met, compliance_pct, mttr_hours)
    SELECT v_month, c.ticket_type, c.priority, c.resolved, c.met, c.compliance_pct, c.mttr_hours
    FROM itops.fn_sla_compliance(v_month, (v_month + interval '1 month - 1 day')::date) c;

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RAISE NOTICE 'Snapshot for % written: % rows', to_char(v_month, 'YYYY-MM'), v_rows;
    RETURN v_rows;
END;
$$;

-- Services with p_min_count or more incidents of the same root cause inside
-- any p_days window: the usual trigger for raising a problem ticket.
CREATE OR REPLACE FUNCTION fn_problem_candidates(p_days integer DEFAULT 7, p_min_count integer DEFAULT 4)
RETURNS TABLE (service text, root_cause text, window_start timestamp, incidents bigint)
LANGUAGE sql STABLE AS $$
    WITH inc AS (
        SELECT s.name AS service, t.root_cause, t.opened_at
        FROM itops.ticket t JOIN itops.service s USING (service_id)
        WHERE t.ticket_type = 'INC' AND t.root_cause IS NOT NULL
    ), windows AS (
        SELECT a.service, a.root_cause, a.opened_at AS window_start,
               (SELECT count(*) FROM inc b
                WHERE b.service = a.service AND b.root_cause = a.root_cause
                  AND b.opened_at >= a.opened_at
                  AND b.opened_at <  a.opened_at + make_interval(days => p_days)) AS n
        FROM inc a
    )
    SELECT DISTINCT ON (service, root_cause) service, root_cause, window_start, n
    FROM windows
    WHERE n >= p_min_count
    ORDER BY service, root_cause, n DESC, window_start;
$$;

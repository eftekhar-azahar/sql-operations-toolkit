-- =====================================================================
-- 05_analytics.sql : example analysis queries
-- Run after 01-04. Each query answers one operational question.
-- =====================================================================
SET search_path TO itops;
SET itops.as_of = '2026-10-31 23:59';

\echo '\n== Q1. Overall resolution SLA compliance by month (all ticket types) =='
SELECT report_month,
       sum(resolved) AS resolved,
       sum(met)      AS met,
       round(100.0 * sum(met) / sum(resolved), 1) AS compliance_pct
FROM v_monthly_sla_compliance
GROUP BY report_month
ORDER BY report_month;

\echo '\n== Q2. Month-over-month change in incident volume per service (LAG) =='
WITH m AS (
    SELECT service, month, incidents,
           lag(incidents) OVER (PARTITION BY service ORDER BY month) AS prev
    FROM v_service_reliability
)
SELECT service, month, incidents, prev AS previous_month,
       round(100.0 * (incidents - prev) / nullif(prev, 0), 1) AS change_pct
FROM m
WHERE month = date '2026-10-01'
ORDER BY incidents DESC;

\echo '\n== Q3. Resolution time percentiles by incident priority (hours) =='
SELECT priority,
       count(*) AS resolved,
       round((percentile_cont(0.5)  WITHIN GROUP (ORDER BY resolve_min) / 60)::numeric, 1) AS p50,
       round((percentile_cont(0.9)  WITHIN GROUP (ORDER BY resolve_min) / 60)::numeric, 1) AS p90,
       round((max(resolve_min) / 60)::numeric, 1) AS worst,
       round(resolve_target_min / 60.0, 1) AS target
FROM v_ticket_sla
WHERE ticket_type = 'INC' AND resolved_at IS NOT NULL
GROUP BY priority, resolve_target_min
ORDER BY priority;

\echo '\n== Q4. Which root causes drive breaches? (incidents, last 3 months) =='
SELECT t.root_cause,
       count(*) AS incidents,
       count(*) FILTER (WHERE NOT v.resolve_met) AS breached,
       round(100.0 * count(*) FILTER (WHERE NOT v.resolve_met) / count(*), 1) AS breach_rate_pct,
       rank() OVER (ORDER BY count(*) FILTER (WHERE NOT v.resolve_met) DESC) AS breach_rank
FROM v_ticket_sla v
JOIN ticket t USING (ticket_id)
WHERE v.ticket_type = 'INC' AND v.resolved_at >= date '2026-08-01'
GROUP BY t.root_cause
ORDER BY breached DESC;

\echo '\n== Q5. Reopen rate and its effect on MTTR (incidents) =='
SELECT CASE WHEN reopen_count > 0 THEN 'reopened' ELSE 'first-time fix' END AS outcome,
       count(*) AS incidents,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS share_pct,
       round(avg(resolve_min) / 60, 2) AS mttr_hours
FROM v_ticket_sla
WHERE ticket_type = 'INC' AND resolved_at IS NOT NULL
GROUP BY 1;

\echo '\n== Q6. Backlog ageing by owner group at the cut-off =='
SELECT * FROM v_backlog_aging ORDER BY open_tickets DESC;

\echo '\n== Q7. Open tickets at 50%+ of their target (fn_breach_risk) =='
SELECT status, count(*) AS tickets FROM fn_breach_risk('2026-10-31 23:59', 0.5) GROUP BY status;

\echo '\n== Q7b. Still savable: AT RISK tickets, closest to breach first =='
SELECT * FROM fn_breach_risk('2026-10-31 23:59', 0.5) WHERE status = 'AT RISK' LIMIT 10;

\echo '\n== Q8. Problem-ticket candidates: 4+ same-cause incidents in 7 days, top 10 =='
SELECT * FROM fn_problem_candidates(7, 4) ORDER BY incidents DESC LIMIT 10;

\echo '\n== Q9. Escalation load on L2/L3 groups =='
SELECT * FROM v_escalation_summary ORDER BY escalations_received DESC;

\echo '\n== Q10. Freeze October 2026 and read the snapshot back =='
SELECT fn_close_month('2026-10-01') AS rows_written;
SELECT ticket_type, priority, measured, met, compliance_pct, mttr_hours
FROM sla_monthly_snapshot WHERE report_month = '2026-10-01'
ORDER BY ticket_type, priority;

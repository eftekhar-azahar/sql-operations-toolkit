-- =====================================================================
-- 03_views.sql : five reporting views
--   v_ticket_sla             one row per ticket: SLA minutes used and outcome
--   v_monthly_sla_compliance month x type x priority compliance and MTTR
--   v_backlog_aging          open tickets by owner group and age bucket
--   v_service_reliability    MTTR and MTBF per service per month
--   v_escalation_summary     escalation and reassignment load per group
-- SLA clock here is 24x7 with customer-pending time excluded.
-- =====================================================================
SET search_path TO itops;

-- 1 -------------------------------------------------------------------
CREATE OR REPLACE VIEW v_ticket_sla AS
WITH pause_pairs AS (
    SELECT ticket_id, event_type, event_time,
           lead(event_time) OVER (PARTITION BY ticket_id ORDER BY event_time, event_id) AS next_time
    FROM ticket_event
    WHERE event_type IN ('pending_customer', 'resumed')
), paused AS (
    SELECT ticket_id,
           sum(extract(epoch FROM (next_time - event_time)) / 60) AS paused_min
    FROM pause_pairs
    WHERE event_type = 'pending_customer' AND next_time IS NOT NULL
    GROUP BY ticket_id
)
SELECT t.ticket_id, t.ticket_no, t.ticket_type, t.priority,
       s.name AS service, g.name AS owner_group,
       t.opened_at, t.first_response_at, t.resolved_at, t.reopen_count,
       st.response_min AS response_target_min,
       st.resolve_min  AS resolve_target_min,
       round(extract(epoch FROM (t.first_response_at - t.opened_at)) / 60, 1) AS response_min,
       round(coalesce(p.paused_min, 0), 1) AS paused_min,
       round(extract(epoch FROM (t.resolved_at - t.opened_at)) / 60
             - coalesce(p.paused_min, 0), 1) AS resolve_min,
       CASE WHEN st.response_min IS NULL OR t.first_response_at IS NULL THEN NULL
            ELSE extract(epoch FROM (t.first_response_at - t.opened_at)) / 60 <= st.response_min
       END AS response_met,
       CASE WHEN t.resolved_at IS NULL THEN NULL
            ELSE extract(epoch FROM (t.resolved_at - t.opened_at)) / 60
                 - coalesce(p.paused_min, 0) <= st.resolve_min
       END AS resolve_met
FROM ticket t
JOIN sla_target st USING (ticket_type, priority)
JOIN service s USING (service_id)
JOIN support_group g USING (group_id)
LEFT JOIN paused p USING (ticket_id);

-- 2 -------------------------------------------------------------------
CREATE OR REPLACE VIEW v_monthly_sla_compliance AS
SELECT date_trunc('month', resolved_at)::date AS report_month,
       ticket_type, priority,
       count(*)                                        AS resolved,
       count(*) FILTER (WHERE resolve_met)             AS met,
       count(*) FILTER (WHERE NOT resolve_met)         AS breached,
       round(100.0 * count(*) FILTER (WHERE resolve_met) / count(*), 1) AS compliance_pct,
       round(avg(resolve_min) / 60, 2)                 AS mttr_hours,
       round(100.0 * count(*) FILTER (WHERE response_met)
             / nullif(count(*) FILTER (WHERE response_met IS NOT NULL), 0), 1) AS response_pct
FROM v_ticket_sla
WHERE resolved_at IS NOT NULL
GROUP BY 1, 2, 3;

-- 3 -------------------------------------------------------------------
-- Ages are measured against the reporting cut-off, set per session:
--   SET itops.as_of = '2026-10-31 23:59';   (defaults to now())
CREATE OR REPLACE VIEW v_backlog_aging AS
WITH open_t AS (
    SELECT v.*,
           coalesce(nullif(current_setting('itops.as_of', true), '')::timestamp,
                    now()::timestamp) - v.opened_at AS age
    FROM v_ticket_sla v
    WHERE v.resolved_at IS NULL
)
SELECT owner_group,
       count(*)                                               AS open_tickets,
       count(*) FILTER (WHERE age <  interval '1 day')        AS "under_1d",
       count(*) FILTER (WHERE age >= interval '1 day'  AND age < interval '3 days')  AS "1_to_3d",
       count(*) FILTER (WHERE age >= interval '3 days' AND age < interval '7 days')  AS "3_to_7d",
       count(*) FILTER (WHERE age >= interval '7 days')       AS "over_7d",
       count(*) FILTER (WHERE extract(epoch FROM age) / 60 - paused_min > resolve_target_min)
                                                              AS already_breached
FROM open_t
GROUP BY owner_group;

-- 4 -------------------------------------------------------------------
-- MTBF = mean gap between consecutive P1/P2 incidents on the same service.
CREATE OR REPLACE VIEW v_service_reliability AS
WITH major AS (
    SELECT service, opened_at, resolve_min,
           opened_at - lag(opened_at) OVER (PARTITION BY service ORDER BY opened_at) AS gap
    FROM v_ticket_sla
    WHERE ticket_type = 'INC' AND priority IN ('P1', 'P2')
), inc AS (
    SELECT service, date_trunc('month', opened_at)::date AS month,
           count(*) AS incidents, avg(resolve_min) AS avg_resolve_min
    FROM v_ticket_sla
    WHERE ticket_type = 'INC'
    GROUP BY 1, 2
)
SELECT i.service, i.month, i.incidents,
       round(i.avg_resolve_min / 60, 2) AS mttr_hours,
       count(m.opened_at)               AS major_incidents,
       round(extract(epoch FROM avg(m.gap)) / 3600, 1) AS mtbf_hours
FROM inc i
LEFT JOIN major m
       ON m.service = i.service AND date_trunc('month', m.opened_at)::date = i.month
GROUP BY i.service, i.month, i.incidents, i.avg_resolve_min;

-- 5 -------------------------------------------------------------------
CREATE OR REPLACE VIEW v_escalation_summary AS
WITH per_ticket AS (
    SELECT ticket_id,
           count(*) FILTER (WHERE event_type = 'escalated') AS escalations
    FROM ticket_event
    GROUP BY ticket_id
)
SELECT g.name AS group_name, g.tier,
       count(e.event_id)                         AS escalations_received,
       count(DISTINCT e.ticket_id)               AS tickets_received,
       round(avg(pt.escalations), 2)             AS avg_hops_on_those_tickets,
       count(DISTINCT e.ticket_id) FILTER (WHERE t.reopen_count > 0) AS reopened_tickets
FROM support_group g
LEFT JOIN ticket_event e ON e.to_group_id = g.group_id AND e.event_type = 'escalated'
LEFT JOIN per_ticket pt  ON pt.ticket_id = e.ticket_id
LEFT JOIN ticket t       ON t.ticket_id = e.ticket_id
WHERE g.tier > 1
GROUP BY g.group_id, g.name, g.tier;

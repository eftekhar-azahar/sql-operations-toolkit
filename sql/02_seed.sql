-- =====================================================================
-- 02_seed.sql : synthetic data, May-October 2026 (about 2,400 tickets)
-- Every row is generated. No real customer, ticket or person appears.
-- =====================================================================
SET search_path TO itops;
DO $$ BEGIN PERFORM setseed(0.42); END $$;  -- same data on every run

INSERT INTO support_group VALUES
    (1, 'L1 Service Desk', 1),
    (2, 'L2 Application Support', 2),
    (3, 'L2 Cloud Operations', 2),
    (4, 'L3 Platform Engineering', 3),
    (5, 'Vendor Support', 3);

INSERT INTO service VALUES
    (1, 'Billing Platform', 'critical'),
    (2, 'Payment Gateway', 'critical'),
    (3, 'CRM Portal', 'high'),
    (4, 'Cloud Compute (ECS)', 'high'),
    (5, 'Customer Self-care App', 'medium'),
    (6, 'Data Warehouse', 'medium'),
    (7, 'Object Storage', 'medium'),
    (8, 'Email & Collaboration', 'low');

-- Illustrative targets in minutes (24x7 clock). Not from any real contract.
INSERT INTO sla_target VALUES
    ('INC', 'P1',  15,    240),
    ('INC', 'P2',  30,    480),
    ('INC', 'P3', 120,   1440),
    ('INC', 'P4', 240,   4320),
    ('SR',  'P3', 240,   2880),
    ('SR',  'P4', 480,   5760),
    ('CR',  'P2', NULL,  2880),
    ('CR',  'P3', NULL,  7200),
    ('PRB', 'P2', NULL, 14400),
    ('PRB', 'P3', NULL, 28800);

-- ---------------------------------------------------------------------
-- Tickets
-- ---------------------------------------------------------------------
WITH draw AS (
    SELECT g,
           random() AS r_type, random() AS r_prio, random() AS r_svc,
           random() AS r_open, random() AS r_resp, random() AS r_res,
           random() AS r_left_open, random() AS r_cause, random() AS r_hour
    FROM generate_series(1, 2400) AS g
), typed AS (
    SELECT d.*,
           CASE WHEN r_type < 0.55 THEN 'INC' WHEN r_type < 0.85 THEN 'SR'
                WHEN r_type < 0.95 THEN 'CR' ELSE 'PRB' END AS ticket_type,
           -- skew the service mix: billing and CRM get the most tickets
           (ARRAY[1,1,1,2,2,3,3,3,4,4,5,5,6,7,8])[1 + floor(r_svc * 15)::int] AS service_id,
           -- weekday-heavy arrival, busiest 09:00-18:00
           timestamp '2026-05-01' + (floor(r_open * 184) || ' days')::interval
               + make_interval(mins => CASE WHEN r_hour < 0.75
                                            THEN 540 + floor(random() * 540)::int
                                            ELSE floor(random() * 1440)::int END) AS opened_at
    FROM draw d
), prio AS (
    SELECT t.*,
           CASE ticket_type
             WHEN 'INC' THEN CASE WHEN r_prio < 0.03 THEN 'P1' WHEN r_prio < 0.15 THEN 'P2'
                                  WHEN r_prio < 0.65 THEN 'P3' ELSE 'P4' END
             WHEN 'SR'  THEN CASE WHEN r_prio < 0.60 THEN 'P3' ELSE 'P4' END
             WHEN 'CR'  THEN CASE WHEN r_prio < 0.30 THEN 'P2' ELSE 'P3' END
             ELSE            CASE WHEN r_prio < 0.40 THEN 'P2' ELSE 'P3' END
           END AS priority
    FROM typed t
)
INSERT INTO ticket (ticket_no, ticket_type, priority, service_id, group_id, opened_at,
                    first_response_at, resolved_at, root_cause)
SELECT p.ticket_type || '-' || to_char(p.opened_at, 'YYMM') || lpad(p.g::text, 5, '0'),
       p.ticket_type, p.priority, p.service_id,
       CASE WHEN p.ticket_type IN ('CR', 'PRB') THEN 4 ELSE 1 END,
       p.opened_at,
       CASE WHEN s.response_min IS NOT NULL THEN
            p.opened_at + make_interval(secs => s.response_min * 60 * (0.1 + power(p.r_resp, 2) * 1.25))
       END,
       -- some recent P3/P4 tickets are still open at the end of October
       CASE WHEN p.opened_at > timestamp '2026-10-21' AND p.priority IN ('P3', 'P4')
                 AND p.r_left_open < 0.25 THEN NULL
            ELSE p.opened_at + make_interval(secs => s.resolve_min * 60
                     * (0.12 + power(p.r_res, 1.6) * 1.05)
                     * CASE WHEN p.service_id = 2 THEN 0.8 WHEN p.service_id = 1 THEN 1.08 ELSE 1 END)
       END,
       CASE WHEN p.ticket_type = 'INC' THEN
            (ARRAY['Application defect', 'Configuration change', 'Capacity', 'Network',
                   'Third-party', 'Data issue', 'User error'])[1 + floor(p.r_cause * 7)::int]
       END
FROM prio p
JOIN sla_target s USING (ticket_type, priority)
ORDER BY p.opened_at;

-- Keep resolution inside the reporting window: anything after the cut-off is open.
UPDATE ticket SET resolved_at = NULL WHERE resolved_at > timestamp '2026-10-31 23:59';

-- ---------------------------------------------------------------------
-- Events: assignment, escalation, customer-pending pauses, reopens
-- ---------------------------------------------------------------------
INSERT INTO ticket_event (ticket_id, event_time, event_type, to_group_id)
SELECT ticket_id, opened_at, 'assigned', group_id FROM ticket;

-- ~35% of incidents and requests escalate from L1 to an L2 team
INSERT INTO ticket_event (ticket_id, event_time, event_type, to_group_id)
SELECT t.ticket_id,
       t.opened_at + (coalesce(t.resolved_at, timestamp '2026-10-31 23:59') - t.opened_at) * 0.2,
       'escalated',
       CASE WHEN t.service_id IN (4, 7) THEN 3 ELSE 2 END
FROM ticket t
WHERE t.ticket_type IN ('INC', 'SR') AND random() < 0.35;

-- ~25% of L2 escalations go on to L3 or the vendor
INSERT INTO ticket_event (ticket_id, event_time, event_type, to_group_id)
SELECT e.ticket_id, e.event_time + interval '2 hours', 'escalated',
       CASE WHEN random() < 0.7 THEN 4 ELSE 5 END
FROM ticket_event e
WHERE e.event_type = 'escalated' AND e.to_group_id IN (2, 3) AND random() < 0.25;

UPDATE ticket t SET group_id = last.to_group_id
FROM (SELECT DISTINCT ON (ticket_id) ticket_id, to_group_id
      FROM ticket_event ORDER BY ticket_id, event_time DESC, event_id DESC) last
WHERE last.ticket_id = t.ticket_id;

-- ~15% of resolved incidents and requests wait on the customer for 1-12 hours
WITH p AS (
    SELECT ticket_id,
           opened_at + (resolved_at - opened_at) * 0.4 AS pause_start,
           make_interval(mins => 60 + floor(random() * 660)::int) AS pause_len,
           resolved_at
    FROM ticket
    WHERE ticket_type IN ('INC', 'SR') AND resolved_at IS NOT NULL AND random() < 0.15
)
INSERT INTO ticket_event (ticket_id, event_time, event_type)
SELECT ticket_id, pause_start, 'pending_customer' FROM p
UNION ALL
SELECT ticket_id, least(pause_start + pause_len, resolved_at), 'resumed' FROM p;

INSERT INTO ticket_event (ticket_id, event_time, event_type)
SELECT ticket_id, resolved_at, 'resolved' FROM ticket WHERE resolved_at IS NOT NULL;

-- ~4% of resolved incidents are reopened within 3 days, then resolved again.
-- ticket.resolved_at always holds the FINAL resolution time.
CREATE TEMP TABLE reopen AS
SELECT ticket_id,
       resolved_at + make_interval(hours => 1 + floor(random() * 70)::int) AS reopened_at,
       make_interval(hours => 1 + floor(random() * 8)::int)              AS fix_time
FROM ticket
WHERE ticket_type = 'INC' AND resolved_at < timestamp '2026-10-25' AND random() < 0.04;

INSERT INTO ticket_event (ticket_id, event_time, event_type)
SELECT ticket_id, reopened_at, 'reopened' FROM reopen
UNION ALL
SELECT ticket_id, reopened_at + fix_time, 'resolved' FROM reopen;

UPDATE ticket t SET reopen_count = 1, resolved_at = r.reopened_at + r.fix_time
FROM reopen r WHERE r.ticket_id = t.ticket_id;

ANALYZE;

-- =====================================================================
-- 01_schema.sql : IT operations ticketing schema (PostgreSQL 13+)
-- Models incidents (INC), service requests (SR), change requests (CR)
-- and problems (PRB), with an event log for assignment, escalation,
-- customer-pending pauses and reopens.
-- =====================================================================

DROP SCHEMA IF EXISTS itops CASCADE;
CREATE SCHEMA itops;
SET search_path TO itops;

CREATE TABLE support_group (
    group_id    smallint PRIMARY KEY,
    name        text     NOT NULL UNIQUE,
    tier        smallint NOT NULL CHECK (tier BETWEEN 1 AND 3)
);

CREATE TABLE service (
    service_id  smallint PRIMARY KEY,
    name        text     NOT NULL UNIQUE,
    criticality text     NOT NULL CHECK (criticality IN ('critical', 'high', 'medium', 'low'))
);

CREATE TABLE sla_target (
    ticket_type     text     NOT NULL CHECK (ticket_type IN ('INC', 'SR', 'CR', 'PRB')),
    priority        text     NOT NULL CHECK (priority IN ('P1', 'P2', 'P3', 'P4')),
    response_min    integer  CHECK (response_min > 0),          -- NULL = no response target
    resolve_min     integer  NOT NULL CHECK (resolve_min > 0),
    PRIMARY KEY (ticket_type, priority)
);

CREATE TABLE ticket (
    ticket_id           integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ticket_no           text      NOT NULL UNIQUE,
    ticket_type         text      NOT NULL,
    priority            text      NOT NULL,
    service_id          smallint  NOT NULL REFERENCES service,
    group_id            smallint  NOT NULL REFERENCES support_group,   -- current owner
    opened_at           timestamp NOT NULL,
    first_response_at   timestamp,
    resolved_at         timestamp,
    root_cause          text,
    reopen_count        smallint  NOT NULL DEFAULT 0,
    FOREIGN KEY (ticket_type, priority) REFERENCES sla_target (ticket_type, priority),
    CHECK (first_response_at IS NULL OR first_response_at >= opened_at),
    CHECK (resolved_at IS NULL OR resolved_at >= opened_at)
);

CREATE TABLE ticket_event (
    event_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ticket_id    integer   NOT NULL REFERENCES ticket ON DELETE CASCADE,
    event_time   timestamp NOT NULL,
    event_type   text      NOT NULL CHECK (event_type IN
                 ('assigned', 'escalated', 'pending_customer', 'resumed', 'resolved', 'reopened')),
    to_group_id  smallint  REFERENCES support_group
);

-- Month-end snapshot written by fn_close_month() so a signed-off report never changes.
CREATE TABLE sla_monthly_snapshot (
    report_month     date    NOT NULL,
    ticket_type      text    NOT NULL,
    priority         text    NOT NULL,
    measured         integer NOT NULL,
    met              integer NOT NULL,
    compliance_pct   numeric(5,1),
    mttr_hours       numeric(8,2),
    captured_at      timestamp NOT NULL DEFAULT now(),
    PRIMARY KEY (report_month, ticket_type, priority)
);

CREATE INDEX ticket_opened_idx   ON ticket (opened_at);
CREATE INDEX ticket_open_idx     ON ticket (priority) WHERE resolved_at IS NULL;
CREATE INDEX ticket_service_idx  ON ticket (service_id, ticket_type, opened_at);
CREATE INDEX event_ticket_idx    ON ticket_event (ticket_id, event_time);

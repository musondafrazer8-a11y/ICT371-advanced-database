-- ICT371 Q6: Monthly Payroll Processing (schema q6)
DROP SCHEMA IF EXISTS q6 CASCADE;
CREATE SCHEMA q6;
SET search_path TO q6;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE employees (
    employee_id  SERIAL PRIMARY KEY,
    full_name    VARCHAR(100) NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
    deduction    NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
    active       BOOLEAN NOT NULL DEFAULT TRUE
);
CREATE TABLE payroll (
    payroll_id  SERIAL PRIMARY KEY,
    employee_id INT NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE NOT NULL,
    gross_pay   NUMERIC(12,2) NOT NULL,
    net_pay     NUMERIC(12,2) NOT NULL,
    CONSTRAINT ck_month_start CHECK (pay_month = date_trunc('month', pay_month)::date),
    CONSTRAINT uq_emp_month UNIQUE (employee_id, pay_month)
);
CREATE TABLE salary_audit (
    audit_id    SERIAL PRIMARY KEY,
    employee_id INT NOT NULL REFERENCES employees(employee_id),
    old_salary  NUMERIC(12,2) NOT NULL,
    new_salary  NUMERIC(12,2) NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
 ('Chanda Mwila',  8000, 1000, 1200, TRUE),
 ('Mutale Banda',  6500,  800,  900, TRUE),
 ('Natasha Phiri', 7200,  500, 1000, TRUE),
 ('Joseph Zulu',   5000,  400,  700, TRUE),    -- deactivated later; history is kept
 ('Mercy Tembo',   4800,  300,  600, FALSE);   -- inactive from the start

-- (b) Function -------------------------------------------------------------
CREATE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS NUMERIC LANGUAGE plpgsql SET search_path = q6 AS $$
DECLARE v_net NUMERIC;
BEGIN
    SELECT basic_salary + allowance - deduction INTO v_net
      FROM employees WHERE employee_id = p_employee_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee: %', p_employee_id;
    END IF;
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
    END IF;
    RETURN v_net;
END $$;

-- (c) Procedure: query FOR loop; any failure rolls back the whole call ---------
CREATE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql SET search_path = q6 AS $$
DECLARE r RECORD; v_net NUMERIC;
BEGIN
    IF p_month IS NULL OR p_month <> date_trunc('month', p_month)::date THEN
        RAISE EXCEPTION 'p_month must be the first day of a month, got %', p_month;
    END IF;
    FOR r IN SELECT employee_id, basic_salary, allowance
               FROM employees WHERE active ORDER BY employee_id
    LOOP
        v_net := fn_net_pay(r.employee_id);          -- raises on a bad calculation
        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (r.employee_id, p_month, r.basic_salary + r.allowance, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;   -- existing rows stay unchanged
    END LOOP;
END $$;

-- (d) Trigger ---------------------------------------------------------------
CREATE FUNCTION trg_salary_audit() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = q6 AS $$
BEGIN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary)
    VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary);
    RETURN NULL;
END $$;

CREATE TRIGGER trg_employees_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_salary_audit();

-- (e) View: joins on employee_id with no 'active' filter, so history stays ------
CREATE VIEW v_payroll_report AS
SELECT e.full_name, p.pay_month, p.gross_pay, p.net_pay
  FROM payroll p JOIN employees e ON e.employee_id = p.employee_id
 ORDER BY p.pay_month, e.full_name;

-- Seed payroll for two months, then deactivate one employee, then a third month --
CALL pr_process_payroll(DATE '2026-09-01');
CALL pr_process_payroll(DATE '2026-10-01');
UPDATE employees SET active = FALSE WHERE employee_id = 4;
UPDATE employees SET basic_salary = 8500 WHERE employee_id = 1;   -- audited
UPDATE employees SET allowance = 1100   WHERE employee_id = 1;    -- not a salary change: no audit
CALL pr_process_payroll(DATE '2026-11-01');
CALL pr_process_payroll(DATE '2026-11-01');   -- rerun: nothing duplicated or changed

-- Tests
SELECT fn_net_pay(1) AS net_employee_1;
DO $$ BEGIN PERFORM fn_net_pay(99);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_process_payroll(DATE '2026-12-15');   -- not a month start
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
-- Whole-call failure: make one employee's net negative, the call must insert nothing.
UPDATE employees SET deduction = 99999 WHERE employee_id = 3;
DO $$ BEGIN CALL pr_process_payroll(DATE '2026-12-01');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
SELECT COUNT(*) AS december_rows FROM payroll WHERE pay_month = DATE '2026-12-01';   -- 0
UPDATE employees SET deduction = 1000 WHERE employee_id = 3;                         -- restore
SELECT * FROM salary_audit;
SELECT * FROM v_payroll_report;   -- Joseph Zulu still shows for Sept and Oct

-- (f) Index -----------------------------------------------------------------
-- UNIQUE (employee_id, pay_month) leads with employee_id, so it cannot serve a
-- filter on pay_month alone. This index leads with pay_month and INCLUDEs the
-- report columns, so the monthly report can be an index-only scan. It does not
-- repeat the (employee_id, pay_month) pair, so nothing is duplicated.
CREATE INDEX idx_payroll_month ON payroll (pay_month) INCLUDE (employee_id, gross_pay, net_pay);
ANALYZE payroll;
SET enable_seqscan = off;
EXPLAIN
SELECT employee_id, gross_pay, net_pay FROM payroll WHERE pay_month = DATE '2026-10-01';
RESET enable_seqscan;

-- (g) Scheduled job: 02:00 on the 1st, for the previous month ------------------
DO $do$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('q6_process_payroll', '0 2 1 * *',
        $cmd$CALL q6.pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$cmd$);
  ELSE
    RAISE NOTICE 'pg_cron not installed. Schedule: 0 2 1 * *  CALL q6.pr_process_payroll(first day of previous month)';
  END IF;
END $do$;

-- Inspect the job and its run history (needs pg_cron):
--   SELECT jobid, jobname, schedule, command, active FROM cron.job WHERE jobname = 'q6_process_payroll';
--   SELECT jobid, status, return_message, start_time, end_time
--     FROM cron.job_run_details
--    WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'q6_process_payroll')
--    ORDER BY start_time DESC;
-- Remove it:  SELECT cron.unschedule('q6_process_payroll');

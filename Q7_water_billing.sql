-- ICT371 Q7: Water Meter Readings and Billing (schema q7)
DROP SCHEMA IF EXISTS q7 CASCADE;
CREATE SCHEMA q7;
SET search_path TO q7;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);
CREATE TABLE readings (
    reading_id       SERIAL PRIMARY KEY,
    customer_id      INT NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE NOT NULL,
    previous_reading NUMERIC(10,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(10,2) NOT NULL CHECK (current_reading >= 0),
    CONSTRAINT ck_reading_month CHECK (reading_month = date_trunc('month', reading_month)::date),
    CONSTRAINT uq_customer_month UNIQUE (customer_id, reading_month)
);
CREATE TABLE bills (
    bill_id     SERIAL PRIMARY KEY,
    reading_id  INT NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_on      DATE NOT NULL,
    CONSTRAINT ck_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);
CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     NUMERIC(14,2) NOT NULL
);

INSERT INTO customers (full_name) VALUES ('Chanda Mwila'), ('Mutale Banda'), ('Natasha Phiri');

-- (b) Function: first 10 units K5, units above 10 K8 ---------------------------
CREATE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12,2) LANGUAGE plpgsql SET search_path = q7 AS $$
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Invalid consumption: %', p_units;
    END IF;
    IF p_units <= 10 THEN
        RETURN ROUND(p_units * 5, 2);
    END IF;
    RETURN ROUND(10 * 5 + (p_units - 10) * 8, 2);
END $$;

-- (c) Procedure -------------------------------------------------------------
CREATE PROCEDURE pr_generate_bill(p_reading_id INT, p_due_on DATE)
LANGUAGE plpgsql SET search_path = q7 AS $$
DECLARE v_prev NUMERIC; v_cur NUMERIC;
BEGIN
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date is required';
    END IF;
    SELECT previous_reading, current_reading INTO v_prev, v_cur
      FROM readings WHERE reading_id = p_reading_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading: %', p_reading_id;
    END IF;
    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;
    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, fn_water_charge(v_cur - v_prev), 0, p_due_on);
END $$;

-- (d) Trigger: rejected readings are never stored ------------------------------
CREATE FUNCTION trg_reading_check() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = q7 AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'Current reading (%) is below previous reading (%)',
              NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_readings_check
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW EXECUTE FUNCTION trg_reading_check();

-- Seed readings after the trigger: zero, exactly 10, and above 10 units ---------
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
 (1, DATE '2026-09-01', 100,  100),    -- 0 units   -> K0
 (1, DATE '2026-10-01', 100,  110),    -- 10 units  -> K50
 (2, DATE '2026-09-01',  50,   65),    -- 15 units  -> K90
 (2, DATE '2026-10-01',  65, 95.5),    -- 30.5      -> K294
 (3, DATE '2026-09-01',  10,   20),    -- 10 units  -> K50
 (3, DATE '2026-10-01',  20,   28);    -- 8 units   -> K40

-- Bills through the procedure; some due dates are in the past
CALL pr_generate_bill(1, CURRENT_DATE - 40);
CALL pr_generate_bill(2, CURRENT_DATE - 20);
CALL pr_generate_bill(3, CURRENT_DATE - 25);
CALL pr_generate_bill(4, CURRENT_DATE - 5);
CALL pr_generate_bill(5, CURRENT_DATE - 15);
CALL pr_generate_bill(6, CURRENT_DATE + 10);     -- not yet due
UPDATE bills SET amount_paid = charge WHERE reading_id = 2;   -- settled
UPDATE bills SET amount_paid = 40     WHERE reading_id = 3;   -- partly paid

-- Tests
SELECT fn_water_charge(0) a, fn_water_charge(10) b, fn_water_charge(15) c, fn_water_charge(30.5) d;
DO $$ BEGIN PERFORM fn_water_charge(NULL);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_water_charge(-1);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_generate_bill(1, CURRENT_DATE);     -- already billed
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_generate_bill(999, CURRENT_DATE);   -- unknown
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
            VALUES (1, DATE '2026-11-01', 110, 105);    -- direct import, backwards meter
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
SELECT COUNT(*) AS readings_stored FROM readings;       -- still 6

-- (e) View ------------------------------------------------------------------
CREATE VIEW v_overdue_bills AS
SELECT c.full_name, b.due_on, b.charge - b.amount_paid AS outstanding_amount
  FROM bills b
  JOIN readings r ON r.reading_id = b.reading_id
  JOIN customers c ON c.customer_id = r.customer_id
 WHERE b.due_on < CURRENT_DATE AND b.amount_paid < b.charge;
SELECT * FROM v_overdue_bills;

-- (f) Index -----------------------------------------------------------------
-- Partial index on due_on covering only unpaid bills: the overdue search is a
-- range on due_on over unpaid rows, and paid bills (the majority over time)
-- are left out, which keeps the index small and fast.
CREATE INDEX idx_bills_unpaid_due ON bills (due_on) WHERE amount_paid < charge;
ANALYZE bills;
SET enable_seqscan = off;
EXPLAIN
SELECT bill_id, due_on, charge - amount_paid AS outstanding
  FROM bills
 WHERE amount_paid < charge AND due_on < CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job -----------------------------------------------------------
CREATE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql SET search_path = q7 AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0)
      FROM bills WHERE amount_paid < charge
    ON CONFLICT (snapshot_date) DO UPDATE SET total_due = EXCLUDED.total_due;
END $$;

CALL pr_refresh_receivables();
CALL pr_refresh_receivables();    -- rerun replaces today's total
SELECT * FROM receivable_snapshot;

DO $do$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('q7_refresh_receivables', '30 0 * * *',
        $cmd$CALL q7.pr_refresh_receivables()$cmd$);
  ELSE
    RAISE NOTICE 'pg_cron not installed. Schedule: 30 0 * * *  CALL q7.pr_refresh_receivables()';
  END IF;
END $do$;

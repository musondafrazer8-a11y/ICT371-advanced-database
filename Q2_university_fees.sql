-- ICT371 Q2: University Fee Payments (schema q2)
DROP SCHEMA IF EXISTS q2 CASCADE;
CREATE SCHEMA q2;
SET search_path TO q2;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL,
    fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);
CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INT NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on    DATE NOT NULL
);
CREATE TABLE payment_audit (
    audit_id   SERIAL PRIMARY KEY,
    payment_id INT NOT NULL REFERENCES payments(payment_id),
    student_id INT NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL,
    logged_at  TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count   INT NOT NULL,
    total_amount    NUMERIC(12,2) NOT NULL
);

INSERT INTO students (student_number, full_name, fee_due) VALUES
 ('2026001', 'Chanda Mwila',   5000.00),
 ('2026002', 'Mutale Banda',   3000.00),
 ('2026003', 'Natasha Phiri',  2000.00);     -- will have no payments

-- (b) Function -------------------------------------------------------------
CREATE FUNCTION fn_fee_balance(p_student_id INT)
RETURNS NUMERIC LANGUAGE plpgsql SET search_path = q2 AS $$
DECLARE v_fee NUMERIC;
BEGIN
    SELECT fee_due INTO v_fee FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student: %', p_student_id;
    END IF;
    RETURN v_fee - COALESCE((SELECT SUM(amount) FROM payments
                              WHERE student_id = p_student_id), 0);
END $$;

-- (c) Procedure (does NOT write the audit row; the trigger does) -------------
CREATE PROCEDURE pr_receive_payment(p_student_id INT, p_amount NUMERIC, p_paid_on DATE)
LANGUAGE plpgsql SET search_path = q2 AS $$
DECLARE v_balance NUMERIC;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Payment amount must be greater than zero';
    END IF;
    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;  -- serialise per student
    v_balance := fn_fee_balance(p_student_id);                          -- raises if unknown
    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment % exceeds outstanding balance %', p_amount, v_balance;
    END IF;
    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, COALESCE(p_paid_on, CURRENT_DATE));
END $$;

-- (d) Trigger ---------------------------------------------------------------
CREATE FUNCTION trg_payment_audit() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = q2 AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
    RETURN NULL;
END $$;

CREATE TRIGGER trg_payments_audit
AFTER INSERT ON payments
FOR EACH ROW EXECUTE FUNCTION trg_payment_audit();

-- (e) View ------------------------------------------------------------------
CREATE VIEW v_fee_balances AS
SELECT s.student_number, s.full_name,
       s.fee_due - COALESCE(SUM(p.amount), 0) AS outstanding_balance
  FROM students s
  LEFT JOIN payments p ON p.student_id = s.student_id
 GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount), 0) > 0;

-- Seed payments through the procedure (six; student 3 has none) -------------
CALL pr_receive_payment(1, 1500, CURRENT_DATE - 3);
CALL pr_receive_payment(1, 1000, CURRENT_DATE - 2);
CALL pr_receive_payment(1,  500, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1000, CURRENT_DATE - 3);
CALL pr_receive_payment(2, 1000, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1000, CURRENT_DATE - 1);   -- student 2 is now fully settled

-- Tests
SELECT fn_fee_balance(1) AS bal_1, fn_fee_balance(2) AS bal_2, fn_fee_balance(3) AS bal_3_full_fee;
DO $$ BEGIN CALL pr_receive_payment(1, 99999, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_payment(1, 0, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_payment(1, NULL, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
SELECT * FROM students;                       -- fee_due unchanged
SELECT * FROM payment_audit ORDER BY audit_id; -- six rows written by the trigger
SELECT * FROM v_fee_balances;                  -- student 2 excluded

-- (f) Index -----------------------------------------------------------------
-- student_id is an equality filter and paid_on a range, so (student_id, paid_on)
-- lets one index scan jump to the student and read only the date range, in order.
CREATE INDEX idx_payments_student_paid_on ON payments (student_id, paid_on);
ANALYZE payments;
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM payments
 WHERE student_id = 1 AND paid_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job ---------------------------------------------------------
CREATE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql SET search_path = q2 AS $$
BEGIN
    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
      FROM payments WHERE paid_on = p_day
    ON CONFLICT (collection_date) DO UPDATE
       SET payment_count = EXCLUDED.payment_count, total_amount = EXCLUDED.total_amount;
END $$;

CALL pr_refresh_collections(CURRENT_DATE - 1);
CALL pr_refresh_collections(CURRENT_DATE - 1);  -- rerun replaces the row
SELECT * FROM daily_collections;

DO $do$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('q2_refresh_collections', '0 1 * * *',
        $cmd$CALL q2.pr_refresh_collections(CURRENT_DATE - 1)$cmd$);
  ELSE
    RAISE NOTICE 'pg_cron not installed. Schedule: 0 1 * * *  CALL q2.pr_refresh_collections(CURRENT_DATE - 1)';
  END IF;
END $do$;

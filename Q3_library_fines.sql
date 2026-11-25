-- ICT371 Q3: Library Returns and Overdue Fines (schema q3)
DROP SCHEMA IF EXISTS q3 CASCADE;
CREATE SCHEMA q3;
SET search_path TO q3;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title   VARCHAR(150) NOT NULL
);
CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    book_id       INT NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100) NOT NULL,
    borrowed_on   DATE NOT NULL,
    due_on        DATE NOT NULL,
    returned_on   DATE NULL,
    fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CONSTRAINT ck_due_after_borrow CHECK (due_on >= borrowed_on)
);
CREATE TABLE loan_audit (
    audit_id         SERIAL PRIMARY KEY,
    loan_id          INT NOT NULL REFERENCES loans(loan_id),
    old_returned_on  DATE NULL,
    new_returned_on  DATE NULL,
    changed_at       TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INT NOT NULL,
    total_fine    NUMERIC(12,2) NOT NULL
);

INSERT INTO books (title) VALUES
 ('Database System Concepts'), ('Introduction to Algorithms'), ('Computer Networks');

-- (b) Function: K2 per full day after the due date, minimum zero --------------
CREATE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE)
RETURNS NUMERIC LANGUAGE plpgsql SET search_path = q3 AS $$
DECLARE v_due DATE; v_ret DATE; v_end DATE;
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of must not be NULL';
    END IF;
    SELECT due_on, returned_on INTO v_due, v_ret FROM loans WHERE loan_id = p_loan_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan: %', p_loan_id;
    END IF;
    v_end := LEAST(p_as_of, COALESCE(v_ret, p_as_of));   -- earlier of as-of and return date
    RETURN 2 * GREATEST(v_end - v_due, 0);
END $$;

-- (c) Procedure: return date and final fine are stored in ONE update ----------
CREATE PROCEDURE pr_return_loan(p_loan_id INT, p_returned_on DATE)
LANGUAGE plpgsql SET search_path = q3 AS $$
DECLARE v_borrowed DATE; v_ret DATE; v_fine NUMERIC;
BEGIN
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Return date is required';
    END IF;
    SELECT borrowed_on, returned_on INTO v_borrowed, v_ret
      FROM loans WHERE loan_id = p_loan_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan: %', p_loan_id;
    END IF;
    IF v_ret IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_ret;
    END IF;
    IF p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date % is before borrow date %', p_returned_on, v_borrowed;
    END IF;
    v_fine := fn_loan_fine(p_loan_id, p_returned_on);    -- loan still open: uses p_returned_on
    UPDATE loans SET returned_on = p_returned_on, fine_amount = v_fine
     WHERE loan_id = p_loan_id;
END $$;

-- (d) Trigger ---------------------------------------------------------------
CREATE FUNCTION trg_loan_return_audit() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = q3 AS $$
BEGIN
    INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on)
    VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on);
    RETURN NULL;
END $$;

CREATE TRIGGER trg_loans_return_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION trg_loan_return_audit();

-- (e) View ------------------------------------------------------------------
CREATE VIEW v_overdue_loans AS
SELECT b.title, l.borrower_name, l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
  FROM loans l JOIN books b ON b.book_id = l.book_id
 WHERE l.returned_on IS NULL AND l.due_on < CURRENT_DATE;

-- Seed: six loans (all start open), then three are returned via the procedure --
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
 (1, 'Chanda Mwila',  CURRENT_DATE - 30, CURRENT_DATE - 16),  -- 1 open, overdue
 (2, 'Mutale Banda',  CURRENT_DATE - 20, CURRENT_DATE - 6),   -- 2 returned on time
 (3, 'Natasha Phiri', CURRENT_DATE - 25, CURRENT_DATE - 11),  -- 3 returned late
 (1, 'Joseph Zulu',   CURRENT_DATE - 3,  CURRENT_DATE + 11),  -- 4 open, not yet due
 (2, 'Mercy Tembo',   CURRENT_DATE - 18, CURRENT_DATE - 4),   -- 5 open, overdue
 (3, 'Peter Lungu',   CURRENT_DATE - 10, CURRENT_DATE - 2);   -- 6 returned ON the due date

CALL pr_return_loan(2, CURRENT_DATE - 8);    -- before due: fine 0
CALL pr_return_loan(3, CURRENT_DATE - 6);    -- 5 days late: fine K10
CALL pr_return_loan(6, CURRENT_DATE - 2);    -- on due date: fine 0

-- Tests
SELECT loan_id, fn_loan_fine(loan_id, CURRENT_DATE) AS fine_today, fine_amount FROM loans ORDER BY 1;
DO $$ BEGIN CALL pr_return_loan(3, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_return_loan(999, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_return_loan(1, CURRENT_DATE - 100);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
UPDATE loans SET returned_on = returned_on WHERE loan_id = 2;   -- unchanged: no audit row
SELECT * FROM loan_audit ORDER BY audit_id;                     -- exactly three rows
SELECT * FROM v_overdue_loans;

-- (f) Index -----------------------------------------------------------------
-- Partial index: only unreturned loans are indexed, so it stays small as the
-- history of returned loans grows, and it is keyed on book_id for the lookup.
CREATE INDEX idx_loans_unreturned_book ON loans (book_id) WHERE returned_on IS NULL;
ANALYZE loans;
SET enable_seqscan = off;
EXPLAIN
SELECT loan_id, borrower_name, due_on FROM loans
 WHERE book_id = 1 AND returned_on IS NULL;
RESET enable_seqscan;

-- (g) Scheduled job ---------------------------------------------------------
-- Counts loans unreturned as of p_as_of that are past their due date.
CREATE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql SET search_path = q3 AS $$
BEGIN
    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of, COUNT(*), COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
      FROM loans
     WHERE borrowed_on <= p_as_of
       AND (returned_on IS NULL OR returned_on > p_as_of)
       AND due_on < p_as_of
    ON CONFLICT (snapshot_date) DO UPDATE
       SET overdue_count = EXCLUDED.overdue_count, total_fine = EXCLUDED.total_fine;
END $$;

CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);   -- rerun replaces the same snapshot_date
SELECT * FROM overdue_summary;

DO $do$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('q3_refresh_overdue', '10 0 * * *',
        $cmd$CALL q3.pr_refresh_overdue(CURRENT_DATE)$cmd$);
  ELSE
    RAISE NOTICE 'pg_cron not installed. Schedule: 10 0 * * *  CALL q3.pr_refresh_overdue(CURRENT_DATE)';
  END IF;
END $do$;

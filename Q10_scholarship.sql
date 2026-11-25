-- ICT371 Q10: Scholarship Application Assessment (schema q10)
DROP SCHEMA IF EXISTS q10 CASCADE;
CREATE SCHEMA q10;
SET search_path TO q10;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);
CREATE TABLE applications (
    application_id      SERIAL PRIMARY KEY,
    student_id          INT NOT NULL REFERENCES students(student_id),
    age_at_application  INT NOT NULL CHECK (age_at_application > 0),
    monthly_income      NUMERIC(12,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark        NUMERIC(5,2) NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on        DATE NOT NULL,
    status              VARCHAR(10) NOT NULL DEFAULT 'PENDING',
    CONSTRAINT ck_app_status CHECK (status IN ('PENDING','APPROVED','REJECTED'))
);
CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INT NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(10) NOT NULL,
    new_status     VARCHAR(10) NOT NULL,
    changed_at     TIMESTAMP NOT NULL DEFAULT now()
);

INSERT INTO students (student_number, full_name) VALUES
 ('2026001','Chanda Mwila'), ('2026002','Mutale Banda'), ('2026003','Natasha Phiri');

-- Six PENDING applications: clear pass, three boundary passes/fails, two clear fails
INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
 (1, 20, 1500.00, 85.00, CURRENT_DATE - 10, 'PENDING'),  -- 1 qualifies
 (2, 18, 3000.00, 70.00, CURRENT_DATE - 9,  'PENDING'),  -- 2 qualifies (all three at the boundary)
 (2, 25, 2000.00, 75.00, CURRENT_DATE - 8,  'PENDING'),  -- 3 qualifies (age 25 inclusive)
 (3, 17, 1000.00, 90.00, CURRENT_DATE - 7,  'PENDING'),  -- 4 fails: too young
 (3, 22, 3000.01, 80.00, CURRENT_DATE - 6,  'PENDING'),  -- 5 fails: income just over
 (1, 23, 2500.00, 69.99, CURRENT_DATE - 5,  'PENDING');  -- 6 fails: mark just under

-- (b) Function -------------------------------------------------------------
CREATE FUNCTION fn_scholarship_eligible(p_age INT, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN LANGUAGE plpgsql SET search_path = q10 AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark must not be NULL';
    END IF;
    IF p_age <= 0 THEN RAISE EXCEPTION 'Age must be positive, got %', p_age; END IF;
    IF p_income < 0 THEN RAISE EXCEPTION 'Income must not be negative, got %', p_income; END IF;
    IF p_mark < 0 OR p_mark > 100 THEN RAISE EXCEPTION 'Mark must be 0 to 100, got %', p_mark; END IF;
    RETURN p_age BETWEEN 18 AND 25 AND p_income <= 3000 AND p_mark >= 70;
END $$;

-- (c) Procedure -------------------------------------------------------------
CREATE PROCEDURE pr_assess_application(p_application_id INT)
LANGUAGE plpgsql SET search_path = q10 AS $$
DECLARE v_app applications%ROWTYPE;
BEGIN
    SELECT * INTO v_app FROM applications
     WHERE application_id = p_application_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Application % does not exist', p_application_id;
    END IF;
    IF v_app.status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % was already assessed (status %)', p_application_id, v_app.status;
    END IF;
    UPDATE applications
       SET status = CASE WHEN fn_scholarship_eligible(v_app.age_at_application,
                                                      v_app.monthly_income,
                                                      v_app.average_mark)
                         THEN 'APPROVED' ELSE 'REJECTED' END
     WHERE application_id = p_application_id;
END $$;

-- (d) Trigger ---------------------------------------------------------------
CREATE FUNCTION trg_decision_audit() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = q10 AS $$
BEGIN
    INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
    VALUES (OLD.application_id, OLD.status, NEW.status, now());
    RETURN NULL;
END $$;

CREATE TRIGGER trg_applications_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_decision_audit();

-- (e) View: approved only, income deliberately omitted -------------------------
CREATE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status
  FROM applications a JOIN students s ON s.student_id = a.student_id
 WHERE a.status = 'APPROVED';

-- Tests (before the batch job)
SELECT fn_scholarship_eligible(18, 3000, 70) AS boundary_ok,
       fn_scholarship_eligible(26, 1000, 90) AS too_old;
DO $$ BEGIN PERFORM fn_scholarship_eligible(NULL, 1000, 80);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, -1, 80);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, 1000, 101);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
CALL pr_assess_application(1);                       -- single assessment
DO $$ BEGIN CALL pr_assess_application(1);          -- already assessed
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_assess_application(999);        -- unknown
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
UPDATE applications SET status = status WHERE application_id = 1;   -- unchanged: no audit row

-- (f) Index -----------------------------------------------------------------
-- Equality on status first, then the range on submitted_on: the index narrows to
-- one status and then reads the date range in order, with no extra sort.
CREATE INDEX idx_applications_status_submitted ON applications (status, submitted_on);
ANALYZE applications;
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM applications
 WHERE status = 'PENDING' AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Batch job: only PENDING rows are visited, so reruns do nothing new --------
CREATE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql SET search_path = q10 AS $$
DECLARE r RECORD;
BEGIN
    FOR r IN SELECT application_id FROM applications
              WHERE status = 'PENDING' ORDER BY application_id
    LOOP
        CALL pr_assess_application(r.application_id);
    END LOOP;
END $$;

CALL pr_assess_pending();
CALL pr_assess_pending();                  -- rerun: nothing pending, no new audit rows
SELECT application_id, status FROM applications ORDER BY 1;   -- 1,2,3 APPROVED; 4,5,6 REJECTED
SELECT * FROM decision_audit ORDER BY audit_id;               -- exactly six rows
SELECT * FROM v_approved_applicants;

DO $do$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('q10_assess_pending', '0 8 * * 1',
        $cmd$CALL q10.pr_assess_pending()$cmd$);
  ELSE
    RAISE NOTICE 'pg_cron not installed. Schedule: 0 8 * * 1  CALL q10.pr_assess_pending()';
  END IF;
END $do$;

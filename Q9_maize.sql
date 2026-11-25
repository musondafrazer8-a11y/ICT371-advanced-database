-- ICT371 Q9: Farmer Cooperative Maize Deliveries (schema q9)
DROP SCHEMA IF EXISTS q9 CASCADE;
CREATE SCHEMA q9;
SET search_path TO q9;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE farmers (
    farmer_id     SERIAL PRIMARY KEY,
    farmer_number VARCHAR(20) NOT NULL UNIQUE,
    full_name     VARCHAR(100) NOT NULL
);
CREATE TABLE deliveries (
    delivery_id  SERIAL PRIMARY KEY,
    farmer_id    INT NOT NULL REFERENCES farmers(farmer_id),
    grade        CHAR(1) NOT NULL CHECK (grade IN ('A','B','C')),
    weight_kg    NUMERIC(10,2) NOT NULL CHECK (weight_kg > 0),
    unit_rate    NUMERIC(8,2)  NOT NULL,       -- filled by the trigger
    total_value  NUMERIC(14,2) NOT NULL,       -- filled by the trigger
    delivered_on DATE NOT NULL,
    is_paid      BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight  NUMERIC(14,2) NOT NULL,
    total_value   NUMERIC(14,2) NOT NULL
);

INSERT INTO farmers (farmer_number, full_name) VALUES
 ('F001','Chanda Mwila'), ('F002','Mutale Banda'), ('F003','Natasha Phiri');

-- (b) Function -------------------------------------------------------------
CREATE FUNCTION fn_maize_rate(p_grade TEXT)
RETURNS NUMERIC LANGUAGE plpgsql SET search_path = q9 AS $$
DECLARE v_rate NUMERIC;
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade must not be NULL';
    END IF;
    v_rate := CASE p_grade WHEN 'A' THEN 5.00 WHEN 'B' THEN 4.00 WHEN 'C' THEN 3.00 END;
    IF v_rate IS NULL THEN
        RAISE EXCEPTION 'Unsupported grade: %', p_grade;
    END IF;
    RETURN v_rate;
END $$;

-- (d) Trigger: one pricing rule for every route into the table -----------------
CREATE FUNCTION trg_delivery_pricing() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = q9 AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive, got %', NEW.weight_kg;
    END IF;
    NEW.unit_rate   := fn_maize_rate(NEW.grade::TEXT);
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
    RETURN NEW;
END $$;

CREATE TRIGGER trg_deliveries_pricing
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW EXECUTE FUNCTION trg_delivery_pricing();

-- (c) Procedure: supplies only the basic fields; the trigger prices them -------
-- unit_rate and total_value are omitted on purpose. They are NOT NULL, but a
-- BEFORE trigger sets them before constraints are checked.
CREATE PROCEDURE pr_receive_delivery(p_farmer_id INT, p_grade TEXT, p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql SET search_path = q9 AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
        RAISE EXCEPTION 'Unknown farmer: %', p_farmer_id;
    END IF;
    IF p_grade IS NULL OR p_grade NOT IN ('A','B','C') THEN
        RAISE EXCEPTION 'Invalid grade: %', p_grade;
    END IF;
    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive';
    END IF;
    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date is required';
    END IF;
    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
END $$;

-- (e) View: LEFT JOIN so farmers with nothing unpaid show 0 ----------------------
CREATE VIEW v_farmer_amount_due AS
SELECT f.farmer_number, f.full_name,
       COALESCE(SUM(d.total_value) FILTER (WHERE NOT d.is_paid), 0) AS amount_due
  FROM farmers f
  LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id
 GROUP BY f.farmer_id, f.farmer_number, f.full_name
 ORDER BY f.farmer_number;

-- Seed: six deliveries through the procedure (trigger already installed) --------
CALL pr_receive_delivery(1, 'A', 100,   CURRENT_DATE - 3);
CALL pr_receive_delivery(1, 'B', 50.5,  CURRENT_DATE - 2);
CALL pr_receive_delivery(2, 'C', 200,   CURRENT_DATE - 2);
CALL pr_receive_delivery(2, 'A', 80,    CURRENT_DATE - 1);
CALL pr_receive_delivery(3, 'B', 120,   CURRENT_DATE - 1);
CALL pr_receive_delivery(3, 'A', 60,    CURRENT_DATE - 1);
UPDATE deliveries SET is_paid = TRUE WHERE delivery_id IN (1, 5, 6);   -- both payment states

-- Tests
SELECT fn_maize_rate('A') a, fn_maize_rate('B') b, fn_maize_rate('C') c;
DO $$ BEGIN PERFORM fn_maize_rate('D');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_maize_rate(NULL);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_delivery(99, 'A', 10, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_delivery(1, 'A', -5, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
-- Direct SQL follows the same rule: wrong rate/total supplied by hand is overwritten
INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on)
VALUES (1, 'C', 10, 99, 9999, CURRENT_DATE);
SELECT delivery_id, grade, weight_kg, unit_rate, total_value, is_paid FROM deliveries ORDER BY 1;
DELETE FROM deliveries WHERE delivery_id = 7;      -- remove the test row
SELECT * FROM v_farmer_amount_due;                 -- farmer F003 shows 0

-- (f) Index -----------------------------------------------------------------
-- farmer_id is an equality filter and delivered_on a range, so (farmer_id,
-- delivered_on) reads one farmer's deliveries for the period directly, in date order.
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);
ANALYZE deliveries;
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM deliveries
 WHERE farmer_id = 1 AND delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job: upsert replaces totals, never adds to them ------------------
CREATE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql SET search_path = q9 AS $$
BEGIN
    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    SELECT p_day, COALESCE(SUM(weight_kg), 0), COALESCE(SUM(total_value), 0)
      FROM deliveries WHERE delivered_on = p_day
    ON CONFLICT (purchase_date) DO UPDATE
       SET total_weight = EXCLUDED.total_weight, total_value = EXCLUDED.total_value;
END $$;

CALL pr_refresh_purchases(CURRENT_DATE - 1);
CALL pr_refresh_purchases(CURRENT_DATE - 1);     -- rerun: same totals, not doubled
SELECT * FROM daily_purchases;

DO $do$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('q9_refresh_purchases', '30 1 * * *',
        $cmd$CALL q9.pr_refresh_purchases(CURRENT_DATE - 1)$cmd$);
  ELSE
    RAISE NOTICE 'pg_cron not installed. Schedule: 30 1 * * *  CALL q9.pr_refresh_purchases(CURRENT_DATE - 1)';
  END IF;
END $do$;

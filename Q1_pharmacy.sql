-- ICT371 Q1: Pharmacy Stock and Daily Sales (PostgreSQL / PL/pgSQL)
-- Run the whole file in the pgAdmin Query Tool. Everything lives in schema q1.
DROP SCHEMA IF EXISTS q1 CASCADE;
CREATE SCHEMA q1;
SET search_path TO q1;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE medicines (
    medicine_id   SERIAL PRIMARY KEY,
    medicine_name VARCHAR(100) NOT NULL,
    unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INT NOT NULL CHECK (stock_qty >= 0)
);
CREATE TABLE sales (
    sale_id     SERIAL PRIMARY KEY,
    medicine_id INT NOT NULL REFERENCES medicines(medicine_id),
    quantity    INT NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on     DATE NOT NULL
);
CREATE TABLE stock_audit (
    audit_id    SERIAL PRIMARY KEY,
    medicine_id INT NOT NULL REFERENCES medicines(medicine_id),
    old_qty     INT NOT NULL,
    new_qty     INT NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE daily_sales (
    sales_date   DATE PRIMARY KEY,
    total_qty    INT NOT NULL,
    total_amount NUMERIC(12,2) NOT NULL
);

INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
 ('Paracetamol 500mg', 2.50, 50),
 ('Amoxicillin 250mg', 8.00, 30),
 ('Ibuprofen 200mg',   4.00, 12);

-- (b) Function -------------------------------------------------------------
CREATE FUNCTION fn_sale_value(p_medicine_id INT, p_quantity INT)
RETURNS NUMERIC LANGUAGE plpgsql SET search_path = q1 AS $$
DECLARE v_price NUMERIC;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: %', p_quantity;
    END IF;
    SELECT unit_price INTO v_price FROM medicines WHERE medicine_id = p_medicine_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine: %', p_medicine_id;
    END IF;
    RETURN ROUND(v_price * p_quantity, 2);
END $$;

-- (c) Procedure ------------------------------------------------------------
-- The row is locked (FOR UPDATE) so two sales cannot oversell. Any RAISE aborts
-- the call, so neither table changes for an invalid sale.
CREATE PROCEDURE pr_record_sale(p_medicine_id INT, p_quantity INT, p_sold_on DATE)
LANGUAGE plpgsql SET search_path = q1 AS $$
DECLARE v_price NUMERIC; v_stock INT;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive';
    END IF;
    SELECT unit_price, stock_qty INTO v_price, v_stock
      FROM medicines WHERE medicine_id = p_medicine_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine: %', p_medicine_id;
    END IF;
    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock: % available, % requested', v_stock, p_quantity;
    END IF;
    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, COALESCE(p_sold_on, CURRENT_DATE));
    UPDATE medicines SET stock_qty = stock_qty - p_quantity
     WHERE medicine_id = p_medicine_id;          -- deducted exactly once
END $$;

-- (d) Trigger --------------------------------------------------------------
CREATE FUNCTION trg_medicine_stock_audit() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = q1 AS $$
BEGIN
    INSERT INTO stock_audit (medicine_id, old_qty, new_qty)
    VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty);
    RETURN NULL;
END $$;

CREATE TRIGGER trg_medicines_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)
EXECUTE FUNCTION trg_medicine_stock_audit();

-- (e) View -----------------------------------------------------------------
CREATE VIEW v_low_stock AS
SELECT medicine_name, unit_price, stock_qty AS remaining_stock
  FROM medicines
 WHERE stock_qty < 10;

-- Seed sales THROUGH the procedure (six valid sales) ------------------------
CALL pr_record_sale(1, 10, CURRENT_DATE - 2);
CALL pr_record_sale(2,  5, CURRENT_DATE - 2);
CALL pr_record_sale(3,  3, CURRENT_DATE - 1);
CALL pr_record_sale(1, 15, CURRENT_DATE - 1);
CALL pr_record_sale(3,  2, CURRENT_DATE);
CALL pr_record_sale(2,  4, CURRENT_DATE);

-- Tests: function, rejected sale (nothing changes), audit, view
SELECT fn_sale_value(1, 4) AS value_of_4_paracetamol;
DO $$ BEGIN
    CALL pr_record_sale(3, 999, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM;
END $$;
SELECT * FROM medicines ORDER BY medicine_id;
SELECT * FROM stock_audit ORDER BY audit_id;
SELECT * FROM v_low_stock;            -- Ibuprofen (12 - 3 - 2 = 7) appears

-- (f) Index ----------------------------------------------------------------
-- Equality on medicine_id first, then the range on sold_on: one B-tree scan reads
-- exactly the matching entries, already ordered by date.
CREATE INDEX idx_sales_medicine_date ON sales (medicine_id, sold_on);
ANALYZE sales;
SET enable_seqscan = off;   -- the table is tiny; this forces the planner to show the index
EXPLAIN
SELECT * FROM sales
 WHERE medicine_id = 1 AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------
-- Upsert: a rerun overwrites the row, so totals are never duplicated or doubled.
CREATE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql SET search_path = q1 AS $$
BEGIN
    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT p_day, COALESCE(SUM(quantity), 0), COALESCE(SUM(quantity * unit_price), 0)
      FROM sales WHERE sold_on = p_day
    ON CONFLICT (sales_date) DO UPDATE
       SET total_qty = EXCLUDED.total_qty, total_amount = EXCLUDED.total_amount;
END $$;

CALL pr_refresh_sales(CURRENT_DATE - 1);
CALL pr_refresh_sales(CURRENT_DATE - 1);       -- rerun: still one row, same totals
SELECT * FROM daily_sales;

-- Needs the pg_cron extension (CREATE EXTENSION pg_cron; in the cron database).
DO $do$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('q1_refresh_sales', '15 0 * * *',
        $cmd$CALL q1.pr_refresh_sales(CURRENT_DATE - 1)$cmd$);
  ELSE
    RAISE NOTICE 'pg_cron not installed. Schedule: 15 0 * * *  CALL q1.pr_refresh_sales(CURRENT_DATE - 1)';
  END IF;
END $do$;

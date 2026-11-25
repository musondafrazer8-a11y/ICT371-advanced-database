-- ICT371 Q8: Transport Fleet Maintenance (schema q8)
DROP SCHEMA IF EXISTS q8 CASCADE;
CREATE SCHEMA q8;
SET search_path TO q8;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE vehicles (
    vehicle_id            SERIAL PRIMARY KEY,
    registration          VARCHAR(15) NOT NULL UNIQUE,
    current_odometer      INT NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer INT NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT ck_service_le_current CHECK (last_service_odometer <= current_odometer)
);
CREATE TABLE trips (
    trip_id        SERIAL PRIMARY KEY,
    vehicle_id     INT NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE NOT NULL,
    start_odometer INT NOT NULL CHECK (start_odometer >= 0),
    end_odometer   INT NOT NULL CHECK (end_odometer >= 0)
);
CREATE TABLE service_alerts (
    vehicle_id       INT PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service INT NOT NULL,
    flagged_on       DATE NOT NULL
);

INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
 ('ABC 1234', 12000,  5000),    -- 7000 km since service: due
 ('BCD 2345',  8000,  5000),    -- 3000 km: not due
 ('CDE 3456', 20000, 15000);    -- exactly 5000 km: due

-- (b) Function -------------------------------------------------------------
CREATE FUNCTION fn_service_due(p_vehicle_id INT)
RETURNS BOOLEAN LANGUAGE plpgsql SET search_path = q8 AS $$
DECLARE v_km INT;
BEGIN
    SELECT current_odometer - last_service_odometer INTO v_km
      FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle: %', p_vehicle_id;
    END IF;
    RETURN v_km >= 5000;
END $$;

-- (c) Procedure: validates and inserts; the TRIGGER updates the odometer ---------
CREATE PROCEDURE pr_record_trip(p_vehicle_id INT, p_trip_on DATE, p_start INT, p_end INT)
LANGUAGE plpgsql SET search_path = q8 AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
        RAISE EXCEPTION 'Unknown vehicle: %', p_vehicle_id;
    END IF;
    IF p_start IS NULL OR p_end IS NULL OR p_end <= p_start THEN
        RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)', p_end, p_start;
    END IF;
    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, COALESCE(p_trip_on, CURRENT_DATE), p_start, p_end);
END $$;

-- (d) Trigger: BEFORE INSERT, one UPDATE of the odometer per inserted trip -------
CREATE FUNCTION trg_trip_odometer() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = q8 AS $$
DECLARE v_current INT;
BEGIN
    IF NEW.start_odometer < 0 OR NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: start %, end %', NEW.start_odometer, NEW.end_odometer;
    END IF;
    SELECT current_odometer INTO v_current
      FROM vehicles WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle: %', NEW.vehicle_id;
    END IF;
    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Trip must start at the current odometer (%), got %',
              v_current, NEW.start_odometer;
    END IF;
    UPDATE vehicles SET current_odometer = NEW.end_odometer
     WHERE vehicle_id = NEW.vehicle_id;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_trips_odometer
BEFORE INSERT ON trips
FOR EACH ROW EXECUTE FUNCTION trg_trip_odometer();

-- (e) View ------------------------------------------------------------------
CREATE VIEW v_service_due AS
SELECT registration, current_odometer - last_service_odometer AS km_since_service
  FROM vehicles
 WHERE current_odometer - last_service_odometer >= 5000;

-- Seed: six trips through the procedure, after the trigger exists ----------------
CALL pr_record_trip(1, CURRENT_DATE - 6, 12000, 12100);
CALL pr_record_trip(1, CURRENT_DATE - 4, 12100, 12300);
CALL pr_record_trip(2, CURRENT_DATE - 5,  8000,  8400);
CALL pr_record_trip(2, CURRENT_DATE - 3,  8400,  8900);
CALL pr_record_trip(3, CURRENT_DATE - 2, 20000, 20150);
CALL pr_record_trip(3, CURRENT_DATE - 1, 20150, 20500);

-- Tests
SELECT vehicle_id, registration, current_odometer, fn_service_due(vehicle_id) AS due FROM vehicles ORDER BY 1;
DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 12000, 12400);   -- wrong start (now 12300)
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 12300, 12300);   -- end not greater
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(99, CURRENT_DATE, 0, 10);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
            VALUES (1, CURRENT_DATE, 12300, 12200);               -- direct SQL, bad mileage
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
SELECT * FROM vehicles ORDER BY vehicle_id;    -- odometers moved exactly once per trip
SELECT * FROM v_service_due;

-- (f) Index -----------------------------------------------------------------
-- One vehicle (equality) and a date range: (vehicle_id, trip_on) lets a single
-- B-tree descent find that vehicle and read just the date range in order.
CREATE INDEX idx_trips_vehicle_date ON trips (vehicle_id, trip_on);
ANALYZE trips;
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM trips
 WHERE vehicle_id = 1 AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job -----------------------------------------------------------
CREATE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql SET search_path = q8 AS $$
BEGIN
    -- remove alerts for vehicles that are no longer due (e.g. after a service)
    DELETE FROM service_alerts sa
     WHERE NOT EXISTS (SELECT 1 FROM vehicles v
                        WHERE v.vehicle_id = sa.vehicle_id
                          AND v.current_odometer - v.last_service_odometer >= 5000);
    -- insert new alerts, or refresh km on existing ones (flagged_on is kept)
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
      FROM vehicles
     WHERE current_odometer - last_service_odometer >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE SET km_since_service = EXCLUDED.km_since_service;
END $$;

CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts;                       -- vehicles 1 and 3
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 1;  -- serviced
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts;                       -- vehicle 1's alert is gone

DO $do$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('q8_refresh_service_alerts', '0 6 * * 1',
        $cmd$CALL q8.pr_refresh_service_alerts()$cmd$);
  ELSE
    RAISE NOTICE 'pg_cron not installed. Schedule: 0 6 * * 1  CALL q8.pr_refresh_service_alerts()';
  END IF;
END $do$;

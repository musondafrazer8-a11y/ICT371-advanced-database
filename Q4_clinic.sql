-- ICT371 Q4: Clinic Appointment Scheduling (schema q4)
DROP SCHEMA IF EXISTS q4 CASCADE;
CREATE SCHEMA q4;
SET search_path TO q4;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    full_name  VARCHAR(100) NOT NULL
);
CREATE TABLE doctors (
    doctor_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);
CREATE TABLE appointments (
    appointment_id  SERIAL PRIMARY KEY,
    patient_id      INT NOT NULL REFERENCES patients(patient_id),
    doctor_id       INT NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE NOT NULL,
    slot_time       TIME NOT NULL,
    status          VARCHAR(10) NOT NULL DEFAULT 'BOOKED',
    CONSTRAINT ck_status CHECK (status IN ('BOOKED','ATTENDED','CANCELLED')),
    CONSTRAINT ck_slot   CHECK (slot_time IN ('09:00','10:00','11:00','12:00'))
);
CREATE TABLE clinic_summary (
    summary_date    DATE PRIMARY KEY,
    booked_count    INT NOT NULL,
    attended_count  INT NOT NULL,
    cancelled_count INT NOT NULL
);

INSERT INTO patients (full_name) VALUES ('Chanda Mwila'), ('Mutale Banda'), ('Natasha Phiri');
INSERT INTO doctors  (full_name) VALUES ('Dr Zulu'), ('Dr Tembo'), ('Dr Lungu');

-- (b) Function ---------------------------------------------------------------
CREATE FUNCTION fn_daily_load(p_doctor_id INT, p_day DATE)
RETURNS INT LANGUAGE plpgsql SET search_path = q4 AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor: %', p_doctor_id;
    END IF;
    RETURN (SELECT COUNT(*) FROM appointments
             WHERE doctor_id = p_doctor_id
               AND appointment_day = p_day
               AND status <> 'CANCELLED');          -- COUNT gives 0 when no bookings
END $$;

-- (c) Procedure -------------------------------------------------------------
-- Clash checking is left to the trigger (d), which also covers direct SQL.
CREATE PROCEDURE pr_book_appointment(p_patient_id INT, p_doctor_id INT, p_day DATE, p_slot TIME)
LANGUAGE plpgsql SET search_path = q4 AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM patients WHERE patient_id = p_patient_id) THEN
        RAISE EXCEPTION 'Unknown patient: %', p_patient_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor: %', p_doctor_id;
    END IF;
    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Appointment date % is in the past or missing', p_day;
    END IF;
    IF p_slot IS NULL OR p_slot NOT IN ('09:00','10:00','11:00','12:00') THEN
        RAISE EXCEPTION 'Unsupported slot: %', p_slot;
    END IF;
    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END $$;

-- (d) Trigger ---------------------------------------------------------------
CREATE FUNCTION trg_appointment_clash() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = q4 AS $$
BEGIN
    IF NEW.status <> 'CANCELLED' AND EXISTS (
        SELECT 1 FROM appointments a
         WHERE a.doctor_id = NEW.doctor_id
           AND a.appointment_day = NEW.appointment_day
           AND a.slot_time = NEW.slot_time
           AND a.status <> 'CANCELLED'
           AND a.appointment_id IS DISTINCT FROM NEW.appointment_id  -- skip the row being changed
    ) THEN
        RAISE EXCEPTION 'Doctor % already has an appointment on % at %',
              NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_appointments_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION trg_appointment_clash();

-- Extra safety net against two sessions racing past the trigger (optional):
CREATE UNIQUE INDEX uq_active_slot ON appointments (doctor_id, appointment_day, slot_time)
 WHERE status <> 'CANCELLED';

-- (e) View: only what reception needs, no other patient data -------------------
CREATE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name, d.full_name AS doctor_name, a.slot_time
  FROM appointments a
  JOIN patients p ON p.patient_id = a.patient_id
  JOIN doctors  d ON d.doctor_id  = a.doctor_id
 WHERE a.appointment_day = CURRENT_DATE AND a.status = 'BOOKED'
 ORDER BY a.slot_time;

-- Seed: six appointments (no slot clashes) --------------------------------------
CALL pr_book_appointment(1, 1, CURRENT_DATE,     '09:00');
CALL pr_book_appointment(2, 1, CURRENT_DATE,     '10:00');
CALL pr_book_appointment(3, 2, CURRENT_DATE,     '09:00');
CALL pr_book_appointment(3, 1, CURRENT_DATE + 1, '09:00');
INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
 (1, 2, CURRENT_DATE - 1, '10:00', 'ATTENDED'),     -- history (past dates are direct inserts)
 (2, 3, CURRENT_DATE - 1, '11:00', 'CANCELLED');

-- Tests
SELECT fn_daily_load(1, CURRENT_DATE) AS dr1_today, fn_daily_load(3, CURRENT_DATE + 5) AS empty_day;
DO $$ BEGIN CALL pr_book_appointment(2, 1, CURRENT_DATE, '09:00');      -- clash
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(2, 1, CURRENT_DATE - 1, '09:00');  -- past
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(2, 1, CURRENT_DATE, '13:00');      -- bad slot
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(1, 99, CURRENT_DATE, '11:00');     -- bad doctor
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
-- UPDATE: moving appointment 1 to a slot taken by appointment 2 is rejected,
-- but re-saving it in its own slot is allowed because it excludes itself.
DO $$ BEGIN UPDATE appointments SET slot_time = '10:00' WHERE appointment_id = 1;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
UPDATE appointments SET patient_id = patient_id WHERE appointment_id = 1;
SELECT * FROM v_today_appointments;

-- (f) Index -----------------------------------------------------------------
-- The schedule screen asks "this doctor's appointments on this day", so both
-- columns are equality filters. Non-unique: a doctor has several slots a day.
CREATE INDEX idx_appt_day_doctor ON appointments (appointment_day, doctor_id);
ANALYZE appointments;
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM appointments
 WHERE appointment_day = CURRENT_DATE AND doctor_id = 1;
RESET enable_seqscan;

-- (g) Scheduled job -----------------------------------------------------------
CREATE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql SET search_path = q4 AS $$
BEGIN
    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
      FROM appointments WHERE appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE
       SET booked_count    = EXCLUDED.booked_count,
           attended_count  = EXCLUDED.attended_count,
           cancelled_count = EXCLUDED.cancelled_count;
END $$;

CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);   -- rerun replaces
SELECT * FROM clinic_summary;

DO $do$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('q4_refresh_clinic_summary', '0 1 * * *',
        $cmd$CALL q4.pr_refresh_clinic_summary(CURRENT_DATE - 1)$cmd$);
  ELSE
    RAISE NOTICE 'pg_cron not installed. Schedule: 0 1 * * *  CALL q4.pr_refresh_clinic_summary(CURRENT_DATE - 1)';
  END IF;
END $do$;

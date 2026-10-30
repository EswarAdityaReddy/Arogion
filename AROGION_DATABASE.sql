-- ============================================================================
-- AROGION DATABASE HANDLER
-- Production-ready canonical SQL for medication, alarm, and intake tracking.
--
-- Use this file as the single source of truth for the medication subsystem.
-- It is idempotent and safe to re-run after schema changes.
--
-- Notes:
-- 1) This script assumes Supabase/Postgres.
-- 2) Row-level security uses a claim-aware helper so it can work with a mapped
--    Firebase UID claim or a Supabase-authenticated UID.
-- 3) No sample data is enabled by default.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ----------------------------------------------------------------------------
-- Helper functions
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.arogion_actor_id()
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
  SELECT NULLIF(
    COALESCE(
      auth.jwt() ->> 'firebase_uid',
      auth.jwt() ->> 'user_id',
      auth.uid()::text
    ),
    ''
  );
$$;

CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

-- ----------------------------------------------------------------------------
-- Medications
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.medications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id TEXT NOT NULL,
  medication_name TEXT NOT NULL,
  dosage TEXT NOT NULL,
  medication_type TEXT NOT NULL,
  timing_labels TEXT[] NOT NULL DEFAULT '{}'::TEXT[],
  timing_values TEXT[] NOT NULL DEFAULT '{}'::TEXT[],
  time_frequency TEXT NOT NULL,
  days_of_week INTEGER[] NOT NULL DEFAULT '{0,1,2,3,4,5,6}',
  start_date DATE NOT NULL DEFAULT CURRENT_DATE,
  end_date DATE,
  duration_days INTEGER,
  prescribed_date DATE,
  expiry_date DATE,
  instructions TEXT NOT NULL DEFAULT '',
  warnings TEXT NOT NULL DEFAULT '',
  alarm_enabled BOOLEAN NOT NULL DEFAULT TRUE,
  reminder_notification BOOLEAN NOT NULL DEFAULT TRUE,
  notification_minutes_before INTEGER NOT NULL DEFAULT 15,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT medications_user_id_not_empty CHECK (length(trim(user_id)) > 0),
  CONSTRAINT medications_time_labels_match_values CHECK (array_length(timing_labels, 1) = array_length(timing_values, 1))
);

CREATE INDEX IF NOT EXISTS idx_medications_user_id ON public.medications(user_id);
CREATE INDEX IF NOT EXISTS idx_medications_user_active ON public.medications(user_id, is_active);
CREATE INDEX IF NOT EXISTS idx_medications_created_at ON public.medications(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_medications_expiry ON public.medications(expiry_date) WHERE is_active = TRUE;

ALTER TABLE public.medications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS medications_select_own ON public.medications;
CREATE POLICY medications_select_own
  ON public.medications
  FOR SELECT
  USING (user_id = public.arogion_actor_id());

DROP POLICY IF EXISTS medications_insert_own ON public.medications;
CREATE POLICY medications_insert_own
  ON public.medications
  FOR INSERT
  WITH CHECK (user_id = public.arogion_actor_id());

DROP POLICY IF EXISTS medications_update_own ON public.medications;
CREATE POLICY medications_update_own
  ON public.medications
  FOR UPDATE
  USING (user_id = public.arogion_actor_id())
  WITH CHECK (user_id = public.arogion_actor_id());

DROP POLICY IF EXISTS medications_delete_own ON public.medications;
CREATE POLICY medications_delete_own
  ON public.medications
  FOR DELETE
  USING (user_id = public.arogion_actor_id());

DROP TRIGGER IF EXISTS trg_medications_updated_at ON public.medications;
CREATE TRIGGER trg_medications_updated_at
BEFORE UPDATE ON public.medications
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

-- ----------------------------------------------------------------------------
-- Medication alarms
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.medication_alarms (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  medication_id UUID NOT NULL REFERENCES public.medications(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL,
  alarm_time TIME NOT NULL,
  alarm_label TEXT,
  dose_number INTEGER NOT NULL,
  dose_name TEXT,
  is_enabled BOOLEAN NOT NULL DEFAULT TRUE,
  last_triggered TIMESTAMPTZ,
  upcoming_trigger TIMESTAMPTZ,
  notification_type TEXT NOT NULL DEFAULT 'Sound+Vibration',
  notify_before_minutes INTEGER NOT NULL DEFAULT 15,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT medication_alarms_user_id_not_empty CHECK (length(trim(user_id)) > 0),
  CONSTRAINT medication_alarms_dose_number_positive CHECK (dose_number > 0),
  CONSTRAINT medication_alarms_unique_dose UNIQUE (medication_id, dose_number)
);

CREATE INDEX IF NOT EXISTS idx_alarm_medication ON public.medication_alarms(medication_id);
CREATE INDEX IF NOT EXISTS idx_alarm_user ON public.medication_alarms(user_id);
CREATE INDEX IF NOT EXISTS idx_alarm_enabled ON public.medication_alarms(user_id, is_enabled);
CREATE INDEX IF NOT EXISTS idx_alarm_trigger ON public.medication_alarms(upcoming_trigger) WHERE is_enabled = TRUE;

ALTER TABLE public.medication_alarms ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS medication_alarms_select_own ON public.medication_alarms;
CREATE POLICY medication_alarms_select_own
  ON public.medication_alarms
  FOR SELECT
  USING (user_id = public.arogion_actor_id());

DROP POLICY IF EXISTS medication_alarms_insert_own ON public.medication_alarms;
CREATE POLICY medication_alarms_insert_own
  ON public.medication_alarms
  FOR INSERT
  WITH CHECK (user_id = public.arogion_actor_id());

DROP POLICY IF EXISTS medication_alarms_update_own ON public.medication_alarms;
CREATE POLICY medication_alarms_update_own
  ON public.medication_alarms
  FOR UPDATE
  USING (user_id = public.arogion_actor_id())
  WITH CHECK (user_id = public.arogion_actor_id());

DROP POLICY IF EXISTS medication_alarms_delete_own ON public.medication_alarms;
CREATE POLICY medication_alarms_delete_own
  ON public.medication_alarms
  FOR DELETE
  USING (user_id = public.arogion_actor_id());

DROP TRIGGER IF EXISTS trg_medication_alarms_updated_at ON public.medication_alarms;
CREATE TRIGGER trg_medication_alarms_updated_at
BEFORE UPDATE ON public.medication_alarms
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

-- ----------------------------------------------------------------------------
-- Intake logs
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.medication_intake_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  medication_id UUID NOT NULL REFERENCES public.medications(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL,
  alarm_id UUID REFERENCES public.medication_alarms(id) ON DELETE SET NULL,
  scheduled_date DATE NOT NULL,
  scheduled_time TIME NOT NULL,
  actual_intake_time TIMESTAMPTZ,
  status TEXT NOT NULL DEFAULT 'Pending',
  notes TEXT NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT medication_intake_logs_user_id_not_empty CHECK (length(trim(user_id)) > 0),
  CONSTRAINT medication_intake_logs_status_valid CHECK (status IN ('Pending', 'Taken', 'Skipped', 'Missed'))
);

CREATE INDEX IF NOT EXISTS idx_intake_medication ON public.medication_intake_logs(medication_id);
CREATE INDEX IF NOT EXISTS idx_intake_user ON public.medication_intake_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_intake_date ON public.medication_intake_logs(user_id, scheduled_date);
CREATE INDEX IF NOT EXISTS idx_intake_status ON public.medication_intake_logs(user_id, status);

ALTER TABLE public.medication_intake_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS medication_intake_logs_select_own ON public.medication_intake_logs;
CREATE POLICY medication_intake_logs_select_own
  ON public.medication_intake_logs
  FOR SELECT
  USING (user_id = public.arogion_actor_id());

DROP POLICY IF EXISTS medication_intake_logs_insert_own ON public.medication_intake_logs;
CREATE POLICY medication_intake_logs_insert_own
  ON public.medication_intake_logs
  FOR INSERT
  WITH CHECK (user_id = public.arogion_actor_id());

DROP POLICY IF EXISTS medication_intake_logs_update_own ON public.medication_intake_logs;
CREATE POLICY medication_intake_logs_update_own
  ON public.medication_intake_logs
  FOR UPDATE
  USING (user_id = public.arogion_actor_id())
  WITH CHECK (user_id = public.arogion_actor_id());

DROP POLICY IF EXISTS medication_intake_logs_delete_own ON public.medication_intake_logs;
CREATE POLICY medication_intake_logs_delete_own
  ON public.medication_intake_logs
  FOR DELETE
  USING (user_id = public.arogion_actor_id());

DROP TRIGGER IF EXISTS trg_medication_intake_logs_updated_at ON public.medication_intake_logs;
CREATE TRIGGER trg_medication_intake_logs_updated_at
BEFORE UPDATE ON public.medication_intake_logs
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

-- ----------------------------------------------------------------------------
-- Helper upsert for alarms
-- ----------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.upsert_medication_alarm_by_dose(
  UUID,
  TEXT,
  INTEGER,
  TEXT,
  TIME,
  BOOLEAN,
  TEXT,
  INTEGER
);

CREATE OR REPLACE FUNCTION public.upsert_medication_alarm_by_dose(
  p_medication_id UUID,
  p_user_id TEXT,
  p_dose_number INTEGER,
  p_alarm_label TEXT,
  p_alarm_time TIME,
  p_is_enabled BOOLEAN DEFAULT TRUE,
  p_notification_type TEXT DEFAULT 'Sound+Vibration',
  p_notify_before_minutes INTEGER DEFAULT 15
)
RETURNS TABLE(alarm_id UUID, success BOOLEAN, message TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
  v_alarm_id UUID;
BEGIN
  INSERT INTO public.medication_alarms (
    medication_id,
    user_id,
    dose_number,
    alarm_label,
    alarm_time,
    is_enabled,
    notification_type,
    notify_before_minutes,
    created_at,
    updated_at
  )
  VALUES (
    p_medication_id,
    p_user_id,
    p_dose_number,
    p_alarm_label,
    p_alarm_time,
    COALESCE(p_is_enabled, TRUE),
    COALESCE(p_notification_type, 'Sound+Vibration'),
    COALESCE(p_notify_before_minutes, 15),
    NOW(),
    NOW()
  )
  ON CONFLICT (medication_id, dose_number)
  DO UPDATE SET
    alarm_label = EXCLUDED.alarm_label,
    alarm_time = EXCLUDED.alarm_time,
    is_enabled = EXCLUDED.is_enabled,
    notification_type = EXCLUDED.notification_type,
    notify_before_minutes = EXCLUDED.notify_before_minutes,
    updated_at = NOW()
  RETURNING id INTO v_alarm_id;

  RETURN QUERY SELECT v_alarm_id, TRUE, 'Alarm saved successfully';
EXCEPTION
  WHEN OTHERS THEN
    RETURN QUERY SELECT NULL::UUID, FALSE, SQLERRM;
END;
$$;

-- ----------------------------------------------------------------------------
-- Optional DEV seed data
-- ----------------------------------------------------------------------------
-- Keep commented in production.
--
-- INSERT INTO public.medications (...) VALUES (...);
-- INSERT INTO public.medication_alarms (...) VALUES (...);
-- INSERT INTO public.medication_intake_logs (...) VALUES (...);

-- End of canonical database handler.

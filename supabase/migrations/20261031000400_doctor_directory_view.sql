begin;

-- A single, read-only directory view for staff and professional Doctor details.
-- Schedules are aggregated so each Doctor still appears as one row.
create or replace view public.doctor_directory
with (security_invoker = true)
as
select
  s.id as staff_id,
  s.name as doctor_name,
  s.active as staff_active,
  d.professional_title,
  coalesce(
    nullif(btrim(d.custom_specialization), ''),
    nullif(btrim(ms.specialization_name), ''),
    nullif(btrim(d.sub_specialization), ''),
    'Not specified'
  ) as specialization,
  d.sub_specialization,
  d.department,
  d.professional_description,
  d.professional_credentials,
  d.doctor_identifier,
  d.consultation_available,
  d.admin_override_locked,
  coalesce(weekly.schedule, '[]'::jsonb) as weekly_availability,
  coalesce(time_off.dates, '[]'::jsonb) as unavailability
from public.staff s
join public.doctor_profiles d on d.staff_id = s.id
left join public.medical_specializations ms on ms.id = d.specialization_id
left join lateral (
  select jsonb_agg(
    jsonb_build_object(
      'day_of_week', a.day_of_week,
      'is_available', a.is_available,
      'start_time', a.start_time,
      'end_time', a.end_time,
      'break_start', a.break_start,
      'break_end', a.break_end,
      'appointment_duration_minutes', a.appointment_duration_minutes,
      'max_appointments_per_slot', a.max_appointments_per_slot
    ) order by a.day_of_week
  ) as schedule
  from public.staff_availability a
  where a.staff_id = s.id
) weekly on true
left join lateral (
  select jsonb_agg(
    jsonb_build_object(
      'date', u.unavailable_date,
      'start_time', u.start_time,
      'end_time', u.end_time
    ) order by u.unavailable_date, u.start_time
  ) as dates
  from public.staff_unavailability u
  where u.staff_id = s.id
) time_off on true
where s.account_type = 'doctor';

grant select on public.doctor_directory to authenticated;

commit;

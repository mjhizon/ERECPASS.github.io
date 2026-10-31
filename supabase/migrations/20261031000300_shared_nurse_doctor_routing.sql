-- Shared Nurse queue and Doctor-owned appointment workflow.
-- Additive: preserves existing appointment rows and legacy staff identifiers.
-- Requires 20261029000100_pending_staff_verification.sql,
-- 20261031000100_appointment_management_foundation.sql and
-- 20261031000200_patient_time_is_preference.sql to be applied first.
begin;

alter table public.appointments
  add column if not exists assigned_nurse_id uuid references auth.users(id) on delete set null,
  add column if not exists assigned_doctor_user_id uuid references auth.users(id) on delete set null,
  add column if not exists reassignment_reason text;

-- These audit fields are needed by the legacy-queue history updates below.
alter table public.appointment_audit_logs
  add column if not exists previous_doctor_staff_id text references public.staff(id) on delete set null,
  add column if not exists new_doctor_staff_id text references public.staff(id) on delete set null,
  add column if not exists details jsonb not null default '{}'::jsonb;

alter table public.doctor_profiles
  add column if not exists custom_specialization text,
  add column if not exists professional_credentials text not null default '',
  add column if not exists doctor_identifier text not null default '',
  add column if not exists admin_override_locked boolean not null default false;

alter table public.staff
  add column if not exists account_type text not null default 'other',
  add column if not exists professional_title text not null default '';
alter table public.pending_staff_accounts
  add column if not exists account_type text not null default 'other',
  add column if not exists professional_title text not null default '';

-- One-time classification for existing accounts. New accounts store the type
-- separately, so descriptive titles and assigned tasks do not control routing.
update public.staff set professional_title=coalesce(nullif(btrim(role_title),''),'')
where professional_title='' and coalesce(role_title,'')<>'';
update public.staff s set account_type=case
  when coalesce(s.role_title,'') ilike '%nurse%' or coalesce(s.task,'') ilike '%nurse%' then 'nurse'
  when coalesce(s.role_title,'') ilike '%doctor%' or coalesce(s.role_title,'') ilike '%physician%'
    or coalesce(s.role_title,'') ilike '%general practitioner%' or coalesce(s.role_title,'') ilike '%surgeon%'
    or coalesce(s.role_title,'') ilike '%specialist%' or coalesce(s.task,'') ilike '%doctor%'
    or coalesce(s.name,'') ilike 'dr.%' then 'doctor'
  else 'other' end,
  professional_title=coalesce(nullif(btrim(s.role_title),''),'')
where s.account_type='other' and (coalesce(s.role_title,'') ilike '%nurse%' or coalesce(s.task,'') ilike '%nurse%'
  or coalesce(s.role_title,'') ilike '%doctor%' or coalesce(s.role_title,'') ilike '%physician%'
  or coalesce(s.role_title,'') ilike '%general practitioner%' or coalesce(s.role_title,'') ilike '%surgeon%'
  or coalesce(s.role_title,'') ilike '%specialist%' or coalesce(s.task,'') ilike '%doctor%'
  or coalesce(s.name,'') ilike 'dr.%');
update public.pending_staff_accounts p set
  professional_title=coalesce(nullif(btrim(p.role_title),''),''),
  account_type=case when coalesce(p.role_title,'') ilike '%nurse%' or coalesce(p.task,'') ilike '%nurse%' then 'nurse'
    when coalesce(p.role_title,'') ilike '%doctor%' or coalesce(p.role_title,'') ilike '%physician%'
      or coalesce(p.role_title,'') ilike '%general practitioner%' or coalesce(p.role_title,'') ilike '%surgeon%'
      or coalesce(p.role_title,'') ilike '%specialist%' or coalesce(p.task,'') ilike '%doctor%'
      or coalesce(p.full_name,'') ilike 'dr.%' then 'doctor' else 'other' end
where p.account_type='other';
alter table public.staff drop constraint if exists staff_account_type_check;
alter table public.staff add constraint staff_account_type_check check(account_type in ('nurse','doctor','other'));
alter table public.pending_staff_accounts drop constraint if exists pending_staff_accounts_account_type_check;
alter table public.pending_staff_accounts add constraint pending_staff_accounts_account_type_check check(account_type in ('nurse','doctor','other'));

-- Register existing Doctor accounts. This only creates profile rows; it does
-- not create staff accounts.
insert into public.doctor_profiles(staff_id, professional_title)
select s.id, coalesce(nullif(btrim(s.professional_title),''),'Doctor')
from public.staff s
join public.profiles p on p.id=s.user_id and p.role='staff' and p.active=true
where s.active=true and s.account_type='doctor'
on conflict (staff_id) do nothing;

-- Admin-created Doctors also need a profile row before they can appear in the
-- Nurse assignment directory. The Admin form stores an explicit Doctor prefix
-- in staff.account_type; this trigger covers both immediate and verified account
-- creation paths after this migration is installed.
create or replace function public.erecpass_register_doctor_profile()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_title text;
begin
  if new.account_type='doctor' then
    v_title:=nullif(btrim(new.professional_title),'');
    insert into public.doctor_profiles(staff_id,professional_title)
    values(new.id,coalesce(v_title,'Doctor'))
    on conflict(staff_id) do nothing;
  end if;
  return new;
end $$;
revoke all on function public.erecpass_register_doctor_profile() from public,anon,authenticated;
drop trigger if exists staff_register_doctor_profile on public.staff;
create trigger staff_register_doctor_profile after insert or update on public.staff
for each row execute function public.erecpass_register_doctor_profile();

update public.appointments a set assigned_doctor_user_id=s.user_id
from public.staff s join public.doctor_profiles d on d.staff_id=s.id
where a.provider_staff_id=s.id and a.assigned_doctor_user_id is null;

insert into public.medical_specializations(specialization_name) values
  ('Family Medicine'),('Other')
on conflict(specialization_name) do nothing;

create table if not exists public.appointment_assignments (
  id bigint generated by default as identity primary key,
  appointment_id bigint not null references public.appointments(id) on delete cascade,
  previous_doctor_staff_id text references public.staff(id) on delete set null,
  doctor_staff_id text not null references public.staff(id) on delete restrict,
  doctor_user_id uuid not null references auth.users(id) on delete restrict,
  assigned_by uuid references auth.users(id) on delete set null,
  assignment_reason text not null default '',
  created_at timestamptz not null default now()
);
create index if not exists appointment_assignments_appointment_created_idx
  on public.appointment_assignments(appointment_id, created_at desc);
create index if not exists appointment_assignments_doctor_created_idx
  on public.appointment_assignments(doctor_staff_id, created_at desc);

create table if not exists public.appointment_actor_notifications (
  id bigint generated by default as identity primary key,
  recipient_user_id uuid not null references auth.users(id) on delete cascade,
  recipient_role text not null check(recipient_role in ('nurse','doctor','admin')),
  appointment_id bigint references public.appointments(id) on delete cascade,
  event_key text not null unique,
  title text not null,
  message text not null,
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists appointment_actor_notifications_inbox_idx
  on public.appointment_actor_notifications(recipient_user_id,is_read,created_at desc);

-- Put legacy pending requests back into the shared queue while retaining the
-- former Doctor and time as migration history/preference.
insert into public.appointment_assignments(
  appointment_id,previous_doctor_staff_id,doctor_staff_id,doctor_user_id,assigned_by,assignment_reason
)
select a.id,null,s.id,s.user_id,null,'Legacy pending assignment moved to the shared Nurse queue.'
from public.appointments a
join public.staff s on s.id=a.provider_staff_id
join public.doctor_profiles d on d.staff_id=s.id
where lower(btrim(a.status)) in ('pending','pending approval')
  and a.provider_staff_id is not null and s.user_id is not null
  and not exists(select 1 from public.appointment_assignments x where x.appointment_id=a.id);

insert into public.appointment_audit_logs(
  appointment_id,changed_by,changed_by_role,previous_status,new_status,action,reason,previous_doctor_staff_id,new_doctor_staff_id,details
)
select a.id,null,'system',a.status,'Pending','legacy_request_queued',
  'Legacy pending request routed to the shared Nurse queue.',a.provider_staff_id,null,
  jsonb_build_object('former_appointment_time',a.appointment_time,'former_doctor',a.doctor)
from public.appointments a
where lower(btrim(a.status)) in ('pending','pending approval')
  and a.provider_staff_id is not null
  and exists(select 1 from public.doctor_profiles d where d.staff_id=a.provider_staff_id);

with queued as (
  update public.appointments a set
    provider_staff_id=null,assigned_doctor_user_id=null,assigned_nurse_id=null,
    doctor='Unassigned',preferred_time=coalesce(a.preferred_time,a.appointment_time),
    appointment_time=null,status='Pending'
  where lower(btrim(a.status)) in ('pending','pending approval')
    and a.provider_staff_id is not null
    and exists(select 1 from public.doctor_profiles d where d.staff_id=a.provider_staff_id)
  returning a.id,a.patient_id,a.patient_name,a.appointment_date
), nurse_notifications as (
  insert into public.appointment_actor_notifications(recipient_user_id,recipient_role,appointment_id,event_key,title,message)
  select s.user_id,'nurse',q.id,'appointment:'||q.id||':legacy-queued:nurse:'||s.user_id,
    'Legacy request added to shared queue',format('%s has a pending appointment request for %s.',q.patient_name,to_char(q.appointment_date,'FMMonth DD, YYYY'))
  from queued q cross join public.staff s join public.profiles p on p.id=s.user_id and p.role='staff' and p.active=true
  where s.active=true and s.account_type='nurse'
    and not exists(select 1 from public.doctor_profiles d where d.staff_id=s.id)
  on conflict(event_key) do nothing returning id
)
insert into public.appointment_notifications(patient_id,appointment_id,title,message,notification_type)
select q.patient_id,q.id,'Appointment waiting for Nurse assignment',
  format('Your request for %s is waiting for a Nurse to assign a Doctor.',to_char(q.appointment_date,'FMMonth DD, YYYY')),'pending'
from queued q;

create table if not exists public.doctor_profile_audit_logs (
  id bigint generated by default as identity primary key,
  doctor_staff_id text not null references public.staff(id) on delete cascade,
  changed_by uuid not null references auth.users(id) on delete restrict,
  change_reason text not null,
  previous_profile jsonb not null default '{}'::jsonb,
  new_profile jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists doctor_profile_audit_logs_staff_created_idx
  on public.doctor_profile_audit_logs(doctor_staff_id, created_at desc);

create table if not exists public.doctor_account_audit_logs (
  id bigint generated by default as identity primary key,
  doctor_staff_id text not null references public.staff(id) on delete cascade,
  changed_by uuid not null references auth.users(id) on delete restrict,
  was_active boolean not null,
  is_active boolean not null,
  change_reason text not null,
  created_at timestamptz not null default now()
);
create index if not exists doctor_account_audit_logs_staff_created_idx
  on public.doctor_account_audit_logs(doctor_staff_id,created_at desc);

create or replace function public.erecpass_protect_admin_doctor_profile()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if old.admin_override_locked and not exists(
    select 1 from public.profiles p where p.id=auth.uid() and p.role='admin' and p.active=true
  ) then
    raise exception 'This Doctor profile was corrected by Admin. Contact Admin to make further changes.' using errcode='42501';
  end if;
  return new;
end $$;
revoke all on function public.erecpass_protect_admin_doctor_profile() from public,anon,authenticated;
drop trigger if exists doctor_profiles_protect_admin_override on public.doctor_profiles;
create trigger doctor_profiles_protect_admin_override before update on public.doctor_profiles
for each row execute function public.erecpass_protect_admin_doctor_profile();

create or replace function public.erecpass_is_active_nurse(p_user_id uuid default auth.uid())
returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
  select (p_user_id=auth.uid() or exists(select 1 from public.profiles me where me.id=auth.uid() and me.role='admin' and me.active=true)) and exists(
    select 1 from public.staff s join public.profiles p on p.id=s.user_id
    where s.user_id=p_user_id and s.active=true and p.role='staff' and p.active=true
      and s.account_type='nurse'
      and not exists(select 1 from public.doctor_profiles d where d.staff_id=s.id)
  )
$$;

create or replace function public.erecpass_is_active_doctor(p_user_id uuid default auth.uid())
returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
  select (p_user_id=auth.uid() or exists(select 1 from public.profiles me where me.id=auth.uid() and me.role='admin' and me.active=true)) and exists(
    select 1 from public.staff s
    join public.profiles p on p.id=s.user_id
    left join public.doctor_profiles d on d.staff_id=s.id
    where s.user_id=p_user_id and s.active=true and p.role='staff' and p.active=true
      and s.account_type='doctor'
  )
$$;

revoke all on function public.erecpass_is_active_nurse(uuid) from public,anon;
revoke all on function public.erecpass_is_active_doctor(uuid) from public,anon;
grant execute on function public.erecpass_is_active_nurse(uuid) to authenticated;
grant execute on function public.erecpass_is_active_doctor(uuid) to authenticated;

create or replace function public.erecpass_doctor_unavailable_for_appointment(
  p_staff_id text,p_appointment_date date,p_appointment_time time default null
) returns boolean language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v_schedule public.staff_availability%rowtype; v_duration integer;
begin
  if not exists(select 1 from public.staff s join public.profiles p on p.id=s.user_id
    join public.doctor_profiles d on d.staff_id=s.id
    where s.id=p_staff_id and s.active=true and p.active=true and d.consultation_available=true) then return true; end if;
  select a.* into v_schedule from public.staff_availability a
  where a.staff_id=p_staff_id and a.day_of_week=extract(dow from p_appointment_date)::smallint and a.is_available=true;
  if not found then return true; end if;
  if p_appointment_time is null and not exists(
    select 1 from public.get_available_appointment_slots(p_staff_id,p_appointment_date) limit 1
  ) then return true; end if;
  if exists(select 1 from public.staff_unavailability u where u.staff_id=p_staff_id and u.unavailable_date=p_appointment_date
    and (u.start_time is null or p_appointment_time is null or
      (p_appointment_time<u.end_time and p_appointment_time+make_interval(mins=>v_schedule.appointment_duration_minutes)>u.start_time))) then return true; end if;
  if p_appointment_time is not null then
    v_duration:=coalesce(v_schedule.appointment_duration_minutes,30);
    if p_appointment_time<v_schedule.start_time or p_appointment_time+make_interval(mins=>v_duration)>v_schedule.end_time then return true; end if;
    if v_schedule.break_start is not null and p_appointment_time<v_schedule.break_end
      and p_appointment_time+make_interval(mins=>v_duration)>v_schedule.break_start then return true; end if;
  end if;
  return false;
end $$;
revoke all on function public.erecpass_doctor_unavailable_for_appointment(text,date,time) from public,anon;
grant execute on function public.erecpass_doctor_unavailable_for_appointment(text,date,time) to authenticated;

-- Patient requests enter the shared Nurse queue without a Doctor assignment.
create or replace function public.create_appointment_request(
  p_appointment_date date,
  p_appointment_time time,
  p_reason text
) returns public.appointments
language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  v_patient public.patients%rowtype;
  v_appointment public.appointments%rowtype;
begin
  if auth.uid() is null then raise exception 'Authentication required.' using errcode='28000'; end if;
  if not exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='patient' and p.active=true) then
    raise exception 'Active Patient access is required.' using errcode='42501';
  end if;
  if p_appointment_date is null or p_appointment_time is null then
    raise exception 'Choose a requested date and preferred time.' using errcode='22023';
  end if;
  if nullif(btrim(coalesce(p_reason,'')),'') is null then
    raise exception 'Enter the reason for your appointment.' using errcode='22023';
  end if;
  if (p_appointment_date+p_appointment_time) <= (now() at time zone 'Asia/Manila') then
    raise exception 'Appointment requests must be in the future (Asia/Manila time).' using errcode='22023';
  end if;
  select * into v_patient from public.patients p where p.user_id=auth.uid() for share;
  if not found then raise exception 'Your Supabase patient profile could not be found.' using errcode='P0002'; end if;

  insert into public.appointments(
    legacy_id,patient_id,patient_name,doctor,provider_staff_id,appointment_date,
    appointment_time,preferred_time,appointment_duration_minutes,reason,status,created_by
  ) values (
    gen_random_uuid()::text,v_patient.id,v_patient.full_name,'Unassigned',null,p_appointment_date,
    null,p_appointment_time,null,btrim(p_reason),'Pending',auth.uid()
  ) returning * into v_appointment;

  insert into public.appointment_notifications(patient_id,appointment_id,title,message,notification_type)
  values(v_patient.id,v_appointment.id,'Appointment request submitted',
    format('Your appointment request for %s at %s is waiting for Nurse assignment.',
      to_char(p_appointment_date,'FMMonth DD, YYYY'),to_char(p_appointment_time,'FMHH12:MI AM')||' Manila time'),'pending')
  on conflict do nothing;

  insert into public.appointment_actor_notifications(recipient_user_id,recipient_role,appointment_id,event_key,title,message)
  select s.user_id,'nurse',v_appointment.id,'appointment:'||v_appointment.id||':submitted:nurse:'||s.user_id,
    'New appointment request',format('%s requested an appointment for %s.',v_patient.full_name,to_char(p_appointment_date,'FMMonth DD, YYYY'))
  from public.staff s join public.profiles p on p.id=s.user_id and p.role='staff' and p.active=true
  where s.active=true and s.account_type='nurse'
    and not exists(select 1 from public.doctor_profiles d where d.staff_id=s.id)
  on conflict(event_key) do nothing;

  return v_appointment;
end $$;

revoke all on function public.create_appointment_request(date,time,text) from public,anon;
grant execute on function public.create_appointment_request(date,time,text) to authenticated;

-- Patient time is a preference for routing; the assigned Doctor confirms a
-- real slot later. Offer clinic-hour choices without reserving them.
create or replace function public.get_available_appointment_times(p_appointment_date date)
returns table(preferred_time time)
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare v_slot time;
begin
  if not exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='patient' and p.active=true) then
    raise exception 'Active Patient access is required.' using errcode='42501';
  end if;
  if p_appointment_date is null or p_appointment_date<(now() at time zone 'Asia/Manila')::date then return; end if;
  v_slot:='08:00';
  while v_slot<='17:00' loop
    if (p_appointment_date+v_slot)>(now() at time zone 'Asia/Manila') then
      preferred_time:=v_slot; return next;
    end if;
    v_slot:=v_slot+interval '30 minutes';
  end loop;
end $$;
revoke all on function public.get_available_appointment_times(date) from public,anon;
grant execute on function public.get_available_appointment_times(date) to authenticated;

create or replace function public.cancel_own_appointment(p_appointment_id bigint)
returns public.appointments
language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_appt public.appointments%rowtype; v_updated public.appointments%rowtype;
begin
  if not exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='patient' and p.active=true) then
    raise exception 'Active Patient access is required.' using errcode='42501';
  end if;
  select a.* into v_appt from public.appointments a join public.patients p on p.id=a.patient_id
  where a.id=p_appointment_id and p.user_id=auth.uid() for update of a;
  if not found then raise exception 'Your appointment was not found.' using errcode='P0002'; end if;
  if lower(btrim(v_appt.status)) not in ('pending','pending approval','assigned','approved') then
    raise exception 'Only pending, assigned, or approved appointments can be cancelled.' using errcode='55000';
  end if;
  update public.appointments set status='Cancelled',last_decision_by=auth.uid(),last_decision_at=now()
  where id=p_appointment_id returning * into v_updated;
  insert into public.appointment_audit_logs(appointment_id,changed_by,changed_by_role,previous_status,new_status,action,reason,previous_doctor_staff_id,new_doctor_staff_id)
  values(v_appt.id,auth.uid(),'patient',v_appt.status,v_updated.status,'patient_cancel','Cancelled by patient.',v_appt.provider_staff_id,v_appt.provider_staff_id);
  insert into public.appointment_notifications(patient_id,appointment_id,title,message,notification_type)
  values(v_appt.patient_id,v_appt.id,'Appointment cancelled','Your appointment has been cancelled.','cancelled') on conflict do nothing;
  if v_appt.provider_staff_id is not null then
    insert into public.appointment_actor_notifications(recipient_user_id,recipient_role,appointment_id,event_key,title,message)
    select s.user_id,'doctor',v_appt.id,'appointment:'||v_appt.id||':cancelled:'||s.user_id,'Appointment cancelled',
      format('The patient cancelled the appointment request for %s.',to_char(v_appt.appointment_date,'FMMonth DD, YYYY'))
    from public.staff s where s.id=v_appt.provider_staff_id on conflict(event_key) do nothing;
  end if;
  insert into public.appointment_actor_notifications(recipient_user_id,recipient_role,appointment_id,event_key,title,message)
  select s.user_id,'nurse',v_appt.id,'appointment:'||v_appt.id||':cancelled:nurse:'||s.user_id,'Appointment cancelled',
    format('%s cancelled the appointment request for %s.',v_appt.patient_name,to_char(v_appt.appointment_date,'FMMonth DD, YYYY'))
  from public.staff s join public.profiles p on p.id=s.user_id and p.role='staff' and p.active=true
  where s.active=true and s.account_type='nurse'
    and not exists(select 1 from public.doctor_profiles d where d.staff_id=s.id)
  on conflict(event_key) do nothing;
  return v_updated;
end $$;
revoke all on function public.cancel_own_appointment(bigint) from public,anon;
grant execute on function public.cancel_own_appointment(bigint) to authenticated;

-- A Doctor is chosen from registered active Doctor profiles and appointment
-- row locking ensures only one Nurse can win an unassigned/rejected request.
create or replace function public.nurse_assign_appointment(
  p_appointment_id bigint,
  p_doctor_staff_id text,
  p_reason text default ''
) returns public.appointments
language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  v_appt public.appointments%rowtype;
  v_updated public.appointments%rowtype;
  v_doctor public.staff%rowtype;
  v_assignment_id bigint;
  v_previous text;
  v_nurse_id text;
begin
  if not public.erecpass_is_active_nurse(auth.uid()) then
    raise exception 'Active Nurse access is required to assign Doctors.' using errcode='42501';
  end if;
  if nullif(btrim(coalesce(p_doctor_staff_id,'')),'') is null then
    raise exception 'Choose a Doctor.' using errcode='22023';
  end if;
  select s.* into v_doctor from public.staff s
  join public.profiles p on p.id=s.user_id and p.role='staff' and p.active=true
  join public.doctor_profiles d on d.staff_id=s.id and d.consultation_available=true
  where s.id=p_doctor_staff_id and s.active=true;
  if not found then raise exception 'The selected Doctor is not active or registered.' using errcode='P0002'; end if;
  select s.id into v_nurse_id from public.staff s where s.user_id=auth.uid() and s.active=true;

  select * into v_appt from public.appointments where id=p_appointment_id for update;
  if not found then raise exception 'Appointment not found.' using errcode='P0002'; end if;
  if lower(btrim(v_appt.status)) not in ('pending','pending approval','rejected','reassignment requested','assigned','approved') then
    raise exception 'Only unassigned or eligible rejected requests can be assigned.' using errcode='55000';
  end if;
  if lower(btrim(v_appt.status)) in ('assigned','approved') and
    not public.erecpass_doctor_unavailable_for_appointment(v_appt.provider_staff_id,v_appt.appointment_date,v_appt.appointment_time) then
    raise exception 'This Doctor is still available. Reassignment is only allowed after the assigned Doctor becomes unavailable.' using errcode='55000';
  end if;
  if lower(btrim(v_appt.status)) in ('pending','pending approval') and v_appt.provider_staff_id is not null then
    raise exception 'This request has already been assigned. Refresh the shared queue.' using errcode='55000';
  end if;
  if v_appt.provider_staff_id=p_doctor_staff_id and lower(btrim(v_appt.status))='rejected' then
    raise exception 'Choose a different Doctor to reassign this rejected request.' using errcode='22023';
  end if;
  v_previous:=v_appt.provider_staff_id;

  update public.appointments set provider_staff_id=v_doctor.id,assigned_doctor_user_id=v_doctor.user_id,doctor=v_doctor.name,
    assigned_nurse_id=auth.uid(),status='Assigned',rejection_reason=null,
    reassignment_reason=case when v_previous is not null then btrim(coalesce(p_reason,'')) else null end,
    appointment_time=case when lower(btrim(v_appt.status))='approved' then null else appointment_time end,
    last_decision_by=null,last_decision_at=null
  where id=p_appointment_id returning * into v_updated;

  insert into public.appointment_assignments(appointment_id,previous_doctor_staff_id,doctor_staff_id,doctor_user_id,assigned_by,assignment_reason)
  values(v_updated.id,v_previous,v_doctor.id,v_doctor.user_id,auth.uid(),btrim(coalesce(p_reason,''))) returning id into v_assignment_id;

  insert into public.appointment_audit_logs(
    appointment_id,changed_by,changed_by_role,previous_status,new_status,action,reason,previous_doctor_staff_id,new_doctor_staff_id,details
  ) values (
    v_updated.id,auth.uid(),'nurse',v_appt.status,'Assigned',case when v_previous is null then 'nurse_assign' else 'nurse_reassign' end,
    concat_ws(' | ',nullif(btrim(v_appt.rejection_reason),''),nullif(btrim(coalesce(p_reason,'')),'')),v_previous,v_doctor.id,
    jsonb_build_object('assignment_id',v_assignment_id,'nurse_staff_id',v_nurse_id,'previous_rejection_reason',v_appt.rejection_reason,'previous_appointment_time',v_appt.appointment_time)
  );

  insert into public.appointment_notifications(patient_id,appointment_id,title,message,notification_type)
  values(v_updated.patient_id,v_updated.id,'Doctor assigned',
    format('A Doctor has been assigned to your appointment request: %s.',v_doctor.name),'assigned')
  on conflict do nothing;

  insert into public.appointment_actor_notifications(recipient_user_id,recipient_role,appointment_id,event_key,title,message)
  values(v_doctor.user_id,'doctor',v_updated.id,'appointment:'||v_updated.id||':assigned:'||v_assignment_id,
    'Appointment assigned',format('Please review the appointment request from %s for %s.',v_updated.patient_name,to_char(v_updated.appointment_date,'FMMonth DD, YYYY')))
  on conflict(event_key) do nothing;

  insert into public.appointment_actor_notifications(recipient_user_id,recipient_role,appointment_id,event_key,title,message)
  select s.user_id,'nurse',v_updated.id,'appointment:'||v_updated.id||':assignment:'||v_assignment_id||':nurse:'||s.user_id,
    'Appointment assignment updated',format('%s was assigned to %s.',v_updated.patient_name,v_doctor.name)
  from public.staff s join public.profiles p on p.id=s.user_id and p.role='staff' and p.active=true
  where s.active=true and s.account_type='nurse'
    and not exists(select 1 from public.doctor_profiles d where d.staff_id=s.id)
  on conflict(event_key) do nothing;

  return v_updated;
end $$;
revoke all on function public.nurse_assign_appointment(bigint,text,text) from public,anon;
grant execute on function public.nurse_assign_appointment(bigint,text,text) to authenticated;

create or replace function public.nurse_list_active_doctors(p_appointment_date date)
returns table(
  staff_id text, user_id uuid, full_name text, professional_title text,
  specialization text, department text, professional_description text,
  doctor_identifier text, available_slots time[]
)
language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
  if not public.erecpass_is_active_nurse(auth.uid()) then
    raise exception 'Active Nurse access is required.' using errcode='42501';
  end if;
  return query
  select s.id,s.user_id,s.name,d.professional_title,
    coalesce(nullif(d.custom_specialization,''),m.specialization_name,d.sub_specialization,'Not specified'),
    d.department,d.professional_description,d.doctor_identifier,
    coalesce((select array_agg(x.appointment_time order by x.appointment_time)
      from public.get_available_appointment_slots(s.id,p_appointment_date) x),array[]::time[])
  from public.staff s
  join public.profiles p on p.id=s.user_id and p.role='staff' and p.active=true
  join public.doctor_profiles d on d.staff_id=s.id and d.consultation_available=true
  left join public.medical_specializations m on m.id=d.specialization_id and m.is_active=true
  where s.active=true
  order by s.name;
end $$;
revoke all on function public.nurse_list_active_doctors(date) from public,anon;
grant execute on function public.nurse_list_active_doctors(date) to authenticated;

-- Only the assigned Doctor can make the final decision. Rejected history stays
-- in appointment_audit_logs; approval validates the chosen slot in the trigger.
create or replace function public.doctor_decide_appointment(
  p_appointment_id bigint,p_decision text,p_reason text default null,p_note text default null,p_confirmed_time time default null
) returns public.appointments
language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  v_appt public.appointments%rowtype;
  v_updated public.appointments%rowtype;
  v_doctor_staff_id text;
  v_decision text:=lower(btrim(coalesce(p_decision,'')));
  v_new_status text;
  v_doctor_name text;
  v_assignment_id bigint;
begin
  if not public.erecpass_is_active_doctor(auth.uid()) then
    raise exception 'Active Doctor access is required.' using errcode='42501';
  end if;
  if v_decision not in ('approve','reject') then raise exception 'Decision must be approve or reject.' using errcode='22023'; end if;
  if v_decision='reject' and nullif(btrim(coalesce(p_reason,'')),'') is null then
    raise exception 'A rejection reason is required.' using errcode='22023';
  end if;
  select s.id,s.name into v_doctor_staff_id,v_doctor_name from public.staff s
  where s.user_id=auth.uid() and s.active=true;
  select * into v_appt from public.appointments where id=p_appointment_id for update;
  if not found then raise exception 'Appointment not found.' using errcode='P0002'; end if;
  if v_appt.provider_staff_id is distinct from v_doctor_staff_id then
    raise exception 'This appointment is not assigned to your Doctor account.' using errcode='42501';
  end if;
  if lower(btrim(v_appt.status)) not in ('assigned','pending','pending approval') then
    raise exception 'Only assigned pending requests can be decided.' using errcode='55000';
  end if;
  if v_decision='approve' and coalesce(p_confirmed_time,v_appt.appointment_time) is null then
    raise exception 'Choose a confirmed appointment time before approval.' using errcode='22023';
  end if;
  v_new_status:=case when v_decision='approve' then 'Approved' else 'Rejected' end;
  update public.appointments set status=v_new_status,
    appointment_time=case when v_decision='approve' then coalesce(p_confirmed_time,appointment_time) else appointment_time end,
    rejection_reason=case when v_decision='reject' then btrim(p_reason) else null end,
    staff_note=coalesce(nullif(btrim(p_note),''),staff_note),last_decision_by=auth.uid(),last_decision_at=now()
  where id=p_appointment_id returning * into v_updated;
  select a.id into v_assignment_id from public.appointment_assignments a
  where a.appointment_id=v_updated.id and a.doctor_staff_id=v_doctor_staff_id order by a.created_at desc limit 1;
  insert into public.appointment_audit_logs(
    appointment_id,changed_by,changed_by_role,previous_status,new_status,action,reason,previous_doctor_staff_id,new_doctor_staff_id,details
  ) values (
    v_updated.id,auth.uid(),'doctor',v_appt.status,v_updated.status,'doctor_'||v_decision,
    case when v_decision='reject' then btrim(p_reason) else coalesce(nullif(btrim(p_note),''),'Approved by assigned Doctor.') end,
    v_appt.provider_staff_id,v_updated.provider_staff_id,jsonb_build_object('assignment_id',v_assignment_id)
  );

  insert into public.appointment_notifications(patient_id,appointment_id,title,message,notification_type)
  values(v_updated.patient_id,v_updated.id,'Appointment '||v_new_status,
    case when v_decision='approve' then format('Your appointment with %s has been approved for %s at %s Manila time.',
      v_doctor_name,to_char(v_updated.appointment_date,'FMMonth DD, YYYY'),to_char(v_updated.appointment_time,'FMHH12:MI AM'))
    else 'Your appointment request has been rejected. Reason: '||btrim(p_reason) end,lower(v_new_status))
  on conflict do nothing;

  insert into public.appointment_actor_notifications(recipient_user_id,recipient_role,appointment_id,event_key,title,message)
  select s.user_id,'nurse',v_updated.id,'appointment:'||v_updated.id||':decision:'||v_new_status||':'||s.user_id,
    'Doctor '||lower(v_new_status),format('%s was %s by %s.',v_updated.patient_name,lower(v_new_status),v_doctor_name)
  from public.staff s join public.profiles p on p.id=s.user_id and p.role='staff' and p.active=true
  where s.active=true and s.account_type='nurse'
    and not exists(select 1 from public.doctor_profiles d where d.staff_id=s.id)
  on conflict(event_key) do nothing;
  return v_updated;
end $$;
revoke all on function public.doctor_decide_appointment(bigint,text,text,text,time) from public,anon;
grant execute on function public.doctor_decide_appointment(bigint,text,text,text,time) to authenticated;

-- Nurse approval is an audited override for an already assigned request. A
-- Doctor and a real available slot are still required; the appointment trigger
-- validates conflicts and schedule rules before the status can be approved.
create or replace function public.nurse_override_appointment_approval(
  p_appointment_id bigint,p_confirmed_time time,p_reason text
) returns public.appointments
language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  v_appt public.appointments%rowtype;
  v_updated public.appointments%rowtype;
  v_doctor_name text;
  v_doctor_user_id uuid;
  v_audit_id bigint;
begin
  if not public.erecpass_is_active_nurse(auth.uid()) then
    raise exception 'Active Nurse access is required to override an appointment.' using errcode='42501';
  end if;
  if p_confirmed_time is null then raise exception 'Choose the confirmed visit time.' using errcode='22023'; end if;
  if nullif(btrim(coalesce(p_reason,'')),'') is null then raise exception 'An override reason is required.' using errcode='22023'; end if;
  select * into v_appt from public.appointments where id=p_appointment_id for update;
  if not found then raise exception 'Appointment not found.' using errcode='P0002'; end if;
  if v_appt.provider_staff_id is null then raise exception 'Assign a Doctor before approving this request.' using errcode='55000'; end if;
  if lower(btrim(v_appt.status)) not in ('assigned','pending','pending approval','rejected') then
    raise exception 'Only assigned pending or rejected requests can be approved by a Nurse override.' using errcode='55000';
  end if;
  select s.name,s.user_id into v_doctor_name,v_doctor_user_id from public.staff s
  join public.profiles p on p.id=s.user_id and p.role='staff' and p.active=true
  join public.doctor_profiles d on d.staff_id=s.id and d.consultation_available=true
  where s.id=v_appt.provider_staff_id and s.account_type='doctor' and s.active=true;
  if not found then raise exception 'The assigned Doctor is inactive or unavailable for consultation.' using errcode='55000'; end if;

  update public.appointments set status='Approved',appointment_time=p_confirmed_time,
    rejection_reason=null,last_decision_by=auth.uid(),last_decision_at=now()
  where id=p_appointment_id returning * into v_updated;
  insert into public.appointment_audit_logs(
    appointment_id,changed_by,changed_by_role,previous_status,new_status,action,reason,
    previous_doctor_staff_id,new_doctor_staff_id,details
  ) values (
    v_updated.id,auth.uid(),'nurse',v_appt.status,'Approved','nurse_override_approve',btrim(p_reason),
    v_appt.provider_staff_id,v_updated.provider_staff_id,
    jsonb_build_object('previous_time',v_appt.appointment_time,'confirmed_time',v_updated.appointment_time)
  ) returning id into v_audit_id;
  insert into public.appointment_notifications(patient_id,appointment_id,title,message,notification_type)
  values(v_updated.patient_id,v_updated.id,'Appointment Approved',
    format('Your appointment with %s was approved by the Nurse for %s at %s Manila time.',
      v_doctor_name,to_char(v_updated.appointment_date,'FMMonth DD, YYYY'),to_char(v_updated.appointment_time,'FMHH12:MI AM')),'approved')
  on conflict do nothing;
  insert into public.appointment_actor_notifications(recipient_user_id,recipient_role,appointment_id,event_key,title,message)
  values(v_doctor_user_id,'doctor',v_updated.id,'appointment:'||v_updated.id||':nurse-override:'||v_audit_id,
    'Nurse approval override',format('%s was approved for %s at %s. Reason: %s',v_updated.patient_name,
      to_char(v_updated.appointment_date,'FMMonth DD, YYYY'),to_char(v_updated.appointment_time,'FMHH12:MI AM'),btrim(p_reason)))
  on conflict(event_key) do nothing;
  insert into public.appointment_actor_notifications(recipient_user_id,recipient_role,appointment_id,event_key,title,message)
  select s.user_id,'nurse',v_updated.id,'appointment:'||v_updated.id||':nurse-override:'||v_audit_id||':nurse:'||s.user_id,
    'Appointment approved by Nurse override',format('%s was approved by a Nurse. Reason: %s',v_updated.patient_name,btrim(p_reason))
  from public.staff s join public.profiles p on p.id=s.user_id and p.role='staff' and p.active=true
  where s.active=true and s.account_type='nurse'
  on conflict(event_key) do nothing;
  return v_updated;
end $$;
revoke all on function public.nurse_override_appointment_approval(bigint,time,text) from public,anon;
grant execute on function public.nurse_override_appointment_approval(bigint,time,text) to authenticated;

-- Retain the existing RPC name for older clients, but enforce Doctor-only
-- decisions so a Nurse cannot approve/reject through the legacy endpoint.
create or replace function public.staff_decide_appointment(
  p_appointment_id bigint,p_decision text,p_reason text default null,p_note text default null,p_appointment_time time default null
) returns public.appointments
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if not public.erecpass_is_active_doctor(auth.uid()) then
    raise exception 'Only the assigned Doctor can approve or reject this appointment.' using errcode='42501';
  end if;
  return public.doctor_decide_appointment(p_appointment_id,p_decision,p_reason,p_note,p_appointment_time);
end $$;
revoke all on function public.staff_decide_appointment(bigint,text,text,text,time) from public,anon;
grant execute on function public.staff_decide_appointment(bigint,text,text,text,time) to authenticated;

create or replace function public.admin_update_doctor_profile(
  p_staff_id text,p_specialization_id uuid,p_custom_specialization text,p_department text,
  p_description text,p_credentials text,p_reason text
) returns public.doctor_profiles
language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  v_old jsonb;
  v_new public.doctor_profiles%rowtype;
begin
  if not exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='admin' and p.active=true) then
    raise exception 'Active Admin access is required.' using errcode='42501';
  end if;
  if nullif(btrim(coalesce(p_reason,'')),'') is null then raise exception 'An audit reason is required.' using errcode='22023'; end if;
  if not exists(select 1 from public.staff s join public.profiles p on p.id=s.user_id where s.id=p_staff_id and s.active=true and p.role='staff' and p.active=true
    and s.account_type='doctor') then
    raise exception 'Active Doctor profile not found.' using errcode='P0002';
  end if;
  select to_jsonb(d) into v_old from public.doctor_profiles d where d.staff_id=p_staff_id for update;
  insert into public.doctor_profiles(staff_id,specialization_id,custom_specialization,department,professional_description,professional_credentials,admin_override_locked)
  values(p_staff_id,p_specialization_id,nullif(btrim(coalesce(p_custom_specialization,'')),''),btrim(coalesce(p_department,'')),btrim(coalesce(p_description,'')),btrim(coalesce(p_credentials,'')),true)
  on conflict(staff_id) do update set specialization_id=excluded.specialization_id,
    custom_specialization=excluded.custom_specialization,department=excluded.department,
    professional_description=excluded.professional_description,professional_credentials=excluded.professional_credentials,
    admin_override_locked=true
  returning * into v_new;
  insert into public.doctor_profile_audit_logs(doctor_staff_id,changed_by,change_reason,previous_profile,new_profile)
  values(p_staff_id,auth.uid(),btrim(p_reason),coalesce(v_old,'{}'::jsonb),to_jsonb(v_new));
  return v_new;
end $$;
revoke all on function public.admin_update_doctor_profile(text,uuid,text,text,text,text,text) from public,anon;
grant execute on function public.admin_update_doctor_profile(text,uuid,text,text,text,text,text) to authenticated;

create or replace function public.admin_set_doctor_active(p_staff_id text,p_active boolean,p_reason text)
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_user_id uuid; v_was_active boolean;
begin
  if not exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='admin' and p.active=true) then
    raise exception 'Active Admin access is required.' using errcode='42501';
  end if;
  if nullif(btrim(coalesce(p_reason,'')),'') is null then raise exception 'An audit reason is required.' using errcode='22023'; end if;
  select s.user_id,s.active into v_user_id,v_was_active from public.staff s
  join public.profiles p on p.id=s.user_id and p.role='staff'
  where s.id=p_staff_id and s.account_type='doctor' for update of s;
  if not found then raise exception 'Doctor account not found.' using errcode='P0002'; end if;
  update public.staff set active=p_active where id=p_staff_id;
  update public.profiles set active=p_active where id=v_user_id;
  insert into public.doctor_account_audit_logs(doctor_staff_id,changed_by,was_active,is_active,change_reason)
  values(p_staff_id,auth.uid(),v_was_active,p_active,btrim(p_reason));
  return p_active;
end $$;
revoke all on function public.admin_set_doctor_active(text,boolean,text) from public,anon;
grant execute on function public.admin_set_doctor_active(text,boolean,text) to authenticated;

create or replace function public.erecpass_notify_affected_appointments(
  p_staff_id text,p_date date,p_reason text,p_event_key text,p_all_times boolean default false,
  p_start_time time default null,p_end_time time default null
) returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_appt public.appointments%rowtype; v_doctor_name text;
begin
  select s.name into v_doctor_name from public.staff s where s.id=p_staff_id;
  for v_appt in select a.* from public.appointments a
    where a.provider_staff_id=p_staff_id and a.appointment_date=p_date
      and lower(btrim(a.status)) in ('assigned','approved')
      and (p_all_times or a.appointment_time is null or (a.appointment_time<p_end_time and
        a.appointment_time+make_interval(mins=>coalesce(a.appointment_duration_minutes,30))>p_start_time))
  loop
    if not exists(select 1 from public.appointment_notifications n where n.appointment_id=v_appt.id and n.notification_type='doctor_unavailable') then
      insert into public.appointment_notifications(patient_id,appointment_id,title,message,notification_type)
      values(v_appt.patient_id,v_appt.id,'Doctor availability changed',
        format('Your appointment with %s may need to be rescheduled because the Doctor reported unavailability. Please wait for a Nurse to contact you.',coalesce(v_doctor_name,'your Doctor')),
        'doctor_unavailable');
    end if;
    insert into public.appointment_audit_logs(appointment_id,changed_by,changed_by_role,previous_status,new_status,action,reason,previous_doctor_staff_id,new_doctor_staff_id)
    values(v_appt.id,auth.uid(),case when exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='admin') then 'admin' else 'staff' end,
      v_appt.status,v_appt.status,'doctor_unavailability_reported',p_reason,p_staff_id,p_staff_id);
    insert into public.appointment_actor_notifications(recipient_user_id,recipient_role,appointment_id,event_key,title,message)
    select s.user_id,'nurse',v_appt.id,p_event_key||':appointment:'||v_appt.id||':nurse:'||s.user_id,
      'Doctor availability changed',format('%s may need a new Doctor for %s. Reason: %s',v_appt.patient_name,to_char(v_appt.appointment_date,'FMMonth DD, YYYY'),p_reason)
    from public.staff s join public.profiles p on p.id=s.user_id and p.role='staff' and p.active=true
    where s.active=true and s.account_type='nurse'
      and not exists(select 1 from public.doctor_profiles d where d.staff_id=s.id)
    on conflict(event_key) do nothing;
  end loop;
end $$;
revoke all on function public.erecpass_notify_affected_appointments(text,date,text,text,boolean,time,time) from public,anon,authenticated;

create or replace function public.erecpass_staff_unavailability_notify()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  perform public.erecpass_notify_affected_appointments(new.staff_id,new.unavailable_date,
    coalesce(nullif(btrim(new.reason),''),'Doctor unavailable'),
    'doctor-unavailability:'||new.id||':'||new.created_at,new.start_time is null,new.start_time,new.end_time);
  return new;
end $$;
revoke all on function public.erecpass_staff_unavailability_notify() from public,anon,authenticated;
drop trigger if exists staff_unavailability_notify_appointments on public.staff_unavailability;
create trigger staff_unavailability_notify_appointments after insert or update on public.staff_unavailability
for each row execute function public.erecpass_staff_unavailability_notify();

create or replace function public.erecpass_staff_availability_notify()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_appt public.appointments%rowtype; v_reason text; v_day date; v_key text;
begin
  for v_appt in select a.* from public.appointments a
    where a.provider_staff_id=old.staff_id and extract(dow from a.appointment_date)::smallint=old.day_of_week
      and a.appointment_date>=(now() at time zone 'Asia/Manila')::date
      and lower(btrim(a.status)) in ('assigned','approved')
  loop
    if tg_op='DELETE' then v_reason:='Doctor removed a working day';
    elsif not new.is_available then v_reason:='Doctor marked this working day unavailable';
    elsif v_appt.appointment_time is not null and
      (v_appt.appointment_time<new.start_time or
       v_appt.appointment_time+make_interval(mins=>coalesce(v_appt.appointment_duration_minutes,new.appointment_duration_minutes))>new.end_time or
       (new.break_start is not null and v_appt.appointment_time<new.break_end and
        v_appt.appointment_time+make_interval(mins=>coalesce(v_appt.appointment_duration_minutes,new.appointment_duration_minutes))>new.break_start))
      then v_reason:='Doctor changed working hours or break time';
    else continue;
    end if;
    v_day:=v_appt.appointment_date;
    v_key:='doctor-schedule:'||old.id||':'||coalesce(new.updated_at,now())::text;
    perform public.erecpass_notify_affected_appointments(old.staff_id,v_day,v_reason,v_key,true,null,null);
  end loop;
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;
revoke all on function public.erecpass_staff_availability_notify() from public,anon,authenticated;
drop trigger if exists staff_availability_notify_appointments on public.staff_availability;
create trigger staff_availability_notify_appointments after update or delete on public.staff_availability
for each row execute function public.erecpass_staff_availability_notify();

-- Admin overrides keep before/after Doctor IDs in the existing appointment log.
create or replace function public.admin_override_appointment(
  p_appointment_id bigint,p_new_status text,p_reason text,p_provider_staff_id text default null,
  p_appointment_date date default null,p_appointment_time time default null
) returns public.appointments
language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  v_appt public.appointments%rowtype;
  v_updated public.appointments%rowtype;
  v_provider_name text;
  v_status text:=btrim(coalesce(p_new_status,''));
begin
  if not exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='admin' and p.active=true) then
    raise exception 'Active Admin access is required.' using errcode='42501';
  end if;
  if nullif(btrim(coalesce(p_reason,'')),'') is null then raise exception 'An override reason is required.' using errcode='22023'; end if;
  if v_status not in ('Pending','Pending Approval','Assigned','Approved','Rejected','Cancelled','Completed') then
    raise exception 'Unsupported appointment status.' using errcode='22023';
  end if;
  select * into v_appt from public.appointments where id=p_appointment_id for update;
  if not found then raise exception 'Appointment not found.' using errcode='P0002'; end if;
  if v_status='Assigned' and coalesce(p_provider_staff_id,v_appt.provider_staff_id) is null then
    raise exception 'Choose a Doctor before assigning this appointment.' using errcode='22023';
  end if;
  if p_provider_staff_id is not null and not exists(
    select 1 from public.staff s join public.profiles p on p.id=s.user_id and p.role='staff' and p.active=true
    where s.id=p_provider_staff_id and s.active=true and s.account_type='doctor'
  ) then raise exception 'The selected account is not an active Doctor.' using errcode='22023'; end if;
  update public.appointments set status=v_status,provider_staff_id=coalesce(p_provider_staff_id,provider_staff_id),
    assigned_doctor_user_id=case when p_provider_staff_id is null then assigned_doctor_user_id else (select s.user_id from public.staff s where s.id=p_provider_staff_id) end,
    doctor=case when p_provider_staff_id is null then doctor else (select s.name from public.staff s where s.id=p_provider_staff_id) end,
    appointment_date=coalesce(p_appointment_date,appointment_date),
    appointment_time=case when p_provider_staff_id is not null and p_provider_staff_id is distinct from provider_staff_id and v_status='Assigned'
      then null else coalesce(p_appointment_time,appointment_time) end,
    rejection_reason=case when v_status='Rejected' then btrim(p_reason) else null end,
    last_decision_by=auth.uid(),last_decision_at=now()
  where id=p_appointment_id returning * into v_updated;
  insert into public.appointment_audit_logs(
    appointment_id,changed_by,changed_by_role,previous_status,new_status,action,reason,previous_doctor_staff_id,new_doctor_staff_id,details
  ) values(v_updated.id,auth.uid(),'admin',v_appt.status,v_updated.status,'admin_override',btrim(p_reason),
    v_appt.provider_staff_id,v_updated.provider_staff_id,
    jsonb_build_object('previous_date',v_appt.appointment_date,'new_date',v_updated.appointment_date,
      'previous_time',v_appt.appointment_time,'new_time',v_updated.appointment_time));
  if v_appt.provider_staff_id is distinct from v_updated.provider_staff_id and v_updated.provider_staff_id is not null then
    insert into public.appointment_assignments(appointment_id,previous_doctor_staff_id,doctor_staff_id,doctor_user_id,assigned_by,assignment_reason)
    values(v_updated.id,v_appt.provider_staff_id,v_updated.provider_staff_id,v_updated.assigned_doctor_user_id,auth.uid(),'Administrative override: '||btrim(p_reason));
    insert into public.appointment_actor_notifications(recipient_user_id,recipient_role,appointment_id,event_key,title,message)
    select s.user_id,'doctor',v_updated.id,'appointment:'||v_updated.id||':admin-assigned:'||v_updated.updated_at,
      'Appointment assignment updated',format('Admin assigned an appointment request from %s for %s.',v_updated.patient_name,to_char(v_updated.appointment_date,'FMMonth DD, YYYY'))
    from public.staff s where s.id=v_updated.provider_staff_id
    on conflict(event_key) do nothing;
  end if;
  insert into public.appointment_actor_notifications(recipient_user_id,recipient_role,appointment_id,event_key,title,message)
  select p.id,'admin',v_updated.id,'appointment:'||v_updated.id||':admin-override:'||p.id||':'||v_updated.updated_at,
    'Appointment override recorded',format('Appointment %s was changed by an Admin. Reason: %s',v_updated.id,btrim(p_reason))
  from public.profiles p where p.role='admin' and p.active=true and p.id<>auth.uid()
  on conflict(event_key) do nothing;
  select s.name into v_provider_name from public.staff s where s.id=v_updated.provider_staff_id;
  if v_appt.status is distinct from v_updated.status or v_appt.provider_staff_id is distinct from v_updated.provider_staff_id
     or v_appt.appointment_date is distinct from v_updated.appointment_date or v_appt.appointment_time is distinct from v_updated.appointment_time then
    insert into public.appointment_notifications(patient_id,appointment_id,title,message,notification_type)
    values(v_updated.patient_id,v_updated.id,'Appointment update',
      format('Your appointment was updated by Admin. Current status: %s. %s',v_updated.status,btrim(p_reason)),'admin_override')
    on conflict do nothing;
  end if;
  return v_updated;
end $$;
revoke all on function public.admin_override_appointment(bigint,text,text,text,date,time) from public,anon;
grant execute on function public.admin_override_appointment(bigint,text,text,text,date,time) to authenticated;

alter table public.appointment_assignments enable row level security;
alter table public.doctor_profile_audit_logs enable row level security;
alter table public.appointment_actor_notifications enable row level security;
alter table public.doctor_account_audit_logs enable row level security;
grant select on public.appointment_assignments,public.doctor_profile_audit_logs,public.appointment_actor_notifications to authenticated;
grant select on public.doctor_account_audit_logs to authenticated;
grant update(is_read) on public.appointment_actor_notifications to authenticated;
grant usage,select on sequence public.appointment_assignments_id_seq,public.doctor_profile_audit_logs_id_seq,public.appointment_actor_notifications_id_seq to authenticated;

drop policy if exists appointment_assignments_visible_to_participants on public.appointment_assignments;
create policy appointment_assignments_visible_to_participants on public.appointment_assignments for select to authenticated using (
  public.erecpass_is_active_nurse(auth.uid())
  or exists(select 1 from public.staff s where s.id=appointment_assignments.doctor_staff_id and s.user_id=(select auth.uid()) and s.active=true)
  or exists(select 1 from public.profiles p where p.id=(select auth.uid()) and p.role='admin' and p.active=true)
);
drop policy if exists doctor_profile_audit_admin_read on public.doctor_profile_audit_logs;
create policy doctor_profile_audit_admin_read on public.doctor_profile_audit_logs for select to authenticated using (
  exists(select 1 from public.profiles p where p.id=(select auth.uid()) and p.role='admin' and p.active=true)
);
drop policy if exists doctor_account_audit_admin_read on public.doctor_account_audit_logs;
create policy doctor_account_audit_admin_read on public.doctor_account_audit_logs for select to authenticated using (
  exists(select 1 from public.profiles p where p.id=(select auth.uid()) and p.role='admin' and p.active=true)
);
drop policy if exists appointment_actor_notifications_owner_read on public.appointment_actor_notifications;
create policy appointment_actor_notifications_owner_read on public.appointment_actor_notifications for select to authenticated using(recipient_user_id=(select auth.uid()));
drop policy if exists appointment_actor_notifications_owner_mark_read on public.appointment_actor_notifications;
create policy appointment_actor_notifications_owner_mark_read on public.appointment_actor_notifications for update to authenticated
using(recipient_user_id=(select auth.uid())) with check(recipient_user_id=(select auth.uid()));

drop policy if exists appointments_nurse_shared_queue on public.appointments;
create policy appointments_nurse_shared_queue on public.appointments for select to authenticated using(public.erecpass_is_active_nurse(auth.uid()));
drop policy if exists appointment_audit_logs_nurse_shared on public.appointment_audit_logs;
create policy appointment_audit_logs_nurse_shared on public.appointment_audit_logs for select to authenticated using(public.erecpass_is_active_nurse(auth.uid()));

-- Doctor availability is self-managed; Nurses cannot edit Doctor schedules.
drop policy if exists staff_availability_owner_manage on public.staff_availability;
create policy staff_availability_owner_manage on public.staff_availability for all to authenticated
using(public.erecpass_is_active_doctor(auth.uid()) and exists(select 1 from public.staff s where s.id=staff_availability.staff_id and s.user_id=(select auth.uid()) and s.active=true))
with check(public.erecpass_is_active_doctor(auth.uid()) and exists(select 1 from public.staff s where s.id=staff_availability.staff_id and s.user_id=(select auth.uid()) and s.active=true));
drop policy if exists staff_unavailability_owner_manage on public.staff_unavailability;
create policy staff_unavailability_owner_manage on public.staff_unavailability for all to authenticated
using(public.erecpass_is_active_doctor(auth.uid()) and exists(select 1 from public.staff s where s.id=staff_unavailability.staff_id and s.user_id=(select auth.uid()) and s.active=true))
with check(public.erecpass_is_active_doctor(auth.uid()) and exists(select 1 from public.staff s where s.id=staff_unavailability.staff_id and s.user_id=(select auth.uid()) and s.active=true));

drop policy if exists doctor_profiles_owner_insert on public.doctor_profiles;
create policy doctor_profiles_owner_insert on public.doctor_profiles for insert to authenticated with check (
  exists(select 1 from public.staff s join public.profiles p on p.id=s.user_id
    where s.id=doctor_profiles.staff_id and s.user_id=(select auth.uid()) and s.active=true and p.role='staff' and p.active=true
      and s.account_type='doctor')
);
drop policy if exists doctor_profiles_admin_manage on public.doctor_profiles;
drop policy if exists doctor_profiles_directory_read on public.doctor_profiles;
create policy doctor_profiles_directory_read on public.doctor_profiles for select to authenticated using (
  consultation_available=true
  or exists(select 1 from public.profiles p where p.id=(select auth.uid()) and p.role='admin' and p.active=true)
);
drop policy if exists doctor_profiles_owner_update on public.doctor_profiles;
create policy doctor_profiles_owner_update on public.doctor_profiles for update to authenticated
using(exists(select 1 from public.staff s join public.profiles p on p.id=s.user_id
    where s.id=doctor_profiles.staff_id and s.user_id=(select auth.uid()) and s.active=true and p.role='staff' and p.active=true))
with check(exists(select 1 from public.staff s join public.profiles p on p.id=s.user_id
    where s.id=doctor_profiles.staff_id and s.user_id=(select auth.uid()) and s.active=true and p.role='staff' and p.active=true));

-- Supabase Realtime can publish shared queue and inbox changes when enabled.
do $$ begin
  if exists(select 1 from pg_publication where pubname='supabase_realtime') then
    begin alter publication supabase_realtime add table public.appointment_assignments; exception when duplicate_object then null; end;
    begin alter publication supabase_realtime add table public.appointment_actor_notifications; exception when duplicate_object then null; end;
    begin alter publication supabase_realtime add table public.appointments; exception when duplicate_object then null; end;
  end if;
end $$;

commit;

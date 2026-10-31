begin;

-- Patient time is a preference only. Staff records the confirmed time in appointment_time.
alter table public.appointments
  add column if not exists preferred_time time;

comment on column public.appointments.preferred_time is
  'Patient-requested time preference; not a confirmed appointment time.';
comment on column public.appointments.appointment_time is
  'Confirmed appointment time selected by staff.';

-- Pending requests may have no confirmed appointment_time yet. Validate the
-- actual time only when a time has been assigned or the request is approved.
create or replace function public.erecpass_validate_appointment_slot()
returns trigger language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  v_duration integer;
  v_end_time time;
begin
  if lower(trim(coalesce(new.status,''))) not in ('pending','pending approval','approved') then
    return new;
  end if;

  if new.status is not null and lower(trim(new.status))='approved'
     and (new.provider_staff_id is null or new.appointment_time is null) then
    raise exception 'Staff must assign a provider and confirmed visit time before approval.' using errcode='22023';
  end if;

  -- An unassigned legacy pending request or a new request with no confirmed
  -- time is allowed to remain pending.
  if new.provider_staff_id is null or new.appointment_time is null then
    return new;
  end if;

  if not exists (
    select 1 from public.staff s
    join public.profiles p on p.id=s.user_id
    where s.id=new.provider_staff_id and s.active=true
      and p.role='staff' and p.active=true
  ) then
    raise exception 'The assigned staff account is not active.' using errcode='22023';
  end if;

  if new.appointment_date is null
     or (new.appointment_date+new.appointment_time)<=(now() at time zone 'Asia/Manila') then
    raise exception 'The confirmed visit time must be in the future (Asia/Manila time).' using errcode='22023';
  end if;

  -- Serialize staff confirmations for one provider and date so concurrent
  -- approvals cannot claim overlapping times.
  perform pg_advisory_xact_lock(hashtextextended(new.provider_staff_id||'|'||new.appointment_date::text,0));

  v_duration:=coalesce(new.appointment_duration_minutes,30);
  if v_duration<5 or v_duration>240 then
    raise exception 'Invalid appointment duration.' using errcode='22023';
  end if;
  new.appointment_duration_minutes:=v_duration;
  v_end_time:=new.appointment_time+make_interval(mins=>v_duration);
  if (new.appointment_date+new.appointment_time+make_interval(mins=>v_duration))::date>new.appointment_date then
    raise exception 'Appointments cannot extend past midnight.' using errcode='22023';
  end if;

  if exists (
    select 1 from public.staff_unavailability u
    where u.staff_id=new.provider_staff_id
      and u.unavailable_date=new.appointment_date
      and (u.start_time is null or (new.appointment_time<u.end_time and v_end_time>u.start_time))
  ) then
    raise exception 'The assigned staff member is marked unavailable at that time.' using errcode='23P01';
  end if;

  if exists (
    select 1 from public.appointments a
    where a.provider_staff_id=new.provider_staff_id
      and a.appointment_date=new.appointment_date
      and a.id is distinct from new.id
      and a.appointment_time is not null
      and lower(trim(a.status)) in ('pending','pending approval','approved')
      and a.appointment_time<v_end_time
      and (a.appointment_time+make_interval(mins=>coalesce(a.appointment_duration_minutes,v_duration)))>new.appointment_time
  ) then
    raise exception 'That confirmed time overlaps another appointment for this staff member.' using errcode='23P01';
  end if;

  return new;
end $$;

-- Replace the original schedule-matching booking function. Choose an active
-- staff account for the date by current appointment workload; do not require
-- the patient's preferred time to match staff availability.
create or replace function public.create_appointment_request(
  p_appointment_date date,
  p_appointment_time time,
  p_reason text
) returns public.appointments
language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  v_patient public.patients%rowtype;
  v_provider record;
  v_appointment public.appointments%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Authentication required.' using errcode='28000';
  end if;
  if not exists (
    select 1 from public.profiles p
    where p.id=auth.uid() and p.role='patient' and p.active=true
  ) then
    raise exception 'Active Patient access is required.' using errcode='42501';
  end if;
  if p_appointment_date is null
     or p_appointment_date<(now() at time zone 'Asia/Manila')::date then
    raise exception 'Choose today or a future appointment date (Asia/Manila).' using errcode='22023';
  end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null or length(trim(p_reason))>1000 then
    raise exception 'Enter a consultation purpose of 1 to 1000 characters.' using errcode='22023';
  end if;

  select p.* into v_patient
  from public.patients p
  where p.user_id=auth.uid() and p.active=true;
  if not found then
    raise exception 'Your active Patient record could not be found.' using errcode='P0002';
  end if;

  select s.id,s.name into v_provider
  from public.staff s
  join public.profiles pr on pr.id=s.user_id
  where s.active=true and pr.role='staff' and pr.active=true
  order by (
    select count(*) from public.appointments a
    where a.provider_staff_id=s.id
      and a.appointment_date=p_appointment_date
      and lower(trim(a.status)) in ('pending','pending approval','approved')
  ), s.id
  limit 1;
  if not found then
    raise exception 'No active staff account is available to receive this request.' using errcode='P0002';
  end if;

  insert into public.appointments(
    legacy_id,patient_id,patient_name,doctor,provider_staff_id,appointment_date,
    appointment_time,preferred_time,appointment_duration_minutes,reason,status,created_by
  ) values(
    gen_random_uuid()::text,v_patient.id,v_patient.full_name,v_provider.name,v_provider.id,
    p_appointment_date,null,p_appointment_time,30,trim(p_reason),'Pending Approval',auth.uid()
  ) returning * into v_appointment;

  insert into public.appointment_notifications(
    patient_id,appointment_id,title,message,notification_type
  ) values(
    v_patient.id,v_appointment.id,'Appointment request submitted',
    format('Your appointment request for %s was submitted. Your preferred time is %s Manila time; staff will confirm the actual visit time.',
      to_char(p_appointment_date,'FMMonth DD, YYYY'),
      coalesce(to_char(p_appointment_time,'FMHH12:MI AM'),'not specified')),
    'pending'
  );

  return v_appointment;
end $$;

-- Staff must choose and save the confirmed visit time while approving.
create or replace function public.staff_decide_appointment(
  p_appointment_id bigint,
  p_decision text,
  p_reason text default null,
  p_note text default null,
  p_appointment_time time default null
) returns public.appointments
language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  v_staff_id text;
  v_appt public.appointments%rowtype;
  v_updated public.appointments%rowtype;
  v_decision text:=lower(trim(coalesce(p_decision,'')));
  v_new_status text;
  v_message text;
  v_provider_name text;
begin
  if auth.uid() is null then
    raise exception 'Authentication required.' using errcode='28000';
  end if;
  if v_decision not in ('approve','reject') then
    raise exception 'Decision must be approve or reject.' using errcode='22023';
  end if;
  if v_decision='reject' and nullif(trim(coalesce(p_reason,'')),'') is null then
    raise exception 'A rejection reason is required.' using errcode='22023';
  end if;
  if v_decision='approve' and p_appointment_time is null then
    raise exception 'Choose the confirmed visit time before approving this request.' using errcode='22023';
  end if;

  select s.id into v_staff_id
  from public.staff s join public.profiles p on p.id=s.user_id
  where s.user_id=auth.uid() and s.active=true and p.role='staff' and p.active=true;
  if v_staff_id is null then
    raise exception 'Active Staff access is required.' using errcode='42501';
  end if;

  select * into v_appt from public.appointments where id=p_appointment_id for update;
  if not found then
    raise exception 'Appointment not found.' using errcode='P0002';
  end if;
  if v_appt.provider_staff_id is distinct from v_staff_id then
    raise exception 'This appointment is not assigned to your account.' using errcode='42501';
  end if;
  if lower(trim(v_appt.status)) not in ('pending','pending approval') then
    raise exception 'Only pending appointments can be decided.' using errcode='55000';
  end if;

  v_new_status:=case when v_decision='approve' then 'Approved' else 'Rejected' end;
  update public.appointments set
    status=v_new_status,
    appointment_time=case when v_decision='approve' then p_appointment_time else appointment_time end,
    appointment_duration_minutes=case when v_decision='approve' then coalesce(appointment_duration_minutes,30) else appointment_duration_minutes end,
    rejection_reason=case when v_decision='reject' then trim(p_reason) else null end,
    staff_note=coalesce(nullif(trim(p_note),''),staff_note),
    last_decision_by=auth.uid(),
    last_decision_at=now()
  where id=p_appointment_id returning * into v_updated;

  insert into public.appointment_audit_logs(
    appointment_id,changed_by,changed_by_role,previous_status,new_status,action,reason
  ) values(
    v_appt.id,auth.uid(),'staff',v_appt.status,v_updated.status,'staff_'||v_decision,
    case when v_decision='reject' then trim(p_reason)
      else coalesce(nullif(trim(p_note),''),'Staff confirmed visit time: '||to_char(p_appointment_time,'FMHH12:MI AM')||' Manila time.') end
  );

  select s.name into v_provider_name from public.staff s where s.id=v_staff_id;
  if v_decision='approve' then
    v_message:=format('Your appointment with %s is confirmed for %s at %s Manila time.',
      coalesce(v_provider_name,v_appt.doctor,'your provider'),
      coalesce(to_char(v_updated.appointment_date,'FMMonth DD, YYYY'),'the selected date'),
      to_char(v_updated.appointment_time,'FMHH12:MI AM'));
  else
    v_message:='Your appointment request has been rejected. Reason: '||trim(p_reason);
  end if;
  insert into public.appointment_notifications(
    patient_id,appointment_id,title,message,notification_type
  ) values(
    v_appt.patient_id,v_appt.id,'Appointment '||v_new_status,v_message,lower(v_new_status)
  );
  return v_updated;
end $$;

commit;

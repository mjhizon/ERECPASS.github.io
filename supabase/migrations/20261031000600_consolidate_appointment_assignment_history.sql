begin;

-- Appointment assignments are already recorded in appointment_audit_logs.
-- Enrich matching audit entries from the duplicate table, then migrate any
-- assignment-only history before removing the duplicate table.
update public.appointment_audit_logs al
set details=coalesce(al.details,'{}'::jsonb)||jsonb_build_object(
  'doctor_user_id',aa.doctor_user_id,
  'assignment_reason',aa.assignment_reason,
  'assigned_by',aa.assigned_by
)
from public.appointment_assignments aa
where al.appointment_id=aa.appointment_id
  and al.changed_by is not distinct from aa.assigned_by
  and al.previous_doctor_staff_id is not distinct from aa.previous_doctor_staff_id
  and al.new_doctor_staff_id=aa.doctor_staff_id
  and al.created_at=aa.created_at
  and al.action in ('nurse_assign','nurse_reassign','admin_override');

insert into public.appointment_audit_logs(
  appointment_id,changed_by,changed_by_role,previous_status,new_status,action,reason,
  previous_doctor_staff_id,new_doctor_staff_id,details,created_at
)
select aa.appointment_id,aa.assigned_by,
  case when aa.assigned_by is null then 'system'
       when p.role='admin' then 'admin'
       when exists(select 1 from public.staff s where s.user_id=aa.assigned_by and s.account_type='nurse') then 'nurse'
       else 'staff' end,
  null,'Assigned','doctor_assignment',aa.assignment_reason,
  aa.previous_doctor_staff_id,aa.doctor_staff_id,
  jsonb_build_object('doctor_user_id',aa.doctor_user_id,'assignment_reason',aa.assignment_reason,'assigned_by',aa.assigned_by),
  aa.created_at
from public.appointment_assignments aa
left join public.profiles p on p.id=aa.assigned_by
where not exists (
  select 1 from public.appointment_audit_logs al
  where al.appointment_id=aa.appointment_id
    and al.changed_by is not distinct from aa.assigned_by
    and al.previous_doctor_staff_id is not distinct from aa.previous_doctor_staff_id
    and al.new_doctor_staff_id=aa.doctor_staff_id
    and al.created_at=aa.created_at
    and al.action in ('nurse_assign','nurse_reassign','admin_override')
);

-- Keep the existing Nurse assignment RPC, but make its audit row the sole
-- assignment history record and use that row ID for notification de-duplication.
create or replace function public.nurse_assign_appointment(
  p_appointment_id bigint,p_doctor_staff_id text,p_reason text default ''
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
  insert into public.appointment_audit_logs(
    appointment_id,changed_by,changed_by_role,previous_status,new_status,action,reason,
    previous_doctor_staff_id,new_doctor_staff_id,details
  ) values (
    v_updated.id,auth.uid(),'nurse',v_appt.status,'Assigned',case when v_previous is null then 'nurse_assign' else 'nurse_reassign' end,
    concat_ws(' | ',nullif(btrim(v_appt.rejection_reason),''),nullif(btrim(coalesce(p_reason,'')),'')),v_previous,v_doctor.id,
    jsonb_build_object('nurse_staff_id',v_nurse_id,'doctor_user_id',v_doctor.user_id,
      'assignment_reason',btrim(coalesce(p_reason,'')),'assigned_by',auth.uid(),
      'previous_rejection_reason',v_appt.rejection_reason,'previous_appointment_time',v_appt.appointment_time)
  ) returning id into v_assignment_id;
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

-- Doctor decisions use the latest assignment audit event instead of the old
-- assignment table when recording the appointment's audit details.
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
  if not public.erecpass_is_active_doctor(auth.uid()) then raise exception 'Active Doctor access is required.' using errcode='42501'; end if;
  if v_decision not in ('approve','reject') then raise exception 'Decision must be approve or reject.' using errcode='22023'; end if;
  if v_decision='reject' and nullif(btrim(coalesce(p_reason,'')),'') is null then raise exception 'A rejection reason is required.' using errcode='22023'; end if;
  select s.id,s.name into v_doctor_staff_id,v_doctor_name from public.staff s where s.user_id=auth.uid() and s.active=true;
  select * into v_appt from public.appointments where id=p_appointment_id for update;
  if not found then raise exception 'Appointment not found.' using errcode='P0002'; end if;
  if v_appt.provider_staff_id is distinct from v_doctor_staff_id then raise exception 'This appointment is not assigned to your Doctor account.' using errcode='42501'; end if;
  if lower(btrim(v_appt.status)) not in ('assigned','pending','pending approval') then raise exception 'Only assigned pending requests can be decided.' using errcode='55000'; end if;
  if v_decision='approve' and coalesce(p_confirmed_time,v_appt.appointment_time) is null then raise exception 'Choose a confirmed appointment time before approval.' using errcode='22023'; end if;
  v_new_status:=case when v_decision='approve' then 'Approved' else 'Rejected' end;
  update public.appointments set status=v_new_status,
    appointment_time=case when v_decision='approve' then coalesce(p_confirmed_time,appointment_time) else appointment_time end,
    rejection_reason=case when v_decision='reject' then btrim(p_reason) else null end,
    staff_note=coalesce(nullif(btrim(p_note),''),staff_note),last_decision_by=auth.uid(),last_decision_at=now()
  where id=p_appointment_id returning * into v_updated;
  select al.id into v_assignment_id from public.appointment_audit_logs al
  where al.appointment_id=v_updated.id and al.new_doctor_staff_id=v_doctor_staff_id
    and al.action in ('nurse_assign','nurse_reassign','admin_override','doctor_assignment')
  order by al.created_at desc limit 1;
  insert into public.appointment_audit_logs(
    appointment_id,changed_by,changed_by_role,previous_status,new_status,action,reason,previous_doctor_staff_id,new_doctor_staff_id,details
  ) values (
    v_updated.id,auth.uid(),'doctor',v_appt.status,v_updated.status,'doctor_'||v_decision,
    case when v_decision='reject' then btrim(p_reason) else coalesce(nullif(btrim(p_note),''),'Approved by assigned Doctor.') end,
    v_appt.provider_staff_id,v_updated.provider_staff_id,jsonb_build_object('assignment_audit_id',v_assignment_id)
  );
  insert into public.appointment_notifications(patient_id,appointment_id,title,message,notification_type)
  values(v_updated.patient_id,v_updated.id,'Appointment '||v_new_status,
    case when v_decision='approve' then format('Your appointment with %s has been approved for %s at %s Manila time.',v_doctor_name,to_char(v_updated.appointment_date,'FMMonth DD, YYYY'),to_char(v_updated.appointment_time,'FMHH12:MI AM'))
    else 'Your appointment request has been rejected. Reason: '||btrim(p_reason) end,lower(v_new_status)) on conflict do nothing;
  insert into public.appointment_actor_notifications(recipient_user_id,recipient_role,appointment_id,event_key,title,message)
  select s.user_id,'nurse',v_updated.id,'appointment:'||v_updated.id||':decision:'||v_new_status||':'||s.user_id,
    'Doctor '||lower(v_new_status),format('%s was %s by %s.',v_updated.patient_name,lower(v_new_status),v_doctor_name)
  from public.staff s join public.profiles p on p.id=s.user_id and p.role='staff' and p.active=true
  where s.active=true and s.account_type='nurse' and not exists(select 1 from public.doctor_profiles d where d.staff_id=s.id)
  on conflict(event_key) do nothing;
  return v_updated;
end $$;
revoke all on function public.doctor_decide_appointment(bigint,text,text,text,time) from public,anon;
grant execute on function public.doctor_decide_appointment(bigint,text,text,text,time) to authenticated;

-- Admin overrides are already represented by before/after Doctor IDs in the
-- audit table, so no second assignment-history row is written.
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
  if not exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='admin' and p.active=true) then raise exception 'Active Admin access is required.' using errcode='42501'; end if;
  if nullif(btrim(coalesce(p_reason,'')),'') is null then raise exception 'An override reason is required.' using errcode='22023'; end if;
  if v_status not in ('Pending','Pending Approval','Assigned','Approved','Rejected','Cancelled','Completed') then raise exception 'Unsupported appointment status.' using errcode='22023'; end if;
  select * into v_appt from public.appointments where id=p_appointment_id for update;
  if not found then raise exception 'Appointment not found.' using errcode='P0002'; end if;
  if v_status='Assigned' and coalesce(p_provider_staff_id,v_appt.provider_staff_id) is null then raise exception 'Choose a Doctor before assigning this appointment.' using errcode='22023'; end if;
  if p_provider_staff_id is not null and not exists(
    select 1 from public.staff s join public.profiles p on p.id=s.user_id and p.role='staff' and p.active=true
    where s.id=p_provider_staff_id and s.active=true and s.account_type='doctor'
  ) then raise exception 'The selected account is not an active Doctor.' using errcode='22023'; end if;
  update public.appointments set status=v_status,provider_staff_id=coalesce(p_provider_staff_id,provider_staff_id),
    assigned_doctor_user_id=case when p_provider_staff_id is null then assigned_doctor_user_id else (select s.user_id from public.staff s where s.id=p_provider_staff_id) end,
    doctor=case when p_provider_staff_id is null then doctor else (select s.name from public.staff s where s.id=p_provider_staff_id) end,
    appointment_date=coalesce(p_appointment_date,appointment_date),
    appointment_time=case when p_provider_staff_id is not null and p_provider_staff_id is distinct from provider_staff_id and v_status='Assigned' then null else coalesce(p_appointment_time,appointment_time) end,
    rejection_reason=case when v_status='Rejected' then btrim(p_reason) else null end,last_decision_by=auth.uid(),last_decision_at=now()
  where id=p_appointment_id returning * into v_updated;
  insert into public.appointment_audit_logs(
    appointment_id,changed_by,changed_by_role,previous_status,new_status,action,reason,previous_doctor_staff_id,new_doctor_staff_id,details
  ) values(v_updated.id,auth.uid(),'admin',v_appt.status,v_updated.status,'admin_override',btrim(p_reason),v_appt.provider_staff_id,v_updated.provider_staff_id,
    jsonb_build_object('previous_date',v_appt.appointment_date,'new_date',v_updated.appointment_date,'previous_time',v_appt.appointment_time,'new_time',v_updated.appointment_time,
      'assignment_reason',case when v_appt.provider_staff_id is distinct from v_updated.provider_staff_id then 'Administrative override: '||btrim(p_reason) else null end));
  if v_appt.provider_staff_id is distinct from v_updated.provider_staff_id and v_updated.provider_staff_id is not null then
    insert into public.appointment_actor_notifications(recipient_user_id,recipient_role,appointment_id,event_key,title,message)
    select s.user_id,'doctor',v_updated.id,'appointment:'||v_updated.id||':admin-assigned:'||v_updated.updated_at,
      'Appointment assignment updated',format('Admin assigned an appointment request from %s for %s.',v_updated.patient_name,to_char(v_updated.appointment_date,'FMMonth DD, YYYY'))
    from public.staff s where s.id=v_updated.provider_staff_id on conflict(event_key) do nothing;
  end if;
  insert into public.appointment_actor_notifications(recipient_user_id,recipient_role,appointment_id,event_key,title,message)
  select p.id,'admin',v_updated.id,'appointment:'||v_updated.id||':admin-override:'||p.id||':'||v_updated.updated_at,
    'Appointment override recorded',format('Appointment %s was changed by an Admin. Reason: %s',v_updated.id,btrim(p_reason))
  from public.profiles p where p.role='admin' and p.active=true and p.id<>auth.uid() on conflict(event_key) do nothing;
  select s.name into v_provider_name from public.staff s where s.id=v_updated.provider_staff_id;
  if v_appt.status is distinct from v_updated.status or v_appt.provider_staff_id is distinct from v_updated.provider_staff_id
     or v_appt.appointment_date is distinct from v_updated.appointment_date or v_appt.appointment_time is distinct from v_updated.appointment_time then
    insert into public.appointment_notifications(patient_id,appointment_id,title,message,notification_type)
    values(v_updated.patient_id,v_updated.id,'Appointment update',format('Your appointment was updated by Admin. Current status: %s. %s',v_updated.status,btrim(p_reason)),'admin_override')
    on conflict do nothing;
  end if;
  return v_updated;
end $$;
revoke all on function public.admin_override_appointment(bigint,text,text,text,date,time) from public,anon;
grant execute on function public.admin_override_appointment(bigint,text,text,text,date,time) to authenticated;

-- Remove the duplicate table after its history has been copied.
drop policy if exists appointment_assignments_visible_to_participants on public.appointment_assignments;
do $$ begin
  if exists (
    select 1 from pg_publication_tables
    where pubname='supabase_realtime'
      and schemaname='public'
      and tablename='appointment_assignments'
  ) then
    execute 'alter publication supabase_realtime drop table public.appointment_assignments';
  end if;
end $$;
drop table public.appointment_assignments;

commit;

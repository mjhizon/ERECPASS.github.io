begin;

-- Keep one Nurse assignment notification per appointment and recipient.
-- Reassignments refresh that notification instead of adding another inbox row.
create or replace function public.erecpass_refresh_nurse_assignment_notification()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_existing_id bigint;
begin
  if new.recipient_role = 'nurse'
     and new.title = 'Appointment assignment updated'
     and new.appointment_id is not null then
    update public.appointment_actor_notifications n
    set title = new.title,
        message = new.message,
        is_read = false,
        created_at = now()
    where n.id = (
      select old_notice.id
      from public.appointment_actor_notifications old_notice
      where old_notice.recipient_user_id = new.recipient_user_id
        and old_notice.recipient_role = 'nurse'
        and old_notice.appointment_id = new.appointment_id
        and old_notice.title = 'Appointment assignment updated'
      order by old_notice.created_at desc, old_notice.id desc
      limit 1
    )
    returning n.id into v_existing_id;

    if v_existing_id is not null then
      return null;
    end if;

    new.event_key := 'appointment:' || new.appointment_id
      || ':assignment:nurse:' || new.recipient_user_id;
  end if;

  return new;
end;
$$;

revoke all on function public.erecpass_refresh_nurse_assignment_notification()
  from public, anon, authenticated;

drop trigger if exists refresh_nurse_assignment_notification
  on public.appointment_actor_notifications;
create trigger refresh_nurse_assignment_notification
before insert on public.appointment_actor_notifications
for each row
execute function public.erecpass_refresh_nurse_assignment_notification();

commit;

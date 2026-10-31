begin;

-- Patients may remove only appointment notifications belonging to their own
-- patient record. This does not delete or modify the linked appointment.
grant delete on public.appointment_notifications to authenticated;

drop policy if exists appointment_notifications_owner_delete on public.appointment_notifications;
create policy appointment_notifications_owner_delete
on public.appointment_notifications
for delete
to authenticated
using (
  exists (
    select 1
    from public.patients p
    where p.id = appointment_notifications.patient_id
      and p.user_id = (select auth.uid())
  )
);

commit;

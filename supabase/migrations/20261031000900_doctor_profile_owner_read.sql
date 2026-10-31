begin;

-- Let an active Doctor read their own profile even when consultation is
-- temporarily disabled. This keeps the self-service profile editor usable.
drop policy if exists doctor_profiles_owner_read on public.doctor_profiles;
create policy doctor_profiles_owner_read
on public.doctor_profiles
for select
to authenticated
using (
  exists (
    select 1
    from public.staff s
    join public.profiles p on p.id = s.user_id
    where s.id = doctor_profiles.staff_id
      and s.user_id = (select auth.uid())
      and s.active = true
      and s.account_type = 'doctor'
      and p.role = 'staff'
      and p.active = true
  )
);

commit;

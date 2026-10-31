-- Read-only inventory for the active ERecPass Supabase project.
-- Run in Supabase Dashboard > SQL Editor. This returns schema metadata and
-- appointment status counts only; it does not return patient-identifying data
-- or modify database objects or records.

with
target_tables as (
  select n.nspname as schema_name,
         c.relname as table_name,
         c.relrowsecurity as rls_enabled,
         c.relforcerowsecurity as rls_forced
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relkind in ('r', 'p')
    and (
      c.relname in ('appointments', 'patients', 'staff', 'profiles')
      or c.relname ilike '%appointment%'
      or c.relname ilike '%availability%'
      or c.relname ilike '%doctor%'
      or c.relname ilike '%specializ%'
      or c.relname ilike '%notification%'
    )
),
columns_json as (
  select jsonb_agg(jsonb_build_object(
    'table', c.table_name,
    'ordinal', c.ordinal_position,
    'column', c.column_name,
    'data_type', c.data_type,
    'udt_name', c.udt_name,
    'nullable', c.is_nullable,
    'default', c.column_default
  ) order by c.table_name, c.ordinal_position) as details
  from information_schema.columns c
  join target_tables t on t.schema_name = c.table_schema and t.table_name = c.table_name
),
tables_json as (
  select jsonb_agg(jsonb_build_object(
    'schema', schema_name,
    'table', table_name,
    'rls_enabled', rls_enabled,
    'rls_forced', rls_forced
  ) order by table_name) as details
  from target_tables
),
constraints_json as (
  select jsonb_agg(jsonb_build_object(
    'table', c.conrelid::regclass::text,
    'name', c.conname,
    'type', c.contype,
    'definition', pg_get_constraintdef(c.oid, true)
  ) order by c.conrelid::regclass::text, c.conname) as details
  from pg_constraint c
  join target_tables t on t.table_name = c.conrelid::regclass::text
       or ('public.' || t.table_name) = c.conrelid::regclass::text
),
policies_json as (
  select jsonb_agg(jsonb_build_object(
    'table', schemaname || '.' || tablename,
    'name', policyname,
    'command', cmd,
    'roles', roles,
    'using', qual,
    'with_check', with_check
  ) order by tablename, policyname) as details
  from pg_policies p
  join target_tables t on t.schema_name = p.schemaname and t.table_name = p.tablename
),
indexes_json as (
  select jsonb_agg(jsonb_build_object(
    'table', schemaname || '.' || tablename,
    'name', indexname,
    'definition', indexdef
  ) order by tablename, indexname) as details
  from pg_indexes i
  join target_tables t on t.schema_name = i.schemaname and t.table_name = i.tablename
),
triggers_json as (
  select jsonb_agg(jsonb_build_object(
    'table', t.schema_name || '.' || t.table_name,
    'name', tg.tgname,
    'enabled', case tg.tgenabled when 'O' then 'origin' when 'D' then 'disabled'
                                when 'R' then 'replica' when 'A' then 'always' end,
    'definition', pg_get_triggerdef(tg.oid, true)
  ) order by t.table_name, tg.tgname) as details
  from pg_trigger tg
  join target_tables t on t.table_name = tg.tgrelid::regclass::text
       or ('public.' || t.table_name) = tg.tgrelid::regclass::text
  where not tg.tgisinternal
)
select 'tables_and_rls' as section, coalesce(details, '[]'::jsonb) as details from tables_json
union all
select 'columns' as section, coalesce(details, '[]'::jsonb) as details from columns_json
union all
select 'constraints_and_foreign_keys' as section, coalesce(details, '[]'::jsonb) as details from constraints_json
union all
select 'rls_policies' as section, coalesce(details, '[]'::jsonb) as details from policies_json
union all
select 'indexes' as section, coalesce(details, '[]'::jsonb) as details from indexes_json
union all
select 'triggers' as section, coalesce(details, '[]'::jsonb) as details from triggers_json
order by section;

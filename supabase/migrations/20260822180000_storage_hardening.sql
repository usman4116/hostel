-- Storage security migration; NOT executed. Makes sensitive buckets private and
-- applies path-scoped authenticated access. Storage is intentionally separate from table RLS.
begin;

insert into storage.buckets (id, name, public)
values
  ('contract-agreements', 'contract-agreements', false),
  ('contract-signature', 'contract-signature', false),
  ('room-inspection-photos', 'room-inspection-photos', false),
  ('maintenance-photos', 'maintenance-photos', false),
  ('payment-receipts', 'payment-receipts', false)
on conflict (id) do update set public = false;

-- Remove known permissive policies from older environments.
do $$
declare
  bucket_name text;
  policy_row record;
begin
  foreach bucket_name in array array[
    'contract-agreements', 'contract-signature', 'room-inspection-photos',
    'maintenance-photos', 'payment-receipts'
  ] loop
    for policy_row in
      select policyname from pg_policies
      where schemaname = 'storage' and tablename = 'objects'
        and (policyname ilike '%' || replace(bucket_name, '-', ' ') || '%'
          or policyname ilike '%' || bucket_name || '%')
    loop
      execute format('drop policy if exists %I on storage.objects', policy_row.policyname);
    end loop;
  end loop;
end;
$$;

-- Staff can manage sensitive objects. Staff membership is checked through the
-- helper installed by the table-RLS hardening migration.
create policy "Staff manage contract agreements" on storage.objects
  for all to authenticated
  using (bucket_id = 'contract-agreements' and public.is_staff_user())
  with check (bucket_id = 'contract-agreements' and public.is_staff_user());

create policy "Staff manage contract signatures" on storage.objects
  for all to authenticated
  using (bucket_id = 'contract-signature' and public.is_staff_user())
  with check (bucket_id = 'contract-signature' and public.is_staff_user());

create policy "Staff manage inspection photos" on storage.objects
  for all to authenticated
  using (bucket_id = 'room-inspection-photos' and public.is_staff_user())
  with check (bucket_id = 'room-inspection-photos' and public.is_staff_user());

create policy "Staff manage maintenance photos" on storage.objects
  for all to authenticated
  using (bucket_id = 'maintenance-photos' and public.is_staff_user())
  with check (bucket_id = 'maintenance-photos' and public.is_staff_user());

create policy "Staff manage payment receipts" on storage.objects
  for all to authenticated
  using (bucket_id = 'payment-receipts' and public.is_staff_user())
  with check (bucket_id = 'payment-receipts' and public.is_staff_user());

-- Contract agreement and signature paths begin with the contract UUID. The
-- related resident is resolved from the protected contracts table.
create policy "Residents read own contract agreements" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'contract-agreements'
    and exists (
      select 1 from public.contracts c
      where c.id::text = split_part(name, '/', 1)
        and c.resident_id = public.current_resident_id()
    )
  );

create policy "Residents read own contract signatures" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'contract-signature'
    and exists (
      select 1 from public.contracts c
      where c.id::text = split_part(name, '/', 1)
        and c.resident_id = public.current_resident_id()
    )
  );

create policy "Residents upload own contract signatures" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'contract-signature'
    and exists (
      select 1 from public.contracts c
      where c.id::text = split_part(name, '/', 1)
        and c.resident_id = public.current_resident_id()
        and c.status = 'Pending Signature'
    )
  );

-- Inspection paths are inspection/<admission>/<type>/<inspection>/....
create policy "Residents read own inspection photos" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'room-inspection-photos'
    and exists (
      select 1 from public.room_inspections ri
      where ri.id::text = split_part(name, '/', 4)
        and ri.resident_id = public.current_resident_id()
    )
  );

-- Maintenance paths are requests/<maintenance_request_id>/....
create policy "Residents read own maintenance photos" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'maintenance-photos'
    and exists (
      select 1 from public.maintenance_requests mr
      where mr.id::text = split_part(name, '/', 2)
        and mr.resident_id = public.current_resident_id()
    )
  );

create policy "Residents upload own maintenance photos" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'maintenance-photos'
    and exists (
      select 1 from public.maintenance_requests mr
      where mr.id::text = split_part(name, '/', 2)
        and mr.resident_id = public.current_resident_id()
    )
  );

-- Payment paths are resident/<resident-or-owner-id>/.... The database receipt
-- row remains the authority; this policy only permits an authenticated resident
-- to use their own path. Server APIs perform the bill/admission validation.
create policy "Residents read own payment receipts" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'payment-receipts'
    and split_part(name, '/', 1) = public.current_resident_id()::text
  );

create policy "Residents upload own payment receipts" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'payment-receipts'
    and split_part(name, '/', 1) = public.current_resident_id()::text
  );

revoke all on storage.objects from anon;
grant select, insert, update, delete on storage.objects to authenticated;

commit;

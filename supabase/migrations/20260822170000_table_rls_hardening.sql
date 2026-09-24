-- Security migration; NOT executed. Replaces blanket authenticated access with
-- staff-scoped and resident-owned table policies. Storage is intentionally out
-- of scope for this migration.
begin;

create or replace function public.is_staff_user()
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1
    from public.staff_users s
    where lower(btrim(s.email)) = lower(coalesce(auth.jwt() ->> 'email', ''))
      and lower(coalesce(s.status, '')) = 'active'
      and lower(coalesce(s.role, '')) in (
        'super admin', 'admin', 'manager', 'accountant', 'reception', 'staff'
      )
  );
$$;

create or replace function public.is_admin_user()
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1
    from public.staff_users s
    where lower(btrim(s.email)) = lower(coalesce(auth.jwt() ->> 'email', ''))
      and lower(coalesce(s.status, '')) = 'active'
      and lower(coalesce(s.role, '')) in ('super admin', 'admin')
  );
$$;

create or replace function public.current_resident_id()
returns uuid
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select r.id
  from public.residents r
  where lower(btrim(r.email)) = lower(coalesce(auth.jwt() ->> 'email', ''))
    and lower(coalesce(r.status, '')) <> 'archived'
  limit 1;
$$;

revoke all on function public.is_staff_user() from public, anon, authenticated;
revoke all on function public.is_admin_user() from public, anon, authenticated;
revoke all on function public.current_resident_id() from public, anon, authenticated;
grant execute on function public.is_staff_user() to authenticated;
grant execute on function public.is_admin_user() to authenticated;
grant execute on function public.current_resident_id() to authenticated;

-- Remove policies from the blanket-policy era and from the un-applied proposal
-- so an older environment cannot retain a permissive OR-combined policy.
do $$
declare
  target record;
  policy_row record;
begin
  for target in
    select tablename from pg_tables where schemaname = 'public'
  loop
    execute format('alter table public.%I enable row level security', target.tablename);
    execute format('revoke all on table public.%I from anon, authenticated', target.tablename);
    for policy_row in
      select policyname from pg_policies
      where schemaname = 'public' and tablename = target.tablename
    loop
      execute format('drop policy if exists %I on public.%I', policy_row.policyname, target.tablename);
    end loop;
    execute format('grant select, insert, update, delete on table public.%I to authenticated', target.tablename);
  end loop;
end;
$$;

grant usage, select on all sequences in schema public to authenticated;

-- Roles are an upper bound; module permissions are required for non-admin operators.
create or replace function public.staff_can_operate(p_module text, p_roles text[])
returns boolean language sql stable security definer
set search_path = pg_catalog, public as $$
  select exists (select 1 from public.staff_users s
    where lower(btrim(s.email)) = lower(coalesce(auth.jwt() ->> 'email', ''))
      and lower(s.status) = 'active'
      and (lower(s.role) in ('admin', 'super admin')
        or (lower(s.role) = any(p_roles)
          and (p_module in ('inventory','staff') or p_module = any(s.permissions)))));
$$;
revoke all on function public.staff_can_operate(text, text[]) from public, anon, authenticated;
grant execute on function public.staff_can_operate(text, text[]) to authenticated;

-- Preserve staff reads. Write policies are deliberately explicit per operation.
do $$
declare target record;
begin
  for target in select tablename from pg_tables where schemaname = 'public'
    and tablename not in ('staff_users', 'admin_data_action_audits', 'payment_allocations', 'payment_status_history')
  loop
    execute format('create policy "Staff read" on public.%I for select to authenticated using (public.is_staff_user())', target.tablename);
  end loop;
end;
$$;

-- No authenticated policy writes allocations/history/audits/portal links.
-- No direct payment DELETE: reversals preserve the ledger and its status history.
create policy "residents insert operators" on public.residents
  for insert to authenticated
  with check (public.staff_can_operate('residents', array['manager','reception']::text[]));
create policy "residents update operators" on public.residents
  for update to authenticated
  using (public.staff_can_operate('residents', array['manager','reception']::text[])) with check (public.staff_can_operate('residents', array['manager','reception']::text[]));
create policy "admissions insert operators" on public.admissions
  for insert to authenticated
  with check (public.staff_can_operate('admissions', array['manager']::text[])
    or (public.staff_can_operate('admissions', array['reception']::text[])
      and status = 'Pending' and deposit_status in ('Pending','Held')));
create policy "admissions update operators" on public.admissions
  for update to authenticated
  using (public.staff_can_operate('admissions', array['manager','reception']::text[])) with check (public.staff_can_operate('admissions', array['manager','reception']::text[]));
create policy "rooms insert operators" on public.rooms
  for insert to authenticated
  with check (public.staff_can_operate('rooms', array['manager']::text[]));
create policy "rooms update operators" on public.rooms
  for update to authenticated
  using (public.staff_can_operate('rooms', array['manager']::text[])) with check (public.staff_can_operate('rooms', array['manager']::text[]));
create policy "beds insert operators" on public.beds
  for insert to authenticated
  with check (public.staff_can_operate('beds', array['manager']::text[]));
create policy "beds update operators" on public.beds
  for update to authenticated
  using (public.staff_can_operate('beds', array['manager']::text[])) with check (public.staff_can_operate('beds', array['manager']::text[]));
create policy "contracts insert operators" on public.contracts
  for insert to authenticated
  with check (public.staff_can_operate('contracts', array['manager']::text[])
    or (public.staff_can_operate('contracts', array['reception']::text[])
      and status = 'Pending Signature' and owner_signature_status = 'Pending'
      and resident_signature_status = 'Pending' and not signed_by_resident and signed_at is null));
create policy "contracts update operators" on public.contracts
  for update to authenticated
  using (public.staff_can_operate('contracts', array['manager']::text[])) with check (public.staff_can_operate('contracts', array['manager']::text[]));
create policy "contract_templates insert operators" on public.contract_templates
  for insert to authenticated
  with check (public.staff_can_operate('contracts', array['manager']::text[]));
create policy "contract_templates update operators" on public.contract_templates
  for update to authenticated
  using (public.staff_can_operate('contracts', array['manager']::text[])) with check (public.staff_can_operate('contracts', array['manager']::text[]));
create policy "bills insert operators" on public.bills
  for insert to authenticated
  with check (public.staff_can_operate('rent_bills', array['manager','accountant']::text[]));
create policy "bills update operators" on public.bills
  for update to authenticated
  using (public.staff_can_operate('rent_bills', array['manager','accountant']::text[])) with check (public.staff_can_operate('rent_bills', array['manager','accountant']::text[]));
create policy "ac_bills insert operators" on public.ac_bills
  for insert to authenticated
  with check (public.staff_can_operate('meter_reading', array['manager','accountant']::text[]));
create policy "ac_bills update operators" on public.ac_bills
  for update to authenticated
  using (public.staff_can_operate('meter_reading', array['manager','accountant']::text[])) with check (public.staff_can_operate('meter_reading', array['manager','accountant']::text[]));
create policy "payments insert operators" on public.payments
  for insert to authenticated
  with check (public.staff_can_operate('payments', array['accountant']::text[])
    or public.staff_can_operate('rent_bills', array['accountant'])
    or public.staff_can_operate('security_deposits', array['accountant']));
create policy "payments update operators" on public.payments
  for update to authenticated
  using (public.staff_can_operate('payments', array['accountant']::text[])
    or public.staff_can_operate('rent_bills', array['accountant'])
    or public.staff_can_operate('security_deposits', array['accountant']))
  with check (public.staff_can_operate('payments', array['accountant']::text[])
    or public.staff_can_operate('rent_bills', array['accountant'])
    or public.staff_can_operate('security_deposits', array['accountant']));
create policy "payment_receipts insert operators" on public.payment_receipts
  for insert to authenticated
  with check (public.staff_can_operate('payments', array['accountant']::text[]));
create policy "payment_receipts update operators" on public.payment_receipts
  for update to authenticated
  using (public.staff_can_operate('payments', array['accountant']::text[])) with check (public.staff_can_operate('payments', array['accountant']::text[]));
create policy "notices insert operators" on public.notices
  for insert to authenticated
  with check (public.staff_can_operate('notices', array['manager','staff']::text[]));
create policy "notices update operators" on public.notices
  for update to authenticated
  using (public.staff_can_operate('notices', array['manager','staff']::text[])) with check (public.staff_can_operate('notices', array['manager','staff']::text[]));
create policy "notice_recipients insert operators" on public.notice_recipients
  for insert to authenticated
  with check (public.staff_can_operate('notices', array['manager','staff']::text[]));
create policy "notice_recipients update operators" on public.notice_recipients
  for update to authenticated
  using (public.staff_can_operate('notices', array['manager','staff']::text[])) with check (public.staff_can_operate('notices', array['manager','staff']::text[]));
create policy "notice_recipients delete operators" on public.notice_recipients
  for delete to authenticated
  using (public.staff_can_operate('notices', array['manager','staff']::text[]));
create policy "maintenance_requests insert operators" on public.maintenance_requests
  for insert to authenticated
  with check (public.staff_can_operate('maintenance', array['manager','staff']::text[]));
create policy "maintenance_requests update operators" on public.maintenance_requests
  for update to authenticated
  using (public.staff_can_operate('maintenance', array['manager','staff']::text[])) with check (public.staff_can_operate('maintenance', array['manager','staff']::text[]));
create policy "maintenance_photos insert operators" on public.maintenance_photos
  for insert to authenticated
  with check (public.staff_can_operate('maintenance', array['manager','staff']::text[]));
create policy "maintenance_photos delete operators" on public.maintenance_photos
  for delete to authenticated
  using (public.staff_can_operate('maintenance', array['manager','staff']::text[]));
create policy "room_inspections insert operators" on public.room_inspections
  for insert to authenticated
  with check (public.staff_can_operate('inspections', array['manager','staff']::text[]));
create policy "room_inspections update operators" on public.room_inspections
  for update to authenticated
  using (public.staff_can_operate('inspections', array['manager','staff']::text[])) with check (public.staff_can_operate('inspections', array['manager','staff']::text[]));
create policy "inspections insert operators" on public.inspections
  for insert to authenticated
  with check (public.staff_can_operate('inspections', array['manager','staff']::text[]));
create policy "inspections update operators" on public.inspections
  for update to authenticated
  using (public.staff_can_operate('inspections', array['manager','staff']::text[])) with check (public.staff_can_operate('inspections', array['manager','staff']::text[]));
create policy "complaints insert operators" on public.complaints
  for insert to authenticated
  with check (public.staff_can_operate('maintenance', array['manager','reception','staff']::text[]));
create policy "complaints update operators" on public.complaints
  for update to authenticated
  using (public.staff_can_operate('maintenance', array['manager','reception','staff']::text[])) with check (public.staff_can_operate('maintenance', array['manager','reception','staff']::text[]));
create policy "visitors insert operators" on public.visitors
  for insert to authenticated
  with check (public.staff_can_operate('admissions', array['manager','reception']::text[]));
create policy "visitors update operators" on public.visitors
  for update to authenticated
  using (public.staff_can_operate('admissions', array['manager','reception']::text[])) with check (public.staff_can_operate('admissions', array['manager','reception']::text[]));
create policy "inventory insert operators" on public.inventory
  for insert to authenticated
  with check (public.staff_can_operate('inventory', array['manager']::text[]));
create policy "inventory update operators" on public.inventory
  for update to authenticated
  using (public.staff_can_operate('inventory', array['manager']::text[])) with check (public.staff_can_operate('inventory', array['manager']::text[]));
create policy "inventory_categories insert operators" on public.inventory_categories
  for insert to authenticated
  with check (public.staff_can_operate('inventory', array['manager']::text[]));
create policy "inventory_categories update operators" on public.inventory_categories
  for update to authenticated
  using (public.staff_can_operate('inventory', array['manager']::text[])) with check (public.staff_can_operate('inventory', array['manager']::text[]));
create policy "inventory_assignments insert operators" on public.inventory_assignments
  for insert to authenticated
  with check (public.staff_can_operate('inventory', array['manager']::text[]));
create policy "inventory_assignments update operators" on public.inventory_assignments
  for update to authenticated
  using (public.staff_can_operate('inventory', array['manager']::text[])) with check (public.staff_can_operate('inventory', array['manager']::text[]));
create policy "inventory_assignments delete operators" on public.inventory_assignments
  for delete to authenticated
  using (public.staff_can_operate('inventory', array['manager']::text[]));
create policy "inventory_movements insert operators" on public.inventory_movements
  for insert to authenticated
  with check (public.staff_can_operate('inventory', array['manager']::text[]));
create policy "staff insert operators" on public.staff
  for insert to authenticated
  with check (public.staff_can_operate('staff', array['manager']::text[]));
create policy "staff update operators" on public.staff
  for update to authenticated
  using (public.staff_can_operate('staff', array['manager']::text[])) with check (public.staff_can_operate('staff', array['manager']::text[]));
create policy "system_settings insert operators" on public.system_settings
  for insert to authenticated
  with check (public.staff_can_operate('settings', array[]::text[]));
create policy "system_settings update operators" on public.system_settings
  for update to authenticated
  using (public.staff_can_operate('settings', array[]::text[])) with check (public.staff_can_operate('settings', array[]::text[]));

-- Admission cleanup is limited to an unactivated record; dependent FKs still restrict deletion.
create policy "Admission entry rollback" on public.admissions for delete to authenticated
  using (status = 'Pending' and public.staff_can_operate('admissions', array['manager','reception']));
-- Admission operators may claim/release beds, with column guards in the final migration.
create policy "Reception claim beds" on public.beds for update to authenticated
  using (public.staff_can_operate('admissions', array['manager','reception']))
  with check (public.staff_can_operate('admissions', array['manager','reception']));
create policy "Admission resident status" on public.residents for update to authenticated
  using (public.staff_can_operate('admissions', array['manager','reception']))
  with check (public.staff_can_operate('admissions', array['manager','reception']));
create policy "Admission contract lifecycle" on public.contracts for update to authenticated
  using (public.staff_can_operate('admissions', array['manager']))
  with check (public.staff_can_operate('admissions', array['manager']));
-- Explicit admin-only cleanup for standalone configuration/operational records.
-- Resident/payment/admission-history deletion remains in audited service RPCs.
create policy "Admin delete rooms" on public.rooms for delete to authenticated using (public.is_admin_user());
create policy "Admin delete beds" on public.beds for delete to authenticated using (public.is_admin_user());
create policy "Admin delete contract_templates" on public.contract_templates for delete to authenticated using (public.is_admin_user());
create policy "Admin delete bills" on public.bills for delete to authenticated using (public.is_admin_user());
create policy "Admin delete ac_bills" on public.ac_bills for delete to authenticated using (public.is_admin_user());
create policy "Admin delete notices" on public.notices for delete to authenticated using (public.is_admin_user());
create policy "Admin delete maintenance_photos" on public.maintenance_photos for delete to authenticated using (public.is_admin_user());
create policy "Admin delete inventory" on public.inventory for delete to authenticated using (public.is_admin_user());
create policy "Admin delete inventory_categories" on public.inventory_categories for delete to authenticated using (public.is_admin_user());
create policy "Admin delete inventory_assignments" on public.inventory_assignments for delete to authenticated using (public.is_admin_user());
create policy "Admin delete staff" on public.staff for delete to authenticated using (public.is_admin_user());

-- Alternate screens share these writes without broadening their role ceilings.
create policy "Deposit bill operators insert" on public.bills for insert to authenticated
  with check (bill_type = 'Security Deposit' and public.staff_can_operate('security_deposits', array['manager','accountant']));
create policy "Deposit bill operators update" on public.bills for update to authenticated
  using (bill_type = 'Security Deposit' and public.staff_can_operate('security_deposits', array['manager','accountant']))
  with check (bill_type = 'Security Deposit' and public.staff_can_operate('security_deposits', array['manager','accountant']));
create policy "Admission contract entry" on public.contracts for insert to authenticated
  with check (public.staff_can_operate('admissions', array['manager','reception'])
    and status = 'Pending Signature' and owner_signature_status = 'Pending'
    and resident_signature_status = 'Pending' and not signed_by_resident and signed_at is null);
create policy "Beds screen room insert" on public.rooms for insert to authenticated
  with check (public.staff_can_operate('beds', array['manager']));
create policy "Beds screen room update" on public.rooms for update to authenticated
  using (public.staff_can_operate('beds', array['manager'])) with check (public.staff_can_operate('beds', array['manager']));
create policy "Rooms screen beds insert" on public.beds for insert to authenticated
  with check (public.staff_can_operate('rooms', array['manager']));
create policy "Rooms screen beds update" on public.beds for update to authenticated
  using (public.staff_can_operate('rooms', array['manager'])) with check (public.staff_can_operate('rooms', array['manager']));
create policy "Billing meter insert" on public.ac_bills for insert to authenticated
  with check (public.staff_can_operate('rent_bills', array['manager','accountant']));
create policy "Billing meter update" on public.ac_bills for update to authenticated
  using (public.staff_can_operate('rent_bills', array['manager','accountant'])) with check (public.staff_can_operate('rent_bills', array['manager','accountant']));

-- Staff may read staff membership, but only active administrators may mutate
-- roles, permissions, status, or credentials.
create policy "Staff read staff users" on public.staff_users
  for select to authenticated
  using (public.is_staff_user());
create policy "Administrators manage staff users" on public.staff_users
  for all to authenticated
  using (public.is_admin_user())
  with check (public.is_admin_user());

-- The profile screen edits contact details, never email, roles or permissions.
create or replace function public.guard_staff_profile_columns()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if (auth.role() is null and session_user in ('postgres','supabase_admin'))
     or coalesce(auth.role(), '') = 'service_role' or public.is_admin_user() then return new; end if;
  if (to_jsonb(new) - array['full_name','phone','notes','updated_at']::text[])
     is distinct from (to_jsonb(old) - array['full_name','phone','notes','updated_at']::text[]) then
    raise exception 'Only administrators may change staff security fields.' using errcode = '42501';
  end if;
  return new;
end;
$$;
revoke all on function public.guard_staff_profile_columns() from public, anon, authenticated;
create trigger staff_profile_columns before update on public.staff_users
  for each row execute function public.guard_staff_profile_columns();
create policy "Staff update own contact details" on public.staff_users for update to authenticated
  using (public.is_staff_user() and lower(btrim(email)) = lower(coalesce(auth.jwt() ->> 'email', '')))
  with check (public.is_staff_user() and lower(btrim(email)) = lower(coalesce(auth.jwt() ->> 'email', '')));

create policy "Administrators read data action audits" on public.admin_data_action_audits
  for select to authenticated
  using (public.is_admin_user());

create policy "Staff read payment allocations" on public.payment_allocations
  for select to authenticated
  using (public.is_staff_user());

create policy "Staff read payment status history" on public.payment_status_history
  for select to authenticated
  using (public.is_staff_user());

-- Payment status history is written by the payment trigger/RPCs, not by a
-- client session. Keep the trigger able to append history while the table
-- remains non-writable through authenticated table access.
create or replace function public.record_payment_status_change()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if tg_op = 'INSERT' or new.payment_status is distinct from old.payment_status then
    insert into public.payment_status_history (
      payment_id, previous_status, next_status, actor, reason
    ) values (
      new.id,
      case when tg_op = 'INSERT' then null else old.payment_status end,
      new.payment_status,
      coalesce(new.verified_by, current_setting('request.jwt.claim.email', true)),
      new.notes
    );
  end if;
  return new;
end;
$$;
revoke all on function public.record_payment_status_change() from public, anon, authenticated;

-- Resident identity and current/historical admission ownership.
create policy "Residents read own profile" on public.residents
  for select to authenticated
  using (id = public.current_resident_id());

create policy "Residents read own admissions" on public.admissions
  for select to authenticated
  using (resident_id = public.current_resident_id());

create policy "Residents read own rooms" on public.rooms
  for select to authenticated
  using (exists (
    select 1 from public.admissions a
    where a.room_id = rooms.id
      and a.resident_id = public.current_resident_id()
      and a.status in ('Pending', 'Active')
  ));

create policy "Residents read own beds" on public.beds
  for select to authenticated
  using (exists (
    select 1 from public.admissions a
    where a.bed_id = beds.id
      and a.resident_id = public.current_resident_id()
      and a.status in ('Pending', 'Active')
  ));

create policy "Residents read own contracts" on public.contracts
  for select to authenticated
  using (resident_id = public.current_resident_id());

create policy "Residents submit own signature" on public.contracts
  for update to authenticated
  using (
    resident_id = public.current_resident_id()
    and status = 'Pending Signature'
    and exists (
      select 1 from public.admissions a
      where a.id = contracts.admission_id
        and a.resident_id = public.current_resident_id()
        and a.status in ('Pending', 'Active')
    )
  )
  with check (
    resident_id = public.current_resident_id()
    and status = 'Pending Signature'
    and exists (
      select 1 from public.admissions a
      where a.id = contracts.admission_id
        and a.resident_id = public.current_resident_id()
        and a.status in ('Pending', 'Active')
    )
  );

create or replace function public.prevent_resident_contract_privilege_changes()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if coalesce(auth.role(), '') = 'service_role' or public.is_staff_user() then
    return new;
  end if;
  if new.status is distinct from old.status
     or new.contract_content is distinct from old.contract_content
     or new.owner_signature_status is distinct from old.owner_signature_status
     or new.owner_signature_name is distinct from old.owner_signature_name
     or new.monthly_rent is distinct from old.monthly_rent
     or new.security_deposit is distinct from old.security_deposit
     or new.admission_id is distinct from old.admission_id
     or new.resident_id is distinct from old.resident_id then
    raise exception 'Residents may only submit their own contract signature.' using errcode = '42501';
  end if;
  return new;
end;
$$;
revoke all on function public.prevent_resident_contract_privilege_changes() from public, anon, authenticated;
create trigger resident_contract_privilege_guard
before update on public.contracts
for each row execute function public.prevent_resident_contract_privilege_changes();

-- Financial reads are resident-owned. Residents can submit pending proofs only;
-- verification, cancellation, allocations, balances, and audit history remain staff/service-role operations.
create policy "Residents read own approved bills" on public.bills
  for select to authenticated
  using (
    resident_id = public.current_resident_id()
    and lower(coalesce(bill_status, '')) not in ('draft', 'pending approval')
  );

create policy "Residents read own ac bills" on public.ac_bills
  for select to authenticated
  using (resident_id = public.current_resident_id());

create policy "Residents read own payments" on public.payments
  for select to authenticated
  using (resident_id = public.current_resident_id());

create policy "Residents read own receipts" on public.payment_receipts
  for select to authenticated
  using (resident_id = public.current_resident_id());

create policy "Residents submit pending own receipts" on public.payment_receipts
  for insert to authenticated
  with check (
    resident_id = public.current_resident_id()
    and status = 'Pending Verification'
    and verified = false
    and verified_by is null
    and verified_at is null
    and payment_id is null
    and exists (
      select 1 from public.bills b
      where b.id = payment_receipts.bill_id
        and b.resident_id = public.current_resident_id()
        and lower(coalesce(b.bill_status, '')) not in ('draft', 'pending approval', 'cancelled', 'archived')
    )
  );

create policy "Residents read own payment allocations" on public.payment_allocations
  for select to authenticated
  using (exists (
    select 1 from public.payments p
    where p.id = payment_allocations.payment_id
      and p.resident_id = public.current_resident_id()
  ));

create policy "Residents read own payment history" on public.payment_status_history
  for select to authenticated
  using (exists (
    select 1 from public.payments p
    where p.id = payment_status_history.payment_id
      and p.resident_id = public.current_resident_id()
  ));

-- Published resident notices are visible only when addressed by audience rules.
create policy "Residents read addressed notices" on public.notices
  for select to authenticated
  using (
    status = 'Published'
    and publish_date is not null
    and publish_date <= current_date
    and (expiry_date is null or expiry_date >= current_date)
    and (
      audience = 'All Residents'
      or (audience = 'Specific Resident' and resident_id = public.current_resident_id())
      or (audience = 'Specific Room' and exists (
        select 1 from public.admissions a
        where a.resident_id = public.current_resident_id()
          and a.room_id = notices.room_id
          and a.status in ('Pending', 'Active')
      ))
      or (audience = 'Selected Residents' and exists (
        select 1 from public.notice_recipients nr
        where nr.notice_id = notices.id
          and nr.resident_id = public.current_resident_id()
      ))
    )
  );

create policy "Residents read own notice recipients" on public.notice_recipients
  for select to authenticated
  using (resident_id = public.current_resident_id());

-- Resident maintenance/inspection access is row-owned and does not expose staff assignments.
create policy "Residents read own maintenance" on public.maintenance_requests
  for select to authenticated
  using (resident_id = public.current_resident_id());
create policy "Residents create own maintenance" on public.maintenance_requests
  for insert to authenticated
  with check (
    resident_id = public.current_resident_id()
    and exists (
      select 1 from public.admissions a
      where a.resident_id = public.current_resident_id()
        and a.room_id = maintenance_requests.room_id
        and a.status in ('Pending', 'Active')
    )
  );

create policy "Residents read own maintenance photos" on public.maintenance_photos
  for select to authenticated
  using (exists (
    select 1 from public.maintenance_requests m
    where m.id = maintenance_photos.maintenance_request_id
      and m.resident_id = public.current_resident_id()
  ));
create policy "Residents create own maintenance photos" on public.maintenance_photos
  for insert to authenticated
  with check (exists (
    select 1 from public.maintenance_requests m
    where m.id = maintenance_photos.maintenance_request_id
      and m.resident_id = public.current_resident_id()
  ));

create policy "Residents read own inspections" on public.inspections
  for select to authenticated
  using (resident_id = public.current_resident_id());
create policy "Residents read own room inspections" on public.room_inspections
  for select to authenticated
  using (resident_id = public.current_resident_id());
create policy "Residents read own complaints" on public.complaints
  for select to authenticated
  using (resident_id = public.current_resident_id());
create policy "Residents read own visitors" on public.visitors
  for select to authenticated
  using (resident_id = public.current_resident_id());

-- resident_portal_links, contract_templates, system_settings, inventory, staff,
-- and all other internal tables have no resident policy. They remain staff-only.

comment on function public.is_staff_user() is
  'RLS helper: active recognized staff roles only; never derived from client claims.';
comment on function public.is_admin_user() is
  'RLS helper: active admin or super admin only.';
comment on table public.payment_allocations is
  'RLS: staff manage; residents may read allocations belonging to their own payments.';
comment on table public.payment_status_history is
  'RLS: staff manage; residents may read history belonging to their own payments.';

commit;

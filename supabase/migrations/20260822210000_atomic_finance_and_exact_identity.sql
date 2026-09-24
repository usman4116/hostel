-- Local migration only. No remote execution. Requires the complete preceding chain.
begin;

-- Canonical email storage makes API equality case/whitespace independent without LIKE.
create or replace function public.normalize_identity_email()
returns trigger language plpgsql set search_path = pg_catalog, public as $$
begin
  new.email := lower(btrim(new.email));
  return new;
end;
$$;
revoke all on function public.normalize_identity_email() from public, anon, authenticated;
update public.staff_users set email = lower(btrim(email)) where email is distinct from lower(btrim(email));
update public.residents set email = lower(btrim(email)) where email is distinct from lower(btrim(email));
create trigger normalize_staff_email before insert or update of email on public.staff_users
  for each row execute function public.normalize_identity_email();
create trigger normalize_resident_email before insert or update of email on public.residents
  for each row execute function public.normalize_identity_email();

-- lock_financial_ledger() is installed before the payment RPCs in 20260822160000.
create or replace function public.lock_financial_statement()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  perform public.lock_financial_ledger();
  return null;
end;
$$;
revoke all on function public.lock_financial_statement() from public, anon, authenticated;
do $$
declare t text;
begin
  foreach t in array array['payments','payment_allocations','bills','payment_receipts','admissions'] loop
    execute format('create trigger financial_statement_lock before insert or update or delete on public.%I for each statement execute function public.lock_financial_statement()', t);
  end loop;
end;
$$;

-- Allocation-backed payments take precedence over bill_id; legacy rows count once.
create or replace function public.effective_bill_paid(p_bill_id uuid, p_exclude uuid default null)
returns numeric language sql volatile security definer set search_path = pg_catalog, public as $$
  select coalesce(sum(credit), 0)::numeric(12,2) from (
    select pa.amount as credit from public.payment_allocations pa
      join public.payments p on p.id = pa.payment_id
      where pa.bill_id = p_bill_id and p.payment_status = 'Verified'
        and (p_exclude is null or p.id <> p_exclude)
    union all
    select p.amount from public.payments p
      where p.bill_id = p_bill_id and p.payment_status = 'Verified'
        and (p_exclude is null or p.id <> p_exclude)
        and not exists (select 1 from public.payment_allocations pa where pa.payment_id = p.id)
  ) credits;
$$;
revoke all on function public.effective_bill_paid(uuid, uuid) from public, anon, authenticated;

create or replace function public.guard_payment_ledger()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
declare obligation record; b public.bills%rowtype; a public.admissions%rowtype;
begin
  perform public.lock_financial_ledger();
  if tg_op = 'UPDATE' then
    if new.id is distinct from old.id or new.resident_id is distinct from old.resident_id
       or (old.payment_status <> 'Pending' and
         (new.bill_id is distinct from old.bill_id or new.amount is distinct from old.amount
          or (new.payment_status is distinct from old.payment_status and new.payment_status <> 'Cancelled'))) then
      raise exception 'Only pending payments may be edited; reverse finalized payments.' using errcode = '23514';
    end if;
  end if;
  if nullif(btrim(new.reference_number), '') is not null and exists (
    select 1 from public.payments p where p.reference_number = new.reference_number and p.id <> new.id
  ) then raise exception 'Payment reference already exists.' using errcode = '23505'; end if;

  -- Enforce the outstanding amount for individual submissions AND verification.
  -- Combined pending submissions are validated by their exact-total RPC.
  for obligation in
    select new.bill_id as bill_id, new.amount as amount where new.bill_id is not null
    union all
    select pa.bill_id, pa.amount from public.payment_allocations pa
      where pa.payment_id = new.id and new.bill_id is null
    order by bill_id
  loop
    select * into b from public.bills where id = obligation.bill_id for update;
    if not found or b.resident_id is distinct from new.resident_id then
      raise exception 'Payment bill does not belong to resident.' using errcode = '23514';
    end if;
    select * into a from public.admissions where id = b.admission_id;
    if (tg_op = 'INSERT' or new.payment_status in ('Pending','Verified')) then
      if a.id is null or a.resident_id is distinct from new.resident_id
         or a.status not in ('Pending','Active')
         or b.bill_status in ('Draft','Pending Approval','Cancelled') then
        raise exception 'Payment requires a current payable admission obligation.' using errcode = '23514';
      end if;
      if b.bill_type = 'Security Deposit' and a.deposit_status not in ('Pending','Held') then
        raise exception 'Released or deducted deposits require settlement review.' using errcode = '23514';
      end if;
      if obligation.amount > b.total_amount - public.effective_bill_paid(b.id, new.id) then
        raise exception 'Payment exceeds current outstanding balance.' using errcode = '23514';
      end if;
      if new.bill_id is null and new.payment_status = 'Verified'
         and obligation.amount <> b.total_amount - public.effective_bill_paid(b.id, new.id) then
        raise exception 'Combined payment must settle the exact current outstanding obligations.' using errcode = '23514';
      end if;
    end if;
    if tg_op = 'UPDATE' and old.payment_status = 'Verified' and new.payment_status <> 'Verified'
       and b.bill_type = 'Security Deposit' and a.deposit_status not in ('Pending','Held') then
      raise exception 'Released or deducted deposits require settlement review.' using errcode = '23514';
    end if;
  end loop;
  new.verified := new.payment_status = 'Verified';
  if coalesce(auth.role(), '') = 'authenticated' then new.verified_by := auth.jwt() ->> 'email'; end if;
  if new.verified then new.verified_at := coalesce(new.verified_at, now()); else new.verified_at := null; end if;
  return new;
end;
$$;
revoke all on function public.guard_payment_ledger() from public, anon, authenticated;
create trigger payments_ledger_guard before insert or update on public.payments
  for each row execute function public.guard_payment_ledger();

-- Stored bill balances are projections, never client-authoritative values.
create or replace function public.project_bill_balance()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
declare paid numeric;
begin
  perform public.lock_financial_ledger();
  paid := public.effective_bill_paid(new.id);
  if paid > new.total_amount then raise exception 'Bill total is below verified payments.' using errcode = '23514'; end if;
  if tg_op = 'UPDATE' and (new.resident_id is distinct from old.resident_id or new.admission_id is distinct from old.admission_id or new.bill_type is distinct from old.bill_type)
    and exists (select 1 from public.payment_allocations where bill_id = old.id) then
    raise exception 'A payment obligation cannot be moved to another admission.' using errcode = '23514';
  end if;
  if new.bill_status = 'Cancelled' and paid > 0 then
    raise exception 'Reverse verified payments before cancelling their bill.' using errcode = '23514';
  end if;
  new.paid_amount := paid;
  new.balance_amount := new.total_amount - paid;
  if new.bill_status not in ('Draft','Pending Approval','Cancelled') then
    new.bill_status := case when new.total_amount > 0 and new.balance_amount = 0 then 'Paid'
      when paid > 0 then 'Partially Paid' when new.due_date < current_date then 'Overdue' else 'Pending' end;
  end if;
  return new;
end;
$$;
revoke all on function public.project_bill_balance() from public, anon, authenticated;
create trigger bills_balance_projection before insert or update on public.bills
  for each row execute function public.project_bill_balance();

create or replace function public.project_admission_deposit()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if new.status in ('Pending','Active') and new.deposit_status in ('Pending','Held') then
    new.deposit_status := case when new.security_deposit = 0 or exists (
      select 1 from public.bills b where b.admission_id = new.id and b.resident_id = new.resident_id
        and b.bill_type = 'Security Deposit' and b.bill_status not in ('Cancelled','Draft','Pending Approval')
        and b.total_amount > 0 and public.effective_bill_paid(b.id) >= b.total_amount
    ) then 'Held' else 'Pending' end;
  end if;
  return new;
end;
$$;
revoke all on function public.project_admission_deposit() from public, anon, authenticated;
create trigger admissions_deposit_projection before insert or update on public.admissions
  for each row execute function public.project_admission_deposit();

create or replace function public.refresh_deposit_from_bill()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if new.bill_type = 'Security Deposit' then
    update public.admissions set deposit_status = deposit_status
      where id = new.admission_id and status in ('Pending','Active') and deposit_status in ('Pending','Held');
  end if;
  return null;
end;
$$;
revoke all on function public.refresh_deposit_from_bill() from public, anon, authenticated;
create trigger bills_deposit_projection after insert or update on public.bills
  for each row execute function public.refresh_deposit_from_bill();

create or replace function public.refresh_payment_bills()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
declare ids uuid[] := '{}'::uuid[]; target uuid;
begin
  if tg_op <> 'INSERT' and old.bill_id is not null then ids := array_append(ids, old.bill_id); end if;
  if tg_op <> 'DELETE' then
    ids := ids || array(select bill_id from public.payment_allocations where payment_id = new.id);
    if new.bill_id is not null then ids := array_append(ids, new.bill_id); end if;
  end if;
  for target in select distinct x from unnest(ids) as t(x) where x is not null order by x loop
    update public.bills set paid_amount = paid_amount where id = target;
  end loop;
  return null;
end;
$$;
revoke all on function public.refresh_payment_bills() from public, anon, authenticated;
-- Runs after the single-bill allocation synchronization and history triggers.
create trigger payments_z_refresh_bills after insert or update or delete on public.payments
  for each row execute function public.refresh_payment_bills();

create or replace function public.guard_effective_allocation()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
declare ids uuid[] := '{}'::uuid[];
begin
  if tg_op <> 'INSERT' then ids := array_append(ids, old.payment_id); end if;
  if tg_op <> 'DELETE' then ids := array_append(ids, new.payment_id); end if;
  -- Finalized allocations are immutable outside parent synchronization/deletion.
  if pg_trigger_depth() = 1 and exists (
    select 1 from public.payments where id = any(ids) and payment_status <> 'Pending'
  ) then raise exception 'Reverse the payment instead of editing finalized allocations.' using errcode = '23514'; end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;
revoke all on function public.guard_effective_allocation() from public, anon, authenticated;
create trigger allocation_ledger_guard before insert or update or delete on public.payment_allocations
  for each row execute function public.guard_effective_allocation();

-- Guard Reception's necessary bed/occupancy writes and sensitive admission fields.
create or replace function public.guard_operational_columns()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
declare allowed text[];
begin
  if coalesce(auth.role(), '') = 'service_role' or public.is_admin_user()
     or public.staff_can_operate(case when tg_table_name = 'admissions' then 'admissions' else tg_table_name end, array['manager'])
     or (tg_table_name = 'residents' and public.staff_can_operate('residents', array['reception']))
     or (tg_table_name in ('rooms','beds') and (public.staff_can_operate('rooms', array['manager']) or public.staff_can_operate('beds', array['manager']))) then return new; end if;
  if tg_table_name = 'residents' then allowed := array['status','updated_at'];
  elsif tg_table_name = 'rooms' then
    allowed := array['occupied_beds','status','updated_at'];
    new.occupied_beds := (select count(*) from public.beds where room_id = old.id and status = 'Occupied');
    new.status := case when old.status in ('Maintenance','Inactive') then old.status
      when new.occupied_beds = 0 then 'Available' when new.occupied_beds >= old.total_beds then 'Occupied' else 'Partially Occupied' end;
  elsif tg_table_name = 'beds' then allowed := array['status','updated_at'];
  elsif tg_table_name = 'admissions' then
    if new.status = 'Active' and old.status <> 'Active' then
      raise exception 'Admission activation requires an administrator or manager.' using errcode = '42501';
    end if;
    if new.deposit_status is distinct from old.deposit_status
       and (new.deposit_status in ('Released','Deducted') or new.status not in ('Pending','Active')) then
      raise exception 'Deposit settlement requires an administrator or manager.' using errcode = '42501';
    end if;
    allowed := array['room_id','bed_id','admission_date','expected_leaving_date','actual_leaving_date','status','notes','deposit_status','updated_at'];
  end if;
  if (to_jsonb(new) - allowed) is distinct from (to_jsonb(old) - allowed) then
    raise exception 'Role cannot change protected operational fields.' using errcode = '42501';
  end if;
  return new;
end;
$$;
revoke all on function public.guard_operational_columns() from public, anon, authenticated;
create trigger rooms_role_columns before update on public.rooms for each row execute function public.guard_operational_columns();
create trigger beds_role_columns before update on public.beds for each row execute function public.guard_operational_columns();
create trigger admissions_role_columns before update on public.admissions for each row execute function public.guard_operational_columns();
create trigger residents_role_columns before update on public.residents for each row execute function public.guard_operational_columns();

-- Atomic receipt verification: receipt claim, ledger write, projection and link commit together.
create or replace function public.verify_single_payment_receipt(p_receipt_id uuid, p_verifier text)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare r public.payment_receipts%rowtype; p public.payments%rowtype; payment_key uuid;
begin
  perform public.lock_financial_ledger();
  select * into r from public.payment_receipts where id = p_receipt_id for update;
  if r.id is null or r.status <> 'Pending Verification' or r.bill_id is null then
    raise exception 'Receipt is no longer a pending single-bill proof.' using errcode = '40001';
  end if;
  if r.payment_id is not null then
    select * into p from public.payments where id = r.payment_id for update;
    if p.id is null or p.payment_status <> 'Pending' or p.bill_id is distinct from r.bill_id
       or p.resident_id is distinct from r.resident_id or p.amount <> r.amount then
      raise exception 'Payment does not match receipt.' using errcode = '23514';
    end if;
    payment_key := p.id;
    update public.payments set payment_status = 'Verified', verified_by = p_verifier, verified_at = now()
      where id = payment_key;
  else
    payment_key := gen_random_uuid();
    insert into public.payments(id, payment_number, resident_id, bill_id, amount, payment_method,
      reference_number, notes, payment_status, verified_by, verified_at)
    values(payment_key, 'PAY-' || replace(payment_key::text, '-', ''), r.resident_id, r.bill_id, r.amount,
      coalesce(substring(r.notes from '(?im)^Payment method:[ \t]*([^\r\n]+)'), 'Receipt submission'),
      r.reference_number, 'Verified from a resident receipt submission.', 'Verified', p_verifier, now());
  end if;
  update public.payment_receipts set payment_id = payment_key, status = 'Verified', verified = true,
    verified_by = p_verifier, verified_at = now() where id = r.id;
  return jsonb_build_object('payment_id', payment_key, 'receipt_id', r.id);
end;
$$;
revoke all on function public.verify_single_payment_receipt(uuid, text) from public, anon, authenticated;
grant execute on function public.verify_single_payment_receipt(uuid, text) to service_role;

create or replace function public.reject_single_payment_receipt(p_receipt_id uuid, p_actor text, p_reason text)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare r public.payment_receipts%rowtype;
begin
  perform public.lock_financial_ledger();
  select * into r from public.payment_receipts where id = p_receipt_id for update;
  if r.id is null or r.status <> 'Pending Verification' then raise exception 'Receipt is no longer pending.' using errcode = '40001'; end if;
  if r.payment_id is not null then
    update public.payments set payment_status = 'Rejected', verified_by = p_actor, notes = p_reason
      where id = r.payment_id and payment_status = 'Pending' and bill_id = r.bill_id and resident_id = r.resident_id;
    if not found then raise exception 'Linked payment is not pending.' using errcode = '40001'; end if;
  end if;
  update public.payment_receipts set status = 'Rejected', verified = false, verified_by = p_actor,
    verified_at = null, remarks = p_reason where id = r.id;
  return jsonb_build_object('receipt_id', r.id);
end;
$$;
revoke all on function public.reject_single_payment_receipt(uuid, text, text) from public, anon, authenticated;
grant execute on function public.reject_single_payment_receipt(uuid, text, text) to service_role;

-- Shared by every client reconciliation caller. A stale browser snapshot must not
-- reopen a cancelled bill or overwrite a concurrent payment's balance.
create or replace function public.refresh_bill_financials(p_bill_id uuid)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare b public.bills%rowtype;
begin
  if coalesce(auth.role(), '') <> 'service_role'
     and not (public.staff_can_operate('payments', array['accountant'])
       or public.staff_can_operate('rent_bills', array['manager','accountant'])
       or public.staff_can_operate('security_deposits', array['manager','accountant'])) then
    raise exception 'Finance permission is required.' using errcode = '42501';
  end if;
  perform public.lock_financial_ledger();
  update public.bills set paid_amount = paid_amount where id = p_bill_id returning * into b;
  if not found then raise exception 'Bill not found.' using errcode = 'P0002'; end if;
  return jsonb_build_object('paid', b.paid_amount, 'balance', b.balance_amount, 'status', b.bill_status, 'total', b.total_amount);
end;
$$;
revoke all on function public.refresh_bill_financials(uuid) from public, anon, authenticated;
grant execute on function public.refresh_bill_financials(uuid) to authenticated, service_role;

commit;

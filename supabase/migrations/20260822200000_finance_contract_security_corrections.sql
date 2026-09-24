-- Corrective migration only; not executed locally. Apply after 20260822190000.
begin;

-- Prevent concurrent writes while installing synchronization and repairing its projection.
lock table public.payments, public.payment_allocations in share row exclusive mode;

create or replace function public.validate_payment_allocation_total()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  affected_ids uuid[] := '{}'::uuid[];
  affected_id uuid;
  payment_row public.payments%rowtype;
  allocation_total numeric(12,2);
  allocation_count bigint;
begin
  -- Do not access NEW on DELETE or OLD on INSERT, or fields from another table.
  if tg_table_schema = 'public' and tg_table_name = 'payments' then
    if tg_op <> 'INSERT' then affected_ids := array_append(affected_ids, old.id); end if;
    if tg_op <> 'DELETE' then affected_ids := array_append(affected_ids, new.id); end if;
  elsif tg_table_schema = 'public' and tg_table_name = 'payment_allocations' then
    if tg_op <> 'INSERT' then affected_ids := array_append(affected_ids, old.payment_id); end if;
    if tg_op <> 'DELETE' then affected_ids := array_append(affected_ids, new.payment_id); end if;
  else
    raise exception 'Unexpected allocation validation trigger table.' using errcode = '23514';
  end if;

  -- Validate both the source and destination of a moved allocation, once each.
  for affected_id in
    select distinct parent_id from unnest(affected_ids) as parents(parent_id)
    where parent_id is not null order by parent_id
  loop
    select * into payment_row from public.payments where id = affected_id for update;
    -- Parent deletion cascades allocations; there is then no parent to validate.
    if not found then continue; end if;
    select coalesce(sum(amount), 0)::numeric(12,2), count(*)
      into allocation_total, allocation_count
    from public.payment_allocations where payment_id = affected_id;

    if payment_row.bill_id is not null then
      if allocation_count <> 1 or allocation_total <> payment_row.amount
         or exists (select 1 from public.payment_allocations
                    where payment_id = affected_id and bill_id <> payment_row.bill_id) then
        raise exception 'Single-bill payment requires one exact matching allocation.' using errcode = '23514';
      end if;
    elsif payment_row.payment_status = 'Verified' and allocation_total <> payment_row.amount then
      raise exception 'Verified combined payment allocations must equal the parent amount.' using errcode = '23514';
    end if;
    if allocation_total > 0 and allocation_total <> payment_row.amount then
      raise exception 'Payment allocation total must equal the parent payment amount.' using errcode = '23514';
    end if;
    if exists (
      select 1 from public.payment_allocations pa join public.bills b on b.id = pa.bill_id
      where pa.payment_id = affected_id and b.resident_id is distinct from payment_row.resident_id
    ) then
      raise exception 'Allocation bill must belong to the payment resident.' using errcode = '23514';
    end if;
  end loop;
  return null;
end;
$$;
revoke all on function public.validate_payment_allocation_total() from public, anon, authenticated;

-- Keep the existing allocation-table trigger deferred. Include DELETE and identity
-- changes on the parent trigger as well, so each operation resolves its own row shape.
drop trigger payment_status_allocation_check on public.payments;
create constraint trigger payment_status_allocation_check
  after insert or update or delete on public.payments
  deferrable initially deferred
  for each row execute function public.validate_payment_allocation_total();

-- Single-bill allocations are an exact projection of payments.bill_id/amount.
-- SECURITY DEFINER is needed because authenticated staff have allocation SELECT only.
create or replace function public.sync_single_bill_payment_allocation()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  -- Combined submissions create their own two rows in the existing RPC transaction.
  if new.bill_id is null then return new; end if;
  delete from public.payment_allocations
    where payment_id = new.id and bill_id <> new.bill_id;
  insert into public.payment_allocations (payment_id, bill_id, amount)
    values (new.id, new.bill_id, new.amount)
    on conflict (payment_id, bill_id) do update set amount = excluded.amount;
  return new;
end;
$$;
revoke all on function public.sync_single_bill_payment_allocation() from public, anon, authenticated;
create trigger payments_single_bill_allocation_sync
  after insert or update of bill_id, amount on public.payments
  for each row execute function public.sync_single_bill_payment_allocation();

-- Do not silently discard conflicting historical allocations. Empty fresh databases
-- pass this check; valid existing single-bill rows are repaired idempotently below.
do $$
begin
  if exists (
    select 1 from public.payment_allocations pa join public.payments p on p.id = pa.payment_id
    where p.bill_id is not null and pa.bill_id <> p.bill_id
  ) then
    raise exception 'Reconcile conflicting single-bill allocations before applying this migration.' using errcode = '23514';
  end if;
end;
$$;
insert into public.payment_allocations (payment_id, bill_id, amount)
  select id, bill_id, amount from public.payments where bill_id is not null
  on conflict (payment_id, bill_id) do update set amount = excluded.amount;

-- A resident may only move Pending/Re-sign Required to a complete Submitted signature.
-- All other columns, including future staff fields, are immutable to residents.
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
  if old.resident_id is distinct from public.current_resident_id()
     or old.status is distinct from 'Pending Signature'
     or old.resident_signature_status not in ('Pending', 'Re-sign Required')
     or new.resident_signature_status is distinct from 'Submitted'
     or new.signed_by_resident is distinct from true
     or new.signed_at is null
     or nullif(btrim(new.resident_signature_url), '') is null
     or nullif(btrim(old.contract_content), '') is null
     or not exists (
       select 1 from public.admissions a
       where a.id = old.admission_id and a.resident_id = old.resident_id and a.status = 'Pending'
     ) then
    raise exception 'Residents may only submit their own complete contract signature.' using errcode = '42501';
  end if;
  if (to_jsonb(new) - array['resident_signature_url', 'resident_signature_status', 'signed_by_resident', 'signed_at', 'updated_at']::text[])
     is distinct from
     (to_jsonb(old) - array['resident_signature_url', 'resident_signature_status', 'signed_by_resident', 'signed_at', 'updated_at']::text[]) then
    raise exception 'Residents cannot change contract terms or staff approval fields.' using errcode = '42501';
  end if;
  return new;
end;
$$;
revoke all on function public.prevent_resident_contract_privilege_changes() from public, anon, authenticated;

create or replace function public.cancel_payment_with_allocations(
  p_payment_id uuid,
  p_actor text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  payment_row public.payments%rowtype;
  allocation_row record;
  deposit_admission_id uuid;
begin
  perform public.lock_financial_ledger();
  select * into payment_row from public.payments where id = p_payment_id for update;
  if payment_row.id is null or payment_row.payment_status = 'Cancelled' then
    raise exception 'Payment is already cancelled or unavailable.' using errcode = '40001';
  end if;
  for allocation_row in select distinct bill_id from public.payment_allocations where payment_id = p_payment_id loop
    update public.bills b
    set paid_amount = coalesce((select sum(pa.amount) from public.payment_allocations pa join public.payments p on p.id = pa.payment_id where pa.bill_id = b.id and p.payment_status = 'Verified' and p.id <> p_payment_id), 0),
        balance_amount = greatest(b.total_amount - coalesce((select sum(pa.amount) from public.payment_allocations pa join public.payments p on p.id = pa.payment_id where pa.bill_id = b.id and p.payment_status = 'Verified' and p.id <> p_payment_id), 0), 0),
        bill_status = case when greatest(b.total_amount - coalesce((select sum(pa.amount) from public.payment_allocations pa join public.payments p on p.id = pa.payment_id where pa.bill_id = b.id and p.payment_status = 'Verified' and p.id <> p_payment_id), 0), 0) = 0 then 'Paid' when coalesce((select sum(pa.amount) from public.payment_allocations pa join public.payments p on p.id = pa.payment_id where pa.bill_id = b.id and p.payment_status = 'Verified' and p.id <> p_payment_id), 0) > 0 then 'Partially Paid' else 'Pending' end,
        updated_at = now()
    where id = allocation_row.bill_id;
    -- A non-deposit iteration must never clear an earlier deposit admission.
    if exists (select 1 from public.bills where id = allocation_row.bill_id and bill_type = 'Security Deposit') then
      select admission_id into deposit_admission_id from public.bills
      where id = allocation_row.bill_id and bill_type = 'Security Deposit';
    end if;
  end loop;
  update public.payments set payment_status = 'Cancelled', verified = false, verified_by = p_actor, verified_at = null, notes = p_reason, updated_at = now() where id = p_payment_id and payment_status <> 'Cancelled';
  update public.payment_receipts set status = 'Rejected', verified = false, verified_by = p_actor, verified_at = null, remarks = p_reason, updated_at = now() where payment_id = p_payment_id and status = 'Pending Verification';
  if deposit_admission_id is not null then
    update public.admissions set deposit_status = case when exists (select 1 from public.bills where admission_id = deposit_admission_id and bill_type = 'Security Deposit' and bill_status = 'Paid') then 'Held' else 'Pending' end, updated_at = now() where id = deposit_admission_id and status in ('Pending', 'Active');
  end if;
  return jsonb_build_object('payment_id', p_payment_id);
end;
$$;

revoke all on function public.cancel_payment_with_allocations(uuid, text, text) from public, anon, authenticated;
grant execute on function public.cancel_payment_with_allocations(uuid, text, text) to service_role;

commit;

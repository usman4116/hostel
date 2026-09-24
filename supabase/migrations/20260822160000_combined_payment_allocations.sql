-- Local corrective migration; NOT executed. Adds one-payment/many-obligation accounting.
begin;

-- Shared transaction gate; installed before every payment RPC that uses it.
-- READ COMMITTED volatile queries after this lock see the previous writer's commit.
create or replace function public.lock_financial_ledger()
returns void language plpgsql volatile set search_path = pg_catalog, public as $$
begin
  if current_setting('transaction_isolation') <> 'read committed' then
    raise exception 'Retry financial writes at READ COMMITTED.' using errcode = '40001';
  end if;
  perform pg_advisory_xact_lock(20260822, 2100);
end;
$$;
revoke all on function public.lock_financial_ledger() from public, anon, authenticated;

alter table public.payments
  alter column bill_id drop not null;

create table public.payment_allocations (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.payments(id) on delete cascade,
  bill_id uuid not null references public.bills(id) on delete restrict,
  amount numeric(12,2) not null check (amount > 0),
  created_at timestamptz not null default now(),
  unique (payment_id, bill_id)
);

create index payment_allocations_bill_id_idx
  on public.payment_allocations (bill_id, created_at desc);
create index payment_allocations_payment_id_idx
  on public.payment_allocations (payment_id);

insert into public.payment_allocations (payment_id, bill_id, amount)
select id, bill_id, amount
from public.payments
where bill_id is not null
on conflict (payment_id, bill_id) do nothing;

create table public.payment_status_history (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.payments(id) on delete cascade,
  previous_status text,
  next_status text not null check (next_status in ('Pending', 'Verified', 'Rejected', 'Cancelled')),
  actor text,
  reason text,
  created_at timestamptz not null default now()
);

create index payment_status_history_payment_id_idx
  on public.payment_status_history (payment_id, created_at desc);

create or replace function public.validate_payment_allocation_total()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  payment_row public.payments%rowtype;
  allocation_total numeric(12,2);
begin
  select * into payment_row
  from public.payments
  where id = coalesce(new.payment_id, old.payment_id);

  if payment_row.id is null then
    return null;
  end if;

  select coalesce(sum(amount), 0)::numeric(12,2)
    into allocation_total
  from public.payment_allocations
  where payment_id = payment_row.id;

  if payment_row.bill_id is null and payment_row.payment_status = 'Verified'
     and allocation_total <> payment_row.amount then
    raise exception 'Verified combined payment allocations must equal the parent amount.' using errcode = '23514';
  end if;

  if allocation_total > 0 and allocation_total <> payment_row.amount then
    raise exception 'Payment allocation total must equal the parent payment amount.' using errcode = '23514';
  end if;

  return null;
end;
$$;

create constraint trigger payment_allocations_total_check
after insert or update or delete on public.payment_allocations
deferrable initially deferred
for each row execute function public.validate_payment_allocation_total();

create constraint trigger payment_status_allocation_check
after insert or update of amount, bill_id, payment_status on public.payments
deferrable initially deferred
for each row execute function public.validate_payment_allocation_total();

create or replace function public.record_payment_status_change()
returns trigger
language plpgsql
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

create trigger payments_status_history
after insert or update of payment_status on public.payments
for each row execute function public.record_payment_status_change();

create or replace function public.verify_payment_with_allocations(
  p_payment_id uuid,
  p_receipt_id uuid,
  p_verifier text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  payment_row public.payments%rowtype;
  receipt_row public.payment_receipts%rowtype;
  allocation_row record;
  current_admission_id uuid;
  allocation_total numeric(12,2) := 0;
  verified_before numeric(12,2);
  v_paid_amount numeric(12,2);
  v_balance_amount numeric(12,2);
  v_next_bill_status text;
  deposit_bill_id uuid;
  allocation_count integer := 0;
  regular_bill_count integer := 0;
  now_at timestamptz := now();
begin
  perform public.lock_financial_ledger();
  select * into payment_row
  from public.payments
  where id = p_payment_id
  for update;
  if payment_row.id is null or payment_row.payment_status <> 'Pending' then
    raise exception 'Payment is no longer pending.' using errcode = '40001';
  end if;
  if payment_row.bill_id is not null then
    raise exception 'Allocation verification is only for combined payments.' using errcode = '22023';
  end if;

  select * into receipt_row
  from public.payment_receipts
  where id = p_receipt_id and payment_id = p_payment_id
  for update;
  if receipt_row.id is null or receipt_row.status <> 'Pending Verification' then
    raise exception 'Receipt is no longer pending verification.' using errcode = '40001';
  end if;
  if receipt_row.resident_id <> payment_row.resident_id
     or round(receipt_row.amount, 2) <> round(payment_row.amount, 2) then
    raise exception 'Receipt and payment do not match.' using errcode = '23514';
  end if;

  select coalesce(sum(amount), 0)::numeric(12,2)
    into allocation_total
  from public.payment_allocations
  where payment_id = p_payment_id;
  if allocation_total <> payment_row.amount then
    raise exception 'Payment allocation total must equal the parent payment amount.' using errcode = '23514';
  end if;

  for allocation_row in
    select pa.bill_id, pa.amount, b.resident_id, b.admission_id,
           b.total_amount, b.due_date, b.bill_status, b.bill_type
    from public.payment_allocations pa
    join public.bills b on b.id = pa.bill_id
    where pa.payment_id = p_payment_id
    order by pa.created_at, pa.id
    for update of b
  loop
    if allocation_row.resident_id <> payment_row.resident_id
       or allocation_row.admission_id is null then
      raise exception 'Payment allocation does not belong to the payment resident.' using errcode = '23514';
    end if;
    if current_admission_id is null then
      current_admission_id := allocation_row.admission_id;
    elsif current_admission_id <> allocation_row.admission_id then
      raise exception 'Combined payment allocations must use one admission.' using errcode = '23514';
    end if;
    if allocation_row.bill_status in ('Draft', 'Pending Approval', 'Cancelled', 'Archived') then
      raise exception 'Payment allocation references a non-payable bill.' using errcode = '23514';
    end if;
    if lower(coalesce(allocation_row.bill_type, '')) = 'security deposit' then
      deposit_bill_id := allocation_row.bill_id;
    else
      regular_bill_count := regular_bill_count + 1;
    end if;
    allocation_count := allocation_count + 1;

    select coalesce(sum(pa.amount), 0)::numeric(12,2)
      into verified_before
    from public.payment_allocations pa
    join public.payments p on p.id = pa.payment_id
    where pa.bill_id = allocation_row.bill_id
      and p.payment_status = 'Verified'
      and p.id <> p_payment_id;
    if allocation_row.amount > round(coalesce(allocation_row.total_amount, 0) - verified_before, 2) then
      raise exception 'Payment allocation exceeds the current bill balance.' using errcode = '23514';
    end if;

    v_paid_amount := round(verified_before + allocation_row.amount, 2);
    v_balance_amount := greatest(round(coalesce(allocation_row.total_amount, 0) - v_paid_amount, 2), 0);
    v_next_bill_status := case
      when v_balance_amount = 0 then 'Paid'
      when v_paid_amount > 0 then 'Partially Paid'
      when allocation_row.due_date < current_date then 'Overdue'
      else 'Pending'
    end;
    update public.bills
    set paid_amount = v_paid_amount,
      balance_amount = v_balance_amount,
      bill_status = v_next_bill_status,
        updated_at = now_at
    where id = allocation_row.bill_id;
  end loop;

  if current_admission_id is null or allocation_count <> 2 or deposit_bill_id is null or regular_bill_count <> 1 then
    raise exception 'Combined payment has no allocations.' using errcode = '23514';
  end if;
  if not exists (
    select 1 from public.admissions
    where id = current_admission_id
      and resident_id = payment_row.resident_id
      and status in ('Pending', 'Active')
  ) then
    raise exception 'Combined payment admission is no longer current.' using errcode = '23514';
  end if;

  update public.payments
  set payment_status = 'Verified', verified = true, verified_by = p_verifier,
      verified_at = now_at, updated_at = now_at
  where id = p_payment_id and payment_status = 'Pending';
  if not found then
    raise exception 'Payment changed before verification completed.' using errcode = '40001';
  end if;

  update public.payment_receipts
  set status = 'Verified', verified = true, verified_by = p_verifier,
      verified_at = now_at, updated_at = now_at
  where id = p_receipt_id and payment_id = p_payment_id
    and status = 'Pending Verification';
  if not found then
    raise exception 'Receipt changed before verification completed.' using errcode = '40001';
  end if;

  if deposit_bill_id is not null then
    update public.admissions
    set deposit_status = case
      when exists (
        select 1 from public.bills
        where id = deposit_bill_id and balance_amount = 0 and bill_status = 'Paid'
      ) then 'Held' else 'Pending' end,
      updated_at = now_at
    where id = current_admission_id and resident_id = payment_row.resident_id
      and status in ('Pending', 'Active');
  end if;

  return jsonb_build_object('payment_id', p_payment_id, 'receipt_id', p_receipt_id, 'admission_id', current_admission_id);
end;
$$;

create or replace function public.create_combined_payment_submission(
  p_resident_id uuid,
  p_admission_id uuid,
  p_rent_bill_id uuid,
  p_deposit_bill_id uuid,
  p_amount numeric,
  p_payment_method text,
  p_reference_number text,
  p_notes text,
  p_receipt_url text,
  p_original_file_name text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  admission_row public.admissions%rowtype;
  rent_bill public.bills%rowtype;
  deposit_bill public.bills%rowtype;
  rent_paid numeric(12,2);
  deposit_paid numeric(12,2);
  rent_balance numeric(12,2);
  deposit_balance numeric(12,2);
  payment_id uuid := gen_random_uuid();
  receipt_id uuid := gen_random_uuid();
  now_at timestamptz := now();
begin
  perform public.lock_financial_ledger();
  select * into admission_row from public.admissions
  where id = p_admission_id and resident_id = p_resident_id and status in ('Pending', 'Active')
  for update;
  if admission_row.id is null then raise exception 'Current admission could not be verified.' using errcode = '23514'; end if;

  select * into rent_bill from public.bills
  where id = p_rent_bill_id and admission_id = p_admission_id and resident_id = p_resident_id
    and bill_type <> 'Security Deposit' and bill_status not in ('Draft', 'Pending Approval', 'Cancelled', 'Archived')
  for update;
  select * into deposit_bill from public.bills
  where id = p_deposit_bill_id and admission_id = p_admission_id and resident_id = p_resident_id
    and bill_type = 'Security Deposit' and bill_status not in ('Draft', 'Pending Approval', 'Cancelled', 'Archived')
  for update;
  if rent_bill.id is null or deposit_bill.id is null then raise exception 'Both current payment obligations are required.' using errcode = '23514'; end if;

  select coalesce(sum(pa.amount), 0)::numeric(12,2) into rent_paid
  from public.payment_allocations pa join public.payments p on p.id = pa.payment_id
  where pa.bill_id = rent_bill.id and p.payment_status = 'Verified';
  select coalesce(sum(pa.amount), 0)::numeric(12,2) into deposit_paid
  from public.payment_allocations pa join public.payments p on p.id = pa.payment_id
  where pa.bill_id = deposit_bill.id and p.payment_status = 'Verified';
  rent_balance := greatest(round(rent_bill.total_amount - rent_paid, 2), 0);
  deposit_balance := greatest(round(deposit_bill.total_amount - deposit_paid, 2), 0);
  if rent_balance <= 0 or deposit_balance <= 0 or round(p_amount, 2) <> round(rent_balance + deposit_balance, 2) then
    raise exception 'Combined amount must equal the exact current Rent + Security Deposit balance.' using errcode = '23514';
  end if;

  insert into public.payments (id, payment_number, resident_id, bill_id, payment_date, amount, payment_method, reference_number, notes, payment_status, verified, created_at, updated_at)
  values (payment_id, 'PAY-' || extract(year from now_at)::text || '-' || upper(substr(replace(payment_id::text, '-', ''), 1, 8)), p_resident_id, null, now_at::date, round(p_amount, 2), p_payment_method, nullif(p_reference_number, ''), p_notes, 'Pending', false, now_at, now_at);
  insert into public.payment_allocations (payment_id, bill_id, amount) values
    (payment_id, rent_bill.id, rent_balance),
    (payment_id, deposit_bill.id, deposit_balance);
  insert into public.payment_receipts (id, resident_id, bill_id, payment_id, receipt_url, original_file_name, reference_number, amount, status, verified, notes, uploaded_at, created_at, updated_at)
  values (receipt_id, p_resident_id, null, payment_id, p_receipt_url, p_original_file_name, nullif(p_reference_number, ''), round(p_amount, 2), 'Pending Verification', false, p_notes, now_at, now_at, now_at);
  return jsonb_build_object('payment_id', payment_id, 'receipt_id', receipt_id);
end;
$$;

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
    select admission_id into deposit_admission_id from public.bills where id = allocation_row.bill_id and bill_type = 'Security Deposit';
  end loop;
  update public.payments set payment_status = 'Cancelled', verified = false, verified_by = p_actor, verified_at = null, notes = p_reason, updated_at = now() where id = p_payment_id and payment_status <> 'Cancelled';
  update public.payment_receipts set status = 'Rejected', verified = false, verified_by = p_actor, verified_at = null, remarks = p_reason, updated_at = now() where payment_id = p_payment_id and status = 'Pending Verification';
  if deposit_admission_id is not null then
    update public.admissions set deposit_status = case when exists (select 1 from public.bills where admission_id = deposit_admission_id and bill_type = 'Security Deposit' and bill_status = 'Paid') then 'Held' else 'Pending' end, updated_at = now() where id = deposit_admission_id and status in ('Pending', 'Active');
  end if;
  return jsonb_build_object('payment_id', p_payment_id);
end;
$$;

create or replace function public.reject_payment_with_allocations(
  p_payment_id uuid,
  p_receipt_id uuid,
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
  receipt_row public.payment_receipts%rowtype;
begin
  perform public.lock_financial_ledger();
  select * into payment_row from public.payments where id = p_payment_id for update;
  select * into receipt_row from public.payment_receipts where id = p_receipt_id and payment_id = p_payment_id for update;
  if payment_row.id is null or receipt_row.id is null or payment_row.payment_status <> 'Pending' or receipt_row.status <> 'Pending Verification' then
    raise exception 'Payment or receipt is no longer pending.' using errcode = '40001';
  end if;
  update public.payments
  set payment_status = 'Rejected', verified = false, verified_by = p_actor,
      verified_at = null, notes = p_reason, updated_at = now()
  where id = p_payment_id and payment_status = 'Pending';
  update public.payment_receipts
  set status = 'Rejected', verified = false, verified_by = p_actor,
      verified_at = null, remarks = p_reason, updated_at = now()
  where id = p_receipt_id and status = 'Pending Verification';
  return jsonb_build_object('payment_id', p_payment_id, 'receipt_id', p_receipt_id);
end;
$$;

revoke all on function public.verify_payment_with_allocations(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.reject_payment_with_allocations(uuid, uuid, text, text) from public, anon, authenticated;
revoke all on function public.create_combined_payment_submission(uuid, uuid, uuid, uuid, numeric, text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.cancel_payment_with_allocations(uuid, text, text) from public, anon, authenticated;
grant execute on function public.verify_payment_with_allocations(uuid, uuid, text) to service_role;
grant execute on function public.reject_payment_with_allocations(uuid, uuid, text, text) to service_role;
grant execute on function public.create_combined_payment_submission(uuid, uuid, uuid, uuid, numeric, text, text, text, text, text) to service_role;
grant execute on function public.cancel_payment_with_allocations(uuid, text, text) to service_role;

comment on table public.payment_allocations is
  'Canonical obligation allocations for a payment; legacy single-bill payments are backfilled here.';
comment on column public.payments.bill_id is
  'Legacy single-bill compatibility column. Combined payments leave this null and use payment_allocations.';
comment on table public.payment_status_history is
  'Immutable status transition history for payment verification, rejection, and cancellation.';

commit;

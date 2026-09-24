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


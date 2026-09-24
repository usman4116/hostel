-- Migration: Retire plaintext resident portal password persistence
-- Clear historical plaintext passwords and remove column from public.residents.
-- Sensitive resident portal credentials are managed exclusively through Supabase Auth.
begin;

do $$
begin
  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'residents'
      and column_name = 'portal_temp_password'
  ) then
    -- 1. Clear all historical stored plaintext passwords
    update public.residents
    set portal_temp_password = null
    where portal_temp_password is not null;

    -- 2. Drop the column to permanently prevent plaintext persistence
    alter table public.residents
    drop column portal_temp_password;
  end if;
end;
$$;

comment on table public.residents is
  'Residents master records. Sensitive portal credentials are managed exclusively through Supabase Auth and never stored in plaintext.';

commit;

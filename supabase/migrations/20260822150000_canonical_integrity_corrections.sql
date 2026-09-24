-- Local corrective migration; NOT executed. Apply only after the eight historical migrations.
begin;

create unique index residents_resident_code_key on public.residents (resident_code)
  where resident_code is not null and btrim(resident_code) <> '';

-- Existing notice-recipient policies depend on base tables with deliberately closed access.
-- Keep this table closed too until the complete authorization policy set is reviewed.
revoke all on table public.notice_recipients from anon, authenticated;
grant all on table public.notice_recipients to service_role;

create or replace function public.admin_delete_resident_data(
  p_admin_user_id uuid,
  p_admin_email text,
  p_resident_id uuid,
  p_resident_name_confirmation text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_admin_staff_id uuid;
  v_resident_name text;
  v_counts jsonb := '{}'::jsonb;
  v_count bigint;
  v_bed_ids uuid[];
  v_room_ids uuid[];
  v_admission_ids uuid[];
begin
  select id into v_admin_staff_id
  from public.staff_users
  where lower(email) = lower(trim(p_admin_email))
    and lower(coalesce(status, '')) = 'active'
    and lower(coalesce(role, '')) in ('admin', 'super admin')
  limit 1;

  if v_admin_staff_id is null then
    raise exception 'Administrator permission is required.' using errcode = '42501';
  end if;

  select full_name into v_resident_name
  from public.residents
  where id = p_resident_id
  for update;

  if v_resident_name is null then
    raise exception 'Resident not found.' using errcode = 'P0002';
  end if;

  if lower(trim(p_resident_name_confirmation)) is distinct from lower(trim(v_resident_name)) then
    raise exception 'Resident name confirmation does not match.' using errcode = '22023';
  end if;

  -- Inventory needs explicit return/disposal; deletion must not silently lose stock.
  if exists (select 1 from public.inventory_assignments where resident_id = p_resident_id) then
    raise exception 'Return or reassign resident inventory before deleting the resident.' using errcode = '23503';
  end if;

  select coalesce(array_agg(id), '{}'::uuid[]) into v_admission_ids
  from public.admissions where resident_id = p_resident_id;

  select array_remove(array_agg(distinct bed_id), null),
         array_remove(array_agg(distinct room_id), null)
    into v_bed_ids, v_room_ids
  from public.admissions
  where resident_id = p_resident_id;

  delete from public.notification_deliveries where resident_id = p_resident_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('notification_deliveries', v_count);

  delete from public.notice_recipients where resident_id = p_resident_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('notice_recipients', v_count);

  delete from public.notice_recipients
  where notice_id in (select id from public.notices where resident_id = p_resident_id);
  get diagnostics v_count = row_count;
  v_counts := jsonb_set(v_counts, '{notice_recipients}', to_jsonb(coalesce((v_counts ->> 'notice_recipients')::bigint, 0) + v_count));

  delete from public.notices where resident_id = p_resident_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('notices', v_count);

  delete from public.maintenance_photos
  where maintenance_request_id in (
    select id from public.maintenance_requests where resident_id = p_resident_id or admission_id = any(v_admission_ids)
  );
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('maintenance_photos', v_count);

  update public.payment_receipts
  set payment_id = null
  where resident_id = p_resident_id and payment_id is not null;

  delete from public.payment_receipts where resident_id = p_resident_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('payment_receipts', v_count);

  delete from public.payments where resident_id = p_resident_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('payments', v_count);

  delete from public.ac_bills where resident_id = p_resident_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('ac_bills', v_count);

  delete from public.bills where resident_id = p_resident_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('bills', v_count);

  delete from public.contracts where resident_id = p_resident_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('contracts', v_count);

  delete from public.room_inspections where resident_id = p_resident_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('room_inspections', v_count);

  delete from public.inspections where resident_id = p_resident_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('inspections', v_count);

  delete from public.maintenance_requests where resident_id = p_resident_id or admission_id = any(v_admission_ids);
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('maintenance_requests', v_count);

  delete from public.inventory_assignments where resident_id = p_resident_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('inventory_assignments', v_count);

  delete from public.complaints where resident_id = p_resident_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('complaints', v_count);

  delete from public.visitors where resident_id = p_resident_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('visitors', v_count);

  delete from public.resident_portal_links where resident_id = p_resident_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('resident_portal_links', v_count);

  delete from public.admissions where resident_id = p_resident_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('admissions', v_count);

  delete from public.residents where id = p_resident_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('residents', v_count);

  if coalesce(array_length(v_bed_ids, 1), 0) > 0 then
    update public.beds b
    set status = 'Vacant', updated_at = now()
    where b.id = any(v_bed_ids)
      and b.status <> 'Inactive'
      and not exists (
        select 1 from public.admissions a
        where a.bed_id = b.id
          and a.status in ('Pending', 'Active')
      );
  end if;

  if coalesce(array_length(v_room_ids, 1), 0) > 0 then
    update public.rooms r
    set occupied_beds = (
      select count(*)::integer from public.beds b
      where b.room_id = r.id and lower(coalesce(b.status, '')) = 'occupied'
    ), updated_at = now()
    where r.id = any(v_room_ids);
  end if;

  insert into public.admin_data_action_audits (
    admin_user_id, admin_staff_user_id, admin_email, action_type,
    deleted_resident_id, deleted_resident_name, deleted_record_counts, status
  ) values (
    p_admin_user_id, v_admin_staff_id, lower(trim(p_admin_email)), 'RESIDENT_DELETE',
    p_resident_id, v_resident_name, v_counts, 'SUCCESS'
  );

  return v_counts;
end;
$$;

revoke all on function public.admin_delete_resident_data(uuid, text, uuid, text) from public, anon, authenticated;
grant execute on function public.admin_delete_resident_data(uuid, text, uuid, text) to service_role;

-- Validate later-owned maintenance links without adding alternate relationship FKs.
create or replace function public.validate_maintenance_allocation()
returns trigger language plpgsql set search_path = pg_catalog, public as $$
begin
  if new.admission_id is not null and not exists (
    select 1 from public.admissions a where a.id = new.admission_id
      and a.room_id = new.room_id
      and (new.resident_id is null or a.resident_id = new.resident_id)
      and (new.bed_id is null or a.bed_id = new.bed_id)
  ) then raise exception 'Maintenance allocation does not match admission' using errcode = '23514'; end if;
  if new.bed_id is not null and not exists (
    select 1 from public.beds b where b.id = new.bed_id and b.room_id = new.room_id
  ) then raise exception 'Maintenance bed does not belong to room' using errcode = '23514'; end if;
  return new;
end;
$$;
revoke all on function public.validate_maintenance_allocation() from public, anon, authenticated;
create trigger maintenance_allocation_check before insert or update of admission_id, resident_id, room_id, bed_id
  on public.maintenance_requests for each row execute function public.validate_maintenance_allocation();

commit;

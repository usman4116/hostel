-- Local design artifact: NOT executed. Review security and migration chain before deployment.
-- Later-owned profile, inspection cost, maintenance links, popup and communication fields are intentionally absent.
-- No business seeds and no compatibility aliases.
begin;

create or replace function public.set_updated_at()
returns trigger language plpgsql set search_path = pg_catalog, public as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
revoke all on function public.set_updated_at() from public, anon, authenticated;

create table public.residents (
  id uuid primary key default gen_random_uuid(),
  full_name text not null check (length(btrim(full_name)) > 0),
  phone text,
  email text,
  cnic text,
  portal_temp_password text,
  status text not null default 'Inactive' check (status in ('Active', 'Inactive', 'Reserved', 'Notice Period', 'Checked Out', 'Archived')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger residents_updated_at before update on public.residents
  for each row execute function public.set_updated_at();
alter table public.residents enable row level security;
revoke all on table public.residents from anon, authenticated;
grant all on table public.residents to service_role;

create table public.rooms (
  id uuid primary key default gen_random_uuid(),
  room_number text not null unique check (length(btrim(room_number)) > 0),
  floor_number integer,
  block_name text,
  room_type text not null default 'Shared',
  total_beds integer not null default 1 check (total_beds >= 1),
  occupied_beds integer not null default 0 check (occupied_beds >= 0),
  monthly_rent numeric(12,2) not null default 0 check (monthly_rent >= 0),
  security_deposit_amount numeric(12,2) not null default 0 check (security_deposit_amount >= 0),
  description text,
  has_ac boolean not null default false,
  has_attached_bathroom boolean not null default false,
  has_balcony boolean not null default false,
  status text not null default 'Available' check (status in ('Available', 'Partially Occupied', 'Occupied', 'Maintenance', 'Inactive')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger rooms_updated_at before update on public.rooms
  for each row execute function public.set_updated_at();
alter table public.rooms enable row level security;
revoke all on table public.rooms from anon, authenticated;
grant all on table public.rooms to service_role;

create table public.beds (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete restrict,
  bed_number text not null check (length(btrim(bed_number)) > 0),
  status text not null default 'Vacant' check (status in ('Vacant', 'Occupied', 'Inactive')),
  mattress_condition text,
  mattress_cover text,
  unique (room_id, bed_number),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger beds_updated_at before update on public.beds
  for each row execute function public.set_updated_at();
alter table public.beds enable row level security;
revoke all on table public.beds from anon, authenticated;
grant all on table public.beds to service_role;
create index beds_room_id_idx on public.beds (room_id);

create table public.admissions (
  id uuid primary key default gen_random_uuid(),
  resident_id uuid not null references public.residents(id) on delete restrict,
  room_id uuid not null references public.rooms(id) on delete restrict,
  bed_id uuid not null references public.beds(id) on delete restrict,
  admission_number text unique,
  admission_date date not null,
  expected_leaving_date date,
  actual_leaving_date date,
  monthly_rent numeric(12,2) not null default 0 check (monthly_rent >= 0),
  security_deposit numeric(12,2) not null default 0 check (security_deposit >= 0),
  deposit_status text not null default 'Pending' check (deposit_status in ('Pending', 'Held', 'Released', 'Deducted')),
  notice_period_days integer not null default 30 check (notice_period_days >= 0),
  status text not null default 'Pending' check (status in ('Pending', 'Active', 'Completed', 'Cancelled', 'Archived')),
  notes text,
  check (expected_leaving_date is null or expected_leaving_date >= admission_date),
  check (actual_leaving_date is null or actual_leaving_date >= admission_date),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger admissions_updated_at before update on public.admissions
  for each row execute function public.set_updated_at();
alter table public.admissions enable row level security;
revoke all on table public.admissions from anon, authenticated;
grant all on table public.admissions to service_role;
create index admissions_resident_id_idx on public.admissions (resident_id);
create index admissions_room_id_idx on public.admissions (room_id);
create index admissions_bed_id_idx on public.admissions (bed_id);

create table public.contract_templates (
  id bigint generated by default as identity primary key,
  template_name text not null,
  title text not null,
  content text not null,
  is_active boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger contract_templates_updated_at before update on public.contract_templates
  for each row execute function public.set_updated_at();
alter table public.contract_templates enable row level security;
revoke all on table public.contract_templates from anon, authenticated;
grant all on table public.contract_templates to service_role;
revoke all on sequence public.contract_templates_id_seq from anon, authenticated;
grant usage, select on sequence public.contract_templates_id_seq to service_role;

create table public.contracts (
  id uuid primary key default gen_random_uuid(),
  contract_number text not null unique,
  resident_id uuid not null references public.residents(id) on delete restrict,
  admission_id uuid not null references public.admissions(id) on delete restrict,
  room_id uuid references public.rooms(id) on delete restrict,
  bed_id uuid references public.beds(id) on delete restrict,
  template_id bigint references public.contract_templates(id) on delete restrict,
  contract_content text not null,
  start_date date not null,
  end_date date,
  monthly_rent numeric(12,2) not null default 0 check (monthly_rent >= 0),
  security_deposit numeric(12,2) not null default 0 check (security_deposit >= 0),
  notice_period_days integer not null default 30 check (notice_period_days >= 0),
  status text not null default 'Draft' check (status in ('Draft', 'Pending Signature', 'Active', 'Expired', 'Cancelled', 'Terminated')),
  resident_signature_status text not null default 'Pending' check (resident_signature_status in ('Pending', 'Submitted', 'Approved', 'Rejected', 'Re-sign Required', 'Signed')),
  owner_signature_status text not null default 'Pending' check (owner_signature_status in ('Pending', 'Submitted', 'Approved', 'Rejected', 'Re-sign Required', 'Signed')),
  resident_signature_url text,
  resident_signature_name text,
  owner_signature_name text,
  signed_by_resident boolean not null default false,
  signed_at timestamptz,
  notes text,
  check (end_date is null or end_date >= start_date),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger contracts_updated_at before update on public.contracts
  for each row execute function public.set_updated_at();
alter table public.contracts enable row level security;
revoke all on table public.contracts from anon, authenticated;
grant all on table public.contracts to service_role;
create index contracts_resident_id_idx on public.contracts (resident_id);
create index contracts_admission_id_idx on public.contracts (admission_id);
create index contracts_room_id_idx on public.contracts (room_id);
create index contracts_bed_id_idx on public.contracts (bed_id);
create index contracts_template_id_idx on public.contracts (template_id);

create table public.bills (
  id uuid primary key default gen_random_uuid(),
  bill_number text not null unique,
  resident_id uuid not null references public.residents(id) on delete restrict,
  admission_id uuid not null references public.admissions(id) on delete restrict,
  bill_type text not null default 'Rent',
  billing_month text not null,
  rent_amount numeric(12,2) not null default 0 check (rent_amount >= 0),
  electricity_amount numeric(12,2) not null default 0 check (electricity_amount >= 0),
  ac_amount numeric(12,2) not null default 0 check (ac_amount >= 0),
  other_amount numeric(12,2) not null default 0 check (other_amount >= 0),
  discount_amount numeric(12,2) not null default 0 check (discount_amount >= 0),
  total_amount numeric(12,2) not null default 0 check (total_amount >= 0),
  paid_amount numeric(12,2) not null default 0 check (paid_amount >= 0),
  balance_amount numeric(12,2) not null default 0 check (balance_amount >= 0),
  due_date date not null,
  bill_status text not null default 'Pending' check (bill_status in ('Draft', 'Pending Approval', 'Pending', 'Partially Paid', 'Paid', 'Overdue', 'Cancelled')),
  notes text,
  check ((bill_type = 'Security Deposit' and billing_month = 'Security Deposit') or (bill_type <> 'Security Deposit' and billing_month ~ '^[0-9]{4}-(0[1-9]|1[0-2])$')),
  check (paid_amount <= total_amount and balance_amount <= total_amount),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger bills_updated_at before update on public.bills
  for each row execute function public.set_updated_at();
alter table public.bills enable row level security;
revoke all on table public.bills from anon, authenticated;
grant all on table public.bills to service_role;
create index bills_resident_id_idx on public.bills (resident_id);
create index bills_admission_id_idx on public.bills (admission_id);

create table public.ac_bills (
  id uuid primary key default gen_random_uuid(),
  resident_id uuid not null references public.residents(id) on delete restrict,
  admission_id uuid not null references public.admissions(id) on delete restrict,
  bill_id uuid references public.bills(id) on delete restrict,
  billing_month text not null check (billing_month ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),
  previous_reading numeric(12,2) not null default 0 check (previous_reading >= 0),
  current_reading numeric(12,2) not null default 0 check (current_reading >= 0),
  units_consumed numeric(12,2) not null default 0 check (units_consumed >= 0),
  rate_per_unit numeric(12,2) not null default 0 check (rate_per_unit >= 0),
  total_amount numeric(12,2) not null default 0 check (total_amount >= 0),
  remarks text,
  check (current_reading >= previous_reading),
  unique (admission_id, billing_month),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger ac_bills_updated_at before update on public.ac_bills
  for each row execute function public.set_updated_at();
alter table public.ac_bills enable row level security;
revoke all on table public.ac_bills from anon, authenticated;
grant all on table public.ac_bills to service_role;
create index ac_bills_resident_id_idx on public.ac_bills (resident_id);
create index ac_bills_admission_id_idx on public.ac_bills (admission_id);
create index ac_bills_bill_id_idx on public.ac_bills (bill_id);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  payment_number text not null unique,
  resident_id uuid not null references public.residents(id) on delete restrict,
  bill_id uuid not null references public.bills(id) on delete restrict,
  payment_date date not null default current_date,
  amount numeric(12,2) not null check (amount > 0),
  payment_method text not null,
  account_number text,
  reference_number text,
  notes text,
  payment_status text not null default 'Pending' check (payment_status in ('Pending', 'Verified', 'Rejected', 'Cancelled')),
  verified boolean not null default false,
  verified_by text,
  verified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger payments_updated_at before update on public.payments
  for each row execute function public.set_updated_at();
alter table public.payments enable row level security;
revoke all on table public.payments from anon, authenticated;
grant all on table public.payments to service_role;
create index payments_resident_id_idx on public.payments (resident_id);
create index payments_bill_id_idx on public.payments (bill_id);

create table public.payment_receipts (
  id uuid primary key default gen_random_uuid(),
  resident_id uuid not null references public.residents(id) on delete restrict,
  bill_id uuid references public.bills(id) on delete restrict,
  payment_id uuid references public.payments(id) on delete set null,
  receipt_url text not null,
  original_file_name text,
  reference_number text,
  amount numeric(12,2) not null check (amount > 0),
  status text not null default 'Pending Verification' check (status in ('Pending Verification', 'Verified', 'Rejected')),
  verified boolean not null default false,
  verified_by text,
  verified_at timestamptz,
  notes text,
  remarks text,
  uploaded_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger payment_receipts_updated_at before update on public.payment_receipts
  for each row execute function public.set_updated_at();
alter table public.payment_receipts enable row level security;
revoke all on table public.payment_receipts from anon, authenticated;
grant all on table public.payment_receipts to service_role;
create index payment_receipts_resident_id_idx on public.payment_receipts (resident_id);
create index payment_receipts_bill_id_idx on public.payment_receipts (bill_id);
create index payment_receipts_payment_id_idx on public.payment_receipts (payment_id);

create table public.room_inspections (
  id uuid primary key default gen_random_uuid(),
  inspection_number text not null unique,
  resident_id uuid not null references public.residents(id) on delete restrict,
  admission_id uuid not null references public.admissions(id) on delete restrict,
  room_id uuid not null references public.rooms(id) on delete restrict,
  bed_id uuid references public.beds(id) on delete restrict,
  inspection_date date not null default current_date,
  inspection_type text not null check (inspection_type in ('Check In', 'Check Out')),
  inspector_name text,
  cleanliness text,
  electrical_status text,
  plumbing_status text,
  furniture_condition text,
  wall_floor_status text,
  overall_status text,
  notes text,
  damage_description text,
  damage_found boolean not null default false,
  estimated_damage_cost numeric(12,2) not null default 0 check (estimated_damage_cost >= 0),
  status text not null default 'Completed' check (status in ('Completed', 'Archived')),
  before_photos text[] not null default '{}'::text[],
  after_photos text[] not null default '{}'::text[],
  photos text[] not null default '{}'::text[],
  check (not damage_found or length(btrim(coalesce(damage_description, ''))) > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger room_inspections_updated_at before update on public.room_inspections
  for each row execute function public.set_updated_at();
alter table public.room_inspections enable row level security;
revoke all on table public.room_inspections from anon, authenticated;
grant all on table public.room_inspections to service_role;
create index room_inspections_resident_id_idx on public.room_inspections (resident_id);
create index room_inspections_admission_id_idx on public.room_inspections (admission_id);
create index room_inspections_room_id_idx on public.room_inspections (room_id);
create index room_inspections_bed_id_idx on public.room_inspections (bed_id);

create table public.maintenance_requests (
  id uuid primary key default gen_random_uuid(),
  request_number text not null unique,
  resident_id uuid references public.residents(id) on delete restrict,
  room_id uuid not null references public.rooms(id) on delete restrict,
  title text not null,
  description text,
  category text,
  priority text not null default 'Medium' check (priority in ('Low', 'Medium', 'High', 'Emergency')),
  status text not null default 'Open' check (status in ('Open', 'Pending', 'In Progress', 'Completed', 'Cancelled', 'Archived')),
  assigned_to text,
  estimated_cost numeric(12,2) not null default 0 check (estimated_cost >= 0),
  actual_cost numeric(12,2) not null default 0 check (actual_cost >= 0),
  complaint_date date not null default current_date,
  assigned_date date,
  completion_date date,
  completed_at timestamptz,
  photo_url text,
  notes text,
  before_photos text[] not null default '{}'::text[],
  during_photos text[] not null default '{}'::text[],
  after_photos text[] not null default '{}'::text[],
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger maintenance_requests_updated_at before update on public.maintenance_requests
  for each row execute function public.set_updated_at();
alter table public.maintenance_requests enable row level security;
revoke all on table public.maintenance_requests from anon, authenticated;
grant all on table public.maintenance_requests to service_role;
create index maintenance_requests_resident_id_idx on public.maintenance_requests (resident_id);
create index maintenance_requests_room_id_idx on public.maintenance_requests (room_id);

create table public.maintenance_photos (
  id uuid primary key default gen_random_uuid(),
  maintenance_request_id uuid not null references public.maintenance_requests(id) on delete cascade,
  photo_type text not null check (photo_type in ('before','during','after')),
  photo_url text not null,
  created_at timestamptz not null default now()
);
alter table public.maintenance_photos enable row level security;
revoke all on table public.maintenance_photos from anon, authenticated;
grant all on table public.maintenance_photos to service_role;
create index maintenance_photos_maintenance_request_id_idx on public.maintenance_photos (maintenance_request_id);

create table public.staff_users (
  id uuid primary key default gen_random_uuid(),
  email text not null unique,
  full_name text not null,
  phone text,
  notes text,
  role text not null default 'Staff',
  status text not null default 'Active' check (status in ('Active', 'Inactive')),
  permissions text[] not null default '{}'::text[],
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger staff_users_updated_at before update on public.staff_users
  for each row execute function public.set_updated_at();
alter table public.staff_users enable row level security;
revoke all on table public.staff_users from anon, authenticated;
grant all on table public.staff_users to service_role;

create table public.staff (
  id bigint generated by default as identity primary key,
  full_name text not null,
  designation text not null,
  joining_date date not null,
  department text,
  phone text,
  email text,
  cnic text,
  address text,
  notes text,
  salary numeric(12,2) check (salary >= 0),
  advance_amount numeric(12,2) not null default 0 check (advance_amount >= 0),
  status text not null default 'Active' check (status in ('Active', 'Inactive')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger staff_updated_at before update on public.staff
  for each row execute function public.set_updated_at();
alter table public.staff enable row level security;
revoke all on table public.staff from anon, authenticated;
grant all on table public.staff to service_role;
revoke all on sequence public.staff_id_seq from anon, authenticated;
grant usage, select on sequence public.staff_id_seq to service_role;

create table public.notices (
  id bigint generated by default as identity primary key,
  notice_number text unique,
  title text not null,
  description text not null,
  notice_type text not null default 'General',
  audience text not null default 'All Residents' check (audience in ('All Residents', 'Selected Residents', 'Specific Room', 'Specific Resident', 'Staff')),
  resident_id uuid references public.residents(id) on delete restrict,
  room_id uuid references public.rooms(id) on delete restrict,
  staff_id bigint references public.staff(id) on delete restrict,
  attachment_url text,
  priority text not null default 'Normal' check (priority in ('Low', 'Normal', 'Medium', 'High', 'Urgent')),
  status text not null default 'Draft' check (status in ('Draft', 'Published', 'Cancelled', 'Archived')),
  publish_date date,
  expiry_date date,
  pinned boolean not null default false,
  check (status <> 'Published' or publish_date is not null),
  check (expiry_date is null or publish_date is null or expiry_date >= publish_date),
  check ((audience = 'Specific Resident' and resident_id is not null and room_id is null and staff_id is null) or (audience = 'Specific Room' and room_id is not null and resident_id is null and staff_id is null) or (audience = 'Staff' and staff_id is not null and resident_id is null and room_id is null) or (audience in ('All Residents','Selected Residents') and resident_id is null and room_id is null and staff_id is null)),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger notices_updated_at before update on public.notices
  for each row execute function public.set_updated_at();
alter table public.notices enable row level security;
revoke all on table public.notices from anon, authenticated;
grant all on table public.notices to service_role;
revoke all on sequence public.notices_id_seq from anon, authenticated;
grant usage, select on sequence public.notices_id_seq to service_role;
create index notices_resident_id_idx on public.notices (resident_id);
create index notices_room_id_idx on public.notices (room_id);
create index notices_staff_id_idx on public.notices (staff_id);

create table public.inventory_categories (
  id bigint generated by default as identity primary key,
  name text not null unique,
  status text not null default 'Active' check (status in ('Active', 'Inactive')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger inventory_categories_updated_at before update on public.inventory_categories
  for each row execute function public.set_updated_at();
alter table public.inventory_categories enable row level security;
revoke all on table public.inventory_categories from anon, authenticated;
grant all on table public.inventory_categories to service_role;
revoke all on sequence public.inventory_categories_id_seq from anon, authenticated;
grant usage, select on sequence public.inventory_categories_id_seq to service_role;

create table public.inventory (
  id bigint generated by default as identity primary key,
  asset_code text not null unique,
  item_name text not null,
  category_id bigint not null references public.inventory_categories(id) on delete restrict,
  quantity integer not null default 0 check (quantity >= 0),
  available_quantity integer not null default 0 check (available_quantity >= 0),
  assigned_quantity integer not null default 0 check (assigned_quantity >= 0),
  unit text not null default 'Piece',
  purchase_date date,
  warranty_expiry date,
  purchase_price numeric(12,2) check (purchase_price >= 0),
  supplier text,
  brand text,
  model text,
  notes text,
  item_condition text not null default 'Good' check (item_condition in ('Excellent', 'Good', 'Fair', 'Damaged')),
  status text not null default 'Active' check (status in ('Active', 'Inactive')),
  check (quantity = available_quantity + assigned_quantity),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger inventory_updated_at before update on public.inventory
  for each row execute function public.set_updated_at();
alter table public.inventory enable row level security;
revoke all on table public.inventory from anon, authenticated;
grant all on table public.inventory to service_role;
revoke all on sequence public.inventory_id_seq from anon, authenticated;
grant usage, select on sequence public.inventory_id_seq to service_role;
create index inventory_category_id_idx on public.inventory (category_id);

create table public.inventory_assignments (
  id bigint generated by default as identity primary key,
  inventory_id bigint not null references public.inventory(id) on delete restrict,
  room_id uuid references public.rooms(id) on delete restrict,
  bed_id uuid references public.beds(id) on delete restrict,
  resident_id uuid references public.residents(id) on delete restrict,
  staff_id bigint references public.staff(id) on delete restrict,
  quantity integer not null check (quantity > 0),
  assigned_date date not null default current_date,
  remarks text,
  check (num_nonnulls(room_id, bed_id, resident_id, staff_id) = 1),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger inventory_assignments_updated_at before update on public.inventory_assignments
  for each row execute function public.set_updated_at();
alter table public.inventory_assignments enable row level security;
revoke all on table public.inventory_assignments from anon, authenticated;
grant all on table public.inventory_assignments to service_role;
revoke all on sequence public.inventory_assignments_id_seq from anon, authenticated;
grant usage, select on sequence public.inventory_assignments_id_seq to service_role;
create index inventory_assignments_inventory_id_idx on public.inventory_assignments (inventory_id);
create index inventory_assignments_room_id_idx on public.inventory_assignments (room_id);
create index inventory_assignments_bed_id_idx on public.inventory_assignments (bed_id);
create index inventory_assignments_resident_id_idx on public.inventory_assignments (resident_id);
create index inventory_assignments_staff_id_idx on public.inventory_assignments (staff_id);

create table public.inventory_movements (
  id bigint generated by default as identity primary key,
  inventory_id bigint not null references public.inventory(id) on delete restrict,
  movement_type text not null check (movement_type in ('IN','OUT')),
  quantity integer not null check (quantity >= 0),
  movement_date date not null default current_date,
  reference_no text,
  remarks text,
  check (movement_type <> 'OUT' or quantity > 0),
  created_at timestamptz not null default now()
);
alter table public.inventory_movements enable row level security;
revoke all on table public.inventory_movements from anon, authenticated;
grant all on table public.inventory_movements to service_role;
revoke all on sequence public.inventory_movements_id_seq from anon, authenticated;
grant usage, select on sequence public.inventory_movements_id_seq to service_role;
create index inventory_movements_inventory_id_idx on public.inventory_movements (inventory_id);

create table public.complaints (
  id bigint generated by default as identity primary key,
  resident_id uuid not null references public.residents(id) on delete restrict,
  subject text not null,
  category text,
  description text not null,
  priority text not null default 'Medium' check (priority in ('Low', 'Medium', 'High', 'Urgent')),
  status text not null default 'Open' check (status in ('Open', 'In Progress', 'Resolved')),
  assigned_staff text,
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger complaints_updated_at before update on public.complaints
  for each row execute function public.set_updated_at();
alter table public.complaints enable row level security;
revoke all on table public.complaints from anon, authenticated;
grant all on table public.complaints to service_role;
revoke all on sequence public.complaints_id_seq from anon, authenticated;
grant usage, select on sequence public.complaints_id_seq to service_role;
create index complaints_resident_id_idx on public.complaints (resident_id);

create table public.visitors (
  id bigint generated by default as identity primary key,
  resident_id uuid not null references public.residents(id) on delete restrict,
  visitor_name text not null,
  cnic text,
  mobile_number text,
  relation text,
  purpose text,
  notes text,
  entry_time timestamptz not null default now(),
  exit_time timestamptz,
  status text not null default 'Checked In' check (status in ('Checked In', 'Checked Out')),
  check (exit_time is null or exit_time >= entry_time),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger visitors_updated_at before update on public.visitors
  for each row execute function public.set_updated_at();
alter table public.visitors enable row level security;
revoke all on table public.visitors from anon, authenticated;
grant all on table public.visitors to service_role;
revoke all on sequence public.visitors_id_seq from anon, authenticated;
grant usage, select on sequence public.visitors_id_seq to service_role;
create index visitors_resident_id_idx on public.visitors (resident_id);

create table public.system_settings (
  setting_key text primary key,
  hostel_name text,
  hostel_tagline text,
  hostel_address text,
  contact_number text,
  email text,
  manager_name text,
  security_deposit_policy text,
  logo_url text,
  notes text,
  default_currency text not null default 'PKR',
  default_payment_method text not null default 'Payment Method',
  security_deposit_rule_days integer not null default 30 check (security_deposit_rule_days >= 0),
  invoice_prefix text not null default 'INV',
  receipt_prefix text not null default 'RCP',
  allow_online_payments boolean not null default true,
  allow_receipt_uploads boolean not null default true,
  enable_email_notifications boolean not null default false,
  enable_sms_notifications boolean not null default false,
  enable_whatsapp_notifications boolean not null default false,
  auto_backup_enabled boolean not null default false,
  backup_frequency text not null default 'Weekly',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger system_settings_updated_at before update on public.system_settings
  for each row execute function public.set_updated_at();
alter table public.system_settings enable row level security;
revoke all on table public.system_settings from anon, authenticated;
grant all on table public.system_settings to service_role;

create table public.inspections (
  id uuid primary key default gen_random_uuid(),
  resident_id uuid references public.residents(id) on delete restrict,
  room_id uuid references public.rooms(id) on delete restrict,
  inspection_date date not null,
  before_photo text,
  after_photo text,
  damage_notes text,
  created_at timestamptz not null default now()
);
alter table public.inspections enable row level security;
revoke all on table public.inspections from anon, authenticated;
grant all on table public.inspections to service_role;
create index inspections_resident_id_idx on public.inspections (resident_id);
create index inspections_room_id_idx on public.inspections (room_id);

create table public.resident_portal_links (
  id uuid primary key default gen_random_uuid(),
  resident_id uuid not null references public.residents(id) on delete restrict,
  created_at timestamptz not null default now()
);
alter table public.resident_portal_links enable row level security;
revoke all on table public.resident_portal_links from anon, authenticated;
grant all on table public.resident_portal_links to service_role;
create index resident_portal_links_resident_id_idx on public.resident_portal_links (resident_id);

create unique index residents_email_key on public.residents (lower(btrim(email))) where email is not null and btrim(email) <> '';
create unique index residents_cnic_key on public.residents (regexp_replace(cnic, '[^0-9A-Za-z]', '', 'g')) where cnic is not null and btrim(cnic) <> '';
create unique index staff_users_email_normalized_key on public.staff_users (lower(btrim(email)));
create unique index admissions_current_resident_key on public.admissions (resident_id) where status in ('Pending', 'Active');
create unique index admissions_current_bed_key on public.admissions (bed_id) where status in ('Pending', 'Active');
create unique index bills_regular_admission_month_key on public.bills (admission_id, billing_month) where bill_status <> 'Cancelled' and bill_type <> 'Security Deposit';
create unique index bills_deposit_admission_key on public.bills (admission_id) where bill_status <> 'Cancelled' and bill_type = 'Security Deposit';
create unique index payment_receipts_payment_key on public.payment_receipts (payment_id) where payment_id is not null;
create index residents_full_name_idx on public.residents (full_name);
create index admissions_status_created_idx on public.admissions (status, created_at desc);
create index contracts_admission_created_idx on public.contracts (admission_id, created_at desc);
create index bills_status_due_idx on public.bills (bill_status, due_date);
create index bills_month_idx on public.bills (billing_month);
create index payments_bill_verified_idx on public.payments (bill_id, payment_date desc) where payment_status = 'Verified';
create index payment_receipts_status_uploaded_idx on public.payment_receipts (status, uploaded_at desc);
create index notices_publication_idx on public.notices (status, publish_date desc);
create index maintenance_status_date_idx on public.maintenance_requests (status, complaint_date desc);
comment on table public.resident_portal_links is 'Legacy dependency: no one-row-per-resident assumption and no invented credentials.';
comment on column public.residents.portal_temp_password is 'Existing legacy writer only. Remove plaintext credential persistence before production; not a recommended credential store.';
commit;

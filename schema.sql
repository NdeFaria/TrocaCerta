-- =========================================================
-- TROCA CERTA — schema completo para o Supabase
-- Cole isso inteiro no SQL Editor do seu projeto Supabase
-- (Project > SQL Editor > New query > Run)
-- =========================================================

-- extensão pra gerar uuid
create extension if not exists "pgcrypto";

-- ---------------------------------------------------------
-- TABELAS
-- ---------------------------------------------------------

-- dados públicos do carro (o que qualquer pessoa que escaneia o QR pode ver)
create table if not exists public.cars (
  id uuid primary key default gen_random_uuid(),
  qr_token text unique not null,
  nickname text not null,
  interval_km int not null default 7500,
  current_km int not null default 0,
  last_change_km int,
  last_change_date date,
  owner_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

-- dados sensíveis (placa e renavam) — NUNCA exposto publicamente
create table if not exists public.car_documents (
  car_id uuid primary key references public.cars(id) on delete cascade,
  plate text,
  renavam text not null,
  updated_at timestamptz not null default now()
);

-- histórico de trocas de óleo
create table if not exists public.oil_changes (
  id uuid primary key default gen_random_uuid(),
  car_id uuid not null references public.cars(id) on delete cascade,
  km_at_change int not null,
  change_date date not null default current_date,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

-- atualizações de KM entre trocas (alimenta a estimativa de data)
create table if not exists public.km_updates (
  id uuid primary key default gen_random_uuid(),
  car_id uuid not null references public.cars(id) on delete cascade,
  km int not null,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

-- transferências de posse (código de uma vez, expira em 24h)
create table if not exists public.ownership_transfers (
  id uuid primary key default gen_random_uuid(),
  car_id uuid not null references public.cars(id) on delete cascade,
  from_user uuid not null references auth.users(id),
  to_user uuid references auth.users(id),
  transfer_code text not null unique,
  status text not null default 'pending' check (status in ('pending','completed','expired','cancelled')),
  expires_at timestamptz not null default (now() + interval '24 hours'),
  completed_at timestamptz,
  created_at timestamptz not null default now()
);

-- inscrições de push notification (Web Push)
create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  endpoint text not null,
  p256dh text not null,
  auth text not null,
  created_at timestamptz not null default now(),
  unique(user_id, endpoint)
);

-- controle de notificações já enviadas (evita spam)
create table if not exists public.notification_log (
  id uuid primary key default gen_random_uuid(),
  car_id uuid not null references public.cars(id) on delete cascade,
  sent_at timestamptz not null default now(),
  kind text not null -- 'proxima' | 'atrasada'
);

-- ---------------------------------------------------------
-- ROW LEVEL SECURITY
-- ---------------------------------------------------------

alter table public.cars enable row level security;
alter table public.car_documents enable row level security;
alter table public.oil_changes enable row level security;
alter table public.km_updates enable row level security;
alter table public.ownership_transfers enable row level security;
alter table public.push_subscriptions enable row level security;
alter table public.notification_log enable row level security;

-- cars: só o dono acessa a tabela diretamente
-- (o acesso público ao escanear o QR passa SEMPRE pela função get_public_car,
-- nunca por select direto na tabela — por isso não existe policy "anon select" aqui)
create policy "cars_select_owner" on public.cars for select
  using (owner_id = auth.uid());
create policy "cars_update_owner" on public.cars for update
  using (owner_id = auth.uid());
create policy "cars_insert_owner" on public.cars for insert
  with check (owner_id = auth.uid());

-- car_documents: só o dono, nunca público
create policy "docs_select_owner" on public.car_documents for select
  using (exists (select 1 from public.cars c where c.id = car_id and c.owner_id = auth.uid()));
create policy "docs_insert_owner" on public.car_documents for insert
  with check (exists (select 1 from public.cars c where c.id = car_id and c.owner_id = auth.uid()));
create policy "docs_update_owner" on public.car_documents for update
  using (exists (select 1 from public.cars c where c.id = car_id and c.owner_id = auth.uid()));

-- oil_changes / km_updates: só o dono do carro
create policy "oc_select_owner" on public.oil_changes for select
  using (exists (select 1 from public.cars c where c.id = car_id and c.owner_id = auth.uid()));
create policy "oc_insert_owner" on public.oil_changes for insert
  with check (exists (select 1 from public.cars c where c.id = car_id and c.owner_id = auth.uid()));

create policy "ku_select_owner" on public.km_updates for select
  using (exists (select 1 from public.cars c where c.id = car_id and c.owner_id = auth.uid()));
create policy "ku_insert_owner" on public.km_updates for insert
  with check (exists (select 1 from public.cars c where c.id = car_id and c.owner_id = auth.uid()));

-- ownership_transfers: dono atual ou quem está resgatando
create policy "ot_select_involved" on public.ownership_transfers for select
  using (from_user = auth.uid() or to_user = auth.uid());
create policy "ot_insert_owner" on public.ownership_transfers for insert
  with check (from_user = auth.uid());

-- push_subscriptions: cada usuário só mexe na própria inscrição
create policy "push_all_own" on public.push_subscriptions for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- notification_log: leitura só pro dono do carro (não é crítico, mas por consistência)
create policy "notif_select_owner" on public.notification_log for select
  using (exists (select 1 from public.cars c where c.id = car_id and c.owner_id = auth.uid()));

-- ---------------------------------------------------------
-- FUNÇÕES (RPC)
-- ---------------------------------------------------------

-- gera um token curto tipo TC-XXXXX-XXXX
create or replace function public.gen_qr_token()
returns text language sql as $$
  select 'TC-' || upper(substr(md5(random()::text), 1, 5)) || '-' || upper(substr(md5(random()::text), 1, 4));
$$;

-- gera um código de transferência de 6 dígitos
create or replace function public.gen_transfer_code()
returns text language sql as $$
  select lpad(floor(random()*1000000)::text, 6, '0');
$$;

-- criar carro (exige placa/renavam pra provar que o usuário tem o documento em mãos)
create or replace function public.create_car(
  p_nickname text,
  p_plate text,
  p_renavam text,
  p_interval_km int,
  p_current_km int
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_car_id uuid;
  v_token text;
begin
  if p_renavam is null or length(trim(p_renavam)) < 9 then
    raise exception 'RENAVAM inválido';
  end if;
  if p_current_km is null or p_current_km < 0 then
    raise exception 'KM inválido';
  end if;

  loop
    v_token := public.gen_qr_token();
    exit when not exists (select 1 from public.cars where qr_token = v_token);
  end loop;

  insert into public.cars (qr_token, nickname, interval_km, current_km, owner_id)
  values (v_token, p_nickname, coalesce(p_interval_km,7500), p_current_km, auth.uid())
  returning id into v_car_id;

  insert into public.car_documents (car_id, plate, renavam)
  values (v_car_id, upper(trim(p_plate)), trim(p_renavam));

  return v_car_id;
end;
$$;

-- registrar troca de óleo
create or replace function public.register_oil_change(
  p_car_id uuid,
  p_km int,
  p_date date
) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.cars where id = p_car_id and owner_id = auth.uid()) then
    raise exception 'Sem permissão para este carro';
  end if;
  if p_km is null or p_km < (select coalesce(current_km,0) from public.cars where id = p_car_id) then
    raise exception 'KM precisa ser maior ou igual ao KM atual registrado';
  end if;

  insert into public.oil_changes (car_id, km_at_change, change_date, created_by)
  values (p_car_id, p_km, coalesce(p_date, current_date), auth.uid());

  update public.cars
    set current_km = p_km, last_change_km = p_km, last_change_date = coalesce(p_date, current_date)
    where id = p_car_id;
end;
$$;

-- atualizar km (sem trocar óleo)
create or replace function public.update_km(
  p_car_id uuid,
  p_km int
) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.cars where id = p_car_id and owner_id = auth.uid()) then
    raise exception 'Sem permissão para este carro';
  end if;
  if p_km is null or p_km < (select coalesce(current_km,0) from public.cars where id = p_car_id) then
    raise exception 'KM precisa ser maior ou igual ao KM atual registrado';
  end if;

  insert into public.km_updates (car_id, km, created_by) values (p_car_id, p_km, auth.uid());
  update public.cars set current_km = p_km where id = p_car_id;
end;
$$;

-- iniciar transferência de posse (dono atual gera o código)
create or replace function public.request_transfer(p_car_id uuid)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_code text;
begin
  if not exists (select 1 from public.cars where id = p_car_id and owner_id = auth.uid()) then
    raise exception 'Sem permissão para este carro';
  end if;

  update public.ownership_transfers set status = 'expired'
    where car_id = p_car_id and status = 'pending';

  loop
    v_code := public.gen_transfer_code();
    exit when not exists (select 1 from public.ownership_transfers where transfer_code = v_code and status = 'pending');
  end loop;

  insert into public.ownership_transfers (car_id, from_user, transfer_code)
  values (p_car_id, auth.uid(), v_code);

  return v_code;
end;
$$;

-- concluir transferência (novo dono confirma código + placa/renavam)
create or replace function public.claim_transfer(
  p_code text,
  p_plate text,
  p_renavam text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_transfer record;
  v_docs record;
begin
  select * into v_transfer from public.ownership_transfers
    where transfer_code = p_code and status = 'pending' and expires_at > now();

  if v_transfer is null then
    raise exception 'Código inválido ou expirado';
  end if;

  select * into v_docs from public.car_documents where car_id = v_transfer.car_id;

  if v_docs is null or lower(trim(v_docs.renavam)) <> lower(trim(p_renavam)) then
    raise exception 'RENAVAM não confere com este veículo';
  end if;

  update public.cars set owner_id = auth.uid() where id = v_transfer.car_id;
  update public.car_documents set plate = coalesce(upper(trim(p_plate)), plate) where car_id = v_transfer.car_id;

  update public.ownership_transfers
    set status = 'completed', to_user = auth.uid(), completed_at = now()
    where id = v_transfer.id;

  return v_transfer.car_id;
end;
$$;

-- leitura pública via QR (SEM placa, SEM renavam, SEM identidade do dono)
create or replace function public.get_public_car(p_token text)
returns table (
  nickname text,
  interval_km int,
  current_km int,
  last_change_km int,
  last_change_date date,
  next_change_km int,
  status text,
  history jsonb
)
language plpgsql security definer set search_path = public as $$
declare
  v_car record;
begin
  select * into v_car from public.cars where qr_token = p_token;
  if v_car is null then
    raise exception 'QR Code não encontrado';
  end if;

  return query
  select
    v_car.nickname,
    v_car.interval_km,
    v_car.current_km,
    v_car.last_change_km,
    v_car.last_change_date,
    coalesce(v_car.last_change_km, 0) + v_car.interval_km as next_change_km,
    case
      when v_car.current_km >= coalesce(v_car.last_change_km,0) + v_car.interval_km then 'atrasada'
      when v_car.current_km >= coalesce(v_car.last_change_km,0) + v_car.interval_km - 500 then 'proxima'
      else 'ok'
    end as status,
    (
      select coalesce(jsonb_agg(jsonb_build_object('tipo', tipo, 'data', data, 'km', km) order by data desc), '[]'::jsonb)
      from (
        select 'troca' as tipo, change_date::text as data, km_at_change as km from public.oil_changes where car_id = v_car.id
        union all
        select 'atualizacao' as tipo, created_at::date::text as data, km from public.km_updates where car_id = v_car.id
      ) h
    ) as history;
end;
$$;

grant execute on function public.get_public_car(text) to anon, authenticated;
grant execute on function public.create_car(text,text,text,int,int) to authenticated;
grant execute on function public.register_oil_change(uuid,int,date) to authenticated;
grant execute on function public.update_km(uuid,int) to authenticated;
grant execute on function public.request_transfer(uuid) to authenticated;
grant execute on function public.claim_transfer(text,text,text) to authenticated;

-- ---------------------------------------------------------
-- VIEW auxiliar pro app do dono (junta carro + documentos + próxima troca)
-- ---------------------------------------------------------
create or replace view public.my_cars as
select
  c.id, c.qr_token, c.nickname, c.interval_km, c.current_km,
  c.last_change_km, c.last_change_date, c.owner_id, c.created_at,
  d.plate, d.renavam,
  coalesce(c.last_change_km,0) + c.interval_km as next_change_km,
  case
    when c.current_km >= coalesce(c.last_change_km,0) + c.interval_km then 'atrasada'
    when c.current_km >= coalesce(c.last_change_km,0) + c.interval_km - 500 then 'proxima'
    else 'ok'
  end as status
from public.cars c
left join public.car_documents d on d.car_id = c.id;

-- a view herda RLS das tabelas base automaticamente (security_invoker por padrão em views simples
-- no Postgres do Supabase >= 15); se seu projeto for mais antigo, rode a linha abaixo também:
alter view public.my_cars set (security_invoker = true);

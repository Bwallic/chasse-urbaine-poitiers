-- Ping 0 de contrôle + notifications Web Push.
-- Les clés VAPID sont générées côté Edge Function lors de la première activation.

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;

create table if not exists public.app_private_config (
  key text primary key,
  value text not null,
  updated_at timestamptz not null default now()
);
alter table public.app_private_config enable row level security;
revoke all on table public.app_private_config from public, anon, authenticated;

insert into public.app_private_config(key, value, updated_at)
select 'push_dispatch_token', encode(gen_random_bytes(32), 'hex'), now()
where not exists (select 1 from public.app_private_config where key = 'push_dispatch_token');

create table if not exists public.push_subscriptions (
  participant_id uuid primary key references public.participants(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  user_agent text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.push_subscriptions enable row level security;
revoke all on table public.push_subscriptions from public, anon, authenticated;

create table if not exists public.push_jobs (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  slot_id uuid not null references public.ping_slots(id) on delete cascade,
  scheduled_at timestamptz not null,
  status text not null default 'pending',
  attempt_count integer not null default 0,
  locked_at timestamptz,
  sent_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  unique(event_id, slot_id)
);
alter table public.push_jobs enable row level security;
revoke all on table public.push_jobs from public, anon, authenticated;
create index if not exists push_jobs_due_idx on public.push_jobs(status, scheduled_at);

create table if not exists public.push_deliveries (
  job_id uuid not null references public.push_jobs(id) on delete cascade,
  participant_id uuid not null references public.participants(id) on delete cascade,
  status text not null,
  sent_at timestamptz,
  clicked_at timestamptz,
  error text,
  updated_at timestamptz not null default now(),
  primary key(job_id, participant_id)
);
alter table public.push_deliveries enable row level security;
revoke all on table public.push_deliveries from public, anon, authenticated;

insert into public.ping_slots(event_id, label, scheduled_at, ordinal)
select e.id, 'Ping 0', coalesce(e.actual_started_at, e.starts_at), 0
from public.events e
where not exists (
  select 1 from public.ping_slots s where s.event_id = e.id and s.ordinal = 0
);

update public.ping_slots
set label = case ordinal
  when 0 then 'Ping 0'
  when 1 then 'Ping 1'
  when 2 then 'Ping 2'
  when 3 then 'Ping 3'
  else label
end
where ordinal between 0 and 3;

create or replace function public.save_push_subscription(
  p_endpoint text,
  p_p256dh text,
  p_auth text,
  p_user_agent text default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_participant public.participants%rowtype;
begin
  if auth.uid() is null then raise exception 'Authentification requise'; end if;
  select p.* into v_participant from public.participants p
   where p.user_id = auth.uid() and p.active = true limit 1;
  if v_participant.id is null or v_participant.role not in ('target','hunter') then
    raise exception 'Accès réservé aux joueurs';
  end if;
  if nullif(trim(p_endpoint), '') is null or nullif(trim(p_p256dh), '') is null or nullif(trim(p_auth), '') is null then
    raise exception 'Abonnement push incomplet';
  end if;
  delete from public.push_subscriptions where endpoint = p_endpoint and participant_id <> v_participant.id;
  insert into public.push_subscriptions(participant_id, endpoint, p256dh, auth, user_agent, updated_at)
  values(v_participant.id, p_endpoint, p_p256dh, p_auth, p_user_agent, now())
  on conflict (participant_id) do update
    set endpoint = excluded.endpoint,
        p256dh = excluded.p256dh,
        auth = excluded.auth,
        user_agent = excluded.user_agent,
        updated_at = now();
  return true;
end;
$$;

create or replace function public.remove_my_push_subscription()
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare v_participant_id uuid;
begin
  select p.id into v_participant_id from public.participants p
   where p.user_id = auth.uid() and p.active = true limit 1;
  if v_participant_id is null then return false; end if;
  delete from public.push_subscriptions where participant_id = v_participant_id;
  return true;
end;
$$;

create or replace function public.my_push_subscription_status()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.push_subscriptions s
    join public.participants p on p.id = s.participant_id
    where p.user_id = auth.uid() and p.active = true
  );
$$;

create or replace function public.ack_push_notification(p_job_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare v_participant_id uuid;
begin
  select p.id into v_participant_id from public.participants p
   where p.user_id = auth.uid() and p.active = true limit 1;
  if v_participant_id is null then return false; end if;
  update public.push_deliveries d
     set clicked_at = now(), status = 'clicked', updated_at = now()
   where d.job_id = p_job_id and d.participant_id = v_participant_id;
  return found;
end;
$$;

create or replace function public.organizer_start_check_status()
returns table(
  participant_id uuid,
  pseudo text,
  role text,
  notifications_enabled boolean,
  ping0_notification_status text,
  ping0_clicked boolean,
  ping0_position_received boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid := public.my_event_id();
  v_ping0_slot uuid;
  v_ping0_job uuid;
begin
  if public.my_role() <> 'organizer' then raise exception 'Accès organisateur requis'; end if;
  select s.id into v_ping0_slot from public.ping_slots s
   where s.event_id = v_event_id and s.ordinal = 0 limit 1;
  select j.id into v_ping0_job from public.push_jobs j
   where j.event_id = v_event_id and j.slot_id = v_ping0_slot
   order by j.created_at desc limit 1;
  return query
  select p.id,
         p.pseudo,
         p.role,
         exists(select 1 from public.push_subscriptions ps where ps.participant_id = p.id),
         coalesce((select d.status from public.push_deliveries d where d.job_id = v_ping0_job and d.participant_id = p.id), 'pending'),
         coalesce((select d.clicked_at is not null from public.push_deliveries d where d.job_id = v_ping0_job and d.participant_id = p.id), false),
         case when p.role = 'target' then exists(
           select 1 from public.pings pg where pg.participant_id = p.id and pg.slot_id = v_ping0_slot
         ) else false end
  from public.participants p
  where p.event_id = v_event_id and p.active = true and p.role in ('target','hunter')
  order by p.role, p.pseudo;
end;
$$;

create or replace function public.claim_due_push_jobs()
returns table(id uuid, event_id uuid, slot_id uuid, scheduled_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  with picked as (
    select j.id
    from public.push_jobs j
    where j.scheduled_at <= clock_timestamp()
      and (j.status = 'pending' or (j.status = 'processing' and j.locked_at < clock_timestamp() - interval '2 minutes'))
    order by j.scheduled_at
    limit 10
    for update skip locked
  )
  update public.push_jobs j
     set status = 'processing', locked_at = clock_timestamp(), attempt_count = j.attempt_count + 1, last_error = null
    from picked p
   where j.id = p.id
  returning j.id, j.event_id, j.slot_id, j.scheduled_at;
end;
$$;
revoke all on function public.claim_due_push_jobs() from public, anon, authenticated;
grant execute on function public.claim_due_push_jobs() to service_role;

create or replace function public.dispatch_due_push_jobs()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_token text;
begin
  if not exists (
    select 1 from public.push_jobs j
    where j.scheduled_at <= clock_timestamp()
      and (j.status = 'pending' or (j.status = 'processing' and j.locked_at < clock_timestamp() - interval '2 minutes'))
  ) then return; end if;
  select c.value into v_token from public.app_private_config c where c.key = 'push_dispatch_token';
  if v_token is null then return; end if;
  perform net.http_post(
    url := 'https://loqeiqfwiajvzbuhmycr.supabase.co/functions/v1/push-dispatch',
    headers := jsonb_build_object('Content-Type','application/json','x-dispatch-token',v_token),
    body := '{}'::jsonb,
    timeout_milliseconds := 8000
  );
end;
$$;
revoke all on function public.dispatch_due_push_jobs() from public, anon, authenticated;

create or replace function public.start_event_now()
returns table(actual_started_at timestamptz, actual_ends_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid := public.my_event_id();
  v_event public.events%rowtype;
  v_now timestamptz := clock_timestamp();
  v_duration interval;
begin
  if public.my_role() <> 'organizer' then raise exception 'Accès organisateur requis'; end if;
  select e.* into v_event from public.events e where e.id = v_event_id for update;
  if v_event.id is null then raise exception 'Événement introuvable'; end if;
  if v_event.actual_started_at is not null then
    return query select v_event.actual_started_at, v_event.actual_ends_at;
    return;
  end if;
  v_duration := v_event.ends_at - v_event.starts_at;
  update public.ping_slots s
     set scheduled_at = v_now + make_interval(mins => s.ordinal * 30),
         label = case s.ordinal when 0 then 'Ping 0' when 1 then 'Ping 1' when 2 then 'Ping 2' when 3 then 'Ping 3' else s.label end
   where s.event_id = v_event_id;
  update public.events e
     set actual_started_at = v_now, actual_ends_at = v_now + v_duration, status = 'live', active_extraction_key = null
   where e.id = v_event_id;
  delete from public.push_jobs j where j.event_id = v_event_id;
  insert into public.push_jobs(event_id, slot_id, scheduled_at)
  select s.event_id, s.id, s.scheduled_at from public.ping_slots s
   where s.event_id = v_event_id and s.ordinal between 0 and 3;
  perform public.dispatch_due_push_jobs();
  return query select v_now, v_now + v_duration;
end;
$$;

create or replace function public.reset_event_start()
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare v_event_id uuid := public.my_event_id(); v_starts_at timestamptz;
begin
  if public.my_role() <> 'organizer' then raise exception 'Accès organisateur requis'; end if;
  select e.starts_at into v_starts_at from public.events e where e.id = v_event_id;
  if v_starts_at is null then raise exception 'Événement introuvable'; end if;
  delete from public.push_jobs j where j.event_id = v_event_id;
  update public.events e set actual_started_at = null, actual_ends_at = null, status = 'scheduled' where e.id = v_event_id;
  update public.ping_slots s set scheduled_at = v_starts_at + make_interval(mins => s.ordinal * 30) where s.event_id = v_event_id;
  return true;
end;
$$;

create or replace function public.reset_party()
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare v_event_id uuid := public.my_event_id(); v_starts_at timestamptz;
begin
  if public.my_role() <> 'organizer' then raise exception 'Accès organisateur requis'; end if;
  select e.starts_at into v_starts_at from public.events e where e.id = v_event_id;
  if v_starts_at is null then raise exception 'Événement introuvable'; end if;
  delete from public.push_jobs j where j.event_id = v_event_id;
  delete from public.pings pg where pg.event_id = v_event_id;
  update public.ping_slots s set scheduled_at = v_starts_at + make_interval(mins => s.ordinal * 30) where s.event_id = v_event_id;
  update public.events e set actual_started_at = null, actual_ends_at = null, active_extraction_key = null, status = 'scheduled' where e.id = v_event_id;
  return true;
end;
$$;

create or replace function public.my_next_ping_status()
returns table(event_status text, slot_id uuid, slot_label text, scheduled_at timestamptz, all_sent boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_participant public.participants%rowtype;
  v_event_status text;
  v_slot public.ping_slots%rowtype;
  v_now timestamptz := clock_timestamp();
begin
  select p.* into v_participant from public.participants p where p.user_id = auth.uid() and p.active = true limit 1;
  if v_participant.id is null or v_participant.role not in ('target','hunter') then raise exception 'Accès réservé aux Cibles et Chasseurs'; end if;
  select e.status into v_event_status from public.events e where e.id = v_participant.event_id;
  if v_participant.role = 'target' then
    select s.* into v_slot from public.ping_slots s
    where s.event_id = v_participant.event_id
      and not exists (select 1 from public.pings pg where pg.participant_id = v_participant.id and pg.slot_id = s.id)
      and (s.ordinal <> 0 or s.scheduled_at + interval '5 minutes' >= v_now)
    order by s.ordinal limit 1;
  else
    select s.* into v_slot from public.ping_slots s
    where s.event_id = v_participant.event_id
      and s.scheduled_at + interval '1 minute' >= v_now
    order by s.ordinal limit 1;
  end if;
  if v_slot.id is null then
    return query select v_event_status, null::uuid, null::text, null::timestamptz, true;
    return;
  end if;
  return query select v_event_status, v_slot.id, v_slot.label, v_slot.scheduled_at, false;
end;
$$;

create or replace function public.submit_ping_guarded(
  p_lat double precision,
  p_lng double precision,
  p_accuracy_m double precision default null,
  p_confirm_outside boolean default false
)
returns table(id uuid, slot_id uuid, sent_at timestamptz, valid_window boolean, delta_seconds integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_participant public.participants%rowtype;
  v_event public.events%rowtype;
  v_slot public.ping_slots%rowtype;
  v_sent timestamptz := clock_timestamp();
  v_signed_delta integer;
  v_abs_delta integer;
  v_is_control boolean;
  v_ping public.pings%rowtype;
begin
  if auth.uid() is null then raise exception 'Authentification requise'; end if;
  select p.* into v_participant from public.participants p where p.user_id = auth.uid() and p.active = true limit 1;
  if v_participant.id is null then raise exception 'Participant non reconnu'; end if;
  if v_participant.role <> 'target' then raise exception 'Seules les Cibles peuvent envoyer un ping'; end if;
  select e.* into v_event from public.events e where e.id = v_participant.event_id;
  if v_event.id is null then raise exception 'Événement introuvable'; end if;
  if v_event.status <> 'live' or v_event.actual_started_at is null then raise exception 'La partie n''a pas encore démarré'; end if;
  if v_event.actual_ends_at is not null and v_sent > v_event.actual_ends_at then raise exception 'La partie est terminée'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_participant.id::text, 0));
  select s.* into v_slot from public.ping_slots s
  where s.event_id = v_participant.event_id
    and not exists (select 1 from public.pings pg where pg.participant_id = v_participant.id and pg.slot_id = s.id)
    and (s.ordinal <> 0 or s.scheduled_at + interval '5 minutes' >= v_sent)
  order by s.ordinal limit 1;
  if v_slot.id is null then raise exception 'Tous les pings ont déjà été envoyés'; end if;
  v_signed_delta := round(extract(epoch from (v_sent - v_slot.scheduled_at)))::integer;
  v_abs_delta := abs(v_signed_delta);
  v_is_control := v_slot.ordinal = 0;
  if not v_is_control and v_abs_delta > 60 and not coalesce(p_confirm_outside, false) then
    raise exception 'CONFIRM_OUTSIDE_WINDOW|%|%|%', case when v_signed_delta < 0 then 'early' else 'late' end, v_slot.label, v_abs_delta;
  end if;
  insert into public.pings(event_id, participant_id, slot_id, lat, lng, accuracy_m, sent_at, valid_window, delta_seconds)
  values(v_participant.event_id, v_participant.id, v_slot.id, p_lat, p_lng, p_accuracy_m, v_sent, (v_is_control or v_abs_delta <= 60), v_signed_delta)
  on conflict on constraint pings_participant_id_slot_id_key do nothing
  returning public.pings.* into v_ping;
  if v_ping.id is null then
    select pg.* into v_ping from public.pings pg where pg.participant_id = v_participant.id and pg.slot_id = v_slot.id limit 1;
  end if;
  return query select v_ping.id, v_ping.slot_id, v_ping.sent_at, v_ping.valid_window, v_ping.delta_seconds;
end;
$$;

create or replace function public.submit_ping(
  p_lat double precision,
  p_lng double precision,
  p_accuracy_m double precision default null
)
returns table(id uuid, slot_id uuid, sent_at timestamptz, valid_window boolean, delta_seconds integer)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query select g.id, g.slot_id, g.sent_at, g.valid_window, g.delta_seconds
  from public.submit_ping_guarded(p_lat, p_lng, p_accuracy_m, false) g;
end;
$$;

create or replace function public.reset_player_access()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare v_event_id uuid := public.my_event_id(); v_count integer := 0;
begin
  if public.my_role() <> 'organizer' then raise exception 'Accès organisateur requis'; end if;
  delete from public.push_subscriptions ps using public.participants p
   where ps.participant_id = p.id and p.event_id = v_event_id and p.role in ('target','hunter');
  update public.participants p set user_id = null
   where p.event_id = v_event_id and p.role in ('target','hunter') and p.user_id is not null;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function public.reset_all_access()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare v_event_id uuid := public.my_event_id(); v_count integer := 0;
begin
  if public.my_role() <> 'organizer' then raise exception 'Accès organisateur requis'; end if;
  delete from public.push_subscriptions ps using public.participants p
   where ps.participant_id = p.id and p.event_id = v_event_id;
  update public.participants p set user_id = null where p.event_id = v_event_id and p.user_id is not null;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function public.reset_total_test()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare v_event_id uuid := public.my_event_id(); v_starts_at timestamptz; v_count integer := 0;
begin
  if public.my_role() <> 'organizer' then raise exception 'Accès organisateur requis'; end if;
  select e.starts_at into v_starts_at from public.events e where e.id = v_event_id;
  if v_starts_at is null then raise exception 'Événement introuvable'; end if;
  delete from public.push_jobs j where j.event_id = v_event_id;
  delete from public.push_subscriptions ps using public.participants p where ps.participant_id = p.id and p.event_id = v_event_id;
  delete from public.pings pg where pg.event_id = v_event_id;
  update public.ping_slots s set scheduled_at = v_starts_at + make_interval(mins => s.ordinal * 30) where s.event_id = v_event_id;
  update public.events e set actual_started_at = null, actual_ends_at = null, active_extraction_key = null, status = 'scheduled' where e.id = v_event_id;
  with ranked as (
    select p.id, p.role, row_number() over (partition by p.role order by p.id) as rn
    from public.participants p where p.event_id = v_event_id
  )
  update public.participants p
     set user_id = null,
         pseudo = case r.role
           when 'target' then 'CIBLE ' || lpad(r.rn::text, 2, '0')
           when 'hunter' then 'CHASSEUR ' || lpad(r.rn::text, 2, '0')
           when 'organizer' then 'ORGA ' || lpad(r.rn::text, 2, '0')
           else upper(r.role) || ' ' || lpad(r.rn::text, 2, '0') end
    from ranked r where p.id = r.id;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

grant execute on function public.save_push_subscription(text,text,text,text) to authenticated;
grant execute on function public.remove_my_push_subscription() to authenticated;
grant execute on function public.my_push_subscription_status() to authenticated;
grant execute on function public.ack_push_notification(uuid) to authenticated;
grant execute on function public.organizer_start_check_status() to authenticated;

do $$
declare v_job_id bigint;
begin
  select jobid into v_job_id from cron.job where jobname = 'chasse_push_dispatch' limit 1;
  if v_job_id is not null then perform cron.unschedule(v_job_id); end if;
  perform cron.schedule('chasse_push_dispatch', '10 seconds', 'select public.dispatch_due_push_jobs();');
end;
$$;

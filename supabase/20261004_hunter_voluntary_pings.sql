-- Hunter-only voluntary GPS pings.
-- Hunters can publish their current position at will after their +10 min departure.
-- Only hunters can retrieve these pings; the map shows the latest ping per hunter.

create table if not exists public.hunter_pings (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  participant_id uuid not null references public.participants(id) on delete cascade,
  lat double precision not null check (lat between -90 and 90),
  lng double precision not null check (lng between -180 and 180),
  accuracy_m double precision,
  sent_at timestamptz not null default clock_timestamp()
);

create index if not exists hunter_pings_event_sent_idx
  on public.hunter_pings(event_id, sent_at desc);

alter table public.hunter_pings enable row level security;

create or replace function public.submit_hunter_ping(
  p_lat double precision,
  p_lng double precision,
  p_accuracy_m double precision default null
)
returns table(id uuid, sent_at timestamptz)
language plpgsql
security definer
set search_path=public
as $function$
declare
  v_participant public.participants%rowtype;
  v_event public.events%rowtype;
  v_ping public.hunter_pings%rowtype;
  v_now timestamptz := clock_timestamp();
begin
  select p.* into v_participant
  from public.participants p
  where p.user_id=auth.uid() and p.active=true
  limit 1;

  if v_participant.id is null or v_participant.role <> 'hunter' then
    raise exception 'Accès réservé aux Chasseurs';
  end if;

  select e.* into v_event
  from public.events e
  where e.id=v_participant.event_id;

  if v_event.status <> 'live' or v_event.actual_started_at is null then
    raise exception 'La partie n''a pas démarré';
  end if;

  if v_now < v_event.actual_started_at + interval '10 minutes' then
    raise exception 'Le départ des Chasseurs n''est pas encore autorisé';
  end if;

  if v_event.actual_ends_at is not null
     and v_now > v_event.actual_ends_at + interval '60 seconds' then
    raise exception 'La partie est terminée';
  end if;

  insert into public.hunter_pings(event_id,participant_id,lat,lng,accuracy_m,sent_at)
  values(v_participant.event_id,v_participant.id,p_lat,p_lng,p_accuracy_m,v_now)
  returning * into v_ping;

  return query select v_ping.id,v_ping.sent_at;
end;
$function$;

create or replace function public.visible_hunter_pings()
returns table(
  id uuid,
  participant_id uuid,
  pseudo text,
  lat double precision,
  lng double precision,
  accuracy_m double precision,
  sent_at timestamptz
)
language plpgsql
stable
security definer
set search_path=public
as $function$
declare
  v_event uuid := public.my_event_id();
begin
  if public.my_role() <> 'hunter' then
    raise exception 'Accès réservé aux Chasseurs';
  end if;

  return query
  select distinct on (hp.participant_id)
         hp.id,hp.participant_id,p.pseudo,
         hp.lat,hp.lng,hp.accuracy_m,hp.sent_at
  from public.hunter_pings hp
  join public.participants p on p.id=hp.participant_id
  where hp.event_id=v_event
    and p.active=true
    and p.role='hunter'
  order by hp.participant_id,hp.sent_at desc;
end;
$function$;

grant execute on function public.submit_hunter_ping(double precision,double precision,double precision) to authenticated;
grant execute on function public.visible_hunter_pings() to authenticated;
revoke all on public.hunter_pings from public, anon, authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname='supabase_realtime'
      and schemaname='public'
      and tablename='hunter_pings'
  ) then
    alter publication supabase_realtime add table public.hunter_pings;
  end if;
end $$;

-- Contrôles de déroulement, pseudos choisis par les participants et démarrage réel.

alter table public.events
  add column if not exists actual_started_at timestamptz,
  add column if not exists actual_ends_at timestamptz;

create or replace function public.claim_participant_with_pseudo(
  p_code text,
  p_pseudo text
)
returns table (
  id uuid,
  event_id uuid,
  pseudo text,
  role text,
  team text,
  active boolean
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid uuid := auth.uid();
  v_hash text;
  v_pseudo text;
  v_participant public.participants%rowtype;
  v_event_status text;
begin
  if v_uid is null then
    raise exception 'Session anonyme requise';
  end if;

  v_pseudo := regexp_replace(trim(coalesce(p_pseudo, '')), '\s+', ' ', 'g');
  if char_length(v_pseudo) < 2 or char_length(v_pseudo) > 24 then
    raise exception 'Le pseudo doit contenir entre 2 et 24 caractères';
  end if;

  v_hash := encode(digest(upper(trim(p_code)), 'sha256'), 'hex');

  select p.* into v_participant
  from public.participants p
  join public.access_codes c on c.participant_id = p.id
  where c.code_hash = v_hash
  limit 1;

  if v_participant.id is null then
    raise exception 'Code invalide';
  end if;
  if not v_participant.active then
    raise exception 'Participant désactivé';
  end if;

  select e.status into v_event_status
  from public.events e
  where e.id = v_participant.event_id;

  if v_participant.user_id is not null and v_participant.user_id <> v_uid then
    raise exception 'Code déjà utilisé sur un autre appareil';
  end if;

  -- Avant le START, le joueur peut corriger son pseudo sur le même appareil.
  -- Après le START, le pseudo est figé pour éviter les changements d'identité en cours de partie.
  if v_participant.user_id is null or v_event_status <> 'live' then
    if exists (
      select 1 from public.participants p2
      where p2.event_id = v_participant.event_id
        and p2.id <> v_participant.id
        and lower(p2.pseudo) = lower(v_pseudo)
    ) then
      raise exception 'Ce pseudo est déjà utilisé';
    end if;

    update public.participants
       set user_id = coalesce(user_id, v_uid),
           pseudo = v_pseudo
     where public.participants.id = v_participant.id;
  end if;

  return query
    select p.id, p.event_id, p.pseudo, p.role, p.team, p.active
    from public.participants p
    where p.id = v_participant.id;
end;
$$;

create or replace function public.start_event_now()
returns table (
  actual_started_at timestamptz,
  actual_ends_at timestamptz
)
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
  if public.my_role() <> 'organizer' then
    raise exception 'Accès organisateur requis';
  end if;

  select * into v_event
  from public.events
  where id = v_event_id
  for update;

  if v_event.id is null then
    raise exception 'Événement introuvable';
  end if;

  if v_event.actual_started_at is not null then
    return query select v_event.actual_started_at, v_event.actual_ends_at;
    return;
  end if;

  v_duration := v_event.ends_at - v_event.starts_at;

  update public.ping_slots s
     set scheduled_at = v_now + (s.scheduled_at - v_event.starts_at)
   where s.event_id = v_event_id;

  update public.events e
     set actual_started_at = v_now,
         actual_ends_at = v_now + v_duration,
         status = 'live',
         active_extraction_key = null
   where e.id = v_event_id;

  return query select v_now, v_now + v_duration;
end;
$$;

create or replace function public.reset_extraction_zone()
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid := public.my_event_id();
begin
  if public.my_role() <> 'organizer' then
    raise exception 'Accès organisateur requis';
  end if;

  update public.events
     set active_extraction_key = null
   where id = v_event_id;

  return true;
end;
$$;

create or replace function public.submit_ping(
  p_lat double precision,
  p_lng double precision,
  p_accuracy_m double precision default null
)
returns table (
  id uuid,
  slot_id uuid,
  sent_at timestamptz,
  valid_window boolean,
  delta_seconds integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_participant public.participants%rowtype;
  v_event public.events%rowtype;
  v_slot public.ping_slots%rowtype;
  v_sent timestamptz := clock_timestamp();
  v_delta integer;
  v_ping public.pings%rowtype;
begin
  select * into v_participant
  from public.participants
  where user_id = v_uid and active = true
  limit 1;

  if v_participant.id is null or v_participant.role <> 'target' then
    raise exception 'Accès réservé aux Cibles';
  end if;

  select * into v_event
  from public.events
  where id = v_participant.event_id;

  if v_event.status <> 'live' or v_event.actual_started_at is null then
    raise exception 'Activité non démarrée';
  end if;
  if v_event.actual_ends_at is not null and v_sent > v_event.actual_ends_at then
    raise exception 'Activité terminée';
  end if;

  select s.* into v_slot
  from public.ping_slots s
  where s.event_id = v_participant.event_id
    and not exists (
      select 1 from public.pings p
      where p.participant_id = v_participant.id and p.slot_id = s.id
    )
  order by s.ordinal
  limit 1;

  if v_slot.id is null then
    raise exception 'Tous les pings ont déjà été envoyés';
  end if;

  v_delta := abs(extract(epoch from (v_sent - v_slot.scheduled_at))::integer);

  insert into public.pings (
    event_id, participant_id, slot_id, lat, lng, accuracy_m, sent_at, valid_window, delta_seconds
  ) values (
    v_participant.event_id, v_participant.id, v_slot.id, p_lat, p_lng, p_accuracy_m,
    v_sent, v_delta <= 60, v_delta
  ) returning * into v_ping;

  return query
    select v_ping.id, v_ping.slot_id, v_ping.sent_at, v_ping.valid_window, v_ping.delta_seconds;
end;
$$;

revoke execute on function public.claim_participant_with_pseudo(text,text) from public, anon;
revoke execute on function public.start_event_now() from public, anon;
revoke execute on function public.reset_extraction_zone() from public, anon;
revoke execute on function public.submit_ping(double precision,double precision,double precision) from public, anon;

grant execute on function public.claim_participant_with_pseudo(text,text) to authenticated;
grant execute on function public.start_event_now() to authenticated;
grant execute on function public.reset_extraction_zone() to authenticated;
grant execute on function public.submit_ping(double precision,double precision,double precision) to authenticated;

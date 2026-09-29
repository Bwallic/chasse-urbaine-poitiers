-- Correctifs issus de la première phase de test :
-- 1) message clair lorsqu'un navigateur déjà associé tente de prendre un autre code ;
-- 2) suppression des références de colonnes ambiguës dans l'envoi de ping ;
-- 3) verrou/idempotence renforcés pour éviter les doubles pings.

create or replace function public.claim_participant_with_pseudo(p_code text, p_pseudo text)
returns table(id uuid, event_id uuid, pseudo text, role text, team text, active boolean)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid uuid := auth.uid();
  v_hash text;
  v_pseudo text;
  v_participant public.participants%rowtype;
  v_existing public.participants%rowtype;
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

  if v_participant.user_id is not null and v_participant.user_id <> v_uid then
    raise exception 'Code déjà utilisé sur un autre appareil';
  end if;

  select p.* into v_existing
  from public.participants p
  where p.user_id = v_uid
    and p.active = true
    and p.id <> v_participant.id
  limit 1;

  if v_existing.id is not null then
    raise exception 'Ce navigateur est déjà associé à % (%). Utilise un autre navigateur ou une fenêtre privée pour un second compte.', v_existing.pseudo, v_existing.role;
  end if;

  select e.status into v_event_status
  from public.events e
  where e.id = v_participant.event_id;

  if v_participant.user_id is null or v_event_status <> 'live' then
    if exists (
      select 1
      from public.participants p2
      where p2.event_id = v_participant.event_id
        and p2.id <> v_participant.id
        and lower(p2.pseudo) = lower(v_pseudo)
    ) then
      raise exception 'Ce pseudo est déjà utilisé';
    end if;

    update public.participants p
       set user_id = coalesce(p.user_id, v_uid),
           pseudo = v_pseudo
     where p.id = v_participant.id;
  end if;

  return query
    select p.id, p.event_id, p.pseudo, p.role, p.team, p.active
    from public.participants p
    where p.id = v_participant.id;
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
  v_uid uuid := auth.uid();
  v_participant public.participants%rowtype;
  v_event public.events%rowtype;
  v_slot public.ping_slots%rowtype;
  v_sent timestamptz := clock_timestamp();
  v_signed_delta integer;
  v_abs_delta integer;
  v_ping public.pings%rowtype;
begin
  if v_uid is null then
    raise exception 'Authentification requise';
  end if;

  select p.* into v_participant
  from public.participants p
  where p.user_id = v_uid
    and p.active = true
  limit 1;

  if v_participant.id is null then
    raise exception 'Participant non reconnu';
  end if;
  if v_participant.role <> 'target' then
    raise exception 'Seules les Cibles peuvent envoyer un ping';
  end if;

  select e.* into v_event
  from public.events e
  where e.id = v_participant.event_id;

  if v_event.id is null then
    raise exception 'Événement introuvable';
  end if;
  if v_event.status <> 'live' or v_event.actual_started_at is null then
    raise exception 'La partie n''a pas encore démarré';
  end if;
  if v_event.actual_ends_at is not null and v_sent > v_event.actual_ends_at then
    raise exception 'La partie est terminée';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_participant.id::text, 0));

  select s.* into v_slot
  from public.ping_slots s
  where s.event_id = v_participant.event_id
    and not exists (
      select 1
      from public.pings pg
      where pg.participant_id = v_participant.id
        and pg.slot_id = s.id
    )
  order by s.ordinal
  limit 1;

  if v_slot.id is null then
    raise exception 'Tous les pings ont déjà été envoyés';
  end if;

  v_signed_delta := round(extract(epoch from (v_sent - v_slot.scheduled_at)))::integer;
  v_abs_delta := abs(v_signed_delta);

  if v_abs_delta > 60 and not coalesce(p_confirm_outside, false) then
    raise exception 'CONFIRM_OUTSIDE_WINDOW|%|%|%',
      case when v_signed_delta < 0 then 'early' else 'late' end,
      v_slot.label,
      v_abs_delta;
  end if;

  insert into public.pings (
    event_id, participant_id, slot_id, lat, lng, accuracy_m, sent_at, valid_window, delta_seconds
  ) values (
    v_participant.event_id, v_participant.id, v_slot.id, p_lat, p_lng, p_accuracy_m,
    v_sent, v_abs_delta <= 60, v_signed_delta
  )
  on conflict on constraint pings_participant_id_slot_id_key do nothing
  returning public.pings.* into v_ping;

  if v_ping.id is null then
    select pg.* into v_ping
    from public.pings pg
    where pg.participant_id = v_participant.id
      and pg.slot_id = v_slot.id
    limit 1;
  end if;

  return query
    select v_ping.id, v_ping.slot_id, v_ping.sent_at, v_ping.valid_window, v_ping.delta_seconds;
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
  return query
  select g.id, g.slot_id, g.sent_at, g.valid_window, g.delta_seconds
  from public.submit_ping_guarded(p_lat, p_lng, p_accuracy_m, false) g;
end;
$$;

revoke execute on function public.claim_participant_with_pseudo(text, text) from public, anon;
revoke execute on function public.submit_ping_guarded(double precision, double precision, double precision, boolean) from public, anon;
revoke execute on function public.submit_ping(double precision, double precision, double precision) from public, anon;
grant execute on function public.claim_participant_with_pseudo(text, text) to authenticated;
grant execute on function public.submit_ping_guarded(double precision, double precision, double precision, boolean) to authenticated;
grant execute on function public.submit_ping(double precision, double precision, double precision) to authenticated;

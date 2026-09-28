-- Sécurise l'envoi des pings : un seul ping par créneau et confirmation serveur hors fenêtre.

create or replace function public.submit_ping_guarded(
  p_lat double precision,
  p_lng double precision,
  p_accuracy_m double precision default null,
  p_confirm_outside boolean default false
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

  if v_delta > 60 and not coalesce(p_confirm_outside, false) then
    if v_sent < v_slot.scheduled_at then
      raise exception 'CONFIRM_OUTSIDE_WINDOW|early|%|%', v_slot.label, extract(epoch from (v_slot.scheduled_at - v_sent))::integer;
    else
      raise exception 'CONFIRM_OUTSIDE_WINDOW|late|%|%', v_slot.label, extract(epoch from (v_sent - v_slot.scheduled_at))::integer;
    end if;
  end if;

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

revoke execute on function public.submit_ping_guarded(double precision,double precision,double precision,boolean) from public, anon;
grant execute on function public.submit_ping_guarded(double precision,double precision,double precision,boolean) to authenticated;

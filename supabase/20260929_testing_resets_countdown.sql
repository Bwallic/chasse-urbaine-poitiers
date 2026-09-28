-- Outils de test organisateur + statut du prochain ping côté Cible.

create or replace function public.reset_event_start()
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid := public.my_event_id();
  v_starts_at timestamptz;
begin
  if public.my_role() <> 'organizer' then
    raise exception 'Accès organisateur requis';
  end if;

  select starts_at into v_starts_at from public.events where id = v_event_id;
  if v_starts_at is null then
    raise exception 'Événement introuvable';
  end if;

  update public.events
     set actual_started_at = null,
         actual_ends_at = null,
         status = 'scheduled'
   where id = v_event_id;

  update public.ping_slots s
     set scheduled_at = v_starts_at + make_interval(mins => s.ordinal * 30)
   where s.event_id = v_event_id;

  return true;
end;
$$;

create or replace function public.reset_party()
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid := public.my_event_id();
  v_starts_at timestamptz;
begin
  if public.my_role() <> 'organizer' then
    raise exception 'Accès organisateur requis';
  end if;

  select starts_at into v_starts_at from public.events where id = v_event_id;
  if v_starts_at is null then
    raise exception 'Événement introuvable';
  end if;

  delete from public.pings where event_id = v_event_id;

  update public.ping_slots s
     set scheduled_at = v_starts_at + make_interval(mins => s.ordinal * 30)
   where s.event_id = v_event_id;

  update public.events
     set actual_started_at = null,
         actual_ends_at = null,
         active_extraction_key = null,
         status = 'scheduled'
   where id = v_event_id;

  return true;
end;
$$;

create or replace function public.my_next_ping_status()
returns table (
  event_status text,
  slot_id uuid,
  slot_label text,
  scheduled_at timestamptz,
  all_sent boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_participant public.participants%rowtype;
  v_event_status text;
  v_slot public.ping_slots%rowtype;
begin
  select * into v_participant
  from public.participants
  where user_id = v_uid and active = true
  limit 1;

  if v_participant.id is null or v_participant.role <> 'target' then
    raise exception 'Accès réservé aux Cibles';
  end if;

  select status into v_event_status
  from public.events
  where id = v_participant.event_id;

  select s.* into v_slot
  from public.ping_slots s
  where s.event_id = v_participant.event_id
    and not exists (
      select 1 from public.pings p
      where p.participant_id = v_participant.id
        and p.slot_id = s.id
    )
  order by s.ordinal
  limit 1;

  if v_slot.id is null then
    return query select v_event_status, null::uuid, null::text, null::timestamptz, true;
    return;
  end if;

  return query select v_event_status, v_slot.id, v_slot.label, v_slot.scheduled_at, false;
end;
$$;

revoke execute on function public.reset_event_start() from public, anon;
revoke execute on function public.reset_party() from public, anon;
revoke execute on function public.my_next_ping_status() from public, anon;

grant execute on function public.reset_event_start() to authenticated;
grant execute on function public.reset_party() to authenticated;
grant execute on function public.my_next_ping_status() to authenticated;

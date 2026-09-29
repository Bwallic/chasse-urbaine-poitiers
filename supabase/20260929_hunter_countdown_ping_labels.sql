-- Hunter countdown support + generic ping labels

create or replace function public.my_next_ping_status()
returns table(
  event_status text,
  slot_id uuid,
  slot_label text,
  scheduled_at timestamptz,
  all_sent boolean
)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_participant public.participants%rowtype;
  v_event_status text;
  v_slot public.ping_slots%rowtype;
  v_now timestamptz := clock_timestamp();
begin
  select p.* into v_participant
  from public.participants p
  where p.user_id = v_uid
    and p.active = true
  limit 1;

  if v_participant.id is null or v_participant.role not in ('target', 'hunter') then
    raise exception 'Accès réservé aux Cibles et Chasseurs';
  end if;

  select e.status into v_event_status
  from public.events e
  where e.id = v_participant.event_id;

  if v_participant.role = 'target' then
    select s.* into v_slot
    from public.ping_slots s
    where s.event_id = v_participant.event_id
      and not exists (
        select 1
        from public.pings p
        where p.participant_id = v_participant.id
          and p.slot_id = s.id
      )
    order by s.ordinal
    limit 1;
  else
    select s.* into v_slot
    from public.ping_slots s
    where s.event_id = v_participant.event_id
      and s.scheduled_at + interval '1 minute' >= v_now
    order by s.ordinal
    limit 1;
  end if;

  if v_slot.id is null then
    return query
      select v_event_status, null::uuid, null::text, null::timestamptz, true;
    return;
  end if;

  return query
    select v_event_status, v_slot.id, v_slot.label, v_slot.scheduled_at, false;
end;
$function$;

-- Human-facing labels are independent from actual clock times.
update public.ping_slots
set label = 'Ping ' || ordinal::text
where ordinal in (1, 2, 3);

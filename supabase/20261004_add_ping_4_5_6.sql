-- Extend the 20-minute ping schedule across the full two-hour game.
-- Ping 0 = START, then Ping 1..6 every 20 minutes through +120 minutes.

insert into public.ping_slots (event_id, label, scheduled_at, ordinal)
select e.id, 'Ping 4', e.starts_at + interval '80 minutes', 4
from public.events e
where e.id = '11111111-1111-1111-1111-111111111111'
on conflict (event_id, ordinal) do update
set label = excluded.label,
    scheduled_at = excluded.scheduled_at;

insert into public.ping_slots (event_id, label, scheduled_at, ordinal)
select e.id, 'Ping 5', e.starts_at + interval '100 minutes', 5
from public.events e
where e.id = '11111111-1111-1111-1111-111111111111'
on conflict (event_id, ordinal) do update
set label = excluded.label,
    scheduled_at = excluded.scheduled_at;

insert into public.ping_slots (event_id, label, scheduled_at, ordinal)
select e.id, 'Ping 6', e.starts_at + interval '120 minutes', 6
from public.events e
where e.id = '11111111-1111-1111-1111-111111111111'
on conflict (event_id, ordinal) do update
set label = excluded.label,
    scheduled_at = excluded.scheduled_at;

create or replace function public.start_event_now()
returns table(actual_started_at timestamptz, actual_ends_at timestamptz)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_event_id uuid := public.my_event_id();
  v_event public.events%rowtype;
  v_now timestamptz := clock_timestamp();
  v_duration interval;
begin
  if public.my_role() <> 'organizer' then
    raise exception 'Accès organisateur requis';
  end if;

  select e.* into v_event
  from public.events e
  where e.id = v_event_id
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
     set scheduled_at = v_now + make_interval(mins => s.ordinal * 20),
         label = 'Ping ' || s.ordinal::text
   where s.event_id = v_event_id
     and s.ordinal between 0 and 6;

  update public.events e
     set actual_started_at = v_now,
         actual_ends_at = v_now + v_duration,
         status = 'live',
         active_extraction_key = null
   where e.id = v_event_id;

  delete from public.push_jobs j
  where j.event_id = v_event_id;

  insert into public.push_jobs(event_id, slot_id, scheduled_at)
  select s.event_id, s.id, s.scheduled_at
  from public.ping_slots s
  where s.event_id = v_event_id
    and s.ordinal between 0 and 6;

  perform public.dispatch_due_push_jobs();

  return query select v_now, v_now + v_duration;
end;
$function$;

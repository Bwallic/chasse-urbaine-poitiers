-- Évasion Urbaine — planning des pings irrégulier.
-- START = Ping 0, départ chasseurs à +10 min.
-- Pings suivants : +30, +40, +50, +60, +75, +90, +95, +100, +105, +110, +115, +120.

create or replace function public.ping_offset_minutes(p_ordinal integer)
returns integer
language sql
immutable
as $function$
  select case p_ordinal
    when 0 then 0
    when 1 then 30
    when 2 then 40
    when 3 then 50
    when 4 then 60
    when 5 then 75
    when 6 then 90
    when 7 then 95
    when 8 then 100
    when 9 then 105
    when 10 then 110
    when 11 then 115
    when 12 then 120
    else null
  end
$function$;

insert into public.ping_slots(event_id,label,scheduled_at,ordinal)
select
  '11111111-1111-1111-1111-111111111111'::uuid,
  'Ping ' || v.ordinal,
  e.starts_at + make_interval(mins => v.offset_min),
  v.ordinal
from public.events e
cross join (values
  (0,0),(1,30),(2,40),(3,50),(4,60),(5,75),(6,90),
  (7,95),(8,100),(9,105),(10,110),(11,115),(12,120)
) as v(ordinal,offset_min)
where e.id='11111111-1111-1111-1111-111111111111'::uuid
on conflict (event_id,ordinal) do update
set label=excluded.label, scheduled_at=excluded.scheduled_at;

create or replace function public.start_event_now()
returns table(actual_started_at timestamptz, actual_ends_at timestamptz)
language plpgsql
security definer
set search_path=public
as $function$
declare
  v_event_id uuid := public.my_event_id();
  v_event public.events%rowtype;
  v_now timestamptz := clock_timestamp();
begin
  if public.my_role() <> 'organizer' then raise exception 'Accès organisateur requis'; end if;

  select e.* into v_event
  from public.events e
  where e.id=v_event_id
  for update;

  if v_event.id is null then raise exception 'Événement introuvable'; end if;

  if v_event.actual_started_at is not null then
    return query select v_event.actual_started_at, v_event.actual_ends_at;
    return;
  end if;

  update public.ping_slots s
     set scheduled_at=v_now + make_interval(mins => public.ping_offset_minutes(s.ordinal)),
         label='Ping ' || s.ordinal::text
   where s.event_id=v_event_id and s.ordinal between 0 and 12;

  update public.events e
     set actual_started_at=v_now,
         actual_ends_at=v_now + interval '120 minutes',
         status='live',
         active_extraction_key=null
   where e.id=v_event_id;

  delete from public.push_jobs where event_id=v_event_id;

  insert into public.push_jobs(event_id,slot_id,scheduled_at)
  select s.event_id,s.id,s.scheduled_at
  from public.ping_slots s
  where s.event_id=v_event_id and s.ordinal between 0 and 12
  order by s.ordinal;

  perform public.dispatch_due_push_jobs();

  return query select v_now, v_now + interval '120 minutes';
end;
$function$;

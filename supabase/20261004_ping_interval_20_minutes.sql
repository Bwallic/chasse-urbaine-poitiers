-- Change all live and reset ping scheduling from 30-minute to 20-minute intervals.
-- Ping 0 = START, Ping 1 = +20 min, Ping 2 = +40 min, Ping 3 = +60 min.

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
  if public.my_role() <> 'organizer' then raise exception 'Accès organisateur requis'; end if;

  select e.* into v_event
  from public.events e
  where e.id = v_event_id
  for update;

  if v_event.id is null then raise exception 'Événement introuvable'; end if;
  if v_event.actual_started_at is not null then
    return query select v_event.actual_started_at, v_event.actual_ends_at;
    return;
  end if;

  v_duration := v_event.ends_at - v_event.starts_at;

  update public.ping_slots s
     set scheduled_at = v_now + make_interval(mins => s.ordinal * 20),
         label = case s.ordinal
           when 0 then 'Ping 0'
           when 1 then 'Ping 1'
           when 2 then 'Ping 2'
           when 3 then 'Ping 3'
           else s.label
         end
   where s.event_id = v_event_id;

  update public.events e
     set actual_started_at = v_now,
         actual_ends_at = v_now + v_duration,
         status = 'live',
         active_extraction_key = null
   where e.id = v_event_id;

  delete from public.push_jobs j where j.event_id = v_event_id;
  insert into public.push_jobs(event_id, slot_id, scheduled_at)
  select s.event_id, s.id, s.scheduled_at
  from public.ping_slots s
  where s.event_id = v_event_id and s.ordinal between 0 and 3;

  perform public.dispatch_due_push_jobs();
  return query select v_now, v_now + v_duration;
end;
$function$;

create or replace function public.reset_event_start()
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_event_id uuid := public.my_event_id();
  v_starts_at timestamptz;
begin
  if public.my_role() <> 'organizer' then raise exception 'Accès organisateur requis'; end if;
  select e.starts_at into v_starts_at from public.events e where e.id = v_event_id;
  if v_starts_at is null then raise exception 'Événement introuvable'; end if;

  delete from public.push_jobs j where j.event_id = v_event_id;
  update public.events e set actual_started_at = null, actual_ends_at = null, status = 'scheduled' where e.id = v_event_id;
  update public.ping_slots s set scheduled_at = v_starts_at + make_interval(mins => s.ordinal * 20) where s.event_id = v_event_id;
  return true;
end;
$function$;

create or replace function public.reset_party()
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_event_id uuid := public.my_event_id();
  v_starts_at timestamptz;
begin
  if public.my_role() <> 'organizer' then raise exception 'Accès organisateur requis'; end if;
  select e.starts_at into v_starts_at from public.events e where e.id = v_event_id;
  if v_starts_at is null then raise exception 'Événement introuvable'; end if;

  delete from public.push_jobs j where j.event_id = v_event_id;
  delete from public.pings pg where pg.event_id = v_event_id;
  update public.ping_slots s set scheduled_at = v_starts_at + make_interval(mins => s.ordinal * 20) where s.event_id = v_event_id;
  update public.events e set actual_started_at = null, actual_ends_at = null, active_extraction_key = null, status = 'scheduled' where e.id = v_event_id;
  return true;
end;
$function$;

create or replace function public.reset_total_test()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_event_id uuid := public.my_event_id();
  v_starts_at timestamptz;
  v_count integer := 0;
begin
  if public.my_role() <> 'organizer' then
    raise exception 'Accès organisateur requis';
  end if;

  select e.starts_at into v_starts_at
  from public.events e
  where e.id = v_event_id;

  if v_starts_at is null then
    raise exception 'Événement introuvable';
  end if;

  delete from public.push_jobs j
  where j.event_id = v_event_id;

  delete from public.push_subscriptions ps
  using public.participants p
  where ps.participant_id = p.id
    and p.event_id = v_event_id;

  delete from public.pings pg
  where pg.event_id = v_event_id;

  update public.ping_slots s
     set scheduled_at = v_starts_at + make_interval(mins => s.ordinal * 20)
   where s.event_id = v_event_id;

  update public.events e
     set actual_started_at = null,
         actual_ends_at = null,
         active_extraction_key = null,
         status = 'scheduled'
   where e.id = v_event_id;

  update public.participants p
     set user_id = null,
         pseudo = '__RESET__' || replace(p.id::text, '-', '')
   where p.event_id = v_event_id;

  with ranked as (
    select p.id,
           p.role,
           row_number() over (partition by p.role order by p.id) as rn
    from public.participants p
    where p.event_id = v_event_id
  )
  update public.participants p
     set pseudo = case r.role
           when 'target' then 'CIBLE ' || lpad(r.rn::text, 2, '0')
           when 'hunter' then 'CHASSEUR ' || lpad(r.rn::text, 2, '0')
           when 'organizer' then 'ORGA ' || lpad(r.rn::text, 2, '0')
           else upper(r.role) || ' ' || lpad(r.rn::text, 2, '0')
         end
    from ranked r
   where p.id = r.id;

  get diagnostics v_count = row_count;
  return v_count;
end;
$function$;

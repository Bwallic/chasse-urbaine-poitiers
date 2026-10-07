-- Révélation automatique de la zone d'extraction à START +80 minutes.
-- Le tirage est effectué côté serveur et une notification push est envoyée.
-- Le bouton Organisateur reste disponible en secours une fois l'échéance atteinte.

create or replace function public.draw_extraction_zone()
returns text
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_event uuid := public.my_event_id();
  v_key text;
  v_name text;
  v_token text;
  v_event_row public.events%rowtype;
begin
  if public.my_role() <> 'organizer' then
    raise exception 'Accès organisateur requis';
  end if;

  select e.* into v_event_row
  from public.events e
  where e.id = v_event
  for update;

  if v_event_row.id is null then
    raise exception 'Événement introuvable';
  end if;

  if v_event_row.active_extraction_key is not null then
    return v_event_row.active_extraction_key;
  end if;

  if v_event_row.status <> 'live' or v_event_row.actual_started_at is null then
    raise exception 'La partie doit être démarrée avant le tirage';
  end if;

  if clock_timestamp() < v_event_row.actual_started_at + interval '80 minutes' then
    raise exception 'La zone d''extraction sera révélée à START +80 minutes';
  end if;

  if v_event_row.actual_ends_at is not null
     and clock_timestamp() > v_event_row.actual_ends_at + interval '1 minute' then
    raise exception 'La partie est terminée';
  end if;

  select z.zone_key, z.name into v_key, v_name
  from public.zones z
  where z.event_id = v_event
    and z.zone_type = 'extraction'
  order by random()
  limit 1;

  if v_key is null then
    raise exception 'Aucune zone d''extraction configurée';
  end if;

  update public.events
  set active_extraction_key = v_key
  where id = v_event;

  select c.value into v_token
  from public.app_private_config c
  where c.key = 'push_dispatch_token';

  if v_token is not null then
    perform net.http_post(
      url := 'https://loqeiqfwiajvzbuhmycr.supabase.co/functions/v1/push-dispatch',
      headers := jsonb_build_object(
        'Content-Type','application/json',
        'x-dispatch-token',v_token
      ),
      body := jsonb_build_object(
        'mode','extraction',
        'eventId',v_event,
        'zoneKey',v_key,
        'zoneName',v_name
      ),
      timeout_milliseconds := 8000
    );
  end if;

  return v_key;
end;
$function$;

create or replace function public.reveal_due_extraction_zones()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_event record;
  v_key text;
  v_name text;
  v_token text;
  v_count integer := 0;
begin
  for v_event in
    select e.id
    from public.events e
    where e.status = 'live'
      and e.actual_started_at is not null
      and e.active_extraction_key is null
      and clock_timestamp() >= e.actual_started_at + interval '80 minutes'
      and (e.actual_ends_at is null or clock_timestamp() <= e.actual_ends_at + interval '1 minute')
    for update skip locked
  loop
    select z.zone_key, z.name into v_key, v_name
    from public.zones z
    where z.event_id = v_event.id
      and z.zone_type = 'extraction'
    order by random()
    limit 1;

    if v_key is null then
      continue;
    end if;

    update public.events
    set active_extraction_key = v_key
    where id = v_event.id
      and active_extraction_key is null;

    if found then
      v_count := v_count + 1;

      select c.value into v_token
      from public.app_private_config c
      where c.key = 'push_dispatch_token';

      if v_token is not null then
        perform net.http_post(
          url := 'https://loqeiqfwiajvzbuhmycr.supabase.co/functions/v1/push-dispatch',
          headers := jsonb_build_object(
            'Content-Type','application/json',
            'x-dispatch-token',v_token
          ),
          body := jsonb_build_object(
            'mode','extraction',
            'eventId',v_event.id,
            'zoneKey',v_key,
            'zoneName',v_name
          ),
          timeout_milliseconds := 8000
        );
      end if;
    end if;
  end loop;

  return v_count;
end;
$function$;

revoke execute on function public.reveal_due_extraction_zones() from public, anon, authenticated;

do $do$
declare
  v_jobid bigint;
begin
  select jobid into v_jobid
  from cron.job
  where jobname = 'evasion_extraction_reveal'
  limit 1;

  if v_jobid is not null then
    perform cron.unschedule(v_jobid);
  end if;

  perform cron.schedule(
    'evasion_extraction_reveal',
    '10 seconds',
    $cmd$select public.reveal_due_extraction_zones();$cmd$
  );
end;
$do$;

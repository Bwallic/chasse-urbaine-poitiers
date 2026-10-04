-- Évasion Urbaine — améliorations post-bêta.
-- Gestion joueurs, états des Cibles, fin automatique, notifications d'extraction.

alter table public.participants
  add column if not exists play_state text not null default 'free'
    check (play_state in ('free','capturing','prisoner')),
  add column if not exists play_state_updated_at timestamptz;

create or replace function public.set_my_target_state(p_state text)
returns text
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_id uuid;
begin
  if p_state not in ('free','capturing','prisoner') then
    raise exception 'État invalide';
  end if;

  select p.id into v_id
  from public.participants p
  where p.user_id = auth.uid() and p.active = true and p.role = 'target'
  limit 1;

  if v_id is null then raise exception 'Accès réservé aux Cibles'; end if;

  update public.participants
  set play_state = p_state, play_state_updated_at = clock_timestamp()
  where id = v_id;

  return p_state;
end;
$function$;

create or replace function public.my_target_state()
returns table(play_state text, updated_at timestamptz)
language sql
stable
security definer
set search_path = public
as $function$
  select p.play_state, p.play_state_updated_at
  from public.participants p
  where p.user_id = auth.uid() and p.active = true and p.role = 'target'
  limit 1
$function$;

create or replace function public.organizer_manage_list()
returns table(
  id uuid, pseudo text, role text, team text, active boolean,
  device_linked boolean, play_state text, is_self boolean
)
language sql
stable
security definer
set search_path = public
as $function$
  select p.id, p.pseudo, p.role, p.team, p.active,
         (p.user_id is not null),
         p.play_state,
         (p.user_id = auth.uid())
  from public.participants p
  where p.event_id = public.my_event_id()
    and public.my_role() = 'organizer'
  order by
    case p.role when 'organizer' then 1 when 'target' then 2 when 'hunter' then 3 else 4 end,
    p.pseudo
$function$;

create or replace function public.organizer_create_player(
  p_pseudo text, p_role text, p_team text, p_code text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_event uuid := public.my_event_id();
  v_id uuid;
  v_pseudo text := btrim(regexp_replace(coalesce(p_pseudo,''), '\s+', ' ', 'g'));
  v_code text := upper(btrim(coalesce(p_code,'')));
begin
  if public.my_role() <> 'organizer' then raise exception 'Accès organisateur requis'; end if;
  if length(v_pseudo) < 2 or length(v_pseudo) > 24 then raise exception 'Pseudo : 2 à 24 caractères'; end if;
  if p_role not in ('target','hunter','organizer') then raise exception 'Rôle invalide'; end if;
  if length(v_code) < 4 or length(v_code) > 24 then raise exception 'Code : 4 à 24 caractères'; end if;

  insert into public.participants(event_id,pseudo,role,team,active,play_state)
  values (v_event,v_pseudo,p_role,nullif(btrim(coalesce(p_team,'')),''),true,'free')
  returning id into v_id;

  insert into public.access_codes(participant_id,code_hash)
  values (v_id, encode(digest(v_code,'sha256'),'hex'));

  return v_id;
exception
  when unique_violation then raise exception 'Pseudo ou code déjà utilisé';
end;
$function$;

create or replace function public.organizer_update_player(
  p_participant_id uuid, p_pseudo text, p_role text, p_team text,
  p_active boolean, p_new_code text default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_event uuid := public.my_event_id();
  v_self boolean := false;
  v_pseudo text := btrim(regexp_replace(coalesce(p_pseudo,''), '\s+', ' ', 'g'));
  v_code text := upper(btrim(coalesce(p_new_code,'')));
begin
  if public.my_role() <> 'organizer' then raise exception 'Accès organisateur requis'; end if;
  if length(v_pseudo) < 2 or length(v_pseudo) > 24 then raise exception 'Pseudo : 2 à 24 caractères'; end if;
  if p_role not in ('target','hunter','organizer') then raise exception 'Rôle invalide'; end if;

  select (p.user_id = auth.uid()) into v_self
  from public.participants p
  where p.id = p_participant_id and p.event_id = v_event;

  if not found then raise exception 'Participant introuvable'; end if;
  if v_self and (p_role <> 'organizer' or not p_active) then
    raise exception 'Impossible de retirer ton propre accès Organisateur';
  end if;

  update public.participants
  set pseudo = v_pseudo,
      role = p_role,
      team = nullif(btrim(coalesce(p_team,'')),''),
      active = p_active,
      play_state = case when p_role = 'target' then play_state else 'free' end
  where id = p_participant_id and event_id = v_event;

  if p_new_code is not null then
    if length(v_code) < 4 or length(v_code) > 24 then raise exception 'Code : 4 à 24 caractères'; end if;
    insert into public.access_codes(participant_id,code_hash)
    values (p_participant_id, encode(digest(v_code,'sha256'),'hex'))
    on conflict (participant_id) do update set code_hash = excluded.code_hash;
  end if;

  return true;
exception
  when unique_violation then raise exception 'Pseudo ou code déjà utilisé';
end;
$function$;

create or replace function public.organizer_release_player(p_participant_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_event uuid := public.my_event_id();
  v_self boolean := false;
begin
  if public.my_role() <> 'organizer' then raise exception 'Accès organisateur requis'; end if;

  select (p.user_id = auth.uid()) into v_self
  from public.participants p
  where p.id = p_participant_id and p.event_id = v_event;

  if not found then raise exception 'Participant introuvable'; end if;
  if v_self then raise exception 'Utilise RESET TOUS LES ACCÈS pour libérer ton propre appareil'; end if;

  delete from public.push_subscriptions where participant_id = p_participant_id;
  update public.participants set user_id = null
  where id = p_participant_id and event_id = v_event;

  return true;
end;
$function$;

create or replace function public.finish_due_events()
returns integer
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_count integer;
begin
  update public.events
  set status = 'finished'
  where status = 'live'
    and actual_ends_at is not null
    and actual_ends_at + interval '60 seconds' <= clock_timestamp();

  get diagnostics v_count = row_count;
  return v_count;
end;
$function$;

create or replace function public.sync_my_event_state()
returns table(status text, actual_started_at timestamptz, actual_ends_at timestamptz)
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_event uuid := public.my_event_id();
begin
  if v_event is null then raise exception 'Participant non associé'; end if;

  update public.events
  set status = 'finished'
  where id = v_event and status = 'live'
    and actual_ends_at is not null
    and actual_ends_at + interval '60 seconds' <= clock_timestamp();

  return query
  select e.status, e.actual_started_at, e.actual_ends_at
  from public.events e where e.id = v_event;
end;
$function$;

create or replace function public.draw_extraction_zone()
returns text
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_event uuid := public.my_event_id();
  v_key text;
  v_name text;
  v_token text;
begin
  if public.my_role() <> 'organizer' then raise exception 'Accès organisateur requis'; end if;

  select active_extraction_key into v_key from public.events where id = v_event;
  if v_key is not null then return v_key; end if;

  select z.zone_key, z.name into v_key, v_name
  from public.zones z
  where z.event_id = v_event and z.zone_type = 'extraction'
  order by random()
  limit 1;

  if v_key is null then raise exception 'Aucune zone d''extraction configurée'; end if;

  update public.events set active_extraction_key = v_key where id = v_event;

  select value into v_token from public.app_private_config where key = 'push_dispatch_token';

  if v_token is not null then
    perform net.http_post(
      url := 'https://loqeiqfwiajvzbuhmycr.supabase.co/functions/v1/push-dispatch',
      headers := jsonb_build_object('Content-Type','application/json','x-dispatch-token',v_token),
      body := jsonb_build_object(
        'mode','extraction','eventId',v_event,'zoneKey',v_key,'zoneName',v_name
      ),
      timeout_milliseconds := 8000
    );
  end if;

  return v_key;
end;
$function$;

grant execute on function public.set_my_target_state(text) to authenticated;
grant execute on function public.my_target_state() to authenticated;
grant execute on function public.organizer_manage_list() to authenticated;
grant execute on function public.organizer_create_player(text,text,text,text) to authenticated;
grant execute on function public.organizer_update_player(uuid,text,text,text,boolean,text) to authenticated;
grant execute on function public.organizer_release_player(uuid) to authenticated;
grant execute on function public.sync_my_event_state() to authenticated;
revoke all on function public.finish_due_events() from public, anon, authenticated;

do $$
begin
  if not exists (select 1 from cron.job where jobname = 'evasion_finish_events') then
    perform cron.schedule('evasion_finish_events','* * * * *','select public.finish_due_events();');
  end if;
end $$;

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
  select starts_at into v_starts_at from public.events where id = v_event_id;
  if v_starts_at is null then raise exception 'Événement introuvable'; end if;

  delete from public.push_jobs where event_id = v_event_id;
  delete from public.pings where event_id = v_event_id;
  update public.participants set play_state='free', play_state_updated_at=null where event_id=v_event_id;
  update public.ping_slots set scheduled_at=v_starts_at+make_interval(mins=>ordinal*20) where event_id=v_event_id;
  update public.events set actual_started_at=null,actual_ends_at=null,active_extraction_key=null,status='scheduled'
  where id=v_event_id;
  return true;
end;
$function$;

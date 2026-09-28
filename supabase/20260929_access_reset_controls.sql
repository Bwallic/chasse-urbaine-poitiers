-- Contrôles organisateur pour libérer les codes déjà associés à des appareils.

create or replace function public.reset_player_access()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid := public.my_event_id();
  v_count integer := 0;
begin
  if public.my_role() <> 'organizer' then
    raise exception 'Accès organisateur requis';
  end if;

  update public.participants
     set user_id = null
   where event_id = v_event_id
     and role in ('target', 'hunter')
     and user_id is not null;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function public.reset_all_access()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid := public.my_event_id();
  v_count integer := 0;
begin
  if public.my_role() <> 'organizer' then
    raise exception 'Accès organisateur requis';
  end if;

  update public.participants
     set user_id = null
   where event_id = v_event_id
     and user_id is not null;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke execute on function public.reset_player_access() from public, anon;
revoke execute on function public.reset_all_access() from public, anon;
grant execute on function public.reset_player_access() to authenticated;
grant execute on function public.reset_all_access() to authenticated;

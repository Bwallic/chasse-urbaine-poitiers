-- Share target gameplay states according to player role.
-- Hunters see every active target state.
-- Targets see only targets currently in prison.
-- Organizers see every active target state.

create or replace function public.visible_target_states()
returns table(
  id uuid,
  pseudo text,
  play_state text,
  updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $function$
declare
  v_event uuid := public.my_event_id();
  v_role text := public.my_role();
begin
  if v_event is null or v_role is null then
    raise exception 'Participant non associé';
  end if;

  if v_role = 'hunter' or v_role = 'organizer' then
    return query
      select p.id, p.pseudo, p.play_state, p.play_state_updated_at
      from public.participants p
      where p.event_id = v_event
        and p.active = true
        and p.role = 'target'
      order by p.pseudo;
  elsif v_role = 'target' then
    return query
      select p.id, p.pseudo, p.play_state, p.play_state_updated_at
      from public.participants p
      where p.event_id = v_event
        and p.active = true
        and p.role = 'target'
        and p.play_state = 'prisoner'
      order by p.pseudo;
  end if;

  return;
end;
$function$;

grant execute on function public.visible_target_states() to authenticated;

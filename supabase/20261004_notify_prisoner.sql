-- Notify active players when a Cible enters prison.

create or replace function public.set_my_target_state(p_state text)
returns text
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_id uuid;
  v_event uuid;
  v_pseudo text;
  v_old_state text;
  v_token text;
begin
  if p_state not in ('free','capturing','prisoner') then
    raise exception 'État invalide';
  end if;

  select p.id, p.event_id, p.pseudo, p.play_state
    into v_id, v_event, v_pseudo, v_old_state
  from public.participants p
  where p.user_id = auth.uid()
    and p.active = true
    and p.role = 'target'
  limit 1;

  if v_id is null then
    raise exception 'Accès réservé aux Cibles';
  end if;

  update public.participants
  set play_state = p_state,
      play_state_updated_at = clock_timestamp()
  where id = v_id;

  if p_state = 'prisoner' and coalesce(v_old_state,'free') <> 'prisoner' then
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
          'mode','prisoner',
          'eventId',v_event,
          'participantId',v_id,
          'pseudo',v_pseudo
        ),
        timeout_milliseconds := 8000
      );
    end if;
  end if;

  return p_state;
end;
$function$;

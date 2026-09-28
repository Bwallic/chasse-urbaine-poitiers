-- Corrige la résolution de digest() dans la fonction claim_participant.
-- Sur Supabase, pgcrypto est disponible dans le schéma extensions.

create or replace function public.claim_participant(p_code text)
returns table (
  id uuid,
  event_id uuid,
  pseudo text,
  role text,
  team text,
  active boolean
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid uuid := auth.uid();
  v_hash text;
  v_participant public.participants%rowtype;
begin
  if v_uid is null then
    raise exception 'Session anonyme requise';
  end if;

  v_hash := encode(digest(upper(trim(p_code)), 'sha256'), 'hex');

  select p.* into v_participant
  from public.participants p
  join public.access_codes c on c.participant_id = p.id
  where c.code_hash = v_hash
  limit 1;

  if v_participant.id is null then
    raise exception 'Code invalide';
  end if;

  if not v_participant.active then
    raise exception 'Participant désactivé';
  end if;

  if v_participant.user_id is null then
    update public.participants
      set user_id = v_uid
      where public.participants.id = v_participant.id;
  elsif v_participant.user_id <> v_uid then
    raise exception 'Code déjà utilisé sur un autre appareil';
  end if;

  return query
    select p.id, p.event_id, p.pseudo, p.role, p.team, p.active
    from public.participants p
    where p.id = v_participant.id;
end;
$$;

revoke execute on function public.claim_participant(text) from public, anon;
grant execute on function public.claim_participant(text) to authenticated;

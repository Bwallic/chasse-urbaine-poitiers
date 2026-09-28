-- Reconnexion automatique d'un participant à partir de sa session Supabase persistée.

create or replace function public.resume_my_participant()
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
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    return;
  end if;

  return query
  select p.id, p.event_id, p.pseudo, p.role, p.team, p.active
  from public.participants p
  where p.user_id = v_uid
    and p.active = true
  limit 1;
end;
$$;

revoke execute on function public.resume_my_participant() from public, anon;
grant execute on function public.resume_my_participant() to authenticated;

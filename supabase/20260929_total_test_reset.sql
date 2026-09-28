-- Reset complet de la session de test : pings, départ, extraction, associations appareils et pseudos.

create or replace function public.reset_total_test()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid := public.my_event_id();
  v_starts_at timestamptz;
  v_count integer := 0;
begin
  if public.my_role() <> 'organizer' then
    raise exception 'Accès organisateur requis';
  end if;

  select starts_at into v_starts_at
  from public.events
  where id = v_event_id;

  if v_starts_at is null then
    raise exception 'Événement introuvable';
  end if;

  delete from public.pings
  where event_id = v_event_id;

  update public.ping_slots s
     set scheduled_at = v_starts_at + make_interval(mins => s.ordinal * 30)
   where s.event_id = v_event_id;

  update public.events
     set actual_started_at = null,
         actual_ends_at = null,
         active_extraction_key = null,
         status = 'scheduled'
   where id = v_event_id;

  with ranked as (
    select id,
           role,
           row_number() over (partition by role order by id) as rn
    from public.participants
    where event_id = v_event_id
  )
  update public.participants p
     set user_id = null,
         pseudo = case r.role
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
$$;

revoke execute on function public.reset_total_test() from public, anon;
grant execute on function public.reset_total_test() to authenticated;

-- Player/game RPCs require a signed-in Supabase session.
-- Anonymous sign-in is used by the app, which receives the authenticated role.

revoke all on function public.my_required_hunter_ping_status() from public, anon;
revoke all on function public.my_target_state() from public, anon;
revoke all on function public.organizer_create_player(text,text,text,text) from public, anon;
revoke all on function public.organizer_manage_list() from public, anon;
revoke all on function public.organizer_release_player(uuid) from public, anon;
revoke all on function public.organizer_update_player(uuid,text,text,text,boolean,text) from public, anon;
revoke all on function public.set_my_target_state(text) from public, anon;
revoke all on function public.submit_hunter_ping(double precision,double precision,double precision) from public, anon;
revoke all on function public.submit_required_hunter_ping(double precision,double precision,double precision) from public, anon;
revoke all on function public.sync_my_event_state() from public, anon;
revoke all on function public.visible_hunter_pings() from public, anon;
revoke all on function public.visible_required_hunter_pings() from public, anon;
revoke all on function public.visible_target_states() from public, anon;

grant execute on function public.my_required_hunter_ping_status() to authenticated;
grant execute on function public.my_target_state() to authenticated;
grant execute on function public.organizer_create_player(text,text,text,text) to authenticated;
grant execute on function public.organizer_manage_list() to authenticated;
grant execute on function public.organizer_release_player(uuid) to authenticated;
grant execute on function public.organizer_update_player(uuid,text,text,text,boolean,text) to authenticated;
grant execute on function public.set_my_target_state(text) to authenticated;
grant execute on function public.submit_hunter_ping(double precision,double precision,double precision) to authenticated;
grant execute on function public.submit_required_hunter_ping(double precision,double precision,double precision) to authenticated;
grant execute on function public.sync_my_event_state() to authenticated;
grant execute on function public.visible_hunter_pings() to authenticated;
grant execute on function public.visible_required_hunter_pings() to authenticated;
grant execute on function public.visible_target_states() to authenticated;

revoke all on function public.save_push_subscription(text,text,text,text) from public, anon;
revoke all on function public.remove_my_push_subscription() from public, anon;
revoke all on function public.my_push_subscription_status() from public, anon;
revoke all on function public.ack_push_notification(uuid) from public, anon;
revoke all on function public.organizer_start_check_status() from public, anon;

grant execute on function public.save_push_subscription(text,text,text,text) to authenticated;
grant execute on function public.remove_my_push_subscription() to authenticated;
grant execute on function public.my_push_subscription_status() to authenticated;
grant execute on function public.ack_push_notification(uuid) to authenticated;
grant execute on function public.organizer_start_check_status() to authenticated;

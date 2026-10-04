-- Stability/performance indexes added after final gameplay changes.

create index if not exists hunter_pings_participant_idx
  on public.hunter_pings(participant_id);

create index if not exists hunter_required_pings_participant_idx
  on public.hunter_required_pings(participant_id);

create index if not exists pings_slot_idx
  on public.pings(slot_id);

create index if not exists push_deliveries_participant_idx
  on public.push_deliveries(participant_id);

create index if not exists push_jobs_slot_idx
  on public.push_jobs(slot_id);

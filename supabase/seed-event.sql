-- Événement : 28 octobre 2026, Poitiers.
-- Le 28/10/2026, Poitiers est en UTC+1 après le passage à l'heure d'hiver.

insert into public.events (id, name, starts_at, ends_at, status)
values (
  '11111111-1111-1111-1111-111111111111',
  'Chasse Urbaine — Poitiers',
  '2026-10-28 20:00:00+01',
  '2026-10-28 22:00:00+01',
  'scheduled'
)
on conflict (id) do update set
  name = excluded.name,
  starts_at = excluded.starts_at,
  ends_at = excluded.ends_at;

insert into public.zones (event_id, zone_key, name, zone_type, sort_order) values
('11111111-1111-1111-1111-111111111111','play-area','Périmètre de jeu','perimeter',0),
('11111111-1111-1111-1111-111111111111','extraction-1','France 3','extraction',1),
('11111111-1111-1111-1111-111111111111','extraction-2','Triangle d''or','extraction',2),
('11111111-1111-1111-1111-111111111111','extraction-3','Parc de la Cassette','extraction',3),
('11111111-1111-1111-1111-111111111111','extraction-4','Parking de la gare','extraction',4),
('11111111-1111-1111-1111-111111111111','extraction-5','Parc des Troènes','extraction',5),
('11111111-1111-1111-1111-111111111111','prison','Prison — Place de la Liberté','prison',10)
on conflict (event_id, zone_key) do update set name=excluded.name, zone_type=excluded.zone_type, sort_order=excluded.sort_order;

insert into public.ping_slots (event_id, label, scheduled_at, ordinal) values
('11111111-1111-1111-1111-111111111111','20:30','2026-10-28 20:30:00+01',1),
('11111111-1111-1111-1111-111111111111','21:00','2026-10-28 21:00:00+01',2),
('11111111-1111-1111-1111-111111111111','21:30','2026-10-28 21:30:00+01',3)
on conflict (event_id, ordinal) do update set label=excluded.label, scheduled_at=excluded.scheduled_at;

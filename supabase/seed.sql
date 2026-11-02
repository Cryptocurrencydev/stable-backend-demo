-- =============================================================================
-- Local development seed. ALL DATA IS FICTIONAL.
-- Demo logins (local stack only, never use on a hosted project):
--   owner@example.test / trainer@example.test / manager@example.test / viewer@example.test
--   password: local-demo-only
-- =============================================================================

do $$
declare
  u record;
begin
  for u in select * from (values
    ('d0000000-0000-4000-8000-000000000001'::uuid, 'owner@example.test'),
    ('d0000000-0000-4000-8000-000000000002'::uuid, 'trainer@example.test'),
    ('d0000000-0000-4000-8000-000000000003'::uuid, 'manager@example.test'),
    ('d0000000-0000-4000-8000-000000000004'::uuid, 'viewer@example.test')
  ) v(id, email)
  loop
    insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                            raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                            confirmation_token, recovery_token, email_change, email_change_token_new)
    values ('00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated', u.email,
            extensions.crypt('local-demo-only', extensions.gen_salt('bf')), now(),
            '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', '', '');
    insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), u.id, u.id::text,
            jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true),
            'email', now(), now(), now());
  end loop;
end $$;

-- Stable ------------------------------------------------------------------------
insert into private.stables (id, name, city, country, created_by) values
  ('e0000000-0000-4000-8000-000000000001', 'Lindenhof Riding Centre', 'Celle', 'DE', 'd0000000-0000-4000-8000-000000000003');

-- Horses ------------------------------------------------------------------------
insert into private.horses (id, name, breed, birth_year, color, stable_id, created_by) values
  ('f0000000-0000-4000-8000-000000000001', 'Nordwind',   'Hanoverian', 2014, 'bay',      'e0000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000001'),
  ('f0000000-0000-4000-8000-000000000002', 'Kleine Fee', 'Haflinger',  2017, 'chestnut', 'e0000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000001'),
  ('f0000000-0000-4000-8000-000000000003', 'Sturmvogel', 'Trakehner',  2011, 'grey',     null,                                   'd0000000-0000-4000-8000-000000000002');

insert into private.memberships (user_id, horse_id, stable_id, role) values
  ('d0000000-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000001', null, 'owner'),
  ('d0000000-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000002', null, 'owner'),
  ('d0000000-0000-4000-8000-000000000002', 'f0000000-0000-4000-8000-000000000003', null, 'owner'),
  ('d0000000-0000-4000-8000-000000000002', 'f0000000-0000-4000-8000-000000000001', null, 'trainer'),
  ('d0000000-0000-4000-8000-000000000004', 'f0000000-0000-4000-8000-000000000001', null, 'viewer'),
  ('d0000000-0000-4000-8000-000000000003', null, 'e0000000-0000-4000-8000-000000000001', 'owner');

-- Training + tasks ---------------------------------------------------------------
insert into private.training_logs (horse_id, author_id, started_at, duration_minutes, discipline, intensity, notes) values
  ('f0000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000002', now() - interval '3 days', 45, 'dressage', 'moderate', 'Worked on transitions, relaxed in the contact.'),
  ('f0000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000001', now() - interval '1 day',  60, 'hacking',  'light',    'Forest loop, calm.'),
  ('f0000000-0000-4000-8000-000000000003', 'd0000000-0000-4000-8000-000000000002', now() - interval '2 days', 35, 'jumping',  'hard',     'Grid work, 4 fences.');

insert into private.stable_tasks (stable_id, horse_id, title, due_at, assigned_to, created_by) values
  ('e0000000-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000001', 'Farrier visit: front shoes', now() + interval '2 days', 'd0000000-0000-4000-8000-000000000003', 'd0000000-0000-4000-8000-000000000003'),
  ('e0000000-0000-4000-8000-000000000001', null, 'Order hay for November', now() + interval '5 days', null, 'd0000000-0000-4000-8000-000000000003');

-- Products with a simple Digital Product Passport ---------------------------------
insert into private.products (qr_code, gtin, name, manufacturer, category, passport) values
  ('LBX-SADDLE-0001', '04260000000011', 'Allround Saddle 17"', 'Fictional Saddlery GmbH', 'saddle',
   '{"model":"AR-17","batch":"2026-09-A","manufactured_on":"2026-09-14","country_of_origin":"DE",
     "materials":[{"name":"cowhide leather","share_pct":70},{"name":"beech wood tree","share_pct":20},{"name":"steel","share_pct":10}],
     "care":"Clean with saddle soap, oil every 4 weeks.","repair":"Re-flocking available from manufacturer.",
     "end_of_life":"Return to manufacturer take-back programme.","co2e_kg":38.5}'),
  ('LBX-BLANKET-0002', '04260000000028', 'Turnout Blanket 145cm', 'Fictional Textiles BV', 'blanket',
   '{"model":"TB-145","batch":"2026-08-C","country_of_origin":"NL",
     "materials":[{"name":"recycled polyester","share_pct":85},{"name":"nylon","share_pct":15}],
     "care":"Machine wash 30°C.","end_of_life":"Textile recycling.","co2e_kg":12.1}'),
  ('LBX-SENSOR-0003', '04260000000035', 'Stall Climate Sensor', 'Fictional Devices Oy', 'sensor',
   '{"model":"SC-1","firmware":"1.4.2","country_of_origin":"FI","battery":"CR2477","end_of_life":"WEEE e-waste."}');

-- Sensor + a day of hourly readings ------------------------------------------------
insert into private.sensors (id, horse_id, device_id, label, created_by) values
  ('c0000000-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000001', 'SC1-00A4-7F21', 'Nordwind stall', 'd0000000-0000-4000-8000-000000000001');

insert into private.sensor_readings (sensor_id, device_id, recorded_at, temperature_c, humidity_pct)
select 'c0000000-0000-4000-8000-000000000001', 'SC1-00A4-7F21',
       date_trunc('hour', now()) - make_interval(hours => g),
       round((14 + 4 * sin(g / 24.0 * 2 * pi()))::numeric, 2),
       round((65 + 10 * cos(g / 24.0 * 2 * pi()))::numeric, 2)
from generate_series(1, 24) g;

-- Delta sync: cursor pagination, updates, soft-delete tombstones, access
-- gained/lost, and visibility rules.
begin;
select plan(19);
select tests.create_world();

-- ---------------------------------------------------------------- initial full sync
select tests.authenticate_as('alice');
create temp table full1 as select * from api.sync_changes(null, null, 1000);

select is((select count(*)::int from full1 where entity = 'horse'), 1, 'initial sync: 1 horse');
select is((select count(*)::int from full1 where entity = 'training_log'), 2, 'initial sync: 2 training logs');
select is((select count(*)::int from full1 where entity = 'sensor'), 1, 'initial sync: 1 sensor');
select is((select count(*)::int from full1 where entity = 'product'), 1, 'initial sync: 1 product');
select is((select count(*)::int from full1 where entity = 'membership'), 1, 'initial sync: own memberships only');
select is((select count(*)::int from full1 where entity in ('stable', 'stable_task')), 0, 'no stable data for a horse-only member');
select is((select count(*)::int from full1 where deleted), 0, 'no tombstones initially');

-- ---------------------------------------------------------------- pagination == full result, no gaps/overlap
create temp table paged (entity text, id uuid, sync_ts timestamptz, deleted boolean, data jsonb);
do $$
declare v_ts timestamptz; v_id uuid; n int;
begin
  loop
    insert into paged select * from api.sync_changes(v_ts, v_id, 2);
    get diagnostics n = row_count;
    exit when n = 0;
    select p.sync_ts, p.id into v_ts, v_id from paged p order by p.sync_ts desc, p.id desc limit 1;
  end loop;
end $$;
select results_eq('select entity, id from paged order by sync_ts, id', 'select entity, id from full1 order by sync_ts, id',
  'paging with limit 2 yields exactly the full result, in order');
select is((select count(*) from paged), (select count(distinct id) from paged), 'no row delivered twice');

create temp table cursor1 as select sync_ts, id from full1 order by sync_ts desc, id desc limit 1;
select is((select count(*)::int from api.sync_changes((select sync_ts from cursor1), (select id from cursor1))), 0,
  'caught up: nothing after the last cursor');
reset role;

-- ---------------------------------------------------------------- changes after the cursor
select tests.authenticate_as('alice');
select api.update_horse(gen_random_uuid(), tests.h('thunder'), 'Thunder Storm');
select api.delete_training_log(gen_random_uuid(), '40000000-0000-4000-8000-000000000002');
create temp table delta1 as select * from api.sync_changes((select sync_ts from cursor1), (select id from cursor1));

select is((select data ->> 'name' from delta1 where entity = 'horse'), 'Thunder Storm', 'edited horse is delivered');
select ok((select deleted and data is null from delta1 where id = '40000000-0000-4000-8000-000000000002'),
  'soft-deleted log arrives as a tombstone with no payload');
select is((select count(*)::int from delta1), 2, 'only the two changed rows are delivered');
reset role;

-- ---------------------------------------------------------------- visibility rules hold in sync too
select tests.authenticate_as('carol');
select is((select count(*)::int from api.sync_changes() where entity = 'training_log'), 0,
  'viewer never receives training logs through sync');
reset role;

select tests.authenticate_as('dave');
select is((select count(*)::int from api.sync_changes()), 0, 'stranger receives nothing');
create temp table dave_cursor as select clock_timestamp() as ts;
reset role;

-- ---------------------------------------------------------------- access gained: old rows still arrive
select tests.authenticate_as('alice');
select api.grant_membership(gen_random_uuid(), 'horse', tests.h('thunder'), tests.u('dave'), 'rider');
reset role;

select tests.authenticate_as('dave');
create temp table dave_delta as select * from api.sync_changes((select ts from dave_cursor), null);
select ok(exists (select 1 from dave_delta where entity = 'horse' and id = tests.h('thunder')),
  'newly granted horse is delivered even though it was last edited before the cursor');
select ok(exists (select 1 from dave_delta where entity = 'training_log'),
  'its existing training logs are delivered too');
create temp table dave_cursor2 as select clock_timestamp() as ts;
reset role;

-- ---------------------------------------------------------------- access lost: membership tombstone
select tests.authenticate_as('alice');
select api.revoke_membership(gen_random_uuid(),
  (select id from api.memberships where user_id = tests.u('dave') and resource_id = tests.h('thunder')));
reset role;

select tests.authenticate_as('dave');
select ok(
  (select deleted from api.sync_changes((select ts from dave_cursor2), null)
    where entity = 'membership' and data ->> 'resource_id' = tests.h('thunder')::text),
  'revoked access arrives as a membership tombstone so the app can purge local data');
reset role;

-- ---------------------------------------------------------------- stable inheritance in sync
select tests.authenticate_as('erin');
create temp table erin_cursor as select clock_timestamp() as ts;
reset role;
-- bob joins Oak as a trainer (needed to board a horse there), then boards Pepper
insert into private.memberships (user_id, stable_id, role) values (tests.u('bob'), tests.s('oak'), 'trainer');
select tests.authenticate_as('bob');
select api.move_horse(gen_random_uuid(), tests.h('pepper'), tests.s('oak'));
reset role;

select tests.authenticate_as('erin');
select ok(exists (select 1 from api.sync_changes((select ts from erin_cursor), null) where entity = 'horse' and id = tests.h('pepper')),
  'horse boarded at the stable shows up in the manager''s next sync');
reset role;

select * from finish();
rollback;

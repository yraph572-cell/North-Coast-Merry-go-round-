-- North Coast Merry-Go-Round: run once in Supabase SQL Editor.
create table profiles(id uuid primary key references auth.users on delete cascade, email text, name text,
  role text not null default 'user' check(role in('user','admin')), created_at timestamptz default now());

create function is_admin() returns boolean language sql security definer stable set search_path=public as
$$ select exists(select 1 from profiles where id=auth.uid() and role='admin') $$;

create function handle_new_user() returns trigger language plpgsql security definer set search_path=public as
$$ begin insert into profiles(id,email,name) values(new.id,new.email,split_part(new.email,'@',1)); return new; end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function handle_new_user();

create table teams(id uuid primary key default gen_random_uuid(), name text not null unique, logo_url text,
  location text, description text, active boolean not null default true, created_at timestamptz default now());
create table matchdays(id uuid primary key default gen_random_uuid(), number int not null unique, name text not null,
  date date, status text not null default 'upcoming', created_at timestamptz default now());
create table matches(id uuid primary key default gen_random_uuid(),
  matchday_id uuid not null references matchdays on delete restrict,
  team1_id uuid not null references teams on delete restrict, team2_id uuid not null references teams on delete restrict,
  venue text, scheduled_date date, scheduled_time time,
  status text not null default 'scheduled' check(status in('scheduled','live','completed','postponed','cancelled')),
  created_at timestamptz default now(), updated_at timestamptz default now(),
  check(team1_id<>team2_id), unique(matchday_id,team1_id,team2_id));
create index on matches(matchday_id); create index on matches(team1_id); create index on matches(team2_id);
create table match_sets(id uuid primary key default gen_random_uuid(), match_id uuid not null references matches on delete cascade,
  set_number int not null check(set_number between 1 and 5), team1_score int not null check(team1_score>=0), team2_score int not null check(team2_score>=0),
  unique(match_id,set_number),
  check(greatest(team1_score,team2_score)>=case when set_number=5 then 15 else 25 end
    and abs(team1_score-team2_score)>=2
    and (greatest(team1_score,team2_score)=case when set_number=5 then 15 else 25 end or abs(team1_score-team2_score)=2)));
create index on match_sets(match_id);
create table announcements(id uuid primary key default gen_random_uuid(), title text not null, content text, image_url text,
  published boolean not null default false, created_by uuid references profiles, created_at timestamptz default now(), updated_at timestamptz default now());
create table competition_settings(id int primary key default 1 check(id=1), competition_name text, location text, frequency text,
  points_rules jsonb not null default '{"win_3_0":3,"win_3_1":3,"win_3_2":2,"loss_2_3":1,"loss_other":0}', updated_at timestamptz default now());

-- A match can only be "completed" when one team has exactly 3 sets and the other fewer.
create function check_completed() returns trigger language plpgsql as $$
declare a int; b int; begin
  if new.status='completed' then
    select count(*) filter(where team1_score>team2_score), count(*) filter(where team2_score>team1_score) into a,b from match_sets where match_id=new.id;
    if not((a=3 and b<3) or (b=3 and a<3)) then raise exception 'Completed match needs a valid best-of-5 result'; end if;
  end if; new.updated_at=now(); return new; end $$;
create trigger trg_completed before insert or update on matches for each row execute function check_completed();

-- Standings are always computed from completed matches (nothing stored, nothing double counted).
create view standings as
with r as (select m.id, m.team1_id t1, m.team2_id t2,
    count(*) filter(where s.team1_score>s.team2_score) s1, count(*) filter(where s.team2_score>s.team1_score) s2
  from matches m join match_sets s on s.match_id=m.id where m.status='completed' group by m.id,m.team1_id,m.team2_id),
 side as (select t1 team_id,s1 sw,s2 sl from r union all select t2,s2,s1 from r),
 cfg as (select points_rules p from competition_settings limit 1)
select t.id team_id, t.name, count(side.team_id)::int played,
  count(*) filter(where side.sw>side.sl)::int won, count(*) filter(where side.sw<side.sl)::int lost,
  coalesce(sum(side.sw),0)::int sets_won, coalesce(sum(side.sl),0)::int sets_lost,
  (coalesce(sum(side.sw),0)-coalesce(sum(side.sl),0))::int set_diff,
  coalesce(sum(case when side.sw=3 and side.sl<=1 then coalesce((cfg.p->>'win_3_0')::int,3)
    when side.sw=3 then coalesce((cfg.p->>'win_3_2')::int,2)
    when side.sl=3 and side.sw=2 then coalesce((cfg.p->>'loss_2_3')::int,1) else 0 end),0)::int points
from teams t left join side on side.team_id=t.id left join cfg on true where t.active group by t.id,t.name;
grant select on standings to anon,authenticated;

-- RLS
alter table profiles enable row level security; alter table teams enable row level security; alter table matchdays enable row level security;
alter table matches enable row level security; alter table match_sets enable row level security;
alter table announcements enable row level security; alter table competition_settings enable row level security;
create policy "own profile" on profiles for select using(id=auth.uid() or is_admin());
create policy "admin manages profiles" on profiles for update using(is_admin()) with check(is_admin());
do $$ declare t text; begin foreach t in array array['teams','matchdays','matches','match_sets','competition_settings'] loop
  execute format('create policy "public read" on %I for select using(true)',t);
  execute format('create policy "admin write" on %I for all using(is_admin()) with check(is_admin())',t); end loop; end $$;
create policy "read published" on announcements for select using(published or is_admin());
create policy "admin write" on announcements for all using(is_admin()) with check(is_admin());

insert into storage.buckets(id,name,public) values('media','media',true) on conflict do nothing;
create policy "media read" on storage.objects for select using(bucket_id='media');
create policy "media admin write" on storage.objects for all using(bucket_id='media' and is_admin()) with check(bucket_id='media' and is_admin());

insert into competition_settings(id,competition_name,location,frequency) values(1,'North Coast Merry-Go-Round','North Coast, Mombasa, Kenya','Every fortnight');
insert into teams(name) values('Kongowea'),('Bamburi'),('Nyali team'),('Bahari'),('Nams'),('Texas'),('AIC Bombolulu'),('VoK'),
 ('Milele'),('Shimo Prisons'),('Dairy VC'),('Mariakani Lions'),('Twinscan'),('Kadzandani'),('Annex');
-- After you sign up once, make yourself admin:
-- update profiles set role='admin' where email='YOUR_EMAIL';

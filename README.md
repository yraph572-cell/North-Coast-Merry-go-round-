# North Coast Merry-Go-Round
Static site (HTML/JS) + Supabase (Postgres, Auth, RLS, Storage). Deploy on Netlify.
1. Supabase: create project, run `supabase/schema.sql` in the SQL Editor.
2. Authentication > Users: add your admin user (email + password, auto-confirm), then run:
   `update profiles set role='admin' where email='YOU@EMAIL';`
3. Put the project URL and anon key in `config.js`.
4. Push to GitHub, connect the repo in Netlify (publish dir `.`, no build command). `netlify.toml` handles /fixtures, /admin etc. on refresh.
Admins are enforced by RLS (`is_admin()`), not by hiding buttons.

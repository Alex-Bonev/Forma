-- My Vibes (VibeLibrary): saved aesthetic profiles, mirrored like rooms and objects (see 20261018062400_library.sql).
--   saved_vibes.doc = SavedVibe (name, styles, mood, colors, materials, description, custom instructions, dates)
--   files           = manifest of the vibe's inspiration photos, stored under <owner_id>/vibes/<id>/ in `library`
-- Same rules: owner-scoped RLS, tombstones instead of deletes, last writer wins via library_last_writer_wins().

create table public.saved_vibes (
  id uuid primary key,
  owner_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  updated_at timestamptz not null,
  deleted_at timestamptz,
  doc jsonb not null check (pg_column_size(doc) <= 1048576),
  files jsonb not null default '{}' check (pg_column_size(files) <= 262144)
);

create index saved_vibes_owner_id_idx on public.saved_vibes (owner_id);

create trigger saved_vibes_last_writer_wins before insert or update on public.saved_vibes
  for each row execute function public.library_last_writer_wins();

alter table public.saved_vibes enable row level security;

revoke all on public.saved_vibes from anon;
revoke delete, truncate on public.saved_vibes from authenticated;

create policy "Owners read their vibes" on public.saved_vibes
  for select to authenticated using ((select auth.uid()) = owner_id);
create policy "Owners add vibes" on public.saved_vibes
  for insert to authenticated with check ((select auth.uid()) = owner_id);
create policy "Owners change their vibes" on public.saved_vibes
  for update to authenticated
  using ((select auth.uid()) = owner_id)
  with check ((select auth.uid()) = owner_id);

-- Cloud copy of the app's library (ProjectStore). The app stays local-first: Application Support is the working
-- copy RealityKit loads from, and CloudSync mirrors it here.
--
-- Rows hold the app's Codable documents as jsonb, so a new optional Swift field needs no migration:
--   projects.doc        = Project (name, placements, finishes, hidden/removed room objects)
--   projects.room       = RoomModel (was Projects/<id>/room.json)
--   scanned_objects.doc = ScannedObject (name, model file name, bounding box)
--   files               = manifest of the item's files: {"<relative path>": {"size": n, "modified": "<time>"}}
-- Files live in the private `library` bucket under <owner_id>/projects/<id>/... and <owner_id>/objects/<id>/...
--
-- Sync is last-writer-wins on updated_at, which the app sets; the trigger below keeps a stale write from
-- replacing a newer row. A delete is a tombstone (deleted_at), never a row delete.
-- Every user is a Supabase Auth user, anonymous by default: one per install. The session survives a reinstall
-- (Keychain), but a second device is a different user until accounts are linked to a real sign-in.

create table public.projects (
  id uuid primary key,
  owner_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  updated_at timestamptz not null,
  deleted_at timestamptz,
  doc jsonb not null check (pg_column_size(doc) <= 1048576),
  room jsonb not null check (pg_column_size(room) <= 2097152),
  files jsonb not null default '{}' check (pg_column_size(files) <= 262144)
);

create table public.scanned_objects (
  id uuid primary key,
  owner_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  updated_at timestamptz not null,
  deleted_at timestamptz,
  doc jsonb not null check (pg_column_size(doc) <= 1048576),
  files jsonb not null default '{}' check (pg_column_size(files) <= 262144)
);

create index projects_owner_id_idx on public.projects (owner_id);
create index scanned_objects_owner_id_idx on public.scanned_objects (owner_id);

-- A device clock far ahead would otherwise win every later comparison: cap stamps at 5 minutes past server time.
-- On update, an older stamp than the stored one is a stale write: keep the stored row (the upsert still succeeds,
-- and the writer picks up the newer row on its next pull).
create function public.library_last_writer_wins() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := least(new.updated_at, now() + interval '5 minutes');
  if tg_op = 'UPDATE' and new.updated_at < old.updated_at then
    return null;
  end if;
  return new;
end;
$$;

create trigger projects_last_writer_wins before insert or update on public.projects
  for each row execute function public.library_last_writer_wins();
create trigger scanned_objects_last_writer_wins before insert or update on public.scanned_objects
  for each row execute function public.library_last_writer_wins();

alter table public.projects enable row level security;
alter table public.scanned_objects enable row level security;

-- Only signed-in users (anonymous ones included) touch these tables, and never with a hard delete.
revoke all on public.projects, public.scanned_objects from anon;
revoke delete, truncate on public.projects, public.scanned_objects from authenticated;

create policy "Owners read their projects" on public.projects
  for select to authenticated using ((select auth.uid()) = owner_id);
create policy "Owners add projects" on public.projects
  for insert to authenticated with check ((select auth.uid()) = owner_id);
create policy "Owners change their projects" on public.projects
  for update to authenticated
  using ((select auth.uid()) = owner_id)
  with check ((select auth.uid()) = owner_id);

create policy "Owners read their objects" on public.scanned_objects
  for select to authenticated using ((select auth.uid()) = owner_id);
create policy "Owners add objects" on public.scanned_objects
  for insert to authenticated with check ((select auth.uid()) = owner_id);
create policy "Owners change their objects" on public.scanned_objects
  for update to authenticated
  using ((select auth.uid()) = owner_id)
  with check ((select auth.uid()) = owner_id);

-- 50 MB per file: Object Capture models and room USDZ exports. Private: reads need the owner's token.
insert into storage.buckets (id, name, public, file_size_limit)
values ('library', 'library', false, 52428800);

-- The first path segment is the owner's user id, lowercase (auth.uid()::text). The app deletes an item's files
-- when it writes the item's tombstone.
create policy "Owners read their files" on storage.objects
  for select to authenticated
  using (bucket_id = 'library' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "Owners add their files" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'library' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "Owners replace their files" on storage.objects
  for update to authenticated
  using (bucket_id = 'library' and (storage.foldername(name))[1] = (select auth.uid())::text)
  with check (bucket_id = 'library' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "Owners delete their files" on storage.objects
  for delete to authenticated
  using (bucket_id = 'library' and (storage.foldername(name))[1] = (select auth.uid())::text);

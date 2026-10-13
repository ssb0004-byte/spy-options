-- Smart Routine Entry: remember whether a routine's name came from the verified catalog
-- ("catalog:<entry id>@<catalog version>") or was typed by the user ("custom:<uuid>").
-- Nullable, so every existing routine is unchanged.
alter table public.user_substances
  add column if not exists catalog_ref text
  check (catalog_ref is null or (char_length(catalog_ref) <= 120 and catalog_ref ~ '^(catalog|custom):'));

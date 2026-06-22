-- Drop unused password_hash column from users table
-- Authentication is now handled entirely by Supabase Auth
ALTER TABLE public.users DROP COLUMN IF EXISTS password_hash;

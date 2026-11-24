-- Migration: 20261124000000_create_clipper_schema.sql
-- Description: Phase 1 Database Schema for Clipper SaaS (tables, triggers, RLS, storage buckets, realtime, indexes)

-- Enable necessary extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================================
-- 1. TABLES
-- ============================================================================

-- PROFILES (extends auth.users)
CREATE TABLE IF NOT EXISTS public.profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email TEXT,
    credits_minutes INTEGER NOT NULL DEFAULT 30 CHECK (credits_minutes >= 0),
    plan TEXT NOT NULL DEFAULT 'free',
    created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc'::text, now()),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc'::text, now())
);

-- PROJECTS (user video projects)
CREATE TABLE IF NOT EXISTS public.projects (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    source_type TEXT NOT NULL CHECK (source_type IN ('youtube', 'upload')),
    source_url TEXT,
    storage_path TEXT,
    title TEXT,
    duration_seconds INTEGER,
    language TEXT DEFAULT 'en',
    rights_confirmed BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc'::text, now()),
    CONSTRAINT check_source_content CHECK (
        (source_type = 'youtube' AND source_url IS NOT NULL) OR
        (source_type = 'upload' AND storage_path IS NOT NULL)
    )
);

-- JOBS (processing jobs for clipping/transcription)
CREATE TABLE IF NOT EXISTS public.jobs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id UUID NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    status TEXT NOT NULL DEFAULT 'queued' CHECK (
        status IN ('queued', 'fetching', 'transcribing', 'analyzing', 'rendering', 'done', 'failed')
    ),
    progress INTEGER NOT NULL DEFAULT 0 CHECK (progress >= 0 AND progress <= 100),
    clips_requested INTEGER NOT NULL DEFAULT 10 CHECK (clips_requested IN (10, 20, 50)),
    error_message TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc'::text, now()),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc'::text, now())
);

-- TRANSCRIPTS (full speech-to-text transcript segments with word-level timestamps)
CREATE TABLE IF NOT EXISTS public.transcripts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id UUID NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
    segments JSONB NOT NULL DEFAULT '[]'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc'::text, now())
);

-- CLIPS (generated 9:16 vertical short clips)
CREATE TABLE IF NOT EXISTS public.clips (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    job_id UUID NOT NULL REFERENCES public.jobs(id) ON DELETE CASCADE,
    project_id UUID NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    start_time NUMERIC(10, 3) NOT NULL,
    end_time NUMERIC(10, 3) NOT NULL,
    score NUMERIC(5, 2),
    hook_title TEXT,
    reason TEXT,
    caption_style TEXT DEFAULT 'default',
    storage_path TEXT,
    thumbnail_path TEXT,
    status TEXT NOT NULL DEFAULT 'queued' CHECK (
        status IN ('queued', 'rendering', 'done', 'failed')
    ),
    created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc'::text, now()),
    CONSTRAINT check_clip_times CHECK (end_time > start_time)
);

-- USAGE EVENTS (tracking credit consumption)
CREATE TABLE IF NOT EXISTS public.usage_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    job_id UUID REFERENCES public.jobs(id) ON DELETE SET NULL,
    minutes_used INTEGER NOT NULL CHECK (minutes_used > 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc'::text, now())
);

-- ============================================================================
-- 2. INDEXES
-- ============================================================================

-- user_id indexes
CREATE INDEX IF NOT EXISTS idx_projects_user_id ON public.projects(user_id);
CREATE INDEX IF NOT EXISTS idx_jobs_user_id ON public.jobs(user_id);
CREATE INDEX IF NOT EXISTS idx_clips_user_id ON public.clips(user_id);
CREATE INDEX IF NOT EXISTS idx_usage_events_user_id ON public.usage_events(user_id);

-- project_id indexes
CREATE INDEX IF NOT EXISTS idx_jobs_project_id ON public.jobs(project_id);
CREATE INDEX IF NOT EXISTS idx_transcripts_project_id ON public.transcripts(project_id);
CREATE INDEX IF NOT EXISTS idx_clips_project_id ON public.clips(project_id);

-- status indexes
CREATE INDEX IF NOT EXISTS idx_jobs_status ON public.jobs(status);
CREATE INDEX IF NOT EXISTS idx_clips_status ON public.clips(status);

-- ============================================================================
-- 3. TRIGGERS & FUNCTIONS
-- ============================================================================

-- Function to automatically update updated_at timestamp
CREATE OR REPLACE FUNCTION public.handle_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = timezone('utc'::text, now());
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS set_profiles_updated_at ON public.profiles;
CREATE TRIGGER set_profiles_updated_at
    BEFORE UPDATE ON public.profiles
    FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

DROP TRIGGER IF EXISTS set_jobs_updated_at ON public.jobs;
CREATE TRIGGER set_jobs_updated_at
    BEFORE UPDATE ON public.jobs
    FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

-- Trigger to create a profiles row automatically on auth.users signup
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO public.profiles (id, email, credits_minutes, plan)
    VALUES (
        NEW.id,
        NEW.email,
        30,
        'free'
    )
    ON CONFLICT (id) DO NOTHING;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ============================================================================
-- 4. ROW LEVEL SECURITY (RLS)
-- ============================================================================

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.transcripts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.clips ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.usage_events ENABLE ROW LEVEL SECURITY;

-- PROFILES Policies
DROP POLICY IF EXISTS "Users can view their own profile" ON public.profiles;
CREATE POLICY "Users can view their own profile"
    ON public.profiles FOR SELECT
    USING (auth.uid() = id);

DROP POLICY IF EXISTS "Users can update their own profile" ON public.profiles;
CREATE POLICY "Users can update their own profile"
    ON public.profiles FOR UPDATE
    USING (auth.uid() = id);

-- PROJECTS Policies
DROP POLICY IF EXISTS "Users can manage their own projects" ON public.projects;
CREATE POLICY "Users can manage their own projects"
    ON public.projects FOR ALL
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

-- JOBS Policies
DROP POLICY IF EXISTS "Users can manage their own jobs" ON public.jobs;
CREATE POLICY "Users can manage their own jobs"
    ON public.jobs FOR ALL
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

-- TRANSCRIPTS Policies (Access via parent project ownership)
DROP POLICY IF EXISTS "Users can view transcripts of their own projects" ON public.transcripts;
CREATE POLICY "Users can view transcripts of their own projects"
    ON public.transcripts FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.projects
            WHERE projects.id = transcripts.project_id
            AND projects.user_id = auth.uid()
        )
    );

DROP POLICY IF EXISTS "Users can manage transcripts of their own projects" ON public.transcripts;
CREATE POLICY "Users can manage transcripts of their own projects"
    ON public.transcripts FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM public.projects
            WHERE projects.id = transcripts.project_id
            AND projects.user_id = auth.uid()
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.projects
            WHERE projects.id = transcripts.project_id
            AND projects.user_id = auth.uid()
        )
    );

-- CLIPS Policies
DROP POLICY IF EXISTS "Users can manage their own clips" ON public.clips;
CREATE POLICY "Users can manage their own clips"
    ON public.clips FOR ALL
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

-- USAGE EVENTS Policies
DROP POLICY IF EXISTS "Users can view their own usage events" ON public.usage_events;
CREATE POLICY "Users can view their own usage events"
    ON public.usage_events FOR SELECT
    USING (auth.uid() = user_id);

-- ============================================================================
-- 5. REALTIME PUBLICATION
-- ============================================================================

-- Ensure full row replication on updates so realtime listeners receive progress & status
ALTER TABLE public.jobs REPLICA IDENTITY FULL;

-- Add jobs table to supabase_realtime publication safely
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_publication_tables 
        WHERE pubname = 'supabase_realtime' 
        AND schemaname = 'public' 
        AND tablename = 'jobs'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.jobs;
    END IF;
END $$;

-- ============================================================================
-- 6. STORAGE BUCKETS & POLICIES
-- ============================================================================

-- Insert private storage buckets
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES 
    (
        'sources', 
        'sources', 
        false, 
        1073741824, -- 1 GB max
        ARRAY['video/mp4', 'video/quicktime', 'video/webm', 'video/x-matroska', 'audio/mpeg', 'audio/wav', 'audio/mp4']
    ),
    (
        'clips', 
        'clips', 
        false, 
        524288000, -- 500 MB max
        ARRAY['video/mp4', 'image/jpeg', 'image/png', 'image/webp']
    )
ON CONFLICT (id) DO UPDATE SET 
    public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit,
    allowed_mime_types = EXCLUDED.allowed_mime_types;

-- Storage RLS: SOURCES bucket (per-user folder: {user_id}/*)
DROP POLICY IF EXISTS "Users can upload their own source videos" ON storage.objects;
CREATE POLICY "Users can upload their own source videos"
    ON storage.objects FOR INSERT
    WITH CHECK (
        bucket_id = 'sources' 
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

DROP POLICY IF EXISTS "Users can read their own source videos" ON storage.objects;
CREATE POLICY "Users can read their own source videos"
    ON storage.objects FOR SELECT
    USING (
        bucket_id = 'sources' 
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

DROP POLICY IF EXISTS "Users can delete their own source videos" ON storage.objects;
CREATE POLICY "Users can delete their own source videos"
    ON storage.objects FOR DELETE
    USING (
        bucket_id = 'sources' 
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

-- Storage RLS: CLIPS bucket (per-user folder: {user_id}/*)
DROP POLICY IF EXISTS "Users can read their own clips" ON storage.objects;
CREATE POLICY "Users can read their own clips"
    ON storage.objects FOR SELECT
    USING (
        bucket_id = 'clips' 
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

DROP POLICY IF EXISTS "Users can upload clips to their folder" ON storage.objects;
CREATE POLICY "Users can upload clips to their folder"
    ON storage.objects FOR INSERT
    WITH CHECK (
        bucket_id = 'clips' 
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

DROP POLICY IF EXISTS "Users can delete their own clips" ON storage.objects;
CREATE POLICY "Users can delete their own clips"
    ON storage.objects FOR DELETE
    USING (
        bucket_id = 'clips' 
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

-- Migration: 20261124000001_add_clip_metadata_columns.sql
-- Description: Add category, moral_summary, hook_line, and virality_reasons to clips table

ALTER TABLE public.clips
    ADD COLUMN IF NOT EXISTS category TEXT CHECK (
        category IN (
            'exciting',
            'moral_lesson',
            'emotional',
            'funny',
            'surprising',
            'story',
            'insight'
        )
    ),
    ADD COLUMN IF NOT EXISTS moral_summary TEXT,
    ADD COLUMN IF NOT EXISTS hook_line TEXT,
    ADD COLUMN IF NOT EXISTS virality_reasons JSONB DEFAULT '[]'::jsonb;

-- Performance index for category filtering
CREATE INDEX IF NOT EXISTS idx_clips_category ON public.clips(category);

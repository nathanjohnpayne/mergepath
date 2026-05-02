Tracks Phase 2 of **MUX Video Integration** (Project #5).

**Goal:** Views on `/projects/swipe-watch` (and any other page embedding a MUX video) register in Mux Data with correct `video_title` / `video_id` metadata. Missing env key does not break the player.

**Exit criteria:**
- `PUBLIC_MUX_ENV_KEY` read via Astro's Vite env.
- MuxPlayer receives `env-key` + `metadata-video-title` + `metadata-video-id`.
- Real views show up in the Mux Data dashboard.
- Unset key → player still loads, no console errors.

**Depends on:** the Phase 1 parent issue.

Sub-issues below. See [Project #5 README](https://github.com/users/nathanjohnpayne/projects/5) for the full phased plan.

Tracks Phase 4 of **MUX Video Integration** (Project #5).

**Goal:** Replace the hand-maintained static GIF at `public/images/projects/swipe-watch-hero.gif` with a Mux-generated animated GIF pulled from the same asset as the video. Any future project with a `muxPlaybackId` gets a fresh Mux-sourced GIF automatically on build.

**Exit criteria:**
- `scripts/refresh-mux-gifs.mjs` exists and, for every project with a `muxPlaybackId`, writes `public/images/projects/{slug}-hero.gif` from `https://image.mux.com/{playbackId}/animated.gif`.
- Build runs the refresher before `astro build`.
- `scripts/refresh-hero-images.mjs` (the existing GitHub social-preview refresher) skips any project with `muxPlaybackId`.
- OG image generation still works against the new GIF.
- Running the refresher with no network / bad playback ID degrades cleanly (build fails loudly; no silent corruption).

**Depends on:** the Phase 1 parent issue.

Sub-issues below. See [Project #5 README](https://github.com/users/nathanjohnpayne/projects/5) for the full phased plan.

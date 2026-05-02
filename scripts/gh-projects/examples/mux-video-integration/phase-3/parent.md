Tracks Phase 3 of **MUX Video Integration** (Project #5).

**Goal:** MuxPlayer usage lives in a single reusable Astro component so any future project page can embed a video by adding `muxPlaybackId` to its frontmatter. Per-page theming flows automatically from each project's `--project-accent`.

**Exit criteria:**
- `src/components/ProjectMuxPlayer.astro` is the sole consumer of `@mux/mux-player-astro`.
- `src/layouts/ProjectLayout.astro` calls the component once, no inline MuxPlayer logic.
- AGENTS.md documents: "How to add a MUX video to a project page" (one frontmatter field).
- Theming verified against each `project-page--*` accent class (red, yellow, blue, lightblue, paper).

**Depends on:** the Phase 1 parent issue. Phase 2 is optional — component should work without a Mux Data env key.

Sub-issues below. See [Project #5 README](https://github.com/users/nathanjohnpayne/projects/5) for the full phased plan.

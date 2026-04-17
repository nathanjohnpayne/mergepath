Automated tests live here.

- `tests/test_mergepath_frontend.sh` validates `mockups/mergepath.html`
  against `specs/mergepath_policy_configurator.md`. It checks for the
  required structural anchors (title, injection markers, control IDs,
  preset buttons, modal ARIA attributes, reduced-motion CSS), asserts
  the embedded script block contains no data-bearing `innerHTML`
  assignments, confirms all required JS symbols are present
  (`DEFAULTS`, `PRESETS`, `LIMITS`, `compileGlob`, `matchGlob`,
  `simulate`, `normalizePR`, `validatePath`, `copyText`, `openModal`,
  `closeModal`, `renderChips`, `renderPRs`, `renderYaml`,
  `applyPreset`, `announce`), runs `node --check` on the extracted
  script, and finally round-trips a fake `window.__PRS` injection
  through the `<!-- MERGEPATH_INJECT -->` marker to confirm the
  helper contract still holds. Requires `python3` and `node` on
  `PATH`.

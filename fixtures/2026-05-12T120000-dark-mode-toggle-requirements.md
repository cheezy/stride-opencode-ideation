# Dark mode toggle

*Date: 2026-05-12 12:00*
*Session: 2026-05-12T120000-dark-mode-toggle*

## Problem
Users running the app at night against a bright white UI report eye strain, and several have asked for a way to flip the entire interface to a low-light theme. The current single-theme stylesheet has no token system, so every component embeds its own colors and screenshots of dark-mode mockups are inconsistent across pages.

## Goal
Users can flip a single toggle in the app header and the entire interface (all routes, all components, all modal overlays) switches to a low-light palette without a page reload. The preference persists across sessions.

## Success metrics
- 100% of routes render correctly in dark mode (manual walkthrough catches zero contrast-failure regressions on a checked list of 14 pages)
- Toggle round-trip latency under 50ms on a mid-range laptop (no perceptible flicker)
- Dark-mode preference persists across browser restarts (assert via cookie/localStorage round-trip)
- Less than 1 percent of dark-mode-related bug reports from beta users in the 30 days after launch

## Assumptions
- The existing daisyUI theme system can hold both light and dark palettes side-by-side without a custom Tailwind plugin
- Browsers in the supported matrix all honor the `data-theme` attribute pattern already used in `app.css`
- Users do not need per-route theme override — one toggle controls the whole app
- The two existing modal components (`delayed_modal.ex`, `core_components.ex`) follow the same token system once retrofitted

## Constraints
- No new runtime dependencies (no theming JS library)
- Token names must be daisyUI-compatible so we can swap palettes without forking the framework
- The toggle must not flash a wrong-theme paint on first render (FOUC prevention)
- Existing screenshots in `docs/` may be re-shot but not deleted

## Non-goals
- Per-component theme overrides — not in scope; users opt into one theme app-wide
- Automatic time-of-day switching — defer; explicit toggle only
- Theme customization (user-chosen palettes) — defer; ship the binary light/dark choice first
- Email and PDF export theming — out of scope; documents stay light

## Outcome
Anyone running the app after dark uses the dark theme without reaching for a system-level workaround (e.g., browser dark-reader extensions). Designers can share dark-mode mockups confident that production will match them. Future theme work has a token system to extend rather than reinvent.

## Sketch
- Migrate hardcoded colors in `core_components.ex` and `delayed_modal.ex` to daisyUI semantic tokens (`bg-base-100`, `text-base-content`, etc.)
- Add a `theme_toggle` LiveView component placed in the app header; updates a server-side preference and pushes the `data-theme` attribute via a JS hook
- Persist preference in the session cookie for guests; in the `user_preferences` table for logged-in users
- Add a one-line `<script>` in the head that reads the preference before CSS loads to prevent FOUC

## Open questions
- Should the toggle be a binary switch or a tri-state (light / dark / system)? Default to binary; revisit if users ask.
- Do we ship the migration of existing screenshots in the same release or as a follow-up? Probably follow-up to keep the PR shippable.

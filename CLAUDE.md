# Yap

Yap is a fork of [VoiceInk](https://github.com/Beingpax/VoiceInk) (Beingpax). Credit for the original app stays with upstream (see README).

## Iron rule: never act on upstream

Never do anything to `Beingpax/VoiceInk`: no push, PR, issue, comment, release, workflow run, or any other `gh` / GitHub API write. Reading upstream to sync its changes into this fork is the only allowed contact.

- `gh` must target this repo. The default is pinned with `gh repo set-default Sma1lboy/yap`; still pass `-R Sma1lboy/yap` in scripts and in any `gh` call whose target matters. Without a default, `gh` in a fork silently resolves to the upstream parent.
- The `upstream` git remote is fetch-only; its push URL is deliberately invalid. Don't restore it.
- Upstream fixes arrive by fetching `upstream/main` and merging into our `main` (or a sync PR on `Sma1lboy/yap`), never the other way round.
- If a task seems to need anything on upstream, stop and ask Jackson.

## Working here

- Build: `make build` (runs `design-check` first). Visual rules and the single token source: `docs/DESIGN.md`.
- Release: run `scripts/preflight.sh` before tagging; tagging needs Jackson's go-ahead.
- Yap Cloud backend is paygate (`github.com/Sma1lboy/paygate`, private), live at `https://cloud.yap.sma1lboy.me`.

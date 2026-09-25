# Agent Guidelines

This repository runs VeeCode DevPortal 3.x locally with Docker Compose. It is
VeeCode-owned, not a fork of `rhdh-local`, and it builds no image: it runs the
image the pinned `devportal-chart` release points at.

Read [README.md](README.md) for the user-facing flows: first start, the
marketplace walkthrough and proof 2 with a locally exported plugin.

## Invariants

- `.chart-pin` names a `devportal-chart` release tag. The image digest in every
  compose file is the digest that release pins. Move both with
  `scripts/bump-chart-pin.sh`, never by hand.
- The files under `config/` and `dynamic-plugins.yaml` come from the chart at
  `.chart-pin`: three are byte copies, and the two rendered ones carry a
  `DERIVED FILE` header. Copy or re-render them from the chart instead of
  editing them; `scripts/check-config-drift.sh` checks them against the chart.
- `DEVPORTAL_IMAGE` is an explicit opt-in to another image, such as `:edge`.
  `latest` is never valid: it is the 2.x line.

## Verify a change

```bash
scripts/check-config-drift.sh   # needs git and network; compares config/ with the chart at .chart-pin
docker compose config -q        # parses the compose files
```

Booting the stack is heavy; run `docker compose up` on a machine meant for it.
The `nightly-health` workflow boots the default stack on a schedule and on pull
requests that touch the pin or the config.

## Release path

`chart-bump.yml` runs daily, reads the newest `chart-v*` tag of
`veecode-platform/devportal-chart`, and opens a pull request that moves
`.chart-pin` and the digest. A person merges it.

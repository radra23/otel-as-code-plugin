# Adding otel-as-code to the OpenTelemetry Registry

## Stop first: the registry is frozen

As of 2026-11-14 the registry does not accept new entries. Every ecosystem page,
including `adding.md`, now includes this notice:

> New entries and updates to the ecosystem lists, including the registry, are
> no longer being accepted while maintainers work out each list's future.

Tracking issue: https://github.com/open-telemetry/opentelemetry.io/issues/11377
("Ecosystem lists are frozen, retirement planned", open, last maintainer reply
2026-11-11). The stated direction is to retire the registry and make the
community ecosystem explorer (https://explorer.opentelemetry.io/) the source of
truth. Other third-party projects with entries ready are holding them on a fork
branch and not opening PRs. Do the same: keep the entry ready on a fork branch,
and open the PR only after the freeze is lifted or a successor process is
announced in #11377. Do not comment on the issue unless you have something new
to add; maintainers asked mainly for input from registry users.

## Second blocker: the AI contribution policy

The PR template and the contributing docs say that a first-time contributor's
first 3 PRs must be primarily human-written (AIL1: AI may help with completion,
formatting, and linting only), and the PR description must be entirely
human-written (AIL0). The template has a checkbox "I wrote this PR on my own. I
did not use AI to write the PR contents or description."

The draft `otel-registry.yml` next to this file was written by an AI assistant.
If this is your first opentelemetry.io PR, treat it as a reference for the
schema and field values only: write the YAML and the PR description yourself,
and tick the template boxes truthfully. Policy:
https://opentelemetry.io/docs/contributing/pull-requests/#using-ai and
https://github.com/open-telemetry/community/blob/main/policies/genai.md

## Steps, once submissions reopen

1. Sign the CNCF CLA (EasyCLA) with the same name and email as your
   `git config user.name` / `user.email`. Unsigned PRs fail the automated
   checks. https://docs.linuxfoundation.org/lfx/easycla/v2-current/contributors
   (from https://opentelemetry.io/docs/contributing/prerequisites/#cla). If you
   commit with `radra23@users.noreply.github.com`, sign the CLA with that
   address too.
2. Re-read the guide and template in case they changed while frozen:
   - https://github.com/open-telemetry/opentelemetry.io/blob/main/content/en/ecosystem/registry/adding.md
   - https://github.com/open-telemetry/opentelemetry.io/blob/main/templates/registry-entry.yml
   - https://github.com/open-telemetry/opentelemetry.io/blob/main/data/registry-schema.json
3. Fork from the radra23 account and clone:

   ```sh
   gh repo fork open-telemetry/opentelemetry.io --clone
   cd opentelemetry.io
   ```

4. Create a branch. CI fails if the PR branch is named `main` (BRANCH NAME
   check in `.github/workflows/check-file.yml`).

   ```sh
   git checkout -b registry/otel-as-code
   ```

5. Add the file at `data/registry/tools-shell-otel-as-code.yml`. Naming follows
   existing `utilities` entries: `tools-<language>-<name>.yml` (for example
   `tools-shell-otelifysh.yml`, `tools-go-docker-lgtm.yml`).
6. Install and run the local checks the PR template points to:

   ```sh
   npm install
   npm run fix:format       # prettier, 80-column prose wrap for YAML
   npm run check:spelling   # cspell over content and data
   npm run check:filenames
   npm run check:text       # textlint over content and data
   ```

   `npm run fix:all` runs every fixer and is what the PR template recommends.
   If cspell flags a word (for example a handle or product name), add it to the
   `# cSpell:ignore` line at the top of the YAML file rather than to the shared
   dictionaries. Optionally validate against the schema:

   ```sh
   npx -y -p ajv-cli@5 -p ajv-formats@3 ajv validate --spec=draft7 \
     --strict=false -c ajv-formats -s data/registry-schema.json \
     -d data/registry/tools-shell-otel-as-code.yml
   ```

   (The draft here was validated against `data/registry-schema.json` with
   Python `jsonschema`, Draft 7, format checks on. Prettier and cspell were not
   run.)
7. Commit and push:

   ```sh
   git add data/registry/tools-shell-otel-as-code.yml
   git commit -m "Add otel-as-code to the registry"
   git push -u origin registry/otel-as-code
   ```

8. Open the PR against `open-telemetry/opentelemetry.io:main`. Title convention
   from recently merged registry PRs: `Add <project> to the registry` (for
   example #11188 "Add Network Device Receiver to the registry", #11179 "Add
   Dartastic OpenTelemetry SDK for Dart to the registry"). Use
   `Add otel-as-code to the registry`.
9. Fill in the PR template
   (https://github.com/open-telemetry/opentelemetry.io/blob/main/.github/PULL_REQUEST_TEMPLATE.md):
   - Checkboxes: read the Contributing docs (especially "First-time
     contributing?"), whether you wrote the PR yourself without AI, whether it
     has content you did not fully write, the AI policy acknowledgement if so,
     and that you can answer maintainer questions without AI.
   - Delete the HTML comment block and write a short description in your own
     words: what the project is, why `utilities`, and the repo link.
10. After submitting, do not keep rebasing or chasing check status; the
    template says maintainers will tell you when. Formatting failures can be
    fixed by commenting `/fix:format` on the PR
    (https://opentelemetry.io/docs/contributing/pull-requests/#fixing-prs-in-github).

## Choices in the draft

- `registryType: utilities`: the guide defines it as "Any other tool that
  people can use to work with OpenTelemetry". The project is not an
  instrumentation library, SDK, Collector component, or native integration.
- `language: shell`: the schema allows one language and every existing entry
  sets one. The plugin's own code is mostly Bash (GitHub reports Shell as the
  dominant language), and the closest precedent, `tools-shell-otelifysh.yml`
  (a tool that instruments many languages), uses `shell`.
- `license: Apache 2.0`: the spelling existing entries use.
- `isNative` / `isFirstParty`: omitted, as in the `utilities` entries modelled
  on; both would be `false`.

## Links read

- https://github.com/open-telemetry/opentelemetry.io/blob/main/content/en/ecosystem/registry/adding.md
- https://github.com/open-telemetry/opentelemetry.io/blob/main/content/en/ecosystem/_includes/freeze-notice.md
- https://github.com/open-telemetry/opentelemetry.io/issues/11377
- https://github.com/open-telemetry/opentelemetry.io/blob/main/data/registry-schema.json
- https://github.com/open-telemetry/opentelemetry.io/blob/main/templates/registry-entry.yml
- https://github.com/open-telemetry/opentelemetry.io/blob/main/.github/PULL_REQUEST_TEMPLATE.md
- https://github.com/open-telemetry/opentelemetry.io/blob/main/content/en/docs/contributing/_index.md
- https://github.com/open-telemetry/opentelemetry.io/blob/main/content/en/docs/contributing/prerequisites.md
- https://github.com/open-telemetry/opentelemetry.io/blob/main/content/en/docs/contributing/pull-requests.md
- https://github.com/open-telemetry/opentelemetry.io/blob/main/package.json
- https://github.com/open-telemetry/opentelemetry.io/blob/main/data/registry/tools-shell-otelifysh.yml
- https://github.com/open-telemetry/opentelemetry.io/blob/main/data/registry/tools-otel-upgrade-helper.yml
- https://github.com/open-telemetry/opentelemetry.io/blob/main/data/registry/tools-python-pytest-genai-semconv.yml

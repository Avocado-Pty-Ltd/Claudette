# LinkedIn prospecting

Claudette can drive [browser-use](https://github.com/browser-use/browser-use) — the
open-source browser agent — through LinkedIn in your own browser, and come back with
two things:

- **people worth connecting with**, each with a drafted connection note, and
- **posts worth replying to**, each with a drafted comment.

You give it a goal in plain English. It searches, reads profiles and posts, and writes
drafts. Then you read them, edit them, and send them yourself.

## What it does not do

It never clicks **Connect**, never clicks **Send**, and never posts a comment.

That isn't a limitation we plan to remove:

- LinkedIn's [User Agreement](https://www.linkedin.com/legal/user-agreement) prohibits
  using bots or other automated methods to access the service, and automating
  invitations and posts is the fastest way to get an account restricted.
- A connection note nobody read isn't worth sending. The value here is in the
  *research* — finding the right five people and knowing what to say to them — not in
  the clicking.

So the loop is: Claudette drafts → you review in the panel → **Copy** → **Open
profile** → paste and send. Two clicks per contact, with a human in between.

The agent also runs with a reduced toolbelt: `evaluate` (arbitrary JavaScript) and
`upload_file` are removed from what it can do, and navigation is locked to
`*.linkedin.com`, so a wandering model can't wander off-site.

## Setup

### 1. Install browser-use

Open **Settings → LinkedIn** (⌘,) and hit **Install browser-use**. Claudette builds a
virtualenv at `~/Library/Application Support/Claudette/browser-use-venv` and installs
the package into it.

It uses [`uv`](https://docs.astral.sh/uv/) when you have it — `uv` provisions its own
Python 3.12, which matters because macOS only ships Python 3.9 and browser-use needs
3.11+. Otherwise it falls back to `venv` + `pip` against the newest Python it can find.

If neither is available:

```bash
brew install uv           # smallest option
# or
brew install python@3.12
```

Already have browser-use somewhere? Put that interpreter's path in the **Python**
field and Claudette will use it instead.

### 2. Add a model key

The browser agent needs its own model — this is separate from the Claude Code session
in the main window, and it's what reads pages and writes the drafts.

| Provider | Default model | Key from |
| --- | --- | --- |
| Anthropic | `claude-sonnet-4-5` | console.anthropic.com → API keys |
| OpenAI | `gpt-4.1-mini` | platform.openai.com → API keys |
| Google | `gemini-2.5-flash` | aistudio.google.com |
| Ollama | `qwen2.5:7b` | no key — runs locally |

Keys are stored in your Keychain and passed to the sidecar over the environment, never
on the command line where `ps` would show them.

### 3. Sign in to LinkedIn, once

The agent drives a persistent Chrome profile at
`~/Library/Application Support/Claudette/linkedin-profile`. The first run opens a
browser window; sign in to LinkedIn there by hand. The session persists, so later runs
start logged in.

Claudette never sees, asks for, or stores your LinkedIn password. If a run finds itself
logged out it stops and reports `not logged in` rather than trying to sign in.

Leave **Headless** off until you trust it — watching the first couple of runs is the
fastest way to learn what kind of goal produces good results.

### 4. Tell it who you are

**Settings → LinkedIn → About you** is two or three lines about what you do. The drafts
borrow their voice from it, which is the difference between a note that sounds like you
and one that sounds like a template. **Tone** is optional ("direct, a bit dry, no
exclamation marks").

## Running one

Press **⇧⌘L**, click the people icon in the chat header, or type `/linkedin` in the
chat box:

```
/linkedin find Sydney-based founders of seed-stage AI infra startups, and posts of
theirs worth replying to
```

The panel shows a live trace of what the agent is looking at while it works. When it
finishes you get a card per person: who they are, why it picked them, a confidence
chip, and an editable draft with **Copy** and **Open profile**.

Two things to do with a finished report:

- **Copy all** puts the whole thing on the clipboard as Markdown.
- **Send to chat** drops it into the chat box, so you can ask Claude to rework the
  drafts, cross-reference them against your notes, or turn them into a CRM import.

## Tuning

| Setting | Effect |
| --- | --- |
| Contacts / Comments | How many of each to aim for. Fewer and better beats more. |
| Step budget | Hard ceiling on agent steps per run — where the time and the token bill stop. Default 60. |
| Headless | Hides the browser window. Faster, but you can't see what it's doing. |

A specific goal produces dramatically better results than a broad one. "Find heads of
data at Australian insurers talking publicly about LLM adoption" gives the agent search
terms, a filter and a relevance test. "Find me some good contacts" gives it nothing.

## How it fits together

```
ProspectPanel (SwiftUI)
   ↓ goal + options
ProspectRunner  ──spawns──►  python prospector.py --goal … --mode both
   ▲                              │
   └──── JSONL events ────────────┘   (ready / status / step / result / done / error)
                                  │
                                  └── browser-use Agent → Chrome → linkedin.com
```

- `Sources/Claudette/Resources/linkedin_prospector/prospector.py` — the sidecar. Builds
  the task prompt, runs the browser-use `Agent` with `ProspectReport` as its structured
  output schema, and streams one JSON event per line on stdout.
- `Sources/Claudette/Services/BrowserUseService.swift` — finds a Python with
  browser-use in it, spawns the sidecar, parses the event stream, and handles install
  and cancellation.
- `Sources/Claudette/Models/Prospect.swift` — the decoded report.
- `Sources/Claudette/Views/Prospect/` — the panel and the review cards.

The sidecar ships inside the app bundle as a resource, so it's readable: if you want to
change how the agent is briefed, the prompt is right there in `build_task`.

## When it goes wrong

| Symptom | Cause |
| --- | --- |
| "browser-use isn't installed in…" | The interpreter Claudette found doesn't have the package. Install from Settings, or point **Python** at one that does. |
| "Claudette needs Python 3.11 or newer" | macOS ships 3.9. `brew install uv` or `brew install python@3.12`. |
| Run stops with `not logged in` | The Chrome profile's LinkedIn session expired. Run again non-headless and sign in. |
| Run stops with a rate-limit note | LinkedIn throttles heavy searching. Wait it out; the agent won't try to work around it. |
| Empty report | Usually too broad a goal. Narrow it, or raise the step budget. |

The **Agent log** disclosure at the bottom of the panel has the sidecar's stderr, which
is where browser-use's own logging goes.

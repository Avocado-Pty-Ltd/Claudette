# Browser tasks

Claudette can drive [browser-use](https://github.com/browser-use/browser-use) — the
open-source browser agent — through a website in your own browser, and report back
what it found: a list of results, why each one matters, and any text you asked it to
draft.

Press **⇧⌘B**, click the globe in the chat header, or type `/browse <goal>`.

## Recipes are yours, not Claudette's

Claudette ships **no recipes**, and none belong in this repository. The app knows how
to drive a browser; it deliberately knows nothing about any particular site.

Everything site-specific — where to start, which domains to stay on, what counts as a
good result, what to draft, when to run — lives in a JSON file you write:

```
~/Library/Application Support/Claudette/browser-recipes/*.json
```

That's a normal folder. Keep it in a private repo, a dotfiles checkout, or a synced
directory; symlink it if you like. Your rules for your work stay yours.

### Having Claude write one

`/recipe <what it should do>` in the chat box, **⇧⌘R**, or **Describe a new recipe…**
in the panel's ⋯ menu:

```
/recipe watch the pricing pages of three competitors on example.com every Tuesday
        and Thursday morning and tell me anything that changed
```

Claude writes the file and the composer shows it to you before anything is saved —
a summary (where it starts, what it's fenced to, read-only or not, when it runs) over
the raw JSON, with warnings for anything worth a second look, like a recipe that can
interact with pages or a schedule with no goal. **Save** drops it in your recipes
folder and selects it; **Save & open in editor** also opens the file.

This runs through the Claude Code you're already signed into — a one-shot call in a
throwaway session, no extra API key, and it doesn't touch your project conversation.

The hard part of a recipe isn't the JSON, it's knowing what to put in `instructions`.
That's the part worth handing to a model. Edit the file afterwards as much as you like
— it's yours, and nothing regenerates it.

### Writing one by hand

**Settings → Browser agent → Recipes → New…** writes a commented template and opens it.

### The format

```json
{
  "name": "Competitor pricing sweep",
  "icon": "tag",
  "goal": "Check what the three competitors on my list charge, and flag anything that changed",
  "goalPlaceholder": "Which competitors, and what are you watching for?",
  "startURL": "https://example.com/pricing",
  "allowedDomains": ["*.example.com", "*.example.org"],
  "readOnly": true,
  "maxFindings": 8,
  "instructions": "Only public pricing pages — never anything behind a signup. Record the plan name, the monthly price, and the seat minimum. Ignore annual-billing discounts.",
  "drafts": [
    {
      "label": "Slack note",
      "limit": 400,
      "guidance": "What changed and whether it matters to us. One concrete number."
    }
  ],
  "schedule": {
    "enabled": true,
    "days": ["tuesday", "thursday"],
    "at": "morning",
    "catchUpIfMissed": false
  }
}
```

| Field | Meaning |
| --- | --- |
| `name`, `icon` | How it appears in the picker. `icon` is any SF Symbol name. |
| `goal` | Prefilled goal. **Required for scheduled recipes** — nobody's at the keyboard to type one. |
| `goalPlaceholder` | Hint under the goal box. |
| `startURL` | Where the agent opens. |
| `allowedDomains` | Glob patterns the agent is fenced to. Leave it out and it can follow links anywhere. |
| `readOnly` | Default `true`. See below. |
| `maxFindings` | How many results to aim for. Fewer and better beats more. |
| `instructions` | Your rules, in plain English, handed to the agent verbatim. This is where the substance goes. |
| `drafts` | Text to write for each result. `limit` drives the character counter in the UI. |
| `schedule` | When to run by itself. See below. |

Everything except `name` is optional. You can also run with no recipe at all — type a
goal, set the start URL and domains inline, go.

Each run's settings are prefilled from the recipe but editable in the panel, so a
one-off variation doesn't mean editing the file.

## Read-only by default

A read-only run can search, filter, sort, paginate and read. It **cannot** submit a
form, post, send a message, apply, connect, follow, subscribe, buy, or delete.

That's enforced in three places, not just asked for in the prompt:

1. `evaluate` (arbitrary JavaScript), `upload_file` and `send_keys` are removed from
   the agent's toolbelt entirely.
2. `allowedDomains` fences navigation at the browser level.
3. Every `click` and `input` passes through a guard that reads the target element's
   label and refuses anything that looks like it sends or publishes — Send, Post,
   Connect, Submit, Buy, Delete, Share, Subscribe, a comment box, a message
   composer. It fails closed: an element it can't find or can't read a label for is
   refused too. Refusals are counted in the panel header and logged.

Point 3 is defence in depth, **not a sandbox**. It classifies a control by the text
it shows, so an unlabelled or deliberately mislabelled button could still get
through. It exists because a page the agent reads can try to talk it out of following
the prompt, and a prompt is a poor place to keep a safety rule. Cookie banners,
"Apply filters", "Save search" and pagination are deliberately *not* blocked — a
guard that ends every run on the first consent dialog is a guard people turn off.

A refusal isn't fatal: the agent is told why and picks another route.

That's the default for good reasons: a read-and-draft run is one you can let loose on a
schedule without watching it, and most sites' terms of service take a dim view of bots
that act on your behalf. Check the terms of any site you point this at — that's your
call to make, and the reason the rules live in your file rather than in Claudette.

Turn it off per-run under **Options** (or with `"readOnly": false`) when a task
genuinely needs to click through something. Even then the agent never enters
credentials or payment details, and stops rather than working around a captcha,
paywall or rate limit.

## Signing in

The agent drives a persistent browser profile at
`~/Library/Application Support/Claudette/browser-profile`.

That is deliberately **not** your everyday Chrome profile, so your existing logins
don't carry over. It can't be: Chrome locks a profile that's already open, and recent
Chrome refuses automation on the default profile altogether. What *is* your own is the
browser binary — **Settings → Browser agent → Chrome** defaults to your installed
Google Chrome (falling back to Chromium, Brave or Edge), so the window is the browser
you already know and the one the site sees you use every day. Leave it blank and
browser-use downloads its own Chromium instead, which sites tend to trust less.

A task run will never sign in for you — it refuses to enter credentials and stops at
the first login wall. So sign in yourself, once, ahead of time:

**Settings → Browser agent → Sign in to a site** — type a URL, press **Open browser**.
A real browser window opens on that profile and stays open. Sign in by hand, then come
back and press **Done — close it**. The session persists in the profile, so task runs
start signed in.

(This exists because the profile starts empty. A run that meets a login wall stops and
closes the browser, which would leave you no moment in which to sign in.)

Claudette never sees, asks for, or stores a site password. If a run finds itself signed
out it stops and says so in `blocked_reason` rather than trying to sign in.

## Schedules

A recipe with a `schedule` runs by itself:

```json
"schedule": { "days": ["tuesday", "thursday"], "at": "morning" }
```

| Field | Accepts |
| --- | --- |
| `days` | `"monday"`…`"sunday"` or `"mon"`…`"sun"`; the groups `"weekdays"`, `"weekends"`, `"daily"`. Omit for every day. |
| `at` | One time or a list. `"09:00"`, `"9:30am"`, `"0830"`, or a name: `morning` (09:00), `midday` (12:00), `afternoon` (14:00), `evening` (18:00), `night` (21:00). |
| `enabled` | Default `true`. Set `false` to park a schedule without deleting it. |
| `catchUpIfMissed` | Default `false`. See below. |

Times are your Mac's local time. `"at": ["09:00", "17:00"]` runs twice a day.

Then turn on **Settings → Browser agent → Run scheduled recipes**. That master switch
is off until you flip it, so nothing ever runs by itself without you saying so. The
same panel lists every scheduled recipe with its next run, and the last few runs with a
link to each result.

### What "scheduled" honestly means

Claudette is a desktop app, not a daemon. **Schedules fire while Claudette is open.**
If your Mac is asleep or the app is closed at 09:00 on Tuesday, that slot is missed.

- By default a missed slot is simply skipped — you won't open the app on Thursday and
  have Tuesday's run start unprompted.
- `"catchUpIfMissed": true` runs it as soon as Claudette next opens instead.
- A recipe Claudette has never seen before starts from its *next* slot. Adding a
  Tuesday recipe on a Wednesday won't fire it immediately.
- A slot that comes due while another task is running queues up and starts when the
  browser is free — one agent, one browser.

Each scheduled run writes its results to
`~/Library/Application Support/Claudette/browser-runs/<recipe>-<timestamp>.md`, and
posts a notification when it finishes, so an 09:00 run isn't lost because you were
making coffee.

## Setup

### 1. Install browser-use

**Settings → Browser agent → Install browser-use**. Claudette builds a virtualenv at
`~/Library/Application Support/Claudette/browser-use-venv` and installs the package.

It uses [`uv`](https://docs.astral.sh/uv/) when you have it — `uv` provisions its own
Python 3.12, which matters because macOS ships 3.9 and browser-use needs 3.11+.
Otherwise it falls back to `venv` + `pip` against the newest Python it can find. If you
have neither:

```bash
brew install uv           # smallest option
# or
brew install python@3.12
```

Already have browser-use somewhere? Put that interpreter's path in **Python**.

### 2. Add a model key

The browser agent needs its own model — separate from the Claude Code session in the
main window. It's what reads pages and writes drafts.

| Provider | Default model | Key from |
| --- | --- | --- |
| Anthropic | `claude-sonnet-4-5` | console.anthropic.com → API keys |
| OpenAI | `gpt-4.1-mini` | platform.openai.com → API keys |
| Google | `gemini-2.5-flash` | aistudio.google.com |
| Ollama | `qwen2.5:7b` | no key — runs locally |

Keys live in your Keychain and reach the sidecar over the environment, never on the
command line where `ps` would show them.

### 3. Sign in to whatever the task needs

**Settings → Browser agent → Sign in to a site**, as above. Skip it for tasks on sites
that don't need an account.

### 4. Optional: say who you are

**About you** is two or three lines about what you do; **Tone** is a phrase like
"direct, a bit dry, no exclamation marks". Both feed any drafts' voice, which is the
difference between text that sounds like you and text that sounds like a template.

## Reviewing results

Each result is a card: title, subtitle, factual chips the agent read off the page, a
confidence chip, and why it matched. Drafts are editable in place, with a character
counter against the limit the recipe declared, a **Copy** button and a link out to the
page.

At the bottom: **Copy all** puts the whole report on the clipboard as Markdown, and
**Send to chat** drops it into the chat box so Claude can rework it, cross-reference it
against your notes, or turn it into something else.

## How it fits together

```
BrowserTaskPanel (SwiftUI)          TaskScheduler
   │ goal + recipe                     │ fires a recipe at its own times
   ▼                                   ▼
BrowserTaskRunner ──spawns──► python runner.py --provider … --max-steps …
   ▲                              │  ▲ task spec as JSON on stdin
   └──── JSONL events ────────────┘  │  (ready / status / step / result / done / error)
                                     └── browser-use Agent → Chrome → the web
```

- `Sources/Claudette/Resources/browser_agent/runner.py` — the sidecar. Builds the
  agent's brief from the task spec, runs browser-use with `TaskReport` as its structured
  output schema, streams one JSON event per line. Knows nothing about any site.
- `Sources/Claudette/Services/BrowserUseService.swift` — finds a Python with
  browser-use, spawns the sidecar, feeds it the spec, parses the event stream.
- `Sources/Claudette/Services/TaskScheduler.swift` — fires scheduled recipes, queues
  them behind each other, files the results.
- `Sources/Claudette/Services/RecipeStore.swift` — reads your recipe folder.
- `Sources/Claudette/Services/RecipeComposer.swift` — `/recipe`: asks the `claude` CLI
  for a recipe and validates what comes back before the sheet offers to save it.
- `Sources/Claudette/Models/`, `Sources/Claudette/Views/Browser/` — the report, the
  recipe format, the panel and the cards.

The spec goes over stdin rather than argv: it carries your rules, and argv is readable
by every process on the machine.

## When it goes wrong

| Symptom | Cause |
| --- | --- |
| "browser-use isn't installed in…" | The interpreter Claudette found doesn't have the package. Install from Settings, or point **Python** at one that does. |
| "Claudette needs Python 3.11 or newer" | macOS ships 3.9. `brew install uv` or `brew install python@3.12`. |
| Run stops with `not signed in` | The profile's session expired or was never created. Settings → Browser agent → **Sign in to a site**. |
| Run stops with a rate-limit note | The site is throttling. Wait it out; the agent won't try to work around it. |
| Scheduled run never happened | Is the master switch on? Was Claudette open at the time? Does the recipe have a `goal` in the file? The panel shows warnings for a recipe it can't schedule. |
| Empty report | Usually too broad a goal. Narrow it, or raise the step budget. |
| `/recipe` says it can't find `claude` | Recipe writing uses the Claude Code CLI. Install it and run `claude auth`. |
| `/recipe` returned something odd | Press **Start over** and describe it differently — nothing was saved. |

The **Agent log** disclosure at the bottom of the panel has the sidecar's stderr, which
is where browser-use's own logging goes.

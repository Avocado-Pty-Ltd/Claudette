#!/usr/bin/env python3
"""
LinkedIn prospecting sidecar for Claudette.

Drives the open-source `browser-use` agent (https://github.com/browser-use/browser-use)
against LinkedIn in the user's own logged-in Chrome profile, and returns a
*research report*: people worth connecting with, and drafted comments for posts
worth engaging on.

This process NEVER sends a connection request and NEVER publishes a comment.
It reads, reasons, and drafts. Every draft is reviewed and sent by the human in
Claudette's prospect panel. That's a deliberate product decision — LinkedIn's
User Agreement prohibits automated connecting and posting, and a note the human
didn't read isn't worth sending anyway.

Protocol: newline-delimited JSON on stdout, one event per line.

    {"type": "ready",  "browserUse": "0.13.10", "python": "3.12.4"}
    {"type": "status", "message": "Launching Chrome…"}
    {"type": "step",   "step": 3, "url": "...", "title": "...",
                       "goal": "...", "evaluation": "...", "actions": ["navigate"]}
    {"type": "result", "report": { ...ProspectReport... }}
    {"type": "done",   "steps": 14, "durationSeconds": 92.4}
    {"type": "error",  "message": "...", "kind": "missing_dependency"}

Anything browser-use itself logs goes to stderr, so stdout stays parseable.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import signal
import sys
import time
from typing import Any, Literal

# browser-use defaults its own logging to stderr, but pin it explicitly: a stray
# log line on stdout would corrupt the event stream Claudette is parsing.
os.environ.setdefault("BROWSER_USE_SETUP_LOGGING", "true")
os.environ.setdefault("ANONYMIZED_TELEMETRY", "false")

# LinkedIn's connection-note field caps at 300 characters. Draft to 280 so an
# edit in the review panel doesn't immediately overflow it.
CONNECTION_NOTE_LIMIT = 280
COMMENT_LIMIT = 500

# Actions removed from the agent's toolbelt for this run. Navigation, clicking
# and extraction stay — that's how you search LinkedIn at all — but arbitrary
# JavaScript and file uploads have no business in a research pass.
EXCLUDED_ACTIONS = ["evaluate", "upload_file"]


def emit(event: dict[str, Any]) -> None:
    """Write one protocol event. Flushed immediately so the UI stays live."""
    sys.stdout.write(json.dumps(event, ensure_ascii=False) + "\n")
    sys.stdout.flush()


class SidecarExit(Exception):
    """Unwind to `main` after reporting a fatal problem.

    Deliberately not `SystemExit`: raising that inside a coroutine leaves
    asyncio printing "Task exception was never retrieved" over the top of the
    error we just reported, which is exactly the noise Claudette's log
    shouldn't be full of.
    """

    def __init__(self, code: int = 1) -> None:
        super().__init__(f"sidecar exit {code}")
        self.code = code


def fail(message: str, kind: str = "error", exit_code: int = 1, **extra: Any) -> None:
    emit({"type": "error", "message": message, "kind": kind, "executable": sys.executable, **extra})
    raise SidecarExit(exit_code)


# ---------------------------------------------------------------------------
# Structured output — this is the contract with Claudette's Swift decoder.
# ---------------------------------------------------------------------------

try:
    from pydantic import BaseModel, Field
except ImportError:  # pragma: no cover - dependency probe
    emit(
        {
            "type": "error",
            "message": (
                "pydantic is not installed in this Python environment. "
                "Install the prospecting dependencies from Claudette → Settings → LinkedIn."
            ),
            "kind": "missing_dependency",
            "executable": sys.executable,
        }
    )
    sys.exit(1)


class DraftComment(BaseModel):
    """A comment Claudette drafted for one specific post. Never posted by the agent."""

    post_url: str = Field(default="", description="Permalink to the post being commented on.")
    author: str = Field(default="", description="Who wrote the post.")
    post_summary: str = Field(default="", description="One sentence on what the post says.")
    posted_at: str = Field(default="", description="Relative age as LinkedIn shows it, e.g. '2d'.")
    draft: str = Field(default="", description=f"The comment to post, under {COMMENT_LIMIT} characters.")
    rationale: str = Field(default="", description="Why this post is worth commenting on for the goal.")


class Prospect(BaseModel):
    """One person worth connecting with, plus the note to send them."""

    name: str
    headline: str = ""
    profile_url: str = ""
    location: str = ""
    company: str = ""
    mutual_connections: str = Field(default="", description="e.g. '12 mutual connections' if visible.")
    why: str = Field(default="", description="Why this person matches the stated goal.")
    confidence: Literal["high", "medium", "low"] = "medium"
    connection_note: str = Field(
        default="",
        description=f"Personalised connection note, under {CONNECTION_NOTE_LIMIT} characters.",
    )
    comments: list[DraftComment] = Field(
        default_factory=list,
        description="Drafted comments on this person's recent posts, if any were found.",
    )


class ProspectReport(BaseModel):
    goal: str = ""
    summary: str = Field(default="", description="Two or three sentences on what the search found.")
    prospects: list[Prospect] = Field(default_factory=list)
    standalone_comments: list[DraftComment] = Field(
        default_factory=list,
        description="Posts worth commenting on whose author isn't in the prospect list.",
    )
    blocked_reason: str = Field(
        default="",
        description=(
            "Set only when the search could not be completed — e.g. 'not logged in', "
            "'hit a search limit'. Empty on a normal run."
        ),
    )


# ---------------------------------------------------------------------------
# Prompt construction
# ---------------------------------------------------------------------------

VOICE_RULES = f"""
Writing rules for every draft you produce:
- Write as the user, in first person, plainly. No emoji, no hashtags, no "Great post!",
  no "I'd love to connect and explore synergies".
- Every draft must cite something specific and verifiable that you actually read on the
  page — a line from their headline, a claim in their post, the company they just joined.
  If you can't name something specific, say so in `why` and leave confidence "low".
- Connection notes: under {CONNECTION_NOTE_LIMIT} characters, one or two sentences, and a
  concrete reason you're reaching out. No pitch.
- Comments: under {COMMENT_LIMIT} characters. Add something — an example, a counterpoint, a
  question you genuinely have. A comment that only agrees is not worth posting.
""".strip()

SAFETY_RULES = """
Hard constraints on this run:
- You are doing RESEARCH ONLY. Never click "Connect", "Follow", "Send", "Post", "Submit",
  "Reply", or any button that would contact someone or publish anything. Never type into a
  comment box or a message box. The human reviews and sends everything themselves.
- Stay on linkedin.com.
- Do not attempt to view profiles behind a paywall, and never try to defeat a login wall,
  captcha or rate limit. If you hit one, stop and report it in `blocked_reason`.
- If LinkedIn shows you're logged out, stop immediately and set `blocked_reason` to
  "not logged in" rather than trying to sign in.
- Don't collect email addresses, phone numbers or anything else the profile doesn't
  publicly show on the page you're reading.
""".strip()


def build_task(args: argparse.Namespace) -> str:
    wants_contacts = args.mode in ("contacts", "both")
    wants_comments = args.mode in ("comments", "both")

    steps: list[str] = []
    if wants_contacts:
        steps.append(
            f"""
1. Find up to {args.max_contacts} people who match the goal.
   Start from LinkedIn people search — https://www.linkedin.com/search/results/people/?keywords=<terms> —
   and refine the keywords as you learn what the good results look like. Use the filters
   (location, current company, industry) when the goal names them.
   Open the promising profiles to confirm the match before you include them. A profile you
   only saw as a search-result row is a "low" confidence prospect at best.
   For each one, fill in `name`, `headline`, `profile_url` (the canonical /in/… URL),
   `location`, `company`, `why`, `confidence`, and a `connection_note`.
""".strip()
        )
    if wants_comments:
        steps.append(
            f"""
{2 if wants_contacts else 1}. Find posts worth commenting on.
   Use content search — https://www.linkedin.com/search/results/content/?keywords=<terms> —
   and the recent activity of the people you shortlisted ({{profile}}/recent-activity/all/).
   Prefer posts from the last two weeks with real substance and few enough comments that a
   reply will be read. Aim for about {args.max_comments} in total.
   If the post's author is one of your prospects, attach the draft to that prospect's
   `comments`. Otherwise put it in `standalone_comments`.
   Capture the post permalink in `post_url` — open the post's own page if you need to.
""".strip()
        )

    about = (
        f"\nWho the notes and comments are coming from:\n{args.about_me.strip()}\n"
        if args.about_me and args.about_me.strip()
        else "\nThe user hasn't described themselves. Keep the drafts modest and curious "
        "rather than claiming shared background you can't verify.\n"
    )

    tone = f"\nRequested tone: {args.tone.strip()}.\n" if args.tone and args.tone.strip() else ""

    return f"""
You are researching LinkedIn on behalf of the user, inside their own logged-in browser.

THE GOAL, in the user's words:
{args.goal.strip()}
{about}{tone}
What to do:

{chr(10).join(steps)}

{len(steps) + 1}. Call `done` with the structured report. Put two or three sentences in
   `summary` covering what you searched, what you found, and anything the user should know
   before they send. Leave `blocked_reason` empty unless something actually stopped you.

{SAFETY_RULES}

{VOICE_RULES}

Quality bar: {args.max_contacts} mediocre prospects are worth less than three you can
justify. It is a good outcome to return fewer, better-researched entries and explain the
shortfall in `summary`.
""".strip()


# ---------------------------------------------------------------------------
# LLM selection
# ---------------------------------------------------------------------------

DEFAULT_MODELS = {
    "anthropic": "claude-sonnet-4-5",
    "openai": "gpt-4.1-mini",
    "google": "gemini-2.5-flash",
    "ollama": "qwen2.5:7b",
}

API_KEY_ENV = {
    "anthropic": "ANTHROPIC_API_KEY",
    "openai": "OPENAI_API_KEY",
    "google": "GOOGLE_API_KEY",
}


def build_llm(provider: str, model: str | None):
    """Instantiate the browser-use chat model for `provider`.

    Keys are read from the environment by each provider's SDK; Claudette puts
    them there from the Keychain rather than passing them on argv, where they'd
    be visible to every process on the machine via `ps`.
    """
    name = model or DEFAULT_MODELS.get(provider) or ""
    if not name:
        fail(f"No model configured for provider '{provider}'.", kind="config")

    env_key = API_KEY_ENV.get(provider)
    if env_key and not os.environ.get(env_key):
        fail(
            f"{env_key} is not set. Add the key in Claudette → Settings → LinkedIn, "
            "or switch the provider to Ollama to run locally without a key.",
            kind="missing_key",
        )

    if provider == "anthropic":
        from browser_use import ChatAnthropic

        return ChatAnthropic(model=name)
    if provider == "openai":
        from browser_use import ChatOpenAI

        return ChatOpenAI(model=name)
    if provider == "google":
        from browser_use import ChatGoogle

        return ChatGoogle(model=name)
    if provider == "ollama":
        from browser_use import ChatOllama

        return ChatOllama(model=name, host=os.environ.get("OLLAMA_HOST", "http://localhost:11434"))

    fail(f"Unknown provider '{provider}'.", kind="config")


# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------


async def run(args: argparse.Namespace) -> int:
    try:
        from browser_use import Agent, BrowserProfile, BrowserSession, Tools
    except ImportError as exc:
        fail(
            f"browser-use is not installed in this Python environment ({sys.executable}): {exc}. "
            "Install it from Claudette → Settings → LinkedIn, or run "
            "`pip install browser-use` yourself and point Claudette at that interpreter.",
            kind="missing_dependency",
        )

    try:
        from importlib.metadata import version as pkg_version

        bu_version = pkg_version("browser-use")
    except Exception:
        bu_version = "unknown"

    emit(
        {
            "type": "ready",
            "browserUse": bu_version,
            "python": ".".join(str(p) for p in sys.version_info[:3]),
            "executable": sys.executable,
        }
    )

    llm = build_llm(args.provider, args.model)

    emit({"type": "status", "message": "Opening Chrome with your LinkedIn session…"})

    profile_kwargs: dict[str, Any] = {
        "headless": args.headless,
        # Keep the agent on LinkedIn. Even a well-behaved model wanders when a
        # profile links out; this makes wandering impossible rather than unlikely.
        "allowed_domains": ["*.linkedin.com", "linkedin.com"],
        "keep_alive": False,
    }
    if args.user_data_dir:
        # A persistent profile is the whole login story: the user signs into
        # LinkedIn once, by hand, in this profile — Claudette never sees or
        # stores a LinkedIn password.
        profile_kwargs["user_data_dir"] = os.path.expanduser(args.user_data_dir)
    if args.chrome_path:
        profile_kwargs["executable_path"] = os.path.expanduser(args.chrome_path)

    browser_session = BrowserSession(browser_profile=BrowserProfile(**profile_kwargs))
    tools = Tools(exclude_actions=list(EXCLUDED_ACTIONS))

    step_count = 0

    async def on_step(browser_state, agent_output, step_number: int) -> None:
        nonlocal step_count
        step_count = step_number
        actions: list[str] = []
        for action in getattr(agent_output, "action", None) or []:
            try:
                dumped = action.model_dump(exclude_none=True)
                actions.extend(dumped.keys())
            except Exception:
                continue
        emit(
            {
                "type": "step",
                "step": step_number,
                "url": getattr(browser_state, "url", "") or "",
                "title": getattr(browser_state, "title", "") or "",
                "goal": getattr(agent_output, "next_goal", "") or "",
                "evaluation": getattr(agent_output, "evaluation_previous_goal", "") or "",
                "actions": actions,
            }
        )

    agent = Agent(
        task=build_task(args),
        llm=llm,
        browser_session=browser_session,
        tools=tools,
        output_model_schema=ProspectReport,
        register_new_step_callback=on_step,
        use_vision=not args.no_vision,
        max_actions_per_step=4,
        # Claudette owns process lifecycle: it sends SIGTERM on Cancel. Letting
        # browser-use install its own SIGINT/SIGTERM handlers on top swallows that.
        enable_signal_handler=False,
    )

    started = time.monotonic()
    try:
        history = await agent.run(max_steps=args.max_steps)
    except asyncio.CancelledError:
        emit({"type": "status", "message": "Cancelled."})
        return 130
    except Exception as exc:  # noqa: BLE001 - surface anything to the UI rather than dying silently
        emit({"type": "error", "message": f"{type(exc).__name__}: {exc}", "kind": "agent"})
        return 1
    finally:
        try:
            await browser_session.kill()
        except Exception:
            pass

    report: ProspectReport | None = None
    try:
        report = history.structured_output  # type: ignore[assignment]
    except Exception as exc:
        emit({"type": "status", "message": f"Could not parse the structured report: {exc}"})

    if report is None:
        final = history.final_result() if hasattr(history, "final_result") else None
        emit(
            {
                "type": "error",
                "message": (
                    "The agent finished without returning a structured report. "
                    + (f"Its last words: {str(final)[:400]}" if final else "It returned nothing.")
                ),
                "kind": "no_result",
            }
        )
        return 1

    payload = report.model_dump()
    payload["goal"] = payload.get("goal") or args.goal
    emit({"type": "result", "report": payload})
    emit(
        {
            "type": "done",
            "steps": step_count,
            "durationSeconds": round(time.monotonic() - started, 1),
        }
    )
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Claudette's LinkedIn prospecting sidecar.")
    p.add_argument("--goal", required=True, help="What the user is trying to achieve, in their words.")
    p.add_argument("--mode", choices=["contacts", "comments", "both"], default="both")
    p.add_argument("--max-contacts", type=int, default=8)
    p.add_argument("--max-comments", type=int, default=5)
    p.add_argument("--max-steps", type=int, default=60)
    p.add_argument("--provider", choices=sorted(DEFAULT_MODELS), default="anthropic")
    p.add_argument("--model", default=None, help="Override the provider's default model.")
    p.add_argument("--headless", action="store_true", help="Run Chrome without a visible window.")
    p.add_argument("--no-vision", action="store_true", help="Skip screenshots — cheaper, less reliable.")
    p.add_argument("--user-data-dir", default=None, help="Chrome profile holding the LinkedIn login.")
    p.add_argument("--chrome-path", default=None, help="Chrome/Chromium binary to drive.")
    p.add_argument("--about-me", default="", help="How the user describes themselves, for voice.")
    p.add_argument("--tone", default="", help="Requested tone for the drafts.")
    return p.parse_args(argv)


def main() -> None:
    args = parse_args(sys.argv[1:])

    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    task = loop.create_task(run(args))

    def cancel(*_: Any) -> None:
        task.cancel()

    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            loop.add_signal_handler(sig, cancel)
        except (NotImplementedError, RuntimeError):
            signal.signal(sig, cancel)

    try:
        code = loop.run_until_complete(task)
    except SidecarExit as exc:
        code = exc.code
    except asyncio.CancelledError:
        code = 130
    finally:
        try:
            loop.close()
        except Exception:
            pass
    sys.exit(code)


if __name__ == "__main__":
    main()

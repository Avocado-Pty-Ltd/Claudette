#!/usr/bin/env python3
"""
Browser-task sidecar for Claudette.

Runs the open-source `browser-use` agent (https://github.com/browser-use/browser-use)
against a goal the user typed, and returns a structured report: what it found, why
each thing matters, and any text it was asked to draft.

This file knows nothing about any particular website. Everything site-specific —
where to start, which domains to stay on, what "a good result" means, what drafts to
write — arrives at runtime in a task spec on stdin, which Claudette builds from the
user's own recipe file. Keep it that way: rules for one company's workflow belong in
that user's recipe, not in this repository.

Protocol
--------
Input:  one JSON task spec on stdin (see `TaskSpec` below), then EOF.
Output: newline-delimited JSON on stdout, one event per line.

    {"type": "ready",  "browserUse": "0.13.10", "python": "3.12.4", "executable": "…"}
    {"type": "status", "message": "Launching the browser…"}
    {"type": "step",   "step": 3, "url": "…", "title": "…",
                       "goal": "…", "evaluation": "…", "actions": ["navigate"]}
    {"type": "result", "report": { …TaskReport… }}
    {"type": "done",   "steps": 14, "durationSeconds": 92.4}
    {"type": "error",  "message": "…", "kind": "missing_dependency", "executable": "…"}

browser-use logs to stderr, so stdout stays parseable.
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

# browser-use defaults its own logging to stderr, but pin the intent explicitly:
# a stray log line on stdout would corrupt the event stream Claudette parses.
os.environ.setdefault("BROWSER_USE_SETUP_LOGGING", "true")
os.environ.setdefault("ANONYMIZED_TELEMETRY", "false")

# Actions removed from the agent's toolbelt. Navigation, clicking and extraction
# stay — that's how you browse at all — but arbitrary JavaScript and file uploads
# have no business in a research run.
EXCLUDED_ACTIONS = ["evaluate", "upload_file"]

# Additionally excluded when the task runs read-only.
INTERACTION_ACTIONS = ["send_keys"]


def emit(event: dict[str, Any]) -> None:
    """Write one protocol event. Flushed immediately so the UI stays live."""
    sys.stdout.write(json.dumps(event, ensure_ascii=False) + "\n")
    sys.stdout.flush()


class SidecarExit(Exception):
    """Unwind to `main` after reporting a fatal problem.

    Deliberately not `SystemExit`: raising that inside a coroutine leaves asyncio
    printing "Task exception was never retrieved" over the top of the error we just
    reported, which is exactly the noise Claudette's log shouldn't be full of.
    """

    def __init__(self, code: int = 1) -> None:
        super().__init__(f"sidecar exit {code}")
        self.code = code


def fail(message: str, kind: str = "error", exit_code: int = 1, **extra: Any) -> None:
    emit({"type": "error", "message": message, "kind": kind, "executable": sys.executable, **extra})
    raise SidecarExit(exit_code)


# ---------------------------------------------------------------------------
# Structured output — the contract with Claudette's Swift decoder.
# ---------------------------------------------------------------------------

try:
    from pydantic import BaseModel, Field
except ImportError:  # pragma: no cover - dependency probe
    emit(
        {
            "type": "error",
            "message": (
                "pydantic is not installed in this Python environment. "
                "Install the browser-agent dependencies from Claudette → Settings → Browser agent."
            ),
            "kind": "missing_dependency",
            "executable": sys.executable,
        }
    )
    sys.exit(1)


class Draft(BaseModel):
    """A piece of text the agent was asked to write. Never submitted anywhere."""

    label: str = Field(default="", description="Which requested draft this is, copied verbatim.")
    text: str = Field(default="", description="The drafted text itself.")
    target_url: str = Field(default="", description="Page where this draft would be used, if different from the finding's URL.")


class Finding(BaseModel):
    """One result. A person, a page, a product, a post — whatever the goal was about."""

    title: str = Field(description="What this is — a name, a headline, a product.")
    subtitle: str = Field(default="", description="One line of context under the title.")
    url: str = Field(default="", description="Canonical link to this result.")
    details: list[str] = Field(
        default_factory=list,
        description="Short factual chips read off the page, e.g. a company, a location, a price.",
    )
    why: str = Field(default="", description="Why this result matches the goal.")
    confidence: Literal["high", "medium", "low"] = "medium"
    drafts: list[Draft] = Field(default_factory=list, description="One entry per requested draft.")


class TaskReport(BaseModel):
    goal: str = ""
    summary: str = Field(default="", description="Two or three sentences on what was searched and found.")
    findings: list[Finding] = Field(default_factory=list)
    blocked_reason: str = Field(
        default="",
        description=(
            "Set only when the run could not be completed — e.g. 'not signed in', "
            "'hit a rate limit'. Empty on a normal run."
        ),
    )


# ---------------------------------------------------------------------------
# Task spec — everything site-specific, supplied by the caller.
# ---------------------------------------------------------------------------


class DraftSlot(BaseModel):
    label: str
    limit: int | None = Field(default=None, description="Character cap for this draft, if the destination has one.")
    guidance: str = ""


class TaskSpec(BaseModel):
    goal: str
    """Free-text rules from the user's recipe. Injected verbatim — this is where
    anything site-specific or workflow-specific lives."""
    instructions: str = ""
    start_url: str = ""
    allowed_domains: list[str] = Field(default_factory=list)
    max_findings: int = 8
    read_only: bool = True
    persona: str = ""
    tone: str = ""
    drafts: list[DraftSlot] = Field(default_factory=list)


READ_ONLY_RULES = """
This run is READ-ONLY. You are gathering information and writing drafts; you are not
acting on the user's behalf.

- Never click a button that sends, submits, posts, publishes, applies, connects,
  follows, subscribes, buys, or deletes.
- Never type into a message box, comment box or contact form.
- Never sign in, sign up, or enter credentials. If a page needs an account and you
  aren't already signed in, stop and say so in `blocked_reason`.
- Never try to get around a paywall, captcha or rate limit. If you hit one, stop and
  report it in `blocked_reason`.
- Searching, filtering, sorting, paginating and expanding "see more" are all fine —
  they're how you read a site.

The user reviews everything you draft and sends it themselves.
""".strip()

INTERACTIVE_RULES = """
This run may interact with pages: you can fill in forms and click through flows when the
goal requires it.

- Still never enter credentials, payment details, or anything the user hasn't given you.
- Still never try to get around a paywall, captcha or rate limit — stop and report it in
  `blocked_reason`.
- Stop and report rather than guessing if an action looks destructive or irreversible.
""".strip()

WRITING_RULES = """
Rules for every draft you produce:
- Write as the user, in first person, plainly. No emoji, no hashtags, no filler
  enthusiasm, no "I'd love to explore synergies".
- Cite something specific you actually read on the page. If you can't name something
  specific, say so in `why` and set confidence to "low".
- Set each draft's `label` to exactly the label you were asked for, so the app can
  match it up.
""".strip()


def build_task(spec: TaskSpec) -> str:
    sections: list[str] = [
        "You are browsing the web on behalf of the user, in their own browser.",
        f"THE GOAL, in the user's words:\n{spec.goal.strip()}",
    ]

    if spec.persona.strip():
        sections.append(f"Who you are acting for:\n{spec.persona.strip()}")
    if spec.tone.strip():
        sections.append(f"Requested tone for anything you write: {spec.tone.strip()}")
    if spec.start_url.strip():
        sections.append(f"Start here: {spec.start_url.strip()}")
    if spec.instructions.strip():
        # The user's own recipe. Verbatim, and given its own heading so the model
        # treats it as instruction rather than background.
        sections.append(f"The user's rules for this kind of task:\n{spec.instructions.strip()}")

    steps = [
        f"1. Find up to {spec.max_findings} results that match the goal. Open them to confirm "
        "the match before including them — something you only saw in a list of search results "
        'is a "low" confidence finding at best. For each, fill in `title`, `subtitle`, `url`, '
        "`details`, `why` and `confidence`.",
    ]
    if spec.drafts:
        wanted = []
        for slot in spec.drafts:
            line = f'- "{slot.label}"'
            if slot.limit:
                line += f" — under {slot.limit} characters"
            if slot.guidance.strip():
                line += f". {slot.guidance.strip()}"
            wanted.append(line)
        steps.append(
            "2. For each finding, write these drafts into its `drafts` list:\n" + "\n".join(wanted)
        )
    steps.append(
        f"{len(steps) + 1}. Call `done` with the structured report. Put two or three sentences in "
        "`summary` covering what you searched, what you found, and anything the user should know. "
        "Leave `blocked_reason` empty unless something actually stopped you."
    )
    sections.append("What to do:\n\n" + "\n\n".join(steps))

    sections.append(READ_ONLY_RULES if spec.read_only else INTERACTIVE_RULES)
    if spec.drafts:
        sections.append(WRITING_RULES)
    sections.append(
        f"Quality bar: {spec.max_findings} mediocre results are worth less than three you can "
        "justify. Returning fewer, better-researched findings and explaining the shortfall in "
        "`summary` is a good outcome."
    )
    return "\n\n".join(sections)


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

    Keys are read from the environment by each provider's SDK; Claudette puts them
    there from the Keychain rather than passing them on argv, where `ps` would show
    them to every process on the machine.
    """
    name = model or DEFAULT_MODELS.get(provider) or ""
    if not name:
        fail(f"No model configured for provider '{provider}'.", kind="config")

    env_key = API_KEY_ENV.get(provider)
    if env_key and not os.environ.get(env_key):
        fail(
            f"{env_key} is not set. Add the key in Claudette → Settings → Browser agent, "
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


def read_spec() -> TaskSpec:
    raw = sys.stdin.read()
    if not raw.strip():
        fail("No task spec on stdin.", kind="config")
    try:
        return TaskSpec.model_validate_json(raw)
    except Exception as exc:  # noqa: BLE001 - the message is the whole point
        fail(f"Task spec was not valid: {exc}", kind="config")
        raise  # unreachable; keeps type checkers happy


async def run(args: argparse.Namespace, spec: TaskSpec) -> int:
    try:
        from browser_use import Agent, BrowserProfile, BrowserSession, Tools
    except ImportError as exc:
        fail(
            f"browser-use is not installed in this Python environment ({sys.executable}): {exc}. "
            "Install it from Claudette → Settings → Browser agent, or run "
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

    emit({"type": "status", "message": "Opening the browser…"})

    profile_kwargs: dict[str, Any] = {"headless": args.headless, "keep_alive": False}
    if spec.allowed_domains:
        # Fencing the agent to the domains the task actually needs. Even a
        # well-behaved model wanders when a page links out; this makes wandering
        # impossible rather than unlikely.
        profile_kwargs["allowed_domains"] = list(spec.allowed_domains)
    if args.user_data_dir:
        # A persistent profile is the whole sign-in story: the user signs into
        # whatever site they care about once, by hand, in this profile. Claudette
        # never sees or stores a password.
        profile_kwargs["user_data_dir"] = os.path.expanduser(args.user_data_dir)
    if args.chrome_path:
        profile_kwargs["executable_path"] = os.path.expanduser(args.chrome_path)

    browser_session = BrowserSession(browser_profile=BrowserProfile(**profile_kwargs))

    excluded = list(EXCLUDED_ACTIONS)
    if spec.read_only:
        excluded += INTERACTION_ACTIONS
    tools = Tools(exclude_actions=excluded)

    step_count = 0

    async def on_step(browser_state, agent_output, step_number: int) -> None:
        nonlocal step_count
        step_count = step_number
        actions: list[str] = []
        for action in getattr(agent_output, "action", None) or []:
            try:
                actions.extend(action.model_dump(exclude_none=True).keys())
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
        task=build_task(spec),
        llm=llm,
        browser_session=browser_session,
        tools=tools,
        output_model_schema=TaskReport,
        register_new_step_callback=on_step,
        use_vision=not args.no_vision,
        max_actions_per_step=4,
        # Claudette owns process lifecycle: it sends SIGTERM on Stop. Letting
        # browser-use install its own handlers on top swallows that.
        enable_signal_handler=False,
    )

    started = time.monotonic()
    try:
        history = await agent.run(max_steps=args.max_steps)
    except asyncio.CancelledError:
        emit({"type": "status", "message": "Cancelled."})
        return 130
    except Exception as exc:  # noqa: BLE001 - surface anything rather than dying silently
        emit({"type": "error", "message": f"{type(exc).__name__}: {exc}", "kind": "agent"})
        return 1
    finally:
        try:
            await browser_session.kill()
        except Exception:
            pass

    report: TaskReport | None = None
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
    payload["goal"] = payload.get("goal") or spec.goal
    emit({"type": "result", "report": payload})
    emit({"type": "done", "steps": step_count, "durationSeconds": round(time.monotonic() - started, 1)})
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Claudette's browser-task sidecar. The task spec arrives as JSON on stdin."
    )
    p.add_argument("--provider", choices=sorted(DEFAULT_MODELS), default="anthropic")
    p.add_argument("--model", default=None, help="Override the provider's default model.")
    p.add_argument("--max-steps", type=int, default=60)
    p.add_argument("--headless", action="store_true", help="Run the browser without a visible window.")
    p.add_argument("--no-vision", action="store_true", help="Skip screenshots — cheaper, less reliable.")
    p.add_argument("--user-data-dir", default=None, help="Browser profile holding the user's sign-ins.")
    p.add_argument("--chrome-path", default=None, help="Chrome/Chromium binary to drive.")
    return p.parse_args(argv)


def main() -> None:
    args = parse_args(sys.argv[1:])
    try:
        spec = read_spec()
    except SidecarExit as exc:
        sys.exit(exc.code)

    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    task = loop.create_task(run(args, spec))

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

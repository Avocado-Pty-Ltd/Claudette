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
import re
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

# Controls a read-only run refuses to click, matched against an element's visible
# label. `click` and `input` can't simply be removed — they're how you search and
# paginate — so the refusal happens per-action in GuardedTools below.
#
# Deliberately NOT here: accept, agree, allow, confirm, continue, ok. Those are
# cookie and consent banners, and blocking them would end most runs on the first
# page. Also not here: bare "apply" and "save", which are far more often "Apply
# filters" and "Save search" than anything outbound.
OUTBOUND_LABEL = re.compile(
    r"\b("
    r"send|post|publish|connect|follow|unfollow|subscribe|endorse|invite|"
    r"comment|reply|share|submit|delete|remove|withdraw|donate|"
    r"buy|purchase|pay|checkout|check\s+out|place\s+order|order\s+now|"
    r"apply\s+now|easy\s+apply|submit\s+application|"
    r"sign\s+up|signup|register|join\s+now"
    r")\b",
    re.IGNORECASE,
)

# Fields a read-only run refuses to type into — composers, not search boxes.
COMPOSER_FIELD = re.compile(
    r"(add\s+a\s+comment|write\s+a\s+comment|leave\s+a\s+comment|your\s+comment|"
    r"write\s+something|share\s+an\s+update|start\s+a\s+post|say\s+something|"
    r"write\s+a\s+message|your\s+message|send\s+a\s+message|"
    r"write\s+a\s+review|your\s+review|reply|compose)",
    re.IGNORECASE,
)

# Attributes worth reading to work out what a control says, best first.
LABEL_ATTRIBUTES = (
    "aria-label", "title", "value", "placeholder", "alt", "name", "data-testid", "id"
)


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


def element_label(node: Any) -> str:
    """Best-effort visible label for a DOM node: what a person would call it."""
    parts: list[str] = []
    attributes = getattr(node, "attributes", None) or {}
    for key in LABEL_ATTRIBUTES:
        value = attributes.get(key)
        if value and isinstance(value, str):
            parts.append(value)
    value = getattr(node, "node_value", None)
    if value and isinstance(value, str):
        parts.append(value)
    try:
        text = node.get_all_children_text(max_depth=2)
        if text:
            parts.append(text)
    except Exception:
        pass
    joined = " ".join(p.strip() for p in parts if p and p.strip())
    return " ".join(joined.split())[:300]


def make_guarded_tools(base_cls: type, result_cls: type, read_only: bool):
    """Build a Tools subclass that refuses outbound actions on a read-only run.

    `Tools.act` is the single funnel every action passes through, which makes it
    the one honest place to enforce read-only. Without this, "never clicks Send"
    is a promise made only in the prompt — and a page the agent reads can try to
    talk it into ignoring the prompt.

    This is defence in depth, not a sandbox: it classifies a control by the text
    it shows, so an unlabelled or deceptively labelled button can still get
    through. It fails closed on anything it can't identify, and a refusal is not
    fatal — the agent is told why and picks another route.

    `base_cls` and `result_cls` are passed in rather than imported at module level
    because browser-use is imported lazily inside `run` — a missing install has to
    report itself as one clean event, not an ImportError traceback at startup.
    """

    class GuardedTools(base_cls):  # type: ignore[valid-type, misc]
        async def act(self, action, browser_session, **kwargs):
            if read_only:
                reason = await self._veto(action, browser_session)
                if reason:
                    emit({"type": "blocked", "reason": reason})
                    return result_cls(
                        error=(
                            f"Refused: {reason}. This run is read-only — it gathers "
                            "information and drafts text, and the person running it "
                            "acts on the result themselves. Find another way to get "
                            "what you need, or call `done` and explain what stopped you."
                        ),
                        long_term_memory=f"Read-only run refused an action: {reason}",
                    )
            return await super().act(action=action, browser_session=browser_session, **kwargs)

        async def _veto(self, action, browser_session) -> str | None:
            try:
                requested = action.model_dump(exclude_unset=True)
            except Exception:
                return "couldn't read the requested action"

            for name, params in requested.items():
                if params is None or name not in ("click", "input"):
                    continue
                if not isinstance(params, dict):
                    return f"couldn't read the parameters for `{name}`"

                index = params.get("index")
                if index is None:
                    # Coordinate clicks and the like give us nothing to classify.
                    return f"`{name}` didn't identify an element to check"
                try:
                    node = await browser_session.get_element_by_index(int(index))
                except Exception:
                    node = None
                if node is None:
                    return f"couldn't find the element `{name}` wanted to act on"

                label = element_label(node)
                if not label:
                    return f"the element `{name}` wanted to act on has no readable label"

                shown = label[:80]
                if name == "click" and OUTBOUND_LABEL.search(label):
                    return f'"{shown}" looks like a control that sends or publishes something'
                if name == "input" and COMPOSER_FIELD.search(label):
                    return f'"{shown}" looks like a message or comment box'
            return None

    return GuardedTools


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

These limits are enforced by the app, not just asked of you: an action that looks
like it sends or publishes will be refused before it runs, and you'll be told why.
If that happens, find another route or call `done` and explain what stopped you.
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
        from browser_use import ActionResult, Agent, BrowserProfile, BrowserSession, Tools
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
    tools = make_guarded_tools(Tools, ActionResult, spec.read_only)(exclude_actions=excluded)

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


async def run_sign_in(args: argparse.Namespace) -> int:
    """Open the browser on the shared profile and hold it there.

    Needed because a fresh profile is, by definition, signed out — and a normal
    run refuses to sign in and stops the moment it meets a login wall, then
    closes the browser. Without this there is no moment at which the user can
    actually sign in, which made the documented setup impossible to follow.

    No agent and no model here: the browser opens, the person drives it, and
    Claudette holds the process open until they say they're done.
    """
    try:
        from browser_use import BrowserProfile, BrowserSession
    except ImportError as exc:
        fail(
            f"browser-use is not installed in this Python environment ({sys.executable}): {exc}.",
            kind="missing_dependency",
        )

    profile_kwargs: dict[str, Any] = {
        # Always visible: the whole point is for a person to use it.
        "headless": False,
        # Survive the agent's own teardown until we're terminated.
        "keep_alive": True,
    }
    if args.user_data_dir:
        profile_kwargs["user_data_dir"] = os.path.expanduser(args.user_data_dir)
    if args.chrome_path:
        profile_kwargs["executable_path"] = os.path.expanduser(args.chrome_path)
    # Deliberately no allowed_domains: the user is driving, and a sign-in often
    # bounces through an identity provider on another domain.

    session = BrowserSession(browser_profile=BrowserProfile(**profile_kwargs))
    emit({"type": "status", "message": "Opening the browser…"})
    try:
        await session.start()
        target = (args.sign_in or "").strip()
        if target:
            await session.navigate_to(target)
        emit({"type": "signin_ready", "url": target})
        # Hold here until Claudette terminates us.
        await asyncio.Event().wait()
    except asyncio.CancelledError:
        emit({"type": "status", "message": "Closing the browser…"})
        return 0
    except Exception as exc:  # noqa: BLE001
        emit({"type": "error", "message": f"{type(exc).__name__}: {exc}", "kind": "signin"})
        return 1
    finally:
        try:
            await session.kill()
        except Exception:
            pass
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
    p.add_argument(
        "--sign-in",
        nargs="?",
        const="",
        default=None,
        metavar="URL",
        help="Open the browser on the shared profile and hold it open so the user can sign in. "
        "Reads no task spec and runs no agent.",
    )
    return p.parse_args(argv)


def main() -> None:
    args = parse_args(sys.argv[1:])

    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)

    if args.sign_in is not None:
        # Sign-in mode reads no spec — there's no task, just a browser to hold open.
        task = loop.create_task(run_sign_in(args))
    else:
        try:
            spec = read_spec()
        except SidecarExit as exc:
            sys.exit(exc.code)
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

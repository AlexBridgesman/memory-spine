"""spine_gate — process-ancestry access control for the memory vault.

Origin: a third-party desktop app picked up a global agent profile during
onboarding and read the memory packet (real incident, 2026-07-28). The app
inherited a full agent-runtime profile (an ACP runtime, not "just an LLM") and
with it the spine-* tools; it ran spine-packet and shipped the packet content
into its own model channel. The owner had agreed to "connect a model" — never
to expose memory.

Threat model, honestly:
  + catches: agent runtimes and apps that RUN spine-* tools
    (exactly the incident above; this is the realistic vector for LLM agents)
  - does NOT catch: an arbitrary `cat ~/AgentMemory/...` by any user process —
    the vault remains a plain directory. That is why rule #1 (never store
    secret VALUES in memory) stays the primary defense, not this gate.

Policy: DEFAULT-DENY. Unknown caller -> refusal + access.log entry + an alert
to the owner with a ready-to-paste approval command (spine-approve).
"""
import os
import re
import subprocess
import time

HOME = os.path.expanduser("~")
TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CFG = os.path.join(TOOLS, "config")
ALLOWLIST = os.path.join(CFG, "agent-allowlist.tsv")
LOGDIR = os.environ.get("SPINE_LOG_DIR", f"{HOME}/Library/Logs/AgentMemory")
ACCESS_LOG = os.path.join(LOGDIR, "access.log")
NOTIFY = os.path.join(TOOLS, "bin", "spine-notify")
ALERT_COOLDOWN = 1800   # 30 min per identical caller — so a retry loop cannot spam


def caller_chain(max_depth=12):
    """Ancestor chain of the process, from parent up to the root.

    We take both comm and the FULL command line: for scripts, comm shows only
    the interpreter (/bin/zsh) and the launcher path is visible only in args —
    otherwise `node /Applications/SomeAgent.app/.../agent.js` would look like
    a perfectly ordinary node.
    """
    chain = []
    pid = os.getppid()
    for _ in range(max_depth):
        try:
            out = subprocess.run(["ps", "-o", "ppid=,comm=,args=", "-p", str(pid)],
                                 capture_output=True, text=True, timeout=3).stdout.strip()
        except Exception:
            break
        if not out:
            break
        parts = out.split(None, 1)
        if len(parts) < 2:
            break
        ppid_s, rest = parts
        chain.append(rest.strip()[:400])
        try:
            pid = int(ppid_s)
        except ValueError:
            break
        if pid <= 1:
            break
    return chain


def _load_rules():
    """agent-allowlist.tsv: verdict<TAB>pattern<TAB>label<TAB>approved_by<TAB>date.
    verdict: allow | deny. Deny takes precedence over allow (checked separately)."""
    allow, deny = [], []
    try:
        with open(ALLOWLIST, encoding="utf-8") as f:
            for line in f:
                line = line.rstrip("\n")
                if not line.strip() or line.lstrip().startswith("#"):
                    continue
                cols = line.split("\t")
                if len(cols) < 3:
                    continue
                verdict, pattern, label = cols[0].strip(), cols[1].strip(), cols[2].strip()
                if not pattern:
                    continue
                (deny if verdict == "deny" else allow).append((pattern, label))
    except OSError:
        pass   # no dictionary -> fail-safe branch below
    return allow, deny


def _log(verdict, action, scope, agent, chain, label):
    try:
        os.makedirs(os.path.dirname(ACCESS_LOG), exist_ok=True)
        with open(ACCESS_LOG, "a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%F %T')}\t{verdict}\t{action}\t{scope or '-'}\t"
                    f"{agent}\t{label}\t{' <- '.join(chain[:5])}\n")
    except OSError:
        pass


# NEVER suggest bare shells/interpreters (a "zsh" pattern would open memory to
# every script on the machine), and never launchd — the root of EVERY macOS
# process chain; such an allowlist line admits literally everyone (the same
# warning lives in agent-allowlist.tsv).
_NO_SUGGEST = {"zsh", "bash", "sh", "dash", "python", "python3", "node", "env",
               "osascript", "perl", "ruby", "launchd"}


def _suggest_pattern(chain):
    """A ready-to-paste pattern for spine-approve instead of a "<path fragment>"
    placeholder (UX fix 2026-07-30: the owner once received an alert with the
    literal placeholder and had nothing to copy). The best pattern is the .app
    bundle name anywhere in the entry (it also catches
    `node /Applications/SomeAgent.app/.../agent.js`); otherwise the executable
    basename, SKIPPING bare shells/interpreters: suggesting "zsh" = advising
    the owner to open memory to every script in the system."""
    for entry in chain:
        m = re.search(r"/([^/ ]+\.app)/", entry)
        if m:
            return m.group(1)
        toks = entry.split()
        base = os.path.basename(toks[0]) if toks else ""
        if base and base.lower() not in _NO_SUGGEST:
            return base
    return ""


def _alert(action, scope, agent, chain, suggest=True):
    """Owner alert (via spine-notify) with a per-caller cooldown."""
    key = (chain[0] if chain else "unknown").replace("/", "_")[-60:]
    mark = os.path.join(LOGDIR, f".gate-alert-{abs(hash(key)) % 10**8}")
    now = time.time()
    try:
        if os.path.exists(mark) and now - os.stat(mark).st_mtime < ALERT_COOLDOWN:
            return
        open(mark, "w").close()
    except OSError:
        pass
    who = " ← ".join(os.path.basename(c) for c in chain[:4]) or "unknown"
    hint = _suggest_pattern(chain) if suggest else ""
    if suggest:
        tail = (f"Approve (if this is you): spine-approve \"{hint}\" \"label\"" if hint
                else "Approve (if this is you): spine-approve \"<path fragment>\" \"label\"")
    else:
        tail = ("Caller is denylisted (deny > allow) — only the owner can lift this "
                "in config/agent-allowlist.tsv.")
    msg = (f"🔒 Spine: memory access BLOCKED\n"
           f"action: {action}{(' scope ' + scope) if scope else ''}\n"
           f"caller: {who}\n"
           f"agent={agent}\n"
           f"{tail}")
    try:
        subprocess.run([NOTIFY, msg], timeout=60,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


BINDIR = os.path.join(TOOLS, "bin")


def _parent_exe():
    """Executable path of the PARENT without `ps` — the fallback for sandboxes
    where ps is unavailable (seen with Codex under its seatbelt profile,
    2026-07-29). libproc.proc_pidpath is always available on macOS."""
    try:
        import ctypes
        lib = ctypes.CDLL("/usr/lib/libSystem.dylib")
        buf = ctypes.create_string_buffer(4096)
        n = lib.proc_pidpath(ctypes.c_int(os.getppid()), buf, ctypes.c_uint32(4096))
        return buf.value.decode("utf-8", "replace") if n > 0 else ""
    except Exception:
        return ""


def _is_own_tool(entry):
    """Is this ancestor a Spine tool ITSELF — not just anyone whose command
    line happens to contain the word "spine-"? We look only at the FIRST TWO
    tokens: argv[0] = the executable, argv[1] = the script for an interpreter
    (`/bin/bash .../bin/spine-health`, `/usr/bin/python3 .../bin/spine-recall`).
    A `bash -c "true spine-recall; ..."` bypass does not slip through here:
    its argv[1] is "-c". Found by an audit on 2026-07-28 — the previous
    pattern (`allow spine-`) self-authorized anyone who merely ran one of our
    own tools."""
    for tok in entry.split()[:2]:
        if tok.startswith(BINDIR + "/") or tok.startswith(BINDIR + "\\"):
            return True
    return False


def check(action, scope=None, agent=None):
    """Returns (allowed: bool, human_message: str). Call BEFORE handing out data."""
    agent = agent or os.environ.get("SPINE_AGENT", "shared")
    chain = caller_chain()
    hay = " ".join(chain).lower()
    allow, deny = _load_rules()

    # An EMPTY CHAIN is NOT an attacker (bug 2026-07-29: a legitimate agent
    # running inside its own seatbelt sandbox could not see `ps`, so
    # caller_chain() returned [] and the agent got DENY as an "unknown
    # caller"). The caller data is simply MISSING — so decide on an
    # independent signal: the parent process we can read directly through the
    # /proc analogue, or, if even that is gone, fall back to the parent
    # executable path.
    if not chain:
        parent = _parent_exe()
        if parent:
            chain = [parent]
            hay = parent.lower()
        else:
            # No caller data at all. The trade-off is deliberate: a silent
            # DENIAL breaks legitimate sandboxed agents (exactly what happened
            # on 2026-07-29), while a silent allow breaks security. So we
            # allow, but LOUDLY: a distinct verdict in the log + an owner alert.
            _log("ALLOW-NOCHAIN", action, scope, agent, ["(chain unavailable)"],
                 "ps and proc_pidpath unavailable — the caller cannot be identified")
            _alert(f"{action} (caller NOT identified)", scope, agent,
                   ["identification impossible: neither ps nor proc_pidpath"])
            return True, ""

    for pattern, label in deny:
        if pattern.lower() in hay:
            _log("DENY", action, scope, agent, chain, label)
            _alert(action, scope, agent, chain, suggest=False)
            return False, (f"spine: memory access BLOCKED — the caller is denylisted "
                           f"({label}). This is the owner's decision; only the owner can lift it.")

    if not allow:
        # dictionary missing/empty — do not brick the system, but shout
        _log("ALLOW-NOLIST", action, scope, agent, chain, "allowlist missing")
        return True, ""

    # Spine's internal chain (spine-backup -> spine-maintain -> ..., keeper,
    # selftest): allowed by the ACTUAL executable path, not by command-line text
    for entry in chain:
        if _is_own_tool(entry):
            _log("ALLOW", action, scope, agent, chain, "Spine's own tool")
            return True, ""

    for pattern, label in allow:
        if pattern.lower() in hay:
            _log("ALLOW", action, scope, agent, chain, label)
            return True, ""

    _log("DENY", action, scope, agent, chain, "unknown caller")
    _alert(action, scope, agent, chain)
    who = " ← ".join(os.path.basename(c) for c in chain[:3]) or "unknown"
    return False, (f"spine: memory access BLOCKED — the caller is not approved by the owner.\n"
                   f"  chain: {who}\n"
                   f"  memory is readable only by approved agents (default-deny policy).\n"
                   f"  The owner approves with: spine-approve \"<path fragment>\" \"label\"")


def enforce(action, scope=None, agent=None, stream=None):
    """check() + print the message to stderr. True = proceed, False = stop."""
    import sys
    ok, msg = check(action, scope, agent)
    if not ok:
        (stream or sys.stderr).write(msg + "\n")
    return ok

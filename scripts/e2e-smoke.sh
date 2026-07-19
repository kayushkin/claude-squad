#!/usr/bin/env bash
# Boot-and-answer smoke test for claude-squad.
#
# claude-squad is neither an HTTP server nor a bridge harness CLI, so neither of
# the fleet's existing smoke shapes fits. It is a full-screen Bubble Tea TUI that
# manages tmux-backed agent sessions inside a git worktree. A green `go build`
# proves none of its three real entrypoints actually run:
#
#   * version   a plain subcommand. Cheapest proof the binary links + dispatches.
#   * debug     loads config from disk (creating defaults on first run) and prints
#               the resolved config path. Exercises config.LoadConfig +
#               GetConfigDir + DefaultConfig — a real init path a build never sees.
#   * the TUI   the root command. Needs a REAL PTY: on a pipe Bubble Tea paints
#               nothing and can exit 0, so "it ran" proves nothing at all. It is
#               driven through tmux (capture-pane) so we read back the frame it
#               actually painted and can tell "booted the empty list" from
#               "panicked before the first frame".
#
# HERMETICITY IS LOAD-BEARING, NOT HYGIENE. claude-squad keeps all of its state —
# config.json, state.json, instances.json, the autoyes daemon pidfile — under
# $HOME/.claude-squad (config.go GetConfigDir joins os.UserHomeDir()). There is no
# env override, so HOME is the only lever. Run unsandboxed and:
#   - `debug`/the TUI create/read the REAL ~/.claude-squad;
#   - the root command calls daemon.StopDaemon(), which SIGTERMs whatever pid the
#     real pidfile names — i.e. a live autoyes daemon the user is running.
# So every invocation goes through `env -i HOME=<sandbox>`. The `reset` subcommand
# is DESTRUCTIVE (it deletes all instances, kills tmux sessions, and prunes git
# worktrees) and is never run here.
#
# tmux runs on a PRIVATE server (-L) so capture-pane never touches the user's live
# tmux. claude-squad itself shells out to the DEFAULT tmux server to manage its
# sessions, but only when the user creates an instance ('n') — which this smoke
# never does, so it spawns no sessions and no worktrees.
#
# Exits 0 on success, non-zero on the first failing assertion.
#
# Tunables:
#   E2E_KEEP  — "1" leaves $TMP_DIR around after the run.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN_NAME="claude-squad"

for tool in go git tmux timeout jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: required tool '$tool' not found on PATH" >&2
    exit 2
  fi
done

TMP_DIR="$(mktemp -d -t cs-e2e.XXXXXX)"
BIN_DIR="$TMP_DIR/bin"
SANDBOX_HOME="$TMP_DIR/home"
WORK_REPO="$TMP_DIR/work"       # the git repo the TUI is launched inside
NONGIT_DIR="$TMP_DIR/nongit"    # a plain dir, to prove the git-repo guard
BIN="$BIN_DIR/$BIN_NAME"
# A private tmux server. Never the user's: a nightly guard attaching to a live
# tmux could kill panes someone is working in.
TMUX_SOCKET="cs-e2e-$$"
TUI_ERR="$TMP_DIR/tui.err"
TUI_EXIT="$TMP_DIR/tui.exit"
mkdir -p "$BIN_DIR" "$SANDBOX_HOME" "$WORK_REPO" "$NONGIT_DIR"

cleanup() {
  local status=$?
  tmux -L "$TMUX_SOCKET" kill-server 2>/dev/null || true
  if [ "$status" -ne 0 ] && [ -f "$TUI_ERR" ]; then
    echo "----- tui.err -----" >&2
    cat "$TUI_ERR" >&2
  fi
  if [ "${E2E_KEEP:-}" = "1" ]; then
    echo "[e2e] keeping $TMP_DIR"
  else
    rm -rf "$TMP_DIR"
  fi
  return "$status"
}
trap cleanup EXIT INT TERM

step() { printf '\n==> %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# The binary under test, with nothing inherited: sandboxed HOME so config/state/
# pidfile land in the sandbox, and a curated PATH so the result cannot depend on
# which upstream CLIs (claude, aider, ...) happen to be installed. git + tmux both
# live in /usr/bin, which the TUI shells out to.
CS_TIMEOUT="${CS_TIMEOUT:-30}"
run_cs() {
  timeout "$CS_TIMEOUT" env -i \
    HOME="$SANDBOX_HOME" \
    PATH="/usr/bin:/bin" \
    "$BIN" "$@"
}

# ---------------------------------------------------------------------------
step "build $BIN_NAME from $REPO_DIR"
# Ambient env kept for the build so module/build caches are reused. CGO_ENABLED=0
# because the tree is pure Go (JSON-file storage, no sqlite): if a cgo driver is
# ever pulled in, the smoke should fail at the BUILD step, not ship a binary that
# compiles green and dies at runtime.
cd "$REPO_DIR"
CGO_ENABLED=0 go build -o "$BIN" . || fail "go build failed"
[ -x "$BIN" ] || fail "no binary at $BIN after build"

# ---------------------------------------------------------------------------
step "1. version answers and exits 0"
VERSION_OUT="$(run_cs version 2>&1)" || fail "version exited non-zero: $VERSION_OUT"
case "$VERSION_OUT" in
  *"claude-squad version "*) ;;
  *) fail "version did not print a version line; got: $VERSION_OUT" ;;
esac

# ---------------------------------------------------------------------------
step "2. debug loads config and reports a path UNDER the sandbox"
# This is the config init path: LoadConfig -> GetConfigDir (os.UserHomeDir) ->
# DefaultConfig, writing $HOME/.claude-squad/config.json on first run. Assert both
# that the resolved path is inside our sandbox HOME (the hermeticity proof) and
# that the emitted config is valid JSON with the expected default — either can
# break while the binary still builds and exits 0.
DEBUG_OUT="$(run_cs debug 2>&1)" || fail "debug exited non-zero: $DEBUG_OUT"
EXPECT_CFG="$SANDBOX_HOME/.claude-squad/config.json"
case "$DEBUG_OUT" in
  *"Config: $EXPECT_CFG"*) ;;
  *) fail "debug config path is not under the sandbox HOME; want '$EXPECT_CFG'; got: $DEBUG_OUT" ;;
esac
# The pretty-printed JSON object is the block from a lone '{' to a lone '}'.
CFG_JSON="$(printf '%s\n' "$DEBUG_OUT" | sed -n '/^{/,/^}/p')"
echo "$CFG_JSON" | jq -e . >/dev/null 2>&1 || fail "debug emitted invalid config JSON; got: $DEBUG_OUT"
PROG="$(echo "$CFG_JSON" | jq -r '.default_program')"
[ -n "$PROG" ] && [ "$PROG" != "null" ] || fail "config has no default_program; got: $CFG_JSON"

# ---------------------------------------------------------------------------
step "3. the root command refuses to run outside a git repository"
# main.go guards on git.IsGitRepo before ever starting the TUI. That guard is the
# reason the boot tier below has to create a repo first; pin it so a regression
# that drops or inverts it (and would then try to manage worktrees in a non-repo)
# fails loudly. cobra returns the error and main prints it, so assert on the text.
GUARD_OUT="$(cd "$NONGIT_DIR" && run_cs 2>&1 || true)"
case "$GUARD_OUT" in
  *"must be run from within a git repository"*) ;;
  *) fail "root command did not refuse a non-git dir; got: $GUARD_OUT" ;;
esac

# ---------------------------------------------------------------------------
step "4. the TUI boots in a real pty and paints the empty-instance frame"
git -C "$WORK_REPO" init -q
git -C "$WORK_REPO" config user.email smoke@example.com
git -C "$WORK_REPO" config user.name smoke
git -C "$WORK_REPO" commit -q --allow-empty -m "init"

# Bubble Tea needs a genuine terminal: on a pipe it renders nothing and can exit
# 0, so piping it would be a test that cannot fail. tmux supplies the pty. STDOUT
# MUST STAY ON THE PTY (Bubble Tea paints there); only stderr is captured, which
# is where a panic would land. The exit code goes to a file because tmux does not
# hand it back.
tmux -L "$TMUX_SOCKET" new-session -d -s tui -x 200 -y 50 \
  "cd '$WORK_REPO' && env -i HOME='$SANDBOX_HOME' PATH=/usr/bin:/bin TERM=xterm-256color \
   sh -c '\"$BIN\" 2>\"$TUI_ERR\"; echo \$? >\"$TUI_EXIT\"'" \
  || fail "tmux could not start the TUI"

# Poll the pane until the empty-list state paints. Never sleep a guessed interval:
# a fixed sleep makes the test pass or fail on machine speed rather than behaviour.
# The empty-state string is rendered by ui/preview.go only after storage + list +
# menu all initialised, so it is proof of a full boot, not just a first paint.
PANE=""
RENDERED=0
for _ in $(seq 1 120); do
  PANE="$(tmux -L "$TMUX_SOCKET" capture-pane -p -t tui 2>/dev/null || true)"
  case "$PANE" in
    *"No agents running yet"*) RENDERED=1; break ;;
  esac
  if [ -f "$TUI_EXIT" ]; then
    fail "the TUI exited before rendering (code $(cat "$TUI_EXIT")); stderr: $(cat "$TUI_ERR" 2>/dev/null || true); pane:$(printf '\n%s' "$PANE")"
  fi
  sleep 0.1
done
[ "$RENDERED" = "1" ] || fail "TUI never painted the empty-instance frame within 12s; pane:$(printf '\n%s' "$PANE")"

# The bottom menu bar proves the key map rendered, not just a static banner.
case "$PANE" in
  *"q quit"*) ;;
  *) fail "TUI frame is missing the quit key in its menu bar; pane:$(printf '\n%s' "$PANE")" ;;
esac
case "$PANE" in
  *"n new"*) ;;
  *) fail "TUI frame is missing the new-instance key in its menu bar; pane:$(printf '\n%s' "$PANE")" ;;
esac
# A green build that panics during boot paints a Go stack trace instead of chrome.
case "$PANE" in
  *panic*|*"goroutine "*) fail "TUI pane shows a panic/stack trace; pane:$(printf '\n%s' "$PANE")" ;;
esac

# ---------------------------------------------------------------------------
step "5. the TUI quits cleanly on 'q'"
# A TUI that cannot exit leaves the terminal wedged in raw mode. Assert the
# process actually reaps with status 0 and left no panic on stderr.
tmux -L "$TMUX_SOCKET" send-keys -t tui q

QUIT=0
for _ in $(seq 1 120); do
  if [ -f "$TUI_EXIT" ]; then
    QUIT=1
    break
  fi
  sleep 0.1
done
[ "$QUIT" = "1" ] || fail "TUI did not exit within 12s of 'q'; pane:$(printf '\n%s' "$(tmux -L "$TMUX_SOCKET" capture-pane -p -t tui 2>/dev/null || true)")"

TUI_STATUS="$(cat "$TUI_EXIT")"
[ "$TUI_STATUS" = "0" ] || fail "TUI exited $TUI_STATUS on 'q', want 0. stderr: $(cat "$TUI_ERR" 2>/dev/null || true)"
if grep -qi "panic" "$TUI_ERR" 2>/dev/null; then
  fail "TUI PANICKED: $(cat "$TUI_ERR")"
fi

# ---------------------------------------------------------------------------
step "6. the sandbox held"
# claude-squad DOES persist to HOME (config.json), so the hermeticity proof is the
# inverse of a read-only client's: assert its state landed in OUR sandbox, which
# means the run used the redirected HOME and never the real ~/.claude-squad. The
# day someone adds an env override for the config dir, this still passes; the day
# someone hardcodes an absolute path outside HOME, it fails.
[ -f "$EXPECT_CFG" ] || fail "config.json was not written under the sandbox HOME ($EXPECT_CFG) — the run may have escaped to the real \$HOME"

echo ""
echo "e2e smoke test OK ($BIN_NAME)"

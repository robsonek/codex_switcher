#!/bin/bash
# Tests for cx using stub `codex` and `ccswap` binaries (real accounts are never touched).
# Run: bash tests/test-cx.sh   (uses /bin/bash, i.e. bash 3.2 on macOS; requires perl)

set -u
CX="$(cd "$(dirname "$0")/.." && pwd)/cx"
W=$(mktemp -d "${TMPDIR:-/tmp}/cxtest.XXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/work/sub" "$W/tmp"
export TMPDIR="$W/tmp"
PASS=0; FAIL=0

# ---------------------------------------------------------------- stubs
cat > "$W/bin/codex" <<'EOF'
#!/bin/bash
case "$1 $2 $3" in
  "app-server daemon version") exit "${DAEMON_UP:-1}";;
  "app-server daemon stop") echo "DAEMON STOP" >> "$LOG"; exit 0;;
esac
if [ "$1" = login ]; then
  echo "codex login" >> "$LOG"
  case "${LOGIN:-ok}" in
    ok)   echo '{"new":"B"}' > "$CODEX_HOME/auth.json"; exit 0;;
    int)  kill -INT $PPID; kill -INT $$;;
    fail) exit 1;;
  esac
fi
n=$(cat "$CALLS.i" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$CALLS.i"
beh=$(sed -n "${n}p" "$CALLS" 2>/dev/null)
q=""; for x in "$@"; do q="$q [$x]"; done
case " $* " in *" - "*) q="$q <stdin:$(cat)>";; esac
echo "codex#$n (pwd=$(basename "$PWD"))$q" >> "$LOG"
sid="01a1aaaa-0000-7000-8000-00000000000$n"
case "$beh" in
  limit)      echo "session id: $sid" >&2; echo "ERROR: You've hit your usage limit. Try again at 22:00." >&2; exit 1;;
  limit-json) echo "{\"type\":\"thread.started\",\"thread_id\":\"$sid\"}"; echo '{"type":"turn.failed","error":{"message":"You'"'"'ve hit your usage limit."}}'; exit 1;;
  fail)       echo "session id: $sid" >&2; echo "ERROR: something else broke" >&2; exit 1;;
  ok-json)    echo "{\"type\":\"thread.started\",\"thread_id\":\"$sid\"}"; echo "RESULT-$n"; exit 0;;
  sleep)      echo $$ > "$PIDFILE"; exec sleep 47;;
  *)          echo "session id: $sid" >&2; echo "RESULT-$n"; exit 0;;
esac
EOF
cat > "$W/bin/ccswap" <<'EOF'
#!/bin/bash
next() { local f=$1 n; n=$(cat "$f.i" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$f.i"; sed -n "${n}p" "$f" 2>/dev/null; }
case "$1 $2" in
  "codex auto")   r=$(next "$SEQ"); r=${r:-2}; echo "ccswap auto -> $r" >> "$LOG"
                  [ "$r" = 3 ] && echo "${AUTO3_MSG:-all accounts exhausted; earliest reset X}"; exit "$r";;
  "codex status") a=$(next "$STA"); echo "{ \"activeAccountNumber\": ${a:-2} }";;
  "codex list")   printf '  1  a\n  2  b\n  3  c\n';;
  "codex usage")  echo "  <accounts table>";;
  "codex switch") echo "ccswap switch ${*:3}" >> "$LOG"; echo "{\"switched\": ${SWITCH_JSON:-true}}";;
  "codex add")    n=$(( $(cat "$W/add.i" 2>/dev/null || echo 0) + 1 )); echo $n > "$W/add.i"
                  echo "ccswap add #$n [auth=$(cat "$CODEX_HOME/auth.json" 2>/dev/null || echo NONE)]" >> "$LOG"
                  [ "$n" = 2 ] && [ "${ADD2_FAIL:-0}" = 1 ] && exit 1; exit 0;;
esac
exit 0
EOF
# pgrep for the cx under test: real codex processes on this machine must not affect the tests
cat > "$W/bin/pgrep" <<'EOF'
#!/bin/bash
[ "$*" = "-x codex" ] && { [ "${FAKE_BUSY:-0}" = 1 ] && { echo 99999; exit 0; }; exit 1; }
exec /usr/bin/pgrep "$@"
EOF
chmod +x "$W/bin/"*
export W

# ---------------------------------------------------------------- helpers
strip_colors() { perl -pi -e 's/\e\[[0-9;]*m//g' "$1"; }
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }

# t NAME CODEX_BEHAVIORS AUTO_CODES STDIN -- cx arguments
t() {
  N=$1 calls=$2 seq=$3 input=$4; shift 5
  export LOG="$W/$N.log" CALLS="$W/$N.calls" SEQ="$W/$N.seq" STA="$W/$N.sta"
  : > "$LOG"; rm -f "$CALLS.i" "$SEQ.i" "$STA.i"
  printf '%b' "$calls" > "$CALLS"; printf '%b' "$seq" > "$SEQ"; printf '%b' "${STATUS_SEQ:-}" > "$STA"
  (cd "$W/work" && printf '%b' "$input" | PATH="$W/bin:$PATH" perl -e 'alarm shift; exec @ARGV' 30 /bin/bash "$CX" "$@" >"$W/$N.out" 2>"$W/$N.err")
  RC=$?
  [ $RC -eq 142 ] && echo "TIMEOUT [$N] cx did not finish within 30 s" >> "$W/$N.err"
  perl -pi -e 's/Continue the task exactly[^\]]*/CONTINUE/' "$LOG"
  strip_colors "$W/$N.err"
}
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "FAIL [$N] $*"; echo "  log:"; sed 's/^/    /' "$LOG"; echo "  stderr:"; sed 's/^/    /' "$W/$N.err"; }
has()  { grep -qF -- "$1" "$LOG" && ok || bad "missing in log: $1"; }
hasnt(){ grep -qF -- "$1" "$LOG" && bad "unexpected in log: $1" || ok; }
err()  { grep -qF -- "$1" "$W/$N.err" && ok || bad "missing in stderr: $1"; }
out()  { grep -qF -- "$1" "$W/$N.out" && ok || bad "missing in stdout: $1"; }
rc()   { [ "$RC" = "$1" ] && ok || bad "exit code $RC instead of $1"; }
count(){ c=$(grep -oF -- "$1" "$LOG" | wc -l | tr -d ' '); [ "$c" = "$2" ] && ok || bad "\"$1\" occurred $c times instead of $2"; }
S1=01a1aaaa-0000-7000-8000-000000000001

export DAEMON_UP=1 CODEX_HOME="$W/ch"; mkdir -p "$CODEX_HOME"

# ---------------------------------------------------------------- cx exec
t limit_resume 'limit\nok\n' '2\n0\n2\n' '' -- exec -m gpt-x -c 'model_reasoning_effort="high"' -s read-only -o out.md "report"
has "codex#2 (pwd=work) [exec] [resume] [-m] [gpt-x] [-c] [model_reasoning_effort=\"high\"] [-c] [sandbox_mode=\"read-only\"] [-o] [out.md] [$S1] [CONTINUE]"
rc 0; out RESULT-2; err "ERROR: You've hit your usage limit"; err "session id: $S1"; err "[cx] The usage limit interrupted the task"

t resume_orig 'limit\nok\n' '2\n0\n2\n' '' -- exec resume 01a1ffff-0000-7000-8000-000000000099 -m gpt-x -o r2.md "round 2"
has "codex#2 (pwd=work) [exec] [resume] [-m] [gpt-x] [-o] [r2.md] [$S1] [CONTINUE]"; rc 0

t review_rerun 'limit\nok\n' '2\n0\n2\n' '' -- exec -s read-only review --uncommitted -m gpt-x
has "codex#2 (pwd=work) [exec] [-s] [read-only] [review] [--uncommitted] [-m] [gpt-x]"; rc 0

t forced_switch 'limit\nok\n' '2\n2\n2\n' '' -- exec "task"
has "ccswap switch --strategy next-available --json"; has "codex#2 (pwd=work) [exec] [resume] [$S1] [CONTINUE]"; rc 0

AUTO3_MSG="no switch: no-qualifying-candidate" t hysteresis_blocked 'limit\nok\n' '2\n3\n2\n' '' -- exec "task"
has "ccswap switch --strategy next-available --json"; has "codex#2"; rc 0

SWITCH_JSON=false t switch_false 'limit\n' '2\n2\n' '' -- exec "task"
hasnt "codex#2"; rc 1; err "No other account has any limit left"

t all_exhausted 'limit\n' '2\n3\n' '' -- exec "task"
hasnt "codex#2"; hasnt "ccswap switch"; rc 1; err "All accounts have hit their limits"

t other_error 'fail\n' '2\n2\n' '' -- exec "task"
hasnt "codex#2"; hasnt "ccswap switch"; rc 1; err "something else broke"

t ephemeral 'limit\n' '2\n0\n' '' -- exec --ephemeral "task"
hasnt "codex#2"; rc 1; err "run it again (session: $S1)"

t chain_two 'limit\nlimit\nok\n' '2\n0\n0\n2\n' '' -- exec -o o.md "big task"
has "codex#3 (pwd=work) [exec] [resume] [-o] [o.md]"; rc 0; out RESULT-3

t cd_dir 'limit\nok\n' '2\n0\n2\n' '' -- exec -C sub "task"
has "codex#2 (pwd=sub) [exec] [resume] [$S1] [CONTINUE]"; rc 0

t json_mode 'limit-json\nok-json\n' '2\n0\n2\n' '' -- exec --json -s workspace-write "task"
has "codex#2 (pwd=work) [exec] [resume] [--json] [-c] [sandbox_mode=\"workspace-write\"] [$S1] [CONTINUE]"; rc 0

t success 'ok\n' '2\n2\n' '' -- exec "regular task"
count "codex#" 1; rc 0; out RESULT-1

t double_dash 'limit\nok\n' '2\n0\n2\n' '' -- exec -- review
has "codex#2 (pwd=work) [exec] [resume] [$S1] [CONTINUE]"; rc 0

t stdin_prompt 'ok\n' '2\n2\n' 'PROMPT-FROM-STDIN' -- exec -m x -
has "[exec] [-m] [x] [-] <stdin:PROMPT-FROM-STDIN>"; rc 0

t stdin_then_resume 'limit\nok\n' '2\n0\n2\n' 'PROMPT-FROM-STDIN' -- exec -
has "codex#2 (pwd=work) [exec] [resume] [$S1] [CONTINUE]"; rc 0

t review_dashdash_stdin 'limit\n' '2\n0\n' 'INSTRUCTIONS' -- exec review -- -
hasnt "codex#2"; rc 1; err "run it again"

N=closed_stdin; export LOG="$W/$N.log" CALLS="$W/$N.calls" SEQ="$W/$N.seq"; : > "$LOG"; printf 'ok\n' > "$CALLS"; printf '2\n2\n' > "$SEQ"
(cd "$W/work" && PATH="$W/bin:$PATH" /bin/bash "$CX" exec "x" 0<&- >"$W/$N.out" 2>"$W/$N.err"); RC=$?
rc 0; out RESULT-1

# ---------------------------------------------------------------- signals
N=term_running; export LOG="$W/$N.log" CALLS="$W/$N.calls" SEQ="$W/$N.seq" PIDFILE="$W/$N.pid"; : > "$LOG"; rm -f "$PIDFILE" "$CALLS.i" "$SEQ.i"; printf 'sleep\n' > "$CALLS"
(cd "$W/work" && PATH="$W/bin:$PATH" exec /bin/bash "$CX" exec "long task" </dev/null >/dev/null 2>&1) &
CXPID=$!
for _ in $(seq 1 50); do [ -s "$PIDFILE" ] && break; perl -e 'select(undef,undef,undef,0.1)'; done
CPID=$(cat "$PIDFILE" 2>/dev/null)
kill -TERM $CXPID; wait $CXPID; RC=$?
perl -e 'select(undef,undef,undef,0.3)'
rc 143
{ [ -n "$CPID" ] && ! kill -0 "$CPID" 2>/dev/null; } && ok || bad "codex ($CPID) survived cx being terminated"

# TERM at a random moment: cx must exit quickly and leave no processes behind.
N=term_fuzz; hung=0; leftovers=0
for i in $(seq 1 25); do
  export LOG="$W/$N.log" CALLS="$W/$N.calls" SEQ="$W/$N.seq" PIDFILE="$W/$N.pid"; : > "$LOG"; rm -f "$CALLS.i" "$SEQ.i"; printf 'sleep\n' > "$CALLS"
  (cd "$W/work" && PATH="$W/bin:$PATH" exec /bin/bash "$CX" exec "x" </dev/null >/dev/null 2>&1) &
  CXPID=$!
  perl -e "select(undef,undef,undef,0.$((RANDOM % 60)))"
  kill -TERM $CXPID 2>/dev/null
  for _ in $(seq 1 30); do kill -0 $CXPID 2>/dev/null || break; perl -e 'select(undef,undef,undef,0.1)'; done
  if kill -0 $CXPID 2>/dev/null; then hung=$((hung+1)); kill -9 $CXPID 2>/dev/null; fi
  wait $CXPID 2>/dev/null
  perl -e 'select(undef,undef,undef,0.2)'
  if pgrep -f "^sleep 47$" >/dev/null || pgrep -f "tee $W" >/dev/null; then
    leftovers=$((leftovers+1)); pkill -f "^sleep 47$"; pkill -f "tee $W"
  fi
done
[ $hung -eq 0 ] && ok || bad "cx hung after TERM in $hung/25 runs"
[ $leftovers -eq 0 ] && ok || bad "processes left behind after TERM in $leftovers/25 runs"

# ---------------------------------------------------------------- interactive mode
mkdir -p "$CODEX_HOME/app-server-daemon"; echo '{}' > "$CODEX_HOME/auth.json"
AUTH_MT=$(mtime "$CODEX_HOME/auth.json")
daemon_start() { echo "{\"pid\":1,\"startSeconds\":$1}" > "$CODEX_HOME/app-server-daemon/daemon.pid"; }

daemon_start 1000
DAEMON_UP=0 t guard_stale 'ok\n' '2\n2\n' '' --
has "codex#1 (pwd=work) [--no-daemon]"; err "starting this session without it"; hasnt "DAEMON STOP"

daemon_start 9999999999
DAEMON_UP=0 t guard_fresh 'ok\n' '2\n2\n' '' --
has "codex#1 (pwd=work)"; hasnt "--no-daemon"

daemon_start "$AUTH_MT"
DAEMON_UP=0 t guard_same_second 'ok\n' '2\n2\n' '' --
has "[--no-daemon]"

daemon_start 1000
DAEMON_UP=0 t guard_explicit_flag 'ok\n' '2\n2\n' '' -- resume --no-daemon 01a1bbbb-0000-7000-8000-000000000042
count "--no-daemon" 1

t resume_opts 'ok\nok\n' '2\n0\n2\n' '\n' -- -C sub -m gpt-x -c 'a="b"' -i image.png "initial prompt"
has "codex#2 (pwd=work) [resume] [-C] [sub] [-m] [gpt-x] [-c] [a=\"b\"] [--last]"

t resume_by_id 'ok\nok\n' '2\n0\n2\n' '\n' -- resume 01a1bbbb-0000-7000-8000-000000000042 -m gpt-x
has "codex#2 (pwd=work) [resume] [-m] [gpt-x] [01a1bbbb-0000-7000-8000-000000000042]"

t resume_all_last 'ok\nok\n' '2\n0\n2\n' '\n' -- resume --all --include-non-interactive --last
has "codex#2 (pwd=work) [resume] [--all] [--include-non-interactive] [--last]"

t resume_dashdash_id 'ok\nok\n' '2\n0\n2\n' '\n' -- resume -- 01a1bbbb-0000-7000-8000-000000000042
has "codex#2 (pwd=work) [resume] [01a1bbbb-0000-7000-8000-000000000042]"

t resume_keeps_no_daemon 'ok\nok\n' '2\n0\n2\n' '\n' -- --no-daemon
has "codex#2 (pwd=work) [resume] [--no-daemon] [--last]"

t answer_no 'ok\n' '2\n0\n' 'n\n' --
count "codex#" 1

STATUS_SEQ='1\n2\n2\n2\n' t agent_switched 'ok\nok\n' '2\n2\n2\n' '\n' --
has "codex#2 (pwd=work) [resume] [--last]"; err "The account was switched during the session (#1 → #2)"

STATUS_SEQ='1\n1\n' t no_change 'ok\n' '2\n2\n' '' --
count "codex#" 1

# ---------------------------------------------------------------- cx add
ta() {
  N=$1; shift
  export LOG="$W/$N.log" CODEX_HOME="$W/$N.home"; rm -rf "$CODEX_HOME" "$W/add.i"; mkdir -p "$CODEX_HOME"; : > "$LOG"
  echo '{"old":"A"}' > "$CODEX_HOME/auth.json"
  env "$@" PATH="$W/bin:$PATH" perl -e 'alarm shift; exec @ARGV' 30 /bin/bash "$CX" add >/dev/null 2>"$W/$N.err"; RC=$?
  strip_colors "$W/$N.err"
}
auth_is() { [ "$(cat "$CODEX_HOME/auth.json" 2>/dev/null)" = "$1" ] && ok || bad "auth.json = $(cat "$CODEX_HOME/auth.json" 2>/dev/null) instead of $1"; }
bak_is()  { if [ "$1" = none ]; then [ ! -e "$CODEX_HOME/auth.json.cx-backup" ] && ok || bad "backup was not removed"
            else [ "$(cat "$CODEX_HOME/auth.json.cx-backup" 2>/dev/null)" = "$1" ] && ok || bad "backup $1 is missing"; fi; }

ta add_ok LOGIN=ok;               rc 0;   auth_is '{"new":"B"}'; bak_is none; has "ccswap switch 2"
ta add_ctrl_c LOGIN=int;          rc 130; auth_is '{"old":"A"}'; bak_is none
ta add_login_fail LOGIN=fail;     rc 1;   auth_is '{"old":"A"}'; bak_is none
ta add_ccswap_fail LOGIN=ok ADD2_FAIL=1; rc 1; auth_is '{"new":"B"}'; bak_is '{"old":"A"}'; hasnt "ccswap switch"
ta add_busy FAKE_BUSY=1 LOGIN=ok; rc 1; auth_is '{"old":"A"}'; bak_is none; hasnt "codex login"; err "Another codex process is running"

# ---------------------------------------------------------------- cx switch
export CODEX_HOME="$W/ch"
SWITCH_JSON=false t manual_switch_nochange '' '' '' -- switch
rc 0; err "No change"; hasnt "DAEMON STOP"

# ---------------------------------------------------------------- cleanup
N=tmp_cleanup; LOG=/dev/null
left=$(find "$W/tmp" -maxdepth 1 -name 'cx.*' | wc -l | tr -d ' ')
[ "$left" = 0 ] && ok || { FAIL=$((FAIL+1)); echo "FAIL [$N] $left cx.* directories left in TMPDIR"; }

echo "Result: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]

# cx — keep the Codex CLI working across your ChatGPT accounts

`cx` is a small bash wrapper around the [OpenAI Codex CLI](https://github.com/openai/codex). When the active ChatGPT account runs out of its usage limit, `cx` switches to another account you own and keeps going. Interactive sessions are resumed after you confirm, and non-interactive `exec` runs (e.g. started by coding agents) are resumed automatically.

Account storage and switching are handled by [ccswap](https://github.com/errhythm/ccswap). `cx` adds the parts the Codex CLI needs on top of it:
- it decides when to switch;
- it restarts Codex (Codex reads `~/.codex/auth.json` only at startup);
- it resumes the interrupted session.

> **Disclaimer.** Use `cx` only with accounts that you own. Check OpenAI's terms of use before rotating accounts — circumventing usage limits may violate them and can get accounts suspended. This project is not affiliated with OpenAI. Use at your own risk.

## Requirements

- [Codex CLI](https://github.com/openai/codex), signed in with ChatGPT and using the file credential store (`~/.codex/auth.json`). Tested with 0.166.
- [ccswap](https://github.com/errhythm/ccswap) ≥ 0.44: `uv tool install ccswap` (or `pipx install ccswap`).
- bash ≥ 3.2. Developed and tested on macOS; Linux should work but is untested.
- `perl` (only for the test suite).

## Install

```bash
git clone https://github.com/robsonek/codex_switcher.git
cd codex_switcher
ln -sf "$PWD/cx" ~/.local/bin/cx      # any directory on your PATH
```

## Quick start

```bash
cx add          # save the account you are logged in with, then log in with the next one
cx add          # repeat for every account you own (close all codex sessions first)
cx list         # usage limits of all saved accounts
cx              # use instead of `codex`
cx exec …       # use instead of `codex exec …`
```

`cx add` saves the current login in ccswap, moves `auth.json` aside and runs `codex login` for the next account. Moving the file aside means the login cannot touch the previous account's tokens. When the login finishes, `cx add` switches back to the account that was active before.

## Commands

```
cx [codex arguments]    interactive codex; on exit checks the limit and switches if needed
cx exec …               like `codex exec …`, but finishes the task after a usage-limit error
cx add [--device-auth]  add another account (close all codex sessions first)
cx list                 usage limits of all accounts
cx switch [N|email]     manual switch (no argument: account with the most headroom)
cx check                check the limit now and switch if needed
cx help                 help
CX_THRESHOLD=95 cx …    different switching threshold (default 90%)
```

All other subcommands (`login`, `mcp`, `features`, …) are passed to `codex` unchanged.

## When does it switch?

ccswap looks at both the 5-hour and the weekly window of each account.

- **Proactively:** when the active account crosses the threshold, `cx` moves to an account that has used at most threshold − 10% (a hysteresis margin, so accounts near the line don't ping-pong). If no such account exists, it stays on the current one.
- **After a limit error:** when Codex reports a usage limit, `cx` moves to any account that has some limit left.
- **All accounts exhausted:** `cx` shows the reset times. Banked resets can be redeemed manually with `ccswap codex redeem-reset <number>`.

## Interactive sessions: `cx`

1. When the limit is hit, type `/exit`.
2. `cx` switches the account. It also notices if an agent switched it during your session (via `cx exec`).
3. Press Enter to resume the session with the same options (`-C`, `-m`, `-c`, …). If the session was started with `resume <ID>`, it resumes by that ID; otherwise it uses `resume --last`.

`cx` does not stop the shared Codex daemon, so your other open sessions are not interrupted. If the daemon was started before `auth.json` changed, new `cx` sessions start with `--no-daemon`. A plain `codex` would attach to that daemon and keep using the old account, so start sessions through `cx`. A manual `cx switch` stops the daemon.

## Agents and scripts: `cx exec`

`cx exec …` is a drop-in replacement for `codex exec …`: same arguments, same stdin. It also works with `exec review`, `exec resume <ID>` and `-o file`.

- **Before starting**, it switches the account if the active one is above the threshold.
- **When a usage limit interrupts the task** (`ERROR: You've hit your usage limit…`), it switches the account and **finishes the work by itself**:
  - `exec` and `exec resume`: resumes the same session (`codex exec resume <ID>`) with the original options (`-m`, `-c`, `-o`, `--json`, …). `-s X` is carried over as `-c sandbox_mode="X"` and `-C dir` by resuming inside that directory. The final answer goes to the same `-o` file.
  - `exec review`: reruns the review from the start with identical arguments, since it is read-only. Exception: a prompt read from stdin (`-`).
  - If the next account hits its limit too, it moves on again, at most once per saved account.
  - It **does not auto-resume** a plain `exec` / `exec resume` that uses `--ephemeral`, `-p/--profile`, `--add-dir`, `--oss`, `--approve-for-me` or unknown options. In that case it switches the account and prints `[cx] … run it again (session: <ID>)`.
- **After finishing**, it prepares an account with headroom for the next call.
- **Exit code** is the one from the last `codex` run, so a successful resume returns 0. Output of the interrupted part also stays on stdout.
- **Signals:** TERM/INT/HUP sent to `cx` also stop the running `codex`.

## Rules of thumb

- Never switch accounts with `codex logout`: logging out revokes the tokens on OpenAI's side and the saved account stops working.
- If something goes wrong during `cx add`:
  - **failed login or Ctrl-C:** the previous login is restored automatically;
  - **new account logged in but ccswap failed to save it:** the new login stays in `auth.json`, the previous one in `auth.json.cx-backup`, and `cx add` exits with an error.

## Tests

```bash
bash tests/test-cx.sh
```

The suite runs `cx` against stub `codex`, `ccswap` and `pgrep` binaries in a temporary directory. It never touches your real accounts. It covers the `exec` resume logic, interactive resume, the daemon guard, `cx add` failure paths and signal handling.

## Credits

Account storage, usage tracking and switching are provided by [ccswap](https://github.com/errhythm/ccswap).

## License

[MIT](LICENSE)

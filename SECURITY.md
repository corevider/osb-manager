# Security

## Reporting a vulnerability

Please report security problems privately: on GitHub, open the repository's **Security** tab and choose **Report a vulnerability**. Do not open a public issue for them. Include what you found, how to reproduce it and which version you used. The maintainers answer there.

OSB Manager stores game passwords with Windows DPAPI (Windows) or in the Keychain (macOS), never in plain text, and sends usage statistics and reports only with the user's consent (see [docs/telemetry.md](docs/telemetry.md)). A change that weakens either is a security problem.

## The Claude automation and its tokens

Pull request reviews (`claude-review.yml`) and issue fixes (`claude-fix.yml`) run on Claude Code in GitHub Actions. They need one Claude credential. This section is for the maintainers who hold it.

### Which secret to set, and how to switch

| Secret | What it is | When it is used |
| --- | --- | --- |
| `CLAUDE_CODE_OAUTH_TOKEN` | a Claude Code token of the operator's Claude subscription | whenever it is set (the default) |
| `ANTHROPIC_API_KEY` | an Anthropic API key, billed per use | only when `CLAUDE_CODE_OAUTH_TOKEN` is not set |

Every Claude job chooses with the same rule: the subscription token if it is set, otherwise the API key, otherwise the job skips the Claude step with a notice. The choice is made from whether each secret is set; neither value is printed. Only the chosen secret is passed to the Claude step.

- To switch to the API key, add `ANTHROPIC_API_KEY` and delete `CLAUDE_CODE_OAUTH_TOKEN`.
- To switch back, add `CLAUDE_CODE_OAUTH_TOKEN` again. Keeping both is allowed; the subscription token wins.
- To stop the automation, delete both. The workflows then skip their Claude steps.

Put both secrets in the GitHub Environment **`claude`** (Settings, Environments, `claude`, Environment secrets), not as repository secrets. Only the Claude jobs name that environment, so no other workflow or job can read them.

### Creating the subscription token

On the operator's own computer, with Claude Code installed and signed in to the subscription that should pay for the automation:

```sh
claude setup-token
```

It opens a browser sign-in and prints a long-lived token that starts with `sk-ant-`. Copy it straight into the `claude` environment as `CLAUDE_CODE_OAUTH_TOKEN`. Do not paste it anywhere else: not in a file, a chat, an issue, a commit or a terminal that others can see. Never create it on a shared or CI machine.

### A separate API key for CI

If you use `ANTHROPIC_API_KEY`, create a key only for this repository:

1. In the Anthropic Console, create a workspace for CI (for example `osb-ci`) and set a low monthly spend limit on it (for example USD 20).
2. Create an API key in that workspace and name it after the repository.
3. Store it in the `claude` environment as `ANTHROPIC_API_KEY`.

Never reuse a personal key or a key that other tools use. The workflows also cap each run (see below), but the workspace limit is the one that holds when everything else fails.

### Rotation

- **At once after any doubt:** a failed token guard, an unexpected comment or run, a leaked log, a maintainer who leaves, or a secret shown on a screen. Create a new token or key, replace the secret in the `claude` environment, then revoke the old one (the subscription token in the Claude account settings where it was issued, the API key in the Console), and read the recent workflow runs.
- **On a schedule:** every 90 days, the same way. Note the date in your own calendar.

### Secret scanning and push protection

In Settings, Advanced Security (called Code security on some plans), enable **Secret scanning** and **Push protection**. Push protection refuses a push that contains a known token format, and secret scanning alerts the maintainers about tokens already in the repository, its issues or its pull requests. Also enable **Private vulnerability reporting** on the same page: the token guard files its alert through it.

## What each workflow can and cannot do

| Workflow | Can | Cannot |
| --- | --- | --- |
| `ci.yml` | build and test the PR's code on Windows and macOS | read any secret; write to the repository (`contents: read`) |
| `claude-review.yml` | read main, the PR's text and diff (saved as files), and post inline comments and one summary comment | check out or run the PR's code; use a shell, the network or `gh`; write files; approve, request changes or merge; see a token outside its own step |
| `claude-fix.yml` | read the issue, edit the checkout in its `fix` job, build and test the patch in a separate `test` job, and open a PR from a `publish` job | run the agent's code where a Claude token or a write token is present; change protected files; merge |
| `merge-approved.yml` | squash-merge a PR that a maintainer with write access approved at its head commit, after the `windows` and `macos` checks passed and Claude did not say HOLD | merge without a human approval; merge a PR that changes a protected file; read a Claude token |
| `release.yml` | build the Windows package for a maintainer's version tag and attach it to a draft release | sign anything; publish the release; read a Claude token |

Protected files, which the fix bot refuses and `merge-approved.yml` never merges: `.github/`, `SECURITY.md`, `LICENSE`, `scripts/`, `macos/scripts/` (build, signing and notarisation), the `*.entitlements` files and the `Info.plist` templates.

### How the tokens are protected

1. **No untrusted code next to a secret.** The Claude jobs check out `main` and read a pull request only as text (`gh pr view`, `gh pr diff`, saved to files by a plain step). CI runs pull request code on the plain `pull_request` event, which gets no secrets. The code the fix agent writes is built and tested in a separate job that has no secret and a read-only token.
2. **Gates.** An outside pull request or issue reaches Claude only after a maintainer adds `ok-to-review` or `ok-to-fix`. The label covers the commit and the text present when it was added: the review stops when the head moved, and the fix agent gets the issue text from the labelling event.
3. **Least privilege.** Every workflow starts with `permissions: {}` and each job asks for the minimum. The token is given to the Claude step's input only, never as job or workflow `env`. No workflow uses `secrets: inherit`.
4. **Tool limits.** The agent may use `Read`, `Glob` and `Grep` inside the checkout. `.git`, the home folder's dot files, `/proc`, `/sys`, `/dev` and the runner's temp folder are denied, and `Bash`, `WebFetch` and `WebSearch` are denied. Only the fix agent may edit files, inside the checkout and outside `.git` and `.github`. The action's subprocess hardening is on (`allowed_non_write_users` with `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`): credentials are removed from the environment of any subprocess and git uses a credential helper instead of a token in `.git/config`.
5. **Token guard.** `.github/scripts/token-guard.mjs` runs as a plain step after every Claude step. It checks every comment, review comment, review, issue and pull request changed since the job started (the fix job: its outcome text and patch before they leave the job) for the exact token values, fragments of 20 characters, their base64 and hex forms, and the `sk-ant-` shape. On a match it deletes the comment, or replaces the body and closes the issue or pull request, fails the run, and files a private vulnerability report. It never prints a value. GitHub keeps an edit history for bodies, so after any match rotate the tokens.
6. **Supply chain.** Every action is pinned to a full commit SHA with its version in a comment, and `actions/checkout` never keeps credentials.
7. **Environment.** The tokens live in the `claude` environment, limited to the `main` branch. For `pull_request_target` and `issues` runs GitHub evaluates that rule against the default branch, so the jobs can use it. Add yourself as a **required reviewer** of the environment if you want to approve every Claude run by hand: each run then waits for your click.
8. **Limits.** One review per pull request and one fix per issue at a time (older runs are cancelled), job and step timeouts, and per run `--max-turns` and `--max-budget-usd` (review: 80 turns, USD 5; fix: 120 turns, USD 10).

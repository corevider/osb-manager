import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

export const SECRET_VARIABLES = ["TOKEN_GUARD_OAUTH_TOKEN", "TOKEN_GUARD_API_KEY"];
export const RUN_AUTHORS = ["github-actions[bot]", "claude[bot]", "claude"];
export const REMOVED_TEXT = "Removed by the token guard of this repository.";

const KEY_SHAPE = /sk-ant-[A-Za-z0-9_-]{20,}/;
const FRAGMENT_LENGTH = 20;
const INVISIBLE = /[\s\u200b-\u200d\u2060\ufeff]+/g;

export function secretsFromEnvironment(environment) {
    return SECRET_VARIABLES.map((name) => (environment[name] ?? "").trim()).filter((value) => value.length >= 8);
}

function fragmentsOf(secret) {
    if (secret.length <= FRAGMENT_LENGTH) return [secret];
    const fragments = [];
    for (let start = 0; start + FRAGMENT_LENGTH <= secret.length; start++) {
        fragments.push(secret.slice(start, start + FRAGMENT_LENGTH));
    }
    return fragments;
}

function encodedFormsOf(secret) {
    const forms = [];
    for (let offset = 0; offset < 3; offset++) {
        const aligned = secret.slice(offset);
        const usable = aligned.length - (aligned.length % 3);
        if (usable < 15) continue;
        const bytes = Buffer.from(aligned.slice(0, usable), "utf8");
        forms.push(bytes.toString("base64"), bytes.toString("base64url"));
    }
    forms.push(Buffer.from(secret, "utf8").toString("hex"));
    return forms;
}

export function findLeak(text, secrets) {
    if (!text) return null;
    const compact = String(text).replace(INVISIBLE, "");
    for (const secret of secrets) {
        if (fragmentsOf(secret).some((fragment) => compact.includes(fragment))) return "a token value";
        if (encodedFormsOf(secret).some((form) => compact.includes(form))) return "an encoded token value";
    }
    if (KEY_SHAPE.test(compact)) return "an Anthropic key or OAuth token shape";
    return null;
}

export function isRunAuthor(login) {
    return RUN_AUTHORS.includes(login ?? "");
}

export function leakToActOn(item, secrets) {
    const reason = findLeak(item.text, secrets);
    if (!reason) return null;
    if (reason.startsWith("an Anthropic") && !isRunAuthor(item.author)) return null;
    return reason;
}

function nextLink(header) {
    const match = /<([^>]+)>;\s*rel="next"/.exec(header ?? "");
    return match ? match[1] : null;
}

export function createGitHubClient({ token, apiUrl, fetchImpl = fetch }) {
    return async function request(method, path, body) {
        const url = path.startsWith("http") ? path : `${apiUrl}${path}`;
        const response = await fetchImpl(url, {
            method,
            headers: {
                Accept: "application/vnd.github+json",
                Authorization: `Bearer ${token}`,
                "X-GitHub-Api-Version": "2022-11-28",
                ...(body ? { "Content-Type": "application/json" } : {}),
            },
            body: body ? JSON.stringify(body) : undefined,
        });
        const text = await response.text();
        return {
            status: response.status,
            data: text ? JSON.parse(text) : null,
            next: nextLink(response.headers.get("link")),
        };
    };
}

async function listAll(request, path) {
    const items = [];
    let next = path;
    while (next) {
        const response = await request("GET", next);
        if (response.status !== 200) throw new Error(`GET ${path} answered ${response.status}`);
        items.push(...response.data);
        next = response.next;
    }
    return items;
}

export async function collectItems(request, repository, since) {
    const query = `since=${encodeURIComponent(since)}&per_page=100`;
    const items = [];
    for (const comment of await listAll(request, `/repos/${repository}/issues/comments?${query}`)) {
        items.push({
            kind: "issue comment",
            url: comment.html_url,
            author: comment.user?.login,
            text: comment.body,
            remove: { method: "DELETE", path: `/repos/${repository}/issues/comments/${comment.id}` },
        });
    }
    for (const comment of await listAll(request, `/repos/${repository}/pulls/comments?${query}`)) {
        items.push({
            kind: "review comment",
            url: comment.html_url,
            author: comment.user?.login,
            text: comment.body,
            remove: { method: "DELETE", path: `/repos/${repository}/pulls/comments/${comment.id}` },
        });
    }
    const issues = await listAll(request, `/repos/${repository}/issues?state=all&${query}`);
    for (const issue of issues) {
        items.push({
            kind: issue.pull_request ? "pull request" : "issue",
            url: issue.html_url,
            author: issue.user?.login,
            text: `${issue.title ?? ""}\n${issue.body ?? ""}`,
            remove: {
                method: "PATCH",
                path: `/repos/${repository}/issues/${issue.number}`,
                body: { title: REMOVED_TEXT, body: REMOVED_TEXT, state: "closed" },
            },
        });
    }
    for (const pull of issues.filter((issue) => issue.pull_request)) {
        const reviews = await listAll(request, `/repos/${repository}/pulls/${pull.number}/reviews?per_page=100`);
        for (const review of reviews.filter((entry) => (entry.submitted_at ?? "") >= since)) {
            items.push({
                kind: "review",
                url: review.html_url,
                author: review.user?.login,
                text: review.body,
                remove: {
                    method: "PUT",
                    path: `/repos/${repository}/pulls/${pull.number}/reviews/${review.id}`,
                    body: { body: REMOVED_TEXT },
                },
            });
        }
    }
    return items;
}

export async function fileReport(request, repository, findings, runUrl) {
    const lines = findings.map((finding) => `- ${finding.where}: ${finding.reason}; ${finding.outcome}`);
    const response = await request("POST", `/repos/${repository}/security-advisories/reports`, {
        summary: "Token guard: a Claude token may have leaked from a workflow run",
        description: [
            `The token guard of ${runUrl} found the following and acted on it. The value itself is not repeated here.`,
            "",
            ...lines,
            "",
            "Rotate CLAUDE_CODE_OAUTH_TOKEN and ANTHROPIC_API_KEY now, as SECURITY.md describes, then read the run log.",
        ].join("\n"),
        severity: "critical",
    });
    return response.status === 201;
}

export async function guardGitHub({ request, repository, since, secrets, runUrl, log }) {
    const items = await collectItems(request, repository, since);
    const findings = [];
    for (const item of items) {
        const reason = leakToActOn(item, secrets);
        if (!reason) continue;
        const response = await request(item.remove.method, item.remove.path, item.remove.body);
        const done = response.status >= 200 && response.status < 300;
        const outcome = done ? "removed" : `NOT removed (status ${response.status}), remove it by hand`;
        findings.push({ where: `${item.kind} ${item.url}`, reason, outcome });
        log(`::error::Token guard: ${item.kind} ${item.url} contained ${reason}; ${outcome}.`);
    }
    if (findings.length === 0) {
        log(`Token guard: ${items.length} items changed since ${since}; none contains a token.`);
        return 0;
    }
    const reported = await fileReport(request, repository, findings, runUrl).catch(() => false);
    log(reported
        ? "::error::Token guard: a private security report was filed for the maintainers. Rotate the Claude tokens now."
        : "::error::Token guard: the private security report could not be filed. Rotate the Claude tokens now.");
    return 1;
}

export async function guardFiles({ paths, secrets, log, readText = (path) => readFile(path, "utf8") }) {
    let leaks = 0;
    for (const path of paths) {
        const text = await readText(path).catch(() => null);
        if (text === null) continue;
        const reason = findLeak(text, secrets);
        if (!reason) continue;
        leaks++;
        log(`::error::Token guard: ${path} contains ${reason}. Nothing from this run is published.`);
    }
    if (leaks === 0) log(`Token guard: ${paths.length} files checked; none contains a token.`);
    return leaks === 0 ? 0 : 1;
}

function argumentValue(args, name) {
    const index = args.indexOf(name);
    return index >= 0 ? args[index + 1] : undefined;
}

export async function main(args, environment, log = console.log) {
    const secrets = secretsFromEnvironment(environment);
    const [mode, ...rest] = args;
    if (mode === "files") {
        return guardFiles({ paths: rest, secrets, log });
    }
    if (mode === "github") {
        const since = argumentValue(rest, "--since");
        const repository = environment.GITHUB_REPOSITORY;
        const token = environment.GH_TOKEN;
        if (!since || !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/.test(since) || !repository || !token) {
            log("::error::Token guard: needs --since <UTC time>, GITHUB_REPOSITORY and GH_TOKEN.");
            return 2;
        }
        const apiUrl = environment.GITHUB_API_URL || "https://api.github.com";
        const runUrl = `${environment.GITHUB_SERVER_URL || "https://github.com"}/${repository}/actions/runs/${environment.GITHUB_RUN_ID ?? ""}`;
        const request = createGitHubClient({ token, apiUrl });
        try {
            return await guardGitHub({ request, repository, since, secrets, runUrl, log });
        } catch (error) {
            log(`::error::Token guard: could not check the run's comments (${error.message}). Check them by hand.`);
            return 1;
        }
    }
    log("Usage: node token-guard.mjs files <path>... | github --since <UTC time>");
    return 2;
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
    process.exitCode = await main(process.argv.slice(2), process.env);
}

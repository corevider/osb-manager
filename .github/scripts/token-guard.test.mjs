import test from "node:test";
import assert from "node:assert/strict";
import {
    REMOVED_TEXT,
    findLeak,
    guardFiles,
    guardGitHub,
    leakToActOn,
    main,
    secretsFromEnvironment,
} from "./token-guard.mjs";

const fakeOauthToken = ["sk", "ant", "oat01", "Fake0Token0For0Tests".repeat(4)].join("-");
const fakeApiKey = ["sk", "ant", "api03", "MadeUpKeyValue".repeat(5)].join("-");
const plainSecret = "plain-secret-without-any-known-prefix-0123456789";
const since = "2026-11-04T10:00:00Z";
const repository = "example-owner/example-repo";

function fakeGitHub(pages) {
    const calls = [];
    const request = async (method, path, body) => {
        calls.push({ method, path, body });
        if (method === "GET") {
            const key = Object.keys(pages).find((prefix) => path.startsWith(prefix));
            return { status: 200, data: key ? pages[key] : [], next: null };
        }
        if (path.endsWith("/security-advisories/reports")) return { status: 201, data: {} };
        return { status: method === "DELETE" ? 204 : 200, data: {} };
    };
    return { request, calls };
}

test("reads both secrets from the environment and ignores empty ones", () => {
    assert.deepEqual(secretsFromEnvironment({ TOKEN_GUARD_OAUTH_TOKEN: fakeOauthToken, TOKEN_GUARD_API_KEY: "" }), [fakeOauthToken]);
    assert.deepEqual(secretsFromEnvironment({}), []);
});

test("finds the exact value, a fragment, a value split by whitespace and encoded forms", () => {
    const secrets = [plainSecret];
    assert.equal(findLeak(`here: ${plainSecret}`, secrets), "a token value");
    assert.equal(findLeak(`part ${plainSecret.slice(10, 32)} only`, secrets), "a token value");
    assert.equal(findLeak(plainSecret.match(/.{1,7}/g).join("\n"), secrets), "a token value");
    assert.equal(findLeak(plainSecret.split("").join("​"), secrets), "a token value");
    for (const prefix of ["", "x", "xy"]) {
        const encoded = Buffer.from(`${prefix}${plainSecret}`).toString("base64");
        assert.equal(findLeak(encoded, secrets), "an encoded token value", `base64 after ${prefix.length} bytes`);
    }
    assert.equal(findLeak(Buffer.from(plainSecret).toString("hex"), secrets), "an encoded token value");
});

test("finds the Anthropic key and OAuth token shapes without knowing the value", () => {
    assert.equal(findLeak(`token ${fakeOauthToken}`, []), "an Anthropic key or OAuth token shape");
    assert.equal(findLeak(`key ${fakeApiKey}`, []), "an Anthropic key or OAuth token shape");
});

test("leaves ordinary review text alone", () => {
    const text = "The change looks safe. Set ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN as a secret.\n\nVERDICT: MERGE";
    assert.equal(findLeak(text, [fakeOauthToken, fakeApiKey]), null);
    assert.equal(findLeak("", [fakeOauthToken]), null);
});

test("acts on a key shape only in items written by the run's bot", () => {
    const shaped = `see ${fakeApiKey}`;
    assert.equal(leakToActOn({ author: "github-actions[bot]", text: shaped }, []), "an Anthropic key or OAuth token shape");
    assert.equal(leakToActOn({ author: "someone", text: shaped }, []), null);
    assert.equal(leakToActOn({ author: "someone", text: `see ${plainSecret}` }, [plainSecret]), "a token value");
});

test("deletes leaking comments, redacts bodies and reviews, files a report and fails", async () => {
    const { request, calls } = fakeGitHub({
        [`/repos/${repository}/issues/comments`]: [
            { id: 11, html_url: "https://example.test/c/11", user: { login: "github-actions[bot]" }, body: `oops ${fakeOauthToken}` },
            { id: 12, html_url: "https://example.test/c/12", user: { login: "github-actions[bot]" }, body: "VERDICT: MERGE" },
        ],
        [`/repos/${repository}/pulls/comments`]: [
            { id: 21, html_url: "https://example.test/r/21", user: { login: "claude[bot]" }, body: Buffer.from(fakeApiKey.slice(1)).toString("base64") },
        ],
        [`/repos/${repository}/issues?`]: [
            { number: 5, html_url: "https://example.test/pull/5", user: { login: "github-actions[bot]" }, title: "Fix", body: "fine", pull_request: {} },
            { number: 6, html_url: "https://example.test/issues/6", user: { login: "someone" }, title: "Bug", body: `copied ${fakeOauthToken}` },
        ],
        [`/repos/${repository}/pulls/5/reviews`]: [
            { id: 31, html_url: "https://example.test/review/31", user: { login: "github-actions[bot]" }, body: `x ${fakeOauthToken}`, submitted_at: "2026-11-04T10:05:00Z" },
            { id: 32, html_url: "https://example.test/review/32", user: { login: "github-actions[bot]" }, body: `x ${fakeOauthToken}`, submitted_at: "2026-11-03T10:05:00Z" },
        ],
    });
    const lines = [];
    const status = await guardGitHub({
        request,
        repository,
        since,
        secrets: [fakeOauthToken, fakeApiKey],
        runUrl: "https://example.test/run/1",
        log: (line) => lines.push(line),
    });
    assert.equal(status, 1);
    const writes = calls.filter((call) => call.method !== "GET");
    assert.deepEqual(writes.map((call) => `${call.method} ${call.path}`), [
        `DELETE /repos/${repository}/issues/comments/11`,
        `DELETE /repos/${repository}/pulls/comments/21`,
        `PATCH /repos/${repository}/issues/6`,
        `PUT /repos/${repository}/pulls/5/reviews/31`,
        `POST /repos/${repository}/security-advisories/reports`,
    ]);
    assert.equal(writes[2].body.body, REMOVED_TEXT);
    assert.equal(writes[2].body.state, "closed");
    const everything = JSON.stringify({ lines, writes });
    assert.ok(!everything.includes(fakeOauthToken), "the OAuth token is never printed or sent");
    assert.ok(!everything.includes(fakeApiKey), "the API key is never printed or sent");
    assert.ok(lines.some((line) => line.includes("private security report was filed")));
});

test("passes and changes nothing when the run posted no token", async () => {
    const { request, calls } = fakeGitHub({
        [`/repos/${repository}/issues/comments`]: [
            { id: 12, html_url: "https://example.test/c/12", user: { login: "github-actions[bot]" }, body: "Looks fine.\n\nVERDICT: MERGE" },
        ],
    });
    const lines = [];
    const status = await guardGitHub({ request, repository, since, secrets: [fakeOauthToken], runUrl: "", log: (line) => lines.push(line) });
    assert.equal(status, 0);
    assert.ok(calls.every((call) => call.method === "GET"));
});

test("still fails when the report cannot be filed", async () => {
    const { request } = fakeGitHub({
        [`/repos/${repository}/issues/comments`]: [
            { id: 11, html_url: "https://example.test/c/11", user: { login: "github-actions[bot]" }, body: plainSecret },
        ],
    });
    const failingReport = async (method, path, body) => (path.endsWith("/reports") ? { status: 403, data: {} } : request(method, path, body));
    const lines = [];
    const status = await guardGitHub({ request: failingReport, repository, since, secrets: [plainSecret], runUrl: "", log: (line) => lines.push(line) });
    assert.equal(status, 1);
    assert.ok(lines.some((line) => line.includes("could not be filed")));
});

test("checks files and fails without printing the value", async () => {
    const files = { "result.md": "PR\nTitle\nBody", "fix.patch": `+const key = "${fakeApiKey}";` };
    const lines = [];
    const status = await guardFiles({
        paths: ["result.md", "fix.patch", "missing.txt"],
        secrets: [fakeApiKey],
        log: (line) => lines.push(line),
        readText: async (path) => {
            if (!(path in files)) throw new Error("missing");
            return files[path];
        },
    });
    assert.equal(status, 1);
    assert.equal(lines.length, 1);
    assert.match(lines[0], /fix\.patch contains a token value/);
    assert.ok(!lines[0].includes(fakeApiKey));
});

test("refuses to run the GitHub check without its inputs", async () => {
    const lines = [];
    assert.equal(await main(["github"], {}, (line) => lines.push(line)), 2);
    assert.equal(await main(["github", "--since", "yesterday"], { GITHUB_REPOSITORY: repository, GH_TOKEN: "x" }, () => {}), 2);
    assert.equal(await main(["unknown"], {}, () => {}), 2);
});

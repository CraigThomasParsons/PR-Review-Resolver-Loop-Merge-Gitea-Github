// label-new-pr.js: add review:requested to a PR the review/resolve/merge
// pipeline has never labelled, so a brand-new PR enters the loop within
// seconds instead of waiting for pr-pipeline.timer's hourly tick.
//
// Mirrors the exact bot/skip criteria skills/pr-loops-common/gitea-pr.py and
// pr-loop.sh already use, so this agrees with the rest of the pipeline on
// what counts as a PR worth touching -- see that file's `is_bot` comment and
// pr-loop.sh's `PR_LOOP_SKIP_PATTERN` default.
const BOT_LOGINS = new Set(["gitea-actions", "actions-user"]);
const SKIP_TITLE_PATTERN = /docblock-backfill|^chore\(#152\)/;
const REQUESTED_LABEL = "review:requested";

function skip(reason) {
  console.log(`skip: ${reason}`);
  process.exit(0);
}

async function main() {
  const { GITEA_API_URL, REPO, PR_NUMBER, TOKEN, IS_DRAFT, AUTHOR_LOGIN, PR_TITLE, EXISTING_LABELS } = process.env;

  if (IS_DRAFT === "true") skip("draft PR");

  const login = (AUTHOR_LOGIN || "").toLowerCase();
  if (BOT_LOGINS.has(login) || login.endsWith("[bot]")) skip(`bot author ${AUTHOR_LOGIN}`);

  if (SKIP_TITLE_PATTERN.test(PR_TITLE || "")) skip(`title matches the skip pattern: ${PR_TITLE}`);

  const existing = JSON.parse(EXISTING_LABELS || "[]").map((l) => l.name);
  if (existing.some((name) => name.startsWith("review:") || name.startsWith("agent:"))) {
    skip(`already labelled (${existing.join(", ")}); the pipeline already knows about this PR`);
  }

  const headers = { Authorization: `token ${TOKEN}`, "Content-Type": "application/json" };

  const labelsResp = await fetch(`${GITEA_API_URL}/repos/${REPO}/labels?limit=50`, { headers });
  if (!labelsResp.ok) {
    throw new Error(`listing labels failed: ${labelsResp.status} ${await labelsResp.text()}`);
  }
  const labels = await labelsResp.json();
  const requested = labels.find((l) => l.name === REQUESTED_LABEL);
  if (!requested) {
    throw new Error(`repo has no "${REQUESTED_LABEL}" label defined -- run the label roller first`);
  }

  const addResp = await fetch(`${GITEA_API_URL}/repos/${REPO}/issues/${PR_NUMBER}/labels`, {
    method: "POST",
    headers,
    body: JSON.stringify({ labels: [requested.id] }),
  });
  if (!addResp.ok) {
    throw new Error(`adding ${REQUESTED_LABEL} failed: ${addResp.status} ${await addResp.text()}`);
  }
  console.log(`added ${REQUESTED_LABEL} to #${PR_NUMBER}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});

// Files in-app user reports and crash reports as GitHub issues so they can be
// triaged in the project tracker. Enabled purely through environment variables,
// so nothing secret ever lives in the repository:
//
//   COMMSUITE_GH_REPORTER_TOKEN  a token (classic or fine-grained) that may
//                                create issues on the tracker repo.
//   COMMSUITE_GH_REPORTER_REPO   optional "owner/name" override
//                                (defaults to AlekseyShvartsGD/commsuite).
//
// When the token is absent, reporting stays local-only (user reports are still
// stored in SQLite and shown to moderators); no request is made to GitHub.
//
// Crash reports are de-duplicated: a crash whose summary already has an issue
// adds an occurrence comment to that issue (and reopens it if it was closed)
// instead of filing a second identical issue. This keeps automatic reporting
// usable when many devices hit the same bug.

const DEFAULT_REPO = 'AlekseyShvartsGD/commsuite';
const API = 'https://api.github.com';
const CRASH_MARKER = '<!-- commsuite-crash -->';
const CRASH_OCCURRENCE_MARKER = '<!-- commsuite-crash-occurrence -->';
const MAX_ISSUE_PAGES = 10;
const DEFAULT_COMMENT_COOLDOWN_MS = 15 * 60 * 1000;

export function reportingConfigured() {
  return Boolean(process.env.COMMSUITE_GH_REPORTER_TOKEN);
}

export function reportingRepo() {
  return process.env.COMMSUITE_GH_REPORTER_REPO || DEFAULT_REPO;
}

function commentCooldownMs() {
  const value = Number(process.env.COMMSUITE_CRASH_COMMENT_COOLDOWN_MS);
  return Number.isFinite(value) && value >= 0 ? value : DEFAULT_COMMENT_COOLDOWN_MS;
}

async function github(path, { method = 'GET', body } = {}) {
  const token = process.env.COMMSUITE_GH_REPORTER_TOKEN;
  if (!token) throw new Error('GitHub reporting token is not configured');

  const response = await fetch(`${API}${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'commsuite-reporter',
      ...(body ? { 'Content-Type': 'application/json' } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });

  if (!response.ok) {
    const detail = await response.text().catch(() => '');
    throw new Error(`GitHub ${response.status}: ${detail.slice(0, 300)}`);
  }
  if (response.status === 204) return null;
  return response.json();
}

async function postIssue(title, body, labels = []) {
  if (!reportingConfigured()) return { ok: false, skipped: true };

  const repo = reportingRepo();
  const payload = { title, body };
  if (labels.length) payload.labels = labels;
  const issue = await github(`/repos/${repo}/issues`, {
    method: 'POST',
    body: payload,
  });
  return {
    ok: true,
    created: true,
    number: issue.number,
    url: issue.html_url,
  };
}

function buildUserReportIssue({ reporter, target, reason, createdAt }) {
  const title = `User report: @${target.username} reported by @${reporter.username}`;
  const body = [
    `<!-- commsuite-report ${reporter.id} -> ${target.id} -->`,
    'An in-app report was submitted.',
    '',
    '### Reported user',
    `- Display name: **${target.display_name}**`,
    `- Username: @${target.username}`,
    `- User ID: \`${target.id}\``,
    '',
    '### Reporter',
    `- Display name: **${reporter.display_name}**`,
    `- Username: @${reporter.username}`,
    `- User ID: \`${reporter.id}\``,
    '',
    '### Reason',
    reason && reason.trim() ? reason.trim() : '_(no reason given)_',
    '',
    `_Submitted ${new Date(createdAt).toISOString()}_`,
  ].join('\n');
  return { title, body };
}

/// Creates a GitHub issue for a fresh user report. Resolves with
/// `{ ok, number, url }` on success or `{ ok: false, skipped: true }` when no
/// token is configured. Throws on a non-2xx GitHub response.
export async function fileReportIssue({ reporter, target, reason, createdAt }) {
  const { title, body } = buildUserReportIssue({
    reporter,
    target,
    reason,
    createdAt: createdAt ?? Date.now(),
  });
  return postIssue(title, body, ['report']);
}

export function crashSummary(log) {
  for (const raw of String(log || '').split('\n')) {
    const line = raw.trim().replace(/^\[[^\]]*\]\s*/, '').trim();
    if (!line) continue;
    if (/^#\d/.test(line)) continue; // Dart stack frame
    if (line.startsWith('at ')) continue; // stack frame
    return line.slice(0, 120);
  }
  return 'unhandled error';
}

/// Stable identity for a crash: the human-readable summary line, with
/// whitespace/case normalisation so small formatting differences still map to
/// the same issue.
export function crashSignature(log) {
  return crashSummary(log).replace(/\s+/g, ' ').trim().toLowerCase();
}

function normaliseTitle(title) {
  return String(title || '').replace(/\s+/g, ' ').trim().toLowerCase();
}

function buildCrashIssue({ timestamp, log, platform, specs, appVersion, username, auto }) {
  const title = `App crash: ${crashSummary(log)}`;
  const lines = [
    CRASH_MARKER,
    auto
      ? 'An unhandled crash was reported automatically by the app.'
      : 'An unhandled crash was reported from the app.',
    '',
    '### Details',
    `- **Reported by:** ${username ? `@${username}` : '_anonymous_'}`,
    `- **When:** ${timestamp}`,
  ];
  if (appVersion) lines.push(`- **App version:** ${appVersion}`);
  if (platform) lines.push(`- **Platform:** ${platform}`);

  const specEntries = Object.entries(specs || {}).filter(
    ([, value]) => value !== null && value !== undefined && String(value).trim() !== ''
  );
  if (specEntries.length) {
    lines.push('', '### Device');
    for (const [key, value] of specEntries) lines.push(`- **${key}:** ${value}`);
  }

  lines.push('', '### Log', '```', String(log).replace(/```/g, "'''"), '```');
  return { title, body: lines.join('\n') };
}

/// Finds an existing crash issue with the same normalised title. Pages through
/// issues (newest first) so older reports are still recognised. Issues filed
/// before de-duplication existed are matched the same way, as long as their
/// title follows `App crash: <summary>`.
async function findCrashIssue(title) {
  const repo = reportingRepo();
  const wanted = normaliseTitle(title);
  for (let page = 1; page <= MAX_ISSUE_PAGES; page += 1) {
    const batch = await github(
      `/repos/${repo}/issues?state=all&per_page=100&sort=created&direction=desc&page=${page}`
    );
    if (!Array.isArray(batch) || batch.length === 0) return null;
    for (const issue of batch) {
      if (issue.pull_request) continue;
      if (normaliseTitle(issue.title) === wanted) return issue;
      // Defensive fallback for an issue whose title was edited but that still
      // carries the crash marker: match the summary embedded after the marker.
      if (
        typeof issue.body === 'string' &&
        issue.body.includes(CRASH_MARKER) &&
        issue.body.includes(title.slice('App crash: '.length))
      ) {
        return issue;
      }
    }
    if (batch.length < 100) return null;
  }
  return null;
}

function buildCrashOccurrenceComment(report, occurrence) {
  const lines = [
    CRASH_OCCURRENCE_MARKER,
    `### Crash recurred (occurrence #${occurrence})`,
    '',
    `- **When:** ${report.timestamp}`,
  ];
  if (report.appVersion) lines.push(`- **App version:** ${report.appVersion}`);
  if (report.platform) lines.push(`- **Platform:** ${report.platform}`);
  lines.push(`- **Reported by:** ${report.username ? `@${report.username}` : '_anonymous_'}`);

  const specEntries = Object.entries(report.specs || {}).filter(
    ([, value]) => value !== null && value !== undefined && String(value).trim() !== ''
  );
  if (specEntries.length) {
    lines.push('', '### Device');
    for (const [key, value] of specEntries) lines.push(`- **${key}:** ${value}`);
  }

  lines.push(
    '',
    'This report matched the existing crash signature, so it was attached here instead of opening a duplicate issue.',
    '',
    '<details><summary>Log</summary>',
    '',
    '```',
    String(report.log || '').replace(/```/g, "'''"),
    '```',
    '',
    '</details>'
  );
  return lines.join('\n');
}

// Occurrence counters and comment throttling are per-process. They only guard
// against comment spam; correctness (one issue per crash) always comes from the
// GitHub search below.
const occurrences = new Map();
const lastCommentAt = new Map();
const crashLocks = new Map();

function noteOccurrence(number) {
  const now = Date.now();
  const previous = occurrences.get(number) ?? { count: 0, firstSeenAt: now };
  previous.count += 1;
  previous.lastSeenAt = now;
  occurrences.set(number, previous);

  const last = lastCommentAt.get(number) ?? 0;
  const allowed = now - last >= commentCooldownMs();
  if (allowed) lastCommentAt.set(number, now);
  return { count: previous.count, commentAllowed: allowed };
}

/// Serialises reports with the same signature so two devices crashing at the
/// same moment cannot both miss the existing issue and create a duplicate.
function withCrashLock(key, task) {
  const previous = crashLocks.get(key) ?? Promise.resolve();
  const current = previous.catch(() => {}).then(task);
  crashLocks.set(key, current);
  current
    .finally(() => {
      if (crashLocks.get(key) === current) crashLocks.delete(key);
    })
    .catch(() => {});
  return current;
}

/// Files an app crash. Resolves with `{ ok, created, number, url }` for a new
/// issue, `{ ok, created: false, duplicate: true, number, url, reopened }` for
/// an existing one, or `{ ok: false, skipped: true }` when reporting is off.
export async function fileCrashIssue(report) {
  if (!reportingConfigured()) return { ok: false, skipped: true };

  const { title, body } = buildCrashIssue(report);
  return withCrashLock(crashSignature(report.log), async () => {
    const existing = await findCrashIssue(title);
    if (!existing) return postIssue(title, body, ['bug']);

    const occurrence = noteOccurrence(existing.number);
    let commented = false;
    if (occurrence.commentAllowed) {
      const repo = reportingRepo();
      await github(`/repos/${repo}/issues/${existing.number}/comments`, {
        method: 'POST',
        body: { body: buildCrashOccurrenceComment(report, occurrence.count) },
      });
      commented = true;
    }

    let reopened = false;
    if (existing.state === 'closed') {
      const repo = reportingRepo();
      await github(`/repos/${repo}/issues/${existing.number}`, {
        method: 'PATCH',
        body: { state: 'open', state_reason: 'reopened' },
      });
      reopened = true;
    }

    return {
      ok: true,
      created: false,
      duplicate: true,
      number: existing.number,
      url: existing.html_url,
      commented,
      reopened,
      occurrences: occurrence.count,
    };
  });
}

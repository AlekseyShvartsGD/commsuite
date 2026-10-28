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

const DEFAULT_REPO = 'AlekseyShvartsGD/commsuite';
const API = 'https://api.github.com';

export function reportingConfigured() {
  return Boolean(process.env.COMMSUITE_GH_REPORTER_TOKEN);
}

export function reportingRepo() {
  return process.env.COMMSUITE_GH_REPORTER_REPO || DEFAULT_REPO;
}

async function postIssue(title, body, labels = []) {
  const token = process.env.COMMSUITE_GH_REPORTER_TOKEN;
  if (!token) return { ok: false, skipped: true };

  const repo = reportingRepo();
  const payload = { title, body };
  if (labels.length) payload.labels = labels;
  const response = await fetch(`${API}/repos/${repo}/issues`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'commsuite-reporter',
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(payload),
  });

  if (!response.ok) {
    const detail = await response.text().catch(() => '');
    throw new Error(`GitHub ${response.status}: ${detail.slice(0, 300)}`);
  }

  const issue = await response.json();
  return { ok: true, number: issue.number, url: issue.html_url };
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

function crashSummary(log) {
  for (const raw of String(log || '').split('\n')) {
    const line = raw.trim().replace(/^\[[^\]]*\]\s*/, '').trim();
    if (!line) continue;
    if (/^#\d/.test(line)) continue; // Dart stack frame
    if (line.startsWith('at ')) continue; // stack frame
    return line.slice(0, 120);
  }
  return 'unhandled error';
}

function buildCrashIssue({ timestamp, log, platform, specs, appVersion, username }) {
  const title = `App crash: ${crashSummary(log)}`;
  const lines = [
    '<!-- commsuite-crash -->',
    'An unhandled crash was reported from the app.',
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

/// Creates a GitHub issue for an app crash. Same resolution/error contract as
/// [fileReportIssue].
export async function fileCrashIssue(report) {
  const { title, body } = buildCrashIssue(report);
  return postIssue(title, body, ['bug']);
}

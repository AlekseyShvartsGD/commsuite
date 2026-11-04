import assert from 'node:assert/strict';
import { test, beforeEach, afterEach } from 'node:test';

import {
  crashSignature,
  fileCrashIssue,
  fileReportIssue,
  reportingConfigured,
} from '../github.js';

const ORIGINAL_FETCH = globalThis.fetch;
const ORIGINAL_ENV = {
  token: process.env.COMMSUITE_GH_REPORTER_TOKEN,
  repo: process.env.COMMSUITE_GH_REPORTER_REPO,
  cooldown: process.env.COMMSUITE_CRASH_COMMENT_COOLDOWN_MS,
};

function report(overrides = {}) {
  return {
    timestamp: '2026-11-03T10:00:00.000Z',
    log: 'Boom: something broke\n#0      main (package:commsuite/main.dart:10:3)',
    platform: 'windows 10.0.0',
    appVersion: '1.1.3+46',
    username: 'alice',
    auto: true,
    specs: { Device: 'Test PC' },
    ...overrides,
  };
}

function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

beforeEach(() => {
  process.env.COMMSUITE_GH_REPORTER_TOKEN = 'test-token';
  process.env.COMMSUITE_GH_REPORTER_REPO = 'acme/commsuite';
  process.env.COMMSUITE_CRASH_COMMENT_COOLDOWN_MS = '0';
});

afterEach(() => {
  globalThis.fetch = ORIGINAL_FETCH;
  for (const [key, value] of Object.entries({
    COMMSUITE_GH_REPORTER_TOKEN: ORIGINAL_ENV.token,
    COMMSUITE_GH_REPORTER_REPO: ORIGINAL_ENV.repo,
    COMMSUITE_CRASH_COMMENT_COOLDOWN_MS: ORIGINAL_ENV.cooldown,
  })) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
});

test('crash signature ignores timestamps, case and extra whitespace', () => {
  assert.equal(
    crashSignature('[2026-11-03T10:00:00Z]\n  BOOM:   Something broke\n#0 frame'),
    'boom: something broke'
  );
});

test('reporting can be disabled without touching GitHub', async () => {
  delete process.env.COMMSUITE_GH_REPORTER_TOKEN;
  let calls = 0;
  globalThis.fetch = async () => {
    calls += 1;
    throw new Error('must not be called');
  };

  assert.equal(reportingConfigured(), false);
  const result = await fileCrashIssue(report());
  assert.deepEqual(result, { ok: false, skipped: true });
  assert.equal(calls, 0);
});

test('a matching closed issue gets a comment and is reopened', async () => {
  const calls = [];
  const issues = [
    {
      number: 42,
      title: 'App crash: Boom: something broke',
      state: 'closed',
      html_url: 'https://github.com/acme/commsuite/issues/42',
      body: '<!-- commsuite-crash -->',
    },
  ];

  globalThis.fetch = async (url, options = {}) => {
    const method = options.method ?? 'GET';
    calls.push({ method, url: String(url), body: options.body });

    if (method === 'GET' && String(url).includes('/issues?')) {
      return jsonResponse(issues);
    }
    if (method === 'POST' && String(url).endsWith('/issues/42/comments')) {
      return jsonResponse({ id: 1 }, 201);
    }
    if (method === 'PATCH' && String(url).endsWith('/issues/42')) {
      return jsonResponse({ number: 42, state: 'open' });
    }
    if (method === 'POST' && String(url).endsWith('/issues')) {
      throw new Error('a duplicate issue must not be created');
    }
    throw new Error(`unexpected request ${method} ${url}`);
  };

  const result = await fileCrashIssue(report());

  assert.equal(result.ok, true);
  assert.equal(result.created, false);
  assert.equal(result.duplicate, true);
  assert.equal(result.number, 42);
  assert.equal(result.reopened, true);
  assert.equal(result.commented, true);

  const comment = calls.find((c) => c.method === 'POST');
  assert.match(comment.body, /commsuite-crash-occurrence/);
  assert.match(comment.body, /2026-11-03T10:00:00.000Z/);
  assert.match(comment.body, /1\.1\.3\+46/);

  const patch = calls.find((c) => c.method === 'PATCH');
  assert.match(patch.body, /"state":"open"/);
  assert.equal(calls.some((c) => c.method === 'POST' && c.url.endsWith('/issues')), false);
});

test('a repeated crash increments the occurrence count', async () => {
  const issues = [
    {
      number: 7,
      title: 'App crash: Boom: something broke',
      state: 'open',
      html_url: 'https://github.com/acme/commsuite/issues/7',
      body: '<!-- commsuite-crash -->',
    },
  ];
  const comments = [];

  globalThis.fetch = async (url, options = {}) => {
    const method = options.method ?? 'GET';
    if (method === 'GET' && String(url).includes('/issues?')) {
      return jsonResponse(issues);
    }
    if (method === 'POST' && String(url).endsWith('/issues/7/comments')) {
      comments.push(JSON.parse(options.body).body);
      return jsonResponse({ id: comments.length }, 201);
    }
    throw new Error(`unexpected request ${method} ${url}`);
  };

  await fileCrashIssue(report());
  const second = await fileCrashIssue(report({ timestamp: '2026-11-04T10:00:00.000Z' }));

  assert.equal(second.occurrences, 2);
  assert.equal(comments.length, 2);
  assert.match(comments[1], /occurrence #2/);
});

test('comment cooldown suppresses comment spam but still counts occurrences', async () => {
  process.env.COMMSUITE_CRASH_COMMENT_COOLDOWN_MS = '3600000';
  const issues = [
    {
      number: 11,
      title: 'App crash: Boom: something broke',
      state: 'open',
      html_url: 'https://github.com/acme/commsuite/issues/11',
      body: '<!-- commsuite-crash -->',
    },
  ];
  let comments = 0;

  globalThis.fetch = async (url, options = {}) => {
    const method = options.method ?? 'GET';
    if (method === 'GET' && String(url).includes('/issues?')) {
      return jsonResponse(issues);
    }
    if (method === 'POST' && String(url).endsWith('/issues/11/comments')) {
      comments += 1;
      return jsonResponse({ id: comments }, 201);
    }
    throw new Error(`unexpected request ${method} ${url}`);
  };

  const first = await fileCrashIssue(report());
  const second = await fileCrashIssue(report());

  assert.equal(first.commented, true);
  assert.equal(second.commented, false);
  assert.equal(second.occurrences, 2);
  assert.equal(comments, 1);
});

test('a new crash creates exactly one issue', async () => {
  const issues = [];
  const created = [];

  globalThis.fetch = async (url, options = {}) => {
    const method = options.method ?? 'GET';
    const text = String(url);
    if (method === 'GET' && text.includes('/issues?')) {
      return jsonResponse(issues);
    }
    if (method === 'POST' && text.endsWith('/issues')) {
      const payload = JSON.parse(options.body);
      created.push(payload);
      const issue = {
        number: 77,
        title: payload.title,
        state: 'open',
        html_url: 'https://github.com/acme/commsuite/issues/77',
        body: payload.body,
      };
      issues.push(issue);
      return jsonResponse(issue, 201);
    }
    throw new Error(`unexpected request ${method} ${url}`);
  };

  const result = await fileCrashIssue(report());

  assert.equal(result.ok, true);
  assert.equal(result.created, true);
  assert.equal(result.number, 77);
  assert.equal(created.length, 1);
  assert.equal(created[0].title, 'App crash: Boom: something broke');
  assert.deepEqual(created[0].labels, ['bug']);
  assert.match(created[0].body, /reported automatically/);
});

test('concurrent identical crashes are serialised into one issue', async () => {
  const issues = [];
  let created = 0;

  globalThis.fetch = async (url, options = {}) => {
    const method = options.method ?? 'GET';
    const text = String(url);
    if (method === 'GET' && text.includes('/issues?')) {
      return jsonResponse(issues.map((issue) => ({ ...issue })));
    }
    if (method === 'POST' && text.endsWith('/issues')) {
      created += 1;
      const payload = JSON.parse(options.body);
      const issue = {
        // Keep the second request in flight long enough for the first to land.
        number: 90 + created,
        title: payload.title,
        state: 'open',
        html_url: 'https://github.com/acme/commsuite/issues/90',
        body: payload.body,
      };
      await new Promise((resolve) => setTimeout(resolve, 10));
      issues.push(issue);
      return jsonResponse(issue, 201);
    }
    if (method === 'POST' && /\/issues\/\d+\/comments$/.test(text)) {
      return jsonResponse({ id: 1 }, 201);
    }
    throw new Error(`unexpected request ${method} ${url}`);
  };

  const results = await Promise.all([
    fileCrashIssue(report()),
    fileCrashIssue(report()),
  ]);

  assert.equal(created, 1);
  assert.equal(results.filter((r) => r.created).length, 1);
  assert.equal(results.filter((r) => r.duplicate).length, 1);
});

test('user reports still create their own issues', async () => {
  let created = null;
  globalThis.fetch = async (url, options = {}) => {
    const method = options.method ?? 'GET';
    if (method === 'POST' && String(url).endsWith('/issues')) {
      created = JSON.parse(options.body);
      return jsonResponse(
        { number: 5, html_url: 'https://github.com/acme/commsuite/issues/5' },
        201
      );
    }
    throw new Error(`unexpected request ${method} ${url}`);
  };

  const result = await fileReportIssue({
    reporter: { id: 'u1', username: 'alice', display_name: 'Alice' },
    target: { id: 'u2', username: 'bob', display_name: 'Bob' },
    reason: 'spam',
    createdAt: 0,
  });

  assert.equal(result.number, 5);
  assert.ok(created.title.includes('@bob'));
  assert.deepEqual(created.labels, ['report']);
});

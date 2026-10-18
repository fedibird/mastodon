import { CLOSED_SOURCES, SEEK_PREFERENCE, TIMELINE_SEEK_VERSION } from './constants';

const SECRET_KEYS = ['q', 'query', 'text', 'raw', 'body'];

const copyContext = (context) => {
  const source = context || {};
  const next = {};

  Object.keys(source).forEach(key => {
    if (SECRET_KEYS.indexOf(key) !== -1) {
      return;
    }

    next[key] = source[key];
  });

  return next;
};

const idFromPath = (path, pattern) => {
  const match = String(path || '').match(pattern);

  return match ? decodeURIComponent(match[1]) : null;
};

// Source identity comes from the P1 history contract. The column id is a view.
export const seekSourceFromContract = (contract) => {
  if (!contract || typeof contract.source !== 'string' || !contract.source) {
    return null;
  }

  const context = copyContext(contract.params);

  if (contract.source === 'list' || contract.source === 'group') {
    const id = idFromPath(contract.path, /\/(\d+)\s*$/);

    if (id) {
      context.id = id;
    }
  }

  if (contract.source === 'hashtag') {
    const hashtag = idFromPath(contract.path, /\/tag\/([^/?#]+)/);

    if (hashtag) {
      context.hashtag = hashtag;
    }
  }

  if (contract.source === 'account') {
    const accountId = idFromPath(contract.path, /\/accounts\/([^/?#]+)\/statuses/);

    if (accountId) {
      context.account_id = accountId;
    }
  }

  return {
    source: contract.source,
    context,
  };
};

const stableContext = (context) => {
  const keys = Object.keys(context || {}).sort();

  return keys.map(key => `${key}=${JSON.stringify(context[key])}`).join('&');
};

export const seekSourceKey = (contract) => {
  const parsed = seekSourceFromContract(contract);

  if (!parsed) {
    return '';
  }

  return `${parsed.source}?${stableContext(parsed.context)}`;
};

export const createSeekQuery = ({ kind, target, preference = SEEK_PREFERENCE.NEAREST, source, context } = {}) => {
  const input = target || {};
  const safeTarget = {};
  let rejected = false;

  SECRET_KEYS.forEach(key => {
    if (Object.prototype.hasOwnProperty.call(input, key)) {
      rejected = true;
    }
  });

  if (typeof input.id === 'string') {
    safeTarget.id = input.id;
  }

  if (typeof input.at === 'string') {
    safeTarget.at = input.at;
  }

  if (typeof input.accountId === 'string') {
    safeTarget.accountId = input.accountId;
  }

  if (rejected) {
    safeTarget.rejected = true;
  }

  return {
    version: TIMELINE_SEEK_VERSION,
    kind,
    preference,
    source,
    context: copyContext(context),
    target: safeTarget,
  };
};

export const seekTargetPayload = (target) => {
  const payload = {};

  if (!target || target.rejected) {
    return payload;
  }

  if (typeof target.id === 'string') {
    payload.id = target.id;
  }

  if (typeof target.at === 'string') {
    payload.at = target.at;
  }

  if (typeof target.accountId === 'string') {
    payload.account_id = target.accountId;
  }

  return payload;
};

export const normalizeSeekResult = (payload) => {
  const body = payload || {};
  const anchorId = typeof body.anchor_id === 'string' ? body.anchor_id : null;

  return {
    version: body.version || TIMELINE_SEEK_VERSION,
    outcome: typeof body.outcome === 'string' ? body.outcome : 'unavailable',
    capability: typeof body.capability === 'string' ? body.capability : 'unavailable',
    precision: typeof body.precision === 'string' ? body.precision : null,
    anchorId,
    displayRowId: typeof body.display_row_id === 'string' ? body.display_row_id : anchorId,
    limitations: Array.isArray(body.limitations) ? body.limitations.filter(item => typeof item === 'string') : [],
    reason: typeof body.reason === 'string' ? body.reason : null,
  };
};

export const closedSeekSource = (source) => CLOSED_SOURCES.indexOf(source) !== -1;

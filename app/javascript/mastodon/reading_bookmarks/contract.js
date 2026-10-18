// Named reading bookmarks. This is not the P3 session registry and not a
// status bookmark. Payloads carry a source, its context, and one anchor.
// Search text, status bodies, tokens, windows, and column identity are refused.

export const READING_BOOKMARK_VERSION = 1;
export const READING_BOOKMARK_LIMIT = 50;
export const READING_BOOKMARK_NAME_MAX = 100;

const SEARCH_KEYS = [
  'q',
  'query',
  'text',
  'raw',
  'body',
  'spoiler_text',
  'spoiler',
  'content',
  'token',
  'access_token',
  'password',
  'secret',
  'caption',
];

const WINDOW_KEYS = ['window', 'items', 'pages', 'statuses', 'status', 'ids', 'account'];

const PARAM_KEYS = {
  home: ['visibilities'],
  limited: ['visibilities'],
  list: ['id'],
  group: ['id', 'only_media', 'without_media', 'tagged'],
  hashtag: ['hashtag', 'any', 'all', 'none'],
  public: ['remote', 'only_media', 'without_media', 'without_bot'],
  domain: ['domain', 'local', 'only_media', 'without_media', 'without_bot'],
  personal: ['only_media', 'without_media'],
};

const CONTROL = /[\u0000-\u001F\u007F]/;
const OFFSET_LIMIT = 1000000;

const fail = (reason) => ({ ok: false, reason });

const own = (object, key) => Object.prototype.hasOwnProperty.call(object, key);

const findKey = (value, keys) => {
  if (!value || typeof value !== 'object') {
    return false;
  }

  if (Array.isArray(value)) {
    return value.some(item => findKey(item, keys));
  }

  return Object.keys(value).some(key => keys.indexOf(key) !== -1 || findKey(value[key], keys));
};

const idFromPath = (path, pattern) => {
  const match = String(path || '').match(pattern);

  return match ? decodeURIComponent(match[1]) : null;
};

export const readingBookmarkTimelineId = (source, context) => {
  const data = context || {};

  if (source === 'list' || source === 'group') {
    return `${source}:${data.id}`;
  }

  if (source === 'hashtag') {
    return `hashtag:${data.hashtag}`;
  }

  if (source === 'domain') {
    return `domain:${String(data.domain || '').toLowerCase()}`;
  }

  return source;
};

const copyAllowlisted = (params, keys) => {
  const context = {};
  const unknown = Object.keys(params).filter(key => keys.indexOf(key) === -1);

  if (unknown.length > 0) {
    return null;
  }

  keys.forEach(key => {
    if (own(params, key)) {
      context[key] = params[key];
    }
  });

  return context;
};

const contextFromContract = (contract) => {
  if (!contract || typeof contract.source !== 'string' || !PARAM_KEYS[contract.source]) {
    return fail('invalid_source');
  }

  const params = contract.params && typeof contract.params === 'object' ? contract.params : {};
  const context = copyAllowlisted(params, PARAM_KEYS[contract.source]);

  if (!context) {
    return fail('unsupported_field');
  }

  if (contract.source === 'list' || contract.source === 'group') {
    const pathId = idFromPath(contract.path, /\/(\d+)\s*$/);

    if (pathId && context.id && String(context.id) !== pathId) {
      return fail('source_mismatch');
    }

    if (pathId && !context.id) {
      context.id = pathId;
    }
  }

  if (contract.source === 'hashtag' && !context.hashtag) {
    const hashtag = idFromPath(contract.path, /\/tag\/([^/?#]+)/);

    if (hashtag) {
      context.hashtag = hashtag;
    }
  }

  if (contract.source === 'domain' && own(context, 'local') && context.local !== false) {
    return fail('invalid_context');
  }

  if (own(context, 'local')) {
    delete context.local;
  }

  return { ok: true, source: contract.source, context };
};

const anchorPayload = (anchor) => {
  if (!anchor || anchor.version !== READING_BOOKMARK_VERSION) {
    return null;
  }

  if (!Number.isInteger(anchor.offsetPx) || anchor.offsetPx < -OFFSET_LIMIT || anchor.offsetPx > OFFSET_LIMIT) {
    return null;
  }

  if (anchor.alignment !== 'top' && anchor.alignment !== 'center') {
    return null;
  }

  const payload = {
    version: READING_BOOKMARK_VERSION,
    status_id: anchor.statusId,
    offset_px: anchor.offsetPx,
    alignment: anchor.alignment,
  };

  if (anchor.displayRowId) {
    payload.display_row_id = anchor.displayRowId;
  }

  if (anchor.capturedAt) {
    payload.captured_at = anchor.capturedAt;
  }

  return payload;
};

const namePayload = (name) => {
  if (typeof name !== 'string' || CONTROL.test(name)) {
    return null;
  }

  const stripped = name.trim();

  if (stripped.length < 1 || stripped.length > READING_BOOKMARK_NAME_MAX) {
    return null;
  }

  return stripped;
};

export const readingBookmarkPayload = ({
  name,
  contract,
  anchor,
  lockVersion,
  sourceTimelineId,
} = {}) => {
  const scanned = { contract, anchor, name };

  if (findKey(scanned, SEARCH_KEYS)) {
    return fail('search_or_content_not_accepted');
  }

  if (findKey(scanned, WINDOW_KEYS)) {
    return fail('window_not_accepted');
  }

  const named = namePayload(name);
  const parsed = contextFromContract(contract);
  const encoded = anchorPayload(anchor);

  if (!named) {
    return fail('invalid_name');
  }

  if (!parsed.ok) {
    return parsed;
  }

  if (!encoded) {
    return fail('invalid_anchor');
  }

  const timelineId = readingBookmarkTimelineId(parsed.source, parsed.context);

  if (sourceTimelineId && sourceTimelineId !== timelineId && !(parsed.source === 'domain' && String(sourceTimelineId).toLowerCase() === timelineId)) {
    return fail('source_mismatch');
  }

  const payload = {
    name: named,
    source: parsed.source,
    source_timeline_id: timelineId,
    context: parsed.context,
    anchor: encoded,
  };

  if (Number.isInteger(lockVersion)) {
    payload.lock_version = lockVersion;
  }

  return { ok: true, payload };
};

const sourceFromIdentity = (source) => {
  if (!source || source.kind !== 'timeline_source' || typeof source.sourceTimelineId !== 'string') {
    return null;
  }

  const conditions = source.conditions && typeof source.conditions === 'object' ? source.conditions : {};
  const id = source.sourceTimelineId;
  const simple = ['home', 'limited', 'public', 'personal'];

  if (simple.indexOf(id) !== -1) {
    return { source: id, params: conditions, path: '' };
  }

  const list = /^(list|group):([1-9]\d*)$/.exec(id);

  if (list) {
    return {
      source: list[1],
      params: conditions,
      path: `/api/v1/timelines/${list[1]}/${list[2]}`,
    };
  }

  const hashtag = /^hashtag:([^/?#]+)$/.exec(id);

  if (hashtag) {
    return {
      source: 'hashtag',
      params: conditions,
      path: `/api/v1/timelines/tag/${hashtag[1]}`,
    };
  }

  const domain = /^domain:(.+)$/.exec(id);

  if (domain) {
    return {
      source: 'domain',
      params: { ...conditions, domain: conditions.domain || domain[1] },
      path: '',
    };
  }

  return null;
};

export const readingBookmarkPayloadFromPosition = ({ name, position, lockVersion } = {}) => {
  if (!position || position.version !== READING_BOOKMARK_VERSION) {
    return fail('invalid');
  }

  if (findKey(position, SEARCH_KEYS)) {
    return fail('search_or_content_not_accepted');
  }

  if (findKey(position, WINDOW_KEYS)) {
    return fail('window_not_accepted');
  }

  const contract = sourceFromIdentity(position.source);

  if (!contract) {
    return fail('invalid_source');
  }

  return readingBookmarkPayload({
    name,
    contract,
    anchor: {
      version: position.anchor && position.anchor.version,
      statusId: position.anchor && position.anchor.statusId,
      displayRowId: position.anchor && position.anchor.displayRowId,
      offsetPx: position.anchor && position.anchor.offsetPx,
      alignment: position.anchor && position.anchor.alignment,
      capturedAt: position.anchor && position.anchor.capturedAt,
    },
    lockVersion,
    sourceTimelineId: position.source.sourceTimelineId,
  });
};

export const normalizeReadingBookmark = (data) => {
  if (!data || typeof data !== 'object' || Array.isArray(data)) {
    return null;
  }

  const anchor = data.anchor || {};

  return {
    id: data.id === undefined || data.id === null ? null : String(data.id),
    name: data.name,
    source: data.source,
    sourceTimelineId: data.source_timeline_id,
    context: data.context && typeof data.context === 'object' ? data.context : {},
    anchor: {
      version: anchor.version,
      statusId: anchor.status_id,
      displayRowId: anchor.display_row_id || null,
      offsetPx: anchor.offset_px,
      alignment: anchor.alignment,
      capturedAt: anchor.captured_at || null,
    },
    sourceLabel: data.source_label || null,
    availability: data.availability || null,
    lockVersion: data.lock_version,
    createdAt: data.created_at,
    updatedAt: data.updated_at,
  };
};

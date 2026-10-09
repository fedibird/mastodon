// A mix source is a normalized descriptor, not a request URL.
// sourceKey includes the type and conditions so two uses of the same
// timeline id (for example a hashtag with different any/all/none tags)
// do not share a cache. Display titles are never part of the key.
// Timeline ids from timeline_ids.js stay with the original columns.

export const SOURCE_TYPES = [
  'home',
  'limited',
  'personal',
  'public',
  'remote',
  'domain',
  'hashtag',
  'list',
  'group',
  'account',
];

const ID_TYPES = ['list', 'group', 'account'];
const MEDIA_TYPES = ['personal', 'public', 'remote', 'domain', 'group'];
const BOT_TYPES = ['public', 'remote', 'domain'];
// Home, limited, and personal `shows` are the choices saved with the source.
// They do not follow settings.home, settings.limited, or settings.personal,
// so changing those columns later does not change an existing mix.
// A missing flag is stored as true. reblog and reply are display filters.
// private, limited, direct, and personal are visibility filters. Fetching
// must use this snapshot, not getHomeVisibilities().
const SHOW_KEYS = {
  home: ['reblog', 'reply', 'private', 'limited', 'direct', 'personal'],
  limited: ['reblog', 'reply', 'private', 'limited', 'direct', 'personal'],
  personal: ['reply'],
};

const toPlain = (value) => (value && typeof value.toJS === 'function' ? value.toJS() : value);

const isPresent = (value) => value !== undefined && value !== null && value !== '';

export const normalizeTag = (value) => {
  const tag = String(value === undefined || value === null ? '' : value).trim().replace(/^#+/, '');

  if (!tag) {
    return '';
  }

  if (/[\s/?#&:=]/.test(tag) || tag.includes('://')) {
    return null;
  }

  return tag.toLowerCase();
};

const normalizeTagList = (value) => {
  if (!isPresent(value)) {
    return [];
  }

  const list = Array.isArray(value) ? value : String(value).split(/[,\s]+/);
  const tags = [];

  for (let i = 0; i < list.length; i += 1) {
    const item = list[i];
    const raw = item && typeof item === 'object' ? (item.value || item.name || '') : item;
    const tag = normalizeTag(raw);

    if (tag === null) {
      return null;
    }

    if (tag && tags.indexOf(tag) === -1) {
      tags.push(tag);
    }
  }

  tags.sort();
  return tags;
};

const asBoolean = (value) => {
  if (value === true || value === 1 || value === 'true') {
    return true;
  }

  if (value === false || value === 0 || value === 'false' || value === undefined || value === null) {
    return false;
  }

  return null;
};

const cleanTitle = (value) => {
  const title = String(value === undefined || value === null ? '' : value).trim().replace(/\s+/g, ' ');

  if (!title) {
    return '';
  }

  return title.slice(0, 200);
};

const fail = (error) => ({ ok: false, error });

const normalizeShows = (input, allowed) => {
  const showsInput = isPresent(input) ? toPlain(input) : {};

  if (!showsInput || typeof showsInput !== 'object' || Array.isArray(showsInput)) {
    return fail('param_unsupported');
  }

  const provided = Object.keys(showsInput);

  for (let i = 0; i < provided.length; i += 1) {
    if (allowed.indexOf(provided[i]) === -1) {
      return fail('param_unsupported');
    }
  }

  const shows = {};

  for (let i = 0; i < allowed.length; i += 1) {
    const key = allowed[i];

    if (!Object.prototype.hasOwnProperty.call(showsInput, key)) {
      shows[key] = true;
      continue;
    }

    const value = asBoolean(showsInput[key]);

    if (value === null) {
      return fail('param_unsupported');
    }

    shows[key] = value;
  }

  return { shows };
};

const normalizeDomain = (value) => {
  const domain = String(value === undefined || value === null ? '' : value).trim().toLowerCase();

  if (!domain) {
    return fail('domain_blank');
  }

  if (domain.includes('://') || domain.includes('/') || domain.includes('?') || domain.includes('@') || domain.includes(':')) {
    return fail('url_rejected');
  }

  if (!/^[a-z0-9.-]+$/.test(domain) || domain.startsWith('.') || domain.endsWith('.') || domain.includes('..')) {
    return fail('domain_invalid');
  }

  return { domain };
};

const normalizeRecordId = (value) => {
  const id = String(value === undefined || value === null ? '' : value).trim();

  if (!id) {
    return fail('id_blank');
  }

  if (!/^\d+$/.test(id)) {
    return fail('id_invalid');
  }

  return { id };
};

const takeTags = (params, key) => {
  if (!Object.prototype.hasOwnProperty.call(params, key)) {
    return [];
  }

  const tags = normalizeTagList(params[key]);

  if (tags === null) {
    return null;
  }

  return tags;
};

export const normalizeSource = (input) => {
  const raw = toPlain(input) || {};
  const type = typeof raw.type === 'string' ? raw.type : '';

  if (SOURCE_TYPES.indexOf(type) === -1) {
    return fail('type_unknown');
  }

  const paramsInput = toPlain(raw.params) || {};

  if (paramsInput && (typeof paramsInput !== 'object' || Array.isArray(paramsInput))) {
    return fail('param_unsupported');
  }

  if (raw.endpoint || raw.url || raw.path || paramsInput.endpoint || paramsInput.url || paramsInput.path) {
    return fail('url_rejected');
  }

  const source = { type, params: {} };
  const title = cleanTitle(raw.title);

  if (title) {
    source.title = title;
  }

  if (type === 'domain') {
    const domain = normalizeDomain(raw.domain);

    if (domain.error) {
      return domain;
    }

    source.domain = domain.domain;
  }

  if (ID_TYPES.indexOf(type) !== -1) {
    const id = normalizeRecordId(raw.id);

    if (id.error) {
      return id;
    }

    source.id = id.id;
  }

  if (type === 'hashtag') {
    const id = normalizeTag(raw.id);

    if (id === null) {
      return fail('tag_invalid');
    }

    if (!id) {
      return fail('id_blank');
    }

    source.id = id;
  }

  const allowed = new Set(['shows', 'onlyMedia', 'withoutMedia', 'withoutBot', 'any', 'all', 'none', 'tagged', 'withReplies', 'withoutReblogs']);
  const paramKeys = Object.keys(paramsInput);

  for (let i = 0; i < paramKeys.length; i += 1) {
    if (!allowed.has(paramKeys[i])) {
      return fail('param_unsupported');
    }
  }

  if (SHOW_KEYS[type]) {
    const shows = normalizeShows(paramsInput.shows, SHOW_KEYS[type]);

    if (shows.error) {
      return shows;
    }

    source.params.shows = shows.shows;
  } else if (paramsInput.shows) {
    return fail('param_unsupported');
  }

  if (MEDIA_TYPES.indexOf(type) !== -1) {
    const onlyMedia = asBoolean(paramsInput.onlyMedia);
    const withoutMedia = asBoolean(paramsInput.withoutMedia);

    if (onlyMedia === null || withoutMedia === null) {
      return fail('param_unsupported');
    }

    if (onlyMedia && withoutMedia) {
      return fail('media_conflict');
    }

    if (onlyMedia) {
      source.params.onlyMedia = true;
    }

    if (withoutMedia) {
      source.params.withoutMedia = true;
    }
  } else if (paramsInput.onlyMedia || paramsInput.withoutMedia) {
    return fail('param_unsupported');
  }

  if (BOT_TYPES.indexOf(type) !== -1) {
    const withoutBot = asBoolean(paramsInput.withoutBot);

    if (withoutBot === null) {
      return fail('param_unsupported');
    }

    if (withoutBot) {
      source.params.withoutBot = true;
    }
  } else if (paramsInput.withoutBot) {
    return fail('param_unsupported');
  }

  if (type === 'hashtag') {
    const any = takeTags(paramsInput, 'any');
    const all = takeTags(paramsInput, 'all');
    const none = takeTags(paramsInput, 'none');

    if (any === null || all === null || none === null) {
      return fail('tag_invalid');
    }

    if (any.length) {
      source.params.any = any;
    }

    if (all.length) {
      source.params.all = all;
    }

    if (none.length) {
      source.params.none = none;
    }
  } else if (paramsInput.any || paramsInput.all || paramsInput.none) {
    return fail('param_unsupported');
  }

  if (type === 'group' || type === 'account') {
    if (Object.prototype.hasOwnProperty.call(paramsInput, 'tagged') && isPresent(paramsInput.tagged)) {
      const tagged = normalizeTag(paramsInput.tagged);

      if (tagged === null) {
        return fail('tag_invalid');
      }

      if (tagged) {
        source.params.tagged = tagged;
      }
    }
  } else if (paramsInput.tagged) {
    return fail('param_unsupported');
  }

  if (type === 'account') {
    const withReplies = asBoolean(paramsInput.withReplies);
    const withoutReblogs = asBoolean(paramsInput.withoutReblogs);

    if (withReplies === null || withoutReblogs === null) {
      return fail('param_unsupported');
    }

    if (withReplies) {
      source.params.withReplies = true;
    }

    if (withoutReblogs) {
      source.params.withoutReblogs = true;
    }
  } else if (paramsInput.withReplies || paramsInput.withoutReblogs) {
    return fail('param_unsupported');
  }

  return { ok: true, source };
};

const encodeList = (values) => values.map(value => encodeURIComponent(value)).join(',');

const canonicalParams = (params) => {
  const parts = [];

  Object.keys(params).sort().forEach(key => {
    const value = params[key];

    if (Array.isArray(value)) {
      parts.push(`${key}=${encodeList(value)}`);
    } else if (value && typeof value === 'object') {
      const inner = Object.keys(value).sort().map(name => `${encodeURIComponent(name)}:${value[name] === false ? '0' : '1'}`).join(',');
      parts.push(`${key}=${inner}`);
    } else if (value === true) {
      parts.push(`${key}=1`);
    } else if (typeof value === 'string') {
      parts.push(`${key}=${encodeURIComponent(value)}`);
    }
  });

  return parts.join('&') || '-';
};

const identityFor = (source) => {
  if (source.type === 'domain') {
    return encodeURIComponent(source.domain);
  }

  if (source.id) {
    return encodeURIComponent(source.id);
  }

  return '-';
};

export const sourceKey = (input) => {
  const normalized = normalizeSource(input);

  if (!normalized.ok) {
    return null;
  }

  const source = normalized.source;

  return `v1|${source.type}|${identityFor(source)}|${canonicalParams(source.params || {})}`;
};

export const sourceIdentityLabel = (input) => {
  const normalized = normalizeSource(input);

  if (!normalized.ok) {
    return '';
  }

  const source = normalized.source;

  if (source.title) {
    return source.title;
  }

  if (source.type === 'hashtag') {
    return `#${source.id}`;
  }

  if (source.type === 'domain') {
    return source.domain;
  }

  if (source.id) {
    return source.id;
  }

  return source.type;
};

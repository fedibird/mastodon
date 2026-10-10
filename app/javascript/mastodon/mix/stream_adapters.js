import { visibilityConstraints } from './adapter';
import { normalizeSource, sourceKey } from './source';

// Streaming channels follow actions/streaming.js. A source the socket cannot
// express exactly is either filtered locally (candidate) or left to REST.
export const resolveStream = (source, constraintOverrides) => {
  const normalized = normalizeSource(source);

  if (!normalized.ok) {
    return normalized;
  }

  const constraints = visibilityConstraints(constraintOverrides || {});
  const value = normalized.source;
  const params = value.params || {};
  const key = sourceKey(value);
  const base = { ok: true, key, source: value };

  if (value.type === 'account') {
    return { ...base, mode: 'rest_only' };
  }

  if (value.type === 'limited' && !constraints.enableLimitedTimeline) {
    return { ...base, mode: 'rest_only' };
  }

  if (value.type === 'home' || value.type === 'limited' || value.type === 'personal') {
    return { ...base, mode: 'candidate', channel: 'user', params: {} };
  }

  if (value.type === 'list') {
    return { ...base, mode: 'supported', channel: 'list', params: { list: value.id } };
  }

  if (value.type === 'hashtag') {
    const tags = [value.id].concat(params.any || []).map(tag => String(tag).toLowerCase()).filter((tag, index, all) => tag && all.indexOf(tag) === index);
    const channels = tags.map(tag => ({ channel: 'hashtag', params: { tag } }));
    const needsLocalFilter = (params.all && params.all.length) || (params.none && params.none.length);

    return {
      ...base,
      mode: needsLocalFilter ? 'candidate' : 'supported',
      channel: channels[0].channel,
      params: channels[0].params,
      channels,
    };
  }

  if (value.type === 'group') {
    return {
      ...base,
      mode: 'supported',
      channel: `group${mediaSuffix(params)}`,
      params: params.tagged ? { id: value.id, tagged: params.tagged } : { id: value.id },
    };
  }

  if (value.type === 'domain') {
    return {
      ...base,
      mode: 'supported',
      channel: `public:domain${botSuffix(params)}${mediaSuffix(params)}`,
      params: { domain: value.domain },
    };
  }

  if (value.type === 'public' || value.type === 'remote') {
    const remote = value.type === 'remote' ? ':remote' : '';
    const channel = `public${remote}${botSuffix(params)}${mediaSuffix(params)}`;

    return {
      ...base,
      mode: 'supported',
      channel,
      params: {},
      channels: [{ channel, params: {} }],
    };
  }

  return { ...base, mode: 'rest_only' };
};

const withChannels = (resolved) => {
  if (!resolved || !resolved.ok || resolved.channels) {
    return resolved;
  }

  if (!resolved.channel) {
    return { ...resolved, channels: [] };
  }

  return { ...resolved, channels: [{ channel: resolved.channel, params: resolved.params || {} }] };
};

export const streamSubscriptions = (source, constraintOverrides) => withChannels(resolveStream(source, constraintOverrides));

export const streamChannelId = (channel, params) => {
  const keys = Object.keys(params || {}).sort();

  if (!keys.length) {
    return channel;
  }

  return `${channel}&${keys.map(key => `${key}=${params[key]}`).join('&')}`;
};

const botSuffix = (params) => (params.withoutBot ? ':nobot' : ':bot');

const mediaSuffix = (params) => {
  let suffix = '';

  if (params.withoutMedia) {
    suffix += ':nomedia';
  }

  if (params.onlyMedia) {
    suffix += ':media';
  }

  return suffix;
};

const tagNames = (status) => {
  if (!status || !Array.isArray(status.tags)) {
    return null;
  }

  return status.tags.map(tag => String((tag && (tag.name || tag)) || '').replace(/^#/, '').toLowerCase()).filter(Boolean);
};

const hasMedia = (status) => {
  if (!status || !Array.isArray(status.media_attachments)) {
    return null;
  }

  return status.media_attachments.length > 0;
};

const accountBot = (status) => {
  const account = status && status.account;

  if (!account || typeof account !== 'object') {
    return null;
  }

  return account.bot === true;
};

const accountIdOf = (status) => {
  const account = status && status.account;

  if (account && typeof account === 'object') {
    return account.id;
  }

  return account || null;
};

const matchesTagLists = (names, params) => {
  const any = params.any || [];
  const all = params.all || [];
  const none = params.none || [];

  if (any.length && !any.some(tag => names.indexOf(tag) !== -1)) {
    return false;
  }

  if (all.some(tag => names.indexOf(tag) === -1)) {
    return false;
  }

  if (none.some(tag => names.indexOf(tag) !== -1)) {
    return false;
  }

  return true;
};

const PUBLIC_TYPES = ['public', 'remote', 'domain', 'hashtag'];

// Display conditions only. List and group membership is not inferred from the body.
const classifyDisplay = (value, status, me, flags) => {
  const params = value.params || {};
  const visibility = status.visibility_ex || status.visibility;

  if (value.type === 'account') {
    return 'unknown';
  }

  if ((value.type === 'home' || value.type === 'limited' || value.type === 'personal' || PUBLIC_TYPES.indexOf(value.type) !== -1) && !visibility) {
    return 'unknown';
  }

  if (PUBLIC_TYPES.indexOf(value.type) !== -1 && visibility !== 'public') {
    return 'reject';
  }

  if (value.type === 'home' || value.type === 'limited') {
    if (value.type === 'limited' && (visibility === 'public' || visibility === 'unlisted')) {
      return 'reject';
    }

    if (visibility !== 'public' && visibility !== 'unlisted' && params.shows && params.shows[visibility] === false) {
      return 'reject';
    }

    if (visibility === 'direct' && flags.hideDirectFromTimeline) {
      return 'reject';
    }

    if (visibility === 'personal' && flags.hidePersonalFromTimeline) {
      return 'reject';
    }

    if (value.type === 'limited' && !flags.enableLimitedTimeline) {
      return 'reject';
    }
  }

  if (value.type === 'personal' && visibility !== 'personal') {
    return 'reject';
  }

  if (value.type === 'personal' && flags.hidePersonalFromTimeline) {
    return 'reject';
  }

  const owner = accountIdOf(status);

  if (owner !== me) {
    if (params.shows && params.shows.reblog === false && status.reblog) {
      return 'reject';
    }

    if (params.shows && params.shows.reply === false && status.in_reply_to_id && status.in_reply_to_account_id !== me) {
      return 'reject';
    }
  }

  if (params.onlyMedia || params.withoutMedia) {
    const media = hasMedia(status);

    if (media === null) {
      return 'unknown';
    }

    if (params.onlyMedia && !media) {
      return 'reject';
    }

    if (params.withoutMedia && media) {
      return 'reject';
    }
  }

  if (params.withoutBot) {
    const bot = accountBot(status);

    if (bot === null) {
      return 'unknown';
    }

    if (bot) {
      return 'reject';
    }
  }

  if (value.type === 'hashtag' || params.tagged || (params.any && params.any.length) || (params.all && params.all.length) || (params.none && params.none.length)) {
    const names = tagNames(status);

    if (!names) {
      return 'unknown';
    }

    if (params.tagged && names.indexOf(String(params.tagged).toLowerCase()) === -1) {
      return 'reject';
    }

    const any = params.any || [];
    const main = value.type === 'hashtag' ? [String(value.id).toLowerCase()] : [];
    const alternatives = main.concat(any.map(tag => String(tag).toLowerCase()));

    if (alternatives.length && !names.some(name => alternatives.indexOf(name) !== -1)) {
      return 'reject';
    }

    if (!matchesTagLists(names, { ...params, any: [] })) {
      return 'reject';
    }
  }

  return 'accept';
};

// accept: membership evidence and display conditions both hold.
// reject: a checked condition failed.
// unknown: not enough evidence. Callers must not treat this as accept.
export const classifyStreamStatus = (source, status, { me = null, constraints, delivered = false } = {}) => {
  const normalized = normalizeSource(source);

  if (!normalized.ok || !status || !status.id) {
    return 'unknown';
  }

  const value = normalized.source;
  const flags = constraints || visibilityConstraints();
  const display = classifyDisplay(value, status, me, flags);

  if (display !== 'accept') {
    return display;
  }

  if (value.type === 'list' || value.type === 'group') {
    return delivered ? 'accept' : 'unknown';
  }

  return 'accept';
};

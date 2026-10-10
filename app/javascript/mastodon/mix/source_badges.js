import messages from '../features/mixes/messages';
import { normalizeSource, sourceIdentityLabel, sourceKey } from './source';

const TYPE_MESSAGE = {
  home: messages.home,
  limited: messages.limited,
  personal: messages.personal,
  public: messages.public,
  remote: messages.remote,
  domain: messages.domainType,
  hashtag: messages.hashtagType,
  list: messages.listType,
  group: messages.group,
  account: messages.account,
};

const TYPE_ICON = {
  home: 'home',
  limited: 'lock',
  personal: 'user',
  public: 'globe',
  remote: 'globe',
  domain: 'users',
  hashtag: 'tag',
  list: 'list-ul',
  group: 'users',
  account: 'user',
};

const lookupRecord = (collection, id) => {
  if (!collection || !collection.get || id === undefined || id === null || id === '') {
    return '';
  }

  const record = collection.get(String(id));

  if (!record || !record.get || record === false) {
    return '';
  }

  return record.get('title') || record.get('display_name') || record.get('acct') || record.get('username') || '';
};

const hasNarrowingParams = (source) => {
  const params = source.params || {};

  return Object.keys(params).some(key => {
    const value = params[key];

    if (value === undefined || value === null || value === '' || value === false) {
      return false;
    }

    if (Array.isArray(value)) {
      return value.length > 0;
    }

    if (key === 'shows' && value && typeof value === 'object') {
      return Object.keys(value).some(flag => value[flag] === false);
    }

    return true;
  });
};

// Link only when the column URL is the whole source. Extra tag, media,
// bot, or visibility filters are not represented by that URL.
export const sourceTimelinePath = (source) => {
  const normalized = normalizeSource(source);

  if (!normalized.ok || hasNarrowingParams(normalized.source)) {
    return null;
  }

  const plain = normalized.source;

  switch (plain.type) {
  case 'home':
    return '/timelines/home';
  case 'public':
    return '/timelines/public';
  case 'limited':
    return '/timelines/limited';
  case 'personal':
    return '/timelines/personal';
  case 'domain':
    return plain.domain ? `/timelines/public/domain/${encodeURIComponent(plain.domain)}` : null;
  case 'hashtag':
    return plain.id ? `/timelines/tag/${encodeURIComponent(plain.id)}` : null;
  case 'list':
    return plain.id ? `/timelines/list/${encodeURIComponent(plain.id)}` : null;
  case 'group':
    return plain.id ? `/timelines/groups/${encodeURIComponent(plain.id)}` : null;
  case 'account':
    return plain.id ? `/accounts/${encodeURIComponent(plain.id)}` : null;
  default:
    return null;
  }
};

const conditionsFor = (source, formatMessage) => {
  const params = source.params || {};
  const lines = [];
  const tagged = (message, values) => formatMessage(message, values);

  if (params.onlyMedia) {
    lines.push(tagged(messages.onlyMedia));
  }

  if (params.withoutMedia) {
    lines.push(tagged(messages.withoutMedia));
  }

  if (params.withoutBot) {
    lines.push(tagged(messages.withoutBot));
  }

  if (params.withReplies) {
    lines.push(tagged(messages.withReplies));
  }

  if (params.withoutReblogs) {
    lines.push(tagged(messages.withoutReblogs));
  }

  if (params.any && params.any.length) {
    lines.push(`${tagged(messages.any)}: ${params.any.join(', ')}`);
  }

  if (params.all && params.all.length) {
    lines.push(`${tagged(messages.all)}: ${params.all.join(', ')}`);
  }

  if (params.none && params.none.length) {
    lines.push(`${tagged(messages.none)}: ${params.none.join(', ')}`);
  }

  if (params.tagged) {
    lines.push(`${tagged(messages.tagged)}: ${params.tagged}`);
  }

  const shows = params.shows || {};

  if (shows.reblog === false) {
    lines.push(tagged(messages.hideReblog));
  }

  if (shows.reply === false) {
    lines.push(tagged(messages.hideReply));
  }

  if (shows.private === false) {
    lines.push(tagged(messages.hidePrivate));
  }

  if (shows.limited === false) {
    lines.push(tagged(messages.hideLimited));
  }

  if (shows.direct === false) {
    lines.push(tagged(messages.hideDirect));
  }

  if (shows.personal === false) {
    lines.push(tagged(messages.hidePersonal));
  }

  return lines;
};

const displayName = (source, formatMessage, lists, accounts) => {
  const typeMessage = TYPE_MESSAGE[source.type];
  const typeLabel = typeMessage ? formatMessage(typeMessage) : source.type;

  if (source.title) {
    return sourceIdentityLabel(source) || typeLabel;
  }

  if (source.type === 'list') {
    return lookupRecord(lists, source.id) || source.id || typeLabel;
  }

  if (source.type === 'account') {
    return lookupRecord(accounts, source.id) || source.id || typeLabel;
  }

  const identity = sourceIdentityLabel(source);

  if (!identity || identity === source.type) {
    return typeLabel;
  }

  return identity;
};

// Badges follow the saved mix order. Keys that are not in that definition
// are omitted instead of being parsed out of the sourceKey string.
export const sourceBadges = (mixSources, keys, { formatMessage, lists, accounts, warningsByKey } = {}) => {
  if (!formatMessage || !keys || !keys.length) {
    return [];
  }

  const wanted = new Set(keys);

  return (mixSources || []).reduce((badges, input) => {
    const normalized = normalizeSource(input);

    if (!normalized.ok) {
      return badges;
    }

    const source = normalized.source;
    const key = sourceKey(source);

    if (!key || !wanted.has(key)) {
      return badges;
    }

    const label = displayName(source, formatMessage, lists, accounts);
    const typeMessage = TYPE_MESSAGE[source.type];
    const conditions = conditionsFor(source, formatMessage);

    badges.push({
      key,
      type: source.type,
      icon: TYPE_ICON[source.type] || 'asterisk',
      label,
      fullLabel: label,
      typeLabel: typeMessage ? formatMessage(typeMessage) : source.type,
      detail: conditions.join(' · '),
      conditions,
      warningTitles: (warningsByKey && warningsByKey[key]) || [],
      href: sourceTimelinePath(source),
    });

    return badges;
  }, []);
};

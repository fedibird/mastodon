import { List as ImmutableList } from 'immutable';
import { changeColumnParams } from '../../actions/columns';
import { changeSetting } from '../../actions/settings';
import { uniqCompact } from '../../utils/uniq';

const { toHiragana } = require('@koozaki/romaji-conv');

const SHORTCODE_PATTERN = /^[A-Za-z0-9_]+$/;
const REMOTE_SHORTCODE_PATTERN = /^([A-Za-z0-9_]+)@([^@]+)$/;
const EMPTY_LIST = ImmutableList();

function read(item, key) {
  if (!item) {
    return undefined;
  }

  if (typeof item.get === 'function') {
    return item.get(key);
  }

  return item[key];
}

function blank(value) {
  return value === undefined || value === null;
}

function text(value) {
  return blank(value) ? '' : String(value);
}

export function emojiReactionFilterArray(value) {
  if (!value) {
    return [];
  }

  if (typeof value === 'string') {
    return [value];
  }

  if (typeof value.toArray === 'function') {
    return value.toArray();
  }

  if (Array.isArray(value)) {
    return value.slice();
  }

  return [];
}

export function emojiReactionFilterValue(item) {
  const name = text(read(item, 'name'));
  const domain = read(item, 'domain');
  const custom = Boolean(read(item, 'custom'));

  if (custom && domain) {
    return `${name}@${domain}`;
  }

  return name;
}

function labelFromFilterValue(value) {
  const raw = text(value);
  const remote = raw.match(REMOTE_SHORTCODE_PATTERN);

  if (remote) {
    return `:${remote[1]}:@${remote[2]}`;
  }

  if (SHORTCODE_PATTERN.test(raw)) {
    return `:${raw}:`;
  }

  return raw;
}

export function emojiReactionFilterLabel(itemOrValue) {
  if (blank(itemOrValue) || typeof itemOrValue === 'string') {
    return labelFromFilterValue(itemOrValue || '');
  }

  const name = text(read(itemOrValue, 'name'));
  const domain = read(itemOrValue, 'domain');
  const custom = Boolean(read(itemOrValue, 'custom'));

  if (!custom) {
    return name;
  }

  if (domain) {
    return `:${name}:@${domain}`;
  }

  return `:${name}:`;
}

function readingKeyword(item, name) {
  const ruby = text(read(item, 'ruby')).trim();

  if (ruby) {
    return ruby;
  }

  if (!read(item, 'custom') || !name) {
    return '';
  }

  return toHiragana(name);
}

function searchFields(item) {
  const name = text(read(item, 'name'));
  const domain = read(item, 'domain') ? String(read(item, 'domain')) : '';
  const aliases = emojiReactionFilterArray(read(item, 'aliases')).map(alias => text(alias).trim());

  return uniqCompact([
    name,
    readingKeyword(item, name),
    text(read(item, 'alternate_name')).trim(),
    ...aliases,
    domain,
    domain && name ? `${name}@${domain}` : '',
  ]);
}

export function emojiReactionSearchText(item) {
  return searchFields(item).join('\n').toLocaleLowerCase();
}

export function emojiReactionCatalogMatches(item, query) {
  const normalized = String(query || '').trim().toLocaleLowerCase();

  if (!normalized) {
    return true;
  }

  return searchFields(item).some(field => field.toLocaleLowerCase().includes(normalized));
}

export function filterEmojiReactionCatalog(items, query) {
  return emojiReactionFilterArray(items).filter(item => emojiReactionCatalogMatches(item, query));
}

export function findEmojiReactionCatalogItem(items, value) {
  return emojiReactionFilterArray(items).find(item => emojiReactionFilterValue(item) === value) || null;
}

export function sameEmojiFilters(left, right) {
  const a = emojiReactionFilterArray(left);
  const b = emojiReactionFilterArray(right);

  if (a.length !== b.length) {
    return false;
  }

  return a.every((value, index) => value === b[index]);
}

export function getAppliedEmojiReactionFilters(state, columnId) {
  if (columnId) {
    const columns = state.getIn(['settings', 'columns']);
    const column = columns && columns.find(item => item.get('uuid') === columnId);

    return column ? ImmutableList(emojiReactionFilterArray(column.getIn(['params', 'emojis']))) : EMPTY_LIST;
  }

  return ImmutableList(emojiReactionFilterArray(state.getIn(['settings', 'emoji_reactioned_statuses', 'emojis'])));
}

export function getEmojiReactionCatalogState(state) {
  const catalog = state.getIn(['emoji_reactioned_statuses', 'catalog']);

  return {
    catalogItems: catalog && catalog.get('items') ? catalog.get('items') : EMPTY_LIST,
    isLoading: catalog ? Boolean(catalog.get('isLoading')) : false,
    loaded: catalog ? Boolean(catalog.get('loaded')) : false,
    error: catalog ? catalog.get('error') : null,
  };
}

export function saveEmojiReactionFilters(columnId, emojis) {
  const value = ImmutableList(emojiReactionFilterArray(emojis));

  if (columnId) {
    return changeColumnParams(columnId, ['emojis'], value);
  }

  return changeSetting(['emoji_reactioned_statuses', 'emojis'], value);
}

export function normalizePreferredEmojiReactionFilters(value) {
  const seen = new Set();
  const next = [];

  emojiReactionFilterArray(value).forEach(item => {
    const raw = text(item).trim();

    if (!raw || seen.has(raw)) {
      return;
    }

    seen.add(raw);
    next.push(raw);
  });

  return next;
}

export function togglePreferredEmojiReactionFilter(preferred, value) {
  const list = normalizePreferredEmojiReactionFilters(preferred);
  const raw = text(value).trim();

  if (!raw) {
    return list;
  }

  const index = list.indexOf(raw);

  if (index === -1) {
    return list.concat(raw);
  }

  return list.slice(0, index).concat(list.slice(index + 1));
}

export function placePreferredEmojiReactionFilter(preferred, value, index) {
  const raw = text(value).trim();
  const list = normalizePreferredEmojiReactionFilters(preferred).filter(item => item !== raw);

  if (!raw) {
    return normalizePreferredEmojiReactionFilters(preferred);
  }

  const nextIndex = Math.max(0, Math.min(list.length, Number.isFinite(index) ? index : list.length));

  return list.slice(0, nextIndex).concat(raw, list.slice(nextIndex));
}

export function isPreferredEmojiReaction(preferred, value) {
  const raw = text(value).trim();

  if (!raw) {
    return false;
  }

  return normalizePreferredEmojiReactionFilters(preferred).indexOf(raw) !== -1;
}

export function getPreferredEmojiReactionFilters(state) {
  return ImmutableList(normalizePreferredEmojiReactionFilters(state.getIn(['settings', 'emoji_reactioned_statuses', 'preferred_emojis'])));
}

export function savePreferredEmojiReactionFilters(preferred) {
  return changeSetting(
    ['emoji_reactioned_statuses', 'preferred_emojis'],
    ImmutableList(normalizePreferredEmojiReactionFilters(preferred)),
  );
}

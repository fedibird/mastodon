import { List as ImmutableList } from 'immutable';
import { changeColumnParams } from '../../actions/columns';
import { changeSetting } from '../../actions/settings';
import { uniqCompact } from '../../utils/uniq';
import emojiMartData from '../emoji/emoji_mart_data_light';
import unicodeEmojiJapaneseReadings from '../emoji/emoji_unicode_ja_readings';
import unicodeMapping from '../emoji/emoji_unicode_mapping_light';

const { toHiragana } = require('@koozaki/romaji-conv');

const VARIATION_SELECTORS = /[\uFE0E\uFE0F]/g;
const FITZPATRICK_MODIFIERS = /\u{1F3FB}|\u{1F3FC}|\u{1F3FD}|\u{1F3FE}|\u{1F3FF}/gu;
const KATAKANA_LETTER = /[\u30A1-\u30FA\u30FD\u30FE]/;
const ENGLISH_EMOJI_QUERY_SEPARATOR = /[\s,_\-]+/;

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

function normalizeUnicodeEmojiSearchKey(value) {
  return text(value).replace(VARIATION_SELECTORS, '');
}

function unicodeEmojiSearchKeys(name) {
  const exact = text(name);

  if (!exact) {
    return [];
  }

  const normalized = normalizeUnicodeEmojiSearchKey(exact);
  const base = normalized.replace(FITZPATRICK_MODIFIERS, '');
  const keys = [exact];

  if (normalized !== exact) {
    keys.push(normalized);
  }

  if (base !== normalized) {
    keys.push(base);
  }

  return keys;
}

function unicodeEmojiReadingsForKey(key) {
  const readings = key ? unicodeEmojiJapaneseReadings[key] : null;

  return Array.isArray(readings) ? readings : [];
}

function lookupUnicodeEmojiJapaneseReadings(name) {
  const keys = unicodeEmojiSearchKeys(name);

  for (let index = 0; index < keys.length; index += 1) {
    const readings = unicodeEmojiReadingsForKey(normalizeUnicodeEmojiSearchKey(keys[index]));

    if (readings.length) {
      return readings;
    }
  }

  return [];
}

function shortCodeForNative(native) {
  const entry = native ? unicodeMapping[native] : null;

  return entry && entry.shortCode ? entry.shortCode : '';
}

function buildNormalizedShortCodes() {
  const shortCodes = new Map();
  const ambiguous = new Set();

  Object.keys(unicodeMapping).forEach((native) => {
    const shortCode = shortCodeForNative(native);

    if (!shortCode) {
      return;
    }

    const key = normalizeUnicodeEmojiSearchKey(native);

    if (ambiguous.has(key)) {
      return;
    }

    const existing = shortCodes.get(key);

    if (!existing) {
      shortCodes.set(key, shortCode);
      return;
    }

    if (existing !== shortCode) {
      shortCodes.delete(key);
      ambiguous.add(key);
    }
  });

  return { shortCodes, ambiguous };
}

const normalizedUnicodeShortCodes = buildNormalizedShortCodes();

function shortCodeForNormalizedKey(key) {
  if (!key || normalizedUnicodeShortCodes.ambiguous.has(key)) {
    return '';
  }

  return normalizedUnicodeShortCodes.shortCodes.get(key) || '';
}

function lookupUnicodeEmojiShortCode(name) {
  const keys = unicodeEmojiSearchKeys(name);

  for (let index = 0; index < keys.length; index += 1) {
    const key = keys[index];
    const exact = shortCodeForNative(key);

    if (exact) {
      return exact;
    }

    const normalized = shortCodeForNormalizedKey(normalizeUnicodeEmojiSearchKey(key));

    if (normalized) {
      return normalized;
    }
  }

  return '';
}

function aliasesByShortCode() {
  const aliasMap = emojiMartData.short_names;
  const byShortCode = new Map();

  if (!aliasMap || Array.isArray(aliasMap)) {
    return byShortCode;
  }

  Object.keys(aliasMap).forEach((alias) => {
    const shortCode = aliasMap[alias];

    if (!shortCode || !alias) {
      return;
    }

    const aliases = byShortCode.get(shortCode) || [];
    aliases.push(alias);
    byShortCode.set(shortCode, aliases);
  });

  return byShortCode;
}

const unicodeEmojiAliases = aliasesByShortCode();

function lookupUnicodeEmojiEnglishSearchData(name) {
  const shortCode = lookupUnicodeEmojiShortCode(name);
  const emoji = shortCode ? emojiMartData.emojis[shortCode] : null;

  if (!emoji) {
    return null;
  }

  const shortNames = [];
  const pushName = (value) => {
    const alias = text(value);

    if (alias && shortNames.indexOf(alias) === -1) {
      shortNames.push(alias);
    }
  };

  emojiReactionFilterArray(emoji.short_names).forEach(pushName);
  pushName(shortCode);
  emojiReactionFilterArray(unicodeEmojiAliases.get(shortCode)).forEach(pushName);

  return {
    shortNames,
    search: text(emoji.search),
  };
}

function englishSearchHaystack(data) {
  return `${data.shortNames.join('\n')}\n${data.search}`.toLocaleLowerCase();
}

function normalizeEnglishEmojiQuery(query) {
  return String(query || '').trim().toLocaleLowerCase().split(ENGLISH_EMOJI_QUERY_SEPARATOR).filter(Boolean);
}

function unicodeEmojiEnglishMatches(item, query) {
  if (read(item, 'custom')) {
    return false;
  }

  const data = lookupUnicodeEmojiEnglishSearchData(text(read(item, 'name')));

  if (!data) {
    return false;
  }

  const normalized = String(query || '').trim().toLocaleLowerCase();

  if (!normalized) {
    return false;
  }

  // Emoji Mart matches the thumbs-down shortcode before hyphen splitting.
  if (normalized === '-' || normalized === '-1') {
    return data.shortNames.some(name => name.toLocaleLowerCase() === '-1');
  }

  if (data.shortNames.some(name => name.toLocaleLowerCase() === normalized)) {
    return true;
  }

  const tokens = normalizeEnglishEmojiQuery(normalized);

  // One-character tokens match inside almost every keyword. Exact shortcodes
  // such as "a" and "x" are handled above; keyword search starts at 2.
  if (!tokens.length || tokens.some(token => token.length < 2)) {
    return false;
  }

  const haystack = englishSearchHaystack(data);

  return tokens.every(token => haystack.includes(token));
}

function unicodeEmojiReadingKeywords(item, name) {
  if (read(item, 'custom') || !name) {
    return [];
  }

  return lookupUnicodeEmojiJapaneseReadings(name);
}

function searchFields(item) {
  const name = text(read(item, 'name'));
  const domain = read(item, 'domain') ? String(read(item, 'domain')) : '';
  const aliases = emojiReactionFilterArray(read(item, 'aliases')).map(alias => text(alias).trim());

  return uniqCompact([
    name,
    readingKeyword(item, name),
    ...unicodeEmojiReadingKeywords(item, name),
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

  const fields = searchFields(item);

  if (fields.some(field => field.toLocaleLowerCase().includes(normalized))) {
    return true;
  }

  if (unicodeEmojiEnglishMatches(item, normalized)) {
    return true;
  }

  if (!KATAKANA_LETTER.test(normalized)) {
    return false;
  }

  const hiragana = toHiragana(normalized);

  if (!hiragana || hiragana === normalized) {
    return false;
  }

  return unicodeEmojiReadingKeywords(item, text(read(item, 'name'))).some(field => field.toLocaleLowerCase().includes(hiragana));
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

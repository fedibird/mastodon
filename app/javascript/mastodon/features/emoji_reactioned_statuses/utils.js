import { List as ImmutableList } from 'immutable';
import { changeColumnParams } from '../../actions/columns';
import { changeSetting } from '../../actions/settings';

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

function searchFields(item) {
  const name = text(read(item, 'name'));
  const domain = read(item, 'domain') ? String(read(item, 'domain')) : '';
  const fields = [name];

  if (domain) {
    fields.push(domain, `${name}@${domain}`);
  }

  const alternateName = read(item, 'alternate_name');
  if (alternateName) {
    fields.push(String(alternateName));
  }

  const ruby = read(item, 'ruby');
  if (ruby) {
    fields.push(String(ruby));
  }

  emojiReactionFilterArray(read(item, 'aliases')).forEach(alias => {
    if (alias) {
      fields.push(String(alias));
    }
  });

  return fields;
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

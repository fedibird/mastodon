import { isDecimalStatusId } from '../timeline_navigation';
import { capabilityFor } from '../timeline_seek/capability';
import { SEEK_KIND, SEEK_PREFERENCE } from '../timeline_seek/constants';
import { createSeekQuery, seekTargetPayload } from '../timeline_seek/query';

// P4a jumps by date, account, or status id. Text search is a visible mode
// and never becomes a seek target: the seek API rejects raw text, and the
// existing full-text index is not a timeline membership search.

export const JUMP_MODE = Object.freeze({
  DATE: 'date',
  ACCOUNT: 'account',
  STATUS: 'status',
  TEXT: 'text',
});

const SECRET_KEYS = ['q', 'query', 'text', 'raw', 'body'];
const LOCAL_DATE_TIME = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2}))?$/;
const DATE_ONLY = /^\d{4}-\d{2}-\d{2}$/;
const MAX_BIGINT = '9223372036854775807';
const PREFERENCES = [SEEK_PREFERENCE.NEAREST, SEEK_PREFERENCE.BEFORE, SEEK_PREFERENCE.AFTER];

const defaultCreateDate = (year, monthIndex, day, hour, minute, second) => (
  new Date(year, monthIndex, day, hour, minute, second, 0)
);

const pad = (value) => String(value).padStart(2, '0');

export const localTimeZoneName = () => {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || 'local';
  } catch (error) {
    return 'local';
  }
};

export const formatUtcOffset = (date) => {
  const offsetMin = -date.getTimezoneOffset();
  const sign = offsetMin >= 0 ? '+' : '-';
  const abs = Math.abs(offsetMin);

  return `UTC${sign}${pad(Math.floor(abs / 60))}:${pad(abs % 60)}`;
};

// datetime-local is the reader's wall clock. A date with no time is rejected
// so it cannot be sent as P2's UTC day start. A spring-forward gap fails the
// round trip and is not coerced.
export const interpretLocalDateTime = (value, createDate = defaultCreateDate) => {
  if (typeof value !== 'string' || value.length === 0) {
    return { ok: false, reason: 'missing_time' };
  }

  if (DATE_ONLY.test(value)) {
    return { ok: false, reason: 'date_only_rejected' };
  }

  const match = LOCAL_DATE_TIME.exec(value);

  if (!match) {
    return { ok: false, reason: 'invalid_time' };
  }

  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const hour = Number(match[4]);
  const minute = Number(match[5]);
  const second = Number(match[6] || '0');
  const date = createDate(year, month - 1, day, hour, minute, second);

  if (!(date instanceof Date) || Number.isNaN(date.getTime())) {
    return { ok: false, reason: 'invalid_time' };
  }

  if (
    date.getFullYear() !== year
    || date.getMonth() !== month - 1
    || date.getDate() !== day
    || date.getHours() !== hour
    || date.getMinutes() !== minute
    || date.getSeconds() !== second
  ) {
    return { ok: false, reason: 'nonexistent_local_time' };
  }

  const offsetMin = -date.getTimezoneOffset();
  const sign = offsetMin >= 0 ? '+' : '-';
  const abs = Math.abs(offsetMin);
  const at = `${match[1]}-${match[2]}-${match[3]}T${match[4]}:${match[5]}:${pad(second)}${sign}${pad(Math.floor(abs / 60))}:${pad(abs % 60)}`;

  return {
    ok: true,
    at,
    offset: formatUtcOffset(date),
    timeZone: localTimeZoneName(),
  };
};

export const normalizeDecimalId = (value) => {
  const text = typeof value === 'string' ? value.trim() : '';

  if (!isDecimalStatusId(text) || text.length > 19 || (text.length === 19 && text > MAX_BIGINT)) {
    return { ok: false, reason: 'invalid_id' };
  }

  return { ok: true, id: text };
};

export const jumpModeState = (source, mode) => {
  if (mode === JUMP_MODE.TEXT) {
    return {
      level: 'unsupported',
      reason: 'text_search_not_in_timeline',
      canSubmit: false,
    };
  }

  const kind = mode === JUMP_MODE.STATUS ? SEEK_KIND.STATUS : mode;
  const entry = capabilityFor(source, kind);

  return {
    level: entry.level,
    reason: entry.reason,
    canSubmit: entry.level === 'supported' || entry.level === 'approximate',
  };
};

const preferenceOf = (value) => (
  PREFERENCES.indexOf(value) === -1 ? SEEK_PREFERENCE.NEAREST : value
);

export const buildJumpQuery = (input = {}) => {
  if (SECRET_KEYS.some(key => Object.prototype.hasOwnProperty.call(input, key))) {
    return { ok: false, reason: 'search_text_not_accepted' };
  }

  const mode = input.mode;

  if (mode === JUMP_MODE.TEXT) {
    return { ok: false, reason: 'text_search_not_in_timeline' };
  }

  let kind = null;
  let target = null;
  let preference = SEEK_PREFERENCE.NEAREST;

  if (mode === JUMP_MODE.DATE) {
    const parsed = interpretLocalDateTime(input.at, input.createDate);

    if (!parsed.ok) {
      return parsed;
    }

    kind = SEEK_KIND.DATE;
    preference = preferenceOf(input.preference);
    target = { at: parsed.at };
  } else if (mode === JUMP_MODE.ACCOUNT) {
    const parsed = normalizeDecimalId(input.accountId);

    if (!parsed.ok) {
      return { ok: false, reason: input.accountId ? 'invalid_id' : 'account_required' };
    }

    kind = SEEK_KIND.ACCOUNT;
    target = { accountId: parsed.id };
  } else if (mode === JUMP_MODE.STATUS) {
    const parsed = normalizeDecimalId(input.statusId);

    if (!parsed.ok) {
      return parsed;
    }

    kind = SEEK_KIND.STATUS;
    target = { id: parsed.id };
  } else {
    return { ok: false, reason: 'unknown_kind' };
  }

  const query = createSeekQuery({ kind, preference, target });
  const payload = seekTargetPayload(query.target);

  if (query.target.rejected || SECRET_KEYS.some(key => Object.prototype.hasOwnProperty.call(payload, key))) {
    return { ok: false, reason: 'search_text_not_accepted' };
  }

  return { ok: true, query, payload };
};

// loaded confirms the row. filtered and not_loaded put the previous history
// window back. A reader scroll cancels the correction and keeps the window.
export const jumpScrollDisposition = ({ scrollStatus, reason } = {}) => {
  const code = scrollStatus || reason;

  if (code === 'loaded') {
    return 'moved';
  }

  if (code === 'filtered' || code === 'not_loaded') {
    return 'restore';
  }

  if (code === 'user_scroll') {
    return 'cancelled_scroll';
  }

  return 'explain';
};

// Closing the form abandons an unconfirmed scroll. A loaded jump and a
// reader scroll stay where they are.
export const jumpAbandonDisposition = ({ phase, scrollStatus, userCancelled } = {}) => {
  if (phase !== 'scroll' || userCancelled) {
    return 'leave';
  }

  if (scrollStatus === 'loaded' || scrollStatus === 'user_scroll') {
    return 'leave';
  }

  return 'restore_once';
};

import { isDecimalStatusId } from '../timeline_navigation';

// Shared boost / quote / reference anchor selection.
// Status ids stay strings. A missing boost wrapper is never replaced with the
// original status id.

const HOST_BODY = /^[0-9A-Za-z:_-]{1,180}$/;

const unavailable = (kind, reason) => ({
  available: false,
  reason,
  kind,
  accountId: null,
  statusId: null,
  reply: false,
  reblog: false,
});

const ready = (fields) => ({
  available: true,
  reason: 'ready',
  reply: false,
  reblog: false,
  ...fields,
});

const read = (record, key) => {
  if (!record || (typeof record !== 'object' && typeof record !== 'function')) {
    return undefined;
  }

  if (typeof record.get === 'function') {
    const value = record.get(key);

    if (value !== undefined) {
      return value;
    }
  }

  return record[key];
};

const asList = (value) => {
  if (!value) {
    return [];
  }

  if (typeof value.toArray === 'function') {
    return value.toArray();
  }

  if (Array.isArray(value)) {
    return value;
  }

  return [];
};

const decimalId = (value) => (
  isDecimalStatusId(value) ? value : null
);

const idOf = (record) => decimalId(read(record, 'id'));

const accountIdOf = (record) => {
  const account = read(record, 'account');

  if (isDecimalStatusId(account)) {
    return account;
  }

  return idOf(account);
};

const reblogRecord = (status) => {
  const reblog = read(status, 'reblog');

  if (reblog && typeof reblog === 'object') {
    return reblog;
  }

  return null;
};

const reblogIdOf = (status) => {
  const reblog = reblogRecord(status);

  if (reblog) {
    return idOf(reblog);
  }

  return decimalId(read(status, 'reblog')) || decimalId(read(status, 'reblog_of_id'));
};

const isReply = (status) => decimalId(read(status, 'in_reply_to_id')) !== null;

const quoteIdOf = (status) => {
  const quote = read(status, 'quote');

  if (quote && typeof quote === 'object') {
    return idOf(quote);
  }

  return decimalId(read(status, 'quote_id'));
};

// References that are not the quote embedded on the same post.
const ownReferenceIds = (status) => {
  const quoteId = quoteIdOf(status);

  return asList(read(status, 'status_reference_ids')).map(decimalId).filter(id => id && id !== quoteId);
};

const hasOwnReference = (status) => {
  if (ownReferenceIds(status).length > 0) {
    return true;
  }

  const count = read(status, 'status_references_count');
  const total = typeof count === 'number' && Number.isFinite(count) ? count : 0;

  if (total <= 0) {
    return false;
  }

  // The reference counter includes the quote. Without the id list, one
  // reference on a quote is the quote itself.
  return quoteIdOf(status) ? total > 1 : true;
};

// The status that performed the quote or reference. A boost row stores that
// post on `reblog`; the wrapper id belongs to the booster, not the quoter.
const actionStatus = (status) => reblogRecord(status) || status;

const quoteTarget = (status) => {
  const actor = actionStatus(status);
  const statusId = idOf(actor);
  const accountId = accountIdOf(actor);
  const quotedId = quoteIdOf(actor);

  if (!statusId || !accountId) {
    return unavailable('quote', 'invalid');
  }

  if (!quotedId) {
    return unavailable('quote', 'not_a_quote');
  }

  if (quotedId === statusId) {
    return unavailable('quote', 'quote_target');
  }

  return ready({
    kind: 'quote',
    accountId,
    statusId,
    reply: isReply(actor),
    reblog: false,
  });
};

const referenceTarget = (status) => {
  const actor = actionStatus(status);
  const statusId = idOf(actor);
  const accountId = accountIdOf(actor);

  if (!statusId || !accountId) {
    return unavailable('reference', 'invalid');
  }

  if (!hasOwnReference(actor)) {
    return unavailable('reference', 'not_a_reference');
  }

  return ready({
    kind: 'reference',
    accountId,
    statusId,
    reply: isReply(actor),
    reblog: false,
  });
};

const boostTarget = (status) => {
  const statusId = idOf(status);
  const accountId = accountIdOf(status);
  const boostedId = reblogIdOf(status);

  if (!statusId || !accountId || !boostedId || statusId === boostedId) {
    return unavailable('boost', 'not_a_wrapper');
  }

  return ready({
    kind: 'boost',
    accountId,
    statusId,
    reply: false,
    reblog: true,
  });
};

export function accountContextTarget({ kind, status } = {}) {
  if (kind === 'boost') {
    return boostTarget(status);
  }

  if (kind === 'quote') {
    return quoteTarget(status);
  }

  if (kind === 'reference') {
    return referenceTarget(status);
  }

  return unavailable(kind || 'unknown', 'invalid');
}

// Booster lists know the account and the original status, not the wrapper.
// `originalStatusId` is only a guard: it is never copied into statusId.
export function reblogWrapperTarget({ accountId, resolution, originalStatusId } = {}) {
  const boosterId = decimalId(accountId);
  const originalId = decimalId(originalStatusId);

  if (!boosterId) {
    return unavailable('boost', 'unknown');
  }

  const state = resolution && resolution.state;
  const reason = resolution && resolution.reason;

  if (state === 'absent') {
    return unavailable('boost', 'absent');
  }

  if (state === 'unavailable') {
    return unavailable('boost', 'unavailable');
  }

  if (state !== 'resolved') {
    return unavailable('boost', reason === 'ambiguous' ? 'ambiguous' : 'unknown');
  }

  const wrapperId = decimalId(resolution.id);

  if (!wrapperId || (originalId && wrapperId === originalId)) {
    return unavailable('boost', 'unknown');
  }

  if (resolution.account_id && decimalId(resolution.account_id) && decimalId(resolution.account_id) !== boosterId) {
    return unavailable('boost', 'unknown');
  }

  return ready({
    kind: 'boost',
    accountId: boosterId,
    statusId: wrapperId,
    reply: false,
    reblog: true,
  });
}

// Column, scroll, and split timeline ids. `:split:` is kept so two history
// panes do not share a host. The profile timeline id is not a host.
export function accountContextSurfaceKey(value) {
  if (typeof value !== 'string') {
    return null;
  }

  const trimmed = value.trim();

  if (!trimmed || trimmed.indexOf('account:') === 0) {
    return null;
  }

  if (HOST_BODY.test(trimmed)) {
    return trimmed;
  }

  const cleaned = trimmed.replace(/[^0-9A-Za-z:_-]/g, '_').slice(0, 180);

  return HOST_BODY.test(cleaned) ? cleaned : null;
}

// @ts-check

import compareId from '../compare_id';

/**
 * The share state of an external projection (E4) is the pair
 * (`reblogged`, `fedibird_external.link_boost_revision`). The server makes both
 * values from one row, and the revision only grows. Revisions are decimal
 * strings and are compared as strings, never as JavaScript numbers.
 */

const REVISION = /^(?:0|[1-9]\d*)$/;
const DECIMAL_ID = /^[1-9]\d*$/;

export const FLOOR_LIMIT = 256;

/**
 * @param {any} value
 * @return {boolean}
 */
export const isRevision = value => typeof value === 'string' && REVISION.test(value);

/**
 * @param {any} value
 * @return {boolean}
 */
export const isStatusId = value => typeof value === 'string' && DECIMAL_ID.test(value);

/**
 * @param {any} status plain status payload
 * @return {string|null}
 */
export const revisionOfPlain = status => {
  const value = status && status.fedibird_external && status.fedibird_external.link_boost_revision;

  return isRevision(value) ? value : null;
};

/**
 * @param {any} status Immutable status
 * @return {string|null}
 */
export const revisionOfImmutable = status => {
  const value = status && typeof status.getIn === 'function' ? status.getIn(['fedibird_external', 'link_boost_revision']) : undefined;

  return isRevision(value) ? value : null;
};

/**
 * A payload with no revision, a held status with no revision, and a status
 * that is not held are all outside this rule: the ordinary import applies.
 * An older revision never replaces a newer one, and while an optimistic
 * click is outstanding an equal revision does not take the click back.
 *
 * @param {any} existing Immutable status or undefined
 * @param {any} incoming plain status payload
 * @return {any} payload to import
 */
export const protectBoostState = (existing, incoming) => {
  const incomingRevision = revisionOfPlain(incoming);

  if (!existing || incomingRevision === null) {
    return incoming;
  }

  const currentRevision = revisionOfImmutable(existing);

  if (currentRevision === null) {
    return incoming;
  }

  const order = compareId(incomingRevision, currentRevision);
  const optimistic = existing.get('link_boost_optimistic');

  if (order > 0 || (order === 0 && optimistic === undefined)) {
    return incoming;
  }

  const kept = {
    ...incoming,
    reblogged: existing.get('reblogged'),
    fedibird_external: { ...incoming.fedibird_external, link_boost_revision: currentRevision },
  };

  if (optimistic !== undefined) {
    kept.link_boost_optimistic = optimistic;
  }

  return kept;
};

/**
 * The newest pair a stream event reported for an id, applied to a payload
 * whose revision is older. This covers a status that is not held yet, for
 * example a first page request that was already in flight.
 *
 * @param {{ revision: string, reblogged: boolean }|undefined} floor
 * @param {any} incoming plain status payload
 * @return {any}
 */
export const applyBoostFloor = (floor, incoming) => {
  const incomingRevision = revisionOfPlain(incoming);

  if (!floor || incomingRevision === null || compareId(floor.revision, incomingRevision) <= 0) {
    return incoming;
  }

  return {
    ...incoming,
    reblogged: floor.reblogged,
    fedibird_external: { ...incoming.fedibird_external, link_boost_revision: floor.revision },
  };
};

/**
 * @param {any} payload parsed stream payload
 * @return {{ statusId: string, reblogged: boolean, revision: string }|null}
 */
export const parseBoostEvent = payload => {
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    return null;
  }

  if (payload.version !== 1 && payload.version !== '1') {
    return null;
  }

  if (!isStatusId(payload.status_id) || typeof payload.reblogged !== 'boolean' || !isRevision(payload.revision)) {
    return null;
  }

  return { statusId: payload.status_id, reblogged: payload.reblogged, revision: payload.revision };
};

// @ts-check

const { stripStreamingSearchableText } = require('./filtering');

const DECIMAL_ID = /^[1-9]\d*$/;
const REVISION = /^(?:0|[1-9]\d*)$/;
const REASONS = new Set([
  'routes_updated',
  'source_deleted',
  'source_restored',
  'list_removed',
  'subscription_removed',
]);

/** @type {WeakMap<function(string): void, ExternalTicket>} */
const tickets = new WeakMap();

/**
 * @typedef ExternalTicket
 * @property {boolean} active
 * @property {string[]} channels
 * @property {Map<string, string>} revisions
 * @property {string} kind
 * @property {string|null} listId
 * @property {function(string): void|null} listener
 * @property {PrivateSlot[]} queue
 * @property {boolean} confirming
 * @property {ConfirmSignal|null} confirmSignal
 * @property {ReturnType<typeof setTimeout>|null} confirmTimer
 * @property {Map<string, string>} seenGenerations
 * @property {Set<string>} removedStatuses
 * @property {Map<string, { subscriptionId: string, routeId: string|null }>} pendingInserts
 * @property {Set<string>} insertedStatuses
 * @property {boolean} boundaryReleased
 * @property {function(string, any[], { signal?: ConfirmSignal, timeoutMs?: number }|undefined=): Promise<any>} query
 * @property {any} req
 * @property {{ kind: string, listId: string|null }} target
 * @property {function(string, string): void} output
 */

/**
 * @typedef PrivateSlot
 * @property {{ event: string, encoded: string, control?: any, delivery?: any }} prepared
 */

/**
 * @typedef ConfirmSignal
 * @property {boolean} aborted
 * @property {function(string, function(): void): void} addEventListener
 * @property {function(string, function(): void): void} removeEventListener
 * @property {function(): void} abort
 */

/**
 * @typedef ConfirmResult
 * @property {boolean} ok
 * @property {boolean} superseded
 * @property {boolean} dropIntent
 * @property {string|null} [routeId]
 */

const PRIVATE_PENDING_LIMIT = 64;
const PRIVATE_CONFIRM_MS = 5000;

/**
 * Generation and delete watermarks for one authenticated user on one
 * request. Tickets on that connection share the maps. A different request
 * or a different user does not. The maps live while at least one private
 * ticket for that user is attached; the last detach drops them.
 *
 * @type {WeakMap<object, Map<string, { seenGenerations: Map<string, string>, removedStatuses: Set<string>, refs: number }>>}
 */
const outputBoundaries = new WeakMap();

/**
 * One private confirmation per ticket. The next statement, and the next
 * message, wait until the query that already started has settled or the
 * driver has cancelled it.
 */

/**
 * @return {ConfirmSignal}
 */
const createSignal = () => {
  const listeners = new Set();

  return {
    aborted: false,
    addEventListener: (_type, listener) => {
      listeners.add(listener);
    },
    removeEventListener: (_type, listener) => {
      listeners.delete(listener);
    },
    abort() {
      if (this.aborted) {
        return;
      }

      this.aborted = true;
      Array.from(listeners).forEach(listener => listener());
    },
  };
};

/**
 * @return {Error}
 */
const abortError = () => Object.assign(new Error('external feed confirmation cancelled'), { code: 'EXTERNAL_FEED_CANCELLED' });

/**
 * @param {boolean} [dropIntent]
 * @return {ConfirmResult}
 */
const rejectedConfirm = (dropIntent = false) => ({ ok: false, superseded: false, dropIntent: dropIntent === true });

/**
 * @param {string|number} left
 * @param {string|number} right
 * @return {number}
 */
const compareDecimal = (left, right) => {
  const a = String(left).replace(/^0+/, '') || '0';
  const b = String(right).replace(/^0+/, '') || '0';

  if (a.length !== b.length) {
    return a.length < b.length ? -1 : 1;
  }

  if (a === b) {
    return 0;
  }

  return a < b ? -1 : 1;
};

/**
 * @param {any} value
 * @return {string}
 */
const yamlScalar = value => {
  if (value === null || value === undefined) {
    return '';
  }

  let text = String(value).replace(/^\uFEFF?---[ \t]*\n?/, '').trim();

  if ((text.startsWith('"') && text.endsWith('"')) || (text.startsWith('\'') && text.endsWith('\''))) {
    text = text.slice(1, -1);
  }

  return text;
};

/**
 * @param {any} value
 * @return {boolean}
 */
const flagEnabled = value => yamlScalar(value) === 'true';

/**
 * @param {any} value
 * @param {string} userId
 * @return {boolean}
 */
const testerListed = (value, userId) => {
  const id = String(userId);

  if (!DECIMAL_ID.test(id)) {
    return false;
  }

  return yamlScalar(value).split(/[,\s]+/).filter(Boolean).includes(id);
};

/**
 * @param {string} userId
 * @param {string} kind
 * @param {string|null} listId
 * @return {string[]}
 */
const channelNames = (userId, kind, listId) => {
  const user = String(userId);

  if (!DECIMAL_ID.test(user)) {
    return [];
  }

  const control = `timeline:external:user:${user}:control`;

  if (kind === 'user') {
    return [`timeline:external:user:${user}:home`, control];
  }

  if (kind === 'list' && DECIMAL_ID.test(String(listId))) {
    return [`timeline:external:user:${user}:list:${String(listId)}`, control];
  }

  return [];
};

/**
 * @param {any} row
 * @param {any} req
 * @return {boolean}
 */
const accountRowAllowed = (row, req) => {
  if (!row || String(row.user_id) !== String(req.userId) || String(row.user_account_id) !== String(req.accountId)) {
    return false;
  }

  if (row.revoked_at) {
    return false;
  }

  if (row.expires_in !== null && row.expires_in !== undefined) {
    const expiresAt = new Date(row.created_at).getTime() + (Number(row.expires_in) * 1000);

    if (Date.now() > expiresAt) {
      return false;
    }
  }

  if (!row.confirmed_at || row.approved !== true || row.disabled === true) {
    return false;
  }

  if (row.suspended_at || row.memorial === true || row.moved_to_account_id) {
    return false;
  }

  return flagEnabled(row.feeds_enabled) && testerListed(row.feeds_testers, row.user_id);
};

const ACCOUNT_SQL = `
  SELECT oauth_access_tokens.revoked_at,
         oauth_access_tokens.expires_in,
         oauth_access_tokens.created_at,
         oauth_access_tokens.resource_owner_id::text AS user_id,
         users.confirmed_at,
         users.approved,
         users.disabled,
         users.account_id::text AS user_account_id,
         accounts.suspended_at,
         accounts.memorial,
         accounts.moved_to_account_id,
         (SELECT value FROM settings WHERE var = 'external_bridge_feeds' AND thing_type IS NULL AND thing_id IS NULL ORDER BY id DESC LIMIT 1) AS feeds_enabled,
         (SELECT value FROM settings WHERE var = 'external_bridge_feeds_testers' AND thing_type IS NULL AND thing_id IS NULL ORDER BY id DESC LIMIT 1) AS feeds_testers
    FROM oauth_access_tokens
    INNER JOIN users ON users.id = oauth_access_tokens.resource_owner_id
    INNER JOIN accounts ON accounts.id = users.account_id
   WHERE oauth_access_tokens.id = $1
     AND users.id::text = $2
     AND users.account_id::text = $3
   LIMIT 1
`;

/**
 * @param {function(string, any[]): Promise<any>} query
 * @param {any} req
 * @param {{ kind: string, listId: string|null }} target
 * @param {{ allowMissingList?: boolean }} [options]
 * @return {Promise<boolean>}
 */
const authorizeExternalDelivery = (query, req, target, options = {}) => {
  if (!req || !req.accessTokenId || !req.userId || !req.accountId || !target) {
    return Promise.resolve(false);
  }

  return query(ACCOUNT_SQL, [String(req.accessTokenId), String(req.userId), String(req.accountId)]).then(result => {
    if (!result || !Array.isArray(result.rows) || result.rows.length !== 1 || !accountRowAllowed(result.rows[0], req)) {
      return false;
    }

    if (target.kind === 'user') {
      return true;
    }

    if (target.kind !== 'list' || !DECIMAL_ID.test(String(target.listId))) {
      return false;
    }

    // list_removed is the one event a list socket may receive after the row
    // is gone. Content and every other reason still require the list.
    if (options.allowMissingList === true) {
      return true;
    }

    return query('SELECT 1 FROM lists WHERE id = $1::bigint AND account_id = $2::bigint LIMIT 1', [String(target.listId), String(req.accountId)]).then(listResult => {
      return !!(listResult && Array.isArray(listResult.rows) && listResult.rows.length === 1);
    });
  }).catch(() => false);
};

const ROUTE_INTENT_SQL = `
  SELECT markers.status_id::text AS status_id,
         (
           SELECT routes.id::text
             FROM external_feed_routes routes
            WHERE routes.user_id = markers.user_id
              AND routes.external_subscription_id = markers.external_subscription_id
              AND (
                ($4::text = 'home' AND routes.destination = 'home' AND routes.list_id IS NULL)
                OR ($4::text = 'list' AND routes.destination = 'list' AND routes.list_id = $5::bigint)
              )
            ORDER BY routes.id DESC
            LIMIT 1
         ) AS route_id
    FROM external_status_projections markers
   WHERE markers.user_id = $1::bigint
     AND markers.external_subscription_id = $2::bigint
     AND markers.status_id = ANY($3::bigint[])
     AND markers.source_deleted = FALSE
     AND EXISTS (
       SELECT 1 FROM external_feed_routes routes
        WHERE routes.user_id = markers.user_id
          AND routes.external_subscription_id = markers.external_subscription_id
          AND (
            ($4::text = 'home' AND routes.destination = 'home' AND routes.list_id IS NULL)
            OR ($4::text = 'list' AND routes.destination = 'list' AND routes.list_id = $5::bigint)
          )
     )
`;

const CONTENT_SQL = `
  SELECT markers.content_generation::text AS content_generation,
         (
           SELECT routes.id::text
             FROM external_feed_routes routes
            WHERE routes.user_id = markers.user_id
              AND routes.external_subscription_id = markers.external_subscription_id
              AND (
                ($4::text = 'home' AND routes.destination = 'home' AND routes.list_id IS NULL)
                OR ($4::text = 'list' AND routes.destination = 'list' AND routes.list_id = $5::bigint)
              )
            ORDER BY routes.id DESC
            LIMIT 1
         ) AS route_id,
         EXISTS (
           SELECT 1 FROM external_feed_routes routes
           WHERE routes.user_id = markers.user_id
             AND routes.external_subscription_id = markers.external_subscription_id
             AND (
               ($4::text = 'home' AND routes.destination = 'home' AND routes.list_id IS NULL)
               OR ($4::text = 'list' AND routes.destination = 'list' AND routes.list_id = $5::bigint)
             )
         ) AS routed
    FROM external_status_projections markers
    INNER JOIN statuses
      ON statuses.id = markers.status_id
     AND statuses.deleted_at IS NULL
     AND statuses.expired_at IS NULL
     AND statuses.external_projection IS TRUE
     AND statuses.visibility = 201
   WHERE markers.id = $1::bigint
     AND markers.user_id = $2::bigint
     AND markers.status_id = $3::bigint
     AND markers.external_subscription_id = $6::bigint
     AND markers.source_deleted = FALSE
   LIMIT 1
`;

const DELETE_SQL = `
  SELECT EXISTS (SELECT 1 FROM statuses WHERE id = $1::bigint) AS status_present,
         EXISTS (
           SELECT 1 FROM external_status_projections
           WHERE status_id = $1::bigint AND user_id = $2::bigint
         ) AS marker_present
`;

/**
 * @param {any} value
 * @param {string} event
 * @param {string} statusId
 * @return {any|null}
 */
const cleanDelivery = (value, event, statusId) => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return null;
  }

  if (typeof value.user_id !== 'string' || !DECIMAL_ID.test(value.user_id)) {
    return null;
  }

  if (typeof value.status_id !== 'string' || !DECIMAL_ID.test(value.status_id) || value.status_id !== statusId) {
    return null;
  }

  if (event === 'delete') {
    if (value.kind !== 'delete') {
      return null;
    }

    return { kind: 'delete', user_id: value.user_id, status_id: value.status_id };
  }

  if (value.kind !== 'content') {
    return null;
  }

  if (typeof value.projection_id !== 'string' || !DECIMAL_ID.test(value.projection_id)) {
    return null;
  }

  if (typeof value.subscription_id !== 'string' || !DECIMAL_ID.test(value.subscription_id)) {
    return null;
  }

  if (typeof value.generation !== 'string' || !DECIMAL_ID.test(value.generation)) {
    return null;
  }

  if (value.route_id !== undefined && value.route_id !== null) {
    if (typeof value.route_id !== 'string' || !DECIMAL_ID.test(value.route_id)) {
      return null;
    }
  }

  const delivery = {
    kind: 'content',
    user_id: value.user_id,
    status_id: value.status_id,
    projection_id: value.projection_id,
    subscription_id: value.subscription_id,
    generation: value.generation,
  };

  if (typeof value.route_id === 'string') {
    delivery.route_id = value.route_id;
  }

  return delivery;
};

/**
 * @param {any} value
 * @return {string|null}
 */
const routeIdOf = value => (typeof value === 'string' && DECIMAL_ID.test(value) ? value : null);

/**
 * @param {function(string, any[], any=): Promise<any>} query
 * @param {any} req
 * @param {{ kind: string, listId: string|null }} target
 * @param {any} delivery
 * @param {ConfirmSignal|null} signal
 * @return {Promise<ConfirmResult>}
 */
const contentStillCurrent = (query, req, target, delivery, signal) => {
  if (signal && signal.aborted) {
    return Promise.resolve(rejectedConfirm());
  }

  if (!delivery || delivery.user_id !== String(req.userId)) {
    return Promise.resolve(rejectedConfirm(true));
  }

  const destination = target.kind === 'list' ? 'list' : 'home';
  const listId = destination === 'list' ? String(target.listId) : null;

  return query(CONTENT_SQL, [
    delivery.projection_id,
    String(req.userId),
    delivery.status_id,
    destination,
    listId,
    delivery.subscription_id,
  ]).then(result => {
    if (signal && signal.aborted) {
      return rejectedConfirm();
    }

    if (!result || !Array.isArray(result.rows) || result.rows.length !== 1) {
      return rejectedConfirm(true);
    }

    const row = result.rows[0];

    if (typeof row.content_generation !== 'string') {
      return rejectedConfirm(true);
    }

    const compared = compareDecimal(row.content_generation, delivery.generation);
    const currentRoute = routeIdOf(row.route_id);
    const deliveredRoute = routeIdOf(delivery.route_id);
    const routed = row.routed === true || currentRoute !== null;
    // A recreated route row has a new id. The old insert does not continue.
    const lifetimeEnded = !!(currentRoute && deliveredRoute && currentRoute !== deliveredRoute);

    if (routed && compared === 0) {
      return { ok: true, superseded: false, dropIntent: lifetimeEnded, routeId: currentRoute };
    }

    // The insert was overtaken by a newer generation that is still on the
    // same route row. Keep the unforwarded insert for that next generation.
    if (routed && compared > 0) {
      return { ok: false, superseded: true, dropIntent: lifetimeEnded, routeId: currentRoute };
    }

    return rejectedConfirm(true);
  }).catch(() => rejectedConfirm());
};

/**
 * @param {function(string, any[], any=): Promise<any>} query
 * @param {any} req
 * @param {any} delivery
 * @param {ConfirmSignal|null} signal
 * @return {Promise<ConfirmResult>}
 */
const deleteStillCurrent = (query, req, delivery, signal) => {
  if (signal && signal.aborted) {
    return Promise.resolve(rejectedConfirm());
  }

  if (!delivery || delivery.user_id !== String(req.userId)) {
    return Promise.resolve(rejectedConfirm());
  }

  return query(DELETE_SQL, [delivery.status_id, String(req.userId)]).then(result => {
    if (signal && signal.aborted) {
      return rejectedConfirm();
    }

    const row = result && Array.isArray(result.rows) ? result.rows[0] : null;

    if (!row) {
      return rejectedConfirm();
    }

    if (row.status_present !== true && row.marker_present !== true) {
      return { ok: true, superseded: false, dropIntent: true };
    }

    return rejectedConfirm();
  }).catch(() => rejectedConfirm());
};

/**
 * @param {function(string, any[], any=): Promise<any>} query
 * @param {any} req
 * @param {{ kind: string, listId: string|null }} target
 * @param {{ event: string, control?: any, delivery?: any }} prepared
 * @param {ConfirmSignal|null} [signal]
 * @return {Promise<ConfirmResult>}
 */
const confirmPrivateEvent = (query, req, target, prepared, signal = null) => {
  if (signal && signal.aborted) {
    return Promise.resolve(rejectedConfirm());
  }

  const allowMissingList = !!(prepared.control && prepared.control.reason === 'list_removed' && target.kind === 'list');

  return authorizeExternalDelivery(query, req, target, { allowMissingList: allowMissingList }).then(allowed => {
    if (signal && signal.aborted) {
      return rejectedConfirm();
    }

    if (!allowed) {
      return rejectedConfirm();
    }

    if (prepared.event === 'update' || prepared.event === 'status.update') {
      return contentStillCurrent(query, req, target, prepared.delivery, signal);
    }

    if (prepared.event === 'delete') {
      return deleteStillCurrent(query, req, prepared.delivery, signal);
    }

    return { ok: true, superseded: false, dropIntent: false };
  }).catch(() => rejectedConfirm());
};

/**
 * @param {ExternalTicket} ticket
 * @param {{ event: string, delivery?: any }} prepared
 * @return {boolean}
 */
const generationAllowed = (ticket, prepared) => {
  if (!prepared.delivery || !prepared.delivery.status_id) {
    return true;
  }

  const statusId = prepared.delivery.status_id;

  if (ticket.removedStatuses.has(statusId) && prepared.event !== 'delete') {
    return false;
  }

  if (prepared.event !== 'update' && prepared.event !== 'status.update') {
    return true;
  }

  const seen = ticket.seenGenerations.get(statusId);

  if (seen === undefined) {
    return true;
  }

  return compareDecimal(seen, prepared.delivery.generation) <= 0;
};

/**
 * @param {ExternalTicket} ticket
 * @param {{ event: string, delivery?: any }} prepared
 */
const rememberDelivery = (ticket, prepared) => {
  if (!prepared.delivery || !prepared.delivery.status_id) {
    return;
  }

  const statusId = prepared.delivery.status_id;

  if (prepared.event === 'delete') {
    ticket.removedStatuses.add(statusId);

    return;
  }

  if (prepared.event !== 'update' && prepared.event !== 'status.update') {
    return;
  }

  const seen = ticket.seenGenerations.get(statusId);

  if (seen === undefined || compareDecimal(prepared.delivery.generation, seen) > 0) {
    ticket.seenGenerations.set(statusId, prepared.delivery.generation);
  }
};

/**
 * Generations and deletes already written for this user on this request.
 * The entry lives until the last private ticket for that user detaches.
 *
 * @param {any} req
 * @return {{ seenGenerations: Map<string, string>, removedStatuses: Set<string>, refs: number }}
 */
const retainBoundary = (req) => {
  let users = outputBoundaries.get(req);

  if (!users) {
    users = new Map();
    outputBoundaries.set(req, users);
  }

  const key = String(req.userId);
  let boundary = users.get(key);

  if (!boundary) {
    boundary = { seenGenerations: new Map(), removedStatuses: new Set(), refs: 0 };
    users.set(key, boundary);
  }

  boundary.refs += 1;

  return boundary;
};

const releaseBoundary = (req) => {
  const users = req ? outputBoundaries.get(req) : null;

  if (!users) {
    return;
  }

  const key = String(req.userId);
  const boundary = users.get(key);

  if (!boundary) {
    return;
  }

  boundary.refs -= 1;

  if (boundary.refs > 0) {
    return;
  }

  users.delete(key);

  if (users.size === 0) {
    outputBoundaries.delete(req);
  }
};

const noteInsertIntent = (ticket, prepared) => {
  if (prepared.event !== 'update' || !prepared.delivery || !prepared.delivery.status_id) {
    return;
  }

  if (typeof prepared.delivery.subscription_id !== 'string') {
    return;
  }

  const statusId = prepared.delivery.status_id;

  if (ticket.insertedStatuses.has(statusId) || ticket.removedStatuses.has(statusId)) {
    return;
  }

  ticket.pendingInserts.set(statusId, {
    subscriptionId: prepared.delivery.subscription_id,
    routeId: routeIdOf(prepared.delivery.route_id),
  });
};

/**
 * @param {ExternalTicket} ticket
 * @param {{ event: string, delivery?: any }} prepared
 * @param {ConfirmResult} result
 */
const noteRejectedIntent = (ticket, prepared, result) => {
  if (!prepared.delivery || !prepared.delivery.status_id || result.dropIntent !== true) {
    return;
  }

  ticket.pendingInserts.delete(prepared.delivery.status_id);
};

/**
 * @param {ExternalTicket} ticket
 * @param {{ event: string, delivery?: any }} prepared
 * @return {string}
 */
const eventToWrite = (ticket, prepared, routeId) => {
  if ((prepared.event !== 'update' && prepared.event !== 'status.update') || !prepared.delivery) {
    return prepared.event;
  }

  const statusId = prepared.delivery.status_id;
  const pending = ticket.pendingInserts.get(statusId);
  const delivered = routeIdOf(prepared.delivery.route_id);
  const current = routeIdOf(routeId);

  if (delivered && current && delivered !== current) {
    if (pending && pending.routeId && compareDecimal(pending.routeId, current) < 0) {
      ticket.pendingInserts.delete(statusId);
    }

    return prepared.event === 'update' ? 'status.update' : prepared.event;
  }

  if (!pending || ticket.insertedStatuses.has(statusId)) {
    return prepared.event;
  }

  if (pending.subscriptionId === prepared.delivery.subscription_id && pending.routeId && delivered && current && pending.routeId === delivered && delivered === current) {
    return 'update';
  }

  // Frames that do not name a route row keep the earlier promotion rule.
  if (!pending.routeId && !delivered) {
    return 'update';
  }

  return prepared.event;
};

/**
 * @param {ExternalTicket} ticket
 * @param {{ event: string, delivery?: any }} prepared
 * @param {string} event
 */
const rememberWrite = (ticket, prepared, event) => {
  rememberDelivery(ticket, prepared);

  if (!prepared.delivery || !prepared.delivery.status_id) {
    return;
  }

  if (event === 'update' || event === 'delete') {
    ticket.pendingInserts.delete(prepared.delivery.status_id);
  }

  if (event === 'update') {
    ticket.insertedStatuses.add(prepared.delivery.status_id);
  }
};

/**
 * @param {Promise<any>[]} started
 * @return {Promise<void>}
 */
const waitStartedQueries = started => {
  if (started.length === 0) {
    return Promise.resolve();
  }

  return Promise.all(started.map(item => Promise.resolve(item).then(() => null, () => null))).then(() => {});
};

/**
 * @param {ExternalTicket} ticket
 * @param {ConfirmSignal} signal
 * @param {Promise<any>[]|null} started
 * @return {function(string, any[]): Promise<any>}
 */
const trackedQuery = (ticket, signal, started) => (sql, params) => {
  if (signal.aborted || !ticket.active) {
    return Promise.reject(abortError());
  }

  let pending;

  try {
    pending = ticket.query(sql, params, { signal: signal, timeoutMs: PRIVATE_CONFIRM_MS });
  } catch (error) {
    return Promise.reject(error);
  }

  if (started) {
    started.push(pending);
  }

  return Promise.resolve(pending).then(result => {
    if (signal.aborted || !ticket.active) {
      return Promise.reject(abortError());
    }

    return result;
  });
};

/**
 * @param {ExternalTicket} ticket
 * @return {{ signal: ConfirmSignal, timer: ReturnType<typeof setTimeout> }}
 */
const armConfirm = ticket => {
  const signal = createSignal();
  const timer = setTimeout(() => {
    if (ticket.confirmSignal === signal) {
      signal.abort();
    }
  }, PRIVATE_CONFIRM_MS);

  ticket.confirmSignal = signal;
  ticket.confirmTimer = timer;

  return { signal: signal, timer: timer };
};

/**
 * @param {ExternalTicket} ticket
 * @param {ConfirmSignal} signal
 * @param {ReturnType<typeof setTimeout>} timer
 */
const disarmConfirm = (ticket, signal, timer) => {
  if (ticket.confirmTimer === timer) {
    clearTimeout(timer);
    ticket.confirmTimer = null;
  }

  if (ticket.confirmSignal === signal) {
    ticket.confirmSignal = null;
  }
};

/**
 * @param {ExternalTicket} ticket
 * @param {string} subscriptionId
 */
const dropSubscriptionIntent = (ticket, subscriptionId) => {
  Array.from(ticket.pendingInserts.entries()).forEach(([statusId, stored]) => {
    if (stored && stored.subscriptionId === subscriptionId) {
      ticket.pendingInserts.delete(statusId);
    }
  });
};

/**
 * A route notice names the row it created or destroyed. An older row's
 * insert intent ends. A newer row, including one noted before this notice
 * reached the head, stays.
 *
 * @param {ExternalTicket} ticket
 * @param {string} subscriptionId
 * @param {{ routeId: string|null, removedRouteId: string|null }} epoch
 */
const applyRouteEpoch = (ticket, subscriptionId, epoch) => {
  Array.from(ticket.pendingInserts.entries()).forEach(([statusId, pending]) => {
    if (!pending || pending.subscriptionId !== subscriptionId) {
      return;
    }

    if (typeof pending.routeId !== 'string') {
      ticket.pendingInserts.delete(statusId);

      return;
    }

    if (epoch.routeId) {
      if (compareDecimal(pending.routeId, epoch.routeId) < 0) {
        ticket.pendingInserts.delete(statusId);
      }

      return;
    }

    if (epoch.removedRouteId && compareDecimal(pending.routeId, epoch.removedRouteId) <= 0) {
      ticket.pendingInserts.delete(statusId);
    }
  });
};

/**
 * Route row ids travel on the Redis envelope, not in the client payload.
 *
 * @param {any} delivery
 * @return {any[]|null}
 */
const cleanRouteEpochs = delivery => {
  if (!delivery || delivery.kind !== 'routes' || !Array.isArray(delivery.epochs)) {
    return null;
  }

  const epochs = [];

  delivery.epochs.forEach(epoch => {
    if (!epoch || typeof epoch !== 'object') {
      return;
    }

    const routeId = routeIdOf(epoch.route_id);
    const removedRouteId = routeIdOf(epoch.removed_route_id);

    if (!routeId && !removedRouteId) {
      return;
    }

    if (epoch.type === 'home') {
      epochs.push({ type: 'home', routeId: routeId, removedRouteId: removedRouteId });

      return;
    }

    if (epoch.type === 'list' && typeof epoch.id === 'string' && DECIMAL_ID.test(epoch.id)) {
      epochs.push({ type: 'list', id: epoch.id, routeId: routeId, removedRouteId: removedRouteId });
    }
  });

  return epochs;
};

/**
 * @param {any[]|null} epochs
 * @param {ExternalTicket} ticket
 * @return {{ routeId: string|null, removedRouteId: string|null }|null}
 */
const epochForTicket = (epochs, ticket) => {
  if (!Array.isArray(epochs)) {
    return null;
  }

  const found = epochs.find(epoch => {
    if (ticket.kind === 'user') {
      return epoch.type === 'home';
    }

    return epoch.type === 'list' && epoch.id === String(ticket.listId);
  });

  return found || null;
};

/**
 * A route removal, source deletion, list removal, or unsubscribe expires
 * only the unforwarded insert for that destination and subscription.
 * routes_updated expires intent tied to an older route row. A notice that
 * does not replace this destination leaves that intent in place.
 *
 * @param {ExternalTicket} ticket
 * @param {{ control?: any }} prepared
 * @param {function(string, any[]): Promise<any>} query
 * @return {Promise<void>}
 */
const expireInsertIntent = (ticket, prepared, query) => {
  const control = prepared.control;

  if (!control) {
    return Promise.resolve();
  }

  if (control.reason === 'source_deleted') {
    if (typeof control.status_id === 'string') {
      ticket.pendingInserts.delete(control.status_id);
    } else {
      dropSubscriptionIntent(ticket, control.subscription_id);
    }

    return Promise.resolve();
  }

  if (control.reason === 'list_removed' && ticket.kind === 'list') {
    ticket.pendingInserts.clear();

    return Promise.resolve();
  }

  if (control.reason === 'subscription_removed') {
    dropSubscriptionIntent(ticket, control.subscription_id);

    return Promise.resolve();
  }

  if (control.reason !== 'routes_updated') {
    return Promise.resolve();
  }

  if (Array.isArray(control.routeEpochs)) {
    const epoch = epochForTicket(control.routeEpochs, ticket);

    if (epoch) {
      applyRouteEpoch(ticket, control.subscription_id, epoch);
    }

    return Promise.resolve();
  }

  const ids = [];

  ticket.pendingInserts.forEach((pending, statusId) => {
    if (pending && pending.subscriptionId === control.subscription_id) {
      ids.push(statusId);
    }
  });

  if (ids.length === 0) {
    return Promise.resolve();
  }

  const destination = ticket.kind === 'list' ? 'list' : 'home';
  const listId = destination === 'list' ? String(ticket.listId) : null;

  return query(ROUTE_INTENT_SQL, [
    String(ticket.req.userId),
    control.subscription_id,
    ids,
    destination,
    listId,
  ]).then(result => {
    const live = new Map();

    if (result && Array.isArray(result.rows)) {
      result.rows.forEach(row => {
        if (row && typeof row.status_id === 'string') {
          live.set(row.status_id, routeIdOf(row.route_id));
        }
      });
    }

    ids.forEach(statusId => {
      if (!live.has(statusId)) {
        ticket.pendingInserts.delete(statusId);

        return;
      }

      const pending = ticket.pendingInserts.get(statusId);
      const current = live.get(statusId);

      if (pending && pending.routeId && current && compareDecimal(pending.routeId, current) < 0) {
        ticket.pendingInserts.delete(statusId);
      }
    });
  }).catch(error => {
    // A cancelled read must not fall through to output. Any other failure
    // leaves the insert intent in place and still allows the notice.
    if (error && error.code === 'EXTERNAL_FEED_CANCELLED') {
      throw error;
    }
  });
};

/**
 * @param {ExternalTicket} ticket
 */
const pumpPrivateQueue = ticket => {
  if (ticket.confirming || !ticket.active || ticket.queue.length === 0) {
    return;
  }

  const slot = ticket.queue[0];
  const started = [];
  const armed = armConfirm(ticket);
  const { signal, timer } = armed;

  ticket.confirming = true;

  const wrapped = trackedQuery(ticket, signal, started);

  const release = () => {
    disarmConfirm(ticket, signal, timer);
    ticket.confirming = false;

    if (ticket.queue[0] === slot) {
      ticket.queue.shift();
    }

    if (ticket.active) {
      pumpPrivateQueue(ticket);
    }
  };

  const settle = () => waitStartedQueries(started).then(release);

  const writeSlot = result => {
    // expireInsertIntent is the last promise. finish is one turn, with no
    // further await between these checks, output, and rememberWrite.
    const finish = () => {
      if (!ticket.active || signal.aborted || !generationAllowed(ticket, slot.prepared)) {
        if (slot.prepared.delivery && ticket.removedStatuses.has(slot.prepared.delivery.status_id)) {
          ticket.pendingInserts.delete(slot.prepared.delivery.status_id);
        }

        return settle();
      }

      if (slot.prepared.control && !claimRevision(ticket, slot.prepared.control)) {
        return settle();
      }

      const event = eventToWrite(ticket, slot.prepared, result && result.routeId);

      try {
        ticket.output(event, slot.prepared.encoded);
        rememberWrite(ticket, slot.prepared, event);
      } catch (error) {
        // A bad client write must not freeze later private events.
      }

      return settle();
    };

    if (!ticket.active || signal.aborted) {
      return settle();
    }

    return expireInsertIntent(ticket, slot.prepared, wrapped).then(finish);
  };

  confirmPrivateEvent(wrapped, ticket.req, ticket.target, slot.prepared, signal).then(result => {
    clearTimeout(timer);
    const verdict = result && result.ok === true ? result : rejectedConfirm(result && result.dropIntent === true);

    if (!ticket.active || signal.aborted || !verdict.ok || !generationAllowed(ticket, slot.prepared)) {
      if (slot.prepared.delivery && ticket.removedStatuses.has(slot.prepared.delivery.status_id)) {
        ticket.pendingInserts.delete(slot.prepared.delivery.status_id);
      }

      noteRejectedIntent(ticket, slot.prepared, verdict);

      return settle();
    }

    return writeSlot(verdict);
  }).catch(() => {
    clearTimeout(timer);

    return settle();
  });
};

/**
 * @param {ExternalTicket} ticket
 * @param {{ event: string, encoded: string, control?: any, delivery?: any }} prepared
 * @return {boolean}
 */
const enqueuePrivateDelivery = (ticket, prepared) => {
  if (!ticket.active || ticket.queue.length >= PRIVATE_PENDING_LIMIT) {
    return false;
  }

  noteInsertIntent(ticket, prepared);
  ticket.queue.push({ prepared: prepared });
  pumpPrivateQueue(ticket);

  return true;
};

/**
 * @param {any} target
 * @return {{ type: string, id?: string }|null}
 */
const cleanTarget = target => {
  if (!target || typeof target !== 'object') {
    return null;
  }

  if (target.type === 'home') {
    return { type: 'home' };
  }

  if (target.type === 'list' && typeof target.id === 'string' && DECIMAL_ID.test(target.id)) {
    return { type: 'list', id: target.id };
  }

  return null;
};

/**
 * @param {any} payload
 * @param {string} kind
 * @param {string|null} listId
 * @return {any|null}
 */
const sanitizeControl = (payload, kind, listId) => {
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    return null;
  }

  if (payload.version !== 1 && payload.version !== '1') {
    return null;
  }

  if (!REASONS.has(payload.reason)) {
    return null;
  }

  if (typeof payload.subscription_id !== 'string' || !DECIMAL_ID.test(payload.subscription_id)) {
    return null;
  }

  if (typeof payload.feed_routes_revision !== 'string' || !REVISION.test(payload.feed_routes_revision)) {
    return null;
  }

  if (!Array.isArray(payload.targets)) {
    return null;
  }

  const targets = [];

  for (let index = 0; index < payload.targets.length; index += 1) {
    const cleaned = cleanTarget(payload.targets[index]);

    if (!cleaned) {
      return null;
    }

    targets.push(cleaned);
  }

  const matched = targets.some(target => {
    if (kind === 'user') {
      // The control channel is already this user. list_removed has no home
      // target; the deleted list id is still only delivered on this channel.
      if (target.type === 'home') {
        return true;
      }

      return payload.reason === 'list_removed' && target.type === 'list';
    }

    return target.type === 'list' && target.id === String(listId);
  });

  if (!matched) {
    return null;
  }

  const clean = {
    version: 1,
    reason: payload.reason,
    targets: targets,
    subscription_id: payload.subscription_id,
    feed_routes_revision: payload.feed_routes_revision,
  };

  if (payload.reason === 'source_deleted' || payload.reason === 'source_restored') {
    if (payload.status_id !== undefined) {
      if (typeof payload.status_id !== 'string' || !DECIMAL_ID.test(payload.status_id)) {
        return null;
      }

      clean.status_id = payload.status_id;
    }
  }

  return clean;
};

/**
 * @param {ExternalTicket} ticket
 * @param {any} control
 * @return {boolean}
 */
const revisionAllowed = (ticket, control) => {
  const previous = ticket.revisions.get(control.subscription_id);

  if (previous === undefined) {
    return true;
  }

  return compareDecimal(control.feed_routes_revision, previous) >= 0;
};

/**
 * @param {ExternalTicket} ticket
 * @param {any} control
 * @return {boolean}
 */
const claimRevision = (ticket, control) => {
  if (!revisionAllowed(ticket, control)) {
    return false;
  }

  ticket.revisions.set(control.subscription_id, control.feed_routes_revision);

  return true;
};

/**
 * @param {ExternalTicket} ticket
 * @param {any} json
 * @return {{ event: string, encoded: string, control?: any }|null}
 */
const prepareEvent = (ticket, json) => {
  if (!json || typeof json.event !== 'string') {
    return null;
  }

  if (json.event === 'update' || json.event === 'status.update') {
    if (!json.payload || typeof json.payload !== 'object' || Array.isArray(json.payload)) {
      return null;
    }

    if (typeof json.payload.id !== 'string' || !DECIMAL_ID.test(json.payload.id)) {
      return null;
    }

    const delivery = cleanDelivery(json.delivery, json.event, json.payload.id);

    if (!delivery) {
      return null;
    }

    stripStreamingSearchableText(json.payload);

    return { event: json.event, encoded: JSON.stringify(json.payload), delivery: delivery };
  }

  if (json.event === 'delete') {
    if (typeof json.payload !== 'string' || !DECIMAL_ID.test(json.payload)) {
      return null;
    }

    const delivery = cleanDelivery(json.delivery, json.event, json.payload);

    if (!delivery) {
      return null;
    }

    return { event: json.event, encoded: json.payload, delivery: delivery };
  }

  if (json.event === 'external_feed_changed') {
    const control = sanitizeControl(json.payload, ticket.kind, ticket.listId);

    if (!control || !revisionAllowed(ticket, control)) {
      return null;
    }

    const encoded = JSON.stringify(control);
    const routeEpochs = cleanRouteEpochs(json.delivery);

    if (routeEpochs) {
      control.routeEpochs = routeEpochs;
    }

    return { event: json.event, encoded: encoded, control: control };
  }

  return null;
};

/**
 * @param {function(string): void} listener
 * @param {{ unsubscribe: function(string, function(string): void): void }} deps
 */
const detachExternalFeed = (listener, deps) => {
  const ticket = tickets.get(listener);

  if (!ticket) {
    return;
  }

  ticket.active = false;

  if (ticket.confirmTimer) {
    clearTimeout(ticket.confirmTimer);
    ticket.confirmTimer = null;
  }

  if (ticket.confirmSignal) {
    ticket.confirmSignal.abort();
  }

  if (!ticket.boundaryReleased) {
    ticket.boundaryReleased = true;
    releaseBoundary(ticket.req);
  }

  const channels = ticket.channels.splice(0);

  if (!ticket.listener) {
    return;
  }

  channels.forEach(channel => {
    deps.unsubscribe(channel, ticket.listener);
  });
};

/**
 * @param {object} options
 * @param {function(string): void} options.listener
 * @param {any} options.req
 * @param {{ kind: string, listId?: string }} options.externalFeed
 * @param {function(string, any[]): Promise<any>} options.query
 * @param {string} options.redisPrefix
 * @param {function(string, function(string): void): void} options.subscribe
 * @param {function(string, function(string): void): void} options.unsubscribe
 * @param {function(string, string): void} options.output
 */
const attachExternalFeed = options => {
  const { listener, req, externalFeed, query, redisPrefix, subscribe, unsubscribe, output } = options;

  if (!externalFeed || !req || !req.userId || !req.accessTokenId || !req.accountId) {
    return;
  }

  if (externalFeed.kind !== 'user' && externalFeed.kind !== 'list') {
    return;
  }

  if (tickets.has(listener)) {
    detachExternalFeed(listener, { unsubscribe: unsubscribe });
  }

  const boundary = retainBoundary(req);

  /** @type {ExternalTicket} */
  const ticket = {
    active: true,
    channels: [],
    revisions: new Map(),
    kind: externalFeed.kind,
    listId: externalFeed.listId === undefined || externalFeed.listId === null ? null : String(externalFeed.listId),
    listener: null,
    queue: [],
    confirming: false,
    confirmSignal: null,
    confirmTimer: null,
    seenGenerations: boundary.seenGenerations,
    removedStatuses: boundary.removedStatuses,
    pendingInserts: new Map(),
    insertedStatuses: new Set(),
    boundaryReleased: false,
    query: query,
    req: req,
    target: { kind: externalFeed.kind, listId: externalFeed.listId === undefined || externalFeed.listId === null ? null : String(externalFeed.listId) },
    output: output,
  };

  tickets.set(listener, ticket);

  const deps = { unsubscribe: unsubscribe };

  if (req.on) {
    req.on('close', () => detachExternalFeed(listener, deps));
  }

  const target = ticket.target;
  const armed = armConfirm(ticket);
  const wrapped = trackedQuery(ticket, armed.signal, null);

  authorizeExternalDelivery(wrapped, req, target).then(allowed => {
    disarmConfirm(ticket, armed.signal, armed.timer);

    if (!ticket.active || armed.signal.aborted || !allowed) {
      if (ticket.active) {
        detachExternalFeed(listener, deps);
      }

      return;
    }

    const names = channelNames(req.userId, ticket.kind, ticket.listId);

    if (names.length === 0) {
      detachExternalFeed(listener, deps);

      return;
    }

    ticket.listener = message => {
      if (!ticket.active) {
        return;
      }

      let json = null;

      try {
        json = JSON.parse(message);
      } catch (error) {
        return;
      }

      const prepared = prepareEvent(ticket, json);

      if (!prepared || ticket.queue.length >= PRIVATE_PENDING_LIMIT) {
        return;
      }

      enqueuePrivateDelivery(ticket, prepared);
    };

    names.forEach(name => {
      const channel = `${redisPrefix}${name}`;

      ticket.channels.push(channel);
      subscribe(channel, ticket.listener);
    });

    if (!ticket.active) {
      detachExternalFeed(listener, deps);
    }
  }).catch(() => {
    disarmConfirm(ticket, armed.signal, armed.timer);
  });
};

/**
 * Private queries only. `connect` is a node-postgres pool connect.
 * A timeout or abort releases the client, and drops it when a statement
 * already started, so the ordinary pool is not given that connection.
 * Callers that omit `timeoutMs` do not set a per-query read timeout.
 *
 * @param {function(function(Error|null, any, function(Error|undefined=): void): void): void} connect
 * @return {function(string, any[], { signal?: ConfirmSignal, timeoutMs?: number }|undefined=): Promise<any>}
 */
const createCancellableQuery = connect => (sql, params, options = {}) => new Promise((resolve, reject) => {
  const signal = options && options.signal;
  const timeoutMs = options && options.timeoutMs;
  let settled = false;
  let client = null;
  let release = null;
  let timer = null;
  let queried = false;

  const finish = (err, result) => {
    if (settled) {
      return;
    }

    settled = true;

    if (timer) {
      clearTimeout(timer);
      timer = null;
    }

    if (signal && signal.removeEventListener) {
      signal.removeEventListener('abort', onAbort);
    }

    if (release) {
      const done = release;

      release = null;

      try {
        done(client && client._externalFeedDropped ? abortError() : undefined);
      } catch (releaseFailure) {
        // The pool throws if a client is released twice.
      }
    }

    if (err) {
      reject(err);

      return;
    }

    resolve(result);
  };

  const dropClient = () => {
    if (!client || client._externalFeedDropped) {
      return;
    }

    client._externalFeedDropped = true;
    const stream = client.connection && client.connection.stream;

    if (stream && typeof stream.destroy === 'function') {
      stream.destroy();
    }
  };

  const onAbort = () => {
    if (queried) {
      dropClient();
    }

    finish(abortError());
  };

  if (signal && signal.aborted) {
    finish(abortError());

    return;
  }

  if (signal && signal.addEventListener) {
    signal.addEventListener('abort', onAbort);
  }

  if (typeof timeoutMs === 'number' && timeoutMs > 0) {
    timer = setTimeout(onAbort, timeoutMs);
  }

  try {
    connect((err, connected, done) => {
      if (settled) {
        if (typeof done === 'function') {
          try {
            done();
          } catch (releaseFailure) {
            // Already cancelled before checkout completed.
          }
        }

        return;
      }

      if (err) {
        finish(err);

        return;
      }

      client = connected;
      release = done;

      if (signal && signal.aborted) {
        onAbort();

        return;
      }

      const config = { text: sql, values: params };

      if (typeof timeoutMs === 'number' && timeoutMs > 0) {
        config.query_timeout = timeoutMs;
      }

      queried = true;
      client.query(config, (queryError, result) => {
        if (queryError) {
          if (client) {
            client._externalFeedDropped = true;
          }

          finish(queryError);

          return;
        }

        finish(null, result);
      });
    });
  } catch (error) {
    finish(error);
  }
});

module.exports = {
  compareDecimal,
  yamlScalar,
  flagEnabled,
  testerListed,
  channelNames,
  accountRowAllowed,
  sanitizeControl,
  prepareEvent,
  authorizeExternalDelivery,
  confirmPrivateEvent,
  createCancellableQuery,
  PRIVATE_PENDING_LIMIT,
  PRIVATE_CONFIRM_MS,
  attachExternalFeed,
  detachExternalFeed,
  revisionAllowed,
  claimRevision,
};

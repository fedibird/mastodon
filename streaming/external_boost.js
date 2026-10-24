// @ts-check

const { compareDecimal, createSignal, abortError } = require('./external_feed');

const DECIMAL_ID = /^[1-9]\d*$/;
const REVISION = /^(?:0|[1-9]\d*)$/;

const EVENT = 'external_link_boost_changed';
const BOOST_PENDING_LIMIT = 64;
const BOOST_CONFIRM_MS = 5000;
const BOOST_SEEN_LIMIT = 512;

/**
 * Owner-only share state of an external projection (E4). This is a separate
 * channel from the E3 home, list, and control channels. It needs no feed
 * route and does not read the E3 or E4 feature flags: a state change that has
 * already happened is the token user's own, and Undo works while sharing is
 * off. What it does require is the same account check as every private
 * channel (token live, `resource_owner_id` matches, user functional) and, for
 * each frame, a marker owned by that user.
 *
 * The Redis frame only names the user and the projection. What is written is
 * the (revision, reblogged) row as it is when the frame reaches the head of
 * the ticket queue, so a late or duplicated frame never writes an older pair.
 *
 * @typedef BoostTicket
 * @property {boolean} active
 * @property {string[]} channels
 * @property {function(string): void|null} listener
 * @property {string[]} queue
 * @property {Set<string>} queued
 * @property {boolean} confirming
 * @property {any} signal
 * @property {ReturnType<typeof setTimeout>|null} timer
 * @property {Map<string, string>} seen
 * @property {any} req
 * @property {function(string, any[], any=): Promise<any>} query
 * @property {function(string, string): void} output
 */

/** @type {WeakMap<function(string): void, BoostTicket>} */
const tickets = new WeakMap();

/**
 * @param {string} userId
 * @return {string|null}
 */
const boostChannelName = userId => {
  const id = String(userId);

  return DECIMAL_ID.test(id) ? `timeline:external:user:${id}:boost` : null;
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
         accounts.moved_to_account_id
    FROM oauth_access_tokens
    INNER JOIN users ON users.id = oauth_access_tokens.resource_owner_id
    INNER JOIN accounts ON accounts.id = users.account_id
   WHERE oauth_access_tokens.id = $1
     AND users.id::text = $2
     AND users.account_id::text = $3
   LIMIT 1
`;

const STATE_SQL = `
  SELECT states.revision::text AS revision,
         states.reblogged AS reblogged
    FROM external_projection_link_boost_states states
   WHERE states.user_id = $1::bigint
     AND states.projection_status_id = $2::bigint
     AND EXISTS (
       SELECT 1 FROM external_status_projections markers
        WHERE markers.user_id = states.user_id
          AND markers.status_id = states.projection_status_id
     )
   LIMIT 1
`;

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

  return !(row.suspended_at || row.memorial === true || row.moved_to_account_id);
};

/**
 * @param {function(string, any[]): Promise<any>} query
 * @param {any} req
 * @return {Promise<boolean>}
 */
const authorizeBoostDelivery = (query, req) => {
  if (!req || !req.accessTokenId || !req.userId || !req.accountId) {
    return Promise.resolve(false);
  }

  return query(ACCOUNT_SQL, [String(req.accessTokenId), String(req.userId), String(req.accountId)]).then(result => {
    return !!(result && Array.isArray(result.rows) && result.rows.length === 1 && accountRowAllowed(result.rows[0], req));
  }).catch(() => false);
};

/**
 * Only the user and the projection are taken from the frame. The payload and
 * the delivery object must agree with each other; the client body is rebuilt
 * from the database row, so nothing else in the frame is forwarded.
 *
 * @param {any} json
 * @param {string} userId
 * @return {{ statusId: string, revision: string }|null}
 */
const prepareBoostEvent = (json, userId) => {
  if (!json || json.event !== EVENT) {
    return null;
  }

  const payload = json.payload;
  const delivery = json.delivery;

  if (!payload || typeof payload !== 'object' || Array.isArray(payload) || !delivery || typeof delivery !== 'object' || Array.isArray(delivery)) {
    return null;
  }

  if (payload.version !== 1 && payload.version !== '1') {
    return null;
  }

  if (typeof payload.status_id !== 'string' || !DECIMAL_ID.test(payload.status_id)) {
    return null;
  }

  if (typeof payload.revision !== 'string' || !REVISION.test(payload.revision) || typeof payload.reblogged !== 'boolean') {
    return null;
  }

  if (delivery.kind !== 'boost' || delivery.user_id !== String(userId) || delivery.status_id !== payload.status_id || delivery.revision !== payload.revision) {
    return null;
  }

  return { statusId: payload.status_id, revision: payload.revision };
};

/**
 * @param {BoostTicket} ticket
 * @param {string} statusId
 * @param {string} revision
 */
const rememberSeen = (ticket, statusId, revision) => {
  ticket.seen.delete(statusId);
  ticket.seen.set(statusId, revision);

  while (ticket.seen.size > BOOST_SEEN_LIMIT) {
    const oldest = ticket.seen.keys().next().value;

    ticket.seen.delete(oldest);
  }
};

/**
 * @param {BoostTicket} ticket
 */
const pump = ticket => {
  if (ticket.confirming || !ticket.active || ticket.queue.length === 0) {
    return;
  }

  const statusId = /** @type {string} */ (ticket.queue[0]);
  const signal = createSignal();
  const started = [];

  // A frame that arrives while this one is being read must be read again, so
  // coalescing only covers frames that are still waiting.
  ticket.queued.delete(statusId);
  ticket.confirming = true;
  ticket.signal = signal;

  const timer = setTimeout(() => signal.abort(), BOOST_CONFIRM_MS);

  ticket.timer = timer;

  const run = (sql, params) => {
    if (signal.aborted || !ticket.active) {
      return Promise.reject(abortError());
    }

    const pending = ticket.query(sql, params, { signal: signal, timeoutMs: BOOST_CONFIRM_MS });

    started.push(pending);

    return Promise.resolve(pending).then(result => {
      if (signal.aborted || !ticket.active) {
        return Promise.reject(abortError());
      }

      return result;
    });
  };

  const release = () => {
    clearTimeout(timer);

    if (ticket.timer === timer) {
      ticket.timer = null;
    }

    if (ticket.signal === signal) {
      ticket.signal = null;
    }

    ticket.confirming = false;
    ticket.queue.shift();

    if (ticket.active) {
      pump(ticket);
    }
  };

  // The next message waits until every statement that already started has
  // settled or been cancelled.
  const settle = () => Promise.all(started.map(item => Promise.resolve(item).then(() => null, () => null))).then(release);

  authorizeBoostDelivery(run, ticket.req).then(allowed => {
    if (!allowed) {
      return null;
    }

    return run(STATE_SQL, [String(ticket.req.userId), statusId]);
  }).then(result => {
    const row = result && Array.isArray(result.rows) ? result.rows[0] : null;

    // One turn from here to the write: no await between the ticket and
    // signal check, the watermark, and output.
    if (!row || !ticket.active || signal.aborted) {
      return;
    }

    if (typeof row.revision !== 'string' || !REVISION.test(row.revision) || typeof row.reblogged !== 'boolean') {
      return;
    }

    const seen = ticket.seen.get(statusId);

    if (seen !== undefined && compareDecimal(row.revision, seen) <= 0) {
      return;
    }

    try {
      ticket.output(EVENT, JSON.stringify({
        version: 1,
        status_id: statusId,
        reblogged: row.reblogged,
        revision: row.revision,
      }));
      rememberSeen(ticket, statusId, row.revision);
    } catch (error) {
      // A bad client write must not freeze later frames.
    }
  }).catch(() => {}).then(settle).catch(() => {});
};

/**
 * @param {function(string): void} listener
 * @param {{ unsubscribe: function(string, function(string): void): void }} deps
 */
const detachExternalBoost = (listener, deps) => {
  const ticket = tickets.get(listener);

  if (!ticket) {
    return;
  }

  ticket.active = false;
  tickets.delete(listener);

  if (ticket.timer) {
    clearTimeout(ticket.timer);
    ticket.timer = null;
  }

  if (ticket.signal) {
    ticket.signal.abort();
  }

  ticket.queue.length = 0;
  ticket.queued.clear();

  const channels = ticket.channels.splice(0);
  const inner = ticket.listener;

  if (!inner) {
    return;
  }

  channels.forEach(channel => {
    deps.unsubscribe(channel, inner);
  });
};

/**
 * Attaches the owner boost channel to an authenticated `user` or `list`
 * connection. `listener` is the connection's stream listener; it is only the
 * key under which this ticket is found again on unsubscribe or close.
 *
 * @param {object} options
 * @param {function(string): void} options.listener
 * @param {any} options.req
 * @param {{ kind: string }} options.externalFeed
 * @param {function(string, any[], any=): Promise<any>} options.query
 * @param {string} options.redisPrefix
 * @param {function(string, function(string): void): void} options.subscribe
 * @param {function(string, function(string): void): void} options.unsubscribe
 * @param {function(string, string): void} options.output
 */
const attachExternalBoost = options => {
  const { listener, req, externalFeed, query, redisPrefix, subscribe, unsubscribe, output } = options;

  if (!externalFeed || (externalFeed.kind !== 'user' && externalFeed.kind !== 'list')) {
    return;
  }

  if (!req || !req.userId || !req.accessTokenId || !req.accountId) {
    return;
  }

  const name = boostChannelName(req.userId);

  if (!name) {
    return;
  }

  const deps = { unsubscribe: unsubscribe };

  if (tickets.has(listener)) {
    detachExternalBoost(listener, deps);
  }

  /** @type {BoostTicket} */
  const ticket = {
    active: true,
    channels: [],
    listener: null,
    queue: [],
    queued: new Set(),
    confirming: false,
    signal: null,
    timer: null,
    seen: new Map(),
    req: req,
    query: query,
    output: output,
  };

  tickets.set(listener, ticket);

  if (req.on) {
    req.on('close', () => detachExternalBoost(listener, deps));
  }

  const signal = createSignal();
  const timer = setTimeout(() => signal.abort(), BOOST_CONFIRM_MS);

  ticket.signal = signal;
  ticket.timer = timer;

  const guarded = (sql, params) => {
    if (signal.aborted || !ticket.active) {
      return Promise.reject(abortError());
    }

    return Promise.resolve(ticket.query(sql, params, { signal: signal, timeoutMs: BOOST_CONFIRM_MS })).then(result => {
      if (signal.aborted || !ticket.active) {
        return Promise.reject(abortError());
      }

      return result;
    });
  };

  authorizeBoostDelivery(guarded, req).then(allowed => {
    clearTimeout(timer);

    if (ticket.timer === timer) {
      ticket.timer = null;
    }

    if (ticket.signal === signal) {
      ticket.signal = null;
    }

    if (!ticket.active || signal.aborted || !allowed) {
      detachExternalBoost(listener, deps);

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

      const prepared = prepareBoostEvent(json, String(req.userId));

      if (!prepared || ticket.queued.has(prepared.statusId) || ticket.queue.length >= BOOST_PENDING_LIMIT) {
        return;
      }

      ticket.queued.add(prepared.statusId);
      ticket.queue.push(prepared.statusId);
      pump(ticket);
    };

    const channel = `${redisPrefix}${name}`;

    ticket.channels.push(channel);
    subscribe(channel, ticket.listener);
  }).catch(() => {
    clearTimeout(timer);
  });
};

module.exports = {
  EVENT,
  BOOST_PENDING_LIMIT,
  BOOST_CONFIRM_MS,
  boostChannelName,
  accountRowAllowed,
  authorizeBoostDelivery,
  prepareBoostEvent,
  attachExternalBoost,
  detachExternalBoost,
};

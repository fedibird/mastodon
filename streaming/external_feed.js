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
 */

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
 * @return {Promise<boolean>}
 */
const authorizeExternalDelivery = (query, req, target) => {
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

    return query('SELECT 1 FROM lists WHERE id = $1::bigint AND account_id = $2::bigint LIMIT 1', [String(target.listId), String(req.accountId)]).then(listResult => {
      return !!(listResult && Array.isArray(listResult.rows) && listResult.rows.length === 1);
    });
  }).catch(() => false);
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
      return target.type === 'home';
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

    stripStreamingSearchableText(json.payload);

    return { event: json.event, encoded: JSON.stringify(json.payload) };
  }

  if (json.event === 'delete') {
    if (typeof json.payload !== 'string' || !DECIMAL_ID.test(json.payload)) {
      return null;
    }

    return { event: json.event, encoded: json.payload };
  }

  if (json.event === 'external_feed_changed') {
    const control = sanitizeControl(json.payload, ticket.kind, ticket.listId);

    if (!control || !revisionAllowed(ticket, control)) {
      return null;
    }

    return { event: json.event, encoded: JSON.stringify(control), control: control };
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

  /** @type {ExternalTicket} */
  const ticket = {
    active: true,
    channels: [],
    revisions: new Map(),
    kind: externalFeed.kind,
    listId: externalFeed.listId === undefined || externalFeed.listId === null ? null : String(externalFeed.listId),
    listener: null,
  };

  tickets.set(listener, ticket);

  const deps = { unsubscribe: unsubscribe };

  if (req.on) {
    req.on('close', () => detachExternalFeed(listener, deps));
  }

  const target = { kind: ticket.kind, listId: ticket.listId };

  authorizeExternalDelivery(query, req, target).then(allowed => {
    if (!ticket.active || !allowed) {
      return;
    }

    const names = channelNames(req.userId, ticket.kind, ticket.listId);

    if (names.length === 0) {
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

      if (!prepared) {
        return;
      }

      authorizeExternalDelivery(query, req, target).then(stillAllowed => {
        if (!ticket.active || !stillAllowed) {
          return;
        }

        if (prepared.control && !claimRevision(ticket, prepared.control)) {
          return;
        }

        output(prepared.event, prepared.encoded);
      }).catch(() => {});
    };

    names.forEach(name => {
      const channel = `${redisPrefix}${name}`;

      ticket.channels.push(channel);
      subscribe(channel, ticket.listener);
    });

    if (!ticket.active) {
      detachExternalFeed(listener, deps);
    }
  }).catch(() => {});
};

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
  attachExternalFeed,
  detachExternalFeed,
  revisionAllowed,
  claimRevision,
};

import compareId from '../compare_id';
import { isDecimalStatusId } from '../timeline_navigation';
import {
  MEMBERSHIP_ID_LIMIT,
  MEMBERSHIP_SEARCH_PAGE_DEFAULT,
  MEMBERSHIP_SEARCH_PAGE_MAX,
  MEMBERSHIP_SESSION_CANDIDATE_LIMIT,
  SEEK_KIND,
  SEEK_PREFERENCE,
  TIMELINE_SEEK_VERSION,
} from '../timeline_seek/constants';
import { createSeekQuery, seekSourceFromContract, seekSourceKey } from '../timeline_seek/query';
import { anchorBeyondSplitBoundary } from '../timeline_seek/window';

// GET /api/v2/search page contract, read from Api::V2::SearchController,
// Api::BaseController#limit_param, and SearchService / StatusesSearchService:
//   q, type=statuses, offset, limit
//   default limit 20 (RESULTS_LIMIT). A passed limit is min(abs(limit), 40)
//   because max is default * 2. Offset is applied only when type is present.
//   Auth is read / read:search plus a user. Chewy disabled, a blank query,
//   Faraday::ConnectionFailed, and Parslet::ParseFailed all become statuses: []
//   with no error flag. This session does not turn that into a hard error.
//
// Caps match TimelineSeek::Membership: 50 ids per batch, 200 deduped
// candidate ids kept for the session (not raw hits received), and 10
// search pages. Each response is walked only up to the 40-row page max,
// so a huge payload cannot expand the session. A full page whose ids were
// already seen stays continuable until one of those caps. A short page
// still means the index stopped. The query stays in the search GET only.

export const TEXT_SEARCH_PAGE_SIZE = MEMBERSHIP_SEARCH_PAGE_DEFAULT;
export const TEXT_SEARCH_MAX_PAGES = MEMBERSHIP_SESSION_CANDIDATE_LIMIT / MEMBERSHIP_SEARCH_PAGE_DEFAULT;

const SEARCH_TEXT_KEYS = ['q', 'query', 'text', 'raw', 'body'];

const clampLimit = (value, fallback, ceiling) => {
  const number = Number(value);

  if (!Number.isFinite(number) || number < 1) {
    return Math.min(fallback, ceiling);
  }

  return Math.min(Math.floor(number), ceiling);
};

export const textSearchLimits = (serverLimits) => {
  const server = serverLimits || {};

  return {
    ids: clampLimit(server.ids, MEMBERSHIP_ID_LIMIT, MEMBERSHIP_ID_LIMIT),
    sessionCandidates: clampLimit(server.session_candidates, MEMBERSHIP_SESSION_CANDIDATE_LIMIT, MEMBERSHIP_SESSION_CANDIDATE_LIMIT),
    page: clampLimit(server.search_page_default, TEXT_SEARCH_PAGE_SIZE, Math.min(TEXT_SEARCH_PAGE_SIZE, MEMBERSHIP_SEARCH_PAGE_MAX)),
    maxPages: clampLimit(server.max_search_pages, TEXT_SEARCH_MAX_PAGES, TEXT_SEARCH_MAX_PAGES),
  };
};

const emptyRecords = () => ({});

export const createTextSearchState = () => ({
  generation: 0,
  searched: false,
  pagesFetched: 0,
  offset: 0,
  candidates: [],
  records: emptyRecords(),
  outcomes: {},
  members: [],
  partial: false,
  unknownCount: 0,
  limitations: [],
  stop: null,
  transport: null,
  membershipHalt: null,
  limits: textSearchLimits(),
});

export const textSearchIdentity = (props = {}) => {
  const parsed = seekSourceFromContract(props.contract);

  return {
    sourceKey: seekSourceKey(props.contract),
    source: parsed ? parsed.source : '',
    context: parsed ? parsed.context : {},
    accountId: props.accountId || '',
    columnId: props.columnId || '',
    locationKey: props.locationKey || '',
    splitSessionId: props.splitSessionId || '',
  };
};

export const textSearchIdentityKey = (identity) => [
  identity.sourceKey,
  identity.accountId,
  identity.columnId,
  identity.locationKey,
  identity.splitSessionId,
].join('\n');

// Opening history for a jump assigns a split id. That is still this column's
// search. A different split, column, account, route, or source is not.
export const identityChangeResets = (previous, next) => {
  if (!previous || !next) {
    return false;
  }

  if (previous.accountId !== next.accountId || previous.columnId !== next.columnId || previous.locationKey !== next.locationKey || previous.sourceKey !== next.sourceKey) {
    return true;
  }

  if (previous.splitSessionId && previous.splitSessionId !== next.splitSessionId) {
    return true;
  }

  return false;
};

export const plainExcerpt = (html, limit = 140) => {
  const text = String(html || '')
    .replace(/<br\s*\/?>/gi, ' ')
    .replace(/<[^>]*>/g, '')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;|&apos;/g, '\'')
    .replace(/\s+/g, ' ')
    .trim();

  if (text.length <= limit) {
    return text;
  }

  return `${text.slice(0, limit).trim()}…`;
};

export const candidateFromStatus = (status) => {
  if (!status || typeof status !== 'object') {
    return null;
  }

  const id = status.id !== undefined && status.id !== null ? String(status.id) : '';

  if (!isDecimalStatusId(id)) {
    return null;
  }

  const account = status.account || {};
  const reblog = status.reblog && typeof status.reblog === 'object' ? status.reblog : null;
  const bodySource = reblog || status;
  const spoiler = typeof bodySource.spoiler_text === 'string' ? bodySource.spoiler_text : '';
  const content = typeof bodySource.content === 'string' ? bodySource.content : '';

  return {
    id,
    createdAt: typeof status.created_at === 'string' ? status.created_at : '',
    accountId: account.id !== undefined && account.id !== null ? String(account.id) : '',
    displayName: typeof account.display_name === 'string' ? account.display_name : '',
    acct: typeof account.acct === 'string' ? account.acct : '',
    excerpt: plainExcerpt(spoiler || content),
    reblogOfId: reblog && reblog.id !== undefined && reblog.id !== null ? String(reblog.id) : null,
  };
};

export const sortIdsDesc = (ids) => ids.slice().sort((left, right) => compareId(right, left));

const copyLimitations = (current, incoming) => {
  const next = current.slice();

  (incoming || []).forEach(item => {
    if (typeof item === 'string' && next.indexOf(item) === -1) {
      next.push(item);
    }
  });

  return next;
};

export const beginSearch = (state) => ({
  ...createTextSearchState(),
  generation: (state && state.generation ? state.generation : 0) + 1,
  limits: state && state.limits ? state.limits : textSearchLimits(),
});

export const ingestSearchPage = (state, page) => {
  const body = page || {};

  if (!body.ok) {
    return {
      ...state,
      searched: true,
      transport: body.reason === 'cancelled' ? 'cancelled' : 'network',
      stop: 'uncertain',
      partial: true,
    };
  }

  const pageSize = state.limits.page;
  const incoming = [];
  const records = { ...state.records };
  const seen = {};
  const rawStatuses = Array.isArray(body.statuses) ? body.statuses : [];
  const examined = rawStatuses.slice(0, MEMBERSHIP_SEARCH_PAGE_MAX);

  state.candidates.forEach(id => {
    seen[id] = true;
  });

  examined.forEach(status => {
    if (state.candidates.length + incoming.length >= state.limits.sessionCandidates) {
      return;
    }

    const candidate = candidateFromStatus(status);

    if (!candidate || seen[candidate.id]) {
      return;
    }

    seen[candidate.id] = true;
    incoming.push(candidate.id);
    records[candidate.id] = candidate;
  });

  const candidates = state.candidates.concat(incoming);
  const pagesFetched = state.pagesFetched + 1;
  const count = examined.length;
  let stop;

  if (count === 0) {
    stop = 'uncertain';
  } else if (candidates.length >= state.limits.sessionCandidates || pagesFetched >= state.limits.maxPages) {
    stop = 'limit';
  } else if (count < pageSize) {
    stop = 'exhausted';
  } else {
    stop = 'more';
  }

  return {
    ...state,
    searched: true,
    records,
    candidates,
    pagesFetched,
    offset: state.offset + pageSize,
    stop,
    transport: null,
  };
};

export const uncheckedIds = (state) => state.candidates.filter(id => !state.outcomes[id]);

export const nextMembershipIds = (state) => uncheckedIds(state).slice(0, state.limits.ids);

export const membershipBody = (identity, ids) => {
  const context = {};

  Object.keys(identity.context || {}).forEach(key => {
    if (SEARCH_TEXT_KEYS.indexOf(key) === -1) {
      context[key] = identity.context[key];
    }
  });

  return {
    version: TIMELINE_SEEK_VERSION,
    source: identity.source,
    context,
    ids: ids.slice(0, MEMBERSHIP_ID_LIMIT),
  };
};

export const payloadHasSearchText = (value) => {
  if (!value || typeof value !== 'object') {
    return false;
  }

  return Object.keys(value).some(key => SEARCH_TEXT_KEYS.indexOf(key) !== -1 || payloadHasSearchText(value[key]));
};

const haltFrom = (response) => {
  if (!response || response.ok === false) {
    return {
      outcome: 'unavailable',
      reason: response && response.reason === 'cancelled' ? 'cancelled' : 'network',
      results: null,
    };
  }

  return response.body || response;
};

export const ingestMembership = (state, response) => {
  const body = haltFrom(response);

  if (!body || body.outcome === 'unsupported' || body.outcome === 'unavailable' || !Array.isArray(body.results)) {
    return {
      ...state,
      membershipHalt: {
        outcome: body && body.outcome ? body.outcome : 'unavailable',
        reason: body && body.reason ? body.reason : 'network',
      },
      partial: true,
      stop: state.stop === 'more' ? 'uncertain' : (state.stop || 'uncertain'),
    };
  }

  const outcomes = { ...state.outcomes };
  const records = { ...state.records };
  let unknownCount = state.unknownCount;
  let partial = state.partial || body.outcome === 'partial';

  body.results.forEach(row => {
    const id = row && row.id !== undefined && row.id !== null ? String(row.id) : '';

    if (!id || outcomes[id]) {
      return;
    }

    outcomes[id] = row.outcome;

    if (row.outcome === 'unknown') {
      unknownCount += 1;
      partial = true;
    }

    if (row.outcome !== 'member') {
      delete records[id];
    }
  });

  const server = body.limits || {};
  const limits = {
    ...state.limits,
    ids: clampLimit(server.ids, state.limits.ids, state.limits.ids),
  };

  return {
    ...state,
    outcomes,
    records,
    members: sortIdsDesc(state.candidates.filter(id => outcomes[id] === 'member')),
    unknownCount,
    partial,
    limitations: copyLimitations(state.limitations, body.limitations),
    limits,
    membershipHalt: null,
  };
};

// A jump may proceed only when this id is a confirmed member right now.
// unknown is a retained-window miss, not permission to scroll or seek.
export const membershipGate = (response, statusId) => {
  const body = haltFrom(response);

  if (!isDecimalStatusId(statusId)) {
    return { ok: false, outcome: 'unsupported', reason: 'invalid_id' };
  }

  if (!body || body.outcome === 'unsupported' || body.outcome === 'unavailable' || !Array.isArray(body.results)) {
    return {
      ok: false,
      outcome: body && body.outcome ? body.outcome : 'unavailable',
      reason: body && body.reason ? body.reason : 'network',
    };
  }

  const row = body.results.find(item => item && String(item.id) === String(statusId));

  if (!row || row.outcome !== 'member') {
    const outcome = row && typeof row.outcome === 'string' ? row.outcome : 'not_found';
    const reason = row && typeof row.reason === 'string' && row.reason ? row.reason : outcome;

    return { ok: false, outcome, reason };
  }

  return { ok: true, outcome: 'member', reason: 'member' };
};

export const publicResults = (state) => (
  state.members.map(id => state.records[id]).filter(record => record && state.outcomes[record.id] === 'member')
);

export const publicPaging = (state) => {
  if (!state.searched) {
    return 'idle';
  }

  if (state.transport === 'cancelled') {
    return 'idle';
  }

  if (state.transport === 'network') {
    return 'network';
  }

  if (state.membershipHalt) {
    return 'uncertain';
  }

  if (uncheckedIds(state).length > 0) {
    return 'checking';
  }

  return state.stop || 'idle';
};

export const sessionView = (state) => ({
  candidates: state.candidates.length,
  pages: state.pagesFetched,
  members: state.members.length,
  paging: publicPaging(state),
  partial: state.partial,
  unknownCount: state.unknownCount,
  limitations: state.limitations.slice(),
  maxPages: state.limits.maxPages,
  sessionCandidates: state.limits.sessionCandidates,
});

const confirmCandidates = async (state, identity, membership, isCurrent) => {
  let next = state;
  let ids = nextMembershipIds(next);

  while (ids.length) {
    if (!isCurrent(next.generation)) {
      return next;
    }

    const payload = membershipBody(identity, ids);

    if (payload.ids.length > next.limits.ids || payloadHasSearchText(payload)) {
      next = ingestMembership(next, { outcome: 'unsupported', reason: 'search_text_not_accepted' });
      break;
    }

    const response = await membership(payload);

    if (!isCurrent(next.generation)) {
      return next;
    }

    const pendingBefore = uncheckedIds(next).length;

    next = ingestMembership(next, response);

    if (next.membershipHalt) {
      break;
    }

    if (uncheckedIds(next).length >= pendingBefore) {
      next = ingestMembership(next, { outcome: 'unavailable', reason: 'network' });
      break;
    }

    ids = nextMembershipIds(next);
  }

  return next;
};

export const runSearchSession = async ({ state, identity, search, membership, isCurrent }) => {
  const next = beginSearch(state);

  if (!isCurrent(next.generation)) {
    return { applied: false, state: next };
  }

  const page = await search({ offset: next.offset, limit: next.limits.page });

  if (!isCurrent(next.generation)) {
    return { applied: false, state: next };
  }

  const ingested = ingestSearchPage(next, page || { ok: false, reason: 'network', statuses: [], received: 0 });
  const confirmed = await confirmCandidates(ingested, identity, membership, isCurrent);

  return { applied: isCurrent(confirmed.generation), state: confirmed };
};

export const runNextPage = async ({ state, identity, search, membership, isCurrent }) => {
  if (publicPaging(state) !== 'more') {
    return { applied: true, state };
  }

  const generation = state.generation;
  const page = await search({ offset: state.offset, limit: state.limits.page });

  if (!isCurrent(generation)) {
    return { applied: false, state };
  }

  const ingested = ingestSearchPage(state, page || { ok: false, reason: 'network', statuses: [], received: 0 });
  const confirmed = await confirmCandidates(ingested, identity, membership, isCurrent);

  return { applied: isCurrent(confirmed.generation), state: confirmed };
};

// A boost wrapper in the history window is the display row. The search hit
// id stays the original. Featured f- rows are not decimal anchors, so they
// fall through to seek.
export const loadedDisplayRowId = (items, statusId, reblogOf) => {
  const rows = items && items.toArray ? items.toArray() : items;

  if (!rows || !rows.length || !isDecimalStatusId(statusId)) {
    return null;
  }

  if (rows.indexOf(statusId) !== -1) {
    return statusId;
  }

  for (let index = 0; index < rows.length; index += 1) {
    const rowId = rows[index];

    if (!isDecimalStatusId(rowId)) {
      continue;
    }

    if (reblogOf && reblogOf(rowId) === statusId) {
      return rowId;
    }
  }

  return null;
};

export const textJumpRequest = ({ statusId, loadedDisplayRowId: loaded, boundaryId } = {}) => {
  if (!isDecimalStatusId(statusId)) {
    return { ok: false, reason: 'invalid_id' };
  }

  if (loaded && isDecimalStatusId(loaded)) {
    if (anchorBeyondSplitBoundary(loaded, boundaryId)) {
      return { ok: false, reason: 'newer_than_split_boundary' };
    }

    return { ok: true, mode: 'loaded', anchorId: loaded, statusId };
  }

  const query = createSeekQuery({
    kind: SEEK_KIND.SEARCH_HIT,
    preference: SEEK_PREFERENCE.NEAREST,
    target: { id: statusId },
  });

  if (!query || query.target.rejected || payloadHasSearchText(query)) {
    return { ok: false, reason: 'search_text_not_accepted' };
  }

  return { ok: true, mode: 'seek', query, statusId };
};

import {
  beginSearch,
  candidateFromStatus,
  createTextSearchState,
  identityChangeResets,
  ingestMembership,
  ingestSearchPage,
  loadedDisplayRowId,
  membershipBody,
  nextMembershipIds,
  payloadHasSearchText,
  publicPaging,
  publicResults,
  runNextPage,
  runSearchSession,
  sortIdsDesc,
  textJumpRequest,
  textSearchIdentity,
  TEXT_SEARCH_MAX_PAGES,
  TEXT_SEARCH_PAGE_SIZE,
} from '../session';

const phrase = (id, text, extra = {}) => ({
  id,
  created_at: '2026-10-17T01:02:03.000Z',
  content: `<p>${text}</p>`,
  account: { id: '7', display_name: 'Ada', acct: 'ada' },
  ...extra,
});

const identity = textSearchIdentity({
  contract: { source: 'home', path: '/api/v1/timelines/home', params: { visibilities: [] } },
  accountId: '1',
  columnId: 'column-a',
  locationKey: 'route-a',
  splitSessionId: '',
});

const memberBody = (rows, extra = {}) => ({
  ok: true,
  body: {
    outcome: extra.outcome || (rows.some(row => row.outcome === 'unknown') ? 'partial' : 'complete'),
    results: rows,
    limitations: extra.limitations || [],
    limits: {
      ids: 50,
      session_candidates: 200,
      search_page_default: 20,
      search_page: 40,
      max_search_pages: 10,
    },
  },
});

const page = (statuses) => ({ ok: true, statuses, received: statuses.length });

describe('timeline text search session', () => {
  it('shows only confirmed members, newest id first, after membership', async () => {
    const secret = 'private-candidate-phrase';
    const older = 'older-member-phrase';
    const newer = 'newer-member-phrase';
    const calls = [];
    const result = await runSearchSession({
      state: createTextSearchState(),
      identity,
      search: () => Promise.resolve(page([
        phrase('10', secret),
        phrase('20', older),
        phrase('100', newer),
      ])),
      membership: (payload) => {
        calls.push(payload);
        return Promise.resolve(memberBody([
          { id: '10', outcome: 'not_visible', reason: 'viewer_filter' },
          { id: '20', outcome: 'member' },
          { id: '100', outcome: 'member' },
        ]));
      },
      isCurrent: () => true,
    });

    expect(calls).toHaveLength(1);
    expect(calls[0].ids).toEqual(['10', '20', '100']);
    expect(payloadHasSearchText(calls[0])).toBe(false);
    expect(calls[0].q).toBeUndefined();
    expect(publicResults(result.state).map(row => row.excerpt)).toEqual([newer, older]);
    expect(publicResults(result.state).map(row => row.id)).toEqual(['100', '20']);
    expect(JSON.stringify(publicResults(result.state))).not.toContain(secret);
    expect(result.state.records['10']).toBeUndefined();
  });

  it('sorts huge ids by decimal string length and digits, never by Number', () => {
    const huge = '9223372036854775807';
    const mid = '9223372036854775806';
    const small = '99';

    expect(sortIdsDesc([small, huge, mid, '100'])).toEqual([huge, mid, '100', small]);
    expect(Number.isSafeInteger(Number(huge))).toBe(false);
  });

  it('keeps unknown as partial and does not list it', () => {
    const statuses = [
      phrase('50', 'outside-phrase'),
      phrase('40', 'inside-phrase'),
    ];

    for (let index = 0; index < 18; index += 1) {
      statuses.push(phrase(String(30 + index), `filler-${index}`));
    }

    const started = ingestSearchPage(beginSearch(createTextSearchState()), page(statuses));
    const confirmed = ingestMembership(started, memberBody([
      { id: '50', outcome: 'unknown', reason: 'outside_retained_range' },
      { id: '40', outcome: 'member' },
    ].concat(statuses.slice(2).map(status => ({ id: status.id, outcome: 'not_in_source' }))), { limitations: ['retention_2000'] }));

    expect(confirmed.partial).toBe(true);
    expect(confirmed.unknownCount).toBe(1);
    expect(confirmed.limitations).toContain('retention_2000');
    expect(publicResults(confirmed).map(row => row.id)).toEqual(['40']);
    expect(JSON.stringify(publicResults(confirmed))).not.toContain('outside-phrase');
    expect(publicPaging(confirmed)).toBe('more');
  });

  it('treats an empty search page as uncertain, not a full-history miss', async () => {
    const result = await runSearchSession({
      state: createTextSearchState(),
      identity,
      search: () => Promise.resolve({ ok: true, statuses: [], received: 0 }),
      membership: jest.fn(),
      isCurrent: () => true,
    });

    expect(result.state.members).toEqual([]);
    expect(publicPaging(result.state)).toBe('uncertain');
    expect(result.state.transport).toBeNull();
  });

  it('records a transport failure without inventing a search-disabled error', async () => {
    const result = await runSearchSession({
      state: createTextSearchState(),
      identity,
      search: () => Promise.resolve({ ok: false, reason: 'network', statuses: [], received: 0 }),
      membership: jest.fn(),
      isCurrent: () => true,
    });

    expect(publicPaging(result.state)).toBe('network');
    expect(result.state.partial).toBe(true);
    expect(JSON.stringify(result.state)).not.toContain('search_disabled');
  });

  it('stops a sparse scan at 200 candidates, 10 pages, and batches of 50', async () => {
    const searches = [];
    const batches = [];
    let state = createTextSearchState();
    const search = ({ offset, limit }) => {
      searches.push({ offset, limit });
      const statuses = [];

      for (let index = 0; index < limit; index += 1) {
        const id = String(1000 + offset + index);
        statuses.push(phrase(id, `hit-${id}`));
      }

      return Promise.resolve(page(statuses));
    };
    const membership = (payload) => {
      batches.push(payload.ids.slice());
      return Promise.resolve(memberBody(payload.ids.map((id, index) => ({
        id,
        outcome: index === 0 ? 'member' : 'not_in_source',
      }))));
    };
    const first = await runSearchSession({
      state,
      identity,
      search,
      membership,
      isCurrent: () => true,
    });

    state = first.state;

    while (publicPaging(state) === 'more') {
      const step = await runNextPage({
        state,
        identity,
        search,
        membership,
        isCurrent: () => true,
      });

      state = step.state;
    }

    expect(TEXT_SEARCH_PAGE_SIZE).toBe(20);
    expect(TEXT_SEARCH_MAX_PAGES).toBe(10);
    expect(searches).toHaveLength(10);
    expect(searches[0]).toEqual({ offset: 0, limit: 20 });
    expect(searches[9]).toEqual({ offset: 180, limit: 20 });
    expect(state.candidates).toHaveLength(200);
    expect(batches.every(ids => ids.length <= 50)).toBe(true);
    expect(batches.reduce((sum, ids) => sum + ids.length, 0)).toBe(200);
    expect(publicPaging(state)).toBe('limit');
    expect(publicResults(state)).toHaveLength(10);
  });

  it('does not request another page after a short page', async () => {
    const search = jest.fn(() => Promise.resolve(page([phrase('8', 'only')])));
    const result = await runSearchSession({
      state: createTextSearchState(),
      identity,
      search,
      membership: (payload) => Promise.resolve(memberBody(payload.ids.map(id => ({ id, outcome: 'not_in_source' })))),
      isCurrent: () => true,
    });
    const more = await runNextPage({
      state: result.state,
      identity,
      search,
      membership: jest.fn(),
      isCurrent: () => true,
    });

    expect(publicPaging(result.state)).toBe('exhausted');
    expect(search).toHaveBeenCalledTimes(1);
    expect(more.state).toBe(result.state);
  });

  it('dedupes ids and sends a second batch only for the remainder', () => {
    let state = beginSearch(createTextSearchState());

    for (let pageIndex = 0; pageIndex < 3; pageIndex += 1) {
      const statuses = [];

      for (let index = 0; index < 20; index += 1) {
        const id = String((pageIndex * 20) + index + 1);
        statuses.push(phrase(id, `row-${id}`));
      }

      if (pageIndex === 2) {
        statuses[0] = phrase('1', 'duplicate-phrase');
      }

      state = ingestSearchPage(state, page(statuses));
    }

    const batches = [];
    let ids = nextMembershipIds(state);

    while (ids.length) {
      batches.push(ids);
      state = ingestMembership(state, memberBody(ids.map(id => ({ id, outcome: 'member' }))));
      ids = nextMembershipIds(state);
    }

    expect(state.candidates.filter(id => id === '1')).toHaveLength(1);
    expect(state.candidates).toHaveLength(59);
    expect(batches.map(batch => batch.length)).toEqual([50, 9]);
    expect(new Set(batches.flat()).size).toBe(59);
    expect(JSON.stringify(batches)).not.toContain('duplicate-phrase');
  });

  it('drops a stale page when the generation changes', async () => {
    let resolveSearch;
    let current = true;
    const membership = jest.fn();
    const flight = runSearchSession({
      state: createTextSearchState(),
      identity,
      search: () => new Promise(resolve => {
        resolveSearch = resolve;
      }),
      membership,
      isCurrent: () => current,
    });

    current = false;
    resolveSearch(page([phrase('5', 'stale-phrase')]));

    const result = await flight;

    expect(result.applied).toBe(false);
    expect(publicResults(result.state)).toEqual([]);
    expect(membership).not.toHaveBeenCalled();
    expect(JSON.stringify(result.state.records)).not.toContain('stale-phrase');
  });

  it('resets when the column, account, route, or source changes, and keeps a new split id', () => {
    const next = { ...identity, splitSessionId: 'home:split:column-a:1' };
    const otherColumn = { ...identity, columnId: 'column-b' };

    expect(identityChangeResets(identity, next)).toBe(false);
    expect(identityChangeResets(next, { ...next, splitSessionId: 'home:split:column-a:2' })).toBe(true);
    expect(identityChangeResets(identity, otherColumn)).toBe(true);
    expect(identityChangeResets(identity, { ...identity, accountId: '2' })).toBe(true);
    expect(identityChangeResets(identity, { ...identity, locationKey: 'route-b' })).toBe(true);
    expect(identityChangeResets(identity, textSearchIdentity({
      contract: { source: 'public', path: '/api/v1/timelines/public', params: {} },
      accountId: '1',
      columnId: 'column-a',
      locationKey: 'route-a',
    }))).toBe(true);
  });

  it('jumps a loaded boost wrapper without putting the query on the seek', () => {
    const loaded = loadedDisplayRowId(['300', '200'], '150', (rowId) => (rowId === '200' ? '150' : null));
    const plan = textJumpRequest({ statusId: '150', loadedDisplayRowId: loaded, boundaryId: '400' });

    expect(loaded).toBe('200');
    expect(plan.mode).toBe('loaded');
    expect(plan.anchorId).toBe('200');
    expect(textJumpRequest({ statusId: '150', loadedDisplayRowId: '500', boundaryId: '400' }).reason).toBe('newer_than_split_boundary');

    const seek = textJumpRequest({ statusId: '9223372036854775807', loadedDisplayRowId: null });

    expect(seek.mode).toBe('seek');
    expect(seek.query.kind).toBe('searchHit');
    expect(seek.query.target).toEqual({ id: '9223372036854775807' });
    expect(payloadHasSearchText(seek.query)).toBe(false);
    expect(JSON.stringify(seek.query)).not.toContain('secret');
  });

  it('strips tags before an excerpt is stored and omits search text from membership', () => {
    const candidate = candidateFromStatus(phrase('3', 'Hello <b>there</b>&amp; friends'));

    expect(candidate.excerpt).toBe('Hello there& friends');
    expect(membershipBody(identity, ['3'])).toEqual({
      version: 1,
      source: 'home',
      context: { visibilities: [] },
      ids: ['3'],
    });
    expect(membershipBody({ ...identity, context: { q: 'secret', visibilities: [] } }, ['3']).context.q).toBeUndefined();
  });
});

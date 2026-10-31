import { groupDirectoryApiParams, groupDirectoryFilterKey, groupDirectoryViewKey, normalizeGroupDirectoryParams } from '../params';

describe('group directory params', () => {
  it('keeps pinned columns and the route on different view keys', () => {
    expect(groupDirectoryViewKey(null)).toEqual('route');
    expect(groupDirectoryViewKey('abc')).toEqual('column:abc');
    expect(groupDirectoryViewKey('abc')).not.toEqual(groupDirectoryViewKey('def'));
  });

  it('changes the filter key when search, software, scope, or order changes', () => {
    const base = normalizeGroupDirectoryParams({});

    expect(groupDirectoryFilterKey(base)).toEqual(groupDirectoryFilterKey({ order: 'active', scope: 'all' }));
    expect(groupDirectoryFilterKey({ ...base, q: '写真' })).not.toEqual(groupDirectoryFilterKey(base));
    expect(groupDirectoryFilterKey({ ...base, software: 'lemmy' })).not.toEqual(groupDirectoryFilterKey({ ...base, software: 'unknown' }));
    expect(groupDirectoryFilterKey({ ...base, scope: 'following' })).not.toEqual(groupDirectoryFilterKey({ ...base, scope: 'local' }));
    expect(groupDirectoryFilterKey({ ...base, order: 'new' })).not.toEqual(groupDirectoryFilterKey(base));
  });

  it('omits empty filters and keeps order=new as the existing API value', () => {
    expect(groupDirectoryApiParams({ order: 'new', q: '', software: '', scope: 'all' })).toEqual({
      order: 'new',
      limit: 20,
    });
    expect(groupDirectoryApiParams({ q: '  walkers@example  ', software: 'lemmy', scope: 'local' })).toEqual({
      order: 'active',
      limit: 20,
      q: '  walkers@example  ',
      software: 'lemmy',
      scope: 'local',
    });
  });
});

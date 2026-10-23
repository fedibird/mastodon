import { Map as ImmutableMap } from 'immutable';

import { getHomeVisibilities, getLimitedVisibilities } from '../../selectors';
import { normalizeSource, sourceKey } from '../source';
import { resolveRequest } from '../adapter';
import { classifyStreamStatus } from '../stream_adapters';

describe('external mix shows', () => {
  const shows = ImmutableMap({
    private: true,
    limited: true,
    direct: true,
    personal: true,
  });

  it('leaves an omitted external flag out of the saved home key', () => {
    const omitted = normalizeSource({ type: 'home', params: { shows: { reply: false } } });
    const explicit = normalizeSource({ type: 'home', params: { shows: { external: false } } });
    const included = normalizeSource({ type: 'home', params: { shows: { external: true } } });

    expect(omitted.ok).toBe(true);
    expect(omitted.source.params.shows.external).toBeUndefined();
    expect(sourceKey(omitted.source)).toBe('v1|home|-|shows=direct:1,limited:1,personal:1,private:1,reblog:1,reply:0');
    expect(explicit.source.params.shows.external).toBe(false);
    expect(sourceKey(explicit.source)).not.toBe(sourceKey(omitted.source));
    expect(sourceKey(included.source)).toContain('external:1');
    expect(normalizeSource({ type: 'limited', params: { shows: { external: true } } }).ok).toBe(false);
    expect(normalizeSource({ type: 'personal', params: { shows: { external: true } } }).ok).toBe(false);
  });

  it('requests external only for a permitted home source that saved it', () => {
    const home = { type: 'home', params: { shows: { external: true } } };
    const omitted = { type: 'home', params: {} };
    const excluded = { type: 'home', params: { shows: { external: false } } };

    expect(resolveRequest(home, null, { externalFeedsPermitted: true }).params.visibilities).toContain('external');
    expect(resolveRequest(home).params.visibilities).not.toContain('external');
    expect(resolveRequest(omitted, null, { externalFeedsPermitted: true }).params.visibilities).not.toContain('external');
    expect(resolveRequest(excluded, null, { externalFeedsPermitted: true }).params.visibilities).not.toContain('external');
    expect(resolveRequest({ type: 'limited', params: { shows: { external: true } } }, null, {
      enableLimitedTimeline: true,
      externalFeedsPermitted: true,
    }).ok).toBe(false);
  });

  it('rejects an external status unless the home source explicitly includes it', () => {
    const status = { id: '10', visibility: 'external', account: { id: '1' } };
    const home = { type: 'home', params: { shows: { external: true } } };

    expect(classifyStreamStatus(home, status, { me: '1' })).toBe('accept');
    expect(classifyStreamStatus({ type: 'home', params: {} }, status, { me: '1' })).toBe('reject');
    expect(classifyStreamStatus({ type: 'home', params: { shows: { external: false } } }, status, { me: '1' })).toBe('reject');
    expect(classifyStreamStatus({ type: 'limited', params: {} }, status, { me: '1', constraints: { enableLimitedTimeline: true } })).toBe('reject');
    expect(classifyStreamStatus({ type: 'personal', params: {} }, status, { me: '1' })).toBe('reject');
    expect(classifyStreamStatus({ type: 'list', id: '4', params: {} }, status, { me: '1', delivered: true })).toBe('accept');
  });

  it('adds external to the home column only while the signed-in user is permitted', () => {
    const state = ImmutableMap({
      settings: ImmutableMap({
        home: ImmutableMap({ shows }),
        limited: ImmutableMap({ shows }),
      }),
    });
    const off = getHomeVisibilities(state);
    const on = getHomeVisibilities(state.setIn(['externalFeeds', 'permitted'], true));

    expect(off).not.toContain('external');
    expect(on).toEqual(off.concat(['external']));
    expect(getLimitedVisibilities(state.setIn(['externalFeeds', 'permitted'], true))).not.toContain('external');
  });
});

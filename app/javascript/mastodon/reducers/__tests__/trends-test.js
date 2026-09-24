import {
  TRENDS_TAGS_FETCH_REQUEST,
  TRENDS_TAGS_FETCH_SUCCESS,
  TRENDS_TAGS_FETCH_FAIL,
  TRENDS_LINKS_FETCH_REQUEST,
  TRENDS_LINKS_FETCH_SUCCESS,
  TRENDS_LINKS_FETCH_FAIL,
} from '../../actions/trends';
import trends from '../trends';

describe('trends reducer', () => {
  it('loads trending tags and clears loading on success', () => {
    const requested = trends(undefined, { type: TRENDS_TAGS_FETCH_REQUEST });
    expect(requested.getIn(['tags', 'isLoading'])).toBe(true);

    const loaded = trends(requested, {
      type: TRENDS_TAGS_FETCH_SUCCESS,
      trends: [{ name: 'fedibird' }],
    });

    expect(loaded.getIn(['tags', 'isLoading'])).toBe(false);
    expect(loaded.getIn(['tags', 'items', 0, 'name'])).toEqual('fedibird');
  });

  it('clears tag loading on failure', () => {
    const requested = trends(undefined, { type: TRENDS_TAGS_FETCH_REQUEST });
    const failed = trends(requested, { type: TRENDS_TAGS_FETCH_FAIL });

    expect(failed.getIn(['tags', 'isLoading'])).toBe(false);
  });

  it('loads trending links and clears loading on success', () => {
    const requested = trends(undefined, { type: TRENDS_LINKS_FETCH_REQUEST });
    expect(requested.getIn(['links', 'isLoading'])).toBe(true);

    const loaded = trends(requested, {
      type: TRENDS_LINKS_FETCH_SUCCESS,
      trends: [{ id: 'link-1', title: 'Fedibird news' }],
    });

    expect(loaded.getIn(['links', 'isLoading'])).toBe(false);
    expect(loaded.getIn(['links', 'items', 0, 'id'])).toEqual('link-1');
  });

  it('clears link loading on failure', () => {
    const requested = trends(undefined, { type: TRENDS_LINKS_FETCH_REQUEST });
    const failed = trends(requested, { type: TRENDS_LINKS_FETCH_FAIL });

    expect(failed.getIn(['links', 'isLoading'])).toBe(false);
  });
});

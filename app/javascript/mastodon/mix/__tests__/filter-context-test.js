import { toServerSideType } from '../../utils/filters';
import { filterContextForSource, mixTimelineId } from '../filter_context';

describe('mix filter context', () => {
  it('does not treat a mix timeline id as the context of its sources', () => {
    const mixId = mixTimelineId('mix-1');

    expect(toServerSideType(mixId)).toBe('public');
    expect(filterContextForSource({ type: 'home', params: { shows: { reply: false } } })).toBe('home');
    expect(filterContextForSource({ type: 'list', id: '4' })).toBe('home');
    expect(filterContextForSource({ type: 'account', id: '9' })).toBe('account');
    expect(filterContextForSource({ type: 'public' })).toBe('public');
    expect(filterContextForSource({ type: 'remote' })).toBe('public');
    expect(filterContextForSource({ type: 'domain', domain: 'example.com' })).toBe('public');
    expect(filterContextForSource({ type: 'hashtag', id: 'ruby' })).toBe('public');
    expect(filterContextForSource({ type: 'group', id: '3' })).toBe('public');
    expect(filterContextForSource({ type: 'limited' })).toBe('public');
    expect(filterContextForSource({ type: 'personal' })).toBe('public');
    expect(filterContextForSource({ type: 'home' })).not.toBe(toServerSideType(mixId));
  });
});
import fs from 'fs';
import path from 'path';

import { featureUsageFlagFrom, initialFeaturePrefetchAllowed } from '../feature_usage';

const javascriptRoot = path.resolve(__dirname, '../..');
const read = relative => fs.readFileSync(path.join(javascriptRoot, relative), 'utf8');

describe('feature usage hints', () => {
  it('keeps only explicit booleans and treats every other value as unknown', () => {
    expect(featureUsageFlagFrom({ feature_usage: { has_circles: false } }, 'has_circles')).toBe(false);
    expect(featureUsageFlagFrom({ feature_usage: { has_lists: true } }, 'has_lists')).toBe(true);
    expect(featureUsageFlagFrom({ feature_usage: { has_personal_emoji_set: false } }, 'has_circles')).toBeUndefined();

    [null, undefined, {}, { feature_usage: null }, { feature_usage: [] }, { feature_usage: { has_circles: 'false' } }, { feature_usage: { has_circles: 0 } }, { feature_usage: { has_circles: null } }].forEach(state => {
      expect(featureUsageFlagFrom(state, 'has_circles')).toBeUndefined();
    });
  });

  it('allows the initial prefetch unless the hint is exactly false', () => {
    expect(initialFeaturePrefetchAllowed(false)).toBe(false);
    expect(initialFeaturePrefetchAllowed(true)).toBe(true);
    expect(initialFeaturePrefetchAllowed(undefined)).toBe(true);
    expect(initialFeaturePrefetchAllowed(null)).toBe(true);
    expect(initialFeaturePrefetchAllowed('false')).toBe(true);
  });
});

describe('initial prefetch call sites', () => {
  it('asks the circles hint only at boot, and leaves later circle reads unguarded', () => {
    const boot = read('mastodon/containers/mastodon.js');
    const compose = read('mastodon/containers/compose_container.js');
    const circlesAction = read('mastodon/actions/circles.js');
    const circlesColumn = read('mastodon/features/circles/index.js');

    expect(boot).toContain('dispatch(prefetchCircles())');
    expect(boot).not.toContain('dispatch(fetchCircles())');
    expect(boot).not.toContain('fetchLists');
    expect(compose).toContain('dispatch(prefetchCircles())');
    expect(compose).not.toContain('dispatch(fetchCircles())');
    expect(compose).not.toContain('fetchLists');

    expect(circlesAction).toContain('initialFeaturePrefetchAllowed(featureUsageFlag(\'has_circles\'))');
    expect(circlesAction.indexOf('export const fetchCircles')).toBeLessThan(circlesAction.indexOf('export const prefetchCircles'));
    expect(circlesAction.slice(circlesAction.indexOf('export const fetchCircles'), circlesAction.indexOf('export const prefetchCircles'))).not.toContain('featureUsageFlag');
    expect(circlesColumn).toContain('fetchCircles()');
    expect(circlesColumn).not.toContain('prefetchCircles');
    expect(circlesAction).toContain('dispatch(fetchCircles());');
  });

  it('does not prefetch lists at boot and does not let the hint block an explicit list read', () => {
    const listsAction = read('mastodon/actions/lists.js');
    const listsColumn = read('mastodon/features/lists/index.js');
    const mixEditor = read('mastodon/features/mixes/editor.js');
    const fetchListsBody = listsAction.slice(listsAction.indexOf('export const fetchLists'), listsAction.indexOf('export const fetchListsRequest'));

    expect(listsAction).not.toContain('featureUsageFlag');
    expect(listsAction).not.toContain('feature_usage');
    expect(fetchListsBody).toContain('/api/v1/lists');
    expect(listsColumn).toContain('fetchLists()');
    expect(mixEditor).toContain('fetchLists()');
    expect(listsAction).toContain('dispatch(fetchLists());');
  });

  it('skips personal stock only in the preload, not in the stock loader or the editor', () => {
    const preferences = read('mastodon/features/emoji/emoji_picker_preferences.js');
    const stock = read('mastodon/features/emoji/emoji_stock_source.js');
    const editor = read('mastodon/features/emoji/personal_emoji_set_editor/api.js');

    expect(preferences).toContain('has_personal_emoji_set');
    expect(preferences).toContain('loadPersonalEmojiStock()');
    expect(stock).not.toContain('featureUsageFlag');
    expect(stock).not.toContain('feature_usage');
    expect(stock).toContain('/api/v1/emoji_sets/personal/stock');
    expect(editor).toContain('/api/v1/emoji_sets/personal');
    expect(editor).not.toContain('feature_usage');
  });
});

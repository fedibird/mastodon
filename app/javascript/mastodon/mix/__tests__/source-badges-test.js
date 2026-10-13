jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

import { fromJS } from 'immutable';
import { badgeRevisionToken, mixBadgeIdentity, paneBadgeToken, sourceBadges, sourceTimelinePath, storeBadge } from '../source_badges';
import { sourceKey } from '../source';

const formatMessage = (message, values) => {
  let text = message.defaultMessage || message.id;

  if (values) {
    Object.keys(values).forEach(key => {
      text = text.split(`{${key}}`).join(String(values[key]));
    });
  }

  return text;
};

const home = { type: 'home', params: {} };
const tag = { type: 'hashtag', id: 'fediverse', params: { any: ['news'] } };
const otherTag = { type: 'hashtag', id: 'fediverse', title: 'Quiet tag', params: { all: ['dev'] } };
const list = { type: 'list', id: '4', title: '技術ニュース', params: {} };
const bareList = { type: 'list', id: '9', params: {} };

describe('mix source badges', () => {
  it('follows the saved source order and does not parse the source key', () => {
    const badges = sourceBadges(
      [home, tag, list],
      [sourceKey(list), sourceKey(home), sourceKey(tag)],
      { formatMessage },
    );

    expect(badges.map(badge => badge.label)).toEqual(['Home', '#fediverse', '技術ニュース']);
    expect(badges.map(badge => badge.key)).toEqual([sourceKey(home), sourceKey(tag), sourceKey(list)]);
    expect(badges[0].href).toBeNull();
    expect(badges[0].settingsDiffer).toBe(true);
    expect(badges[1].href).toBeNull();
    expect(badges[1].detail).toBe('Any of these: news');
    expect(badges[2].href).toBe('/timelines/list/4');
    expect(badges[0].typeLabel).toBe('Home');
  });

  it('uses a stored list title, then the id, and keeps a custom title', () => {
    const unnamed = sourceBadges([bareList], [sourceKey(bareList)], { formatMessage });
    const named = sourceBadges([bareList], [sourceKey(bareList)], {
      formatMessage,
      lists: fromJS({ 9: { id: '9', title: 'Friends' } }),
    });
    const custom = sourceBadges([otherTag], [sourceKey(otherTag)], {
      formatMessage,
      warningsByKey: { [sourceKey(otherTag)]: ['Spoilers'] },
    });

    expect(unnamed[0].label).toBe('9');
    expect(named[0].label).toBe('Friends');
    expect(custom[0].label).toBe('Quiet tag');
    expect(custom[0].detail).toBe('All of these: dev');
    expect(custom[0].warningTitles).toEqual(['Spoilers']);
    expect(custom[0].href).toBeNull();
    expect(sourceTimelinePath({ type: 'public', params: { withoutBot: true } })).toBeNull();
    expect(sourceTimelinePath({ type: 'public', params: {} })).toBe('/timelines/public');
    expect(sourceTimelinePath({ type: 'home', params: {} })).toBeNull();
    expect(sourceTimelinePath({ type: 'limited', params: {} })).toBeNull();
    expect(sourceTimelinePath({ type: 'personal', params: {} })).toBeNull();
  });

  it('changes the cache identity when labels, order, names, warnings, or locale change', () => {
    const lists = fromJS({ 9: { id: '9', title: 'Friends' } });
    const renamed = fromJS({ 9: { id: '9', title: 'Companions' } });
    const base = { sources: [home, bareList], lists, accounts: null, locale: 'en' };
    const identity = mixBadgeIdentity(base);

    expect(mixBadgeIdentity({ ...base, locale: 'ja' })).not.toBe(identity);
    expect(mixBadgeIdentity({ ...base, lists: renamed })).not.toBe(identity);
    expect(mixBadgeIdentity({ ...base, sources: [bareList, home] })).not.toBe(identity);
    expect(mixBadgeIdentity({ ...base, sources: [{ ...home, title: 'Desk' }, bareList] })).not.toBe(identity);

    const warnings = { [sourceKey(home)]: ['Spoilers'] };
    const token = paneBadgeToken({ pane: 'live', keys: [sourceKey(home)], warnings, identity });
    const revision = badgeRevisionToken({
      views: [{ sourceKeysById: { 10: [sourceKey(home)] }, sourceWarningsById: { 10: warnings } }, null, null],
      identity,
    });

    expect(token).toContain('en');
    expect(token).toContain('Spoilers');
    expect(revision).toContain(identity);
    expect(revision).not.toBe(badgeRevisionToken({
      views: [{ sourceKeysById: { 10: [sourceKey(list)] }, sourceWarningsById: {} }, null, null],
      identity,
    }));
  });

  it('drops the oldest badge arrays once the cache is full', () => {
    const cache = new Map();

    for (let index = 0; index < 201; index += 1) {
      storeBadge(cache, `single:${index}`, { token: String(index), value: [index] }, 200);
    }

    expect(cache.size).toBe(200);
    expect(cache.has('single:0')).toBe(false);
    expect(cache.get('single:200').value).toEqual([200]);
    expect(storeBadge(cache, 'single:200', { token: 'same', value: [200] }, 200)).toEqual([200]);
    expect(cache.size).toBe(200);
  });

  it('omits keys that are not in the saved mix', () => {
    const badges = sourceBadges([home], ['v1|not-a-real-key'], { formatMessage });

    expect(badges).toEqual([]);
  });
});

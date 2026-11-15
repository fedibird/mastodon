import { Map as ImmutableMap } from 'immutable';

jest.mock('mastodon/api', () => () => ({
  get: jest.fn(() => Promise.reject(new Error('offline'))),
}));
import {
  blockEmojiMuteAuthorization,
  installEmojiMutesForTests,
  noteEmojiMutesChanged,
  resetEmojiMuteStoreForTests,
  setEmojiMuteViewerSignedInForTests,
} from '../emoji_mute_store';
import {
  emojiPickerCandidateHidden,
  emojiPickerVisibility,
  noteUnresolvedPickerCandidate,
  projectEmojiStockForPicker,
  resetUnresolvedPickerCandidatesForTests,
  unresolvedPickerCandidates,
} from '../emoji_picker_visibility';
import { nativeForEmojiRecord, projectStandardPickerProps } from '../emoji_picker_standard_visibility';
import nimblePickerData from '../emoji_mart_nimble_data';

const SKIN = '👍\u{1F3FB}';
const ZWJ = '👩\u200d👩\u200d👦\u200d👦';
const VARIATION = '#\uFE0F\u20E3';

const rule = (emoji, effects) => ({ emoji, effects });

const stockItem = (key, native, extra = {}) => ({
  key,
  label: extra.label || native,
  image: { src: `https://assets.example/${key}.svg`, alt: native, title: extra.title || native },
  search: [extra.label || native, native],
  selection: { id: extra.id || native, custom: false, native },
  reference: { kind: 'unicode', native },
  ...extra.item,
});

const customItem = (key, id, shortcode) => ({
  key,
  label: shortcode,
  image: { src: `https://cdn.example/${id}.png`, alt: `:${shortcode}:`, title: shortcode },
  search: [shortcode],
  selection: { id: shortcode, custom: true, colons: `:${shortcode}:`, native: `:${shortcode}:` },
  reference: { kind: 'custom', scope: 'local', custom_emoji_id: id, shortcode },
});

describe('hide_in_picker candidate visibility', () => {
  beforeEach(() => {
    resetEmojiMuteStoreForTests();
    resetUnresolvedPickerCandidatesForTests();
    setEmojiMuteViewerSignedInForTests(true);
  });

  afterEach(() => {
    resetEmojiMuteStoreForTests();
    resetUnresolvedPickerCandidatesForTests();
  });

  it('hides only hide_in_picker and keeps the other three effects independent', () => {
    installEmojiMutesForTests({
      revision: '4',
      emoji_mutes: [
        rule({ kind: 'unicode', native: '👍' }, { hide_in_picker: true, replace_in_text: false, hide_reactions: false, reject_reactions_to_own_posts: false }),
        rule({ kind: 'unicode', native: '❤️' }, { hide_in_picker: false, replace_in_text: true, hide_reactions: true, reject_reactions_to_own_posts: true }),
      ],
    });

    const visibility = emojiPickerVisibility();

    expect(visibility.ready).toBe(true);
    expect(emojiPickerCandidateHidden({ kind: 'unicode', native: '👍' }, visibility)).toBe(true);
    expect(emojiPickerCandidateHidden({ kind: 'unicode', native: '❤️' }, visibility)).toBe(false);
    expect(emojiPickerVisibility()).toBe(visibility);
  });

  it('does not treat an unconfirmed document as zero mutes', () => {
    expect(emojiPickerVisibility().ready).toBe(false);
    expect(emojiPickerVisibility().index.size).toBe(0);

    const source = {
      categories: [{ id: 'saved', name: 'Saved', items: [stockItem('plain', '👍')] }],
    };
    const held = projectEmojiStockForPicker(source);

    expect(held.held).toBe(true);
    expect(held.stock.categories).toEqual([]);
    expect(source.categories[0].items).toHaveLength(1);

    blockEmojiMuteAuthorization('forbidden');
    expect(emojiPickerVisibility().ready).toBe(false);
    expect(projectEmojiStockForPicker(source).held).toBe(true);
  });

  it('matches finished unicode natives and leaves a different skin, ZWJ, or variation selector', () => {
    installEmojiMutesForTests({
      revision: '2',
      emoji_mutes: [
        rule({ kind: 'unicode', native: SKIN }, { hide_in_picker: true }),
        rule({ kind: 'unicode', native: ZWJ }, { hide_in_picker: true }),
        rule({ kind: 'unicode', native: '‼' }, { hide_in_picker: true }),
      ],
    });

    const visibility = emojiPickerVisibility();

    expect(emojiPickerCandidateHidden({ kind: 'unicode', native: SKIN }, visibility)).toBe(true);
    expect(emojiPickerCandidateHidden({ kind: 'unicode', native: '👍' }, visibility)).toBe(false);
    expect(emojiPickerCandidateHidden({ kind: 'unicode', native: ZWJ }, visibility)).toBe(true);
    expect(emojiPickerCandidateHidden({ kind: 'unicode', native: '👩' }, visibility)).toBe(false);
    expect(emojiPickerCandidateHidden({ kind: 'unicode', native: '‼' }, visibility)).toBe(true);
    expect(emojiPickerCandidateHidden({ kind: 'unicode', native: VARIATION }, visibility)).toBe(false);
    expect(nativeForEmojiRecord(nimblePickerData.emojis['+1'], 1)).toBe('👍');
    expect(nativeForEmojiRecord(nimblePickerData.emojis['+1'], 2)).toBe(SKIN);
  });

  it('separates local ids and remote domains with the same shortcode', () => {
    installEmojiMutesForTests({
      revision: '3',
      emoji_mutes: [
        rule({ kind: 'custom', scope: 'local', custom_emoji_id: '11', shortcode: 'blob' }, { hide_in_picker: true }),
        rule({ kind: 'custom', scope: 'remote', domain: 'a.example', shortcode: 'blob' }, { hide_in_picker: true }),
      ],
    });

    const visibility = emojiPickerVisibility();

    expect(emojiPickerCandidateHidden({ kind: 'custom', scope: 'local', custom_emoji_id: '11', shortcode: 'blob' }, visibility)).toBe(true);
    expect(emojiPickerCandidateHidden({ kind: 'custom', scope: 'local', custom_emoji_id: '22', shortcode: 'blob' }, visibility)).toBe(false);
    expect(emojiPickerCandidateHidden({ kind: 'custom', scope: 'local', shortcode: 'blob' }, visibility)).toBe(false);
    expect(emojiPickerCandidateHidden({ kind: 'custom', scope: 'remote', domain: 'a.example', shortcode: 'blob' }, visibility)).toBe(true);
    expect(emojiPickerCandidateHidden({ kind: 'custom', scope: 'remote', domain: 'b.example', shortcode: 'blob' }, visibility)).toBe(false);
    expect(unresolvedPickerCandidates().some(entry => entry.startsWith('reference:'))).toBe(true);
  });

  it('filters stock before render without rewriting the saved document', () => {
    const light = stockItem('light', SKIN, { label: 'Light' });
    const plain = stockItem('plain', '👍', { label: 'Plain' });
    const again = stockItem('again', SKIN, { label: 'Again' });
    const local = customItem('local', '11', 'blob');
    const other = customItem('other', '22', 'blob');
    const source = {
      categories: [
        {
          id: 'tones',
          name: 'Tones',
          heading: { text: 'T', image: { src: light.image.src, alt: SKIN } },
          items: [light, plain],
        },
        {
          id: 'more',
          name: 'More',
          heading: { text: 'M' },
          items: [again, local, other],
        },
      ],
    };
    Object.freeze(source);
    source.categories.forEach(category => Object.freeze(category));

    installEmojiMutesForTests({
      revision: '8',
      emoji_mutes: [
        rule({ kind: 'unicode', native: SKIN }, { hide_in_picker: true, hide_reactions: false }),
        rule({ kind: 'custom', scope: 'local', custom_emoji_id: '11', shortcode: 'blob' }, { hide_in_picker: true }),
      ],
    });

    const projected = projectEmojiStockForPicker(source);

    expect(projected.held).toBe(false);
    expect(projected.stock).not.toBe(source);
    expect(source.categories[0].items.map(item => item.key)).toEqual(['light', 'plain']);
    expect(projected.stock.categories[0].items.map(item => item.key)).toEqual(['plain']);
    expect(projected.stock.categories[0].heading).toEqual({ text: 'Tones' });
    expect(projected.stock.categories[0].heading.image).toBeUndefined();
    expect(projected.stock.categories[1].items.map(item => item.key)).toEqual(['other']);
    expect(projected.stock.categories[1].heading).toEqual({ text: 'M' });
    expect(projectEmojiStockForPicker(source).stock).toBe(projected.stock);
  });

  it('drops a muted representative without promoting another emoji', () => {
    const plain = stockItem('plain', '👍');
    const kept = stockItem('kept', '❤️');
    const source = {
      categories: [{
        id: 'only',
        name: 'Only muted',
        heading: { text: 'O', image: { src: plain.image.src, alt: '👍' } },
        items: [plain, kept],
      }],
    };

    installEmojiMutesForTests({
      revision: '1',
      emoji_mutes: [rule({ kind: 'unicode', native: '👍' }, { hide_in_picker: true })],
    });

    const projected = projectEmojiStockForPicker(source);

    expect(projected.stock.categories[0].items.map(entry => entry.key)).toEqual(['kept']);
    expect(projected.stock.categories[0].heading).toEqual({ text: 'Only muted' });
    expect(JSON.stringify(projected.stock)).not.toContain(plain.image.src);
  });

  it('rebuilds the standard candidate list for the active skin and leaves Nimble data intact', () => {
    const people = nimblePickerData.categories.find(category => category.id === 'people');
    const before = people.emojis.slice();
    const custom = [
      { id: 'blob', short_names: ['blob'], custom: true, custom_emoji_id: '11', imageUrl: '/11.png' },
      { id: 'blob', short_names: ['blob'], custom: true, custom_emoji_id: '22', imageUrl: '/22.png' },
      { id: 'no-id', short_names: ['no-id'], custom: true, imageUrl: '/noid.png' },
    ];

    installEmojiMutesForTests({
      revision: '6',
      emoji_mutes: [
        rule({ kind: 'unicode', native: '👍' }, { hide_in_picker: true }),
        rule({ kind: 'custom', scope: 'local', custom_emoji_id: '11', shortcode: 'blob' }, { hide_in_picker: true }),
      ],
    });

    const visibility = emojiPickerVisibility();
    const props = { skin: 1, custom, recent: ['+1', 'heart', 'blob', 'no-id', 'missing_recent'] };
    const projected = projectStandardPickerProps(props, visibility, nimblePickerData);

    expect(people.emojis).toEqual(before);
    expect(projected.data).not.toBe(nimblePickerData);
    expect(projected.data.emojis).toBe(nimblePickerData.emojis);
    const visibleIds = projected.data.categories.flatMap(category => category.emojis);

    expect(visibleIds).not.toContain('+1');
    expect(visibleIds).toContain('heart');
    expect(visibleIds).toContain('grinning');
    expect(projected.custom.map(emoji => emoji.custom_emoji_id || emoji.id)).toEqual(['22', 'no-id']);
    expect(projected.recent).toEqual(['heart', 'blob', 'no-id', 'missing_recent']);
    expect(projected.emojisToShowFilter(nimblePickerData.emojis['+1'])).toBe(false);
    expect(projected.emojisToShowFilter(nimblePickerData.emojis.heart)).toBe(true);
    expect(unresolvedPickerCandidates()).toEqual(expect.arrayContaining(['custom:no-id', 'recent:missing_recent']));

    const skinned = projectStandardPickerProps({ ...props, skin: 2 }, visibility, nimblePickerData);

    expect(skinned.data.categories.flatMap(category => category.emojis)).toContain('+1');
    expect(skinned.emojisToShowFilter(nimblePickerData.emojis['+1'])).toBe(true);

    const again = projectStandardPickerProps(props, visibility, nimblePickerData);

    expect(again.data).toBe(projected.data);
    expect(again.custom).toBe(projected.custom);
    expect(again.recent).toBe(projected.recent);
    expect(again.emojisToShowFilter).toBe(projected.emojisToShowFilter);
  });

  it('accepts immutable rules and ignores a stale stream until the next document', async () => {
    installEmojiMutesForTests({
      revision: '1',
      emoji_mutes: [
        rule(ImmutableMap({ kind: 'unicode', native: '👍' }), ImmutableMap({ hide_in_picker: true })),
      ],
    });

    expect(emojiPickerCandidateHidden({ kind: 'unicode', native: '👍' })).toBe(true);

    const pending = noteEmojiMutesChanged({ revision: '2' });

    expect(emojiPickerVisibility().ready).toBe(false);
    expect(emojiPickerCandidateHidden({ kind: 'unicode', native: '👍' })).toBe(true);
    pending.catch(() => {});
  });

  it('records an unresolved candidate without hiding a different emoji', () => {
    noteUnresolvedPickerCandidate('custom', 'shortcode-only');
    expect(unresolvedPickerCandidates()).toContain('custom:shortcode-only');
  });
});

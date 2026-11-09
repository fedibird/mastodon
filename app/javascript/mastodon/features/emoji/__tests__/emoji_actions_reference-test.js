import {
  DEFAULT_MUTE_REPLACEMENT,
  normalizeReference,
  referencesEqual,
  findMuteForReference,
  referenceFromReaction,
  referenceFromStockItem,
  detailPathForReference,
  datasetFromReference,
  referenceFromDataset,
} from '../emoji_actions/reference';

describe('emoji actions references', () => {
  it('normalizes unicode, local, and remote identities without mixing domains', () => {
    expect(normalizeReference({ kind: 'unicode', native: '👍🏽' })).toEqual({ kind: 'unicode', native: '👍🏽' });
    expect(normalizeReference({ kind: 'custom', custom_emoji_id: 12, shortcode: 'blob' })).toEqual({
      kind: 'custom',
      scope: 'local',
      custom_emoji_id: '12',
      shortcode: 'blob',
    });
    expect(normalizeReference({ kind: 'custom', scope: 'remote', domain: 'a.example', shortcode: 'blob' })).toEqual({
      kind: 'custom',
      scope: 'remote',
      domain: 'a.example',
      shortcode: 'blob',
    });
    expect(referencesEqual(
      { kind: 'custom', scope: 'remote', domain: 'a.example', shortcode: 'blob' },
      { kind: 'custom', scope: 'remote', domain: 'b.example', shortcode: 'blob' },
    )).toBe(false);
  });

  it('finds a mute by identity and keeps the default replacement constant', () => {
    const rules = [
      { id: '1', emoji: { kind: 'unicode', native: '😀' } },
      { id: '2', emoji: { kind: 'custom', scope: 'local', custom_emoji_id: '9', shortcode: 'blob' } },
    ];

    expect(findMuteForReference(rules, { kind: 'custom', scope: 'local', custom_emoji_id: '9' }).id).toBe('2');
    expect(DEFAULT_MUTE_REPLACEMENT).toBe('［絵文字］');
  });

  it('builds reaction and stock references and detail paths', () => {
    expect(referenceFromReaction({
      name: 'blob',
      parts: [{ identity: { kind: 'custom', scope: 'remote', domain: 'x.example', shortcode: 'blob' } }],
    })).toEqual({ kind: 'custom', scope: 'remote', domain: 'x.example', shortcode: 'blob' });

    expect(referenceFromStockItem({
      reference: { kind: 'unicode', native: '😀' },
      selection: { id: 'grinning', native: '😀' },
    })).toEqual({ kind: 'unicode', native: '😀' });

    expect(detailPathForReference({ kind: 'unicode', native: '👍🏽' })).toBe(`/emoji_detail/unicode/${encodeURIComponent('👍🏽')}`);
  });

  it('round-trips dataset attributes used by hosts', () => {
    const reference = { kind: 'custom', scope: 'local', custom_emoji_id: '5', shortcode: 'cat' };
    const dataset = datasetFromReference(reference);

    expect(referenceFromDataset(dataset)).toEqual(reference);
  });
});

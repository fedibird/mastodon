import { fromJS } from 'immutable';
import {
  DEFAULT_MUTE_REPLACEMENT,
  normalizeReference,
  referencesEqual,
  findMuteForReference,
  referenceFromReaction,
  accountIdFromStatus,
  representativeReactionPart,
  referenceFromStockItem,
  referenceFromPickerEmoji,
  detailPathForReference,
  copyTextForReference,
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

  it('matches local identity only when both sides have a stable database id', () => {
    expect(referencesEqual(
      { kind: 'custom', scope: 'local', custom_emoji_id: '11', shortcode: 'blob' },
      { kind: 'custom', scope: 'local', custom_emoji_id: '11', shortcode: 'blob' },
    )).toBe(true);

    expect(referencesEqual(
      { kind: 'custom', scope: 'local', custom_emoji_id: '11', shortcode: 'blob' },
      { kind: 'custom', scope: 'local', custom_emoji_id: '22', shortcode: 'blob' },
    )).toBe(false);

    expect(referencesEqual(
      { kind: 'custom', scope: 'local', custom_emoji_id: '11', shortcode: 'blob' },
      { kind: 'custom', scope: 'local', shortcode: 'blob' },
    )).toBe(false);

    expect(findMuteForReference([
      { id: '1', emoji: { kind: 'custom', scope: 'local', custom_emoji_id: '11', shortcode: 'blob' } },
    ], { kind: 'custom', scope: 'local', shortcode: 'blob' })).toBeNull();

    expect(findMuteForReference([
      { id: '1', emoji: { kind: 'custom', scope: 'local', custom_emoji_id: '11', shortcode: 'blob' } },
    ], { kind: 'custom', scope: 'local', custom_emoji_id: '22', shortcode: 'blob' })).toBeNull();

    expect(DEFAULT_MUTE_REPLACEMENT).toBe('［絵文字］');
  });

  it('does not rewrite unresolved custom identity as a resolvable local id', () => {
    expect(normalizeReference({
      kind: 'custom',
      scope: 'unresolved',
      custom_emoji_id: '99',
    })).toBeNull();

    expect(referenceFromReaction({
      name: 'gone',
      parts: [{
        identity: { kind: 'custom', scope: 'unresolved', custom_emoji_id: '99' },
        custom_emoji_id: '99',
      }],
    })).toBeNull();

    expect(referenceFromReaction({
      name: 'blob',
      parts: [{
        identity: { kind: 'custom', scope: 'unresolved', custom_emoji_id: '99' },
        custom_emoji_id: '99',
        domain: 'other.example',
        shortcode: 'blob',
      }],
    })).toEqual({
      kind: 'custom',
      scope: 'remote',
      domain: 'other.example',
      shortcode: 'blob',
    });
  });

  it('reads account id from expanded status.account maps', () => {
    expect(accountIdFromStatus(fromJS({ account: 'acct-1' }))).toBe('acct-1');
    expect(accountIdFromStatus(fromJS({ account: { id: '42', acct: 'alice' } }))).toBe('42');
    expect(accountIdFromStatus(fromJS({ account: null }))).toBeNull();
  });

  it('uses the display representative part, not created_at order', () => {
    const group = {
      name: 'blob',
      domain: null,
      url: 'https://cdn.example/local.png',
      parts: [
        {
          identity: { kind: 'custom', scope: 'remote', domain: 'other.example', shortcode: 'blob' },
          custom_emoji_id: '22',
          domain: 'other.example',
          url: 'https://cdn.example/remote.png',
        },
        {
          identity: { kind: 'custom', scope: 'local', custom_emoji_id: '11', shortcode: 'blob' },
          custom_emoji_id: '11',
          domain: null,
          url: 'https://cdn.example/local.png',
        },
      ],
    };

    expect(representativeReactionPart(group).custom_emoji_id).toBe('11');
    expect(referenceFromReaction(group)).toEqual({
      kind: 'custom',
      scope: 'local',
      custom_emoji_id: '11',
      shortcode: 'blob',
    });

    const reversedDisplay = {
      name: 'blob',
      domain: 'other.example',
      url: 'https://cdn.example/remote.png',
      parts: [
        {
          identity: { kind: 'custom', scope: 'local', custom_emoji_id: '11', shortcode: 'blob' },
          custom_emoji_id: '11',
          url: 'https://cdn.example/local.png',
        },
        {
          identity: { kind: 'custom', scope: 'remote', domain: 'other.example', shortcode: 'blob' },
          custom_emoji_id: '22',
          domain: 'other.example',
          url: 'https://cdn.example/remote.png',
        },
      ],
    };

    expect(referenceFromReaction(reversedDisplay)).toEqual({
      kind: 'custom',
      scope: 'remote',
      domain: 'other.example',
      shortcode: 'blob',
    });
  });

  it('builds stock and picker references and detail paths', () => {
    expect(referenceFromStockItem({
      reference: { kind: 'unicode', native: '😀' },
      selection: { id: 'grinning', native: '😀' },
    })).toEqual({ kind: 'unicode', native: '😀' });

    expect(referenceFromPickerEmoji({ id: 'thumbsup', native: '👍🏽', skin: 4 })).toEqual({
      kind: 'unicode',
      native: '👍🏽',
    });

    expect(referenceFromPickerEmoji({
      id: 'blob',
      custom: true,
      colons: ':blob:',
      custom_emoji_id: '9',
    })).toEqual({
      kind: 'custom',
      scope: 'local',
      custom_emoji_id: '9',
      shortcode: 'blob',
    });

    expect(detailPathForReference({ kind: 'unicode', native: '👍🏽' })).toBe(`/emoji_detail/unicode/${encodeURIComponent('👍🏽')}`);
  });

  it('round-trips dataset attributes used by hosts', () => {
    const reference = { kind: 'custom', scope: 'local', custom_emoji_id: '5', shortcode: 'cat' };
    const dataset = datasetFromReference(reference);

    expect(referenceFromDataset(dataset)).toEqual(reference);
  });

  it('builds clipboard text for unicode and local shortcodes only', () => {
    expect(copyTextForReference({ kind: 'unicode', native: '👩‍👩‍👧‍👦' })).toBe('👩‍👩‍👧‍👦');
    expect(copyTextForReference({ kind: 'custom', scope: 'local', custom_emoji_id: '9', shortcode: 'blob' })).toBe(':blob:');
    expect(copyTextForReference({ kind: 'custom', scope: 'local', custom_emoji_id: '9' })).toBeNull();
    expect(copyTextForReference(
      { kind: 'custom', scope: 'local', custom_emoji_id: '9' },
      { reference: { kind: 'custom', scope: 'local', custom_emoji_id: '9', shortcode: 'blob' } },
    )).toBe(':blob:');
    expect(copyTextForReference({ kind: 'custom', scope: 'remote', domain: 'a.example', shortcode: 'blob' })).toBeNull();
  });
});

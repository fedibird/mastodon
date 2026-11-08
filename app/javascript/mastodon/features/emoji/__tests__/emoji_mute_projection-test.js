import { partHidden, projectGroups, projectStreamPayload, snapshotIsFresh, unicodeHidden } from '../emoji_mute_projection';

const unicodeMute = native => ({
  effects: { hide_reactions: true, replace_in_text: true },
  emoji: { kind: 'unicode', native },
});

const localMute = id => ({
  effects: { hide_reactions: true },
  emoji: { kind: 'custom', scope: 'local', custom_emoji_id: id, shortcode: 'blob' },
});

const remoteMute = (domain, shortcode) => ({
  effects: { hide_reactions: true },
  emoji: { kind: 'custom', scope: 'remote', domain, shortcode },
});

describe('emoji mute projection', () => {
  it('treats variation selectors as different unicode identities', () => {
    const mutes = [unicodeMute('‼')];

    expect(unicodeHidden('‼', mutes)).toBe(true);
    expect(unicodeHidden('‼️', mutes)).toBe(false);
    expect(partHidden({ native: '‼️', account_ids: ['1'] }, mutes)).toBe(false);
  });

  it('removes only the muted identity from a mixed name group', () => {
    const groups = [{
      name: 'blob',
      count: 3,
      account_ids: ['1', '2', '3'],
      domain: 'a.example',
      parts: [
        { custom_emoji_id: '10', shortcode: 'blob', account_ids: ['1', '2'], url: 'https://local/blob' },
        { custom_emoji_id: '11', shortcode: 'blob', domain: 'remote.example', account_ids: ['3'], url: 'https://remote/blob' },
      ],
    }];

    const projected = projectGroups(groups, [remoteMute('remote.example', 'blob')]);

    expect(projected.count).toBe(2);
    expect(projected.groups[0].account_ids).toEqual(['1', '2']);
    expect(projected.groups[0].domain).toBeUndefined();
    expect(projected.groups[0].url).toBe('https://local/blob');
    expect(projected.groups[0].parts).toHaveLength(1);
  });

  it('does not hide a custom group that has no identity parts', () => {
    const groups = [{ name: 'blob', count: 2, account_ids: ['1', '2'], domain: 'remote.example' }];

    expect(projectGroups(groups, [remoteMute('remote.example', 'blob'), localMute('10')]).groups).toEqual(groups);
  });

  it('drops a fully hidden stream payload and ignores a stale snapshot', () => {
    const payload = {
      status_id: '9',
      name: '👍',
      count: 1,
      account_ids: ['4'],
      parts: [{ native: '👍', account_ids: ['4'] }],
    };

    expect(projectStreamPayload(payload, [unicodeMute('👍')])).toBeNull();
    expect(snapshotIsFresh(2, 4)).toBe(false);
    expect(snapshotIsFresh(4, 4)).toBe(true);
    expect(snapshotIsFresh(null, 4)).toBe(true);
  });
});

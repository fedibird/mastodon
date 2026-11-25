import { COMPOSER_DRAFT_RECOVERY_STORAGE_KEY, composerDraftRecoveryEnabled, composerDraftsActive, postDraftSyncEnabled } from '../feature';

describe('composer draft recovery flag', () => {
  it('stays off unless the browser opts in', () => {
    const storage = {
      value: null,
      getItem () {
        return this.value;
      },
    };

    expect(composerDraftRecoveryEnabled(storage)).toBe(false);
    storage.value = '1';
    expect(composerDraftRecoveryEnabled(storage)).toBe(true);
    expect(composerDraftRecoveryEnabled({
      getItem () {
        throw new Error('denied');
      },
    })).toBe(false);
    expect(COMPOSER_DRAFT_RECOVERY_STORAGE_KEY).toBe('fedibird:composer-draft-recovery');
  });

  it('keeps server sync off unless this session was admitted', () => {
    expect(postDraftSyncEnabled(undefined)).toBe(false);
    expect(postDraftSyncEnabled({})).toBe(false);
    expect(postDraftSyncEnabled({ post_draft_sync: { enabled: false, reason: 'disabled' } })).toBe(false);
    expect(postDraftSyncEnabled({ post_draft_sync: { enabled: true } })).toBe(true);
    expect(composerDraftsActive({ getItem: () => null }, {})).toBe(false);
    expect(composerDraftsActive({ getItem: () => null }, { post_draft_sync: { enabled: true } })).toBe(true);
  });
});

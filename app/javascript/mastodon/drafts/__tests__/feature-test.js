import { COMPOSER_DRAFT_RECOVERY_STORAGE_KEY, composerDraftRecoveryEnabled } from '../feature';

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
});

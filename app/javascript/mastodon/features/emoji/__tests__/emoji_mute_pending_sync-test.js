import {
  notePendingMuteSync,
  clearPendingMuteSync,
  getPendingMuteSync,
  muteFromPendingOrStore,
  resetPendingMuteSyncForTests,
} from '../emoji_actions/pending_sync';
import {
  captureMenuSession,
  canApplyMutationToOpenMenu,
  isCurrentMenuSession,
} from '../emoji_actions/menu_session';
import { createMuteAndSync, deleteMuteAndSync, retryMuteSync } from '../emoji_actions/mute_follow_up';

describe('pending mute sync across menu lifecycle', () => {
  const referenceA = { kind: 'unicode', native: '😀' };
  const referenceB = { kind: 'unicode', native: '❤️' };
  const savedMute = { id: '10', revision: '4', emoji: referenceA };

  beforeEach(() => {
    resetPendingMuteSyncForTests();
  });

  it('keeps pending sync after close-shaped clear of UI fields', () => {
    notePendingMuteSync({
      reference: referenceA,
      revision: '4',
      mute: savedMute,
      operation: 'mute',
      syncError: Object.assign(new Error('offline'), { status: 503 }),
    });

    expect(getPendingMuteSync(referenceA).revision).toBe('4');
    expect(muteFromPendingOrStore(referenceA, null)).toEqual(savedMute);
    expect(muteFromPendingOrStore(referenceA, { id: 'stale' }).id).toBe('10');
  });

  it('POST 201 → sync 503 → reopen uses pending mute without needing store', async () => {
    const createMute = jest.fn(() => Promise.resolve({ revision: '4', emoji_mute: savedMute }));
    const syncMutes = jest.fn()
      .mockRejectedValueOnce(Object.assign(new Error('offline'), { status: 503 }))
      .mockResolvedValueOnce(undefined);

    const first = await createMuteAndSync({ createMute, syncMutes, reference: referenceA });
    expect(first.synced).toBe(false);

    notePendingMuteSync({
      reference: referenceA,
      revision: first.response.revision,
      mute: savedMute,
      operation: 'mute',
      syncError: first.syncError,
    });

    // Simulate menu close wiping local pendingSyncRevision, then reopen.
    expect(muteFromPendingOrStore(referenceA, null)).toEqual(savedMute);

    await retryMuteSync({ syncMutes, revision: getPendingMuteSync(referenceA).revision });
    clearPendingMuteSync(referenceA);

    expect(createMute).toHaveBeenCalledTimes(1);
    expect(syncMutes).toHaveBeenCalledTimes(2);
    expect(getPendingMuteSync(referenceA)).toBeNull();
  });

  it('DELETE success → sync 503 → reopen treats mute as removed', async () => {
    const deleteMute = jest.fn(() => Promise.resolve({ revision: '5' }));
    const syncMutes = jest.fn(() => Promise.reject(Object.assign(new Error('offline'), { status: 503 })));

    const result = await deleteMuteAndSync({
      deleteMute,
      syncMutes,
      mute: savedMute,
    });

    notePendingMuteSync({
      reference: referenceA,
      revision: result.response.revision,
      mute: null,
      operation: 'unmute',
      syncError: result.syncError,
    });

    expect(muteFromPendingOrStore(referenceA, savedMute)).toBeNull();
    expect(deleteMute).toHaveBeenCalledTimes(1);
  });

  it('does not apply A mutation UI to B session', () => {
    const sessionA = captureMenuSession(1, referenceA);
    expect(isCurrentMenuSession(sessionA, { loadGeneration: 1, reference: referenceA })).toBe(true);
    expect(isCurrentMenuSession(sessionA, { loadGeneration: 2, reference: referenceB })).toBe(false);
    expect(isCurrentMenuSession(sessionA, { loadGeneration: 1, reference: referenceB })).toBe(false);
  });

  it('applies A completion to a reopened A menu even when generation advanced', () => {
    const sessionA = captureMenuSession(1, referenceA);
    // Generation-strict check fails after close→reopen.
    expect(isCurrentMenuSession(sessionA, { loadGeneration: 2, reference: referenceA })).toBe(false);
    // Identity-based apply still allows the reopened A menu to clear busy.
    expect(canApplyMutationToOpenMenu(sessionA, { reference: referenceA })).toBe(true);
    expect(canApplyMutationToOpenMenu(sessionA, { reference: referenceB })).toBe(false);
    expect(canApplyMutationToOpenMenu(sessionA, { reference: null })).toBe(false);
  });
});

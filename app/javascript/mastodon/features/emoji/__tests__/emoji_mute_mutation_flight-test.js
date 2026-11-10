import {
  beginMuteMutation,
  endMuteMutation,
  isMuteMutationInFlight,
  resetMuteMutationFlightsForTests,
} from '../emoji_actions/mutation_flight';
import { createMuteAndSync } from '../emoji_actions/mute_follow_up';
import { resetPendingMuteSyncForTests, getPendingMuteSync } from '../emoji_actions/pending_sync';

describe('mute mutation in-flight across menu lifecycle', () => {
  const referenceA = { kind: 'unicode', native: '😀' };
  const referenceB = { kind: 'unicode', native: '❤️' };

  beforeEach(() => {
    resetMuteMutationFlightsForTests();
    resetPendingMuteSyncForTests();
  });

  it('blocks a second mute begin for the same identity while the first is open', () => {
    expect(beginMuteMutation(referenceA, 'mute')).toBe(true);
    expect(beginMuteMutation(referenceA, 'mute')).toBe(false);
    expect(isMuteMutationInFlight(referenceA)).toBe(true);
    expect(beginMuteMutation(referenceB, 'mute')).toBe(true);
    endMuteMutation(referenceA);
    expect(isMuteMutationInFlight(referenceA)).toBe(false);
    expect(beginMuteMutation(referenceA, 'mute')).toBe(true);
  });

  it('keeps the in-flight lock through close/reopen until POST resolves', async () => {
    let resolvePost;
    const createMute = jest.fn(() => new Promise(resolve => {
      resolvePost = resolve;
    }));
    const syncMutes = jest.fn(() => Promise.resolve());

    expect(beginMuteMutation(referenceA, 'mute')).toBe(true);

    const pending = createMuteAndSync({
      createMute,
      syncMutes,
      reference: referenceA,
    });

    // Menu close/reopen still sees the flight for A.
    expect(isMuteMutationInFlight(referenceA)).toBe(true);
    expect(beginMuteMutation(referenceA, 'mute')).toBe(false);

    resolvePost({
      revision: '9',
      emoji_mute: { id: '1', revision: '9', emoji: referenceA },
    });
    await pending;
    endMuteMutation(referenceA);

    expect(isMuteMutationInFlight(referenceA)).toBe(false);
    expect(createMute).toHaveBeenCalledTimes(1);
  });

  it('allows a normal retry after a failed write clears the flight', async () => {
    expect(beginMuteMutation(referenceA, 'mute')).toBe(true);

    await expect(createMuteAndSync({
      createMute: () => Promise.reject(Object.assign(new Error('boom'), { status: 500 })),
      syncMutes: jest.fn(),
      reference: referenceA,
    })).rejects.toMatchObject({ status: 500 });

    endMuteMutation(referenceA);
    expect(getPendingMuteSync(referenceA)).toBeNull();
    expect(beginMuteMutation(referenceA, 'mute')).toBe(true);
  });
});

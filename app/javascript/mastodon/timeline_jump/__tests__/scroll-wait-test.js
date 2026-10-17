import { createJumpScrollWait } from '../scroll_wait';

describe('jump scroll wait', () => {
  it('resolves once from the seek settle and ignores a later notice', async () => {
    const wait = createJumpScrollWait();
    const seen = [];
    const pending = wait.arm('seek-1').then(result => {
      seen.push(result.reason);
    });

    expect(wait.notify('seek-1', { scrollStatus: 'loaded', reason: 'loaded' })).toBe(true);
    expect(wait.notify('seek-1', { scrollStatus: 'filtered', reason: 'filtered' })).toBe(false);
    await pending;

    expect(seen).toEqual(['loaded']);
    expect(wait.pending()).toBe(false);
  });

  it('does not restore after close or unmount cancels the wait', async () => {
    const wait = createJumpScrollWait();
    let restored = 0;
    const pending = wait.arm('seek-1').then(result => {
      if (result.reason === 'filtered' || result.reason === 'not_loaded') {
        restored += 1;
      }

      return result;
    });

    expect(wait.cancel({ scrollStatus: 'stale', reason: 'stale' })).toBe(true);
    expect(wait.notify('seek-1', { scrollStatus: 'filtered', reason: 'filtered' })).toBe(false);
    expect(wait.cancel()).toBe(false);

    await expect(pending).resolves.toEqual({ scrollStatus: 'stale', reason: 'stale' });
    expect(restored).toBe(0);
  });

  it('does not accept a settle for a different seek session', async () => {
    const wait = createJumpScrollWait();
    let settled = false;
    const pending = wait.arm('seek-2').then(() => {
      settled = true;
    });

    expect(wait.notify('seek-1', { scrollStatus: 'loaded', reason: 'loaded' })).toBe(false);
    expect(settled).toBe(false);
    wait.cancel({ scrollStatus: 'stale', reason: 'stale' });
    await pending;
    expect(settled).toBe(true);
  });
});
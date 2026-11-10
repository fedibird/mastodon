import {
  createMuteAndSync,
  deleteMuteAndSync,
  retryMuteSync,
} from '../emoji_actions/mute_follow_up';

describe('mute follow-up sync separation', () => {
  const reference = { kind: 'unicode', native: '😀' };
  const savedMute = {
    id: '10',
    revision: '4',
    emoji: reference,
  };

  it('treats POST 201 + sync 503 as saved with syncError (no CRUD failure)', async () => {
    const createMute = jest.fn(() => Promise.resolve({
      revision: '4',
      emoji_mute: savedMute,
    }));
    const syncMutes = jest.fn(() => Promise.reject(Object.assign(new Error('offline'), { status: 503 })));

    const result = await createMuteAndSync({ createMute, syncMutes, reference });

    expect(createMute).toHaveBeenCalledTimes(1);
    expect(syncMutes).toHaveBeenCalledWith({ changed: { revision: '4' } });
    expect(result).toEqual({
      saved: true,
      synced: false,
      response: { revision: '4', emoji_mute: savedMute },
      syncError: expect.objectContaining({ status: 503 }),
    });
  });

  it('treats DELETE 200 + sync 503 as saved with syncError', async () => {
    const deleteMute = jest.fn(() => Promise.resolve({ revision: '5' }));
    const syncMutes = jest.fn(() => Promise.reject(Object.assign(new Error('offline'), { status: 503 })));

    const result = await deleteMuteAndSync({
      deleteMute,
      syncMutes,
      mute: savedMute,
    });

    expect(deleteMute).toHaveBeenCalledWith('10', '4');
    expect(result.saved).toBe(true);
    expect(result.synced).toBe(false);
    expect(result.syncError.status).toBe(503);
  });

  it('retries sync only without re-running create/delete', async () => {
    const syncMutes = jest.fn()
      .mockRejectedValueOnce(Object.assign(new Error('offline'), { status: 503 }))
      .mockResolvedValueOnce(undefined);

    const first = await createMuteAndSync({
      createMute: jest.fn(() => Promise.resolve({ revision: '4', emoji_mute: savedMute })),
      syncMutes,
      reference,
    });
    expect(first.synced).toBe(false);

    await retryMuteSync({ syncMutes, revision: first.response.revision });
    expect(syncMutes).toHaveBeenCalledTimes(2);
    expect(syncMutes.mock.calls[1][0]).toEqual({ changed: { revision: '4' } });
  });

  it('accepts a later stream-style sync with the same revision', async () => {
    const syncMutes = jest.fn(() => Promise.resolve({ revision: '4' }));

    await retryMuteSync({ syncMutes, revision: '4' });
    expect(syncMutes).toHaveBeenCalledWith({ changed: { revision: '4' } });
  });
});

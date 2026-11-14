import { compareAndPut, createIndexedDbDraftBackend, openComposerDraftDatabase } from '../storage';

function fakeDatabase () {
  const rows = new Map();

  const open = () => {
    const request = {};
    const db = {
      objectStoreNames: {
        contains: () => true,
      },
      transaction () {
        const tx = {
          completed: false,
        };
        const finish = () => {
          if (tx.completed) {
            return;
          }

          tx.completed = true;

          if (tx.oncomplete) {
            tx.oncomplete();
          }
        };
        const store = {
          get (key) {
            const req = {};

            Promise.resolve().then(() => {
              req.result = rows.get(JSON.stringify(key));

              if (req.onsuccess) {
                req.onsuccess();
              }

              return Promise.resolve().then(() => {
                if (!tx.pending) {
                  finish();
                }
              });
            }).catch(() => undefined);

            return req;
          },
          put (record) {
            tx.pending = true;
            rows.set(JSON.stringify([record.account_id, record.client_draft_uuid]), record);

            const req = {};

            Promise.resolve().then(() => {
              if (req.onsuccess) {
                req.onsuccess();
              }

              finish();
            }).catch(() => undefined);

            return req;
          },
          delete (key) {
            tx.pending = true;
            rows.delete(JSON.stringify(key));
            Promise.resolve().then(() => finish()).catch(() => undefined);

            return {};
          },
          index () {
            return {
              getAll (accountId) {
                const req = {};

                Promise.resolve().then(() => {
                  const matched = [];

                  rows.forEach((row) => {
                    if (row.account_id === accountId) {
                      matched.push(row);
                    }
                  });
                  req.result = matched;

                  if (req.onsuccess) {
                    req.onsuccess();
                  }
                }).catch(() => undefined);

                return req;
              },
            };
          },
        };

        tx.objectStore = () => store;

        return tx;
      },
    };

    Promise.resolve().then(() => {
      request.result = db;

      if (request.onsuccess) {
        request.onsuccess();
      }
    }).catch(() => undefined);

    return request;
  };

  return { open, rows };
}

describe('composer draft storage', () => {
  it('keeps the current revision when the content is unchanged and refuses a stale base revision', () => {
    const current = { account_id: '42', client_draft_uuid: 'draft-1', schema_version: 1, revision: 2, content_hash: 'same' };
    const same = { ...current, saved_at: 'later' };

    expect(compareAndPut(current, same, { baseRevision: 1 }).status).toBe('unchanged');
    expect(compareAndPut(current, { ...current, content_hash: 'next' }, { baseRevision: 1 }).status).toBe('conflict');
    expect(compareAndPut(current, { ...current, content_hash: 'next' }, { baseRevision: 2 }).record.revision).toBe(3);
    expect(compareAndPut({ ...current, account_id: '7' }, same, { baseRevision: 2 }).reason).toBe('account_mismatch');
  });

  it('stores and lists only the requested account', async () => {
    const factory = fakeDatabase();
    const backend = createIndexedDbDraftBackend({
      openDatabase: () => openComposerDraftDatabase(factory),
    });
    const saved = await backend.writeDraft({
      schema_version: 1,
      account_id: '42',
      client_draft_uuid: 'draft-1',
      content_hash: 'one',
      input: { text: 'one' },
    }, { baseRevision: 0, stillCurrent: () => true, isDiscarded: () => false });

    await backend.writeDraft({
      schema_version: 1,
      account_id: '7',
      client_draft_uuid: 'draft-2',
      content_hash: 'two',
      input: { text: 'two' },
    }, { baseRevision: 0, stillCurrent: () => true, isDiscarded: () => false });

    expect(saved.status).toBe('saved');
    expect((await backend.listDrafts('42')).map(item => item.input.text)).toEqual(['one']);
    expect((await backend.readDraft('42', 'draft-1')).revision).toBe(1);
  });

  it('does not write a snapshot that went stale before commit', async () => {
    const factory = fakeDatabase();
    const backend = createIndexedDbDraftBackend({
      openDatabase: () => openComposerDraftDatabase(factory),
    });
    const result = await backend.writeDraft({
      schema_version: 1,
      account_id: '42',
      client_draft_uuid: 'draft-1',
      content_hash: 'old',
      input: { text: 'old' },
    }, { baseRevision: 0, stillCurrent: () => false, isDiscarded: () => false });

    expect(result.status).toBe('stale');
    expect(await backend.readDraft('42', 'draft-1')).toBeUndefined();
  });

  it('deletes a put that is discarded before the write transaction finishes', async () => {
    const factory = fakeDatabase();
    const backend = createIndexedDbDraftBackend({
      openDatabase: () => openComposerDraftDatabase(factory),
    });
    let seen = 0;
    const result = await backend.writeDraft({
      schema_version: 1,
      account_id: '42',
      client_draft_uuid: 'draft-1',
      content_hash: 'one',
      input: { text: 'one' },
    }, {
      baseRevision: 0,
      stillCurrent: () => true,
      isDiscarded: () => {
        seen += 1;
        return seen >= 3;
      },
    });

    expect(result.status).toBe('discarded');
    expect(await backend.readDraft('42', 'draft-1')).toBeUndefined();
  });

  it('reports an unavailable database without throwing to the caller of open', async () => {
    await expect(openComposerDraftDatabase(null)).rejects.toMatchObject({ reason: 'unavailable' });
    await expect(openComposerDraftDatabase({
      open () {
        throw new Error('private mode');
      },
    })).rejects.toThrow('private mode');
  });
});

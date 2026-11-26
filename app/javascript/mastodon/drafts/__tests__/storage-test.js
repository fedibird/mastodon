import { compareAndDelete, compareAndPut, createIndexedDbDraftBackend, createIndexedDbSyncLedger, createMemoryDraftBackend, ensureComposerDraftStores, openComposerDraftDatabase, syncCursorRecord, transitionSyncCursor } from '../storage';

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

  it('deletes only the sent version and keeps a newer save from another writer', async () => {
    const current = { account_id: '42', client_draft_uuid: 'draft-1', schema_version: 1, revision: 2, content_hash: 'newer', input: { text: 'newer' } };

    expect(compareAndDelete(current, { contentHash: 'sent', revision: 1 }).status).toBe('kept');
    expect(compareAndDelete({ ...current, content_hash: 'sent', revision: 4 }, { contentHash: 'sent', revision: 1 }).status).toBe('deleted');
    expect(compareAndDelete(null, { contentHash: 'sent', revision: 1 }).status).toBe('missing');
    expect(compareAndDelete(
      { ...current, revision: 1, content_hash: 'old' },
      { contentHash: 'new', savedHash: 'old', revision: 1 },
    ).status).toBe('deleted');
    expect(compareAndDelete(
      { ...current, revision: 1, content_hash: 'other' },
      { contentHash: 'new', savedHash: 'old', revision: 1 },
    ).status).toBe('kept');
    expect(compareAndDelete(current, { contentHash: 'new', savedHash: 'old', revision: 1 }).status).toBe('kept');

    const factory = fakeDatabase();
    const indexed = createIndexedDbDraftBackend({
      openDatabase: () => openComposerDraftDatabase(factory),
    });
    const memory = createMemoryDraftBackend();

    await Promise.all([indexed, memory].map(async (backend) => {
      await backend.writeDraft({
        schema_version: 1,
        account_id: '42',
        client_draft_uuid: 'draft-1',
        content_hash: 'sent',
        input: { text: 'sent' },
      }, { baseRevision: 0, stillCurrent: () => true, isDiscarded: () => false });
      await backend.writeDraft({
        schema_version: 1,
        account_id: '42',
        client_draft_uuid: 'draft-1',
        content_hash: 'newer',
        input: { text: 'newer' },
      }, { baseRevision: 1, stillCurrent: () => true, isDiscarded: () => false });
      await backend.writeDraft({
        schema_version: 1,
        account_id: '42',
        client_draft_uuid: 'draft-2',
        content_hash: 'other',
        input: { text: 'other' },
      }, { baseRevision: 0, stillCurrent: () => true, isDiscarded: () => false });

      const kept = await backend.deleteDraft('42', 'draft-1', { contentHash: 'sent', revision: 1 });

      expect(kept.status).toBe('kept');
      expect((await backend.readDraft('42', 'draft-1')).input.text).toBe('newer');

      const removed = await backend.deleteDraft('42', 'draft-1', { contentHash: 'newer', revision: 2 });

      expect(removed.status).toBe('deleted');
      expect(await backend.readDraft('42', 'draft-1')).toBeFalsy();
      expect((await backend.readDraft('42', 'draft-2')).input.text).toBe('other');
    }));
  });

  it('round-trips conflict, tombstone, and send intent through the IndexedDB codec', async () => {
    const rows = new Map();
    const db = {
      transaction () {
        const tx = {};
        const store = {
          get (key) {
            const request = {};

            queueMicrotask(() => {
              request.result = rows.get(JSON.stringify(key));

              if (request.onsuccess) {
                request.onsuccess();
              }
            });

            return request;
          },
          put (record) {
            rows.set(JSON.stringify([record.account_id, record.client_uuid]), record);
            const request = {};

            queueMicrotask(() => {
              if (request.onsuccess) {
                request.onsuccess();
              }

              if (tx.oncomplete) {
                tx.oncomplete();
              }
            });

            return request;
          },
          index () {
            return {
              getAll () {
                const request = {};

                queueMicrotask(() => {
                  request.result = Array.from(rows.values());

                  if (request.onsuccess) {
                    request.onsuccess();
                  }
                });

                return request;
              },
            };
          },
        };

        tx.objectStore = () => store;

        return tx;
      },
    };
    const ledger = createIndexedDbSyncLedger({ openDatabase: () => Promise.resolve(db) });
    const cursor = syncCursorRecord({
      account_id: '42',
      client_uuid: '11111111-1111-4111-8111-111111111111',
      server_draft_id: '15',
      server_revision: 5,
      acked_hash: 'hash-a',
      acked_generation: 2,
      sync_generation: 8,
      conflict: true,
      conflict_revision: 6,
      delete_state: 'blocked',
      probe_hash: 'hash-probe',
      tombstone: true,
      intent_kind: 'patch',
      intent_hash: 'hash-a',
      intent_base_revision: 5,
      intent_expected_revision: 6,
      cursor_version: 1,
    });

    await ledger.write(cursor);

    expect(await ledger.read('42', cursor.client_uuid)).toEqual(cursor);
    expect((await ledger.list('42'))[0].sync_generation).toBe(8);
    expect((await ledger.list('42'))[0].delete_state).toBe('blocked');
    expect((await ledger.list('42'))[0].intent_expected_revision).toBe(6);
  });

  it('adds the sync store when an older draft database is opened', () => {
    const created = [];
    const names = new Set(['drafts']);
    const db = {
      objectStoreNames: {
        contains: name => names.has(name),
      },
      createObjectStore (name) {
        names.add(name);
        created.push(name);

        return { createIndex () {} };
      },
    };

    ensureComposerDraftStores(db);
    ensureComposerDraftStores(db);

    expect(created).toEqual(['sync']);
  });

  it('reports an unavailable database without throwing to the caller of open', async () => {
    await expect(openComposerDraftDatabase(null)).rejects.toMatchObject({ reason: 'unavailable' });
    await expect(openComposerDraftDatabase({
      open () {
        throw new Error('private mode');
      },
    })).rejects.toThrow('private mode');
  });

  it('keeps a discard on the revision it names and refuses a finish with no operation', () => {
    const current = syncCursorRecord({
      account_id: '42',
      client_uuid: 'draft-1',
      server_draft_id: '15',
      server_revision: 4,
      acked_hash: 'hash-a',
      cursor_version: 2,
    });
    const stale = transitionSyncCursor(current, {
      transition: 'discard',
      cursor_version: 1,
      delete_revision: 4,
      delete_draft_id: '15',
      tombstone: true,
    });
    const pinned = transitionSyncCursor(current, {
      transition: 'discard',
      cursor_version: 2,
      delete_revision: 4,
      delete_draft_id: '15',
      tombstone: true,
    });
    const missing = transitionSyncCursor(null, {
      transition: 'finish',
      operation_id: 'op',
      operation_owner: 'page',
      server_revision: 1,
    });

    expect(stale.record.delete_state).not.toBe('pending');
    expect(stale.record.server_revision).toBe(4);
    expect(pinned.accepted).toBe(true);
    expect(pinned.record.delete_state).toBe('pending');
    expect(pinned.record.delete_revision).toBe(4);
    expect(missing.accepted).toBe(false);
    expect(missing.reason).toBe('missing_operation');
  });

  it('updates a saved base only when it is still the base this page sent', async () => {
    const backend = createMemoryDraftBackend();
    const previous = { recorded: true, revision: 5, draft_id: '15', hash: 'hash-old' };
    const next = { recorded: true, revision: 6, draft_id: '15', hash: 'hash-new' };

    await backend.writeDraft({
      schema_version: 1,
      account_id: '42',
      client_draft_uuid: 'draft-1',
      content_hash: 'hash-edited',
      sync_base: previous,
      input: { text: 'edited' },
    }, { baseRevision: 0, stillCurrent: () => true, isDiscarded: () => false });

    expect((await backend.noteSyncBase('42', 'draft-1', { recorded: true, revision: 9, draft_id: '15', hash: 'other' }, next)).status).toBe('kept');
    expect((await backend.readDraft('42', 'draft-1')).sync_base.revision).toBe(5);
    expect((await backend.noteSyncBase('42', 'draft-1', previous, next)).status).toBe('saved');
    expect((await backend.readDraft('42', 'draft-1')).sync_base).toEqual(next);
    expect((await backend.readDraft('42', 'draft-1')).input.text).toBe('edited');
  });
});

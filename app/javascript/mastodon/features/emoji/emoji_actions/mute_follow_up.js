// Mute / unmute persist on the server before the client document sync.
// A sync failure must not be presented as a CRUD failure (which invites
// duplicate POST / stale DELETE retries).

export async function createMuteAndSync({ createMute, syncMutes, reference }) {
  const response = await createMute(reference);

  try {
    await syncMutes({ changed: { revision: response.revision } });
    return { saved: true, synced: true, response, syncError: null };
  } catch (syncError) {
    return { saved: true, synced: false, response, syncError };
  }
}

export async function deleteMuteAndSync({ deleteMute, syncMutes, mute }) {
  const response = await deleteMute(mute.id, mute.revision);

  try {
    await syncMutes({ changed: { revision: response.revision } });
    return { saved: true, synced: true, response, syncError: null };
  } catch (syncError) {
    return { saved: true, synced: false, response, syncError };
  }
}

export async function retryMuteSync({ syncMutes, revision }) {
  await syncMutes(revision ? { changed: { revision } } : {});
}

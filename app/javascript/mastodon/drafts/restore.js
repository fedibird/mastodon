import { COMPOSER_DRAFT_RESTORE, targetComposerAction } from '../actions/composer';
import { scheduleComposerInteractionCheck } from '../actions/posting_identities';
import { me } from '../initial_state';
import { selectComposer } from '../selectors/composer';
import uuid from '../uuid';
import { getComposerDraftSession } from './middleware';
import {
  composerDraftHasPersistableInput,
  draftCaptureBlock,
  restoreComposerDraft,
} from './snapshot';

function surfaceIsBusy (composer) {
  return !composer || composerDraftHasPersistableInput(composer) || Boolean(draftCaptureBlock(composer));
}

export function restoreLocalComposerDraft (composerId, clientDraftUuid) {
  return (dispatch, getState) => {
    const session = getComposerDraftSession();

    if (!session || !me || !clientDraftUuid) {
      return Promise.resolve(null);
    }

    if (surfaceIsBusy(selectComposer(getState(), composerId))) {
      return Promise.resolve(null);
    }

    if (!session.claim(clientDraftUuid, composerId)) {
      return Promise.resolve(null);
    }

    return session.read(me, clientDraftUuid).then((record) => {
      const current = selectComposer(getState(), composerId);
      const restored = record && restoreComposerDraft(record);

      if (!restored || !restored.ok || String(restored.snapshot.account_id) !== String(me) || surfaceIsBusy(current)) {
        session.release(clientDraftUuid);
        session.refreshOffers(me);
        return null;
      }

      dispatch(targetComposerAction({
        type: COMPOSER_DRAFT_RESTORE,
        snapshot: restored.snapshot,
        idempotencyKey: uuid(),
        baseRevision: record.revision || 0,
      }, composerId));
      dispatch(scheduleComposerInteractionCheck(composerId));

      return restored.snapshot;
    }).catch((error) => {
      session.release(clientDraftUuid);
      session.refreshOffers(me);
      return Promise.reject(error);
    });
  };
}

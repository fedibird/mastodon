import { COMPOSER_DRAFT_RESTORE, COMPOSER_DRAFT_TARGET, targetComposerAction } from '../actions/composer';
import { importFetchedStatus } from '../actions/importer';
import { scheduleComposerInteractionCheck } from '../actions/posting_identities';
import api from '../api';
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

function cachedStatus (state, id) {
  if (!state || typeof state.getIn !== 'function' || !id) {
    return null;
  }

  const status = state.getIn(['statuses', id]);

  if (!status || status.get('needs_fetch')) {
    return null;
  }

  return status;
}

export function resolveDraftTargets (composerId, snapshot, restoreToken) {
  return (dispatch, getState) => {
    const input = snapshot && snapshot.input || {};
    const targets = [];

    if (input.in_reply_to_id) {
      targets.push(['reply', String(input.in_reply_to_id)]);
    }

    if (input.quote_id) {
      targets.push(['quote', String(input.quote_id)]);
    }

    targets.forEach(([role, id]) => {
      const finish = (hold, replyStatus) => {
        const current = selectComposer(getState(), composerId);
        const currentId = role === 'reply' ? current && current.get('in_reply_to') : current && current.get('quote_from');

        if (!current || current.get('draftRestoreToken') !== restoreToken || String(currentId || '') !== id) {
          return;
        }

        dispatch(targetComposerAction({
          type: COMPOSER_DRAFT_TARGET,
          role,
          hold,
          replyStatus,
          restoreToken,
          targetId: id,
        }, composerId));
      };
      const present = cachedStatus(getState(), id);

      if (present) {
        finish(null, role === 'reply' && typeof present.toJS === 'function' ? present.toJS() : present);
        return;
      }

      api(getState).get(`/api/v1/statuses/${id}`).then((response) => {
        const status = response && response.data;

        if (!status || String(status.id) !== id) {
          finish('failed', null);
          return;
        }

        dispatch(importFetchedStatus(status));
        finish(null, role === 'reply' ? status : null);
      }).catch(() => {
        finish('failed', null);
      });
    });
  };
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

      const idempotencyKey = uuid();
      const restoreToken = uuid();

      dispatch(targetComposerAction({
        type: COMPOSER_DRAFT_RESTORE,
        snapshot: restored.snapshot,
        idempotencyKey,
        restoreToken,
        baseRevision: record.revision || 0,
      }, composerId));

      if (selectComposer(getState(), composerId).get('draftRestoreToken') === restoreToken) {
        dispatch(resolveDraftTargets(composerId, restored.snapshot, restoreToken));
      }

      dispatch(scheduleComposerInteractionCheck(composerId));

      return restored.snapshot;
    }).catch((error) => {
      session.release(clientDraftUuid);
      session.refreshOffers(me);
      return Promise.reject(error);
    });
  };
}

import { Map as ImmutableMap } from 'immutable';
import api from 'mastodon/api';

import { ACCOUNT_CONTEXT_OPEN, accountContextFilters, accountContextHostId } from '../timeline_seek/account_context';
import { WINDOW_SEEK_RESTORE } from '../timeline_seek/constants';
import { seekSourceKey } from '../timeline_seek/query';
import { accountHistoryContract } from '../windowed_history/sources';
import { closeAccountContextHost, expandAccountContext, seekAccountContext, settleAccountContextScroll } from './account_context_history';
import {
  ACCOUNT_CONTEXT_VIEW_CLOSE,
  ACCOUNT_CONTEXT_VIEW_COMMIT,
  ACCOUNT_CONTEXT_VIEW_NOTICE,
  ACCOUNT_CONTEXT_VIEW_OPEN,
  ACCOUNT_CONTEXT_VIEW_RESTORE,
  ACCOUNT_CONTEXT_VIEW_SEEK,
} from '../reducers/account_context_views';
import { accountContextSurfaceKey } from '../account_context/target';

export { accountContextSurfaceKey } from '../account_context/target';

// Survives close. A reopened host must not reuse the id of a request that
// can still resolve.
let requestSerial = 0;

const nextRequestSerial = () => {
  requestSerial += 1;
  return requestSerial;
};

const sessionContract = (session) => {
  if (!session) {
    return null;
  }

  return accountHistoryContract(session.get('accountId'), accountContextFilters({
    reply: session.get('reply'),
    reblog: session.get('reblog'),
  }));
};

const stillCurrent = (state, hostKey, generation, sourceKey) => {
  const session = state.getIn(['accountContextViews', 'sessions', hostKey]);

  return !!(
    session
    && session.get('generation') === generation
    && session.get('sourceKey') === sourceKey
  );
};

const heldFromCommitted = (committed) => {
  if (!committed || !committed.get('windowState') || !committed.get('session')) {
    return null;
  }

  return {
    sourceKey: committed.get('sourceKey'),
    items: committed.get('items'),
    windowState: committed.get('windowState'),
    session: committed.get('session'),
  };
};

const committedRecord = (held) => {
  if (!held || !held.windowState || !held.session) {
    return null;
  }

  return ImmutableMap({
    sourceKey: held.sourceKey,
    items: held.items,
    windowState: held.windowState,
    session: held.session,
  });
};

// The restore target is the last display whose seek scroll settled, or a
// ready timeline whose scroll is not still pending. An in-flight switch only
// has an empty or unconfirmed window, so it is not a restore target.
const restoreTarget = (state, hostKey) => {
  const timelineId = accountContextHostId(hostKey);
  const timeline = timelineId && state.getIn(['timelines', timelineId]);
  const session = state.getIn(['accountContextViews', 'sessions', hostKey]);
  const stored = heldFromCommitted(session && session.get('committed'));
  const seek = timeline && timeline.get('seek');

  if (!session) {
    return null;
  }

  if (seek && seek.get('scrollStatus') === 'pending') {
    return stored;
  }

  if (
    session.get('phase') === 'ready'
    && timeline
    && timeline.get('contextHost') === true
    && timeline.get('window')
    && timeline.get('contextSource') === session.get('sourceKey')
  ) {
    return {
      sourceKey: timeline.get('contextSource'),
      items: timeline.get('items'),
      windowState: timeline.get('window'),
      session,
    };
  }

  return stored;
};

const restoreHeldHost = (dispatch, hostKey, generation, held, notice) => {
  const timelineId = accountContextHostId(hostKey);
  const plainWindow = typeof held.windowState.toJS === 'function' ? held.windowState.toJS() : held.windowState;

  dispatch({
    type: ACCOUNT_CONTEXT_OPEN,
    timeline: timelineId,
    source: held.sourceKey,
    window: plainWindow,
  });
  dispatch({
    type: WINDOW_SEEK_RESTORE,
    timeline: timelineId,
    items: held.items,
    windowState: held.windowState,
    reason: 'not_loaded',
    replaceWindow: true,
  });
  dispatch({
    type: ACCOUNT_CONTEXT_VIEW_RESTORE,
    hostKey,
    generation,
    session: held.session,
    notice,
  });
};

export function openAccountContext({ hostTimelineId, target } = {}) {
  return (dispatch, getState) => {
    const hostKey = accountContextSurfaceKey(hostTimelineId);

    if (!hostKey || !target || !target.available || typeof target.statusId !== 'string' || typeof target.accountId !== 'string') {
      return Promise.resolve({ opened: false, reason: target && target.reason ? target.reason : 'invalid' });
    }

    const contract = accountHistoryContract(target.accountId, accountContextFilters({
      reply: !!target.reply,
      reblog: !!target.reblog,
    }));
    const sourceKey = seekSourceKey(contract);
    const generation = nextRequestSerial();
    const held = restoreTarget(getState(), hostKey);
    const timelineId = accountContextHostId(hostKey);

    dispatch({
      type: ACCOUNT_CONTEXT_VIEW_OPEN,
      hostKey,
      generation,
      kind: target.kind,
      accountId: target.accountId,
      statusId: target.statusId,
      reply: !!target.reply,
      reblog: !!target.reblog,
      sourceKey,
      committed: committedRecord(held),
    });

    return dispatch(seekAccountContext({
      hostTimelineId: hostKey,
      contract,
      statusId: target.statusId,
      preserveItems: true,
    })).then(result => {
      const scroll = result && result.scroll;
      const liveSeekId = getState().getIn(['timelines', timelineId, 'seek', 'id']);

      if (!stillCurrent(getState(), hostKey, generation, sourceKey) || result.outcome === 'stale') {
        return { ...result, opened: false, stale: true };
      }

      if (scroll && scroll.sessionId && liveSeekId && scroll.sessionId !== liveSeekId) {
        return { ...result, opened: false, stale: true };
      }

      // A failed switch restores the last settled display. The snapshot taken
      // after a source change is the empty window of the attempt, not that display.
      if (result.outcome !== 'resolved' && held) {
        restoreHeldHost(dispatch, hostKey, generation, held, result.outcome || result.reason || 'unknown');
        return { ...result, opened: false, restored: true, hostKey, generation };
      }

      const previous = held && held.sourceKey !== sourceKey ? held : result.previous;

      dispatch({
        type: ACCOUNT_CONTEXT_VIEW_SEEK,
        hostKey,
        generation,
        sourceKey,
        outcome: result.outcome,
        seekSessionId: scroll ? scroll.sessionId : null,
        scrollRevision: scroll ? scroll.revision : null,
        previous,
      });

      return { ...result, opened: true, hostKey, generation };
    });
  };
}

export function closeAccountContext(hostTimelineId) {
  return (dispatch) => {
    const hostKey = accountContextSurfaceKey(hostTimelineId);

    if (!hostKey) {
      return;
    }

    dispatch(closeAccountContextHost(hostKey));
    dispatch({
      type: ACCOUNT_CONTEXT_VIEW_CLOSE,
      hostKey,
    });
  };
}

export function pageAccountContext({ hostTimelineId, direction } = {}) {
  return (dispatch, getState) => {
    const hostKey = accountContextSurfaceKey(hostTimelineId);
    const session = hostKey && getState().getIn(['accountContextViews', 'sessions', hostKey]);
    const contract = sessionContract(session);

    if (!contract || seekSourceKey(contract) !== session.get('sourceKey')) {
      return Promise.resolve();
    }

    return dispatch(expandAccountContext({
      hostTimelineId: hostKey,
      contract,
      direction,
    }));
  };
}

export function settleAccountContextView({
  hostTimelineId,
  renderedIds,
  articlePresent,
  sessionId,
  scrollRevision,
  source,
} = {}) {
  return (dispatch, getState) => {
    const hostKey = accountContextSurfaceKey(hostTimelineId);
    const session = hostKey && getState().getIn(['accountContextViews', 'sessions', hostKey]);
    const timelineId = accountContextHostId(hostKey);
    const seek = timelineId && getState().getIn(['timelines', timelineId, 'seek']);

    if (!session || !seek || seek.get('id') !== sessionId || session.get('sourceKey') !== source) {
      return { scroll: false, reason: 'stale' };
    }

    if (session.get('seekSessionId') && session.get('seekSessionId') !== sessionId) {
      return { scroll: false, reason: 'stale' };
    }

    const stored = session.get('previousItems') ? {
      items: session.get('previousItems'),
      windowState: session.get('previousWindow'),
    } : null;
    const previousSource = session.get('previousSourceKey');
    const crossSource = !!(
      previousSource
      && previousSource !== session.get('sourceKey')
      && session.get('previousSession')
      && stored
    );

    const plan = dispatch(settleAccountContextScroll({
      hostTimelineId: hostKey,
      renderedIds,
      articlePresent,
      previous: crossSource ? null : stored,
      sessionId,
      scrollRevision,
      source,
    }));

    if ((plan.reason === 'filtered' || plan.reason === 'not_loaded') && crossSource) {
      if (stillCurrent(getState(), hostKey, session.get('generation'), source)) {
        restoreHeldHost(dispatch, hostKey, session.get('generation'), {
          sourceKey: previousSource,
          items: session.get('previousItems'),
          windowState: session.get('previousWindow'),
          session: session.get('previousSession'),
        }, plan.reason);
      }

      return plan;
    }

    if (plan.reason === 'filtered' || plan.reason === 'not_loaded') {
      dispatch({
        type: ACCOUNT_CONTEXT_VIEW_NOTICE,
        hostKey,
        generation: session.get('generation'),
        seekSessionId: sessionId,
        notice: plan.reason,
      });
    }

    if (plan.scroll) {
      const shown = getState().getIn(['timelines', timelineId]);
      const shownSession = getState().getIn(['accountContextViews', 'sessions', hostKey]) || session;

      dispatch({
        type: ACCOUNT_CONTEXT_VIEW_COMMIT,
        hostKey,
        generation: shownSession.get('generation'),
        seekSessionId: sessionId,
        committed: committedRecord({
          sourceKey: shownSession.get('sourceKey'),
          items: shown && shown.get('items'),
          windowState: shown && shown.get('window'),
          session: shownSession,
        }),
      });
    }

    return plan;
  };
}

const normalizeWrapper = (data, accountId) => {
  const body = data || {};

  return {
    state: typeof body.state === 'string' ? body.state : 'unknown',
    reason: typeof body.reason === 'string' ? body.reason : null,
    id: typeof body.id === 'string' ? body.id : null,
    account_id: typeof body.account_id === 'string' ? body.account_id : accountId,
  };
};

// Bounded lookup. The original status id is the query subject, never the anchor.
export function lookupReblogWrapper({ statusId, accountId } = {}) {
  return (_dispatch, getState) => {
    if (typeof statusId !== 'string' || typeof accountId !== 'string') {
      return Promise.resolve({ state: 'unknown', reason: 'invalid', id: null, account_id: null });
    }

    return api(getState).get(`/api/v1/statuses/${statusId}/reblog_wrapper`, {
      params: { account_id: accountId },
    }).then(response => normalizeWrapper(response && response.data, accountId)).catch(() => ({
      state: 'unknown',
      reason: 'request_failed',
      id: null,
      account_id: accountId,
    }));
  };
}

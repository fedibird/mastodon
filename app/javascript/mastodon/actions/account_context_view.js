import api from 'mastodon/api';

import { accountContextFilters, accountContextHostId } from '../timeline_seek/account_context';
import { seekSourceKey } from '../timeline_seek/query';
import { accountHistoryContract } from '../windowed_history/sources';
import { closeAccountContextHost, expandAccountContext, seekAccountContext, settleAccountContextScroll } from './account_context_history';
import {
  ACCOUNT_CONTEXT_VIEW_CLOSE,
  ACCOUNT_CONTEXT_VIEW_NOTICE,
  ACCOUNT_CONTEXT_VIEW_OPEN,
  ACCOUNT_CONTEXT_VIEW_SEEK,
} from '../reducers/account_context_views';
import { accountContextSurfaceKey } from '../account_context/target';

export { accountContextSurfaceKey } from '../account_context/target';

const previousBySession = new Map();

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
    const generation = (getState().getIn(['accountContextViews', 'sessions', hostKey, 'generation']) || 0) + 1;

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
    });

    return dispatch(seekAccountContext({
      hostTimelineId: hostKey,
      contract,
      statusId: target.statusId,
    })).then(result => {
      const scroll = result && result.scroll;

      if (scroll && scroll.sessionId) {
        previousBySession.set(scroll.sessionId, result.previous || null);
      }

      if (!stillCurrent(getState(), hostKey, generation, sourceKey)) {
        return { ...result, opened: false, stale: true };
      }

      dispatch({
        type: ACCOUNT_CONTEXT_VIEW_SEEK,
        hostKey,
        generation,
        sourceKey,
        outcome: result.outcome,
        seekSessionId: scroll ? scroll.sessionId : null,
        scrollRevision: scroll ? scroll.revision : null,
        previous: result.previous,
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
    } : previousBySession.get(sessionId);

    const plan = dispatch(settleAccountContextScroll({
      hostTimelineId: hostKey,
      renderedIds,
      articlePresent,
      previous: stored,
      sessionId,
      scrollRevision,
      source,
    }));

    if (plan.reason === 'filtered' || plan.reason === 'not_loaded') {
      dispatch({
        type: ACCOUNT_CONTEXT_VIEW_NOTICE,
        hostKey,
        generation: session.get('generation'),
        seekSessionId: sessionId,
        notice: plan.reason,
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

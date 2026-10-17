import React from 'react';
import { connect } from 'react-redux';
import PropTypes from 'prop-types';
import { CancelToken, isCancel } from 'axios';
import {
  TIMELINE_SPLIT_KEEP_HISTORY,
  clearTimelineSplitReturnAnchor,
  createTimelineSplit,
  destroyTimelineSplit,
  saveTimelineSplitReturnAnchor,
} from '../../../actions/timelines';
import { cancelWindowedHistory } from '../../../windowed_history/flights';
import api from '../../../api';
import { seekWindowedTimeline } from '../../../actions/timeline_seek';
import { WINDOW_SEEK_RESTORE } from '../../../timeline_seek/constants';
import { me } from '../../../initial_state';
import { captureHistoryPosition, cancelHistoryResume, resumeHistoryPosition } from '../../../actions/timeline_position';
import TimelineSplitControllerCore, {
  STATUS_TIMELINE_SPLIT_LAYOUT_CLASS,
  clampTimelineSplitRatio,
} from './timeline_split_controller_core';

export { STATUS_TIMELINE_SPLIT_LAYOUT_CLASS, clampTimelineSplitRatio };

const accountIdFromInitialState = (value) => {
  if (typeof value === 'string' && value.length > 0) {
    return value;
  }

  if (typeof value === 'number' && Number.isFinite(value)) {
    return String(value);
  }

  return null;
};

const mapStateToProps = (state, ownProps) => {
  const { sourceTimelineId } = ownProps;
  const activeSplitId = state.getIn(['timelines', sourceTimelineId, 'splitTimelineId']) || null;

  return {
    activeSplitId,
    splitReturnAnchor: state.getIn(['timelines', sourceTimelineId, 'splitReturnAnchor']) || null,
    splitBlocked: state.getIn(['timelines', sourceTimelineId, 'isPartial']),
    historyResume: activeSplitId ? state.getIn(['timelines', activeSplitId, 'historyResume']) || null : null,
    historyItemIds: activeSplitId ? state.getIn(['timelines', activeSplitId, 'items']) || null : null,
    historySeek: activeSplitId ? state.getIn(['timelines', activeSplitId, 'seek']) || null : null,
    accountId: ownProps.accountId || accountIdFromInitialState(me),
  };
};

// pure: false so a parent re-render (title, unread, composer) still invokes the render prop.
export default @connect(mapStateToProps, null, null, { pure: false })
class StatusTimelineSplitController extends React.Component {

  static propTypes = {
    dispatch: PropTypes.func.isRequired,
    sourceTimelineId: PropTypes.string.isRequired,
    children: PropTypes.func.isRequired,
    activeSplitId: PropTypes.string,
    splitReturnAnchor: PropTypes.object,
    splitBlocked: PropTypes.bool,
    historyResume: PropTypes.object,
    historyItemIds: PropTypes.object,
    historySeek: PropTypes.object,
    accountId: PropTypes.string,
    historyContract: PropTypes.object,
  };

  handleCreate = (splitId, anchorId) => {
    this.props.dispatch(createTimelineSplit(this.props.sourceTimelineId, splitId, anchorId));
  };

  handleDestroy = (splitId, options = {}) => {
    cancelWindowedHistory(splitId);
    this.props.dispatch(destroyTimelineSplit(this.props.sourceTimelineId, splitId, {
      keep: options.keep || TIMELINE_SPLIT_KEEP_HISTORY,
      liveAtTop: options.liveAtTop,
    }));
  };

  handleSaveReturnAnchor = (anchor) => {
    this.props.dispatch(saveTimelineSplitReturnAnchor(this.props.sourceTimelineId, anchor));
  };

  handleClearReturnAnchor = () => {
    this.props.dispatch(clearTimelineSplitReturnAnchor(this.props.sourceTimelineId));
  };

  handleCaptureHistoryPosition = (payload) => captureHistoryPosition(payload);

  handleResumeHistory = (payload) => {
    this.props.dispatch(resumeHistoryPosition(payload));
  };

  handleCancelHistoryResume = (payload) => {
    this.props.dispatch(cancelHistoryResume(payload));
  };

  handleSeekTimeline = (payload) => this.props.dispatch((dispatch, getState) => {
    const before = getState().getIn(['timelines', payload.splitTimelineId]);
    const snapshot = before ? {
      items: before.get('items'),
      windowState: before.get('window'),
    } : null;

    return dispatch(seekWindowedTimeline(payload)).then(result => ({
      result,
      snapshot,
    }));
  });

  handleSearchJumpAccounts = (query) => {
    if (this.jumpAccountCancel) {
      this.jumpAccountCancel();
      this.jumpAccountCancel = null;
    }

    return this.props.dispatch((dispatch, getState) => api(getState).get('/api/v1/accounts/search', {
      cancelToken: new CancelToken(cancel => {
        this.jumpAccountCancel = cancel;
      }),
      params: {
        q: query,
        resolve: false,
        limit: 4,
      },
    }).then(response => ({
      ok: true,
      accounts: (response.data || []).map(account => ({
        id: account && account.id !== undefined && account.id !== null ? String(account.id) : '',
        acct: account.acct || '',
        display_name: account.display_name || '',
      })).filter(account => account.id),
    })).catch(error => {
      if (isCancel(error)) {
        return { ok: false, reason: 'cancelled', accounts: [] };
      }

      return { ok: false, reason: 'network', accounts: [] };
    }));
  };

  handleCancelAccountSearch = () => {
    if (this.jumpAccountCancel) {
      this.jumpAccountCancel();
      this.jumpAccountCancel = null;
    }
  };

  handleRestoreJump = ({ splitTimelineId, sessionId, items, windowState, reason }) => {
    this.props.dispatch({
      type: WINDOW_SEEK_RESTORE,
      timeline: splitTimelineId,
      sessionId,
      items,
      windowState,
      reason,
    });
  };

  render () {
    const { dispatch, activeSplitId, splitReturnAnchor, splitBlocked, historyResume, historyItemIds, historySeek, accountId, historyContract, ...rest } = this.props;

    return (
      <TimelineSplitControllerCore
        {...rest}
        activeSplitId={activeSplitId}
        splitReturnAnchor={splitReturnAnchor}
        splitBlocked={splitBlocked}
        historyResume={historyResume}
        historyItemIds={historyItemIds}
        historySeek={historySeek}
        accountId={accountId}
        historyContract={historyContract}
        onSeekTimeline={this.handleSeekTimeline}
        onSearchJumpAccounts={this.handleSearchJumpAccounts}
        onCancelAccountSearch={this.handleCancelAccountSearch}
        onRestoreJump={this.handleRestoreJump}
        onCreate={this.handleCreate}
        onDestroy={this.handleDestroy}
        onSaveReturnAnchor={this.handleSaveReturnAnchor}
        onClearReturnAnchor={this.handleClearReturnAnchor}
        onCaptureHistoryPosition={this.handleCaptureHistoryPosition}
        onResumeHistory={this.handleResumeHistory}
        onCancelHistoryResume={this.handleCancelHistoryResume}
      />
    );
  }

}

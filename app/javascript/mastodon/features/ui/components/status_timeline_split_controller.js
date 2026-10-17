import React from 'react';
import { connect } from 'react-redux';
import PropTypes from 'prop-types';
import {
  TIMELINE_SPLIT_KEEP_HISTORY,
  clearTimelineSplitReturnAnchor,
  createTimelineSplit,
  destroyTimelineSplit,
  saveTimelineSplitReturnAnchor,
} from '../../../actions/timelines';
import { cancelWindowedHistory } from '../../../windowed_history/flights';
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

  render () {
    const { dispatch, activeSplitId, splitReturnAnchor, splitBlocked, historyResume, historyItemIds, accountId, historyContract, ...rest } = this.props;

    return (
      <TimelineSplitControllerCore
        {...rest}
        activeSplitId={activeSplitId}
        splitReturnAnchor={splitReturnAnchor}
        splitBlocked={splitBlocked}
        historyResume={historyResume}
        historyItemIds={historyItemIds}
        accountId={accountId}
        historyContract={historyContract}
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

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
import TimelineSplitControllerCore, {
  STATUS_TIMELINE_SPLIT_LAYOUT_CLASS,
  clampTimelineSplitRatio,
} from './timeline_split_controller_core';

export { STATUS_TIMELINE_SPLIT_LAYOUT_CLASS, clampTimelineSplitRatio };

const mapStateToProps = (state, { sourceTimelineId }) => ({
  activeSplitId: state.getIn(['timelines', sourceTimelineId, 'splitTimelineId']) || null,
  splitReturnAnchor: state.getIn(['timelines', sourceTimelineId, 'splitReturnAnchor']) || null,
  splitBlocked: state.getIn(['timelines', sourceTimelineId, 'isPartial']),
});

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
  };

  handleCreate = (splitId) => {
    this.props.dispatch(createTimelineSplit(this.props.sourceTimelineId, splitId));
  };

  handleDestroy = (splitId, options = {}) => {
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

  render () {
    const { dispatch, activeSplitId, splitReturnAnchor, splitBlocked, ...rest } = this.props;

    return (
      <TimelineSplitControllerCore
        {...rest}
        activeSplitId={activeSplitId}
        splitReturnAnchor={splitReturnAnchor}
        splitBlocked={splitBlocked}
        onCreate={this.handleCreate}
        onDestroy={this.handleDestroy}
        onSaveReturnAnchor={this.handleSaveReturnAnchor}
        onClearReturnAnchor={this.handleClearReturnAnchor}
      />
    );
  }

}

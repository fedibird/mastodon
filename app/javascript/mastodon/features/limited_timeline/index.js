import React, { Fragment } from 'react';
import { connect } from 'react-redux';
import { expandLimitedTimeline } from '../../actions/timelines';
import PropTypes from 'prop-types';
import StatusListContainer from '../ui/containers/status_list_container';
import Column from '../../components/column';
import ColumnHeader from '../../components/column_header';
import { addColumn, removeColumn, moveColumn } from '../../actions/columns';
import { getLimitedVisibilities } from 'mastodon/selectors';
import { defineMessages, injectIntl, FormattedMessage } from 'react-intl';
import ColumnSettingsContainer from './containers/column_settings_container';
import { defaultColumnWidth } from 'mastodon/initial_state';
import { changeSetting } from '../../actions/settings';
import { changeColumnParams } from '../../actions/columns';
import { DEFAULT_TIMELINE_SPLIT_RATIO } from 'mastodon/components/timeline_splitter';
import StatusTimelineSplitController, { clampTimelineSplitRatio } from '../ui/components/status_timeline_split_controller';

const messages = defineMessages({
  title: { id: 'column.limited', defaultMessage: 'Limited' },
  splitUnavailable: { id: 'timeline.split_source_unavailable', defaultMessage: 'This timeline is already split in another column' },
});

const columnIndex = (columns, columnId) => columns ? columns.findIndex(column => column.get('uuid') === columnId) : -1;

const mapStateToProps = (state, { columnId }) => {
  const columns = state.getIn(['settings', 'columns']);
  const index = columnIndex(columns, columnId);
  const columnWidth = (columnId && index >= 0) ? columns.get(index).getIn(['params', 'columnWidth']) : state.getIn(['settings', 'limited', 'columnWidth']);

  return {
    hasUnread: state.getIn(['timelines', 'limited', 'unread']) > 0,
    visibilities: getLimitedVisibilities(state),
    columnWidth: columnWidth ?? defaultColumnWidth,
    splitRatio: clampTimelineSplitRatio(state.getIn(['settings', 'limited', 'splitRatio'], DEFAULT_TIMELINE_SPLIT_RATIO)),
  };
};

export default @connect(mapStateToProps)
@injectIntl
class LimitedTimeline extends React.PureComponent {

  static propTypes = {
    dispatch: PropTypes.func.isRequired,
    intl: PropTypes.object.isRequired,
    hasUnread: PropTypes.bool,
    visibilities: PropTypes.arrayOf(PropTypes.string),
    columnId: PropTypes.string,
    multiColumn: PropTypes.bool,
    columnWidth: PropTypes.string,
    splitRatio: PropTypes.number,
    location: PropTypes.shape({
      key: PropTypes.string,
    }),
  };

  handlePin = () => {
    const { columnId, dispatch } = this.props;

    if (columnId) {
      dispatch(removeColumn(columnId));
    } else {
      dispatch(addColumn('LIMITED', {}));
    }
  }

  handleMove = (dir) => {
    const { columnId, dispatch } = this.props;
    dispatch(moveColumn(columnId, dir));
  }

  handleWidthChange = (value) => {
    const { columnId, dispatch } = this.props;

    if (columnId) {
      dispatch(changeColumnParams(columnId, 'columnWidth', value));
    } else {
      dispatch(changeSetting(['limited', 'columnWidth'], value));
    }
  }

  handleSplitRatioCommit = (ratio) => {
    this.props.dispatch(changeSetting(['limited', 'splitRatio'], ratio));
  }

  handleLoadMore = maxId => {
    const { dispatch, visibilities } = this.props;

    dispatch(expandLimitedTimeline({ maxId, visibilities }));
  }

  handleLoadMoreHistory = maxId => {
    const { dispatch, visibilities } = this.props;

    dispatch(expandLimitedTimeline({ maxId, visibilities, timelineId: this.splitTimelineId }));
  }

  componentDidMount () {
    const { dispatch, visibilities } = this.props;

    dispatch(expandLimitedTimeline({ visibilities }));
  }

  componentDidUpdate (prevProps) {
    const { dispatch, visibilities } = this.props;

    if (prevProps.visibilities.toString() !== visibilities.toString()) {
      dispatch(expandLimitedTimeline({ visibilities }));
    }
  }

  renderColumn = (split) => {
    const { intl, hasUnread, columnId, multiColumn, columnWidth } = this.props;
    const pinned = !!columnId;
    const emptyMessage = <FormattedMessage id='empty_column.limited' defaultMessage='Your limited timeline is empty.' />;

    this.splitTimelineId = split.splitTimelineId;

    let timeline;

    if (!split.isSplit) {
      timeline = (
        <StatusListContainer
          trackScroll={!pinned}
          scrollKey={`limited_timeline-${columnId}`}
          onLoadMore={this.handleLoadMore}
          timelineId='limited'
          emptyMessage={emptyMessage}
          bindToDocument={!multiColumn}
        />
      );
    } else {
      timeline = (
        <div className='timeline-split' style={{ '--timeline-split-ratio': split.ratio }}>
          <div className='timeline-split__pane timeline-split__pane--live'>
            <StatusListContainer
              timelineId='limited'
              dataTimelineId='limited'
              includePendingItems
              statusLimit={40}
              manageTimelineScrollState={false}
              trackIntersection={false}
              trackScroll={false}
              scrollKey={`limited_timeline-${columnId}-live`}
              emptyMessage={emptyMessage}
              bindToDocument={false}
            />
          </div>

          {split.splitter}

          <div className='timeline-split__pane timeline-split__pane--history'>
            <StatusListContainer
              trackScroll={multiColumn ? !pinned : false}
              scrollKey={`limited_timeline-${columnId}`}
              onLoadMore={this.handleLoadMoreHistory}
              timelineId='limited'
              dataTimelineId={split.splitTimelineId}
              trackIntersection
              emptyMessage={emptyMessage}
              bindToDocument={false}
            />
          </div>
        </div>
      );
    }

    return (
      <Column bindToDocument={!multiColumn} ref={split.setColumnRef} label={intl.formatMessage(messages.title)} columnWidth={columnWidth}>
        <ColumnHeader
          icon='lock'
          active={hasUnread}
          title={intl.formatMessage(messages.title)}
          onPin={this.handlePin}
          onMove={this.handleMove}
          onClick={split.handleHeaderClick}
          pinned={pinned}
          multiColumn={multiColumn}
          extraButton={(
            <Fragment>
              {split.splitButton}
              {split.closeLiveButton}
            </Fragment>
          )}
          columnWidth={columnWidth}
          onWidthChange={this.handleWidthChange}
        >
          <ColumnSettingsContainer />
        </ColumnHeader>

        {timeline}
      </Column>
    );
  }

  render () {
    const { columnId, multiColumn, splitRatio, location } = this.props;

    return (
      <StatusTimelineSplitController
        key='limited'
        sourceTimelineId='limited'
        columnId={columnId}
        multiColumn={multiColumn}
        location={location}
        splitRatio={splitRatio}
        onSplitRatioCommit={this.handleSplitRatioCommit}
        unavailableMessage={messages.splitUnavailable}
      >
        {this.renderColumn}
      </StatusTimelineSplitController>
    );
  }

}

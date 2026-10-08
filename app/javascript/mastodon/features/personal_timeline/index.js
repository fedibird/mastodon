import React, { Fragment } from 'react';
import { connect } from 'react-redux';
import { expandPersonalTimeline, clearTimelineSplitReturnAnchor } from '../../actions/timelines';
import { personalTimelineId } from '../../actions/timeline_ids';
import PropTypes from 'prop-types';
import StatusListContainer from '../ui/containers/status_list_container';
import Column from '../../components/column';
import ColumnHeader from '../../components/column_header';
import { addColumn, removeColumn, moveColumn } from '../../actions/columns';
import { defineMessages, injectIntl, FormattedMessage } from 'react-intl';
import ColumnSettingsContainer from './containers/column_settings_container';
import { defaultColumnWidth } from 'mastodon/initial_state';
import { changeSetting } from '../../actions/settings';
import { changeColumnParams } from '../../actions/columns';
import { DEFAULT_TIMELINE_SPLIT_RATIO } from 'mastodon/components/timeline_splitter';
import StatusTimelineSplitController, { clampTimelineSplitRatio } from '../ui/components/status_timeline_split_controller';

const messages = defineMessages({
  title: { id: 'column.personal', defaultMessage: 'Personal' },
  splitUnavailable: { id: 'timeline.split_source_unavailable', defaultMessage: 'This timeline is already split in another column' },
});

const columnIndex = (columns, columnId) => columns ? columns.findIndex(column => column.get('uuid') === columnId) : -1;

const mapStateToProps = (state, { columnId }) => {
  const columns = state.getIn(['settings', 'columns']);
  const index = columnIndex(columns, columnId);
  const onlyMedia = (columnId && index >= 0) ? columns.get(index).getIn(['params', 'other', 'onlyMedia']) : state.getIn(['settings', 'personal', 'other', 'onlyMedia']);
  const withoutMedia = (columnId && index >= 0) ? columns.get(index).getIn(['params', 'other', 'withoutMedia']) : state.getIn(['settings', 'personal', 'other', 'withoutMedia']);
  const columnWidth = (columnId && index >= 0) ? columns.get(index).getIn(['params', 'columnWidth']) : state.getIn(['settings', 'personal', 'columnWidth']);
  const sourceTimelineId = personalTimelineId({ onlyMedia, withoutMedia });

  return {
    hasUnread: state.getIn(['timelines', sourceTimelineId, 'unread']) > 0,
    onlyMedia,
    withoutMedia,
    columnWidth: columnWidth ?? defaultColumnWidth,
    splitRatio: clampTimelineSplitRatio(state.getIn(['settings', 'personal', 'splitRatio'], DEFAULT_TIMELINE_SPLIT_RATIO)),
  };
};

export default @connect(mapStateToProps)
@injectIntl
class PersonalTimeline extends React.PureComponent {

  static propTypes = {
    dispatch: PropTypes.func.isRequired,
    intl: PropTypes.object.isRequired,
    hasUnread: PropTypes.bool,
    columnId: PropTypes.string,
    onlyMedia: PropTypes.bool,
    withoutMedia: PropTypes.bool,
    multiColumn: PropTypes.bool,
    columnWidth: PropTypes.string,
    splitRatio: PropTypes.number,
    location: PropTypes.shape({
      key: PropTypes.string,
    }),
  };

  static defaultProps = {
    onlyMedia: false,
    withoutMedia: false,
  };

  handlePin = () => {
    const { columnId, dispatch, onlyMedia, withoutMedia } = this.props;

    if (columnId) {
      dispatch(removeColumn(columnId));
    } else {
      dispatch(addColumn('PERSONAL', { other: { onlyMedia, withoutMedia } }));
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
      dispatch(changeSetting(['personal', 'columnWidth'], value));
    }
  }

  handleSplitRatioCommit = (ratio) => {
    this.props.dispatch(changeSetting(['personal', 'splitRatio'], ratio));
  }

  handleLoadMore = maxId => {
    const { dispatch, onlyMedia, withoutMedia } = this.props;

    dispatch(expandPersonalTimeline({ maxId, onlyMedia, withoutMedia }));
  }

  handleLoadMoreHistory = maxId => {
    const { dispatch, onlyMedia, withoutMedia } = this.props;

    dispatch(expandPersonalTimeline({ maxId, onlyMedia, withoutMedia, timelineId: this.splitTimelineId }));
  }

  componentDidMount () {
    const { dispatch, onlyMedia, withoutMedia } = this.props;

    dispatch(expandPersonalTimeline({ onlyMedia, withoutMedia }));
  }

  componentDidUpdate (prevProps) {
    const { dispatch, onlyMedia, withoutMedia } = this.props;

    if (prevProps.onlyMedia !== onlyMedia || prevProps.withoutMedia !== withoutMedia) {
      dispatch(expandPersonalTimeline({ onlyMedia, withoutMedia }));
      dispatch(clearTimelineSplitReturnAnchor(personalTimelineId(prevProps)));
    }
  }

  renderColumn = (split) => {
    const { intl, hasUnread, columnId, multiColumn, columnWidth, onlyMedia, withoutMedia } = this.props;
    const pinned = !!columnId;
    const sourceTimelineId = personalTimelineId({ onlyMedia, withoutMedia });
    const emptyMessage = <FormattedMessage id='empty_column.personal' defaultMessage='Personal posts unavailable' />;

    this.splitTimelineId = split.splitTimelineId;

    let timeline;

    if (!split.isSplit) {
      timeline = (
        <StatusListContainer
          timelineId={sourceTimelineId}
          onLoadMore={this.handleLoadMore}
          trackScroll={!pinned}
          scrollKey={`personal_timeline-${columnId}`}
          emptyMessage={emptyMessage}
          bindToDocument={!multiColumn}
          showCard={!withoutMedia}
        />
      );
    } else {
      timeline = (
        <div className='timeline-split' style={{ '--timeline-split-ratio': split.ratio }}>
          <div className='timeline-split__pane timeline-split__pane--live'>
            <StatusListContainer
              timelineId={sourceTimelineId}
              dataTimelineId={sourceTimelineId}
              includePendingItems
              statusLimit={40}
              manageTimelineScrollState={false}
              trackIntersection={false}
              trackScroll={false}
              scrollKey={`personal_timeline-${columnId}-live`}
              emptyMessage={emptyMessage}
              bindToDocument={false}
              showCard={!withoutMedia}
            />
          </div>

          {split.splitter}

          <div className='timeline-split__pane timeline-split__pane--history'>
            <StatusListContainer
              trackScroll={multiColumn ? !pinned : false}
              scrollKey={`personal_timeline-${columnId}`}
              onLoadMore={this.handleLoadMoreHistory}
              timelineId={sourceTimelineId}
              dataTimelineId={split.splitTimelineId}
              trackIntersection
              emptyMessage={emptyMessage}
              bindToDocument={false}
              showCard={!withoutMedia}
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
          <ColumnSettingsContainer columnId={columnId} />
        </ColumnHeader>

        {timeline}
      </Column>
    );
  }

  render () {
    const { columnId, multiColumn, onlyMedia, withoutMedia, splitRatio, location } = this.props;
    const sourceTimelineId = personalTimelineId({ onlyMedia, withoutMedia });

    return (
      <StatusTimelineSplitController
        key={sourceTimelineId}
        sourceTimelineId={sourceTimelineId}
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

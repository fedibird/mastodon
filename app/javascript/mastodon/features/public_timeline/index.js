import React from 'react';
import { connect } from 'react-redux';
import { defineMessages, injectIntl, FormattedMessage } from 'react-intl';
import PropTypes from 'prop-types';
import StatusListContainer from '../ui/containers/status_list_container';
import Column from '../../components/column';
import ColumnHeader from '../../components/column_header';
import { clearTimelineSplitReturnAnchor, expandPublicTimeline } from '../../actions/timelines';
import { publicTimelineId } from '../../actions/timeline_ids';
import { addColumn, removeColumn, moveColumn } from '../../actions/columns';
import ColumnSettingsContainer from './containers/column_settings_container';
import { connectPublicStream } from '../../actions/streaming';
import { defaultColumnWidth } from 'mastodon/initial_state';
import { changeSetting } from '../../actions/settings';
import { changeColumnParams } from '../../actions/columns';
import { DEFAULT_TIMELINE_SPLIT_RATIO } from 'mastodon/components/timeline_splitter';
import StatusTimelineSplitController, { clampTimelineSplitRatio } from '../ui/components/status_timeline_split_controller';

const messages = defineMessages({
  title: { id: 'column.public', defaultMessage: 'Federated timeline' },
  splitUnavailable: { id: 'timeline.split_source_unavailable', defaultMessage: 'This timeline is already split in another column' },
});

const columnIndex = (columns, columnId) => columns ? columns.findIndex(column => column.get('uuid') === columnId) : -1;

const mapStateToProps = (state, { columnId }) => {
  const columns = state.getIn(['settings', 'columns']);
  const index = columnIndex(columns, columnId);
  const onlyMedia = (columnId && index >= 0) ? columns.get(index).getIn(['params', 'other', 'onlyMedia']) : state.getIn(['settings', 'public', 'other', 'onlyMedia']);
  const withoutMedia = (columnId && index >= 0) ? columns.get(index).getIn(['params', 'other', 'withoutMedia']) : state.getIn(['settings', 'public', 'other', 'withoutMedia']);
  const withoutBot = (columnId && index >= 0) ? columns.get(index).getIn(['params', 'other', 'withoutBot']) : state.getIn(['settings', 'public', 'other', 'withoutBot']);
  const onlyRemote = (columnId && index >= 0) ? columns.get(index).getIn(['params', 'other', 'onlyRemote']) : state.getIn(['settings', 'public', 'other', 'onlyRemote']);
  const columnWidth = (columnId && index >= 0) ? columns.get(index).getIn(['params', 'columnWidth']) : state.getIn(['settings', 'public', 'columnWidth']);
  const sourceTimelineId = publicTimelineId({ onlyRemote, withoutBot, withoutMedia, onlyMedia });
  const timelineState = state.getIn(['timelines', sourceTimelineId]);

  return {
    hasUnread: !!timelineState && timelineState.get('unread') > 0,
    onlyMedia,
    withoutMedia,
    withoutBot,
    onlyRemote,
    columnWidth: columnWidth ?? defaultColumnWidth,
    splitRatio: clampTimelineSplitRatio(state.getIn(['settings', 'public', 'splitRatio'], DEFAULT_TIMELINE_SPLIT_RATIO)),
  };
};

export default @connect(mapStateToProps)
@injectIntl
class PublicTimeline extends React.PureComponent {

  static contextTypes = {
    router: PropTypes.object,
  };

  static defaultProps = {
    onlyMedia: false,
    withoutMedia: false,
    withoutBot: false,
    onlyRemote: false,
  };

  static propTypes = {
    dispatch: PropTypes.func.isRequired,
    intl: PropTypes.object.isRequired,
    columnId: PropTypes.string,
    multiColumn: PropTypes.bool,
    columnWidth: PropTypes.string,
    hasUnread: PropTypes.bool,
    onlyMedia: PropTypes.bool,
    withoutMedia: PropTypes.bool,
    withoutBot: PropTypes.bool,
    onlyRemote: PropTypes.bool,
    splitRatio: PropTypes.number,
    location: PropTypes.shape({
      key: PropTypes.string,
    }),
  };

  handlePin = () => {
    const { columnId, dispatch, onlyMedia, withoutMedia, withoutBot, onlyRemote } = this.props;

    if (columnId) {
      dispatch(removeColumn(columnId));
    } else {
      dispatch(addColumn(onlyRemote ? 'REMOTE' : 'PUBLIC', { other: { onlyMedia, withoutMedia, withoutBot, onlyRemote } }));
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
      dispatch(changeSetting(['public', 'columnWidth'], value));
    }
  }

  handleSplitRatioCommit = (ratio) => {
    this.props.dispatch(changeSetting(['public', 'splitRatio'], ratio));
  }

  componentDidMount () {
    const { dispatch, onlyMedia, withoutMedia, withoutBot, onlyRemote } = this.props;

    dispatch(expandPublicTimeline({ onlyMedia, withoutMedia, withoutBot, onlyRemote }));
    this.disconnect = dispatch(connectPublicStream({ onlyMedia, withoutMedia, withoutBot, onlyRemote }));
  }

  componentDidUpdate (prevProps) {
    if (prevProps.onlyMedia !== this.props.onlyMedia || prevProps.withoutMedia !== this.props.withoutMedia || prevProps.withoutBot !== this.props.withoutBot || prevProps.onlyRemote !== this.props.onlyRemote) {
      const { dispatch, onlyMedia, withoutMedia, withoutBot, onlyRemote } = this.props;

      this.disconnect();
      dispatch(expandPublicTimeline({ onlyMedia, withoutMedia, withoutBot, onlyRemote }));
      this.disconnect = dispatch(connectPublicStream({ onlyMedia, withoutMedia, withoutBot, onlyRemote }));
      dispatch(clearTimelineSplitReturnAnchor(publicTimelineId(prevProps)));
    }
  }

  componentWillUnmount () {
    if (this.disconnect) {
      this.disconnect();
      this.disconnect = null;
    }
  }

  handleLoadMore = maxId => {
    const { dispatch, onlyMedia, withoutMedia, withoutBot, onlyRemote } = this.props;

    dispatch(expandPublicTimeline({ maxId, onlyMedia, withoutMedia, withoutBot, onlyRemote }));
  }

  handleLoadMoreHistory = maxId => {
    const { dispatch, onlyMedia, withoutMedia, withoutBot, onlyRemote } = this.props;

    dispatch(expandPublicTimeline({ maxId, onlyMedia, withoutMedia, withoutBot, onlyRemote, timelineId: this.splitTimelineId }));
  }

  renderColumn = (split) => {
    const { intl, columnId, hasUnread, multiColumn, onlyMedia, withoutMedia, onlyRemote, withoutBot, columnWidth } = this.props;
    const pinned = !!columnId;
    const sourceTimelineId = publicTimelineId({ onlyRemote, withoutBot, withoutMedia, onlyMedia });
    const emptyMessage = <FormattedMessage id='empty_column.public' defaultMessage='There is nothing here! Write something publicly, or manually follow users from other servers to fill it up' />;

    this.splitTimelineId = split.splitTimelineId;

    let timeline;

    if (!split.isSplit) {
      timeline = (
        <StatusListContainer
          timelineId={sourceTimelineId}
          onLoadMore={this.handleLoadMore}
          trackScroll={!pinned}
          scrollKey={`public_timeline-${columnId}`}
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
              scrollKey={`public_timeline-${columnId}-live`}
              emptyMessage={emptyMessage}
              bindToDocument={false}
              showCard={!withoutMedia}
            />
          </div>

          {split.splitter}

          <div className='timeline-split__pane timeline-split__pane--history'>
            <StatusListContainer
              trackScroll={multiColumn ? !pinned : false}
              scrollKey={`public_timeline-${columnId}`}
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
          icon='globe'
          active={hasUnread}
          title={intl.formatMessage(messages.title)}
          onPin={this.handlePin}
          onMove={this.handleMove}
          onClick={split.handleHeaderClick}
          pinned={pinned}
          multiColumn={multiColumn}
          extraButton={split.splitButton}
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
    const { columnId, multiColumn, onlyMedia, withoutMedia, withoutBot, onlyRemote, splitRatio, location } = this.props;
    const sourceTimelineId = publicTimelineId({ onlyRemote, withoutBot, withoutMedia, onlyMedia });

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

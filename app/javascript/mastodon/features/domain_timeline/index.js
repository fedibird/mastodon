import React from 'react';
import { connect } from 'react-redux';
import { injectIntl, FormattedMessage } from 'react-intl';
import { defineMessages } from 'react-intl';
import PropTypes from 'prop-types';
import StatusListContainer from '../ui/containers/status_list_container';
import Column from '../../components/column';
import ColumnHeader from '../../components/column_header';
import { expandDomainTimeline, clearTimelineSplitReturnAnchor } from '../../actions/timelines';
import { domainTimelineId } from '../../actions/timeline_ids';
import { addColumn, removeColumn, moveColumn } from '../../actions/columns';
import ColumnSettingsContainer from './containers/column_settings_container';
import { connectDomainStream } from '../../actions/streaming';
import { defaultColumnWidth } from 'mastodon/initial_state';
import { changeSetting } from '../../actions/settings';
import { changeColumnParams } from '../../actions/columns';
import { DEFAULT_TIMELINE_SPLIT_RATIO } from 'mastodon/components/timeline_splitter';
import StatusTimelineSplitController, { clampTimelineSplitRatio } from '../ui/components/status_timeline_split_controller';

const messages = defineMessages({
  splitUnavailable: { id: 'timeline.split_source_unavailable', defaultMessage: 'This timeline is already split in another column' },
});

const columnIndex = (columns, columnId) => columns ? columns.findIndex(column => column.get('uuid') === columnId) : -1;

const mapStateToProps = (state, props) => {
  const domain = props.params.domain;
  const columns = state.getIn(['settings', 'columns']);
  const index = columnIndex(columns, props.columnId);
  const columnWidth = (props.columnId && index >= 0) ? columns.get(index).getIn(['params', 'columnWidth']) : state.getIn(['settings', 'domain', 'columnWidth']);
  const onlyMedia = (props.columnId && index >= 0) ? columns.get(index).getIn(['params', 'other', 'onlyMedia']) : state.getIn(['settings', 'domain', 'other', 'onlyMedia']);
  const withoutMedia = (props.columnId && index >= 0) ? columns.get(index).getIn(['params', 'other', 'withoutMedia']) : state.getIn(['settings', 'domain', 'other', 'withoutMedia']);
  const withoutBot = (props.columnId && index >= 0) ? columns.get(index).getIn(['params', 'other', 'withoutBot']) : state.getIn(['settings', 'domain', 'other', 'withoutBot']);
  const sourceTimelineId = domainTimelineId(domain, { withoutBot, withoutMedia, onlyMedia });
  const timelineState = state.getIn(['timelines', sourceTimelineId]);

  return {
    hasUnread: !!timelineState && timelineState.get('unread') > 0,
    onlyMedia,
    withoutMedia,
    withoutBot,
    domain,
    columnWidth: columnWidth ?? defaultColumnWidth,
    splitRatio: clampTimelineSplitRatio(state.getIn(['settings', 'domain', 'splitRatio'], DEFAULT_TIMELINE_SPLIT_RATIO)),
  };
};

export default @connect(mapStateToProps)
@injectIntl
class DomainTimeline extends React.PureComponent {

  static contextTypes = {
    router: PropTypes.object,
  };

  static defaultProps = {
    onlyMedia: false,
    withoutMedia: false,
    withoutBot: false,
  };

  static propTypes = {
    params: PropTypes.object.isRequired,
    dispatch: PropTypes.func.isRequired,
    columnId: PropTypes.string,
    intl: PropTypes.object.isRequired,
    hasUnread: PropTypes.bool,
    multiColumn: PropTypes.bool,
    columnWidth: PropTypes.string,
    onlyMedia: PropTypes.bool,
    withoutMedia: PropTypes.bool,
    withoutBot: PropTypes.bool,
    domain: PropTypes.string,
    splitRatio: PropTypes.number,
    location: PropTypes.shape({
      key: PropTypes.string,
    }),
  };

  handlePin = () => {
    const { columnId, dispatch, onlyMedia, withoutMedia, withoutBot, domain } = this.props;

    if (columnId) {
      dispatch(removeColumn(columnId));
    } else {
      dispatch(addColumn('DOMAIN', { domain, other: { onlyMedia, withoutMedia, withoutBot } }));
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
      dispatch(changeSetting(['domain', 'columnWidth'], value));
    }
  }

  handleSplitRatioCommit = (ratio) => {
    this.props.dispatch(changeSetting(['domain', 'splitRatio'], ratio));
  }

  componentDidMount () {
    const { dispatch, onlyMedia, withoutMedia, withoutBot, domain } = this.props;

    dispatch(expandDomainTimeline(domain, { onlyMedia, withoutMedia, withoutBot }));
    this.disconnect = dispatch(connectDomainStream(domain, { onlyMedia, withoutMedia, withoutBot }));
  }

  componentDidUpdate (prevProps) {
    const { dispatch, onlyMedia, withoutMedia, withoutBot, domain } = this.props;
    const filtersChanged = prevProps.onlyMedia !== onlyMedia || prevProps.withoutMedia !== withoutMedia || prevProps.withoutBot !== withoutBot;
    const domainChanged = prevProps.domain !== domain;

    if (filtersChanged || domainChanged) {
      this.disconnect();
      dispatch(expandDomainTimeline(domain, { onlyMedia, withoutMedia, withoutBot }));
      this.disconnect = dispatch(connectDomainStream(domain, { onlyMedia, withoutMedia, withoutBot }));
    }

    if (filtersChanged && !domainChanged) {
      dispatch(clearTimelineSplitReturnAnchor(domainTimelineId(prevProps.domain, prevProps)));
    }
  }

  componentWillUnmount () {
    if (this.disconnect) {
      this.disconnect();
      this.disconnect = null;
    }
  }

  handleLoadMore = maxId => {
    const { dispatch, onlyMedia, withoutMedia, withoutBot, domain } = this.props;

    dispatch(expandDomainTimeline(domain, { maxId, onlyMedia, withoutMedia, withoutBot }));
  }

  handleLoadMoreHistory = maxId => {
    const { dispatch, onlyMedia, withoutMedia, withoutBot, domain } = this.props;

    dispatch(expandDomainTimeline(domain, { maxId, onlyMedia, withoutMedia, withoutBot, timelineId: this.splitTimelineId }));
  }

  renderColumn = (split) => {
    const { hasUnread, columnId, multiColumn, onlyMedia, withoutMedia, withoutBot, domain, columnWidth } = this.props;
    const pinned = !!columnId;
    const sourceTimelineId = domainTimelineId(domain, { withoutBot, withoutMedia, onlyMedia });
    const emptyMessage = <FormattedMessage id='empty_column.domain' defaultMessage='There is nothing here! Manually follow users from other servers to fill it up' />;

    this.splitTimelineId = split.splitTimelineId;

    let timeline;

    if (!split.isSplit) {
      timeline = (
        <StatusListContainer
          trackScroll={!pinned}
          scrollKey={`domain_timeline-${columnId}`}
          timelineId={sourceTimelineId}
          onLoadMore={this.handleLoadMore}
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
              scrollKey={`domain_timeline-${columnId}-live`}
              emptyMessage={emptyMessage}
              bindToDocument={false}
              showCard={!withoutMedia}
            />
          </div>

          {split.splitter}

          <div className='timeline-split__pane timeline-split__pane--history'>
            <StatusListContainer
              trackScroll={multiColumn ? !pinned : false}
              scrollKey={`domain_timeline-${columnId}`}
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
      <Column bindToDocument={!multiColumn} ref={split.setColumnRef} label={domain} columnWidth={columnWidth}>
        <ColumnHeader
          icon='users'
          active={hasUnread}
          title={domain}
          onPin={this.handlePin}
          onMove={this.handleMove}
          onClick={split.handleHeaderClick}
          pinned={pinned}
          multiColumn={multiColumn}
          extraButton={split.splitButton}
          showBackButton
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
    const { columnId, multiColumn, onlyMedia, withoutMedia, withoutBot, domain, splitRatio, location } = this.props;
    const sourceTimelineId = domainTimelineId(domain, { withoutBot, withoutMedia, onlyMedia });

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

import React, { Fragment } from 'react';
import { connect } from 'react-redux';
import { expandHomeTimeline } from '../../actions/timelines';
import { getHomeVisibilities } from 'mastodon/selectors';
import PropTypes from 'prop-types';
import StatusListContainer from '../ui/containers/status_list_container';
import Column from '../../components/column';
import ColumnHeader from '../../components/column_header';
import { addColumn, removeColumn, moveColumn } from '../../actions/columns';
import { defineMessages, injectIntl, FormattedMessage } from 'react-intl';
import ColumnSettingsContainer from './containers/column_settings_container';
import { Link } from 'react-router-dom';
import { fetchAnnouncements, toggleShowAnnouncements } from 'mastodon/actions/announcements';
import AnnouncementsContainer from 'mastodon/features/getting_started/containers/announcements_container';
import classNames from 'classnames';
import IconWithBadge from 'mastodon/components/icon_with_badge';
import { DEFAULT_TIMELINE_SPLIT_RATIO } from 'mastodon/components/timeline_splitter';
import { defaultColumnWidth } from 'mastodon/initial_state';
import { changeSetting } from '../../actions/settings';
import { changeColumnParams } from '../../actions/columns';
import StatusTimelineSplitController, { clampTimelineSplitRatio } from '../ui/components/status_timeline_split_controller';

const messages = defineMessages({
  title: { id: 'column.home', defaultMessage: 'Home' },
  show_announcements: { id: 'home.show_announcements', defaultMessage: 'Show announcements' },
  hide_announcements: { id: 'home.hide_announcements', defaultMessage: 'Hide announcements' },
  splitUnavailable: { id: 'timeline.split_unavailable', defaultMessage: 'Another Home timeline is already split' },
});

const mapStateToProps = (state, { columnId }) => {
  const columns = state.getIn(['settings', 'columns']);
  const index = columns ? columns.findIndex(c => c.get('uuid') === columnId) : -1;
  const columnWidth = (columnId && index >= 0) ? columns.get(index).getIn(['params', 'columnWidth']) : state.getIn(['settings', 'home', 'columnWidth']);

  return {
    hasUnread: state.getIn(['timelines', 'home', 'unread']) > 0,
    isPartial: state.getIn(['timelines', 'home', 'isPartial']),
    hasAnnouncements: !state.getIn(['announcements', 'items']).isEmpty(),
    unreadAnnouncements: state.getIn(['announcements', 'items']).count(item => !item.get('read')),
    showAnnouncements: state.getIn(['announcements', 'show']),
    visibilities: getHomeVisibilities(state),
    columnWidth: columnWidth ?? defaultColumnWidth,
    splitRatio: clampTimelineSplitRatio(state.getIn(['settings', 'home', 'splitRatio'], DEFAULT_TIMELINE_SPLIT_RATIO)),
  };
};

export default @connect(mapStateToProps)
@injectIntl
class HomeTimeline extends React.PureComponent {

  static propTypes = {
    dispatch: PropTypes.func.isRequired,
    intl: PropTypes.object.isRequired,
    hasUnread: PropTypes.bool,
    isPartial: PropTypes.bool,
    columnId: PropTypes.string,
    multiColumn: PropTypes.bool,
    columnWidth: PropTypes.string,
    hasAnnouncements: PropTypes.bool,
    unreadAnnouncements: PropTypes.number,
    showAnnouncements: PropTypes.bool,
    visibilities: PropTypes.arrayOf(PropTypes.string),
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
      dispatch(addColumn('HOME', {}));
    }
  }

  handleMove = (dir) => {
    const { columnId, dispatch } = this.props;
    dispatch(moveColumn(columnId, dir));
  }

  handleSplitRatioCommit = (ratio) => {
    this.props.dispatch(changeSetting(['home', 'splitRatio'], ratio));
  }

  handleLoadMore = maxId => {
    const { visibilities } = this.props;

    this.props.dispatch(expandHomeTimeline({ maxId, visibilities }));
  }

  handleLoadMoreHistory = maxId => {
    const { visibilities } = this.props;

    this.props.dispatch(expandHomeTimeline({
      maxId,
      visibilities,
      timelineId: this.splitTimelineId,
    }));
  }

  componentDidMount () {
    this.announcementsTimer = setTimeout(() => this.props.dispatch(fetchAnnouncements()), 700);
    this._checkIfReloadNeeded(false, this.props.isPartial);
  }

  componentDidUpdate (prevProps) {
    const { dispatch, visibilities } = this.props;

    if (prevProps.visibilities.toString() !== visibilities.toString()) {
      dispatch(expandHomeTimeline({ visibilities }));
    }

    this._checkIfReloadNeeded(prevProps.isPartial, this.props.isPartial);
  }

  componentWillUnmount () {
    this._stopPolling();

    if (this.announcementsTimer) {
      clearTimeout(this.announcementsTimer);
      this.announcementsTimer = null;
    }
  }

  _checkIfReloadNeeded (wasPartial, isPartial) {
    const { dispatch, visibilities } = this.props;

    if (wasPartial === isPartial) {
      return;
    } else if (!wasPartial && isPartial) {
      this.polling = setInterval(() => {
        dispatch(expandHomeTimeline({ visibilities }));
      }, 3000);
    } else if (wasPartial && !isPartial) {
      this._stopPolling();
    }
  }

  _stopPolling () {
    if (this.polling) {
      clearInterval(this.polling);
      this.polling = null;
    }
  }

  handleToggleAnnouncementsClick = (e) => {
    e.stopPropagation();
    this.props.dispatch(toggleShowAnnouncements());
  }

  handleWidthChange = (value) => {
    const { columnId, dispatch } = this.props;

    if (columnId) {
      dispatch(changeColumnParams(columnId, 'columnWidth', value));
    } else {
      dispatch(changeSetting(['home', 'columnWidth'], value));
    }
  }

  renderEmptyMessage () {
    return (
      <FormattedMessage id='empty_column.home' defaultMessage='Your home timeline is empty! Follow more people to fill it up. {suggestions}' values={{ suggestions: <Link to='/start'><FormattedMessage id='empty_column.home.suggestions' defaultMessage='See some suggestions' /></Link> }} />
    );
  }

  renderColumn = (split) => {
    const { intl, hasUnread, columnId, multiColumn, hasAnnouncements, unreadAnnouncements, showAnnouncements, columnWidth } = this.props;
    const pinned = !!columnId;
    const emptyMessage = this.renderEmptyMessage();

    this.splitTimelineId = split.splitTimelineId;

    let announcementsButton = null;

    if (hasAnnouncements) {
      announcementsButton = (
        <button
          key='announcements'
          className={classNames('column-header__button', { 'active': showAnnouncements })}
          title={intl.formatMessage(showAnnouncements ? messages.hide_announcements : messages.show_announcements)}
          aria-label={intl.formatMessage(showAnnouncements ? messages.hide_announcements : messages.show_announcements)}
          aria-pressed={showAnnouncements ? 'true' : 'false'}
          onClick={this.handleToggleAnnouncementsClick}
        >
          <IconWithBadge id='bullhorn' count={unreadAnnouncements} />
        </button>
      );
    }

    const extraButton = (
      <Fragment>
        {split.splitButton}
        {announcementsButton}
      </Fragment>
    );

    let timeline;

    if (!split.isSplit) {
      timeline = (
        <StatusListContainer
          trackScroll={!pinned}
          scrollKey={`home_timeline-${columnId}`}
          onLoadMore={this.handleLoadMore}
          timelineId='home'
          emptyMessage={emptyMessage}
          bindToDocument={!multiColumn}
        />
      );
    } else {
      timeline = (
        <div className='timeline-split' style={{ '--timeline-split-ratio': split.ratio }}>
          <div className='timeline-split__pane timeline-split__pane--live'>
            <StatusListContainer
              timelineId='home'
              dataTimelineId='home'
              includePendingItems
              statusLimit={40}
              manageTimelineScrollState={false}
              trackIntersection={false}
              trackScroll={false}
              scrollKey={`home_timeline-${columnId}-live`}
              emptyMessage={emptyMessage}
              bindToDocument={false}
            />
          </div>

          {split.splitter}

          <div className='timeline-split__pane timeline-split__pane--history'>
            <StatusListContainer
              trackScroll={multiColumn ? !pinned : false}
              scrollKey={`home_timeline-${columnId}`}
              onLoadMore={this.handleLoadMoreHistory}
              timelineId='home'
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
          icon='home'
          active={hasUnread}
          title={intl.formatMessage(messages.title)}
          onPin={this.handlePin}
          onMove={this.handleMove}
          onClick={split.handleHeaderClick}
          pinned={pinned}
          multiColumn={multiColumn}
          extraButton={extraButton}
          appendContent={hasAnnouncements && showAnnouncements && <AnnouncementsContainer />}
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
        sourceTimelineId='home'
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

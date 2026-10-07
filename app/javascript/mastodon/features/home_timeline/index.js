import React, { Fragment } from 'react';
import { connect } from 'react-redux';
import { createTimelineSplit, destroyTimelineSplit, expandHomeTimeline } from '../../actions/timelines';
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
import Icon from 'mastodon/components/icon';
import IconWithBadge from 'mastodon/components/icon_with_badge';
import TimelineSplitter, { DEFAULT_TIMELINE_SPLIT_RATIO, MAX_TIMELINE_SPLIT_RATIO, MIN_TIMELINE_SPLIT_RATIO } from 'mastodon/components/timeline_splitter';
import { defaultColumnWidth } from 'mastodon/initial_state';
import { changeSetting } from '../../actions/settings';
import { changeColumnParams } from '../../actions/columns';
import uuid from '../../uuid';

const messages = defineMessages({
  title: { id: 'column.home', defaultMessage: 'Home' },
  show_announcements: { id: 'home.show_announcements', defaultMessage: 'Show announcements' },
  hide_announcements: { id: 'home.hide_announcements', defaultMessage: 'Hide announcements' },
  split: { id: 'timeline.split', defaultMessage: 'Split timeline' },
  unsplit: { id: 'timeline.unsplit', defaultMessage: 'Remove timeline split' },
  splitUnavailable: { id: 'timeline.split_unavailable', defaultMessage: 'Another Home timeline is already split' },
  splitter: { id: 'timeline.splitter', defaultMessage: 'Timeline splitter' },
});

const clampSplitRatio = (value) => {
  const number = Number(value);

  if (!Number.isFinite(number)) {
    return DEFAULT_TIMELINE_SPLIT_RATIO;
  }

  return Math.min(MAX_TIMELINE_SPLIT_RATIO, Math.max(MIN_TIMELINE_SPLIT_RATIO, Math.round(number)));
};

const mapStateToProps = (state, { columnId }) => {
  const columns = state.getIn(['settings', 'columns']);
  const index = columns ? columns.findIndex(c => c.get('uuid') === columnId) : -1;
  const columnWidth = (columnId && index >= 0) ? columns.get(index).getIn(['params', 'columnWidth']) : state.getIn(['settings', 'home', 'columnWidth']);
  const splitTimelineId = state.getIn(['timelines', 'home', 'splitTimelineId']) || null;

  return {
    hasUnread: state.getIn(['timelines', 'home', 'unread']) > 0,
    isPartial: state.getIn(['timelines', 'home', 'isPartial']),
    hasAnnouncements: !state.getIn(['announcements', 'items']).isEmpty(),
    unreadAnnouncements: state.getIn(['announcements', 'items']).count(item => !item.get('read')),
    showAnnouncements: state.getIn(['announcements', 'show']),
    visibilities: getHomeVisibilities(state),
    columnWidth: columnWidth ?? defaultColumnWidth,
    splitTimelineId,
    splitRatio: clampSplitRatio(state.getIn(['settings', 'home', 'splitRatio'], DEFAULT_TIMELINE_SPLIT_RATIO)),
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
    splitTimelineId: PropTypes.string,
    splitRatio: PropTypes.number,
  };

  state = {
    ratio: null,
  };

  constructor (props) {
    super(props);
    this.instanceId = props.columnId || uuid();
  }

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

  handleHeaderClick = () => {
    this.column.scrollTop();
  }

  splitKeyPrefix = () => `home:split:${this.instanceId}:`

  ownsSplit = () => {
    const active = this.props.splitTimelineId;

    return typeof active === 'string' && active.startsWith(this.splitKeyPrefix());
  }

  getSplitTimelineId = () => {
    if (this.ownsSplit()) {
      return this.props.splitTimelineId;
    }

    return `${this.splitKeyPrefix()}${this.splitSessionId}`;
  }

  getColumnNode = () => this.column && this.column.node

  getSplitRatio = () => this.state.ratio === null ? this.props.splitRatio : this.state.ratio

  findScrollable = (target) => {
    const node = this.getColumnNode();

    if (!node) {
      return null;
    }

    if (target === 'history') {
      return node.querySelector('.timeline-split__pane--history .scrollable');
    }

    return node.querySelector('.scrollable');
  }

  captureScrollTop = (target) => {
    const scrollable = this.findScrollable(target);

    return scrollable ? scrollable.scrollTop : 0;
  }

  restorePendingScroll = () => {
    if (!this.pendingScroll) {
      return;
    }

    const node = this.findScrollable(this.pendingScroll.target);

    if (!node) {
      return;
    }

    const top = this.pendingScroll.top;
    const target = this.pendingScroll.target;
    node.scrollTop = top;

    const token = {};
    this.scrollRestoreToken = token;

    requestAnimationFrame(() => {
      if (this.scrollRestoreToken !== token || !this.pendingScroll || this.pendingScroll.target !== target) {
        return;
      }

      const next = this.findScrollable(target);

      if (next) {
        next.scrollTop = top;
      }

      if (this.pendingScroll && this.pendingScroll.target === target && this.pendingScroll.top === top) {
        this.pendingScroll = null;
      }
    });
  }

  splitTimeline = () => {
    if (!this.props.multiColumn || this.props.isPartial || this.props.splitTimelineId) {
      return;
    }

    this.splitSessionId = uuid();
    this.pendingScroll = { top: this.captureScrollTop('single'), target: 'history' };
    this.props.dispatch(createTimelineSplit('home', this.getSplitTimelineId()));
  }

  unsplitTimeline = () => {
    if (!this.ownsSplit()) {
      return;
    }

    this.pendingScroll = { top: this.captureScrollTop('history'), target: 'single' };
    this.props.dispatch(destroyTimelineSplit('home', this.getSplitTimelineId()));
  }

  handleToggleSplit = (event) => {
    event.stopPropagation();

    if (this.ownsSplit()) {
      this.unsplitTimeline();
      return;
    }

    this.splitTimeline();
  }

  handleRatioChange = (value) => {
    this.setState({ ratio: clampSplitRatio(value) });
  }

  handleRatioCommit = (value) => {
    const ratio = clampSplitRatio(value);

    this.setState({ ratio: null });

    if (ratio !== this.props.splitRatio) {
      this.props.dispatch(changeSetting(['home', 'splitRatio'], ratio));
    }
  }

  setRef = c => {
    this.column = c;
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
      timelineId: this.getSplitTimelineId(),
    }));
  }

  componentDidMount () {
    this.announcementsTimer = setTimeout(() => this.props.dispatch(fetchAnnouncements()), 700);
    this._checkIfReloadNeeded(false, this.props.isPartial);
  }

  componentDidUpdate (prevProps) {
    const { dispatch, visibilities, multiColumn } = this.props;

    if (prevProps.visibilities.toString() !== visibilities.toString()) {
      dispatch(expandHomeTimeline({ visibilities }));
    }

    if (prevProps.multiColumn && !multiColumn && this.ownsSplit()) {
      this.pendingScroll = null;
      dispatch(destroyTimelineSplit('home', this.getSplitTimelineId()));
    }

    this._checkIfReloadNeeded(prevProps.isPartial, this.props.isPartial);
    this.restorePendingScroll();
  }

  componentWillUnmount () {
    this._stopPolling();
    this.scrollRestoreToken = null;
    this.pendingScroll = null;

    if (this.announcementsTimer) {
      clearTimeout(this.announcementsTimer);
      this.announcementsTimer = null;
    }

    if (this.ownsSplit()) {
      this.props.dispatch(destroyTimelineSplit('home', this.getSplitTimelineId()));
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

  renderSplitButton () {
    const { intl, multiColumn, isPartial } = this.props;

    if (!multiColumn) {
      return null;
    }

    const ownSplit = this.ownsSplit();
    const otherSplit = !!this.props.splitTimelineId && !ownSplit;
    const disabled = otherSplit || (!ownSplit && !!isPartial);
    let label = messages.split;

    if (ownSplit) {
      label = messages.unsplit;
    } else if (otherSplit) {
      label = messages.splitUnavailable;
    }

    const text = intl.formatMessage(label);

    return (
      <button
        key='split'
        type='button'
        className={classNames('column-header__button', 'column-header__split-button', { active: ownSplit })}
        title={text}
        aria-label={text}
        aria-pressed={ownSplit ? 'true' : 'false'}
        disabled={disabled}
        onClick={this.handleToggleSplit}
      >
        <Icon id='columns' className='column-header__split-icon' />
      </button>
    );
  }

  renderTimeline () {
    const { columnId, multiColumn } = this.props;
    const pinned = !!columnId;
    const emptyMessage = this.renderEmptyMessage();

    if (!(multiColumn && this.ownsSplit())) {
      return (
        <StatusListContainer
          trackScroll={!pinned}
          scrollKey={`home_timeline-${columnId}`}
          onLoadMore={this.handleLoadMore}
          timelineId='home'
          emptyMessage={emptyMessage}
          bindToDocument={!multiColumn}
        />
      );
    }

    const splitTimelineId = this.getSplitTimelineId();
    const ratio = this.getSplitRatio();

    return (
      <div className='timeline-split' style={{ '--timeline-split-ratio': ratio }}>
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

        <TimelineSplitter
          value={ratio}
          min={MIN_TIMELINE_SPLIT_RATIO}
          max={MAX_TIMELINE_SPLIT_RATIO}
          onChange={this.handleRatioChange}
          onCommit={this.handleRatioCommit}
          onClose={this.unsplitTimeline}
          label={this.props.intl.formatMessage(messages.splitter)}
          closeLabel={this.props.intl.formatMessage(messages.unsplit)}
        />

        <div className='timeline-split__pane timeline-split__pane--history'>
          <StatusListContainer
            trackScroll={!pinned}
            scrollKey={`home_timeline-${columnId}`}
            onLoadMore={this.handleLoadMoreHistory}
            timelineId='home'
            dataTimelineId={splitTimelineId}
            trackIntersection
            emptyMessage={emptyMessage}
            bindToDocument={false}
          />
        </div>
      </div>
    );
  }

  render () {
    const { intl, hasUnread, columnId, multiColumn, hasAnnouncements, unreadAnnouncements, showAnnouncements, columnWidth } = this.props;
    const pinned = !!columnId;

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
        {this.renderSplitButton()}
        {announcementsButton}
      </Fragment>
    );

    return (
      <Column bindToDocument={!multiColumn} ref={this.setRef} label={intl.formatMessage(messages.title)} columnWidth={columnWidth}>
        <ColumnHeader
          icon='home'
          active={hasUnread}
          title={intl.formatMessage(messages.title)}
          onPin={this.handlePin}
          onMove={this.handleMove}
          onClick={this.handleHeaderClick}
          pinned={pinned}
          multiColumn={multiColumn}
          extraButton={extraButton}
          appendContent={hasAnnouncements && showAnnouncements && <AnnouncementsContainer />}
          columnWidth={columnWidth}
          onWidthChange={this.handleWidthChange}
        >
          <ColumnSettingsContainer />
        </ColumnHeader>

        {this.renderTimeline()}
      </Column>
    );
  }

}

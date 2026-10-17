import { debounce } from 'lodash';
import React from 'react';
import { connect } from 'react-redux';
import ImmutablePropTypes from 'react-immutable-proptypes';
import PropTypes from 'prop-types';
import StatusContainer from '../containers/status_container';
import ImmutablePureComponent from 'react-immutable-pure-component';
import ReloadZone from './reload_zone';
import LoadGap from './load_gap';
import ScrollableList from './scrollable_list';
import RegenerationIndicator from 'mastodon/components/regeneration_indicator';
import { addIntersectionStatusId, removeIntersectionStatusId } from 'mastodon/actions/statuses';
import { isIOS } from 'mastodon/is_mobile';
import { showReloadButton } from '../initial_state';
import { List as ImmutableList } from 'immutable';
import { HistoryAnchorNotice } from './load_window_edge';

export default @connect(null, null, null, { forwardRef: true })
class StatusList extends ImmutablePureComponent {

  static propTypes = {
    dispatch: PropTypes.func.isRequired,
    scrollKey: PropTypes.string.isRequired,
    statusIds: ImmutablePropTypes.list.isRequired,
    featuredStatusIds: ImmutablePropTypes.list,
    onLoadMore: PropTypes.func,
    onScrollToTop: PropTypes.func,
    onScroll: PropTypes.func,
    trackScroll: PropTypes.bool,
    sourceBadgesForId: PropTypes.func,
    badgeRevision: PropTypes.string,
    isLoading: PropTypes.bool,
    isPartial: PropTypes.bool,
    hasMore: PropTypes.bool,
    hasNewer: PropTypes.bool,
    onLoadNewer: PropTypes.func,
    newerLoading: PropTypes.bool,
    newerStatus: PropTypes.string,
    olderStatus: PropTypes.string,
    windowedHistory: PropTypes.bool,
    anchorResolution: PropTypes.string,
    historyUnbounded: PropTypes.bool,
    onCommitWindowAnchor: PropTypes.func,
    prepend: PropTypes.node,
    emptyMessage: PropTypes.node,
    alwaysPrepend: PropTypes.bool,
    timelineId: PropTypes.string,
    contextTypeForId: PropTypes.func,
    warningTitlesForId: PropTypes.func,
    showCard: PropTypes.bool,
    trackIntersection: PropTypes.bool,
    bindToDocument: PropTypes.bool,
    immediateStatusIds: ImmutablePropTypes.list,
    filterStatusIds: ImmutablePropTypes.list,
  };

  static defaultProps = {
    trackScroll: true,
    showCard: true,
    trackIntersection: true,
  };

  getFeaturedStatusCount = () => {
    return this.props.featuredStatusIds ? this.props.featuredStatusIds.size : 0;
  }

  componentDidMount () {
    this.commitWindowAnchor();
  }

  componentDidUpdate (prevProps) {
    const anchor = this.pendingWindowAnchor;
    const settled = prevProps.statusIds !== this.props.statusIds
      || (prevProps.isLoading && !this.props.isLoading)
      || (prevProps.newerLoading && !this.props.newerLoading);

    if (anchor && settled) {
      this.pendingWindowAnchor = null;
      this.restoreReadingAnchor(anchor, { kind: this.windowAnchorKind() });
    }
  }

  componentWillUnmount () {
    this.pendingWindowAnchor = null;
    this.handleLoadOlder.cancel();
    this.handleLoadNewer.cancel();
  }

  windowAnchorKind = () => (this.props.bindToDocument ? 'document' : 'history')

  commitWindowAnchor = () => {
    const { windowedHistory, anchorResolution, historyUnbounded, onCommitWindowAnchor } = this.props;
    const needsPlacement = historyUnbounded || anchorResolution === 'missing';

    if (!windowedHistory || !needsPlacement || !onCommitWindowAnchor) {
      return;
    }

    const anchor = this.captureReadingAnchor({ kind: this.windowAnchorKind() });

    if (anchor && anchor.statusId) {
      onCommitWindowAnchor(anchor.statusId);
    }
  }

  rememberWindowAnchor = () => {
    if (!this.props.windowedHistory) {
      return null;
    }

    const anchor = this.captureReadingAnchor({ kind: this.windowAnchorKind() });
    this.pendingWindowAnchor = anchor;

    return anchor && anchor.statusId;
  }

  getCurrentStatusIndex = (id, featured) => {
    if (featured) {
      return this.props.featuredStatusIds.indexOf(id);
    } else {
      return this.props.statusIds.indexOf(id) + this.getFeaturedStatusCount();
    }
  }

  handleMoveUp = (id, featured) => {
    const elementIndex = this.getCurrentStatusIndex(id, featured) - 1;
    this._selectChild(elementIndex, true);
  }

  handleMoveDown = (id, featured) => {
    const elementIndex = this.getCurrentStatusIndex(id, featured) + 1;
    this._selectChild(elementIndex, false);
  }

  handleLoadOlder = debounce((gapCursor) => {
    if (this.props.windowedHistory) {
      const anchorId = this.rememberWindowAnchor();
      this.props.onLoadMore(gapCursor, anchorId);
      return;
    }

    const cursor = gapCursor || (this.props.statusIds.size > 0 ? this.props.statusIds.last() : undefined);
    this.props.onLoadMore(cursor);
  }, 300, { leading: true })

  handleLoadGap = (maxId) => {
    this.handleLoadOlder(maxId);
  }

  handleLoadNewer = debounce(() => {
    if (!this.props.onLoadNewer) {
      return;
    }

    const anchorId = this.rememberWindowAnchor();
    this.props.onLoadNewer(anchorId);
  }, 300, { leading: true })

  handleReload = () => {
    location.reload();
  }

  handleIntersectionChange = (id, isIntersecting) => {
    const { dispatch } = this.props;

    if (isIntersecting) {
      dispatch(addIntersectionStatusId(id));
    } else {
      dispatch(removeIntersectionStatusId(id));
    }
  }

  _selectChild (index, align_top) {
    const container = this.node.node;
    const element = container.querySelector(`article:nth-of-type(${index + 1}) .focusable`);

    if (element) {
      if (align_top && container.scrollTop > element.offsetTop) {
        element.scrollIntoView(true);
      } else if (!align_top && container.scrollTop + container.clientHeight < element.offsetTop + element.offsetHeight) {
        element.scrollIntoView(false);
      }
      element.focus();
    }
  }

  setRef = c => {
    this.node = c;
  }

  getTimelineScrollHost = (kind) => (
    this.node && this.node.getTimelineScrollHost ? this.node.getTimelineScrollHost(kind) : { kind: kind || 'pane', list: null, scroller: null }
  )

  captureReadingAnchor = (options) => (
    this.node && this.node.captureReadingAnchor ? this.node.captureReadingAnchor(options) : { version: 1, statusId: null, displayRowId: null, offsetPx: 0, alignment: 'top' }
  )

  restoreReadingAnchor = (anchor, options) => (
    this.node && this.node.restoreReadingAnchor ? this.node.restoreReadingAnchor(anchor, options) : { ok: false, reason: 'missing_host' }
  )

  scrollToLoadedStatus = (statusId, options) => (
    this.node && this.node.scrollToLoadedStatus ? this.node.scrollToLoadedStatus(statusId, options) : { ok: false, reason: 'missing_host' }
  )

  render () {
    const { statusIds, featuredStatusIds, filterStatusIds, onLoadMore, onLoadNewer, timelineId, contextTypeForId, warningTitlesForId, sourceBadgesForId, badgeRevision, showCard, trackIntersection, immediateStatusIds, windowedHistory, anchorResolution, historyUnbounded, onCommitWindowAnchor, hasNewer, newerLoading, newerStatus, olderStatus, prepend, ...other } = this.props;

    void badgeRevision;
    void onCommitWindowAnchor;
    const { isLoading, isPartial } = other;
    const contextTypeFor = (statusId) => contextTypeForId ? (contextTypeForId(statusId) || timelineId) : timelineId;
    const warningTitlesFor = (statusId) => warningTitlesForId ? warningTitlesForId(statusId) : undefined;

    if (isPartial) {
      return <RegenerationIndicator />;
    }

    // timelineId becomes the filter context. A mix column id is unknown to
    // toServerSideType and would be treated as public, so P2 must pass each
    // status the filter context of its source instead of the mix id.
    let scrollableContent = (isLoading || statusIds.size > 0) ? (
      statusIds.map((statusId, index) => statusId === null ? (
        <LoadGap
          key={'gap:' + statusIds.get(index + 1)}
          disabled={isLoading}
          maxId={index > 0 ? statusIds.get(index - 1) : null}
          onClick={this.handleLoadGap}
        />
      ) : (
        <StatusContainer
          key={statusId}
          id={statusId}
          onMoveUp={this.handleMoveUp}
          onMoveDown={this.handleMoveDown}
          contextType={contextTypeFor(statusId)}
          warningTitles={warningTitlesFor(statusId)}
          sourceBadges={sourceBadgesForId ? sourceBadgesForId(statusId) : undefined}
          scrollKey={this.props.scrollKey}
          showThread
          showCard={showCard}
          immediate={!!(immediateStatusIds && immediateStatusIds.includes(statusId))}
        />
      ))
    ) : ImmutableList();

    if (scrollableContent && featuredStatusIds) {
      scrollableContent = featuredStatusIds.map(statusId => (
        <StatusContainer
          key={`f-${statusId}`}
          id={statusId}
          featured
          onMoveUp={this.handleMoveUp}
          onMoveDown={this.handleMoveDown}
          contextType={contextTypeFor(statusId)}
          sourceBadges={sourceBadgesForId ? sourceBadgesForId(statusId) : undefined}
          showThread
          showCard={showCard}
        />
      )).concat(scrollableContent);
    }

    if (showReloadButton && scrollableContent && isIOS()) {
      scrollableContent = scrollableContent.unshift(<ReloadZone key='reload' onClick={this.handleReload} />);
    }

    const showAnchorNotice = windowedHistory && (anchorResolution === 'missing' || (historyUnbounded && anchorResolution === 'unspecified'));
    const historyPrepend = showAnchorNotice ? <HistoryAnchorNotice key='history-anchor' /> : null;
    let listPrepend = prepend;

    if (historyPrepend && prepend) {
      listPrepend = <React.Fragment>{historyPrepend}{prepend}</React.Fragment>;
    } else if (historyPrepend) {
      listPrepend = historyPrepend;
    }

    return (
      <ScrollableList {...other} prepend={listPrepend} hasNewer={hasNewer} onLoadNewer={onLoadNewer && this.handleLoadNewer} newerLoading={newerLoading} newerStatus={newerStatus} olderStatus={windowedHistory ? olderStatus : undefined} filterStatusIds={statusIds.concat(filterStatusIds || ImmutableList(), featuredStatusIds || ImmutableList(), immediateStatusIds || ImmutableList())} showLoading={isLoading && statusIds.size === 0} onLoadMore={onLoadMore && this.handleLoadOlder} onIntersectionChange={trackIntersection ? this.handleIntersectionChange : undefined} ref={this.setRef}>
        {scrollableContent}
      </ScrollableList>
    );
  }

}

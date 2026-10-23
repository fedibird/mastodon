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
import { planSeekScroll } from '../timeline_seek/window';
import { completeSurfaceResume, emitHistorySurfaceScroll, emitHistorySurfaceUnmount, bindHistorySurface, peekSurfaceResume } from '../timeline_position/surface';

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
    readingSurface: PropTypes.bool,
    anchorResolution: PropTypes.string,
    historyUnbounded: PropTypes.bool,
    windowRevision: PropTypes.number,
    onCommitWindowAnchor: PropTypes.func,
    seekScrollPending: PropTypes.bool,
    seekSessionId: PropTypes.string,
    seekAnchorId: PropTypes.string,
    seekScrollRevision: PropTypes.number,
    onSeekScroll: PropTypes.func,
    historySurfaceId: PropTypes.string,
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

  anchorAttempts = 0;

  componentDidMount () {
    this.bindHistorySurface();
    this.scheduleAnchorCapture();
    this.scheduleSeekScroll();
  }

  componentDidUpdate (prevProps) {
    const pending = this.pendingWindowAnchor;
    const revision = this.props.windowRevision || 0;

    if (pending && revision !== pending.revision) {
      this.pendingWindowAnchor = null;

      if (!this.props.seekScrollPending && pending.anchor && pending.anchor.statusId) {
        this.restoreReadingAnchor(pending.anchor, { kind: this.windowAnchorKind() });
      }
    } else if (pending) {
      const loading = !!(this.props.isLoading || this.props.newerLoading);
      const wasLoading = !!(prevProps.isLoading || prevProps.newerLoading);

      if (!loading && wasLoading) {
        this.pendingWindowAnchor = null;
      }
    }

    if (this.props.historyUnbounded && !prevProps.historyUnbounded) {
      this.anchorAttempts = 0;
    }

    this.bindHistorySurface();
    this.scheduleAnchorCapture();
    this.scheduleSeekScroll();
  }

  componentWillUnmount () {
    this.seekScrollUnmounted = true;
    this.pendingWindowAnchor = null;
    this.releaseHistorySurface(true);
    this.stopAnchorCapture();
    this.cancelSeekScrollFrame();
    this.handleLoadOlder.cancel();
    this.handleLoadNewer.cancel();
  }

  bindHistorySurface = () => {
    const id = this.props.historySurfaceId;

    if (this.boundSurfaceId === id) {
      return;
    }

    this.releaseHistorySurface(false);

    if (!id) {
      return;
    }

    this.boundSurfaceId = id;
    this.unbindSurface = bindHistorySurface(id, {
      capture: () => this.captureReadingAnchor({
        kind: this.windowAnchorKind(),
        capturedAt: new Date().toISOString(),
      }),
      restore: (anchor, options) => this.restoreArmedAnchor(anchor, options),
    });
  }

  releaseHistorySurface = (notify) => {
    const id = this.boundSurfaceId;

    if (notify && id) {
      emitHistorySurfaceUnmount(id, this.captureReadingAnchor({
        kind: this.windowAnchorKind(),
        capturedAt: new Date().toISOString(),
      }));
    }

    if (this.unbindSurface) {
      this.unbindSurface();
      this.unbindSurface = null;
    }

    this.boundSurfaceId = null;
  }

  restoreArmedAnchor = (anchor, options = {}) => {
    const statusId = anchor && anchor.statusId;
    const displayRowId = anchor && anchor.displayRowId;
    const featured = typeof displayRowId === 'string' && displayRowId.indexOf('f-') === 0;
    const rendered = this.props.statusIds;

    if (rendered && statusId && !featured && !rendered.includes(statusId)) {
      return { ok: false, reason: 'filtered', moved: false };
    }

    return this.restoreReadingAnchor(anchor, {
      allowProvisionalFallback: !!options.allowProvisionalFallback,
      kind: options.kind || this.windowAnchorKind(),
    });
  }

  handleUserScroll = () => {
    this.seekScrollGeneration = (this.seekScrollGeneration || 0) + 1;
    const key = this.seekScrollKey();

    if (key && this.seekScrollSettled !== key) {
      this.cancelSeekScrollFrame();
      this.seekScrollScheduled = null;
      this.seekScrollSettled = key;

      if (this.props.onSeekScroll) {
        this.props.onSeekScroll({
          sessionId: this.props.seekSessionId,
          revision: this.props.seekScrollRevision,
          anchorId: this.props.seekAnchorId,
          scrolled: false,
          reason: 'user_scroll',
        });
      }
    }

    if (this.props.onUserScroll) {
      this.props.onUserScroll();
    }

    if (this.props.historySurfaceId) {
      emitHistorySurfaceScroll(this.props.historySurfaceId);
    }
  }

  seekScrollKey = () => {
    const { seekScrollPending, seekSessionId, seekAnchorId, seekScrollRevision, windowRevision } = this.props;

    if (!seekScrollPending || !seekSessionId || !seekAnchorId) {
      return null;
    }

    if ((seekScrollRevision || 0) !== (windowRevision || 0)) {
      return null;
    }

    return `${seekSessionId}:${seekScrollRevision}:${seekAnchorId}`;
  }

  cancelSeekScrollFrame = () => {
    if (this.seekScrollFrame) {
      cancelAnimationFrame(this.seekScrollFrame);
      this.seekScrollFrame = null;
    }
  }

  // One frame after the window commit. The filtered status list and the
  // articles exist by then. A newer session, unmount, or a dropped pending
  // flag cancels the frame before it moves the scroller.
  scheduleSeekScroll = () => {
    const key = this.seekScrollKey();

    if (!key) {
      this.cancelSeekScrollFrame();
      this.seekScrollScheduled = null;
      return;
    }

    if (this.seekScrollSettled === key || this.seekScrollScheduled === key) {
      return;
    }

    this.cancelSeekScrollFrame();
    this.seekScrollScheduled = key;
    const generation = this.seekScrollGeneration || 0;

    this.seekScrollFrame = requestAnimationFrame(() => {
      this.seekScrollFrame = null;

      if (this.seekScrollUnmounted || (this.seekScrollGeneration || 0) !== generation || this.seekScrollKey() !== key) {
        return;
      }

      const { seekSessionId, seekScrollRevision, seekAnchorId, statusIds, onSeekScroll, historySurfaceId } = this.props;
      const armed = peekSurfaceResume(historySurfaceId);
      const resumeAnchor = armed && armed.anchor && (armed.anchor.statusId === seekAnchorId || armed.anchor.displayRowId === seekAnchorId)
        ? armed.anchor
        : null;
      const plan = planSeekScroll({ anchorId: seekAnchorId, renderedIds: statusIds });
      let settled = plan;

      if (plan.scroll) {
        const moved = resumeAnchor
          ? this.restoreArmedAnchor(resumeAnchor, { allowProvisionalFallback: !!armed.allowFallback })
          : (this.scrollToLoadedStatus(seekAnchorId) || { ok: false, reason: 'not_loaded' });

        settled = moved.ok
          ? { scroll: true, reason: 'loaded', anchorId: seekAnchorId }
          : planSeekScroll({
            anchorId: seekAnchorId,
            renderedIds: statusIds,
            articlePresent: false,
          });
      }

      this.seekScrollSettled = key;

      if (onSeekScroll) {
        onSeekScroll({
          sessionId: seekSessionId,
          revision: seekScrollRevision,
          anchorId: seekAnchorId,
          scrolled: !!settled.scroll,
          reason: settled.reason,
        });
      }

      if (armed && historySurfaceId) {
        completeSurfaceResume(historySurfaceId, {
          requestId: armed.requestId,
          scrolled: !!settled.scroll,
          reason: settled.reason,
        });
      }
    });
  }

  stopAnchorCapture = () => {
    if (this.anchorFrame) {
      cancelAnimationFrame(this.anchorFrame);
      this.anchorFrame = null;
    }
  }

  windowAnchorKind = () => (this.props.bindToDocument ? 'document' : 'history')

  scheduleAnchorCapture = () => {
    const { windowedHistory, historyUnbounded, onCommitWindowAnchor } = this.props;

    if (!windowedHistory || !historyUnbounded || !onCommitWindowAnchor || this.anchorFrame || this.anchorAttempts >= 8) {
      return;
    }

    const tick = () => {
      this.anchorFrame = null;

      if (!this.props.historyUnbounded || !this.props.onCommitWindowAnchor) {
        return;
      }

      const anchor = this.captureReadingAnchor({ kind: this.windowAnchorKind() });

      if (anchor && anchor.statusId) {
        this.rememberWindowAnchor(anchor);
        this.props.onCommitWindowAnchor(anchor.statusId);
        return;
      }

      this.anchorAttempts += 1;

      if (this.anchorAttempts < 8) {
        this.anchorFrame = requestAnimationFrame(tick);
        return;
      }

      this.props.onCommitWindowAnchor(null);
    };

    this.anchorFrame = requestAnimationFrame(tick);
  }

  rememberWindowAnchor = (captured) => {
    if (!this.props.windowedHistory) {
      return null;
    }

    const anchor = captured || this.captureReadingAnchor({ kind: this.windowAnchorKind() });

    this.pendingWindowAnchor = {
      anchor,
      revision: this.props.windowRevision || 0,
    };

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
      if (this.props.newerLoading || this.props.historyUnbounded) {
        return;
      }

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
    if (!this.props.onLoadNewer || this.props.isLoading || this.props.historyUnbounded) {
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
    const { statusIds, featuredStatusIds, filterStatusIds, onLoadMore, onLoadNewer, timelineId, dataTimelineId, contextHostId, contextTypeForId, warningTitlesForId, sourceBadgesForId, badgeRevision, showCard, trackIntersection, immediateStatusIds, windowedHistory, readingSurface, anchorResolution, historyUnbounded, onCommitWindowAnchor, hasNewer, newerLoading, newerStatus, olderStatus, prepend, seekScrollPending, seekSessionId, seekAnchorId, seekScrollRevision, onSeekScroll, historySurfaceId, onUserScroll, ...other } = this.props;

    void badgeRevision;
    void onCommitWindowAnchor;
    void seekScrollPending;
    void seekSessionId;
    void seekAnchorId;
    void seekScrollRevision;
    void onSeekScroll;
    void historySurfaceId;
    void onUserScroll;
    const { isLoading, isPartial } = other;
    const surfaceTimelineId = dataTimelineId || timelineId;
    const rowHostId = contextHostId || (
      typeof surfaceTimelineId === 'string' && surfaceTimelineId.indexOf(':split:') !== -1
        ? surfaceTimelineId
        : (this.props.scrollKey || surfaceTimelineId || 'timeline')
    );
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
          contextHostId={rowHostId}
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
          contextHostId={rowHostId}
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

    const anchorSourceKey = `${surfaceTimelineId || ''}:${windowedHistory ? 'history' : 'stream'}`;
    const showAnchorNotice = windowedHistory && (anchorResolution === 'missing' || (historyUnbounded && anchorResolution === 'unspecified'));
    const historyPrepend = showAnchorNotice ? <HistoryAnchorNotice key='history-anchor' /> : null;
    let listPrepend = prepend;

    if (historyPrepend && prepend) {
      listPrepend = <React.Fragment>{historyPrepend}{prepend}</React.Fragment>;
    } else if (historyPrepend) {
      listPrepend = historyPrepend;
    }

    return (
      <ScrollableList {...other} prepend={listPrepend} hasNewer={hasNewer} onLoadNewer={onLoadNewer && this.handleLoadNewer} newerLoading={newerLoading} newerStatus={newerStatus} olderStatus={windowedHistory ? olderStatus : undefined} windowedHistory={!!windowedHistory} readingSurface={!!readingSurface} anchorSourceKey={anchorSourceKey} filterStatusIds={statusIds.concat(filterStatusIds || ImmutableList(), featuredStatusIds || ImmutableList(), immediateStatusIds || ImmutableList())} showLoading={isLoading && statusIds.size === 0} onLoadMore={onLoadMore && this.handleLoadOlder} onUserScroll={historySurfaceId ? this.handleUserScroll : onUserScroll} onIntersectionChange={trackIntersection ? this.handleIntersectionChange : undefined} ref={this.setRef}>
        {scrollableContent}
      </ScrollableList>
    );
  }

}

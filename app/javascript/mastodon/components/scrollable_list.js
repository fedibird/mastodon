import React, { PureComponent } from 'react';
import ScrollContainer from 'mastodon/containers/scroll_container';
import PropTypes from 'prop-types';
import IntersectionObserverArticleContainer from '../containers/intersection_observer_article_container';
import LoadMore from './load_more';
import LoadPending from './load_pending';
import LoadWindowEdge from './load_window_edge';
import IntersectionObserverWrapper from '../features/ui/util/intersection_observer_wrapper';
import { throttle } from 'lodash';
import { List as ImmutableList } from 'immutable';
import classNames from 'classnames';
import { attachFullscreenListener, detachFullscreenListener, isFullscreen } from '../features/ui/util/fullscreen';
import LoadingIndicator from './loading_indicator';
import { connect } from 'react-redux';
import { FilterSurface } from '../filter_reconciliation/surface';
import {
  TIMELINE_ANCHOR_REASONS,
  TIMELINE_ANCHOR_VERSION,
  captureTimelineAnchor,
  isDecimalStatusId,
  readDocumentVisibleTop,
  restoreTimelineAnchor,
  scheduleTimelineAnchorFrames,
  scrollToLoadedTimelineStatus,
} from '../timeline_navigation';

const MOUSE_IDLE_DELAY = 300;

const mapStateToProps = (state, { scrollKey }) => {
  return {
    preventScroll: scrollKey === state.getIn(['dropdown_menu', 'scroll_key']),
  };
};

export default @connect(mapStateToProps, null, null, { forwardRef: true })
class ScrollableList extends PureComponent {

  static contextTypes = {
    router: PropTypes.object,
  };

  static propTypes = {
    scrollKey: PropTypes.string.isRequired,
    onLoadMore: PropTypes.func,
    onLoadPending: PropTypes.func,
    onScrollToTop: PropTypes.func,
    onScroll: PropTypes.func,
    trackScroll: PropTypes.bool,
    isLoading: PropTypes.bool,
    showLoading: PropTypes.bool,
    hasMore: PropTypes.bool,
    hasNewer: PropTypes.bool,
    onLoadNewer: PropTypes.func,
    newerLoading: PropTypes.bool,
    newerStatus: PropTypes.string,
    olderStatus: PropTypes.string,
    numPending: PropTypes.number,
    prepend: PropTypes.node,
    append: PropTypes.node,
    alwaysPrepend: PropTypes.bool,
    emptyMessage: PropTypes.node,
    children: PropTypes.node,
    bindToDocument: PropTypes.bool,
    preventScroll: PropTypes.bool,
    tabIndex: PropTypes.string,
    onIntersectionChange: PropTypes.func,
    dispatch: PropTypes.func,
    filterStatusIds: PropTypes.oneOfType([PropTypes.array, PropTypes.object]),
    filterIdForRow: PropTypes.func,
  };

  static defaultProps = {
    trackScroll: true,
    tabIndex: '0',
  };

  state = {
    fullscreen: null,
    cachedMediaWidth: 250, // Default media/card width using default Mastodon theme
  };

  intersectionObserverWrapper = new IntersectionObserverWrapper();

  handleScroll = throttle(() => {
    if (this.node) {
      const scrollTop = this.getScrollTop();
      const scrollHeight = this.getScrollHeight();
      const clientHeight = this.getClientHeight();
      const offset = scrollHeight - scrollTop - clientHeight;
      const anchorJump = this._isAnchorJumpScroll(scrollTop);

      // A jump to an already loaded row must not page in more. A real user
      // scroll, including one that arrives before this throttled call runs,
      // still loads when it is within 400px of the end.
      const olderBlocked = this.props.olderStatus === 'error' || this.props.olderStatus === 'unavailable';

      if (!anchorJump && 400 > offset && this.props.onLoadMore && this.props.hasMore && !this.props.isLoading && !olderBlocked) {
        this.props.onLoadMore();
      }

      if (scrollTop < 100 && this.props.onScrollToTop) {
        this.props.onScrollToTop();
      } else if (this.props.onScroll) {
        this.props.onScroll();
      }

      if (this._anchorScrollSuppressedLoad && !anchorJump) {
        this.scrollToTopOnMouseIdle = false;
        this._cancelAnchorCorrection();
        this._anchorScrollSuppressedLoad = false;
        this._syntheticScrollTop = null;
      } else if (!this.lastScrollWasSynthetic) {
        // If the last scroll wasn't caused by setScrollTop(), assume it was
        // intentional and cancel any pending scroll reset on mouse idle
        this.scrollToTopOnMouseIdle = false;
        this._cancelAnchorCorrection();
      }
      if (this._syntheticScrollDepth === 0) {
        this.lastScrollWasSynthetic = false;
      }
    }
  }, 150, {
    trailing: true,
  });

  mouseIdleTimer = null;
  mouseMovedRecently = false;
  lastScrollWasSynthetic = false;
  scrollToTopOnMouseIdle = false;
  _syntheticScrollDepth = 0;
  _anchorScrollSuppressedLoad = false;
  _syntheticScrollTop = null;

  _isAnchorJumpScroll = (scrollTop) => {
    if (this._syntheticScrollDepth > 0) {
      return true;
    }

    return this._anchorScrollSuppressedLoad &&
      this._syntheticScrollTop !== null &&
      Math.abs(scrollTop - this._syntheticScrollTop) <= 1;
  }

  _getScrollingElement = () => {
    if (this.props.bindToDocument) {
      return (document.scrollingElement || document.body);
    } else {
      return this.node;
    }
  }

  setScrollTop = newScrollTop => {
    if (this.getScrollTop() !== newScrollTop) {
      this.lastScrollWasSynthetic = true;

      this._getScrollingElement().scrollTop = newScrollTop;
    }
  };

  clearMouseIdleTimer = () => {
    if (this.mouseIdleTimer === null) {
      return;
    }

    clearTimeout(this.mouseIdleTimer);
    this.mouseIdleTimer = null;
  };

  handleMouseMove = throttle(() => {
    // As long as the mouse keeps moving, clear and restart the idle timer.
    this.clearMouseIdleTimer();
    this.mouseIdleTimer = setTimeout(this.handleMouseIdle, MOUSE_IDLE_DELAY);

    if (!this.mouseMovedRecently && this.getScrollTop() === 0) {
      // Only set if we just started moving and are scrolled to the top.
      this.scrollToTopOnMouseIdle = true;
    }

    // Save setting this flag for last, so we can do the comparison above.
    this.mouseMovedRecently = true;
  }, MOUSE_IDLE_DELAY / 2);

  handleWheel = throttle(() => {
    this.scrollToTopOnMouseIdle = false;
  }, 150, {
    trailing: true,
  });

  handleMouseIdle = () => {
    if (this.scrollToTopOnMouseIdle && !this.props.preventScroll) {
      this.setScrollTop(0);
    }

    this.mouseMovedRecently = false;
    this.scrollToTopOnMouseIdle = false;
  }

  componentDidMount () {
    this.attachScrollListener();
    this.attachIntersectionObserver();

    attachFullscreenListener(this.onFullScreenChange);

    // Handle initial scroll posiiton
    this.handleScroll();
    this.updateFilterSurface();
  }

  updateFilterSurface = () => {
    const location = this.context.router?.history?.location || this.context.router?.route?.location;
    if (location?.key && !location.state?.mastodonModalKey) this.filterRouteKey = location.key;
    const surfaceKey = `${this.filterRouteKey || ''}:${this.props.scrollKey}`;
    if (this.filterSurface && (this.filterSurface.node !== this.node || this.filterSurface.scrollKey !== surfaceKey || this.filterSurface.bindToDocument !== this.props.bindToDocument || !this.props.filterStatusIds)) {
      this.filterSurface.destroy();
      this.filterSurface = null;
    }
    if (!this.props.filterStatusIds || !this.node) return;
    if (!this.filterHistoryUnlisten) this.filterHistoryUnlisten = this.context.router?.history?.listen(nextLocation => {
      if (!nextLocation.state?.mastodonModalKey) this.updateFilterSurface();
    });
    if (!this.filterSurface) {
      this.filterSurface = new FilterSurface(this.props.dispatch, this.node, { ...this.props, scrollKey: surfaceKey, ids: this.props.filterStatusIds, idForRow: this.props.filterIdForRow });
    } else {
      this.filterSurface.preventScroll = this.props.preventScroll;
      this.filterSurface.idForRow = this.props.filterIdForRow || this.filterSurface.idForRow;
      this.filterSurface.update(this.props.filterStatusIds);
    }
  }

  handleIntersectionChange = (id, intersecting, entry) => {
    this.filterSurface?.intersection(id, intersecting, entry);
    this.props.onIntersectionChange?.(id, intersecting);
  }

  handleFilterLayout = () => this.filterSurface?.prepare();

  getScrollPosition = () => {
    if (this.node && (this.getScrollTop() > 0 || this.mouseMovedRecently)) {
      return { height: this.getScrollHeight(), top: this.getScrollTop() };
    } else {
      return null;
    }
  }

  getScrollTop = () => {
    return this._getScrollingElement().scrollTop;
  }

  getScrollHeight = () => {
    return this._getScrollingElement().scrollHeight;
  }

  getClientHeight = () => {
    return this._getScrollingElement().clientHeight;
  }

  updateScrollBottom = (snapshot) => {
    const newScrollTop = this.getScrollHeight() - snapshot;

    this.setScrollTop(newScrollTop);
  }

  getSnapshotBeforeUpdate (prevProps) {
    const someItemInserted = React.Children.count(prevProps.children) > 0 &&
      React.Children.count(prevProps.children) < React.Children.count(this.props.children) &&
      this.getFirstChildKey(prevProps) !== this.getFirstChildKey(this.props);
    const pendingChanged = (prevProps.numPending > 0) !== (this.props.numPending > 0);

    if (pendingChanged || someItemInserted && (this.getScrollTop() > 0 || this.mouseMovedRecently || this.props.preventScroll)) {
      return this.getScrollHeight() - this.getScrollTop();
    } else {
      return null;
    }
  }

  componentDidUpdate (prevProps, prevState, snapshot) {
    if (prevProps.bindToDocument !== this.props.bindToDocument) {
      this.detachScrollListener(prevProps.bindToDocument);
      this.attachScrollListener();
      this.attachIntersectionObserver();
    }
    // Reset the scroll position when a new child comes in in order not to
    // jerk the scrollbar around if you're already scrolled down the page.
    if (snapshot !== null) {
      this.setScrollTop(this.getScrollHeight() - snapshot);
    }

    if (prevProps.scrollKey !== this.props.scrollKey || prevProps.bindToDocument !== this.props.bindToDocument) {
      this._cancelAnchorCorrection();
    }

    this.updateFilterSurface();
  }

  _currentLocationKey = () => {
    const location = this.context.router?.history?.location || this.context.router?.route?.location;

    return location ? location.key : null;
  }

  _cancelAnchorCorrection = () => {
    if (this._anchorCancel) {
      this._anchorCancel();
      this._anchorCancel = null;
    }
  }

  _childStatusIds = () => {
    const ids = [];

    React.Children.forEach(this.props.children, (child) => {
      if (child && isDecimalStatusId(child.key)) {
        ids.push(child.key);
      }
    });

    return ids;
  }

  getTimelineScrollHost = (kind) => {
    const resolved = kind || (this.props.bindToDocument ? 'document' : 'pane');

    if (resolved === 'document') {
      return {
        kind: 'document',
        list: this.node || null,
        scroller: document.scrollingElement || document.body,
      };
    }

    return {
      kind: resolved === 'live' || resolved === 'history' ? resolved : 'pane',
      list: this.node || null,
      scroller: this.node || null,
    };
  }

  getTimelineVisibleTop = (host) => {
    const scrollHost = host || this.getTimelineScrollHost();

    if (!scrollHost || scrollHost.kind === 'document') {
      return readDocumentVisibleTop();
    }

    if (!scrollHost.scroller || typeof scrollHost.scroller.getBoundingClientRect !== 'function') {
      return 0;
    }

    return scrollHost.scroller.getBoundingClientRect().top;
  }

  _anchorHostMissing = () => {
    if (this._anchorUnmounted) {
      return { ok: false, reason: TIMELINE_ANCHOR_REASONS.STALE };
    }

    if (!this.node) {
      return { ok: false, reason: TIMELINE_ANCHOR_REASONS.MISSING_HOST };
    }

    return null;
  }

  _provisionalFallback = (allowed, host) => {
    if (!allowed) {
      return 'none';
    }

    return host.kind === 'document' ? 'document-delta' : 'absolute';
  }

  _beginSyntheticAnchorScroll = () => {
    this.scrollToTopOnMouseIdle = false;
    this._syntheticScrollDepth += 1;
    this.lastScrollWasSynthetic = true;
    this._anchorScrollSuppressedLoad = true;

    return this.getScrollTop();
  }

  _finishSyntheticAnchorScroll = (before) => {
    this._syntheticScrollDepth = Math.max(0, this._syntheticScrollDepth - 1);
    const top = this.getScrollTop();
    const moved = top !== before;

    // A synchronous scroll listener clears the synthetic flag. Put it back
    // when this jump actually moved, so the throttled trailing event does
    // not cancel the one or two correction frames.
    this.lastScrollWasSynthetic = moved || this._syntheticScrollDepth > 0;

    if (moved) {
      this._syntheticScrollTop = top;
    } else if (this._syntheticScrollDepth === 0) {
      const stillAtAnchor = this._syntheticScrollTop !== null && Math.abs(top - this._syntheticScrollTop) <= 1;

      this._anchorScrollSuppressedLoad = stillAtAnchor;
    }
  }

  _scheduleAnchorCorrection = (generation, anchor) => {
    this._cancelAnchorCorrection();
    const cursor = { top: this.getScrollTop() };
    const locationKey = this._currentLocationKey();

    this._anchorCancel = scheduleTimelineAnchorFrames({
      frames: 2,
      shouldAbort: () => (
        this._anchorUnmounted ||
        this._anchorGeneration !== generation ||
        this._currentLocationKey() !== locationKey ||
        Math.abs(this.getScrollTop() - cursor.top) > 1
      ),
      apply: () => {
        if (this._anchorUnmounted || this._anchorGeneration !== generation) {
          return;
        }

        const before = this._beginSyntheticAnchorScroll();
        const host = this.getTimelineScrollHost();
        const result = restoreTimelineAnchor({
          scrollHost: host,
          visibleTop: this.getTimelineVisibleTop(host),
          anchor,
          fallback: 'none',
        });

        if (result.ok) {
          cursor.top = this.getScrollTop();
        }

        this._finishSyntheticAnchorScroll(before);
      },
    });
  }

  captureReadingAnchor = ({ alignment = 'top', capturedAt, kind } = {}) => {
    const missing = this._anchorHostMissing();

    if (missing) {
      return {
        version: TIMELINE_ANCHOR_VERSION,
        statusId: null,
        displayRowId: null,
        offsetPx: 0,
        alignment: alignment === 'center' ? 'center' : 'top',
      };
    }

    const host = this.getTimelineScrollHost(kind);

    return captureTimelineAnchor({
      scrollHost: host,
      visibleTop: this.getTimelineVisibleTop(host),
      alignment,
      capturedAt,
    });
  }

  restoreReadingAnchor = (anchor, { allowProvisionalFallback = false, kind } = {}) => {
    const missing = this._anchorHostMissing();

    if (missing) {
      return missing;
    }

    this._anchorGeneration = (this._anchorGeneration || 0) + 1;
    const generation = this._anchorGeneration;
    const host = this.getTimelineScrollHost(kind);
    const before = this._beginSyntheticAnchorScroll();
    const result = restoreTimelineAnchor({
      scrollHost: host,
      visibleTop: this.getTimelineVisibleTop(host),
      anchor,
      fallback: this._provisionalFallback(allowProvisionalFallback, host),
    });

    this._finishSyntheticAnchorScroll(before);

    if (result.ok) {
      this._scheduleAnchorCorrection(generation, result.anchor || anchor);
    }

    return result;
  }

  scrollToLoadedStatus = (statusId, { alignment = 'top', offsetPx = 0, kind, loadedStatusIds, displayRowId } = {}) => {
    const missing = this._anchorHostMissing();

    if (missing) {
      return missing;
    }

    this._anchorGeneration = (this._anchorGeneration || 0) + 1;
    const generation = this._anchorGeneration;
    const host = this.getTimelineScrollHost(kind);
    const before = this._beginSyntheticAnchorScroll();
    const result = scrollToLoadedTimelineStatus({
      scrollHost: host,
      visibleTop: this.getTimelineVisibleTop(host),
      statusId,
      displayRowId,
      alignment,
      offsetPx,
      loadedStatusIds: loadedStatusIds || this._childStatusIds(),
    });

    this._finishSyntheticAnchorScroll(before);

    if (result.ok && result.anchor) {
      this._scheduleAnchorCorrection(generation, result.anchor);
    }

    return result;
  }

  cacheMediaWidth = (width) => {
    if (width && this.state.cachedMediaWidth !== width) {
      this.setState({ cachedMediaWidth: width });
    }
  }

  componentWillUnmount () {
    this._anchorUnmounted = true;
    this._cancelAnchorCorrection();
    this.filterHistoryUnlisten?.();
    this.filterSurface?.destroy();
    this.handleScroll.cancel();
    this.handleWheel.cancel();
    this.handleMouseMove.cancel();
    this.clearMouseIdleTimer();
    this.detachScrollListener();
    this.detachIntersectionObserver();

    detachFullscreenListener(this.onFullScreenChange);
  }

  onFullScreenChange = () => {
    this.setState({ fullscreen: isFullscreen() });
  }

  attachIntersectionObserver () {
    let nodeOptions = {
      root: this.node,
      rootMargin: '300% 0px',
    };

    this.intersectionObserverWrapper
      .connect(this.props.bindToDocument ? {} : nodeOptions);
  }

  detachIntersectionObserver () {
    this.intersectionObserverWrapper.disconnect();
  }

  attachScrollListener () {
    if (this.props.bindToDocument) {
      document.addEventListener('scroll', this.handleScroll);
      document.addEventListener('wheel', this.handleWheel);
    } else {
      this.node.addEventListener('scroll', this.handleScroll);
      this.node.addEventListener('wheel', this.handleWheel);
    }
  }

  detachScrollListener (bindToDocument = this.props.bindToDocument) {
    if (bindToDocument) {
      document.removeEventListener('scroll', this.handleScroll);
      document.removeEventListener('wheel', this.handleWheel);
    } else {
      this.node.removeEventListener('scroll', this.handleScroll);
      this.node.removeEventListener('wheel', this.handleWheel);
    }
  }

  getFirstChildKey (props) {
    const { children } = props;
    let firstChild     = children;

    if (children instanceof ImmutableList) {
      firstChild = children.get(0);
    } else if (Array.isArray(children)) {
      firstChild = children[0];
    }

    return firstChild && firstChild.key;
  }

  setRef = (c) => {
    this.node = c;
  }

  handleLoadMore = e => {
    if (e && e.preventDefault) {
      e.preventDefault();
    }

    this.props.onLoadMore();
  }

  handleLoadNewer = () => {
    if (this.props.onLoadNewer) {
      this.props.onLoadNewer();
    }
  }

  handleLoadPending = e => {
    e.preventDefault();
    this.props.onLoadPending();
    // Prevent the weird scroll-jumping behavior, as we explicitly don't want to
    // scroll to top, and we know the scroll height is going to change
    this.scrollToTopOnMouseIdle = false;
    this.lastScrollWasSynthetic = false;
    this.clearMouseIdleTimer();
    this.mouseIdleTimer = setTimeout(this.handleMouseIdle, MOUSE_IDLE_DELAY);
    this.mouseMovedRecently = true;
  }

  render () {
    const { children, scrollKey, trackScroll, showLoading, isLoading, hasMore, hasNewer, newerLoading, newerStatus, olderStatus, numPending, prepend, alwaysPrepend, append, emptyMessage, onLoadMore, onLoadNewer, tabIndex } = this.props;
    const { fullscreen } = this.state;
    const childrenCount = React.Children.count(children);
    const showOlder = onLoadMore && (hasMore || olderStatus === 'error' || olderStatus === 'unavailable');
    const showNewer = onLoadNewer && (hasNewer || newerStatus === 'error' || newerStatus === 'unavailable');
    const loadNewer = showNewer ? (
      <LoadWindowEdge
        direction='newer'
        status={newerLoading ? 'loading' : newerStatus}
        visible={!newerLoading}
        disabled={newerLoading}
        onClick={this.handleLoadNewer}
      />
    ) : null;
    let loadMore = null;

    if (showOlder && olderStatus) {
      loadMore = <LoadWindowEdge direction='older' status={isLoading ? 'loading' : olderStatus} visible={!isLoading} disabled={isLoading} onClick={this.handleLoadMore} />;
    } else if (showOlder) {
      loadMore = <LoadMore visible={!isLoading} onClick={this.handleLoadMore} />;
    }
    const loadPending  = (numPending > 0) ? <LoadPending count={numPending} onClick={this.handleLoadPending} /> : null;
    let scrollableArea = null;

    if (showLoading) {
      scrollableArea = (
        <div className='scrollable scrollable--flex' ref={this.setRef}>
          <div role='feed' className='item-list'>
            {prepend}
          </div>

          <div className='scrollable__append'>
            <LoadingIndicator />
          </div>
        </div>
      );
    } else if (isLoading || childrenCount > 0 || numPending > 0 || hasMore || showNewer || !emptyMessage) {
      scrollableArea = (
        <div className={classNames('scrollable', { fullscreen })} ref={this.setRef} onMouseMove={this.handleMouseMove}>
          <div role='feed' className='item-list'>
            {prepend}

            {loadNewer}

            {loadPending}

            {React.Children.map(this.props.children, (child, index) => (
              <IntersectionObserverArticleContainer
                key={child.key}
                id={child.key}
                index={index}
                listLength={childrenCount}
                intersectionObserverWrapper={this.intersectionObserverWrapper}
                saveHeightKey={trackScroll ? `${this.context.router.route.location.key}:${scrollKey}` : null}
                tabIndex={tabIndex}
                onIntersectionChange={this.handleIntersectionChange}
                onBeforeLayoutChange={this.handleFilterLayout}
              >
                {React.cloneElement(child, {
                  getScrollPosition: this.getScrollPosition,
                  updateScrollBottom: this.updateScrollBottom,
                  cachedMediaWidth: this.state.cachedMediaWidth,
                  cacheMediaWidth: this.cacheMediaWidth,
                })}
              </IntersectionObserverArticleContainer>
            ))}

            {loadMore}

            {!hasMore && append}
          </div>
        </div>
      );
    } else {
      scrollableArea = (
        <div className={classNames('scrollable scrollable--flex', { fullscreen })} ref={this.setRef}>
          {alwaysPrepend && prepend}

          <div className='empty-column-indicator'>
            {emptyMessage}
          </div>
        </div>
      );
    }

    if (trackScroll) {
      return (
        <ScrollContainer scrollKey={scrollKey}>
          {scrollableArea}
        </ScrollContainer>
      );
    } else {
      return scrollableArea;
    }
  }

}

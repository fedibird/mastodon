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
import TimelineMasonry from './timeline_masonry';
import { findVisibleMasonryTile, leadingMasonryPrefixKeys, reconcileMasonryPrepends } from 'mastodon/utils/timeline_masonry_layout';
import MediaDisplayControls from './media_display_controls';
import MediaItemsLayout from './media_items_layout';
import { defaultMediaShape, defaultMediaSize, defaultMediaVisibility } from 'mastodon/utils/media_display';
import { mediaTimelineSequence } from 'mastodon/utils/media_timeline_sequence';
import { isCardTimelineLayout } from 'mastodon/utils/timeline_layout';
import { connect } from 'react-redux';
import { FilterSurface } from '../filter_reconciliation/surface';
import { isProgrammaticTopScroll, releaseProgrammaticTopScroll } from '../scroll';
import {
  TIMELINE_ANCHOR_REASONS,
  TIMELINE_ANCHOR_VERSION,
  captureTimelineAnchor,
  isDecimalStatusId,
  readDocumentVisibleTop,
  restoreTimelineAnchor,
  selectAnchorFromMeasurements,
  scheduleTimelineAnchorFrames,
  scrollToLoadedTimelineStatus,
} from '../timeline_navigation';

const MOUSE_IDLE_DELAY = 300;
const MASONRY_SCROLL_IDLE_DELAY = 500;
const MASONRY_ANCHOR_EPSILON = 0.5;

const mapStateToProps = (state, { scrollKey }) => {
  return {
    preventScroll: scrollKey === state.getIn(['dropdown_menu', 'scroll_key']),
    mediaFilters: state.get('filters'),
    mediaFilterMatches: state.get('filterMatches'),
    mediaFilterGeneration: state.getIn(['filterMatches', 'generation'], 0),
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
    onUserScroll: PropTypes.func,
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
    windowedHistory: PropTypes.bool,
    readingSurface: PropTypes.bool,
    anchorSourceKey: PropTypes.string,
    layoutMode: PropTypes.string,
    mediaRows: PropTypes.array,
    mediaStatuses: PropTypes.object,
    mediaTimelineId: PropTypes.string,
    mediaContextForId: PropTypes.func,
    mediaFilters: PropTypes.object,
    mediaFilterMatches: PropTypes.object,
    mediaFilterGeneration: PropTypes.number,
    mediaLastStatusId: PropTypes.string,
  };

  static defaultProps = {
    trackScroll: true,
    tabIndex: '0',
  };

  state = {
    fullscreen: null,
    cachedMediaWidth: 250, // Default media/card width using default Mastodon theme
    // Saved appearance defaults. Toolbar changes stay on this screen.
    mediaShape: defaultMediaShape(),
    mediaSize: defaultMediaSize(),
    mediaVisibility: defaultMediaVisibility(),
    mediaRevealSource: `${this.props.layoutMode}:${this.props.mediaTimelineId || this.props.scrollKey}`,
    revealedMediaKeys: new Set(),
    revealedFilterStatusIds: new Set(),
  };

  static getDerivedStateFromProps (nextProps, prevState) {
    const source = `${nextProps.layoutMode}:${nextProps.mediaTimelineId || nextProps.scrollKey}`;
    return source === prevState.mediaRevealSource ? null : {
      mediaRevealSource: source,
      revealedMediaKeys: new Set(),
      revealedFilterStatusIds: new Set(),
    };
  }

  handleMediaShapeChange = mediaShape => {
    this.setState({ mediaShape });
  }

  handleMediaSizeChange = mediaSize => {
    this.setState({ mediaSize });
  }

  handleMediaVisibilityChange = mediaVisibility => {
    // Clear individual image reveals when switching policy, without touching
    // a separate manual override of a warning-filtered post.
    this.setState({ mediaVisibility, revealedMediaKeys: new Set() });
  }

  handleMediaTileReveal = key => {
    if (!key) return;
    this.setState(({ revealedMediaKeys }) => ({ revealedMediaKeys: new Set([...revealedMediaKeys, key]) }));
  }

  handleMediaFilterReveal = statusId => {
    if (!statusId) return;
    this.setState(({ revealedFilterStatusIds }) => ({ revealedFilterStatusIds: new Set([...revealedFilterStatusIds, statusId]) }));
  }

  intersectionObserverWrapper = new IntersectionObserverWrapper();

  handleScroll = throttle(() => {
    if (this.node) {
      const scrollTop = this.getScrollTop();
      const scrollHeight = this.getScrollHeight();
      const clientHeight = this.getClientHeight();
      const offset = scrollHeight - scrollTop - clientHeight;
      const headerScroll = this._headerScrollActive();
      const anchorJump = headerScroll || this._isAnchorJumpScroll(scrollTop);

      // Momentum scroll events continue after touch release. Record native
      // movement before any throttled anchor correction can run.
      if (!anchorJump && !this.lastScrollWasSynthetic && !this._suppressUserScroll) {
        this._lastNativeScrollAt = Date.now();
      }

      // A jump to an already loaded row must not page in more. A real user
      // scroll, including one that arrives before this throttled call runs,
      // still loads when it is within 400px of the end.
      const olderBlocked = this.props.olderStatus === 'error' || this.props.olderStatus === 'unavailable' || this.props.olderStatus === 'paused';

      if (!anchorJump && 400 > offset && this.props.onLoadMore && this.props.hasMore && !this.props.isLoading && !olderBlocked) {
        this.props.onLoadMore();
      }

      if (scrollTop < 100 && this.props.onScrollToTop) {
        this.props.onScrollToTop();
      } else if (this.props.onScroll) {
        this.props.onScroll();
      }

      if (!anchorJump && !this._suppressUserScroll && this.props.onUserScroll) {
        this.props.onUserScroll();
      }

      if (headerScroll) {
        // The header is driving this scroller to the top. Drop queued
        // anchor frames so they cannot apply after the smooth scroll ends.
        this._anchorGeneration = (this._anchorGeneration || 0) + 1;
        this._cancelAnchorCorrection();
      }

      if (!anchorJump && this._anchorScrollSuppressedLoad) {
        this._disarmMouseIdle();
        this._cancelAnchorCorrection();
        this._anchorScrollSuppressedLoad = false;
        this._syntheticScrollTop = null;
      } else if (!anchorJump && !this.lastScrollWasSynthetic) {
        // If the last scroll wasn't caused by setScrollTop(), assume it was
        // intentional and cancel any pending scroll reset on mouse idle
        this._disarmMouseIdle();
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
  _mouseIdleSession = 0;
  _mouseIdleScrollTop = null;
  _syntheticScrollDepth = 0;
  _anchorScrollSuppressedLoad = false;
  _syntheticScrollTop = null;
  _lastNativeScrollAt = -Infinity;

  _hasActiveMasonryScroll = () => Date.now() - this._lastNativeScrollAt < MASONRY_SCROLL_IDLE_DELAY;

  _isAnchorJumpScroll = (scrollTop) => {
    if (this._syntheticScrollDepth > 0) {
      return true;
    }

    // alignDisplayRow writes scrollTop directly. The browser may deliver that
    // scroll event after the synthetic depth has already returned to zero.
    // Keep the jump marked until the throttled handler has seen it, unless
    // the reader has actually gestured.
    if (this._restoreToken && this._syntheticScrollTop !== null && Math.abs(scrollTop - this._syntheticScrollTop) <= 1) {
      return true;
    }

    return this._anchorScrollSuppressedLoad &&
      this._syntheticScrollTop !== null &&
      Math.abs(scrollTop - this._syntheticScrollTop) <= 1;
  }

  _armRestoreToken = () => {
    this._restoreToken = (this._restoreToken || 0) + 1;
    const token = this._restoreToken;

    if (this._restoreTokenTimer) {
      clearTimeout(this._restoreTokenTimer);
    }

    // Longer than handleScroll's 150ms trailing edge.
    this._restoreTokenTimer = setTimeout(() => {
      this._restoreTokenTimer = null;

      if (this._restoreToken === token && this._syntheticScrollDepth === 0) {
        this._restoreToken = 0;
      }
    }, 250);
  }

  _clearRestoreToken = () => {
    this._restoreToken = 0;

    if (this._restoreTokenTimer) {
      clearTimeout(this._restoreTokenTimer);
      this._restoreTokenTimer = null;
    }
  }

  _headerScrollActive = () => {
    if (isProgrammaticTopScroll(this._getScrollingElement())) {
      this._programmaticTopScrollSeen = true;
      return true;
    }

    if (!this._programmaticTopScrollSeen) {
      return false;
    }

    // The trailing throttle can fire once after the smooth scroll releases.
    this._programmaticTopScrollSeen = false;
    return true;
  }

  _markUserScrollIntent = () => {
    this._lastNativeScrollAt = Date.now();
    this._disarmMouseIdle();
    this._programmaticTopScrollSeen = false;
    this._anchorGeneration = (this._anchorGeneration || 0) + 1;
    this._clearRestoreToken();
    this._anchorScrollSuppressedLoad = false;
    this._syntheticScrollTop = null;
    this._cancelAnchorCorrection();

    if (!this._suppressUserScroll && this.props.onUserScroll) {
      this.props.onUserScroll();
    }
  }

  _getScrollingElement = () => {
    if (this.props.bindToDocument) {
      return (document.scrollingElement || document.body);
    } else {
      return this.node;
    }
  }

  setScrollTop = newScrollTop => {
    if (isProgrammaticTopScroll(this._getScrollingElement())) {
      return;
    }

    if (this.getScrollTop() !== newScrollTop) {
      // Ratify only a correction that still starts at the armed position.
      // A scrollbar move that never delivered a scroll event must not be
      // adopted as the next expected offset.
      this._noteMouseIdleCorrection(newScrollTop);
      this.lastScrollWasSynthetic = true;

      this._getScrollingElement().scrollTop = newScrollTop;
    }
  };

  _armMouseIdle = () => {
    this._mouseIdleSession += 1;
    this.scrollToTopOnMouseIdle = true;
    this._mouseIdleScrollTop = this.getScrollTop();
  };

  _disarmMouseIdle = () => {
    this.scrollToTopOnMouseIdle = false;
    this._mouseIdleScrollTop = null;
  };

  _retireMouseIdle = () => {
    this._lastNativeScrollAt = -Infinity;
    this._mouseIdleSession += 1;
    this._disarmMouseIdle();
    this.mouseMovedRecently = false;
    this.clearMouseIdleTimer();
  };

  _mouseIdleMatches = () => (
    this.scrollToTopOnMouseIdle &&
    this._mouseIdleScrollTop !== null &&
    Math.abs(this.getScrollTop() - this._mouseIdleScrollTop) <= 1
  );

  _noteMouseIdleCorrection = (nextTop) => {
    if (!this._mouseIdleMatches()) {
      return;
    }

    this._mouseIdleScrollTop = nextTop;
  };

  // FilterSurface writes scrollTop itself. Adopt that pin only when it still
  // starts at the armed offset, and mark the scroll synthetic before the
  // event is delivered. A reader move that already left the armed offset is
  // left alone, including its inertia.
  _acceptFilterScroll = (nextTop) => {
    if (!this._mouseIdleMatches()) {
      return;
    }

    this._mouseIdleScrollTop = nextTop;
    this.lastScrollWasSynthetic = true;
  };

  clearMouseIdleTimer = () => {
    if (this.mouseIdleTimer === null) {
      return;
    }

    clearTimeout(this.mouseIdleTimer);
    this.mouseIdleTimer = null;
  };

  // A history or other reading surface keeps local 0 as a place in the
  // backlog. Hovering there must not reserve a jump back to the latest row.
  _reservesReturnToTop = () => !(this.props.windowedHistory || this.props.readingSurface);

  handleMouseMove = throttle(() => {
    // As long as the mouse keeps moving, clear and restart the idle timer.
    this.clearMouseIdleTimer();

    if (!this.mouseMovedRecently && this.getScrollTop() === 0 && this._reservesReturnToTop()) {
      // Only set if we just started moving and are scrolled to the top.
      this._armMouseIdle();
    }

    const session = this._mouseIdleSession;

    this.mouseIdleTimer = setTimeout(() => this.handleMouseIdle(session), MOUSE_IDLE_DELAY);

    // Save setting this flag for last, so we can do the comparison above.
    this.mouseMovedRecently = true;
  }, MOUSE_IDLE_DELAY / 2);

  handleWheel = throttle(() => {
    this._markUserScrollIntent();
  }, 150, {
    leading: true,
    trailing: false,
  });

  handleTouchMove = () => {
    this._markUserScrollIntent();
  }

  handlePointerScroll = (event) => {
    if (!event) {
      return;
    }

    if (event.pointerType === 'touch' || event.pointerType === 'pen') {
      this._markUserScrollIntent();
      return;
    }

    if (event.type === 'pointermove' && event.buttons > 0) {
      this._markUserScrollIntent();
    }
  }

  handleKeyScroll = (event) => {
    if (!event) {
      return;
    }

    const target = event.target;

    if (target && (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.isContentEditable)) {
      return;
    }

    const keys = ['ArrowDown', 'ArrowUp', 'PageDown', 'PageUp', 'Home', 'End', ' '];

    if (keys.indexOf(event.key) !== -1) {
      this._markUserScrollIntent();
    }
  }

  handleMouseIdle = (session) => {
    if (this._anchorUnmounted) {
      return;
    }

    // A route change, seek, or newer hover session owns the scroller now.
    if (session !== undefined && session !== this._mouseIdleSession) {
      return;
    }

    // Compare with the position this session expects, including insertions
    // the list itself applied. Do not treat every non-zero offset as a
    // reader gesture, and do not trust lastScrollWasSynthetic: handleScroll
    // clears it before this timer runs.
    if (this._mouseIdleMatches() && !this.props.preventScroll && this._reservesReturnToTop()) {
      this._cancelFilterAnchor();
      this.setScrollTop(0);
    }

    this.mouseMovedRecently = false;
    this._disarmMouseIdle();
  }

  componentDidMount () {
    this.attachScrollListener();
    this.attachIntersectionObserver();

    attachFullscreenListener(this.onFullScreenChange);

    // The mount read is not a reader gesture. Cancel the trailing throttle
    // so it cannot be replayed later as a user scroll.
    this._suppressUserScroll = true;
    this.handleScroll();
    this.handleScroll.cancel();
    this._suppressUserScroll = false;
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
      this.filterSurface = new FilterSurface(this.props.dispatch, this.node, { ...this.props, scrollKey: surfaceKey, ids: this.props.filterStatusIds, idForRow: this.props.filterIdForRow, followingLatest: () => this.isFollowingLatest(), onAcceptedScroll: this._acceptFilterScroll });
    } else {
      this.filterSurface.preventScroll = this.props.preventScroll;
      this.filterSurface.followingLatest = () => this.isFollowingLatest();
      this.filterSurface.onAcceptedScroll = this._acceptFilterScroll;
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

    // Masonry prepends only push down the column receiving a new item.
    // The overall scrollHeight delta no longer describes the displacement
    // of the card being read, so preserve an actual visible article instead.
    const variableHeightMasonry = isCardTimelineLayout(this.props.layoutMode) ||
      (this.props.layoutMode === 'media' && this.state.mediaShape === 'original');

    // Native momentum is a user-driven animation, not a fixed reading anchor.
    // A snapshot taken while it runs would write scrollTop during the swipe.
    if (variableHeightMasonry && this._hasActiveMasonryScroll()) {
      return null;
    }

    // A bounded Live window may replace the oldest post with a new one,
    // keeping the item count unchanged. Pinned posts also keep the first
    // child key unchanged. Use the same prepend identity rule as Masonry.
    let masonryPrepend = false;
    if (variableHeightMasonry) {
      const before = React.Children.toArray(prevProps.children).map(child => String(child.key));
      const after = React.Children.toArray(this.props.children).map(child => String(child.key));
      const plan = reconcileMasonryPrepends(before, after, leadingMasonryPrefixKeys(before));
      masonryPrepend = !plan.reset && plan.prependedKeys.length > 0;
    }

    // Split History and other reading surfaces preserve their top row even
    // at scrollTop=0; only a live feed following the newest post stays at 0.
    if (masonryPrepend &&
        (this.getScrollTop() > 0 || this.mouseMovedRecently || this.props.preventScroll ||
         this.props.windowedHistory || this.props.readingSurface)) {
      const anchor = this.captureVisibleMasonryItem();
      if (anchor) {
        return { masonryAnchor: true, ...anchor };
      }

      // A height-delta fallback would be incorrect for independently moving
      // columns. If nothing in the masonry is visible, leave the scroller as is.
      return null;
    }

    if (pendingChanged || someItemInserted && (this.getScrollTop() > 0 || this.mouseMovedRecently || this.props.preventScroll)) {
      return this.getScrollHeight() - this.getScrollTop();
    }

    const grew = React.Children.count(this.props.children) > React.Children.count(prevProps.children);
    const sameHead = this.getFirstChildKey(prevProps) === this.getFirstChildKey(this.props);

    // A late external row can land under the first item. Keep the article
    // that was at the top of the viewport from jumping.
    if (grew && sameHead && this.getScrollTop() > 0) {
      const anchor = this.captureVisibleArticle();

      if (anchor) {
        return { anchor: true, id: anchor.id, top: anchor.top };
      }
    }

    return null;
  }

  // The visual top of a masonry tile does not follow article DOM order.
  // Tile keys also distinguish multiple attachments belonging to one status.
  captureVisibleMasonryItem () {
    if (!this.node || typeof this.node.querySelectorAll !== 'function') {
      return null;
    }

    const host = this.getTimelineScrollHost();
    const visibleTop = this.getTimelineVisibleTop(host);
    const viewportHeight = host.kind === 'document'
      ? (window.innerHeight || this.getClientHeight())
      : this.getClientHeight();
    const visibleBottom = visibleTop + viewportHeight;
    const tile = findVisibleMasonryTile(this.node, visibleTop, visibleBottom);
    return tile ? { key: tile.key, top: tile.top } : null;
  }

  restoreMasonryItemAnchor (snapshot) {
    if (!this.node || !snapshot || !snapshot.key) {
      return;
    }

    // Never interpolate React keys into a CSS selector. They may contain
    // escaped characters and status/attachment IDs share prefixes.
    const items = this.node.querySelectorAll('.timeline-masonry > .timeline-masonry__item[data-layout-key]');
    const item = Array.from(items).find(node => node.getAttribute('data-layout-key') === snapshot.key);
    if (!item) {
      return;
    }

    const delta = item.getBoundingClientRect().top - snapshot.top;
    if (Math.abs(delta) > 0.5) {
      this.setScrollTop(this.getScrollTop() + delta);
    }
  }

  // The initial prepend snapshot is owned by ScrollableList, but a late
  // ResizeObserver update only re-renders TimelineMasonry. Use the exact same
  // viewport-relative tile anchor for those child-only layout changes.
  captureMasonryLayoutAnchor = () => {
    if (!this.node || this._anchorUnmounted || this._hasActiveMasonryScroll() ||
        isProgrammaticTopScroll(this._getScrollingElement()) ||
        (this.isFollowingLatest() && !this.mouseMovedRecently && !this.props.preventScroll)) {
      return null;
    }

    const anchor = this.captureVisibleMasonryItem();
    return anchor ? { ...anchor, scrollTop: this.getScrollTop() } : null;
  }

  restoreMasonryLayoutAnchor = snapshot => {
    if (!snapshot || !snapshot.key || this._anchorUnmounted ||
        this._hasActiveMasonryScroll() ||
        isProgrammaticTopScroll(this._getScrollingElement()) ||
        (typeof snapshot.scrollTop === 'number' &&
         Math.abs(this.getScrollTop() - snapshot.scrollTop) > MASONRY_ANCHOR_EPSILON)) {
      return;
    }

    const before = this._beginSyntheticAnchorScroll();
    this.restoreMasonryItemAnchor(snapshot);
    this._finishSyntheticAnchorScroll(before);
    this._scheduleMasonryAnchorCorrection(snapshot);
  }

  _scheduleMasonryAnchorCorrection = (snapshot) => {
    if (this._hasActiveMasonryScroll()) {
      return;
    }

    this._anchorGeneration = (this._anchorGeneration || 0) + 1;
    const generation = this._anchorGeneration;
    this._cancelAnchorCorrection();

    const cursor = { top: this.getScrollTop() };
    const locationKey = this._currentLocationKey();
    this._anchorCancel = scheduleTimelineAnchorFrames({
      frames: 2,
      shouldAbort: () => (
        this._anchorUnmounted ||
        this._hasActiveMasonryScroll() ||
        this._anchorGeneration !== generation ||
        this._currentLocationKey() !== locationKey ||
        isProgrammaticTopScroll(this._getScrollingElement()) ||
        Math.abs(this.getScrollTop() - cursor.top) > MASONRY_ANCHOR_EPSILON
      ),
      apply: () => {
        const before = this._beginSyntheticAnchorScroll();
        this.restoreMasonryItemAnchor(snapshot);
        cursor.top = this.getScrollTop();
        this._finishSyntheticAnchorScroll(before);
      },
    });
  }

  captureVisibleArticle () {
    if (!this.node || typeof this.node.querySelectorAll !== 'function') {
      return null;
    }

    const host = this.getTimelineScrollHost();
    const visibleTop = this.getTimelineVisibleTop(host);
    const rows = [];
    const articles = this.node.querySelectorAll('article[data-id]');

    for (let index = 0; index < articles.length; index += 1) {
      const article = articles[index];
      const id = article.getAttribute('data-id');

      if (!/^\d+$/.test(id || '')) {
        continue;
      }

      const box = article.getBoundingClientRect();

      rows.push({
        rowId: id,
        top: box.top,
        bottom: box.bottom,
        height: box.height,
      });
    }

    const selected = selectAnchorFromMeasurements({ rows, visibleTop });
    const row = rows.find(item => item.rowId === selected.rowId);

    if (!row) {
      return null;
    }

    return { id: row.rowId, top: row.top };
  }

  restoreArticleAnchor (snapshot) {
    if (!this.node || !snapshot || !/^\d+$/.test(snapshot.id || '')) {
      return;
    }

    const article = this.node.querySelector(`article[data-id="${snapshot.id}"]`);

    if (!article) {
      return;
    }

    const delta = article.getBoundingClientRect().top - snapshot.top;

    if (Math.abs(delta) > 0.5) {
      this.setScrollTop(this.getScrollTop() + delta);
    }
  }

  componentDidUpdate (prevProps, prevState, snapshot) {
    if (prevProps.bindToDocument !== this.props.bindToDocument) {
      this.detachScrollListener(prevProps.bindToDocument);
      this.attachScrollListener();
      this.attachIntersectionObserver();
    }
    // Preserve native momentum when a parent update inserts/reorders cards.
    // Quiet periods still receive the usual reading-anchor correction.
    const activeMasonryScroll = (isCardTimelineLayout(this.props.layoutMode) ||
      (this.props.layoutMode === 'media' && this.state.mediaShape === 'original')) &&
      this._hasActiveMasonryScroll();
    if (!activeMasonryScroll) {
      if (snapshot && snapshot.masonryAnchor) {
        this.restoreMasonryLayoutAnchor(snapshot);
      } else if (snapshot && snapshot.anchor) {
        this.restoreArticleAnchor(snapshot);
      } else if (snapshot !== null) {
        this.setScrollTop(this.getScrollHeight() - snapshot);
      }
    }

    if (prevProps.scrollKey !== this.props.scrollKey || prevProps.bindToDocument !== this.props.bindToDocument || prevProps.anchorSourceKey !== this.props.anchorSourceKey || !!prevProps.windowedHistory !== !!this.props.windowedHistory || !!prevProps.readingSurface !== !!this.props.readingSurface) {
      this._cancelAnchorCorrection();
      this._cancelFilterAnchor();
      this._retireMouseIdle();
    }

    this.updateFilterSurface();
  }

  _currentLocationKey = () => {
    const location = this.context.router?.history?.location || this.context.router?.route?.location;

    return location ? location.key : null;
  }

  // The unread icon uses a 100px threshold. Follow is the actual top of a
  // streaming list. A windowed history pane, and any other reading surface
  // such as mix history, is a reading position even at local 0.
  isFollowingLatest = () => {
    if (this.props.windowedHistory || this.props.readingSurface || this._anchorUnmounted) {
      return false;
    }

    return Math.abs(this.getScrollTop()) <= 0.5;
  };

  _cancelFilterAnchor = () => {
    if (this.filterSurface && typeof this.filterSurface.cancel === 'function') {
      this.filterSurface.cancel();
    }
  };

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
    this._disarmMouseIdle();
    this._syntheticScrollDepth += 1;
    this.lastScrollWasSynthetic = true;
    this._anchorScrollSuppressedLoad = true;
    this._armRestoreToken();

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
        isProgrammaticTopScroll(this._getScrollingElement()) ||
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

    releaseProgrammaticTopScroll(this._getScrollingElement());
    this._cancelFilterAnchor();

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

    releaseProgrammaticTopScroll(this._getScrollingElement());
    this._cancelFilterAnchor();

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
    this._retireMouseIdle();
    this._cancelAnchorCorrection();
    this.filterHistoryUnlisten?.();
    this.filterSurface?.destroy();
    this.handleScroll.cancel();
    this.handleWheel.cancel();
    this.handleMouseMove.cancel();
    this._clearRestoreToken();
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
    const target = this.props.bindToDocument ? document : this.node;

    target.addEventListener('scroll', this.handleScroll);
    target.addEventListener('wheel', this.handleWheel);
    target.addEventListener('touchmove', this.handleTouchMove);
    target.addEventListener('pointerdown', this.handlePointerScroll);
    target.addEventListener('pointermove', this.handlePointerScroll);
    target.addEventListener('keydown', this.handleKeyScroll);
  }

  detachScrollListener (bindToDocument = this.props.bindToDocument) {
    const target = bindToDocument ? document : this.node;

    if (!target) {
      return;
    }

    target.removeEventListener('scroll', this.handleScroll);
    target.removeEventListener('wheel', this.handleWheel);
    target.removeEventListener('touchmove', this.handleTouchMove);
    target.removeEventListener('pointerdown', this.handlePointerScroll);
    target.removeEventListener('pointermove', this.handlePointerScroll);
    target.removeEventListener('keydown', this.handleKeyScroll);
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
    this._disarmMouseIdle();
    this.lastScrollWasSynthetic = false;
    this.clearMouseIdleTimer();
    this.mouseIdleTimer = setTimeout(this.handleMouseIdle, MOUSE_IDLE_DELAY);
    this.mouseMovedRecently = true;
  }

  render () {
    const { children, scrollKey, trackScroll, showLoading, isLoading, hasMore, hasNewer, newerLoading, newerStatus, olderStatus, numPending, prepend, alwaysPrepend, append, emptyMessage, onLoadMore, onLoadNewer, tabIndex, layoutMode } = this.props;
    const { fullscreen, mediaShape, mediaSize, mediaVisibility } = this.state;
    const mediaMode = layoutMode === 'media';
    const mediaControls = mediaMode ? (
      <MediaDisplayControls
        shape={mediaShape}
        size={mediaSize}
        visibility={mediaVisibility}
        onShapeChange={this.handleMediaShapeChange}
        onSizeChange={this.handleMediaSizeChange}
        onVisibilityChange={this.handleMediaVisibilityChange}
      />
    ) : null;
    const childrenCount = React.Children.count(children);
    const showOlder = onLoadMore && (hasMore || olderStatus === 'error' || olderStatus === 'unavailable' || olderStatus === 'paused');
    const showNewer = onLoadNewer && (hasNewer || newerStatus === 'error' || newerStatus === 'unavailable' || newerStatus === 'paused');
    const loadNewer = showNewer ? (
      <LoadWindowEdge
        direction='newer'
        status={newerLoading ? 'loading' : newerStatus}
        visible={!newerLoading}
        disabled={newerLoading || isLoading}
        onClick={this.handleLoadNewer}
      />
    ) : null;
    let loadMore = null;

    if (showOlder && olderStatus) {
      loadMore = <LoadWindowEdge direction='older' status={isLoading ? 'loading' : olderStatus} visible={!isLoading} disabled={isLoading || newerLoading} onClick={this.handleLoadMore} />;
    } else if (showOlder) {
      loadMore = <LoadMore visible={!isLoading} onClick={this.handleLoadMore} />;
    }
    const loadPending  = (numPending > 0) ? <LoadPending count={numPending} onClick={this.handleLoadPending} /> : null;
    let scrollableArea = null;
    const filterInfo = mediaMode ? {
      filters: this.props.mediaFilters,
      matches: this.props.mediaFilterMatches,
      generation: this.props.mediaFilterGeneration,
      revealedMediaKeys: this.state.revealedMediaKeys,
      revealedFilterStatusIds: this.state.revealedFilterStatusIds,
    } : null;
    const mediaTimeline = mediaMode
      ? mediaTimelineSequence(this.props.mediaRows, this.props.mediaStatuses, mediaVisibility, filterInfo)
      : null;
    const mediaSource = mediaMode && onLoadMore && this.props.mediaTimelineId ? {
      kind: 'timeline',
      timelineId: this.props.mediaTimelineId,
      afterStatusId: this.props.mediaLastStatusId,
      visibility: mediaVisibility,
      contextTypeForId: this.props.mediaContextForId,
      onLoadMore,
    } : null;
    const renderedItems = React.Children.map(children, (child, index) => (
      <IntersectionObserverArticleContainer
        key={child.key}
        id={child.key}
        index={index}
        listLength={childrenCount}
        intersectionObserverWrapper={this.intersectionObserverWrapper}
        // Cached heights from the old full-width list cannot be used for cards.
        saveHeightKey={trackScroll && !isCardTimelineLayout(layoutMode) && layoutMode !== 'media' ? `${this.context.router.route.location.key}:${scrollKey}` : null}
        tabIndex={tabIndex}
        onIntersectionChange={this.handleIntersectionChange}
        onBeforeLayoutChange={this.handleFilterLayout}
      >
        {React.cloneElement(child, {
          getScrollPosition: this.getScrollPosition,
          updateScrollBottom: this.updateScrollBottom,
          cachedMediaWidth: this.state.cachedMediaWidth,
          cacheMediaWidth: this.cacheMediaWidth,
          mediaShape: mediaMode ? mediaShape : undefined,
          mediaVisibility: mediaMode ? mediaVisibility : undefined,
          mediaTimeline,
          mediaSource,
          onMediaTileReveal: mediaMode ? this.handleMediaTileReveal : undefined,
          mediaTileRevealed: mediaMode && this.state.revealedMediaKeys.has(child.props.mediaRowKey),
          onMediaFilterReveal: mediaMode ? this.handleMediaFilterReveal : undefined,
          mediaFilterRevealed: mediaMode && this.state.revealedFilterStatusIds.has(child.props.id),
        })}
      </IntersectionObserverArticleContainer>
    ));
    let itemLayout = renderedItems;
    if (isCardTimelineLayout(layoutMode)) {
      itemLayout = (
        <TimelineMasonry
          mode={layoutMode}
          onCaptureLayoutAnchor={this.captureMasonryLayoutAnchor}
          onRestoreLayoutAnchor={this.restoreMasonryLayoutAnchor}
        >
          {renderedItems}
        </TimelineMasonry>
      );
    } else if (mediaMode) {
      itemLayout = (
        <MediaItemsLayout
          shape={mediaShape}
          size={mediaSize}
          onCaptureLayoutAnchor={this.captureMasonryLayoutAnchor}
          onRestoreLayoutAnchor={this.restoreMasonryLayoutAnchor}
        >
          {renderedItems}
        </MediaItemsLayout>
      );
    }

    if (showLoading) {
      scrollableArea = (
        <div className={classNames('scrollable scrollable--flex', { 'scrollable--document': this.props.bindToDocument })} ref={this.setRef}>
          <div role='feed' className='item-list'>
            {prepend}
            {mediaControls}
          </div>

          <div className='scrollable__append'>
            <LoadingIndicator />
          </div>
        </div>
      );
    } else if (isLoading || childrenCount > 0 || numPending > 0 || hasMore || showNewer || !emptyMessage) {
      scrollableArea = (
        <div className={classNames('scrollable', { fullscreen, 'scrollable--document': this.props.bindToDocument })} ref={this.setRef} onMouseMove={this.handleMouseMove}>
          <div role='feed' className='item-list'>
            {prepend}

            {mediaControls}

            {loadNewer}

            {loadPending}

            {itemLayout}

            {loadMore}

            {!hasMore && append}
          </div>
        </div>
      );
    } else {
      scrollableArea = (
        <div className={classNames('scrollable scrollable--flex', { fullscreen, 'scrollable--document': this.props.bindToDocument })} ref={this.setRef}>
          {alwaysPrepend && prepend}
          {mediaControls}

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

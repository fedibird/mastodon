import React from 'react';
import PropTypes from 'prop-types';
import { defineMessages, injectIntl } from 'react-intl';
import classNames from 'classnames';
import Icon from 'mastodon/components/icon';
import TimelineSplitter, {
  DEFAULT_TIMELINE_SPLIT_RATIO,
  MAX_TIMELINE_SPLIT_RATIO,
  MIN_TIMELINE_SPLIT_RATIO,
} from 'mastodon/components/timeline_splitter';
import uuid from '../../../uuid';
import { scrollTop as scrollElementToTop } from '../../../scroll';
import {
  alignLegacySplitAnchor,
  captureTimelineAnchor,
  legacySplitAnchorFromCapture,
  readDocumentVisibleTop,
} from 'mastodon/timeline_navigation';
import { HISTORY_POSITION_CAPTURE_INTERVAL_MS, HISTORY_RESUME_IN_FLIGHT } from 'mastodon/timeline_position/constants';
import { historyLayout, historySourceIdentity, historyViewIdentity } from 'mastodon/timeline_position/identity';
import { autoResumeDecision } from 'mastodon/timeline_position/policy';
import { getPositionRegistry } from 'mastodon/timeline_position/session';
import { captureHistorySurface, subscribeHistorySurface } from 'mastodon/timeline_position/surface';

const messages = defineMessages({
  split: { id: 'timeline.split', defaultMessage: 'Split timeline' },
  unsplit: { id: 'timeline.unsplit', defaultMessage: 'Remove timeline split' },
  splitter: { id: 'timeline.splitter', defaultMessage: 'Timeline splitter' },
  closeHistoryPane: { id: 'timeline.close_history_pane', defaultMessage: 'Close history pane' },
  closeLivePane: { id: 'timeline.close_live_pane', defaultMessage: 'Close live pane' },
  resume: { id: 'timeline.resume_history', defaultMessage: 'Resume saved place' },
  resumeBusy: { id: 'timeline.resume_history_busy', defaultMessage: 'Resuming saved place' },
  resumeFailed: { id: 'timeline.resume_history_failed', defaultMessage: 'Could not resume the saved place' },
});

export const STATUS_TIMELINE_SPLIT_LAYOUT_CLASS = 'status-timeline-split';
export const TIMELINE_SPLIT_KEEP_LIVE = 'live';
export const TIMELINE_SPLIT_KEEP_HISTORY = 'history';

export const clampTimelineSplitRatio = (value) => {
  const number = Number(value);

  if (!Number.isFinite(number)) {
    return DEFAULT_TIMELINE_SPLIT_RATIO;
  }

  return Math.min(MAX_TIMELINE_SPLIT_RATIO, Math.max(MIN_TIMELINE_SPLIT_RATIO, Math.round(number)));
};

const resetDocumentScroll = () => {
  const scroller = document.scrollingElement || document.body;

  if (scroller) {
    scroller.scrollTop = 0;
  }
};

// Scroll, ratio, and pane layout shared by ordinary timelines and mixes.
// Callers own the Redux split record through the callbacks.
export default @injectIntl
class TimelineSplitControllerCore extends React.Component {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    children: PropTypes.func.isRequired,
    sourceTimelineId: PropTypes.string.isRequired,
    columnId: PropTypes.string,
    multiColumn: PropTypes.bool,
    location: PropTypes.shape({
      key: PropTypes.string,
    }),
    splitRatio: PropTypes.number,
    onSplitRatioCommit: PropTypes.func.isRequired,
    unavailableMessage: PropTypes.shape({
      id: PropTypes.string,
      defaultMessage: PropTypes.string,
    }).isRequired,
    splitContextKey: PropTypes.string,
    activeSplitId: PropTypes.string,
    splitReturnAnchor: PropTypes.object,
    splitBlocked: PropTypes.bool,
    anchorHold: PropTypes.bool,
    onCreate: PropTypes.func.isRequired,
    onDestroy: PropTypes.func.isRequired,
    onSaveReturnAnchor: PropTypes.func.isRequired,
    onClearReturnAnchor: PropTypes.func.isRequired,
    accountId: PropTypes.string,
    historyContract: PropTypes.object,
    historyResume: PropTypes.object,
    historyItemIds: PropTypes.object,
    onCaptureHistoryPosition: PropTypes.func,
    onResumeHistory: PropTypes.func,
    onCancelHistoryResume: PropTypes.func,
  };

  static contextTypes = {
    router: PropTypes.object,
  };

  state = {
    ratio: null,
    positionEpoch: 0,
  };

  constructor (props) {
    super(props);
    this.instanceId = props.columnId || uuid();
    this.locationKey = props.location ? props.location.key : undefined;
  }

  splitKeyPrefix = () => `${this.props.sourceTimelineId}:split:${this.instanceId}:`

  ownsSplit = () => {
    const active = this.props.activeSplitId;

    return typeof active === 'string' && active.startsWith(this.splitKeyPrefix());
  }

  getSplitTimelineId = () => {
    if (this.ownsSplit()) {
      return this.props.activeSplitId;
    }

    return `${this.splitKeyPrefix()}${this.splitSessionId}`;
  }

  getColumnNode = () => this.column && this.column.node

  getSplitRatio = () => clampTimelineSplitRatio(this.state.ratio === null ? this.props.splitRatio : this.state.ratio)

  findScrollable = (target) => {
    const node = this.getColumnNode();

    if (!node) {
      return null;
    }

    if (target === 'history') {
      return node.querySelector('.timeline-split__pane--history .scrollable');
    }

    if (target === 'live') {
      return node.querySelector('.timeline-split__pane--live .scrollable');
    }

    return node.querySelector('.scrollable');
  }

  getDocumentVisibleTop = () => readDocumentVisibleTop()

  documentScrollHost = (list) => ({
    kind: 'document',
    list,
    scroller: document.scrollingElement || document.body,
  })

  paneScrollHost = (pane, list) => ({
    kind: pane === 'live' ? 'live' : 'history',
    list,
    scroller: list,
  })

  captureDocumentAnchor = () => {
    const scrollable = this.findScrollable('single');
    const visibleTop = this.getDocumentVisibleTop();
    const fallbackOffset = scrollable ? Math.max(0, visibleTop - scrollable.getBoundingClientRect().top) : 0;
    const captured = captureTimelineAnchor({
      scrollHost: this.documentScrollHost(scrollable),
      visibleTop,
      alignment: 'top',
    });

    return legacySplitAnchorFromCapture(captured, { fallbackOffset, target: 'history' });
  }

  capturePaneAnchor = (pane) => {
    const scrollable = this.findScrollable(pane);
    const visibleTop = scrollable ? scrollable.getBoundingClientRect().top : 0;
    const fallbackOffset = scrollable ? scrollable.scrollTop : 0;
    const captured = captureTimelineAnchor({
      scrollHost: this.paneScrollHost(pane, scrollable),
      visibleTop,
      alignment: 'top',
    });

    return legacySplitAnchorFromCapture(captured, { fallbackOffset, target: 'document' });
  }

  applyScrollAnchor = (anchor) => {
    if (!anchor) {
      return false;
    }

    if (anchor.target === 'history') {
      const history = this.findScrollable('history');

      if (!history) {
        return false;
      }

      const result = alignLegacySplitAnchor({
        scrollHost: this.paneScrollHost('history', history),
        visibleTop: history.getBoundingClientRect().top,
        anchor,
        fallback: 'absolute',
      });

      return !!(result.ok || result.usedFallback);
    }

    if (anchor.target === 'document') {
      const scrollable = this.findScrollable('single');
      const scroller = document.scrollingElement || document.body;

      if (!scrollable || !scroller) {
        return false;
      }

      const result = alignLegacySplitAnchor({
        scrollHost: this.documentScrollHost(scrollable),
        visibleTop: this.getDocumentVisibleTop(),
        anchor,
        fallback: 'document-delta',
      });

      return !!(result.ok || result.usedFallback);
    }

    return false;
  }

  restoreScrollAnchor = () => {
    if (!this.scrollAnchor || this.scrollAnchorApplied) {
      return;
    }

    const anchor = this.scrollAnchor;

    if (!this.applyScrollAnchor(anchor)) {
      return;
    }

    this.scrollAnchorApplied = true;

    const token = {};
    this.scrollRestoreToken = token;

    requestAnimationFrame(() => {
      if (this.scrollRestoreToken !== token || this.scrollAnchor !== anchor) {
        return;
      }

      this.applyScrollAnchor(anchor);

      if (this.scrollAnchor === anchor) {
        this.scrollAnchor = null;
        this.scrollAnchorApplied = false;
      }
    });
  }

  syncSplitLayoutClass = () => {
    const active = !this.props.multiColumn && this.ownsSplit();

    if (active) {
      document.body.classList.add(STATUS_TIMELINE_SPLIT_LAYOUT_CLASS);
      this.splitLayoutClass = true;
      return;
    }

    this.clearSplitLayoutClass();
  }

  clearSplitLayoutClass = () => {
    if (!this.splitLayoutClass) {
      return;
    }

    document.body.classList.remove(STATUS_TIMELINE_SPLIT_LAYOUT_CLASS);
    this.splitLayoutClass = false;
  }

  clearSplitScroll = () => {
    this.pendingScroll = null;
    this.scrollAnchor = null;
    this.scrollAnchorApplied = false;
    this.shouldResetDocumentScroll = false;
    this.scrollRestoreToken = null;
    this.returnAnchorToken = null;
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
    if (this.props.splitBlocked || this.props.activeSplitId) {
      return;
    }

    this.returnAnchorToken = null;
    this.splitSessionId = uuid();
    this.scrollAnchorApplied = false;

    const reading = this.captureSplitReading();

    if (this.props.multiColumn) {
      this.scrollAnchor = null;

      if (reading && reading.displayRowId) {
        this.pendingScroll = null;
        this.scrollAnchor = legacySplitAnchorFromCapture(reading, {
          fallbackOffset: this.captureScrollTop('single'),
          target: 'history',
        });
      } else {
        this.pendingScroll = { top: this.captureScrollTop('single'), target: 'history' };
      }
    } else {
      this.pendingScroll = null;
      this.scrollAnchor = this.captureDocumentAnchor();
      this.shouldResetDocumentScroll = true;
    }

    this.props.onCreate(this.getSplitTimelineId(), reading && reading.statusId);
  }

  captureSplitReading = () => {
    const scrollable = this.findScrollable('single');

    if (!scrollable) {
      return null;
    }

    const multiColumn = !!this.props.multiColumn;

    return captureTimelineAnchor({
      scrollHost: multiColumn ? {
        kind: 'pane',
        list: scrollable,
        scroller: scrollable,
      } : this.documentScrollHost(scrollable),
      visibleTop: multiColumn ? scrollable.getBoundingClientRect().top : this.getDocumentVisibleTop(),
      alignment: 'top',
    });
  }

  unsplitToHistory = () => {
    if (!this.ownsSplit()) {
      return;
    }

    const historyAtTop = this.captureScrollTop('history') <= 1;

    this.scrollAnchorApplied = false;

    if (this.props.splitBlocked) {
      this.clearSplitScroll();
    } else if (this.props.multiColumn) {
      this.scrollAnchor = null;
      this.pendingScroll = { top: this.captureScrollTop('history'), target: 'single' };
    } else {
      this.pendingScroll = null;
      this.shouldResetDocumentScroll = false;
      this.scrollAnchor = this.capturePaneAnchor('history');
    }

    this.cancelInFlightResume('split_closed');
    this.flushHistoryPosition();
    this.props.onDestroy(this.getSplitTimelineId(), {
      keep: TIMELINE_SPLIT_KEEP_HISTORY,
      historyAtTop,
    });
  }

  unsplitToLive = () => {
    if (!this.ownsSplit()) {
      return;
    }

    const liveScrollTop = this.captureScrollTop('live');
    const liveAtTop = liveScrollTop <= 1;

    this.scrollAnchorApplied = false;

    if (this.props.splitBlocked) {
      this.clearSplitScroll();
    } else if (this.props.multiColumn) {
      this.scrollAnchor = null;
      this.pendingScroll = { top: liveScrollTop, target: 'single' };
    } else {
      this.pendingScroll = null;
      this.shouldResetDocumentScroll = false;
      this.scrollAnchor = this.capturePaneAnchor('live');
    }

    this.cancelInFlightResume('split_closed');
    this.flushHistoryPosition();
    this.props.onDestroy(this.getSplitTimelineId(), {
      keep: TIMELINE_SPLIT_KEEP_LIVE,
      liveAtTop,
    });
  }

  handleToggleSplit = (event) => {
    event.stopPropagation();

    if (this.ownsSplit()) {
      this.unsplitToLive();
      return;
    }

    this.splitTimeline();
  }

  handleCloseLive = (event) => {
    event.preventDefault();
    event.stopPropagation();
    this.unsplitToHistory();
  }

  handleRatioChange = (value) => {
    this.setState({ ratio: clampTimelineSplitRatio(value) });
  }

  handleRatioCommit = (value) => {
    const ratio = clampTimelineSplitRatio(value);

    this.setState({ ratio: null });

    if (ratio !== clampTimelineSplitRatio(this.props.splitRatio)) {
      this.props.onSplitRatioCommit(ratio);
    }
  }

  setColumnRef = c => {
    this.column = c;
  }

  handleHeaderClick = () => {
    if (this.ownsSplit()) {
      const live = this.findScrollable('live');

      if (live) {
        scrollElementToTop(live);
      }

      return;
    }

    if (this.column) {
      this.column.scrollTop();
    }
  }

  returnAnchorRecord = () => {
    const anchor = this.props.splitReturnAnchor;

    if (!anchor || !anchor.get) {
      return null;
    }

    return {
      target: 'document',
      id: anchor.get('id'),
      offset: anchor.get('offset'),
      fallbackOffset: anchor.get('fallbackOffset'),
    };
  }

  scheduleReturnAnchorRestore = () => {
    const anchor = this.props.splitReturnAnchor;

    if (!anchor || !anchor.get) {
      return;
    }

    const sameLocation = anchor.get('locationKey') === this.locationKey;

    if (!sameLocation || this.props.multiColumn) {
      this.props.onClearReturnAnchor();
      return;
    }

    if (this.props.splitBlocked) {
      if (!this.props.anchorHold) {
        this.props.onClearReturnAnchor();
      }

      return;
    }

    const record = this.returnAnchorRecord();
    const token = {};
    this.returnAnchorToken = token;

    requestAnimationFrame(() => {
      if (this.returnAnchorToken !== token) {
        return;
      }

      if (!this.applyScrollAnchor(record)) {
        return;
      }

      requestAnimationFrame(() => {
        if (this.returnAnchorToken !== token) {
          return;
        }

        this.applyScrollAnchor(record);

        if (this.returnAnchorToken === token) {
          this.returnAnchorToken = null;
          this.props.onClearReturnAnchor();
        }
      });
    });
  }

  componentDidMount () {
    this.syncSplitLayoutClass();
    this.scheduleReturnAnchorRestore();
    this.syncHistorySurface();
    this.maybeAutoResume();
  }

  componentDidUpdate (prevProps) {
    const previousLocationKey = prevProps.location ? prevProps.location.key : undefined;
    const nextLocationKey = this.props.location ? this.props.location.key : undefined;

    if (previousLocationKey !== nextLocationKey) {
      this.cancelInFlightResume('route_change');
      this.locationKey = nextLocationKey;
      this.autoResumeKey = null;
    }

    if (prevProps.accountId !== this.props.accountId && prevProps.accountId) {
      getPositionRegistry().evictAccount(prevProps.accountId);
    }

    if (prevProps.splitContextKey !== this.props.splitContextKey) {
      this.clearSplitScroll();
      this.clearSplitLayoutClass();

      if (this.ownsSplit()) {
        this.cancelInFlightResume('split_closed');
        this.flushHistoryPosition();
        this.props.onDestroy(this.getSplitTimelineId(), { keep: TIMELINE_SPLIT_KEEP_HISTORY });
      }

      this.props.onClearReturnAnchor();
      return;
    }

    const layoutChanged = !!prevProps.multiColumn !== !!this.props.multiColumn;

    if (layoutChanged && this.ownsSplit()) {
      this.clearSplitScroll();
      this.cancelInFlightResume('split_closed');
      this.flushHistoryPosition();
      this.props.onDestroy(this.getSplitTimelineId(), { keep: TIMELINE_SPLIT_KEEP_HISTORY });
    }

    if (layoutChanged) {
      this.clearSplitLayoutClass();
    } else {
      this.syncSplitLayoutClass();
    }

    this.restorePendingScroll();
    this.restoreScrollAnchor();

    const waitingForAnchor = prevProps.anchorHold && prevProps.splitBlocked;
    const stillWaitingForAnchor = this.props.anchorHold && this.props.splitBlocked;

    if ((waitingForAnchor && !stillWaitingForAnchor) || prevProps.splitReturnAnchor !== this.props.splitReturnAnchor) {
      this.scheduleReturnAnchorRestore();
    }

    this.syncHistorySurface();

    if (this.pendingExplicitResume && this.ownsSplit()) {
      this.pendingExplicitResume = false;
      if (this.props.onResumeHistory) {
        this.props.onResumeHistory(this.resumePayload({ explicit: true }));
      }
    } else if (previousLocationKey !== nextLocationKey) {
      this.maybeAutoResume();
    }

    if (this.shouldResetDocumentScroll) {
      this.shouldResetDocumentScroll = false;
      resetDocumentScroll();

      requestAnimationFrame(() => {
        if (!this.props.multiColumn && this.ownsSplit()) {
          resetDocumentScroll();
        }
      });
    }
  }

  componentWillUnmount () {
    this.positionUnmounted = true;
    this.returnAnchorToken = null;
    this.cancelInFlightResume('unmount');
    this.flushHistoryPosition();

    if (this.positionCaptureTimer) {
      clearTimeout(this.positionCaptureTimer);
      this.positionCaptureTimer = null;
    }

    if (this.unsubscribeSurface) {
      this.unsubscribeSurface();
      this.unsubscribeSurface = null;
    }

    if (this.ownsSplit() && !this.props.multiColumn && !this.props.splitBlocked) {
      const captured = this.capturePaneAnchor('history');

      this.props.onSaveReturnAnchor({
        locationKey: this.locationKey,
        id: captured.id,
        offset: captured.offset,
        fallbackOffset: captured.fallbackOffset,
      });
    }

    this.clearSplitScroll();
    this.clearSplitLayoutClass();

    if (this.ownsSplit()) {
      this.props.onDestroy(this.getSplitTimelineId(), { keep: TIMELINE_SPLIT_KEEP_HISTORY });
    }
  }

  historyAction = () => {
    const router = this.context && this.context.router;

    if (router && router.history && router.history.action) {
      return router.history.action;
    }

    return null;
  }

  positionIdentity = () => {
    if (!this.props.historyContract || !this.props.accountId) {
      return null;
    }

    const source = historySourceIdentity(this.props.sourceTimelineId, this.props.historyContract);
    const view = historyViewIdentity({
      columnId: this.props.columnId,
      sourceTimelineId: this.props.sourceTimelineId,
      locationKey: this.locationKey,
    });

    if (!source || !view) {
      return null;
    }

    return { source, view };
  }

  savedPosition = () => {
    const identity = this.positionIdentity();

    if (!identity) {
      return null;
    }

    return getPositionRegistry().find(this.props.accountId, identity.source, identity.view);
  }

  writeHistoryPosition = ({ sync = false, anchor = null } = {}) => {
    const identity = this.positionIdentity();

    if (!identity || !this.props.onCaptureHistoryPosition) {
      return null;
    }

    const captured = anchor || (this.surfaceId ? captureHistorySurface(this.surfaceId) : null);

    if (!captured || (!captured.statusId && !captured.displayRowId)) {
      return null;
    }

    const result = this.props.onCaptureHistoryPosition({
      accountId: this.props.accountId,
      source: identity.source,
      view: identity.view,
      anchor: captured,
      layout: historyLayout(this.props.multiColumn),
      routeEntryKey: this.locationKey || null,
      sync,
      minIntervalMs: HISTORY_POSITION_CAPTURE_INTERVAL_MS,
    });

    if (result && result.ok && !this.positionUnmounted) {
      this.setState(state => ({ positionEpoch: (state.positionEpoch || 0) + 1 }));
    }

    return result;
  }

  flushHistoryPosition = () => {
    if (this.positionCaptureTimer) {
      clearTimeout(this.positionCaptureTimer);
      this.positionCaptureTimer = null;
    }

    return this.writeHistoryPosition({ sync: true });
  }

  schedulePositionCapture = () => {
    if (this.positionCaptureTimer) {
      return;
    }

    this.positionCaptureTimer = setTimeout(() => {
      this.positionCaptureTimer = null;
      this.writeHistoryPosition({ sync: false });
    }, HISTORY_POSITION_CAPTURE_INTERVAL_MS);
  }

  cancelInFlightResume = (reason) => {
    const resume = this.props.historyResume;

    if (!resume || !resume.get || !this.props.onCancelHistoryResume) {
      return;
    }

    if (HISTORY_RESUME_IN_FLIGHT.indexOf(resume.get('phase')) === -1) {
      return;
    }

    this.props.onCancelHistoryResume({
      splitTimelineId: this.ownsSplit() ? this.getSplitTimelineId() : resume.get('splitSessionId'),
      requestId: resume.get('requestId'),
      reason,
    });
  }

  syncHistorySurface = () => {
    const id = this.ownsSplit() && this.props.historyContract ? this.getSplitTimelineId() : null;

    if (id === this.surfaceId) {
      return;
    }

    if (this.unsubscribeSurface) {
      this.unsubscribeSurface();
      this.unsubscribeSurface = null;
    }

    this.surfaceId = id;

    if (!id) {
      return;
    }

    this.unsubscribeSurface = subscribeHistorySurface(id, (event) => {
      if (event.type === 'unmount') {
        this.writeHistoryPosition({ sync: true, anchor: event.anchor });
        return;
      }

      if (event.type === 'scroll') {
        // Read the in-flight resume from the store. Props can still be the
        // pre-BEGIN render while restoreHistorySurface is on the stack.
        if (this.props.onCancelHistoryResume) {
          this.props.onCancelHistoryResume({
            splitTimelineId: id,
            reason: 'user_scroll',
          });
        }

        this.schedulePositionCapture();
      }
    });
  }

  resumePayload = ({ explicit, historyAction }) => {
    const identity = this.positionIdentity();

    return {
      accountId: this.props.accountId,
      sourceTimelineId: this.props.sourceTimelineId,
      splitTimelineId: this.getSplitTimelineId(),
      contract: this.props.historyContract,
      source: identity && identity.source,
      view: identity && identity.view,
      locationKey: this.locationKey,
      historyAction: historyAction || this.historyAction(),
      explicit: !!explicit,
      multiColumn: !!this.props.multiColumn,
    };
  }

  maybeAutoResume = () => {
    if (!this.props.onResumeHistory || !this.ownsSplit() || !this.positionIdentity()) {
      return;
    }

    if (this.autoResumeKey && this.autoResumeKey === this.locationKey) {
      return;
    }

    const saved = this.savedPosition();
    const items = this.props.historyItemIds;
    const statusId = saved && saved.position && saved.position.anchor && saved.position.anchor.statusId;
    const anchor = this.props.splitReturnAnchor;
    const decision = autoResumeDecision({
      saved,
      locationKey: this.locationKey,
      historyAction: this.historyAction(),
      historyOpen: true,
      statusInWindow: !!(items && typeof items.includes === 'function' && statusId && items.includes(statusId)),
      returnAnchorOwnsRestore: !!(anchor && anchor.get && anchor.get('locationKey') === this.locationKey && !this.props.multiColumn),
    });

    if (!decision.apply) {
      return;
    }

    this.autoResumeKey = this.locationKey;
    this.props.onResumeHistory(this.resumePayload({ explicit: false, historyAction: 'POP' }));
  }

  handleResumeHistory = (event) => {
    event.preventDefault();
    event.stopPropagation();

    if (!this.props.onResumeHistory || !this.positionIdentity()) {
      return;
    }

    const resume = this.props.historyResume;

    if (resume && resume.get && HISTORY_RESUME_IN_FLIGHT.indexOf(resume.get('phase')) !== -1) {
      return;
    }

    if (!this.ownsSplit()) {
      if (this.props.splitBlocked || this.props.activeSplitId) {
        return;
      }

      this.pendingExplicitResume = true;
      this.splitTimeline();
      return;
    }

    this.props.onResumeHistory(this.resumePayload({ explicit: true }));
  }

  renderResumeButton () {
    if (!this.positionIdentity()) {
      return null;
    }

    const saved = this.savedPosition();

    if (!saved) {
      return null;
    }

    const resume = this.props.historyResume;
    const phase = resume && resume.get ? resume.get('phase') : null;
    const busy = HISTORY_RESUME_IN_FLIGHT.indexOf(phase) !== -1;
    const failed = phase === 'failed';
    const ownSplit = this.ownsSplit();
    const otherSplit = !!this.props.activeSplitId && !ownSplit;
    const disabled = busy || otherSplit || (!ownSplit && !!this.props.splitBlocked);
    let label = messages.resume;

    if (failed) {
      label = messages.resumeFailed;
    } else if (busy) {
      label = messages.resumeBusy;
    }

    const text = this.props.intl.formatMessage(label);

    return (
      <button
        key='resume-history'
        type='button'
        className={classNames('column-header__button', 'column-header__resume-button', { active: failed })}
        title={text}
        aria-label={text}
        aria-busy={busy ? 'true' : 'false'}
        disabled={disabled}
        onClick={this.handleResumeHistory}
      >
        <Icon id='arrow-left' className='column-header__icon' />
      </button>
    );
  }

  renderSplitButton () {
    const { intl, splitBlocked, unavailableMessage } = this.props;
    const ownSplit = this.ownsSplit();
    const otherSplit = !!this.props.activeSplitId && !ownSplit;
    const disabled = otherSplit || (!ownSplit && !!splitBlocked);
    let label = messages.split;

    if (ownSplit) {
      label = messages.unsplit;
    } else if (otherSplit) {
      label = unavailableMessage;
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

  renderSplitter () {
    const ratio = this.getSplitRatio();

    return (
      <TimelineSplitter
        value={ratio}
        min={MIN_TIMELINE_SPLIT_RATIO}
        max={MAX_TIMELINE_SPLIT_RATIO}
        onChange={this.handleRatioChange}
        onCommit={this.handleRatioCommit}
        onCloseHistory={this.unsplitToLive}
        label={this.props.intl.formatMessage(messages.splitter)}
        closeHistoryLabel={this.props.intl.formatMessage(messages.closeHistoryPane)}
      />
    );
  }

  renderCloseLiveButton () {
    const label = this.props.intl.formatMessage(messages.closeLivePane);

    return (
      <button
        type='button'
        className='column-header__button column-header__split-close-live'
        title={label}
        aria-label={label}
        onClick={this.handleCloseLive}
      >
        <Icon id='times' className='column-header__icon' />
      </button>
    );
  }

  render () {
    const isSplit = this.ownsSplit();

    return this.props.children({
      isSplit,
      splitTimelineId: isSplit ? this.getSplitTimelineId() : null,
      ratio: this.getSplitRatio(),
      setColumnRef: this.setColumnRef,
      handleHeaderClick: this.handleHeaderClick,
      splitButton: this.renderSplitButton(),
      resumeButton: this.renderResumeButton(),
      splitter: isSplit ? this.renderSplitter() : null,
      closeLiveButton: isSplit ? this.renderCloseLiveButton() : null,
    });
  }

}

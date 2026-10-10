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

const messages = defineMessages({
  split: { id: 'timeline.split', defaultMessage: 'Split timeline' },
  unsplit: { id: 'timeline.unsplit', defaultMessage: 'Remove timeline split' },
  splitter: { id: 'timeline.splitter', defaultMessage: 'Timeline splitter' },
  closeHistoryPane: { id: 'timeline.close_history_pane', defaultMessage: 'Close history pane' },
  closeLivePane: { id: 'timeline.close_live_pane', defaultMessage: 'Close live pane' },
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

const articleSelector = (id) => {
  const value = String(id).replace(/\\/g, '\\\\').replace(/"/g, '\\"');

  return `article[data-id="${value}"]`;
};

const findAnchorArticle = (container, visibleTop) => {
  if (!container) {
    return null;
  }

  const articles = container.querySelectorAll('article[data-id]');

  for (let i = 0; i < articles.length; i += 1) {
    if (articles[i].getBoundingClientRect().bottom > visibleTop) {
      return articles[i];
    }
  }

  return null;
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
  };

  state = {
    ratio: null,
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

  getDocumentVisibleTop = () => {
    const portal = document.getElementById('tabs-bar__portal');
    const wrapper = portal && portal.closest('.tabs-bar__wrapper');

    if (!wrapper) {
      return 0;
    }

    const rect = wrapper.getBoundingClientRect();

    if (rect.bottom <= 0 || rect.top > 0) {
      return 0;
    }

    return Math.max(0, rect.bottom);
  }

  captureDocumentAnchor = () => {
    const scrollable = this.findScrollable('single');
    const visibleTop = this.getDocumentVisibleTop();
    const fallbackOffset = scrollable ? Math.max(0, visibleTop - scrollable.getBoundingClientRect().top) : 0;
    const article = findAnchorArticle(scrollable, visibleTop);

    if (!article) {
      return { id: null, offset: 0, fallbackOffset, target: 'history' };
    }

    return {
      id: article.getAttribute('data-id'),
      offset: article.getBoundingClientRect().top - visibleTop,
      fallbackOffset,
      target: 'history',
    };
  }

  capturePaneAnchor = (pane) => {
    const scrollable = this.findScrollable(pane);
    const visibleTop = scrollable ? scrollable.getBoundingClientRect().top : 0;
    const fallbackOffset = scrollable ? scrollable.scrollTop : 0;
    const article = findAnchorArticle(scrollable, visibleTop);

    if (!article) {
      return { id: null, offset: 0, fallbackOffset, target: 'document' };
    }

    return {
      id: article.getAttribute('data-id'),
      offset: article.getBoundingClientRect().top - visibleTop,
      fallbackOffset,
      target: 'document',
    };
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

      const article = anchor.id ? history.querySelector(articleSelector(anchor.id)) : null;

      if (article) {
        const delta = (article.getBoundingClientRect().top - history.getBoundingClientRect().top) - anchor.offset;
        history.scrollTop += delta;
      } else {
        history.scrollTop = anchor.fallbackOffset;
      }

      return true;
    }

    if (anchor.target === 'document') {
      const scrollable = this.findScrollable('single');
      const scroller = document.scrollingElement || document.body;

      if (!scrollable || !scroller) {
        return false;
      }

      const visibleTop = this.getDocumentVisibleTop();
      const article = anchor.id ? scrollable.querySelector(articleSelector(anchor.id)) : null;

      if (article) {
        const delta = article.getBoundingClientRect().top - visibleTop - anchor.offset;
        scroller.scrollTop += delta;
      } else {
        const listOffset = visibleTop - scrollable.getBoundingClientRect().top;
        scroller.scrollTop += anchor.fallbackOffset - listOffset;
      }

      return true;
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

    if (this.props.multiColumn) {
      this.scrollAnchor = null;
      this.pendingScroll = { top: this.captureScrollTop('single'), target: 'history' };
    } else {
      this.pendingScroll = null;
      this.scrollAnchor = this.captureDocumentAnchor();
      this.shouldResetDocumentScroll = true;
    }

    this.props.onCreate(this.getSplitTimelineId());
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
  }

  componentDidUpdate (prevProps) {
    const previousLocationKey = prevProps.location ? prevProps.location.key : undefined;
    const nextLocationKey = this.props.location ? this.props.location.key : undefined;

    if (previousLocationKey !== nextLocationKey) {
      this.locationKey = nextLocationKey;
    }

    if (prevProps.splitContextKey !== this.props.splitContextKey) {
      this.clearSplitScroll();
      this.clearSplitLayoutClass();

      if (this.ownsSplit()) {
        this.props.onDestroy(this.getSplitTimelineId(), { keep: TIMELINE_SPLIT_KEEP_HISTORY });
      }

      this.props.onClearReturnAnchor();
      return;
    }

    const layoutChanged = !!prevProps.multiColumn !== !!this.props.multiColumn;

    if (layoutChanged && this.ownsSplit()) {
      this.clearSplitScroll();
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
    this.returnAnchorToken = null;

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
      splitter: isSplit ? this.renderSplitter() : null,
      closeLiveButton: isSplit ? this.renderCloseLiveButton() : null,
    });
  }

}

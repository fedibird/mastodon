import React from 'react';
import PropTypes from 'prop-types';
import { timelineCardColumnsForWidth } from 'mastodon/utils/timeline_layout';
import { mediaColumnsForWidth } from 'mastodon/utils/media_display';
import {
  planMasonryPrependFrontier,
  isFullWidthMasonryKey,
  reconcileMasonryPrepends,
} from 'mastodon/utils/timeline_masonry_layout';

const GAP = 8;
const ESTIMATED_HEIGHT = 190;

// A prepend is laid out above the existing feed instead of packing onto
// the bottom of whichever old column happens to be shortest. The tallest
// upward protrusion shifts ALL old columns down by the same amount; shorter
// new columns reserve the remainder as placeholders that future arrivals use.
const arrangeMasonry = (keys, prefixCount, prependCount, columns, availableWidth, measuredHeight, assignments) => {
  const cellWidth = (availableWidth - GAP * (columns - 1)) / columns;
  const bottoms = new Array(columns).fill(0);
  const positions = new Map();

  const place = key => {
    const height = measuredHeight(key);

    if (isFullWidthMasonryKey(key)) {
      const top = Math.max(...bottoms);
      bottoms.fill(top + height + GAP);
      positions.set(key, { top, left: 0, width: availableWidth, fullWidth: true });
      return;
    }

    let column = assignments.get(key);
    if (column === undefined || column < 0 || column >= columns) {
      // Initial loads and old-page appends retain the original Masonry rule.
      column = bottoms.indexOf(Math.min(...bottoms));
      assignments.set(key, column);
    }

    const top = bottoms[column];
    bottoms[column] += height + GAP;
    positions.set(key, { top, left: column * (cellWidth + GAP), width: cellWidth });
  };

  keys.slice(0, prefixCount).forEach(place);

  // Pinned statuses/reload controls always stay above incoming live content.
  const liveTop = Math.max(...bottoms);
  const prependedKeys = keys.slice(prefixCount, prefixCount + prependCount);
  const prepend = planMasonryPrependFrontier(columns, prependedKeys, assignments, measuredHeight, GAP);

  // A common boundary protects the original cards and their column offsets.
  // Adding a tile inside an existing placeholder does not move older cards.
  bottoms.fill(liveTop + prepend.height);
  keys.slice(prefixCount + prependCount).forEach(place);

  prependedKeys.forEach(key => {
    const item = prepend.positions.get(key);
    if (item.fullWidth) {
      positions.set(key, {
        top: liveTop + item.top, left: 0, width: availableWidth, fullWidth: true,
      });
    } else {
      positions.set(key, {
        top: liveTop + item.top,
        left: item.column * (cellWidth + GAP),
        width: cellWidth,
      });
    }
  });

  const placeholders = prepend.placeholders.map(blank => ({
    ...blank,
    top: liveTop + blank.top,
    left: blank.column * (cellWidth + GAP),
    width: cellWidth,
  }));

  return {
    positions,
    placeholders,
    height: keys.length ? Math.max(...bottoms) - GAP : 0,
  };
};

// Keep DOM/keyboard order newest-first; only new item positions and headroom
// placeholders change on a streaming prepend.
export default class TimelineMasonry extends React.PureComponent {

  static propTypes = {
    children: PropTypes.node,
    mode: PropTypes.string.isRequired,
    mediaSize: PropTypes.string,
    onCaptureLayoutAnchor: PropTypes.func,
    onRestoreLayoutAnchor: PropTypes.func,
    holdMeasurements: PropTypes.func,
    onMeasurementsHeld: PropTypes.func,
  };

  state = { width: 0, heights: {} };
  assignments = new Map();
  observed = new Set();
  columns = 0;
  layoutVariant = null;
  previousKeys = [];
  prefixKeys = [];
  prependKeys = [];

  setRoot = node => {
    this.root = node;
  }

  componentDidMount () {
    if (window.ResizeObserver) {
      this.resizeObserver = new window.ResizeObserver(this.handleResize);
    }

    window.addEventListener('resize', this.measureFallback);
    this.observe();
  }

  // A late image load, CW expansion, or ResizeObserver measurement changes
  // this component's own state, without updating ScrollableList's props.
  // Capture its visible tile *before* the new transforms are committed.
  getSnapshotBeforeUpdate (prevProps, prevState) {
    const sizeChanged = prevState.width !== this.state.width ||
      prevState.heights !== this.state.heights ||
      prevProps.mode !== this.props.mode ||
      prevProps.mediaSize !== this.props.mediaSize;

    return sizeChanged && this.props.onCaptureLayoutAnchor
      ? this.props.onCaptureLayoutAnchor()
      : null;
  }

  componentDidUpdate (prevProps, prevState, snapshot) {
    this.observe();

    // Parent list prepends use their own snapshot; this path complements them
    // for measurements arriving *after* that short correction window.
    if (snapshot && this.props.onRestoreLayoutAnchor) {
      this.props.onRestoreLayoutAnchor(snapshot);
    }
  }

  componentWillUnmount () {
    window.removeEventListener('resize', this.measureFallback);
    if (this.resizeObserver) {
      this.resizeObserver.disconnect();
    }
    this.observed.clear();
  }

  measureFallback = () => {
    if (!this.root) {
      return;
    }

    const width = Math.round(this.root.getBoundingClientRect().width);
    const heights = { ...this.state.heights };

    Array.from(this.root.children).forEach(node => {
      const key = node.getAttribute('data-layout-key');
      const content = this._contentNode(node);
      if (key && content) {
        heights[key] = Math.max(1, Math.ceil(content.getBoundingClientRect().height));
      }
    });

    if (width !== this.state.width || Object.keys(heights).some(key => heights[key] !== this.state.heights[key])) {
      this._commitMeasurements(width, heights);
    }
  }

  handleResize = entries => {
    const heights = {};
    let width = this.state.width;

    entries.forEach(entry => {
      if (entry.target === this.root) {
        width = Math.round(entry.contentRect.width);
      } else {
        const key = this._layoutKeyFromTarget(entry.target);
        if (key) {
          heights[key] = Math.max(1, Math.ceil(entry.contentRect.height));
        }
      }
    });

    this._commitMeasurements(width, heights);
  }

  _contentNode = (item) => {
    const content = item && item.firstElementChild;
    return content && content.classList.contains('timeline-masonry__content') ? content : item;
  }

  _layoutKeyFromTarget = (target) => {
    if (!target || target === this.root || !target.getAttribute) {
      return null;
    }
    if (target.hasAttribute('data-layout-key')) {
      return target.getAttribute('data-layout-key');
    }
    const item = target.closest && target.closest('[data-layout-key]');
    return item ? item.getAttribute('data-layout-key') : null;
  }

  _slotHeight = (key) => this.state.heights[key] || ESTIMATED_HEIGHT;

  // The absolute tile's transform stays put while momentum owns the scroll.
  // Lock its border box to that slot so a late image or expanded CW cannot
  // paint over the next card, and a shorter measurement cannot open a hole.
  _slotLock = (key) => {
    if (!this.props.holdMeasurements || !this.props.holdMeasurements() || !this._heldHeights) {
      return null;
    }
    const pending = this._heldHeights[key];
    const slot = this._slotHeight(key);
    if (pending === undefined || Math.abs(pending - slot) <= 1) {
      return null;
    }
    return slot;
  }

  _heldHeightsChanged = (previous, next) => {
    if (!previous) {
      return true;
    }
    const keys = Object.keys(next);
    return keys.length !== Object.keys(previous).length || keys.some(key => previous[key] !== next[key]);
  }

  // A height applied while the reader is still in momentum moves every tile
  // below it. Keep the measurement and apply it once the list is idle, when
  // the anchor restore can run without writing scrollTop into the swipe.
  _commitMeasurements = (width, heights) => {
    if (this.props.holdMeasurements && this.props.holdMeasurements()) {
      const nextHeights = { ...(this._heldHeights || {}), ...heights };
      const changed = this._heldHeightsChanged(this._heldHeights, nextHeights);
      this._heldWidth = width;
      this._heldHeights = nextHeights;
      if (changed) {
        if (this.props.onMeasurementsHeld) {
          this.props.onMeasurementsHeld();
        }
        this.forceUpdate();
      }
      return;
    }

    const merged = this._heldHeights ? { ...this._heldHeights, ...heights } : heights;
    const nextWidth = width === undefined ? this._heldWidth : width;
    this._heldHeights = null;
    this._heldWidth = undefined;
    this._applyMeasurements(nextWidth === undefined ? this.state.width : nextWidth, merged);
  }

  hasHeldMeasurements = () => (this._heldHeights !== undefined && this._heldHeights !== null) || this._heldWidth !== undefined;

  discardHeldMeasurements = () => {
    this._heldHeights = null;
    this._heldWidth = undefined;
  }

  flushHeldMeasurements = () => {
    if (!this.hasHeldMeasurements()) {
      return;
    }

    const heights = this._heldHeights || {};
    const width = this._heldWidth === undefined ? this.state.width : this._heldWidth;
    this._heldHeights = null;
    this._heldWidth = undefined;
    this._applyMeasurements(width, heights);
  }

  _applyMeasurements = (width, heights) => {
    this.setState(state => {
      const changed = Object.keys(heights).some(key => Math.abs((state.heights[key] || 0) - heights[key]) > 1);
      if (!changed && width === state.width) {
        return null;
      }

      return { width, heights: changed ? { ...state.heights, ...heights } : state.heights };
    });
  }

  observe () {
    if (!this.root) {
      return;
    }
    if (!this.resizeObserver) {
      this.measureFallback();
      return;
    }

    const items = Array.from(this.root.children).filter(node => node.hasAttribute('data-layout-key'));
    const nodes = new Set([this.root, ...items.map(item => this._contentNode(item))]);
    this.observed.forEach(node => {
      if (!nodes.has(node)) {
        this.resizeObserver.unobserve(node);
        this.observed.delete(node);
      }
    });
    nodes.forEach(node => {
      if (!this.observed.has(node)) {
        this.resizeObserver.observe(node);
        this.observed.add(node);
      }
    });
  }

  render () {
    const children = React.Children.toArray(this.props.children);
    const width = this.state.width;
    const availableWidth = Math.max(1, width || 320);
    let columns = 1;
    if (width) {
      columns = this.props.mode === 'media'
        ? mediaColumnsForWidth(this.props.mediaSize, width)
        : timelineCardColumnsForWidth(this.props.mode, width);
    }
    const variant = this.props.mode + ':' + (this.props.mediaSize || '');

    // Explicit resizing and layout changes may start fresh; streaming new
    // items must never move previously assigned items horizontally.
    if (this.columns !== columns || this.layoutVariant !== variant) {
      this.columns = columns;
      this.layoutVariant = variant;
      this.assignments.clear();
      this.previousKeys = [];
      this.prefixKeys = [];
      this.prependKeys = [];
    }

    const keys = children.map(child => String(child.key));
    const plan = reconcileMasonryPrepends(this.previousKeys, keys, this.prefixKeys);

    if (plan.reset) {
      this.assignments.clear();
      this.prependKeys = [];
    }

    const existing = new Set(keys);
    this.assignments.forEach((_, key) => {
      if (!existing.has(key)) {
        this.assignments.delete(key);
      }
    });

    // Only the contiguous portion immediately below the fixed prefix is
    // part of the upward-growing area. A middle insertion is an old-page
    // change, not another streaming prepend.
    const prepended = new Set([...this.prependKeys, ...plan.prependedKeys]);
    this.prependKeys = [];
    for (const key of keys.slice(plan.prefixKeys.length)) {
      if (!prepended.has(key)) {
        break;
      }
      this.prependKeys.push(key);
    }

    const measuredHeight = key => this.state.heights[key] || ESTIMATED_HEIGHT;
    const { positions, placeholders, height } = arrangeMasonry(
      keys, plan.prefixKeys.length, this.prependKeys.length,
      columns, availableWidth, measuredHeight, this.assignments,
    );

    this.previousKeys = keys;
    this.prefixKeys = plan.prefixKeys;

    return (
      <div
        ref={this.setRoot}
        className={this.props.onCaptureLayoutAnchor ? 'timeline-masonry timeline-masonry--managed-anchor' : 'timeline-masonry'}
        style={{ height: Math.max(0, height) }}
      >
        {children.map(child => {
          const key = String(child.key);
          const { top, left, width: itemWidth, fullWidth } = positions.get(key);

          const slotLock = this._slotLock(key);
          const style = {
            width: width ? itemWidth + 'px' : '100%',
            insetInlineStart: left + 'px',
            transform: 'translate3d(0, ' + top + 'px, 0)',
          };
          if (slotLock !== null) {
            style.height = slotLock + 'px';
            style.overflow = 'hidden';
          }

          return (
            <div
              key={key}
              data-layout-key={key}
              className={fullWidth ? 'timeline-masonry__item timeline-masonry__item--full' : 'timeline-masonry__item'}
              style={style}
            >
              <div className='timeline-masonry__content'>
                {child}
              </div>
            </div>
          );
        })}
        {placeholders.map(placeholder => (
          <div
            key={'placeholder:' + placeholder.key}
            aria-hidden='true'
            className='timeline-masonry__placeholder'
            style={{
              width: placeholder.width + 'px',
              height: placeholder.height + 'px',
              insetInlineStart: placeholder.left + 'px',
              transform: 'translate3d(0, ' + placeholder.top + 'px, 0)',
            }}
          />
        ))}
      </div>
    );
  }

}

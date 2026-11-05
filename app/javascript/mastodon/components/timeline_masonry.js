import React from 'react';
import PropTypes from 'prop-types';
import { timelineCardColumnsForWidth } from 'mastodon/utils/timeline_layout';
import { mediaColumnsForWidth } from 'mastodon/utils/media_display';
import {
  assignMasonryPrependedColumns,
  isFullWidthMasonryKey,
  reconcileMasonryPrepends,
} from 'mastodon/utils/timeline_masonry_layout';

const GAP = 8;
const ESTIMATED_HEIGHT = 190;

// Preserve each item's column while positioning items newest-first within
// that column. A full-width row synchronizes the columns at its boundary.
const arrangeMasonry = (keys, prefixCount, columns, availableWidth, measuredHeight, assignments) => {
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

  // Pinned statuses/reload controls stay above all live statuses even when
  // the final pinned row has different heights in different columns.
  bottoms.fill(Math.max(...bottoms));
  keys.slice(prefixCount).forEach(place);

  return {
    positions,
    height: keys.length ? Math.max(...bottoms) - GAP : 0,
  };
};

// Keep logical (DOM/keyboard) newest-first order independent from columns.
// Incoming items are assigned to the currently shortest column, with
// inline-end winning ties. Unlike reserved rows, no empty cells are added.
export default class TimelineMasonry extends React.PureComponent {

  static propTypes = {
    children: PropTypes.node,
    mode: PropTypes.string.isRequired,
    mediaSize: PropTypes.string,
  };

  state = { width: 0, heights: {} };
  assignments = new Map();
  observed = new Set();
  columns = 0;
  layoutVariant = null;
  previousKeys = [];
  prefixKeys = [];

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

  componentDidUpdate () {
    this.observe();
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
      if (key) {
        heights[key] = Math.max(1, Math.ceil(node.getBoundingClientRect().height));
      }
    });

    if (width !== this.state.width || Object.keys(heights).some(key => heights[key] !== this.state.heights[key])) {
      this.setState({ width, heights });
    }
  }

  handleResize = entries => {
    const heights = {};
    let width = this.state.width;

    entries.forEach(entry => {
      if (entry.target === this.root) {
        width = Math.round(entry.contentRect.width);
      } else {
        const key = entry.target.getAttribute('data-layout-key');
        if (key) {
          heights[key] = Math.max(1, Math.ceil(entry.contentRect.height));
        }
      }
    });

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

    const nodes = new Set([this.root, ...Array.from(this.root.children).filter(node => node.hasAttribute('data-layout-key'))]);
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
    }

    const keys = children.map(child => String(child.key));
    const plan = reconcileMasonryPrepends(this.previousKeys, keys, this.prefixKeys);

    if (plan.reset) {
      this.assignments.clear();
    }

    const existing = new Set(keys);
    this.assignments.forEach((_, key) => {
      if (!existing.has(key)) {
        this.assignments.delete(key);
      }
    });

    const measuredHeight = key => this.state.heights[key] || ESTIMATED_HEIGHT;

    if (columns > 1 && plan.prependedKeys.length > 0) {
      // First give any newly paged older keys their normal column assignment.
      // Then place the received batch oldest-to-newest, adjusting column
      // heights after *each* addition; unlike reserved bands there is no
      // row maximum that forces whitespace into shorter columns.
      const prepended = new Set(plan.prependedKeys);
      const baseKeys = keys.filter(key => !prepended.has(key));
      arrangeMasonry(baseKeys, plan.prefixKeys.length, columns, availableWidth, measuredHeight, this.assignments);

      const olderMainKeys = keys.slice(plan.prefixKeys.length + plan.prependedKeys.length);
      assignMasonryPrependedColumns(
        columns, olderMainKeys, plan.prependedKeys, this.assignments, measuredHeight, GAP,
      );
    }

    const { positions, height } = arrangeMasonry(
      keys, plan.prefixKeys.length, columns, availableWidth, measuredHeight, this.assignments,
    );

    this.previousKeys = keys;
    this.prefixKeys = plan.prefixKeys;

    return (
      <div ref={this.setRoot} className='timeline-masonry' style={{ height: Math.max(0, height) }}>
        {children.map(child => {
          const key = String(child.key);
          const { top, left, width: itemWidth, fullWidth } = positions.get(key);

          return (
            <div
              key={key}
              data-layout-key={key}
              className={fullWidth ? 'timeline-masonry__item timeline-masonry__item--full' : 'timeline-masonry__item'}
              style={{ width: width ? itemWidth + 'px' : '100%', insetInlineStart: left + 'px', transform: 'translate3d(0, ' + top + 'px, 0)' }}
            >
              {child}
            </div>
          );
        })}
      </div>
    );
  }

}

import React from 'react';
import PropTypes from 'prop-types';
import { timelineCardColumnsForWidth } from 'mastodon/utils/timeline_layout';
import { mediaColumnsForWidth } from 'mastodon/utils/media_display';
import { isFullWidthMasonryKey, reconcileMasonryPrependRows } from 'mastodon/utils/timeline_masonry_layout';

const GAP = 8;
const ESTIMATED_HEIGHT = 190;

// DOM order stays newest-first, independently of the physical columns.
// Streaming prepends fill reserved rows end-to-start; existing card positions
// only move together when the height of the reserved area changes.
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
  prependRows = [];
  prefixKeys = [];

  setRoot = node => { this.root = node; }

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

    // Empty placeholders reserve space, but only actual cards have heights
    // to measure. Do not observe the placeholders as stream events arrive.
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
    const columns = width ? (this.props.mode === 'media'
      ? mediaColumnsForWidth(this.props.mediaSize, width)
      : timelineCardColumnsForWidth(this.props.mode, width)) : 1;
    const variant = this.props.mode + ':' + (this.props.mediaSize || '');

    // Resize, mode and size changes are explicit re-layouts. A streaming
    // prepend within the same layout is not: keep existing columns intact.
    if (this.columns !== columns || this.layoutVariant !== variant) {
      this.columns = columns;
      this.layoutVariant = variant;
      this.assignments.clear();
      this.previousKeys = [];
      this.prependRows = [];
      this.prefixKeys = [];
    }

    const keys = children.map(child => String(child.key));
    const existing = new Set(keys);
    const prependPlan = reconcileMasonryPrependRows(columns, this.previousKeys, keys, this.prependRows, this.prefixKeys);
    this.prependRows = prependPlan.rows;
    this.prefixKeys = prependPlan.prefixKeys;
    this.previousKeys = keys;

    this.assignments.forEach((_, key) => {
      if (!existing.has(key)) {
        this.assignments.delete(key);
      }
    });

    const cellWidth = (availableWidth - GAP * (columns - 1)) / columns;
    const arrangements = new Map();
    const placeholders = [];
    const measuredHeight = key => this.state.heights[key] || ESTIMATED_HEIGHT;
    const prefixKeySet = new Set(this.prefixKeys);
    const prefixBottoms = new Array(columns).fill(0);

    // Featured/reload controls remain at the top. Build their positions once
    // and reserve a full-width boundary underneath before streaming rows.
    children.forEach(child => {
      const key = String(child.key);
      if (!prefixKeySet.has(key)) {
        return;
      }

      const height = measuredHeight(key);
      if (isFullWidthMasonryKey(key)) {
        const top = Math.max(...prefixBottoms);
        prefixBottoms.fill(top + height + GAP);
        arrangements.set(key, { top, left: 0, width: availableWidth, fullWidth: true });
        return;
      }

      let column = this.assignments.get(key);
      if (column === undefined || column >= columns) {
        column = prefixBottoms.indexOf(Math.min(...prefixBottoms));
        this.assignments.set(key, column);
      }
      const top = prefixBottoms[column];
      prefixBottoms[column] += height + GAP;
      arrangements.set(key, { top, left: column * (cellWidth + GAP), width: cellWidth });
    });

    let reservedTop = Math.max(...prefixBottoms);

    this.prependRows.forEach((row, index) => {
      if (row.kind === 'full') {
        arrangements.set(row.key, {
          top: reservedTop,
          left: 0,
          width: availableWidth,
          fullWidth: true,
        });
        reservedTop += measuredHeight(row.key) + GAP;
        return;
      }

      const rowHeight = Math.max(1, ...row.slots.filter(Boolean).map(measuredHeight));

      row.slots.forEach((key, column) => {
        const left = column * (cellWidth + GAP);
        const itemHeight = key ? measuredHeight(key) : 0;

        if (key) {
          arrangements.set(key, { top: reservedTop, left, width: cellWidth });
        }

        // Blank cells and the space below short tiles are real, inert
        // placeholders. No existing card needs to be rebalanced to fill them.
        if (rowHeight - itemHeight > 1) {
          placeholders.push({
            key: index + ':' + column,
            top: reservedTop + itemHeight,
            left,
            width: cellWidth,
            height: rowHeight - itemHeight,
          });
        }
      });

      reservedTop += rowHeight + GAP;
    });

    const bottoms = new Array(columns).fill(reservedTop);

    children.forEach(child => {
      const key = String(child.key);
      if (arrangements.has(key)) {
        return;
      }

      const fullWidth = isFullWidthMasonryKey(key);
      const height = measuredHeight(key);

      if (fullWidth) {
        const top = Math.max(...bottoms);
        bottoms.fill(top + height + GAP);
        arrangements.set(key, { top, left: 0, width: availableWidth, fullWidth });
        return;
      }

      let column = this.assignments.get(key);
      if (column === undefined || column >= columns) {
        column = bottoms.indexOf(Math.min(...bottoms));
        this.assignments.set(key, column);
      }

      const top = bottoms[column];
      bottoms[column] += height + GAP;
      arrangements.set(key, { top, left: column * (cellWidth + GAP), width: cellWidth });
    });

    const height = Math.max(0, ...bottoms) - (children.length ? GAP : 0);

    return (
      <div ref={this.setRoot} className='timeline-masonry' style={{ height: Math.max(0, height) }}>
        {children.map(child => {
          const key = String(child.key);
          const { top, left, width: itemWidth, fullWidth } = arrangements.get(key);

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

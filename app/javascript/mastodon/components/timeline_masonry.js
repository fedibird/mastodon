import React from 'react';
import PropTypes from 'prop-types';
import { timelineCardColumnsForWidth } from 'mastodon/utils/timeline_layout';

const GAP = 8;
const ESTIMATED_HEIGHT = 190;

// DOM order is chronological even though visual cards use balanced columns.
// Existing keys keep their column when new posts arrive at the front.
export default class TimelineMasonry extends React.PureComponent {

  static propTypes = {
    children: PropTypes.node,
    mode: PropTypes.string.isRequired,
  };

  state = { width: 0, heights: {} };
  assignments = new Map();
  observed = new Set();
  columns = 0;

  setRoot = node => { this.root = node; }

  componentDidMount () {
    if (typeof ResizeObserver !== 'undefined') {
      this.resizeObserver = new ResizeObserver(this.handleResize);
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

    const nodes = new Set([this.root, ...Array.from(this.root.children)]);
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
    const columns = width ? timelineCardColumnsForWidth(this.props.mode, width) : 1;

    if (this.columns !== columns) {
      this.columns = columns;
      this.assignments.clear();
    }

    const existing = new Set(children.map(child => String(child.key)));
    this.assignments.forEach((_, key) => {
      if (!existing.has(key)) {
        this.assignments.delete(key);
      }
    });

    const cellWidth = (availableWidth - GAP * (columns - 1)) / columns;
    const bottoms = new Array(columns).fill(0);

    const arranged = children.map(child => {
      const key = String(child.key);
      const fullWidth = key.includes('gap:');
      const height = this.state.heights[key] || ESTIMATED_HEIGHT;

      if (fullWidth) {
        const top = Math.max(...bottoms);
        bottoms.fill(top + height + GAP);
        return { child, key, top, left: 0, width: availableWidth, fullWidth };
      }

      let column = this.assignments.get(key);
      if (column === undefined || column >= columns) {
        column = bottoms.indexOf(Math.min(...bottoms));
        this.assignments.set(key, column);
      }

      const top = bottoms[column];
      bottoms[column] += height + GAP;
      return { child, key, top, left: column * (cellWidth + GAP), width: cellWidth };
    });
    const height = Math.max(0, ...bottoms) - (children.length ? GAP : 0);

    return (
      <div ref={this.setRoot} className='timeline-masonry' style={{ height: Math.max(0, height) }}>
        {arranged.map(({ child, key, top, left, width: itemWidth, fullWidth }) => (
          <div
            key={key}
            data-layout-key={key}
            className={fullWidth ? 'timeline-masonry__item timeline-masonry__item--full' : 'timeline-masonry__item'}
            style={{ width: width ? `${itemWidth}px` : '100%', transform: `translate3d(${left}px, ${top}px, 0)` }}
          >
            {child}
          </div>
        ))}
      </div>
    );
  }

}

import React from 'react';
import PropTypes from 'prop-types';
import { supportsPassiveEvents } from 'detect-passive-events';
import { scrollTop } from '../scroll';
import classNames from 'classnames';

export default class Column extends React.PureComponent {

  static propTypes = {
    children: PropTypes.node,
    label: PropTypes.string,
    bindToDocument: PropTypes.bool,
    columnWidth: PropTypes.string,
    dropComposerId: PropTypes.string,
  };

  scrollTop () {
    const scrollable = this.props.bindToDocument ? document.scrollingElement : this.node.querySelector('.scrollable');

    if (!scrollable) {
      return;
    }

    this._interruptScrollAnimation = scrollTop(scrollable);
  }

  handleWheel = () => {
    if (typeof this._interruptScrollAnimation !== 'function') {
      return;
    }

    this._interruptScrollAnimation();
  }

  setRef = c => {
    this.node = c;
  }

  // Group timelines publish a viewer-specific landmark without changing
  // `label`. A label prop change would re-render every child in the column.
  setLandmarkLabel(label) {
    this.landmarkLabel = typeof label === 'string' ? label : undefined;
    this.applyLandmarkLabel();
  }

  applyLandmarkLabel() {
    if (!this.node) {
      return;
    }

    const label = this.landmarkLabel !== undefined ? this.landmarkLabel : this.props.label;

    if (typeof label !== 'string' || this.node.getAttribute('aria-label') === label) {
      return;
    }

    this.node.setAttribute('aria-label', label);
  }

  componentDidMount () {
    this.applyLandmarkLabel();

    if (this.props.bindToDocument) {
      document.addEventListener('wheel', this.handleWheel, supportsPassiveEvents ? { passive: true } : false);
    } else {
      this.node.addEventListener('wheel', this.handleWheel, supportsPassiveEvents ? { passive: true } : false);
    }
  }

  componentDidUpdate () {
    this.applyLandmarkLabel();
  }

  componentWillUnmount () {
    if (typeof this._interruptScrollAnimation === 'function') {
      this._interruptScrollAnimation();
    }

    if (this.props.bindToDocument) {
      document.removeEventListener('wheel', this.handleWheel);
    } else if (this.node) {
      this.node.removeEventListener('wheel', this.handleWheel);
    }
  }

  render () {
    const { label, columnWidth, children, dropComposerId } = this.props;

    return (
      <div
        role='region'
        aria-label={label}
        className={classNames('column', columnWidth)}
        data-drop-composer-id={dropComposerId || undefined}
        ref={this.setRef}
      >
        {children}
      </div>
    );
  }

}

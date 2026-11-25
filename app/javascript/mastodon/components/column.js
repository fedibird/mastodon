import React from 'react';
import PropTypes from 'prop-types';
import { supportsPassiveEvents } from 'detect-passive-events';
import { scrollTop } from '../scroll';
import classNames from 'classnames';
import { forgetEmojiMuteAttributeSource, rememberEmojiMuteAttributeSource, rememberEmojiMuteDisplayAttribute } from 'mastodon/features/emoji/emoji_mute_sources';

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

  // Only a caller that sets a landmark override may rewrite the mounted
  // aria-label. Other columns keep whatever the live guard wrote.
  setLandmarkLabel(label, source) {
    if (typeof label !== 'string') {
      this.landmarkActive = false;
      this.landmarkLabel = undefined;
      this.landmarkSource = null;

      if (this.node) {
        forgetEmojiMuteAttributeSource(this.node, 'aria-label');
      }

      return;
    }

    this.landmarkActive = true;
    this.landmarkLabel = label;
    this.landmarkSource = source && typeof source.plain === 'string' ? source : null;
    this.applyLandmarkLabel();
  }

  applyLandmarkLabel() {
    if (!this.landmarkActive || !this.node || typeof this.landmarkLabel !== 'string') {
      return;
    }

    if (this.node.getAttribute('aria-label') !== this.landmarkLabel) {
      this.node.setAttribute('aria-label', this.landmarkLabel);
    }

    const source = this.landmarkSource;

    if (source && typeof source.html === 'string' && source.html !== '') {
      rememberEmojiMuteDisplayAttribute(this.node, 'aria-label', source.plain || '', source.html);
      return;
    }

    if (source) {
      rememberEmojiMuteAttributeSource(this.node, 'aria-label', source.plain);
      return;
    }

    forgetEmojiMuteAttributeSource(this.node, 'aria-label');
  }

  componentDidMount () {
    if (this.landmarkActive) {
      this.applyLandmarkLabel();
    }

    if (this.props.bindToDocument) {
      document.addEventListener('wheel', this.handleWheel, supportsPassiveEvents ? { passive: true } : false);
    } else {
      this.node.addEventListener('wheel', this.handleWheel, supportsPassiveEvents ? { passive: true } : false);
    }
  }

  componentDidUpdate () {
    if (this.landmarkActive) {
      this.applyLandmarkLabel();
    }
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

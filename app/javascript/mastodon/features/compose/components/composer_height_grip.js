import React from 'react';
import PropTypes from 'prop-types';
import { defineMessages, injectIntl } from 'react-intl';
import { clampComposerTextHeight, composerTextHeightBounds } from '../composer_text_height';

const messages = defineMessages({
  resize: { id: 'compose_form.resize_text', defaultMessage: 'Resize the text field' },
});

const KEYBOARD_STEP = 22;

class ComposerHeightGrip extends React.PureComponent {

  static propTypes = {
    intl: PropTypes.object,
    onChange: PropTypes.func.isRequired,
    onMeasure: PropTypes.func.isRequired,
  };

  componentWillUnmount () {
    this.detachPointerListeners();
    this.restoreSelection();
  }

  setGrip = (node) => {
    this.grip = node;
  };

  label () {
    if (this.props.intl) {
      return this.props.intl.formatMessage(messages.resize);
    }

    return messages.resize.defaultMessage;
  }

  bounds () {
    const measured = this.props.onMeasure() || {};

    return composerTextHeightBounds({
      viewportHeight: window.innerHeight,
      chromeHeight: measured.chromeHeight,
      lineHeight: measured.lineHeight,
    });
  }

  detachPointerListeners = () => {
    document.removeEventListener('pointermove', this.handlePointerMove);
    document.removeEventListener('pointerup', this.handlePointerUp);
    document.removeEventListener('pointercancel', this.handlePointerCancel);
  };

  preventSelection = () => {
    this.previousUserSelect = document.body.style.userSelect;
    document.body.style.userSelect = 'none';
  };

  restoreSelection = () => {
    if (this.previousUserSelect === undefined) {
      return;
    }

    document.body.style.userSelect = this.previousUserSelect;
    this.previousUserSelect = undefined;
  };

  handlePointerDown = (event) => {
    if (event.button !== undefined && event.button !== 0) {
      return;
    }

    event.preventDefault();
    this.dragging = true;
    this.startY = event.clientY;
    this.startHeight = this.props.onMeasure().height;
    this.preventSelection();

    if (this.grip) {
      this.grip.focus();

      if (typeof this.grip.setPointerCapture === 'function') {
        try {
          this.grip.setPointerCapture(event.pointerId);
        } catch (ignoredError) {
          void ignoredError;
        }
      }
    }

    document.addEventListener('pointermove', this.handlePointerMove);
    document.addEventListener('pointerup', this.handlePointerUp);
    document.addEventListener('pointercancel', this.handlePointerCancel);
  };

  heightFromPointer = (event) => {
    const { min, max } = this.bounds();

    return clampComposerTextHeight(this.startHeight + (event.clientY - this.startY), min, max);
  };

  handlePointerMove = (event) => {
    if (!this.dragging) {
      return;
    }

    if (event.cancelable) {
      event.preventDefault();
    }

    this.props.onChange(this.heightFromPointer(event));
  };

  finishPointer = (event, cancel) => {
    if (!this.dragging) {
      return;
    }

    this.dragging = false;
    this.detachPointerListeners();
    this.restoreSelection();

    if (this.grip && typeof this.grip.releasePointerCapture === 'function' && event) {
      try {
        this.grip.releasePointerCapture(event.pointerId);
      } catch (ignoredError) {
        void ignoredError;
      }
    }

    this.props.onChange(cancel ? this.startHeight : this.heightFromPointer(event));
  };

  handlePointerUp = (event) => {
    this.finishPointer(event, false);
  };

  handlePointerCancel = (event) => {
    this.finishPointer(event, true);
  };

  handleKeyDown = (event) => {
    const measured = this.props.onMeasure();
    const { min, max } = this.bounds();
    const current = measured.height;
    let next;

    switch (event.key) {
    case 'ArrowUp':
      next = current - KEYBOARD_STEP;
      break;
    case 'ArrowDown':
      next = current + KEYBOARD_STEP;
      break;
    case 'Home':
      next = min;
      break;
    case 'End':
      next = max;
      break;
    default:
      return;
    }

    event.preventDefault();
    this.props.onChange(clampComposerTextHeight(next, min, max));
  };

  render () {
    const measured = this.props.onMeasure();
    const { min, max } = measured.height ? this.bounds() : { min: 0, max: 0 };
    const value = measured.height ? clampComposerTextHeight(measured.height, min, max) : undefined;

    return (
      <div
        className='portable-composer__grip'
        role='separator'
        tabIndex={0}
        aria-orientation='horizontal'
        aria-label={this.label()}
        aria-valuemin={value === undefined ? undefined : min}
        aria-valuemax={value === undefined ? undefined : max}
        aria-valuenow={value}
        onPointerDown={this.handlePointerDown}
        onKeyDown={this.handleKeyDown}
        ref={this.setGrip}
      >
        <span className='portable-composer__grip-line' />
      </div>
    );
  }

}

export default injectIntl(ComposerHeightGrip);

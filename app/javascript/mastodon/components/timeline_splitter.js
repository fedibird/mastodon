import React from 'react';
import PropTypes from 'prop-types';
import Icon from './icon';

export const DEFAULT_TIMELINE_SPLIT_RATIO = 35;
export const MIN_TIMELINE_SPLIT_RATIO = 20;
export const MAX_TIMELINE_SPLIT_RATIO = 80;

const KEYBOARD_STEP = 5;
const KEYBOARD_STEP_LARGE = 10;

export default class TimelineSplitter extends React.PureComponent {

  static propTypes = {
    value: PropTypes.number.isRequired,
    min: PropTypes.number,
    max: PropTypes.number,
    onChange: PropTypes.func.isRequired,
    onCommit: PropTypes.func.isRequired,
    onCloseHistory: PropTypes.func.isRequired,
    label: PropTypes.string.isRequired,
    closeHistoryLabel: PropTypes.string.isRequired,
  };

  static defaultProps = {
    min: MIN_TIMELINE_SPLIT_RATIO,
    max: MAX_TIMELINE_SPLIT_RATIO,
  };

  componentWillUnmount () {
    this.detachPointerListeners();
  }

  setSeparatorRef = c => {
    this.separator = c;
  }

  clamp (value) {
    const { min, max } = this.props;

    return Math.min(max, Math.max(min, value));
  }

  ratioFromPointer (event) {
    const container = this.separator && this.separator.closest('.timeline-split');

    if (!container) {
      return this.props.value;
    }

    const rect = container.getBoundingClientRect();

    if (!rect.height || !Number.isFinite(event.clientY)) {
      return this.props.value;
    }

    return this.clamp(Math.round(((event.clientY - rect.top) / rect.height) * 100));
  }

  detachPointerListeners = () => {
    document.removeEventListener('pointermove', this.handlePointerMove);
    document.removeEventListener('pointerup', this.handlePointerUp);
    document.removeEventListener('pointercancel', this.handlePointerUp);
  }

  handlePointerDown = (event) => {
    if (event.button !== undefined && event.button !== 0) {
      return;
    }

    if (event.target.closest('button')) {
      return;
    }

    event.preventDefault();
    this.dragging = true;

    if (this.separator) {
      this.separator.focus();

      if (typeof this.separator.setPointerCapture === 'function') {
        try {
          this.separator.setPointerCapture(event.pointerId);
        } catch (ignoredError) {
          // Document-level listeners still follow the pointer when capture is unavailable.
          void ignoredError;
        }
      }
    }

    document.addEventListener('pointermove', this.handlePointerMove);
    document.addEventListener('pointerup', this.handlePointerUp);
    document.addEventListener('pointercancel', this.handlePointerUp);
    this.props.onChange(this.ratioFromPointer(event));
  }

  handlePointerMove = (event) => {
    if (!this.dragging) {
      return;
    }

    event.preventDefault();
    this.props.onChange(this.ratioFromPointer(event));
  }

  handlePointerUp = (event) => {
    if (!this.dragging) {
      return;
    }

    this.dragging = false;
    this.detachPointerListeners();

    const value = this.ratioFromPointer(event);
    this.props.onChange(value);
    this.props.onCommit(value);
  }

  handleKeyDown = (event) => {
    const { min, max, value } = this.props;
    const step = event.shiftKey ? KEYBOARD_STEP_LARGE : KEYBOARD_STEP;
    let next;

    switch (event.key) {
    case 'ArrowUp':
      next = value - step;
      break;
    case 'ArrowDown':
      next = value + step;
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
    next = this.clamp(next);
    this.props.onChange(next);
    this.props.onCommit(next);
  }

  handleDoubleClick = (event) => {
    if (event.target.closest('button')) {
      return;
    }

    event.preventDefault();
    this.props.onChange(DEFAULT_TIMELINE_SPLIT_RATIO);
    this.props.onCommit(DEFAULT_TIMELINE_SPLIT_RATIO);
  }

  handleClosePointerDown = (event) => {
    event.stopPropagation();
  }

  handleCloseClick = (event) => {
    event.preventDefault();
    event.stopPropagation();
    this.props.onCloseHistory();
  }

  render () {
    const { value, min, max, label, closeHistoryLabel } = this.props;

    return (
      <div
        className='timeline-split__separator'
        role='separator'
        tabIndex={0}
        aria-orientation='horizontal'
        aria-valuemin={min}
        aria-valuemax={max}
        aria-valuenow={value}
        aria-label={label}
        onPointerDown={this.handlePointerDown}
        onKeyDown={this.handleKeyDown}
        onDoubleClick={this.handleDoubleClick}
        ref={this.setSeparatorRef}
      >
        <span className='timeline-split__separator-line' />
        <button
          type='button'
          className='timeline-split__close'
          aria-label={closeHistoryLabel}
          title={closeHistoryLabel}
          onPointerDown={this.handleClosePointerDown}
          onClick={this.handleCloseClick}
        >
          <Icon id='times' />
        </button>
      </div>
    );
  }

}

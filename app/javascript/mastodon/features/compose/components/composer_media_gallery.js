import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { defineMessages, injectIntl } from 'react-intl';
import classNames from 'classnames';
import Icon from 'mastodon/components/icon';
import { moveMediaIds, summaryThumbCount, visibleMediaWindow } from '../composer_media';

const messages = defineMessages({
  undo: { id: 'upload_form.undo', defaultMessage: 'Delete' },
  attachment: { id: 'upload_form.attachment', defaultMessage: 'Attachment {index}' },
  more: { id: 'upload_form.show_more', defaultMessage: 'Show {count} more attachments' },
  close: { id: 'upload_form.hide_attachments', defaultMessage: 'Hide the full attachment list' },
  reorder: { id: 'upload_form.reorder', defaultMessage: 'Drag to reorder, or press the arrow keys.' },
  videoOnly: { id: 'upload_form.video_only', defaultMessage: 'Only one video or audio file can be attached.' },
});

const DRAG_THRESHOLD = 8;

const typeIcon = (type) => {
  if (type === 'video' || type === 'gifv') {
    return 'video-camera';
  }

  if (type === 'audio') {
    return 'music';
  }

  return 'file-o';
};

const previewStyle = (media) => {
  const url = media.get('preview_url');

  if (!url) {
    return null;
  }

  const focusX = media.getIn(['meta', 'focus', 'x']);
  const focusY = media.getIn(['meta', 'focus', 'y']);
  const x = ((Number(focusX) || 0) / 2 + 0.5) * 100;
  const y = ((Number(focusY) || 0) / -2 + 0.5) * 100;

  return {
    backgroundImage: `url("${String(url).replace(/["\\()]/g, '')}")`,
    backgroundPosition: `${x}% ${y}%`,
  };
};

class ComposerMediaGallery extends React.PureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    media: ImmutablePropTypes.list.isRequired,
    summary: PropTypes.bool,
    onEdit: PropTypes.func.isRequired,
    onRemove: PropTypes.func.isRequired,
    onMoveTo: PropTypes.func.isRequired,
    onMoveBy: PropTypes.func.isRequired,
  };

  state = {
    dragId: null,
    overIndex: null,
    expanded: false,
    previewLimit: null,
  };

  rootNode = null;

  pointer = null;

  suppressClick = false;

  suppressTimer = null;

  resizeObserver = null;

  setRootNode = (node) => {
    this.rootNode = node;
  };

  componentDidMount () {
    this.measureSummary();

    if (typeof ResizeObserver === 'function' && this.rootNode && this.rootNode.parentElement) {
      this.resizeObserver = new ResizeObserver(this.measureSummary);
      this.resizeObserver.observe(this.rootNode.parentElement);
    }
  }

  componentDidUpdate () {
    this.measureSummary();
  }

  componentWillUnmount () {
    this.releasePointer();
    this.unbindPointerListeners();
    this.clearSuppressTimer();
    this.pointer = null;
    this.suppressClick = false;

    if (this.resizeObserver) {
      this.resizeObserver.disconnect();
      this.resizeObserver = null;
    }
  }

  measureSummary = () => {
    if (!this.props.summary || this.state.expanded || !this.rootNode || !this.rootNode.parentElement) {
      return;
    }

    const width = this.rootNode.clientWidth || this.rootNode.parentElement.clientWidth;

    if (!width) {
      return;
    }

    const previewLimit = summaryThumbCount({
      width,
      itemCount: this.props.media.size,
      reserved: 0,
    });

    if (previewLimit !== this.state.previewLimit) {
      this.setState({ previewLimit });
    }
  };

  clearSuppressTimer () {
    if (this.suppressTimer) {
      clearTimeout(this.suppressTimer);
      this.suppressTimer = null;
    }
  }

  armClickSuppression () {
    this.suppressClick = true;
    this.clearSuppressTimer();
    this.suppressTimer = setTimeout(() => {
      this.suppressClick = false;
      this.suppressTimer = null;
    }, 0);
  }

  bindPointerListeners () {
    document.addEventListener('pointermove', this.handlePointerMove);
    document.addEventListener('pointerup', this.handlePointerUp);
    document.addEventListener('pointercancel', this.handlePointerCancel);
  }

  unbindPointerListeners () {
    document.removeEventListener('pointermove', this.handlePointerMove);
    document.removeEventListener('pointerup', this.handlePointerUp);
    document.removeEventListener('pointercancel', this.handlePointerCancel);
  }

  capturePointer () {
    const gesture = this.pointer;

    if (!gesture || gesture.captured || !gesture.target || typeof gesture.target.setPointerCapture !== 'function') {
      return;
    }

    if (gesture.pointerId === undefined || gesture.pointerId === null) {
      return;
    }

    try {
      gesture.target.setPointerCapture(gesture.pointerId);
      gesture.captured = true;
    } catch (error) {
      gesture.captured = false;
    }
  }

  releasePointer () {
    const gesture = this.pointer;

    if (!gesture || !gesture.captured || !gesture.target || typeof gesture.target.releasePointerCapture !== 'function') {
      return;
    }

    try {
      if (typeof gesture.target.hasPointerCapture !== 'function' || gesture.target.hasPointerCapture(gesture.pointerId)) {
        gesture.target.releasePointerCapture(gesture.pointerId);
      }
    } catch (error) {
      // The browser may already have released the pointer.
    }
  }

  indexAt (x, y) {
    if (!this.rootNode) {
      return null;
    }

    const nodes = this.rootNode.querySelectorAll('.compose-form__media-item');
    let found = null;

    nodes.forEach(node => {
      if (typeof node.getBoundingClientRect !== 'function') {
        return;
      }

      const rect = node.getBoundingClientRect();

      if (x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom) {
        found = Number(node.getAttribute('data-media-index'));
      }
    });

    return Number.isInteger(found) ? found : null;
  }

  handlePointerDown = (event) => {
    if (typeof event.button === 'number' && event.button !== 0) {
      return;
    }

    const id = event.currentTarget.getAttribute('data-media-id');

    if (event.target.closest && event.target.closest('.compose-form__media-remove')) {
      return;
    }

    this.pointer = {
      id,
      pointerId: event.pointerId,
      pointerType: event.pointerType || 'mouse',
      x: event.clientX,
      y: event.clientY,
      moved: false,
      captured: false,
      target: event.currentTarget,
    };
    this.bindPointerListeners();
  };

  samePointer = (event) => {
    if (!this.pointer) {
      return false;
    }

    if (this.pointer.pointerId === undefined || this.pointer.pointerId === null || event.pointerId === undefined || event.pointerId === null) {
      return true;
    }

    return event.pointerId === this.pointer.pointerId;
  };

  handlePointerMove = (event) => {
    if (!this.samePointer(event)) {
      return;
    }

    const pointX = event.clientX || (event.nativeEvent && event.nativeEvent.clientX) || 0;
    const pointY = event.clientY || (event.nativeEvent && event.nativeEvent.clientY) || 0;
    const distance = Math.hypot(pointX - this.pointer.x, pointY - this.pointer.y);

    if (!this.pointer.moved && distance < DRAG_THRESHOLD) {
      return;
    }

    if (!this.pointer.moved) {
      this.pointer.moved = true;
      this.capturePointer();
    }

    if (event.cancelable) {
      event.preventDefault();
    }

    const overIndex = this.indexAt(pointX, pointY);

    this.pointer.overIndex = overIndex;

    this.setState({
      dragId: this.pointer.id,
      overIndex,
    });
  };

  finishPointer = (commit) => {
    if (!this.pointer) {
      this.unbindPointerListeners();
      return;
    }

    const { id, moved, overIndex: pointerOver } = this.pointer;
    const overIndex = pointerOver !== undefined && pointerOver !== null ? pointerOver : this.state.overIndex;

    this.releasePointer();
    this.unbindPointerListeners();
    this.pointer = null;

    if (commit && moved) {
      this.armClickSuppression();
    } else {
      this.suppressClick = false;
      this.clearSuppressTimer();
    }

    if (commit && moved && overIndex !== null && overIndex !== undefined) {
      this.props.onMoveTo(id, overIndex);
    }

    this.setState({ dragId: null, overIndex: null });
  };

  handlePointerUp = (event) => {
    if (event && !this.samePointer(event)) {
      return;
    }

    this.finishPointer(true);
  };

  handlePointerCancel = (event) => {
    if (event && !this.samePointer(event)) {
      return;
    }

    this.finishPointer(false);
  };

  handleThumbClick = (event) => {
    const id = event.currentTarget.getAttribute('data-media-id');

    if (this.suppressClick) {
      this.suppressClick = false;
      this.clearSuppressTimer();
      event.preventDefault();
      event.stopPropagation();
      return;
    }

    this.props.onEdit(id);
  };

  handleKeyDown = (event) => {
    const id = event.currentTarget.getAttribute('data-media-id');
    const index = Number(event.currentTarget.getAttribute('data-media-index'));
    const size = Number(event.currentTarget.getAttribute('data-media-size'));
    if (event.key === 'ArrowLeft' || event.key === 'ArrowUp') {
      event.preventDefault();

      if (index > 0) {
        this.props.onMoveBy(id, -1);
      }

      return;
    }

    if (event.key === 'ArrowRight' || event.key === 'ArrowDown') {
      event.preventDefault();

      if (index < size - 1) {
        this.props.onMoveBy(id, 1);
      }
    }
  };

  handleRemove = (event) => {
    event.stopPropagation();
    this.props.onRemove(event.currentTarget.getAttribute('data-media-id'));
  };

  handleExpand = () => {
    this.setState({ expanded: true });
  };

  handleCollapse = () => {
    this.setState({ expanded: false });
  };

  previewIds (ids) {
    const { dragId, overIndex } = this.state;

    if (!dragId || overIndex === null || overIndex === undefined) {
      return ids;
    }

    return moveMediaIds(ids, dragId, overIndex);
  }

  renderItem (media, index, size) {
    const { intl } = this.props;
    const id = media.get('id');
    const description = media.get('description') || '';
    const label = description || intl.formatMessage(messages.attachment, { index: index + 1 });
    const style = previewStyle(media);
    const dragging = this.state.dragId === id;
    const dropTarget = this.state.overIndex === index && this.state.dragId && this.state.dragId !== id;

    return (
      <div
        key={id}
        className={classNames('compose-form__media-item', {
          'is-dragging': dragging,
          'is-drop-target': dropTarget,
        })}
        data-media-id={id}
        data-media-index={index}
      >
        <button
          type='button'
          className='compose-form__media-thumb'
          aria-label={label}
          title={intl.formatMessage(messages.reorder)}
          aria-keyshortcuts='ArrowLeft ArrowRight'
          data-media-id={id}
          data-media-index={index}
          data-media-size={size}
          onPointerDown={this.handlePointerDown}
          onClick={this.handleThumbClick}
          onKeyDown={this.handleKeyDown}
        >
          {style ? (
            <span className='compose-form__media-preview' style={style} />
          ) : (
            <Icon id={typeIcon(media.get('type'))} fixedWidth aria-hidden='true' />
          )}
        </button>
        <button
          type='button'
          className='compose-form__media-remove'
          aria-label={intl.formatMessage(messages.undo)}
          data-media-id={id}
          onPointerDown={this.stopRemovePointer}
          onClick={this.handleRemove}
        >
          <Icon id='times' fixedWidth aria-hidden='true' />
        </button>
      </div>
    );
  }

  stopRemovePointer = (event) => {
    event.stopPropagation();
  };

  mediaConstraint (media) {
    const exclusive = media.some(item => ['video', 'audio', 'gifv'].includes(item.get('type')));

    if (exclusive) {
      return messages.videoOnly;
    }

    return null;
  }

  render () {
    const { intl, media, summary } = this.props;

    if (!media || media.isEmpty()) {
      return null;
    }

    const ids = this.previewIds(media.map(item => item.get('id')).toArray());
    const windowed = visibleMediaWindow(ids, {
      summary,
      expanded: this.state.expanded,
      limit: this.props.summary && this.state.previewLimit !== null ? this.state.previewLimit : undefined,
    });
    const visible = windowed.visible.map(id => media.find(item => item.get('id') === id)).filter(Boolean);
    const constraint = this.mediaConstraint(media);

    return (
      <div className='compose-form__media-block' data-testid='composer-media' ref={this.setRootNode}>
        <div
          className={classNames('compose-form__media', {
            'compose-form__media--summary': summary && !this.state.expanded,
            'compose-form__media--full': !summary || this.state.expanded,
            'is-reordering': Boolean(this.state.dragId),
          })}
        >
          {visible.map(item => this.renderItem(item, ids.indexOf(item.get('id')), ids.length))}
          {windowed.overflow > 0 && (
            <button
              type='button'
              className='compose-form__media-more'
              aria-label={intl.formatMessage(messages.more, { count: windowed.overflow })}
              onClick={this.handleExpand}
            >
              {`+${windowed.overflow}`}
            </button>
          )}
          {summary && this.state.expanded && (
            <button
              type='button'
              className='compose-form__media-collapse'
              onClick={this.handleCollapse}
            >
              {intl.formatMessage(messages.close)}
            </button>
          )}
        </div>
        {constraint && (
          <p className='compose-form__media-constraint' role='status'>{intl.formatMessage(constraint)}</p>
        )}
      </div>
    );
  }

}

export default injectIntl(ComposerMediaGallery);

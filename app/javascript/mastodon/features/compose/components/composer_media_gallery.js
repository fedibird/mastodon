import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { defineMessages, injectIntl } from 'react-intl';
import classNames from 'classnames';
import Icon from 'mastodon/components/icon';
import { visibleMediaWindow } from '../composer_media';

const messages = defineMessages({
  edit: { id: 'upload_form.edit', defaultMessage: 'Edit' },
  undo: { id: 'upload_form.undo', defaultMessage: 'Delete' },
  earlier: { id: 'upload_form.move_backward', defaultMessage: 'Move earlier' },
  later: { id: 'upload_form.move_forward', defaultMessage: 'Move later' },
  attachment: { id: 'upload_form.attachment', defaultMessage: 'Attachment {index}' },
  more: { id: 'upload_form.show_more', defaultMessage: 'Show {count} more attachments' },
  close: { id: 'upload_form.hide_attachments', defaultMessage: 'Hide the full attachment list' },
  reorder: { id: 'upload_form.reorder', defaultMessage: 'Drag to reorder, or press the arrow keys.' },
  menu: { id: 'upload_form.media_menu', defaultMessage: 'Attachment options' },
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
    menuId: null,
    dragId: null,
    overIndex: null,
    expanded: false,
  };

  rootNode = null;

  pointer = null;

  suppressClick = false;

  setRootNode = (node) => {
    this.rootNode = node;
  };

  componentWillUnmount () {
    this.pointer = null;
  }

  indexAt (x, y) {
    if (!this.rootNode) {
      return null;
    }

    const nodes = this.rootNode.querySelectorAll('[data-media-index]');
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

    if (event.target.closest && event.target.closest('.compose-form__media-menu')) {
      return;
    }

    this.pointer = {
      id,
      x: event.clientX,
      y: event.clientY,
      moved: false,
    };

    if (event.currentTarget.setPointerCapture && event.pointerId !== undefined && event.pointerId !== null) {
      try {
        event.currentTarget.setPointerCapture(event.pointerId);
      } catch (error) {
        // Pointer capture is optional.
      }
    }
  };

  handlePointerMove = (event) => {
    if (!this.pointer) {
      return;
    }

    const distance = Math.hypot(event.clientX - this.pointer.x, event.clientY - this.pointer.y);

    if (!this.pointer.moved && distance < DRAG_THRESHOLD) {
      return;
    }

    this.pointer.moved = true;
    event.preventDefault();

    const pointX = event.clientX || (event.nativeEvent && event.nativeEvent.clientX) || 0;
    const pointY = event.clientY || (event.nativeEvent && event.nativeEvent.clientY) || 0;
    const overIndex = this.indexAt(pointX, pointY);

    this.pointer.overIndex = overIndex;

    this.setState({
      dragId: this.pointer.id,
      overIndex,
      menuId: null,
    });
  };

  finishPointer = (commit) => {
    if (!this.pointer) {
      return;
    }

    const { id, moved, overIndex: pointerOver } = this.pointer;
    const overIndex = pointerOver !== undefined && pointerOver !== null ? pointerOver : this.state.overIndex;

    this.pointer = null;

    if (moved) {
      this.suppressClick = true;
    }

    if (commit && moved && overIndex !== null && overIndex !== undefined) {
      this.props.onMoveTo(id, overIndex);
    }

    this.setState({ dragId: null, overIndex: null });
  };

  handlePointerUp = () => {
    this.finishPointer(true);
  };

  handlePointerCancel = () => {
    this.finishPointer(false);
  };

  handleThumbClick = (event) => {
    const id = event.currentTarget.getAttribute('data-media-id');

    if (this.suppressClick) {
      this.suppressClick = false;
      event.preventDefault();
      event.stopPropagation();
      return;
    }

    this.setState(state => ({ menuId: state.menuId === id ? null : id }));
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

  closeMenu = () => {
    this.setState({ menuId: null });
  };

  handleEdit = (event) => {
    const id = event.currentTarget.getAttribute('data-media-id');

    event.stopPropagation();
    this.closeMenu();
    this.props.onEdit(id);
  };

  handleRemove = (event) => {
    const id = event.currentTarget.getAttribute('data-media-id');

    event.stopPropagation();
    this.closeMenu();
    this.props.onRemove(id);
  };

  handleMoveEarlier = (event) => {
    event.stopPropagation();
    this.props.onMoveBy(event.currentTarget.getAttribute('data-media-id'), -1);
  };

  handleMoveLater = (event) => {
    event.stopPropagation();
    this.props.onMoveBy(event.currentTarget.getAttribute('data-media-id'), 1);
  };

  handleExpand = () => {
    this.setState({ expanded: true, menuId: null });
  };

  handleCollapse = () => {
    this.setState({ expanded: false, menuId: null });
  };

  renderItem (media, index, size) {
    const { intl } = this.props;
    const id = media.get('id');
    const description = media.get('description') || '';
    const label = description || intl.formatMessage(messages.attachment, { index: index + 1 });
    const style = previewStyle(media);
    const menuOpen = this.state.menuId === id;
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
        onPointerDown={this.handlePointerDown}
        onPointerMove={this.handlePointerMove}
        onPointerUp={this.handlePointerUp}
        onPointerCancel={this.handlePointerCancel}
      >
        <button
          type='button'
          className='compose-form__media-thumb'
          aria-label={label}
          aria-haspopup='menu'
          aria-expanded={menuOpen}
          aria-keyshortcuts='ArrowLeft ArrowRight'
          title={intl.formatMessage(messages.reorder)}
          data-media-id={id}
          data-media-index={index}
          data-media-size={size}
          onClick={this.handleThumbClick}
          onKeyDown={this.handleKeyDown}
        >
          {style ? (
            <span className='compose-form__media-preview' style={style} />
          ) : (
            <Icon id={typeIcon(media.get('type'))} fixedWidth aria-hidden='true' />
          )}
        </button>
        {menuOpen && (
          <div className='compose-form__media-menu' role='menu' aria-label={intl.formatMessage(messages.menu)}>
            <button type='button' role='menuitem' data-media-id={id} onClick={this.handleEdit}>
              <Icon id='pencil' fixedWidth aria-hidden='true' />
              {intl.formatMessage(messages.edit)}
            </button>
            <button type='button' role='menuitem' data-media-id={id} onClick={this.handleRemove}>
              <Icon id='times' fixedWidth aria-hidden='true' />
              {intl.formatMessage(messages.undo)}
            </button>
            <button type='button' role='menuitem' data-media-id={id} disabled={index === 0} onClick={this.handleMoveEarlier}>
              <Icon id='arrow-left' fixedWidth aria-hidden='true' />
              {intl.formatMessage(messages.earlier)}
            </button>
            <button type='button' role='menuitem' data-media-id={id} disabled={index >= size - 1} onClick={this.handleMoveLater}>
              <Icon id='arrow-right' fixedWidth aria-hidden='true' />
              {intl.formatMessage(messages.later)}
            </button>
          </div>
        )}
      </div>
    );
  }

  render () {
    const { intl, media, summary } = this.props;

    if (!media || media.isEmpty()) {
      return null;
    }

    const ids = media.map(item => item.get('id')).toArray();
    const windowed = visibleMediaWindow(ids, { summary, expanded: this.state.expanded });
    const visible = windowed.visible.map(id => media.find(item => item.get('id') === id)).filter(Boolean);

    return (
      <div
        className={classNames('compose-form__media', {
          'compose-form__media--summary': summary && !this.state.expanded,
          'compose-form__media--full': !summary || this.state.expanded,
        })}
        data-testid='composer-media'
        ref={this.setRootNode}
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
    );
  }

}

export default injectIntl(ComposerMediaGallery);

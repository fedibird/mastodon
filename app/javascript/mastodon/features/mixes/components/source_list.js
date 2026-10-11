import React from 'react';
import PropTypes from 'prop-types';
import classNames from 'classnames';
import Icon from 'mastodon/components/icon';
import { normalizeSource, sourceKey } from 'mastodon/mix/source';
import { describeMixSource } from 'mastodon/mix/source_badges';
import messages from '../messages';

const conditionText = (intl, params) => {
  const parts = [];

  if (params.any && params.any.length) {
    parts.push(`${intl.formatMessage(messages.any)} ${params.any.join(', ')}`);
  }

  if (params.all && params.all.length) {
    parts.push(`${intl.formatMessage(messages.all)} ${params.all.join(', ')}`);
  }

  if (params.none && params.none.length) {
    parts.push(`${intl.formatMessage(messages.none)} ${params.none.join(', ')}`);
  }

  if (params.tagged) {
    parts.push(`${intl.formatMessage(messages.tagged)} #${params.tagged}`);
  }

  if (params.onlyMedia) {
    parts.push(intl.formatMessage(messages.onlyMedia));
  }

  if (params.withoutMedia) {
    parts.push(intl.formatMessage(messages.withoutMedia));
  }

  if (params.withoutBot) {
    parts.push(intl.formatMessage(messages.withoutBot));
  }

  if (params.withReplies) {
    parts.push(intl.formatMessage(messages.withReplies));
  }

  if (params.withoutReblogs) {
    parts.push(intl.formatMessage(messages.withoutReblogs));
  }

  if (params.shows) {
    Object.keys(params.shows).sort().forEach(key => {
      if (params.shows[key] === false) {
        const message = {
          reblog: messages.hideReblog,
          reply: messages.hideReply,
          private: messages.hidePrivate,
          limited: messages.hideLimited,
          direct: messages.hideDirect,
          personal: messages.hidePersonal,
        }[key];

        if (message) {
          parts.push(intl.formatMessage(message));
        }
      }
    });
  }

  return parts.join(', ');
};

class SourceRow extends React.PureComponent {

  static propTypes = {
    index: PropTypes.number.isRequired,
    source: PropTypes.object.isRequired,
    intl: PropTypes.object.isRequired,
    editable: PropTypes.bool,
    dragging: PropTypes.bool,
    over: PropTypes.bool,
    onRemove: PropTypes.func,
    onReorder: PropTypes.func,
    onDragStart: PropTypes.func,
    onDragOver: PropTypes.func,
    onDrop: PropTypes.func,
    onDragEnd: PropTypes.func,
  };

  handleRemove = () => {
    this.props.onRemove(this.props.index);
  };

  handleKeyDown = (event) => {
    if (event.key !== 'ArrowUp' && event.key !== 'ArrowDown') {
      return;
    }

    event.preventDefault();
    const next = event.key === 'ArrowUp' ? this.props.index - 1 : this.props.index + 1;

    this.props.onReorder(this.props.index, next);
  };

  handleDragStart = (event) => {
    event.stopPropagation();
    this.props.onDragStart(event, this.props.index);
  };

  handleDragOver = (event) => {
    this.props.onDragOver(event, this.props.index);
  };

  handleDrop = (event) => {
    this.props.onDrop(event, this.props.index);
  };

  render () {
    const { source, intl, editable, dragging, over, index } = this.props;
    const normalized = normalizeSource(source);
    const value = normalized.ok ? normalized.source : source;
    const row = describeMixSource(value, {
      formatMessage: (message, values) => intl.formatMessage(message, values),
    });
    const label = row ? row.label : (value.type || '');
    const detail = normalized.ok ? conditionText(intl, value.params || {}) : '';

    return (
      <li
        className={classNames('mix-editor__source', { 'is-dragging': dragging, 'is-over': over })}
        draggable={editable ? 'true' : undefined}
        onDragStart={editable ? this.handleDragStart : undefined}
        onDragOver={editable ? this.handleDragOver : undefined}
        onDrop={editable ? this.handleDrop : undefined}
        onDragEnd={editable ? this.props.onDragEnd : undefined}
      >
        {editable && (
          <button
            type='button'
            className='icon-button mix-editor__handle'
            draggable='true'
            data-handle-index={index}
            aria-label={intl.formatMessage(messages.reorderSource)}
            onKeyDown={this.handleKeyDown}
            onDragStart={this.handleDragStart}
          >
            <Icon id='bars' fixedWidth aria-hidden='true' />
          </button>
        )}
        <div className='mix-editor__source-main'>
          <span className='mix-editor__source-heading'>
            {row && <Icon id={row.icon} className='mix-editor__source-icon' fixedWidth aria-hidden='true' />}
            <span className='mix-editor__source-label'>{label}</span>
            {row && row.showChip && <span className='mix-editor__source-chip'>{row.typeLabel}</span>}
          </span>
          {detail ? <span className='mix-editor__source-detail'>{detail}</span> : null}
        </div>
        {editable && (
          <button type='button' className='icon-button mix-editor__remove' aria-label={intl.formatMessage(messages.removeSource)} onClick={this.handleRemove}>
            <Icon id='times' aria-hidden='true' />
          </button>
        )}
      </li>
    );
  }

}

export default class SourceList extends React.PureComponent {

  static propTypes = {
    sources: PropTypes.array.isRequired,
    intl: PropTypes.object.isRequired,
    editable: PropTypes.bool,
    onRemove: PropTypes.func,
    onReorder: PropTypes.func,
  };

  state = {
    dragging: null,
    over: null,
  };

  dragFrom = null;

  focusIndex = null;

  setListRef = (node) => {
    this.listNode = node;
  };

  componentDidUpdate () {
    if (this.focusIndex === null || !this.listNode) {
      return;
    }

    const node = this.listNode.querySelector(`[data-handle-index="${this.focusIndex}"]`);

    this.focusIndex = null;

    if (node) {
      node.focus();
    }
  }

  handleDragStart = (event, index) => {
    if (event.dataTransfer) {
      event.dataTransfer.effectAllowed = 'move';

      try {
        event.dataTransfer.setData('text/plain', String(index));
      } catch (error) {
        // Some browsers throw when the drag payload is set during tests.
      }
    }

    this.dragFrom = index;
    this.setState({ dragging: index, over: index });
  };

  handleDragOver = (event, index) => {
    event.preventDefault();

    if (event.dataTransfer) {
      event.dataTransfer.dropEffect = 'move';
    }

    if (this.state.over !== index) {
      this.setState({ over: index });
    }
  };

  handleDrop = (event, index) => {
    event.preventDefault();
    const from = this.dragFrom;

    this.dragFrom = null;
    this.setState({ dragging: null, over: null });

    if (from !== null && from !== index && this.props.onReorder) {
      this.props.onReorder(from, index);
    }
  };

  handleDragEnd = () => {
    this.dragFrom = null;
    this.setState({ dragging: null, over: null });
  };

  handleReorder = (from, to) => {
    if (!this.props.onReorder || to < 0 || to >= this.props.sources.length || from === to) {
      return;
    }

    this.focusIndex = to;
    this.props.onReorder(from, to);
  };

  render () {
    const { sources, intl, editable, onRemove } = this.props;

    if (!sources.length) {
      return null;
    }

    return (
      <ol className='mix-editor__sources' ref={this.setListRef}>
        {sources.map((source, index) => (
          <SourceRow
            key={sourceKey(source) || `invalid:${index}`}
            index={index}
            source={source}
            intl={intl}
            editable={editable}
            dragging={this.state.dragging === index}
            over={this.state.over === index && this.state.dragging !== index}
            onRemove={onRemove}
            onReorder={this.handleReorder}
            onDragStart={this.handleDragStart}
            onDragOver={this.handleDragOver}
            onDrop={this.handleDrop}
            onDragEnd={this.handleDragEnd}
          />
        ))}
      </ol>
    );
  }

}

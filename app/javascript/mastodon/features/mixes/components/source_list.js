import React from 'react';
import PropTypes from 'prop-types';
import { normalizeSource, sourceIdentityLabel, sourceKey } from 'mastodon/mix/source';
import messages from '../messages';

const TYPE_MESSAGE = {
  home: messages.home,
  limited: messages.limited,
  personal: messages.personal,
  public: messages.public,
  remote: messages.remote,
  domain: messages.domainType,
  hashtag: messages.hashtagType,
  list: messages.listType,
  group: messages.group,
  account: messages.account,
};

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
    disableUp: PropTypes.bool,
    disableDown: PropTypes.bool,
    onRemove: PropTypes.func,
    onMove: PropTypes.func,
  };

  handleRemove = () => {
    this.props.onRemove(this.props.index);
  };

  handleMoveUp = () => {
    this.props.onMove(this.props.index, -1);
  };

  handleMoveDown = () => {
    this.props.onMove(this.props.index, 1);
  };

  render () {
    const { source, intl, editable, disableUp, disableDown } = this.props;
    const normalized = normalizeSource(source);
    const value = normalized.ok ? normalized.source : source;
    const type = TYPE_MESSAGE[value.type] ? intl.formatMessage(TYPE_MESSAGE[value.type]) : value.type;
    const name = normalized.ok ? sourceIdentityLabel(value) : '';
    const detail = normalized.ok ? conditionText(intl, value.params || {}) : '';

    return (
      <li className='mix-editor__source'>
        <span className='mix-editor__source-name'>
          <span className='mix-editor__source-type'>{type}</span>
          {name && name !== value.type ? <span>{name}</span> : null}
          {detail ? <span className='mix-editor__source-detail'>{detail}</span> : null}
        </span>
        {editable && (
          <span className='mix-editor__source-actions'>
            <button type='button' className='button button-secondary' onClick={this.handleMoveUp} disabled={disableUp}>{intl.formatMessage(messages.moveUp)}</button>
            <button type='button' className='button button-secondary' onClick={this.handleMoveDown} disabled={disableDown}>{intl.formatMessage(messages.moveDown)}</button>
            <button type='button' className='button button-secondary' onClick={this.handleRemove}>{intl.formatMessage(messages.removeSource)}</button>
          </span>
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
    onMove: PropTypes.func,
  };

  render () {
    const { sources, intl, editable, onRemove, onMove } = this.props;

    if (!sources.length) {
      return null;
    }

    return (
      <ol className='mix-editor__sources'>
        {sources.map((source, index) => (
          <SourceRow
            key={sourceKey(source) || `invalid:${index}`}
            index={index}
            source={source}
            intl={intl}
            editable={editable}
            disableUp={index === 0}
            disableDown={index === sources.length - 1}
            onRemove={onRemove}
            onMove={onMove}
          />
        ))}
      </ol>
    );
  }

}

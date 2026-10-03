import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { defineMessages, injectIntl } from 'react-intl';
import Icon from 'mastodon/components/icon';
import Emoji from 'mastodon/components/emoji';
import {
  emojiReactionFilterArray,
  emojiReactionFilterLabel,
  findEmojiReactionCatalogItem,
} from '../utils';

const messages = defineMessages({
  open: { id: 'emoji_reaction_filter.open', defaultMessage: 'Filter by emoji' },
  remove: { id: 'emoji_reaction_filter.remove', defaultMessage: 'Remove {emoji} from emoji filter' },
});

const read = (item, key) => (typeof item.get === 'function' ? item.get(key) : item[key]);

class EmojiFilterChip extends React.PureComponent {

  static propTypes = {
    value: PropTypes.string.isRequired,
    label: PropTypes.string.isRequired,
    item: PropTypes.object,
    removeLabel: PropTypes.string.isRequired,
    onRemove: PropTypes.func.isRequired,
  };

  handleRemove = (event) => {
    event.preventDefault();
    event.stopPropagation();
    this.props.onRemove(this.props.value);
  };

  renderGlyph() {
    const { item, label } = this.props;

    if (!item) {
      return <span className='emoji-reaction-filter-bar__fallback'>{label}</span>;
    }

    const custom = Boolean(read(item, 'custom'));
    const url = read(item, 'url');
    const staticUrl = read(item, 'static_url');
    const domain = read(item, 'domain');

    if (custom && !url && !staticUrl) {
      return <span className='emoji-reaction-filter-bar__fallback'>{label}</span>;
    }

    return (
      <Emoji
        className='emoji-reaction-filter-bar__glyph'
        emoji={String(read(item, 'name') || '')}
        url={custom ? (url || undefined) : undefined}
        static_url={custom ? (staticUrl || undefined) : undefined}
        domain={custom && domain ? domain : undefined}
        hovered={false}
      />
    );
  }

  render() {
    return (
      <span className='emoji-reaction-filter-bar__chip'>
        {this.renderGlyph()}
        <button
          type='button'
          className='emoji-reaction-filter-bar__remove'
          aria-label={this.props.removeLabel}
          onClick={this.handleRemove}
        >
          <Icon id='times' />
        </button>
      </span>
    );
  }

}

export default @injectIntl
class EmojiFilterBar extends React.PureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    emojis: PropTypes.oneOfType([ImmutablePropTypes.list, PropTypes.array]),
    catalogItems: PropTypes.oneOfType([ImmutablePropTypes.list, PropTypes.array]),
    expanded: PropTypes.bool,
    onOpen: PropTypes.func.isRequired,
    onChange: PropTypes.func.isRequired,
    onTriggerMouseDown: PropTypes.func,
  };

  static defaultProps = {
    emojis: [],
    catalogItems: [],
    expanded: false,
  };

  handleOpen = (event) => {
    this.props.onOpen(event);
  };

  handleTriggerMouseDown = (event) => {
    if (this.props.onTriggerMouseDown) {
      this.props.onTriggerMouseDown(event);
    }
  };

  handleRemove = (value) => {
    const next = emojiReactionFilterArray(this.props.emojis).filter(item => item !== value);
    this.props.onChange(next);
  };

  render() {
    const { intl, expanded } = this.props;
    const selected = emojiReactionFilterArray(this.props.emojis);
    const openLabel = intl.formatMessage(messages.open);

    if (selected.length === 0) {
      return (
        <div className='emoji-reaction-filter-bar'>
          <button
            type='button'
            className='emoji-reaction-filter-bar__trigger'
            aria-label={openLabel}
            aria-expanded={expanded}
            aria-haspopup='dialog'
            onClick={this.handleOpen}
            onMouseDown={this.handleTriggerMouseDown}
          >
            <Icon id='filter' />
            <span className='emoji-reaction-filter-bar__label'>{openLabel}</span>
          </button>
        </div>
      );
    }

    return (
      <div className='emoji-reaction-filter-bar'>
        <div className='emoji-reaction-filter-bar__chips'>
          {selected.map(value => {
            const item = findEmojiReactionCatalogItem(this.props.catalogItems, value);
            const label = item ? emojiReactionFilterLabel(item) : emojiReactionFilterLabel(value);

            return (
              <EmojiFilterChip
                key={value}
                value={value}
                label={label}
                item={item}
                removeLabel={intl.formatMessage(messages.remove, { emoji: label })}
                onRemove={this.handleRemove}
              />
            );
          })}
          <button
            type='button'
            className='emoji-reaction-filter-bar__add'
            aria-label={openLabel}
            aria-expanded={expanded}
            aria-haspopup='dialog'
            onClick={this.handleOpen}
            onMouseDown={this.handleTriggerMouseDown}
          >
            <Icon id='plus' />
          </button>
        </div>
      </div>
    );
  }

}

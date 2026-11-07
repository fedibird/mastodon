import React from 'react';
import PropTypes from 'prop-types';
import { defineMessages, injectIntl } from 'react-intl';
import Icon from 'mastodon/components/icon';

const messages = defineMessages({
  toolbar: { id: 'media_display.toolbar', defaultMessage: 'Media display options' },
  shape: { id: 'media_display.shape', defaultMessage: 'Layout' },
  square: { id: 'media_display.square', defaultMessage: 'Square' },
  original: { id: 'media_display.original', defaultMessage: 'Original' },
  size: { id: 'media_display.size', defaultMessage: 'Thumbnail size' },
  small: { id: 'media_display.small', defaultMessage: 'Small' },
  medium: { id: 'media_display.medium', defaultMessage: 'Medium' },
  large: { id: 'media_display.large', defaultMessage: 'Large' },
  max: { id: 'media_display.max', defaultMessage: 'Maximum' },
  visibility: { id: 'media_display.visibility', defaultMessage: 'Media visibility (this column only)' },
  hideSensitive: { id: 'media_display.hide_sensitive', defaultMessage: 'Hide sensitive media' },
  showAll: { id: 'media_display.show_all', defaultMessage: 'Always show media' },
  hideAll: { id: 'media_display.hide_all', defaultMessage: 'Always hide media' },
});

class MediaDisplayControls extends React.PureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    shape: PropTypes.oneOf(['square', 'original']).isRequired,
    size: PropTypes.oneOf(['small', 'medium', 'large', 'max']).isRequired,
    visibility: PropTypes.oneOf(['hide_sensitive', 'show_all', 'hide_all']).isRequired,
    onShapeChange: PropTypes.func.isRequired,
    onSizeChange: PropTypes.func.isRequired,
    onVisibilityChange: PropTypes.func.isRequired,
    compact: PropTypes.bool,
  };

  handleShapeClick = event => {
    this.props.onShapeChange(event.currentTarget.value);
  }

  handleSizeClick = event => {
    this.props.onSizeChange(event.currentTarget.value);
  }

  handleVisibilityClick = event => {
    this.props.onVisibilityChange(event.currentTarget.value);
  }

  renderButton = (value, label, active, onClick, icon = null) => (
    <button
      type='button'
      key={value}
      className={`media-display-controls__button${active ? ' active' : ''}`}
      value={value}
      title={label}
      aria-label={label}
      aria-pressed={active}
      onClick={onClick}
    >
      {icon}
      {!icon && label}
    </button>
  )

  render () {
    const { intl, shape, size, visibility } = this.props;
    const label = intl.formatMessage;

    return (
      <div className={`media-display-controls${this.props.compact ? ' media-display-controls--compact' : ''}`} role='toolbar' aria-label={label(messages.toolbar)}>
        <div className='media-display-controls__group' role='group' aria-label={label(messages.shape)}>
          {this.renderButton('square', label(messages.square), shape === 'square', this.handleShapeClick)}
          {this.renderButton('original', label(messages.original), shape === 'original', this.handleShapeClick)}
        </div>
        <div className='media-display-controls__group' role='group' aria-label={label(messages.size)}>
          {this.renderButton('small', label(messages.small), size === 'small', this.handleSizeClick)}
          {this.renderButton('medium', label(messages.medium), size === 'medium', this.handleSizeClick)}
          {this.renderButton('large', label(messages.large), size === 'large', this.handleSizeClick)}
          {this.renderButton('max', label(messages.max), size === 'max', this.handleSizeClick)}
        </div>
        <div className='media-display-controls__group' role='group' aria-label={label(messages.visibility)}>
          {this.renderButton('hide_sensitive', label(messages.hideSensitive), visibility === 'hide_sensitive', this.handleVisibilityClick, <><Icon id='eye' /><Icon id='eye-slash' /></>)}
          {this.renderButton('show_all', label(messages.showAll), visibility === 'show_all', this.handleVisibilityClick, <Icon id='eye' />)}
          {this.renderButton('hide_all', label(messages.hideAll), visibility === 'hide_all', this.handleVisibilityClick, <Icon id='eye-slash' />)}
        </div>
      </div>
    );
  }

}

export default injectIntl(MediaDisplayControls);

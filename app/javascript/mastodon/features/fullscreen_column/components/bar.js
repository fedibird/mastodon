import React from 'react';
import PropTypes from 'prop-types';
import { defineMessages, injectIntl } from 'react-intl';
import Icon from 'mastodon/components/icon';
import MediaDisplayControls from 'mastodon/components/media_display_controls';

const messages = defineMessages({
  open: { id: 'fullscreen_column.open', defaultMessage: 'Open fullscreen' },
  close: { id: 'fullscreen_column.close', defaultMessage: 'Close fullscreen' },
  back: { id: 'fullscreen_column.back', defaultMessage: 'Back' },
  compose: { id: 'fullscreen_column.compose', defaultMessage: 'Post' },
  appearance: { id: 'fullscreen_column.appearance', defaultMessage: 'Display' },
  normal: { id: 'fullscreen_column.appearance.normal', defaultMessage: 'Standard' },
  card: { id: 'fullscreen_column.appearance.card', defaultMessage: 'Cards' },
  media: { id: 'fullscreen_column.appearance.media', defaultMessage: 'Media' },
  columns: { id: 'fullscreen_column.columns', defaultMessage: 'Columns' },
  columnCount: { id: 'fullscreen_column.column_count', defaultMessage: '{count} columns' },
  scale: { id: 'fullscreen_column.scale', defaultMessage: 'Size' },
  small: { id: 'fullscreen_column.scale.small', defaultMessage: 'Small' },
  medium: { id: 'fullscreen_column.scale.medium', defaultMessage: 'Medium' },
  large: { id: 'fullscreen_column.scale.large', defaultMessage: 'Large' },
  max: { id: 'fullscreen_column.scale.max', defaultMessage: 'Maximum' },
});

const APPEARANCES = [
  ['normal', messages.normal],
  ['card', messages.card],
  ['media', messages.media],
];

const SCALES = [
  ['small', messages.small],
  ['medium', messages.medium],
  ['large', messages.large],
  ['max', messages.max],
];

class FullscreenColumnBar extends React.PureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    title: PropTypes.string,
    appearance: PropTypes.string,
    columns: PropTypes.number,
    scale: PropTypes.string,
    supportsStatusLayout: PropTypes.bool,
    supportsComposer: PropTypes.bool,
    supportsMediaControls: PropTypes.bool,
    canGoBack: PropTypes.bool,
    mediaShape: PropTypes.string,
    mediaSize: PropTypes.string,
    mediaVisibility: PropTypes.string,
    onAppearance: PropTypes.func,
    onColumns: PropTypes.func,
    onScale: PropTypes.func,
    onMediaShape: PropTypes.func,
    onMediaSize: PropTypes.func,
    onMediaVisibility: PropTypes.func,
    onCompose: PropTypes.func,
    onBack: PropTypes.func,
    onClose: PropTypes.func.isRequired,
  };

  handleChoice = (event) => {
    const name = event.currentTarget.getAttribute('data-choice');
    const value = event.currentTarget.getAttribute('data-value');

    if (name === 'appearance') {
      this.props.onAppearance(value);
    } else if (name === 'columns') {
      this.props.onColumns(Number(value));
    } else if (name === 'scale') {
      this.props.onScale(value);
    }
  }

  renderChoice (name, value, label, active) {
    return (
      <button
        type='button'
        key={value}
        className={`fullscreen-column__choice${active ? ' active' : ''}`}
        aria-pressed={active}
        data-choice={name}
        data-value={value}
        onClick={this.handleChoice}
      >
        {label}
      </button>
    );
  }

  render () {
    const {
      intl,
      title,
      appearance,
      columns,
      scale,
      supportsStatusLayout,
      supportsComposer,
      supportsMediaControls,
      canGoBack,
      onClose,
    } = this.props;
    const label = intl.formatMessage;
    const statusLayout = supportsStatusLayout && appearance !== 'media';

    return (
      <div className='fullscreen-column__bar'>
        <div className='fullscreen-column__title' title={title}>{title}</div>
        <div className='fullscreen-column__controls'>
          {canGoBack && (
            <button type='button' className='fullscreen-column__text-button' onClick={this.props.onBack}>
              <Icon id='chevron-left' />
              {label(messages.back)}
            </button>
          )}
          {supportsStatusLayout && (
            <div className='fullscreen-column__group' role='group' aria-label={label(messages.appearance)}>
              {APPEARANCES.map(([value, message]) => this.renderChoice('appearance', value, label(message), appearance === value))}
            </div>
          )}
          {statusLayout && (
            <div className='fullscreen-column__group' role='group' aria-label={label(messages.columns)}>
              {[1, 2, 3].map(count => this.renderChoice('columns', count, label(messages.columnCount, { count }), Number(columns) === count))}
            </div>
          )}
          {statusLayout && (
            <div className='fullscreen-column__group' role='group' aria-label={label(messages.scale)}>
              {SCALES.map(([value, message]) => this.renderChoice('scale', value, label(message), scale === value))}
            </div>
          )}
          {supportsMediaControls && appearance === 'media' && (
            <MediaDisplayControls
              compact
              shape={this.props.mediaShape}
              size={this.props.mediaSize}
              visibility={this.props.mediaVisibility}
              onShapeChange={this.props.onMediaShape}
              onSizeChange={this.props.onMediaSize}
              onVisibilityChange={this.props.onMediaVisibility}
            />
          )}
          {supportsComposer && (
            <button type='button' className='fullscreen-column__text-button' onClick={this.props.onCompose}>
              <Icon id='pencil' />
              {label(messages.compose)}
            </button>
          )}
        </div>
        <button
          type='button'
          className='fullscreen-column__close'
          title={label(messages.close)}
          aria-label={label(messages.close)}
          onClick={onClose}
        >
          <Icon id='times' />
        </button>
      </div>
    );
  }

}

export { messages as fullscreenColumnMessages };
export default injectIntl(FullscreenColumnBar);

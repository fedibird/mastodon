import React from 'react';
import PropTypes from 'prop-types';
import { FormattedMessage } from 'react-intl';

import Icon from 'mastodon/components/icon';

// Labels stay in FormattedMessage so a locale can replace them. The visible
// control is only the icon; the name is copied onto aria-label and title.
const copyLabel = (button) => {
  const name = button.querySelector('.external-player-controls__name');
  const text = name && name.textContent;

  if (!text) {
    return;
  }

  button.title = text;
  button.setAttribute('aria-label', text);
};

export default class ExternalPlayerActions extends React.PureComponent {

  static propTypes = {
    pinned: PropTypes.bool,
    describedBy: PropTypes.string,
    onPin: PropTypes.func,
    onReturn: PropTypes.func,
    onClose: PropTypes.func.isRequired,
  };

  static nextId = 0;

  constructor (props) {
    super(props);
    ExternalPlayerActions.nextId += 1;
    this.groupLabelId = `external-player-controls-label-${ExternalPlayerActions.nextId}`;
  }

  componentDidMount () {
    this.syncLabels();
  }

  componentDidUpdate () {
    this.syncLabels();
  }

  setRoot = (element) => {
    this.root = element;
  };

  syncLabels = () => {
    if (!this.root) {
      return;
    }

    this.root.querySelectorAll('button').forEach(copyLabel);
  };

  renderButton (action, icon, label, onClick, describedBy) {
    return (
      <button
        type='button'
        className='external-player-controls__button'
        data-external-player-action={action}
        aria-describedby={describedBy || undefined}
        onClick={onClick}
      >
        <Icon id={icon} fixedWidth aria-hidden='true' />
        <span className='external-player-controls__name'>
          {label}
        </span>
      </button>
    );
  }

  render () {
    const { pinned, describedBy, onPin, onReturn, onClose } = this.props;
    const primary = pinned ? this.renderButton(
      'return',
      'chevron-left',
      <FormattedMessage id='external_media.return_to_post' defaultMessage='Return to the post' />,
      onReturn,
      describedBy,
    ) : this.renderButton(
      'pin',
      'external-link',
      <FormattedMessage id='external_media.pop_out' defaultMessage='Pop out the player' />,
      onPin,
    );

    return (
      <div className='external-player-controls' role='group' aria-labelledby={this.groupLabelId} ref={this.setRoot}>
        <span className='external-player-controls__name' id={this.groupLabelId}>
          <FormattedMessage id='external_media.player_controls' defaultMessage='Player controls' />
        </span>
        {primary}
        {this.renderButton(
          'close',
          'times',
          <FormattedMessage id='external_media.close' defaultMessage='Close the player' />,
          onClose,
        )}
      </div>
    );
  }

}

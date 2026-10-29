import React from 'react';
import PropTypes from 'prop-types';
import { FormattedMessage } from 'react-intl';

import Icon from 'mastodon/components/icon';

// The translated string is the accessible name and the tooltip in the same
// render. Reading it back from the DOM after commit goes stale when the
// locale changes without this component rendering again.
const ActionButton = ({ label, action, icon, onClick, describedBy }) => (
  <button
    type='button'
    className='external-player-controls__button'
    data-external-player-action={action}
    aria-label={label}
    title={label}
    aria-describedby={describedBy || undefined}
    onClick={onClick}
  >
    <Icon id={icon} fixedWidth aria-hidden='true' />
  </button>
);

ActionButton.propTypes = {
  label: PropTypes.string.isRequired,
  action: PropTypes.string.isRequired,
  icon: PropTypes.string.isRequired,
  onClick: PropTypes.func,
  describedBy: PropTypes.string,
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

  renderPin = (label) => (
    <ActionButton label={label} action='pin' icon='external-link' onClick={this.props.onPin} />
  );

  renderReturn = (label) => (
    <ActionButton label={label} action='return' icon='chevron-left' onClick={this.props.onReturn} describedBy={this.props.describedBy} />
  );

  renderClose = (label) => (
    <ActionButton label={label} action='close' icon='times' onClick={this.props.onClose} />
  );

  render () {
    const { pinned } = this.props;

    return (
      <div className='external-player-controls' role='group' aria-labelledby={this.groupLabelId}>
        <span className='external-player-controls__name' id={this.groupLabelId}>
          <FormattedMessage id='external_media.player_controls' defaultMessage='Player controls' />
        </span>
        {pinned ? (
          <FormattedMessage id='external_media.return_to_post' defaultMessage='Return to the post'>
            {this.renderReturn}
          </FormattedMessage>
        ) : (
          <FormattedMessage id='external_media.pop_out' defaultMessage='Pop out the player'>
            {this.renderPin}
          </FormattedMessage>
        )}
        <FormattedMessage id='external_media.close' defaultMessage='Close the player'>
          {this.renderClose}
        </FormattedMessage>
      </div>
    );
  }

}

import React from 'react';
import { defineMessages, injectIntl } from 'react-intl';
import PropTypes from 'prop-types';
import Icon from 'mastodon/components/icon';
import { isAdministrator } from 'mastodon/initial_state';

const messages = defineMessages({
  show: { id: 'timeline.show_composer', defaultMessage: 'Show composer' },
  hide: { id: 'timeline.hide_composer', defaultMessage: 'Hide composer' },
});

class PortableComposerToggle extends React.PureComponent {

  static propTypes = {
    visible: PropTypes.bool,
    onToggle: PropTypes.func.isRequired,
    intl: PropTypes.object.isRequired,
  };

  handleClick = (event) => {
    event.stopPropagation();
    this.props.onToggle();
  }

  render () {
    if (!isAdministrator) {
      return null;
    }

    const { intl, visible } = this.props;
    const label = intl.formatMessage(visible ? messages.hide : messages.show);

    return (
      <button
        type='button'
        className='column-header__button'
        title={label}
        aria-label={label}
        aria-pressed={visible ? 'true' : 'false'}
        onClick={this.handleClick}
      >
        <Icon id='pencil' fixedWidth className='column-header__icon' />
      </button>
    );
  }

}

export default injectIntl(PortableComposerToggle);

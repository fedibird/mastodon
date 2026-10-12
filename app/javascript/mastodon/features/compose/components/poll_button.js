import React from 'react';
import IconButton from '../../../components/icon_button';
import PropTypes from 'prop-types';
import { defineMessages, injectIntl } from 'react-intl';
import Icon from 'mastodon/components/icon';

const messages = defineMessages({
  add_poll: { id: 'poll_button.add_poll', defaultMessage: 'Add a poll' },
  remove_poll: { id: 'poll_button.remove_poll', defaultMessage: 'Remove poll' },
  menu: { id: 'compose_form.overflow.poll', defaultMessage: 'Poll' },
});

const iconStyle = {
  height: null,
  lineHeight: '27px',
};

export default
@injectIntl
class PollButton extends React.PureComponent {

  static propTypes = {
    disabled: PropTypes.bool,
    unavailable: PropTypes.bool,
    active: PropTypes.bool,
    presentation: PropTypes.oneOf(['menu']),
    onMenuClose: PropTypes.func,
    onClick: PropTypes.func.isRequired,
    intl: PropTypes.object.isRequired,
  };

  handleClick = () => {
    this.props.onClick();

    if (this.props.onMenuClose) {
      this.props.onMenuClose();
    }
  }

  render () {
    const { intl, active, unavailable, disabled, presentation } = this.props;

    if (unavailable) {
      return null;
    }

    if (presentation === 'menu') {
      return (
        <button type='button' className='compose-form__menu-row' disabled={disabled} onClick={this.handleClick}>
          <Icon id='tasks' fixedWidth aria-hidden='true' />
          <span>{intl.formatMessage(messages.menu)}</span>
        </button>
      );
    }

    return (
      <div className='compose-form__poll-button'>
        <IconButton
          icon='tasks'
          title={intl.formatMessage(active ? messages.remove_poll : messages.add_poll)}
          disabled={disabled}
          onClick={this.handleClick}
          className={`compose-form__poll-button-icon ${active ? 'active' : ''}`}
          size={18}
          inverted
          style={iconStyle}
        />
      </div>
    );
  }

}

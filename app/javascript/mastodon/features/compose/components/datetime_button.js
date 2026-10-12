import React from 'react';
import IconButton from '../../../components/icon_button';
import PropTypes from 'prop-types';
import { defineMessages, injectIntl } from 'react-intl';

const messages = defineMessages({
  add_datetime: { id: 'datetime_button.add_datetime', defaultMessage: 'Add datetime' },
  remove_datetime: { id: 'datetime_button.remove_datetime', defaultMessage: 'Remove datetime' },
  menu: { id: 'compose_form.overflow.schedule', defaultMessage: 'Publish and expiry time' },
});

const iconStyle = {
  height: null,
  lineHeight: '27px',
};

export default
@injectIntl
class DateTimeButton extends React.PureComponent {

  static propTypes = {
    disabled: PropTypes.bool,
    active: PropTypes.bool,
    presentation: PropTypes.oneOf(['menu']),
    onClick: PropTypes.func.isRequired,
    intl: PropTypes.object.isRequired,
  };

  handleClick = () => {
    this.props.onClick();
  }

  render () {
    const { intl, active, disabled, presentation } = this.props;

    if (presentation === 'menu') {
      return (
        <button type='button' className='compose-form__menu-row' disabled={disabled} onClick={this.handleClick}>
          <span aria-hidden='true'>📅</span>
          <span>{intl.formatMessage(messages.menu)}</span>
        </button>
      );
    }

    return (
      <div className='compose-form__datetime-button'>
        <IconButton
          icon='calendar'
          title={intl.formatMessage(active ? messages.remove_datetime : messages.add_datetime)}
          disabled={disabled}
          onClick={this.handleClick}
          className={`compose-form__datetime-button-icon ${active ? 'active' : ''}`}
          size={18}
          inverted
          style={iconStyle}
        />
      </div>
    );
  }

}

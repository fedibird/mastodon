import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePureComponent from 'react-immutable-pure-component';
import { defineMessages, injectIntl, FormattedMessage } from 'react-intl';
import IconButton from 'mastodon/components/icon_button';
import ScheduledDropDownContainer from '../containers/scheduled_dropdown_container';
import ExpiresDropDownContainer from '../containers/expires_dropdown_container';
import ExpiresActionContainer from '../containers/expires_action_container';

const messages = defineMessages({
  close: { id: 'compose_form.datetime.close', defaultMessage: 'Remove schedule' },
});

export default
@injectIntl
class DateTimeForm extends ImmutablePureComponent {

  static propTypes = {
    form_enable: PropTypes.bool.isRequired,
    onClose: PropTypes.func,
    intl: PropTypes.object.isRequired,
  };

  handleClose = () => {
    if (this.props.onClose) {
      this.props.onClose();
    }
  };

  render () {
    const { form_enable, intl } = this.props;

    if (!form_enable) {
      return null;
    }

    return (
      <div className='compose-form__datetime-wrapper'>
        <IconButton
          className='compose-form__form-dismiss'
          icon='times'
          title={intl.formatMessage(messages.close)}
          onClick={this.handleClose}
          inverted
        />
        <div className='datetime__schedule'>
          <div className='datetime__category'><FormattedMessage id='datetime.scheduled' defaultMessage='Scheduled' /></div>
          <ScheduledDropDownContainer />
        </div>
        <div className='datetime__expire'>
          <div className='datetime__category'><FormattedMessage id='datetime.expires' defaultMessage='Expires' /></div>
          <ExpiresDropDownContainer />
          <ExpiresActionContainer />
        </div>
      </div>
    );
  }

}

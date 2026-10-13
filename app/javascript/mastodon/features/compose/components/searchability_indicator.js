import React from 'react';
import PropTypes from 'prop-types';
import { defineMessages, FormattedMessage, injectIntl } from 'react-intl';
import Icon from 'mastodon/components/icon';
import IconButton from '../../../components/icon_button';

const messages = defineMessages({
  label: { id: 'compose_form.overflow.searchability', defaultMessage: 'Search visibility' },
  reset: { id: 'compose_form.searchability.reset', defaultMessage: 'Reset search visibility' },
  public: { id: 'searchability.public.short', defaultMessage: 'Public' },
  private: { id: 'searchability.private.short', defaultMessage: 'Followers-only' },
  direct: { id: 'searchability.direct.short', defaultMessage: 'Reacted-users-only' },
});

const valueMessage = {
  public: messages.public,
  private: messages.private,
  direct: messages.direct,
};

class SearchabilityIndicator extends React.PureComponent {

  static propTypes = {
    changed: PropTypes.bool,
    value: PropTypes.string,
    fallback: PropTypes.string,
    onReset: PropTypes.func.isRequired,
    intl: PropTypes.object.isRequired,
  };

  handleReset = () => {
    this.props.onReset(this.props.fallback);
  };

  render () {
    const { changed, intl, value } = this.props;

    if (!changed) {
      return null;
    }

    const selected = intl.formatMessage(valueMessage[value] || messages.private);

    return (
      <div className='compose-form__datetime-wrapper' data-testid='searchability-indicator'>
        <div className='datetime__expires-indicator'>
          <div className='datetime__expires-indicator__icon'>
            <Icon id='search' fixedWidth aria-hidden='true' />
          </div>
          <div className='datetime__expires-indicator__message'>
            <div className='expires-indicator__cancel'>
              <IconButton title={intl.formatMessage(messages.reset)} icon='times' onClick={this.handleReset} inverted />
            </div>
            <FormattedMessage {...messages.label} />
            {': '}
            {selected}
          </div>
        </div>
      </div>
    );
  }

}

export default injectIntl(SearchabilityIndicator);

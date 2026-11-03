import React from 'react';
import PropTypes from 'prop-types';
import { defineMessages, injectIntl } from 'react-intl';

const messages = defineMessages({
  placeholder: { id: 'account.media_tag_placeholder', defaultMessage: 'Filter by hashtag' },
  apply: { id: 'account.media_tag_apply', defaultMessage: 'Filter' },
});

// Shared by Posts, Posts & Replies, About and the standalone Media gallery.
// Route-based views keep the chosen tag in the URL; Media keeps it local.
class AccountHashtagFilter extends React.PureComponent {

  static contextTypes = {
    router: PropTypes.object,
  };

  static propTypes = {
    intl: PropTypes.object.isRequired,
    accountId: PropTypes.string.isRequired,
    tagged: PropTypes.string,
    routeBase: PropTypes.string,
    onSelectTag: PropTypes.func,
  };

  state = {
    value: this.props.tagged || '',
  };

  componentDidUpdate (prevProps) {
    if (prevProps.tagged !== this.props.tagged || prevProps.accountId !== this.props.accountId) {
      this.setState({ value: this.props.tagged || '' });
    }
  }

  handleChange = event => {
    this.setState({ value: event.target.value });
  }

  handleSubmit = event => {
    event.preventDefault();
    const tagged = this.state.value.replace(/^[#＃]/, '').trim().normalize('NFKC');
    const choice = tagged || null;
    if (this.props.onSelectTag) {
      this.props.onSelectTag(choice);
      return;
    }

    const route = this.props.routeBase || `/accounts/${this.props.accountId}/posts`;
    const next = choice ? `${route}/${encodeURIComponent(choice)}` : route;
    if (this.context.router && this.context.router.history) {
      this.context.router.history.push(next);
    }
  }

  render () {
    const { intl } = this.props;
    const placeholder = intl.formatMessage(messages.placeholder);

    return (
      <form className='account-gallery__tag-search' onSubmit={this.handleSubmit} role='search'>
        <input
          type='search'
          maxLength={100}
          value={this.state.value}
          onChange={this.handleChange}
          placeholder={placeholder}
          aria-label={placeholder}
        />
        <button type='submit'>{intl.formatMessage(messages.apply)}</button>
      </form>
    );
  }

}

export default injectIntl(AccountHashtagFilter);

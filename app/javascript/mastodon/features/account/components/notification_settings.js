import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { connect } from 'react-redux';
import { defineMessages, injectIntl } from 'react-intl';
import DropdownMenuContainer from 'mastodon/containers/dropdown_menu_container';
import IconButton from 'mastodon/components/icon_button';
import Icon from 'mastodon/components/icon';
import { toggleAccountNotification } from 'mastodon/actions/account_notifications';
import { me } from 'mastodon/initial_state';

const messages = defineMessages({
  settings: { id: 'account.notification_settings', defaultMessage: 'Notification settings' },
  posts: { id: 'account.notify_posts', defaultMessage: 'Notify about new posts' },
  boosts: { id: 'account.notify_boosts', defaultMessage: 'Notify about boosts' },
});

export class NotificationSettings extends React.PureComponent {

  static propTypes = {
    accountId: PropTypes.string.isRequired,
    relationship: ImmutablePropTypes.map,
    saving: PropTypes.bool,
    onToggle: PropTypes.func.isRequired,
    intl: PropTypes.object.isRequired,
  };

  handleSelect = item => {
    if (!this.props.saving) this.props.onToggle(this.props.accountId, item.key);
  };

  renderItem = (item, index, { onClick, setRef }) => (
    <li key={item.key} className='dropdown-menu__item account-notification-settings__item' role='none'>
      <button type='button' role='menuitemcheckbox' aria-checked={item.checked} aria-disabled={this.props.saving} disabled={this.props.saving} data-index={index} onClick={onClick} ref={setRef}>
        <Icon id={item.checked ? 'check-square-o' : 'square-o'} fixedWidth aria-hidden='true' /> {item.text}
      </button>
    </li>
  );

  render () {
    const { accountId, relationship, saving, intl } = this.props;
    if (accountId === me || !(relationship?.get('following') || relationship?.get('requested'))) return null;

    const posts = !!relationship.get('notifying');
    const boosts = !!relationship.get('notifying_reblogs');
    const items = [
      { key: 'notify', text: intl.formatMessage(messages.posts), checked: posts },
      { key: 'notify_reblogs', text: intl.formatMessage(messages.boosts), checked: boosts },
    ];

    return (
      <span className='account-notification-settings' aria-busy={saving}>
        <DropdownMenuContainer items={items} onItemClick={this.handleSelect} renderItem={this.renderItem} closeOnSelect={false} restoreFocus forceDropdown scrollable menuRole='menu'>
          <IconButton icon='bell-o' size={24} active={posts || boosts} title={intl.formatMessage(messages.settings)} />
        </DropdownMenuContainer>
      </span>
    );
  }

}

const mapStateToProps = (state, { accountId }) => ({
  relationship: state.getIn(['relationships', accountId]),
  saving: state.getIn(['account_notifications', accountId], false),
});

export default connect(mapStateToProps, { onToggle: toggleAccountNotification })(injectIntl(NotificationSettings));

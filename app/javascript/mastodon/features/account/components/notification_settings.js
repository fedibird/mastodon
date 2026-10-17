import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { connect } from 'react-redux';
import { defineMessages, injectIntl } from 'react-intl';
import DropdownMenuContainer from 'mastodon/containers/dropdown_menu_container';
import IconButton from 'mastodon/components/icon_button';
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

  // The menuitemcheckbox button is the only control. A real react-toggle
  // input inside it would nest interactive elements and toggle twice, so the
  // switch below only reuses the shared .react-toggle appearance.
  renderItem = (item, index, { onClick, setRef }) => (
    <li key={item.key} className='dropdown-menu__item account-notification-settings__item' role='none'>
      <button type='button' role='menuitemcheckbox' aria-checked={item.checked} aria-disabled={this.props.saving} disabled={this.props.saving} data-index={index} onClick={onClick} ref={setRef}>
        <span className='setting-toggle'>
          <span className={item.checked ? 'react-toggle react-toggle--checked' : 'react-toggle'} aria-hidden='true'>
            <span className='react-toggle-track'>
              <span className='react-toggle-track-check'>
                <svg width='14' height='11' viewBox='0 0 14 11' focusable='false'>
                  <path d='M11.264 0L5.26 6.004 2.103 2.847 0 4.95l5.26 5.26 8.108-8.107L11.264 0' fill='#fff' fillRule='evenodd' />
                </svg>
              </span>
              <span className='react-toggle-track-x'>
                <svg width='10' height='10' viewBox='0 0 10 10' focusable='false'>
                  <path d='M9.9 2.12L7.78 0 4.95 2.828 2.12 0 0 2.12l2.83 2.83L0 7.776 2.123 9.9 4.95 7.07 7.78 9.9 9.9 7.776 7.072 4.95 9.9 2.12' fill='#fff' fillRule='evenodd' />
                </svg>
              </span>
            </span>
            <span className='react-toggle-thumb' />
          </span>
          <span className='setting-toggle__label'>{item.text}</span>
        </span>
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

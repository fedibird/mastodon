import React, { Fragment } from 'react';
import ImmutablePropTypes from 'react-immutable-proptypes';
import PropTypes from 'prop-types';
import { defineMessages, injectIntl, FormattedMessage } from 'react-intl';
import Button from 'mastodon/components/button';
import ImmutablePureComponent from 'react-immutable-pure-component';
import { autoPlayHeader, autoPlayEmoji, me, isStaff, show_followed_by, follow_button_to_list_adder, disablePost, disableBlock, disableDomainBlock, disableReport, disableFollow, disableUnfollow } from 'mastodon/initial_state';
import classNames from 'classnames';
import Icon from 'mastodon/components/icon';
import IconButton from 'mastodon/components/icon_button';
import Avatar from 'mastodon/components/avatar';
import DropdownMenuContainer from 'mastodon/containers/dropdown_menu_container';

const messages = defineMessages({
  unfollow: { id: 'account.unfollow', defaultMessage: 'Unfollow' },
  follow: { id: 'account.follow', defaultMessage: 'Follow' },
  unsubscribe: { id: 'account.unsubscribe', defaultMessage: 'Unsubscribe' },
  subscribe: { id: 'account.subscribe', defaultMessage: 'Subscribe' },
  cancel_follow_request: { id: 'account.cancel_follow_request', defaultMessage: 'Cancel follow request' },
  requested: { id: 'account.requested', defaultMessage: 'Awaiting approval. Click to cancel follow request' },
  unblock: { id: 'account.unblock', defaultMessage: 'Unblock @{name}' },
  edit_profile: { id: 'account.edit_profile', defaultMessage: 'Edit profile' },
  account_locked: { id: 'account.locked_info', defaultMessage: 'This account privacy status is set to locked. The owner manually reviews who can follow them.' },
  conversations: { id: 'account.conversations', defaultMessage: 'Show conversations with @{name}' },
  conversations_all: { id: 'account.conversations_all', defaultMessage: 'Show all conversations' },
  mention: { id: 'account.mention', defaultMessage: 'Mention @{name}' },
  direct: { id: 'account.direct', defaultMessage: 'Direct message @{name}' },
  unmute: { id: 'account.unmute', defaultMessage: 'Unmute @{name}' },
  block: { id: 'account.block', defaultMessage: 'Block @{name}' },
  mute: { id: 'account.mute', defaultMessage: 'Mute @{name}' },
  report: { id: 'account.report', defaultMessage: 'Report @{name}' },
  share: { id: 'account.share', defaultMessage: 'Share @{name}\'s profile' },
  media: { id: 'account.media', defaultMessage: 'Media' },
  blockDomain: { id: 'account.block_domain', defaultMessage: 'Block domain {domain}' },
  unblockDomain: { id: 'account.unblock_domain', defaultMessage: 'Unblock domain {domain}' },
  hideReblogs: { id: 'account.hide_reblogs', defaultMessage: 'Hide boosts from @{name}' },
  showReblogs: { id: 'account.show_reblogs', defaultMessage: 'Show boosts from @{name}' },
  enableNotifications: { id: 'account.enable_notifications', defaultMessage: 'Notify me when @{name} posts' },
  disableNotifications: { id: 'account.disable_notifications', defaultMessage: 'Stop notifying me when @{name} posts' },
  pins: { id: 'navigation_bar.pins', defaultMessage: 'Pinned toots' },
  preferences: { id: 'navigation_bar.preferences', defaultMessage: 'Preferences' },
  follow_requests: { id: 'navigation_bar.follow_requests', defaultMessage: 'Follow requests' },
  favourites: { id: 'navigation_bar.favourites', defaultMessage: 'Favourites' },
  lists: { id: 'navigation_bar.lists', defaultMessage: 'Lists' },
  circles: { id: 'navigation_bar.circles', defaultMessage: 'Circles' },
  blocks: { id: 'navigation_bar.blocks', defaultMessage: 'Blocked users' },
  domain_blocks: { id: 'navigation_bar.domain_blocks', defaultMessage: 'Blocked domains' },
  mutes: { id: 'navigation_bar.mutes', defaultMessage: 'Muted users' },
  endorse: { id: 'account.endorse', defaultMessage: 'Feature on profile' },
  unendorse: { id: 'account.unendorse', defaultMessage: 'Don\'t feature on profile' },
  add_or_remove_from_list: { id: 'account.add_or_remove_from_list', defaultMessage: 'Add or Remove from lists' },
  add_or_remove_from_circle: { id: 'account.add_or_remove_from_circle', defaultMessage: 'Add or Remove from circles' },
  admin_account: { id: 'status.admin_account', defaultMessage: 'Open moderation interface for @{name}' },
});

export default @injectIntl
class HeaderCommon extends ImmutablePureComponent {

  static contextTypes = {
    router: PropTypes.object,
  };

  static propTypes = {
    account: ImmutablePropTypes.map,
    onFollow: PropTypes.func.isRequired,
    onSubscribe: PropTypes.func.isRequired,
    onAddToList: PropTypes.func.isRequired,
    onBlock: PropTypes.func.isRequired,
    onMention: PropTypes.func.isRequired,
    onDirect: PropTypes.func.isRequired,
    onConversations: PropTypes.func.isRequired,
    onReblogToggle: PropTypes.func.isRequired,
    onNotifyToggle: PropTypes.func.isRequired,
    onReport: PropTypes.func.isRequired,
    onMute: PropTypes.func.isRequired,
    onBlockDomain: PropTypes.func.isRequired,
    onUnblockDomain: PropTypes.func.isRequired,
    onEndorseToggle: PropTypes.func.isRequired,
    onAddToList: PropTypes.func.isRequired,
    onEditAccountNote: PropTypes.func.isRequired,
    intl: PropTypes.object.isRequired,
    domain: PropTypes.string.isRequired,
  };

  componentDidMount () {
    this._updateEmojiLinks();
  }

  componentDidUpdate () {
    this._updateEmojiLinks();
  }

  _updateEmojiLinks () {
    const node = this.node;

    if (!node) {
      return;
    }

    const emojis = node.querySelectorAll('.custom-emoji');

    for (var i = 0; i < emojis.length; i++) {
      let emoji = emojis[i];
      emoji.addEventListener('click', this.handleEmojiClick, false);
      emoji.style.cursor = 'pointer';
    }
  }

  handleEmojiClick = e => {
    const shortcode = e.target.dataset.shortcode;
    const domain = e.target.dataset.domain;

    if (this.context.router) {
      e.preventDefault();
      e.stopPropagation();
      this.context.router.history.push(`/emoji_detail/${shortcode}${domain ? `@${domain}` : ''}`);
    }
  }

  openEditProfile = () => {
    window.open('/settings/profile', '_blank');
  }

  isStatusesPageActive = (match, location) => {
    if (!match) {
      return false;
    }

    return !location.pathname.match(/\/(followers|following)\/?$/);
  }

  handleMouseEnter = ({ currentTarget }) => {
    if (autoPlayEmoji) {
      return;
    }

    const emojis = currentTarget.querySelectorAll('.custom-emoji');

    for (var i = 0; i < emojis.length; i++) {
      let emoji = emojis[i];
      emoji.src = emoji.getAttribute('data-original');
    }
  }

  handleMouseLeave = ({ currentTarget }) => {
    if (autoPlayEmoji) {
      return;
    }

    const emojis = currentTarget.querySelectorAll('.custom-emoji');

    for (var i = 0; i < emojis.length; i++) {
      let emoji = emojis[i];
      emoji.src = emoji.getAttribute('data-static');
    }
  }

  handleFollow = (e) => {
    if ((e && e.shiftKey) ^ !follow_button_to_list_adder) {
      this.props.onFollow(this.props.account);
    } else {
      this.props.onAddToList(this.props.account);
    }
  }

  handleSubscribe = (e) => {
    if ((e && e.shiftKey) ^ !follow_button_to_list_adder) {
      this.props.onSubscribe(this.props.account);
    } else {
      this.props.onAddToList(this.props.account);
    }
  }

  setRef = (c) => {
    this.node = c;
  }

  render () {
    const { account, intl, domain } = this.props;

    if (!account) {
      return null;
    }

    const suspended = account.get('suspended');

    let info        = [];
    let actionBtn   = '';
    let bellBtn     = '';
    let lockedIcon  = '';
    let menu        = [];
    let header      = '';

    if (me !== account.get('id') && account.getIn(['relationship', 'followed_by'])) {
      info.push(<span key='followed_by' className='relationship-tag'><FormattedMessage id='account.follows_you' defaultMessage='Follows you' /></span>);
    } else if (me !== account.get('id') && account.getIn(['relationship', 'blocking'])) {
      info.push(<span key='blocked' className='relationship-tag'><FormattedMessage id='account.blocked' defaultMessage='Blocked' /></span>);
    }

    if (me !== account.get('id') && account.getIn(['relationship', 'muting'])) {
      info.push(<span key='muted' className='relationship-tag'><FormattedMessage id='account.muted' defaultMessage='Muted' /></span>);
    } else if (me !== account.get('id') && account.getIn(['relationship', 'domain_blocking'])) {
      info.push(<span key='domain_blocked' className='relationship-tag'><FormattedMessage id='account.domain_blocked' defaultMessage='Domain blocked' /></span>);
    }

    if (account.getIn(['relationship', 'requested']) || account.getIn(['relationship', 'following'])) {
      bellBtn = <IconButton icon='bell-o' size={24} active={account.getIn(['relationship', 'notifying'])} title={intl.formatMessage(account.getIn(['relationship', 'notifying']) ? messages.disableNotifications : messages.enableNotifications, { name: account.get('username') })} onClick={this.props.onNotifyToggle} />;
    }

    if (me !== account.get('id')) {
      if (suspended) {
        if (!account.get('relationship')) { // Wait until the relationship is loaded
          actionBtn = '';
        } else if (account.getIn(['relationship', 'blocking'])) {
          actionBtn = <Button className='logo-button' text={intl.formatMessage(messages.unblock, { name: account.get('username') })} onClick={this.props.onBlock} />;
        } else if (!disableBlock) {
          actionBtn = <Button className='logo-button' text={intl.formatMessage(messages.block, { name: account.get('username') })} onClick={this.props.onBlock} />;
        }
      } else {
        if (!account.get('relationship')) { // Wait until the relationship is loaded
          actionBtn = '';
        } else if (account.getIn(['relationship', 'requested'])) {
          actionBtn = <Button className={classNames('logo-button', { 'button--with-bell': bellBtn !== '' })} text={intl.formatMessage(messages.cancel_follow_request)} title={intl.formatMessage(messages.requested)} onClick={this.props.onFollow} />;
        } else if (!account.getIn(['relationship', 'blocking'])) {
          if (account.getIn(['relationship', 'following'])) {
            actionBtn = <Button disabled={disableUnfollow || account.getIn(['relationship', 'blocked_by'])} className={classNames('logo-button', { 'button--destructive': !disableUnfollow, 'button--with-bell': bellBtn !== '' })} text={intl.formatMessage(messages.unfollow)} onClick={this.props.onFollow} />;
          } else {
            actionBtn = <Button disabled={disableFollow || account.getIn(['relationship', 'blocked_by'])} className={classNames('logo-button', { 'button--with-bell': bellBtn !== '' })} text={intl.formatMessage(messages.follow)} onClick={this.props.onFollow} />;
          }
        } else if (account.getIn(['relationship', 'blocking'])) {
          actionBtn = <Button className='logo-button' text={intl.formatMessage(messages.unblock, { name: account.get('username') })} onClick={this.props.onBlock} />;
        }
      }
    } else {
      actionBtn = <Button className='logo-button' text={intl.formatMessage(messages.edit_profile)} onClick={this.openEditProfile} />;
    }

    if (account.get('moved') && !account.getIn(['relationship', 'following'])) {
      actionBtn = '';
    }

    if (account.get('locked')) {
      lockedIcon = <Icon id='lock' title={intl.formatMessage(messages.account_locked)} />;
    }

    if (account.get('id') !== me) {
      if (!disablePost) {
        menu.push({ text: intl.formatMessage(messages.mention, { name: account.get('username') }), action: this.props.onMention });
        menu.push({ text: intl.formatMessage(messages.direct, { name: account.get('username') }), action: this.props.onDirect });
        menu.push(null);
      }

      menu.push({ text: intl.formatMessage(messages.conversations, { name: account.get('username') }), action: this.props.onConversations });
    } else {
      menu.push({ text: intl.formatMessage(messages.conversations_all), action: this.props.onConversations });
    }
    menu.push(null);

    if ('share' in navigator) {
      menu.push({ text: intl.formatMessage(messages.share, { name: account.get('username') }), action: this.handleShare });
      menu.push(null);
    }

    if (account.get('id') === me) {
      menu.push({ text: intl.formatMessage(messages.edit_profile), href: '/settings/profile' });
      menu.push({ text: intl.formatMessage(messages.preferences), href: '/settings/preferences' });
      menu.push({ text: intl.formatMessage(messages.pins), to: '/pinned' });
      menu.push(null);
      menu.push({ text: intl.formatMessage(messages.follow_requests), to: '/follow_requests' });
      menu.push({ text: intl.formatMessage(messages.favourites), to: '/favourites' });
      menu.push({ text: intl.formatMessage(messages.lists), to: '/lists' });
      menu.push({ text: intl.formatMessage(messages.circles), to: '/circles' });
      menu.push(null);
      menu.push({ text: intl.formatMessage(messages.mutes), to: '/mutes' });
      menu.push({ text: intl.formatMessage(messages.blocks), to: '/blocks' });
      menu.push({ text: intl.formatMessage(messages.domain_blocks), to: '/domain_blocks' });
    } else {
      if (account.getIn(['relationship', 'following'])) {
        if (!account.getIn(['relationship', 'muting'])) {
          if (account.getIn(['relationship', 'showing_reblogs'])) {
            menu.push({ text: intl.formatMessage(messages.hideReblogs, { name: account.get('username') }), action: this.props.onReblogToggle });
          } else {
            menu.push({ text: intl.formatMessage(messages.showReblogs, { name: account.get('username') }), action: this.props.onReblogToggle });
          }
        }

        menu.push({ text: intl.formatMessage(account.getIn(['relationship', 'endorsed']) ? messages.unendorse : messages.endorse), action: this.props.onEndorseToggle });
        menu.push(null);
      }
      menu.push({ text: intl.formatMessage(messages.add_or_remove_from_list), action: this.props.onAddToList });
      menu.push(null);

      if (account.getIn(['relationship', 'followed_by'])) {
        menu.push({ text: intl.formatMessage(messages.add_or_remove_from_circle), action: this.props.onAddToCircle });
        menu.push(null);
      }

      if (account.getIn(['relationship', 'muting'])) {
        menu.push({ text: intl.formatMessage(messages.unmute, { name: account.get('username') }), action: this.props.onMute });
      } else {
        menu.push({ text: intl.formatMessage(messages.mute, { name: account.get('username') }), action: this.props.onMute });
      }

      if (account.getIn(['relationship', 'blocking'])) {
        menu.push({ text: intl.formatMessage(messages.unblock, { name: account.get('username') }), action: this.props.onBlock });
      } else if (!disableBlock) {
        menu.push({ text: intl.formatMessage(messages.block, { name: account.get('username') }), action: this.props.onBlock });
      }

      if (!disableReport) {
        menu.push({ text: intl.formatMessage(messages.report, { name: account.get('username') }), action: this.props.onReport });
      }
    }

    if (account.get('acct') !== account.get('username')) {
      const domain = account.get('acct').split('@')[1];

      if (account.getIn(['relationship', 'domain_blocking'])) {
        menu.push(null);
        menu.push({ text: intl.formatMessage(messages.unblockDomain, { domain }), action: this.props.onUnblockDomain });
      } else if (!disableDomainBlock) {
        menu.push(null);
        menu.push({ text: intl.formatMessage(messages.blockDomain, { domain }), action: this.props.onBlockDomain });
      }
    }

    if (account.get('id') !== me && isStaff) {
      menu.push(null);
      menu.push({ text: intl.formatMessage(messages.admin_account, { name: account.get('username') }), href: `/admin/accounts/${account.get('id')}` });
    }

    const displayNameHtml = { __html: account.get('display_name_html') };
    const acct            = account.get('acct').indexOf('@') === -1 && domain ? `${account.get('acct')}@${domain}` : account.get('acct');

    let badge;

    if (account.get('bot')) {
      badge = (<div className='account-role bot'><FormattedMessage id='account.badges.bot' defaultMessage='Bot' /></div>);
    } else if (account.get('group')) {
      badge = (<div className='account-role group'><FormattedMessage id='account.badges.group' defaultMessage='Group' /></div>);
    } else {
      badge = null;
    }

    const following        = account.getIn(['relationship', 'following']);
    const delivery         = account.getIn(['relationship', 'delivery_following']);
    const followed_by      = account.getIn(['relationship', 'followed_by']) && show_followed_by;
    const subscribing      = account.getIn(['relationship', 'subscribing'], new Map).size > 0;
    const subscribing_home = account.getIn(['relationship', 'subscribing', '-1'], new Map).size > 0;
    const blockd_by        = account.getIn(['relationship', 'blocked_by']);
    let buttons;

    if(me !== account.get('id') && !blockd_by) {
      let following_buttons, subscribing_buttons;
      if(!account.get('moved') || subscribing) {
        subscribing_buttons = (
          <IconButton
            icon='rss-square'
            title={intl.formatMessage(subscribing ? messages.unsubscribe : messages.subscribe)}
            onClick={this.handleSubscribe}
            active={subscribing}
            no_delivery={subscribing && !subscribing_home}
          />
        );
      }
      if(!account.get('moved') || following) {
        following_buttons = (
          <IconButton
            disabled={following ? disableUnfollow : disableFollow}
            icon={following ? 'user-times' : 'user-plus'}
            title={intl.formatMessage(following ? messages.unfollow : messages.follow)}
            onClick={this.handleFollow}
            active={following}
            passive={followed_by}
            no_delivery={following && !delivery}
          />
        );
      }
      buttons = <Fragment>{subscribing_buttons}{following_buttons}</Fragment>;
    }

    if (account.get('header_full')) {
      if (autoPlayHeader) {
        header = account.get('header_full');
      } else {
        header = account.get('header_full_static');
      }
    } else {
      if (autoPlayHeader) {
        header = account.get('header');
      } else {
        header = account.get('header_static');
      }
    }

    return (
      <div className={classNames('account__header', 'advanced', { inactive: !!account.get('moved') })} onMouseEnter={this.handleMouseEnter} onMouseLeave={this.handleMouseLeave}>
        <div className='account__header__image'>
          <div className='account__header__info'>
            {!suspended && info}
          </div>

          <img src={header} alt='' className='parallax' />
        </div>

        <div className='account__header__bar'>
          <div className='account__header__tabs'>
            <a className='avatar' href={account.get('url')} rel='noopener noreferrer' target='_blank'>
              <Avatar account={account} size={90} full />
            </a>

            <div className='spacer' />

            <div className='account__header__tabs__buttons'>
              {actionBtn}
              {!suspended && (<>
                {bellBtn}

                <DropdownMenuContainer items={menu} icon='ellipsis-v' size={24} direction='right' />
              </>)}
            </div>
          </div>

          <div className='account__header__tabs__name'>
            <h1 ref={this.setRef}>
              <span dangerouslySetInnerHTML={displayNameHtml} /> {badge}
              <small>@{acct} {lockedIcon}</small>
            </h1>
            <div className='account__header__tabs__name__relationship account__relationship'>
              {buttons}
            </div>
          </div>
        </div>
      </div>
    );
  }

}

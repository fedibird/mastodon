import React, { Fragment } from 'react';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { injectIntl, FormattedMessage, defineMessages } from 'react-intl';
import { HotKeys } from 'react-hotkeys';
import PropTypes from 'prop-types';
import ImmutablePureComponent from 'react-immutable-pure-component';
import { me } from 'mastodon/initial_state';
import StatusContainer from 'mastodon/containers/status_container';
import AccountContainer from 'mastodon/containers/account_container';
import FollowRequestContainer from '../containers/follow_request_container';
import Avatar from 'mastodon/components/avatar';
import Emoji from 'mastodon/components/emoji';
import Icon from 'mastodon/components/icon';
import Permalink from 'mastodon/components/permalink';
import Content from 'mastodon/components/content';
import classNames from 'classnames';

const messages = defineMessages({
  favourite: { id: 'notification.favourite', defaultMessage: '{name} favourited your post' },
  follow: { id: 'notification.follow', defaultMessage: '{name} followed you' },
  ownPoll: { id: 'notification.own_poll', defaultMessage: 'Your poll has ended' },
  poll: { id: 'notification.poll', defaultMessage: 'A poll you have voted in has ended' },
  reblog: { id: 'notification.reblog', defaultMessage: '{name} boosted your post' },
  status: { id: 'notification.status', defaultMessage: '{name} just posted' },
  emoji_reaction: { id: 'notification.emoji_reaction', defaultMessage: '{name} reactioned your post' },
  status_reference: { id: 'notification.status_reference', defaultMessage: '{name} referenced your post' },
  scheduled_status: { id: 'notification.scheduled_status', defaultMessage: 'Your scheduled post has been posted' },
  followed: { id: 'notification.followed', defaultMessage: '{name} accept your follow request' },
});

const notificationForScreenReader = (intl, message, timestamp) => {
  const output = [message];

  output.push(intl.formatDate(timestamp, { hour: '2-digit', minute: '2-digit', month: 'short', day: 'numeric' }));

  return output.join(', ');
};

export default @injectIntl
class Notification extends ImmutablePureComponent {

  static contextTypes = {
    router: PropTypes.object,
  };

  static propTypes = {
    notification: ImmutablePropTypes.map.isRequired,
    hidden: PropTypes.bool,
    onMoveUp: PropTypes.func.isRequired,
    onMoveDown: PropTypes.func.isRequired,
    onMention: PropTypes.func.isRequired,
    onFavourite: PropTypes.func.isRequired,
    onReblog: PropTypes.func.isRequired,
    onToggleHidden: PropTypes.func.isRequired,
    status: ImmutablePropTypes.map,
    intl: PropTypes.object.isRequired,
    getScrollPosition: PropTypes.func,
    updateScrollBottom: PropTypes.func,
    cacheMediaWidth: PropTypes.func,
    cachedMediaWidth: PropTypes.number,
    unread: PropTypes.bool,
  };

  handleMoveUp = () => {
    const { notification, onMoveUp } = this.props;
    onMoveUp(notification.get('id'));
  }

  handleMoveDown = () => {
    const { notification, onMoveDown } = this.props;
    onMoveDown(notification.get('id'));
  }

  handleOpen = () => {
    const { notification } = this.props;

    if (notification.get('status')) {
      this.context.router.history.push(`/statuses/${notification.get('status')}`);
    } else {
      this.handleOpenProfile();
    }
  }

  handleOpenProfile = () => {
    const { notification } = this.props;
    this.context.router.history.push(`/accounts/${notification.getIn(['account', 'id'])}`);
  }

  handleMention = e => {
    e.preventDefault();

    const { notification, onMention } = this.props;
    onMention(notification.get('account'), this.context.router.history);
  }

  handleHotkeyFavourite = () => {
    const { status } = this.props;
    if (status) this.props.onFavourite(status);
  }

  handleHotkeyBoost = e => {
    const { status } = this.props;
    if (status) this.props.onReblog(status, e);
  }

  handleHotkeyToggleHidden = () => {
    const { status } = this.props;
    if (status) this.props.onToggleHidden(status);
  }

  getHandlers () {
    return {
      reply: this.handleMention,
      favourite: this.handleHotkeyFavourite,
      boost: this.handleHotkeyBoost,
      mention: this.handleMention,
      open: this.handleOpen,
      openProfile: this.handleOpenProfile,
      moveUp: this.handleMoveUp,
      moveDown: this.handleMoveDown,
      toggleHidden: this.handleHotkeyToggleHidden,
    };
  }

  renderFollow (notification, account, link) {
    const { intl, unread } = this.props;

    return (
      <HotKeys handlers={this.getHandlers()}>
        <div className={classNames('notification notification-follow focusable', { unread })} tabIndex='0' aria-label={notificationForScreenReader(intl, intl.formatMessage(messages.follow, { name: account.get('acct') }), notification.get('created_at'))}>
          <div className='notification__message'>
            <div className='notification__favourite-icon-wrapper'>
              <Icon id='user-plus' fixedWidth />
            </div>

            <span title={notification.get('created_at')}>
              <FormattedMessage id='notification.follow' defaultMessage='{name} followed you' values={{ name: link }} />
            </span>
          </div>

          <AccountContainer id={account.get('id')} hidden={this.props.hidden} />
        </div>
      </HotKeys>
    );
  }

  renderFollowRequest (notification, account, link) {
    const { intl, unread } = this.props;

    return (
      <HotKeys handlers={this.getHandlers()}>
        <div className={classNames('notification notification-follow-request focusable', { unread })} tabIndex='0' aria-label={notificationForScreenReader(intl, intl.formatMessage({ id: 'notification.follow_request', defaultMessage: '{name} has requested to follow you' }, { name: account.get('acct') }), notification.get('created_at'))}>
          <div className='notification__message'>
            <div className='notification__favourite-icon-wrapper'>
              <Icon id='user' fixedWidth />
            </div>

            <span title={notification.get('created_at')}>
              <FormattedMessage id='notification.follow_request' defaultMessage='{name} has requested to follow you' values={{ name: link }} />
            </span>
          </div>

          <FollowRequestContainer id={account.get('id')} withNote={false} hidden={this.props.hidden} />
        </div>
      </HotKeys>
    );
  }

  renderFollowedMessage (notification, account, link) {
    const { intl, unread } = this.props;
    account = notification.get('target_account');

    return (
      <HotKeys handlers={this.getHandlers()}>
        <div className={classNames('notification notification-followed-message focusable', { unread })} tabIndex='0' aria-label={notificationForScreenReader(intl, intl.formatMessage({ id: 'notification.followed-message', defaultMessage: '{name} accept your follow request' }, { name: account.get('acct') }), notification.get('created_at'))}>
          <div className='notification__message'>
            <div className='notification__favourite-icon-wrapper'>
              <Icon id='check-circle-o' fixedWidth />
            </div>

            <span title={notification.get('created_at')}>
              <FormattedMessage id='notification.followed-message' defaultMessage='{name} accept your follow request' values={{ name: link }} />
            </span>
          </div>

          {account.get('followed_message') &&
            <div className='notification__message'>
              <div className='notification__avatar-wrapper'>
                <Avatar account={account} size={48} />
              </div>

              <div className='notification__followed_message translate'>
                <Content className='notification__followed_message' contentHtml={{ __html: account.get('followed_message_emojified') }} />
              </div>
            </div>
          }
        </div>
      </HotKeys>
    );
  }

  renderMention (notification) {
    return (
      <StatusContainer
        id={notification.get('status')}
        withDismiss
        hidden={this.props.hidden}
        onMoveDown={this.handleMoveDown}
        onMoveUp={this.handleMoveUp}
        contextType='notifications'
        getScrollPosition={this.props.getScrollPosition}
        updateScrollBottom={this.props.updateScrollBottom}
        cachedMediaWidth={this.props.cachedMediaWidth}
        cacheMediaWidth={this.props.cacheMediaWidth}
        unread={this.props.unread}
      />
    );
  }

  renderFavourite (notification, link) {
    const { intl, unread } = this.props;

    return (
      <HotKeys handlers={this.getHandlers()}>
        <div className={classNames('notification notification-favourite focusable', { unread })} tabIndex='0' aria-label={notificationForScreenReader(intl, intl.formatMessage(messages.favourite, { name: notification.getIn(['account', 'acct']) }), notification.get('created_at'))}>
          <div className='notification__message'>
            <div className='notification__favourite-icon-wrapper'>
              <Icon id='star' className='star-icon' fixedWidth />
            </div>

            <span title={notification.get('created_at')}>
              <FormattedMessage id='notification.favourite' defaultMessage='{name} favourited your post' values={{ name: link }} />
            </span>
          </div>

          <StatusContainer
            id={notification.get('status')}
            account={notification.get('account')}
            muted
            withDismiss
            hidden={!!this.props.hidden}
            getScrollPosition={this.props.getScrollPosition}
            updateScrollBottom={this.props.updateScrollBottom}
            cachedMediaWidth={this.props.cachedMediaWidth}
            cacheMediaWidth={this.props.cacheMediaWidth}
          />
        </div>
      </HotKeys>
    );
  }

  renderReblog (notification, link) {
    const { intl, unread } = this.props;

    return (
      <HotKeys handlers={this.getHandlers()}>
        <div className={classNames('notification notification-reblog focusable', { unread })} tabIndex='0' aria-label={notificationForScreenReader(intl, intl.formatMessage(messages.reblog, { name: notification.getIn(['account', 'acct']) }), notification.get('created_at'))}>
          <div className='notification__message'>
            <div className='notification__favourite-icon-wrapper'>
              <Icon id='retweet' fixedWidth />
            </div>

            <span title={notification.get('created_at')}>
              <FormattedMessage id='notification.reblog' defaultMessage='{name} boosted your post' values={{ name: link }} />
            </span>
          </div>

          <StatusContainer
            id={notification.get('status')}
            account={notification.get('account')}
            muted
            withDismiss
            hidden={this.props.hidden}
            getScrollPosition={this.props.getScrollPosition}
            updateScrollBottom={this.props.updateScrollBottom}
            cachedMediaWidth={this.props.cachedMediaWidth}
            cacheMediaWidth={this.props.cacheMediaWidth}
          />
        </div>
      </HotKeys>
    );
  }

  renderStatus (notification, link) {
    const { intl, unread } = this.props;

    return (
      <HotKeys handlers={this.getHandlers()}>
        <div className={classNames('notification notification-status focusable', { unread })} tabIndex='0' aria-label={notificationForScreenReader(intl, intl.formatMessage(messages.status, { name: notification.getIn(['account', 'acct']) }), notification.get('created_at'))}>
          <div className='notification__message'>
            <div className='notification__favourite-icon-wrapper'>
              <Icon id='home' fixedWidth />
            </div>

            <span title={notification.get('created_at')}>
              <FormattedMessage id='notification.status' defaultMessage='{name} just posted' values={{ name: link }} />
            </span>
          </div>

          <StatusContainer
            id={notification.get('status')}
            account={notification.get('account')}
            muted
            withDismiss
            hidden={this.props.hidden}
            getScrollPosition={this.props.getScrollPosition}
            updateScrollBottom={this.props.updateScrollBottom}
            cachedMediaWidth={this.props.cachedMediaWidth}
            cacheMediaWidth={this.props.cacheMediaWidth}
          />
        </div>
      </HotKeys>
    );
  }

  renderScheduledStatus (notification) {
    const { intl, unread } = this.props;

    return (
      <HotKeys handlers={this.getHandlers()}>
        <div className={classNames('notification notification-scheduled-status focusable', { unread })} tabIndex='0' aria-label={notificationForScreenReader(intl, intl.formatMessage(messages.scheduled_status, { name: notification.getIn(['account', 'acct']) }), notification.get('created_at'))}>
          <div className='notification__message'>
            <div className='notification__favourite-icon-wrapper'>
              <Icon id='clock-o' fixedWidth />
            </div>

            <span title={notification.get('created_at')}>
              <FormattedMessage id='notification.scheduled_status' defaultMessage='Your scheduled post has been posted' />
            </span>
          </div>

          <StatusContainer
            id={notification.get('status')}
            account={notification.get('account')}
            muted
            withDismiss
            hidden={this.props.hidden}
            getScrollPosition={this.props.getScrollPosition}
            updateScrollBottom={this.props.updateScrollBottom}
            cachedMediaWidth={this.props.cachedMediaWidth}
            cacheMediaWidth={this.props.cacheMediaWidth}
          />
        </div>
      </HotKeys>
    );
  }

  renderPoll (notification, account) {
    const { intl, unread } = this.props;
    const ownPoll  = me === account.get('id');
    const message  = ownPoll ? intl.formatMessage(messages.ownPoll) : intl.formatMessage(messages.poll);

    return (
      <HotKeys handlers={this.getHandlers()}>
        <div className={classNames('notification notification-poll focusable', { unread })} tabIndex='0' aria-label={notificationForScreenReader(intl, message, notification.get('created_at'))}>
          <div className='notification__message'>
            <div className='notification__favourite-icon-wrapper'>
              <Icon id='tasks' fixedWidth />
            </div>

            <span title={notification.get('created_at')}>
              {ownPoll ? (
                <FormattedMessage id='notification.own_poll' defaultMessage='Your poll has ended' />
              ) : (
                <FormattedMessage id='notification.poll' defaultMessage='A poll you have voted in has ended' />
              )}
            </span>
          </div>

          <StatusContainer
            id={notification.get('status')}
            account={account}
            muted
            withDismiss
            hidden={this.props.hidden}
            getScrollPosition={this.props.getScrollPosition}
            updateScrollBottom={this.props.updateScrollBottom}
            cachedMediaWidth={this.props.cachedMediaWidth}
            cacheMediaWidth={this.props.cacheMediaWidth}
          />
        </div>
      </HotKeys>
    );
  }

  renderReaction (notification, link) {
    const { intl, unread } = this.props;

    if (!notification.get('emoji_reaction')) {
      return <Fragment />;
    }

    const wide = notification.getIn(['emoji_reaction', 'width'], 1) / notification.getIn(['emoji_reaction', 'height'], 1) >= 1.4;

    return (
      <HotKeys handlers={this.getHandlers()}>
        <div className={classNames('notification notification-reaction focusable', { unread })} tabIndex='0' aria-label={notificationForScreenReader(intl, intl.formatMessage(messages.emoji_reaction, { name: notification.getIn(['account', 'acct']) }), notification.get('created_at'))}>
          <div className='notification__message'>
            <div className={classNames('notification__reaction-icon-wrapper', { wide })}>
              <Emoji hovered={false} emoji={notification.getIn(['emoji_reaction', 'name'])} url={notification.getIn(['emoji_reaction', 'url'])} static_url={notification.getIn(['emoji_reaction', 'static_url'])} />
            </div>

            <span title={notification.get('created_at')} className={classNames('notification__reaction-message-wrapper', { wide })}>
              <FormattedMessage id='notification.emoji_reaction' defaultMessage='{name} reactioned your post' values={{ name: link }} />
            </span>
          </div>

          <StatusContainer
            id={notification.get('status')}
            account={notification.get('account')}
            muted
            withDismiss
            hidden={!!this.props.hidden}
            getScrollPosition={this.props.getScrollPosition}
            updateScrollBottom={this.props.updateScrollBottom}
            cachedMediaWidth={this.props.cachedMediaWidth}
            cacheMediaWidth={this.props.cacheMediaWidth}
          />
        </div>
      </HotKeys>
    );
  }

  renderStatusReference (notification, link) {
    const { intl, unread } = this.props;

    return (
      <HotKeys handlers={this.getHandlers()}>
        <div className={classNames('notification notification-status-reference focusable', { unread })} tabIndex='0' aria-label={notificationForScreenReader(intl, intl.formatMessage(messages.status_reference, { name: notification.getIn(['account', 'acct']) }), notification.get('created_at'))}>
          <div className='notification__message'>
            <div className='notification__favourite-icon-wrapper'>
              <Icon id='link' fixedWidth />
            </div>

            <span title={notification.get('created_at')}>
              <FormattedMessage id='notification.status_reference' defaultMessage='{name} referenced your post' values={{ name: link }} />
            </span>
          </div>

          <StatusContainer
            id={notification.get('status')}
            account={notification.get('account')}
            muted
            withDismiss
            hidden={this.props.hidden}
            getScrollPosition={this.props.getScrollPosition}
            updateScrollBottom={this.props.updateScrollBottom}
            cachedMediaWidth={this.props.cachedMediaWidth}
            cacheMediaWidth={this.props.cacheMediaWidth}
          />
        </div>
      </HotKeys>
    );
  }

  render () {
    const { notification } = this.props;
    const account          = notification.get('account');
    const displayNameHtml  = { __html: account.get('display_name_html') };
    const link             = <bdi><Permalink className='notification__display-name' href={account.get('url')} title={account.get('acct')} to={`${(account.get('group', false)) ? '/timelines/groups/' : '/accounts/'}${account.get('id')}`} dangerouslySetInnerHTML={displayNameHtml} /></bdi>;

    switch(notification.get('type')) {
    case 'follow':
      return this.renderFollow(notification, account, link);
    case 'follow_request':
      return this.renderFollowRequest(notification, account, link);
    case 'followed':
      return this.renderFollowedMessage(notification, account, link);
    case 'mention':
      return this.renderMention(notification);
    case 'favourite':
      return this.renderFavourite(notification, link);
    case 'reblog':
      return this.renderReblog(notification, link);
    case 'status':
      return this.renderStatus(notification, link);
    case 'scheduled_status':
      return this.renderScheduledStatus(notification, link);
    case 'poll':
      return this.renderPoll(notification, account);
    case 'emoji_reaction':
      return this.renderReaction(notification, link);
    case 'status_reference':
      return this.renderStatusReference(notification, link);
    }

    return null;
  };

}

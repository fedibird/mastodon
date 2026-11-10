import React from 'react';
import { connect } from 'react-redux';
import { makeGetAccount } from 'mastodon/selectors';
import ImmutablePropTypes from 'react-immutable-proptypes';
import ImmutablePureComponent from 'react-immutable-pure-component';
import Avatar from 'mastodon/components/avatar';
import EmojiMutedHtml from 'mastodon/components/emoji_muted_html';
import { FormattedMessage, injectIntl } from 'react-intl';

const makeMapStateToProps = () => {
  const getAccount = makeGetAccount();

  const mapStateToProps = (state, { accountId }) => ({
    account: getAccount(state, accountId),
  });

  return mapStateToProps;
};

class Account extends ImmutablePureComponent {

  static propTypes = {
    account: ImmutablePropTypes.map,
  };

  render () {
    const { account } = this.props;

    if ( !account ) {
      return null;
    }

    return (
      <div className='account-popup__wapper'>
        <div className='account-popup__avatar-wrapper'><Avatar account={account} size={14} /></div>
        <bdi><EmojiMutedHtml tag='strong' className='account-popup__display-name__html' html={account.get('display_name_html') || ''} /></bdi>
      </div>
    );
  }
}

const AccountContainer = connect(makeMapStateToProps)(Account);

const ACCOUNT_POPUP_ROWS_MAX = 10;

class AccountPopup extends ImmutablePureComponent {

  static propTypes = {
    accountIds: ImmutablePropTypes.list.isRequired,
  };

  render () {
    const { accountIds } = this.props;

    return (
      <>
        {accountIds.take(ACCOUNT_POPUP_ROWS_MAX).map(accountId => <AccountContainer key={accountId} accountId={accountId} />)}
        {accountIds.size > ACCOUNT_POPUP_ROWS_MAX && <div className='account-popup__wapper'><bdi><strong className='account-popup__display-name__html'><FormattedMessage id='account_popup.more_users' defaultMessage='({number, plural, one {# other user} other {# other users}})' values={{ number: accountIds.size - ACCOUNT_POPUP_ROWS_MAX}} children={msg=> <>{msg}</>} /></strong></bdi></div>}
      </>
    );
  }
}

export default injectIntl(AccountPopup);

import React from 'react';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { connect } from 'react-redux';

import Avatar from 'mastodon/components/avatar';
import { makeGetAccount } from 'mastodon/selectors';

const makeMapStateToProps = () => {
  const getAccount = makeGetAccount();

  return (state, { accountId }) => ({
    account: getAccount(state, accountId),
  });
};

class InlineAccount extends React.PureComponent {

  static propTypes = {
    account: ImmutablePropTypes.map,
  };

  render () {
    const { account } = this.props;

    if (!account) {
      return null;
    }

    return (
      <span className='inline-account'>
        <Avatar size={13} account={account} /> <strong>{account.get('username')}</strong>
      </span>
    );
  }

}

export default connect(makeMapStateToProps)(InlineAccount);

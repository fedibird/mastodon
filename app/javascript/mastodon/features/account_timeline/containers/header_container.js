import React from 'react';
import { connect } from 'react-redux';
import { makeGetAccount } from '../../../selectors';
import Header from '../components/header';
import {
  followAccount,
  unfollowAccount,
  subscribeAccount,
  unsubscribeAccount,
  unblockAccount,
  unmuteAccount,
  pinAccount,
  unpinAccount,
} from '../../../actions/accounts';
import {
  mentionCompose,
  directCompose,
} from '../../../actions/compose';
import { initMuteModal } from '../../../actions/mutes';
import { initBlockModal } from '../../../actions/blocks';
import { initReport } from '../../../actions/reports';
import { openModal } from '../../../actions/modal';
import { blockDomain, unblockDomain } from '../../../actions/domain_blocks';
import { defineMessages, injectIntl, FormattedMessage } from 'react-intl';
import { followModal, unfollowModal, subscribeModal, unsubscribeModal, confirmDomainBlock } from '../../../initial_state';
import { List as ImmutableList } from 'immutable';

const messages = defineMessages({
  followConfirm: { id: 'confirmations.follow.confirm', defaultMessage: 'Follow' },
  unfollowConfirm: { id: 'confirmations.unfollow.confirm', defaultMessage: 'Unfollow' },
  subscribeConfirm: { id: 'confirmations.subscribe.confirm', defaultMessage: 'Subscribe' },
  unsubscribeConfirm: { id: 'confirmations.unsubscribe.confirm', defaultMessage: 'Unsubscribe' },
  blockDomainConfirm: { id: 'confirmations.domain_block.confirm', defaultMessage: 'Hide entire domain' },
  blockDomainPassphrase: { id: 'confirmations.domain_block.passphrase', defaultMessage: 'block' },
});

const makeMapStateToProps = () => {
  const getAccount = makeGetAccount();

  const mapStateToProps = (state, { accountId, hideTabs, hideProfile }) => ({
    account: getAccount(state, accountId),
    domain: state.getIn(['meta', 'domain']),
    identity_proofs: state.getIn(['identity_proofs', accountId], ImmutableList()),
    hideProfile: hideTabs || hideProfile,
    advancedMode: state.getIn(['settings', 'account', 'other', 'advancedMode'], false),
  });

  return mapStateToProps;
};

const mapDispatchToProps = (dispatch, { intl }) => ({

  onFollow (account) {
    if (account.getIn(['relationship', 'following']) || account.getIn(['relationship', 'requested'])) {
      if (unfollowModal) {
        dispatch(openModal('CONFIRM', {
          message: <FormattedMessage id='confirmations.unfollow.message' defaultMessage='Are you sure you want to unfollow {name}?' values={{ name: <strong>@{account.get('acct')}</strong> }} />,
          confirm: intl.formatMessage(messages.unfollowConfirm),
          onConfirm: () => dispatch(unfollowAccount(account.get('id'))),
        }));
      } else {
        dispatch(unfollowAccount(account.get('id')));
      }
    } else {
      if (followModal) {
        dispatch(openModal('CONFIRM', {
          message: <FormattedMessage id='confirmations.follow.message' defaultMessage='Are you sure you want to follow {name}?' values={{ name: <strong>@{account.get('acct')}</strong> }} />,
          confirm: intl.formatMessage(messages.followConfirm),
          onConfirm: () => dispatch(followAccount(account.get('id'))),
        }));
      } else {
        dispatch(followAccount(account.get('id')));
      }
    }
  },

  onSubscribe (account) {
    if (account.getIn(['relationship', 'subscribing', '-1'], new Map).size > 0) {
      if (unsubscribeModal) {
        dispatch(openModal('CONFIRM', {
          message: <FormattedMessage id='confirmations.unsubscribe.message' defaultMessage='Are you sure you want to unsubscribe {name}?' values={{ name: <strong>@{account.get('acct')}</strong> }} />,
          confirm: intl.formatMessage(messages.unsubscribeConfirm),
          onConfirm: () => dispatch(unsubscribeAccount(account.get('id'))),
        }));
      } else {
        dispatch(unsubscribeAccount(account.get('id')));
      }
    } else {
      if (subscribeModal) {
        dispatch(openModal('CONFIRM', {
          message: <FormattedMessage id='confirmations.subscribe.message' defaultMessage='Are you sure you want to subscribe {name}?' values={{ name: <strong>@{account.get('acct')}</strong> }} />,
          confirm: intl.formatMessage(messages.subscribeConfirm),
          onConfirm: () => dispatch(subscribeAccount(account.get('id'))),
        }));
      } else {
        dispatch(subscribeAccount(account.get('id')));
      }
    }
  },

  onAddToList (account){
    dispatch(openModal('LIST_ADDER', {
      accountId: account.get('id'),
    }));
  },

  onBlock (account) {
    if (account.getIn(['relationship', 'blocking'])) {
      dispatch(unblockAccount(account.get('id')));
    } else {
      dispatch(initBlockModal(account));
    }
  },

  onMention (account, router) {
    dispatch(mentionCompose(account, router));
  },

  onDirect (account, router) {
    dispatch(directCompose(account, router));
  },

  onConversations (account, router) {
    router.push(`/accounts/${account.get('id')}/conversations`);
  },

  onReblogToggle (account) {
    if (account.getIn(['relationship', 'showing_reblogs'])) {
      dispatch(followAccount(account.get('id'), { reblogs: false }));
    } else {
      dispatch(followAccount(account.get('id'), { reblogs: true }));
    }
  },

  onEndorseToggle (account) {
    if (account.getIn(['relationship', 'endorsed'])) {
      dispatch(unpinAccount(account.get('id')));
    } else {
      dispatch(pinAccount(account.get('id')));
    }
  },

  onReport (account) {
    dispatch(initReport(account));
  },

  onMute (account) {
    if (account.getIn(['relationship', 'muting'])) {
      dispatch(unmuteAccount(account.get('id')));
    } else {
      dispatch(initMuteModal(account));
    }
  },

  onBlockDomain (domain) {
    dispatch(openModal('CONFIRM', {
      message: <FormattedMessage id='confirmations.domain_block.message' defaultMessage='Are you really, really sure you want to block the entire {domain}? In most cases a few targeted blocks or mutes are sufficient and preferable. You will not see content from that domain in any public timelines or your notifications. Your followers from that domain will be removed.' values={{ domain: <strong>{domain}</strong> }} />,
      confirm: intl.formatMessage(messages.blockDomainConfirm),
      onConfirm: () => dispatch(blockDomain(domain)),
      passphrase: confirmDomainBlock && intl.formatMessage(messages.blockDomainPassphrase),
      destructive: true,
    }));
  },

  onUnblockDomain (domain) {
    dispatch(unblockDomain(domain));
  },

  onAddToList(account){
    dispatch(openModal('LIST_ADDER', {
      accountId: account.get('id'),
    }));
  },

  onAddToCircle(account){
    dispatch(openModal('CIRCLE_ADDER', {
      accountId: account.get('id'),
    }));
  },

});

export default injectIntl(connect(makeMapStateToProps, mapDispatchToProps)(Header));

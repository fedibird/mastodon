import React from 'react';
import PropTypes from 'prop-types';
import { defineMessages, injectIntl } from 'react-intl';
import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import { connect } from 'react-redux';
import { fetchPostingIdentities, retryComposerInteraction, selectComposerSenderIdentity } from '../../../actions/posting_identities';
import { isAdministrator, me } from '../../../initial_state';
import { postingAccountControlAvailable } from '../composer_toolbar';
import { sessionPostingIdentityId } from '../../../posting_identity/identity';
import { PORTABLE_COMPOSER_MODE_SIMPLE, selectComposer, selectPortableComposerDisplayMode } from '../../../selectors/composer';
import { selectComposerCanSendAsIdentity, selectComposerSenderIdentity as selectSender } from '../../../selectors/posting_identities';
import { withComposerId } from '../composer_id_context';
import SenderIdentity from '../components/sender_identity';

const messages = defineMessages({
  loadFailed: { id: 'compose_form.sender_identity.failed', defaultMessage: 'Couldn’t confirm who this post is from.' },
  retry: { id: 'compose_form.sender_identity.retry', defaultMessage: 'Retry' },
});

const PostingAccountLoadRetry = injectIntl(({ intl, onRetry }) => (
  <p className='compose-form__sender-status' role='status' data-testid='posting-account-load-retry'>
    {intl.formatMessage(messages.loadFailed)}
    <button type='button' className='compose-form__sender-retry' onClick={onRetry}>
      {intl.formatMessage(messages.retry)}
    </button>
  </p>
));

PostingAccountLoadRetry.propTypes = {
  intl: PropTypes.object,
  onRetry: PropTypes.func.isRequired,
};

// The signed-in account fills in a sender only when that sender is the
// session identity. A missing delegated identity must not borrow it.
export const presentSenderIdentity = (sender, sessionAccount, sessionIdentityId) => {
  if (!sender) {
    return sender;
  }

  const selectedId = sender.get('id');
  const delegated = typeof selectedId === 'string' && selectedId.startsWith('delegated:');

  if (delegated) {
    if (sender.get('authorization') === 'ready') {
      return sender;
    }

    return sender.get('authorization') ? sender : sender.set('authorization', 'unavailable');
  }

  if (!sender.get('account') && sessionAccount && selectedId === sessionIdentityId) {
    return sender.set('account', sessionAccount);
  }

  return sender;
};

export const mapStateToProps = (state, { composerId }) => {
  const sender = selectSender(state, composerId);
  const composer = selectComposer(state, composerId);
  const catalog = state.getIn(['postingIdentities', 'identities']);
  const catalogStatus = state.getIn(['postingIdentities', 'status'], 'idle');
  const showPostingAccount = postingAccountControlAvailable({
    catalog,
    status: catalogStatus,
    selectedId: sender ? sender.get('id') : null,
    canLink: isAdministrator,
  });
  const sessionId = sessionPostingIdentityId();
  const sessionAccount = me ? state.getIn(['accounts', me]) : null;
  const current = presentSenderIdentity(sender, sessionAccount, sessionId);
  const choices = (catalog || []).filter(identity => {
    if (!identity || identity.get('authorization') !== 'ready') {
      return false;
    }

    if (identity.get('kind') === 'delegated') {
      return identity.getIn(['capabilities', 'post']) === 'supported';
    }

    return identity.get('kind') === 'local' && identity.get('id') === sessionId;
  });

  if (!isAdministrator) {
    return {
      showPostingAccount,
      visible: Boolean(sessionAccount),
      current: sessionAccount ? ImmutableMap({
        id: sessionId,
        authorization: 'ready',
        status: 'ready',
        account: sessionAccount,
      }) : null,
      choices: ImmutableList(),
      selectedId: sessionId,
      sessionIdentityId: sessionId,
      selectable: false,
      text: composer ? composer.get('text') : '',
      blockReason: null,
      sendBlocked: null,
      failed: false,
      canLink: false,
      compact: selectPortableComposerDisplayMode(state, composerId) === PORTABLE_COMPOSER_MODE_SIMPLE,
      catalog: null,
    };
  }

  return {
    showPostingAccount,
    visible: Boolean(sender),
    selectable: true,
    current,
    choices,
    selectedId: sender ? sender.get('id') : null,
    sessionIdentityId: sessionId,
    text: composer ? composer.get('text') : '',
    blockReason: sender ? sender.get('switchBlockReason') : null,
    sendBlocked: (() => {
      const decision = selectComposerCanSendAsIdentity(state, composerId);
      const delegated = sender && String(sender.get('id') || '').startsWith('delegated:');

      return delegated && !decision.canSend ? decision.reason : null;
    })(),
    failed: catalogStatus === 'failed',
    canLink: true,
    compact: selectPortableComposerDisplayMode(state, composerId) === PORTABLE_COMPOSER_MODE_SIMPLE,
    catalog: state.getIn(['postingIdentities', 'identities']),
  };
};

class SenderIdentityContainer extends React.PureComponent {

  static propTypes = {
    dispatch: PropTypes.func.isRequired,
    composerId: PropTypes.string,
    visible: PropTypes.bool,
    selectable: PropTypes.bool,
    current: PropTypes.object,
    failed: PropTypes.bool,
    canLink: PropTypes.bool,
    compact: PropTypes.bool,
    showPostingAccount: PropTypes.bool,
    presentation: PropTypes.string,
    suppressed: PropTypes.bool,
    open: PropTypes.bool,
    anchor: PropTypes.object,
    onDismiss: PropTypes.func,
    choices: PropTypes.object,
    selectedId: PropTypes.string,
    sessionIdentityId: PropTypes.string,
    text: PropTypes.string,
    blockReason: PropTypes.string,
    sendBlocked: PropTypes.string,
    catalog: PropTypes.object,
  };

  componentDidMount () {
    if (isAdministrator) {
      this.props.dispatch(fetchPostingIdentities());
    }
  }

  handleRetry = () => {
    this.props.dispatch(fetchPostingIdentities({ force: true }));
  };

  handleRetryInteraction = () => {
    this.props.dispatch(retryComposerInteraction(this.props.composerId));
  };

  handleSelect = (identityId, options) => {
    this.props.dispatch(selectComposerSenderIdentity(this.props.composerId, identityId, options || {}));
  };

  render () {
    if (this.props.suppressed || !this.props.visible) {
      return null;
    }

    if (!this.props.showPostingAccount) {
      if (this.props.failed && this.props.canLink) {
        return <PostingAccountLoadRetry onRetry={this.handleRetry} />;
      }

      return null;
    }

    const blockReason = this.props.blockReason || this.props.sendBlocked;
    const shared = {
      current: this.props.current,
      choices: this.props.choices,
      selectedId: this.props.selectedId,
      sessionIdentityId: this.props.sessionIdentityId,
      text: this.props.text,
      blockReason,
      failed: this.props.failed,
      compact: this.props.compact,
      selectable: this.props.selectable,
      composerId: this.props.composerId,
      catalog: this.props.catalog,
      onRetry: this.handleRetry,
      onRetryInteraction: this.props.sendBlocked === 'target' || this.props.sendBlocked === 'follow' ? this.handleRetryInteraction : null,
      onSelect: this.handleSelect,
    };

    if (this.props.presentation === 'detached') {
      return (
        <SenderIdentity
          {...shared}
          presentation='detached'
          open={this.props.open}
          anchor={this.props.anchor}
          onDismiss={this.props.onDismiss}
        />
      );
    }

    return <SenderIdentity {...shared} header />;
  }

}

export default withComposerId(connect(mapStateToProps)(SenderIdentityContainer));

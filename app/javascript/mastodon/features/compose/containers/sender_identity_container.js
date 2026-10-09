import React from 'react';
import PropTypes from 'prop-types';
import { connect } from 'react-redux';
import { fetchPostingIdentities, selectComposerSenderIdentity } from '../../../actions/posting_identities';
import { isAdministrator, me } from '../../../initial_state';
import { sessionPostingIdentityId } from '../../../posting_identity/identity';
import { PORTABLE_COMPOSER_MODE_SIMPLE, selectComposer, selectPortableComposerDisplayMode } from '../../../selectors/composer';
import { selectComposerCanSendAsIdentity, selectComposerSenderIdentity as selectSender } from '../../../selectors/posting_identities';
import { withComposerId } from '../composer_id_context';
import SenderIdentity from '../components/sender_identity';

const mapStateToProps = (state, { composerId }) => {
  const sender = selectSender(state, composerId);
  const composer = selectComposer(state, composerId);
  const catalogStatus = state.getIn(['postingIdentities', 'status'], 'idle');
  const sessionAccount = me ? state.getIn(['accounts', me]) : null;
  const current = sender && !sender.get('account') && sessionAccount ? sender.set('account', sessionAccount) : sender;
  const sessionId = sessionPostingIdentityId();
  const choices = (state.getIn(['postingIdentities', 'identities']) || []).filter(identity => {
    if (!identity || identity.get('authorization') !== 'ready') {
      return false;
    }

    if (identity.get('kind') === 'delegated') {
      return identity.getIn(['capabilities', 'post']) === 'supported';
    }

    return identity.get('kind') === 'local' && identity.get('id') === sessionId;
  });

  return {
    visible: isAdministrator && Boolean(sender),
    current,
    choices,
    selectedId: sender ? sender.get('id') : null,
    text: composer ? composer.get('text') : '',
    blockReason: sender ? sender.get('switchBlockReason') : null,
    sendBlocked: (() => {
      const decision = selectComposerCanSendAsIdentity(state, composerId);
      const delegated = sender && String(sender.get('id') || '').startsWith('delegated:');

      return delegated && !decision.canSend ? decision.reason : null;
    })(),
    failed: catalogStatus === 'failed',
    compact: selectPortableComposerDisplayMode(state, composerId) === PORTABLE_COMPOSER_MODE_SIMPLE,
  };
};

class SenderIdentityContainer extends React.PureComponent {

  static propTypes = {
    dispatch: PropTypes.func.isRequired,
    composerId: PropTypes.string,
    visible: PropTypes.bool,
    current: PropTypes.object,
    failed: PropTypes.bool,
    compact: PropTypes.bool,
    choices: PropTypes.object,
    selectedId: PropTypes.string,
    text: PropTypes.string,
    blockReason: PropTypes.string,
    sendBlocked: PropTypes.string,
  };

  componentDidMount () {
    if (isAdministrator) {
      this.props.dispatch(fetchPostingIdentities());
    }
  }

  handleRetry = () => {
    this.props.dispatch(fetchPostingIdentities({ force: true }));
  };

  handleSelect = (identityId, options) => {
    this.props.dispatch(selectComposerSenderIdentity(this.props.composerId, identityId, options || {}));
  };

  render () {
    if (!this.props.visible) {
      return null;
    }

    const blockReason = this.props.blockReason || this.props.sendBlocked;

    return (
      <SenderIdentity
        current={this.props.current}
        choices={this.props.choices}
        selectedId={this.props.selectedId}
        text={this.props.text}
        blockReason={blockReason}
        failed={this.props.failed}
        compact={this.props.compact}
        onRetry={this.handleRetry}
        onSelect={this.handleSelect}
      />
    );
  }

}

export default withComposerId(connect(mapStateToProps)(SenderIdentityContainer));

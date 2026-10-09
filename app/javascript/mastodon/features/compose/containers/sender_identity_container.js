import React from 'react';
import PropTypes from 'prop-types';
import { connect } from 'react-redux';
import { List as ImmutableList } from 'immutable';
import { fetchPostingIdentities, selectComposerSenderIdentity, syncComposerSenderIdentity } from '../../../actions/posting_identities';
import { isAdministrator, me } from '../../../initial_state';
import { selectComposerCanSendAsIdentity, selectComposerSenderIdentity as selectSender } from '../../../selectors/posting_identity';
import { withComposerId } from '../composer_id_context';
import SenderIdentity from '../components/sender_identity';

const accountFromIdentity = identity => (identity ? identity.get('account') : null);

const mapStateToProps = (state, { composerId, compact }) => {
  const identities = state.getIn(['postingIdentities', 'identities'], ImmutableList());
  const sender = selectSender(state, composerId);
  const selectedId = sender ? sender.get('id') : null;
  const selected = identities && identities.find ? identities.find(identity => identity.get('id') === selectedId) : null;
  const sessionAccount = me ? state.getIn(['accounts', String(me)]) : null;

  return {
    visible: isAdministrator,
    compact,
    identities,
    selectedId,
    account: accountFromIdentity(selected) || sessionAccount,
    catalogStatus: state.getIn(['postingIdentities', 'status'], 'idle'),
    canSend: selectComposerCanSendAsIdentity(state, composerId),
  };
};

const mapDispatchToProps = (dispatch, { composerId }) => ({
  onSelect(identityId) {
    dispatch(selectComposerSenderIdentity(composerId, identityId));
    return null;
  },

  onMount() {
    if (isAdministrator) {
      dispatch(syncComposerSenderIdentity(composerId));
      dispatch(fetchPostingIdentities());
    }

    return null;
  },

  onRetry() {
    if (isAdministrator) {
      dispatch(fetchPostingIdentities({ force: true }));
    }

    return null;
  },
});

class SenderIdentityContainer extends React.PureComponent {

  static propTypes = {
    composerId: PropTypes.string,
    compact: PropTypes.bool,
    onMount: PropTypes.func.isRequired,
    onRetry: PropTypes.func.isRequired,
    catalogStatus: PropTypes.string,
  };

  componentDidMount() {
    this.props.onMount();
  }

  render() {
    return (
      <SenderIdentity
        {...this.props}
        onRetry={this.props.catalogStatus === 'failed' ? this.props.onRetry : null}
      />
    );
  }

}

export default withComposerId(connect(mapStateToProps, mapDispatchToProps)(SenderIdentityContainer));

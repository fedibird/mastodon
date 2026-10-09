import React from 'react';
import PropTypes from 'prop-types';
import { connect } from 'react-redux';
import { List as ImmutableList } from 'immutable';
import { fetchPostingIdentities, selectComposerSenderIdentity } from '../../../actions/posting_identities';
import { isAdministrator, me } from '../../../initial_state';
import { PORTABLE_COMPOSER_MODE_SIMPLE, selectPortableComposerDisplayMode } from '../../../selectors/composer';
import { selectComposerSenderIdentity as selectSender } from '../../../selectors/posting_identities';
import { withComposerId } from '../composer_id_context';
import SenderIdentity from '../components/sender_identity';

const mapStateToProps = (state, { composerId }) => {
  const sender = selectSender(state, composerId);
  const identities = state.getIn(['postingIdentities', 'identities'], ImmutableList());
  const catalogStatus = state.getIn(['postingIdentities', 'status'], 'idle');
  const sessionAccount = me ? state.getIn(['accounts', me]) : null;
  const current = sender && !sender.get('account') && sessionAccount ? sender.set('account', sessionAccount) : sender;

  return {
    visible: isAdministrator && Boolean(sender),
    current,
    choices: identities,
    selectedId: sender ? sender.get('id') : null,
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
    choices: PropTypes.object,
    selectedId: PropTypes.string,
    failed: PropTypes.bool,
    compact: PropTypes.bool,
  };

  componentDidMount () {
    if (isAdministrator) {
      this.props.dispatch(fetchPostingIdentities());
    }
  }

  handleSelect = identityId => {
    this.props.dispatch(selectComposerSenderIdentity(this.props.composerId, identityId));
  };

  handleRetry = () => {
    this.props.dispatch(fetchPostingIdentities({ force: true }));
  };

  render () {
    if (!this.props.visible) {
      return null;
    }

    return (
      <SenderIdentity
        current={this.props.current}
        choices={this.props.choices}
        selectedId={this.props.selectedId}
        failed={this.props.failed}
        compact={this.props.compact}
        onSelect={this.handleSelect}
        onRetry={this.handleRetry}
      />
    );
  }

}

export default withComposerId(connect(mapStateToProps)(SenderIdentityContainer));

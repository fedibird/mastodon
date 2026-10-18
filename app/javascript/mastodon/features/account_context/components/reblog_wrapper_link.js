import React from 'react';
import PropTypes from 'prop-types';
import { connect } from 'react-redux';
import { defineMessages, FormattedMessage, injectIntl } from 'react-intl';

import { reblogWrapperTarget } from '../../../account_context/target';
import { lookupReblogWrapper, openAccountContext } from '../../../actions/account_context_view';

const messages = defineMessages({
  open: { id: 'account_context.boost_list', defaultMessage: 'See posts around this boost' },
  loading: { id: 'account_context.wrapper_loading', defaultMessage: 'Looking up this boost…' },
  absent: { id: 'account_context.wrapper_absent', defaultMessage: 'No boost from this account was found.' },
  unavailable: { id: 'account_context.wrapper_unavailable', defaultMessage: 'This boost cannot be shown.' },
  ambiguous: { id: 'account_context.wrapper_ambiguous', defaultMessage: 'More than one boost matches, so this list cannot choose one.' },
  unknown: { id: 'account_context.wrapper_unknown', defaultMessage: 'The boost post could not be identified.' },
});

const noticeMessage = {
  absent: messages.absent,
  unavailable: messages.unavailable,
  ambiguous: messages.ambiguous,
  unknown: messages.unknown,
};

class ReblogWrapperLink extends React.PureComponent {

  static propTypes = {
    dispatch: PropTypes.func.isRequired,
    accountId: PropTypes.string.isRequired,
    originalStatusId: PropTypes.string.isRequired,
    hostTimelineId: PropTypes.string.isRequired,
  };

  state = {
    phase: 'idle',
    reason: null,
    generation: 0,
  };

  componentWillUnmount () {
    this.unmounted = true;
  }

  handleClick = (event) => {
    event.preventDefault();
    event.stopPropagation();

    const generation = (this.lookupGeneration || 0) + 1;
    const { dispatch, accountId, originalStatusId, hostTimelineId } = this.props;

    this.lookupGeneration = generation;
    this.setState({ phase: 'loading', reason: null, generation });

    return dispatch(lookupReblogWrapper({ statusId: originalStatusId, accountId })).then(resolution => {
      if (this.unmounted || this.lookupGeneration !== generation) {
        return null;
      }

      const target = reblogWrapperTarget({
        accountId,
        resolution,
        originalStatusId,
      });

      if (!target.available) {
        this.setState({ phase: 'notice', reason: target.reason });
        return null;
      }

      this.setState({ phase: 'idle', reason: null });
      dispatch(openAccountContext({ hostTimelineId, target }));
      return null;
    }).catch(() => {
      if (this.unmounted || this.lookupGeneration !== generation) {
        return null;
      }

      this.setState({ phase: 'notice', reason: 'unknown' });
      return null;
    });
  };

  render () {
    const { phase, reason } = this.state;
    const notice = noticeMessage[reason] || messages.unknown;

    return (
      <div className='account-context-reblog'>
        <button type='button' className='account-context-link' disabled={phase === 'loading'} onClick={this.handleClick}>
          <FormattedMessage {...(phase === 'loading' ? messages.loading : messages.open)} />
        </button>
        {phase === 'notice' && (
          <p className='account-context-reblog__notice'>
            <FormattedMessage {...notice} />
          </p>
        )}
      </div>
    );
  }

}

export default injectIntl(connect()(ReblogWrapperLink));

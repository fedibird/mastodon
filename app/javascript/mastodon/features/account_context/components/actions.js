import React from 'react';
import PropTypes from 'prop-types';
import { defineMessages, FormattedMessage } from 'react-intl';

import { accountContextSurfaceKey, accountContextTarget } from '../../../account_context/target';

const messages = defineMessages({
  boost: { id: 'account_context.boost', defaultMessage: 'See posts around this boost' },
  quote: { id: 'account_context.quote', defaultMessage: 'See posts around this quote' },
  reference: { id: 'account_context.reference', defaultMessage: 'See posts around this reference' },
});

class ContextButton extends React.PureComponent {

  static propTypes = {
    target: PropTypes.object.isRequired,
    hostTimelineId: PropTypes.string.isRequired,
    message: PropTypes.object.isRequired,
    onOpen: PropTypes.func,
  };

  handleClick = (event) => {
    event.preventDefault();
    event.stopPropagation();

    if (this.props.onOpen) {
      this.props.onOpen(this.props.hostTimelineId, this.props.target);
    }
  };

  render () {
    return (
      <button type='button' className='account-context-link' onClick={this.handleClick}>
        <FormattedMessage {...this.props.message} />
      </button>
    );
  }

}

// Links for the account that boosted, quoted, or referenced. These are not
// the thread control and they do not open the quoted or referenced post.
class AccountContextActions extends React.PureComponent {

  static propTypes = {
    status: PropTypes.object,
    hostTimelineId: PropTypes.string,
    onOpen: PropTypes.func,
  };

  render () {
    const hostTimelineId = accountContextSurfaceKey(this.props.hostTimelineId);
    const status = this.props.status;

    if (!hostTimelineId || !status) {
      return null;
    }

    const boost = accountContextTarget({ kind: 'boost', status });
    const quote = accountContextTarget({ kind: 'quote', status });
    const reference = accountContextTarget({ kind: 'reference', status });
    const links = [];

    if (boost.available) {
      links.push(<ContextButton key='boost' target={boost} hostTimelineId={hostTimelineId} message={messages.boost} onOpen={this.props.onOpen} />);
    }

    if (quote.available) {
      links.push(<ContextButton key='quote' target={quote} hostTimelineId={hostTimelineId} message={messages.quote} onOpen={this.props.onOpen} />);
    }

    if (reference.available) {
      links.push(<ContextButton key='reference' target={reference} hostTimelineId={hostTimelineId} message={messages.reference} onOpen={this.props.onOpen} />);
    }

    if (links.length === 0) {
      return null;
    }

    return (
      <div className='account-context-actions'>
        {links}
      </div>
    );
  }

}

export default AccountContextActions;

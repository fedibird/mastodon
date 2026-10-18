import React from 'react';
import PropTypes from 'prop-types';
import { connect } from 'react-redux';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { defineMessages, FormattedMessage, injectIntl } from 'react-intl';

import { closeAccountContext } from '../../actions/account_context_view';
import { accountContextOrder } from '../../reducers/account_context_views';
import AccountContextTimeline from './components/timeline';

const messages = defineMessages({
  back: { id: 'account_context.back', defaultMessage: 'Back' },
  boost: { id: 'account_context.title.boost', defaultMessage: 'Posts around this boost' },
  quote: { id: 'account_context.title.quote', defaultMessage: 'Posts around this quote' },
  reference: { id: 'account_context.title.reference', defaultMessage: 'Posts around this reference' },
});

class AccountContextPanel extends React.PureComponent {

  static propTypes = {
    hostKey: PropTypes.string.isRequired,
    session: ImmutablePropTypes.map,
    intl: PropTypes.object.isRequired,
    onClose: PropTypes.func.isRequired,
  };

  handleClose = () => {
    this.props.onClose(this.props.hostKey);
  };

  render () {
    const { hostKey, session, intl } = this.props;

    if (!session) {
      return null;
    }

    const title = messages[session.get('kind')] || messages.reference;

    return (
      <section className='account-context-panel' role='dialog' aria-label={intl.formatMessage(title)}>
        <header className='account-context-panel__header'>
          <button type='button' className='account-context-panel__back' onClick={this.handleClose}>
            <FormattedMessage {...messages.back} />
          </button>
          <h1 className='account-context-panel__title'>
            <FormattedMessage {...title} />
          </h1>
        </header>
        <div className='account-context-panel__body'>
          <AccountContextTimeline hostKey={hostKey} />
        </div>
      </section>
    );
  }

}

const NARROW_QUERY = '(max-width: 630px)';

const narrowViewport = () => (
  typeof window.matchMedia === 'function' && window.matchMedia(NARROW_QUERY).matches
);

class AccountContextLayer extends React.PureComponent {

  static propTypes = {
    dispatch: PropTypes.func.isRequired,
    intl: PropTypes.object.isRequired,
    order: ImmutablePropTypes.list.isRequired,
    sessions: ImmutablePropTypes.map,
  };

  state = {
    narrow: false,
  };

  componentDidMount () {
    this.setState({ narrow: narrowViewport() });
    window.addEventListener('keydown', this.handleKeyDown);

    if (typeof window.matchMedia === 'function') {
      this.media = window.matchMedia(NARROW_QUERY);
      this.media.addEventListener('change', this.handleMedia);
    }
  }

  componentWillUnmount () {
    window.removeEventListener('keydown', this.handleKeyDown);

    if (this.media) {
      this.media.removeEventListener('change', this.handleMedia);
    }
  }

  handleMedia = () => {
    this.setState({ narrow: narrowViewport() });
  };

  handleKeyDown = (event) => {
    if (event.key !== 'Escape' || this.props.order.size === 0) {
      return;
    }

    event.preventDefault();
    this.props.dispatch(closeAccountContext(this.props.order.last()));
  };

  handleClose = (hostKey) => {
    this.props.dispatch(closeAccountContext(hostKey));
  };

  renderPanel = (hostKey) => (
    <AccountContextPanel
      key={hostKey}
      hostKey={hostKey}
      session={this.props.sessions.get(hostKey)}
      intl={this.props.intl}
      onClose={this.handleClose}
    />
  );

  render () {
    const { order } = this.props;

    if (!order || order.size === 0) {
      return null;
    }

    const visible = this.state.narrow ? order.slice(-1) : order;

    return (
      <div className='account-context-layer'>
        {visible.map(this.renderPanel)}
      </div>
    );
  }

}

const mapStateToProps = (state) => ({
  order: accountContextOrder(state),
  sessions: state.getIn(['accountContextViews', 'sessions']),
});

export default injectIntl(connect(mapStateToProps)(AccountContextLayer));

import React from 'react';
import PropTypes from 'prop-types';
import { defineMessages, injectIntl } from 'react-intl';

const messages = defineMessages({
  destination: { id: 'compose_form.posting_style.context', defaultMessage: 'Posting destination' },
  details: { id: 'compose_form.destination.details', defaultMessage: 'Destination details' },
  warning: { id: 'compose_form.destination.warning', defaultMessage: 'Posting to this destination needs attention' },
});

class ComposerDestinationSummary extends React.PureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    placeLabel: PropTypes.string,
    warning: PropTypes.bool,
    contextDetails: PropTypes.node,
  };

  state = {
    open: false,
  };

  root = null;

  trigger = null;

  setRoot = (node) => {
    this.root = node;
  };

  setTrigger = (node) => {
    this.trigger = node;
  };

  componentDidMount () {
    document.addEventListener('mousedown', this.handleDocumentClick);
    document.addEventListener('keydown', this.handleDocumentKey);
  }

  componentWillUnmount () {
    document.removeEventListener('mousedown', this.handleDocumentClick);
    document.removeEventListener('keydown', this.handleDocumentKey);
  }

  handleDocumentClick = (event) => {
    if (!this.state.open || !this.root || this.root.contains(event.target)) {
      return;
    }

    this.setState({ open: false });
  };

  handleDocumentKey = (event) => {
    if (event.key === 'Escape' && this.state.open) {
      event.preventDefault();
      this.setState({ open: false }, () => {
        if (this.trigger) {
          this.trigger.focus();
        }
      });
    }
  };

  handleToggle = () => {
    this.setState(state => ({ open: !state.open }));
  };

  render () {
    const { intl, placeLabel, warning, contextDetails } = this.props;
    const name = placeLabel || intl.formatMessage(messages.destination);

    return (
      <div className='compose-form__destination' data-testid='composer-destination' ref={this.setRoot}>
        <span className='compose-form__destination-name'>{name}</span>
        {warning ? <span className='compose-form__style-warning' role='status'>{intl.formatMessage(messages.warning)}</span> : null}
        <button
          type='button'
          className='compose-form__destination-details'
          aria-expanded={this.state.open}
          ref={this.setTrigger}
          onClick={this.handleToggle}
        >
          {intl.formatMessage(messages.details)}
        </button>
        {this.state.open ? (
          <div className='compose-form__destination-panel'>
            {contextDetails}
          </div>
        ) : null}
      </div>
    );
  }

}

export default injectIntl(ComposerDestinationSummary);

import React from 'react';
import PropTypes from 'prop-types';
import { FormattedMessage, defineMessages, injectIntl } from 'react-intl';

const messages = defineMessages({
  newer: { id: 'timeline_history.load_newer', defaultMessage: 'Load newer posts' },
  older: { id: 'timeline_history.load_older', defaultMessage: 'Load older posts' },
  newerError: { id: 'timeline_history.load_newer_error', defaultMessage: 'Could not load newer posts. Try again' },
  olderError: { id: 'timeline_history.load_older_error', defaultMessage: 'Could not load older posts. Try again' },
  newerUnavailable: { id: 'timeline_history.newer_unavailable', defaultMessage: 'Newer posts in this range are no longer in the feed. Try again' },
  olderUnavailable: { id: 'timeline_history.older_unavailable', defaultMessage: 'Older posts in this range are no longer in the feed. Try again' },
  anchorMissing: { id: 'timeline_history.anchor_missing', defaultMessage: 'Could not find the post you were reading. History was not jumped to the top.' },
});

const labelFor = (direction, status) => {
  if (status === 'error') {
    return direction === 'newer' ? messages.newerError : messages.olderError;
  }

  if (status === 'unavailable') {
    return direction === 'newer' ? messages.newerUnavailable : messages.olderUnavailable;
  }

  return direction === 'newer' ? messages.newer : messages.older;
};

export const HistoryAnchorNotice = () => (
  <div className='load-more load-window-edge load-window-edge--notice'>
    <FormattedMessage {...messages.anchorMissing} />
  </div>
);

export default @injectIntl
class LoadWindowEdge extends React.PureComponent {

  static propTypes = {
    direction: PropTypes.oneOf(['newer', 'older']).isRequired,
    status: PropTypes.string,
    disabled: PropTypes.bool,
    visible: PropTypes.bool,
    onClick: PropTypes.func,
    intl: PropTypes.object.isRequired,
  };

  static defaultProps = {
    visible: true,
    status: 'open',
  };

  handleClick = (event) => {
    event.preventDefault();

    if (this.props.onClick) {
      this.props.onClick();
    }
  };

  render () {
    const { direction, disabled, visible, status, intl } = this.props;
    const label = intl.formatMessage(labelFor(direction, status));

    return (
      <button
        type='button'
        className='load-more load-window-edge'
        disabled={disabled || !visible}
        style={{ visibility: visible ? 'visible' : 'hidden' }}
        onClick={this.handleClick}
        data-history-edge={direction}
        data-history-status={status}
      >
        {label}
      </button>
    );
  }

}

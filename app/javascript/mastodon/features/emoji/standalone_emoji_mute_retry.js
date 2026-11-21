import React from 'react';
import PropTypes from 'prop-types';
import { connect } from 'react-redux';
import { FormattedMessage } from 'react-intl';
import { retryEmojiMuteLoad } from 'mastodon/actions/emoji_mutes';

const mapStateToProps = state => ({
  failed: state.getIn(['emojiMutes', 'phase']) === 'error' && state.getIn(['emojiMutes', 'availability']) !== 'disabled',
});

// /share keeps the composer usable when the rules GET fails. This is the
// retry that does not reload the page.
class StandaloneEmojiMuteRetry extends React.PureComponent {

  handleRetry = () => {
    this.props.dispatch(retryEmojiMuteLoad());
  };

  render() {
    if (!this.props.failed) {
      return null;
    }

    return (
      <div className='emoji-mutes-bootstrap' role='alert'>
        <p>
          <FormattedMessage
            id='emoji_mutes.standalone_retry'
            defaultMessage='Emoji mute settings could not be verified. You can keep composing. Emoji stay hidden until the settings load.'
          />
        </p>
        <button type='button' onClick={this.handleRetry}>
          <FormattedMessage id='emoji_mutes.bootstrap_retry' defaultMessage='Retry loading settings' />
        </button>
      </div>
    );
  }

}

StandaloneEmojiMuteRetry.propTypes = {
  failed: PropTypes.bool,
  dispatch: PropTypes.func,
};

export default connect(mapStateToProps)(StandaloneEmojiMuteRetry);

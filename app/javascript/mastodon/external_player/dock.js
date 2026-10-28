import React from 'react';
import PropTypes from 'prop-types';
import { connect } from 'react-redux';
import { FormattedMessage } from 'react-intl';

import { removePictureInPicture } from 'mastodon/actions/picture_in_picture';
import ExternalPlayerActions from './actions';
import {
  closeSession,
  getPinnedSession,
  registerDockSlot,
  setAttachmentFloatActive,
  setFloatingClaimHandler,
  subscribeExternalPlayers,
  unpinSession,
} from './session';

class ExternalPlayerDock extends React.PureComponent {

  static propTypes = {
    dispatch: PropTypes.func.isRequired,
    attachmentPip: PropTypes.bool,
  };

  componentDidMount () {
    this.unsubscribe = subscribeExternalPlayers(() => {
      if (!this.unmounted) {
        this.forceUpdate();
      }
    });
    setFloatingClaimHandler(() => {
      this.props.dispatch(removePictureInPicture());
    });
    setAttachmentFloatActive(this.props.attachmentPip === true);
  }

  componentDidUpdate (prevProps) {
    if (prevProps.attachmentPip !== this.props.attachmentPip) {
      setAttachmentFloatActive(this.props.attachmentPip === true);
    }
  }

  componentWillUnmount () {
    this.unmounted = true;

    if (this.unsubscribe) {
      this.unsubscribe();
    }

    if (this.releaseSlot) {
      this.releaseSlot();
      this.releaseSlot = null;
    }

    setFloatingClaimHandler(null);
  }

  setSlot = (element) => {
    if (this.releaseSlot) {
      this.releaseSlot();
      this.releaseSlot = null;
    }

    if (element) {
      this.releaseSlot = registerDockSlot(element);
    }
  };

  handleReturn = () => {
    const session = getPinnedSession();

    if (session) {
      unpinSession(session.key);
    }
  };

  handleClose = () => {
    const session = getPinnedSession();

    if (session) {
      closeSession(session.key);
    }
  };

  render () {
    const session = getPinnedSession();

    if (!session) {
      return null;
    }

    const titleId = 'external-player-dock-title';
    const noteId = 'external-player-return-note';
    const missing = session.returnUnavailable === true || session.anchorIds.size === 0;

    return (
      <div className={`external-player-dock external-player-dock--${session.kind}`} role='region' aria-labelledby={titleId}>
        <div className='external-player-dock__bar'>
          <p id={titleId} className='external-player-dock__title'>
            <FormattedMessage id='external_media.fixed_player' defaultMessage='Fixed player' />
          </p>
          <ExternalPlayerActions
            pinned
            describedBy={missing ? noteId : undefined}
            onReturn={this.handleReturn}
            onClose={this.handleClose}
          />
        </div>
        {missing ? (
          <p id={noteId} className='external-player-dock__note' aria-live='polite'>
            <FormattedMessage id='external_media.return_unavailable' defaultMessage='The original post is not in this view. Playback stays in the fixed player.' />
          </p>
        ) : null}
        <div className='external-player-dock__slot' ref={this.setSlot} />
      </div>
    );
  }

}

const mapStateToProps = state => {
  const pip = state.get('picture_in_picture') || {};
  return {
    attachmentPip: !!pip.statusId,
  };
};

export default connect(mapStateToProps)(ExternalPlayerDock);

import React from 'react';
import PropTypes from 'prop-types';
import { FormattedMessage } from 'react-intl';

import {
  anchorRole,
  closeSession,
  pinSession,
  registerAnchor,
  subscribeExternalPlayers,
  unpinSession,
  unregisterAnchor,
  updateAnchorElement,
} from './session';

// The row owns the toolbar and the empty slot. The media element itself is
// not a React child, so a re-render cannot give it a new src or a new parent.
export default class ExternalPlayerSurface extends React.PureComponent {

  static propTypes = {
    session: PropTypes.shape({
      key: PropTypes.string.isRequired,
      pinned: PropTypes.bool,
      returnUnavailable: PropTypes.bool,
    }).isRequired,
    prefer: PropTypes.bool,
    releaseSignal: PropTypes.shape({
      mode: PropTypes.string,
    }),
    frameClassName: PropTypes.string,
    footer: PropTypes.node,
  };

  componentDidMount () {
    this.unsubscribe = subscribeExternalPlayers(() => {
      if (!this.unmounted) {
        this.forceUpdate();
      }
    });
    this.attach();
  }

  componentDidUpdate () {
    this.attach();
  }

  componentWillUnmount () {
    this.unmounted = true;

    if (this.unsubscribe) {
      this.unsubscribe();
    }

    if (this.anchorId) {
      unregisterAnchor(this.anchorId);
      this.anchorId = null;
    }
  }

  attach () {
    const session = this.props.session;
    const element = this.frameNode;

    if (!session || !element) {
      return;
    }

    if (this.anchorId) {
      updateAnchorElement(this.anchorId, element);
      return;
    }

    this.anchorId = registerAnchor({
      key: session.key,
      element,
      prefer: this.props.prefer === true,
      releaseMode: () => (this.props.releaseSignal && this.props.releaseSignal.mode) || 'detach',
    });
  }

  handlePin = () => {
    pinSession(this.props.session.key);
  };

  handleReturn = () => {
    unpinSession(this.props.session.key);
  };

  handleClose = () => {
    closeSession(this.props.session.key);
  };

  setFrame = (element) => {
    this.frameNode = element;
  };

  render () {
    const { session, footer, frameClassName } = this.props;
    const role = anchorRole(session, this.anchorId);
    const pinned = role === 'pinned';

    return (
      <div className='external-player-surface' data-external-player-role={role}>
        <div className='external-player-toolbar'>
          {pinned ? (
            <button type='button' className='external-player-toolbar__button' onClick={this.handleReturn}>
              <FormattedMessage id='external_media.return_to_post' defaultMessage='Return to the post' />
            </button>
          ) : (
            <button type='button' className='external-player-toolbar__button' onClick={this.handlePin}>
              <FormattedMessage id='external_media.pop_out' defaultMessage='Pop out' />
            </button>
          )}
          <button type='button' className='external-player-toolbar__button' onClick={this.handleClose}>
            <FormattedMessage id='external_media.close' defaultMessage='Close' />
          </button>
        </div>
        <div className={frameClassName} ref={this.setFrame}>
          {role === 'elsewhere' ? (
            <p className='external-player-surface__elsewhere'>
              <FormattedMessage id='external_media.open_elsewhere' defaultMessage='This player is open on another copy of this post.' />
            </p>
          ) : null}
          {pinned ? (
            <p className='external-player-surface__pinned'>
              <FormattedMessage id='external_media.fixed_player' defaultMessage='Fixed player' />
            </p>
          ) : null}
        </div>
        {footer || null}
      </div>
    );
  }

}

import React from 'react';
import PropTypes from 'prop-types';
import { FormattedMessage } from 'react-intl';

// The Mastodon shell owns retry, ignore, and the preference write. Layouts
// only render this card, so a column switch cannot mount a second copy of
// that state. Session isolation stays outside the detached WebUI.
export const EmojiMuteNoticeContext = React.createContext(null);

let noticeSequence = 0;

export default class EmojiMuteLoadNotice extends React.PureComponent {

  static contextType = EmojiMuteNoticeContext;

  static propTypes = {
    placement: PropTypes.oneOf(['compose-panel', 'drawer', 'columns', 'session']).isRequired,
  };

  titleId = `emoji-mute-load-notice-title-${noticeSequence += 1}`;

  render () {
    const notice = this.context;
    const { placement } = this.props;

    if (!notice) {
      return null;
    }

    const boot = notice.boot;
    const visible = boot === 'error' || boot === 'ignored' || boot === 'session-changed';

    if (!visible) {
      return null;
    }

    if (placement === 'session') {
      if (boot !== 'session-changed') {
        return null;
      }
    } else if (boot === 'session-changed') {
      return null;
    }

    const failure = notice.failure;
    const session = boot === 'session-changed';
    const ignored = boot === 'ignored';
    const unauthorized = !session && !ignored && failure === 'unauthorized';
    const forbidden = !session && !ignored && failure === 'forbidden';
    const allowRetry = boot === 'error' && !unauthorized && !forbidden;
    const allowIgnore = boot === 'error';
    const allowDisable = !session;
    const allowSignIn = unauthorized;
    const role = ignored ? 'status' : 'alert';
    let title = <FormattedMessage id='emoji_mutes.notice_title' defaultMessage="Couldn't load emoji mutes" />;
    let body = <FormattedMessage id='emoji_mutes.notice_body' defaultMessage='Emoji stay hidden until the settings check finishes. You can keep using everything else.' />;

    if (session) {
      title = <FormattedMessage id='emoji_mutes.notice_session_title' defaultMessage='Reload to switch accounts safely' />;
      body = <FormattedMessage id='emoji_mutes.session_changed' defaultMessage='Your account changed. Reload to protect your emoji mute settings.' />;
    } else if (ignored) {
      title = <FormattedMessage id='emoji_mutes.notice_ignored_title' defaultMessage='Emoji muting is ignored in this tab' />;
      body = <FormattedMessage id='emoji_mutes.bootstrap_ignored' defaultMessage='Emoji muting is ignored in this tab for this account. Every emoji is visible, including ones you muted, until you reload or switch accounts.' />;
    } else if (unauthorized) {
      title = <FormattedMessage id='emoji_mutes.notice_unauthorized_title' defaultMessage='Sign in again to check emoji mutes' />;
      body = <FormattedMessage id='emoji_mutes.bootstrap_unauthorized' defaultMessage='Your session expired. Reload and sign in again. Emoji stay hidden until mute settings can be verified.' />;
    } else if (forbidden) {
      title = <FormattedMessage id='emoji_mutes.notice_forbidden_title' defaultMessage='Emoji mutes can’t be read' />;
      body = <FormattedMessage id='emoji_mutes.bootstrap_forbidden' defaultMessage='This account cannot read emoji mute settings. Emoji stay hidden until you ignore this view or turn the feature off.' />;
    }

    const primaryLabel = allowSignIn
      ? <FormattedMessage id='emoji_mutes.bootstrap_sign_in' defaultMessage='Reload and sign in' />
      : <FormattedMessage id='emoji_mutes.notice_retry' defaultMessage='Try again' />;
    const primaryAction = allowSignIn ? notice.onReload : notice.onRetry;
    const showPrimary = allowRetry || allowSignIn || session;
    const singleAction = showPrimary && !allowIgnore;

    return (
      <div className='emoji-mute-load-notice' role={role} data-placement={placement} aria-labelledby={this.titleId}>
        <div className='emoji-mute-load-notice__title'>
          <span className='emoji-mute-load-notice__icon' aria-hidden='true'>!</span>
          <strong id={this.titleId}>{title}</strong>
        </div>
        <p className='emoji-mute-load-notice__body'>{body}</p>
        {showPrimary && (
          <div className={singleAction ? 'emoji-mute-load-notice__actions emoji-mute-load-notice__actions--single' : 'emoji-mute-load-notice__actions'}>
            <button type='button' className='emoji-mute-load-notice__action emoji-mute-load-notice__action--primary' onClick={primaryAction}>
              {session ? <FormattedMessage id='emoji_mutes.session_reload' defaultMessage='Reload the page' /> : primaryLabel}
            </button>
            {allowIgnore && (
              <button type='button' className='emoji-mute-load-notice__action emoji-mute-load-notice__action--ignore' onClick={notice.onIgnore}>
                <FormattedMessage id='emoji_mutes.notice_ignore' defaultMessage='Ignore this time' />
              </button>
            )}
          </div>
        )}
        {!showPrimary && allowIgnore && (
          <div className='emoji-mute-load-notice__actions emoji-mute-load-notice__actions--single'>
            <button type='button' className='emoji-mute-load-notice__action emoji-mute-load-notice__action--ignore' onClick={notice.onIgnore}>
              <FormattedMessage id='emoji_mutes.notice_ignore' defaultMessage='Ignore this time' />
            </button>
          </div>
        )}
        {allowDisable && (
          <button type='button' className='emoji-mute-load-notice__disable' onClick={notice.onDisable} disabled={notice.preferenceSaving} aria-busy={notice.preferenceSaving ? 'true' : 'false'}>
            <FormattedMessage id='emoji_mutes.notice_disable' defaultMessage='Turn the feature off' />
          </button>
        )}
        {allowIgnore && (
          <p className='emoji-mute-load-notice__note'>
            <FormattedMessage id='emoji_mutes.notice_ignore_warning' defaultMessage='Ignoring this also shows emoji you muted.' />
          </p>
        )}
        {notice.preferenceError && (
          <p className='emoji-mute-load-notice__save-error' role='alert'>
            <FormattedMessage id='emoji_mutes.bootstrap_disable_failed' defaultMessage='Emoji muting stayed on because the setting could not be saved.' />
          </p>
        )}
      </div>
    );
  }

}

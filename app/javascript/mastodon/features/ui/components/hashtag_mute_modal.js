import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { connect } from 'react-redux';
import { defineMessages, injectIntl, FormattedMessage } from 'react-intl';
import { Link } from 'react-router-dom';
import Button from '../../../components/button';
import { closeModal } from '../../../actions/modal';
import { fetchFilters } from '../../../actions/filters';
import { muteHashtag, unmuteHashtag, updateHashtagMute } from '../../../actions/hashtag_mutes';
import { HASHTAG_MUTE_CONTEXTS, HASHTAG_MUTE_DURATIONS, findHashtagMute } from '../../../utils/hashtag_mute';

const messages = defineMessages({
  minutes: { id: 'intervals.full.minutes', defaultMessage: '{number, plural, one {# minute} other {# minutes}}' },
  hours: { id: 'intervals.full.hours', defaultMessage: '{number, plural, one {# hour} other {# hours}}' },
  days: { id: 'intervals.full.days', defaultMessage: '{number, plural, one {# day} other {# days}}' },
  indefinite: { id: 'mute_modal.indefinite', defaultMessage: 'Indefinite' },
  title: { id: 'hashtag_mute.title', defaultMessage: 'Mute #{name}?' },
  explanation: { id: 'hashtag_mute.explanation', defaultMessage: 'Posts that carry this hashtag exactly are hidden. The posts and the tag stay where they are. A longer tag, ordinary text, and the same text inside a URL are not this hashtag.' },
  duration: { id: 'hashtag_mute.duration', defaultMessage: 'Duration' },
  currentUntil: { id: 'hashtag_mute.current_until', defaultMessage: 'Currently muted until {time}. The duration above starts from now.' },
  currentIndefinite: { id: 'hashtag_mute.current_indefinite', defaultMessage: 'Currently muted with no end time.' },
  currentExpired: { id: 'hashtag_mute.current_expired', defaultMessage: 'This mute has expired, so matching posts are visible again.' },
  contextsLabel: { id: 'hashtag_mute.contexts_label', defaultMessage: 'Applies in' },
  home: { id: 'hashtag_mute.context.home', defaultMessage: 'Home and lists' },
  notifications: { id: 'hashtag_mute.context.notifications', defaultMessage: 'Notifications' },
  public: { id: 'hashtag_mute.context.public', defaultMessage: 'Public and other timelines' },
  thread: { id: 'hashtag_mute.context.thread', defaultMessage: 'Conversations' },
  account: { id: 'hashtag_mute.context.account', defaultMessage: 'Profiles' },
  scopeNote: { id: 'hashtag_mute.scope_note', defaultMessage: 'Muting again changes the duration and keeps these places. A new mute applies in every place.' },
  settings: { id: 'hashtag_mute.settings', defaultMessage: 'Change where this applies' },
  confirm: { id: 'hashtag_mute.confirm', defaultMessage: 'Mute' },
  update: { id: 'hashtag_mute.update', defaultMessage: 'Update mute' },
  unmute: { id: 'hashtag_mute.unmute', defaultMessage: 'Unmute' },
  cancel: { id: 'hashtag_mute.cancel', defaultMessage: 'Cancel' },
});

const CONTEXT_MESSAGES = {
  home: messages.home,
  notifications: messages.notifications,
  public: messages.public,
  thread: messages.thread,
  account: messages.account,
};

const DURATION_LABELS = {
  300: [messages.minutes, 5],
  1800: [messages.minutes, 30],
  3600: [messages.hours, 1],
  7200: [messages.hours, 2],
  10800: [messages.hours, 3],
  21600: [messages.hours, 6],
  86400: [messages.days, 1],
  259200: [messages.days, 3],
  604800: [messages.days, 7],
};

const mapStateToProps = (state, { hashtag }) => ({
  hashtag,
  existing: findHashtagMute(state.get('filters'), hashtag),
});

const mapDispatchToProps = dispatch => ({
  onLoad() {
    return dispatch(fetchFilters());
  },

  onClose() {
    dispatch(closeModal());
  },

  onMute(name, expiresIn) {
    return dispatch(muteHashtag(name, expiresIn));
  },

  onUpdate(id, expiresIn) {
    return dispatch(updateHashtagMute(id, expiresIn));
  },

  onUnmute(id) {
    return dispatch(unmuteHashtag(id));
  },
});

class HashtagMuteModal extends React.PureComponent {

  static propTypes = {
    hashtag: PropTypes.string.isRequired,
    existing: ImmutablePropTypes.map,
    intl: PropTypes.object.isRequired,
    onLoad: PropTypes.func.isRequired,
    onClose: PropTypes.func.isRequired,
    onMute: PropTypes.func.isRequired,
    onUpdate: PropTypes.func.isRequired,
    onUnmute: PropTypes.func.isRequired,
  };

  state = {
    duration: 0,
    ready: false,
    submitting: false,
  };

  componentDidMount() {
    const ready = Promise.resolve(this.props.onLoad()).then(this.markReady, this.markReady);

    if (this.durationSelect) {
      this.durationSelect.focus();
    }

    return ready;
  }

  markReady = () => {
    this.setState({ ready: true });
  };

  setDurationSelect = (node) => {
    this.durationSelect = node;
  };

  handleDuration = (event) => {
    this.setState({ duration: Number(event.target.value) });
  };

  contexts() {
    const { existing } = this.props;
    const saved = existing && existing.get('context');
    const values = saved && saved.toArray ? saved.toArray() : HASHTAG_MUTE_CONTEXTS;

    return values.filter(context => HASHTAG_MUTE_CONTEXTS.indexOf(context) !== -1);
  }

  handleConfirm = () => {
    const { existing, hashtag, onMute, onUpdate, onClose } = this.props;
    const request = existing
      ? onUpdate(existing.get('id'), this.state.duration)
      : onMute(hashtag, this.state.duration);

    this.setState({ submitting: true });

    Promise.resolve(request).then(() => {
      onClose();
    }).catch(() => {
      this.setState({ submitting: false });
    });
  };

  handleUnmute = () => {
    const { existing, onUnmute, onClose } = this.props;

    if (!existing) {
      return;
    }

    this.setState({ submitting: true });

    Promise.resolve(onUnmute(existing.get('id'))).then(() => {
      onClose();
    }).catch(() => {
      this.setState({ submitting: false });
    });
  };

  renderCurrent() {
    const { existing, intl } = this.props;

    if (!existing) {
      return null;
    }

    const expiresAt = existing.get('expires_at');

    if (!expiresAt) {
      return <p>{intl.formatMessage(messages.currentIndefinite)}</p>;
    }

    if (expiresAt <= Date.now()) {
      return <p>{intl.formatMessage(messages.currentExpired)}</p>;
    }

    return (
      <p>
        {intl.formatMessage(messages.currentUntil, {
          time: intl.formatTime(expiresAt, { year: 'numeric', month: 'short', day: 'numeric', hour: 'numeric', minute: 'numeric' }),
        })}
      </p>
    );
  }

  render() {
    const { hashtag, existing, intl, onClose } = this.props;
    const { duration, ready, submitting } = this.state;
    const busy = !ready || submitting;

    return (
      <div className='modal-root__modal mute-modal' role='dialog' aria-modal='true' aria-labelledby='hashtag-mute-title'>
        <div className='mute-modal__container'>
          <p id='hashtag-mute-title'>
            <strong>{intl.formatMessage(messages.title, { name: hashtag })}</strong>
          </p>
          <p className='mute-modal__explanation'>
            {intl.formatMessage(messages.explanation)}
          </p>
          {this.renderCurrent()}
          <div>
            <label htmlFor='hashtag-mute-duration'>
              <FormattedMessage id='hashtag_mute.duration' defaultMessage='Duration' />
              {': '}
            </label>
            {/* eslint-disable-next-line jsx-a11y/no-onchange */}
            <select id='hashtag-mute-duration' ref={this.setDurationSelect} value={String(duration)} onChange={this.handleDuration}>
              {HASHTAG_MUTE_DURATIONS.map(seconds => (
                <option key={seconds} value={String(seconds)}>
                  {seconds === 0 ? intl.formatMessage(messages.indefinite) : intl.formatMessage(DURATION_LABELS[seconds][0], { number: DURATION_LABELS[seconds][1] })}
                </option>
              ))}
            </select>
          </div>
          <p id='hashtag-mute-contexts-label'>{intl.formatMessage(messages.contextsLabel)}</p>
          <ul className='mute-modal__contexts' aria-labelledby='hashtag-mute-contexts-label'>
            {this.contexts().map(context => (
              <li key={context}>{intl.formatMessage(CONTEXT_MESSAGES[context])}</li>
            ))}
          </ul>
          <p className='mute-modal__explanation'>{intl.formatMessage(messages.scopeNote)}</p>
          <Link className='mute-modal__settings-link' to='/settings/filters' onClick={onClose}>
            {intl.formatMessage(messages.settings)}
          </Link>
        </div>
        <div className='mute-modal__action-bar'>
          <Button onClick={onClose} className='mute-modal__cancel-button' disabled={submitting}>
            {intl.formatMessage(messages.cancel)}
          </Button>
          {existing && (
            <Button onClick={this.handleUnmute} className='mute-modal__cancel-button' disabled={busy}>
              {intl.formatMessage(messages.unmute)}
            </Button>
          )}
          <Button onClick={this.handleConfirm} disabled={busy}>
            {intl.formatMessage(existing ? messages.update : messages.confirm)}
          </Button>
        </div>
      </div>
    );
  }

}

export default injectIntl(connect(mapStateToProps, mapDispatchToProps)(HashtagMuteModal));

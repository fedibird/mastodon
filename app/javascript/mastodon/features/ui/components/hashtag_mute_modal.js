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
import { projectHashtagLabel, registerHashtagDialogConcealer, unprojectHashtagSentence } from 'mastodon/features/emoji/hashtag_menu_names';
import { recordEmojiMuteText } from 'mastodon/features/emoji/emoji_mute_live_dom';
import { rememberEmojiMuteTextSource } from 'mastodon/features/emoji/emoji_mute_sources';
import { emojiMuteTextIndexFromState, SUPPRESS_UNVERIFIED_INDEX, suppressUnicodeEmoji, UNVERIFIED_EMOJI_PLACEHOLDER } from 'mastodon/features/emoji/emoji_mute_text';

const messages = defineMessages({
  minutes: { id: 'intervals.full.minutes', defaultMessage: '{number, plural, one {# minute} other {# minutes}}' },
  hours: { id: 'intervals.full.hours', defaultMessage: '{number, plural, one {# hour} other {# hours}}' },
  days: { id: 'intervals.full.days', defaultMessage: '{number, plural, one {# day} other {# days}}' },
  indefinite: { id: 'mute_modal.indefinite', defaultMessage: 'Indefinite' },
  title: { id: 'hashtag_mute.title', defaultMessage: 'Mute #{name}?' },
  explanation: { id: 'hashtag_mute.explanation', defaultMessage: 'Posts that carry this hashtag exactly are hidden. The posts and the tag stay where they are. A longer tag, ordinary text, and the same text inside a URL are not this hashtag.' },
  duration: { id: 'hashtag_mute.duration', defaultMessage: 'Duration' },
  currentUntil: { id: 'hashtag_mute.current_until', defaultMessage: 'Currently muted until {time}.' },
  currentIndefinite: { id: 'hashtag_mute.current_indefinite', defaultMessage: 'Currently muted with no end time.' },
  currentExpired: { id: 'hashtag_mute.current_expired', defaultMessage: 'This mute has expired, so matching posts are visible again.' },
  keepDuration: { id: 'hashtag_mute.keep_duration', defaultMessage: 'Don\'t change' },
  keepHint: { id: 'hashtag_mute.keep_hint', defaultMessage: 'Don\'t change leaves the current end time. Any other choice starts from now and hides matching posts.' },
  restoreHide: { id: 'hashtag_mute.restore_hide', defaultMessage: 'This rule is set to warn. Updating it hides matching posts again.' },
  expiredChoice: { id: 'hashtag_mute.expired_choice', defaultMessage: 'The previous end time has passed. Choose a new duration before muting again.' },
  chooseDuration: { id: 'hashtag_mute.choose_duration', defaultMessage: 'Choose a duration' },
  loading: { id: 'hashtag_mute.loading', defaultMessage: 'Loading the current mute settings…' },
  loadError: { id: 'hashtag_mute.load_error', defaultMessage: 'The current mute settings could not be loaded. Nothing was changed.' },
  loadStale: { id: 'hashtag_mute.load_stale', defaultMessage: 'A newer request replaced this one. Load the settings again before muting.' },
  retry: { id: 'hashtag_mute.retry', defaultMessage: 'Try again' },
  contextsLabel: { id: 'hashtag_mute.contexts_label', defaultMessage: 'Applies in' },
  home: { id: 'hashtag_mute.context.home', defaultMessage: 'Home and lists' },
  notifications: { id: 'hashtag_mute.context.notifications', defaultMessage: 'Notifications' },
  public: { id: 'hashtag_mute.context.public', defaultMessage: 'Public and other timelines' },
  thread: { id: 'hashtag_mute.context.thread', defaultMessage: 'Conversations' },
  account: { id: 'hashtag_mute.context.account', defaultMessage: 'Profiles' },
  scopeNote: { id: 'hashtag_mute.scope_note', defaultMessage: 'Updating keeps these places. A new mute applies in every place.' },
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
  // The shared expiry timer only changes this count. Reading it here makes an
  // open dialog render again at the end time, while Date.now() still decides
  // whether the saved mute has ended.
  filterClock: state.get('filterClock') || 0,
  emojiMuteTextIndex: emojiMuteTextIndexFromState(state),
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

  onUpdate(id, expiresIn, options) {
    return dispatch(updateHashtagMute(id, expiresIn, options));
  },

  onUnmute(id) {
    return dispatch(unmuteHashtag(id));
  },
});

class HashtagMuteModal extends React.PureComponent {

  static propTypes = {
    hashtag: PropTypes.string.isRequired,
    existing: ImmutablePropTypes.map,
    filterClock: PropTypes.number,
    intl: PropTypes.object.isRequired,
    onLoad: PropTypes.func.isRequired,
    onClose: PropTypes.func.isRequired,
    onMute: PropTypes.func.isRequired,
    onUpdate: PropTypes.func.isRequired,
    onUnmute: PropTypes.func.isRequired,
    emojiMuteTextIndex: PropTypes.object,
    imageRanges: PropTypes.array,
  };

  imageRanges() {
    const ranges = this.props.imageRanges;

    if (!ranges) {
      return [];
    }

    return typeof ranges.toJS === 'function' ? ranges.toJS() : ranges;
  }

  concealForSuppress = sink => {
    const heading = document.getElementById('hashtag-mute-title');

    if (!heading || !heading.isConnected || !this.props.hashtag) {
      return;
    }

    const ranges = this.imageRanges();
    const raw = this.props.hashtag;
    const rendered = projectHashtagLabel(raw, ranges, this.props.emojiMuteTextIndex);
    const shown = projectHashtagLabel(raw, ranges, SUPPRESS_UNVERIFIED_INDEX);
    const label = shown !== '' ? shown : UNVERIFIED_EMOJI_PLACEHOLDER;
    const needles = [];

    [rendered, raw, suppressUnicodeEmoji(rendered), suppressUnicodeEmoji(raw)].forEach(value => {
      if (value && value !== label && needles.indexOf(value) === -1) {
        needles.push(value);
      }
    });

    if (needles.length === 0) {
      return;
    }

    const owner = heading.ownerDocument || document;
    const walker = owner.createTreeWalker(heading, NodeFilter.SHOW_TEXT, null);
    let node = walker.nextNode();

    while (node) {
      const value = node.nodeValue || '';
      let next = value;

      needles.forEach(needle => {
        if (next.includes(needle)) {
          next = next.split(needle).join(label);
        }
      });

      if (next !== value) {
        const noted = sink && sink.find(record => record.kind === 'text' && record.node === node);
        const base = noted && typeof noted.value === 'string' ? noted.value : value;
        const logical = unprojectHashtagSentence(base, rendered, raw);

        rememberEmojiMuteTextSource(node, logical);

        if (noted) {
          noted.value = logical;
        } else {
          recordEmojiMuteText(sink, node);
        }

        node.nodeValue = next;
      }

      node = walker.nextNode();
    }
  }

  visibleHashtag() {
    const shown = projectHashtagLabel(this.props.hashtag, this.imageRanges(), this.props.emojiMuteTextIndex);

    if (typeof shown !== 'string') {
      return this.props.hashtag;
    }

    // An empty replacement is a real projection. Saving still uses the original tag.
    return shown !== '' ? shown : UNVERIFIED_EMOJI_PLACEHOLDER;
  }

  state = {
    duration: null,
    durationChosen: false,
    loadState: 'loading',
    submitting: false,
  };

  componentDidMount() {
    this.unregisterDialogConcealer = registerHashtagDialogConcealer(this.concealForSuppress);
    return this.loadFilters();
  }

  componentWillUnmount() {
    if (this.unregisterDialogConcealer) {
      this.unregisterDialogConcealer();
    }
  }

  componentDidUpdate(_prevProps, prevState) {
    if (this.state.loadState === 'ready' && prevState.loadState !== 'ready' && this.durationSelect) {
      this.durationSelect.focus();
    }
  }

  loadFilters = () => {
    this.setState({ loadState: 'loading', submitting: false, durationChosen: false, duration: null });

    return Promise.resolve(this.props.onLoad()).then(result => {
      if (result && result.ok) {
        this.setState({ loadState: 'ready' });
        return;
      }

      this.setState({ loadState: result && result.stale ? 'stale' : 'error' });
    }, () => {
      this.setState({ loadState: 'error' });
    });
  };

  setDurationSelect = (node) => {
    this.durationSelect = node;
  };

  handleDuration = (event) => {
    const { value } = event.target;

    if (value === '') {
      this.setState({ durationChosen: false, duration: null });
      return;
    }

    this.setState({
      durationChosen: true,
      duration: Number(value),
    });
  };

  expired(existing = this.props.existing, now = Date.now()) {
    if (!existing) {
      return false;
    }

    const expiresAt = existing.get('expires_at');

    return !!expiresAt && expiresAt <= now;
  }

  offersKeepDuration() {
    return !!(this.props.existing && !this.expired());
  }

  keepsCurrentDuration() {
    return this.offersKeepDuration() && !this.state.durationChosen;
  }

  resolvedDuration() {
    if (this.state.durationChosen) {
      return this.state.duration;
    }

    if (this.keepsCurrentDuration()) {
      return null;
    }

    if (this.props.existing) {
      return null;
    }

    return 0;
  }

  canConfirm() {
    if (this.state.loadState !== 'ready' || this.state.submitting) {
      return false;
    }

    if (this.expired() && !this.state.durationChosen) {
      return false;
    }

    return this.resolvedDuration() !== null || this.keepsCurrentDuration();
  }

  contexts() {
    const { existing } = this.props;
    const saved = existing && existing.get('context');
    const values = saved && saved.toArray ? saved.toArray() : HASHTAG_MUTE_CONTEXTS;

    return values.filter(context => HASHTAG_MUTE_CONTEXTS.indexOf(context) !== -1);
  }

  handleConfirm = () => {
    const { existing, hashtag, onMute, onUpdate, onClose } = this.props;

    if (this.expired() && !this.state.durationChosen) {
      this.forceUpdate();
      return;
    }

    if (!this.canConfirm()) {
      return;
    }

    const duration = this.resolvedDuration();
    const request = existing
      ? onUpdate(existing.get('id'), duration, { preserveExpiry: duration === null })
      : onMute(hashtag, duration);

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
    const { existing, intl, onClose } = this.props;
    const { loadState, submitting } = this.state;
    const ready = loadState === 'ready';
    const duration = this.resolvedDuration();
    // filterClock is not a timestamp. Mentioning it keeps this render tied to
    // the expiry tick; the comparison below uses the current time.
    const expired = ready && this.props.filterClock >= 0 && this.expired();
    const keepDuration = ready && this.keepsCurrentDuration();
    const offerKeep = ready && this.offersKeepDuration();
    const warns = ready && existing && existing.get('filter_action') !== 'hide' && !expired;

    return (
      <div className='modal-root__modal mute-modal' role='dialog' aria-modal='true' aria-labelledby='hashtag-mute-title'>
        <div className='mute-modal__container'>
          <p id='hashtag-mute-title'>
            <strong>{intl.formatMessage(messages.title, { name: this.visibleHashtag() })}</strong>
          </p>
          <p className='mute-modal__explanation'>
            {intl.formatMessage(messages.explanation)}
          </p>
          {loadState === 'loading' && <p className='mute-modal__explanation'>{intl.formatMessage(messages.loading)}</p>}
          {loadState === 'error' && <p className='mute-modal__explanation' role='alert'>{intl.formatMessage(messages.loadError)}</p>}
          {loadState === 'stale' && <p className='mute-modal__explanation' role='alert'>{intl.formatMessage(messages.loadStale)}</p>}
          {(loadState === 'error' || loadState === 'stale') && (
            <Button onClick={this.loadFilters}>{intl.formatMessage(messages.retry)}</Button>
          )}
          {ready && this.renderCurrent()}
          {ready && (
            <div>
              <label htmlFor='hashtag-mute-duration'>
                <FormattedMessage id='hashtag_mute.duration' defaultMessage='Duration' />
                {': '}
              </label>
              {/* eslint-disable-next-line jsx-a11y/no-onchange */}
              <select id='hashtag-mute-duration' ref={this.setDurationSelect} value={duration === null ? '' : String(duration)} onChange={this.handleDuration}>
                {offerKeep && (
                  <option value=''>{intl.formatMessage(messages.keepDuration)}</option>
                )}
                {expired && <option value='' disabled>{intl.formatMessage(messages.chooseDuration)}</option>}
                {HASHTAG_MUTE_DURATIONS.map(seconds => (
                  <option key={seconds} value={String(seconds)}>
                    {seconds === 0 ? intl.formatMessage(messages.indefinite) : intl.formatMessage(DURATION_LABELS[seconds][0], { number: DURATION_LABELS[seconds][1] })}
                  </option>
                ))}
              </select>
            </div>
          )}
          {keepDuration && <p className='mute-modal__explanation'>{intl.formatMessage(messages.keepHint)}</p>}
          {expired && <p className='mute-modal__explanation'>{intl.formatMessage(messages.expiredChoice)}</p>}
          {warns && <p className='mute-modal__explanation'>{intl.formatMessage(messages.restoreHide)}</p>}
          {ready && <p id='hashtag-mute-contexts-label'>{intl.formatMessage(messages.contextsLabel)}</p>}
          {ready && (
            <ul className='mute-modal__contexts' aria-labelledby='hashtag-mute-contexts-label'>
              {this.contexts().map(context => (
                <li key={context}>{intl.formatMessage(CONTEXT_MESSAGES[context])}</li>
              ))}
            </ul>
          )}
          {ready && <p className='mute-modal__explanation'>{intl.formatMessage(messages.scopeNote)}</p>}
          {ready && (
            <Link className='mute-modal__settings-link' to='/settings/filters' onClick={onClose}>
              {intl.formatMessage(messages.settings)}
            </Link>
          )}
        </div>
        <div className='mute-modal__action-bar'>
          <Button onClick={onClose} className='mute-modal__cancel-button' disabled={submitting}>
            {intl.formatMessage(messages.cancel)}
          </Button>
          {ready && existing && (
            <Button onClick={this.handleUnmute} className='mute-modal__cancel-button' disabled={submitting}>
              {intl.formatMessage(messages.unmute)}
            </Button>
          )}
          <Button onClick={this.handleConfirm} disabled={!this.canConfirm()}>
            {intl.formatMessage(existing ? messages.update : messages.confirm)}
          </Button>
        </div>
      </div>
    );
  }

}

export default injectIntl(connect(mapStateToProps, mapDispatchToProps)(HashtagMuteModal));

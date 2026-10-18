import React from 'react';
import PropTypes from 'prop-types';
import { defineMessages, injectIntl } from 'react-intl';
import {
  JUMP_MODE,
  buildJumpQuery,
  formatUtcOffset,
  interpretLocalDateTime,
  jumpModeState,
  localTimeZoneName,
} from '../../../timeline_jump/model';
import { SEEK_PREFERENCE } from '../../../timeline_seek/constants';
import { seekSourceFromContract } from '../../../timeline_seek/query';
import {
  createTextSearchState,
  identityChangeResets,
  publicResults,
  runNextPage,
  runSearchSession,
  sessionView,
  textSearchIdentity,
  textSearchIdentityKey,
} from '../../../timeline_text_search/session';

const messages = defineMessages({
  title: { id: 'timeline.jump', defaultMessage: 'Find in this timeline' },
  close: { id: 'timeline.jump_close', defaultMessage: 'Close timeline search' },
  mode: { id: 'timeline.jump_mode', defaultMessage: 'What to find' },
  date: { id: 'timeline.jump_date', defaultMessage: 'Date' },
  account: { id: 'timeline.jump_account', defaultMessage: 'Account' },
  status: { id: 'timeline.jump_status', defaultMessage: 'Post' },
  text: { id: 'timeline.jump_text', defaultMessage: 'Text' },
  preference: { id: 'timeline.jump_preference', defaultMessage: 'Which post' },
  nearest: { id: 'timeline.jump_nearest', defaultMessage: 'Nearest' },
  before: { id: 'timeline.jump_before', defaultMessage: 'Before' },
  after: { id: 'timeline.jump_after', defaultMessage: 'After' },
  when: { id: 'timeline.jump_when', defaultMessage: 'Date and time' },
  accountQuery: { id: 'timeline.jump_account_query', defaultMessage: 'Account' },
  statusId: { id: 'timeline.jump_status_id', defaultMessage: 'Post ID' },
  go: { id: 'timeline.jump_go', defaultMessage: 'Jump' },
  busy: { id: 'timeline.jump_busy', defaultMessage: 'Looking…' },
  accounts: { id: 'timeline.jump_accounts', defaultMessage: 'Matching accounts' },
  textUnsupported: { id: 'timeline.jump_text_unsupported', defaultMessage: 'This timeline cannot be searched by text.' },
  textQuery: { id: 'timeline.jump_text_query', defaultMessage: 'Text' },
  textSearch: { id: 'timeline.jump_text_search', defaultMessage: 'Search' },
  textHint: { id: 'timeline.jump_text_hint', defaultMessage: 'Searches the existing full-text index, then keeps only posts that are in this timeline. The words are sent in the search request URL and can be stored in network logs. This screen does not save them.' },
  textRedis: { id: 'timeline.jump_text_redis', defaultMessage: 'Only the latest 2000 posts can be confirmed. A hit outside that range stays unchecked. It is not marked absent.' },
  textPartial: { id: 'timeline.jump_text_partial', defaultMessage: 'Some hits are outside the retained range. They are hidden here and are not marked absent.' },
  textRange: { id: 'timeline.jump_text_range', defaultMessage: 'Checked {candidates} search hits across {pages} pages. {members} are in this timeline.' },
  textUncertain: { id: 'timeline.jump_text_uncertain', defaultMessage: 'Nothing in the checked range. An empty search page can also mean the index is off or unreachable, so this is not a full-history miss.' },
  textExhausted: { id: 'timeline.jump_text_exhausted', defaultMessage: 'The search returned no further hits for this query.' },
  textLimit: { id: 'timeline.jump_text_limit', defaultMessage: 'Stopped at the limit of {candidates} hits or {pages} pages. Later hits were not checked.' },
  textMore: { id: 'timeline.jump_text_more', defaultMessage: 'Check the next page' },
  textResults: { id: 'timeline.jump_text_results', defaultMessage: 'Posts in this timeline' },
  textNext: { id: 'timeline.jump_text_next', defaultMessage: 'Next result' },
  textPrevious: { id: 'timeline.jump_text_previous', defaultMessage: 'Previous result' },
  textEmpty: { id: 'timeline.jump_text_empty', defaultMessage: 'None of the checked hits are in this timeline.' },
  textRecheck: { id: 'timeline.jump_text_recheck', defaultMessage: 'A post can change before the jump. The jump checks membership again.' },
  textChecking: { id: 'timeline.jump_text_checking', defaultMessage: 'Checking which hits are in this timeline…' },
  textMissing: { id: 'timeline.jump_text_missing', defaultMessage: 'Enter text to search.' },
  shiftEnter: { id: 'timeline.jump_shift_enter', defaultMessage: 'Moving between text results is not available.' },
  dateHint: { id: 'timeline.jump_date_hint', defaultMessage: '{timeZone} ({offset}). Local time is sent with that offset. A date alone is not midnight UTC. The match is an approximate id-order probe.' },
  dateRedis: { id: 'timeline.jump_date_redis', defaultMessage: 'Only the latest 2000 posts in this timeline can be probed.' },
  accountHint: { id: 'timeline.jump_account_hint', defaultMessage: 'Jumps to the newest probed post from the account (20 posts). This is not a full history.' },
  accountUnsupported: { id: 'timeline.jump_account_unsupported', defaultMessage: 'This timeline cannot be jumped by account.' },
  statusHint: { id: 'timeline.jump_status_hint', defaultMessage: 'Jumps to a post only when it belongs to this timeline.' },
  statusRedis: { id: 'timeline.jump_status_redis', defaultMessage: 'Posts older than the latest 2000 are outside this timeline’s retained history.' },
  moved: { id: 'timeline.jump_moved', defaultMessage: 'Moved in history.' },
  movedPrecision: { id: 'timeline.jump_moved_precision', defaultMessage: 'Moved in history ({precision}).' },
  pendingScroll: { id: 'timeline.jump_pending_scroll', defaultMessage: 'Opened the history window. Waiting for the row.' },
  notInSource: { id: 'timeline.jump_not_in_source', defaultMessage: 'Nothing in this timeline matched.' },
  notVisible: { id: 'timeline.jump_not_visible', defaultMessage: 'A filter or permission is hiding that post.' },
  notFound: { id: 'timeline.jump_not_found', defaultMessage: 'Nothing matched in the checked range.' },
  outsideRetained: { id: 'timeline.jump_outside_retained', defaultMessage: 'Outside the latest 2000 posts retained for this timeline.' },
  probeExhausted: { id: 'timeline.jump_probe_exhausted', defaultMessage: 'The probe stopped before a match. The timeline may continue past that budget.' },
  splitBoundary: { id: 'timeline.jump_split_boundary', defaultMessage: 'That post is on the live side of the split. History was not moved.' },
  filtered: { id: 'timeline.jump_filtered', defaultMessage: 'The post is filtered out. History was left in place.' },
  notLoaded: { id: 'timeline.jump_not_loaded', defaultMessage: 'The row was not on screen. History was left in place.' },
  userScroll: { id: 'timeline.jump_user_scroll', defaultMessage: 'Scrolling stopped the position adjustment.' },
  cancelled: { id: 'timeline.jump_cancelled', defaultMessage: 'Cancelled.' },
  stale: { id: 'timeline.jump_stale', defaultMessage: 'Ignored an outdated result.' },
  network: { id: 'timeline.jump_network', defaultMessage: 'The request failed.' },
  unsupported: { id: 'timeline.jump_unsupported', defaultMessage: 'This jump is not available.' },
  unavailable: { id: 'timeline.jump_unavailable', defaultMessage: 'Could not jump.' },
  splitUnavailable: { id: 'timeline.jump_split_unavailable', defaultMessage: 'History is unavailable while another column is split.' },
  missingTime: { id: 'timeline.jump_missing_time', defaultMessage: 'Choose a date and time.' },
  dateOnly: { id: 'timeline.jump_date_only', defaultMessage: 'Choose a time as well. A date alone is not treated as midnight UTC.' },
  dst: { id: 'timeline.jump_dst', defaultMessage: 'That local time does not exist.' },
  invalidTime: { id: 'timeline.jump_invalid_time', defaultMessage: 'Enter a date and time with a timezone offset.' },
  invalidId: { id: 'timeline.jump_invalid_id', defaultMessage: 'Enter the post or account id as a decimal string.' },
  accountRequired: { id: 'timeline.jump_account_required', defaultMessage: 'Choose an account from the list.' },
  accountEmpty: { id: 'timeline.jump_account_empty', defaultMessage: 'No matching accounts.' },
  accountFailed: { id: 'timeline.jump_account_failed', defaultMessage: 'Account lookup failed.' },
  preferenceUnmet: { id: 'timeline.jump_preference_unmet', defaultMessage: 'The requested before/after side was not in the probe, so a nearby post was used.' },
});

const REASON_MESSAGE = {
  text_search_not_in_timeline: 'textUnsupported',
  missing_text: 'textMissing',
  shift_enter: 'shiftEnter',
  not_in_source: 'notInSource',
  source_filter: 'notInSource',
  not_visible: 'notVisible',
  viewer_filter: 'notVisible',
  not_found: 'notFound',
  outside_retained_range: 'outsideRetained',
  date_probe_exhausted: 'probeExhausted',
  account_probe_exhausted: 'probeExhausted',
  newer_than_split_boundary: 'splitBoundary',
  filtered: 'filtered',
  not_loaded: 'notLoaded',
  user_scroll: 'userScroll',
  cancelled: 'cancelled',
  stale: 'stale',
  stale_resolve: 'stale',
  stale_window: 'stale',
  session_replaced: 'stale',
  network: 'network',
  unsupported: 'unsupported',
  split_unavailable: 'splitUnavailable',
  split_inactive: 'splitUnavailable',
  window_required: 'unavailable',
  missing_time: 'missingTime',
  date_only_rejected: 'dateOnly',
  nonexistent_local_time: 'dst',
  invalid_time: 'invalidTime',
  timezone_required: 'invalidTime',
  invalid_id: 'invalidId',
  account_required: 'accountRequired',
  search_text_not_accepted: 'textUnsupported',
  personal_is_not_an_account_timeline: 'accountUnsupported',
};

const sourceOf = (contract) => {
  const parsed = seekSourceFromContract(contract);

  return parsed ? parsed.source : null;
};

const accountLabel = (account) => {
  const name = account.display_name || account.acct || account.id;

  return account.acct ? `${name} @${account.acct}` : name;
};

export const jumpResultText = (intl, result) => {
  if (!result) {
    return null;
  }

  if (result.moved) {
    const moved = result.precision && result.precision !== 'exact'
      ? intl.formatMessage(messages.movedPrecision, { precision: result.precision })
      : intl.formatMessage(messages.moved);

    if (result.limitations && result.limitations.indexOf('preference_unmet') !== -1) {
      return `${moved} ${intl.formatMessage(messages.preferenceUnmet)}`;
    }

    return moved;
  }

  if (result.limitations && result.limitations.indexOf('preference_unmet') !== -1 && result.outcome === 'resolved') {
    return intl.formatMessage(messages.preferenceUnmet);
  }

  const key = REASON_MESSAGE[result.reason] || REASON_MESSAGE[result.outcome];

  if (key) {
    return intl.formatMessage(messages[key]);
  }

  if (result.outcome === 'unsupported') {
    return intl.formatMessage(messages.unsupported);
  }

  return intl.formatMessage(messages.unavailable);
};

class TimelineColumnJumpPanel extends React.PureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    contract: PropTypes.object,
    panelId: PropTypes.string.isRequired,
    onSubmit: PropTypes.func.isRequired,
    onSearchAccounts: PropTypes.func,
    onInvalidate: PropTypes.func,
    onClose: PropTypes.func.isRequired,
    accountId: PropTypes.string,
    columnId: PropTypes.string,
    locationKey: PropTypes.string,
    splitSessionId: PropTypes.string,
    onSearchStatuses: PropTypes.func,
    onCheckMembership: PropTypes.func,
    onCancelTextSearch: PropTypes.func,
    onJumpStatus: PropTypes.func,
  };

  state = {
    mode: JUMP_MODE.DATE,
    preference: SEEK_PREFERENCE.NEAREST,
    dateTime: '',
    accountQuery: '',
    accounts: [],
    accountLookup: null,
    selectedAccountId: null,
    statusId: '',
    textQuery: '',
    textResults: [],
    textView: null,
    textIndex: -1,
    notice: null,
    result: null,
    busy: false,
  };

  textSession = createTextSearchState();

  searchQuery = '';

  static getDerivedStateFromProps (props, state) {
    const identity = textSearchIdentity(props);
    const key = textSearchIdentityKey(identity);

    if (state.textIdentityKey === key) {
      return null;
    }

    if (!state.textIdentityKey || !identityChangeResets(state.textIdentity, identity)) {
      return { textIdentityKey: key, textIdentity: identity };
    }

    return {
      textIdentityKey: key,
      textIdentity: identity,
      textQuery: '',
      textResults: [],
      textView: null,
      textIndex: -1,
      busy: false,
      result: null,
      notice: null,
    };
  }

  componentDidMount () {
    if (this.modeNode) {
      this.modeNode.focus();
    }
  }

  componentDidUpdate (prevProps) {
    if (identityChangeResets(textSearchIdentity(prevProps), this.textIdentity())) {
      this.localRequest += 1;
      this.textSession = createTextSearchState();
      this.searchQuery = '';
      this.cancelTextSearch();
    }
  }

  componentWillUnmount () {
    this.unmounted = true;
    this.localRequest += 1;
    this.searchQuery = '';
    this.textSession = createTextSearchState();
    this.cancelTextSearch();

    if (this.accountTimer) {
      clearTimeout(this.accountTimer);
    }
  }

  localRequest = 0;

  setModeNode = (node) => {
    this.modeNode = node;
  };

  invalidate = () => {
    this.localRequest += 1;

    if (this.props.onInvalidate) {
      this.props.onInvalidate();
    }
  };

  textIdentity = () => textSearchIdentity(this.props);

  cancelTextSearch = () => {
    if (this.props.onCancelTextSearch) {
      this.props.onCancelTextSearch();
    }
  };

  clearTextResults = () => {
    this.textSession = createTextSearchState();
    this.searchQuery = '';
    this.setState({
      textResults: [],
      textView: null,
      textIndex: -1,
    });
  };

  isImeEnter = (event) => {
    const native = event.nativeEvent || {};

    return this.composing || event.keyCode === 229 || event.which === 229 || native.isComposing || native.keyCode === 229;
  };

  handleComposition = (event) => {
    const starting = event.type === 'compositionstart';

    this.composing = starting;
    // Safari and Firefox can emit a plain Enter after compositionend.
    // Swallow that one key. A later Enter is a real search or move.
    this.imeJustEnded = !starting;
  };

  handleKeyDown = (event) => {
    if (event.key === 'Escape') {
      event.preventDefault();
      event.stopPropagation();
      this.searchQuery = '';
      this.props.onClose();
      return;
    }

    if (event.key === 'Enter' && (this.isImeEnter(event) || this.imeJustEnded)) {
      event.preventDefault();
      event.stopPropagation();
      this.imeJustEnded = false;
      return;
    }

    if (this.imeJustEnded) {
      this.imeJustEnded = false;
    }

    if (event.key === 'Enter' && event.shiftKey) {
      event.preventDefault();
      event.stopPropagation();

      if (this.state.mode === JUMP_MODE.TEXT) {
        this.moveTextResult(-1);
        return;
      }

      this.setState({ notice: 'shift_enter', result: null });
    }
  };

  handleMode = (event) => {
    this.invalidate();
    this.cancelTextSearch();
    this.textSession = createTextSearchState();
    this.searchQuery = '';
    this.setState({
      mode: event.target.value,
      notice: null,
      result: null,
      accounts: [],
      accountLookup: null,
      textResults: [],
      textView: null,
      textIndex: -1,
      busy: false,
    });
  };

  handlePreference = (event) => {
    this.invalidate();
    this.setState({ preference: event.target.value, result: null, notice: null });
  };

  handleDate = (event) => {
    this.invalidate();
    this.setState({ dateTime: event.target.value, result: null, notice: null });
  };

  handleStatus = (event) => {
    this.invalidate();
    this.setState({ statusId: event.target.value, result: null, notice: null });
  };

  handleAccountQuery = (event) => {
    const accountQuery = event.target.value;

    this.invalidate();
    this.setState({
      accountQuery,
      selectedAccountId: null,
      result: null,
      notice: null,
      accountLookup: null,
    });

    if (this.accountTimer) {
      clearTimeout(this.accountTimer);
    }

    this.accountTimer = setTimeout(() => this.lookupAccounts(accountQuery), 250);
  };

  lookupAccounts = (accountQuery) => {
    const query = accountQuery.trim().replace(/^@/, '');

    if (!query || !this.props.onSearchAccounts) {
      this.setState({ accounts: [], accountLookup: null });
      return;
    }

    const request = this.localRequest;

    this.props.onSearchAccounts(query).then(response => {
      if (this.unmounted || request !== this.localRequest) {
        return;
      }

      const body = response || {};

      if (!body.ok && body.reason === 'cancelled') {
        return;
      }

      this.setState({
        accounts: Array.isArray(body.accounts) ? body.accounts : [],
        accountLookup: body.ok ? 'ready' : (body.reason || 'network'),
      });
    }).catch(() => {
      if (this.unmounted || request !== this.localRequest) {
        return;
      }

      this.setState({ accounts: [], accountLookup: 'network' });
    });
  };

  chooseAccount = (event) => {
    this.invalidate();
    this.setState({
      selectedAccountId: event.currentTarget.getAttribute('data-account-id'),
      result: null,
      notice: null,
    });
  };

  handleTextQuery = (event) => {
    this.localRequest += 1;
    this.cancelTextSearch();
    this.textSession = createTextSearchState();
    this.searchQuery = '';
    this.setState({
      textQuery: event.target.value,
      textResults: [],
      textView: null,
      textIndex: -1,
      result: null,
      notice: null,
      busy: false,
    });
  };

  publishText = (request, outcome) => {
    if (this.unmounted || request !== this.localRequest || !outcome.applied) {
      return;
    }

    this.textSession = outcome.state;
    this.setState({
      busy: false,
      textResults: publicResults(outcome.state),
      textView: sessionView(outcome.state),
    });
  };

  searchText = () => {
    const query = this.state.textQuery.trim();
    const source = sourceOf(this.props.contract);
    const modeState = jumpModeState(source, JUMP_MODE.TEXT);

    if (!query) {
      this.setState({ notice: 'missing_text', result: null });
      return;
    }

    if (!modeState.canSubmit || !this.props.onSearchStatuses || !this.props.onCheckMembership) {
      this.setState({ result: { outcome: 'unsupported', reason: 'text_search_not_in_timeline', moved: false }, notice: null });
      return;
    }

    const request = ++this.localRequest;
    const identity = this.textIdentity();

    this.searchQuery = query;
    this.setState({ busy: true, textResults: [], textView: null, textIndex: -1, result: null, notice: null });
    this.textSession = createTextSearchState();

    runSearchSession({
      state: this.textSession,
      identity,
      search: ({ offset, limit }) => {
        if (request !== this.localRequest || this.searchQuery !== query) {
          return Promise.resolve({ ok: false, reason: 'cancelled', statuses: [], received: 0 });
        }

        return this.props.onSearchStatuses({ q: query, offset, limit });
      },
      membership: (payload) => this.props.onCheckMembership(payload),
      isCurrent: () => request === this.localRequest && !this.unmounted && this.searchQuery === query,
    }).then(outcome => this.publishText(request, outcome)).catch(() => {
      if (this.unmounted || request !== this.localRequest) {
        return;
      }

      this.setState({ busy: false, result: { outcome: 'unavailable', reason: 'network', moved: false } });
    });
  };

  loadMoreText = () => {
    if (!this.props.onSearchStatuses || !this.props.onCheckMembership || this.state.busy) {
      return;
    }

    const query = this.searchQuery;
    const request = ++this.localRequest;
    const identity = this.textIdentity();

    this.setState({ busy: true, notice: null });
    runNextPage({
      state: this.textSession,
      identity,
      search: ({ offset, limit }) => {
        if (request !== this.localRequest || this.searchQuery !== query) {
          return Promise.resolve({ ok: false, reason: 'cancelled', statuses: [], received: 0 });
        }

        return this.props.onSearchStatuses({ q: query, offset, limit });
      },
      membership: (payload) => this.props.onCheckMembership(payload),
      isCurrent: () => request === this.localRequest && !this.unmounted && this.searchQuery === query,
    }).then(outcome => this.publishText(request, outcome)).catch(() => {
      if (this.unmounted || request !== this.localRequest) {
        return;
      }

      this.setState({ busy: false, result: { outcome: 'unavailable', reason: 'network', moved: false } });
    });
  };

  jumpToText = (index) => {
    const row = this.state.textResults[index];

    if (!row || !this.props.onJumpStatus || this.state.busy) {
      return;
    }

    const request = ++this.localRequest;

    this.setState({ busy: true, notice: null });
    this.props.onJumpStatus({ statusId: row.id }).then(result => {
      if (this.unmounted || request !== this.localRequest) {
        return;
      }

      const moved = !!(result && result.moved);

      this.setState(prev => ({
        busy: false,
        result: result || { outcome: 'unavailable', reason: 'network', moved: false },
        textIndex: moved ? index : prev.textIndex,
      }));
    }).catch(() => {
      if (this.unmounted || request !== this.localRequest) {
        return;
      }

      this.setState({ busy: false, result: { outcome: 'unavailable', reason: 'network', moved: false } });
    });
  };

  chooseTextResult = (event) => {
    const marker = event.currentTarget.getAttribute('data-index');
    const index = this.state.textResults.findIndex((row, position) => String(position) === marker);

    if (index !== -1) {
      this.jumpToText(index);
    }
  };

  showPreviousText = () => {
    this.moveTextResult(-1);
  };

  showNextText = () => {
    this.moveTextResult(1);
  };

  moveTextResult = (delta) => {
    const { textResults, textIndex } = this.state;

    if (!textResults.length) {
      return;
    }

    let index = textIndex;

    if (delta > 0) {
      index = textIndex < 0 ? 0 : textIndex + 1;
    } else if (textIndex > 0) {
      index = textIndex - 1;
    } else {
      return;
    }

    if (index < 0 || index >= textResults.length) {
      return;
    }

    this.jumpToText(index);
  };

  handleSubmit = (event) => {
    event.preventDefault();

    if (this.composing || this.isImeEnter(event)) {
      return;
    }

    if (this.state.mode === JUMP_MODE.TEXT) {
      this.searchText();
      return;
    }

    const built = buildJumpQuery({
      mode: this.state.mode,
      preference: this.state.preference,
      at: this.state.dateTime,
      accountId: this.state.selectedAccountId,
      statusId: this.state.statusId.trim(),
    });

    if (!built.ok) {
      this.setState({ result: { outcome: 'unsupported', reason: built.reason, moved: false }, notice: null });
      return;
    }

    const request = ++this.localRequest;

    this.setState({ busy: true, result: null, notice: null });
    this.props.onSubmit(built.query).then(result => {
      if (this.unmounted || request !== this.localRequest) {
        return;
      }

      this.setState({ busy: false, result: result || { outcome: 'unavailable', reason: 'network', moved: false } });
    }).catch(() => {
      if (this.unmounted || request !== this.localRequest) {
        return;
      }

      this.setState({ busy: false, result: { outcome: 'unavailable', reason: 'network', moved: false } });
    });
  };

  capabilityNote () {
    const { intl, contract } = this.props;
    const source = sourceOf(contract);
    const mode = jumpModeState(source, this.state.mode);

    if (this.state.mode === JUMP_MODE.TEXT) {
      if (!mode.canSubmit) {
        return intl.formatMessage(messages.textUnsupported);
      }

      const hint = intl.formatMessage(messages.textHint);

      if (mode.level === 'approximate') {
        return `${hint} ${intl.formatMessage(messages.textRedis)}`;
      }

      return hint;
    }

    if (this.state.mode === JUMP_MODE.DATE) {
      const parsed = this.state.dateTime ? interpretLocalDateTime(this.state.dateTime) : null;
      const offset = parsed && parsed.ok ? parsed.offset : formatUtcOffset(new Date());
      const timeZone = parsed && parsed.ok ? parsed.timeZone : localTimeZoneName();
      const hint = intl.formatMessage(messages.dateHint, { timeZone, offset });

      if (mode.reason === 'redis_id_probe_not_created_at') {
        return `${hint} ${intl.formatMessage(messages.dateRedis)}`;
      }

      return hint;
    }

    if (this.state.mode === JUMP_MODE.ACCOUNT) {
      if (!mode.canSubmit) {
        return intl.formatMessage(messages.accountUnsupported);
      }

      return intl.formatMessage(messages.accountHint);
    }

    if (mode.reason === 'redis_retained_window') {
      return `${intl.formatMessage(messages.statusHint)} ${intl.formatMessage(messages.statusRedis)}`;
    }

    return intl.formatMessage(messages.statusHint);
  }

  textStatusText () {
    const { intl } = this.props;
    const view = this.state.textView;

    if (!view || view.paging === 'idle') {
      return null;
    }

    const parts = [];

    if (view.paging === 'checking' || this.state.busy) {
      parts.push(intl.formatMessage(messages.textChecking));
    }

    if (view.paging === 'network') {
      parts.push(intl.formatMessage(messages.network));
    }

    if (view.candidates > 0) {
      parts.push(intl.formatMessage(messages.textRange, {
        candidates: view.candidates,
        pages: view.pages,
        members: view.members,
      }));
    }

    if (view.partial || view.unknownCount > 0) {
      parts.push(intl.formatMessage(messages.textPartial));
    }

    if (view.paging === 'uncertain') {
      parts.push(intl.formatMessage(messages.textUncertain));
    } else if (view.paging === 'exhausted') {
      parts.push(intl.formatMessage(messages.textExhausted));
    } else if (view.paging === 'limit') {
      parts.push(intl.formatMessage(messages.textLimit, {
        candidates: view.sessionCandidates,
        pages: view.maxPages,
      }));
    }

    if (view.members === 0 && view.candidates > 0 && view.paging !== 'checking' && view.paging !== 'network' && view.paging !== 'idle') {
      parts.push(intl.formatMessage(messages.textEmpty));
    }

    if (view.members > 0) {
      parts.push(intl.formatMessage(messages.textRecheck));
    }

    return parts.join(' ');
  }

  createdLabel (value) {
    const { intl } = this.props;

    if (!value) {
      return '';
    }

    if (typeof intl.formatDate === 'function') {
      const date = new Date(value);

      if (!Number.isNaN(date.getTime())) {
        return intl.formatDate(date, {
          year: 'numeric',
          month: 'short',
          day: 'numeric',
          hour: '2-digit',
          minute: '2-digit',
        });
      }
    }

    return value;
  }

  renderTextSearch (modeState) {
    const { intl, panelId } = this.props;
    const view = this.state.textView;
    const status = this.textStatusText();
    const canSearch = modeState.canSubmit && !this.state.busy && this.state.textQuery.trim().length > 0;
    const atStart = this.state.textIndex <= 0;
    const atEnd = this.state.textIndex < 0
      ? this.state.textResults.length === 0
      : this.state.textIndex >= this.state.textResults.length - 1;

    return (
      <div className='timeline-jump__stack' data-layout='stack'>
        <div className='timeline-jump__row'>
          <label htmlFor={`${panelId}-text`}>{intl.formatMessage(messages.textQuery)}</label>
          <input
            id={`${panelId}-text`}
            className='setting-text'
            type='text'
            value={this.state.textQuery}
            onChange={this.handleTextQuery}
            onCompositionStart={this.handleComposition}
            onCompositionEnd={this.handleComposition}
            autoComplete='off'
            spellCheck='false'
            disabled={!modeState.canSubmit}
          />
        </div>
        {status && <p className='timeline-jump__note' role='status' aria-live='polite'>{status}</p>}
        {this.state.textResults.length > 0 && (
          <ul className='timeline-jump__results' aria-label={intl.formatMessage(messages.textResults)}>
            {this.state.textResults.map((row, index) => (
              <li key={row.id}>
                <button
                  type='button'
                  className='timeline-jump__hit'
                  data-index={index}
                  aria-current={this.state.textIndex === index ? 'true' : undefined}
                  onClick={this.chooseTextResult}
                >
                  <span className='timeline-jump__hit-account'>{row.acct ? `${row.displayName || row.acct} @${row.acct}` : (row.displayName || row.id)}</span>
                  <span className='timeline-jump__hit-time'>{this.createdLabel(row.createdAt)}</span>
                  <span className='timeline-jump__hit-excerpt'>{row.excerpt}</span>
                </button>
              </li>
            ))}
          </ul>
        )}
        <div className='timeline-jump__nav'>
          <button type='button' className='timeline-jump__close' disabled={atStart || this.state.busy} onClick={this.showPreviousText}>
            {intl.formatMessage(messages.textPrevious)}
          </button>
          <button
            type='button'
            className='timeline-jump__close'
            disabled={atEnd || this.state.busy || this.state.textResults.length === 0}
            onClick={this.showNextText}
          >
            {intl.formatMessage(messages.textNext)}
          </button>
          <button type='button' className='timeline-jump__close' disabled={!view || view.paging !== 'more' || this.state.busy} onClick={this.loadMoreText}>
            {intl.formatMessage(messages.textMore)}
          </button>
        </div>
        <div className='timeline-jump__actions'>
          <button type='submit' className='timeline-jump__go' disabled={!canSearch}>
            {this.state.busy ? intl.formatMessage(messages.busy) : intl.formatMessage(messages.textSearch)}
          </button>
          <button type='button' className='timeline-jump__close' onClick={this.props.onClose}>
            {intl.formatMessage(messages.close)}
          </button>
        </div>
      </div>
    );
  }

  render () {
    const { intl, panelId } = this.props;
    const { mode, busy } = this.state;
    const source = sourceOf(this.props.contract);
    const modeState = jumpModeState(source, mode);
    const feedback = this.state.notice
      ? jumpResultText(intl, { reason: this.state.notice })
      : jumpResultText(intl, this.state.result);
    let accountLookup = null;

    if (this.state.accountLookup === 'network') {
      accountLookup = intl.formatMessage(messages.accountFailed);
    } else if (this.state.accountLookup === 'ready' && this.state.accounts.length === 0) {
      accountLookup = intl.formatMessage(messages.accountEmpty);
    }

    return (
      <form
        id={panelId}
        className='timeline-jump'
        role='dialog'
        aria-label={intl.formatMessage(messages.title)}
        aria-busy={busy ? 'true' : 'false'}
        onSubmit={this.handleSubmit}
        onKeyDown={this.handleKeyDown}
        onCompositionStart={this.handleComposition}
        onCompositionEnd={this.handleComposition}
      >
        <div className='timeline-jump__row'>
          <label htmlFor={`${panelId}-mode`}>{intl.formatMessage(messages.mode)}</label>
          <select
            id={`${panelId}-mode`}
            className='setting-text'
            ref={this.setModeNode}
            value={mode}
            onChange={this.handleMode}
          >
            <option value={JUMP_MODE.DATE}>{intl.formatMessage(messages.date)}</option>
            <option value={JUMP_MODE.ACCOUNT}>{intl.formatMessage(messages.account)}</option>
            <option value={JUMP_MODE.STATUS}>{intl.formatMessage(messages.status)}</option>
            <option value={JUMP_MODE.TEXT}>{intl.formatMessage(messages.text)}</option>
          </select>
        </div>

        {mode === JUMP_MODE.DATE && (
          <React.Fragment>
            <div className='timeline-jump__row'>
              <label htmlFor={`${panelId}-when`}>{intl.formatMessage(messages.when)}</label>
              <input
                id={`${panelId}-when`}
                className='setting-text'
                type='datetime-local'
                value={this.state.dateTime}
                onChange={this.handleDate}
                autoComplete='off'
                required
              />
            </div>
            <div className='timeline-jump__row'>
              <label htmlFor={`${panelId}-preference`}>{intl.formatMessage(messages.preference)}</label>
              <select
                id={`${panelId}-preference`}
                className='setting-text'
                value={this.state.preference}
                onChange={this.handlePreference}
              >
                <option value={SEEK_PREFERENCE.NEAREST}>{intl.formatMessage(messages.nearest)}</option>
                <option value={SEEK_PREFERENCE.BEFORE}>{intl.formatMessage(messages.before)}</option>
                <option value={SEEK_PREFERENCE.AFTER}>{intl.formatMessage(messages.after)}</option>
              </select>
            </div>
          </React.Fragment>
        )}

        {mode === JUMP_MODE.ACCOUNT && modeState.canSubmit && (
          <div className='timeline-jump__row'>
            <label htmlFor={`${panelId}-account`}>{intl.formatMessage(messages.accountQuery)}</label>
            <input
              id={`${panelId}-account`}
              className='setting-text'
              type='text'
              value={this.state.accountQuery}
              onChange={this.handleAccountQuery}
              autoComplete='off'
              spellCheck='false'
            />
            {accountLookup && <p className='timeline-jump__note'>{accountLookup}</p>}
            {this.state.accounts.length > 0 && (
              <ul className='timeline-jump__accounts' aria-label={intl.formatMessage(messages.accounts)}>
                {this.state.accounts.map(account => (
                  <li key={account.id}>
                    <button
                      type='button'
                      className='timeline-jump__account'
                      data-account-id={account.id}
                      aria-pressed={this.state.selectedAccountId === account.id ? 'true' : 'false'}
                      onClick={this.chooseAccount}
                    >
                      {accountLabel(account)}
                    </button>
                  </li>
                ))}
              </ul>
            )}
          </div>
        )}

        {mode === JUMP_MODE.STATUS && (
          <div className='timeline-jump__row'>
            <label htmlFor={`${panelId}-status`}>{intl.formatMessage(messages.statusId)}</label>
            <input
              id={`${panelId}-status`}
              className='setting-text'
              type='text'
              inputMode='numeric'
              value={this.state.statusId}
              onChange={this.handleStatus}
              autoComplete='off'
              spellCheck='false'
            />
          </div>
        )}

        {mode === JUMP_MODE.TEXT && modeState.canSubmit && this.renderTextSearch(modeState)}

        <p className='timeline-jump__note'>{this.capabilityNote()}</p>
        {feedback && <p className='timeline-jump__result' role='status'>{feedback}</p>}

        {!(mode === JUMP_MODE.TEXT && modeState.canSubmit) && (
          <div className='timeline-jump__actions'>
            <button type='submit' className='timeline-jump__go' disabled={!modeState.canSubmit || busy}>
              {busy ? intl.formatMessage(messages.busy) : intl.formatMessage(messages.go)}
            </button>
            <button type='button' className='timeline-jump__close' onClick={this.props.onClose}>
              {intl.formatMessage(messages.close)}
            </button>
          </div>
        )}
      </form>
    );
  }

}

export default injectIntl(TimelineColumnJumpPanel);

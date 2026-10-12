import React, { Fragment } from 'react';
import CharacterCounter from './character_counter';
import Button from '../../../components/button';
import ImmutablePropTypes from 'react-immutable-proptypes';
import PropTypes from 'prop-types';
import ReplyIndicatorContainer from '../containers/reply_indicator_container';
import QuoteIndicatorContainer from '../containers/quote_indicator_container';
import AutosuggestTextarea from '../../../components/autosuggest_textarea';
import AutosuggestInput from '../../../components/autosuggest_input';
import PollButtonContainer from '../containers/poll_button_container';
import DateTimeButtonContainer from '../containers/datetime_button_container';
import UploadButtonContainer from '../containers/upload_button_container';
import { defineMessages, injectIntl, FormattedMessage } from 'react-intl';
import SpoilerButtonContainer from '../containers/spoiler_button_container';
import PrivacyDropdownContainer from '../containers/privacy_dropdown_container';
import SearchabilityDropdownContainer from '../containers/searchability_dropdown_container';
import CircleDropdownContainer from '../containers/circle_dropdown_container';
import DateTimeFormContainer from '../containers/datetime_form_container';
import ExpiresIndicatorContainer from '../containers/expires_indicator_container';
import EmojiPickerDropdownContainer from '../containers/emoji_picker_dropdown_container';
import LanguageDropdownContainer from '../containers/language_dropdown_container';
import PollFormContainer from '../containers/poll_form_container';
import UploadFormContainer from '../containers/upload_form_container';
import WarningContainer from '../containers/warning_container';
import { postingContextCapabilityMessages } from './posting_context_bar';
import ReferenceStack from '../../../features/reference_stack';
import { isMobile } from '../../../is_mobile';
import ImmutablePureComponent from 'react-immutable-pure-component';
import { length } from 'stringz';
import { countableText } from '../util/counter';
import Icon from 'mastodon/components/icon';
import { disablePost, maxChars } from '../../../initial_state';
import IconButton from '../../../components/icon_button';
import classNames from 'classnames';
import { PORTABLE_COMPOSER_MODE_FULL, PORTABLE_COMPOSER_MODE_SIMPLE } from '../../../selectors/composer';
import { isExternalFileDrag, markComposerFileDrop } from '../composer_drop';
import ComposerOverflowMenu from './composer_overflow_menu';

const allowedAroundShortCode = '><\u0085\u0020\u00a0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200a\u202f\u205f\u3000\u2028\u2029\u0009\u000a\u000b\u000c\u000d';

const messages = defineMessages({
  placeholder: { id: 'compose_form.placeholder', defaultMessage: 'What is on your mind?' },
  spoiler_placeholder: { id: 'compose_form.spoiler_placeholder', defaultMessage: 'Write your warning here' },
  publish: { id: 'compose_form.publish', defaultMessage: 'Toot' },
  publishLoud: { id: 'compose_form.publish_loud', defaultMessage: '{publish}!' },
  saveChanges: { id: 'compose_form.save_changes', defaultMessage: 'Save changes' },
  editing: { id: 'compose_form.editing', defaultMessage: 'Editing post' },
  cancelEdit: { id: 'compose_form.cancel_edit', defaultMessage: 'Cancel' },
  update: { id: 'compose_form.update_scheduled_status', defaultMessage: 'Update scheduled post' },
  delete: { id: 'compose_form.delete_scheduled_status', defaultMessage: 'Delete scheduled post' },
  and: { id: 'compose_form.and', defaultMessage: ' + ' },
  simpleMode: { id: 'compose_form.simple_mode', defaultMessage: 'Switch to simple view' },
  fullMode: { id: 'compose_form.full_mode', defaultMessage: 'Show full composer' },
  privacyPublic: { id: 'privacy.public.short', defaultMessage: 'Public' },
  privacyUnlisted: { id: 'privacy.unlisted.short', defaultMessage: 'Unlisted' },
  privacyPrivate: { id: 'privacy.private.short', defaultMessage: 'Followers-only' },
  privacyMutual: { id: 'privacy.mutual.short', defaultMessage: 'Mutuals-followers-only' },
  privacyLimited: { id: 'privacy.limited.short', defaultMessage: 'Circle' },
  privacyDirect: { id: 'privacy.direct.short', defaultMessage: 'Direct' },
  privacyPersonal: { id: 'privacy.personal.short', defaultMessage: 'Personal' },
  surfaceMismatch: { id: 'compose_form.posting_style.surface_mismatch', defaultMessage: 'This draft still uses the previous destination. Posting stays off until you apply the destination shown here.' },
  surfaceAccept: { id: 'compose_form.posting_style.surface_accept', defaultMessage: 'Use this destination' },
  more: { id: 'compose_form.more_actions', defaultMessage: 'More actions' },
  uploadBlocked: { id: 'compose_form.upload_blocked', defaultMessage: 'This posting account can’t attach media here.' },
  uploadBlockedMedia: { id: 'compose_form.upload_blocked.media', defaultMessage: 'This posting account can’t attach media.' },
  uploadBlockedReply: { id: 'compose_form.upload_blocked.reply', defaultMessage: 'Replies and quotes can’t include media from this posting account.' },
  uploadBlockedPoll: { id: 'compose_form.upload_blocked.poll', defaultMessage: 'Remove the poll before attaching media as this posting account.' },
  uploadBlockedSchedule: { id: 'compose_form.upload_blocked.schedule', defaultMessage: 'Scheduled posts can’t include media from this posting account.' },
  uploadBlockedGroup: { id: 'compose_form.upload_blocked.group', defaultMessage: 'Group posts can’t include media from this posting account.' },
  uploadBlockedUnauthorized: { id: 'compose_form.upload_blocked.unauthorized', defaultMessage: 'This posting account isn’t allowed to attach media.' },
  uploadBlockedUnresolved: { id: 'compose_form.upload_blocked.unresolved', defaultMessage: 'Still confirming whether this posting account can attach media.' },
  uploadBlockedFailed: { id: 'compose_form.upload_blocked.failed', defaultMessage: 'Couldn’t confirm whether this posting account can attach media.' },
  uploadBlockedMismatch: { id: 'compose_form.upload_blocked.mismatch', defaultMessage: 'This posting account doesn’t match the signed-in account.' },
  uploadBlockedEdit: { id: 'compose_form.upload_blocked.edit', defaultMessage: 'Finish or discard this edit before attaching media as this posting account.' },
  cwOn: { id: 'compose_form.cw_on', defaultMessage: 'Content warning is on' },
  pollOn: { id: 'compose_form.poll_on', defaultMessage: 'Poll added' },
  scheduleOn: { id: 'compose_form.schedule_on', defaultMessage: 'Scheduled' },
  expiryOn: { id: 'compose_form.expiry_on', defaultMessage: 'Expiry is set' },
  sensitiveOn: { id: 'compose_form.sensitive_on', defaultMessage: 'Media is marked sensitive' },
});

const uploadReasonMessage = {
  media: messages.uploadBlockedMedia,
  reply: messages.uploadBlockedReply,
  quote: messages.uploadBlockedReply,
  poll: messages.uploadBlockedPoll,
  schedule: messages.uploadBlockedSchedule,
  schedule_bound: messages.uploadBlockedSchedule,
  group: messages.uploadBlockedGroup,
  unauthorized: messages.uploadBlockedUnauthorized,
  unregistered: messages.uploadBlockedUnauthorized,
  unsupported: messages.uploadBlockedUnauthorized,
  unresolved: messages.uploadBlockedUnresolved,
  idle: messages.uploadBlockedUnresolved,
  loading: messages.uploadBlockedUnresolved,
  failed: messages.uploadBlockedFailed,
  mismatch: messages.uploadBlockedMismatch,
  edit_bound: messages.uploadBlockedEdit,
  missing: messages.uploadBlocked,
};

export default @injectIntl
class ComposeForm extends ImmutablePureComponent {

  static contextTypes = {
    router: PropTypes.object,
  };

  static propTypes = {
    intl: PropTypes.object.isRequired,
    text: PropTypes.string.isRequired,
    effectiveText: PropTypes.string,
    suggestions: ImmutablePropTypes.list,
    spoiler: PropTypes.bool,
    privacy: PropTypes.string,
    spoilerText: PropTypes.string,
    focusDate: PropTypes.instanceOf(Date),
    caretPosition: PropTypes.number,
    preselectDate: PropTypes.instanceOf(Date),
    isSubmitting: PropTypes.bool,
    isChangingUpload: PropTypes.bool,
    isUploading: PropTypes.bool,
    isCircleUnselected: PropTypes.bool,
    prohibitedVisibilities: ImmutablePropTypes.set,
    prohibitedWords: ImmutablePropTypes.set,
    isScheduled: PropTypes.bool,
    isScheduledStatusEditting: PropTypes.bool,
    isEditing: PropTypes.bool,
    lang: PropTypes.string,
    styleController: PropTypes.node,
    stylePicker: PropTypes.node,
    senderIdentity: PropTypes.node,
    onCancelEdit: PropTypes.func,
    onChange: PropTypes.func.isRequired,
    onSubmit: PropTypes.func.isRequired,
    onClearSuggestions: PropTypes.func.isRequired,
    onFetchSuggestions: PropTypes.func.isRequired,
    onSuggestionSelected: PropTypes.func.isRequired,
    onChangeSpoilerText: PropTypes.func.isRequired,
    onPaste: PropTypes.func.isRequired,
    onPickEmoji: PropTypes.func.isRequired,
    showSearch: PropTypes.bool,
    anyMedia: PropTypes.bool,
    singleColumn: PropTypes.bool,
    autoFocus: PropTypes.bool,
    contextCompliant: PropTypes.bool,
    canAttempt: PropTypes.bool,
    canSendAsIdentity: PropTypes.bool,
    capabilityReason: PropTypes.string,
    surfaceMismatch: PropTypes.bool,
    onAcceptSurface: PropTypes.func,
    displayMode: PropTypes.oneOf(['full', 'simple']),
    onDisplayModeChange: PropTypes.func,
    composerId: PropTypes.string,
    hasPoll: PropTypes.bool,
    hasExpiry: PropTypes.bool,
    sensitive: PropTypes.bool,
    canUploadMedia: PropTypes.bool,
    uploadBlockReason: PropTypes.string,
  };

  state = {
    fileHover: false,
    uploadNotice: null,
  };

  static defaultProps = {
    showSearch: false,
    autoFocus: true,
    contextCompliant: true,
    canAttempt: true,
    canSendAsIdentity: true,
    capabilityReason: null,
    surfaceMismatch: false,
    displayMode: 'full',
  };

  handleChange = (e) => {
    this.props.onChange(e.target.value);
  }

  handleKeyDown = (e) => {
    if (e.keyCode === 13 && (e.ctrlKey || e.metaKey)) {
      this.handleSubmit();
    }
  }

  composedText = () => {
    return this.props.effectiveText ?? this.props.text;
  }

  getFulltextForCharacterCounting = () => {
    return [this.props.spoiler? this.props.spoilerText: '', countableText(this.composedText())].join('');
  }

  canSubmit = () => {
    const { isSubmitting, isChangingUpload, isUploading, isCircleUnselected, isEditing, anyMedia, prohibitedVisibilities, privacy, prohibitedWords, spoilerText, contextCompliant, canAttempt, canSendAsIdentity } = this.props;
    const composedText = this.composedText();
    const fulltext = this.getFulltextForCharacterCounting();
    const isOnlyWhitespace = fulltext.length !== 0 && fulltext.trim().length === 0;
    const noVisibility = !isEditing && prohibitedVisibilities?.includes(privacy);
    const ngWords = prohibitedWords.some( word => composedText.includes(word) || spoilerText?.includes(word) );

    return !(isSubmitting || isUploading || isChangingUpload || isCircleUnselected || length(fulltext) > maxChars || (isOnlyWhitespace && !anyMedia) || noVisibility || ngWords || !contextCompliant || !canAttempt || canSendAsIdentity === false || this.props.surfaceMismatch);
  }

  renderSurfaceMismatch () {
    if (!this.props.surfaceMismatch) {
      return null;
    }

    return (
      <div className='compose-form__surface-mismatch' role='status'>
        <span>{this.props.intl.formatMessage(messages.surfaceMismatch)}</span>
        {this.props.onAcceptSurface ? (
          <button type='button' onClick={this.props.onAcceptSurface}>
            {this.props.intl.formatMessage(messages.surfaceAccept)}
          </button>
        ) : null}
      </div>
    );
  }

  renderCapabilityGuard () {
    if (!this.isSimpleMode() || this.props.canAttempt !== false) {
      return null;
    }

    const reasonMessages = {
      compliance: postingContextCapabilityMessages.blockedCompliance,
      delivery_unsupported: postingContextCapabilityMessages.blockedUnsupported,
      delivery_unresolved: postingContextCapabilityMessages.blockedUnresolved,
      target_mismatch: postingContextCapabilityMessages.blockedMismatch,
    };
    const message = reasonMessages[this.props.capabilityReason] || postingContextCapabilityMessages.blockedCompliance;

    return (
      <div className='compose-form__capability-guard' role='status'>
        <span>{this.props.intl.formatMessage(message)}</span>
        <button type='button' onClick={this.handleFullModeClick}>
          {this.props.intl.formatMessage(postingContextCapabilityMessages.blockedDetails)}
        </button>
      </div>
    );
  }

  handleSubmit = () => {
    if (this.props.text !== this.autosuggestTextarea.textarea.value) {
      // Something changed the text inside the textarea (e.g. browser extensions like Grammarly)
      // Update the state to match the current text
      this.props.onChange(this.autosuggestTextarea.textarea.value);
    }

    if (!this.canSubmit()) {
      return;
    }

    this.props.onSubmit(this.context.router ? this.context.router.history : null);
  }

  onSuggestionsClearRequested = () => {
    this.props.onClearSuggestions();
  }

  onSuggestionsFetchRequested = (token) => {
    this.props.onFetchSuggestions(token);
  }

  onSuggestionSelected = (tokenStart, token, value) => {
    this.props.onSuggestionSelected(tokenStart, token, value, ['text']);
  }

  onSpoilerSuggestionSelected = (tokenStart, token, value) => {
    this.props.onSuggestionSelected(tokenStart, token, value, ['spoiler_text']);
  }

  handleChangeSpoilerText = (e) => {
    this.props.onChangeSpoilerText(e.target.value);
  }

  handleFocus = () => {
    if (this.composeForm && !this.props.singleColumn) {
      const { left, right } = this.composeForm.getBoundingClientRect();
      if (left < 0 || right > (window.innerWidth || document.documentElement.clientWidth)) {
        this.composeForm.scrollIntoView();
      }
    }
  }

  componentDidMount () {
    this._updateFocusAndSelection({ });
  }

  componentDidUpdate (prevProps) {
    this._updateFocusAndSelection(prevProps);
    this.syncUploadNotice();
  }

  syncUploadNotice () {
    if (!this.state.uploadNotice) {
      return;
    }

    if (this.props.canUploadMedia !== false) {
      this.setState({ uploadNotice: null });
      return;
    }

    const reason = this.props.uploadBlockReason || 'unauthorized';

    if (reason !== this.state.uploadNotice) {
      this.setState({ uploadNotice: reason });
    }
  }

  uploadNoticeText () {
    const message = uploadReasonMessage[this.state.uploadNotice] || messages.uploadBlocked;

    return this.props.intl.formatMessage(message);
  }

  _updateFocusAndSelection = (prevProps) => {
    // This statement does several things:
    // - If we're beginning a reply, and,
    //     - Replying to zero or one users, places the cursor at the end of the textbox.
    //     - Replying to more than one user, selects any usernames past the first;
    //       this provides a convenient shortcut to drop everyone else from the conversation.
    if (this.props.focusDate !== prevProps.focusDate) {
      let selectionEnd, selectionStart;

      if (this.props.preselectDate !== prevProps.preselectDate) {
        selectionEnd   = this.props.text.length;
        selectionStart = this.props.text.search(/\s/) + 1;
      } else if (typeof this.props.caretPosition === 'number') {
        selectionStart = this.props.caretPosition;
        selectionEnd   = this.props.caretPosition;
      } else {
        selectionEnd   = this.props.text.length;
        selectionStart = selectionEnd;
      }

      this.autosuggestTextarea.textarea.setSelectionRange(selectionStart, selectionEnd);
      this.autosuggestTextarea.textarea.focus();
    } else if(prevProps.isSubmitting && !this.props.isSubmitting) {
      this.autosuggestTextarea.textarea.focus();
    } else if (this.props.spoiler !== prevProps.spoiler) {
      if (this.props.spoiler && this.spoilerText) {
        this.spoilerText.input.focus();
      } else if (this.autosuggestTextarea) {
        this.autosuggestTextarea.textarea.focus();
      }
    }
  }

  setAutosuggestTextarea = (c) => {
    this.autosuggestTextarea = c;
  }

  setSpoilerText = (c) => {
    this.spoilerText = c;
  }

  setRef = c => {
    this.composeForm = c;
  };

  publishAccessibleName () {
    const { intl } = this.props;

    if (this.props.isEditing) {
      return intl.formatMessage(messages.saveChanges);
    }

    if (!this.props.isEditing && this.props.isScheduledStatusEditting && this.props.isScheduled) {
      return intl.formatMessage(messages.update);
    }

    if (this.props.privacy !== 'public' && this.props.privacy !== 'unlisted') {
      return intl.formatMessage(messages.publish);
    }

    if (this.props.privacy === 'unlisted') {
      return intl.formatMessage(messages.publish);
    }

    return intl.formatMessage(messages.publishLoud, { publish: intl.formatMessage(messages.publish) });
  }

  publishLabel () {
    const { intl } = this.props;
    let publishText = '';

    if (this.props.isEditing) {
      publishText = intl.formatMessage(messages.saveChanges);
    } else if (this.props.privacy !== 'public' && this.props.privacy !== 'unlisted') {
      publishText = <span className='compose-form__publish-private'><Icon id='lock' /> {intl.formatMessage(messages.publish)}</span>;
    } else {
      publishText = this.props.privacy !== 'unlisted' ? intl.formatMessage(messages.publishLoud, { publish: intl.formatMessage(messages.publish) }) : intl.formatMessage(messages.publish);
    }

    if (!this.props.isEditing && this.props.isScheduledStatusEditting) {
      if (this.props.isScheduled ) {
        publishText = <span className='compose-form__update'>{intl.formatMessage(messages.update)}</span>;
      } else {
        publishText = <Fragment><span className='compose-form__delete'>{intl.formatMessage(messages.delete)}</span>{intl.formatMessage(messages.and)}{publishText}</Fragment>;
      }
    }

    return publishText;
  }

  renderPublishButton (publishText) {
    return (
      <div className='compose-form__publish-button-wrapper'>
        <Button text={publishText} onClick={this.handleSubmit} disabled={disablePost || !this.canSubmit()} />
      </div>
    );
  }

  isSimpleMode () {
    return typeof this.props.onDisplayModeChange === 'function' && this.props.displayMode === PORTABLE_COMPOSER_MODE_SIMPLE;
  }

  handlePaste = (files) => {
    if (this.props.canUploadMedia === false) {
      this.setState({ uploadNotice: this.props.uploadBlockReason || 'unauthorized' });
      return;
    }

    this.setState({ uploadNotice: null });
    this.props.onPaste(files);
  }

  handleComposerDragEnter = (event) => {
    if (!isExternalFileDrag(event.dataTransfer)) {
      return;
    }

    event.preventDefault();
    event.stopPropagation();
    this.setState({ fileHover: true });
  }

  handleComposerDragOver = (event) => {
    if (!isExternalFileDrag(event.dataTransfer)) {
      return;
    }

    event.preventDefault();
    event.stopPropagation();

    try {
      event.dataTransfer.dropEffect = 'copy';
    } catch (error) {
      // Some browsers reject dropEffect assignment.
    }
  }

  handleComposerDragLeave = (event) => {
    if (event.currentTarget.contains(event.relatedTarget)) {
      return;
    }

    this.setState({ fileHover: false });
  }

  handleComposerDrop = (event) => {
    if (!isExternalFileDrag(event.dataTransfer)) {
      return;
    }

    event.preventDefault();
    event.stopPropagation();
    markComposerFileDrop(event);
    this.setState({ fileHover: false });

    const files = event.dataTransfer && event.dataTransfer.files;

    if (files && files.length >= 1) {
      this.handlePaste(files);
    }
  }

  handleSimpleModeClick = () => {
    this.props.onDisplayModeChange(PORTABLE_COMPOSER_MODE_SIMPLE);
  }

  handleFullModeClick = () => {
    this.props.onDisplayModeChange(PORTABLE_COMPOSER_MODE_FULL);
  }

  renderTextarea (modifiers, overlay) {
    const { intl, showSearch, autoFocus } = this.props;
    const simple = this.isSimpleMode();

    return (
      <AutosuggestTextarea
        ref={this.setAutosuggestTextarea}
        placeholder={intl.formatMessage(messages.placeholder)}
        disabled={this.props.isSubmitting}
        value={this.props.text}
        onChange={this.handleChange}
        suggestions={this.props.suggestions}
        onFocus={this.handleFocus}
        onKeyDown={this.handleKeyDown}
        onSuggestionsFetchRequested={this.onSuggestionsFetchRequested}
        onSuggestionsClearRequested={this.onSuggestionsClearRequested}
        onSuggestionSelected={this.onSuggestionSelected}
        onPaste={this.handlePaste}
        autoFocus={autoFocus && !showSearch && !isMobile(window.innerWidth)}
        lang={this.props.lang}
        overlay={overlay}
        minRows={simple ? 2 : undefined}
        maxRows={simple ? 3 : undefined}
      >
        {modifiers}
      </AutosuggestTextarea>
    );
  }

  renderModeToggle () {
    if (typeof this.props.onDisplayModeChange !== 'function') {
      return null;
    }

    const simple = this.isSimpleMode();

    return (
      <IconButton
        className='compose-form__mode-toggle'
        icon={simple ? 'expand' : 'compress'}
        title={this.props.intl.formatMessage(simple ? messages.fullMode : messages.simpleMode)}
        onClick={simple ? this.handleFullModeClick : this.handleSimpleModeClick}
        inverted
      />
    );
  }

  renderIconPublish () {
    const privatePost = !this.props.isEditing && this.props.privacy !== 'public' && this.props.privacy !== 'unlisted';

    return (
      <IconButton
        className={classNames('compose-form__publish-icon', { 'compose-form__publish-private': privatePost })}
        icon={this.props.isEditing ? 'pencil' : 'paper-plane'}
        title={this.publishAccessibleName()}
        disabled={disablePost || !this.canSubmit()}
        onClick={this.handleSubmit}
      />
    );
  }

  renderSimpleBadge (icon, title) {
    return (
      <IconButton
        className='compose-form__simple-badge'
        icon={icon}
        title={title}
        onClick={this.handleFullModeClick}
        inverted
      />
    );
  }

  renderHeader () {
    return (
      <div className='compose-form__header'>
        <div className='compose-form__header-context'>{this.props.stylePicker}</div>
        <div className='compose-form__header-audience'>
          <PrivacyDropdownContainer disabled={this.props.isEditing} showLabel />
        </div>
      </div>
    );
  }

  handleEmojiPick = (data) => {
    const { text }     = this.props;
    const position     = this.autosuggestTextarea.textarea.selectionStart;
    const needsSpace   = data.custom && position > 0 && !allowedAroundShortCode.includes(text[position - 1]);

    this.props.onPickEmoji(position, data, needsSpace);
  }

  renderFooter (publishText, simple) {
    const { intl } = this.props;

    return (
      <div className='compose-form__buttons-wrapper'>
        <div className='compose-form__buttons'>
          <div className='compose-form__toolbar-account'>{this.props.senderIdentity}</div>
          {simple ? null : <UploadButtonContainer />}
          {simple ? null : <SpoilerButtonContainer />}
          <LanguageDropdownContainer />
          {!this.props.isEditing && (
            <ComposerOverflowMenu label={intl.formatMessage(messages.more)}>
              {this.renderModeToggle()}
              <DateTimeButtonContainer presentation='menu' />
              <SearchabilityDropdownContainer presentation='menu' />
              <PollButtonContainer presentation='menu' />
            </ComposerOverflowMenu>
          )}
        </div>

        <div className='compose-form__submit'>
          <div className='compose-form__preflight' data-composer-preflight='true' />
          {simple ? this.renderIconPublish() : this.renderPublishButton(publishText)}
        </div>
      </div>
    );
  }

  renderSpoiler () {
    const { intl } = this.props;

    if (!this.props.spoiler) {
      return null;
    }

    return (
      <div className='spoiler-input spoiler-input--visible' ref={this.setRef} data-testid='cw-input'>
        <AutosuggestInput
          placeholder={intl.formatMessage(messages.spoiler_placeholder)}
          value={this.props.spoilerText}
          onChange={this.handleChangeSpoilerText}
          onKeyDown={this.handleKeyDown}
          disabled={!this.props.spoiler}
          ref={this.setSpoilerText}
          suggestions={this.props.suggestions}
          onSuggestionsFetchRequested={this.onSuggestionsFetchRequested}
          onSuggestionsClearRequested={this.onSuggestionsClearRequested}
          onSuggestionSelected={this.onSpoilerSuggestionSelected}
          searchTokens={[':']}
          id='cw-spoiler-input'
          className='spoiler-input__input'
          lang={this.props.lang}
        />
      </div>
    );
  }

  renderSimpleBadges () {
    const { intl } = this.props;
    const badges = [];

    if (this.props.spoiler) {
      badges.push(this.renderSimpleBadge('warning', intl.formatMessage(messages.cwOn)));
    }

    if (this.props.hasPoll) {
      badges.push(this.renderSimpleBadge('tasks', intl.formatMessage(messages.pollOn)));
    }

    if (this.props.isScheduled) {
      badges.push(this.renderSimpleBadge('calendar', intl.formatMessage(messages.scheduleOn)));
    }

    if (this.props.hasExpiry) {
      badges.push(this.renderSimpleBadge('hourglass', intl.formatMessage(messages.expiryOn)));
    }

    if (this.props.sensitive) {
      badges.push(this.renderSimpleBadge('eye-slash', intl.formatMessage(messages.sensitiveOn)));
    }

    if (badges.length === 0) {
      return null;
    }

    return <div className='compose-form__simple-badges'>{badges}</div>;
  }

  render () {
    const { intl } = this.props;
    const publishText = this.publishLabel();
    const simple = this.isSimpleMode();
    const overlay = simple ? null : (
      <Fragment>
        <div className='compose-form__emoji-anchor'>
          <EmojiPickerDropdownContainer onPickEmoji={this.handleEmojiPick} />
        </div>
        <div className='compose-form__count-anchor' data-testid='character-count'>
          <CharacterCounter max={maxChars} text={this.getFulltextForCharacterCounting()} />
        </div>
      </Fragment>
    );
    const modifiers = simple ? null : (
      <div className='compose-form__modifiers'>
        <UploadFormContainer />
        <PollFormContainer />
        {!this.props.isEditing && <DateTimeFormContainer />}
        {!this.props.isEditing && <ExpiresIndicatorContainer />}
      </div>
    );

    return (
      <div
        className={classNames('compose-form', {
          'compose-form--simple': simple,
          'compose-form--file-hover': this.state.fileHover,
        })}
        data-composer-id={this.props.composerId || 'primary'}
        onDragEnter={this.handleComposerDragEnter}
        onDragOver={this.handleComposerDragOver}
        onDragLeave={this.handleComposerDragLeave}
        onDrop={this.handleComposerDrop}
      >
        {this.props.styleController}
        {this.renderHeader()}
        {this.renderSurfaceMismatch()}
        {this.renderCapabilityGuard()}
        {this.state.uploadNotice ? (
          <p className='compose-form__upload-notice' role='status'>{this.uploadNoticeText()}</p>
        ) : null}
        {!simple && <WarningContainer />}
        {!simple && this.props.isEditing && (
          <div className='edit-indicator'>
            <div className='edit-indicator__cancel'><IconButton title={intl.formatMessage(messages.cancelEdit)} icon='times' onClick={this.props.onCancelEdit} inverted /></div>
            <div className='edit-indicator__content translate'><FormattedMessage {...messages.editing} /></div>
          </div>
        )}
        {!simple && <ReplyIndicatorContainer />}
        {!simple && !this.props.isEditing && <QuoteIndicatorContainer />}
        {!simple && this.renderSpoiler()}

        <div className='compose-form__body'>
          {this.renderTextarea(modifiers, overlay)}
          {simple && (
            <div className={classNames('compose-form__simple-row', { 'compose-form__simple-row--overlay': !this.props.anyMedia })}>
              <UploadFormContainer summary />
              {this.renderSimpleBadges()}
            </div>
          )}
        </div>

        {!simple && !this.props.isEditing && <CircleDropdownContainer key='circle' />}
        {this.renderFooter(publishText, simple)}
        {!simple && !this.props.isEditing && <ReferenceStack key='references' />}
      </div>
    );
  }

}

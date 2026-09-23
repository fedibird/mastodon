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
import PollFormContainer from '../containers/poll_form_container';
import UploadFormContainer from '../containers/upload_form_container';
import WarningContainer from '../containers/warning_container';
import ReferenceStack from '../../../features/reference_stack';
import { isMobile } from '../../../is_mobile';
import ImmutablePureComponent from 'react-immutable-pure-component';
import { length } from 'stringz';
import { countableText } from '../util/counter';
import Icon from 'mastodon/components/icon';
import { disablePost, maxChars } from '../../../initial_state';
import IconButton from '../../../components/icon_button';

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
});

export default @injectIntl
class ComposeForm extends ImmutablePureComponent {

  static contextTypes = {
    router: PropTypes.object,
  };

  static propTypes = {
    intl: PropTypes.object.isRequired,
    text: PropTypes.string.isRequired,
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
  };

  static defaultProps = {
    showSearch: false,
  };

  handleChange = (e) => {
    this.props.onChange(e.target.value);
  }

  handleKeyDown = (e) => {
    if (e.keyCode === 13 && (e.ctrlKey || e.metaKey)) {
      this.handleSubmit();
    }
  }

  getFulltextForCharacterCounting = () => {
    return [this.props.spoiler? this.props.spoilerText: '', countableText(this.props.text)].join('');
  }

  canSubmit = () => {
    const { isSubmitting, isChangingUpload, isUploading, isCircleUnselected, anyMedia, prohibitedVisibilities, privacy, prohibitedWords, text, spoilerText } = this.props;
    const fulltext = this.getFulltextForCharacterCounting();
    const isOnlyWhitespace = fulltext.length !== 0 && fulltext.trim().length === 0;
    const noVisibility = prohibitedVisibilities?.includes(privacy);
    const ngWords = prohibitedWords.some( word => text.includes(word) || spoilerText?.includes(word) );

    return !(isSubmitting || isUploading || isChangingUpload || isCircleUnselected || length(fulltext) > maxChars || (isOnlyWhitespace && !anyMedia) || noVisibility || ngWords);
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
      if (this.props.spoiler) {
        this.spoilerText.input.focus();
      } else {
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

  handleEmojiPick = (data) => {
    const { text }     = this.props;
    const position     = this.autosuggestTextarea.textarea.selectionStart;
    const needsSpace   = data.custom && position > 0 && !allowedAroundShortCode.includes(text[position - 1]);

    this.props.onPickEmoji(position, data, needsSpace);
  }

  render () {
    const { intl, onPaste, showSearch } = this.props;
    const disabled = this.props.isSubmitting;
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

    return (
      <div className='compose-form'>
        <WarningContainer />

        {this.props.isEditing && (
          <div className='edit-indicator'>
            <div className='edit-indicator__cancel'><IconButton title={intl.formatMessage(messages.cancelEdit)} icon='times' onClick={this.props.onCancelEdit} inverted /></div>
            <div className='edit-indicator__content translate'><FormattedMessage {...messages.editing} /></div>
          </div>
        )}

        <ReplyIndicatorContainer />
        {!this.props.isEditing && <QuoteIndicatorContainer />}

        <div className={`spoiler-input ${this.props.spoiler ? 'spoiler-input--visible' : ''}`} ref={this.setRef}>
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
          />
        </div>

        <AutosuggestTextarea
          ref={this.setAutosuggestTextarea}
          placeholder={intl.formatMessage(messages.placeholder)}
          disabled={disabled}
          value={this.props.text}
          onChange={this.handleChange}
          suggestions={this.props.suggestions}
          onFocus={this.handleFocus}
          onKeyDown={this.handleKeyDown}
          onSuggestionsFetchRequested={this.onSuggestionsFetchRequested}
          onSuggestionsClearRequested={this.onSuggestionsClearRequested}
          onSuggestionSelected={this.onSuggestionSelected}
          onPaste={onPaste}
          autoFocus={!showSearch && !isMobile(window.innerWidth)}
        >
          <div className='compose-form__modifiers'>
            <UploadFormContainer />
            <PollFormContainer />
            {!this.props.isEditing && <DateTimeFormContainer />}
            {!this.props.isEditing && <ExpiresIndicatorContainer />}
          </div>
        </AutosuggestTextarea>

        <div className='compose-form__buttons-wrapper'>
          <div className='compose-form__buttons'>
            <UploadButtonContainer />
            <PollButtonContainer />
            <PrivacyDropdownContainer disabled={this.props.isEditing} />
            <SpoilerButtonContainer />
            <EmojiPickerDropdownContainer onPickEmoji={this.handleEmojiPick} />
            {!this.props.isEditing && <DateTimeButtonContainer />}
            {!this.props.isEditing && <SearchabilityDropdownContainer />}
          </div>
          <div className='character-counter__wrapper'><CharacterCounter max={maxChars} text={this.getFulltextForCharacterCounting()} /></div>
        </div>

        {!this.props.isEditing && <CircleDropdownContainer />}

        <div className='compose-form__publish'>
          <div className='compose-form__publish-button-wrapper'><Button text={publishText} onClick={this.handleSubmit} disabled={disablePost || !this.canSubmit()} block /></div>
        </div>

        {!this.props.isEditing && <ReferenceStack />}
      </div>
    );
  }

}

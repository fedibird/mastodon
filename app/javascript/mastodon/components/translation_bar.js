import React from 'react';
import ImmutablePropTypes from 'react-immutable-proptypes';
import PropTypes from 'prop-types';
import { defineMessages } from 'react-intl';
import classnames from 'classnames';
import Overlay from 'react-overlays/Overlay';
import { languages as preloadedLanguages } from 'mastodon/initial_state';
import { languageOption, needsChineseScriptChoice, sameTranslationLanguage, sourceLanguageOptions, targetLanguageOptions } from 'mastodon/utils/translation_languages';
import { normalizedContentLocale, preTranslationRequestModes } from 'mastodon/utils/translation_view';
import LanguageDropdownMenu from 'mastodon/components/language_dropdown_menu';

const messages = defineMessages({
  translate: { id: 'status.translate', defaultMessage: 'Translate' },
  bilingual: { id: 'status.bilingual', defaultMessage: 'Bilingual' },
  original: { id: 'status.original', defaultMessage: 'Original' },
  translated: { id: 'status.translated', defaultMessage: 'Translated' },
  translationModes: { id: 'status.translation_modes', defaultMessage: 'Translation display' },
  sourceLanguage: { id: 'status.translation_source_language', defaultMessage: 'Source language, {language}' },
  targetLanguage: { id: 'status.translation_target_language', defaultMessage: 'Target language, {language}' },
  unspecified: { id: 'status.translation_unspecified', defaultMessage: 'Unspecified' },
  unsupportedPair: { id: 'status.translation_unsupported_pair', defaultMessage: 'This language pair is not supported.' },
  chooseChineseScript: { id: 'status.translation_choose_chinese_script', defaultMessage: 'Choose Simplified Chinese or Traditional Chinese as the source language.' },
  detectedSource: { id: 'status.translation_detected_source', defaultMessage: 'Detected {language}' },
});

const languageName = (code, intl) => languageOption(code, preloadedLanguages, intl.formatMessage(messages.unspecified))[2];

// StatusContent opens the status from a mousedown/mouseup gesture and only
// ignores button, anchor, and label targets. The language menu is a portaled
// list of role="option" divs, so it still reaches that gesture through the
// React tree. Keep the whole bar, including the portaled menu, inside this
// boundary. stopPropagation only: buttons, search, and keyboard handling stay
// on their own targets, and the menu's document capture listener still sees
// outside clicks.
const stopInteractionPropagation = event => {
  event.stopPropagation();
};

const interactionBoundary = {
  onMouseDown: stopInteractionPropagation,
  onMouseUp: stopInteractionPropagation,
  onClick: stopInteractionPropagation,
  onKeyDown: stopInteractionPropagation,
  onTouchStart: stopInteractionPropagation,
  onTouchEnd: stopInteractionPropagation,
};

class LanguageSelector extends React.PureComponent {

  static propTypes = {
    value: PropTypes.string,
    label: PropTypes.string.isRequired,
    ariaLabel: PropTypes.string.isRequired,
    languages: PropTypes.arrayOf(PropTypes.arrayOf(PropTypes.string)).isRequired,
    onChange: PropTypes.func.isRequired,
    intl: PropTypes.object.isRequired,
  };

  state = {
    open: false,
    placement: 'bottom',
  };

  handleToggle = () => {
    if (this.state.open && this.activeElement) {
      this.activeElement.focus({ preventScroll: true });
    } else if (!this.state.open) {
      this.activeElement = document.activeElement;
    }

    this.setState({ open: !this.state.open });
  };

  handleClose = () => {
    if (this.state.open && this.activeElement) {
      this.activeElement.focus({ preventScroll: true });
    }

    this.setState({ open: false });
  };

  handleChange = value => {
    if (value && value !== this.props.value) {
      this.props.onChange(value);
    }
  };

  setTargetRef = c => {
    this.target = c;
  };

  findTarget = () => this.target;

  handleOverlayEnter = (state) => {
    this.setState({ placement: state.placement });
  };

  render () {
    const { value, label, ariaLabel, languages, intl } = this.props;
    const { open, placement } = this.state;

    return (
      <span className={classnames('status__translation-bar__picker', placement, { active: open })}>
        <button
          type='button'
          className='status__translation-bar__language'
          aria-label={ariaLabel}
          aria-haspopup='listbox'
          aria-expanded={open}
          ref={this.setTargetRef}
          onClick={this.handleToggle}
        >
          <span className='status__translation-bar__language-label'>{label}</span>
          <span aria-hidden='true'> ▾</span>
        </button>

        <Overlay show={open} placement='bottom' flip target={this.findTarget} popperConfig={{ strategy: 'fixed', onFirstUpdate: this.handleOverlayEnter }}>
          {({ props }) => (
            <div {...props} {...interactionBoundary}>
              <div className={`dropdown-animation language-dropdown__dropdown ${placement}`}>
                <LanguageDropdownMenu
                  value={value}
                  languages={languages}
                  frequentlyUsedLanguages={[]}
                  onClose={this.handleClose}
                  onChange={this.handleChange}
                  intl={intl}
                />
              </div>
            </div>
          )}
        </Overlay>
      </span>
    );
  }

}

export default class TranslationBar extends React.PureComponent {

  static propTypes = {
    status: ImmutablePropTypes.map,
    translation: ImmutablePropTypes.map,
    mode: PropTypes.string,
    pending: PropTypes.bool,
    preferredMode: PropTypes.string,
    viewerSource: PropTypes.string,
    viewerTarget: PropTypes.string,
    detectedSource: PropTypes.string,
    showResult: PropTypes.bool,
    translationLanguages: ImmutablePropTypes.map,
    pairSupported: PropTypes.bool,
    languagesKnown: PropTypes.bool,
    statusTranslatable: PropTypes.bool,
    canRequest: PropTypes.bool,
    onSelect: PropTypes.func,
    onChangeSource: PropTypes.func,
    onChangeTarget: PropTypes.func,
    intl: PropTypes.object.isRequired,
  };

  renderModeButton = (mode, label, pressed) => (
    <button
      key={mode}
      type='button'
      data-mode={mode}
      className={classnames('status__translation-controls__mode', { active: pressed })}
      aria-pressed={pressed}
      disabled={this.props.pending}
      onClick={this.handleSelect}
    >
      {label}
    </button>
  );

  renderActionButton = (action, label, preferred, disabled, description, descriptionId) => (
    <button
      key={action}
      type='button'
      data-mode={action}
      className={classnames('status__content__translate-button', {
        'status__content__translate-button--primary': action === preferred,
        'status__content__translate-button--secondary': action !== preferred,
      })}
      disabled={disabled || this.props.pending}
      title={description || undefined}
      aria-describedby={description ? descriptionId : undefined}
      onClick={this.handleSelect}
    >
      {label}
    </button>
  );

  handleSelect = (event) => {
    const mode = event.currentTarget.getAttribute('data-mode');

    if (this.props.onSelect) {
      this.props.onSelect(mode);
    }
  };

  render () {
    const {
      status,
      translation,
      mode,
      preferredMode,
      viewerSource,
      viewerTarget,
      detectedSource,
      showResult,
      translationLanguages,
      pairSupported,
      languagesKnown,
      statusTranslatable,
      canRequest,
      onChangeSource,
      onChangeTarget,
      intl,
    } = this.props;

    const unspecifiedName = intl.formatMessage(messages.unspecified);
    const sourceLabel = languageName(viewerSource, intl);
    const targetLabel = languageName(viewerTarget, intl);
    const defaultTarget = normalizedContentLocale(intl.locale);
    const sourceLanguages = sourceLanguageOptions(translationLanguages, viewerSource, preloadedLanguages, unspecifiedName);
    const targetLanguages = targetLanguageOptions(translationLanguages, viewerSource, viewerTarget, preloadedLanguages, unspecifiedName, defaultTarget);
    const descriptionId = `translation-pair-${status ? status.get('id') : 'status'}`;
    const showActions = !!canRequest && !!statusTranslatable && !!languagesKnown && !showResult;
    const pairUnsupported = showActions && !pairSupported;
    const sameLanguage = sameTranslationLanguage(viewerSource, viewerTarget, translationLanguages);
    const showChineseScriptGuidance = pairUnsupported && !sameLanguage && needsChineseScriptChoice(viewerSource, viewerTarget, translationLanguages);
    const showUnsupportedPairMessage = pairUnsupported && !sameLanguage && !showChineseScriptGuidance;
    let actionDescription = null;

    if (showChineseScriptGuidance) {
      actionDescription = intl.formatMessage(messages.chooseChineseScript);
    } else if (showUnsupportedPairMessage) {
      actionDescription = intl.formatMessage(messages.unsupportedPair);
    }
    const requestActions = preTranslationRequestModes(preferredMode);
    const preferred = requestActions.length === 1 ? requestActions[0] : null;
    const provider = showResult ? translation?.get('provider') : null;
    const detectedCode = (detectedSource || '').trim();
    const detectedDiffers = showResult && detectedCode !== '' && detectedCode !== viewerSource;
    const detectedName = detectedDiffers ? languageName(detectedCode, intl) : '';

    return (
      <div className='status__translation-bar status__translation-controls' {...interactionBoundary}>
        <div className='status__translation-bar__languages'>
          <LanguageSelector
            value={viewerSource}
            label={sourceLabel}
            ariaLabel={intl.formatMessage(messages.sourceLanguage, { language: sourceLabel })}
            languages={sourceLanguages}
            onChange={onChangeSource}
            intl={intl}
          />
          <span className='status__translation-bar__arrow' aria-hidden='true'>→</span>
          <LanguageSelector
            value={viewerTarget}
            label={targetLabel}
            ariaLabel={intl.formatMessage(messages.targetLanguage, { language: targetLabel })}
            languages={targetLanguages}
            onChange={onChangeTarget}
            intl={intl}
          />
          {detectedName && (
            <span className='status__translation-bar__detected'>
              {intl.formatMessage(messages.detectedSource, { language: detectedName })}
            </span>
          )}
          {provider && <span className='status__translation-bar__provider'>· {provider}</span>}
        </div>

        {showResult && (
          <div className='status__translation-bar__actions status__translation-controls__modes' role='group' aria-label={intl.formatMessage(messages.translationModes)}>
            {this.renderModeButton('original', intl.formatMessage(messages.original), mode === 'original')}
            <span className='status__translation-controls__separator' aria-hidden='true'>|</span>
            {this.renderModeButton('translated', intl.formatMessage(messages.translated), mode === 'translated')}
            <span className='status__translation-controls__separator' aria-hidden='true'>|</span>
            {this.renderModeButton('bilingual', intl.formatMessage(messages.bilingual), mode === 'bilingual')}
          </div>
        )}

        {showActions && !showResult && (
          <div className='status__translation-bar__actions'>
            {requestActions.map(action => this.renderActionButton(
              action,
              action === 'bilingual' ? intl.formatMessage(messages.bilingual) : intl.formatMessage(messages.translate),
              preferred,
              pairUnsupported,
              actionDescription,
              descriptionId,
            ))}
          </div>
        )}

        {(showUnsupportedPairMessage || showChineseScriptGuidance) && (
          <p className='status__translation-bar__note' id={descriptionId}>
            {actionDescription}
          </p>
        )}
      </div>
    );
  }

}

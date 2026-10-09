import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { defineMessages, injectIntl } from 'react-intl';
import classNames from 'classnames';

const messages = defineMessages({
  label: { id: 'compose_form.posting_style.label', defaultMessage: 'Posting style' },
  usual: { id: 'compose_form.posting_style.usual', defaultMessage: 'Usual settings' },
  placeOnly: { id: 'compose_form.posting_style.place_only', defaultMessage: 'This place only' },
  settings: { id: 'compose_form.posting_style.settings', defaultMessage: 'Posting style settings' },
  destination: { id: 'compose_form.posting_style.destination', defaultMessage: 'Destination {label}' },
  pending: { id: 'compose_form.posting_style.pending', defaultMessage: 'Checking the destination' },
  failed: { id: 'compose_form.posting_style.failed', defaultMessage: 'Can’t post because the destination could not be verified' },
  failedError: { id: 'compose_form.posting_style.failed_error', defaultMessage: 'Couldn’t reach the destination. Choose the style again or retry.' },
  failedUnsupported: { id: 'compose_form.posting_style.failed_unsupported', defaultMessage: 'This destination isn’t supported, so you can’t post.' },
  retry: { id: 'compose_form.posting_style.retry', defaultMessage: 'Retry' },
  catalogFailed: { id: 'compose_form.posting_style.catalog_failed', defaultMessage: 'Couldn’t load posting styles.' },
  catalogRetry: { id: 'compose_form.posting_style.catalog_retry', defaultMessage: 'Reload posting styles' },
  defaultLabel: { id: 'compose_form.posting_style.default_label', defaultMessage: 'Default for this place' },
  defaultUse: { id: 'compose_form.posting_style.default_use', defaultMessage: 'Always use this style here' },
  defaultNone: { id: 'compose_form.posting_style.default_none', defaultMessage: 'Don’t use a style here' },
  defaultAuto: { id: 'compose_form.posting_style.default_auto', defaultMessage: 'Return to automatic selection' },
  defaultSaved: { id: 'compose_form.posting_style.default_saved', defaultMessage: 'This place uses this style by default' },
  defaultNoneSaved: { id: 'compose_form.posting_style.default_none_saved', defaultMessage: 'This place does not use a style' },
  defaultUnavailable: { id: 'compose_form.posting_style.default_unavailable', defaultMessage: 'The saved style for this place isn’t available' },
  defaultMark: { id: 'compose_form.posting_style.default_mark', defaultMessage: 'Default' },
  defaultSaving: { id: 'compose_form.posting_style.default_saving', defaultMessage: 'Saving the default for this place' },
  defaultFailed: { id: 'compose_form.posting_style.default_failed', defaultMessage: 'Couldn’t save the default for this place.' },
  defaultLoadFailed: { id: 'compose_form.posting_style.default_load_failed', defaultMessage: 'Couldn’t load the default for this place.' },
  defaultRetry: { id: 'compose_form.posting_style.default_retry', defaultMessage: 'Reload the default for this place' },
  unapplied: { id: 'compose_form.posting_style.unapplied', defaultMessage: 'Not applied: {fields}' },
  conflict: { id: 'compose_form.posting_style.conflict', defaultMessage: 'Can’t post because visibility does not meet the destination' },
  fieldPrivacy: { id: 'compose_form.posting_style.field.privacy', defaultMessage: 'visibility' },
  fieldLanguage: { id: 'compose_form.posting_style.field.language', defaultMessage: 'language' },
  fieldSpoiler: { id: 'compose_form.posting_style.field.spoiler', defaultMessage: 'content warning' },
  fieldSensitive: { id: 'compose_form.posting_style.field.sensitive', defaultMessage: 'sensitive media' },
  fieldDestination: { id: 'compose_form.posting_style.field.destination', defaultMessage: 'destination' },
});

const fieldMessage = {
  privacy: messages.fieldPrivacy,
  language: messages.fieldLanguage,
  spoiler: messages.fieldSpoiler,
  sensitive: messages.fieldSensitive,
  destination: messages.fieldDestination,
};

let pickerSequence = 0;

const destinationLabel = style => {
  if (!style || !style.getIn) {
    return null;
  }

  const kind = style.getIn(['target', 'kind']);
  const label = style.getIn(['target', 'label']);

  if (kind === 'none' || !label) {
    return null;
  }

  return label;
};

class UserPostingStylePicker extends React.PureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    styles: ImmutablePropTypes.list,
    selectedId: PropTypes.string,
    snapshot: ImmutablePropTypes.map,
    unapplied: ImmutablePropTypes.list,
    destinationStatus: PropTypes.string,
    destinationFailure: PropTypes.string,
    visibilityConflict: PropTypes.bool,
    onSelect: PropTypes.func.isRequired,
    onRetry: PropTypes.func,
    onSaveDefault: PropTypes.func,
    onUseNoStyle: PropTypes.func,
    onResetDefault: PropTypes.func,
    onRetryAssignment: PropTypes.func,
    emptyLabel: PropTypes.oneOf(['usual', 'place']),
    compact: PropTypes.bool,
    showDefaults: PropTypes.bool,
    assignmentFetchStatus: PropTypes.string,
    assignmentStatus: PropTypes.string,
    assignmentStyleId: PropTypes.string,
    assignmentFailure: PropTypes.string,
  };

  state = {
    open: false,
  };

  root = null;

  trigger = null;

  constructor (props) {
    super(props);
    pickerSequence += 1;
    this.menuId = `posting-style-menu-${pickerSequence}`;
    this.labelId = `posting-style-label-${pickerSequence}`;
  }

  setRoot = node => {
    this.root = node;
  };

  setTrigger = node => {
    this.trigger = node;
  };

  componentDidUpdate (_prevProps, prevState) {
    if (!this.state.open || prevState.open || !this.root) {
      return;
    }

    const selected = this.root.querySelector('.compose-form__style-option.active') || this.root.querySelector('.compose-form__style-option');

    if (selected) {
      selected.focus();
    }
  }

  closeMenu = ({ focusTrigger = false } = {}) => {
    this.setState({ open: false }, () => {
      if (focusTrigger && this.trigger) {
        this.trigger.focus();
      }
    });
  };

  focusOption = offset => {
    if (!this.root) {
      return;
    }

    const options = Array.from(this.root.querySelectorAll('.compose-form__style-option'));

    if (options.length === 0) {
      return;
    }

    const index = options.indexOf(document.activeElement);
    let next = 0;

    if (index < 0) {
      next = offset > 0 ? 0 : options.length - 1;
    } else {
      next = (index + offset + options.length) % options.length;
    }

    options[next].focus();
  };

  handleMenuKey = event => {
    if (event.key === 'ArrowDown') {
      event.preventDefault();
      this.focusOption(1);
      return;
    }

    if (event.key === 'ArrowUp') {
      event.preventDefault();
      this.focusOption(-1);
      return;
    }

    if (event.key !== 'Enter' && event.key !== ' ') {
      return;
    }

    const option = event.target.closest('.compose-form__style-option');

    if (!option || !this.root || !this.root.contains(option)) {
      return;
    }

    event.preventDefault();
    option.click();
  };

  componentDidMount () {
    document.addEventListener('mousedown', this.handleDocumentClick);
    document.addEventListener('keydown', this.handleDocumentKey);
  }

  componentWillUnmount () {
    document.removeEventListener('mousedown', this.handleDocumentClick);
    document.removeEventListener('keydown', this.handleDocumentKey);
  }

  handleDocumentClick = event => {
    if (!this.state.open || !this.root || this.root.contains(event.target)) {
      return;
    }

    this.setState({ open: false });
  };

  handleDocumentKey = event => {
    if (event.key === 'Escape' && this.state.open) {
      event.preventDefault();
      this.closeMenu({ focusTrigger: true });
    }
  };

  handleToggle = () => {
    this.setState(state => ({ open: !state.open }));
  };

  handleSelect = event => {
    const styleId = event.currentTarget.getAttribute('data-style-id');

    this.closeMenu({ focusTrigger: true });
    this.props.onSelect(styleId || null);
  };

  handleSaveDefault = () => {
    const { onSaveDefault, selectedId, assignmentFetchStatus } = this.props;

    if (!onSaveDefault || !selectedId || assignmentFetchStatus === 'saving') {
      return;
    }

    onSaveDefault(selectedId);
  };

  handleUseNoStyle = () => {
    const { onUseNoStyle, assignmentFetchStatus } = this.props;

    if (!onUseNoStyle || assignmentFetchStatus === 'saving') {
      return;
    }

    onUseNoStyle();
  };

  handleResetDefault = () => {
    const { onResetDefault, assignmentFetchStatus } = this.props;

    if (!onResetDefault || assignmentFetchStatus === 'saving') {
      return;
    }

    onResetDefault();
  };

  currentStyle () {
    const { styles, selectedId, snapshot } = this.props;

    if (!selectedId) {
      return null;
    }

    if (snapshot && snapshot.get && snapshot.get('id') === selectedId) {
      return snapshot;
    }

    return styles && styles.find(style => style.get('id') === selectedId);
  }

  renderOption (style) {
    const { intl, selectedId } = this.props;
    const id = style ? style.get('id') : null;
    const label = style ? destinationLabel(style) : null;
    const purpose = style ? style.get('purpose') : '';
    const icon = style ? style.get('icon') : '';
    const name = style ? style.get('name') : this.emptyOptionLabel();

    return (
      <button
        key={id || 'usual'}
        type='button'
        role='menuitemradio'
        data-style-id={id || ''}
        aria-checked={selectedId === id || (!selectedId && !style)}
        className={classNames('compose-form__style-option', { active: selectedId === id || (!selectedId && !style) })}
        onClick={this.handleSelect}
      >
        <span className='compose-form__style-option-main'>
          {icon ? <span className='compose-form__style-icon' aria-hidden='true'>{icon}</span> : null}
          <span className='compose-form__style-name'>{name}</span>
        </span>
        {purpose ? <span className='compose-form__style-purpose'>{purpose}</span> : null}
        {label ? <span className='compose-form__style-destination'>{intl.formatMessage(messages.destination, { label })}</span> : null}
      </button>
    );
  }

  emptyOptionLabel () {
    const { intl, emptyLabel } = this.props;

    if (emptyLabel === 'place') {
      return intl.formatMessage(messages.placeOnly);
    }

    return intl.formatMessage(messages.usual);
  }

  failureMessage () {
    const { intl, destinationFailure } = this.props;

    if (destinationFailure === 'unsupported') {
      return intl.formatMessage(messages.failedUnsupported);
    }

    if (destinationFailure === 'error') {
      return intl.formatMessage(messages.failedError);
    }

    return intl.formatMessage(messages.failed);
  }

  savedStyleMatches () {
    const { assignmentFetchStatus, assignmentStatus, assignmentStyleId, selectedId } = this.props;

    return assignmentFetchStatus === 'ready'
      && assignmentStatus === 'style'
      && Boolean(selectedId)
      && assignmentStyleId === selectedId;
  }

  renderDefaultActions () {
    const {
      intl,
      showDefaults,
      selectedId,
      assignmentFetchStatus,
      assignmentStatus,
      onSaveDefault,
      onUseNoStyle,
      onResetDefault,
      onRetryAssignment,
      assignmentFailure,
    } = this.props;

    if (!showDefaults || !onSaveDefault || !onUseNoStyle || !onResetDefault) {
      return null;
    }

    if (!assignmentFetchStatus || assignmentFetchStatus === 'idle') {
      return null;
    }

    const saving = assignmentFetchStatus === 'saving';
    const ready = assignmentFetchStatus === 'ready';
    const known = ready || assignmentFetchStatus === 'failed';
    const usePressed = this.savedStyleMatches();
    const nonePressed = ready && assignmentStatus === 'none';
    const autoPressed = ready && assignmentStatus === 'unset';

    return (
      <div className='compose-form__style-defaults' role='group' aria-label={intl.formatMessage(messages.defaultLabel)} data-posting-style-defaults='true'>
        {saving ? <p className='compose-form__style-default-status'>{intl.formatMessage(messages.defaultSaving)}</p> : null}
        {ready && usePressed ? <p className='compose-form__style-default-status'>{intl.formatMessage(messages.defaultSaved)}</p> : null}
        {ready && assignmentStatus === 'none' ? <p className='compose-form__style-default-status'>{intl.formatMessage(messages.defaultNoneSaved)}</p> : null}
        {ready && assignmentStatus === 'unavailable' ? <p className='compose-form__style-default-status'>{intl.formatMessage(messages.defaultUnavailable)}</p> : null}
        {assignmentFailure === 'save' ? <p className='compose-form__style-notice'>{intl.formatMessage(messages.defaultFailed)}</p> : null}
        {assignmentFetchStatus === 'failed' && assignmentFailure !== 'save' ? (
          <React.Fragment>
            <p className='compose-form__style-notice'>{intl.formatMessage(messages.defaultLoadFailed)}</p>
            {onRetryAssignment ? (
              <button type='button' className='compose-form__style-retry' onClick={onRetryAssignment}>
                {intl.formatMessage(messages.defaultRetry)}
              </button>
            ) : null}
          </React.Fragment>
        ) : null}
        <button
          type='button'
          className='compose-form__style-default-action'
          aria-pressed={usePressed}
          disabled={!known || saving || !selectedId || usePressed}
          onClick={this.handleSaveDefault}
        >
          {intl.formatMessage(messages.defaultUse)}
        </button>
        <button
          type='button'
          className='compose-form__style-default-action'
          aria-pressed={nonePressed}
          disabled={!known || saving || nonePressed}
          onClick={this.handleUseNoStyle}
        >
          {intl.formatMessage(messages.defaultNone)}
        </button>
        <button
          type='button'
          className='compose-form__style-default-action'
          aria-pressed={autoPressed}
          disabled={!known || saving || autoPressed}
          onClick={this.handleResetDefault}
        >
          {intl.formatMessage(messages.defaultAuto)}
        </button>
      </div>
    );
  }

  renderNotices () {
    const { intl, unapplied, destinationStatus, visibilityConflict, onRetry } = this.props;
    const notices = [];

    if (destinationStatus === 'pending' || destinationStatus === 'needs_resolve') {
      notices.push(intl.formatMessage(messages.pending));
    } else if (destinationStatus === 'failed') {
      notices.push(this.failureMessage());
    }

    if (visibilityConflict) {
      notices.push(intl.formatMessage(messages.conflict));
    }

    const fields = unapplied ? unapplied.filter(field => fieldMessage[field]).toArray() : [];

    if (fields.length > 0) {
      notices.push(intl.formatMessage(messages.unapplied, {
        fields: fields.map(field => intl.formatMessage(fieldMessage[field])).join(', '),
      }));
    }

    if (notices.length === 0) {
      return null;
    }

    return (
      <div className='compose-form__style-notices'>
        {notices.map(notice => (
          <p key={notice} className='compose-form__style-notice'>{notice}</p>
        ))}
        {destinationStatus === 'failed' && onRetry ? (
          <button type='button' className='compose-form__style-retry' onClick={onRetry}>
            {intl.formatMessage(messages.retry)}
          </button>
        ) : null}
      </div>
    );
  }

  render () {
    const { intl, compact } = this.props;
    const current = this.currentStyle();
    const icon = current ? current.get('icon') : '';
    const name = current ? current.get('name') : this.emptyOptionLabel();
    const label = destinationLabel(current);
    const defaultActions = this.renderDefaultActions();

    return (
      <div className={classNames('compose-form__style', { 'compose-form__style--compact': compact })} ref={this.setRoot} data-posting-style-picker='true'>
        <div className='compose-form__style-label' id={this.labelId}>{intl.formatMessage(messages.label)}</div>
        <button
          type='button'
          className='compose-form__style-button'
          aria-expanded={this.state.open}
          aria-haspopup='menu'
          aria-controls={this.menuId}
          ref={this.setTrigger}
          onClick={this.handleToggle}
        >
          {icon ? <span className='compose-form__style-icon' aria-hidden='true'>{icon}</span> : null}
          <span className='compose-form__style-name'>{name}</span>
          {compact && this.savedStyleMatches() ? <span className='compose-form__style-default-mark'>{intl.formatMessage(messages.defaultMark)}</span> : null}
          {compact ? <span className='compose-form__style-caret' aria-hidden='true'>▾</span> : null}
        </button>
        {label ? <div className='compose-form__style-current-destination'>{intl.formatMessage(messages.destination, { label })}</div> : null}
        {this.state.open && (
          <div className='compose-form__style-menu'>
            <div
              id={this.menuId}
              className='compose-form__style-options'
              role='menu'
              tabIndex={-1}
              aria-labelledby={this.labelId}
              onKeyDown={this.handleMenuKey}
            >
              {this.renderOption(null)}
              {this.props.styles && this.props.styles.map(style => this.renderOption(style))}
            </div>
            <a className='compose-form__style-settings' href='/settings/user_posting_contexts'>
              {intl.formatMessage(messages.settings)}
            </a>
          </div>
        )}
        {defaultActions}
        {this.renderNotices()}
      </div>
    );
  }

}

export class UserPostingStyleCatalogNotice extends React.PureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    onRetry: PropTypes.func.isRequired,
  };

  render () {
    const { intl, onRetry } = this.props;

    return (
      <div className='compose-form__style' data-posting-style-catalog='failed'>
        <p className='compose-form__style-notice'>{intl.formatMessage(messages.catalogFailed)}</p>
        <button type='button' className='compose-form__style-retry' onClick={onRetry}>
          {intl.formatMessage(messages.catalogRetry)}
        </button>
      </div>
    );
  }

}

export default injectIntl(UserPostingStylePicker);
export const IntlUserPostingStyleCatalogNotice = injectIntl(UserPostingStyleCatalogNotice);

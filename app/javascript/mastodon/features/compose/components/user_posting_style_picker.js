import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { defineMessages, injectIntl } from 'react-intl';
import classNames from 'classnames';

const messages = defineMessages({
  label: { id: 'compose_form.posting_style.label', defaultMessage: 'Posting style' },
  usual: { id: 'compose_form.posting_style.usual', defaultMessage: 'Usual settings' },
  settings: { id: 'compose_form.posting_style.settings', defaultMessage: 'Posting style settings' },
  destination: { id: 'compose_form.posting_style.destination', defaultMessage: 'Destination {label}' },
  pending: { id: 'compose_form.posting_style.pending', defaultMessage: 'Checking the destination' },
  failed: { id: 'compose_form.posting_style.failed', defaultMessage: 'Can’t post because the destination could not be verified' },
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
    visibilityConflict: PropTypes.bool,
    onSelect: PropTypes.func.isRequired,
  };

  state = {
    open: false,
  };

  root = null;

  setRoot = node => {
    this.root = node;
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
      this.setState({ open: false });
    }
  };

  handleToggle = () => {
    this.setState(state => ({ open: !state.open }));
  };

  handleSelect = event => {
    const styleId = event.currentTarget.getAttribute('data-style-id');

    this.setState({ open: false });
    this.props.onSelect(styleId || null);
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
    const name = style ? style.get('name') : intl.formatMessage(messages.usual);

    return (
      <button
        key={id || 'usual'}
        type='button'
        role='option'
        data-style-id={id || ''}
        aria-selected={selectedId === id || (!selectedId && !style)}
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

  renderNotices () {
    const { intl, unapplied, destinationStatus, visibilityConflict } = this.props;
    const notices = [];

    if (destinationStatus === 'pending' || destinationStatus === 'needs_resolve') {
      notices.push(intl.formatMessage(messages.pending));
    } else if (destinationStatus === 'failed') {
      notices.push(intl.formatMessage(messages.failed));
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
      </div>
    );
  }

  render () {
    const { intl } = this.props;
    const current = this.currentStyle();
    const icon = current ? current.get('icon') : '';
    const name = current ? current.get('name') : intl.formatMessage(messages.usual);
    const label = destinationLabel(current);

    return (
      <div className='compose-form__style' ref={this.setRoot} data-posting-style-picker='true'>
        <div className='compose-form__style-label'>{intl.formatMessage(messages.label)}</div>
        <button
          type='button'
          className='compose-form__style-button'
          aria-expanded={this.state.open}
          aria-haspopup='listbox'
          onClick={this.handleToggle}
        >
          {icon ? <span className='compose-form__style-icon' aria-hidden='true'>{icon}</span> : null}
          <span className='compose-form__style-name'>{name}</span>
        </button>
        {label ? <div className='compose-form__style-current-destination'>{intl.formatMessage(messages.destination, { label })}</div> : null}
        {this.state.open && (
          <div className='compose-form__style-menu' role='listbox'>
            {this.renderOption(null)}
            {this.props.styles && this.props.styles.map(style => this.renderOption(style))}
            <a className='compose-form__style-settings' href='/settings/user_posting_contexts'>
              {intl.formatMessage(messages.settings)}
            </a>
          </div>
        )}
        {this.renderNotices()}
      </div>
    );
  }

}

export default injectIntl(UserPostingStylePicker);

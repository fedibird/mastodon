import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { defineMessages, injectIntl } from 'react-intl';
import classNames from 'classnames';

const messages = defineMessages({
  label: { id: 'compose_form.sender_identity.label', defaultMessage: 'Posting as' },
  hint: { id: 'compose_form.sender_identity.hint', defaultMessage: 'This does not change the account you are logged in as.' },
  unavailable: { id: 'compose_form.sender_identity.unavailable', defaultMessage: 'Posting as this identity isn’t available.' },
  failed: { id: 'compose_form.sender_identity.failed', defaultMessage: 'Couldn’t confirm who this post is from.' },
  retry: { id: 'compose_form.sender_identity.retry', defaultMessage: 'Retry' },
  linked: { id: 'compose_form.sender_identity.linked', defaultMessage: 'Linked account' },
  confirmSwitch: { id: 'compose_form.sender_identity.confirm_switch', defaultMessage: 'Post as @{acct}? The text you are writing stays. This does not change the account you are logged in as.' },
  blockedMedia: { id: 'compose_form.sender_identity.blocked_media', defaultMessage: 'Remove attached media before posting as another account.' },
  blockedPoll: { id: 'compose_form.sender_identity.blocked_poll', defaultMessage: 'Remove the poll before posting as another account.' },
  blockedReply: { id: 'compose_form.sender_identity.blocked_reply', defaultMessage: 'Replies and quotes cannot be posted as another account yet.' },
  blockedGroup: { id: 'compose_form.sender_identity.blocked_group', defaultMessage: 'Group posts cannot be posted as another account yet.' },
  blockedSchedule: { id: 'compose_form.sender_identity.blocked_schedule', defaultMessage: 'Scheduled and expiring posts cannot be posted as another account yet.' },
  blockedEdit: { id: 'compose_form.sender_identity.blocked_edit', defaultMessage: 'Finish or discard this edit before changing the posting account.' },
  blockedGeneric: { id: 'compose_form.sender_identity.blocked_generic', defaultMessage: 'This posting account cannot be selected for the draft you are writing.' },
});

const blockMessage = reason => {
  switch (reason) {
  case 'media':
  case 'media_uploading':
    return messages.blockedMedia;
  case 'poll':
    return messages.blockedPoll;
  case 'reply':
  case 'quote':
    return messages.blockedReply;
  case 'group':
    return messages.blockedGroup;
  case 'schedule':
  case 'schedule_bound':
    return messages.blockedSchedule;
  case 'edit_bound':
    return messages.blockedEdit;
  default:
    return messages.blockedGeneric;
  }
};

const accountField = (account, camel, snake) => {
  if (!account || !account.get) {
    return '';
  }

  return account.get(camel) || account.get(snake) || '';
};

const accountAcct = account => accountField(account, 'acct', 'acct');

const accountName = account => accountField(account, 'displayName', 'display_name');

const accountAvatar = account => accountField(account, 'avatarStatic', 'avatar_static') || accountField(account, 'avatar', 'avatar');

class SenderIdentity extends React.PureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    current: ImmutablePropTypes.map,
    failed: PropTypes.bool,
    onRetry: PropTypes.func,
    compact: PropTypes.bool,
    choices: ImmutablePropTypes.list,
    selectedId: PropTypes.string,
    sessionIdentityId: PropTypes.string,
    onSelect: PropTypes.func,
    blockReason: PropTypes.string,
    text: PropTypes.string,
  };

  handleChoiceClick = event => {
    this.handleSelect(event.currentTarget.getAttribute('data-identity-id'));
  };

  handleSelect = identityId => {
    const { intl, onSelect, selectedId, text, choices } = this.props;

    if (!onSelect || identityId === selectedId) {
      return;
    }

    const choice = choices && choices.find(item => item.get('id') === identityId);
    const acct = choice ? accountAcct(choice.get('account')) : '';
    const draft = typeof text === 'string' && text.trim() !== '';

    if (draft) {
      const confirmed = window.confirm(intl.formatMessage(messages.confirmSwitch, { acct }));

      if (!confirmed) {
        return;
      }
    }

    onSelect(identityId, { confirmed: true });
  };

  handleKeyDown = event => {
    const choices = this.postableChoices();

    if (!choices.length || (event.key !== 'ArrowRight' && event.key !== 'ArrowLeft' && event.key !== 'ArrowDown' && event.key !== 'ArrowUp')) {
      return;
    }

    event.preventDefault();
    const ids = choices.map(item => item.get('id'));
    const index = Math.max(0, ids.indexOf(this.props.selectedId));
    const forward = event.key === 'ArrowRight' || event.key === 'ArrowDown';
    const next = ids[(index + (forward ? 1 : ids.length - 1)) % ids.length];

    this.handleSelect(next);
  };

  postableChoices () {
    const { choices, sessionIdentityId } = this.props;
    const list = choices && choices.filter ? choices : null;

    if (!list) {
      return [];
    }

    const filtered = list.filter(item => {
      if (!item || item.get('authorization') !== 'ready') {
        return false;
      }

      if (item.get('kind') === 'delegated') {
        return item.getIn(['capabilities', 'post']) === 'supported';
      }

      if (item.get('kind') === 'local') {
        return Boolean(sessionIdentityId) && item.get('id') === sessionIdentityId;
      }

      return false;
    });

    return filtered.toArray ? filtered.toArray() : filtered;
  }

  renderAvatar (account) {
    const src = accountAvatar(account);

    if (!src) {
      return null;
    }

    return <img className='compose-form__sender-avatar' src={src} alt='' />;
  }

  renderIdentity (account) {
    const acct = accountAcct(account);
    const name = accountName(account);

    return (
      <React.Fragment>
        {this.renderAvatar(account)}
        <span className='compose-form__sender-acct'>
          {acct ? `@${acct}` : name}
        </span>
      </React.Fragment>
    );
  }

  renderChoice (item) {
    const selected = item.get('id') === this.props.selectedId;
    const account = item.get('account');
    const acct = accountAcct(account);
    const linked = item.get('kind') === 'delegated';
    const label = linked
      ? this.props.intl.formatMessage(messages.linked)
      : this.props.intl.formatMessage(messages.label);

    return (
      <button
        key={item.get('id')}
        type='button'
        role='radio'
        aria-checked={selected}
        className={classNames('compose-form__sender-choice', { active: selected })}
        data-identity-id={item.get('id')}
        onClick={this.handleChoiceClick}
      >
        {this.renderIdentity(account)}
        <span className='compose-form__sender-kind'>{label}</span>
        <span className='sr-only'>{selected ? acct : ''}</span>
      </button>
    );
  }

  render () {
    const { intl, current, failed, compact, blockReason, selectedId } = this.props;
    const authorization = current && current.get('authorization');
    const unavailable = authorization && authorization !== 'ready';
    const account = current && current.get('account') ? current.get('account') : current;
    const { sessionIdentityId } = this.props;
    const choices = this.postableChoices();
    const sessionChoice = choices.find(item => item.get('id') === sessionIdentityId);
    const selectable = choices.length > 1 || Boolean(sessionChoice && selectedId && selectedId !== sessionIdentityId);

    return (
      <div
        className={classNames('compose-form__sender', { 'compose-form__sender--compact': compact })}
        data-testid='sender-identity'
        title={intl.formatMessage(messages.hint)}
      >
        <span className='compose-form__sender-label'>{intl.formatMessage(messages.label)}</span>
        {selectable ? (
          <div
            className='compose-form__sender-choices'
            role='radiogroup'
            tabIndex={0}
            aria-label={intl.formatMessage(messages.label)}
            onKeyDown={this.handleKeyDown}
          >
            {choices.map(item => this.renderChoice(item))}
          </div>
        ) : (
          <span className='compose-form__sender-current' data-testid='sender-identity-current'>
            {this.renderIdentity(account)}
          </span>
        )}
        {selectable ? (
          <span className='sr-only' data-testid='sender-identity-current'>
            {accountAcct(choices.find(item => item.get('id') === selectedId)?.get('account') || account)}
          </span>
        ) : null}
        {compact ? null : (
          <p className='compose-form__sender-hint'>{intl.formatMessage(messages.hint)}</p>
        )}
        {blockReason ? (
          <p className='compose-form__sender-status' role='status'>{intl.formatMessage(blockMessage(blockReason))}</p>
        ) : null}
        {failed ? (
          <p className='compose-form__sender-status' role='status'>
            {intl.formatMessage(messages.failed)}
            {this.props.onRetry ? (
              <button type='button' className='compose-form__sender-retry' onClick={this.props.onRetry}>
                {intl.formatMessage(messages.retry)}
              </button>
            ) : null}
          </p>
        ) : null}
        {unavailable && !failed ? (
          <p className='compose-form__sender-status' role='status'>{intl.formatMessage(messages.unavailable)}</p>
        ) : null}
      </div>
    );
  }

}

export default injectIntl(SenderIdentity);

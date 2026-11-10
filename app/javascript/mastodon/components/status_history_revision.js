import React from 'react';
import PropTypes from 'prop-types';
import { FormattedMessage } from 'react-intl';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { List as ImmutableList } from 'immutable';
import escapeTextContentForBrowser from 'escape-html';
import IconButton from 'mastodon/components/icon_button';
import DisplayName from 'mastodon/components/display_name';
import EmojiMutedHtml from 'mastodon/components/emoji_muted_html';
import RelativeTimestamp from 'mastodon/components/relative_timestamp';
import emojify from 'mastodon/features/emoji/emoji';

// The author domain is the remote mute identity. A missing account is not
// guessed from an emoji row. Local identity is only the id on this revision's
// emoji list, written while the HTML is built. A later row that reused the
// shortcode is a different emoji, and a shortcode with no id is left alone.
const authorDomainFromAccount = account => {
  const acct = account && typeof account.get === 'function' ? account.get('acct') : '';

  if (typeof acct !== 'string') {
    return '';
  }

  const at = acct.indexOf('@');

  return at === -1 ? '' : acct.slice(at + 1);
};

const revisionEmojiMap = revision => {
  const emojis = revision && typeof revision.get === 'function' ? revision.get('emojis') : null;
  const map = {};

  if (!emojis || typeof emojis.forEach !== 'function') {
    return map;
  }

  emojis.forEach(emoji => {
    const shortcode = emoji && typeof emoji.get === 'function' ? emoji.get('shortcode') : null;

    if (!shortcode) {
      return;
    }

    map[`:${shortcode}:`] = typeof emoji.toJS === 'function' ? emoji.toJS() : emoji;
  });

  return map;
};

const revisionDisplayHtml = (text, revision, account, escaped) => {
  const source = escaped ? escapeTextContentForBrowser(text || '') : (text || '');

  return emojify(source, revisionEmojiMap(revision), authorDomainFromAccount(account));
};

export default class StatusHistoryRevision extends React.PureComponent {

  static propTypes = {
    revision: ImmutablePropTypes.map,
    account: ImmutablePropTypes.map,
    language: PropTypes.string,
    onClose: PropTypes.func.isRequired,
  };

  render () {
    const { revision, language, onClose, account } = this.props;

    if (!revision) {
      return (
        <div className='modal-root__modal compare-history-modal'>
          <div className='report-modal__target'>
            <IconButton className='report-modal__close' title='Close' icon='times' onClick={onClose} size={20} />
            <FormattedMessage id='status.history.empty' defaultMessage='No edit history' />
          </div>
        </div>
      );
    }

    const contentHtml = revisionDisplayHtml(revision.get('content'), revision, account, false);
    const spoilerText = revision.get('spoiler_text') || '';
    const spoilerHtml = spoilerText ? revisionDisplayHtml(spoilerText, revision, account, true) : '';
    const formattedDate = <RelativeTimestamp timestamp={revision.get('created_at')} short={false} />;
    const formattedName = account ? <DisplayName account={account} /> : null;
    const label = revision.get('original') ? (
      <FormattedMessage id='status.history.created' defaultMessage='{name} created {date}' values={{ name: formattedName, date: formattedDate }} />
    ) : (
      <FormattedMessage id='status.history.edited' defaultMessage='{name} edited {date}' values={{ name: formattedName, date: formattedDate }} />
    );
    const media = revision.get('media_attachments') || ImmutableList();

    return (
      <div className='modal-root__modal compare-history-modal'>
        <div className='report-modal__target'>
          <IconButton className='report-modal__close' title='Close' icon='times' onClick={onClose} size={20} />
          {label}
        </div>

        <div className='compare-history-modal__container'>
          <div className='status__content'>
            {spoilerText.length > 0 && (
              <React.Fragment>
                <EmojiMutedHtml tag='div' className='translate' html={spoilerHtml} lang={language} />
                <hr />
              </React.Fragment>
            )}

            <EmojiMutedHtml tag='div' className='status__content__text status__content__text--visible translate' html={contentHtml} lang={language} />

            {revision.get('sensitive') && (
              <p className='compare-history-modal__sensitive'>
                <FormattedMessage id='status.history.sensitive' defaultMessage='Marked as sensitive' />
              </p>
            )}

            {!!revision.get('poll') && (
              <ul className='compare-history-modal__poll'>
                {revision.getIn(['poll', 'options']).map((option, optionIndex) => (
                  <li key={`${optionIndex}-${option.get('title')}`}>
                    <EmojiMutedHtml html={revisionDisplayHtml(option.get('title'), revision, account, true)} />
                  </li>
                ))}
              </ul>
            )}

            {media.size > 0 && (
              <ul className='compare-history-modal__media'>
                {media.map(item => (
                  <li key={item.get('id')}>
                    <FormattedMessage id='status.history.media_description' defaultMessage='Media description: {description}' values={{ description: item.get('description') || '' }} />
                  </li>
                ))}
              </ul>
            )}

            <p className='compare-history-modal__created'>
              <FormattedMessage id='status.history.revision_time' defaultMessage='Revision time: {date}' values={{ date: formattedDate }} />
            </p>
          </div>
        </div>
      </div>
    );
  }

}

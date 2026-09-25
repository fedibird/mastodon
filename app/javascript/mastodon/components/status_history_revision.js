import React from 'react';
import PropTypes from 'prop-types';
import { FormattedMessage } from 'react-intl';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { List as ImmutableList } from 'immutable';
import IconButton from 'mastodon/components/icon_button';
import DisplayName from 'mastodon/components/display_name';
import RelativeTimestamp from 'mastodon/components/relative_timestamp';
import emojify from 'mastodon/features/emoji/emoji';

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

    const emojiMap = (revision.get('emojis') || ImmutableList()).reduce((obj, emoji) => {
      obj[`:${emoji.get('shortcode')}:`] = emoji.toJS();
      return obj;
    }, {});
    const content = { __html: emojify(revision.get('content') || '', emojiMap) };
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
            {revision.get('spoiler_text') && revision.get('spoiler_text').length > 0 && (
              <React.Fragment>
                <div className='translate' lang={language}>{revision.get('spoiler_text')}</div>
                <hr />
              </React.Fragment>
            )}

            <div className='status__content__text status__content__text--visible translate' dangerouslySetInnerHTML={content} lang={language} />

            {revision.get('sensitive') && (
              <p className='compare-history-modal__sensitive'>
                <FormattedMessage id='status.history.sensitive' defaultMessage='Marked as sensitive' />
              </p>
            )}

            {!!revision.get('poll') && (
              <ul className='compare-history-modal__poll'>
                {revision.getIn(['poll', 'options']).map(option => (
                  <li key={option.get('title')}>{option.get('title')}</li>
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

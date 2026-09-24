import React, { PureComponent } from 'react';
import PropTypes from 'prop-types';
import { FormattedMessage } from 'react-intl';
import classNames from 'classnames';

import Blurhash from 'mastodon/components/blurhash';
import RelativeTimestamp from 'mastodon/components/relative_timestamp';
import ShortNumber from 'mastodon/components/short_number';

const accountsCountRenderer = (displayNumber, pluralReady) => (
  <FormattedMessage
    id='trends.counter_by_accounts'
    defaultMessage='{count, plural, one {{counter} person} other {{counter} people}} talking'
    values={{ count: pluralReady, counter: <strong>{displayNumber}</strong> }}
  />
);

export default class Story extends PureComponent {

  static propTypes = {
    url: PropTypes.string.isRequired,
    title: PropTypes.string,
    lang: PropTypes.string,
    publisher: PropTypes.string,
    publishedAt: PropTypes.string,
    author: PropTypes.string,
    sharedTimes: PropTypes.number.isRequired,
    thumbnail: PropTypes.string,
    thumbnailDescription: PropTypes.string,
    blurhash: PropTypes.string,
    expanded: PropTypes.bool,
  };

  state = {
    thumbnailLoaded: false,
  };

  handleImageLoad = () => this.setState({ thumbnailLoaded: true });

  render () {
    const { expanded, url, title, lang, publisher, author, publishedAt, sharedTimes, thumbnail, thumbnailDescription, blurhash } = this.props;
    const { thumbnailLoaded } = this.state;

    return (
      <a className={classNames('story', { expanded })} href={url} target='_blank' rel='noopener noreferrer'>
        <div className='story__details'>
          <div className='story__details__publisher'>
            <span lang={lang}>{publisher}</span>
            {publishedAt && <> · <RelativeTimestamp timestamp={publishedAt} /></>}
          </div>
          <div className='story__details__title' lang={lang}>{title}</div>
          <div className='story__details__shared'>
            {author && <><FormattedMessage id='link_preview.author' defaultMessage='By {name}' values={{ name: <strong>{author}</strong> }} /> · </>}
            <ShortNumber value={sharedTimes} renderer={accountsCountRenderer} />
          </div>
        </div>

        <div className='story__thumbnail'>
          {thumbnail ? (
            <>
              {blurhash && (
                <div className={classNames('story__thumbnail__preview', { 'story__thumbnail__preview--hidden': thumbnailLoaded })}>
                  <Blurhash hash={blurhash} />
                </div>
              )}
              <img src={thumbnail} onLoad={this.handleImageLoad} alt={thumbnailDescription || ''} title={thumbnailDescription} lang={lang} />
            </>
          ) : <div className='story__thumbnail__placeholder' />}
        </div>
      </a>
    );
  }

}

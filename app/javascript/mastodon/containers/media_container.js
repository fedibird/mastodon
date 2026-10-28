import React, { PureComponent, Fragment } from 'react';
import ReactDOM from 'react-dom';
import PropTypes from 'prop-types';
import { IntlProvider, addLocaleData } from 'react-intl';
import { List as ImmutableList, fromJS } from 'immutable';
import { getLocale } from 'mastodon/locales';
import { getScrollbarWidth } from 'mastodon/utils/scrollbar';
import MediaGallery from 'mastodon/components/media_gallery';
import StatusMediaStack from 'mastodon/components/status_media';
import Poll from 'mastodon/components/poll';
import Hashtag from 'mastodon/components/hashtag';
import ModalRoot from 'mastodon/components/modal_root';
import { PublicMediaModal } from 'mastodon/features/ui/components/media_modal';
import Video from 'mastodon/features/video';
import Card from 'mastodon/features/status/components/card';
import Audio from 'mastodon/features/audio';
import PublicStatusHistory from 'mastodon/components/public_status_history';
import StatusHistoryRevision from 'mastodon/components/status_history_revision';

const { localeData, messages } = getLocale();
addLocaleData(localeData);

const MEDIA_COMPONENTS = {
  MediaGallery,
  Video,
  Card,
  Poll,
  Hashtag,
  Audio,
  StatusMediaStack,
  StatusHistory: PublicStatusHistory,
};

export default class MediaContainer extends PureComponent {

  static propTypes = {
    locale: PropTypes.string.isRequired,
    components: PropTypes.object.isRequired,
  };

  state = {
    media: null,
    index: null,
    time: null,
    backgroundColor: null,
    options: null,
    historyRevision: null,
    historyLanguage: null,
  };

  lockScroll = () => {
    document.body.classList.add('with-modals--active');
    document.documentElement.style.marginRight = `${getScrollbarWidth()}px`;
  }

  handleOpenMedia = (media, index) => {
    this.lockScroll();

    this.setState({
      media,
      index,
      options: null,
      historyRevision: null,
      historyLanguage: null,
    });
  }

  handleOpenVideo = (options) => {
    const { components } = this.props;
    const { media } = JSON.parse(components[options.componetIndex].getAttribute('data-props'));
    const mediaList = fromJS(media);

    this.lockScroll();

    this.setState({
      media: mediaList,
      index: 0,
      options,
      historyRevision: null,
      historyLanguage: null,
    });
  }

  // StatusMediaStack calls this with the attachment that was expanded.
  // A page can hold several players, so the modal must not read media from
  // the host node's full list the way a lone Video component does.
  handleOpenStackedVideo = (attachment, options) => {
    const media = attachment && typeof attachment.get === 'function'
      ? ImmutableList([attachment])
      : fromJS([attachment]);

    this.lockScroll();

    this.setState({
      media,
      index: 0,
      options: options || null,
      historyRevision: null,
      historyLanguage: null,
    });
  }

  handleOpenHistoryRevision = (revision, language) => {
    this.lockScroll();

    this.setState({
      media: null,
      index: null,
      options: null,
      historyRevision: revision,
      historyLanguage: language,
    });
  }

  handleCloseMedia = () => {
    document.body.classList.remove('with-modals--active');
    document.documentElement.style.marginRight = 0;

    this.setState({
      media: null,
      index: null,
      time: null,
      backgroundColor: null,
      options: null,
      historyRevision: null,
      historyLanguage: null,
    });
  }

  setBackgroundColor = color => {
    this.setState({ backgroundColor: color });
  }

  handlersFor (componentName, index) {
    if (componentName === 'Video') {
      return {
        componetIndex: index,
        onOpenVideo: this.handleOpenVideo,
      };
    }

    if (componentName === 'StatusMediaStack') {
      return {
        Gallery: MediaGallery,
        Video,
        Audio,
        onOpenMedia: this.handleOpenMedia,
        onOpenVideo: this.handleOpenStackedVideo,
      };
    }

    return {
      onOpenMedia: this.handleOpenMedia,
    };
  }

  render () {
    const { locale, components } = this.props;

    return (
      <IntlProvider locale={locale} messages={messages}>
        <Fragment>
          {[].map.call(components, (component, i) => {
            const componentName = component.getAttribute('data-component');
            const Component = MEDIA_COMPONENTS[componentName];
            const { media, card, poll, hashtag, ...props } = JSON.parse(component.getAttribute('data-props'));

            const handlers = this.handlersFor(componentName, i);

            Object.assign(props, {
              ...(media   ? { media:   fromJS(media)   } : {}),
              ...(card    ? { card:    fromJS(card)    } : {}),
              ...(poll    ? { poll:    fromJS(poll)    } : {}),
              ...(hashtag ? { hashtag: fromJS(hashtag) } : {}),
              ...handlers,
              ...(componentName === 'StatusHistory' ? {
                onOpenRevision: this.handleOpenHistoryRevision,
              } : {}),
            });

            return ReactDOM.createPortal(
              <Component {...props} key={`media-${i}`} />,
              component,
            );
          })}

          <ModalRoot backgroundColor={this.state.backgroundColor} onClose={this.handleCloseMedia}>
            {this.state.media ? (
              <PublicMediaModal
                media={this.state.media}
                index={this.state.index || 0}
                currentTime={this.state.options?.startTime}
                autoPlay={this.state.options?.autoPlay}
                volume={this.state.options?.defaultVolume}
                onClose={this.handleCloseMedia}
                onChangeBackgroundColor={this.setBackgroundColor}
              />
            ) : this.state.historyRevision ? (
              <StatusHistoryRevision
                revision={this.state.historyRevision}
                account={this.state.historyRevision.get('account')}
                language={this.state.historyLanguage}
                onClose={this.handleCloseMedia}
              />
            ) : null}
          </ModalRoot>
        </Fragment>
      </IntlProvider>
    );
  }

}

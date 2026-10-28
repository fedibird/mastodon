import React from 'react';
import ReactDOM from 'react-dom';
import { IntlProvider } from 'react-intl';
import { createStore } from 'redux';
import { Provider } from 'react-redux';
import { Map as ImmutableMap } from 'immutable';

import ExternalEmbedPlayer from 'mastodon/components/external_embed_player';
import ExternalPlayerDock from 'mastodon/external_player/dock';
import IntersectionObserverArticle from 'mastodon/components/intersection_observer_article';
import IntersectionObserverWrapper from 'mastodon/features/ui/util/intersection_observer_wrapper';

const store = createStore(() => ImmutableMap({ picture_in_picture: {} }));
const fixture = window.__PLAYER_FIXTURE__;
const imageUrl = window.__PLAYER_IMAGE__;

const Page = () => {
  const [warning, setWarning] = React.useState(false);
  const [body, setBody] = React.useState(false);
  const [image, setImage] = React.useState(false);
  const wrapper = React.useMemo(() => new IntersectionObserverWrapper(), []);
  const scrollRef = React.useRef(null);

  React.useEffect(() => {
    if (scrollRef.current) {
      wrapper.connect({ root: scrollRef.current, rootMargin: '0px', threshold: 0 });
    }

    return () => wrapper.disconnect();
  }, [wrapper]);

  return (
    <Provider store={store}>
      <IntlProvider locale='en' messages={{}}>
        <div>
        <div id='column' className='scrollable' ref={scrollRef}>
          <div className='item-list' role='feed'>
            <article id='above' className='status'>
              <button id='toggle-warning' type='button' onClick={() => setWarning((open) => !open)}>Toggle warning</button>
              {warning ? <p id='warning-body'>Content warning body for the post above the player.</p> : null}
              <button id='toggle-body' type='button' onClick={() => setBody((open) => !open)}>Toggle body</button>
              {body ? <p id='post-body'>Expanded post body above the player.</p> : null}
              <button id='show-image' type='button' onClick={() => setImage(true)}>Show image</button>
              {image ? <img id='above-image' alt='' src={imageUrl} /> : null}
            </article>
            <IntersectionObserverArticle id='player-row' index={1} listLength={2} intersectionObserverWrapper={wrapper}>
              <ExternalEmbedPlayer
                statusId='status-1'
                entry={{ id: 'media-1', url: fixture, duration: 61 }}
                articleUrl='https://example.com/article'
              />
            </IntersectionObserverArticle>
          </div>
        </div>
        <ExternalPlayerDock />
        </div>
      </IntlProvider>
    </Provider>
  );
};

ReactDOM.render(<Page />, document.getElementById('app'));

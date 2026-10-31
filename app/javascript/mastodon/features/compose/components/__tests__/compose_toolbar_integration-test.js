import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { List as ImmutableList, Map as ImmutableMap, Set as ImmutableSet } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';

jest.mock('react-intl', () => {
  const intl = {
    formatMessage: ({ defaultMessage }) => defaultMessage,
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

jest.mock('mastodon/initial_state', () => ({
  allowPollImage: false,
  maxAttachments: 2,
  me: '42',
  isAdministrator: true,
  disablePost: false,
  maxChars: 500,
}));

jest.mock('../../containers/reply_indicator_container', () => () => null);
jest.mock('../../containers/quote_indicator_container', () => () => null);
jest.mock('../../containers/poll_button_container', () => () => null);
jest.mock('../../containers/datetime_button_container', () => () => null);
jest.mock('../../containers/spoiler_button_container', () => () => null);
jest.mock('../../containers/privacy_dropdown_container', () => () => <div data-testid='privacy-dropdown' />);
jest.mock('../../containers/searchability_dropdown_container', () => () => null);
jest.mock('../../containers/circle_dropdown_container', () => () => null);
jest.mock('../../containers/datetime_form_container', () => () => null);
jest.mock('../../containers/expires_indicator_container', () => () => null);
jest.mock('../../containers/searchability_indicator_container', () => () => null);
jest.mock('../../containers/emoji_picker_dropdown_container', () => () => null);
jest.mock('../../containers/language_dropdown_container', () => () => null);
jest.mock('../../containers/poll_form_container', () => () => null);
jest.mock('../../containers/upload_form_container', () => () => null);
jest.mock('../../containers/warning_container', () => () => null);
jest.mock('../../../reference_stack', () => () => null);

import { postingContextHasDetails } from '../posting_context_bar';
import { mapStateToProps as postingContextState } from '../../containers/posting_context_bar_container';
import { initialState as composerInitialState } from '../../../../reducers/composer';
import ComposeForm from '../compose_form';

const noop = () => {};

const capabilities = (media = 'supported') => ImmutableMap({
  post: 'supported',
  media,
  reply: 'supported',
  quote: 'supported',
  group: 'supported',
  schedule: 'supported',
});

const localIdentity = capabilitiesValue => ImmutableMap({
  id: 'local:42',
  kind: 'local',
  provider: 'fedibird',
  authorization: 'ready',
  account: ImmutableMap({ id: '42' }),
  capabilities: capabilities(capabilitiesValue),
});

const delegatedIdentity = ImmutableMap({
  id: 'delegated:7',
  kind: 'delegated',
  provider: 'fedibird',
  authorization: 'ready',
  account: ImmutableMap({ id: '99', acct: 'other@example.com' }),
  capabilities: capabilities('supported'),
});

const composerWith = (extra, senderId = 'local:42') => composerInitialState.merge({
  senderIdentity: ImmutableMap({ id: senderId, status: 'ready', selectionOrigin: 'explicit', changeEpoch: 1 }),
  ...extra,
});

const stateFor = (composer, identities = ImmutableList([localIdentity()])) => ImmutableMap({
  compose: composer,
  media_attachments: ImmutableMap({
    accept_content_types: ImmutableList(['image/png', 'image/jpeg', 'video/mp4', 'audio/mpeg']),
  }),
  postingIdentities: ImmutableMap({
    status: 'ready',
    confirmedIdentityId: 'local:42',
    defaultIdentityId: 'local:42',
    identities,
  }),
});

const menuToolbar = [
  { id: 'posting_account', placement: 'hidden' },
  { id: 'media', placement: 'menu' },
  { id: 'cw', placement: 'hidden' },
  { id: 'language', placement: 'hidden' },
  { id: 'datetime', placement: 'hidden' },
  { id: 'searchability', placement: 'hidden' },
  { id: 'poll', placement: 'hidden' },
];

const renderComposer = (state, { openMenu = true } = {}) => {
  const store = {
    getState: () => state,
    dispatch: jest.fn(),
    subscribe: () => () => {},
  };

  render(
    <Provider store={store}>
      <ComposeForm
        text=''
        suggestions={ImmutableList()}
        privacy='public'
        prohibitedVisibilities={ImmutableSet()}
        prohibitedWords={ImmutableSet()}
        onChange={noop}
        onSubmit={noop}
        onClearSuggestions={noop}
        onFetchSuggestions={noop}
        onSuggestionSelected={noop}
        onChangeSpoilerText={noop}
        onPaste={noop}
        onPickEmoji={noop}
        composerToolbar={menuToolbar}
        overflowContextActive={false}
      />
    </Provider>,
  );

  if (openMenu) {
    fireEvent.click(screen.getByRole('button', { name: 'More actions' }));
  }

  return store;
};

const attachButton = () => screen.queryByRole('button', { name: /Add (images, a video or an audio file|a still image)/ });

describe('ComposeForm media menu with the real upload button', () => {
  it('hides the menu row while a poll blocks uploads and restores it afterward', () => {
    renderComposer(stateFor(composerWith({ poll: ImmutableMap({ options: ImmutableList(['a', 'b']) }) })), { openMenu: false });

    expect(screen.queryByRole('button', { name: 'More actions' })).toBeNull();
    expect(attachButton()).toBeNull();

    cleanup();
    renderComposer(stateFor(composerWith({ poll: null })));

    expect(attachButton()).toBeEnabled();
  });

  it('disables the menu row when the attachment limit is reached', () => {
    renderComposer(stateFor(composerWith({
      media_attachments: ImmutableList([
        ImmutableMap({ type: 'image' }),
        ImmutableMap({ type: 'image' }),
      ]),
    })));

    expect(attachButton()).toBeDisabled();
  });

  it('disables the menu row and explains a missing media permission', () => {
    renderComposer(stateFor(
      composerWith({}),
      ImmutableList([localIdentity('unavailable')]),
    ));

    expect(attachButton()).toBeDisabled();
    expect(screen.getByText('Image upload needs posting and media permission for this account.')).toBeTruthy();
  });

  it('uses the still-image label when that account cannot post video or audio', () => {
    renderComposer(stateFor(
      composerWith({}, 'delegated:7'),
      ImmutableList([localIdentity(), delegatedIdentity]),
    ));

    expect(screen.getByRole('button', { name: 'Add a still image' })).toBeEnabled();
    expect(screen.getByText('Still images only.')).toBeTruthy();
  });
});

describe('posting context overflow', () => {
  it('is absent for a normal destination and present when a mention is required', () => {
    const plain = ImmutableMap({ compose: composerInitialState });
    const mentioned = ImmutableMap({
      compose: composerInitialState.setIn(['context', 'managed', 'mentions'], ImmutableList([
        ImmutableMap({ enforcement: 'required', acct: 'group', accountId: '9' }),
      ])),
    });

    expect(postingContextHasDetails(postingContextState(plain, { composerId: 'primary' }))).toBe(false);
    expect(postingContextHasDetails(postingContextState(mentioned, { composerId: 'primary' }))).toBe(true);
  });
});

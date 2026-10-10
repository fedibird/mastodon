import { List as ImmutableList, Map as ImmutableMap, fromJS } from 'immutable';
import { cleanup, render, screen } from '@testing-library/react';
import React from 'react';

jest.mock('react-intl', () => {
  const intl = {
    formatMessage: ({ defaultMessage }, values) => {
      if (!values) {
        return defaultMessage;
      }

      return defaultMessage.replace(/\{(\w+)\}/g, (_, key) => values[key]);
    },
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
  };
});

jest.mock('../../../../initial_state', () => ({
  me: '42',
  isAdministrator: true,
}));

import { initialState as composerInitialState } from '../../../../reducers/composer';
import SenderIdentity from '../../components/sender_identity';
import { mapStateToProps } from '../sender_identity_container';

const adminAccount = ImmutableMap({
  id: '42',
  acct: 'admin',
  display_name: 'Admin',
  avatar_static: '/avatars/admin.png',
});

const localIdentity = fromJS({
  id: 'local:42',
  kind: 'local',
  provider: 'fedibird',
  authorization: 'ready',
  account: {
    id: '42',
    acct: 'admin',
    displayName: 'Admin',
    avatarStatic: '/avatars/admin.png',
  },
  capabilities: { post: 'supported' },
});

const expiredSender = ImmutableMap({
  id: 'delegated:99',
  selectionOrigin: 'explicit',
  status: 'ready',
  changeEpoch: 1,
});

const stateFor = (composerId, { simple = false, senderIdentity = expiredSender, identities = ImmutableList([localIdentity]) } = {}) => {
  const composer = composerInitialState.merge({
    text: 'Keep this draft',
    privacy: 'private',
    spoiler_text: 'cw',
    language: 'ja',
    senderIdentity,
  });
  const shared = {
    accounts: ImmutableMap({ 42: adminAccount }),
    postingIdentities: ImmutableMap({
      status: 'ready',
      defaultIdentityId: 'local:42',
      confirmedIdentityId: 'local:42',
      identities,
    }),
    settings: ImmutableMap({
      portableComposerDisplayMode: ImmutableMap({
        [composerId]: simple ? 'simple' : 'full',
      }),
    }),
  };

  if (composerId === 'primary') {
    return ImmutableMap({
      ...shared,
      compose: composer,
    });
  }

  return ImmutableMap({
    ...shared,
    compose: composerInitialState,
    composers: ImmutableMap({
      byId: ImmutableMap({
        [composerId]: composer,
      }),
    }),
  });
};

const renderSender = (composerId, options) => {
  const props = mapStateToProps(stateFor(composerId, options), { composerId });

  render(<SenderIdentity {...props} />);

  return props;
};

describe('SenderIdentityContainer', () => {
  it('does not show the signed-in account as an expired delegated sender', () => {
    ['primary', 'portable:list-column:b'].forEach(composerId => {
      const props = renderSender(composerId);

      expect(props.selectedId).toEqual('delegated:99');
      expect(props.current.get('account')).toBeUndefined();
      expect(props.current.get('authorization')).toEqual('unavailable');
      expect(props.choices.map(item => item.get('id')).toArray()).toEqual(['local:42']);
      expect(props.sendBlocked).toEqual('unregistered');
      expect(screen.getByText('This linked account is not available right now.')).toBeTruthy();
      expect(screen.getAllByTestId('sender-identity-current').some(node => node.textContent.includes('@admin'))).toBe(false);
      expect(screen.getByRole('radio', { name: /@admin/ })).toBeTruthy();
      expect(screen.getByTestId('sender-identity').textContent).toContain('does not change the account you are logged in as');

      cleanup();
    });
  });

  it('keeps the same unavailable sender in simple mode', () => {
    const props = renderSender('portable:list-column:b', { simple: true });
    const sender = screen.getByTestId('sender-identity');

    expect(props.compact).toBe(true);
    expect(props.current.get('account')).toBeUndefined();
    expect(sender.className).toContain('compose-form__sender--compact');
    expect(screen.getByText('This linked account is not available right now.')).toBeTruthy();
    expect(screen.getByTestId('sender-identity-current').textContent).not.toContain('@admin');
    expect(sender.textContent).not.toContain('does not change the account you are logged in as');
    expect(screen.getByRole('radio', { name: /@admin/ })).toBeTruthy();
  });

  it('still fills the signed-in account when that identity is selected', () => {
    const props = mapStateToProps(stateFor('primary', {
      identities: ImmutableList(),
      senderIdentity: ImmutableMap({
        id: 'local:42',
        selectionOrigin: 'default',
        status: 'ready',
        changeEpoch: 0,
      }),
    }), { composerId: 'primary' });

    expect(props.current.getIn(['account', 'acct'])).toEqual('admin');
    expect(props.selectedId).toEqual('local:42');
    expect(props.sendBlocked).toBeNull();
  });
});

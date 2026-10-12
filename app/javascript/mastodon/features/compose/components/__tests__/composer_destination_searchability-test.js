import { fireEvent, render, screen } from '@testing-library/react';
import { Map as ImmutableMap } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

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
  isAdministrator: false,
  showComposerPostingStyleSelector: true,
}));

import { createComposer } from '../../../../actions/composer';
import compose from '../../../../reducers/compose';
import composers from '../../../../reducers/composers';
import { selectComposer } from '../../../../selectors/composer';
import { PRIMARY_COMPOSER_ID } from '../../../../utils/composer';
import { ComposerProvider } from '../../composer_id_context';
import SearchabilityDropdownContainer from '../../containers/searchability_dropdown_container';
import UserPostingStylePicker from '../../containers/user_posting_style_picker_container';
import SearchabilityDropdown from '../searchability_dropdown';
import ComposerContextDetails from '../composer_context_details';
import ComposerDestinationSummary from '../composer_destination_summary';
import { eventInOwnedSearchabilityPopup } from '../../searchability_popup';

const portableId = 'portable:hashtag-column:books';
const userIsTouching = () => true;

const reduce = (state, action) => {
  if (!state || !action || action.type === '@@INIT') {
    return state;
  }

  return state
    .set('compose', compose(state.get('compose'), action))
    .set('composers', composers(state.get('composers'), action));
};

const baseState = () => ImmutableMap({
  compose: compose(undefined, { type: '@@INIT' }),
  composers: composers(undefined, createComposer(portableId)),
});

const renderDestination = (store, composerId, contextDetails = <SearchabilityDropdownContainer />) => {
  render(
    <Provider store={store}>
      <ComposerProvider composerId={composerId}>
        <UserPostingStylePicker header contextDetails={contextDetails} />
      </ComposerProvider>
    </Provider>,
  );
};

const openSearchability = () => {
  fireEvent.click(screen.getByRole('button', { name: 'Destination details' }));
  fireEvent.click(screen.getByRole('button', { name: 'Adjust status searchability' }));

  return screen.getByRole('option', { name: /Searchable for all/ });
};

describe('composer destination searchability', () => {
  it('ignores another composer’s portaled searchability menu', () => {
    const popup = document.createElement('div');
    const option = document.createElement('div');

    popup.setAttribute('data-searchability-popup', portableId);
    popup.appendChild(option);
    document.body.appendChild(popup);

    expect(eventInOwnedSearchabilityPopup({ target: option }, PRIMARY_COMPOSER_ID)).toBe(false);
    expect(eventInOwnedSearchabilityPopup({ target: option }, portableId)).toBe(true);
    expect(eventInOwnedSearchabilityPopup({ target: option }, '')).toBe(false);

    popup.remove();
  });

  [PRIMARY_COMPOSER_ID, portableId].forEach((composerId) => {
    it(`changes searchability from the portaled menu on ${composerId}`, () => {
      const store = createStore(reduce, baseState());

      renderDestination(store, composerId);

      const option = openSearchability();
      const panel = document.querySelector('.compose-form__destination-panel');

      expect(panel.contains(option)).toBe(false);
      expect(option.closest('[data-searchability-popup]').getAttribute('data-searchability-popup')).toBe(composerId);

      fireEvent.mouseDown(option);

      expect(panel.isConnected).toBe(true);
      expect(screen.getByRole('button', { name: 'Destination details' })).toHaveAttribute('aria-expanded', 'true');

      fireEvent.click(option);

      expect(panel.isConnected).toBe(true);
      expect(screen.getByRole('button', { name: 'Destination details' })).toHaveAttribute('aria-expanded', 'true');
      expect(selectComposer(store.getState(), composerId).get('searchability')).toBe('public');
      expect(screen.queryByRole('listbox')).not.toBeInTheDocument();
    });
  });

  it('closes the details panel on a real outside press without changing searchability', () => {
    const store = createStore(reduce, baseState());

    renderDestination(store, PRIMARY_COMPOSER_ID);
    openSearchability();

    fireEvent.mouseDown(document.body);

    expect(document.querySelector('.compose-form__destination-panel')).toBeNull();
    expect(screen.getByRole('button', { name: 'Destination details' })).toHaveAttribute('aria-expanded', 'false');
    expect(selectComposer(store.getState(), PRIMARY_COMPOSER_ID).get('searchability')).toBeNull();
    expect(screen.queryByRole('listbox')).not.toBeInTheDocument();
  });

  it('does not let one composer’s portaled menu own the other composer’s panel', () => {
    const store = createStore(reduce, baseState());

    render(
      <Provider store={store}>
        <ComposerProvider composerId={PRIMARY_COMPOSER_ID}>
          <UserPostingStylePicker header contextDetails={<SearchabilityDropdownContainer />} />
        </ComposerProvider>
        <ComposerProvider composerId={portableId}>
          <UserPostingStylePicker header contextDetails={<SearchabilityDropdownContainer />} />
        </ComposerProvider>
      </Provider>,
    );

    screen.getAllByRole('button', { name: 'Destination details' }).forEach(button => fireEvent.click(button));
    screen.getAllByRole('button', { name: 'Adjust status searchability' }).forEach(button => fireEvent.click(button));

    const portableOption = screen.getAllByRole('option', { name: /Searchable for all/ }).find(option => (
      option.closest('[data-searchability-popup]').getAttribute('data-searchability-popup') === portableId
    ));
    const portablePanel = document.querySelectorAll('.compose-form__destination-panel')[1];

    fireEvent.mouseDown(portableOption);

    expect(portableOption.isConnected).toBe(true);
    expect(screen.getAllByRole('button', { name: 'Destination details' })[0]).toHaveAttribute('aria-expanded', 'false');
    expect(screen.getAllByRole('button', { name: 'Destination details' })[1]).toHaveAttribute('aria-expanded', 'true');

    fireEvent.click(portableOption);

    expect(selectComposer(store.getState(), portableId).get('searchability')).toBe('public');
    expect(selectComposer(store.getState(), PRIMARY_COMPOSER_ID).get('searchability')).toBeNull();
    expect(screen.getAllByRole('button', { name: 'Destination details' })[0]).toHaveAttribute('aria-expanded', 'false');
    expect(screen.getAllByRole('button', { name: 'Destination details' })[1]).toHaveAttribute('aria-expanded', 'true');
    expect(portablePanel.isConnected).toBe(true);
  });

  it('hides the empty details control while editing a status', () => {
    const store = createStore(reduce, baseState().setIn(['compose', 'id'], 'status-1'));

    renderDestination(store, PRIMARY_COMPOSER_ID, <ComposerContextDetails />);

    expect(screen.getByTestId('composer-destination')).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Destination details' })).toBeNull();
    expect(document.querySelector('.compose-form__destination-panel')).toBeNull();
    expect(screen.queryByTestId('posting-context-bar')).toBeNull();
  });

  it('hides the empty details control while editing a scheduled status', () => {
    const store = createStore(reduce, baseState().setIn(['composers', 'byId', portableId, 'scheduled_status_id'], 'sched-1'));

    renderDestination(store, portableId, <ComposerContextDetails />);

    expect(screen.getByTestId('composer-destination')).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Destination details' })).toBeNull();
    expect(document.querySelector('.compose-form__destination-panel')).toBeNull();
    expect(screen.queryByTestId('posting-context-bar')).toBeNull();
  });

  it('still applies an ACTIONS modal choice after the press leaves the details panel', () => {
    const onChange = jest.fn();
    const onModalOpen = jest.fn();
    const onModalClose = jest.fn();

    render(
      <ComposerDestinationSummary
        composerId={PRIMARY_COMPOSER_ID}
        contextDetails={(
          <SearchabilityDropdown
            composerId={PRIMARY_COMPOSER_ID}
            value='private'
            onChange={onChange}
            isUserTouching={userIsTouching}
            onModalOpen={onModalOpen}
            onModalClose={onModalClose}
          />
        )}
      />,
    );

    fireEvent.click(screen.getByRole('button', { name: 'Destination details' }));
    fireEvent.click(screen.getByRole('button', { name: 'Adjust status searchability' }));

    expect(screen.queryByRole('listbox')).not.toBeInTheDocument();
    expect(onModalOpen).toHaveBeenCalledTimes(1);

    const action = document.createElement('a');

    action.setAttribute('data-index', '0');
    action.className = 'actions-modal__choice';
    document.body.appendChild(action);
    fireEvent.mouseDown(action);
    onModalOpen.mock.calls[0][0].onClick({
      preventDefault () {},
      currentTarget: action,
    });
    action.remove();

    expect(onChange).toHaveBeenCalledWith('public');
    expect(onModalClose).toHaveBeenCalledTimes(1);
  });
});

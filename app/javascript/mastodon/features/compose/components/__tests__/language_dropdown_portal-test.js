/* eslint-disable react/prop-types, react/jsx-no-bind */
import React from 'react';
import { act, fireEvent, render, screen } from '@testing-library/react';
import { IntlProvider } from 'react-intl';
import LanguageDropdown from '../language_dropdown';
import { setFullscreenOverlayPortal } from 'mastodon/utils/overlay_portal';
import { registerOverlayLayer, resetOverlayLayersForTests } from 'mastodon/utils/overlay_layers';

const languages = [
  ['en', 'English', 'English'],
  ['ja', 'Japanese', '日本語'],
];

describe('LanguageDropdown fullscreen portal', () => {
  afterEach(() => {
    setFullscreenOverlayPortal(null);
    resetOverlayLayersForTests();
    document.body.innerHTML = '';
  });

  it('places the open menu in the fullscreen portal', () => {
    const portal = document.createElement('div');
    const host = document.createElement('div');

    host.className = 'fullscreen-column-host';
    document.body.appendChild(portal);
    document.body.appendChild(host);
    setFullscreenOverlayPortal(portal);

    const view = render(
      <IntlProvider locale='en'>
        <LanguageDropdown value='en' languages={languages} onChange={() => {}} />
      </IntlProvider>,
      { container: host },
    );

    act(() => {
      fireEvent.click(view.getByRole('button', { name: 'Change language' }));
    });

    expect(portal.querySelector('.language-dropdown__dropdown')).not.toBeNull();
    expect(document.body.querySelector('body > .language-dropdown__dropdown')).toBeNull();
  });

  it('places the detached menu in the fullscreen portal', () => {
    const portal = document.createElement('div');
    const host = document.createElement('div');

    host.className = 'fullscreen-column-host';
    document.body.appendChild(portal);
    document.body.appendChild(host);
    setFullscreenOverlayPortal(portal);

    render(
      <IntlProvider locale='en'>
        <LanguageDropdown presentation='detached' open value='en' languages={languages} onChange={() => {}} onClose={() => {}} />
      </IntlProvider>,
      { container: host },
    );

    expect(portal.querySelector('.language-dropdown__dropdown')).not.toBeNull();
  });

  it('lets one Escape close the language menu without closing the composer', () => {
    const onEscape = jest.fn();
    const host = document.createElement('div');

    host.className = 'fullscreen-column-host';
    document.body.appendChild(host);
    registerOverlayLayer({ id: 'fullscreen-composer', priority: 60, onEscape });

    const view = render(
      <IntlProvider locale='en'>
        <LanguageDropdown value='en' languages={languages} onChange={() => {}} />
      </IntlProvider>,
      { container: host },
    );
    const button = view.getByRole('button', { name: 'Change language' });

    act(() => {
      fireEvent.click(button);
    });

    const search = screen.getByPlaceholderText('Search languages...');

    fireEvent.change(search, { target: { value: 'en' } });
    fireEvent.keyDown(search, { key: 'Escape', keyCode: 27 });
    fireEvent.keyUp(window, { key: 'Escape', keyCode: 27 });

    expect(search.value).toBe('');
    expect(onEscape).not.toHaveBeenCalled();

    fireEvent.keyDown(search, { key: 'Escape', keyCode: 27 });
    fireEvent.keyUp(window, { key: 'Escape', keyCode: 27 });

    expect(screen.queryByPlaceholderText('Search languages...')).toBeNull();
    expect(onEscape).not.toHaveBeenCalled();

    act(() => {
      fireEvent.click(button);
    });
    fireEvent.keyDown(screen.getAllByRole('option')[0], { key: 'Escape', keyCode: 27 });
    fireEvent.keyUp(window, { key: 'Escape', keyCode: 27 });

    expect(screen.queryByRole('listbox')).toBeNull();
    expect(onEscape).not.toHaveBeenCalled();
  });
});

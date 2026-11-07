/* eslint-disable react/prop-types, react/jsx-no-bind */
import React from 'react';
import { act, fireEvent, render } from '@testing-library/react';
import { IntlProvider } from 'react-intl';
import LanguageDropdown from '../language_dropdown';
import { setFullscreenOverlayPortal } from 'mastodon/utils/overlay_portal';

const languages = [
  ['en', 'English', 'English'],
  ['ja', 'Japanese', '日本語'],
];

describe('LanguageDropdown fullscreen portal', () => {
  afterEach(() => {
    setFullscreenOverlayPortal(null);
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
});

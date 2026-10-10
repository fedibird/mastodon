import { act, fireEvent, render, screen } from '@testing-library/react';
import React from 'react';
import { MemoryRouter } from 'react-router-dom';

jest.mock('react-intl', () => {
  const intl = {
    formatMessage: (message, values) => {
      let text = message.defaultMessage || message.id;

      if (values) {
        Object.keys(values).forEach(key => {
          text = text.split(`{${key}}`).join(String(values[key]));
        });
      }

      return text;
    },
  };

  return {
    defineMessages: messages => messages,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

import MixSourceBadges from '../source_badges';

const badge = (key, label, extra = {}) => ({
  key,
  type: 'list',
  icon: 'list-ul',
  label,
  fullLabel: label,
  typeLabel: 'List',
  detail: extra.detail || '',
  conditions: extra.conditions || [],
  warningTitles: extra.warningTitles || [],
  href: extra.href || null,
});

const badges = [
  badge('a', 'Home'),
  badge('b', 'Alpha', { conditions: ['Media only'], warningTitles: ['Spoilers'], href: '/timelines/home' }),
  badge('c', 'Beta'),
  badge('d', 'A very long source name that should stay in the button text'),
];

const renderBadges = (items) => render(
  <MemoryRouter>
    <MixSourceBadges
      badges={items} intl={{
        formatMessage: (message, values) => {
          let text = message.defaultMessage;

          if (values) {
            Object.keys(values).forEach(key => {
              text = text.split(`{${key}}`).join(String(values[key]));
            });
          }

          return text;
        },
      }}
    />
  </MemoryRouter>,
);

describe('mix source badge component', () => {
  it('shows one source and opens its details from the keyboard', () => {
    renderBadges([badges[1]]);

    expect(screen.getByText('Shown via')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Alpha' }));
    expect(screen.getByText('Spoilers')).toBeTruthy();
    expect(screen.getByText('Media only')).toBeTruthy();
    expect(screen.getByRole('link', { name: 'Open original timeline' }).getAttribute('href')).toBe('/timelines/home');

    act(() => {
      document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }));
    });
    expect(screen.queryByText('Media only')).toBeNull();
    expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Alpha' }));
  });

  it('collapses sources after the third and expands the rest', () => {
    renderBadges(badges);

    expect(screen.getByRole('button', { name: 'Home' })).toBeTruthy();
    expect(screen.queryByRole('button', { name: /very long source name/ })).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: '1 more' }));
    expect(screen.getByRole('button', { name: /very long source name/ })).toBeTruthy();
    expect(screen.queryByRole('button', { name: '1 more' })).toBeNull();
  });

  it('renders nothing when the status has no visible sources', () => {
    const { container } = renderBadges([]);

    expect(container.querySelector('.status__mix-sources')).toBeNull();
  });
});

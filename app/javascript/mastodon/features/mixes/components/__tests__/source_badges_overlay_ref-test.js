import { fireEvent, render, screen } from '@testing-library/react';
import React from 'react';
import { MemoryRouter } from 'react-router-dom';

const overlayRefs = [];

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
  };
});

jest.mock('react-overlays/Overlay', () => {
  return function Overlay ({ show, children }) {
    if (!show) {
      return null;
    }

    const ref = (node) => {
      overlayRefs.push(node);
    };

    return children({
      props: { ref, style: { position: 'fixed' } },
      placement: 'bottom-start',
    });
  };
});

import MixSourceBadges from '../source_badges';

const badge = (key, label) => ({
  key,
  type: 'list',
  icon: 'list-ul',
  label,
  fullLabel: label,
  typeLabel: 'List',
  detail: '',
  conditions: [],
  warningTitles: [],
  href: null,
  settingsDiffer: false,
});

describe('mix source badge overlay ref', () => {
  beforeEach(() => {
    overlayRefs.length = 0;
  });

  it('forwards the menu node to the overlay ref and clears it on close', () => {
    render(
      <MemoryRouter>
        <MixSourceBadges badges={[badge('a', 'Alpha'), badge('b', 'Beta')]} />
      </MemoryRouter>,
    );

    fireEvent.click(screen.getByRole('button', { name: 'Alpha' }));
    fireEvent.click(screen.getByRole('button', { name: 'Beta' }));
    expect(screen.queryByRole('dialog', { name: 'Alpha' })).toBeNull();
    expect(overlayRefs[overlayRefs.length - 1]).toBe(screen.getByRole('dialog', { name: 'Beta' }));

    fireEvent.click(screen.getByRole('button', { name: 'Beta' }));
    fireEvent.click(screen.getByRole('button', { name: 'Alpha' }));

    const menu = screen.getByRole('dialog', { name: 'Alpha' });

    expect(overlayRefs[overlayRefs.length - 1]).toBe(menu);
    expect(menu.style.position).toBe('fixed');

    fireEvent.click(screen.getByRole('button', { name: 'Close source details' }));
    expect(overlayRefs[overlayRefs.length - 1]).toBeNull();
    expect(screen.queryByRole('dialog')).toBeNull();
    expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Alpha' }));

    fireEvent.click(screen.getByRole('button', { name: 'Beta' }));
    expect(screen.queryByRole('dialog', { name: 'Alpha' })).toBeNull();
    expect(overlayRefs[overlayRefs.length - 1]).toBe(screen.getByRole('dialog', { name: 'Beta' }));
  });
});

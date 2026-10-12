import { fireEvent, render, screen } from '@testing-library/react';
import { List as ImmutableList, fromJS } from 'immutable';
import React from 'react';

jest.mock('react-intl', () => {
  const React = require('react');
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

import UserPostingStylePicker, { IntlUserPostingStyleCatalogNotice } from '../user_posting_style_picker';

const styles = ImmutableList([
  fromJS({
    id: '1',
    name: 'サークル告知',
    icon: '📣',
    purpose: 'サークル向けの告知',
    target: { kind: 'group', label: 'localsquad' },
  }),
  fromJS({
    id: '2',
    name: '読書メモ',
    icon: '📚',
    purpose: '読んだ本',
    target: { kind: 'hashtag', label: '#books' },
  }),
]);

describe('UserPostingStylePicker', () => {
  it('lists usual settings, saved styles, and the settings page', () => {
    const onSelect = jest.fn();

    render(
      <UserPostingStylePicker
        styles={styles}
        selectedId={null}
        snapshot={null}
        unapplied={ImmutableList()}
        destinationStatus='idle'
        visibilityConflict={false}
        onSelect={onSelect}
      />,
    );

    expect(screen.getByText('Posting style')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'No style' })).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'No style' }));
    expect(screen.getByRole('menuitemradio', { name: /サークル告知/ })).toBeTruthy();
    expect(screen.getByText('サークル向けの告知')).toBeTruthy();
    expect(screen.getByText('Destination localsquad')).toBeTruthy();
    expect(screen.getByRole('link', { name: 'Posting style settings' }).getAttribute('href')).toEqual('/settings/user_posting_contexts');

    fireEvent.click(screen.getByRole('menuitemradio', { name: /読書メモ/ }));

    expect(onSelect).toHaveBeenCalledWith('2');
  });

  it('moves with the arrow keys, selects with Enter, and returns focus on Escape', () => {
    const onSelect = jest.fn();

    render(
      <UserPostingStylePicker
        styles={styles}
        selectedId={null}
        snapshot={null}
        unapplied={ImmutableList()}
        destinationStatus='idle'
        visibilityConflict={false}
        onSelect={onSelect}
      />,
    );

    const trigger = screen.getByRole('button', { name: 'No style' });

    fireEvent.click(trigger);

    const usual = screen.getByRole('menuitemradio', { name: /No style/ });
    const circle = screen.getByRole('menuitemradio', { name: /サークル告知/ });

    expect(usual).toHaveAttribute('aria-checked', 'true');
    expect(circle).toHaveAttribute('aria-checked', 'false');
    expect(document.activeElement).toBe(usual);

    fireEvent.keyDown(usual, { key: 'ArrowDown' });

    expect(document.activeElement).toBe(circle);

    fireEvent.keyDown(circle, { key: 'Enter' });

    expect(onSelect).toHaveBeenCalledWith('1');
    expect(screen.queryByRole('menu')).not.toBeInTheDocument();
    expect(document.activeElement).toBe(trigger);

    fireEvent.click(trigger);
    expect(screen.getByRole('link', { name: 'Posting style settings' }).getAttribute('role')).toBeNull();
    fireEvent.keyDown(screen.getByRole('menu'), { key: 'Escape' });

    expect(screen.queryByRole('menu')).not.toBeInTheDocument();
    expect(document.activeElement).toBe(trigger);
  });

  it('distinguishes a network failure from an unsupported destination and retries outside the menu', () => {
    const onRetry = jest.fn();
    const { rerender } = render(
      <UserPostingStylePicker
        styles={styles}
        selectedId='1'
        snapshot={styles.get(0)}
        unapplied={ImmutableList()}
        destinationStatus='failed'
        destinationFailure='error'
        visibilityConflict={false}
        onSelect={jest.fn()}
        onRetry={onRetry}
      />,
    );

    expect(screen.getByText('Couldn’t reach the destination. Choose the style again or retry.')).toBeTruthy();
    expect(screen.queryByRole('menu')).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Retry' }));
    expect(onRetry).toHaveBeenCalledTimes(1);

    rerender(
      <UserPostingStylePicker
        styles={styles}
        selectedId='1'
        snapshot={styles.get(0)}
        unapplied={ImmutableList()}
        destinationStatus='failed'
        destinationFailure='unsupported'
        visibilityConflict={false}
        onSelect={jest.fn()}
        onRetry={onRetry}
      />,
    );

    expect(screen.getByText('This destination isn’t supported, so you can’t post.')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Retry' })).toBeTruthy();
  });

  it('names the empty option for a fixed destination separately from the style', () => {
    render(
      <UserPostingStylePicker
        styles={styles}
        selectedId={null}
        snapshot={null}
        unapplied={ImmutableList()}
        destinationStatus='idle'
        visibilityConflict={false}
        emptyLabel='place'
        compact
        onSelect={jest.fn()}
      />,
    );

    fireEvent.click(screen.getByRole('button', { name: 'No style' }));

    const place = screen.getByRole('menuitemradio', { name: /No style/ });
    const circle = screen.getByRole('menuitemradio', { name: /サークル告知/ });

    expect(place).toHaveAttribute('aria-checked', 'true');
    expect(circle).toHaveAttribute('aria-checked', 'false');
    expect(screen.getByText('Destination localsquad')).toBeTruthy();
    expect(screen.getByText('サークル告知').className).toContain('compose-form__style-name');
  });

  const defaultProps = {
    showDefaults: true,
    assignmentFetchStatus: 'ready',
    assignmentStatus: 'unset',
    assignmentStyleId: null,
    assignmentFailure: null,
    onSaveDefault: jest.fn(),
    onUseNoStyle: jest.fn(),
    onResetDefault: jest.fn(),
    onRetryAssignment: jest.fn(),
  };

  it('keeps place defaults outside the style radio group', () => {
    const onSelect = jest.fn();
    const onSaveDefault = jest.fn();

    render(
      <UserPostingStylePicker
        styles={styles}
        selectedId='1'
        snapshot={styles.get(0)}
        unapplied={ImmutableList()}
        destinationStatus='idle'
        visibilityConflict={false}
        onSelect={onSelect}
        {...defaultProps}
        onSaveDefault={onSaveDefault}
      />,
    );

    fireEvent.click(screen.getByRole('button', { name: /サークル告知/ }));

    const useHere = document.querySelector('.compose-form__style-star[data-style-id="1"]');
    const radios = screen.getAllByRole('menuitemradio').map(item => item.textContent);

    expect(useHere.getAttribute('role')).toBeNull();
    expect(radios.some(text => text.includes('Save as the default for this place'))).toBe(false);
    expect(document.querySelector('.compose-form__style-star[data-style-id=""]')).toBeTruthy();
    expect(useHere).toHaveAttribute('aria-pressed', 'false');

    fireEvent.click(useHere);

    expect(onSaveDefault).toHaveBeenCalledWith('1');
    expect(onSelect).not.toHaveBeenCalled();
  });

  it('shows a saved default and does not present a failed save as success', () => {
    const { rerender } = render(
      <UserPostingStylePicker
        styles={styles}
        selectedId='1'
        snapshot={styles.get(0)}
        unapplied={ImmutableList()}
        destinationStatus='idle'
        visibilityConflict={false}
        onSelect={jest.fn()}
        {...defaultProps}
        assignmentStatus='style'
        assignmentStyleId='1'
      />,
    );

    fireEvent.click(screen.getByRole('button', { name: /サークル告知/ }));
    expect(document.querySelector('.compose-form__style-star[data-style-id="1"]')).toHaveAttribute('aria-pressed', 'true');
    expect(screen.queryByText('This place uses this style by default')).not.toBeInTheDocument();

    rerender(
      <UserPostingStylePicker
        styles={styles}
        selectedId='2'
        snapshot={styles.get(1)}
        unapplied={ImmutableList()}
        destinationStatus='idle'
        visibilityConflict={false}
        onSelect={jest.fn()}
        {...defaultProps}
        assignmentFetchStatus='saving'
        assignmentStatus='unset'
      />,
    );

    expect(screen.getByText('Saving the default for this place')).toBeTruthy();
    expect(screen.queryByText('This place uses this style by default')).not.toBeInTheDocument();
    expect(document.querySelector('.compose-form__style-star[data-style-id="2"]')).toBeDisabled();

    rerender(
      <UserPostingStylePicker
        styles={styles}
        selectedId='2'
        snapshot={styles.get(1)}
        unapplied={ImmutableList()}
        destinationStatus='idle'
        visibilityConflict={false}
        emptyLabel='place'
        compact
        onSelect={jest.fn()}
        {...defaultProps}
        assignmentFetchStatus='ready'
        assignmentFailure='save'
        assignmentStatus='unset'
      />,
    );

    expect(screen.getByText('Couldn’t save the default for this place.')).toBeTruthy();
    expect(screen.queryByText('This place uses this style by default')).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Always use this style here' })).not.toBeInTheDocument();
    expect(document.querySelector('.compose-form__style--compact')).toBeTruthy();
    expect(screen.getByRole('button', { name: /読書メモ/ })).toBeTruthy();

    const trigger = screen.getByRole('button', { name: /読書メモ/ });

    if (trigger.getAttribute('aria-expanded') !== 'true') {
      fireEvent.click(trigger);
    }

    const failedSave = document.querySelector('.compose-form__style-star[data-style-id="2"]');

    expect(failedSave.getAttribute('role')).toBeNull();
    expect(failedSave.closest('.compose-form__style-menu')).toBeTruthy();
    expect(failedSave.closest('[role="menuitemradio"]')).toBeNull();
  });

  it('keeps simple-mode default actions in the open menu and out of the radio group', () => {
    const onSelect = jest.fn();
    const onUseNoStyle = jest.fn();

    render(
      <UserPostingStylePicker
        styles={styles}
        selectedId='2'
        snapshot={styles.get(1)}
        unapplied={ImmutableList()}
        destinationStatus='idle'
        visibilityConflict={false}
        emptyLabel='place'
        compact
        onSelect={onSelect}
        {...defaultProps}
        assignmentStatus='style'
        assignmentStyleId='2'
        onUseNoStyle={onUseNoStyle}
      />,
    );

    expect(screen.getByText('Default')).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Always use this style here' })).not.toBeInTheDocument();
    expect(document.querySelector('.compose-form__style-defaults')).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: /読書メモ/ }));

    const useHere = document.querySelector('.compose-form__style-star[data-style-id="2"]');
    const none = document.querySelector('.compose-form__style-star[data-style-id=""]');
    const menu = screen.getByRole('menu');

    expect(useHere.closest('.compose-form__style-menu')).toBeTruthy();
    expect(useHere.closest('[role="menuitemradio"]')).toBeNull();
    expect(screen.getAllByRole('menuitemradio').some(item => item.textContent.includes('Save as the default for this place'))).toBe(false);
    expect(document.activeElement.getAttribute('role')).toEqual('menuitemradio');

    fireEvent.keyDown(menu, { key: 'ArrowDown' });

    expect(document.activeElement.getAttribute('role')).toEqual('menuitemradio');
    expect(document.activeElement).not.toBe(useHere);

    fireEvent.click(none);

    expect(onUseNoStyle).toHaveBeenCalledTimes(1);
    expect(onSelect).not.toHaveBeenCalled();

    fireEvent.keyDown(document, { key: 'Escape' });

    expect(screen.queryByRole('menu')).not.toBeInTheDocument();
    expect(document.querySelector('.compose-form__style-star')).toBeNull();
    expect(document.activeElement).toBe(screen.getByRole('button', { name: /読書メモ/ }));
  });

  it('blocks place-default changes while the destination is unconfirmed', () => {
    const onSaveDefault = jest.fn();
    const onUseNoStyle = jest.fn();
    const onResetDefault = jest.fn();

    render(
      <UserPostingStylePicker
        styles={styles}
        selectedId='1'
        snapshot={styles.get(0)}
        unapplied={ImmutableList()}
        destinationStatus='idle'
        visibilityConflict={false}
        onSelect={jest.fn()}
        {...defaultProps}
        defaultsBlocked
        onSaveDefault={onSaveDefault}
        onUseNoStyle={onUseNoStyle}
        onResetDefault={onResetDefault}
      />,
    );

    expect(screen.getByText('This draft’s destination isn’t confirmed, so the default for this place can’t be changed.')).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: /サークル告知/ }));

    const stars = Array.from(document.querySelectorAll('.compose-form__style-star'));

    expect(stars.length).toBeGreaterThan(0);
    stars.forEach(star => {
      expect(star).toBeDisabled();
      fireEvent.click(star);
    });

    expect(onSaveDefault).not.toHaveBeenCalled();
    expect(onUseNoStyle).not.toHaveBeenCalled();
    expect(onResetDefault).not.toHaveBeenCalled();
  });

  it('offers a reload when the place default could not be loaded', () => {
    const onRetryAssignment = jest.fn();

    render(
      <UserPostingStylePicker
        styles={styles}
        selectedId={null}
        snapshot={null}
        unapplied={ImmutableList()}
        destinationStatus='idle'
        visibilityConflict={false}
        onSelect={jest.fn()}
        {...defaultProps}
        assignmentFetchStatus='failed'
        assignmentFailure='fetch'
        assignmentStatus={null}
        onRetryAssignment={onRetryAssignment}
      />,
    );

    expect(screen.queryByText('This place does not use a style')).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Reload the default for this place' }));
    expect(onRetryAssignment).toHaveBeenCalledTimes(1);
  });

  it('offers a way to reload posting styles after the catalog request fails', () => {
    const onRetry = jest.fn();

    render(<IntlUserPostingStyleCatalogNotice onRetry={onRetry} />);

    expect(screen.getByText('Couldn’t load posting styles.')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Reload posting styles' }));
    expect(onRetry).toHaveBeenCalledTimes(1);
  });

  it('renders a custom emoji icon without inserting raw HTML', () => {
    const customEmojis = fromJS([{
      shortcode: 'fedibird',
      url: '/emoji/fedibird.png',
      static_url: '/emoji/fedibird.png',
    }]);
    const withEmoji = styles.map(style => style.get('id') === '2' ? style.set('icon', ':fedibird:') : style);

    const { container } = render(
      <UserPostingStylePicker
        header
        styles={withEmoji}
        customEmojis={customEmojis}
        selectedId='2'
        snapshot={withEmoji.get(1)}
        unapplied={ImmutableList()}
        destinationStatus='idle'
        visibilityConflict={false}
        onSelect={jest.fn()}
        {...defaultProps}
        assignmentStatus='style'
        assignmentStyleId='2'
      />,
    );

    expect(container.querySelector('img.emojione')).toBeTruthy();
    expect(container.innerHTML).not.toContain('<script');

    const hostile = styles.set(0, styles.get(0).set('icon', '<img src=x onerror=alert(1)>'));

    const hostileView = render(
      <UserPostingStylePicker
        header
        styles={hostile}
        customEmojis={ImmutableList()}
        selectedId='1'
        snapshot={hostile.get(0)}
        unapplied={ImmutableList()}
        destinationStatus='idle'
        visibilityConflict={false}
        onSelect={jest.fn()}
        {...defaultProps}
      />,
    );

    expect(hostileView.container.querySelector('[onerror]')).toBeNull();
    expect(screen.getAllByRole('button', { name: /サークル告知/ }).length).toBeGreaterThan(0);
  });

  it('hides style choices without hiding the destination', () => {
    render(
      <UserPostingStylePicker
        header
        showStyleControls={false}
        placeLabel='localsquad'
        contextDetails={<div>Follow the group</div>}
        styles={styles}
        selectedId='1'
        snapshot={styles.get(0)}
        unapplied={ImmutableList()}
        destinationStatus='failed'
        destinationFailure='unsupported'
        visibilityConflict={false}
        onSelect={jest.fn()}
        {...defaultProps}
      />,
    );

    expect(screen.getByRole('button', { name: 'localsquad' })).toBeTruthy();
    expect(screen.queryByRole('menuitemradio')).toBeNull();
    expect(screen.queryByRole('button', { name: 'Always use this style here' })).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: 'localsquad' }));

    expect(screen.getByText('Follow the group')).toBeTruthy();
    expect(screen.getAllByText('This destination isn’t supported, so you can’t post.').length).toBeGreaterThan(0);
    expect(screen.queryByRole('menuitemradio')).toBeNull();
  });

  it('keeps the destination header while styles load or fail to load', () => {
    const onRetryCatalog = jest.fn();
    const view = render(
      <UserPostingStylePicker
        header
        catalogLoading
        showStyleControls={false}
        placeLabel='localsquad'
        contextDetails={<div>Follow the group</div>}
        styles={styles}
        selectedId={null}
        snapshot={null}
        unapplied={ImmutableList()}
        destinationStatus='idle'
        visibilityConflict={false}
        onSelect={jest.fn()}
        onRetryCatalog={onRetryCatalog}
      />,
    );

    const picker = document.querySelector('[data-posting-style-picker]');

    expect(screen.getByRole('button', { name: /localsquad/ })).toBeTruthy();
    expect(document.querySelector('.compose-form__style-context')).toBeNull();
    expect(picker.querySelector('[data-posting-style-catalog]')).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: /localsquad/ }));

    expect(screen.getByText('Loading posting styles')).toBeTruthy();
    expect(screen.getByText('Follow the group')).toBeTruthy();
    expect(document.querySelector('.compose-form__style-overlay')).toContainElement(screen.getByText('Follow the group'));
    expect(screen.queryByRole('menuitemradio')).toBeNull();

    view.rerender(
      <UserPostingStylePicker
        header
        catalogFailed
        showStyleControls={false}
        placeLabel='localsquad'
        contextDetails={<div>Create permission confirmed</div>}
        styles={styles}
        selectedId={null}
        snapshot={null}
        unapplied={ImmutableList()}
        destinationStatus='idle'
        visibilityConflict
        onSelect={jest.fn()}
        onRetryCatalog={onRetryCatalog}
      />,
    );

    expect(screen.getByRole('button', { name: /localsquad/ })).toHaveAttribute('aria-expanded', 'true');
    expect(document.querySelector('[data-posting-style-catalog="failed"]')).toBeTruthy();
    expect(screen.getByText('Create permission confirmed')).toBeTruthy();
    expect(screen.getByText('Can’t post because visibility does not meet the destination')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Reload posting styles' }));
    expect(onRetryCatalog).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole('menuitemradio')).toBeNull();
  });
});

/* eslint-disable react/prop-types */

import { fireEvent, render, screen } from '@testing-library/react';
import React from 'react';
import { IntlProvider, addLocaleData } from 'react-intl';
import japaneseLocaleData from 'react-intl/locale-data/ja';
import japanese from 'mastodon/locales/ja.json';

jest.mock('mastodon/components/icon', () => {
  const ReactMock = require('react');
  return ({ id }) => ReactMock.createElement('span', { 'data-icon': id });
});

import MediaDisplayControls from '../media_display_controls';

addLocaleData(japaneseLocaleData);

describe('media display controls', () => {
  it('localizes all controls and routes changes to the view, not the user preferences', () => {
    const onShapeChange = jest.fn();
    const onSizeChange = jest.fn();
    const onVisibilityChange = jest.fn();

    render(
      <IntlProvider locale='ja' messages={japanese}>
        <MediaDisplayControls
          shape='square'
          size='small'
          visibility='hide_sensitive'
          onShapeChange={onShapeChange}
          onSizeChange={onSizeChange}
          onVisibilityChange={onVisibilityChange}
        />
      </IntlProvider>,
    );

    expect(screen.getByRole('toolbar', { name: 'メディアの表示設定' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'スクエア' })).toHaveAttribute('aria-pressed', 'true');
    expect(screen.getByRole('button', { name: '小' })).toHaveAttribute('aria-pressed', 'true');
    expect(screen.getByRole('button', { name: '閲覧注意メディアを隠す' })).toHaveAttribute('aria-pressed', 'true');
    expect(screen.getByRole('button', { name: 'メディアを常に表示する' })).toHaveAttribute('aria-pressed', 'false');

    fireEvent.click(screen.getByRole('button', { name: 'オリジナル' }));
    fireEvent.click(screen.getByRole('button', { name: '最大' }));
    fireEvent.click(screen.getByRole('button', { name: 'メディアを常に隠す' }));

    expect(onShapeChange).toHaveBeenCalledWith('original');
    expect(onSizeChange).toHaveBeenCalledWith('max');
    expect(onVisibilityChange).toHaveBeenCalledWith('hide_all');
  });
});

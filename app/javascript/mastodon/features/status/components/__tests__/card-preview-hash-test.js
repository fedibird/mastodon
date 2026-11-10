/* eslint-disable react/prop-types */

import { fireEvent, render } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';

jest.mock('mastodon/initial_state', () => ({ useBlurhash: true }));
jest.mock('react-intl', () => ({ FormattedMessage: ({ defaultMessage }) => defaultMessage }));
jest.mock('mastodon/components/icon', () => () => null);
jest.mock('mastodon/components/blurhash', () => {
  const ReactMock = require('react');

  return ({ hash, className }) => ReactMock.createElement('canvas', { className, 'data-testid': 'card-blurhash', 'data-hash': hash });
});
jest.mock('mastodon/components/thumbhash', () => {
  const ReactMock = require('react');

  return ({ hash, className }) => ReactMock.createElement('canvas', { className, 'data-testid': 'card-thumbhash', 'data-hash': hash });
});

import Card from '../card';

const makeCard = (overrides = {}) => fromJS({
      type: 'link',
      provider_name: 'Example',
      url: 'https://example.test/article',
      title: 'Article',
      description: '',
      width: 320,
      height: 180,
      image: 'https://example.test/image.jpg',
      blurhash: null,
      thumbhash: null,
      ...overrides,
  });

const renderCard = (overrides = {}) => render(
  <Card card={makeCard(overrides)} onOpenMedia={jest.fn()} />,
);

describe('Card image preview hashes', () => {
  it('does not render a blur canvas without either hash', () => {
    const { container, queryByTestId } = renderCard();

    expect(queryByTestId('card-blurhash')).toBeNull();
    expect(queryByTestId('card-thumbhash')).toBeNull();
    expect(container.querySelector('.status-card__image-preview')).toBeNull();
    expect(container.querySelector('.status-card__image-image')).not.toBeNull();
  });

  it('renders the blurhash when thumbhash is absent', () => {
    const { getByTestId, queryByTestId } = renderCard({ blurhash: 'blur' });

    expect(getByTestId('card-blurhash')).toHaveAttribute('data-hash', 'blur');
    expect(queryByTestId('card-thumbhash')).toBeNull();
  });

  it('resets the loaded preview when the card changes', () => {
    const onOpenMedia = jest.fn();
    const { container, rerender } = render(
      <Card card={makeCard({ blurhash: 'old' })} onOpenMedia={onOpenMedia} />,
    );

    fireEvent.load(container.querySelector('.status-card__image-image'));
    expect(container.querySelector('.status-card__image-preview')).toHaveClass('status-card__image-preview--hidden');

    rerender(<Card card={makeCard({ blurhash: 'new', title: 'New article' })} onOpenMedia={onOpenMedia} />);
    expect(container.querySelector('.status-card__image-preview')).not.toHaveClass('status-card__image-preview--hidden');
  });

  it('updates the spoiler overlay when sensitivity changes', () => {
    const onOpenMedia = jest.fn();
    const photo = makeCard({ type: 'photo' });
    const { getByText, queryByText, rerender } = render(
      <Card card={photo} sensitive onOpenMedia={onOpenMedia} />,
    );

    expect(getByText('Sensitive content')).toBeInTheDocument();

    rerender(<Card card={photo} sensitive={false} onOpenMedia={onOpenMedia} />);
    expect(queryByText('Sensitive content')).toBeNull();

    rerender(<Card card={photo} sensitive onOpenMedia={onOpenMedia} />);
    expect(getByText('Sensitive content')).toBeInTheDocument();
  });

  it('prefers thumbhash when both hashes are present', () => {
    const { getByTestId, queryByTestId } = renderCard({ blurhash: 'blur', thumbhash: 'thumb' });

    expect(getByTestId('card-thumbhash')).toHaveAttribute('data-hash', 'thumb');
    expect(queryByTestId('card-blurhash')).toBeNull();
  });
});

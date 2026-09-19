require 'rails_helper'

RSpec.describe Tag, type: :model do
  describe 'validations' do
    it 'invalid with #' do
      expect(Tag.new(name: '#hello_world')).to_not be_valid
    end

    it 'invalid with .' do
      expect(Tag.new(name: '.abcdef123')).to_not be_valid
    end

    it 'invalid with spaces' do
      expect(Tag.new(name: 'hello world')).to_not be_valid
    end

    it 'valid with ａｅｓｔｈｅｔｉｃ' do
      expect(Tag.new(name: 'ａｅｓｔｈｅｔｉｃ')).to be_valid
    end
  end

  describe 'HASHTAG_RE' do
    subject { Tag::HASHTAG_RE }

    it 'does not match URLs with anchors with non-hashtag characters' do
      expect(subject.match('Check this out https://medium.com/@alice/some-article#.abcdef123')).to be_nil
    end

    it 'does not match URLs with hashtag-like anchors' do
      expect(subject.match('https://en.wikipedia.org/wiki/Ghostbusters_(song)#Lawsuit')).to be_nil
    end

    it 'matches ﻿#ａｅｓｔｈｅｔｉｃ' do
      expect(subject.match('﻿this is #ａｅｓｔｈｅｔｉｃ').to_s).to eq ' #ａｅｓｔｈｅｔｉｃ'
    end

    it 'matches digits at the start' do
      expect(subject.match('hello #3d').to_s).to eq ' #3d'
    end

    it 'matches digits in the middle' do
      expect(subject.match('hello #l33ts35k').to_s).to eq ' #l33ts35k'
    end

    it 'matches digits at the end' do
      expect(subject.match('hello #world2016').to_s).to eq ' #world2016'
    end

    it 'matches underscores at the beginning' do
      expect(subject.match('hello #_test').to_s).to eq ' #_test'
    end

    it 'matches underscores at the end' do
      expect(subject.match('hello #test_').to_s).to eq ' #test_'
    end

    it 'matches underscores in the middle' do
      expect(subject.match('hello #one_two_three').to_s).to eq ' #one_two_three'
    end

    it 'matches middle dots' do
      expect(subject.match('hello #one·two·three').to_s).to eq ' #one·two·three'
    end

    it 'matches ZWNJ' do
      expect(subject.match('just add #نرم‌افزار and').to_s).to eq ' #نرم‌افزار'
    end

    it 'does not match middle dots at the start' do
      expect(subject.match('hello #·one·two·three')).to be_nil
    end

    it 'does not match middle dots at the end' do
      expect(subject.match('hello #one·two·three·').to_s).to eq ' #one·two·three'
    end

    it 'does not match purely-numeric hashtags' do
      expect(subject.match('hello #0123456')).to be_nil
    end
  end

  describe '#to_param' do
    it 'returns name' do
      tag = Fabricate(:tag, name: 'foo')
      expect(tag.to_param).to eq 'foo'
    end
  end

  describe '.find_normalized' do
    it 'returns tag for a multibyte case-insensitive name' do
      upcase_string   = 'abcABCａｂｃＡＢＣやゆよ'
      downcase_string = 'abcabcａｂｃａｂｃやゆよ';

      tag = Fabricate(:tag, name: downcase_string)
      expect(Tag.find_normalized(upcase_string)).to eq tag
    end
  end

  describe '.matches_name' do
    it 'returns tags for multibyte case-insensitive names' do
      upcase_string   = 'abcABCａｂｃＡＢＣやゆよ'
      downcase_string = 'abcabcａｂｃａｂｃやゆよ';

      tag = Fabricate(:tag, name: downcase_string)
      expect(Tag.matches_name(upcase_string)).to eq [tag]
    end

    it 'uses the LIKE operator' do
      expect(Tag.matches_name('100%abc').to_sql).to eq %q[SELECT "tags".* FROM "tags" WHERE LOWER("tags"."name") LIKE LOWER('100\\%abc%')]
    end
  end

  describe '.matching_name' do
    it 'returns tags for multibyte case-insensitive names' do
      upcase_string   = 'abcABCａｂｃＡＢＣやゆよ'
      downcase_string = 'abcabcａｂｃａｂｃやゆよ';

      tag = Fabricate(:tag, name: downcase_string)
      expect(Tag.matching_name(upcase_string)).to eq [tag]
    end
  end

  describe '.find_or_create_by_names' do
    it 'runs a passed block once per tag regardless of duplicates' do
      upcase_string   = 'abcABCａｂｃＡＢＣやゆよ'
      downcase_string = 'abcabcａｂｃａｂｃやゆよ'
      tags            = []

      Tag.find_or_create_by_names([upcase_string, downcase_string]) do |tag|
        tags << tag
      end

      expect(tags.map(&:id).uniq).to eq [tags.first.id]
    end

    it 'does not persist display_name for newly created tags' do
      tag = Tag.find_or_create_by_names('FreshDisplayNameTag').first

      expect(tag.attributes['display_name']).to be_nil
      expect(tag.display_name).to eq tag.name
    end
  end

  describe '.search_for' do
    it 'finds tag records with matching names' do
      tag = Fabricate(:tag, name: "match")
      _miss_tag = Fabricate(:tag, name: "miss")

      results = Tag.search_for("match")

      expect(results).to eq [tag]
    end

    it 'finds tag records in case insensitive' do
      tag = Fabricate(:tag, name: "MATCH")
      _miss_tag = Fabricate(:tag, name: "miss")

      results = Tag.search_for("match")

      expect(results).to eq [tag]
    end

    it 'finds the exact matching tag as the first item' do
      similar_tag = Fabricate(:tag, name: "matchlater", reviewed_at: Time.now.utc)
      tag = Fabricate(:tag, name: "match", reviewed_at: Time.now.utc)

      results = Tag.search_for("match")

      expect(results).to eq [tag, similar_tag]
    end
  end

  describe '#display_name' do
    it 'falls back to name when display_name is nil' do
      tag = Fabricate(:tag, name: 'foo')

      expect(tag.attributes['display_name']).to be_nil
      expect(tag.display_name).to eq 'foo'
    end

    it 'returns the stored display_name when present' do
      tag = Fabricate(:tag, name: 'foo')
      tag.update!(display_name: 'FOO')

      expect(tag.reload.attributes['display_name']).to eq 'FOO'
      expect(tag.name).to eq 'foo'
      expect(tag.display_name).to eq 'FOO'
    end
  end

  describe 'display_name validation' do
    let(:tag) { Fabricate(:tag, name: 'foo') }

    it 'allows a nil display_name' do
      tag.display_name = nil
      expect(tag).to be_valid
    end

    it 'allows a same-tag display_name with different case' do
      tag.display_name = 'FOO'
      expect(tag).to be_valid
    end

    it 'allows a full-width equivalent display_name' do
      tag.display_name = 'ｆｏｏ'
      expect(tag).to be_valid
    end

    it 'allows an ASCII-folding equivalent display_name' do
      tag = Fabricate(:tag, name: 'blahaj')
      tag.display_name = 'BLÅHAJ'
      expect(tag).to be_valid
    end

    it 'rejects a different-tag display_name' do
      tag.display_name = 'bar'
      expect(tag).not_to be_valid
      expect(tag.errors[:display_name]).to be_present
    end
  end

  describe '.normalize' do
    it 'only strips a leading hash and otherwise leaves Fedibird names unchanged' do
      expect(Tag.normalize('#Foo')).to eq 'Foo'
      expect(Tag.normalize('BLÅHAJ')).to eq 'BLÅHAJ'
      expect(Tag.normalize('ａｅｓｔｈｅｔｉｃ')).to eq 'ａｅｓｔｈｅｔｉｃ'
    end
  end

  describe 'Fedibird tag identity' do
    it 'does not merge HashtagNormalizer-equivalent names into one tag' do
      ascii = Fabricate(:tag, name: 'blahaj')
      accented = Fabricate(:tag, name: 'BLÅHAJ')

      expect(accented.id).to_not eq ascii.id
      expect(Tag.normalize('BLÅHAJ')).to eq 'BLÅHAJ'
      expect(HashtagNormalizer.new.normalize('BLÅHAJ')).to eq 'blahaj'
      expect(Tag.find_or_create_by_names('BLÅHAJ').map(&:id)).to eq [accented.id]
      expect(Tag.find_or_create_by_names('blahaj').map(&:id)).to eq [ascii.id]
    end

    it 'does not collapse full-width names into ASCII identities' do
      ascii = Fabricate(:tag, name: 'synthwave')
      fullwidth = Fabricate(:tag, name: 'Ｓｙｎｔｈｗａｖｅ')

      expect(fullwidth.id).to_not eq ascii.id
      expect(Tag.normalize('Ｓｙｎｔｈｗａｖｅ')).to eq 'Ｓｙｎｔｈｗａｖｅ'
      expect(HashtagNormalizer.new.normalize('Ｓｙｎｔｈｗａｖｅ')).to eq 'synthwave'
    end
  end

  describe 'Paginable' do
    it 'paginates tags by id' do
      Tag.delete_all
      older = Fabricate(:tag)
      newer = Fabricate(:tag)

      expect(Tag.to_a_paginated_by_id(1)).to eq [newer]
      expect(Tag.to_a_paginated_by_id(1, max_id: newer.id)).to eq [older]
    end
  end
end

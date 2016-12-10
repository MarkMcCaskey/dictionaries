{-|
  Module:      NLP.Dictionary
  Copyright:   (c) 2016 Al Zohali
  License:     BSD3
  Maintainer:  Al Zohali <zohl@fmap.me>
  Stability:   experimental
-}

module NLP.Dictionary (
    Dictionary(..)
  ) where

import Data.Text.Lazy (Text)
import Data.Trie

-- | Core type class that provides interface to dictionaries.
class Dictionary a where
  getEntries :: Text -> a -> IO [Text]
  getTrie    :: a -> Trie Text

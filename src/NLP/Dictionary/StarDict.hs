{-|
  Module:      NLP.Dictionary.StarDict
  Copyright:   (c) 2016 Al Zohali
  License:     BSD3
  Maintainer:  Al Zohali <zohl@fmap.me>
  Stability:   experimental

  = Description
  Tools for StarDict dictionaries.
  To load a dictionary you should call 'mkDictionary' with path to .ifo file
  and render function.
  Every call of getEntry will perform file reading operation to retrieve
  requested data. For in-memory version see 'NLP.Dictionary.StarDict.InMemory'.
-}


{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

module NLP.Dictionary.StarDict (
    StarDict (..)
  , StarDictException (..)
  , mkDictionary

  , mkDataParser
  , DataEntry (..)
  , Renderer

  , checkFiles
  , checkGZFiles

  , IfoFile(..)
  , IfoFilePath
  , readIfoFile
  , indexNumberParser
  , ifoDateFormat

  , Index
  , IndexEntry
  , readIndexFile

  , checkDataFile
  ) where

import Prelude hiding (takeWhile)
import Control.Applicative (liftA2, many)
import Control.Arrow ((***))
import Control.Monad (when, unless)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Catch (Exception, MonadThrow, throwM)
import Data.Attoparsec.ByteString.Lazy (Result(..), Parser, parse, string, takeWhile, inClass)
import Data.Attoparsec.ByteString.Char8 (isEndOfLine, endOfLine, skipSpace, char)
import Data.Binary.Get (Get, runGet, runGetOrFail, isEmpty)
import Data.Binary.Get (getRemainingLazyByteString, getLazyByteStringNul, getLazyByteString)
import Data.Binary.Get (getWord32be, getWord64be)
import Data.ByteString.Lazy (ByteString)
import Data.Char (chr)
import Data.List (intercalate)
import Data.Map.Strict (Map)
import Data.Maybe (maybeToList)
import Data.Typeable (Typeable)
import Data.Time (parseTimeM, defaultTimeLocale)
import Data.Time.Clock (UTCTime)
import Data.Text.Lazy (Text)
import Data.Text.Lazy.Encoding (decodeUtf8, decodeLatin1)
import System.Directory (doesFileExist, getTemporaryDirectory)
import System.FilePath.Posix (dropExtension, joinPath, takeBaseName, (-<.>), (<.>))
import System.IO (Handle, IOMode(..), SeekMode(..), withFile, hSeek)
import NLP.Dictionary (Dictionary(..))
import qualified Codec.Compression.GZip as GZip
import qualified Data.ByteString.Lazy as BS
import qualified Data.ByteString.Lazy.Char8 as BSC8
import qualified Data.Map.Strict as Map
import qualified Data.Text.Lazy as T

-- | Exceptions that are thrown when something with this module went wrong.
data StarDictException
  = WrongIfoFormat FilePath String
  -- ^ Thrown when information file (.ifo) has unsupported format.

  | IndexNotFound FilePath
  -- ^ Thrown when index file (.idx, .idx.gz) is not found.

  | WrongIndexFormat FilePath String
  -- ^ Thrown when index file has unsupported format.

  | DictionaryNotFound FilePath
  -- ^ Thrown when dictionary file (.dict, .dict.dz) has unsupported format.
  deriving (Eq, Show, Typeable)

instance Exception StarDictException


-- | Representation of .ifo file.
data IfoFile = IfoFile {
    ifoMagicData        :: ByteString
  , ifoVersion          :: String
  , ifoBookName         :: Text
  , ifoWordCount        :: Int
  , ifoIdxFileSize      :: Int
  , ifoIdxOffsetBits    :: Maybe Int
  , ifoSynWordCount     :: Maybe Int
  , ifoAuthor           :: Maybe Text
  , ifoEmail            :: Maybe Text
  , ifoWebsite          :: Maybe Text
  , ifoDescription      :: Maybe Text
  , ifoDate             :: Maybe UTCTime
  , ifoSameTypeSequence :: Maybe String
  , ifoDictType         :: Maybe String
  } deriving (Eq, Show)

-- | Date format of 'ifoDate' in IfoFile.
ifoDateFormat :: String
ifoDateFormat = "%0Y.%m.%d"


-- | Read .ifo file at the given path.
readIfoFile :: (MonadThrow m, MonadIO m) => FilePath -> m IfoFile
readIfoFile ifoPath = (liftIO . BS.readFile $ ifoPath) >>= (readIfoBS ifoPath)

-- | Read .ifo file from bytestring 
readIfoBS
  :: (MonadThrow m, MonadIO m)
  => FilePath   -- ^ File that the IFO data was read from (for error reporting)
  -> ByteString -- ^ Content of IFO file
  -> m IfoFile
readIfoBS ifoPath ifoBS = case (parse ifoFile ifoBS) of
    (Fail _ _ msg) -> throwM $ WrongIfoFormat ifoPath msg
    (Done _ r)     -> return r
  where
    expect :: (Eq a, Show a) => String -> a -> [a] -> Parser ()
    expect name x xs = unless (x `elem` xs) . fail . concat $ [
      name, " must be ", fmts xs, " (", show x, " provided)"
      ] where
      fmt y = '\'':(show y) ++ "'"
  
      fmts = \case
        []     -> ""
        (y:[]) -> fmt y
        ys     -> (intercalate ", " . map fmt . init $ ys) ++ " or " ++ (fmt . last $ ys)

    justExpect :: (Eq a, Show a) => String -> Maybe a -> [a] -> Parser ()
    justExpect name mx xs = maybe (return ()) (\x -> expect name x xs) mx

    ifoFile :: Parser IfoFile
    ifoFile = do
      ifoMagicData <- magicData
      expect "magic data" ifoMagicData ["StarDict's dict ifo file"]

      (_, ifoVersion) <- (id *** BSC8.unpack) <$> (endOfLine *> pair (Just "version"))
      expect "version" ifoVersion ["2.4.2", "3.0.0"]

      ifoData <- Map.fromList <$> (endOfLine *> (many (pair Nothing) <* endOfLine))
      let get = flip Map.lookup ifoData
      let require field = ( $ (get field)) $ maybe
            (fail $ "required field " ++ BSC8.unpack field ++ " not found") (return)

      ifoBookName    <- decodeUtf8 <$> require "bookname"
      ifoWordCount   <- read . BSC8.unpack <$> require "wordcount"
      ifoIdxFileSize <- read . BSC8.unpack <$> require "idxfilesize"

      let ifoIdxOffsetBits = read . BSC8.unpack <$> get "idxoffsetbits"
      justExpect "idxoffsetbits" ifoIdxOffsetBits [32, 64]

      let ifoSynWordCount     = read . BSC8.unpack <$> get "synwordcount"
      let ifoAuthor           = decodeUtf8 <$> get "author"
      let ifoEmail            = decodeUtf8 <$> get "email"
      let ifoWebsite          = decodeUtf8 <$> get "website"
      let ifoDescription      = decodeUtf8 <$> get "description"

      let ifoDate = get "date" >>= parseTimeM False defaultTimeLocale ifoDateFormat . BSC8.unpack

      let ifoSameTypeSequence = BSC8.unpack <$> get "sametypesequence"

      let ifoDictType = BSC8.unpack <$> get "dicttype"
      justExpect "dicttype" ifoDictType ["wordnet"]

      return IfoFile {..}


    magicData :: Parser ByteString
    magicData = BS.fromStrict <$> takeWhile (not . isEndOfLine)

    pair :: Maybe ByteString -> Parser (ByteString, ByteString)
    pair = pair' . maybe
      (takeWhile $ inClass "A-Za-z0-9-_")
      (string . BS.toStrict) where

      pair' key = do
        k <- BS.fromStrict <$> (skipSpace *> key)
        _ <- skipSpace *> char '='
        v <- BS.fromStrict <$> (skipSpace *> takeWhile (not . isEndOfLine))
        return (k, v)

-- | Get 32-bit or 64-bit integer depending on description in the .ifo file.
indexNumberParser :: IfoFile -> Get Int
indexNumberParser IfoFile {..} = case ifoIdxOffsetBits of
  (Just 64) -> fromIntegral <$> getWord64be
  _         -> fromIntegral <$> getWord32be

-- | Representation of an .idx file.
type Index = Map Text (Int, Int)

-- | Representation of an .idx file entry.
type IndexEntry = (Text, (Int, Int))

-- | Given .ifo file name and list of extensions, returns first existing file with the same basename.
checkFiles :: IfoFilePath -> [FilePath] -> IO (Maybe FilePath)
checkFiles _ [] = return Nothing
checkFiles ifoPath (ext:exts) = let fn = ifoPath -<.> ext
  in (doesFileExist fn) >>= \case
    True  -> return . Just $ fn
    False -> checkFiles ifoPath exts

-- | Given .ifo file name and two lists of extensions, returns first
-- existing file with with the same basename and extension from the first
-- list or (if such file doesn't exists) from the second list.
checkGZFiles
  :: IfoFilePath
  -> [FilePath]
  -> [FilePath]
  -> IO (Maybe (Either FilePath FilePath))
checkGZFiles ifoPath exts exts' = (checkFiles ifoPath exts) >>= maybe
  (fmap (Right <$>) (checkFiles ifoPath exts'))
  (return . Just . Left)

-- | Type synonym to distinguish usage of paths.
type IfoFilePath = FilePath

-- | Read .idx (.idx.gz) file.
readIndexFile :: (MonadThrow m, MonadIO m) => IfoFilePath -> Get Int -> m Index
readIndexFile fn num = checkIndexFile fn >>= getIndexContents >>= (mkIndex num) where

  checkIndexFile :: (MonadThrow m, MonadIO m) => IfoFilePath -> m (Either FilePath FilePath)
  checkIndexFile ifoPath = (liftIO $ checkGZFiles ifoPath ["idx"] ["idx.gz"]) >>= \case
    Nothing   -> throwM $ IndexNotFound ifoPath
    Just path -> return path

  getIndexContents :: (MonadThrow m, MonadIO m)
    => Either FilePath FilePath -> m (FilePath, ByteString)
  getIndexContents path = liftIO . fmap (fn,) . postprocess . BS.readFile $ fn where
    postprocess = either (const id) (const $ fmap GZip.decompress) path
    fn = either id id path

readIndexBS
  :: (MonadThrow m, MonadIO m)
  => ByteString -- ^ Index contents
  -> Get Int
  -> m Index
readIndexBS bs num = mkIndex num ("ByteString",GZip.decompress bs)


mkIndex
  :: (MonadThrow m, MonadIO m)
  => Get Int
  -> (FilePath, ByteString)
  -> m Index
mkIndex num (fn, contents) = either
  (\(_, _, err) -> throwM $ WrongIndexFormat fn err)
  (\(_, _, res) -> return . Map.fromList $ res)
  (runGetOrFail (getIndexEntries num) contents)

getIndexEntries :: Get Int -> Get [IndexEntry]
getIndexEntries num = isEmpty >>= \case
  True  -> return []
  False -> liftA2 (:) (getIndexEntry num) (getIndexEntries num)

getIndexEntry :: Get Int -> Get IndexEntry
getIndexEntry num = (,) <$> (decodeUtf8 <$> getLazyByteStringNul)
                    <*> ((,) <$> num <*> num)

-- | Returns path of decompressed dictionary.
checkDataFile :: (MonadThrow m, MonadIO m) => IfoFilePath -> m FilePath
checkDataFile ifoPath = (liftIO $ checkGZFiles ifoPath ["dict1"] ["dict.dz"]) >>= \case
  Nothing         -> throwM $ DictionaryNotFound ifoPath
  Just (Left fn)  -> return fn
  Just (Right fn) -> liftIO $ do
    fn' <- (joinPath . (:[(takeBaseName ifoPath) <.> "dict"])) <$> getTemporaryDirectory
    GZip.decompress <$> (BS.readFile fn) >>= BS.writeFile fn'
    return fn'

-- | Possible dictionary entry formats.
data DataEntry
  = UTF8Text Text
  | LocaleText Text
  | Pango Text
  | Phonetics Text
  | XDXF Text
  | CJK Text
  | PowerWord Text
  | MediaWiki Text
  | HTML Text
  | Resource [FilePath]
  | WAVEAudio ByteString
  | Picture ByteString
  | Reserved ByteString
  deriving (Eq, Show)

-- | Parser for a list of elements.
getMany :: Get a -> Get [a]
getMany p = isEmpty >>= \case
  True  -> return []
  False -> liftA2 (:) p (getMany p)

-- | Returns parser based on description in .ifo file.
mkDataParser :: Maybe String -> Get [DataEntry]
mkDataParser = maybe (getMany getGenericEntry) getSpecificEntries where

  getGenericEntry :: Get DataEntry
  getGenericEntry = BSC8.head <$> getLazyByteString 1
                >>= getSpecificEntry getLazyByteStringNul

  getSpecificEntries :: [Char] -> Get [DataEntry]
  getSpecificEntries cs = sequence $ zipWith getSpecificEntry ps cs where
    ps :: [Get ByteString]
    ps = reverse . take (length cs) $ getRemainingLazyByteString:(repeat getLazyByteStringNul)

  getSpecificEntry :: Get ByteString -> Char -> Get DataEntry
  getSpecificEntry getData = \case
    'm' -> UTF8Text   . decodeUtf8 <$> getData
    'l' -> LocaleText . decodeLatin1 <$> getData
    'g' -> Pango      . decodeUtf8 <$> getData
    't' -> Phonetics  . decodeUtf8 <$> getData
    'x' -> XDXF       . decodeUtf8 <$> getData
    'y' -> CJK        . decodeUtf8 <$> getData
    'k' -> PowerWord  . decodeUtf8 <$> getData
    'w' -> MediaWiki  . decodeUtf8 <$> getData
    'h' -> HTML       . decodeUtf8 <$> getData
    'n' -> Resource   . lines . T.unpack . decodeUtf8 <$> getData
    'r' -> Resource   . lines . T.unpack . decodeUtf8 <$> getData
    'W' -> WAVEAudio <$> getData
    'P' -> Picture   <$> getData
    'X' -> Reserved  <$> getData
    _   -> error "type not supported"

-- | Type of function to transform dictionary entries to a text.
type Renderer = DataEntry -> Text

-- | Representation of the dictionary.
data StarDict = StarDict {
    sdIfoFile    :: IfoFile
  , sdIndex      :: Index
  , sdDataPath   :: FilePath
  , sdDataParser :: Get [DataEntry]
  , sdRender     :: Renderer
  }

-- | Create dictionary.
mkDictionary :: (MonadThrow m, MonadIO m) => IfoFilePath -> Renderer -> m StarDict
mkDictionary ifoPath sdRender = do
  sdIfoFile    <- readIfoFile   ifoPath
  sdIndex      <- readIndexFile ifoPath (indexNumberParser sdIfoFile)
  sdDataPath   <- checkDataFile ifoPath
  let sdDataParser = mkDataParser (ifoSameTypeSequence sdIfoFile)
  return StarDict {..}

instance Dictionary StarDict where
  getEntries str (StarDict {..}) = withFile sdDataPath ReadMode extractEntries where

    extractEntries :: Handle -> IO [Text]
    extractEntries h = mapM (extractEntry h) . maybeToList . Map.lookup str $ sdIndex

    extractEntry :: Handle -> (Int, Int) -> IO Text
    extractEntry h (offset, size) = do
      hSeek h AbsoluteSeek (fromIntegral offset)
      T.concat . map sdRender . runGet sdDataParser <$> BS.hGet h size


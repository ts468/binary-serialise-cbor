{-# LANGUAGE CPP                #-}
{-# LANGUAGE MagicHash          #-}
{-# LANGUAGE BangPatterns       #-}
{-# LANGUAGE RankNTypes         #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE DeriveDataTypeable #-}

#if __GLASGOW_HASKELL__ > 706
-- Bump up from the default 1.5, otherwise our decoder fast path is no good.
-- We went over the threshold when we switched to using ST.
{-# OPTIONS_GHC -funfolding-keeness-factor=2.0 #-}
#endif

-- |
-- Module      : Codec.CBOR.Read
-- Copyright   : (c) Duncan Coutts 2015-2017
-- License     : BSD3-style (see LICENSE.txt)
--
-- Maintainer  : duncan@community.haskell.org
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--
-- Tools for reading values in a CBOR-encoded format
-- back into ordinary values.
--
module Codec.CBOR.Read
  ( deserialiseFromBytes         -- :: Decoder a -> ByteString -> Either String (ByteString, a)
  , deserialiseFromBytesWithSize -- :: Decoder a -> ByteString -> Either String (ByteString, ByteOffset, a)
  , deserialiseIncremental       -- :: Decoder a -> ST s (IDecode s a)
  , DeserialiseFailure(..)
  , IDecode(..)
  , ByteOffset
  ) where

#include "cbor.h"

#if !MIN_VERSION_base(4,8,0)
import           Control.Applicative
#endif
import           GHC.Int

import           Control.Monad (ap)
import           Control.Monad.ST
import           Data.Array.IArray
import           Data.Array.Unboxed
import qualified Data.Array.Base as A
import           Data.Monoid
import           Data.Bits
import           Data.ByteString                (ByteString)
import qualified Data.ByteString                as BS
import qualified Data.ByteString.Unsafe         as BS
import qualified Data.ByteString.Lazy           as LBS
import qualified Data.ByteString.Lazy.Internal  as LBS
import qualified Data.Text          as T
import qualified Data.Text.Encoding as T
import           Data.Word
import           GHC.Word
#if defined(ARCH_32bit)
import           GHC.IntWord64
#endif
import           GHC.Exts
import           GHC.Float (float2Double)
import           Data.Typeable
import           Control.Exception

import           Codec.CBOR.Decoding hiding (DecodeAction(Done, Fail))
import           Codec.CBOR.Decoding (DecodeAction)
import qualified Codec.CBOR.Decoding as D
import           Codec.CBOR.Magic

--------------------------------------------------------------------------------

-- | An exception type that may be returned (by pure functions) or
-- thrown (by IO actions) that fail to deserialise a given input.
--
-- @since 0.2.0.0
data DeserialiseFailure = DeserialiseFailure ByteOffset String
  deriving (Show, Typeable)

instance Exception DeserialiseFailure where
#if MIN_VERSION_base(4,8,0)
    displayException (DeserialiseFailure off msg) =
      "Codec.CBOR: deserialising failed at offset "
           ++ show off ++ " : " ++ msg
#endif

-- | An Incremental decoder, used to represent the result of
-- attempting to run a decoder over a given input, and return a value
-- of type @a@.
data IDecode s a
  = -- | The decoder has consumed the available input and needs more
    -- to continue. Provide @'Just'@ if more input is available and
    -- @'Nothing'@ otherwise, and you will get a new @'IDecode'@.
    Partial (Maybe BS.ByteString -> ST s (IDecode s a))

    -- | The decoder has successfully finished. Except for the output
    -- value you also get any unused input as well as the number of
    -- bytes consumed.
  | Done !BS.ByteString {-# UNPACK #-} !ByteOffset a

    -- | The decoder ran into an error. The decoder either used
    -- @'fail'@ or was not provided enough input. Contains any
    -- unconsumed input, the number of bytes consumed, and a
    -- @'DeserialiseFailure'@ exception describing the reason why the
    -- failure occurred.
  | Fail !BS.ByteString {-# UNPACK #-} !ByteOffset DeserialiseFailure

-- | Given a @'Decoder'@ and some @'LBS.ByteString'@ representing
-- an encoded CBOR value, return @'Either'@ the decoded CBOR value
-- or an error. In addition to the decoded value return any remaining input
-- content.
--
-- @since 0.2.0.0
deserialiseFromBytes :: (forall s. Decoder s a)
                     -> LBS.ByteString
                     -> Either DeserialiseFailure (LBS.ByteString, a)
deserialiseFromBytes d lbs =
    fmap f $ runIDecode (deserialiseIncremental d) lbs
  where f (rest, _, x) = (rest, x)

-- | Given a @'Decoder'@ and some @'LBS.ByteString'@ representing
-- an encoded CBOR value, return @'Either'@ the decoded CBOR value
-- or an error. In addition to the decoded value return any remaining input
-- content and the number of bytes consumed.
--
-- @since 0.2.0.0
deserialiseFromBytesWithSize :: (forall s. Decoder s a)
                             -> LBS.ByteString
                             -> Either DeserialiseFailure (LBS.ByteString, ByteOffset, a)
deserialiseFromBytesWithSize d lbs =
    runIDecode (deserialiseIncremental d) lbs

runIDecode :: (forall s. ST s (IDecode s a))
           -> LBS.ByteString
           -> Either DeserialiseFailure (LBS.ByteString, ByteOffset, a)
runIDecode d lbs =
    runST (go lbs =<< d)
  where
    go :: LBS.ByteString
       -> IDecode s a
       -> ST s (Either DeserialiseFailure (LBS.ByteString, ByteOffset, a))
    go  _                  (Fail _ _ err)  = return (Left err)
    go  lbs'               (Done bs off x) = return (Right (LBS.Chunk bs lbs', off, x))
    go  LBS.Empty          (Partial  k)    = k Nothing   >>= go LBS.Empty
    go (LBS.Chunk bs lbs') (Partial  k)    = k (Just bs) >>= go lbs'

-- | Run a @'Decoder'@ incrementally, returning a continuation
-- representing the result of the incremental decode.
--
-- @since 0.2.0.0
deserialiseIncremental :: Decoder s a -> ST s (IDecode s a)
deserialiseIncremental decoder = do
    da <- getDecodeAction decoder
    runIncrementalDecoder (runDecodeAction da)

----------------------------------------------
-- A monad for building incremental decoders
--

-- | Simple alias for @'Int64'@, used to make types more descriptive.
type ByteOffset = Int64

newtype IncrementalDecoder s a = IncrementalDecoder {
       unIncrementalDecoder ::
         forall r. (a -> ST s (IDecode s r)) -> ST s (IDecode s r)
     }

instance Functor (IncrementalDecoder s) where
    fmap f a = a >>= return . f

instance Applicative (IncrementalDecoder s) where
    pure x = IncrementalDecoder $ \k -> k x
    (<*>) = ap

instance Monad (IncrementalDecoder s) where
    return = pure

    {-# INLINE (>>=) #-}
    m >>= f = IncrementalDecoder $ \k ->
                unIncrementalDecoder m $ \x ->
                  unIncrementalDecoder (f x) k

runIncrementalDecoder :: IncrementalDecoder s (ByteString, ByteOffset, a)
                      -> ST s (IDecode s a)
runIncrementalDecoder (IncrementalDecoder f) =
  f (\(trailing, off, x) -> return $ Done trailing off x)

decodeFail :: ByteString -> ByteOffset -> String -> IncrementalDecoder s a
decodeFail trailing off msg = IncrementalDecoder $ \_ -> return $ Fail trailing off exn
  where exn = DeserialiseFailure off msg

needChunk :: IncrementalDecoder s (Maybe ByteString)
needChunk = IncrementalDecoder $ \k -> return $ Partial $ \mbs -> k mbs

lift :: ST s a -> IncrementalDecoder s a
lift action = IncrementalDecoder (\k -> action >>= k)

--------------------------------------------
-- The main decoder
--

-- The top level entry point
runDecodeAction :: DecodeAction s a
                -> IncrementalDecoder s (ByteString, ByteOffset, a)
runDecodeAction (D.Fail msg)        = decodeFail BS.empty 0 msg
runDecodeAction (D.Done x)          = return (BS.empty, 0, x)
runDecodeAction (D.PeekAvailable k) = lift (k 0#) >>= runDecodeAction
runDecodeAction da = do
    mbs <- needChunk
    case mbs of
      Nothing -> decodeFail BS.empty 0 "end of input"
      Just bs -> go_slow da bs 0

-- The decoder is split into a fast path and a slow path. The fast path is
-- used for a single input chunk. It decodes as far as it can, reading only
-- whole tokens that fit within the input chunk. When it cannot read any
-- further it returns control to the slow path. The slow path fixes up all the
-- complicated corner cases with tokens that span chunk boundaries, gets more
-- input and then goes back into the fast path.
--
-- The idea is that chunks are usually large, and we can use simpler and
-- faster code if we don't make it deal with the general case of tokens that
-- span chunk boundaries.

-- These are all the ways in which the fast path can finish, and return
-- control to the slow path. In particular there are three different cases
-- of tokens spanning a chunk boundary.
--
data SlowPath s a
   = FastDone               {-# UNPACK #-} !ByteString a
   | SlowConsumeTokenString {-# UNPACK #-} !ByteString (T.Text     -> ST s (DecodeAction s a)) {-# UNPACK #-} !Int
   | SlowConsumeTokenBytes  {-# UNPACK #-} !ByteString (ByteString -> ST s (DecodeAction s a)) {-# UNPACK #-} !Int
   | SlowDecodeAction       {-# UNPACK #-} !ByteString (DecodeAction s a)
   | SlowFail               {-# UNPACK #-} !ByteString String


-- The main fast path. The fast path itself is actually split into two parts
-- the main version 'go_fast' and a version used when we are near the end of
-- the chunk, 'go_fast_end'.
--
-- This version can then do fewer tests when we're not near the end of the
-- chunk, in particular we just check if there's enough input buffer space
-- left for the largest possible fixed-size token (8+1 bytes).
--
go_fast :: ByteString -> DecodeAction s a -> ST s (SlowPath s a)

go_fast !bs da | BS.length bs < 9 = go_fast_end bs da

go_fast !bs da@(ConsumeWord k) =
    case tryConsumeWord (BS.unsafeHead bs) bs of
      DecodeFailure           -> go_fast_end bs da
      DecodedToken sz (W# w#) -> k w# >>= go_fast (BS.unsafeDrop sz bs)

go_fast !bs da@(ConsumeWord8 k) =
    case tryConsumeWord (BS.unsafeHead bs) bs of
      DecodeFailure           -> go_fast_end bs da
      DecodedToken sz (W# w#) ->
        case gtWord# w# 0xff## of
          0#                  -> k w#  >>= go_fast (BS.unsafeDrop sz bs)
          _                   -> go_fast_end bs da

go_fast !bs da@(ConsumeWord16 k) =
    case tryConsumeWord (BS.unsafeHead bs) bs of
      DecodeFailure           -> go_fast_end bs da
      DecodedToken sz (W# w#) ->
        case gtWord# w# 0xffff## of
          0#                  -> k w#  >>= go_fast (BS.unsafeDrop sz bs)
          _                   -> go_fast_end bs da

go_fast !bs da@(ConsumeWord32 k) =
    case tryConsumeWord (BS.unsafeHead bs) bs of
      DecodeFailure           -> go_fast_end bs da
      DecodedToken sz (W# w#) ->
#if defined(ARCH_32bit)
                                 k w# >>= go_fast (BS.unsafeDrop sz bs)
#else
        case gtWord# w# 0xffffffff## of
          0#                  -> k w# >>= go_fast (BS.unsafeDrop sz bs)
          _                   -> go_fast_end bs da
#endif

go_fast !bs da@(ConsumeNegWord k) =
    case tryConsumeNegWord (BS.unsafeHead bs) bs of
      DecodeFailure           -> go_fast_end bs da
      DecodedToken sz (W# w#) -> k w# >>= go_fast (BS.unsafeDrop sz bs)

go_fast !bs da@(ConsumeInt k) =
    case tryConsumeInt (BS.unsafeHead bs) bs of
      DecodeFailure           -> go_fast_end bs da
      DecodedToken sz (I# n#) -> k n# >>= go_fast (BS.unsafeDrop sz bs)

go_fast !bs da@(ConsumeInt8 k) =
    case tryConsumeInt (BS.unsafeHead bs) bs of
      DecodeFailure           -> go_fast_end bs da
      DecodedToken sz (I# n#) ->
        case (n# ># 0x7f#) `orI#` (n# <# -0x80#) of
          0#                  -> k n# >>= go_fast (BS.unsafeDrop sz bs)
          _                   -> go_fast_end bs da

go_fast !bs da@(ConsumeInt16 k) =
    case tryConsumeInt (BS.unsafeHead bs) bs of
      DecodeFailure           -> go_fast_end bs da
      DecodedToken sz (I# n#) ->
        case (n# ># 0x7fff#) `orI#` (n# <# -0x8000#) of
          0#                  -> k n# >>= go_fast (BS.unsafeDrop sz bs)
          _                   -> go_fast_end bs da

go_fast !bs da@(ConsumeInt32 k) =
    case tryConsumeInt (BS.unsafeHead bs) bs of
      DecodeFailure           -> go_fast_end bs da
      DecodedToken sz (I# n#) ->
#if defined(ARCH_32bit)
                                 k n# >>= go_fast (BS.unsafeDrop sz bs)
#else
        case (n# ># 0x7fffffff#) `orI#` (n# <# -0x80000000#) of
          0#                  -> k n# >>= go_fast (BS.unsafeDrop sz bs)
          _                   -> go_fast_end bs da
#endif

go_fast !bs da@(ConsumeListLen k) =
    case tryConsumeListLen (BS.unsafeHead bs) bs of
      DecodeFailure           -> go_fast_end bs da
      DecodedToken sz (I# n#) -> k n# >>= go_fast (BS.unsafeDrop sz bs)

go_fast !bs da@(ConsumeMapLen k) =
    case tryConsumeMapLen (BS.unsafeHead bs) bs of
      DecodeFailure           -> go_fast_end bs da
      DecodedToken sz (I# n#) -> k n# >>= go_fast (BS.unsafeDrop sz bs)

go_fast !bs da@(ConsumeTag k) =
    case tryConsumeTag (BS.unsafeHead bs) bs of
      DecodeFailure           -> go_fast_end bs da
      DecodedToken sz (W# w#) -> k w# >>= go_fast (BS.unsafeDrop sz bs)

go_fast !bs da@(ConsumeWordCanonical k) =
    case tryConsumeWord (BS.unsafeHead bs) bs of
      DecodeFailure           -> go_fast_end bs da
      DecodedToken sz (W# w#)
        | isWordCanonical sz w# -> k w# >>= go_fast (BS.unsafeDrop sz bs)
        | otherwise             -> go_fast_end bs da

go_fast !bs da@(ConsumeWord8Canonical k) =
    case tryConsumeWord (BS.unsafeHead bs) bs of
      DecodeFailure           -> go_fast_end bs da
      DecodedToken sz (W# w#) ->
        case gtWord# w# 0xff## of
          0# | isWordCanonical sz w# -> k w# >>= go_fast (BS.unsafeDrop sz bs)
          _                          -> go_fast_end bs da

go_fast !bs da@(ConsumeWord16Canonical k) =
    case tryConsumeWord (BS.unsafeHead bs) bs of
      DecodeFailure           -> go_fast_end bs da
      DecodedToken sz (W# w#) ->
        case gtWord# w# 0xffff## of
          0# | isWordCanonical sz w# -> k w# >>= go_fast (BS.unsafeDrop sz bs)
          _                          -> go_fast_end bs da

go_fast !bs da@(ConsumeWord32Canonical k) =
    case tryConsumeWord (BS.unsafeHead bs) bs of
      DecodeFailure           -> go_fast_end bs da
      DecodedToken sz (W# w#) ->
        case w_out_of_range w# of
          0# | isWordCanonical sz w# -> k w# >>= go_fast (BS.unsafeDrop sz bs)
          _                          -> go_fast_end bs da
  where
    w_out_of_range _w# =
#if defined(ARCH_32bit)
      0#
#else
      gtWord# _w# 0xffffffff##
#endif

go_fast !bs da@(ConsumeNegWordCanonical k) =
    case tryConsumeNegWord (BS.unsafeHead bs) bs of
      DecodeFailure           -> go_fast_end bs da
      DecodedToken sz (W# w#)
        | isWordCanonical sz w# -> k w# >>= go_fast (BS.unsafeDrop sz bs)
        | otherwise             -> go_fast_end bs da

go_fast !bs da@(ConsumeIntCanonical k) =
    case tryConsumeInt (BS.unsafeHead bs) bs of
      DecodeFailure           -> go_fast_end bs da
      DecodedToken sz (I# n#)
        | isIntCanonical sz n# -> k n# >>= go_fast (BS.unsafeDrop sz bs)
        | otherwise            -> go_fast_end bs da

go_fast !bs da@(ConsumeInt8Canonical k) =
    case tryConsumeInt (BS.unsafeHead bs) bs of
      DecodeFailure           -> go_fast_end bs da
      DecodedToken sz (I# n#) ->
        case (n# ># 0x7f#) `orI#` (n# <# -0x80#) of
          0# | isIntCanonical sz n# -> k n# >>= go_fast (BS.unsafeDrop sz bs)
          _                         -> go_fast_end bs da

go_fast !bs da@(ConsumeInt16Canonical k) =
    case tryConsumeInt (BS.unsafeHead bs) bs of
      DecodeFailure           -> go_fast_end bs da
      DecodedToken sz (I# n#) ->
        case (n# ># 0x7fff#) `orI#` (n# <# -0x8000#) of
          0# | isIntCanonical sz n# -> k n# >>= go_fast (BS.unsafeDrop sz bs)
          _                         -> go_fast_end bs da

go_fast !bs da@(ConsumeInt32Canonical k) =
    case tryConsumeInt (BS.unsafeHead bs) bs of
      DecodeFailure           -> go_fast_end bs da
      DecodedToken sz (I# n#) ->
        case n_out_of_range n# of
          0# | isIntCanonical sz n# -> k n# >>= go_fast (BS.unsafeDrop sz bs)
          _                         -> go_fast_end bs da
  where
    n_out_of_range _n# =
#if defined(ARCH_32bit)
      0#
#else
      (_n# ># 0x7fffffff#) `orI#` (_n# <# -0x80000000#)
#endif

go_fast !bs da@(ConsumeListLenCanonical k) =
    case tryConsumeListLen (BS.unsafeHead bs) bs of
      DecodeFailure           -> go_fast_end bs da
      DecodedToken sz (I# n#)
          -- List length can't be negative, cast it to Word#.
        | isWordCanonical sz (int2Word# n#) -> k n# >>= go_fast (BS.unsafeDrop sz bs)
        | otherwise                         -> go_fast_end bs da

go_fast !bs da@(ConsumeMapLenCanonical k) =
    case tryConsumeMapLen (BS.unsafeHead bs) bs of
      DecodeFailure           -> go_fast_end bs da
      DecodedToken sz (I# n#)
          -- Map length can't be negative, cast it to Word#.
        | isWordCanonical sz (int2Word# n#) -> k n# >>= go_fast (BS.unsafeDrop sz bs)
        | otherwise                         -> go_fast_end bs da

go_fast !bs da@(ConsumeTagCanonical k) =
    case tryConsumeTag (BS.unsafeHead bs) bs of
      DecodeFailure           -> go_fast_end bs da
      DecodedToken sz (W# w#)
        | isWordCanonical sz w# -> k w# >>= go_fast (BS.unsafeDrop sz bs)
        | otherwise             -> go_fast_end bs da

#if defined(ARCH_32bit)
go_fast !bs da@(ConsumeWord64 k) =
  case tryConsumeWord64 (BS.unsafeHead bs) bs of
    DecodeFailure             -> go_fast_end bs da
    DecodedToken sz (W64# w#) -> k w# >>= go_fast (BS.unsafeDrop sz bs)

go_fast !bs da@(ConsumeNegWord64 k) =
  case tryConsumeNegWord64 (BS.unsafeHead bs) bs of
    DecodeFailure             -> go_fast_end bs da
    DecodedToken sz (W64# w#) -> k w# >>= go_fast (BS.unsafeDrop sz bs)

go_fast !bs da@(ConsumeInt64 k) =
  case tryConsumeInt64 (BS.unsafeHead bs) bs of
    DecodeFailure             -> go_fast_end bs da
    DecodedToken sz (I64# i#) -> k i# >>= go_fast (BS.unsafeDrop sz bs)

go_fast !bs da@(ConsumeListLen64 k) =
  case tryConsumeListLen64 (BS.unsafeHead bs) bs of
    DecodeFailure             -> go_fast_end bs da
    DecodedToken sz (I64# i#) -> k i# >>= go_fast (BS.unsafeDrop sz bs)

go_fast !bs da@(ConsumeMapLen64 k) =
  case tryConsumeMapLen64 (BS.unsafeHead bs) bs of
    DecodeFailure             -> go_fast_end bs da
    DecodedToken sz (I64# i#) -> k i# >>= go_fast (BS.unsafeDrop sz bs)

go_fast !bs da@(ConsumeTag64 k) =
  case tryConsumeTag64 (BS.unsafeHead bs) bs of
    DecodeFailure             -> go_fast_end bs da
    DecodedToken sz (W64# w#) -> k w# >>= go_fast (BS.unsafeDrop sz bs)

go_fast !bs da@(ConsumeWord64Canonical k) =
  case tryConsumeWord64 (BS.unsafeHead bs) bs of
    DecodeFailure             -> go_fast_end bs da
    DecodedToken sz (W64# w#)
      | isWord64Canonical -> k w# >>= go_fast (BS.unsafeDrop sz bs)
      | otherwise         -> go_fast_end bs da

go_fast !bs da@(ConsumeNegWord64Canonical k) =
  case tryConsumeNegWord64 (BS.unsafeHead bs) bs of
    DecodeFailure             -> go_fast_end bs da
    DecodedToken sz (W64# w#)
      | isWord64Canonical sz w# -> k w# >>= go_fast (BS.unsafeDrop sz bs)
      | otherwise               -> go_fast_end bs da

go_fast !bs da@(ConsumeInt64Canonical k) =
  case tryConsumeInt64 (BS.unsafeHead bs) bs of
    DecodeFailure             -> go_fast_end bs da
    DecodedToken sz (I64# i#)
      | isInt64Canonical sz i# -> k i# >>= go_fast (BS.unsafeDrop sz bs)
      | otherwise              -> go_fast_end bs da

go_fast !bs da@(ConsumeListLen64Canonical k) =
  case tryConsumeListLen64 (BS.unsafeHead bs) bs of
    DecodeFailure             -> go_fast_end bs da
    DecodedToken sz (I64# i#)
        -- List length can't be negative, cast it to Word64#.
      | isWord64Canonical sz (int64ToWord64 i#) -> k i# >>= go_fast (BS.unsafeDrop sz bs)
      | otherwise                               -> go_fast_end bs da

go_fast !bs da@(ConsumeMapLen64Canonical k) =
  case tryConsumeMapLen64 (BS.unsafeHead bs) bs of
    DecodeFailure             -> go_fast_end bs da
    DecodedToken sz (I64# i#)
        -- Map length can't be negative, cast it to Word64#.
      | isWord64Canonical sz (int64ToWord64 i#) -> k i# >>= go_fast (BS.unsafeDrop sz bs)
      | otherwise                               -> go_fast_end bs da

go_fast !bs da@(ConsumeTag64Canonical k) =
  case tryConsumeTag64 (BS.unsafeHead bs) bs of
    DecodeFailure             -> go_fast_end bs da
    DecodedToken sz (W64# w#)
      | isWord64Canonical sz w# -> k w# >>= go_fast (BS.unsafeDrop sz bs)
      | otherwise               -> go_fast_end bs da
#endif

go_fast !bs da@(ConsumeInteger k) =
    case tryConsumeInteger (BS.unsafeHead bs) bs of
      DecodedToken sz (BigIntToken _ n) -> k n >>= go_fast (BS.unsafeDrop sz bs)
      _                                 -> go_fast_end bs da

go_fast !bs da@(ConsumeFloat k) =
    case tryConsumeFloat (BS.unsafeHead bs) bs of
      DecodeFailure     -> go_fast_end bs da
      DecodedToken sz (F# f#) -> k f# >>= go_fast (BS.unsafeDrop sz bs)

go_fast !bs da@(ConsumeDouble k) =
    case tryConsumeDouble (BS.unsafeHead bs) bs of
      DecodeFailure     -> go_fast_end bs da
      DecodedToken sz (D# f#) -> k f# >>= go_fast (BS.unsafeDrop sz bs)

go_fast !bs da@(ConsumeBytes k) =
    case tryConsumeBytes (BS.unsafeHead bs) bs of
      DecodeFailure                 -> go_fast_end bs da
      DecodedToken sz (Fits bstr)   -> k bstr >>= go_fast (BS.unsafeDrop sz bs)
      DecodedToken sz (TooLong len) -> return $! SlowConsumeTokenBytes (BS.unsafeDrop sz bs) k len

go_fast !bs da@(ConsumeString k) =
    case tryConsumeString (BS.unsafeHead bs) bs of
      DecodeFailure                 -> go_fast_end bs da
      DecodedToken sz (Fits str)    -> k str >>= go_fast (BS.unsafeDrop sz bs)
      DecodedToken sz (TooLong len) -> return $! SlowConsumeTokenString (BS.unsafeDrop sz bs) k len

go_fast !bs da@(ConsumeBool k) =
    case tryConsumeBool (BS.unsafeHead bs) of
      DecodeFailure     -> go_fast_end bs da
      DecodedToken sz b -> k b >>= go_fast (BS.unsafeDrop sz bs)

go_fast !bs da@(ConsumeSimple k) =
    case tryConsumeSimple (BS.unsafeHead bs) bs of
      DecodeFailure           -> go_fast_end bs da
      DecodedToken sz (W# w#) -> k w# >>= go_fast (BS.unsafeDrop sz bs)

go_fast !bs da@(ConsumeIntegerCanonical k) =
    case tryConsumeInteger (BS.unsafeHead bs) bs of
      DecodedToken sz (BigIntToken True n) -> k n >>= go_fast (BS.unsafeDrop sz bs)
      _                                    -> go_fast_end bs da


go_fast !bs da@(ConsumeFloat16Canonical k) =
    case tryConsumeFloat (BS.unsafeHead bs) bs of
      DecodeFailure     -> go_fast_end bs da
      DecodedToken sz (F# f#)
        | isFloat16Canonical sz -> k f# >>= go_fast (BS.unsafeDrop sz bs)
        | otherwise             -> go_fast_end bs da

go_fast !bs da@(ConsumeFloatCanonical k) =
    case tryConsumeFloat (BS.unsafeHead bs) bs of
      DecodeFailure     -> go_fast_end bs da
      DecodedToken sz f@(F# f#)
        | isFloatCanonical sz bs f -> k f# >>= go_fast (BS.unsafeDrop sz bs)
        | otherwise                -> go_fast_end bs da

go_fast !bs da@(ConsumeDoubleCanonical k) =
    case tryConsumeDouble (BS.unsafeHead bs) bs of
      DecodeFailure     -> go_fast_end bs da
      DecodedToken sz f@(D# f#)
        | isDoubleCanonical sz bs f -> k f# >>= go_fast (BS.unsafeDrop sz bs)
        | otherwise                 -> go_fast_end bs da

go_fast !bs da@(ConsumeSimpleCanonical k) =
    case tryConsumeSimple (BS.unsafeHead bs) bs of
      DecodeFailure           -> go_fast_end bs da
      DecodedToken sz (W# w#)
        | isWordCanonical sz w# -> k w# >>= go_fast (BS.unsafeDrop sz bs)
        | otherwise             -> go_fast_end bs da

go_fast !bs da@(ConsumeBytesIndef k) =
    case tryConsumeBytesIndef (BS.unsafeHead bs) of
      DecodeFailure     -> go_fast_end bs da
      DecodedToken sz _ -> k >>= go_fast (BS.unsafeDrop sz bs)

go_fast !bs da@(ConsumeStringIndef k) =
    case tryConsumeStringIndef (BS.unsafeHead bs) of
      DecodeFailure     -> go_fast_end bs da
      DecodedToken sz _ -> k >>= go_fast (BS.unsafeDrop sz bs)

go_fast !bs da@(ConsumeListLenIndef k) =
    case tryConsumeListLenIndef (BS.unsafeHead bs) of
      DecodeFailure     -> go_fast_end bs da
      DecodedToken sz _ -> k >>= go_fast (BS.unsafeDrop sz bs)

go_fast !bs da@(ConsumeMapLenIndef k) =
    case tryConsumeMapLenIndef (BS.unsafeHead bs) of
      DecodeFailure     -> go_fast_end bs da
      DecodedToken sz _ -> k >>= go_fast (BS.unsafeDrop sz bs)

go_fast !bs da@(ConsumeNull k) =
    case tryConsumeNull (BS.unsafeHead bs) of
      DecodeFailure     -> go_fast_end bs da
      DecodedToken sz _ -> k >>= go_fast (BS.unsafeDrop sz bs)

go_fast !bs da@(ConsumeListLenOrIndef k) =
    case tryConsumeListLenOrIndef (BS.unsafeHead bs) bs of
      DecodeFailure           -> go_fast_end bs da
      DecodedToken sz (I# n#) -> k n# >>= go_fast (BS.unsafeDrop sz bs)

go_fast !bs da@(ConsumeMapLenOrIndef k) =
    case tryConsumeMapLenOrIndef (BS.unsafeHead bs) bs of
      DecodeFailure           -> go_fast_end bs da
      DecodedToken sz (I# n#) -> k n# >>= go_fast (BS.unsafeDrop sz bs)

go_fast !bs (ConsumeBreakOr k) =
    case tryConsumeBreakOr (BS.unsafeHead bs) of
      DecodeFailure     -> k False >>= go_fast bs
      DecodedToken sz _ -> k True >>= go_fast (BS.unsafeDrop sz bs)

go_fast !bs (PeekTokenType k) =
    let !hdr  = BS.unsafeHead bs
        !tkty = decodeTokenTypeTable `A.unsafeAt` fromIntegral hdr
    in k tkty >>= go_fast bs

go_fast !bs (PeekAvailable k) = k (case BS.length bs of I# len# -> len#) >>= go_fast bs

go_fast !bs da@D.Fail{} = go_fast_end bs da
go_fast !bs da@D.Done{} = go_fast_end bs da


-- This variant of the fast path has to do a few more checks because we're
-- near the end of the chunk. The guarantee we provide here is that we will
-- decode any tokens where the whole token fits within the input buffer. So
-- if we return with input buffer space still unconsumed (and we're not done
-- or failed) then there's one remaining token that spans the end of the
-- input chunk (the slow path fixup code relies on this guarantee).
--
go_fast_end :: ByteString -> DecodeAction s a -> ST s (SlowPath s a)

-- these three cases don't need any input

go_fast_end !bs (D.Fail msg)      = return $! SlowFail bs msg
go_fast_end !bs (D.Done x)        = return $! FastDone bs x
go_fast_end !bs (PeekAvailable k) = k (case BS.length bs of I# len# -> len#) >>= go_fast_end bs

-- the next two cases only need the 1 byte token header
go_fast_end !bs da | BS.null bs = return $! SlowDecodeAction bs da

go_fast_end !bs (ConsumeBreakOr k) =
    case tryConsumeBreakOr (BS.unsafeHead bs) of
      DecodeFailure     -> k False >>= go_fast_end bs
      DecodedToken sz _ -> k True  >>= go_fast_end (BS.unsafeDrop sz bs)

go_fast_end !bs (PeekTokenType k) =
    let !hdr  = BS.unsafeHead bs
        !tkty = decodeTokenTypeTable `A.unsafeAt` fromIntegral hdr
    in k tkty >>= go_fast_end bs

-- all the remaining cases have to decode the current token

go_fast_end !bs da
    | let !hdr = BS.unsafeHead bs
    , BS.length bs < tokenSize hdr
    = return $! SlowDecodeAction bs da

go_fast_end !bs (ConsumeWord k) =
    case tryConsumeWord (BS.unsafeHead bs) bs of
      DecodeFailure           -> return $! SlowFail bs "expected word"
      DecodedToken sz (W# w#) -> k w# >>= go_fast_end (BS.unsafeDrop sz bs)

go_fast_end !bs (ConsumeWord8 k) =
    case tryConsumeWord (BS.unsafeHead bs) bs of
      DecodeFailure           -> return $! SlowFail bs "expected word8"
      DecodedToken sz (W# w#) ->
        case gtWord# w# 0xff## of
          0#                  -> k w# >>= go_fast_end (BS.unsafeDrop sz bs)
          _                   -> return $! SlowFail bs "expected word8"

go_fast_end !bs (ConsumeWord16 k) =
    case tryConsumeWord (BS.unsafeHead bs) bs of
      DecodeFailure           -> return $! SlowFail bs "expected word16"
      DecodedToken sz (W# w#) ->
        case gtWord# w# 0xffff## of
          0#                  -> k w# >>= go_fast_end (BS.unsafeDrop sz bs)
          _                   -> return $! SlowFail bs "expected word16"

go_fast_end !bs (ConsumeWord32 k) =
    case tryConsumeWord (BS.unsafeHead bs) bs of
      DecodeFailure           -> return $! SlowFail bs "expected word32"
      DecodedToken sz (W# w#) ->
#if defined(ARCH_32bit)
                                 k w# >>= go_fast_end (BS.unsafeDrop sz bs)
#else
        case gtWord# w# 0xffffffff## of
          0#                  -> k w# >>= go_fast_end (BS.unsafeDrop sz bs)
          _                   -> return $! SlowFail bs "expected word32"
#endif

go_fast_end !bs (ConsumeNegWord k) =
    case tryConsumeNegWord (BS.unsafeHead bs) bs of
      DecodeFailure           -> return $! SlowFail bs "expected negative int"
      DecodedToken sz (W# w#) -> k w# >>= go_fast_end (BS.unsafeDrop sz bs)

go_fast_end !bs (ConsumeInt k) =
    case tryConsumeInt (BS.unsafeHead bs) bs of
      DecodeFailure           -> return $! SlowFail bs "expected int"
      DecodedToken sz (I# n#) -> k n# >>= go_fast_end (BS.unsafeDrop sz bs)

go_fast_end !bs (ConsumeInt8 k) =
    case tryConsumeInt (BS.unsafeHead bs) bs of
      DecodeFailure           -> return $! SlowFail bs "expected int8"
      DecodedToken sz (I# n#) ->
        case (n# ># 0x7f#) `orI#` (n# <# -0x80#) of
          0#                  -> k n# >>= go_fast_end (BS.unsafeDrop sz bs)
          _                   -> return $! SlowFail bs "expected int8"

go_fast_end !bs (ConsumeInt16 k) =
    case tryConsumeInt (BS.unsafeHead bs) bs of
      DecodeFailure           -> return $! SlowFail bs "expected int16"
      DecodedToken sz (I# n#) ->
        case (n# ># 0x7fff#) `orI#` (n# <# -0x8000#) of
          0#                  -> k n# >>= go_fast_end (BS.unsafeDrop sz bs)
          _                   -> return $! SlowFail bs "expected int16"

go_fast_end !bs (ConsumeInt32 k) =
    case tryConsumeInt (BS.unsafeHead bs) bs of
      DecodeFailure           -> return $! SlowFail bs "expected int32"
      DecodedToken sz (I# n#) ->
#if defined(ARCH_32bit)
                                 k n# >>= go_fast_end (BS.unsafeDrop sz bs)
#else
        case (n# ># 0x7fffffff#) `orI#` (n# <# -0x80000000#) of
          0#                  -> k n# >>= go_fast_end (BS.unsafeDrop sz bs)
          _                   -> return $! SlowFail bs "expected int32"
#endif

go_fast_end !bs (ConsumeListLen k) =
    case tryConsumeListLen (BS.unsafeHead bs) bs of
      DecodeFailure           -> return $! SlowFail bs "expected list len"
      DecodedToken sz (I# n#) -> k n# >>= go_fast_end (BS.unsafeDrop sz bs)

go_fast_end !bs (ConsumeMapLen k) =
    case tryConsumeMapLen (BS.unsafeHead bs) bs of
      DecodeFailure           -> return $! SlowFail bs "expected map len"
      DecodedToken sz (I# n#) -> k n# >>= go_fast_end (BS.unsafeDrop sz bs)

go_fast_end !bs (ConsumeTag k) =
    case tryConsumeTag (BS.unsafeHead bs) bs of
      DecodeFailure           -> return $! SlowFail bs "expected tag"
      DecodedToken sz (W# w#) -> k w# >>= go_fast_end (BS.unsafeDrop sz bs)

go_fast_end !bs (ConsumeWordCanonical k) =
    case tryConsumeWord (BS.unsafeHead bs) bs of
      DecodeFailure           -> return $! SlowFail bs "expected word"
      DecodedToken sz (W# w#)
        | isWordCanonical sz w# -> k w# >>= go_fast_end (BS.unsafeDrop sz bs)
        | otherwise             -> return $! SlowFail bs "non-canonical word"

go_fast_end !bs (ConsumeWord8Canonical k) =
    case tryConsumeWord (BS.unsafeHead bs) bs of
      DecodeFailure           -> return $! SlowFail bs "expected word8"
      DecodedToken sz (W# w#) -> case gtWord# w# 0xff## of
          0# | isWordCanonical sz w# -> k w# >>= go_fast_end (BS.unsafeDrop sz bs)
             | otherwise             -> return $! SlowFail bs "non-canonical word8"
          _                          -> return $! SlowFail bs "expected word8"

go_fast_end !bs (ConsumeWord16Canonical k) =
    case tryConsumeWord (BS.unsafeHead bs) bs of
      DecodeFailure           -> return $! SlowFail bs "expected word16"
      DecodedToken sz (W# w#) -> case gtWord# w# 0xffff## of
        0# | isWordCanonical sz w# -> k w# >>= go_fast_end (BS.unsafeDrop sz bs)
           | otherwise             -> return $! SlowFail bs "non-canonical word16"
        _                          -> return $! SlowFail bs "expected word16"

go_fast_end !bs (ConsumeWord32Canonical k) =
    case tryConsumeWord (BS.unsafeHead bs) bs of
      DecodeFailure           -> return $! SlowFail bs "expected word32"
      DecodedToken sz (W# w#) -> case w_out_of_range w# of
        0# | isWordCanonical sz w# -> k w# >>= go_fast_end (BS.unsafeDrop sz bs)
           | otherwise             -> return $! SlowFail bs "non-canonical word32"
        _                          -> return $! SlowFail bs "expected word32"
  where
    w_out_of_range _w# =
#if defined(ARCH_32bit)
      0#
#else
      gtWord# _w# 0xffffffff##
#endif

go_fast_end !bs (ConsumeNegWordCanonical k) =
    case tryConsumeNegWord (BS.unsafeHead bs) bs of
      DecodeFailure           -> return $! SlowFail bs "expected negative int"
      DecodedToken sz (W# w#)
        | isWordCanonical sz w# -> k w# >>= go_fast_end (BS.unsafeDrop sz bs)
        | otherwise             -> return $! SlowFail bs "non-canonical negative int"

go_fast_end !bs (ConsumeIntCanonical k) =
    case tryConsumeInt (BS.unsafeHead bs) bs of
      DecodeFailure           -> return $! SlowFail bs "expected int"
      DecodedToken sz (I# n#)
        | isIntCanonical sz n# -> k n# >>= go_fast_end (BS.unsafeDrop sz bs)
        | otherwise            -> return $! SlowFail bs "non-canonical int"

go_fast_end !bs (ConsumeInt8Canonical k) =
    case tryConsumeInt (BS.unsafeHead bs) bs of
      DecodeFailure           -> return $! SlowFail bs "expected int8"
      DecodedToken sz (I# n#) ->
        case (n# ># 0x7f#) `orI#` (n# <# -0x80#) of
          0# | isIntCanonical sz n# -> k n# >>= go_fast_end (BS.unsafeDrop sz bs)
             | otherwise            -> return $! SlowFail bs "non-canonical int8"
          _                         -> return $! SlowFail bs "expected int8"

go_fast_end !bs (ConsumeInt16Canonical k) =
    case tryConsumeInt (BS.unsafeHead bs) bs of
      DecodeFailure           -> return $! SlowFail bs "expected int16"
      DecodedToken sz (I# n#) ->
        case (n# ># 0x7fff#) `orI#` (n# <# -0x8000#) of
          0# | isIntCanonical sz n# -> k n# >>= go_fast_end (BS.unsafeDrop sz bs)
             | otherwise            -> return $! SlowFail bs "non-canonical int16"
          _                         -> return $! SlowFail bs "expected int16"

go_fast_end !bs (ConsumeInt32Canonical k) =
    case tryConsumeInt (BS.unsafeHead bs) bs of
      DecodeFailure           -> return $! SlowFail bs "expected int32"
      DecodedToken sz (I# n#) ->
        case n_out_of_range n# of
          0# | isIntCanonical sz n# -> k n# >>= go_fast_end (BS.unsafeDrop sz bs)
             | otherwise            -> return $! SlowFail bs "non-canonical int32"
          _                         -> return $! SlowFail bs "expected int32"
  where
    n_out_of_range _n# =
#if defined(ARCH_32bit)
      0#
#else
      (_n# ># 0x7fffffff#) `orI#` (_n# <# -0x80000000#)
#endif

go_fast_end !bs (ConsumeListLenCanonical k) =
    case tryConsumeListLen (BS.unsafeHead bs) bs of
      DecodeFailure           -> return $! SlowFail bs "expected list len"
      DecodedToken sz (I# n#)
          -- List length can't be negative, cast it to Word#.
        | isWordCanonical sz (int2Word# n#) -> k n# >>= go_fast_end (BS.unsafeDrop sz bs)
        | otherwise                         -> return $! SlowFail bs "non-canonical list len"

go_fast_end !bs (ConsumeMapLenCanonical k) =
    case tryConsumeMapLen (BS.unsafeHead bs) bs of
      DecodeFailure           -> return $! SlowFail bs "expected map len"
      DecodedToken sz (I# n#)
          -- Map length can't be negative, cast it to Word#.
        | isWordCanonical sz (int2Word# n#) -> k n# >>= go_fast_end (BS.unsafeDrop sz bs)
        | otherwise                         -> return $! SlowFail bs "non-canonical map len"

go_fast_end !bs (ConsumeTagCanonical k) =
    case tryConsumeTag (BS.unsafeHead bs) bs of
      DecodeFailure           -> return $! SlowFail bs "expected tag"
      DecodedToken sz (W# w#)
        | isWordCanonical sz w# -> k w# >>= go_fast_end (BS.unsafeDrop sz bs)
        | otherwise             -> return $! SlowFail bs "non-canonical tag"

#if defined(ARCH_32bit)
go_fast_end !bs (ConsumeWord64 k) =
  case tryConsumeWord64 (BS.unsafeHead bs) bs of
    DecodeFailure             -> return $! SlowFail bs "expected word64"
    DecodedToken sz (W64# w#) -> k w# >>= go_fast_end (BS.unsafeDrop sz bs)

go_fast_end !bs (ConsumeNegWord64 k) =
  case tryConsumeNegWord64 (BS.unsafeHead bs) bs of
    DecodeFailure             -> return $! SlowFail bs "expected negative word64"
    DecodedToken sz (W64# w#) -> k w# >>= go_fast_end (BS.unsafeDrop sz bs)

go_fast_end !bs (ConsumeInt64 k) =
  case tryConsumeInt64 (BS.unsafeHead bs) bs of
    DecodeFailure             -> return $! SlowFail bs "expected int64"
    DecodedToken sz (I64# i#) -> k i# >>= go_fast_end (BS.unsafeDrop sz bs)

go_fast_end !bs (ConsumeListLen64 k) =
  case tryConsumeListLen64 (BS.unsafeHead bs) bs of
    DecodeFailure             -> return $! SlowFail bs "expected list len 64"
    DecodedToken sz (I64# i#) -> k i# >>= go_fast_end (BS.unsafeDrop sz bs)

go_fast_end !bs (ConsumeMapLen64 k) =
  case tryConsumeMapLen64 (BS.unsafeHead bs) bs of
    DecodeFailure             -> return $! SlowFail bs "expected map len 64"
    DecodedToken sz (I64# i#) -> k i# >>= go_fast_end (BS.unsafeDrop sz bs)

go_fast_end !bs (ConsumeTag64 k) =
  case tryConsumeTag64 (BS.unsafeHead bs) bs of
    DecodeFailure             -> return $! SlowFail bs "expected tag64"
    DecodedToken sz (W64# w#) -> k w# >>= go_fast_end (BS.unsafeDrop sz bs)
#endif

go_fast_end !bs (ConsumeInteger k) =
    case tryConsumeInteger (BS.unsafeHead bs) bs of
      DecodeFailure                         -> return $! SlowFail bs "expected integer"
      DecodedToken sz (BigIntToken _ n)     -> k n >>= go_fast_end (BS.unsafeDrop sz bs)
      DecodedToken sz (BigUIntNeedBody len) -> return $! SlowConsumeTokenBytes (BS.unsafeDrop sz bs) (adjustContBigUIntNeedBody k) len
      DecodedToken sz (BigNIntNeedBody len) -> return $! SlowConsumeTokenBytes (BS.unsafeDrop sz bs) (adjustContBigNIntNeedBody k) len
      DecodedToken sz  BigUIntNeedHeader    -> return $! SlowDecodeAction      (BS.unsafeDrop sz bs) (adjustContBigUIntNeedHeader k)
      DecodedToken sz  BigNIntNeedHeader    -> return $! SlowDecodeAction      (BS.unsafeDrop sz bs) (adjustContBigNIntNeedHeader k)

go_fast_end !bs (ConsumeFloat k) =
    case tryConsumeFloat (BS.unsafeHead bs) bs of
      DecodeFailure     -> return $! SlowFail bs "expected float"
      DecodedToken sz (F# f#) -> k f# >>= go_fast_end (BS.unsafeDrop sz bs)

go_fast_end !bs (ConsumeDouble k) =
    case tryConsumeDouble (BS.unsafeHead bs) bs of
      DecodeFailure           -> return $! SlowFail bs "expected double"
      DecodedToken sz (D# f#) -> k f# >>= go_fast_end (BS.unsafeDrop sz bs)

go_fast_end !bs (ConsumeBytes k) =
    case tryConsumeBytes (BS.unsafeHead bs) bs of
      DecodeFailure                 -> return $! SlowFail bs "expected bytes"
      DecodedToken sz (Fits bstr)   -> k bstr >>= go_fast_end (BS.unsafeDrop sz bs)
      DecodedToken sz (TooLong len) -> return $! SlowConsumeTokenBytes (BS.unsafeDrop sz bs) k len

go_fast_end !bs (ConsumeString k) =
    case tryConsumeString (BS.unsafeHead bs) bs of
      DecodeFailure                 -> return $! SlowFail bs "expected string"
      DecodedToken sz (Fits str)    -> k str >>= go_fast_end (BS.unsafeDrop sz bs)
      DecodedToken sz (TooLong len) -> return $! SlowConsumeTokenString (BS.unsafeDrop sz bs) k len

go_fast_end !bs (ConsumeBool k) =
    case tryConsumeBool (BS.unsafeHead bs) of
      DecodeFailure     -> return $! SlowFail bs "expected bool"
      DecodedToken sz b -> k b >>= go_fast_end (BS.unsafeDrop sz bs)

go_fast_end !bs (ConsumeSimple k) =
    case tryConsumeSimple (BS.unsafeHead bs) bs of
      DecodeFailure           -> return $! SlowFail bs "expected simple"
      DecodedToken sz (W# w#) -> k w# >>= go_fast_end (BS.unsafeDrop sz bs)

go_fast_end !bs (ConsumeIntegerCanonical k) =
    case tryConsumeInteger (BS.unsafeHead bs) bs of
      DecodeFailure                         -> return $! SlowFail bs "expected integer"
      DecodedToken sz (BigIntToken canonical n)
        | canonical -> k n >>= go_fast_end (BS.unsafeDrop sz bs)
        | otherwise -> return $! SlowFail bs "non-canonical integer"
      DecodedToken sz (BigUIntNeedBody len) -> return $! SlowConsumeTokenBytes (BS.unsafeDrop sz bs) (adjustContBigUIntNeedBody k) len
      DecodedToken sz (BigNIntNeedBody len) -> return $! SlowConsumeTokenBytes (BS.unsafeDrop sz bs) (adjustContBigNIntNeedBody k) len
      DecodedToken sz  BigUIntNeedHeader    -> return $! SlowDecodeAction      (BS.unsafeDrop sz bs) (adjustContBigUIntNeedHeader k)
      DecodedToken sz  BigNIntNeedHeader    -> return $! SlowDecodeAction      (BS.unsafeDrop sz bs) (adjustContBigNIntNeedHeader k)

go_fast_end !bs (ConsumeFloat16Canonical k) =
    case tryConsumeFloat (BS.unsafeHead bs) bs of
      DecodeFailure     -> return $! SlowFail bs "expected float"
      DecodedToken sz (F# f#)
        | isFloat16Canonical sz -> k f# >>= go_fast_end (BS.unsafeDrop sz bs)
        | otherwise             -> return $! SlowFail bs "non-canonical float16"

go_fast_end !bs (ConsumeFloatCanonical k) =
    case tryConsumeFloat (BS.unsafeHead bs) bs of
      DecodeFailure     -> return $! SlowFail bs "expected float"
      DecodedToken sz f@(F# f#)
        | isFloatCanonical sz bs f -> k f# >>= go_fast_end (BS.unsafeDrop sz bs)
        | otherwise                -> return $! SlowFail bs "non-canonical float"

go_fast_end !bs (ConsumeDoubleCanonical k) =
    case tryConsumeDouble (BS.unsafeHead bs) bs of
      DecodeFailure           -> return $! SlowFail bs "expected double"
      DecodedToken sz f@(D# f#)
        | isDoubleCanonical sz bs f -> k f# >>= go_fast_end (BS.unsafeDrop sz bs)
        | otherwise                 -> return $! SlowFail bs "non-canonical double"

go_fast_end !bs (ConsumeSimpleCanonical k) =
    case tryConsumeSimple (BS.unsafeHead bs) bs of
      DecodeFailure           -> return $! SlowFail bs "expected simple"
      DecodedToken sz (W# w#)
        | isWordCanonical sz w# -> k w# >>= go_fast_end (BS.unsafeDrop sz bs)
        | otherwise             -> return $! SlowFail bs "non-canonical simple"

go_fast_end !bs (ConsumeBytesIndef k) =
    case tryConsumeBytesIndef (BS.unsafeHead bs) of
      DecodeFailure     -> return $! SlowFail bs "expected bytes start"
      DecodedToken sz _ -> k >>= go_fast_end (BS.unsafeDrop sz bs)

go_fast_end !bs (ConsumeStringIndef k) =
    case tryConsumeStringIndef (BS.unsafeHead bs) of
      DecodeFailure     -> return $! SlowFail bs "expected string start"
      DecodedToken sz _ -> k >>= go_fast_end (BS.unsafeDrop sz bs)

go_fast_end !bs (ConsumeListLenIndef k) =
    case tryConsumeListLenIndef (BS.unsafeHead bs) of
      DecodeFailure     -> return $! SlowFail bs "expected list start"
      DecodedToken sz _ -> k >>= go_fast_end (BS.unsafeDrop sz bs)

go_fast_end !bs (ConsumeMapLenIndef k) =
    case tryConsumeMapLenIndef (BS.unsafeHead bs) of
      DecodeFailure     -> return $! SlowFail bs "expected map start"
      DecodedToken sz _ -> k >>= go_fast_end (BS.unsafeDrop sz bs)

go_fast_end !bs (ConsumeNull k) =
    case tryConsumeNull (BS.unsafeHead bs) of
      DecodeFailure     -> return $! SlowFail bs "expected null"
      DecodedToken sz _ -> k >>= go_fast_end (BS.unsafeDrop sz bs)

go_fast_end !bs (ConsumeListLenOrIndef k) =
    case tryConsumeListLenOrIndef (BS.unsafeHead bs) bs of
      DecodeFailure           -> return $! SlowFail bs "expected list len or indef"
      DecodedToken sz (I# n#) -> k n# >>= go_fast_end (BS.unsafeDrop sz bs)

go_fast_end !bs (ConsumeMapLenOrIndef k) =
    case tryConsumeMapLenOrIndef (BS.unsafeHead bs) bs of
      DecodeFailure           -> return $! SlowFail bs "expected map len or indef"
      DecodedToken sz (I# n#) -> k n# >>= go_fast_end (BS.unsafeDrop sz bs)


-- The slow path starts off by running the fast path on the current chunk
-- then looking at where it finished, fixing up the chunk boundary issues,
-- getting more input and going around again.
--
-- The offset here is the offset after of all data consumed so far,
-- so not including the current chunk.
--
go_slow :: DecodeAction s a -> ByteString -> ByteOffset
        -> IncrementalDecoder s (ByteString, ByteOffset, a)
go_slow da bs !offset = do
  slowpath <- lift $ go_fast bs da
  case slowpath of
    FastDone bs' x -> return (bs', offset', x)
      where
        !offset' = offset + fromIntegral (BS.length bs - BS.length bs')

    SlowConsumeTokenBytes bs' k len -> do
      (bstr, bs'') <- getTokenVarLen len bs' offset'
      lift (k bstr) >>= \daz -> go_slow daz bs'' (offset' + fromIntegral len)
      where
        !offset' = offset + fromIntegral (BS.length bs - BS.length bs')

    SlowConsumeTokenString bs' k len -> do
      (bstr, bs'') <- getTokenVarLen len bs' offset'
      let !str = T.decodeUtf8 bstr  -- TODO FIXME: utf8 validation
      lift (k str) >>= \daz -> go_slow daz bs'' (offset' + fromIntegral len)
      where
        !offset' = offset + fromIntegral (BS.length bs - BS.length bs')

    -- we didn't have enough input in the buffer
    SlowDecodeAction bs' da' | BS.null bs' -> do
      -- in this case we're exactly out of input
      -- so we can get more input and carry on
      mbs <- needChunk
      case mbs of
        Nothing   -> decodeFail bs' offset' "end of input"
        Just bs'' -> go_slow da' bs'' offset'
      where
        !offset' = offset + fromIntegral (BS.length bs - BS.length bs')

    SlowDecodeAction bs' da' ->
      -- of course we should only end up here when we really are out of
      -- input, otherwise go_fast_end could have continued
      assert (BS.length bs' < tokenSize (BS.head bs')) $
      go_slow_fixup da' bs' offset'
      where
        !offset' = offset + fromIntegral (BS.length bs - BS.length bs')

    SlowFail bs' msg -> decodeFail bs' offset' msg
      where
        !offset' = offset + fromIntegral (BS.length bs - BS.length bs')

-- The complicated case is when a token spans a chunk boundary.
--
-- Our goal is to get enough input so that go_fast_end can consume exactly one
-- token without need for further fixups.
--
go_slow_fixup :: DecodeAction s a -> ByteString -> ByteOffset
              -> IncrementalDecoder s (ByteString, ByteOffset, a)
go_slow_fixup da !bs !offset = do
    let !hdr = BS.head bs
        !sz  = tokenSize hdr
    mbs <- needChunk
    case mbs of
      Nothing -> decodeFail bs offset "end of input"

      Just bs'
          -- We have enough input now, try reading one final token
        | BS.length bs + BS.length bs' >= sz
       -> go_slow_overlapped da sz bs bs' offset

          -- We still don't have enough input, get more
        | otherwise
       -> go_slow_fixup da (bs <> bs') offset

-- We've now got more input, but we have one token that spanned the old and
-- new input buffers, so we have to decode that one before carrying on
go_slow_overlapped :: DecodeAction s a -> Int -> ByteString -> ByteString
                   -> ByteOffset
                   -> IncrementalDecoder s (ByteString, ByteOffset, a)
go_slow_overlapped da sz bs_cur bs_next !offset =

    -- we have:
    --   sz            the size of the pending input token
    --   bs_cur        the tail end of the previous input buffer
    --   bs_next       the next input chunk

    -- we know the old buffer is too small, but the combo is enough
    assert (BS.length bs_cur < sz) $
    assert (BS.length bs_cur + BS.length bs_next >= sz) $

    -- we make:
    --   bs_tok        a buffer containing only the pending input token
    --   bs'           the tail of the next input chunk,
    --                   which will become the next input buffer

    let bs_tok   = bs_cur <> BS.unsafeTake (sz - BS.length bs_cur) bs_next
        bs'      =           BS.unsafeDrop (sz - BS.length bs_cur) bs_next
        offset'  = offset + fromIntegral sz in

    -- so the token chunk should be exactly the right size
    assert (BS.length bs_tok == sz) $
    -- and overall we shouldn't loose any input
    assert (BS.length bs_cur + BS.length bs_next == sz + BS.length bs') $ do

    -- so now we can run the fast path to consume just this one token
    slowpath <- lift $ go_fast_end bs_tok da
    case slowpath of

      -- typically we'll fall out of the fast path having
      -- consumed exactly one token, now with no trailing data
      SlowDecodeAction bs_empty da' ->
        assert (BS.null bs_empty) $
        go_slow da' bs' offset'

      -- but the other possibilities can happen too
      FastDone bs_empty x ->
        assert (BS.null bs_empty) $
        return (bs', offset', x)

      SlowConsumeTokenBytes bs_empty k len ->
        assert (BS.null bs_empty) $ do
        (bstr, bs'') <- if BS.length bs' < len
                          then getTokenVarLen len bs' offset'
                          else let !bstr = BS.take len bs'
                                   !bs'' = BS.drop len bs'
                                in return (bstr, bs'')
        lift (k bstr) >>= \daz -> go_slow daz bs'' (offset' + fromIntegral len)

      SlowConsumeTokenString bs_empty k len ->
        assert (BS.null bs_empty) $ do
        (bstr, bs'') <- if BS.length bs' < len
                          then getTokenVarLen len bs' offset'
                          else let !bstr = BS.take len bs'
                                   !bs'' = BS.drop len bs'
                                in return (bstr, bs'')
        let !str = T.decodeUtf8 bstr  -- TODO FIXME: utf8 validation
        lift (k str) >>= \daz -> go_slow daz bs'' (offset' + fromIntegral len)

      SlowFail bs_unconsumed msg ->
        decodeFail (bs_unconsumed <> bs') offset'' msg
        where
          !offset'' = offset + fromIntegral (sz - BS.length bs_unconsumed)



-- TODO FIXME: we can do slightly better here. If we're returning a
-- lazy string (String, lazy Text, lazy ByteString) then we don't have
-- to strictify here and if we're returning a strict string perhaps we
-- can still stream the utf8 validation/converstion

-- TODO FIXME: also consider sharing or not sharing here, and possibly
-- rechunking.

getTokenVarLen :: Int -> ByteString -> ByteOffset
               -> IncrementalDecoder s (ByteString, ByteString)
getTokenVarLen len bs offset =
    assert (len > BS.length bs) $ do
    mbs <- needChunk
    case mbs of
      Nothing -> decodeFail BS.empty offset "end of input"
      Just bs'
        | let n = len - BS.length bs
        , BS.length bs' >= n ->
            let !tok = bs <> BS.unsafeTake n bs'
             in return (tok, BS.drop n bs')

        | otherwise -> getTokenVarLenSlow
                         [bs',bs]
                         (len - (BS.length bs + BS.length bs'))
                         offset

getTokenVarLenSlow :: [ByteString] -> Int -> ByteOffset
                   -> IncrementalDecoder s (ByteString, ByteString)
getTokenVarLenSlow bss n offset = do
    mbs <- needChunk
    case mbs of
      Nothing -> decodeFail BS.empty offset "end of input"
      Just bs
        | BS.length bs >= n ->
            let !tok = BS.concat (reverse (BS.unsafeTake n bs : bss))
             in return (tok, BS.drop n bs)
        | otherwise -> getTokenVarLenSlow (bs:bss) (n - BS.length bs) offset



tokenSize :: Word8 -> Int
tokenSize hdr =
    fromIntegral $
      decodeTableSz `A.unsafeAt` (fromIntegral hdr .&. 0x1f)

decodeTableSz :: UArray Word8 Word8
decodeTableSz =
  array (0, 0x1f) $
      [ (encodeHeader 0 n, 1) | n <- [0..0x1f] ]
   ++ [ (encodeHeader 0 n, s) | (n, s) <- zip [24..27] [2,3,5,9] ]

decodeTokenTypeTable :: Array Word8 TokenType
decodeTokenTypeTable =
  array (minBound, maxBound) $
    [ (encodeHeader 0 n,  TypeUInt) | n <-  [0..26] ]
 ++ [ (encodeHeader 0 27, TypeUInt64)
    , (encodeHeader 0 31, TypeInvalid) ]

 ++ [ (encodeHeader 1 n,  TypeNInt) | n <-  [0..26] ]
 ++ [ (encodeHeader 1 27, TypeNInt64)
    , (encodeHeader 1 31, TypeInvalid) ]

 ++ [ (encodeHeader 2 n,  TypeBytes) | n <-  [0..27] ]
 ++ [ (encodeHeader 2 31, TypeBytesIndef) ]

 ++ [ (encodeHeader 3 n,  TypeString) | n <-  [0..27] ]
 ++ [ (encodeHeader 3 31, TypeStringIndef) ]

 ++ [ (encodeHeader 4 n,  TypeListLen) | n <-  [0..26] ]
 ++ [ (encodeHeader 4 27, TypeListLen64)
    , (encodeHeader 4 31, TypeListLenIndef) ]

 ++ [ (encodeHeader 5 n,  TypeMapLen) | n <-  [0..26] ]
 ++ [ (encodeHeader 5 27, TypeMapLen64)
    , (encodeHeader 5 31, TypeMapLenIndef) ]

 ++ [ (encodeHeader 6 n,  TypeTag) | n <- 0:1:[4..26] ]
 ++ [ (encodeHeader 6 2,  TypeInteger)
    , (encodeHeader 6 3,  TypeInteger)
    , (encodeHeader 6 27, TypeTag64)
    , (encodeHeader 6 31, TypeInvalid) ]

 ++ [ (encodeHeader 7 n,  TypeSimple) | n <-  [0..19] ]
 ++ [ (encodeHeader 7 20, TypeBool)
    , (encodeHeader 7 21, TypeBool)
    , (encodeHeader 7 22, TypeNull)
    , (encodeHeader 7 23, TypeSimple)
    , (encodeHeader 7 24, TypeSimple)
    , (encodeHeader 7 25, TypeFloat16)
    , (encodeHeader 7 26, TypeFloat32)
    , (encodeHeader 7 27, TypeFloat64)
    , (encodeHeader 7 31, TypeBreak) ]

 ++ [ (encodeHeader mt n, TypeInvalid) | mt <- [0..7], n <- [28..30] ]

encodeHeader :: Word -> Word -> Word8
encodeHeader mt ai = fromIntegral (mt `shiftL` 5 .|. ai)

data DecodedToken a = DecodedToken !Int !a | DecodeFailure
  deriving Show

data LongToken a = Fits !a | TooLong !Int
  deriving Show

{-# INLINE isFloat16Canonical #-}
isFloat16Canonical :: Int -> Bool
isFloat16Canonical sz
  | sz == 3   = True
  | otherwise = False

{-# INLINE isFloatCanonical #-}
isFloatCanonical :: Int -> BS.ByteString -> Float -> Bool
isFloatCanonical sz bs f
  | isNaN f   = sz == 3 && "\xf9\x7e\x00" `BS.isPrefixOf` bs
  | otherwise = sz == 5

{-# INLINE isDoubleCanonical #-}
isDoubleCanonical :: Int -> BS.ByteString -> Double -> Bool
isDoubleCanonical sz bs f
  | isNaN f   = sz == 3 && "\xf9\x7e\x00" `BS.isPrefixOf` bs
  | otherwise = sz == 9

{-# INLINE isWordCanonical #-}
isWordCanonical :: Int -> Word# -> Bool
isWordCanonical sz w#
  | sz == 2 && isTrue# (w# `leWord#` 0x17##)       = False
  | sz == 3 && isTrue# (w# `leWord#` 0xff##)       = False
  | sz == 5 && isTrue# (w# `leWord#` 0xffff##)     = False
  | sz == 9 && isTrue# (w# `leWord#` 0xffffffff##) = False
  | otherwise                                      = True

{-# INLINE isIntCanonical #-}
isIntCanonical :: Int -> Int# -> Bool
isIntCanonical sz i#
  | isTrue# (i# <# 0#) = isWordCanonical sz (not# w#)
  | otherwise          = isWordCanonical sz       w#
  where
    w# = int2Word# i#

#if defined(ARCH_32bit)
{-# INLINE isWord64Canonical #-}
isWord64Canonical :: Int -> Word64# -> Bool
isWord64Canonical sz w#
  | sz == 2 && isTrue# (w# `leWord64#` 0x17##)       = False
  | sz == 3 && isTrue# (w# `leWord64#` 0xff##)       = False
  | sz == 5 && isTrue# (w# `leWord64#` 0xffff##)     = False
  | sz == 9 && isTrue# (w# `leWord64#` 0xffffffff##) = False
  | otherwise                                        = True

{-# INLINE isInt64Canonical #-}
isInt64Canonical :: Int -> Int64# -> Bool
isInt64Canonical sz i#
  | isTrue# (i# <# 0#) = isWord64Canonical sz (not64# w#)
  | otherwise          = isWord64Canonical sz         w#
  where
    w# = int64ToWord64# i#
#endif

-- TODO FIXME: check with 7.10 and file ticket:
-- a case analysis against 0x00 .. 0xff :: Word8 turns into a huge chain
-- of >= tests. It could use a jump table, or at least it could use a binary
-- division. Whereas for Int or Word it does the right thing.

{-# INLINE tryConsumeWord #-}
tryConsumeWord :: Word8 -> ByteString -> DecodedToken Word
tryConsumeWord hdr !bs = case fromIntegral hdr :: Word of
  -- Positive integers (type 0)
  0x00 -> DecodedToken 1 0
  0x01 -> DecodedToken 1 1
  0x02 -> DecodedToken 1 2
  0x03 -> DecodedToken 1 3
  0x04 -> DecodedToken 1 4
  0x05 -> DecodedToken 1 5
  0x06 -> DecodedToken 1 6
  0x07 -> DecodedToken 1 7
  0x08 -> DecodedToken 1 8
  0x09 -> DecodedToken 1 9
  0x0a -> DecodedToken 1 10
  0x0b -> DecodedToken 1 11
  0x0c -> DecodedToken 1 12
  0x0d -> DecodedToken 1 13
  0x0e -> DecodedToken 1 14
  0x0f -> DecodedToken 1 15
  0x10 -> DecodedToken 1 16
  0x11 -> DecodedToken 1 17
  0x12 -> DecodedToken 1 18
  0x13 -> DecodedToken 1 19
  0x14 -> DecodedToken 1 20
  0x15 -> DecodedToken 1 21
  0x16 -> DecodedToken 1 22
  0x17 -> DecodedToken 1 23
  0x18 -> DecodedToken 2 (eatTailWord8 bs)
  0x19 -> DecodedToken 3 (eatTailWord16 bs)
  0x1a -> DecodedToken 5 (eatTailWord32 bs)
  0x1b -> DecodedToken 9 (fromIntegral $ eatTailWord64 bs) -- TODO FIXME: overflow
  _    -> DecodeFailure


{-# INLINE tryConsumeNegWord #-}
tryConsumeNegWord :: Word8 -> ByteString -> DecodedToken Word
tryConsumeNegWord hdr !bs = case fromIntegral hdr :: Word of
  -- Positive integers (type 0)
  0x20 -> DecodedToken 1 0
  0x21 -> DecodedToken 1 1
  0x22 -> DecodedToken 1 2
  0x23 -> DecodedToken 1 3
  0x24 -> DecodedToken 1 4
  0x25 -> DecodedToken 1 5
  0x26 -> DecodedToken 1 6
  0x27 -> DecodedToken 1 7
  0x28 -> DecodedToken 1 8
  0x29 -> DecodedToken 1 9
  0x2a -> DecodedToken 1 10
  0x2b -> DecodedToken 1 11
  0x2c -> DecodedToken 1 12
  0x2d -> DecodedToken 1 13
  0x2e -> DecodedToken 1 14
  0x2f -> DecodedToken 1 15
  0x30 -> DecodedToken 1 16
  0x31 -> DecodedToken 1 17
  0x32 -> DecodedToken 1 18
  0x33 -> DecodedToken 1 19
  0x34 -> DecodedToken 1 20
  0x35 -> DecodedToken 1 21
  0x36 -> DecodedToken 1 22
  0x37 -> DecodedToken 1 23
  0x38 -> DecodedToken 2 (eatTailWord8 bs)
  0x39 -> DecodedToken 3 (eatTailWord16 bs)
  0x3a -> DecodedToken 5 (eatTailWord32 bs)
  0x3b -> DecodedToken 9 (fromIntegral $ eatTailWord64 bs) -- TODO FIXME: overflow
  _    -> DecodeFailure


{-# INLINE tryConsumeInt #-}
tryConsumeInt :: Word8 -> ByteString -> DecodedToken Int
tryConsumeInt hdr !bs = case fromIntegral hdr :: Word of
  -- Positive integers (type 0)
  0x00 -> DecodedToken 1 0
  0x01 -> DecodedToken 1 1
  0x02 -> DecodedToken 1 2
  0x03 -> DecodedToken 1 3
  0x04 -> DecodedToken 1 4
  0x05 -> DecodedToken 1 5
  0x06 -> DecodedToken 1 6
  0x07 -> DecodedToken 1 7
  0x08 -> DecodedToken 1 8
  0x09 -> DecodedToken 1 9
  0x0a -> DecodedToken 1 10
  0x0b -> DecodedToken 1 11
  0x0c -> DecodedToken 1 12
  0x0d -> DecodedToken 1 13
  0x0e -> DecodedToken 1 14
  0x0f -> DecodedToken 1 15
  0x10 -> DecodedToken 1 16
  0x11 -> DecodedToken 1 17
  0x12 -> DecodedToken 1 18
  0x13 -> DecodedToken 1 19
  0x14 -> DecodedToken 1 20
  0x15 -> DecodedToken 1 21
  0x16 -> DecodedToken 1 22
  0x17 -> DecodedToken 1 23
  0x18 -> DecodedToken 2 (fromIntegral (eatTailWord8 bs))
  0x19 -> DecodedToken 3 (fromIntegral (eatTailWord16 bs))
  0x1a -> DecodedToken 5 (fromIntegral (eatTailWord32 bs)) -- TODO FIXME: overflow
  0x1b -> DecodedToken 9 (fromIntegral (eatTailWord64 bs)) -- TODO FIXME: overflow

  -- Negative integers (type 1)
  0x20 -> DecodedToken 1 (-1)
  0x21 -> DecodedToken 1 (-2)
  0x22 -> DecodedToken 1 (-3)
  0x23 -> DecodedToken 1 (-4)
  0x24 -> DecodedToken 1 (-5)
  0x25 -> DecodedToken 1 (-6)
  0x26 -> DecodedToken 1 (-7)
  0x27 -> DecodedToken 1 (-8)
  0x28 -> DecodedToken 1 (-9)
  0x29 -> DecodedToken 1 (-10)
  0x2a -> DecodedToken 1 (-11)
  0x2b -> DecodedToken 1 (-12)
  0x2c -> DecodedToken 1 (-13)
  0x2d -> DecodedToken 1 (-14)
  0x2e -> DecodedToken 1 (-15)
  0x2f -> DecodedToken 1 (-16)
  0x30 -> DecodedToken 1 (-17)
  0x31 -> DecodedToken 1 (-18)
  0x32 -> DecodedToken 1 (-19)
  0x33 -> DecodedToken 1 (-20)
  0x34 -> DecodedToken 1 (-21)
  0x35 -> DecodedToken 1 (-22)
  0x36 -> DecodedToken 1 (-23)
  0x37 -> DecodedToken 1 (-24)
  0x38 -> DecodedToken 2 (-1 - fromIntegral (eatTailWord8 bs))
  0x39 -> DecodedToken 3 (-1 - fromIntegral (eatTailWord16 bs))
  0x3a -> DecodedToken 5 (-1 - fromIntegral (eatTailWord32 bs)) -- TODO FIXME: overflow
  0x3b -> DecodedToken 9 (-1 - fromIntegral (eatTailWord64 bs)) -- TODO FIXME: overflow
  _    -> DecodeFailure


{-# INLINE tryConsumeInteger #-}
tryConsumeInteger :: Word8 -> ByteString -> DecodedToken (BigIntToken Integer)
tryConsumeInteger hdr !bs = case fromIntegral hdr :: Word of

  -- Positive integers (type 0)
  0x00 -> DecodedToken 1 (BigIntToken True 0)
  0x01 -> DecodedToken 1 (BigIntToken True 1)
  0x02 -> DecodedToken 1 (BigIntToken True 2)
  0x03 -> DecodedToken 1 (BigIntToken True 3)
  0x04 -> DecodedToken 1 (BigIntToken True 4)
  0x05 -> DecodedToken 1 (BigIntToken True 5)
  0x06 -> DecodedToken 1 (BigIntToken True 6)
  0x07 -> DecodedToken 1 (BigIntToken True 7)
  0x08 -> DecodedToken 1 (BigIntToken True 8)
  0x09 -> DecodedToken 1 (BigIntToken True 9)
  0x0a -> DecodedToken 1 (BigIntToken True 10)
  0x0b -> DecodedToken 1 (BigIntToken True 11)
  0x0c -> DecodedToken 1 (BigIntToken True 12)
  0x0d -> DecodedToken 1 (BigIntToken True 13)
  0x0e -> DecodedToken 1 (BigIntToken True 14)
  0x0f -> DecodedToken 1 (BigIntToken True 15)
  0x10 -> DecodedToken 1 (BigIntToken True 16)
  0x11 -> DecodedToken 1 (BigIntToken True 17)
  0x12 -> DecodedToken 1 (BigIntToken True 18)
  0x13 -> DecodedToken 1 (BigIntToken True 19)
  0x14 -> DecodedToken 1 (BigIntToken True 20)
  0x15 -> DecodedToken 1 (BigIntToken True 21)
  0x16 -> DecodedToken 1 (BigIntToken True 22)
  0x17 -> DecodedToken 1 (BigIntToken True 23)

  0x18 -> let !w@(W# w#) = eatTailWord8 bs
              sz = 2
          in DecodedToken sz (BigIntToken (isWordCanonical sz w#)   (fromIntegral w))
  0x19 -> let !w@(W# w#) = eatTailWord16 bs
              sz = 3
          in DecodedToken sz (BigIntToken (isWordCanonical sz w#)   (fromIntegral w))
  0x1a -> let !w@(W# w#) = eatTailWord32 bs
              sz = 5
          in DecodedToken sz (BigIntToken (isWordCanonical sz w#)   (fromIntegral w))
  0x1b -> let !w@(W64# w#) = eatTailWord64 bs
              sz = 9
#if defined(ARCH_32bit)
          in DecodedToken sz (BigIntToken (isWord64Canonical sz w#) (fromIntegral w))
#else
          in DecodedToken sz (BigIntToken (isWordCanonical sz w#)   (fromIntegral w))
#endif

  -- Negative integers (type 1)
  0x20 -> DecodedToken 1 (BigIntToken True (-1))
  0x21 -> DecodedToken 1 (BigIntToken True (-2))
  0x22 -> DecodedToken 1 (BigIntToken True (-3))
  0x23 -> DecodedToken 1 (BigIntToken True (-4))
  0x24 -> DecodedToken 1 (BigIntToken True (-5))
  0x25 -> DecodedToken 1 (BigIntToken True (-6))
  0x26 -> DecodedToken 1 (BigIntToken True (-7))
  0x27 -> DecodedToken 1 (BigIntToken True (-8))
  0x28 -> DecodedToken 1 (BigIntToken True (-9))
  0x29 -> DecodedToken 1 (BigIntToken True (-10))
  0x2a -> DecodedToken 1 (BigIntToken True (-11))
  0x2b -> DecodedToken 1 (BigIntToken True (-12))
  0x2c -> DecodedToken 1 (BigIntToken True (-13))
  0x2d -> DecodedToken 1 (BigIntToken True (-14))
  0x2e -> DecodedToken 1 (BigIntToken True (-15))
  0x2f -> DecodedToken 1 (BigIntToken True (-16))
  0x30 -> DecodedToken 1 (BigIntToken True (-17))
  0x31 -> DecodedToken 1 (BigIntToken True (-18))
  0x32 -> DecodedToken 1 (BigIntToken True (-19))
  0x33 -> DecodedToken 1 (BigIntToken True (-20))
  0x34 -> DecodedToken 1 (BigIntToken True (-21))
  0x35 -> DecodedToken 1 (BigIntToken True (-22))
  0x36 -> DecodedToken 1 (BigIntToken True (-23))
  0x37 -> DecodedToken 1 (BigIntToken True (-24))
  0x38 -> let !w@(W# w#) = eatTailWord8 bs
              sz = 2
          in DecodedToken sz (BigIntToken (isWordCanonical sz w#)   (-1 - fromIntegral w))
  0x39 -> let !w@(W# w#) = eatTailWord16 bs
              sz = 3
          in DecodedToken sz (BigIntToken (isWordCanonical sz w#)   (-1 - fromIntegral w))
  0x3a -> let !w@(W# w#) = eatTailWord32 bs
              sz = 5
          in DecodedToken sz (BigIntToken (isWordCanonical sz w#)   (-1 - fromIntegral w))
  0x3b -> let !w@(W64# w#) = eatTailWord64 bs
              sz = 9
#if defined(ARCH_32bit)
          in DecodedToken sz (BigIntToken (isWord64Canonical sz w#) (-1 - fromIntegral w))
#else
          in DecodedToken sz (BigIntToken (isWordCanonical sz w#)   (-1 - fromIntegral w))
#endif

  0xc2 -> readBigUInt bs
  0xc3 -> readBigNInt bs

  _    -> DecodeFailure


{-# INLINE tryConsumeBytes #-}
tryConsumeBytes :: Word8 -> ByteString -> DecodedToken (LongToken ByteString)
tryConsumeBytes hdr !bs = case fromIntegral hdr :: Word of

  -- Bytes (type 2)
  0x40 -> readBytesSmall 0 bs
  0x41 -> readBytesSmall 1 bs
  0x42 -> readBytesSmall 2 bs
  0x43 -> readBytesSmall 3 bs
  0x44 -> readBytesSmall 4 bs
  0x45 -> readBytesSmall 5 bs
  0x46 -> readBytesSmall 6 bs
  0x47 -> readBytesSmall 7 bs
  0x48 -> readBytesSmall 8 bs
  0x49 -> readBytesSmall 9 bs
  0x4a -> readBytesSmall 10 bs
  0x4b -> readBytesSmall 11 bs
  0x4c -> readBytesSmall 12 bs
  0x4d -> readBytesSmall 13 bs
  0x4e -> readBytesSmall 14 bs
  0x4f -> readBytesSmall 15 bs
  0x50 -> readBytesSmall 16 bs
  0x51 -> readBytesSmall 17 bs
  0x52 -> readBytesSmall 18 bs
  0x53 -> readBytesSmall 19 bs
  0x54 -> readBytesSmall 20 bs
  0x55 -> readBytesSmall 21 bs
  0x56 -> readBytesSmall 22 bs
  0x57 -> readBytesSmall 23 bs
  0x58 -> readBytes8  bs
  0x59 -> readBytes16 bs
  0x5a -> readBytes32 bs
  0x5b -> readBytes64 bs
  _    -> DecodeFailure


{-# INLINE tryConsumeString #-}
tryConsumeString :: Word8 -> ByteString -> DecodedToken (LongToken T.Text)
tryConsumeString hdr !bs = case fromIntegral hdr :: Word of

  -- Strings (type 3)
  0x60 -> readStringSmall 0 bs
  0x61 -> readStringSmall 1 bs
  0x62 -> readStringSmall 2 bs
  0x63 -> readStringSmall 3 bs
  0x64 -> readStringSmall 4 bs
  0x65 -> readStringSmall 5 bs
  0x66 -> readStringSmall 6 bs
  0x67 -> readStringSmall 7 bs
  0x68 -> readStringSmall 8 bs
  0x69 -> readStringSmall 9 bs
  0x6a -> readStringSmall 10 bs
  0x6b -> readStringSmall 11 bs
  0x6c -> readStringSmall 12 bs
  0x6d -> readStringSmall 13 bs
  0x6e -> readStringSmall 14 bs
  0x6f -> readStringSmall 15 bs
  0x70 -> readStringSmall 16 bs
  0x71 -> readStringSmall 17 bs
  0x72 -> readStringSmall 18 bs
  0x73 -> readStringSmall 19 bs
  0x74 -> readStringSmall 20 bs
  0x75 -> readStringSmall 21 bs
  0x76 -> readStringSmall 22 bs
  0x77 -> readStringSmall 23 bs
  0x78 -> readString8  bs
  0x79 -> readString16 bs
  0x7a -> readString32 bs
  0x7b -> readString64 bs
  _    -> DecodeFailure


{-# INLINE tryConsumeListLen #-}
tryConsumeListLen :: Word8 -> ByteString -> DecodedToken Int
tryConsumeListLen hdr !bs = case fromIntegral hdr :: Word of
  -- List structures (type 4)
  0x80 -> DecodedToken 1 0
  0x81 -> DecodedToken 1 1
  0x82 -> DecodedToken 1 2
  0x83 -> DecodedToken 1 3
  0x84 -> DecodedToken 1 4
  0x85 -> DecodedToken 1 5
  0x86 -> DecodedToken 1 6
  0x87 -> DecodedToken 1 7
  0x88 -> DecodedToken 1 8
  0x89 -> DecodedToken 1 9
  0x8a -> DecodedToken 1 10
  0x8b -> DecodedToken 1 11
  0x8c -> DecodedToken 1 12
  0x8d -> DecodedToken 1 13
  0x8e -> DecodedToken 1 14
  0x8f -> DecodedToken 1 15
  0x90 -> DecodedToken 1 16
  0x91 -> DecodedToken 1 17
  0x92 -> DecodedToken 1 18
  0x93 -> DecodedToken 1 19
  0x94 -> DecodedToken 1 20
  0x95 -> DecodedToken 1 21
  0x96 -> DecodedToken 1 22
  0x97 -> DecodedToken 1 23
  0x98 -> DecodedToken 2 (fromIntegral (eatTailWord8 bs))
  0x99 -> DecodedToken 3 (fromIntegral (eatTailWord16 bs))
  0x9a -> DecodedToken 5 (fromIntegral (eatTailWord32 bs)) -- TODO FIXME: overflow
  0x9b -> DecodedToken 9 (fromIntegral (eatTailWord64 bs)) -- TODO FIXME: overflow
  _    -> DecodeFailure


{-# INLINE tryConsumeMapLen #-}
tryConsumeMapLen :: Word8 -> ByteString -> DecodedToken Int
tryConsumeMapLen hdr !bs = case fromIntegral hdr :: Word of
  -- Map structures (type 5)
  0xa0 -> DecodedToken 1 0
  0xa1 -> DecodedToken 1 1
  0xa2 -> DecodedToken 1 2
  0xa3 -> DecodedToken 1 3
  0xa4 -> DecodedToken 1 4
  0xa5 -> DecodedToken 1 5
  0xa6 -> DecodedToken 1 6
  0xa7 -> DecodedToken 1 7
  0xa8 -> DecodedToken 1 8
  0xa9 -> DecodedToken 1 9
  0xaa -> DecodedToken 1 10
  0xab -> DecodedToken 1 11
  0xac -> DecodedToken 1 12
  0xad -> DecodedToken 1 13
  0xae -> DecodedToken 1 14
  0xaf -> DecodedToken 1 15
  0xb0 -> DecodedToken 1 16
  0xb1 -> DecodedToken 1 17
  0xb2 -> DecodedToken 1 18
  0xb3 -> DecodedToken 1 19
  0xb4 -> DecodedToken 1 20
  0xb5 -> DecodedToken 1 21
  0xb6 -> DecodedToken 1 22
  0xb7 -> DecodedToken 1 23
  0xb8 -> DecodedToken 2 (fromIntegral (eatTailWord8 bs))
  0xb9 -> DecodedToken 3 (fromIntegral (eatTailWord16 bs))
  0xba -> DecodedToken 5 (fromIntegral (eatTailWord32 bs)) -- TODO FIXME: overflow
  0xbb -> DecodedToken 9 (fromIntegral (eatTailWord64 bs)) -- TODO FIXME: overflow
  _    -> DecodeFailure


{-# INLINE tryConsumeListLenIndef #-}
tryConsumeListLenIndef :: Word8 -> DecodedToken ()
tryConsumeListLenIndef hdr = case fromIntegral hdr :: Word of
  0x9f -> DecodedToken 1 ()
  _    -> DecodeFailure


{-# INLINE tryConsumeMapLenIndef #-}
tryConsumeMapLenIndef :: Word8 -> DecodedToken ()
tryConsumeMapLenIndef hdr = case fromIntegral hdr :: Word of
  0xbf -> DecodedToken 1 ()
  _    -> DecodeFailure


{-# INLINE tryConsumeListLenOrIndef #-}
tryConsumeListLenOrIndef :: Word8 -> ByteString -> DecodedToken Int
tryConsumeListLenOrIndef hdr !bs = case fromIntegral hdr :: Word of

  -- List structures (type 4)
  0x80 -> DecodedToken 1 0
  0x81 -> DecodedToken 1 1
  0x82 -> DecodedToken 1 2
  0x83 -> DecodedToken 1 3
  0x84 -> DecodedToken 1 4
  0x85 -> DecodedToken 1 5
  0x86 -> DecodedToken 1 6
  0x87 -> DecodedToken 1 7
  0x88 -> DecodedToken 1 8
  0x89 -> DecodedToken 1 9
  0x8a -> DecodedToken 1 10
  0x8b -> DecodedToken 1 11
  0x8c -> DecodedToken 1 12
  0x8d -> DecodedToken 1 13
  0x8e -> DecodedToken 1 14
  0x8f -> DecodedToken 1 15
  0x90 -> DecodedToken 1 16
  0x91 -> DecodedToken 1 17
  0x92 -> DecodedToken 1 18
  0x93 -> DecodedToken 1 19
  0x94 -> DecodedToken 1 20
  0x95 -> DecodedToken 1 21
  0x96 -> DecodedToken 1 22
  0x97 -> DecodedToken 1 23
  0x98 -> DecodedToken 2 (fromIntegral (eatTailWord8 bs))
  0x99 -> DecodedToken 3 (fromIntegral (eatTailWord16 bs))
  0x9a -> DecodedToken 5 (fromIntegral (eatTailWord32 bs)) -- TODO FIXME: overflow
  0x9b -> DecodedToken 9 (fromIntegral (eatTailWord64 bs)) -- TODO FIXME: overflow
  0x9f -> DecodedToken 1 (-1) -- indefinite length
  _    -> DecodeFailure


{-# INLINE tryConsumeMapLenOrIndef #-}
tryConsumeMapLenOrIndef :: Word8 -> ByteString -> DecodedToken Int
tryConsumeMapLenOrIndef hdr !bs = case fromIntegral hdr :: Word of

  -- Map structures (type 5)
  0xa0 -> DecodedToken 1 0
  0xa1 -> DecodedToken 1 1
  0xa2 -> DecodedToken 1 2
  0xa3 -> DecodedToken 1 3
  0xa4 -> DecodedToken 1 4
  0xa5 -> DecodedToken 1 5
  0xa6 -> DecodedToken 1 6
  0xa7 -> DecodedToken 1 7
  0xa8 -> DecodedToken 1 8
  0xa9 -> DecodedToken 1 9
  0xaa -> DecodedToken 1 10
  0xab -> DecodedToken 1 11
  0xac -> DecodedToken 1 12
  0xad -> DecodedToken 1 13
  0xae -> DecodedToken 1 14
  0xaf -> DecodedToken 1 15
  0xb0 -> DecodedToken 1 16
  0xb1 -> DecodedToken 1 17
  0xb2 -> DecodedToken 1 18
  0xb3 -> DecodedToken 1 19
  0xb4 -> DecodedToken 1 20
  0xb5 -> DecodedToken 1 21
  0xb6 -> DecodedToken 1 22
  0xb7 -> DecodedToken 1 23
  0xb8 -> DecodedToken 2 (fromIntegral (eatTailWord8 bs))
  0xb9 -> DecodedToken 3 (fromIntegral (eatTailWord16 bs))
  0xba -> DecodedToken 5 (fromIntegral (eatTailWord32 bs)) -- TODO FIXME: overflow
  0xbb -> DecodedToken 9 (fromIntegral (eatTailWord64 bs)) -- TODO FIXME: overflow
  0xbf -> DecodedToken 1 (-1) -- indefinite length
  _    -> DecodeFailure


{-# INLINE tryConsumeTag #-}
tryConsumeTag :: Word8 -> ByteString -> DecodedToken Word
tryConsumeTag hdr !bs = case fromIntegral hdr :: Word of

  -- Tagged values (type 6)
  0xc0 -> DecodedToken 1 0
  0xc1 -> DecodedToken 1 1
  0xc2 -> DecodedToken 1 2
  0xc3 -> DecodedToken 1 3
  0xc4 -> DecodedToken 1 4
  0xc5 -> DecodedToken 1 5
  0xc6 -> DecodedToken 1 6
  0xc7 -> DecodedToken 1 7
  0xc8 -> DecodedToken 1 8
  0xc9 -> DecodedToken 1 9
  0xca -> DecodedToken 1 10
  0xcb -> DecodedToken 1 11
  0xcc -> DecodedToken 1 12
  0xcd -> DecodedToken 1 13
  0xce -> DecodedToken 1 14
  0xcf -> DecodedToken 1 15
  0xd0 -> DecodedToken 1 16
  0xd1 -> DecodedToken 1 17
  0xd2 -> DecodedToken 1 18
  0xd3 -> DecodedToken 1 19
  0xd4 -> DecodedToken 1 20
  0xd5 -> DecodedToken 1 21
  0xd6 -> DecodedToken 1 22
  0xd7 -> DecodedToken 1 23
  0xd8 -> DecodedToken 2 (eatTailWord8 bs)
  0xd9 -> DecodedToken 3 (eatTailWord16 bs)
  0xda -> DecodedToken 5 (eatTailWord32 bs)
  0xdb -> DecodedToken 9 (fromIntegral (eatTailWord64 bs)) -- TODO FIXME: overflow
  _    -> DecodeFailure

--
-- 64-on-32 bit code paths
--

#if defined(ARCH_32bit)
tryConsumeWord64 :: Word8 -> ByteString -> DecodedToken Word64
tryConsumeWord64 hdr !bs = case fromIntegral hdr :: Word of
  -- Positive integers (type 0)
  0x00 -> DecodedToken 1 0
  0x01 -> DecodedToken 1 1
  0x02 -> DecodedToken 1 2
  0x03 -> DecodedToken 1 3
  0x04 -> DecodedToken 1 4
  0x05 -> DecodedToken 1 5
  0x06 -> DecodedToken 1 6
  0x07 -> DecodedToken 1 7
  0x08 -> DecodedToken 1 8
  0x09 -> DecodedToken 1 9
  0x0a -> DecodedToken 1 10
  0x0b -> DecodedToken 1 11
  0x0c -> DecodedToken 1 12
  0x0d -> DecodedToken 1 13
  0x0e -> DecodedToken 1 14
  0x0f -> DecodedToken 1 15
  0x10 -> DecodedToken 1 16
  0x11 -> DecodedToken 1 17
  0x12 -> DecodedToken 1 18
  0x13 -> DecodedToken 1 19
  0x14 -> DecodedToken 1 20
  0x15 -> DecodedToken 1 21
  0x16 -> DecodedToken 1 22
  0x17 -> DecodedToken 1 23
  0x18 -> DecodedToken 2 (fromIntegral (eatTailWord8 bs))
  0x19 -> DecodedToken 3 (fromIntegral (eatTailWord16 bs))
  0x1a -> DecodedToken 5 (fromIntegral (eatTailWord32 bs))
  0x1b -> DecodedToken 9 (fromIntegral (eatTailWord64 bs)) -- TODO FIXME: overflow
  _    -> DecodeFailure
{-# INLINE tryConsumeWord64 #-}

tryConsumeNegWord64 :: Word8 -> ByteString -> DecodedToken Word64
tryConsumeNegWord64 hdr !bs = case fromIntegral hdr :: Word of
  -- Positive integers (type 0)
  0x20 -> DecodedToken 1 0
  0x21 -> DecodedToken 1 1
  0x22 -> DecodedToken 1 2
  0x23 -> DecodedToken 1 3
  0x24 -> DecodedToken 1 4
  0x25 -> DecodedToken 1 5
  0x26 -> DecodedToken 1 6
  0x27 -> DecodedToken 1 7
  0x28 -> DecodedToken 1 8
  0x29 -> DecodedToken 1 9
  0x2a -> DecodedToken 1 10
  0x2b -> DecodedToken 1 11
  0x2c -> DecodedToken 1 12
  0x2d -> DecodedToken 1 13
  0x2e -> DecodedToken 1 14
  0x2f -> DecodedToken 1 15
  0x30 -> DecodedToken 1 16
  0x31 -> DecodedToken 1 17
  0x32 -> DecodedToken 1 18
  0x33 -> DecodedToken 1 19
  0x34 -> DecodedToken 1 20
  0x35 -> DecodedToken 1 21
  0x36 -> DecodedToken 1 22
  0x37 -> DecodedToken 1 23
  0x38 -> DecodedToken 2 (fromIntegral (eatTailWord8 bs))
  0x39 -> DecodedToken 3 (fromIntegral (eatTailWord16 bs))
  0x3a -> DecodedToken 5 (fromIntegral (eatTailWord32 bs))
  0x3b -> DecodedToken 9 (fromIntegral (eatTailWord64 bs)) -- TODO FIXME: overflow
  _    -> DecodeFailure
{-# INLINE tryConsumeNegWord64 #-}

tryConsumeInt64 :: Word8 -> ByteString -> DecodedToken Int64
tryConsumeInt64 hdr !bs = case fromIntegral hdr :: Word of
  -- Positive integers (type 0)
  0x00 -> DecodedToken 1 0
  0x01 -> DecodedToken 1 1
  0x02 -> DecodedToken 1 2
  0x03 -> DecodedToken 1 3
  0x04 -> DecodedToken 1 4
  0x05 -> DecodedToken 1 5
  0x06 -> DecodedToken 1 6
  0x07 -> DecodedToken 1 7
  0x08 -> DecodedToken 1 8
  0x09 -> DecodedToken 1 9
  0x0a -> DecodedToken 1 10
  0x0b -> DecodedToken 1 11
  0x0c -> DecodedToken 1 12
  0x0d -> DecodedToken 1 13
  0x0e -> DecodedToken 1 14
  0x0f -> DecodedToken 1 15
  0x10 -> DecodedToken 1 16
  0x11 -> DecodedToken 1 17
  0x12 -> DecodedToken 1 18
  0x13 -> DecodedToken 1 19
  0x14 -> DecodedToken 1 20
  0x15 -> DecodedToken 1 21
  0x16 -> DecodedToken 1 22
  0x17 -> DecodedToken 1 23
  0x18 -> DecodedToken 2 (fromIntegral (eatTailWord8 bs))
  0x19 -> DecodedToken 3 (fromIntegral (eatTailWord16 bs))
  0x1a -> DecodedToken 5 (fromIntegral (eatTailWord32 bs)) -- TODO FIXME: overflow
  0x1b -> DecodedToken 9 (fromIntegral (eatTailWord64 bs)) -- TODO FIXME: overflow

  -- Negative integers (type 1)
  0x20 -> DecodedToken 1 (-1)
  0x21 -> DecodedToken 1 (-2)
  0x22 -> DecodedToken 1 (-3)
  0x23 -> DecodedToken 1 (-4)
  0x24 -> DecodedToken 1 (-5)
  0x25 -> DecodedToken 1 (-6)
  0x26 -> DecodedToken 1 (-7)
  0x27 -> DecodedToken 1 (-8)
  0x28 -> DecodedToken 1 (-9)
  0x29 -> DecodedToken 1 (-10)
  0x2a -> DecodedToken 1 (-11)
  0x2b -> DecodedToken 1 (-12)
  0x2c -> DecodedToken 1 (-13)
  0x2d -> DecodedToken 1 (-14)
  0x2e -> DecodedToken 1 (-15)
  0x2f -> DecodedToken 1 (-16)
  0x30 -> DecodedToken 1 (-17)
  0x31 -> DecodedToken 1 (-18)
  0x32 -> DecodedToken 1 (-19)
  0x33 -> DecodedToken 1 (-20)
  0x34 -> DecodedToken 1 (-21)
  0x35 -> DecodedToken 1 (-22)
  0x36 -> DecodedToken 1 (-23)
  0x37 -> DecodedToken 1 (-24)
  0x38 -> DecodedToken 2 (-1 - fromIntegral (eatTailWord8 bs))
  0x39 -> DecodedToken 3 (-1 - fromIntegral (eatTailWord16 bs))
  0x3a -> DecodedToken 5 (-1 - fromIntegral (eatTailWord32 bs)) -- TODO FIXME: overflow
  0x3b -> DecodedToken 9 (-1 - fromIntegral (eatTailWord64 bs)) -- TODO FIXME: overflow
  _    -> DecodeFailure
{-# INLINE tryConsumeInt64 #-}

tryConsumeListLen64 :: Word8 -> ByteString -> DecodedToken Int64
tryConsumeListLen64 hdr !bs = case fromIntegral hdr :: Word of
  -- List structures (type 4)
  0x80 -> DecodedToken 1 0
  0x81 -> DecodedToken 1 1
  0x82 -> DecodedToken 1 2
  0x83 -> DecodedToken 1 3
  0x84 -> DecodedToken 1 4
  0x85 -> DecodedToken 1 5
  0x86 -> DecodedToken 1 6
  0x87 -> DecodedToken 1 7
  0x88 -> DecodedToken 1 8
  0x89 -> DecodedToken 1 9
  0x8a -> DecodedToken 1 10
  0x8b -> DecodedToken 1 11
  0x8c -> DecodedToken 1 12
  0x8d -> DecodedToken 1 13
  0x8e -> DecodedToken 1 14
  0x8f -> DecodedToken 1 15
  0x90 -> DecodedToken 1 16
  0x91 -> DecodedToken 1 17
  0x92 -> DecodedToken 1 18
  0x93 -> DecodedToken 1 19
  0x94 -> DecodedToken 1 20
  0x95 -> DecodedToken 1 21
  0x96 -> DecodedToken 1 22
  0x97 -> DecodedToken 1 23
  0x98 -> DecodedToken 2 (fromIntegral (eatTailWord8 bs))
  0x99 -> DecodedToken 3 (fromIntegral (eatTailWord16 bs))
  0x9a -> DecodedToken 5 (fromIntegral (eatTailWord32 bs)) -- TODO FIXME: overflow
  0x9b -> DecodedToken 9 (fromIntegral (eatTailWord64 bs)) -- TODO FIXME: overflow
  _    -> DecodeFailure
{-# INLINE tryConsumeListLen64 #-}

tryConsumeMapLen64 :: Word8 -> ByteString -> DecodedToken Int64
tryConsumeMapLen64 hdr !bs = case fromIntegral hdr :: Word of
  -- Map structures (type 5)
  0xa0 -> DecodedToken 1 0
  0xa1 -> DecodedToken 1 1
  0xa2 -> DecodedToken 1 2
  0xa3 -> DecodedToken 1 3
  0xa4 -> DecodedToken 1 4
  0xa5 -> DecodedToken 1 5
  0xa6 -> DecodedToken 1 6
  0xa7 -> DecodedToken 1 7
  0xa8 -> DecodedToken 1 8
  0xa9 -> DecodedToken 1 9
  0xaa -> DecodedToken 1 10
  0xab -> DecodedToken 1 11
  0xac -> DecodedToken 1 12
  0xad -> DecodedToken 1 13
  0xae -> DecodedToken 1 14
  0xaf -> DecodedToken 1 15
  0xb0 -> DecodedToken 1 16
  0xb1 -> DecodedToken 1 17
  0xb2 -> DecodedToken 1 18
  0xb3 -> DecodedToken 1 19
  0xb4 -> DecodedToken 1 20
  0xb5 -> DecodedToken 1 21
  0xb6 -> DecodedToken 1 22
  0xb7 -> DecodedToken 1 23
  0xb8 -> DecodedToken 2 (fromIntegral (eatTailWord8 bs))
  0xb9 -> DecodedToken 3 (fromIntegral (eatTailWord16 bs))
  0xba -> DecodedToken 5 (fromIntegral (eatTailWord32 bs)) -- TODO FIXME: overflow
  0xbb -> DecodedToken 9 (fromIntegral (eatTailWord64 bs)) -- TODO FIXME: overflow
  _    -> DecodeFailure
{-# INLINE tryConsumeMapLen64 #-}

tryConsumeTag64 :: Word8 -> ByteString -> DecodedToken Word64
tryConsumeTag64 hdr !bs = case fromIntegral hdr :: Word of
  -- Tagged values (type 6)
  0xc0 -> DecodedToken 1 0
  0xc1 -> DecodedToken 1 1
  0xc2 -> DecodedToken 1 2
  0xc3 -> DecodedToken 1 3
  0xc4 -> DecodedToken 1 4
  0xc5 -> DecodedToken 1 5
  0xc6 -> DecodedToken 1 6
  0xc7 -> DecodedToken 1 7
  0xc8 -> DecodedToken 1 8
  0xc9 -> DecodedToken 1 9
  0xca -> DecodedToken 1 10
  0xcb -> DecodedToken 1 11
  0xcc -> DecodedToken 1 12
  0xcd -> DecodedToken 1 13
  0xce -> DecodedToken 1 14
  0xcf -> DecodedToken 1 15
  0xd0 -> DecodedToken 1 16
  0xd1 -> DecodedToken 1 17
  0xd2 -> DecodedToken 1 18
  0xd3 -> DecodedToken 1 19
  0xd4 -> DecodedToken 1 20
  0xd5 -> DecodedToken 1 21
  0xd6 -> DecodedToken 1 22
  0xd7 -> DecodedToken 1 23
  0xd8 -> DecodedToken 2 (fromIntegral (eatTailWord8 bs))
  0xd9 -> DecodedToken 3 (fromIntegral (eatTailWord16 bs))
  0xda -> DecodedToken 5 (fromIntegral (eatTailWord32 bs))
  0xdb -> DecodedToken 9 (fromIntegral (eatTailWord64 bs)) -- TODO FIXME: overflow
  _    -> DecodeFailure
{-# INLINE tryConsumeTag64 #-}
#endif

{-# INLINE tryConsumeFloat #-}
tryConsumeFloat :: Word8 -> ByteString -> DecodedToken Float
tryConsumeFloat hdr !bs = case fromIntegral hdr :: Word of
  0xf9 -> DecodedToken 3 (wordToFloat16 (eatTailWord16 bs))
  0xfa -> DecodedToken 5 (wordToFloat32 (eatTailWord32 bs))
  _    -> DecodeFailure


{-# INLINE tryConsumeDouble #-}
tryConsumeDouble :: Word8 -> ByteString -> DecodedToken Double
tryConsumeDouble hdr !bs = case fromIntegral hdr :: Word of
  0xf9 -> DecodedToken 3 (float2Double $ wordToFloat16 (eatTailWord16 bs))
  0xfa -> DecodedToken 5 (float2Double $ wordToFloat32 (eatTailWord32 bs))
  0xfb -> DecodedToken 9                (wordToFloat64 (eatTailWord64 bs))
  _    -> DecodeFailure


{-# INLINE tryConsumeBool #-}
tryConsumeBool :: Word8 -> DecodedToken Bool
tryConsumeBool hdr = case fromIntegral hdr :: Word of
  0xf4 -> DecodedToken 1 False
  0xf5 -> DecodedToken 1 True
  _    -> DecodeFailure


{-# INLINE tryConsumeSimple #-}
tryConsumeSimple :: Word8 -> ByteString -> DecodedToken Word
tryConsumeSimple hdr !bs = case fromIntegral hdr :: Word of

  -- Simple and floats (type 7)
  0xe0 -> DecodedToken 1 0
  0xe1 -> DecodedToken 1 1
  0xe2 -> DecodedToken 1 2
  0xe3 -> DecodedToken 1 3
  0xe4 -> DecodedToken 1 4
  0xe5 -> DecodedToken 1 5
  0xe6 -> DecodedToken 1 6
  0xe7 -> DecodedToken 1 7
  0xe8 -> DecodedToken 1 8
  0xe9 -> DecodedToken 1 9
  0xea -> DecodedToken 1 10
  0xeb -> DecodedToken 1 11
  0xec -> DecodedToken 1 12
  0xed -> DecodedToken 1 13
  0xee -> DecodedToken 1 14
  0xef -> DecodedToken 1 15
  0xf0 -> DecodedToken 1 16
  0xf1 -> DecodedToken 1 17
  0xf2 -> DecodedToken 1 18
  0xf3 -> DecodedToken 1 19
  0xf4 -> DecodedToken 1 20
  0xf5 -> DecodedToken 1 21
  0xf6 -> DecodedToken 1 22
  0xf7 -> DecodedToken 1 23
  0xf8 -> DecodedToken 2 (eatTailWord8 bs)
  _    -> DecodeFailure


{-# INLINE tryConsumeBytesIndef #-}
tryConsumeBytesIndef :: Word8 -> DecodedToken ()
tryConsumeBytesIndef hdr = case fromIntegral hdr :: Word of
  0x5f -> DecodedToken 1 ()
  _    -> DecodeFailure


{-# INLINE tryConsumeStringIndef #-}
tryConsumeStringIndef :: Word8 -> DecodedToken ()
tryConsumeStringIndef hdr = case fromIntegral hdr :: Word of
  0x7f -> DecodedToken 1 ()
  _    -> DecodeFailure


{-# INLINE tryConsumeNull #-}
tryConsumeNull :: Word8 -> DecodedToken ()
tryConsumeNull hdr = case fromIntegral hdr :: Word of
  0xf6 -> DecodedToken 1 ()
  _    -> DecodeFailure


{-# INLINE tryConsumeBreakOr #-}
tryConsumeBreakOr :: Word8 -> DecodedToken ()
tryConsumeBreakOr hdr = case fromIntegral hdr :: Word of
  0xff -> DecodedToken 1 ()
  _    -> DecodeFailure


readBytesSmall :: Int -> ByteString -> DecodedToken (LongToken ByteString)
readBytesSmall n bs
  -- if n <= bound then ok return it all
  | n + hdrsz <= BS.length bs
  = DecodedToken (n+hdrsz) $ Fits $
      BS.unsafeTake n (BS.unsafeDrop hdrsz bs)

  -- if n > bound then slow path, multi-chunk
  | otherwise
  = DecodedToken hdrsz $ TooLong n
  where
    hdrsz = 1

readBytes8, readBytes16, readBytes32, readBytes64
  :: ByteString -> DecodedToken (LongToken ByteString)

readBytes8 bs
  | n <= BS.length bs - hdrsz
  = DecodedToken (n+hdrsz) $ Fits $
      BS.unsafeTake n (BS.unsafeDrop hdrsz bs)

  -- if n > bound then slow path, multi-chunk
  | otherwise
  = DecodedToken hdrsz $ TooLong n
  where
    hdrsz = 2
    n = fromIntegral (eatTailWord8 bs)

readBytes16 bs
  | n <= BS.length bs - hdrsz
  = DecodedToken (n+hdrsz) $ Fits $
      BS.unsafeTake n (BS.unsafeDrop hdrsz bs)

  -- if n > bound then slow path, multi-chunk
  | otherwise
  = DecodedToken hdrsz $ TooLong n
  where
    hdrsz = 3
    n = fromIntegral (eatTailWord16 bs)

readBytes32 bs
  | n <= BS.length bs - hdrsz
  = DecodedToken (n+hdrsz) $ Fits $
      BS.unsafeTake n (BS.unsafeDrop hdrsz bs)

  -- if n > bound then slow path, multi-chunk
  | otherwise
  = DecodedToken hdrsz $ TooLong n
  where
    hdrsz = 5
    -- TODO FIXME: int overflow
    n = fromIntegral (eatTailWord32 bs)

readBytes64 bs
  | n <= BS.length bs - hdrsz
  = DecodedToken (n+hdrsz) $ Fits $
      BS.unsafeTake n (BS.unsafeDrop hdrsz bs)

  -- if n > bound then slow path, multi-chunk
  | otherwise
  = DecodedToken hdrsz $ TooLong n
  where
    hdrsz = 5
    -- TODO FIXME: int overflow
    n = fromIntegral (eatTailWord64 bs)


readStringSmall :: Int -> ByteString -> DecodedToken (LongToken T.Text)
readStringSmall n bs
  -- if n <= bound then ok return it all
  | n + hdrsz <= BS.length bs
  = DecodedToken (n+hdrsz) $ Fits $
      T.decodeUtf8 (BS.unsafeTake n (BS.unsafeDrop hdrsz bs))
      -- TODO FIXME: utf8 validation

  -- if n > bound then slow path, multi-chunk
  | otherwise
  = DecodedToken hdrsz $ TooLong n
  where
    hdrsz = 1

readString8, readString16,
 readString32, readString64 :: ByteString -> DecodedToken (LongToken T.Text)
readString8 bs
  | n <= BS.length bs - hdrsz
  = DecodedToken (n+hdrsz) $ Fits $
      T.decodeUtf8 (BS.unsafeTake n (BS.unsafeDrop hdrsz bs))
      -- TODO FIXME: utf8 validation

  -- if n > bound then slow path, multi-chunk
  | otherwise
  = DecodedToken hdrsz $ TooLong n
  where
    hdrsz = 2
    n = fromIntegral (eatTailWord8 bs)

readString16 bs
  | n <= BS.length bs - hdrsz
  = DecodedToken (n+hdrsz) $ Fits $
      T.decodeUtf8 (BS.unsafeTake n (BS.unsafeDrop hdrsz bs))
      -- TODO FIXME: utf8 validation

  -- if n > bound then slow path, multi-chunk
  | otherwise
  = DecodedToken hdrsz $ TooLong n
  where
    hdrsz = 3
    n = fromIntegral (eatTailWord16 bs)

readString32 bs
  | n <= BS.length bs - hdrsz
  = DecodedToken (n+hdrsz) $ Fits $
      T.decodeUtf8 (BS.unsafeTake n (BS.unsafeDrop hdrsz bs))
      -- TODO FIXME: utf8 validation

  -- if n > bound then slow path, multi-chunk
  | otherwise
  = DecodedToken hdrsz $ TooLong n
  where
    hdrsz = 5
    -- TODO FIXME: int overflow
    n = fromIntegral (eatTailWord32 bs)

readString64 bs
  | n <= BS.length bs - hdrsz
  = DecodedToken (n+hdrsz) $ Fits $
      T.decodeUtf8 (BS.unsafeTake n (BS.unsafeDrop hdrsz bs))
      -- TODO FIXME: utf8 validation

  -- if n > bound then slow path, multi-chunk
  | otherwise
  = DecodedToken hdrsz $ TooLong n
  where
    hdrsz = 5
    -- TODO FIXME: int overflow
    n = fromIntegral (eatTailWord64 bs)


------------------------------------------------------------------------------
-- Reading big integers
--

-- Big ints consist of two CBOR tokens: a tag token (2 for positive, 3 for
-- negative) followed by a bytes token. Our usual invariant (for go_fast and
-- go_fast_end) only guarantees that we've got enough space to decode the
-- first token. So given that there's two tokens and the second is variable
-- length then there are several points where we can discover we're out of
-- input buffer space.
--
-- In those cases we need to break out of the fast path but we must arrange
-- things so that we can continue later once we've got more input buffer.
--
-- In particular, we might run out of space when:
--   1. trying to decode the header of the second token (bytes); or
--   2. trying to read the bytes body
--
--- The existing mechanisms we've got to drop out of the fast path are:
--   * SlowDecodeAction to re-read a whole token
--   * SlowConsumeTokenBytes to read the body of a bytes token
--
-- Of course when we resume we need to convert the bytes into an integer.
-- Rather than making new fast path return mechanisms we can reuse the
-- existing ones, so long as we're prepared to allocate new continuation
-- closures. This seems a reasonable price to pay to reduce complexity since
-- decoding a big int across an input buffer boundary ought to be rare, and
-- allocating a new continuation closure isn't that expensive.

data BigIntToken a = BigIntToken Bool {- canonical? -} Integer
                   | BigUIntNeedBody Int
                   | BigNIntNeedBody Int
                   | BigUIntNeedHeader
                   | BigNIntNeedHeader

-- So when we have to break out because we can't read the whole bytes body
-- in one go then we need to use SlowConsumeTokenBytes but we can adjust the
-- continuation so that when we get the ByteString back we convert it to an
-- Integer before calling the original continuation.

adjustContBigUIntNeedBody, adjustContBigNIntNeedBody
  :: (Integer -> ST s (DecodeAction s a))
  -> (ByteString -> ST s (DecodeAction s a))

adjustContBigUIntNeedBody k = \bs -> k $! uintegerFromBytes bs
adjustContBigNIntNeedBody k = \bs -> k $! nintegerFromBytes bs

-- And when we have to break out because we can't read the bytes token header
-- in one go then we need to use SlowDecodeAction but we have to make two
-- adjustments. When we resume we need to read a bytes token, not a big int.
-- That is we don't want to re-read the tag token. Indeed we cannot even if we
-- wanted to because the slow path code only guarantees to arrange for one
-- complete token header in the input buffer. So we must pretend that we did
-- in fact want to read a bytes token using ConsumeBytes, and then we can
-- adjust the continuation for that in the same way as above.

adjustContBigUIntNeedHeader, adjustContBigNIntNeedHeader
  :: (Integer -> ST s (DecodeAction s a))
  -> DecodeAction s a

adjustContBigUIntNeedHeader k = ConsumeBytes (\bs -> k $! uintegerFromBytes bs)
adjustContBigNIntNeedHeader k = ConsumeBytes (\bs -> k $! nintegerFromBytes bs)

-- So finally when reading the input buffer we check if we have enough space
-- to read the header of the bytes token and then try to read the bytes body,
-- using the appropriate break-out codes as above.

{-# INLINE readBigUInt #-}
readBigUInt :: ByteString -> DecodedToken (BigIntToken a)
readBigUInt bs
    | let bs' = BS.unsafeTail bs
    , not (BS.null bs')
    , let !hdr = BS.unsafeHead bs'
    , BS.length bs' >= tokenSize hdr
    = case tryConsumeBytes hdr bs' of
        DecodeFailure                 -> DecodeFailure
        DecodedToken sz (Fits bstr)   -> DecodedToken (1+sz)
          (BigIntToken (isBigIntRepCanonical bstr) (uintegerFromBytes bstr))
        DecodedToken sz (TooLong len) -> DecodedToken (1+sz) (BigUIntNeedBody len)

    | otherwise
    = DecodedToken 1 BigUIntNeedHeader

{-# INLINE readBigNInt #-}
readBigNInt :: ByteString -> DecodedToken (BigIntToken a)
readBigNInt bs
    | let bs' = BS.unsafeTail bs
    , not (BS.null bs')
    , let !hdr = BS.unsafeHead bs'
    , BS.length bs' >= tokenSize hdr
    = case tryConsumeBytes hdr bs' of
        DecodeFailure                 -> DecodeFailure
        DecodedToken sz (Fits bstr)   -> DecodedToken (1+sz)
          (BigIntToken (isBigIntRepCanonical bstr) (nintegerFromBytes bstr))
        DecodedToken sz (TooLong len) -> DecodedToken (1+sz) (BigNIntNeedBody len)

    | otherwise
    = DecodedToken 1 BigNIntNeedHeader

-- Binary representation of a big integer is canonical if it's at least 9 bytes
-- long (as for smaller values the canonical representation is the same one as
-- for Int) and the leading byte is not zero (meaning that it's the smallest
-- representation for the number in question).
isBigIntRepCanonical :: ByteString -> Bool
isBigIntRepCanonical bstr = BS.length bstr > 8 && BS.unsafeHead bstr /= 0x00

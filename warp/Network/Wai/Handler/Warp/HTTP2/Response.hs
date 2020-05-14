{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Network.Wai.Handler.Warp.HTTP2.Response (
    fromResponse
  ) where

import qualified Control.Exception as E
import qualified Data.ByteString.Builder as BB
import qualified Network.HTTP.Types as H
import qualified Network.HTTP2.Server as H2
import Network.Wai hiding (responseFile, responseBuilder, responseStream)
import Network.Wai.Internal (Response(..))

import Network.Wai.Handler.Warp.File
import Network.Wai.Handler.Warp.HTTP2.Request (getHTTP2Data)
import Network.Wai.Handler.Warp.HTTP2.Types
import Network.Wai.Handler.Warp.Header
import qualified Network.Wai.Handler.Warp.Response as R
import qualified Network.Wai.Handler.Warp.Settings as S
import Network.Wai.Handler.Warp.Types

----------------------------------------------------------------

fromResponse :: S.Settings -> InternalInfo -> Request -> Response -> IO (H2.Response, H.Status)
fromResponse settings ii req rsp = do
    date <- getDate ii
    rspst@(h2rsp,st) <- case rsp of
      ResponseFile    st rsphdr path mpart -> do
          let rsphdr' = add date svr rsphdr
          responseFile    st rsphdr' isHead path mpart ii reqhdr
      ResponseBuilder st rsphdr builder -> do
          let rsphdr' = add date svr rsphdr
          return $ responseBuilder st rsphdr' isHead builder
      ResponseStream  st rsphdr strmbdy -> do
          let rsphdr' = add date svr rsphdr
          return $ responseStream  st rsphdr' isHead strmbdy
      _ -> error "ResponseRaw is not supported in HTTP/2"
    mh2data <- getHTTP2Data req
    case mh2data of
      Nothing     -> return rspst
      Just h2data -> do
          let !trailers = http2dataTrailers h2data
              !h2rsp' = H2.setResponseTrailersMaker h2rsp trailers
          return (h2rsp', st)
  where
    !isHead = requestMethod req == H.methodHead
    !reqhdr = requestHeaders req
    !svr    = S.settingsServerName settings
    add date server rsphdr = R.addAltSvc settings $
        (H.hDate, date) : (H.hServer, server) : rsphdr
    -- fixme: not adding svr if already exists

----------------------------------------------------------------

responseFile :: H.Status -> H.ResponseHeaders -> Bool
             -> FilePath -> Maybe FilePart -> InternalInfo -> H.RequestHeaders
             -> IO (H2.Response, H.Status)
responseFile st rsphdr _ _ _ _ _
  | noBody st = return $ responseNoBody st rsphdr

responseFile st rsphdr isHead path (Just fp) _ _ =
    return $ responseFile2XX st rsphdr isHead fileSpec
  where
    !off'   = fromIntegral $ filePartOffset fp
    !bytes' = fromIntegral $ filePartByteCount fp
    !fileSpec = H2.FileSpec path off' bytes'

responseFile _ rsphdr isHead path Nothing ii reqhdr = do
    efinfo <- E.try $ getFileInfo ii path
    case efinfo of
        Left (_ex :: E.IOException) -> return $ response404 rsphdr
        Right finfo -> do
            let reqidx = indexRequestHeader reqhdr
                rspidx = indexResponseHeader rsphdr
            case conditionalRequest finfo rsphdr rspidx reqidx of
                WithoutBody s                -> return $ responseNoBody s rsphdr
                WithBody s rsphdr' off bytes -> do
                    let !off'   = fromIntegral off
                        !bytes' = fromIntegral bytes
                        !fileSpec = H2.FileSpec path off' bytes'
                    return $ responseFile2XX s rsphdr' isHead fileSpec

----------------------------------------------------------------

responseFile2XX :: H.Status -> H.ResponseHeaders -> Bool -> H2.FileSpec -> (H2.Response, H.Status)
responseFile2XX st rsphdr isHead fileSpec
  | isHead = responseNoBody st rsphdr
  | otherwise = (H2.responseFile st rsphdr fileSpec, st)

----------------------------------------------------------------

responseBuilder :: H.Status -> H.ResponseHeaders -> Bool
                -> BB.Builder
                -> (H2.Response, H.Status)
responseBuilder st rsphdr isHead builder
  | noBody st = responseNoBody st rsphdr
  | isHead    = responseNoBody st rsphdr
  | otherwise = (H2.responseBuilder st rsphdr builder, st)

----------------------------------------------------------------

responseStream :: H.Status -> H.ResponseHeaders -> Bool
               -> StreamingBody
               -> (H2.Response, H.Status)
responseStream st rsphdr isHead strmbdy
  | noBody st = responseNoBody st rsphdr
  | isHead    = responseNoBody st rsphdr
  | otherwise = (H2.responseStreaming st rsphdr strmbdy, st)

----------------------------------------------------------------

responseNoBody :: H.Status -> H.ResponseHeaders -> (H2.Response, H.Status)
responseNoBody st rsphdr = (H2.responseNoBody st rsphdr, st)

----------------------------------------------------------------

response404 :: H.ResponseHeaders -> (H2.Response, H.Status)
response404 rsphdr = (h2rsp, st)
  where
    h2rsp = H2.responseBuilder st rsphdr' body
    st = H.notFound404
    !rsphdr' = R.replaceHeader H.hContentType "text/plain; charset=utf-8" rsphdr
    !body = BB.byteString "File not found"

----------------------------------------------------------------

noBody :: H.Status -> Bool
noBody = not . R.hasBody

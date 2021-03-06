{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DeriveDataTypeable #-}
import Test.Hspec
import Control.Exception (Exception, toException)
import qualified Data.ByteString as S
import Network.Wai hiding (requestBody)
import Network.Wai.Handler.Warp (run)
import Network.HTTP.Conduit
import Network.HTTP.Conduit.Browser2
import Data.ByteString.Base64 (encode)
import Data.Typeable (Typeable)
import Control.Concurrent (forkIO, killThread)
import Network.HTTP.Types
import Control.Exception.Lifted (try)
import Data.ByteString.UTF8 (fromString)
import Data.CaseInsensitive (mk)
import qualified Data.ByteString.Lazy as L
import Data.IORef
import Control.Monad.IO.Class (liftIO)

-- TODO tests for responseTimeout/Browser.timeout.

data TestException = TestException
    deriving (Show, Typeable)

instance Exception TestException

strictToLazy :: S.ByteString -> L.ByteString
strictToLazy = L.fromChunks . replicate 1

lazyToStrict :: L.ByteString -> S.ByteString
lazyToStrict = S.concat . L.toChunks

dummy :: S.ByteString
dummy = "dummy"

user :: S.ByteString
user = "user"

pass :: S.ByteString
pass = "pass"

failure :: L.ByteString
failure = "failure"

success :: L.ByteString
success = "success"

appWithSideEffect :: IORef Bool -> Application
appWithSideEffect ref _ = liftIO $ do
    v <- readIORef ref
    writeIORef ref $ not v
    if v
        then return $ responseLBS status500 [] failure
        else return $ responseLBS status200 [] success

app :: Application
app req =
    case pathInfo req of
        [] -> return $ responseLBS status200 [] "homepage"
        ["cookies"] -> return $ responseLBS status200 [tastyCookie] "cookies"
        ["print-cookies"] -> return $ responseLBS status200 [] $ getHeader "Cookie"
        ["useragent"] -> return $ responseLBS status200 [] $ getHeader "User-Agent"
        ["accept"] -> return $ responseLBS status200 [] $ getHeader "Accept"
        ["authorities"] -> return $ responseLBS status200 [] $ getHeader "Authorization"
        ["redir1"] -> return $ responseLBS temporaryRedirect307 [redir2] L.empty
        ["redir2"] -> return $ responseLBS temporaryRedirect307 [redir3] L.empty
        ["redir3"] -> return $ responseLBS status200 [] $ strictToLazy dummy
        _ -> return $ responseLBS status404 [] "not found"

    where tastyCookie = (mk (fromString "Set-Cookie"), fromString "flavor=chocolate-chip;")
          getHeader s = strictToLazy $ case lookup s $ Network.Wai.requestHeaders req of
                            Just a -> a
                            Nothing -> S.empty
          redir2 = (mk (fromString "Location"), fromString "/redir2")
          redir3 = (mk (fromString "Location"), fromString "/redir3")

main :: IO ()
main = do
    ref <- newIORef True
    hspec $ do
        describe "browser" $ do
            it "cookie jar works" $ do
                tid <- forkIO $ run 3011 app
                request1 <- parseUrl "http://127.0.0.1:3011/cookies"
                request2 <- parseUrl "http://127.0.0.1:3011/print-cookies"
                elbs <- withManager $ \manager -> do
                    browse manager $ do
                        _ <- makeRequestLbs request1
                        makeRequestLbs request2
                killThread tid
                if (lazyToStrict $ responseBody elbs) /= fromString "flavor=chocolate-chip"
                     then error "Should have gotten the cookie back!"
                     else return ()
            it "cookie filter can deny cookies" $ do
                tid <- forkIO $ run 3011 app
                request1 <- parseUrl "http://127.0.0.1:3011/cookies"
                request2 <- parseUrl "http://127.0.0.1:3011/print-cookies"
                elbs <- withManager $ \manager -> do
                    browse manager $ do
                        setCookieFilter $ const $ const $ return False
                        _ <- makeRequestLbs request1
                        makeRequestLbs request2
                killThread tid
                if (lazyToStrict $ responseBody elbs) /= S.empty
                     then error "Shouldn't have gotten the cookie back!"
                     else return ()
            it "can save and load cookie jar" $ do
                tid <- forkIO $ run 3011 app
                request1 <- parseUrl "http://127.0.0.1:3011/cookies"
                request2 <- parseUrl "http://127.0.0.1:3011/print-cookies"
                (elbs1, elbs2) <- withManager $ \manager -> do
                    browse manager $ do
                        _ <- makeRequestLbs request1
                        cookie_jar <- getCookieJar
                        setCookieJar def
                        elbs1 <- makeRequestLbs request2
                        setCookieJar cookie_jar
                        elbs2 <- makeRequestLbs request2
                        return (elbs1, elbs2)
                killThread tid
                if (((lazyToStrict $ responseBody elbs1) /= S.empty) ||
                    ((lazyToStrict $ responseBody elbs2) /= fromString "flavor=chocolate-chip"))
                     then error "Cookie jar got garbled up!"
                     else return ()
            it "user agent sets correctly" $ do
                tid <- forkIO $ run 3012 app
                request <- parseUrl "http://127.0.0.1:3012/useragent"
                elbs <- withManager $ \manager -> do
                    browse manager $ do
                        setUserAgent $ Just $ fromString "abcd"
                        makeRequestLbs request
                killThread tid
                if (lazyToStrict $ responseBody elbs) /= fromString "abcd"
                     then error "Should have gotten the user agent back!"
                     else return ()
            it "user agent overrides" $ do
                tid <- forkIO $ run 3012 app
                request <- parseUrl "http://127.0.0.1:3012/useragent"
                elbs <- withManager $ \manager -> do
                    browse manager $ do
                        setUserAgent $ Just $ fromString "abcd"
                        makeRequestLbs request{Network.HTTP.Conduit.requestHeaders = [(hUserAgent, "bwahaha")]}
                killThread tid
                let a = lazyToStrict $ responseBody elbs
                if a == fromString "abcd"
                     then return ()
                     else if a == fromString "bwahaha"
                            then error "Should have overwriten request's own header!"
                            else error $ "Some kind of magic happened, User-Agent: \"" ++ show a ++ "\"."
            it "zeroes overrideHeaders" $ do
                tid <- forkIO $ run 3012 app
                request <- parseUrl "http://127.0.0.1:3012/useragent"
                elbs <- withManager $ \manager -> do
                    browse manager $ do
                        setUserAgent Nothing
                        setOverrideHeaders []
                        makeRequestLbs request{Network.HTTP.Conduit.requestHeaders = [(hUserAgent, "bwahaha")]}
                killThread tid
                if (lazyToStrict $ responseBody elbs) /= fromString "bwahaha"
                     then error "Shouldn't have deleted user-agent!"
                     else return ()
            it "setting overrideheaders doesn't unset useragent" $ do
                tid <- forkIO $ run 3012 app
                request <- parseUrl "http://127.0.0.1:3012/useragent"
                elbs <- withManager $ \manager -> do
                    browse manager $ do
                        setUserAgent $ Just "abcd"
                        setOverrideHeaders []
                        makeRequestLbs request{Network.HTTP.Conduit.requestHeaders = [(hUserAgent, "bwahaha")]}
                killThread tid
                if (lazyToStrict $ responseBody elbs) /= fromString "abcd"
                     then error "Should have overrided user-agent!"
                     else return ()
            it "doesn't override additional headers" $ do
                tid <- forkIO $ run 3012 app
                request <- parseUrl "http://127.0.0.1:3012/accept"
                elbs <- withManager $ \manager -> do
                    browse manager $ do
                        insertOverrideHeader ("User-Agent", "http-conduit")
                        insertOverrideHeader ("Connection", "keep-alive")
                        makeRequestLbs request{Network.HTTP.Conduit.requestHeaders = [("User-Agent", "another agent"), ("Accept", "everything/digestible")]}
                killThread tid
                if (lazyToStrict $ responseBody elbs) /= fromString "everything/digestible"
                     then error "Shouldn't have deleted Accept header!"
                     else return ()
            it "authorities get set correctly" $ do
                tid <- forkIO $ run 3013 app
                request <- parseUrl "http://127.0.0.1:3013/authorities"
                elbs <- withManager $ \manager -> do
                    browse manager $ do
                        setAuthorities $ const $ Just (user, pass)
                        makeRequestLbs request
                killThread tid
                if (lazyToStrict $ responseBody elbs) /= (fromString "Basic " `S.append` (encode $ user `S.append` ":" `S.append` pass))
                     then error "Authorities didn't get set correctly!"
                     else return ()
            it "can follow redirects" $ do
                tid <- forkIO $ run 3014 app
                request <- parseUrl "http://127.0.0.1:3014/redir1"
                elbs <- withManager $ \manager -> do
                    browse manager $ do
                        setMaxRedirects $ Just 2
                        makeRequestLbs request
                killThread tid
                if (lazyToStrict $ responseBody elbs) /= dummy
                     then error "Should be able to follow 2 redirects"
                     else return ()
            it "max redirects fails correctly" $ do
                tid <- forkIO $ run 3015 app
                request <- parseUrl "http://127.0.0.1:3015/redir1"
                elbs <- try $ withManager $ \manager -> do
                    browse manager $ do
                        setMaxRedirects $ Just 1
                        makeRequestLbs request
                killThread tid
                case elbs of
                     Left (TooManyRedirects _) -> return ()
                     _ -> error "Shouldn't have followed all those redirects!"
            it "Retry fails correctly when it is too low" $ do
                writeIORef ref True
                tid <- forkIO $ run 3016 $ appWithSideEffect ref
                request <- parseUrl "http://127.0.0.1:3016/"
                elbs <- try $ withManager $ \manager -> do
                    browse manager $ do
                        setMaxRetryCount 1
                        makeRequestLbs request
                killThread tid
                case elbs of
                     Left (StatusCodeException _ _) -> return ()
                     _ -> error "1 redirect shouldn't be enough!"
            it "Makes multiple retries" $ do
                writeIORef ref True
                tid <- forkIO $ run 3017 $ appWithSideEffect ref
                request <- parseUrl "http://127.0.0.1:3017/"
                elbs <- withManager $ \manager -> do
                    browse manager $ do
                        setMaxRetryCount 2
                        makeRequestLbs request
                killThread tid
                if responseBody elbs /= success
                     then error "Didn't retry failed request"
                     else return ()
            it "throws statusCodeException, when maxRedirects=0" $ do
                tid <- forkIO $ run 3015 app
                request <- parseUrl "http://127.0.0.1:3015/redir1"
                elbs <- try $ withManager $ \manager -> do
                    browse manager $ do
                        setMaxRedirects $ Just 0
                        makeRequestLbs request
                killThread tid
                case elbs of
                     Left StatusCodeException{} -> return ()
                     _ -> error "Should've thrown StatusCodeException!"
            it "doesn't override redirectCount when maxRedirects=Nothing" $ do
                tid <- forkIO $ run 3015 app
                request <- parseUrl "http://127.0.0.1:3015/redir1"
                elbs <- try $ withManager $ \manager -> do
                    browse manager $ do
                        setMaxRedirects Nothing
                        makeRequestLbs request{redirectCount = 0}
                killThread tid
                case elbs of
                     Left StatusCodeException{} -> return ()
                     _ -> error "redirectCount /= 0!"
            it "overrides redirectCount when maxRedirects/=Nothing" $ do
                tid <- forkIO $ run 3015 app
                request <- parseUrl "http://127.0.0.1:3015/redir1"
                elbs <- try $ withManager $ \manager -> do
                    browse manager $ do
                        setMaxRedirects $ Just 0
                        makeRequestLbs request{redirectCount = 10}
                killThread tid
                case elbs of
                     Left StatusCodeException{} -> return ()
                     _ -> error "redirectCount should be 0!"
            it "uses checkStatus correctly" $ do
                tid <- forkIO $ run 3012 app
                request <- parseUrl "http://127.0.0.1:3012/useragent"
                elbs <- try $ withManager $ \manager -> do
                    browse manager $ do
                        setCheckStatus $ Just $  \ _ _ -> Just $ toException TestException
                        makeRequestLbs request
                killThread tid
                case elbs of
                    Left TestException -> return ()
                    _ -> error "Should have thrown an exception!"

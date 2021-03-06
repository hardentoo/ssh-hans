{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
module Network.SSH.Rekey where

import Network.SSH.Named
import Network.SSH.Mac
import Network.SSH.Ciphers
import Network.SSH.Compression
import Network.SSH.Messages
import Network.SSH.Keys
import Network.SSH.PubKey
import Network.SSH.State
import Network.SSH.Packet

import Control.Applicative ((<|>))
#if !MIN_VERSION_base(4,8,0)
import Control.Applicative ((<$>), (<*>))
#endif
import Data.List ((\\), find)
import Data.IORef (readIORef, modifyIORef')
import Control.Concurrent
import Control.Monad

import Data.ByteString.Short (ShortByteString)
import qualified Data.ByteString as S
import qualified Data.ByteString.Lazy as L

----------------------------------------------------------------
-- Key exchange is described in RFC 4253 sections 7 through 9

-- | Initial entry point into the rekeying logic. This version
-- sends a proposal and waits for the response.
initialKeyExchange :: HandleLike -> SshState -> IO ()
initialKeyExchange h state =
  do i_us <- mkProposal (sshProposalPrefs state)
     sendProposal h state i_us
     SshMsgKexInit i_them <- receive h state
     rekeyConnection h state i_us i_them

-- | Subsequent entry point into the rekeying logic. This version
-- is called when a proposal has already been received and only
-- sends the response.
rekeyKeyExchange :: HandleLike -> SshState -> SshProposal -> IO ()
rekeyKeyExchange h state i_them =
  do i_us <- mkProposal (sshProposalPrefs state)
     sendProposal h state i_us
     rekeyConnection h state i_us i_them

sendProposal :: HandleLike -> SshState -> SshProposal -> IO ()
sendProposal h state i_us =
  do debug state $ "auth methods: " ++ show (sshServerHostKeyAlgs i_us)
     send h state (SshMsgKexInit i_us)

-- | Build 'SshProposal' from preferences.
--
-- An error occurs if some suplied algorithm is not supported.
mkProposal :: SshProposalPrefs -> IO SshProposal
mkProposal prefs = do
  sshProposalCookie <- newCookie

  sshServerHostKeyAlgs <- check list    sshServerHostKeyAlgsPrefs
  sshKexAlgs           <- check list    sshKexAlgsPrefs
  sshEncAlgs           <- check sshAlgs sshEncAlgsPrefs
  sshMacAlgs           <- check sshAlgs sshMacAlgsPrefs
  sshCompAlgs          <- check sshAlgs sshCompAlgsPrefs

  let sshLanguages       = SshAlgs [] []
  let sshFirstKexFollows = False
  return SshProposal{..}

  where
  -- Apply one of the below checkers.
  check :: (a -> a -> IO a) -> (SshProposalPrefs -> a) -> IO a
  check check' project =
    check' (project prefs) (project allAlgsSshProposalPrefs)

  -- Check that preferred algorithms are supported and die loudly if
  -- not.
  list :: (Eq a, Show a) => [a] -> [a] -> IO [a]
  list preferred supported = do
    let unsupported = preferred \\ supported
    when (not $ null unsupported) $
      fail $ "mkProposal: unsupported algorithms: " ++ show unsupported ++
             "            supported algorithms: " ++ show supported
    return preferred

  sshAlgs :: SshAlgs -> SshAlgs -> IO SshAlgs
  sshAlgs (SshAlgs p_c p_s) (SshAlgs s_c s_s) =
    SshAlgs <$> list p_c s_c <*> list p_s s_s

-- | The collection of all supported algorithms.
--
-- A client can use these prefs as is. A server, on the other hand,
-- should specify 'sshServerHostKeyAlgsPrefs' corresponding to the
-- types of actual private keys it has.
allAlgsSshProposalPrefs :: SshProposalPrefs
allAlgsSshProposalPrefs = SshProposalPrefs
  { sshKexAlgsPrefs           = map nameOf allKex
  , sshServerHostKeyAlgsPrefs = allHostKeyAlgs
  , sshEncAlgsPrefs           =
      SshAlgs (map nameOf allCipher)      (map nameOf allCipher)
  , sshMacAlgsPrefs           =
      SshAlgs (map nameOf allMac)         (map nameOf allMac)
  , sshCompAlgsPrefs          =
      SshAlgs (map nameOf allCompression) (map nameOf allCompression)
  }

rekeyConnection :: HandleLike -> SshState -> SshProposal -> SshProposal -> IO ()
rekeyConnection h state i_us i_them
  | ClientRole <- sshRole state = rekeyConnection_c h state i_us i_them
  | ServerRole <- sshRole state = rekeyConnection_s h state i_us i_them
  | otherwise = error "rekeyConnection: unreachable code!"

rekeyConnection_s :: HandleLike -> SshState -> SshProposal -> SshProposal -> IO ()
rekeyConnection_s h state i_s i_c =
  do (v_s, v_c) <- readIORef (sshIdents state)
     let (_i_us, i_them) = (i_s, i_c)

     let creds = sshAuthMethods state
     suite    <- computeSuiteOrDie h state creds i_c i_s

     handleMissedGuess h state suite i_them

     SshMsgKexDhInit pub_c <- receive h state
     (pub_s, kexFinish)    <- kexRun (suite_kex suite)
     k <- maybe (fail "bad remote public") return (kexFinish pub_c)

     let sid = SshSessionId
             $ kexHash (suite_kex suite)
             $ sshDhHash v_c v_s i_c i_s (suite_host_pub suite) pub_c pub_s k

     -- the session id doesn't change on rekeying
     modifyIORef' (sshSessionId state) (<|> Just sid)

     sig <- signSessionId (suite_host_priv suite) sid
     send h state (SshMsgKexDhReply (suite_host_pub suite) pub_s sig)

     installSecurity h state suite sid k

rekeyConnection_c :: HandleLike -> SshState -> SshProposal -> SshProposal -> IO ()
rekeyConnection_c h state i_c i_s =
  do (v_s, v_c) <- readIORef (sshIdents state)
     let (_i_us, i_them) = (i_c, i_s)

     suite <- computeSuiteOrDie h state [] i_c i_s

     handleMissedGuess h state suite i_them

     let kex = suite_kex suite
     (pub_c, kexFinish) <- kexRun kex
     debug state "ran kex! sending dhInit to server ..."
     send h state (SshMsgKexDhInit pub_c)
     debug state"sent dhInit to server! waiting for dhReply ..."
     SshMsgKexDhReply pub_cert_s pub_s sig_s <-
       receiveSpecific SshMsgTagKexDhReply h state
     debug state "got dhReply from server!"
     k <- maybe (fail "bad remote public") return (kexFinish pub_s)
     let sid = SshSessionId
             $ kexHash kex
             $ sshDhHash v_c v_s i_c i_s pub_cert_s pub_c pub_s k

     -- the session id doesn't change on rekeying
     modifyIORef' (sshSessionId state) (<|> Just sid)
     debug state "verifying server sig ..."
     when (not $ verifyServerSig pub_cert_s sig_s sid) $ do
       send h state (SshMsgDisconnect SshDiscKexFailed
                            "Unable to verify server sig!" "")
       fail "Unable to verify server sig!"
     debug state "verified server sig!"

     installSecurity h state suite sid k

-- | When their proposal says that a kex guess packet
-- is coming, but their guess was wrong, we must drop the next packet.
handleMissedGuess ::
  HandleLike -> SshState ->
  CipherSuite ->
  SshProposal {- ^ them -} ->
  IO ()
handleMissedGuess h state suite i_them
  | sshFirstKexFollows i_them
  , guess:_        <- sshKexAlgs i_them
  , actual         <- suite_kex_desc (suite_desc suite)
  , guess /= actual = void (receive h state)

  | otherwise = return ()

-- The client should pass @[]@ for the @serverCreds@.
computeSuiteOrDie ::
  HandleLike -> SshState -> [ServerCredential] -> SshProposal -> SshProposal ->
  IO CipherSuite
computeSuiteOrDie h state serverCreds i_c i_s = do
  let i_them = clientAndServer2them (sshRole state) i_c i_s
  debug state "negotiating cipher suite ..."
  debug state $ "their ssh proposal: " ++ show i_them
  suite <- dieGracefullyOnSuiteFailure h state
         $ computeSuite state serverCreds i_s i_c
  debug state "negotiated suite:"
  debug state $ show (suite_desc suite)
  return suite

dieGracefullyOnSuiteFailure ::
  HandleLike -> SshState  -> Maybe CipherSuite -> IO CipherSuite
dieGracefullyOnSuiteFailure h state Nothing = do
  send h state (SshMsgDisconnect SshDiscProtocolError
                       "Failed to agree on cipher suite!" "")
  fail "cipher suite negotiation failed"
dieGracefullyOnSuiteFailure _ _ (Just cs) = return cs

installSecurity ::
  HandleLike -> SshState -> CipherSuite ->
  SshSessionId ->
  S.ByteString {- ^ shared secret -} ->
  IO ()
installSecurity h state suite sid k =
  do Just osid <- readIORef (sshSessionId state)
     let keys = genKeys (kexHash (suite_kex suite)) k sid osid

     send h state SshMsgNewKeys
     transitionKeysOutgoing suite keys state

     SshMsgNewKeys <- receiveSpecific SshMsgTagNewKeys h state
     transitionKeysIncoming suite keys state

transitionKeysOutgoing :: CipherSuite -> Keys -> SshState -> IO ()
transitionKeysOutgoing CipherSuite{..} Keys{..} SshState{..} =
  do compress <- makeCompress $ cs suite_c2s_comp suite_s2c_comp
     modifyMVar_ sshSendState $ \(seqNum,_,_,_,_,drg) ->
       return ( seqNum
              , cs suite_c2s_cipher suite_s2c_cipher
              , activateCipherE
                  (cs k_c2s_cipherKeys k_s2c_cipherKeys)
                  (cs suite_c2s_cipher suite_s2c_cipher)
              , cs (suite_c2s_mac k_c2s_integKey) (suite_s2c_mac k_s2c_integKey)
              , compress
              , drg
              )
  where cs = clientAndServer2us sshRole

transitionKeysIncoming :: CipherSuite -> Keys -> SshState -> IO ()
transitionKeysIncoming CipherSuite{..} Keys{..} SshState{..} =
  do decompress <- makeDecompress $ cs suite_s2c_comp suite_c2s_comp
     modifyIORef' sshRecvState $ \(seqNum, _, _, _, _) ->
       ( seqNum
       , cs suite_s2c_cipher suite_c2s_cipher
       , activateCipherD
           (cs k_s2c_cipherKeys k_c2s_cipherKeys)
           (cs suite_s2c_cipher suite_c2s_cipher)
       , cs (suite_s2c_mac k_s2c_integKey) (suite_c2s_mac k_c2s_integKey)
       , decompress
       )
  where cs = clientAndServer2us sshRole

-- TODO(conathan): refactor: remove the host private key and the host
-- public key -- these can be part of client or server specific state
-- -- and change callers to use a 'role'-based selector for c2s and
-- s2c, since these are always in the same order in the suite.
data CipherSuite = CipherSuite
  { suite_kex :: Kex
  , suite_c2s_cipher, suite_s2c_cipher :: Cipher
  , suite_c2s_mac   , suite_s2c_mac    :: L.ByteString -> Mac
  , suite_c2s_comp  , suite_s2c_comp   :: Compression
  , suite_host_priv :: PrivateKey
  , suite_host_pub  :: SshPubCert
  , suite_desc      :: CipherSuiteDesc
  }

data CipherSuiteDesc = CipherSuiteDesc
  { suite_kex_desc
  , suite_c2s_cipher_desc, suite_s2c_cipher_desc
  , suite_c2s_mac_desc   , suite_s2c_mac_desc
  , suite_c2s_comp_desc  , suite_s2c_comp_desc :: ShortByteString
  } deriving (Show)

-- | Compute a cipher suite given two proposals. The first algorithm
-- requested by the client that the server also supports is selected.
computeSuite :: SshState -> [ServerCredential] -> SshProposal -> SshProposal ->
  Maybe CipherSuite
computeSuite SshState{..} auths server h =
  do let det = determineAlg server h

     suite_kex_desc <- det sshKexAlgs
     suite_kex      <- lookupNamed allKex suite_kex_desc

     suite_c2s_cipher_desc <- det (sshClientToServer.sshEncAlgs)
     suite_c2s_cipher      <- lookupNamed allCipher suite_c2s_cipher_desc

     suite_s2c_cipher_desc <- det (sshServerToClient.sshEncAlgs)
     suite_s2c_cipher      <- lookupNamed allCipher suite_s2c_cipher_desc

     suite_c2s_mac_desc <- if aeadMode suite_c2s_cipher
                           then Just (nameOf mac_none)
                           else det (sshClientToServer.sshMacAlgs)
     suite_c2s_mac      <- lookupNamed allMac suite_c2s_mac_desc

     suite_s2c_mac_desc <- if aeadMode suite_s2c_cipher
                           then Just (nameOf mac_none)
                           else det (sshServerToClient.sshMacAlgs)
     suite_s2c_mac      <- lookupNamed allMac suite_s2c_mac_desc

     -- TODO(conathan): factor out server private key since it doesn't
     -- make sense for client.
     let host_auth_s = lookupNamed auths =<< det sshServerHostKeyAlgs
     let host_auth_c = return (undefined, undefined)
     (suite_host_pub, suite_host_priv) <- clientAndServer2us sshRole
                                          host_auth_c host_auth_s

     suite_s2c_comp_desc <- det (sshServerToClient.sshCompAlgs)
     suite_s2c_comp      <- lookupNamed allCompression suite_s2c_comp_desc

     suite_c2s_comp_desc <- det (sshClientToServer.sshCompAlgs)
     suite_c2s_comp      <- lookupNamed allCompression suite_c2s_comp_desc

     let suite_desc = CipherSuiteDesc{..}
     return CipherSuite{..}

-- | Select first client choice acceptable to the server
determineAlg ::
  SshProposal {- ^ server -} ->
  SshProposal {- ^ client -} ->
  (SshProposal -> [ShortByteString]) {- ^ selector -} ->
  Maybe ShortByteString
determineAlg server client f = find (`elem` f server) (f client)

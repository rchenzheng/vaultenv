{-# LANGUAGE FlexibleInstances 
#-}
{-|
Module      : Config
Description : Read config from CLI options and environment

This module uses optparse-applicative to parse CLI options. It augments the
optparse parser with a mechanism to allow for overrides in environment
variables.

The main entry point is @parseOptionsFromEnvAndCli@.
-}
module Config
  ( Options(..)
  , MilliSeconds(..)
  , parseOptionsFromEnvAndCli
  , LogLevel(..)
  , readConfigFromEnvFiles
  , emptyOptions, defaultOptions, isOptionsComplete
  , splitAddress, validateCopyAddr, mergeOptions, getOptionsValue
  , Validated(), Completed()
  ) where

import Control.Applicative ((<*>), (<|>))
import Control.Monad(when, unless)
import Control.Monad.Except (runExcept, throwError)
import Data.List (intercalate, isPrefixOf)
import Data.Maybe (fromJust, fromMaybe, isNothing, isJust)
import Data.Monoid ((<>))
import Data.Char (isDigit)
import Data.Either (lefts, rights, isLeft)
import Data.Version (showVersion)
import Options.Applicative (value, long, auto, option, metavar, help, flag,
                            str, argument, many)
import Paths_vaultenv (version) -- Magic to get the version field from cabal.
import System.IO.Error (catchIOError)
import System.Exit (die)

import qualified Configuration.Dotenv as DotEnv
import qualified Options.Applicative as OptParse
import qualified System.Directory as Dir

-- | Type alias for enviornment variables, used for readability in this module.
type EnvVar = (String, String)

-- | Newtype wrapper for millisecond values.
newtype MilliSeconds = MilliSeconds { unMilliSeconds :: Int }
  deriving (Eq, Show)

-- | @Options@ contains all the configuration we support in vaultenv. It is
-- used in our @Main@ module to specify behavior.
data Options validated completed = Options
  { oVaultHost       :: Maybe String
  , oVaultPort       :: Maybe Int
  , oVaultAddr       :: Maybe String
  , oVaultToken      :: Maybe String
  , oSecretFile      :: Maybe FilePath
  , oCmd             :: Maybe String
  , oArgs            :: Maybe [String]
  , oConnectTls      :: Maybe Bool
  , oValidateCerts   :: Maybe Bool
  , oInheritEnv      :: Maybe Bool
  , oRetryBaseDelay  :: Maybe MilliSeconds
  , oRetryAttempts   :: Maybe Int
  , oLogLevel        :: Maybe LogLevel
  , oUsePath         :: Maybe Bool
  } deriving (Eq)

-- | Phantom type that indicates that an option is 
-- checked to be completed by ```isOptionsComplete``` and is validated by
-- ```validateCopyAddr```
data Completed

data UnCompleted

-- | Phantom type that indicates that an option is 
-- validated by ```validateCopyAddr```
data Validated

-- | Phantom type that indicates that an option is 
-- not validated by ```isOptionsComplete```
data UnValidated

-- An empty set of options, nothing is specified
emptyOptions :: Options Validated UnCompleted
emptyOptions = Options
  { oVaultHost      = Nothing
  , oVaultPort      = Nothing
  , oVaultAddr      = Nothing
  , oVaultToken     = Nothing
  , oSecretFile     = Nothing
  , oCmd            = Nothing
  , oArgs           = Nothing
  , oConnectTls     = Nothing
  , oValidateCerts  = Nothing
  , oInheritEnv     = Nothing
  , oRetryBaseDelay = Nothing
  , oRetryAttempts  = Nothing
  , oLogLevel       = Nothing
  , oUsePath        = Nothing
  }

-- | The default options that should be used when no value is specified
defaultOptions :: Options Validated UnCompleted
defaultOptions = Options
  { oVaultHost      = Just "localhost"
  , oVaultPort      = Just 8200
  , oVaultAddr      = Just "http://localhost:8200"
  , oVaultToken     = Nothing
  , oSecretFile     = Nothing
  , oCmd            = Nothing
  , oArgs           = Just []
  , oConnectTls     = Just True
  , oValidateCerts  = Just True
  , oInheritEnv     = Just True
  , oRetryBaseDelay = Just (MilliSeconds 40)
  , oRetryAttempts  = Just 9
  , oLogLevel       = Just Error
  , oUsePath        = Just True
}

-- | Casts one options structure into antoher, use only when certain that 
-- the validated and completed options can be given to a options file. 
castOptions :: Options a b -> Options c d
castOptions opts = Options
  { oVaultHost      = oVaultHost opts
  , oVaultPort      = oVaultPort opts
  , oVaultAddr      = oVaultAddr opts
  , oVaultToken     = oVaultToken opts
  , oSecretFile     = oSecretFile opts
  , oCmd            = oCmd opts 
  , oArgs           = oArgs opts
  , oConnectTls     = oConnectTls opts
  , oValidateCerts  = oValidateCerts opts 
  , oInheritEnv     = oInheritEnv opts
  , oRetryBaseDelay = oRetryBaseDelay opts
  , oRetryAttempts  = oRetryAttempts opts
  , oLogLevel       = oLogLevel opts
  , oUsePath        = oUsePath opts
}

instance Show (Options valid complete) where
  show opts = intercalate "\n"
    [ "Host:           " ++ showSpecifiedString (oVaultHost opts)
    , "Port:           " ++ showSpecified (oVaultPort opts)
    , "Addr            " ++ showSpecifiedString (oVaultAddr opts)
    , "Token:          " ++ maybe "Unspecified" (const "*****") (oVaultToken opts)
    , "Secret file:    " ++ showSpecifiedString (oSecretFile opts)
    , "Command:        " ++ showSpecifiedString (oCmd opts)
    , "Arguments:      " ++ showSpecified (oArgs opts)
    , "Use TLS:        " ++ showSpecified (oConnectTls opts)
    , "Validate certs: " ++ showSpecified (oValidateCerts opts)
    , "Inherit env:    " ++ showSpecified (oInheritEnv opts)
    , "Base delay:     " ++ showSpecified (unMilliSeconds <$> oRetryBaseDelay opts)
    , "Retry attempts: " ++ showSpecified (oRetryAttempts opts)
    , "Log-level:      " ++ showSpecified (oLogLevel opts)
    , "Use PATH:       " ++ showSpecified (oUsePath opts)
    ] where 
      showSpecified :: Show a => Maybe a -> String
      showSpecified (Just x) = show x
      showSpecified Nothing = "Unspecified"
      showSpecifiedString = fromMaybe "Unspecified"

-- | Gets the option from a Maybe, ```name``` should only be used for debugging
-- purposes, as ```isOptionsComplete``` should verify that every property that
-- does not have a default value, is present in the options.
getOptionsValue :: String -> Maybe a -> a 
getOptionsValue name = 
    fromMaybe (errorWithoutStackTrace 
        ("No configuration was found with the name " ++ name ++ " but it is required")
    )


data OptionsError
  = UnspecifiedValue String
  | InvalidAddrFormat String
  | UnknownScheme String
  | NonNumericPort String
  | HostPortSchemeAddrMismatch String String Int String -- UseTLS Host Port Addr

instance Show OptionsError where
  show (UnspecifiedValue s) = "The option " ++ s ++ " is required but not specified"
  show (InvalidAddrFormat s) = "The address " ++ s ++ " has an invalid format"
  show (UnknownScheme s)  = "The address " ++ s ++ " has no recognisable scheme, " 
      ++ " expected http:// or https:// at the beginning of the address."
  show (NonNumericPort s) = "The port " ++ s ++ " is not a valid int value"
  show (HostPortSchemeAddrMismatch scheme host port addr) = 
    "The scheme " ++ show scheme ++ 
    " , the host " ++ show host ++ 
    " and the port " ++ show port ++  
    " do not match the provided addr " ++ show addr

-- | Validates for a set of options that any provided addr is valid and that either the 
-- scheme, host and port or that any given addr matches the other provided information.
validateCopyAddr :: Options UnValidated completed -> Either OptionsError (Options Validated completed)
validateCopyAddr opts 
  | isNothing (oVaultAddr opts) = Right (castOptions opts) 
  | otherwise = runExcept $ do
      let addr = fromMaybe 
                      (errorWithoutStackTrace "Addr not a Just in validation") 
                      (oVaultAddr opts)
          (mStrScheme, addrHost, addrStrPort) = splitAddress addr
      unless (all isDigit addrStrPort && not (null addrStrPort)) 
          (throwError $ NonNumericPort addrStrPort)
      unless (isJust mStrScheme) 
          (throwError $ UnknownScheme addrHost)
      let mHost = oVaultHost opts
          mPort = oVaultPort opts
          mUseTLS = oConnectTls opts
          addrPort = read addrStrPort
          addrTLS | mStrScheme == Just "http://" = Just False
                  | mStrScheme == Just "https://" = Just True
                  | otherwise = Nothing -- This should never occur!
      when 
        (
          (isJust mHost && Just addrHost /= mHost) 
          || 
          (isJust mPort && Just addrPort /= mPort)
          || 
          (isJust mUseTLS && addrTLS /= mUseTLS)
        )
        (throwError $ HostPortSchemeAddrMismatch 
            (fromMaybe "" mStrScheme) 
            (fromMaybe "" mHost) 
            (fromMaybe (-1) mPort) 
            (fromMaybe "" $ oVaultAddr opts)
        )
      return opts{
          oVaultHost = Just addrHost,
          oVaultPort = Just addrPort,
          oConnectTls = addrTLS
        }

-- | This functions merges two options, where every specific option in the 
-- second options parameter is only used if for that option no value is 
-- specified in the first options parameter.
mergeOptions  :: Options Validated UnCompleted 
              -> Options Validated UnCompleted 
              -> Options Validated UnCompleted
mergeOptions opts1 opts2 = let 
      combine :: (Options Validated UnCompleted -> Maybe a) -> Maybe a
      combine f | isJust (f opts1) = f opts1
                | otherwise = f opts2 
    in 
    Options 
      (combine oVaultHost) -- Vault Host
      (combine oVaultPort) -- Vault Port
      (combine oVaultAddr) -- Vault Addr
      (combine oVaultToken) -- Vault Token
      (combine oSecretFile) -- Secret File
      (combine oCmd) -- Command
      (combine oArgs) -- Arguments
      (combine oConnectTls) -- Connect Tls
      (combine oValidateCerts) -- Validate Certs
      (combine oInheritEnv) -- InheritEnv
      (combine oRetryBaseDelay) -- Retry Base Delay
      (combine oRetryAttempts) -- Retry Attempts
      (combine oLogLevel) -- Log Level
      (combine oUsePath) -- Use Path



isOptionsComplete :: Options Validated UnCompleted
                  -> Either [OptionsError] (Options Validated Completed)
isOptionsComplete opts = 
      let errors = concat
            [
              [UnspecifiedValue "Token"       | isNothing (oVaultToken opts)]
            , [UnspecifiedValue "Command"     | isNothing (oCmd opts)]
            , [UnspecifiedValue "Secret file" | isNothing (oSecretFile opts)]
            ]
      in  if not (null errors) 
          then Left errors 
          else Right (castOptions opts)

splitAddress :: String -> (Maybe String, String, String)
splitAddress addr = 
        let
          -- | Split the string on the last colon
          splitOnLastColon :: String -> (String, String)
          splitOnLastColon = splitOnLastColonHelper "" ""
          -- | Helper that splits on the last colon, oneButLast contains 
          -- everything before the last colon lastAfter contains everything 
          -- after the last colon
          splitOnLastColonHelper :: String -> String -> String -> (String, String)
          splitOnLastColonHelper oneButLast lastAfter [] = 
                      (drop 1 (reverse oneButLast), reverse lastAfter)
          splitOnLastColonHelper oneButLast lastAfter (c:cs) 
              | c == ':'  = splitOnLastColonHelper 
                                  (lastAfter ++ ":" ++ oneButLast) "" cs
              | otherwise = splitOnLastColonHelper 
                                  oneButLast (c : lastAfter) cs
          
          (schemeHost, port) = splitOnLastColon addr
          (scheme, host)  
              | isPrefixOf "http://" schemeHost = 
                    (Just "http://", drop (length "http://") schemeHost)
              | isPrefixOf "https://" schemeHost = 
                    (Just "https://", drop (length "https://") schemeHost)
              | otherwise = (Nothing, schemeHost)
        in (scheme, host, port)
        
          

-- | LogLevel to run vaultenv under. Under @Error@, which is the default, we
-- will print error messages in error cases. Examples: Vault gives 404s, our
-- token is invalid, we don't have permissions for a certain path, Vault is
-- unavailable.
--
-- Under @Info@, we print some additional information related to the config.
data LogLevel
  = Info
  | Error
  deriving (Eq, Ord, Show)

instance Read LogLevel where
  readsPrec _ "error" = [(Error, "")]
  readsPrec _ "info" = [(Info, "")]
  readsPrec _ _ = []

-- | Parse program options from the command line and the process environment.
parseOptionsFromEnvAndCli :: [EnvVar] -> [[EnvVar]] -> IO (Options Validated Completed)
parseOptionsFromEnvAndCli localEnvVars envFileSettings =
  let eLocalEnvFlagsOptions = validateCopyAddr $ parseEnvFlags localEnvVars
      eEnvFileSettingsOptions = map (validateCopyAddr . parseEnvFlags) envFileSettings
  in do
    eParseResult <- validateCopyAddr <$> OptParse.execParser optionsParserWithInfo
    let results = eEnvFileSettingsOptions ++ [eLocalEnvFlagsOptions, eParseResult]
    if any isLeft results then
      die ("[ERROR] " ++ unlines (map show $ lefts results))
    else 
        let 
          combined = foldl (flip mergeOptions) defaultOptions (rights results)
          completed = isOptionsComplete combined
          in either 
                (\l -> die ("[ERROR] " ++ show l))
                return
                completed

-- | Parses behavior flags from a list of environment variables. If an
-- environment variable corresponding to the flag is set to @"true"@ or
-- @"false"@, we use that as the default on the corresponding CLI option.
--
-- If these variables aren't present, we default to @False@. We print an error
-- if they're set to anything else than @"true"@ or @"false"@.
parseEnvFlags :: [EnvVar] -> Options UnValidated UnCompleted
parseEnvFlags envVars
  = emptyOptions
  { oVaultHost      = lookupEnvString   "VAULT_HOST"
  , oVaultPort      = lookupEnvInt      "VAULT_PORT"
  , oVaultAddr      = lookupEnvString   "VAULT_ADDR"  
  , oVaultToken     = lookupEnvString   "VAULT_TOKEN"
  , oSecretFile     = lookupEnvString   "VAULTENV_SECRETS_FILE"
  , oCmd            = lookupEnvString   "CMD"
  , oArgs           = lookupStringList  "ARGS..."
  , oConnectTls     = lookupEnvFlag     "VAULTENV_CONNECT_TLS"
  , oValidateCerts  = lookupEnvFlag     "VAULTENV_VALIDATE_CERTS"
  , oInheritEnv     = lookupEnvFlag     "VAULTENV_INHERIT_ENV"
  , oRetryBaseDelay = MilliSeconds <$> lookupEnvInt      "VAULTENV_RETRY_BASE_DELAY"
  , oRetryAttempts  = lookupEnvInt      "VAULTENV_RETRY_ATTEMPTS"
  , oLogLevel       = lookupEnvLogLevel "VAULTENV_LOG_LEVEL"
  , oUsePath        = lookupEnvFlag     "VAULTENV_USE_PATH"
  }
  where
    err :: String -> a
    err key = errorWithoutStackTrace $ "[ERROR]: Invalid value for environment variable " ++ key
    lookupEnvString key = lookup key envVars
    lookupEnvInt :: String -> Maybe Int
    lookupEnvInt key 
      | isNothing sVal = Nothing
      | not (null sVal) && all isDigit (fromJust sVal) = read <$> sVal
      | otherwise = err key
      where sVal = lookupEnvString key
    lookupStringList key = words <$> lookupEnvString key
    lookupEnvLogLevel key = 
      case lookup key envVars of
        Just "info" -> Just Info
        Just "error" -> Just Error
        Nothing -> Nothing
        _ -> err key
    lookupEnvFlag key =
      case lookup key envVars of
        Just "true" -> Just True
        Just "false" -> Just False
        Nothing -> Nothing
        _ -> err key

{-
Nothing -- Vault Host
  Nothing -- Vault Port
  Nothing -- Vault Addr
  Nothing -- Vault Token
  Nothing -- Secret File
  Nothing -- Command
  Nothing -- Arguments
  Nothing -- Connect Tls
  Nothing -- Validate Certs
  Nothing -- InheritEnv
  Nothing -- Retry Base Delay
  Nothing -- Retry Attempts
  Nothing -- Log Level
  Nothing -- Use Path

-}

-- | This function adds metadata to the @Options@ parser so it can be used with
-- execParser.
optionsParserWithInfo :: OptParse.ParserInfo (Options UnValidated UnCompleted)
optionsParserWithInfo =
  OptParse.info
    (OptParse.helper <*> versionOption <*> optionsParser)
    (OptParse.fullDesc <> OptParse.header header)
  where
    versionOption = OptParse.infoOption (showVersion version) (long "version" <> help "Show version")
    header = "vaultenv " ++ showVersion version ++ " - run programs with secrets from HashiCorp Vault"


-- | Parser for our CLI options. Seems intimidating, but is straightforward
-- once you know about applicative parsing patterns. We construct a parser for
-- @Options@ by combining parsers for parts of the record.
--
-- Toy example to illustrate the pattern:
--
-- @
--     OptionRecord <$> parser1 <*> parser2 <*> parser3
-- @
--
-- Here, the parser for @OptionRecord@ is the combination of parsers of its
-- internal fields.
--
-- The parsers get constructed by using different combinators from the
-- @Options.Applicative@ module. Here, we use @strOption@, @option@, @argument@
-- and flag. These take a @Mod@ value, which can specify how to parse an
-- option. These @Mod@ values have monoid instances and are composed as such.
--
-- So in our example above, we could have the following definition for
-- @parser1@:
--
-- @
--    parser1 = strOption $ long "my-option" <> value "default"
-- @
--
-- And have the thing compile if the first member of @OptionRecord@ would have
-- type @String@.
--
-- Another thing that should be noted is the way we use the Alternate instance
-- of @Parser@s. The @connectTls@, @validateCerts@ and @inheritEnv@ parsers all
-- have a cousin prefixed with @no@. Combining these with the alternate
-- instance like so
--
-- @
--    noConnectTls <|> connectTls
-- @
--
-- means that they are both mutually exclusive.
--
-- Why do we have the options for the affirmative case? (e.g. why does
-- @--connect-tls@ exist if we default to that behavior?) Because we want to be
-- able to override all config that happens via environment variables on the
-- CLI. So @VAULTENV_CONNECT_TLS=false vaultenv --connect-tls@ should connect
-- to Vault over a secure connection. Without this option, this use case is not
-- possible.
--
-- The way we do this in the parser is by taking an @EnvFlags@ record which
-- contains the settings that were provided via environment variables (and the
-- defaults, if there wasn't anything configured). We use this record to set
-- the default values of the different behaviour switches. So, if an
-- environment variable is used to configure the TLS option, that value will
-- always be used, except if it is overridden on the CLI.
optionsParser :: OptParse.Parser (Options UnValidated UnCompleted)
optionsParser = Options
    <$> host
    <*> port
    <*> addr
    <*> token
    <*> secretsFile
    <*> cmd
    <*> cmdArgs
    <*> (noConnectTls    <|> connectTls)
    <*> (noValidateCerts <|> validateCerts)
    <*> (noInheritEnv    <|> inheritEnv)
    <*> baseDelayMs
    <*> retryAttempts
    <*> logLevel
    <*> usePath
  where
    maybeStr = Just <$> str
    maybeStrOption = option maybeStr
    host
      =  option (Just <$> str)
      $  long "host"
      <> metavar "HOST"
      <> value Nothing
      <> help ("Vault host, either an IP address or DNS name. Defaults to localhost. " ++
               "Also configurable via VAULT_HOST.")
    port
      =  option (Just <$> auto)
      $  long "port"
      <> metavar "PORT"
      <> value Nothing
      <> help "Vault port. Defaults to 8200. Also configurable via VAULT_PORT."
    addr =
        option (Just <$> str)
        $ long "addr"
        <> metavar "ADDR"
        <> value Nothing
        <> help ("Vault address, the ip-address or DNS name, followed by the port, " ++
            "separated with a ':' Cannot be combined with either VAULT_PORT or VAULT_HOST")
    token
      =  maybeStrOption
      $  long "token"
      <> metavar "TOKEN"
      <> value Nothing
      <> help "Token to authenticate to Vault with. Also configurable via VAULT_TOKEN."
    secretsFile
      =  maybeStrOption
      $  long "secrets-file"
      <> metavar "FILENAME"
      <> value Nothing
      <> help ("Config file specifying which secrets to request. Also configurable " ++
               "via VAULTENV_SECRETS_FILE." )
    cmd
      =  argument maybeStr
      $  metavar "CMD"
      <> help "command to run after fetching secrets"
      <> value Nothing
    cmdArgs
      = (\lst -> if null lst then Nothing else Just lst) <$> 
        many ( argument str
        (     metavar "ARGS..."
          <>  help "Arguments to pass to CMD, defaults to nothing")
        )
    noConnectTls
      =  flag Nothing (Just False)
      $  long "no-connect-tls"
      <> help ("Don't use TLS when connecting to Vault. Default: use TLS. Also " ++
              "configurable via VAULTENV_CONNECT_TLS.")
    connectTls
      =  flag Nothing (Just True)
      $  long "connect-tls"
      <> help ("Always connect to Vault via TLS. Default: use TLS. Can be used " ++
                "to override VAULTENV_CONNECT_TLS.")
    noValidateCerts
      =  flag Nothing (Just True) 
      $  long "no-validate-certs"
      <> help ("Don't validate TLS certificates when connecting to Vault. Default: " ++
              "validate certs. Also configurable via VAULTENV_VALIDATE_CERTS.")
    validateCerts
      =  flag Nothing (Just True) 
      $  long "validate-certs"
      <> help ("Always validate TLS certificates when connecting to Vault. Default: " ++
                "validate certs. Can be used to override VAULTENV_CONNECT_TLS.")
    noInheritEnv
      =  flag Nothing (Just False)
      $  long "no-inherit-env"
      <> help ("Don't merge the parent environment with the secrets file. Default: " ++
              "merge environments. Also configurable via VAULTENV_INHERIT_ENV.")
    inheritEnv
      =  flag Nothing (Just True)
      $  long "inherit-env"
      <> help ("Always merge the parent environment with the secrets file. Default: " ++
                "merge environments. Can be used to override VAULTENV_INHERIT_ENV.")
    baseDelayMs
      =  fmap MilliSeconds <$> option (Just <$> auto)
      (  long "retry-base-delay-milliseconds"
      <> metavar "MILLISECONDS"
      <> value Nothing
      <> help ("Base delay for vault connection retrying. Defaults to 40ms. " ++
                "Also configurable via VAULTENV_RETRY_BASE_DELAY_MS.")
      )
    retryAttempts
      =  option (Just <$> auto)
      $  long "retry-attempts"
      <> metavar "NUM"
      <> value Nothing
      <> help ("Maximum number of vault connection retries. Defaults to 9. " ++
               "Also configurable through VAULTENV_RETRY_ATTEMPTS.")
    logLevel
      =  option (Just <$> auto)
      $  long "log-level"
      <> value Nothing
      <> metavar "error | info"
      
      <> help ("Log-level to run vaultenv under. Options: 'error' or 'info'. " ++
               "Defaults to 'error'. Also configurable via VAULTENV_LOG_LEVEL")
    usePath
      =  flag Nothing (Just True)
      $  long "use-path"
      <> help ("Use PATH for finding the executable that vaultenv should call. Default: " ++
              "don't search PATH. Also configurable via VAULTENV_USE_PATH.")


-- | Search for environment files in default locations and load them in order.
--
-- This function tries to read the following files in order to obtain
-- environment configuration. This is implicit behavior and allows the user to
-- configure vaultenv without setting up environment variables or passing CLI
-- flags. This is nicer for interactive usage.
readConfigFromEnvFiles :: IO [[(String, String)]]
readConfigFromEnvFiles = do
  xdgDir <- (Just <$> Dir.getXdgDirectory Dir.XdgConfig "vaultenv")
    `catchIOError` const (pure Nothing)
  cwd <- Dir.getCurrentDirectory
  let
    machineConfigFile = "/etc/vaultenv.conf"

    userConfigFile :: Maybe FilePath
    userConfigFile = fmap (++ "/vaultenv.conf") xdgDir
    cwdConfigFile = cwd ++ "/.env"

  -- @doesFileExist@ doesn't throw exceptions, it catches @IOError@s and
  -- returns @False@ if those are encountered.
  machineConfigExists <- Dir.doesFileExist machineConfigFile
  machineConfig <- if machineConfigExists
    then DotEnv.parseFile machineConfigFile
    else pure []

  userConfigExists <- case userConfigFile of
     Nothing -> pure False
     Just fp -> Dir.doesFileExist fp
  userConfig <- if userConfigExists
    then DotEnv.parseFile (fromJust userConfigFile) -- safe because of loadUserConfig
    else pure []

  cwdConfigExists <- Dir.doesFileExist cwdConfigFile
  cwdConfig <- if cwdConfigExists
    then DotEnv.parseFile cwdConfigFile
    else pure []

  -- Deduplicate, user config takes precedence over machine config
  let config = [machineConfig, userConfig, cwdConfig]
  pure config

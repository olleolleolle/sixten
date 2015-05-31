{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Parser where

import Bound
import Control.Applicative((<|>), Alternative)
import Control.Monad.Except
import Control.Monad.State
import Data.Text(Text)
import Data.Char
import qualified Data.HashSet as HS
import Data.Ord
import qualified Text.Parser.Token.Highlight as Highlight
import qualified Text.Trifecta as Trifecta
import Text.Trifecta((<?>))
import Text.Trifecta.Delta

import Annotation
import Hint
import Input
import Util

type Input = Text
newtype Parser a = Parser {runParser :: StateT Delta Trifecta.Parser a}
  deriving ( Monad, MonadPlus, MonadState Delta
           , Functor, Applicative, Alternative
           , Trifecta.Parsing, Trifecta.CharParsing
           , Trifecta.DeltaParsing
           )

parseString :: Parser a -> String -> Trifecta.Result a
parseString p = Trifecta.parseString (evalStateT (runParser p) mempty <* Trifecta.eof) mempty

parseFromFile :: MonadIO m => Parser a -> FilePath -> m (Maybe a)
parseFromFile p = Trifecta.parseFromFile
                $ evalStateT (runParser p) mempty <* Trifecta.eof

instance Trifecta.TokenParsing Parser where
  someSpace = Trifecta.skipSome (Trifecta.satisfy isSpace) *> (comments <|> pure ())
           <|> comments
    where
      comments = (lineComment <|> multilineComment) *> Trifecta.whiteSpace

lineComment :: Parser ()
lineComment =
  () <$ Trifecta.string "--"
     <* Trifecta.manyTill Trifecta.anyChar (Trifecta.char '\n')
     <?> "line comment"

multilineComment :: Parser ()
multilineComment =
  () <$ Trifecta.string "{-" <* inner
  <?> "multi-line comment"
  where
    inner =  Trifecta.string "-}"
         <|> multilineComment *> inner
         <|> Trifecta.anyChar *> inner


deltaLine :: Delta -> Int
deltaLine Columns {}           = 0
deltaLine Tab {}               = 0
deltaLine (Lines l _ _ _)      = fromIntegral l + 1
deltaLine (Directed _ l _ _ _) = fromIntegral l + 1

deltaColumn :: Delta -> Int
deltaColumn pos = fromIntegral (column pos) + 1

-- | Drop the indentation anchor -- use the current position as the reference
--   point in the given parser.
dropAnchor :: Parser a -> Parser a
dropAnchor p = do
  oldAnchor <- get
  pos       <- Trifecta.position
  put pos
  result    <- p
  put oldAnchor
  return result

-- | Check that the current indentation level is the same as the anchor
sameCol :: Parser ()
sameCol = do
  pos    <- Trifecta.position
  anchor <- get
  case comparing deltaColumn pos anchor of
    LT -> Trifecta.unexpected "unindent"
    EQ -> return ()
    GT -> Trifecta.unexpected "indent"

-- | Check that the current indentation level is on the same line as the anchor
--   or on a successive line but more indented.
sameLineOrIndented :: Parser ()
sameLineOrIndented = do
  pos    <- Trifecta.position
  anchor <- get
  case (comparing deltaLine pos anchor, comparing deltaColumn pos anchor) of
    (EQ, _)  -> return () -- Same line
    (GT, GT) -> return () -- Indented
    (_,  _)  -> Trifecta.unexpected "unindent"

-- | One or more at the same indentation level.
someSameCol :: Parser a -> Parser [a]
someSameCol p = Trifecta.some (sameCol >> p)

-- | Zero or more at the same indentation level.
manySameCol :: Parser a -> Parser [a]
manySameCol p = Trifecta.many (sameCol >> p)

-- | One or more on the same line or a successive but indented line.
someSI :: Parser a -> Parser [a]
someSI p = Trifecta.some (sameLineOrIndented >> p)
--
-- | Zero or more on the same line or a successive but indented line.
manySI :: Parser a -> Parser [a]
manySI p = Trifecta.many (sameLineOrIndented >> p)

-- * Applicative style combinators for checking that the second argument parser
--   is on the same line or indented compared to the anchor.
infixl 4 <$>%, <$%, <*>%, <*%, *>%
(<$>%) :: (a -> b) -> Parser a -> Parser b
f <$>% p = f <$> (sameLineOrIndented >> p)
(<$%) :: a -> Parser b -> Parser a
f <$%  p = f <$  (sameLineOrIndented >> p)
(<*>%) :: Parser (a -> b) -> Parser a -> Parser b
p <*>% q = p <*> (sameLineOrIndented >> q)
(<*%) :: Parser a -> Parser b -> Parser a
p <*%  q = p <*  (sameLineOrIndented >> q)
(*>%) :: Parser a -> Parser b -> Parser b
p *>%  q = p *>  (sameLineOrIndented >> q)

idStyle :: Trifecta.CharParsing m => Trifecta.IdentifierStyle m
idStyle = Trifecta.IdentifierStyle "Dependent" start letter res Highlight.Identifier Highlight.ReservedIdentifier
  where
    start  = Trifecta.satisfy isAlpha    <|> Trifecta.oneOf "_"
    letter = Trifecta.satisfy isAlphaNum <|> Trifecta.oneOf "_'"
    res    = HS.fromList ["forall", "_", "Type"]

ident :: Parser Name
ident = Trifecta.token $ Trifecta.ident idStyle

reserved :: String -> Parser ()
reserved = Trifecta.token . Trifecta.reserve idStyle

wildcard :: Parser ()
wildcard = reserved "_"

identOrWildcard :: Parser (Maybe Name)
identOrWildcard = Just <$> ident
               <|> Nothing <$ wildcard

symbol :: String -> Parser Name
symbol = Trifecta.token . Trifecta.symbol

data Binding
  = Plain Plicitness [Maybe Name]
  | Typed Plicitness [Maybe Name] (Expr Name)
  deriving (Eq, Ord, Show)

abstractBindings :: (NameHint -> Plicitness -> Maybe (Expr Name)
                              -> Scope1 Expr Name -> Expr Name)
                 -> [Binding]
                 -> Expr Name -> Expr Name
abstractBindings c = flip $ foldr f
  where
    f (Plain p xs)   e = foldr (\x -> c (h x) p Nothing  . abstractMaybe1 x) e xs
    f (Typed p xs t) e = foldr (\x -> c (h x) p (Just t) . abstractMaybe1 x) e xs
    abstractMaybe1 = maybe abstractNone abstract1
    h = Hint

atomicBinding :: Parser Binding
atomicBinding
  =  Plain Explicit . (:[]) <$> identOrWildcard
 <|> Typed Explicit <$ symbol "(" <*>% someSI identOrWildcard <*% symbol ":" <*>% expr <*% symbol ")"
 <|> implicit <$ symbol "{" <*>% someSI identOrWildcard
              <*> Trifecta.optional (id <$% symbol ":" *> expr)
              <*% symbol "}"
 <?> "atomic variable binding"
 where
  implicit xs Nothing  = Plain Implicit xs
  implicit xs (Just t) = Typed Implicit xs t

someBindings :: Parser [Binding]
someBindings
  = someSI atomicBinding
 <?> "variable bindings"

manyBindings :: Parser [Binding]
manyBindings
  = manySI atomicBinding
 <?> "variable bindings"

atomicExpr :: Parser (Expr Name)
atomicExpr
  =  Type     <$ reserved "Type"
 <|> Wildcard <$ wildcard
 <|> Var      <$> ident
 <|> abstr (reserved "forall") Pi
 <|> abstr (symbol   "\\")     lam
 <|> symbol "(" *>% expr <*% symbol ")"
 <?> "atomic expression"
  where
    abstr t c = abstractBindings c <$ t <*>% someBindings <*% symbol "." <*>% expr

followedBy :: (Monad m, Alternative m) => m a -> [a -> m b] -> m b
followedBy p ps = do
  x <- p
  Trifecta.choice $ map ($ x) ps

expr :: Parser (Expr Name)
expr
  = (foldl (uncurry . App) <$> atomicExpr <*> manySI argument)
     `followedBy` [typeAnno, arr Explicit, return]
 <|> ((symbol "{" *>% expr <*% symbol "}") `followedBy` [arr Implicit])
 <?> "expression"
  where
    typeAnno e  = Anno e <$% symbol ":" <*>% expr
    arr p e = (Pi (Hint Nothing) p (Just e) . Scope . Var . F)
           <$% symbol "->" <*>% expr
    argument :: Parser (Plicitness, Expr Name)
    argument =  (,) Implicit <$ symbol "{" <*>% expr <*% symbol "}"
            <|> (,) Explicit <$> atomicExpr

topLevel :: Parser (TopLevel Name)
topLevel =  ident    `followedBy` [typeDecl, def . Just]
        <|> wildcard `followedBy` [const $ def Nothing]
  where
    typeDecl n = TypeDecl n <$% symbol ":" <*>% expr
    def n = DefLine n <$>% (abstractBindings lam <$> manyBindings <*% symbol "=" <*>% expr)

program :: Parser [TopLevel Name]
program = dropAnchor (manySameCol $ dropAnchor topLevel)

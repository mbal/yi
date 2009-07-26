{-# LANGUAGE Rank2Types #-}
module Yi.Lexer.Alex (
                       alexGetChar, alexInputPrevChar, unfoldLexer, lexScanner,
                       alexCollectChar, 
                       AlexState(..), AlexInput, Stroke,
                       actionConst, actionAndModify, actionStringAndModify, actionStringConst,
                       Tok(..), tokBegin, tokEnd, tokFromT, tokRegion, 
                       Posn(..), startPosn, moveStr, 
                       ASI,
                       (+~), (~-), Size(..),
                       tokToSpan
                      ) where

import Yi.Syntax hiding (mkHighlighter)
import Yi.Prelude
import Prelude ()
import Yi.Region
import Data.Ord (comparing)
import Data.Ix

type IndexedStr = [(Point, Char)]
type AlexInput = (Char, IndexedStr)
type Action hlState token = IndexedStr -> hlState -> (hlState, token)

-- | Lexer state
data AlexState lexerState = AlexState {
      stLexer  :: lexerState,   -- (user defined) lexer state
      lookedOffset :: !Point, -- Last offset looked at
      stPosn :: !Posn
    } deriving Show

data Tok t = Tok
    {
     tokT :: t,
     tokLen  :: Size,
     tokPosn :: Posn
    }

instance Functor Tok where
    fmap f (Tok t l p) = Tok (f t) l p



tokToSpan :: Tok t -> Span t
tokToSpan (Tok t len posn) = Span (posnOfs posn) t (posnOfs posn +~ len)

tokFromT :: forall t. t -> Tok t
tokFromT t = Tok t 0 startPosn

tokBegin :: forall t. Tok t -> Point
tokBegin = posnOfs . tokPosn

tokEnd :: forall t. Tok t -> Point
tokEnd t = tokBegin t +~ tokLen t

tokRegion :: Tok t -> Region
tokRegion t = mkRegion (tokBegin t) (tokEnd t)


instance Show t => Show (Tok t) where
    show tok = show (tokPosn tok) ++ ": " ++ show (tokT tok)

data Posn = Posn {
      posnOfs :: !Point
    , posnLine :: !Int
    , posnCol :: !Int
  } deriving (Eq, Ix)

-- TODO: Verify that this is right.  /Deniz
instance Ord Posn where
    compare = comparing posnOfs

instance Show Posn where
    show (Posn o l c) = "L" ++ show l ++ " " ++ "C" ++ show c ++ "@" ++ show o

startPosn :: Posn
startPosn = Posn 0 1 0


moveStr :: Posn -> IndexedStr -> Posn
moveStr posn str = foldl' moveCh posn (fmap snd str)

moveCh :: Posn -> Char -> Posn
moveCh (Posn o l c) '\t' = Posn (o+1) l       (((c+8) `div` 8)*8)
moveCh (Posn o l _) '\n' = Posn (o+1) (l+1)   0
moveCh (Posn o l c) _    = Posn (o+1) l       (c+1)

alexGetChar :: AlexInput -> Maybe (Char, AlexInput)
alexGetChar (_,[]) = Nothing
alexGetChar (_,(_,c):rest) = Just (c, (c,rest))

alexCollectChar :: AlexInput -> [Char]
alexCollectChar (_, []) = []
alexCollectChar (_, (_,c):rest) = c : (alexCollectChar (c,rest))

alexInputPrevChar :: AlexInput -> Char
alexInputPrevChar (prevChar,_) = prevChar

actionConst :: token -> Action lexState token
actionConst token _str state = (state, token)

actionAndModify :: (lexState -> lexState) -> token -> Action lexState token
actionAndModify modifierFct token _str state = (modifierFct state, token)

actionStringAndModify :: (lexState -> lexState) -> (String ->token) -> Action lexState token
actionStringAndModify modifierFct f indexedStr state = (modifierFct state, f $ fmap snd indexedStr)

actionStringConst :: (String -> token) -> Action lexState token
actionStringConst f indexedStr state = (state, f $ fmap snd indexedStr)

type ASI s = (AlexState s, AlexInput)

lexScanner :: forall lexerState token.
                                          ((AlexState lexerState, AlexInput)
                                           -> Maybe (token, (AlexState lexerState, AlexInput)))
                                          -> lexerState
                                          -> Scanner Point Char
                                          -> Scanner (AlexState lexerState) token
lexScanner l st0 src = Scanner
                 {
                  --stStart = posnOfs . stPosn,
                  scanLooked = lookedOffset,
                  scanInit = AlexState st0 0 startPosn,
                  scanRun = \st -> 
                     case posnOfs $ stPosn st of
                         0 -> unfoldLexer l (st, ('\n', scanRun src 0))
                         ofs -> case scanRun src (ofs - 1) of 
                             -- FIXME: if this is a non-ascii char the ofs. will be wrong.
                             -- However, since the only thing that matters (for now) is 'is the previous char a new line', we don't really care.
                             -- (this is to support ^,$ in regexes)
                             [] -> []
                             ((_,ch):rest) -> unfoldLexer l (st, (ch, rest))
                 }

-- | unfold lexer function into a function that returns a stream of (state x token)
unfoldLexer :: ((AlexState lexState, input) -> Maybe (token, (AlexState lexState, input)))
             -> (AlexState lexState, input) -> [(AlexState lexState, token)]
unfoldLexer f b = case f b of
             Nothing -> []
             Just (t, b') -> (fst b, t) : unfoldLexer f b'